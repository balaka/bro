#!/bin/bash
# bro v3 — Stop hook (the turnstile).
# Blocks the end of a turn when today's journal for this workspace is stale
# (older than staleMinutes) or missing, and appends a light format lint.
# Blocks AT MOST ONCE per prompt (marker keyed by prompt_id) so it can never loop.
# Silent when bro is not enabled for the current project.

set -uo pipefail

CONFIG="$HOME/.claude/bro-config.json"
ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
ROOT="${ROOT/#\~/$HOME}"
STALE_MIN=$(jq -r '.staleMinutes // 30' "$CONFIG" 2>/dev/null || echo 30)

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
PROMPT_ID=$(echo "$INPUT" | jq -r '.prompt_id // "none"' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)

WS=$(jq -r --arg c "$CWD" '.workspaces[$c] // empty' "$CONFIG" 2>/dev/null)
[ -z "$WS" ] && WS=$(basename "$CWD" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-._')
WS_DIR="$ROOT/$WS"
[ -d "$WS_DIR" ] || exit 0

# store must be v3 — during migration limbo, do not block anything
[ "$(cat "$ROOT/.version" 2>/dev/null || echo 0)" -ge 3 ] 2>/dev/null || exit 0

TODAY_FILE="$WS_DIR/$(date +%F).md"

# one block per prompt, ever — loop-proof by construction
GUARD_DIR="${TMPDIR:-/tmp}/bro-turnstile"
mkdir -p "$GUARD_DIR" 2>/dev/null
GUARD="$GUARD_DIR/$PROMPT_ID"
[ -f "$GUARD" ] && exit 0

fresh=0
if [ -f "$TODAY_FILE" ]; then
  AGE_MIN=$(( ( $(date +%s) - $(stat -f %m "$TODAY_FILE" 2>/dev/null || stat -c %Y "$TODAY_FILE" 2>/dev/null || echo 0) ) / 60 ))
  [ "$AGE_MIN" -lt "$STALE_MIN" ] && fresh=1
fi

# light lint of today's file (only when it exists)
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
  REASON="bro turnstile: no journal for today. Create $TODAY_FILE (format: '# bro — $(date +%F) / $WS' + '## HH:MM — <topic>' section; markers DECIDED:/RULE:/TAIL:, RU aliases РЕШЕНИЕ:/ПРАВИЛО:/ХВОСТ:) and log this session's substance, then finish your reply."
elif [ "$fresh" = 0 ]; then
  REASON="bro turnstile: journal $TODAY_FILE is ${AGE_MIN}min stale (threshold ${STALE_MIN}min). Append a '## HH:MM — <topic>' section covering what happened since the last entry, then finish your reply.${LINT:+ Also fix:$LINT}"
else
  REASON="bro turnstile: journal format issues in $TODAY_FILE —$LINT Fix them, then finish your reply."
fi

# both contract generations: top-level decision/reason (classic) + continueLoop (current)
jq -cn --arg r "$REASON" '{decision:"block",reason:$r,hookSpecificOutput:{hookEventName:"Stop",continueLoop:true,additionalContext:$r}}'
exit 0
