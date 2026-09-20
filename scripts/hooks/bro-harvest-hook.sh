#!/bin/bash
# bro v3.6 — SessionStart hook, registered with "async": true.
# Harvests the current workspace's markers into the registers in the background,
# so the session-start hook that injects context never waits for it (and can
# never be cancelled because of it). Emits nothing; harvest is incremental, so a
# normal run costs well under a second — only the first run after an upgrade, or
# a --full run, reads every journal.
# Workspace resolution is the same walk as in bro-session-start.sh.

set -uo pipefail

command -v jq >/dev/null 2>&1 && HAS_JQ=1 || HAS_JQ=0
CONFIG="$HOME/.claude/bro-config.json"

if [ "$HAS_JQ" = 1 ]; then
  ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
else
  ROOT="~/bro"
fi
ROOT="${ROOT/#\~/$HOME}"

INPUT=$(cat)
jget() { # $1 = key
  if [ "$HAS_JQ" = 1 ]; then
    echo "$INPUT" | jq -r ".$1 // empty" 2>/dev/null
  else
    printf '%s' "$INPUT" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}
CWD=$(jget cwd); [ -z "$CWD" ] && CWD=$(pwd)
SID=$(jget session_id)
case "$SID" in *[!A-Za-z0-9_-]*) SID="" ;; esac
[ -n "$SID" ] && [ -f "$HOME/.claude/bro/off/$SID" ] && exit 0

slug_of() { basename "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-._'; }

# resolution: config map (cwd, then ancestors) → dir-slug walk up to $HOME
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
[ -d "$ROOT/$WS" ] || exit 0

# an outdated store is migrated first, never harvested into
SKILL_MAJOR=$(cut -d. -f1 "$HOME/.claude/bro/VERSION" 2>/dev/null || echo 3)
STORE_MAJOR=$(cat "$ROOT/.version" 2>/dev/null || echo 0)
[ "$STORE_MAJOR" -lt "$SKILL_MAJOR" ] 2>/dev/null && exit 0

HARVEST="$(dirname "$0")/bro-harvest.sh"
[ -x "$HARVEST" ] || HARVEST="$HOME/.claude/bro/bin/bro-harvest.sh"
[ -x "$HARVEST" ] || exit 0
"$HARVEST" --root "$ROOT" --workspace "$WS" --quiet >/dev/null 2>&1
exit 0
