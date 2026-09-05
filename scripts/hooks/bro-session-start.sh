#!/bin/bash
# bro v3 — SessionStart hook (matchers: startup, resume, compact, clear).
# Injects the read-order for this workspace into every session, and flags a
# storage-version mismatch (→ /bro migrate). Silent when bro is not enabled
# for the current project.

set -uo pipefail

CONFIG="$HOME/.claude/bro-config.json"
ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
ROOT="${ROOT/#\~/$HOME}"

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)

# per-chat off switch: /bro off touches ~/.claude/bro/off/<session_id>
SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SID" ] && [ -f "$HOME/.claude/bro/off/$SID" ] && exit 0

# workspace resolution: explicit map in config, else lowercased basename of cwd
WS=$(jq -r --arg c "$CWD" '.workspaces[$c] // empty' "$CONFIG" 2>/dev/null)
if [ -z "$WS" ]; then
  WS=$(basename "$CWD" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-._')
fi
WS_DIR="$ROOT/$WS"

# not enabled for this project → stay silent
[ -d "$WS_DIR" ] || exit 0

# version check: skill VERSION vs store .version
SKILL_VERSION_FILE="$HOME/.claude/bro/VERSION"
SKILL_MAJOR=$(cut -d. -f1 "$SKILL_VERSION_FILE" 2>/dev/null || echo 3)
STORE_MAJOR=$(cat "$ROOT/.version" 2>/dev/null || echo 0)

CTX=""
if [ "$STORE_MAJOR" -lt "$SKILL_MAJOR" ] 2>/dev/null; then
  CTX="bro: STORAGE FORMAT OUTDATED (store v$STORE_MAJOR, skill v$SKILL_MAJOR). Tell the user and run /bro migrate before writing any bro entries."
else
  # harvest markers born since last session into the registers (idempotent, fast)
  [ -x "$HOME/.claude/bro/bin/bro-harvest.sh" ] && "$HOME/.claude/bro/bin/bro-harvest.sh" --root "$ROOT" --workspace "$WS" --quiet 2>/dev/null

  TODAY=$(date +%F)
  YESTERDAY=$(ls "$WS_DIR" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' | sort | grep -v "^$TODAY\.md$" | tail -1)
  CTX="bro v3 active for workspace '$WS'. Read now, in order: 1) $ROOT/_principles.md 2) $WS_DIR/_workspace.md 3) $WS_DIR/$TODAY.md (today's journal; create per bro skill format if missing)"
  [ -n "$YESTERDAY" ] && CTX="$CTX 4) $WS_DIR/$YESTERDAY (previous day)."
  CTX="$CTX Keep the journal current through the session — the stop hook enforces freshness (threshold in ~/.claude/bro-config.json)."
  NOPEN=$(grep -c '^- \[ \]' "$WS_DIR/open.md" 2>/dev/null || echo 0)
  [ "$NOPEN" -gt 0 ] 2>/dev/null && CTX="$CTX Open items: $NOPEN unchecked in $WS_DIR/open.md — review what today's work touches."
  NRULE=$(grep -c '^- \[ \]' "$ROOT/_rule-candidates.md" 2>/dev/null || echo 0)
  [ "$NRULE" -gt 0 ] 2>/dev/null && CTX="$CTX Rule candidates pending operator confirmation: $NRULE in $ROOT/_rule-candidates.md."
  NDUE=$(awk -v today="$(date +%F)" '/\*\*Пересмотр:\*\*/ { if ($NF <= today) n++ } END { print n+0 }' "$ROOT/_principles.md" 2>/dev/null)
  [ "$NDUE" -gt 0 ] 2>/dev/null && CTX="$CTX Principle reviews DUE: $NDUE (list in INDEX.md, section Reviews due) — walk the operator through them: alive → extend the date with a longer interval; stale → supersede."
  [ -f "$ROOT/CONFLICTS.md" ] && CTX="$CTX NOTE: $ROOT/CONFLICTS.md exists — unresolved principle-merge conflicts; surface to the user when relevant."
fi

jq -cn --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
exit 0
