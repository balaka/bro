#!/bin/bash
# bro v3 installer — deterministic, idempotent.
# Installs the skill, the hook scripts, default config, and registers the
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
  command -v git >/dev/null || { echo "bro-install: git is required" >&2; exit 1; }
  TMP=$(mktemp -d)
  if ! git clone --depth 1 "$REPO_URL" "$TMP/bro" 2>&1 | tail -2; then
    echo "bro-install: git clone of $REPO_URL failed (network/proxy?)" >&2; exit 1
  fi
  SRC_DIR="$TMP/bro"
fi

command -v jq >/dev/null || { echo "bro-install: jq is required (brew install jq)"; exit 1; }

BIN_DIR="$HOME/.claude/bro/bin"
SKILL_DIR="$HOME/.claude/skills/bro"
SETTINGS="$HOME/.claude/settings.json"
CONFIG="$HOME/.claude/bro-config.json"

echo "[bro-install] installing from $SRC_DIR (v$(cat "$SRC_DIR/VERSION"))"

# 1. scripts + version stamp — atomic per file (cp to tmp + mv), so hooks
# executing concurrently never read a half-written script
# bro-lib.sh first, and named explicitly (not just "whatever's in scripts/"):
# it's a sourced dependency of bro-harvest.sh (and, from here on, other
# scripts), not a standalone entry point — every consumer expects to find it
# next to itself in this same $BIN_DIR.
mkdir -p "$BIN_DIR"
for f in "$SRC_DIR/scripts/bro-lib.sh" "$SRC_DIR"/scripts/hooks/*.sh "$SRC_DIR/scripts/bro-migrate.sh" "$SRC_DIR/scripts/bro-harvest.sh" "$SRC_DIR/scripts/bro-append.sh"; do
  b=$(basename "$f")
  cp "$f" "$BIN_DIR/.$b.new" && chmod +x "$BIN_DIR/.$b.new" && mv "$BIN_DIR/.$b.new" "$BIN_DIR/$b"
done
# v3.9 (§4 of the v3.9 plan): the register-language converter,
# scripts/bro-translate-registers.sh — copied the same atomic way as every
# script above, but only IF this checkout actually has it. Guarded rather
# than listed unconditionally in the loop above: this installer runs under
# `set -euo pipefail`, so a `cp` of a file that doesn't exist would abort
# the WHOLE install (config, store, and every hook registration below,
# never reached) instead of just skipping one optional script. Guarding it
# means a checkout that predates the converter keeps installing everything
# else exactly as before, and the moment the converter lands in scripts/,
# this same run starts picking it up with no further change here.
if [ -f "$SRC_DIR/scripts/bro-translate-registers.sh" ]; then
  cp "$SRC_DIR/scripts/bro-translate-registers.sh" "$BIN_DIR/.bro-translate-registers.sh.new" \
    && chmod +x "$BIN_DIR/.bro-translate-registers.sh.new" \
    && mv "$BIN_DIR/.bro-translate-registers.sh.new" "$BIN_DIR/bro-translate-registers.sh"
fi
cp "$SRC_DIR/VERSION" "$HOME/.claude/bro/.VERSION.new" && mv "$HOME/.claude/bro/.VERSION.new" "$HOME/.claude/bro/VERSION"

# 2. skill (canonical location); retire the v2 command file if present
mkdir -p "$SKILL_DIR"
cp "$SRC_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
if [ -f "$HOME/.claude/commands/bro.md" ]; then
  mv "$HOME/.claude/commands/bro.md" "$HOME/.claude/commands/bro.md.v2-retired"
  echo "[bro-install] v2 command file retired → ~/.claude/commands/bro.md.v2-retired"
fi

# 3. config: create with defaults, or add missing keys without touching existing ones
# autoCreateAfterAnswers (v3.8, operator's own decision): a self-created
# workspace (bro-session-start.sh finds a git repo bro has never seen) is
# only actually mkdir'd once this many of the chat's own responses have
# gone by (bro-stop-turnstile.sh counts them) — real work starting, not
# just bro noticing a folder. Same merge shape as staleMinutes below.
if [ ! -f "$CONFIG" ]; then
  printf '{\n  "version": "%s",\n  "root": "~/bro",\n  "staleMinutes": 30,\n  "autoCreateAfterAnswers": 5,\n  "workspaces": {}\n}\n' "$(cat "$SRC_DIR/VERSION")" > "$CONFIG"
else
  jq --arg v "$(cat "$SRC_DIR/VERSION")" \
     '.version = $v
      | .root = (.root // "~/bro")
      | .staleMinutes = (.staleMinutes // 30)
      | .autoCreateAfterAnswers = (.autoCreateAfterAnswers // 5)
      | .workspaces = (.workspaces // {})' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
fi

# 3b. store: create root + version stamp for organic (never-migrated) installs,
# so session-start doesn't demand a migration that has nothing to migrate
STORE_ROOT=$(jq -r '.root // "~/bro"' "$CONFIG"); STORE_ROOT="${STORE_ROOT/#\~/$HOME}"
mkdir -p "$STORE_ROOT"
[ -f "$STORE_ROOT/.version" ] || cut -d. -f1 "$SRC_DIR/VERSION" > "$STORE_ROOT/.version"

# 4. hooks in settings.json — replace any previous bro entries, then add ours
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

jq --arg bin "$BIN_DIR" '
  # drop any hook group that references our bin dir (idempotent re-install)
  def scrub: if . == null then [] else
    map(.hooks = (.hooks // [] | map(select((.command // "") | contains($bin) | not))))
    | map(select(.hooks | length > 0)) end;

  # session start = two hooks per matcher: the context injector (fast, 10 s cap)
  # and the harvest, async — it may take long on a first pass and must never be
  # able to cancel the injector (pre-3.6 it ran inside it and did exactly that)
  def start($m): {matcher:$m, hooks:[
      {type:"command", command:($bin+"/bro-session-start.sh"), timeout:10},
      {type:"command", command:($bin+"/bro-harvest-hook.sh"), async:true}]};

  # Stop = turnstile (freshness/form gate, 15s cap) + async harvest — the
  # same async harvest hook already registered under SessionStart above,
  # now firing every turn too (v3.8 section 3) so registers stop lagging a
  # whole chat behind. Added inside the SAME group, in its hooks array,
  # same shape as start($m) above — not a second top-level Stop group.
  # (No apostrophes in this comment block on purpose: it lives inside the
  # single-quoted jq program below, where one would close the string early.)
  .hooks = (.hooks // {})
  | .hooks.SessionStart = ((.hooks.SessionStart | scrub) + [
      start("startup"), start("resume"), start("compact"), start("clear")
    ])
  | .hooks.Stop = ((.hooks.Stop | scrub) + [
      {hooks:[
        {type:"command", command:($bin+"/bro-stop-turnstile.sh"), timeout:15,
         statusMessage:"bro: checking journal freshness"},
        {type:"command", command:($bin+"/bro-harvest-hook.sh"), async:true}
      ]}
    ])
  | .hooks.PreToolUse = ((.hooks.PreToolUse | scrub) + [
      {matcher:"Write|Edit|Bash", hooks:[{type:"command", command:($bin+"/bro-write-guard.sh"), timeout:10}]}
    ])
  | .hooks.PreCompact = ((.hooks.PreCompact | scrub) + [
      {hooks:[{type:"command", command:($bin+"/bro-precompact.sh"), timeout:5}]}
    ])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "[bro-install] done:"
echo "  skill    → $SKILL_DIR/SKILL.md"
echo "  scripts  → $BIN_DIR/"
echo "  config   → $CONFIG"
echo "  hooks    → $SETTINGS (SessionStart ×4: context + async harvest, Stop: turnstile + async harvest, PreToolUse Write|Edit|Bash, PreCompact)"
echo ""
echo "Open a new session (hooks load on start). If you have v1/v2 bro folders,"
echo "the session-start hook will flag them — run /bro migrate when it does."
echo ""
echo "Upgrading from an older 3.x? Optional, ask the operator first (it adds to their registers):"
echo "  ~/.claude/bro/bin/bro-harvest.sh --all --full"
echo "re-reads old journals once and picks up markers older versions missed — Capitalized"
echo "Russian ones (Решение:, Правило:, Хвост:) and journals with a suffix in the name. ДЕЛО"
echo "(the open-item marker's Russian spelling) is ALL-CAPS only — there is no Capitalized"
echo "'Дело:' form, unlike the Russian aliases above."
echo "Only adds, never duplicates; 1–2 minutes on a busy store."
echo ""
echo "Translate this store's own service words to English (register headers, origin/closed"
echo "signatures, _state.md — never the operator's own entries)? Optional, with the store"
echo "owner's consent: run  ~/.claude/bro/bin/bro-translate-registers.sh --all --dry-run  first"
echo "to preview, then the same command without --dry-run once you're satisfied — it backs up"
echo "every file it touches before changing it. An untranslated store keeps working exactly"
echo "as before either way."
