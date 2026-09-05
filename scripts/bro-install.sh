#!/bin/bash
# bro v3 installer — deterministic, idempotent.
# Installs the skill, the hook scripts, default config, and registers the four
# hooks in ~/.claude/settings.json. Safe to re-run (it replaces its own entries).
#
# Usage:  scripts/bro-install.sh          (from a cloned repo)
#         curl -fsSL https://raw.githubusercontent.com/balaka/bro/main/scripts/bro-install.sh | bash
#         (curl mode clones the repo to a temp dir first)

set -euo pipefail

REPO_URL="https://github.com/balaka/bro"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd || true)"

# curl-pipe mode: no repo around this script → clone to temp
if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/VERSION" ]; then
  TMP=$(mktemp -d)
  git clone --depth 1 "$REPO_URL" "$TMP/bro" >/dev/null 2>&1
  SRC_DIR="$TMP/bro"
fi

command -v jq >/dev/null || { echo "bro-install: jq is required (brew install jq)"; exit 1; }

BIN_DIR="$HOME/.claude/bro/bin"
SKILL_DIR="$HOME/.claude/skills/bro"
SETTINGS="$HOME/.claude/settings.json"
CONFIG="$HOME/.claude/bro-config.json"

echo "[bro-install] installing from $SRC_DIR (v$(cat "$SRC_DIR/VERSION"))"

# 1. scripts + version stamp
mkdir -p "$BIN_DIR"
cp "$SRC_DIR"/scripts/hooks/*.sh "$BIN_DIR/"
cp "$SRC_DIR/scripts/bro-migrate.sh" "$BIN_DIR/"
cp "$SRC_DIR/VERSION" "$HOME/.claude/bro/VERSION"
chmod +x "$BIN_DIR"/*.sh

# 2. skill (canonical location); retire the v2 command file if present
mkdir -p "$SKILL_DIR"
cp "$SRC_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
if [ -f "$HOME/.claude/commands/bro.md" ]; then
  mv "$HOME/.claude/commands/bro.md" "$HOME/.claude/commands/bro.md.v2-retired"
  echo "[bro-install] v2 command file retired → ~/.claude/commands/bro.md.v2-retired"
fi

# 3. config: create with defaults, or add missing keys without touching existing ones
if [ ! -f "$CONFIG" ]; then
  printf '{\n  "version": "%s",\n  "root": "~/bro",\n  "staleMinutes": 30,\n  "workspaces": {}\n}\n' "$(cat "$SRC_DIR/VERSION")" > "$CONFIG"
else
  jq --arg v "$(cat "$SRC_DIR/VERSION")" \
     '.version = $v
      | .root = (.root // "~/bro")
      | .staleMinutes = (.staleMinutes // 30)
      | .workspaces = (.workspaces // {})' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
fi

# 4. hooks in settings.json — replace any previous bro entries, then add ours
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

jq --arg bin "$BIN_DIR" '
  # drop any hook group that references our bin dir (idempotent re-install)
  def scrub: if . == null then [] else
    map(.hooks = (.hooks // [] | map(select((.command // "") | contains($bin) | not))))
    | map(select(.hooks | length > 0)) end;

  .hooks = (.hooks // {})
  | .hooks.SessionStart = ((.hooks.SessionStart | scrub) + [
      {matcher:"startup", hooks:[{type:"command", command:($bin+"/bro-session-start.sh"), timeout:10}]},
      {matcher:"resume",  hooks:[{type:"command", command:($bin+"/bro-session-start.sh"), timeout:10}]},
      {matcher:"compact", hooks:[{type:"command", command:($bin+"/bro-session-start.sh"), timeout:10}]},
      {matcher:"clear",   hooks:[{type:"command", command:($bin+"/bro-session-start.sh"), timeout:10}]}
    ])
  | .hooks.Stop = ((.hooks.Stop | scrub) + [
      {hooks:[{type:"command", command:($bin+"/bro-stop-turnstile.sh"), timeout:15,
               statusMessage:"bro: checking journal freshness"}]}
    ])
  | .hooks.PreToolUse = ((.hooks.PreToolUse | scrub) + [
      {matcher:"Write|Edit", hooks:[{type:"command", command:($bin+"/bro-write-guard.sh"), timeout:10}]}
    ])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "[bro-install] done:"
echo "  skill    → $SKILL_DIR/SKILL.md"
echo "  scripts  → $BIN_DIR/"
echo "  config   → $CONFIG"
echo "  hooks    → $SETTINGS (SessionStart ×4, Stop, PreToolUse Write|Edit)"
echo ""
echo "Open a new session (hooks load on start). If you have v1/v2 bro folders,"
echo "the session-start hook will flag them — run /bro migrate when it does."
