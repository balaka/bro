#!/bin/bash
# tests/parts/v5-c.sh — bro-context.sh, bro-stop.sh, bro-install.sh. Sourced (HOME temp) or standalone.
C_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../scripts" && pwd)"
C_FAIL=0
c_chk() { local d="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $d"; else echo "FAIL: $d"; C_FAIL=$((C_FAIL+1)); fi; }
c_ctx() { printf '{"cwd":"%s"}' "$HOME/proj" | bash "$C_DIR/bro-context.sh" "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
c_stop() { printf '{"cwd":"%s"%s}' "$HOME/proj" "$1" | bash "$C_DIR/bro-stop.sh"; }
v5c_run() {
  mkdir -p "$HOME/proj" "$HOME/bro/cw" "$HOME/.claude/bro"
  printf '{"root":"~/bro","staleMinutes":30,"contextChars":10000,"workspaces":{"%s":"cw"}}\n' "$HOME/proj" > "$HOME/.claude/bro-config.json"
  echo 5.0.0 > "$HOME/.claude/bro/VERSION"
  local L="$HOME/bro/cw/tasks.log" i
  c_chk "none when log missing" test "$(c_ctx task)" = "## bro · tasks (cw) — none"
  printf 't-aaaaaa | 2026-10-01 | 2026-10-05 | open | old one | cw/2026-10-01.md#10:00\nt-bbbbbb | 2026-10-02 | 2026-11-02 | open | fresh one\nt-cccccc | 2026-10-03 | 2026-10-20 | open | a | b pipe\n' > "$L"
  o=$(c_ctx task)
  c_chk "heading with count" bash -c "echo '$o' | head -1 | grep -qx '## bro · tasks (cw) — 3 live'"
  c_chk "newest touched first" test "$(echo "$o" | sed -n 2p | cut -c1-8)" = "t-bbbbbb"
  c_chk "oldest touched last" test "$(echo "$o" | sed -n 4p | cut -c1-8)" = "t-aaaaaa"
  c_chk "source field stripped" bash -c "! echo '$o' | grep -q '10:00'"
  c_chk "pipe in text kept" bash -c "echo '$o' | grep -q 'a | b pipe'"
  : > "$L"; for i in $(seq 1 300); do
    printf 't-%06x | 2026-10-01 | 2026-10-%02d | open | %s\n' "$i" $((i % 28 + 1)) "$(printf 'long text %.0s' $(seq 1 12)) $i" >> "$L"; done
  o=$(c_ctx task)
  c_chk "capped at contextChars" test "${#o}" -le 10000
  c_chk "ends with +N more" bash -c "echo '$o' | tail -1 | grep -Eq '^\(\+[0-9]+ more in .*tasks.log — grep them\)$'"
  c_chk "global heading" bash -c "printf '{\"cwd\":\"$HOME/proj\"}' | bash '$C_DIR/bro-context.sh' rule | grep -q 'rules (global) — none'"
  c_chk "no workspace -> silent exit 0" bash -c "mkdir -p '$HOME/nows' && [ -z \"\$(printf '{\"cwd\":\"$HOME/nows\"}' | bash '$C_DIR/bro-context.sh' task)\" ]"
  echo "2020-01-01 | x | y" > "$HOME/bro/cw/misses.log"
  o=$(c_ctx clock)
  export O="$o"
  c_chk "clock has version/ws/append cmd" bash -c 'printf "%s\n" "$O" | grep -q "bro v5.0.0 · workspace cw" && printf "%s\n" "$O" | grep -q "bro-append.sh --workspace cw"'
  c_chk "clock lists markers from kinds.md" bash -c 'printf "%s\n" "$O" | grep -q "  TASK: — a promise" && printf "%s\n" "$O" | grep -q "  INSIGHT: — "'
  c_chk "clock has DONE, stale and misses lines" bash -c 'printf "%s\n" "$O" | grep -q "DONE <id>" && printf "%s\n" "$O" | grep -q "older than 30 min" && printf "%s\n" "$O" | grep -q "^Misses: 1"'
  # stop
  local J="$HOME/bro/cw/$(date +%F).md"
  c_chk "stop blocks when journal missing" bash -c "echo '$(c_stop '')' | jq -e '.decision==\"block\"'"
  echo x > "$J"
  c_chk "stop allows fresh journal" test -z "$(c_stop '')"
  touch -t 202001010000 "$J"
  c_chk "stop blocks stale journal" bash -c "echo '$(c_stop '')' | jq -e '.reason|test(\"min old\")'"
  c_chk "stop allows when stop_hook_active" test -z "$(c_stop ',"stop_hook_active":true')"
  # install
  local S="$HOME/.claude/settings.json"
  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/.claude/bro/bin/bro-stop-turnstile.sh"},{"type":"command","command":"/other/hook.sh"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"/h/.claude/bro/bin/bro-write-guard.sh"}]}]}}' > "$S"
  bash "$C_DIR/bro-install.sh" >/dev/null 2>&1
  c_chk "install: 5 matchers x 7 commands" test "$(jq '[.hooks.SessionStart[]|select(.hooks|length==7)]|length' "$S")" = 5
  c_chk "install: 1 bro Stop + foreign kept" test "$(jq '[.hooks.Stop[].hooks[].command]|length' "$S")" = 2
  c_chk "install: v4 hooks purged" bash -c "! jq -e '.hooks.PreToolUse' '$S'"
  c_chk "install: bro-stop registered" bash -c "jq -e '[.hooks.Stop[].hooks[]|select(.command|endswith(\"bro-stop.sh\"))]|length==1' '$S'"
  c_chk "install: kinds.md and config" bash -c "test -f '$HOME/bro/kinds.md' && jq -e '.contextChars==10000 and (has(\"autoCreateAfterAnswers\")|not)' '$HOME/.claude/bro-config.json'"
  cp "$S" "$S.before"; bash "$C_DIR/bro-install.sh" >/dev/null 2>&1
  c_chk "install idempotent" cmp -s "$S" "$S.before"
  echo '| note | local | NOTE: | n | notes | forever | a side note |' >> "$HOME/bro/kinds.md"
  bash "$C_DIR/bro-install.sh" >/dev/null 2>&1
  c_chk "install: user-added kind gets a hook (8 per matcher)" test "$(jq '[.hooks.SessionStart[]|select(.hooks|length==8)]|length' "$S")" = 5
  [ "$C_FAIL" = 0 ]
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  HOME=$(mktemp -d); export HOME
  trap 'rm -rf "$HOME"' EXIT
  v5c_run; exit $?
fi
