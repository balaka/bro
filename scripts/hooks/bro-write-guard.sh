#!/bin/bash
# bro v3 — PreToolUse hook on Write|Edit (the guard).
# Denies writes to LEGACY bro storage paths (bro/ folders inside repos) so a
# stale chat that remembers the v2 layout cannot clobber or resurrect old
# storages after migration. Writes inside the central store are always allowed.

set -uo pipefail

CONFIG="$HOME/.claude/bro-config.json"
ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
ROOT="${ROOT/#\~/$HOME}"

INPUT=$(cat)
FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FP" ] && exit 0

# central store → always fine
case "$FP" in "$ROOT"/*) exit 0 ;; esac

# storage-shaped paths inside a repo-level bro/ folder:
#   .../bro/_principles.md   .../bro/<tag>/_thread.md
#   .../bro/YYYY-MM-DD.md    .../bro/<tag>/YYYY-MM-DD.md   .../bro/_index.md
if echo "$FP" | grep -qE '(^|/)bro/(_principles\.md|_index\.md|[0-9]{4}-[0-9]{2}-[0-9]{2}\.md|[^/]+/(_thread\.md|[0-9]{4}-[0-9]{2}-[0-9]{2}\.md))$'; then
  jq -cn --arg fp "$FP" --arg root "$ROOT" \
    '("bro v3: " + $fp + " is a legacy bro storage path (v2 layout, archived). Write to the central store instead: " + $root + "/<workspace>/. If migration has not run yet, run /bro migrate first.") as $r
     | {decision:"block", reason:$r,
        hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

exit 0
