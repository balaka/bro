#!/bin/bash
# tests/parts/v5-d.sh — bro-migrate.sh on a tiny synthetic v4 store. Sourced by tests/v5.sh
# (HOME already a temp dir) or run standalone (makes its own temp HOME).
D_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../scripts" && pwd)"
D_FAIL=0
d_chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS: $d"; else echo "FAIL: $d"; D_FAIL=$((D_FAIL+1)); fi; }
d_has() { grep -qF -- "$2" "$1"; }          # file, literal
d_fixture() {
  local R="$HOME/bro"
  rm -rf "$R"; mkdir -p "$R/alpha" "$R/beta" "$R/_principles-sources"
  cat > "$R/alpha/2026-10-01.md" <<'J'
# alpha — 2026-10-01
## 10:00 · main — start
ДЕЛО: ship the widget
РЕШЕНИЕ: use blue
ОТКАЗ: green was too loud
ЗАКРЫТ t-aaaaaa: widget shipped
CLOSED t-bbbbbb: also done
OPEN: english legacy task
DECIDED: english legacy decision
REJECTED: english legacy rejection
ПРАВИЛО: be brief
ТЕРМИН: foo — a made-up word
СОСТОЯНИЕ: calm
ИНСАЙТ: small steps work
дело: lowercase is prose
text with ДЕЛО: in the middle stays
J
  cat > "$R/alpha/2026-10-20.md" <<'J'
# alpha — 2026-10-20
## 09:00 · main — later
t-cccccc — moved to Friday
J
  printf '# beta — 2026-10-02\n## 11:00 · x — y\nTASK: already v5\n' > "$R/beta/2026-10-02.md"
  cat > "$R/alpha/open.md" <<'J'
# alpha — open items

> header prose

- [ ] t-cccccc · call the plumber — from: 2026-10-01 · «10:00 — start»
- [x] t-aaaaaa · ship the widget — from: 2026-10-01 · «10:00 — start» — closed 2026-10-05: shipped
- [x] t-dddddd — закрыт 10.10: no longer needed · old text — from: 2026-10-01 · «10:00 — start»
J
  cat > "$R/alpha/decisions.md" <<'J'
# alpha — decisions

### d-111111 (2026-10-01) [active]
use blue for buttons | instead of: green | because: contrast
— from: 2026-10-01 · «10:00 — start»

### d-222222 (2026-09-20) [superseded by d-111111]
use red for buttons
second body line
— from: 2026-09-20 · «08:00 — old»
J
  printf '# alpha — insights\n\n- **i-333333** · small steps work — from: 2026-10-01 · «10:00 — start»\n' > "$R/alpha/insights.md"
  printf '# alpha — vocabulary\n\n- **v-444444** · foo — a made-up word — from: 2026-10-01 · «10:00 — start»\n' > "$R/alpha/vocab.md"
  printf '# alpha — workspace\nsummary\n' > "$R/alpha/_workspace.md"
  printf '# beta — open items\n\n- [ ] t-eeeeee · beta thing — from: 2026-10-02 · «11:00 — x»\n' > "$R/beta/open.md"
  printf '# Operator state\n<!-- ts: 1790000000 2026-10-15 12:00 -->\n<!-- written by bro-harvest; do not edit by hand -->\nrecorded: 2026-10-15 12:00 · project alpha · «x»\n- tired but steady.\n- short sessions.\n' > "$R/_state.md"
  printf '# principles\n\n## §1 · first\n## §2 · second\n' > "$R/_principles.md"
  printf 'Rule one.\nRule two.\n\nRule three.\n' > "$R/_rules-draft.md"
  echo old > "$R/INDEX.md"; echo old > "$R/_principles-sources/alpha.md"; echo old > "$R/.last-rule-review"
  echo old > "$R/_principles.md.bak-2026-09-30"; echo old > "$R/_rule-candidates.md"
}
d_snapshot() { (cd "$HOME/bro" && find . -type f -not -path './_archive/*' | sort | xargs cksum 2>/dev/null); }
v5d_run() {
  d_fixture
  local R="$HOME/bro" before out
  before=$(d_snapshot)
  out=$(bash "$D_DIR/bro-migrate.sh" --dry-run 2>&1)
  d_chk "dry-run exits 0 and prints counts" bash -c "echo '$out' | grep -q 'task'"
  d_chk "dry-run writes nothing" test "$before" = "$(d_snapshot)"
  d_chk "dry-run makes no backup/stamp" bash -c "test ! -e '$R/_archive' && test ! -e '$R/.v5-migrated'"
  d_chk "dry-run leaves no staging dir" bash -c "! ls -a '$R' | grep -q migrate-stage"

  bash "$D_DIR/bro-migrate.sh" >"$HOME/mig.out" 2>&1; local rc=$?
  d_chk "migrate exits 0" test "$rc" = 0
  local J="$R/alpha/2026-10-01.md"
  d_chk "ДЕЛО: -> TASK:" d_has "$J" "TASK: ship the widget"
  d_chk "РЕШЕНИЕ: -> DECISION:" d_has "$J" "DECISION: use blue"
  d_chk "ОТКАЗ: -> DECISION: rejected —" d_has "$J" "DECISION: rejected — green was too loud"
  d_chk "ЗАКРЫТ id: -> DONE id:" d_has "$J" "DONE t-aaaaaa: widget shipped"
  d_chk "CLOSED id: -> DONE id:" d_has "$J" "DONE t-bbbbbb: also done"
  d_chk "OPEN: -> TASK:" d_has "$J" "TASK: english legacy task"
  d_chk "DECIDED: -> DECISION:" d_has "$J" "DECISION: english legacy decision"
  d_chk "REJECTED: -> DECISION: rejected —" d_has "$J" "DECISION: rejected — english legacy rejection"
  d_chk "ПРАВИЛО/ТЕРМИН/СОСТОЯНИЕ/ИНСАЙТ mapped" bash -c "grep -qx 'RULE: be brief' '$J' && grep -qx 'TERM: foo — a made-up word' '$J' && grep -qx 'STATE: calm' '$J' && grep -qx 'INSIGHT: small steps work' '$J'"
  d_chk "lower-case label stays prose" d_has "$J" "дело: lowercase is prose"
  d_chk "mid-line marker untouched" d_has "$J" "text with ДЕЛО: in the middle stays"
  d_chk "no Russian marker left at line start" bash -c "! grep -qE '^(ДЕЛО|РЕШЕНИЕ|ОТКАЗ|ЗАКРЫТ|ПРАВИЛО|ТЕРМИН|СОСТОЯНИЕ|ИНСАЙТ)' '$J'"
  d_chk "headings and header lines preserved" bash -c "head -2 '$J' | grep -q '^## 10:00' || sed -n 2p '$J' | grep -q '^## 10:00'"

  d_chk "open task keeps old id, created from 'from:'" d_has "$R/alpha/tasks.log" "t-cccccc | 2026-10-01 | 2026-10-20 | open | call the plumber | alpha/2026-10-01.md"
  d_chk "open task touched raised by later journal mention" d_has "$R/alpha/tasks.log" "| 2026-10-20 |"
  d_chk "closed task in archive with done:DATE" d_has "$R/alpha/tasks.archive" "t-aaaaaa | 2026-10-01 | 2026-10-01 | done:2026-10-05 | ship the widget"
  d_chk "closed task not in live log" bash -c "! grep -q t-aaaaaa '$R/alpha/tasks.log'"
  d_chk "variant 'id — закрыт …' goes to archive" bash -c "grep -q '^t-dddddd .* | done:' '$R/alpha/tasks.archive'"
  d_chk "decision active -> live, old id, body single line" d_has "$R/alpha/decisions.log" "d-111111 | 2026-10-01 | 2026-10-01 | open | use blue for buttons | instead of: green | because: contrast"
  d_chk "superseded decision in archive, bodies joined" d_has "$R/alpha/decisions.archive" "d-222222 | 2026-09-20 | 2026-09-20 | superseded:d-111111 | use red for buttons second body line"
  d_chk "superseded decision not live" bash -c "! grep -q d-222222 '$R/alpha/decisions.log'"
  d_chk "insight migrated" d_has "$R/alpha/insights.log" "i-333333 | 2026-10-01 | 2026-10-01 | open | small steps work"
  d_chk "term migrated to glossary.log" d_has "$R/alpha/glossary.log" "v-444444 | 2026-10-01 | 2026-10-01 | open | foo — a made-up word"
  d_chk "second workspace migrated (log, or archive if expire ran)" bash -c "cat '$R'/beta/tasks.log '$R'/beta/tasks.archive 2>/dev/null | grep -q \"^t-eeeeee | 2026-10-02\""
  d_chk "principles.log has 3 lines (one per draft rule)" test "$(wc -l < "$R/principles.log" | tr -d ' ')" = 3
  d_chk "state.log has 1 line, joined with '; '" bash -c "test \"\$(wc -l < '$R/state.log' | tr -d ' ')\" = 1 && grep -q '^s-[0-9a-f]\{6\} | 2026-10-15 | 2026-10-15 | open | tired but steady.; short sessions.' '$R/state.log'"
  d_chk "every log line has >= 5 fields" bash -c "! awk -F' [|] ' 'NF<5{bad=1} END{exit !bad}' '$R'/alpha/*.log '$R'/alpha/*.archive '$R'/principles.log"
  d_chk "kinds.md written" test -s "$R/kinds.md"

  d_chk "backup folder exists" bash -c "ls -d '$R'/_archive/v4-*"
  d_chk "backup holds original open.md" bash -c "grep -q 'call the plumber' '$R'/_archive/v4-*/alpha/open.md"
  d_chk "backup holds original (unrewritten) journal" bash -c "grep -q '^ДЕЛО: ship the widget' '$R'/_archive/v4-*/alpha/2026-10-01.md"
  d_chk "old registers gone from live tree" bash -c "cd '$R' && ! ls alpha/open.md alpha/decisions.md alpha/insights.md alpha/vocab.md alpha/_workspace.md beta/open.md _state.md _principles.md _rules-draft.md INDEX.md _principles-sources _principles.md.bak-2026-09-30 _rule-candidates.md .last-rule-review 2>/dev/null | grep -q ."
  d_chk "old registers moved into archive root" bash -c "ls '$R'/_archive/v4-*/INDEX.md '$R'/_archive/v4-*/_principles-sources/alpha.md '$R'/_archive/v4-*/_rules-draft.md"
  d_chk ".v5-migrated present with date" bash -c "grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}\$' '$R/.v5-migrated'"
  d_chk ".harvest-state marks journals as read" d_has "$R/alpha/.harvest-state" "2026-10-01.md"
  d_chk "counts table printed (alpha task)" bash -c "grep -E '^ +alpha +task +1 +2' '$HOME/mig.out'"

  local snap2; snap2=$(d_snapshot)
  bash "$D_DIR/bro-migrate.sh" >"$HOME/mig2.out" 2>&1; rc=$?
  d_chk "second run refuses (non-zero)" test "$rc" != 0
  d_chk "second run changes nothing" test "$snap2" = "$(d_snapshot)"
  d_chk "dry-run still allowed after migration" bash "$D_DIR/bro-migrate.sh" --dry-run
  [ "$D_FAIL" = 0 ]
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  HOME=$(mktemp -d); export HOME
  trap 'rm -rf "$HOME"' EXIT
  v5d_run; exit $?
fi
