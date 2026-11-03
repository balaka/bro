#!/bin/bash
# tests/parts/v5-a.sh — smoke for bro-lib.sh + bro-append.sh. Sourced by tests/v5.sh
# (HOME already a temp dir), or run standalone (makes its own temp HOME).
A_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../scripts" && pwd)"
A_FAIL=0
a_chk() { # desc, then a command; PASS if it exits 0
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $d"; else echo "FAIL: $d"; A_FAIL=$((A_FAIL+1)); fi
}
a_append() { printf '%s\n' "$1" | bash "$A_DIR/bro-append.sh" --workspace tws --thread th --topic tp; }
a_rejects() { ! a_append "$1"; }
v5a_run() {
  . "$A_DIR/bro-lib.sh"
  mkdir -p "$HOME/bro/tws"
  a_chk "bro_kinds prints 6 rows (default table)" test "$(bro_kinds | wc -l | tr -d ' ')" = 6
  a_chk "bro_kinds row has 7 tab fields" test "$(bro_kinds | head -1 | awk -F'\t' '{print NF}')" = 7
  a_chk "bro_kind_field task prefix = t" test "$(bro_kind_field task prefix)" = t
  a_chk "bro_log_path local" test "$(bro_log_path tws task)" = "$(bro_root)/tws/tasks.log"
  a_chk "bro_log_path global" test "$(bro_log_path tws rule)" = "$(bro_root)/rules.log"
  a_chk "bro_id stable" test "$(bro_id task 2026-11-03 x)" = "$(bro_id task 2026-11-03 x)"
  a_chk "bro_id shape" bash -c "[[ $(bro_id task 2026-11-03 x) =~ ^t-[0-9a-f]{6}$ ]]"
  a_chk "bro_session_context is valid JSON" bash -c ". '$A_DIR/bro-lib.sh'; bro_session_context hi | jq -e '.hookSpecificOutput.additionalContext==\"hi\"'"
  a_chk "append accepts valid body" a_append $'free text\nTASK: Dana — send results\nDONE t-b58d76: sent'
  a_chk "journal has title and header" bash -c "head -1 '$HOME/bro/tws/'*.md | grep -q '^# tws — ' && grep -q ' · th — tp$' '$HOME/bro/tws/'*.md"
  a_chk "append rejects '## ' line" a_rejects '## fake'
  a_chk "append rejects unknown marker" a_rejects 'NOTE: hello'
  a_chk "append accepts marker word mid-line" a_append 'we discussed TASK: and RULE: handling'
  a_chk "append rejects unknown workspace" bash -c "! printf 'x\\n' | bash '$A_DIR/bro-append.sh' --workspace nope --thread t --topic p"
  a_chk "unknown workspace folder not created" test ! -d "$HOME/bro/nope"
  a_chk "append rejects malformed DONE" a_rejects 'DONE nope: x'
  a_chk "append rejects empty body" a_rejects ''
  [ "$A_FAIL" = 0 ]
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  HOME=$(mktemp -d); export HOME
  trap 'rm -rf "$HOME"' EXIT
  v5a_run; exit $?
fi
