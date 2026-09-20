#!/bin/bash
# bro v3.6 — PreCompact hook (manual and auto compaction).
# Compaction wipes the chat's context; right after it the session-start hook must
# inject the read-order again. This hook sets the session's start mark back to
# "pending", so that promise is checked: if the start hook then finishes, the mark
# is "ok" again; if it dies or never runs, the stop hook sees "pending" at the end
# of the first turn, recovers the context and has the operator told.
# Touches nothing unless bro already left a mark for this session.

set -uo pipefail

INPUT=$(cat)
if command -v jq >/dev/null 2>&1; then
  SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
else
  SID=$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
case "$SID" in *[!A-Za-z0-9_-]*) SID="" ;; esac
[ -n "$SID" ] || exit 0
[ -f "$HOME/.claude/bro/off/$SID" ] && exit 0

MARK="$HOME/.claude/bro/started/$SID"
[ -f "$MARK" ] && echo pending > "$MARK" 2>/dev/null
exit 0
