#!/bin/bash
# bro v3.6 — Stop hook (the turnstile).
# Blocks the end of a turn when today's journal for this workspace is stale
# or missing, at most once per (session, prompt) — loop-proof by construction.
# v3.6: also watches the session-start hook — a start that never finished is
# recovered here and reported, instead of leaving the chat blind in silence.
# Workspace resolution walks UP from cwd (config map, then dir slugs).
# Works without jq (sed fallback for parsing; exit-2 fallback for blocking).
#
# v3.7 — hash-gated form lint (§5 of the v3.7 plan). Before this, the lint
# below scanned the WHOLE journal every Stop, so one chat's bad content (or
# stale pre-upgrade content) blocked every OTHER chat's unrelated turn too.
# Now every range bro-append.sh already validated and logged to
# <ws>/.append-log is skipped by the per-occurrence checks (section-header
# format, future-time, colonless marker) as long as its bytes still match
# the hash logged at write time — a hand-edit or historical content changes
# the hash and still gets full scrutiny. This is a content-hash backstop,
# not a session/trust claim: it cannot be spoofed by claiming "some session
# already wrote this," only by matching the exact bytes that were validated.

set -uo pipefail

# bro-lib.sh for hash_range() (the hash-gated lint below) and MRE_NOCOLON
# (the colonless-marker lint, shared with bro-append.sh's pre-write
# validator — see bro-lib.sh's own header for why this is centralized).
# Missing lib degrades (hash-gating off, a locally-duplicated regex takes
# over) rather than disabling the whole turnstile — the freshness check
# below doesn't need bro-lib.sh at all, and losing it silently over one
# missing file would be a much worse failure than a noisier lint.
HAS_LIB=1
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -n "$LIB_DIR" ] && [ -f "$LIB_DIR/bro-lib.sh" ]; then
  . "$LIB_DIR/bro-lib.sh"
else
  HAS_LIB=0
  # v3.8 (§1): kept textually in sync by hand with bro-lib.sh's own
  # MRE_NOCOLON (two RU writings for the original six keywords; STATE and
  # INSIGHT added ALL-CAPS-only, no "Состояние"/"Инсайт" writing — see
  # bro-lib.sh's MRE comment for why; also the optional leading "- " bullet,
  # added there to match MRE's own shape — this copy had fallen behind that
  # one-character change until the coordinator caught it, copied verbatim
  # from bro-lib.sh again here) — this copy only runs when bro-lib.sh itself
  # couldn't be sourced, so it can't call marker_type() or reference
  # bro-lib.sh's variable; it has to be a literal, same as before 3.7
  # extracted the canonical copy out of this file.
  # v3.9 (§1 of the v3.9 plan): OPEN (new EN canonical spelling, was TAIL)
  # and ДЕЛО (new RU spelling, ALL-CAPS only, same discipline as
  # STATE/INSIGHT above) added, brought in verbatim from bro-lib.sh's own
  # copy — same by-hand sync discipline noted above. TAIL/ХВОСТ/Хвост stay
  # in the list unchanged: an untranslated store still writes them, and a
  # colonless line in any of the five open-item spellings must still be
  # caught here exactly as before.
  MRE_NOCOLON='^[[:space:]]*(-[[:space:]]+)?([*][*])?((DECIDED|RULE|OPEN|TAIL|TERM|REJECTED|STATE|INSIGHT|CLOSED)|(РЕШЕНИЕ|Решение|ПРАВИЛО|Правило|ДЕЛО|ХВОСТ|Хвост|ТЕРМИН|Термин|ОТКАЗ|Отказ|ЗАКРЫТ|Закрыт|СОСТОЯНИЕ|ИНСАЙТ))([*][*])?[[:space:]][^:]*$'
  # v3.8, coordinator fix (re-review after §"pending project"): the same
  # reasoning as MRE_NOCOLON just above — lock()/unlock() normally come
  # from bro-lib.sh, sourced above; this is the literal fallback for when
  # it could not be found, copied verbatim from bro-lib.sh's own copy so
  # the pending-project race fix below (which needs a real mutex, not just
  # a regex) still works in degraded mode.
  lock() {
    local l="$1.lock" i=0
    until mkdir "$l" 2>/dev/null; do
      if [ -n "$(find "$l" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
        rmdir "$l" 2>/dev/null && continue
      fi
      i=$((i+1)); [ "$i" -gt 60 ] && return 1
      sleep 0.05
    done
    return 0
  }
  unlock() { rmdir "$1.lock" 2>/dev/null; return 0; }
  mkdir -p "$HOME/.claude/bro" 2>/dev/null
  echo "$(date '+%F %H:%M')  bro-stop-turnstile: bro-lib.sh not found next to $0 — hash-gated lint disabled, running degraded" >> "$HOME/.claude/bro/health.log" 2>/dev/null
fi

command -v jq >/dev/null 2>&1 && HAS_JQ=1 || HAS_JQ=0
CONFIG="$HOME/.claude/bro-config.json"

if [ "$HAS_JQ" = 1 ]; then
  ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
  STALE_MIN=$(jq -r '.staleMinutes // 30' "$CONFIG" 2>/dev/null || echo 30)
else
  ROOT="~/bro"; STALE_MIN=30
fi
ROOT="${ROOT/#\~/$HOME}"

INPUT=$(cat)
jget() {
  if [ "$HAS_JQ" = 1 ]; then
    echo "$INPUT" | jq -r ".$1 // empty" 2>/dev/null
  else
    printf '%s' "$INPUT" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}
CWD=$(jget cwd); [ -z "$CWD" ] && CWD=$(pwd)
SID=$(jget session_id)
case "$SID" in *[!A-Za-z0-9_-]*) SID="" ;; esac   # used as a file name below — ids are uuids, nothing else passes
PROMPT_ID=$(jget prompt_id)
[ -n "$SID" ] && [ -f "$HOME/.claude/bro/off/$SID" ] && exit 0
# moved up from its old position further down (the v3.6 watchdogs' own
# section) — the pending-project logic right below needs it too, and it's
# a pure path string, safe to have this early.
MARK="$HOME/.claude/bro/started/$SID"

slug_of() { basename "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-._'; }
WS=""
D="$CWD"
while :; do
  if [ "$HAS_JQ" = 1 ]; then
    M=$(jq -r --arg c "$D" '.workspaces[$c] // empty' "$CONFIG" 2>/dev/null)
    [ -n "$M" ] && { WS="$M"; break; }
  fi
  [ "$D" = "$HOME" ] || [ "$D" = "/" ] && break
  D=$(dirname "$D")
done
if [ -z "$WS" ]; then
  D="$CWD"
  while [ "$D" != "$HOME" ] && [ "$D" != "/" ]; do
    S=$(slug_of "$D")
    if [ -n "$S" ] && [ -d "$ROOT/$S" ]; then WS="$S"; break; fi
    D=$(dirname "$D")
  done
fi

JUST_CONNECTED=0
PROOT=""
if [ -z "$WS" ]; then
  # v3.8, operator's own decision — bro-session-start.sh no longer creates
  # a workspace the moment it sees an unconnected git repo (that gave 16
  # throwaway projects on the real disk); instead it leaves the candidate
  # name+root at "$MARK.pending-project" and this hook counts the chat's
  # own RESPONSES against it, creating the workspace only once real work
  # has happened. Git itself is never re-run here — only session-open ever
  # calls it (coordinator was explicit: do not duplicate that logic) — this
  # is purely reading what that one call already decided.
  PENDING_FILE="$MARK.pending-project"
  [ -n "$SID" ] && [ -f "$PENDING_FILE" ] || exit 0
  PNAME=""
  IFS=$'\t' read -r PNAME PROOT < "$PENDING_FILE" 2>/dev/null
  [ -n "$PNAME" ] || exit 0

  THRESHOLD=5
  if [ "$HAS_JQ" = 1 ]; then
    THRESHOLD=$(jq -r '.autoCreateAfterAnswers // 5' "$CONFIG" 2>/dev/null)
    case "$THRESHOLD" in ''|*[!0-9]*) THRESHOLD=5 ;; esac
  fi

  # count THIS response, deduped by prompt_id: a block anywhere in this
  # file can make Claude Code re-fire Stop for the SAME prompt (retry),
  # and that must not count as a second response; a genuinely new
  # prompt_id always does. $MARK.pending-count: "count<TAB>last_prompt_id".
  COUNT_FILE="$MARK.pending-count"
  CUR_COUNT=0; LAST_PID=""
  if [ -f "$COUNT_FILE" ]; then
    IFS=$'\t' read -r CUR_COUNT LAST_PID < "$COUNT_FILE" 2>/dev/null
    case "$CUR_COUNT" in ''|*[!0-9]*) CUR_COUNT=0 ;; esac
  fi
  if [ -z "$PROMPT_ID" ] || [ "$PROMPT_ID" != "$LAST_PID" ]; then
    CUR_COUNT=$((CUR_COUNT + 1))
    printf '%s\t%s\n' "$CUR_COUNT" "$PROMPT_ID" > "$COUNT_FILE" 2>/dev/null
  fi

  [ "$CUR_COUNT" -ge "$THRESHOLD" ] 2>/dev/null || exit 0   # below threshold: stay completely silent, no block

  # threshold reached: work has actually happened in this chat — connect
  # it for real now.
  #
  # v3.8, coordinator fix (re-review): two chats in the SAME unconnected
  # repo can both cross their OWN threshold at almost the same instant.
  # mkdir -p being idempotent is not enough on its own — without a lock,
  # BOTH processes can see "the folder doesn't exist yet" before either
  # has created it, both mkdir (harmless), and both conclude "I must be
  # the one telling the chat to start the chronicle" — confirmed live: two
  # genuinely concurrent Stop calls both got the "project is now
  # connected... start its chronicle" block. The fix is not to lock
  # around the mkdir alone: checking "does today's journal exist yet"
  # would NOT discriminate correctly either, since the actual creator
  # hasn't had a turn to call bro-append.sh yet at this exact moment — a
  # naive lock around just that check would still let both processes see
  # "no journal" and both announce. What actually has to be decided
  # atomically is "did *I* find the folder missing and create it, or was
  # it already there" — that answer can only be trusted if checked and
  # acted on under one lock, keyed by the future project path itself
  # (lock()/unlock() from bro-lib.sh, or the matching fallback copy above
  # when it could not be sourced). Only the process that finds it missing
  # sets JUST_CONNECTED and gets the chronicle-start block below; the
  # other finds it already there, adopts it silently, and falls through
  # to the ordinary connected-project flow — which runs its own
  # independent freshness/no-journal check if the creator has not
  # appended yet, using ITS OWN generic wording, never a second copy of
  # the "just connected" message for the same event.
  if lock "$ROOT/$PNAME"; then
    if [ -d "$ROOT/$PNAME" ]; then
      WS="$PNAME"   # someone else already won the race under this same lock
    elif mkdir -p "$ROOT/$PNAME" 2>/dev/null; then
      WS="$PNAME"
      JUST_CONNECTED=1
    fi
    unlock "$ROOT/$PNAME"
  fi
  [ -n "$WS" ] && rm -f "$PENDING_FILE" "$COUNT_FILE" 2>/dev/null
  [ -n "$WS" ] || exit 0   # lock never obtained, or mkdir failed (permissions) -- stay silent, nothing this chat can fix by being blocked
fi
WS_DIR="$ROOT/$WS"
[ -d "$WS_DIR" ] || exit 0

# store must be current major — during migration limbo, never block
[ "$(cat "$ROOT/.version" 2>/dev/null || echo 0)" -ge 3 ] 2>/dev/null || exit 0

TODAY_FILE="$WS_DIR/$(date +%F).md"
# moved up from this file's old bottom section (still used there too) —
# the JUST_CONNECTED block right after block() below needs it as well.
NOWSTAMP="$(date '+%F %H:%M (%A)')"
# v3.9 (§5 of the v3.9 plan): same canonical list bro-session-start.sh
# teaches at chat open — DECIDED:/REJECTED:/RULE:/OPEN:/TERM:/STATE:/
# INSIGHT:, plus CLOSED <id>: to close one (was .../RULE:/TAIL:/TERM:/
# CLOSED:...; OPEN replaces TAIL as the canonical open-item spelling, and
# STATE:/INSIGHT: are now named here too, matching that same list exactly
# instead of a shorter one drifting from it). Russian aliases are named
# once, in a single clause, rather than paired keyword-by-keyword as before.
APPENDHOW="Bash: \`~/.claude/bro/bin/bro-append.sh --workspace $WS --thread '<work thread>' --topic '<topic with a distinguishing detail>'\` with the section body on stdin (markers DECIDED:/REJECTED:/RULE:/OPEN:/TERM:/STATE:/INSIGHT:, and CLOSED <id>: to close one — Russian aliases are also accepted: РЕШЕНИЕ:/ОТКАЗ:/ПРАВИЛО:/ДЕЛО:/ТЕРМИН:/СОСТОЯНИЕ:/ИНСАЙТ:/ЗАКРЫТ:) — never Write/Edit $TODAY_FILE directly, the write guard denies it"

# one block per (session, prompt); prune day-old guard files
GUARD_DIR="${TMPDIR:-/tmp}/bro-turnstile"
mkdir -p "$GUARD_DIR" 2>/dev/null
find "$GUARD_DIR" -type f -mtime +1 -delete 2>/dev/null
GUARD="$GUARD_DIR/${SID:-nosid}__${PROMPT_ID:-noprompt}"
[ -f "$GUARD" ] && exit 0
# the watchdogs below keep their own slot: a prompt can be blocked once by a watchdog
# and once by the freshness check — never more, and neither can starve the other
GUARD_W="${GUARD}__watch"

block() { # $1 = reason; blocks this stop once and exits
  if [ "$HAS_JQ" = 1 ]; then
    # both contract generations: top-level decision/reason (classic) + continueLoop (current)
    jq -cn --arg r "$1" '{decision:"block",reason:$r,hookSpecificOutput:{hookEventName:"Stop",continueLoop:true,additionalContext:$r}}'
    exit 0
  else
    # no jq: exit 2 blocks the stop; stderr is fed back to the model
    echo "$1" >&2
    exit 2
  fi
}

# v3.8, operator's own decision — this turn is the one where a pending
# project actually got connected (mkdir just ran, above). If its chronicle
# doesn't exist yet, starting it IS the very first thing this chat must do:
# block with the instructions right here, before the ordinary watchdogs
# below (which check things — a completed harvest pass, a finished
# session-start — that cannot possibly be true yet for a workspace that is
# zero seconds old, and would only produce a less specific message for the
# same underlying situation). If the chronicle already exists — a second
# chat reached the SAME repo's own threshold after another one already
# connected it and wrote to it (see tests/parts/c-hooks.sh) — there is
# nothing special left to do: fall through to the ordinary flow below,
# same as any other already-connected project.
if [ "$JUST_CONNECTED" = 1 ] && [ ! -f "$TODAY_FILE" ]; then
  block "bro [NOW: $NOWSTAMP]: project '$WS' is now connected (root: $PROOT) — start its chronicle now via $APPENDHOW, and fill in $WS_DIR/_workspace.md (what this is / people / pointers) from what you learn in this chat, then finish your reply."
fi

# v3.6 watchdog — the enforcer's enforcer. bro-session-start.sh leaves a mark per
# session: "pending" on entry, "ok" once its context is out; bro-precompact.sh
# sets it back to "pending" before every compaction. A mark still at "pending"
# means the start hook died on the way (timeout, crash) or never ran after a
# compaction, and this chat is working without principles and read-order.
# Recover here: hand the chat the same context, log it, and have the operator
# told — a dead start must never be silent, whatever else goes wrong below.
if [ -n "$SID" ] && [ ! -f "$GUARD_W" ] && [ -f "$MARK" ] && [ "$(cat "$MARK" 2>/dev/null)" != "ok" ]; then
  START="$(dirname "$0")/bro-session-start.sh"
  [ -x "$START" ] || START="$HOME/.claude/bro/bin/bro-session-start.sh"
  RECOVERED=$(printf '%s' "$INPUT" | "$START" --context-only 2>/dev/null)
  [ -n "$RECOVERED" ] || RECOVERED="(the context could not be rebuilt either — read $ROOT/_principles.md and today's journal in $WS_DIR by hand, and run /bro status)"
  touch "$GUARD_W" 2>/dev/null
  echo ok > "$MARK" 2>/dev/null
  HEALTH="$HOME/.claude/bro/health.log"
  echo "$(date '+%F %H:%M')  session-start did not finish — context recovered by the stop hook  ws=$WS  session=${SID%%-*}" >> "$HEALTH" 2>/dev/null
  [ "$(wc -l < "$HEALTH" 2>/dev/null | tr -d ' ')" -gt 400 ] 2>/dev/null && tail -n 200 "$HEALTH" > "$HEALTH.tmp" 2>/dev/null && mv "$HEALTH.tmp" "$HEALTH"
  block "bro watchdog [NOW: $(date '+%F %H:%M (%A)')]: the session-start hook did not finish in this session (it timed out or crashed, or a compaction was cut short), so this chat has been working without bro context. Tell the operator in one line that bro's session start failed and was recovered by the stop hook (details: ~/.claude/bro/health.log). Then do what it would have asked — $RECOVERED"
fi

# …and the background harvest has a watcher too. Ten minutes after this session's
# last start, a COMPLETED harvest pass must exist that began around or after that
# start (any chat's pass counts — the stamp is per workspace). If not, the async
# hook is not running here (chat opened before an update, hook not registered,
# pass keeps failing): have this chat run the harvest itself and tell the operator.
# Once per session.
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
HWARNED="$MARK.harvest-warned"
if [ -n "$SID" ] && [ ! -f "$GUARD_W" ] && [ -f "$MARK" ] && [ ! -f "$HWARNED" ]; then
  M_AT=$(mtime_of "$MARK"); H_AT=$(mtime_of "$WS_DIR/.harvest-stamp")
  if [ $(( $(date +%s) - M_AT )) -gt 600 ] && [ $(( H_AT + 60 )) -lt "$M_AT" ]; then
    touch "$GUARD_W" 2>/dev/null
    : > "$HWARNED" 2>/dev/null
    echo "$(date '+%F %H:%M')  no completed harvest pass since this session started — chat asked to run it  ws=$WS  session=${SID%%-*}" >> "$HOME/.claude/bro/health.log" 2>/dev/null
    block "bro watchdog [NOW: $(date '+%F %H:%M (%A)')]: no harvest pass has completed for workspace '$WS' since this chat started, so its registers (decisions.md, open.md, vocab.md, rule candidates) may be missing records. Run now with Bash: ~/.claude/bro/bin/bro-harvest.sh --workspace $WS — then tell the operator in one line that bro's background harvest is not running in this chat (a chat opened before a bro update needs to be reopened once; otherwise see ~/.claude/bro/health.log and /bro status), and finish your reply."
  fi
fi

fresh=0
if [ -f "$TODAY_FILE" ]; then
  AGE_MIN=$(( ( $(date +%s) - $(stat -f %m "$TODAY_FILE" 2>/dev/null || stat -c %Y "$TODAY_FILE" 2>/dev/null || echo 0) ) / 60 ))
  [ "$AGE_MIN" -lt "$STALE_MIN" ] && fresh=1
fi

# v3.7 (§5) — hash-gated trusted ranges. <ws>/.append-log has one line per
# bro-append.sh write: date/time, session, journal basename, line range,
# sha256 of that range (hash_range(), from bro-lib.sh — same function both
# sides use, so a re-hash here can only agree with the logged one if the
# bytes are truly unchanged). A range only stays trusted while its CURRENT
# bytes still match; a hand-edit or historical pre-upgrade content changes
# the hash and falls back into full scrutiny below, same as before this
# version. Built once per Stop call, from EVERY session's log entries (not
# just this chat's) — trust is a property of the bytes, not of who wrote them.
TRUSTED_LINES=""
if [ "$HAS_LIB" = 1 ] && [ -f "$WS_DIR/.append-log" ] && [ -f "$TODAY_FILE" ]; then
  TB=$(basename "$TODAY_FILE")
  while IFS=$'\t' read -r _ _ LOGF RANGE LOGHASH; do
    [ "$LOGF" = "$TB" ] || continue
    FROM="${RANGE%-*}"; TO="${RANGE#*-}"
    case "$FROM" in ''|*[!0-9]*) continue ;; esac
    case "$TO" in ''|*[!0-9]*) continue ;; esac
    [ "$(hash_range "$TODAY_FILE" "$FROM" "$TO")" = "$LOGHASH" ] && TRUSTED_LINES="$TRUSTED_LINES $FROM-$TO"
  done < "$WS_DIR/.append-log" 2>/dev/null
fi

LINT=""
if [ -f "$TODAY_FILE" ]; then
  # existence checks run on the real file, unfiltered — they ask "is there a
  # well-formed header/section anywhere", not "does every occurrence pass",
  # so trust status doesn't change their answer (trusted content, by
  # construction, already has a well-formed header — see bro-append.sh).
  head -1 "$TODAY_FILE" | grep -qE "^# bro — [0-9]{4}-[0-9]{2}-[0-9]{2}" \
    || LINT="$LINT Header must be '# bro — YYYY-MM-DD / <workspace>'."
  grep -qE "^## " "$TODAY_FILE" \
    || LINT="$LINT At least one '## HH:MM · <thread> — <topic>' section is required."

  # per-occurrence checks (section-header format, future-time, colonless
  # marker) run against SCAN_FILE, where every trusted line is blanked —
  # same line numbers, so nothing shifts, but a trusted line can no longer
  # match any of these patterns and add to a count. An untrusted line (hand-
  # edit, historical content, anything that bypassed bro-append.sh) is
  # identical in SCAN_FILE to the real file and gets full scrutiny.
  SCAN_FILE="$TODAY_FILE"
  if [ -n "$TRUSTED_LINES" ]; then
    SCAN_FILE=$(mktemp "${TMPDIR:-/tmp}/bro-scan.XXXXXX" 2>/dev/null) || SCAN_FILE="$TODAY_FILE"
    if [ "$SCAN_FILE" != "$TODAY_FILE" ]; then
      awk -v trusted="$TRUSTED_LINES" '
        BEGIN { n = split(trusted, ranges, " ")
                for (i = 1; i <= n; i++) { split(ranges[i], b, "-"); for (j = b[1]; j <= b[2]; j++) T[j] = 1 } }
        { print (NR in T) ? "" : $0 }
      ' "$TODAY_FILE" > "$SCAN_FILE" 2>/dev/null
    fi
  fi

  # canonical section headers: '## HH:MM · <thread> — <topic>'
  BADHDR=$(grep -cE '^## ' "$SCAN_FILE" 2>/dev/null || true); GOODHDR=$(grep -cE '^## [0-9]{2}:[0-9]{2} · .+ — ' "$SCAN_FILE" 2>/dev/null || true)
  [ -n "$BADHDR" ] || BADHDR=0; [ -n "$GOODHDR" ] || GOODHDR=0
  [ "$BADHDR" -gt "$GOODHDR" ] 2>/dev/null \
    && LINT="$LINT $((BADHDR-GOODHDR)) section header(s) off-format — must be '## HH:MM · <thread> — <topic>'."
  # future-time headers: the time was invented, not taken from date
  FUT=$(grep -oE '^## [0-9]{2}:[0-9]{2}' "$SCAN_FILE" 2>/dev/null | awk -v nh="$(date +%H)" -v nm="$(date +%M)" '{hh=substr($0,4,2)+0; mm=substr($0,7,2)+0; if (hh*60+mm > nh*60+nm+3) {print substr($0,4); exit}}')
  [ -n "$FUT" ] && LINT="$LINT Section time $FUT is in the FUTURE (now $(date +%H:%M)) — take time from date, fix the header."
  # marker-like lines missing the colon are silently lost to harvest
  # v3.7: CLOSED/ЗАКРЫТ (§1) added alongside the other five keywords;
  # MRE_NOCOLON now comes from bro-lib.sh (or its degraded fallback above).
  SUS=$(grep -cE "$MRE_NOCOLON" "$SCAN_FILE" 2>/dev/null || true)
  [ -n "$SUS" ] || SUS=0
  [ "$SUS" -gt 0 ] 2>/dev/null && LINT="$LINT $SUS marker-like line(s) without ':' — harvest will skip them; write 'KEYWORD: text' or reword."
  [ "$SCAN_FILE" != "$TODAY_FILE" ] && rm -f "$SCAN_FILE" 2>/dev/null
fi

if [ "$fresh" = 1 ] && [ -z "$LINT" ]; then
  exit 0
fi

touch "$GUARD" 2>/dev/null

# NOWSTAMP and APPENDHOW are computed once, right after TODAY_FILE, near
# the top of this file — the JUST_CONNECTED block above needs them too.
if [ ! -f "$TODAY_FILE" ]; then
  REASON="bro turnstile [NOW: $NOWSTAMP — sync your clock to this]: no journal for today. It's created automatically on the first append — log this session's substance now via $APPENDHOW, then finish your reply."
elif [ "$fresh" = 0 ]; then
  REASON="bro turnstile [NOW: $NOWSTAMP — sync your clock to this]: journal $TODAY_FILE is ${AGE_MIN}min stale (threshold ${STALE_MIN}min). Append a section covering what happened since the last entry via $APPENDHOW, then finish your reply.${LINT:+ Also fix:$LINT}"
else
  REASON="bro turnstile [NOW: $NOWSTAMP — sync your clock to this]: journal format issues in $TODAY_FILE (outside anything bro-append.sh already validated) —$LINT The write guard denies a direct Write/Edit on this file, so these lines can't be patched in place from this chat — if you just wrote them, undo isn't available either; append a corrected line instead via $APPENDHOW. If this is pre-existing content from before this chat, tell the operator it needs a hand-fix (only they can edit the journal directly) and finish your reply."
fi

block "$REASON"
