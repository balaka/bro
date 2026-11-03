#!/bin/bash
# tests/parts/v5-b.sh — harvest + expire. Sourced by tests/v5.sh (HOME is a temp dir) or run standalone.
B_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../scripts" && pwd)"
B_FAIL=0
b_chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS: $d"; else echo "FAIL: $d"; B_FAIL=$((B_FAIL+1)); fi; }
b_eq() { # desc, got, want
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; B_FAIL=$((B_FAIL+1)); fi
}
H() { bash "$B_DIR/bro-harvest.sh" "$@"; }
E() { bash "$B_DIR/bro-expire.sh" "$@"; }
b_snap() { cat "$HOME"/bro/ws/*.log "$HOME"/bro/ws/*.archive "$HOME"/bro/ws/misses.log "$HOME"/bro/w2/*.log "$HOME"/bro/w2/*.archive "$HOME"/bro/*.log "$HOME"/bro/*.archive 2>/dev/null | sort; }
v5b_run() {
  local R="$HOME/bro" T Y
  mkdir -p "$HOME/.claude" "$R/ws" "$R/w2"
  printf '{"root":"%s"}\n' "$R" > "$HOME/.claude/bro-config.json"
  cp "$B_DIR/kinds.md" "$R/kinds.md"
  . "$B_DIR/bro-lib.sh"
  T=$(bro_today)
  local tA tB dA dB sA rC
  tA=$(bro_id task 2026-10-01 'Dana — send results'); tB=$(bro_id task 2026-10-01 'second task')
  dA=$(bro_id decision 2026-10-01 'use bash'); dB=$(bro_id decision 2026-10-02 'use bash 3.2 only')
  cat > "$R/ws/2026-10-01.md" <<J
# ws — 2026-10-01

## 09:15 · th — topic
free text
TASK: Dana — send results
TASK: second task
DECISION: use bash
RULE: always answer in English
STATE: tired
TERM: harvest = move markers to logs
INSIGHT: **markers at line start**
mid-line TASK: not a marker
J
  cat > "$R/ws/2026-10-02.md" <<J
# ws — 2026-10-02

## 10:00 · th — topic2
DONE $tA: sent
$tB — moved to Wednesday
DECISION: use bash 3.2 only (supersedes $dA)
STATE: energetic
TASK: Dana — send results
DONE t-000000: ghost
DECISION: gone (supersedes d-ffffff)
J
  cat > "$R/w2/2026-10-03.md" <<J
## 08:00 · x — y
STATE: calm
TASK: other ws task
J
  H --workspace ws
  H --workspace w2
  b_eq "task A done -> archived" "$(grep -c "^$tA | 2026-10-01 | 2026-10-01 | done:2026-10-02 | Dana — send results" "$R/ws/tasks.archive")" 1
  b_eq "task A re-added on 10-02 (new id, own date)" "$(grep -c "| 2026-10-02 | open | Dana — send results | ws/2026-10-02.md#10:00" "$R/ws/tasks.log")" 1
  b_chk "touch: bare id sets touched=journal date" grep -q "^$tB | 2026-10-01 | 2026-10-02 | open | second task | ws/2026-10-01.md#09:15$" "$R/ws/tasks.log"
  b_chk "new record format + source" grep -q "^$dB | 2026-10-02 | 2026-10-02 | open | use bash 3.2 only | ws/2026-10-02.md#10:00$" "$R/ws/decisions.log"
  b_chk "supersedes suffix stripped from text" bash -c "! grep -q 'supersedes' '$R/ws/decisions.log'"
  b_chk "superseded old decision archived" grep -q "^$dA | 2026-10-01 | 2026-10-01 | superseded:$dB | use bash" "$R/ws/decisions.archive"
  b_eq "decisions.log live count" "$(wc -l < "$R/ws/decisions.log" | tr -d ' ')" 2
  b_chk "mid-line marker ignored" bash -c "! grep -rq 'not a marker' '$R'/ws/*.log"
  b_chk "global rule in root rules.log" grep -q "| open | always answer in English | ws/2026-10-01.md#09:15$" "$R/rules.log"
  b_chk "no local rules log" test ! -e "$R/ws/rules.log"
  b_eq "state lives=last: one live" "$(wc -l < "$R/state.log" | tr -d ' ')" 1
  b_chk "state newest is live (other ws)" grep -q "| calm | " "$R/state.log"
  b_eq "state older archived superseded" "$(grep -c 'superseded:s-' "$R/state.archive")" 2
  b_chk "term + insight local logs" bash -c "grep -q 'harvest = move' '$R/ws/glossary.log' && grep -q 'markers at line start' '$R/ws/insights.log'"
  b_chk "miss: DONE unknown id" grep -q "^2026-10-02 | t-000000 | DONE t-000000: ghost$" "$R/ws/misses.log"
  b_chk "miss: supersedes unknown id" grep -q "^2026-10-02 | d-ffffff | " "$R/ws/misses.log"
  b_chk "state file written" grep -q "^2026-10-02.md	" "$R/ws/.harvest-state"
  # idempotent
  local snap
  snap=$(b_snap | cksum)
  H; H --workspace ws
  b_eq "second run adds nothing" "$(b_snap | cksum)" "$snap"
  # incremental append through bro-append (today's journal)
  mkdir -p "$R/ws"
  printf '%s\n' "TASK: fresh task" "$tB — still going" | bash "$B_DIR/bro-append.sh" --workspace ws --thread th --topic tp >/dev/null
  H --workspace ws
  b_chk "append-fed record harvested with today's date" grep -q "| $T | $T | open | fresh task | ws/$T.md#" "$R/ws/tasks.log"
  b_chk "touched to today via id mention" grep -q "^$tB | 2026-10-01 | $T | open" "$R/ws/tasks.log"
  # dedupe: identical open text is touched, not duplicated
  printf '%s\n' "TASK: fresh task" | bash "$B_DIR/bro-append.sh" --workspace ws --thread th --topic tp >/dev/null
  H --workspace ws
  b_eq "dedupe: still one 'fresh task'" "$(grep -c '| fresh task |' "$R/ws/tasks.log")" 1
  # --all rebuild equals incremental (journals are append-only, so rebuild == full history)
  local before after
  before=$(b_snap)
  H --all
  after=$(b_snap)
  b_eq "--all rebuild equals incremental" "$after" "$before"
  b_eq "--all twice stable" "$(H --all; b_snap)" "$before"

  # ---- expire
  rm -f "$R/.expire-stamp"
  cat > "$R/ws/tasks.log" <<L
t-aaaaaa | 2025-01-01 | 2025-01-01 | open | old task | 
t-bbbbbb | 2025-01-01 | $T | open | touched today | 
L
  cat > "$R/ws/insights.log" <<L
i-aaaaaa | 2025-01-01 | 2025-01-01 | open | old insight |
L
  cat > "$R/ws/decisions.log" <<L
d-aaaaaa | 2025-01-01 | 2025-01-01 | open | old decision |
L
  printf 'r-aaaaaa | 2020-01-01 | 2020-01-01 | open | ancient rule |\n' > "$R/rules.log"
  : > "$R/ws/tasks.archive"
  E --workspace ws
  b_eq "expire: old task gone from log" "$(grep -c old.task "$R/ws/tasks.log")" 0
  b_chk "expire: archived as expired:today" grep -q "^t-aaaaaa | 2025-01-01 | 2025-01-01 | expired:$T | old task" "$R/ws/tasks.archive"
  b_chk "expire: recently touched stays" grep -q "^t-bbbbbb " "$R/ws/tasks.log"
  b_eq "expire: old insight + decision archived" "$(grep -c expired "$R/ws/insights.archive" "$R/ws/decisions.archive" | cut -d: -f2 | tr -d '\n')" 11
  b_chk "expire: forever untouched" grep -q "^r-aaaaaa " "$R/rules.log"
  b_chk "expire --workspace writes no stamp" test ! -e "$R/.expire-stamp"
  # boundary: exactly N days old stays, N+1 expires
  Y=$(bash -c ". '$B_DIR/bro-lib.sh'; date -v-30d +%F 2>/dev/null || date -d '30 days ago' +%F")
  local Z; Z=$(date -v-31d +%F 2>/dev/null || date -d '31 days ago' +%F)
  printf 't-cccccc | 2025-01-01 | %s | open | thirty |\nt-dddddd | 2025-01-01 | %s | open | thirtyone |\n' "$Y" "$Z" >> "$R/ws/tasks.log"
  E --workspace ws
  b_chk "expire: 30-day-old task stays (lives=30d)" grep -q "^t-cccccc " "$R/ws/tasks.log"
  b_chk "expire: 31-day-old task expires" grep -q "^t-dddddd .*expired:" "$R/ws/tasks.archive"
  # stamp
  printf 't-eeeeee | 2025-01-01 | 2025-01-01 | open | stamped |\n' >> "$R/ws/tasks.log"
  E --all
  b_eq "--all writes stamp" "$(cat "$R/.expire-stamp")" "$T"
  b_chk "--all expired it" grep -q "^t-eeeeee .*expired:" "$R/ws/tasks.archive"
  printf 't-ffffff | 2025-01-01 | 2025-01-01 | open | second pass |\n' >> "$R/ws/tasks.log"
  E --all
  b_chk "stamp today -> --all skips" grep -q "^t-ffffff " "$R/ws/tasks.log"
  E --all --force
  b_chk "--force ignores stamp" bash -c "! grep -q '^t-ffffff ' '$R/ws/tasks.log'"
  b_chk "expire usage error without scope" bash -c "! bash '$B_DIR/bro-expire.sh'"
  [ "$B_FAIL" = 0 ]
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  HOME=$(mktemp -d); export HOME
  trap 'rm -rf "$HOME"' EXIT
  v5b_run; exit $?
fi
