#!/bin/bash
# bro v3.7 — bro-append.sh: the SOLE way to add a section to a shared daily
# journal (§5 of the v3.7 plan). Before this, every chat Wrote/Edited
# <ws>/YYYY-MM-DD.md directly — one chat's malformed header or invented
# (non-clock) section time blocked every OTHER chat's Stop until fixed by
# hand (measured in cowork: 132 blocks over two weeks, 46 of them a
# future-timestamped header). This script closes that at the write path:
#
#   - time/date are read from the clock HERE, not passed in — there is no
#     time/date argument, so an invented time is architecturally impossible;
#   - the body is validated BEFORE anything is written — a fake '## ' line
#     or a marker keyword missing its colon rejects the whole call, zero
#     bytes touched, with a precise error naming the offending line;
#   - a marker line's own trailing blank line (the boundary harvest's parser
#     uses to stop a record's body) is inserted automatically if the caller
#     forgot it — the "glue" bug (v3.7 §6a) can no longer happen through
#     this path;
#   - the write is atomic under bro-lib.sh's lock() — parallel chats queue,
#     never interleave or clobber each other's section;
#   - the appended range + a sha256 of it are logged to <ws>/.append-log,
#     which the stop hook's hash-gated lint (bro-stop-turnstile.sh) reads to
#     skip re-scrutinizing content this script already validated.
#
# Usage:
#   echo 'DECIDED: chose X | over: Y | because: Z' | bro-append.sh \
#     --workspace cowork --thread 'bro' --topic 'v3.7 rollout'
#   (or --root <dir> to point at a non-default store; --workspace omitted
#   resolves from cwd the same way the hooks do — config map, then dir slug)
#
# Prints exactly one confirmation line on success; prints a precise error to
# stderr and writes nothing on any validation failure (exit 1).

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -z "$LIB_DIR" ] || [ ! -f "$LIB_DIR/bro-lib.sh" ]; then
  echo "[bro-append] bro-lib.sh not found next to $0 — reinstall (bro-install.sh) or check the repo layout" >&2
  exit 1
fi
. "$LIB_DIR/bro-lib.sh"

err() { echo "[bro-append] $*" >&2; exit 1; }

CONFIG="$HOME/.claude/bro-config.json"
command -v jq >/dev/null 2>&1 && HAS_JQ=1 || HAS_JQ=0
if [ "$HAS_JQ" = 1 ]; then
  ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
else
  ROOT="~/bro"
fi
ROOT="${ROOT/#\~/$HOME}"

WORKSPACE=""; THREAD=""; TOPIC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root|--workspace|--thread|--topic)
      # under `set -u`, "$2" on a flag given with no value is an unbound-variable
      # crash, not a clean error — guard it so a malformed call still gets the
      # precise err() message this script promises, never a raw bash traceback
      [ $# -ge 2 ] || err "'$1' needs a value. Usage: bro-append.sh [--root <dir>] [--workspace <name>] --thread '<work thread>' --topic '<topic>' < body"
      ;;
  esac
  case "$1" in
    --root) ROOT="$2"; ROOT="${ROOT/#\~/$HOME}"; shift ;;
    --workspace) WORKSPACE="$2"; shift ;;
    --thread) THREAD="$2"; shift ;;
    --topic) TOPIC="$2"; shift ;;
    *) err "unknown argument '$1'. Usage: bro-append.sh [--root <dir>] [--workspace <name>] --thread '<work thread>' --topic '<topic>' < body" ;;
  esac
  shift
done

[ -d "$ROOT" ] || err "store root '$ROOT' does not exist — run /bro setup first"

# ---- resolve workspace: same walk bro-session-start.sh/bro-stop-turnstile.sh
# use (config map at cwd/ancestors, then dir-slug match up to $HOME) — this
# script is invoked directly, not through a hook, so there is no cwd field
# to read from JSON; $(pwd) IS the caller's cwd.
if [ -z "$WORKSPACE" ]; then
  slug_of() { basename "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-._'; }
  D="$(pwd)"
  while :; do
    if [ "$HAS_JQ" = 1 ]; then
      M=$(jq -r --arg c "$D" '.workspaces[$c] // empty' "$CONFIG" 2>/dev/null)
      [ -n "$M" ] && { WORKSPACE="$M"; break; }
    fi
    [ "$D" = "$HOME" ] || [ "$D" = "/" ] && break
    D=$(dirname "$D")
  done
  if [ -z "$WORKSPACE" ]; then
    D="$(pwd)"
    while [ "$D" != "$HOME" ] && [ "$D" != "/" ]; do
      S=$(slug_of "$D")
      if [ -n "$S" ] && [ -d "$ROOT/$S" ]; then WORKSPACE="$S"; break; fi
      D=$(dirname "$D")
    done
  fi
  [ -n "$WORKSPACE" ] || err "could not resolve a workspace from $(pwd) — pass --workspace <name> explicitly"
fi
WS_DIR="$ROOT/$WORKSPACE"
[ -d "$WS_DIR" ] || err "workspace '$WORKSPACE' does not exist under $ROOT — run /bro setup first"

[ -n "$THREAD" ] || err "--thread is required (the work thread this section belongs to)"
[ -n "$TOPIC" ] || err "--topic is required (a topic with a distinguishing detail)"
case "$THREAD" in *$'\n'*) err "--thread must not contain a newline" ;; esac
case "$TOPIC" in *$'\n'*) err "--topic must not contain a newline" ;; esac

# ---- read the body (stdin) into a temp file — preserves exact bytes, and
# lets every validation below re-scan it as many times as needed
BODY_RAW=$(mktemp "${TMPDIR:-/tmp}/bro-append-body.XXXXXX" 2>/dev/null) || err "could not create a scratch file"
trap 'rm -f "$BODY_RAW" "${XFORM:-}" 2>/dev/null' EXIT
cat > "$BODY_RAW"
[ -s "$BODY_RAW" ] || err "body (stdin) is empty — nothing to append"

# ---- validate BEFORE writing a byte ----
# (a) a body line starting '## ' would be read as a NEW section header by
# harvest's parser (and by the stop hook's lint) — the caller wants a
# section header, that's what --thread/--topic already build.
BADLN=$(grep -nE '^## ' "$BODY_RAW" 2>/dev/null | head -1)
if [ -n "$BADLN" ]; then
  err "body line ${BADLN%%:*} looks like its own '## ' section header — pass --thread/--topic instead, bro-append.sh builds the header: ${BADLN#*:}"
fi
# (b) a marker keyword with no colon is invisible to harvest (MRE requires
# the colon to recognize a marker at all) — reject instead of silently
# losing it. MRE_NOCOLON comes from bro-lib.sh, same regex the stop hook's
# lint uses post-hoc.
BADLN=$(grep -nE "$MRE_NOCOLON" "$BODY_RAW" 2>/dev/null | head -1)
if [ -n "$BADLN" ]; then
  err "body line ${BADLN%%:*} looks like a marker missing its ':' — harvest would silently skip it. Write 'KEYWORD: text' or reword: ${BADLN#*:}"
fi
# (c) v3.8 (§7): a TAIL/ХВОСТ/Хвост line is ONE open item, not a notebook
# entry for several ("- one record carries 4-6 items through '; ', the
# same list re-recorded four times with drifting wording — this is
# open.md's main weight" per the plan). Reject before a byte is written if
# the line has 2+ TOP-LEVEL "; " separators, 2+ real numbered-list items
# ("(1)"+"(2)" or "1)"+"2)"), or is over length. Uses marker_type()
# (bro-lib.sh) to find the CANONICAL type, not a re-spelled keyword list —
# same discipline as checks (a)/(b) above and harvest.sh's own dispatch:
# any of the three accepted spellings (TAIL, ХВОСТ, Хвост) is caught
# identically, and every OTHER marker type is untouched by this rule
# (plan: "Остальные метки не проверяются этим правилом").
#
# v3.8 review fixes (проверяющий №2, run against all 613 real ХВОСТ lines
# in the chronicles) — the first cut of all three checks below was too
# loose or too strict:
#  - "; " used to count EVERY occurrence anywhere on the line, so a single
#    aside like "(утверждено 01.09; не редактировать; больше ничего)"
#    tripped the 2+ threshold even though both semicolons sit inside one
#    parenthetical, not between separate open items. Now only TOP-LEVEL
#    "; " counts — occurrences inside (...), «...» or "..." are blanked
#    out first (see TL_TOPLEVEL);
#  - the numbered-list check used to fire on ANY "digit+)" pair on the
#    line, catching a date ("03.09)"), a field reference ("(20) … (15)"),
#    or a code ("(58Q7G810295)") that only coincidentally contains one.
#    Now it requires an actual enumeration: literally BOTH "(1)" and "(2)"
#    present, or BOTH "1)" and "2)" present (real lists start counting at
#    1), each anchored at the start of the line or right after a space so
#    a mid-token digit-paren never counts;
#  - the character-vs-byte probe used to read whatever locale the calling
#    process happened to already have — and a chat/hook environment
#    commonly has none set at all, silently taking the 750-byte fallback
#    on every call instead of the intended 400-character limit. The probe
#    (and the real measurement) now explicitly force LC_ALL=en_US.UTF-8,
#    so character-counting is what actually runs whenever a UTF-8 locale
#    is installed at all (true on every system this project targets); the
#    750-byte path is now a genuine last resort, only reached when even a
#    forced UTF-8 locale still can't count characters (verified by the
#    same 'ё' probe, not assumed).
TL_CHARS_OK=""
TL_LNNO=0
while IFS= read -r TL_RAWLN || [ -n "$TL_RAWLN" ]; do
  TL_LNNO=$((TL_LNNO+1))
  printf '%s\n' "$TL_RAWLN" | grep -qE "$MRE" || continue
  # same normalize-then-split as bro-harvest.sh's own KW extraction
  # (strip indent/bullet/bold, keyword = first word before ':', before ' ')
  TL_CLEAN=$(printf '%s' "$TL_RAWLN" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?//; s/\*\*//g')
  TL_HEAD="${TL_CLEAN%%:*}"
  TL_BODY="${TL_CLEAN#*:}"; TL_BODY="${TL_BODY# }"
  TL_KW="${TL_HEAD%% *}"
  TL_KW="${TL_KW%%-*}"; TL_KW="${TL_KW%%–*}"; TL_KW="${TL_KW%%—*}"
  TL_KC=$(marker_type "$TL_KW") || continue
  [ "$TL_KC" = "TAIL" ] || continue

  # top-level only: blank out (...) / «...» / "..." spans before counting,
  # so an aside's own internal "; " never counts as a second/third item
  TL_TOPLEVEL=$(printf '%s' "$TL_BODY" | sed -E 's/\([^)]*\)//g; s/«[^»]*»//g; s/"[^"]*"//g')
  TL_SEMIN=$(printf '%s' "$TL_TOPLEVEL" | grep -o '; ' | wc -l | tr -d ' ')
  [ -n "$TL_SEMIN" ] || TL_SEMIN=0
  if [ "$TL_SEMIN" -ge 2 ]; then
    err "line $TL_LNNO: a TAIL/ХВОСТ/Хвост line carries $TL_SEMIN top-level '; '-separated items — one open item per TAIL: line, split the rest into their own TAIL: lines: $(printf '%s' "$TL_BODY" | cut -c1-80)"
  fi

  # real numbered list only: both "(1)" and "(2)", or both "1)" and "2)" —
  # not just any two "digit)" substrings (dates, field refs, codes)
  TL_HASP1=0; printf '%s' "$TL_BODY" | grep -qE '(^|[[:space:]])\(1\)' && TL_HASP1=1
  TL_HASP2=0; printf '%s' "$TL_BODY" | grep -qE '(^|[[:space:]])\(2\)' && TL_HASP2=1
  TL_HASB1=0; printf '%s' "$TL_BODY" | grep -qE '(^|[[:space:]])1\)' && TL_HASB1=1
  TL_HASB2=0; printf '%s' "$TL_BODY" | grep -qE '(^|[[:space:]])2\)' && TL_HASB2=1
  if { [ "$TL_HASP1" = 1 ] && [ "$TL_HASP2" = 1 ]; } || { [ "$TL_HASB1" = 1 ] && [ "$TL_HASB2" = 1 ]; }; then
    err "line $TL_LNNO: a TAIL/ХВОСТ/Хвост line looks like a numbered list (both item 1 and item 2 present) — one open item per TAIL: line, split the rest into their own TAIL: lines: $(printf '%s' "$TL_BODY" | cut -c1-80)"
  fi

  # length: characters, not bytes -- probed once, lazily, against an
  # EXPLICITLY forced UTF-8 locale (LC_ALL=en_US.UTF-8) rather than
  # whatever locale this process happened to inherit (a chat/hook
  # environment commonly has none set at all, which would otherwise always
  # take the byte fallback below). The probe still verifies the forced
  # locale actually behaves as UTF-8-aware (a known 2-byte, 1-character
  # probe answers "1" from wc -m only when it truly is) rather than assume
  # LC_ALL=en_US.UTF-8 silently worked — falls back to the plan's own
  # 750-byte threshold only when it genuinely didn't.
  if [ -z "$TL_CHARS_OK" ]; then
    TL_PC=$(printf 'ё' | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
    TL_PB=$(printf 'ё' | wc -c | tr -d ' ')
    if [ "$TL_PC" = "1" ] && [ "$TL_PB" != "1" ]; then TL_CHARS_OK=1; else TL_CHARS_OK=0; fi
  fi
  if [ "$TL_CHARS_OK" = 1 ]; then
    TL_LEN=$(printf '%s' "$TL_BODY" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' '); TL_LIMIT=400; TL_UNIT="characters"
  else
    TL_LEN=$(printf '%s' "$TL_BODY" | wc -c | tr -d ' '); TL_LIMIT=750; TL_UNIT="bytes"
  fi
  if [ "$TL_LEN" -gt "$TL_LIMIT" ]; then
    err "line $TL_LNNO: a TAIL/ХВОСТ/Хвост line is $TL_LEN $TL_UNIT (over the $TL_LIMIT-$TL_UNIT limit) — one open item per TAIL: line; trim it or split the rest into their own TAIL: lines"
  fi
done < "$BODY_RAW"

# ---- auto-repair: guarantee a blank line right after every marker line,
# so a body that stacks a marker and a following paragraph with no blank
# line between them can never glue (v3.7 §6a's fix works on this boundary
# too, but bro-append.sh's job is to never produce the glued shape in the
# first place). Only inserts where one isn't already there — never doubles
# an existing blank line.
XFORM=$(mktemp "${TMPDIR:-/tmp}/bro-append-xform.XXXXXX" 2>/dev/null) || err "could not create a scratch file"
awk -v mre="$MRE" '
  { lines[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      print lines[i]
      if (lines[i] ~ mre) {
        nxt = (i < NR) ? lines[i+1] : ""
        if (i == NR || nxt !~ /^[[:space:]]*$/) print ""
      }
    }
  }
' "$BODY_RAW" > "$XFORM"

TODAY=$(date +%F)
NOW=$(date +%H:%M)
TODAY_FILE="$WS_DIR/$TODAY.md"
SECTION_HEADER="## $NOW · $THREAD — $TOPIC"

lock "$TODAY_FILE" || err "could not get the lock on $TODAY_FILE (busy too long) — try again"
trap 'unlock "$TODAY_FILE"; rm -f "$BODY_RAW" "${XFORM:-}" 2>/dev/null' EXIT

# ---- repair a dangling last line (no trailing newline), BEFORE measuring
# PRE, as its own separate step. wc -l counts newlines, not lines — if the
# file's existing content was last touched by something other than
# bro-append.sh (any pre-3.7 Write/Edit content, which is exactly what
# every real journal's most-recent content will be on the day this
# ships) and doesn't end in '\n', wc -l undercounts by one. That single
# missing newline used to get reused below to BOTH terminate the dangling
# line AND serve as NEED_SEP's blank separator — one byte doing two jobs —
# which glued the new section header directly onto the old line with no
# blank line between them, and made FROM start one line too early, so
# .append-log's hashed/"trusted" range covered that pre-existing,
# never-validated line too. Repairing this first, unconditionally, means
# PRE and NEED_SEP below both see the file exactly as bro-append.sh has
# always assumed a journal looks: every existing line properly terminated.
if [ -f "$TODAY_FILE" ] && [ -s "$TODAY_FILE" ] && [ -n "$(tail -c1 "$TODAY_FILE" 2>/dev/null)" ]; then
  printf '\n' >> "$TODAY_FILE"
fi

PRE=0
[ -f "$TODAY_FILE" ] && PRE=$(wc -l < "$TODAY_FILE" 2>/dev/null | tr -d ' ')
[ -n "$PRE" ] || PRE=0

NEED_HEADER=0
[ -f "$TODAY_FILE" ] || NEED_HEADER=1

NEED_SEP=0
if [ "$PRE" -gt 0 ]; then
  LASTLINE=$(sed -n '$p' "$TODAY_FILE" 2>/dev/null)
  [ -n "$LASTLINE" ] && NEED_SEP=1
fi

{
  [ "$NEED_HEADER" = 1 ] && printf '# bro — %s / %s\n\n' "$TODAY" "$WORKSPACE"
  [ "$NEED_SEP" = 1 ] && printf '\n'
  printf '%s\n' "$SECTION_HEADER"
  cat "$XFORM"
} >> "$TODAY_FILE" || err "write to $TODAY_FILE failed"

POST=$(wc -l < "$TODAY_FILE" 2>/dev/null | tr -d ' ')
[ -n "$POST" ] || POST=$PRE
FROM=$((PRE+1)); TO=$POST
HASH=$(hash_range "$TODAY_FILE" "$FROM" "$TO")

# ---- .append-log: date/time \t session \t journal-basename \t from-to \t sha256
# Under its own lock — a different day's journal in the SAME workspace can
# be appended concurrently (each under its own $TODAY_FILE lock), and both
# would race on this one shared log file without it.
# NB: never log a genuinely empty field here. bro-stop-turnstile.sh parses
# this file with `read -r ... < file` under `IFS=$'\t'`, and bash's `read`
# treats tab as IFS *whitespace* — it collapses a run of them instead of
# emitting an empty field the way a non-whitespace delimiter would. An
# empty session id would print two consecutive tabs, shifting every field
# after it left by one (the journal basename lands in the session slot,
# the range in the basename slot, ...) and silently dropping that whole
# entry out of TRUSTED_LINES. "none" is not a real session id, so it can
# never collide with one.
APPEND_LOG="$WS_DIR/.append-log"
if lock "$APPEND_LOG"; then
  printf '%s\t%s\t%s\t%s-%s\t%s\n' "$(date '+%F %H:%M:%S')" "${CLAUDE_SESSION_ID:-none}" "$(basename "$TODAY_FILE")" "$FROM" "$TO" "$HASH" >> "$APPEND_LOG"
  if [ "$(wc -l < "$APPEND_LOG" 2>/dev/null | tr -d ' ')" -gt 500 ] 2>/dev/null; then
    tail -n 300 "$APPEND_LOG" > "$APPEND_LOG.tmp" 2>/dev/null && mv "$APPEND_LOG.tmp" "$APPEND_LOG"
  fi
  unlock "$APPEND_LOG"
else
  echo "[bro-append] WARNING: wrote $TODAY_FILE lines $FROM-$TO but could not lock $APPEND_LOG to record it — the stop hook's lint will scrutinize this range normally (harmless, just not exempted)" >&2
fi

echo "[bro-append] wrote $WORKSPACE/$(basename "$TODAY_FILE") lines $FROM-$TO — '$NOW · $THREAD — $TOPIC' (sha256 ${HASH:0:12}…)"
exit 0
