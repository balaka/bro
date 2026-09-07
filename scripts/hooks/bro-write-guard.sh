#!/bin/bash
# bro v3.3 — PreToolUse hook on Write|Edit (the guard).
# Denies writes to (a) legacy v2 storage paths (bro/ inside repos) and
# (b) generated read-mirrors (bro-view/ — rsync --delete erases local edits).
# Works without jq (sed fallback), so a degraded PATH cannot silently disarm it.

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
if [ "$HAS_JQ" = 1 ]; then
  FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
  FP=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
[ -z "$FP" ] && exit 0

# central store → always fine
case "$FP" in "$ROOT"/*) exit 0 ;; esac

deny() { # $1 = reason
  if [ "$HAS_JQ" = 1 ]; then
    jq -cn --arg r "$1" '{decision:"block", reason:$r,
      hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  else
    echo "$1" >&2
    exit 2
  fi
}

# generated read-mirror: local edits get erased by the next rsync --delete
if echo "$FP" | grep -qE '(^|/)bro-view/'; then
  deny "bro v3: $FP is inside a generated read-mirror (bro-view/) — local edits are erased on the next refresh. Write to the central store instead: $ROOT/<workspace>/."
fi

# legacy v2 storage-shaped paths inside a repo-level bro/ folder
if echo "$FP" | grep -qE '(^|/)bro/(_principles\.md|_index\.md|[0-9]{4}-[0-9]{2}-[0-9]{2}\.md|[^/]+/(_thread\.md|[0-9]{4}-[0-9]{2}-[0-9]{2}\.md))$'; then
  deny "bro v3: $FP is a legacy bro storage path (v2 layout, archived). Write to the central store instead: $ROOT/<workspace>/. If migration has not run yet, run /bro migrate first."
fi

exit 0
