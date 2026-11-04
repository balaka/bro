#!/bin/bash
# bro-install.sh — v5 installer: atomic script copies, config merge, hook registration. Idempotent.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd || true)"
if [ -z "$SRC" ] || [ ! -f "$SRC/VERSION" ]; then   # curl-pipe mode: no repo around -> clone to temp
  command -v git >/dev/null || { echo "bro-install: git is required" >&2; exit 1; }
  TMP=$(mktemp -d)
  git clone --depth 1 https://github.com/balaka/bro "$TMP/bro" 2>&1 | tail -2 || true
  [ -f "$TMP/bro/VERSION" ] || { echo "bro-install: git clone failed (network/proxy?)" >&2; exit 1; }
  SRC="$TMP/bro"
fi
command -v jq >/dev/null || { echo "bro-install: jq is required (brew install jq)"; exit 1; }
BIN="$HOME/.claude/bro/bin"; SKILL="$HOME/.claude/skills/bro"
SETTINGS="$HOME/.claude/settings.json"; CONFIG="$HOME/.claude/bro-config.json"
VER=$(cat "$SRC/VERSION")
echo "[bro-install] v$VER from $SRC"

atomic() { cp "$1" "$2/.$(basename "$3").new" && mv "$2/.$(basename "$3").new" "$2/$3"; }
mkdir -p "$BIN" "$SKILL" "$HOME/.claude"
for b in bro-lib bro-append bro-harvest bro-expire bro-context bro-stop bro-migrate bro-upgrade; do
  if [ -f "$SRC/scripts/$b.sh" ]; then atomic "$SRC/scripts/$b.sh" "$BIN" "$b.sh"; chmod +x "$BIN/$b.sh"
  else echo "[bro-install] warning: scripts/$b.sh missing — skipped"; fi
done
atomic "$SRC/VERSION" "$HOME/.claude/bro" VERSION
[ -f "$SRC/SKILL.md" ] && atomic "$SRC/SKILL.md" "$SKILL" SKILL.md

# config: create or merge (existing values win)
[ -f "$CONFIG" ] || echo '{}' > "$CONFIG"
jq --arg v "$VER" '.version = $v | .root = (.root // "~/bro") | .staleMinutes = (.staleMinutes // 30) | .staleDays = (.staleDays // 3)
  | .contextChars = (.contextChars // 10000) | .workspaces = (.workspaces // {}) | del(.autoCreateAfterAnswers)' \
  "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

ROOT=$(jq -r '.root' "$CONFIG"); ROOT="${ROOT/#\~/$HOME}"
mkdir -p "$ROOT"
[ -f "$ROOT/kinds.md" ] || cp "$SRC/scripts/kinds.md" "$ROOT/kinds.md"

# store upgrade v5.0 -> v5.1 (before hooks, so the principle hook is registered in this run)
if [ -f "$ROOT/.v5-migrated" ] && [ ! -f "$ROOT/.v5.1-upgraded" ] && [ -f "$BIN/bro-upgrade.sh" ]; then
  bash "$BIN/bro-upgrade.sh" || true
fi

# hooks: purge every bro entry (v4 included), then add v5
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-$(date +%F)"
KINDS=$(awk -F'|' '/^[ \t]*\|/ && NF>=8 {k=$2; gsub(/^[ \t]+|[ \t]+$/,"",k); if (k!="kind" && k!~/^:?-+:?$/ && k!="") print k}' "$ROOT/kinds.md" | jq -R . | jq -sc .)
jq --arg bin "$BIN" --argjson kinds "$KINDS" '
  def purge: (.hooks // {}) | to_entries | map(.value |= (map(.hooks = [(.hooks // [])[] | select((.command // "") | contains("/.claude/bro/bin/") | not)]) | map(select(.hooks | length > 0)))) | map(select(.value | length > 0)) | from_entries;
  def cmd($a): {type:"command", command:($bin+"/bro-context.sh "+$a), timeout:10};
  def start($m): {matcher:$m, hooks:([cmd("clock")] + [$kinds[] | cmd(.)])};
  .hooks = purge
  | .hooks.SessionStart = ((.hooks.SessionStart // []) + [start("startup"), start("resume"), start("compact"), start("clear"), start("fork")])
  | .hooks.Stop = ((.hooks.Stop // []) + [{hooks:[{type:"command", command:($bin+"/bro-stop.sh"), timeout:15, statusMessage:"bro: journal freshness"}]}])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "[bro-install] done: scripts -> $BIN, config -> $CONFIG, hooks -> $SETTINGS (backup .bak-$(date +%F))"
if [ ! -f "$ROOT/.v5-migrated" ] && ls "$ROOT"/*/open.md >/dev/null 2>&1; then
  echo "v4 store found — run ~/.claude/bro/bin/bro-migrate.sh"
fi
exit 0
