#!/bin/bash
# bro v3.3 — Stop hook (the turnstile).
# Blocks the end of a turn when today's journal for this workspace is stale
# or missing, at most once per (session, prompt) — loop-proof by construction.
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
    || LINT="$LINT At least one '## HH:MM — <topic>' section is required."
fi

if [ "$fresh" = 1 ] && [ -z "$LINT" ]; then
  exit 0
fi

touch "$GUARD" 2>/dev/null

if [ ! -f "$TODAY_FILE" ]; then
  REASON="bro turnstile: no journal for today. Create $TODAY_FILE (format: '# bro — $(date +%F) / $WS' + '## HH:MM — <topic>' section; markers DECIDED:/RULE:/TAIL:/TERM:, RU aliases РЕШЕНИЕ:/ПРАВИЛО:/ХВОСТ:/ТЕРМИН:) and log this session's substance, then finish your reply."
elif [ "$fresh" = 0 ]; then
  REASON="bro turnstile: journal $TODAY_FILE is ${AGE_MIN}min stale (threshold ${STALE_MIN}min). Append a '## HH:MM — <topic>' section covering what happened since the last entry, then finish your reply.${LINT:+ Also fix:$LINT}"
else
  REASON="bro turnstile: journal format issues in $TODAY_FILE —$LINT Fix them, then finish your reply."
fi

if [ "$HAS_JQ" = 1 ]; then
  # both contract generations: top-level decision/reason (classic) + continueLoop (current)
  jq -cn --arg r "$REASON" '{decision:"block",reason:$r,hookSpecificOutput:{hookEventName:"Stop",continueLoop:true,additionalContext:$r}}'
  exit 0
else
  # no jq: exit 2 blocks the stop; stderr is fed back to the model
  echo "$REASON" >&2
  exit 2
fi
