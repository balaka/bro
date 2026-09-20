#!/bin/bash
# bro v3.6 — Stop hook (the turnstile).
# Blocks the end of a turn when today's journal for this workspace is stale
# or missing, at most once per (session, prompt) — loop-proof by construction.
# v3.6: also watches the session-start hook — a start that never finished is
# recovered here and reported, instead of leaving the chat blind in silence.
# Workspace resolution walks UP from cwd (config map, then dir slugs).
# Works without jq (sed fallback for parsing; exit-2 fallback for blocking).

set -uo pipefail

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
[ -n "$WS" ] || exit 0
WS_DIR="$ROOT/$WS"
[ -d "$WS_DIR" ] || exit 0

# store must be current major — during migration limbo, never block
[ "$(cat "$ROOT/.version" 2>/dev/null || echo 0)" -ge 3 ] 2>/dev/null || exit 0

TODAY_FILE="$WS_DIR/$(date +%F).md"

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

# v3.6 watchdog — the enforcer's enforcer. bro-session-start.sh leaves a mark per
# session: "pending" on entry, "ok" once its context is out; bro-precompact.sh
# sets it back to "pending" before every compaction. A mark still at "pending"
# means the start hook died on the way (timeout, crash) or never ran after a
# compaction, and this chat is working without principles and read-order.
# Recover here: hand the chat the same context, log it, and have the operator
# told — a dead start must never be silent, whatever else goes wrong below.
MARK="$HOME/.claude/bro/started/$SID"
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

LINT=""
if [ -f "$TODAY_FILE" ]; then
  head -1 "$TODAY_FILE" | grep -qE "^# bro — [0-9]{4}-[0-9]{2}-[0-9]{2}" \
    || LINT="$LINT Header must be '# bro — YYYY-MM-DD / <workspace>'."
  grep -qE "^## " "$TODAY_FILE" \
    || LINT="$LINT At least one '## HH:MM · <thread> — <topic>' section is required."
  # canonical section headers: '## HH:MM · <thread> — <topic>'
  BADHDR=$(grep -cE '^## ' "$TODAY_FILE" 2>/dev/null || true); GOODHDR=$(grep -cE '^## [0-9]{2}:[0-9]{2} · .+ — ' "$TODAY_FILE" 2>/dev/null || true)
  [ -n "$BADHDR" ] || BADHDR=0; [ -n "$GOODHDR" ] || GOODHDR=0
  [ "$BADHDR" -gt "$GOODHDR" ] 2>/dev/null \
    && LINT="$LINT $((BADHDR-GOODHDR)) section header(s) off-format — must be '## HH:MM · <thread> — <topic>'."
  # future-time headers: the time was invented, not taken from date
  FUT=$(grep -oE '^## [0-9]{2}:[0-9]{2}' "$TODAY_FILE" 2>/dev/null | awk -v nh="$(date +%H)" -v nm="$(date +%M)" '{hh=substr($0,4,2)+0; mm=substr($0,7,2)+0; if (hh*60+mm > nh*60+nm+3) {print substr($0,4); exit}}')
  [ -n "$FUT" ] && LINT="$LINT Section time $FUT is in the FUTURE (now $(date +%H:%M)) — take time from date, fix the header."
  # marker-like lines missing the colon are silently lost to harvest
  SUS=$(grep -cE '^[[:space:]]*(\*\*)?(DECIDED|RULE|TAIL|TERM|REJECTED|РЕШЕНИЕ|ПРАВИЛО|ХВОСТ|ТЕРМИН|ОТКАЗ)(\*\*)?[[:space:]][^:]*$' "$TODAY_FILE" 2>/dev/null || true)
  [ -n "$SUS" ] || SUS=0
  [ "$SUS" -gt 0 ] 2>/dev/null && LINT="$LINT $SUS marker-like line(s) without ':' — harvest will skip them; write 'KEYWORD: text' or reword."
fi

if [ "$fresh" = 1 ] && [ -z "$LINT" ]; then
  exit 0
fi

touch "$GUARD" 2>/dev/null

NOWSTAMP="$(date '+%F %H:%M (%A)')"
if [ ! -f "$TODAY_FILE" ]; then
  REASON="bro turnstile [NOW: $NOWSTAMP — sync your clock to this]: no journal for today. Create $TODAY_FILE (format: '# bro — $(date +%F) / $WS' + '## HH:MM · <thread> — <topic>' section; markers DECIDED:/REJECTED:/RULE:/TAIL:/TERM:, RU aliases РЕШЕНИЕ:/ОТКАЗ:/ПРАВИЛО:/ХВОСТ:/ТЕРМИН:) and log this session's substance, then finish your reply."
elif [ "$fresh" = 0 ]; then
  REASON="bro turnstile [NOW: $NOWSTAMP — sync your clock to this]: journal $TODAY_FILE is ${AGE_MIN}min stale (threshold ${STALE_MIN}min). Append a '## HH:MM · <thread> — <topic>' section covering what happened since the last entry, then finish your reply.${LINT:+ Also fix:$LINT}"
else
  REASON="bro turnstile [NOW: $NOWSTAMP — sync your clock to this]: journal format issues in $TODAY_FILE —$LINT Fix them, then finish your reply."
fi

block "$REASON"
