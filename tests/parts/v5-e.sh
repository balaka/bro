#!/bin/bash
# tests/parts/v5-e.sh — bro-upgrade.sh (v5.0 -> v5.1 store) and its run from bro-install.sh. Standalone (temp HOME).
E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../scripts" && pwd)"
E_FAIL=0
e_chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS: $d"; else echo "FAIL: $d"; E_FAIL=$((E_FAIL+1)); fi; }
e_store() { # a v5.0 store: old kinds.md (rule global, no principle) + mixed rules.log
  local R="$HOME/bro"
  rm -rf "$R"; mkdir -p "$R/taro" "$HOME/.claude"
  printf '{"root":"~/bro","workspaces":{}}\n' > "$HOME/.claude/bro-config.json"
  sed '/| principle |/d; s/| rule | local |/| rule | global |/' "$E_DIR/kinds.md" > "$R/kinds.md"
  printf 'r-aaaa01 | 2026-11-03 | 2026-11-03 | open | be brief |\nr-aaaa02 | 2026-11-03 | 2026-11-03 | open | answer in English |\n' > "$R/rules.log"
  printf 'r-bbbb01 | 2026-11-04 | 2026-11-04 | open | taro rule one | taro/2026-11-04.md#10:00\nr-bbbb02 | 2026-11-04 | 2026-11-04 | open | taro rule two | taro/2026-11-04.md#10:00\n' >> "$R/rules.log"
  printf 'r-cccc01 | 2026-11-03 | 2026-11-03 | done:2026-11-03 | old gone |\n' > "$R/rules.archive"
  touch "$R/.v5-migrated"
}
v5e_run() {
  e_store
  local R="$HOME/bro"
  e_chk "upgrade exits 0" bash "$E_DIR/bro-upgrade.sh"
  e_chk "principles.log has 2 p- ids" bash -c "[ \$(grep -c '^p-aaaa0[12] ' '$R/principles.log') = 2 ] && [ \$(wc -l < '$R/principles.log' | tr -d ' ') = 2 ]"
  e_chk "taro/rules.log has 2 (ids kept)" bash -c "[ \$(grep -c '^r-bbbb0[12] ' '$R/taro/rules.log') = 2 ] && [ \$(wc -l < '$R/taro/rules.log' | tr -d ' ') = 2 ]"
  e_chk "rules.log gone" test ! -e "$R/rules.log"
  e_chk "rules.archive split too" bash -c "grep -q '^p-cccc01 ' '$R/principles.archive' && test ! -e '$R/rules.archive'"
  e_chk "kinds.md has principle row, global" grep -Eq '^\| principle \| global \| PRINCIPLE: \| p \|' "$R/kinds.md"
  e_chk "kinds.md rule is local" grep -Eq '^\| rule +\| +local +\| RULE: ' "$R/kinds.md"
  e_chk "stamp written" test -f "$R/.v5.1-upgraded"
  e_chk "second run refuses" bash -c "! bash '$E_DIR/bro-upgrade.sh'"
  e_chk "second run changes nothing" bash -c "[ \$(wc -l < '$R/principles.log' | tr -d ' ') = 2 ]"
  # install runs the upgrade before registering hooks
  e_store
  bash "$E_DIR/bro-install.sh" >/dev/null 2>&1
  local S="$HOME/.claude/settings.json"
  e_chk "install ran the upgrade" bash -c "test -f '$R/.v5.1-upgraded' && test -f '$R/principles.log' && test ! -e '$R/rules.log'"
  e_chk "install: 8 commands per matcher (clock + 7 kinds)" test "$(jq '[.hooks.SessionStart[]|select(.hooks|length==8)]|length' "$S")" = 5
  e_chk "install: principle hook registered" bash -c "jq -e '[.hooks.SessionStart[0].hooks[].command|select(endswith(\" principle\"))]|length==1' '$S'"
  [ "$E_FAIL" = 0 ]
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  HOME=$(mktemp -d); export HOME
  trap 'rm -rf "$HOME"' EXIT
  v5e_run; exit $?
fi
