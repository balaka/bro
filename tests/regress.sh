#!/bin/bash
# bro v3.7 — regression suite.
#
# Self-contained: every test builds its own throw-away sandbox under a
# mktemp dir with HOME overridden, and writes only SYNTHETIC journals — it
# never reads or depends on the operator's real ~/bro store. Safe to run
# from a clean checkout with nothing installed.
#
# bash 3.2 + BSD/GNU userland, same target as the rest of this project.
# jq is required to RUN this suite (bro-install.sh itself hard-requires
# it) — the dedicated "no-jq fallback" section below builds its own
# jq-free PATH and exercises the hooks' sed fallbacks inside it, which is
# the thing that actually has to work without jq, not this harness.
#
# Usage: tests/regress.sh
#   BRO_REGRESS_KEEP=1 tests/regress.sh   — keep sandboxes after a FAIL for inspection
#
# Prints one PASS:/FAIL: line per check and exits non-zero if anything failed.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
KEEP="${BRO_REGRESS_KEEP:-0}"

command -v jq >/dev/null 2>&1 || { echo "FAIL: setup — jq is required to run this suite (bro-install.sh itself requires it)"; exit 1; }
command -v bash >/dev/null 2>&1 || { echo "FAIL: setup — bash not found"; exit 1; }

PASS_N=0
FAIL_N=0
FAILED_NAMES=()
ALL_SANDBOXES=()
SIDN=0

pass() { PASS_N=$((PASS_N+1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL_N=$((FAIL_N+1)); FAILED_NAMES+=("$1"); printf 'FAIL: %s -- %s\n' "$1" "$2"; }

# assert helpers ----------------------------------------------------------
assert_eq() { # name actual expected
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$3] got [$2]"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to contain [$3] in: $(printf '%s' "$2" | head -c 400)" ;; esac
}
assert_not_contains() { # name haystack needle
  case "$2" in *"$3"*) fail "$1" "expected NOT to contain [$3] in: $(printf '%s' "$2" | head -c 400)" ;; *) pass "$1" ;; esac
}
assert_exit() { # name actual_exit expected_exit
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected exit $3 got $2"; fi
}
assert_file_exists() { # name path
  [ -f "$2" ] && pass "$1" || fail "$1" "file does not exist: $2"
}
assert_file_absent() { # name path
  [ -f "$2" ] && fail "$1" "file unexpectedly exists: $2" || pass "$1"
}

# A file-backed counter, not a shell variable: `SID=$(next_sid)` runs the
# function in a command-substitution SUBSHELL, so a plain `SIDN=$((SIDN+1))`
# would increment only that subshell's copy and never advance the counter
# the caller sees -- every call would return the same id, and two "distinct"
# sessions would silently share one GUARD/GUARD_W/MARK file. A counter file
# survives the subshell boundary because it's read and written on disk.
SIDCOUNTER_FILE=$(mktemp "${TMPDIR:-/tmp}/bro-regress-sidctr.XXXXXX")
echo 0 > "$SIDCOUNTER_FILE"
next_sid() {
  local n
  n=$(( $(cat "$SIDCOUNTER_FILE") + 1 ))
  echo "$n" > "$SIDCOUNTER_FILE"
  printf 'rs%06d%04dabcd' "$$" "$n"
}
now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time;print(int(time.time()*1000))'
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}
hookjson() { # cwd sid pid event
  printf '{"cwd":"%s","session_id":"%s","prompt_id":"%s","hook_event_name":"%s"}' "$1" "$2" "$3" "$4"
}

# sandbox lifecycle ---------------------------------------------------------
# sets SB HOME ROOT BIN CONFIG; exports HOME so every child process picks it up
new_sandbox() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/bro-regress.XXXXXX") || { echo "FAIL: setup -- mktemp failed"; exit 1; }
  ALL_SANDBOXES+=("$SB")
  export HOME="$SB/home"
  mkdir -p "$HOME/.claude"
  ROOT="$HOME/bro"
  BIN="$HOME/.claude/bro/bin"
  CONFIG="$HOME/.claude/bro-config.json"
}
install_repo() { # installs the repo's own scripts into $HOME (jq required, as production requires)
  bash "$SCRIPTS_DIR/bro-install.sh" > "$SB/install.log" 2>&1
  echo $?
}
# workspace name must already be slug-safe (lowercase, digits, hyphens) --
# resolution below relies on dir-slug matching (basename == workspace name),
# no bro-config.json workspaces map needed, so this suite has no jq
# dependency for the actual test bodies, only for install/assertions.
mkws() { # $1 = workspace name
  mkdir -p "$ROOT/$1" "$SB/proj/$1"
}
proj_dir() { printf '%s/proj/%s' "$SB" "$1"; }

cleanup_all() {
  rm -f "$SIDCOUNTER_FILE" 2>/dev/null
  [ "$KEEP" = "1" ] && [ "$FAIL_N" -gt 0 ] && { echo "(kept ${#ALL_SANDBOXES[@]} sandbox(es) under ${TMPDIR:-/tmp} because BRO_REGRESS_KEEP=1 and something failed)"; return; }
  for d in "${ALL_SANDBOXES[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup_all EXIT

echo "==== bro v3.7 regression suite ===="
echo "repo: $REPO_DIR"
echo ""

# ===========================================================================
# 1. installer idempotency + foreign hooks preserved
# ===========================================================================
echo "-- 1. installer --"
new_sandbox
cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "cleanupPeriodDays": 3650,
  "permissions": {"allow": ["Bash(ls *)", "Bash(git status*)"]},
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type":"command","command":"/opt/foreign/hook.sh","timeout":10}]}
    ],
    "Stop": [
      {"hooks":[{"type":"command","command":"/opt/foreign/stop.sh","timeout":10}]}
    ]
  }
}
JSON

R1=$(install_repo)
assert_exit "installer: first run exits 0" "$R1" "0"
cp "$HOME/.claude/settings.json" "$SB/settings-run1.json"
R2=$(install_repo)
assert_exit "installer: second run exits 0" "$R2" "0"
cp "$HOME/.claude/settings.json" "$SB/settings-run2.json"

if diff -q "$SB/settings-run1.json" "$SB/settings-run2.json" >/dev/null 2>&1; then
  pass "installer: idempotent (run1 settings.json == run2)"
else
  fail "installer: idempotent (run1 settings.json == run2)" "$(diff "$SB/settings-run1.json" "$SB/settings-run2.json" | head -20)"
fi

FOREIGN_SS=$(jq '[.hooks.SessionStart[]? | select(.hooks[]?.command=="/opt/foreign/hook.sh")] | length' "$SB/settings-run2.json")
assert_eq "installer: foreign SessionStart hook preserved" "$FOREIGN_SS" "1"
FOREIGN_STOP=$(jq '[.hooks.Stop[]? | select(.hooks[]?.command=="/opt/foreign/stop.sh")] | length' "$SB/settings-run2.json")
assert_eq "installer: foreign Stop hook preserved" "$FOREIGN_STOP" "1"
PERM=$(jq -c '.permissions.allow' "$SB/settings-run2.json")
assert_contains "installer: pre-existing permissions untouched" "$PERM" "Bash(git status*)"

SS_N=$(jq '.hooks.SessionStart | length' "$SB/settings-run2.json")
assert_eq "installer: SessionStart has 5 groups (1 foreign + 4 bro)" "$SS_N" "5"
STOP_N=$(jq '.hooks.Stop | length' "$SB/settings-run2.json")
assert_eq "installer: Stop has 2 groups (1 foreign + 1 bro)" "$STOP_N" "2"
PTU_M=$(jq -r '.hooks.PreToolUse[0].matcher' "$SB/settings-run2.json")
assert_eq "installer: PreToolUse matcher is Write|Edit|Bash" "$PTU_M" "Write|Edit|Bash"

for f in bro-lib.sh bro-append.sh bro-harvest.sh bro-session-start.sh bro-stop-turnstile.sh bro-write-guard.sh bro-harvest-hook.sh bro-precompact.sh bro-migrate.sh; do
  assert_file_exists "installer: $f present in installed bin dir" "$BIN/$f"
done

# ===========================================================================
# 2. session-start: emits context fast, sets the start mark
# ===========================================================================
echo "-- 2. session-start --"
new_sandbox
install_repo >/dev/null
mkws wssession
SID=$(next_sid)
PROJ=$(proj_dir wssession)
T0=$(now_ms)
OUT=$(hookjson "$PROJ" "$SID" p1 SessionStart | "$BIN/bro-session-start.sh")
RC=$?
T1=$(now_ms)
assert_exit "session-start: exits 0" "$RC" "0"
assert_contains "session-start: names the resolved workspace" "$OUT" "workspace 'wssession'"
assert_contains "session-start: teaches bro-append.sh, not direct Write/Edit" "$OUT" "bro-append.sh"
assert_file_exists "session-start: start mark created" "$HOME/.claude/bro/started/$SID"
MARKVAL=$(cat "$HOME/.claude/bro/started/$SID" 2>/dev/null)
assert_eq "session-start: mark flips to ok once context is out" "$MARKVAL" "ok"
ELAPSED=$((T1-T0))
if [ "$ELAPSED" -lt 5000 ]; then pass "session-start: fast (${ELAPSED}ms < 5000ms, hook cap is 10000ms)"; else fail "session-start: fast" "${ELAPSED}ms, hook cap is 10000ms"; fi

# regression: the injected CLOSED: syntax must match bro.md's own worked
# example (no colon between the keyword and the id) and bro-harvest.sh's
# own parser (HEAD="${CLEAN%%:*}" takes everything before the FIRST colon
# as keyword+id) -- "CLOSED: <id>:" teaches a syntax that harvest can never
# resolve to an id, so every close attempted that way becomes a CLOSE-MISS
# instead of closing anything.
assert_not_contains "session-start: does NOT teach the broken 'CLOSED: <id>:' syntax" "$OUT" "CLOSED: <its exact id"
assert_contains "session-start: teaches 'CLOSED <id>:' (no colon before the id), matching bro.md" "$OUT" "CLOSED <its exact id from open.md>:"

# end-to-end: the exact syntax session-start teaches must actually close a
# tail through harvest, not produce a CLOSE-MISS
mkws wsteach
PROJt=$(proj_dir wsteach)
cd "$PROJt"
printf 'TAIL: something session-start should teach how to close\n' | "$BIN/bro-append.sh" --workspace wsteach --thread t --topic seed >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsteach >/dev/null
OPENT="$ROOT/wsteach/open.md"
TIDT=$(grep -oE '^- \[ \] [a-z0-9-]+' "$OPENT" | head -1 | awk '{print $4}')
cd "$PROJt"
# literally the shape session-start's own text demonstrates: "CLOSED <id>: <text>"
printf 'CLOSED %s: closed exactly the way session-start says to\n' "$TIDT" | "$BIN/bro-append.sh" --workspace wsteach --thread t --topic close >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsteach >/dev/null
assert_contains "session-start: its own taught CLOSED syntax actually flips the checkbox" "$(grep -F "$TIDT" "$OPENT")" "- [x] $TIDT"
assert_file_absent "session-start: its own taught CLOSED syntax produces no CLOSE-MISS" "$ROOT/wsteach/.close-misses.log"

# ===========================================================================
# 3. incremental harvest
# ===========================================================================
echo "-- 3. incremental harvest --"
new_sandbox
install_repo >/dev/null
mkws wsinc
PROJ=$(proj_dir wsinc)
cd "$PROJ"
for i in 1 2 3; do
  printf 'DECIDED: choice %d | over: alt%d | because: reason%d\n' "$i" "$i" "$i" \
    | "$BIN/bro-append.sh" --workspace wsinc --thread "t$i" --topic "topic $i" >/dev/null
done
cd "$REPO_DIR"
OUT=$("$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsinc)
CNT=$(grep -c '^### ' "$ROOT/wsinc/decisions.md" 2>/dev/null || echo 0)
assert_eq "incremental: first pass files all 3 appended markers" "$CNT" "3"
assert_file_exists "incremental: stamp created after a completed pass" "$ROOT/wsinc/.harvest-stamp"
assert_file_exists "incremental: state created after a completed pass" "$ROOT/wsinc/.harvest-state"

OUT2=$("$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsinc)
CNT2=$(grep -c '^### ' "$ROOT/wsinc/decisions.md" 2>/dev/null || echo 0)
assert_eq "incremental: unchanged re-run adds no records" "$CNT2" "3"
# NB: NOT asserting "0 journal(s) to read" here -- the incremental stamp is
# deliberately backdated 2s at pass start (bro-harvest.sh's own comment: a
# journal written in the very second a pass starts must not tie with the
# stamp and look "not newer"), so a re-run within ~2s of the first pass can
# legitimately still see the journal as "newer" and re-read it. The real
# invariant -- that re-reading it adds nothing -- is what's asserted above.

OUT3=$("$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsinc --full)
CNT3=$(grep -c '^### ' "$ROOT/wsinc/decisions.md" 2>/dev/null || echo 0)
assert_eq "incremental: --full over unchanged journal adds no records" "$CNT3" "3"
assert_not_contains "incremental: no id collisions across passes" "$OUT$OUT2$OUT3" "COLLISION"

cd "$PROJ"
printf 'DECIDED: choice 4 | over: alt4 | because: reason4\n' \
  | "$BIN/bro-append.sh" --workspace wsinc --thread t4 --topic "topic 4" >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsinc >/dev/null
CNT4=$(grep -c '^### ' "$ROOT/wsinc/decisions.md" 2>/dev/null || echo 0)
assert_eq "incremental: append -> exactly one new record (4 total)" "$CNT4" "4"
UNIQ4=$(grep -oE '^### [a-z0-9x-]+ ' "$ROOT/wsinc/decisions.md" | sort -u | wc -l | tr -d ' ')
assert_eq "incremental: all 4 ids distinct (nothing overwritten)" "$UNIQ4" "4"

# --- killed inner loop -> stamp not advanced ---
mkws wskill
F="$ROOT/wskill/$(date +%F).md"
{
  printf '# bro -- %s / wskill\n\n' "$(date +%F)"
  for i in $(seq 1 70); do
    printf '## 09:%02d - thread%d - topic%d\nDECIDED: kill-test choice %d | over: alt%d | because: reason%d\n\n' \
      "$((i % 60))" "$i" "$i" "$i" "$i" "$i"
  done
} > "$F"
KOUT="$SB/kill-out.log"; : > "$KOUT"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wskill > "$KOUT" 2>&1 &
KPID=$!
N=0
for i in $(seq 1 500); do
  N=$(grep -c '^\[bro-harvest\] + decision' "$KOUT" 2>/dev/null || echo 0)
  [ "${N:-0}" -gt 15 ] 2>/dev/null && break
  sleep 0.01
done
kill -9 "$KPID" 2>/dev/null
wait "$KPID" 2>/dev/null
pkill -9 -P "$KPID" 2>/dev/null
sleep 0.2
if [ "${N:-0}" -gt 15 ] 2>/dev/null; then pass "kill test: pass was genuinely interrupted mid-flight ($N records written before kill)"; else fail "kill test: pass was genuinely interrupted mid-flight" "only $N records written before kill -- timing window too narrow, test inconclusive"; fi
assert_file_absent "kill test: stamp NOT advanced after a killed pass" "$ROOT/wskill/.harvest-stamp"
assert_file_absent "kill test: state NOT written after a killed pass" "$ROOT/wskill/.harvest-state"

"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wskill --quiet
KCNT=$(grep -c '^### ' "$ROOT/wskill/decisions.md" 2>/dev/null || echo 0)
assert_eq "kill test: resume completes the pass with all 70 records, no loss" "$KCNT" "70"
KUNIQ=$(grep -oE '^### [a-z0-9x-]+ ' "$ROOT/wskill/decisions.md" | sort -u | wc -l | tr -d ' ')
assert_eq "kill test: resume produces 70 distinct ids (nothing duplicated across the kill boundary)" "$KUNIQ" "70"
assert_file_exists "kill test: stamp now advanced after a completed pass" "$ROOT/wskill/.harvest-stamp"

# --- id stability across --all --full (the v3.7 hard-rule requirement:
# changing how a marker body is built must not duplicate what an existing
# store already harvested) ---
mkws wsidstab
F=$(printf '%s/wsidstab/%s.md' "$ROOT" "$(date +%F)")
printf '# bro — %s / wsidstab\n\n## 10:00 · bro — test\nDECIDED: chose Postgres over Mongo\ncontinuation line one about SQL well\ncontinuation line two more text\n\n' "$(date +%F)" > "$F"
"$BIN/bro-harvest.sh" --root "$ROOT" --all --full >/dev/null
CNT_A=$(grep -c '^### ' "$ROOT/wsidstab/decisions.md" 2>/dev/null || echo 0)
"$BIN/bro-harvest.sh" --root "$ROOT" --all --full >/dev/null
CNT_B=$(grep -c '^### ' "$ROOT/wsidstab/decisions.md" 2>/dev/null || echo 0)
assert_eq "id stability: --all --full record counts identical before/after a repeated pass over an unedited store" "$CNT_B" "$CNT_A"

# KNOWN LIMITATION (documented in bro-harvest.sh's own header, not fixed in
# this release -- see the "Id stability across this change" comment):
# editing text inside a marker's old glue span, even though v3.7 no longer
# stores that text in the register body, still perturbs the id and can
# file a second record for the same underlying marker line. This
# characterizes the CURRENT, accepted behavior so a future change to it is
# deliberate, not silent.
sed -i '' 's/SQL well/SQL very well/' "$F"
touch "$F"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsidstab >/dev/null   # incremental: edited-prefix hash-mismatch forces a wide re-read
CNT_C=$(grep -c '^### ' "$ROOT/wsidstab/decisions.md" 2>/dev/null || echo 0)
assert_eq "id stability KNOWN LIMITATION: editing the (unstored) glue tail of an already-harvested marker files a second record" "$CNT_C" "2"
BODY_A=$(grep -A1 '^### ' "$ROOT/wsidstab/decisions.md" | grep 'chose Postgres over Mongo' | sort -u | wc -l | tr -d ' ')
assert_eq "id stability KNOWN LIMITATION: both records carry the identical (own-line-only) body" "$BODY_A" "1"

# ===========================================================================
# 4. glue fix
# ===========================================================================
echo "-- 4. glue fix --"
new_sandbox
install_repo >/dev/null
mkws wsglue
DATE=$(date +%F)
F="$ROOT/wsglue/$DATE.md"
cat > "$F" <<EOF
# bro -- $DATE / wsglue

## 09:00 . t -- topic1
TERM: gluedterm - a term whose paragraph is NOT separated by a blank line
this paragraph has no blank line before it and must not end up in the record

## 09:05 . t -- topic2
TERM: cleanterm - a term written with the required blank-line separation

more prose here, properly separated, also must not glue
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsglue --full > "$SB/glue-out.log" 2>&1
VOC="$ROOT/wsglue/vocab.md"
assert_file_exists "glue: vocab.md created" "$VOC"
GLUED_LINE=$(grep 'gluedterm' "$VOC" 2>/dev/null || true)
assert_not_contains "glue: glued marker's body excludes the un-separated paragraph" "$GLUED_LINE" "must not end up in the record"
assert_contains "glue: glued marker's body is still exactly its own line" "$GLUED_LINE" "gluedterm - a term whose paragraph is NOT separated"
CLEAN_LINE=$(grep 'cleanterm' "$VOC" 2>/dev/null || true)
assert_contains "glue: legitimately-separated record intact" "$CLEAN_LINE" "cleanterm - a term written with the required blank-line separation"
assert_not_contains "glue: legitimately-separated record has no glued prose" "$CLEAN_LINE" "more prose here"
assert_contains "glue: passive counter reported exactly 1 dropped marker" "$(cat "$SB/glue-out.log")" "1 marker(s) had adjacent text not captured"
HEALTH="$HOME/.claude/bro/health.log"
assert_file_exists "glue: health.log written" "$HEALTH"
HCNT=$(grep -c 'marker(s) had adjacent text not captured' "$HEALTH" 2>/dev/null || echo 0)
assert_eq "glue: exactly one health.log line for this pass" "$HCNT" "1"

# a workspace with nothing glued must produce a silent health.log (no line at all)
new_sandbox
install_repo >/dev/null
mkws wsnoglue
F2="$ROOT/wsnoglue/$DATE.md"
cat > "$F2" <<EOF
# bro -- $DATE / wsnoglue

## 09:00 . t -- topic
TERM: onlyterm - clean, no adjacent prose at all
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsnoglue --full > "$SB/noglue-out.log" 2>&1
assert_not_contains "glue: N=0 case prints nothing about dropped markers" "$(cat "$SB/noglue-out.log")" "had adjacent text not captured"
assert_file_absent "glue: N=0 case writes no health.log" "$HOME/.claude/bro/health.log"

# ===========================================================================
# 5. CLOSED marker
# ===========================================================================
echo "-- 5. CLOSED marker --"
new_sandbox
install_repo >/dev/null
mkws wsclosed
PROJ=$(proj_dir wsclosed)
cd "$PROJ"
printf 'TAIL: something to follow up on\n' | "$BIN/bro-append.sh" --workspace wsclosed --thread t --topic tail1 >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsclosed >/dev/null
OPEN="$ROOT/wsclosed/open.md"
TID=$(grep -oE '^- \[ \] [a-z0-9-]+' "$OPEN" | head -1 | awk '{print $4}')
if [ -n "$TID" ]; then pass "CLOSED: tail created with an id ($TID)"; else fail "CLOSED: tail created with an id" "no tail line found in $OPEN"; fi
cp "$OPEN" "$SB/open-before-close.md"

cd "$PROJ"
printf 'CLOSED %s: fixed it during review\n' "$TID" | "$BIN/bro-append.sh" --workspace wsclosed --thread t --topic close1 >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsclosed >/dev/null
FLIPPED=$(grep -F "$TID" "$OPEN" | head -1)
assert_contains "CLOSED: checkbox flips to [x]" "$FLIPPED" "- [x] $TID"
assert_contains "CLOSED: closed-reason text appended" "$FLIPPED" "закрыт"
assert_contains "CLOSED: closed-reason carries the operator's own text" "$FLIPPED" "fixed it during review"
DIFFCNT=$(diff "$SB/open-before-close.md" "$OPEN" | grep -c '^[<>]')
assert_eq "CLOSED: exactly one line changed in open.md, nothing else touched" "$DIFFCNT" "2"

# idempotent: harvest again, and re-CLOSE the same id -- no double-close, no duplicate line
cp "$OPEN" "$SB/open-after-close.md"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsclosed --full >/dev/null
diff -q "$SB/open-after-close.md" "$OPEN" >/dev/null 2>&1 && pass "CLOSED: --full re-run over an already-closed tail is a byte-identical no-op" || fail "CLOSED: --full re-run over an already-closed tail is a byte-identical no-op" "open.md changed"
cd "$PROJ"
printf 'CLOSED %s: closing again should be a no-op\n' "$TID" | "$BIN/bro-append.sh" --workspace wsclosed --thread t --topic reclose >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsclosed >/dev/null
LINECNT=$(grep -cF "$TID" "$OPEN")
assert_eq "CLOSED: re-closing the same id does not duplicate the line" "$LINECNT" "1"

# close-miss: bogus id
cd "$PROJ"
printf 'CLOSED t-doesnotexist99: nope\n' | "$BIN/bro-append.sh" --workspace wsclosed --thread t --topic miss1 >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsclosed >/dev/null
MISS="$ROOT/wsclosed/.close-misses.log"
assert_file_exists "CLOSED: close-miss logged for an id not open" "$MISS"
assert_contains "CLOSED: close-miss log names the bogus id" "$(cat "$MISS")" "t-doesnotexist99"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsclosed --full >/dev/null
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wsclosed --full >/dev/null
MISSCNT=$(wc -l < "$MISS" | tr -d ' ')
assert_eq "CLOSED: close-miss deduped across repeated --full passes" "$MISSCNT" "1"

# regression: a marker that is the literal last physical line of a journal,
# with NO trailing newline after it (any hand-edit, or any pre-bro-append.sh
# content -- bro-append.sh itself always terminates its own writes), must
# still be seen. `wc -l` counts newlines, not lines, so it used to undercount
# by one for exactly this file shape, and the awk scan's own `NR > to {exit}`
# bound silently dropped the file's true last line -- no register write, no
# CLOSE-MISS, no health.log line, no error at all.
mkws wseof
OPENE="$ROOT/wseof/open.md"
printf '# wseof — open items\n\n- [ ] t-fix00 · closing at EOF with no trailing newline — родился: 2026-09-19\n\n' > "$OPENE"
printf '# bro — %s / wseof\n\n## 09:00 · t — topic\nCLOSED t-fix00: closing at EOF with no trailing newline' "$(date +%F)" > "$ROOT/wseof/$(date +%F).md"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wseof --full >/dev/null
assert_contains "EOF marker: a CLOSED on the file's unterminated last line is still seen" "$(grep -F 't-fix00' "$OPENE")" "- [x] t-fix00"

# ===========================================================================
# 6. bro-append.sh
# ===========================================================================
echo "-- 6. bro-append.sh --"
new_sandbox
install_repo >/dev/null
mkws wsappend
PROJ=$(proj_dir wsappend)
cd "$PROJ"

TBEFORE=$(date +%H:%M)
"$BIN/bro-append.sh" --workspace wsappend --thread clocktest --topic "clock check" <<< 'DECIDED: clock test' >/dev/null
TAFTER=$(date +%H:%M)
JF="$ROOT/wsappend/$(date +%F).md"
HDR=$(grep '^## ' "$JF" | head -1)
case "$HDR" in
  *"$TBEFORE"*|*"$TAFTER"*) pass "append: section time stamped from the real clock" ;;
  *) fail "append: section time stamped from the real clock" "header [$HDR] does not match clock window $TBEFORE/$TAFTER" ;;
esac
assert_contains "append: header created once, canonical shape" "$(head -1 "$JF")" "# bro — $(date +%F) / wsappend"

# blank line after every marker: every marker line in the file must be followed by a blank line
awk 'BEGIN{mre="^(DECIDED|REJECTED|RULE|TAIL|TERM|CLOSED):? "} { if ($0 ~ mre) { getline nxt; if (nxt !~ /^[[:space:]]*$/) print NR }}' "$JF" > "$SB/badlines.txt"
BADN=$(wc -l < "$SB/badlines.txt" | tr -d ' ')
assert_eq "append: a blank line always follows a marker line" "$BADN" "0"

# invalid input rejected without writing a byte
mkws wsval
PROJ2=$(proj_dir wsval)
cd "$PROJ2"
JF2="$ROOT/wsval/$(date +%F).md"
assert_file_absent "append: (setup) no journal yet for wsval" "$JF2"

OUT=$(printf '## fake header\nDECIDED: x\n' | "$BIN/bro-append.sh" --workspace wsval --thread t --topic top 2>&1); RC=$?
assert_exit "append: rejects a fake '## ' body line (exit 1)" "$RC" "1"
assert_contains "append: fake '## ' rejection names the offending line" "$OUT" "## "
assert_file_absent "append: fake '## ' rejection wrote zero bytes" "$JF2"

OUT=$(printf 'DECIDED no colon here\n' | "$BIN/bro-append.sh" --workspace wsval --thread t --topic top 2>&1); RC=$?
assert_exit "append: rejects a colonless marker (exit 1)" "$RC" "1"
assert_contains "append: colonless-marker rejection is precise" "$OUT" "missing its ':'"
assert_file_absent "append: colonless-marker rejection wrote zero bytes" "$JF2"

OUT=$(printf '' | "$BIN/bro-append.sh" --workspace wsval --thread t --topic top 2>&1); RC=$?
assert_exit "append: rejects an empty body (exit 1)" "$RC" "1"
assert_file_absent "append: empty-body rejection wrote zero bytes" "$JF2"

OUT=$("$BIN/bro-append.sh" --workspace wsval --thread 2>&1); RC=$?
assert_exit "append: a flag given with no value fails cleanly, not an unbound-variable crash" "$RC" "1"
assert_not_contains "append: no raw bash traceback on malformed flags" "$OUT" "unbound variable"

OUT=$(printf 'DECIDED: x\n' | "$BIN/bro-append.sh" --workspace doesnotexist999 --thread t --topic top 2>&1); RC=$?
assert_exit "append: rejects a nonexistent workspace (exit 1)" "$RC" "1"

# 20 parallel writers -> 20 intact sections, no interleaving
mkws wspar
PROJ3=$(proj_dir wspar)
cd "$PROJ3"
for i in $(seq 1 20); do
  ( printf 'DECIDED: parallel writer %d\n' "$i" | "$BIN/bro-append.sh" --workspace wspar --thread "t$i" --topic "topic $i" >/dev/null 2>&1 ) &
done
wait
JF3="$ROOT/wspar/$(date +%F).md"
SECN=$(grep -c '^## ' "$JF3")
assert_eq "append: 20 parallel writers -> 20 intact sections" "$SECN" "20"
MARKN=$(grep -c '^DECIDED:' "$JF3")
assert_eq "append: 20 parallel writers -> 20 intact markers" "$MARKN" "20"
HDRN=$(grep -c '^# bro' "$JF3")
assert_eq "append: header created exactly once under 20-way concurrency" "$HDRN" "1"
LOGN=$(wc -l < "$ROOT/wspar/.append-log" | tr -d ' ')
assert_eq "append: 20 parallel writers -> 20 append-log entries" "$LOGN" "20"
OVERLAP=$(awk -F'\t' '{print $4}' "$ROOT/wspar/.append-log" | sort -t'-' -k1,1n | awk -F'-' 'NR>1 && $1<=prev{bad=1} {prev=$2} END{print bad+0}')
assert_eq "append: append-log ranges from 20 parallel writers do not overlap" "$OVERLAP" "0"
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wspar >/dev/null
DCNT=$(grep -c '^### ' "$ROOT/wspar/decisions.md" 2>/dev/null || echo 0)
assert_eq "append: harvest picks up all 20 concurrently-written markers, none lost" "$DCNT" "20"

# regression: appending after an existing journal whose last line has NO
# trailing newline (any hand-edit, or any pre-bro-append.sh content) must
# not glue the new section onto the old line, and the logged/hashed range
# must start at the new content, not one line early. `wc -l` used to
# undercount PRE by one here, and the single separator '\n' both terminated
# the dangling old line AND was consumed as the blank-line separator --
# doing neither job fully.
mkws wsdangle
PROJd=$(proj_dir wsdangle)
JFD="$ROOT/wsdangle/$(date +%F).md"
printf '# bro — %s / wsdangle\n\n## 09:00 · t — topic\nTAIL: y' "$(date +%F)" > "$JFD"
cd "$PROJd"
printf 'DECIDED: appended after a dangling last line\n' | "$BIN/bro-append.sh" --workspace wsdangle --thread t --topic after >/dev/null
cd "$REPO_DIR"
OLDLINE=$(sed -n '4p' "$JFD")
assert_eq "dangling-line append: the pre-existing last line is untouched" "$OLDLINE" "TAIL: y"
BLANK=$(sed -n '5p' "$JFD")
assert_eq "dangling-line append: a real blank line now separates old content from the new section" "$BLANK" ""
NEWHDR=$(sed -n '6p' "$JFD")
assert_contains "dangling-line append: the new section header is NOT glued onto the old line" "$NEWHDR" "## "
LOGRANGE=$(awk -F'\t' '{print $4}' "$ROOT/wsdangle/.append-log" | tail -1)
assert_eq "dangling-line append: logged range starts at the new blank separator, not the old (unvalidated) line" "$LOGRANGE" "5-8"

# regression: an empty CLAUDE_SESSION_ID must not collapse .append-log's
# tab-separated fields. bash's `read` under IFS=$'\t' treats tab as IFS
# *whitespace* and collapses a run of them instead of emitting an empty
# field -- an unquoted empty session id shifts every later field left by
# one, and bro-stop-turnstile.sh parses this exact file the exact same way.
mkws wsnosid
PROJn=$(proj_dir wsnosid)
cd "$PROJn"
env -u CLAUDE_SESSION_ID "$BIN/bro-append.sh" --workspace wsnosid --thread t --topic nosid <<< 'DECIDED: no session id set' >/dev/null
cd "$REPO_DIR"
LOGLINE=$(tail -1 "$ROOT/wsnosid/.append-log")
assert_not_contains "no-session-id append: .append-log has no bare double-tab (empty field)" "$LOGLINE" "$(printf '\t\t')"
# parse it exactly the way bro-stop-turnstile.sh does: `read -r ... < file`
# under IFS=tab (bash collapses consecutive IFS-whitespace tabs instead of
# emitting an empty field, so a bare empty session id shifts every later
# field left by one)
PARSED_LOGF=$(printf '%s\n' "$LOGLINE" | { IFS=$'\t' read -r _ _ f _ _; printf '%s' "$f"; })
assert_eq "no-session-id append: read -r under IFS=tab parses the journal-basename field correctly" "$PARSED_LOGF" "$(date +%F).md"

# ===========================================================================
# 7. write guard
# ===========================================================================
echo "-- 7. write guard --"
new_sandbox
install_repo >/dev/null
mkws wsguard
JF="$ROOT/wsguard/$(date +%F).md"
mkdir -p "$ROOT/wsguard"
printf '# bro — %s / wsguard\n\n## 09:00 · t — topic\nDECIDED: x\n' "$(date +%F)" > "$JF"
printf '# wsguard — decisions\n\n> desc\n\n### d-abc123 (2026-01-01) [active]\nsomething\n' > "$ROOT/wsguard/decisions.md"

deny_write() { jq -n --arg fp "$1" '{tool_name:"Write", tool_input:{file_path:$fp, content:"x"}}' | "$BIN/bro-write-guard.sh"; }
deny_edit()  { jq -n --arg fp "$1" '{tool_name:"Edit", tool_input:{file_path:$fp, old_string:"a", new_string:"b"}}' | "$BIN/bro-write-guard.sh"; }
deny_bash()  { jq -n --arg cmd "$1" '{tool_name:"Bash", tool_input:{command:$cmd}}' | "$BIN/bro-write-guard.sh"; }

OUT=$(deny_write "$JF"); assert_contains "guard: denies direct Write on the shared journal" "$OUT" '"decision":"block"'
assert_contains "guard: Write denial teaches the exact bro-append.sh invocation" "$OUT" "bro-append.sh --workspace wsguard"
OUT=$(deny_edit "$JF"); assert_contains "guard: denies direct Edit on the shared journal" "$OUT" '"decision":"block"'
assert_contains "guard: Edit denial teaches bro-append.sh" "$OUT" "bro-append.sh --workspace wsguard"

OUT=$(deny_write "$ROOT/wsguard/_workspace.md"); assert_eq "guard: allows Write to _workspace.md" "$OUT" ""
OUT=$(deny_edit "$ROOT/wsguard/decisions.md"); assert_eq "guard: allows Edit (register status flip)" "$OUT" ""
OUT=$(deny_write "$SB/proj/wsguard/unrelated.txt"); assert_eq "guard: allows Write to an unrelated file" "$OUT" ""

OUT=$(deny_bash "echo 'DECIDED: x' >> ~/bro/wsguard/$(date +%F).md"); assert_contains "guard: denies a Bash >> redirect into the journal" "$OUT" '"decision":"block"'
assert_contains "guard: Bash redirect denial teaches bro-append.sh" "$OUT" "bro-append.sh"
OUT=$(deny_bash "cat >> ~/bro/wsguard/$(date +%F).md <<'EOF'
DECIDED: x
EOF"); assert_contains "guard: denies a Bash heredoc append into the journal" "$OUT" '"decision":"block"'
OUT=$(deny_bash "sed -i '' 's/x/y/' ~/bro/wsguard/$(date +%F).md"); assert_contains "guard: denies sed -i on the journal" "$OUT" '"decision":"block"'

OUT=$(deny_bash "cat ~/bro/wsguard/$(date +%F).md"); assert_eq "guard: allows a plain read (cat) of the journal" "$OUT" ""
OUT=$(deny_bash "grep DECIDED ~/bro/wsguard/$(date +%F).md"); assert_eq "guard: allows grep on the journal" "$OUT" ""
OUT=$(deny_bash "~/.claude/bro/bin/bro-harvest.sh --workspace wsguard"); assert_eq "guard: allows a harvest invocation" "$OUT" ""
OUT=$(deny_bash "~/.claude/bro/bin/bro-append.sh --workspace wsguard --thread t --topic top <<'EOF'
DECIDED: x
EOF"); assert_eq "guard: allows bro-append.sh's own invocation" "$OUT" ""
OUT=$(deny_bash "tee -a ~/bro/_rule-candidates.md <<< 'stuff'"); assert_eq "guard: allows tee to a register (not date-shaped)" "$OUT" ""
OUT=$(deny_bash "some-command > /dev/null 2>&1"); assert_eq "guard: /dev/null redirect near no journal path is allowed" "$OUT" ""

# regression: the Bash-branch heuristic matched ANY YYYY-MM-DD.md-shaped
# path with a write operator, with no requirement that it resolve under
# $ROOT -- unlike the Write/Edit branch above, which scopes to "$ROOT"/*.
# Any unrelated project's own dated .md file (changelog, log rotation, a
# daily note in a completely different repo) was denied as if it were a
# bro journal write.
OUT=$(deny_bash "echo 'release notes' >> ~/unrelated-project/CHANGELOG/$(date +%F).md"); assert_eq "guard: allows a write to an unrelated project's own dated .md file (outside \$ROOT)" "$OUT" ""
OUT=$(deny_bash "echo 'release notes' >> $SB/proj/unrelated/$(date +%F).md"); assert_eq "guard: allows a write to an unrelated dated .md file by absolute path (outside \$ROOT)" "$OUT" ""
# still denies the real thing, in both the ~/bro shorthand and $ROOT absolute forms
OUT=$(deny_bash "echo 'DECIDED: x' >> ~/bro/wsguard/$(date +%F).md"); assert_contains "guard: still denies the real journal via ~/bro shorthand" "$OUT" '"decision":"block"'
OUT=$(deny_bash "echo 'DECIDED: x' >> $ROOT/wsguard/$(date +%F).md"); assert_contains "guard: still denies the real journal via \$ROOT absolute path" "$OUT" '"decision":"block"'

# ===========================================================================
# 8. stop hook
# ===========================================================================
echo "-- 8. stop hook --"
new_sandbox
install_repo >/dev/null

# -- watchdog 1: session-start pending -> recovered, and watchdog 2: harvest not running --
mkws wswd
PROJ=$(proj_dir wswd)
SID1=$(next_sid)
mkdir -p "$HOME/.claude/bro/started"
echo pending > "$HOME/.claude/bro/started/$SID1"
OUT=$(hookjson "$PROJ" "$SID1" p1 Stop | "$BIN/bro-stop-turnstile.sh")
assert_contains "stop: watchdog 1 fires when session-start never finished" "$OUT" "session-start hook did not finish"
assert_contains "stop: watchdog 1 recovers the actual context" "$OUT" "workspace 'wswd'"
MARKVAL=$(cat "$HOME/.claude/bro/started/$SID1" 2>/dev/null)
assert_eq "stop: watchdog 1 flips the mark back to ok after recovering" "$MARKVAL" "ok"

SID2=$(next_sid)
echo ok > "$HOME/.claude/bro/started/$SID2"
OLD=$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null || date -d '20 minutes ago' +%Y%m%d%H%M.%S)
touch -t "$OLD" "$HOME/.claude/bro/started/$SID2"
rm -f "$ROOT/wswd/.harvest-stamp"
PROJ2=$(proj_dir wswd)
cd "$PROJ2"
printf 'DECIDED: watchdog2 filler\n' | "$BIN/bro-append.sh" --workspace wswd --thread t --topic wd2 >/dev/null
cd "$REPO_DIR"
OUT=$(hookjson "$PROJ2" "$SID2" p1 Stop | "$BIN/bro-stop-turnstile.sh")
assert_contains "stop: watchdog 2 fires when no harvest pass has completed since session start" "$OUT" "no harvest pass has completed"
assert_contains "stop: watchdog 2 tells the chat to run harvest itself" "$OUT" "bro-harvest.sh --workspace wswd"

# -- hash-gated lint: both directions --
mkws wshash
PROJ3=$(proj_dir wshash)
cd "$PROJ3"
printf 'DECIDED: chose A over B\n' | "$BIN/bro-append.sh" --workspace wshash --thread t --topic ok >/dev/null
cd "$REPO_DIR"
JF="$ROOT/wshash/$(date +%F).md"
SID3=$(next_sid)
OUT=$(hookjson "$PROJ3" "$SID3" p1 Stop | "$BIN/bro-stop-turnstile.sh")
assert_eq "stop: a fresh, valid journal (fully bro-append.sh-written) produces no block" "$OUT" ""

# inject an UNTRUSTED colonless-marker line directly, bypassing bro-append.sh
printf '\nDECIDED bad marker no colon\n' >> "$JF"
BADLN=$(grep -n 'DECIDED bad marker no colon' "$JF" | cut -d: -f1)
SID4=$(next_sid)
OUT=$(hookjson "$PROJ3" "$SID4" p1 Stop | "$BIN/bro-stop-turnstile.sh")
assert_contains "stop lint direction A: an UNTRUSTED malformed line gets full scrutiny and blocks" "$OUT" "marker-like line(s) without ':'"

# now forge an .append-log entry whose hash matches THAT SAME malformed range
. "$SCRIPTS_DIR/bro-lib.sh"
H=$(hash_range "$JF" "$BADLN" "$BADLN")
printf '%s\t%s\t%s\t%s-%s\t%s\n' "$(date '+%F %H:%M:%S')" "forged" "$(basename "$JF")" "$BADLN" "$BADLN" "$H" >> "$ROOT/wshash/.append-log"
SID5=$(next_sid)
OUT=$(hookjson "$PROJ3" "$SID5" p1 Stop | "$BIN/bro-stop-turnstile.sh")
assert_eq "stop lint direction B: the SAME malformed line, once its range is content-hash-trusted, is exempt" "$OUT" ""

# tamper with the trusted range's bytes -> hash no longer matches -> scrutiny restored
sed -i '' "${BADLN}s/.*/DECIDED bad marker STILL no colon but tampered/" "$JF"
SID6=$(next_sid)
OUT=$(hookjson "$PROJ3" "$SID6" p1 Stop | "$BIN/bro-stop-turnstile.sh")
assert_contains "stop lint: tampering a previously-trusted range's bytes restores full scrutiny" "$OUT" "marker-like line(s) without ':'"

# -- at most two blocks per prompt (one watchdog slot + one freshness/lint slot) --
mkws wsbudget
PROJb=$(proj_dir wsbudget)
SIDb=$(next_sid)
mkdir -p "$HOME/.claude/bro/started"
echo pending > "$HOME/.claude/bro/started/$SIDb"
IN_B=$(hookjson "$PROJb" "$SIDb" pbudget Stop)
OUT1=$(printf '%s' "$IN_B" | "$BIN/bro-stop-turnstile.sh")
assert_contains "stop budget: call 1 (same session+prompt) blocks via watchdog" "$OUT1" "session-start hook did not finish"
OUT2=$(printf '%s' "$IN_B" | "$BIN/bro-stop-turnstile.sh")
assert_contains "stop budget: call 2 (same session+prompt) blocks via freshness/lint (second slot)" "$OUT2" "no journal for today"
OUT3=$(printf '%s' "$IN_B" | "$BIN/bro-stop-turnstile.sh")
assert_eq "stop budget: call 3 (same session+prompt) is silent -- budget exhausted" "$OUT3" ""

# ===========================================================================
# 9. no-jq fallback
# ===========================================================================
echo "-- 9. no-jq fallback --"
# Build a jq-free PATH from symlinks to the real system binaries. This
# environment's interactive shell (zsh, per the harness) wraps `grep` in a
# function for its own purposes -- `command -v grep` there can resolve to
# that function, not /usr/bin/grep. A function is not affected by PATH, so
# link grep explicitly from /usr/bin rather than trusting a PATH lookup to
# find the real binary, and run everything through `env -i` (a genuinely
# empty environment) so no exported shell function can leak in either.
NOJQ_BIN=$(mktemp -d "${TMPDIR:-/tmp}/bro-regress-nojq-bin.XXXXXX")
ALL_SANDBOXES+=("$NOJQ_BIN")
for t in bash sh sed awk grep cat date mkdir rmdir find sort wc head tail tr \
         basename dirname cut mv cp rm stat mktemp touch sleep env ls \
         shasum sha256sum printf true false expr; do
  for d in /bin /usr/bin /sbin /usr/sbin; do
    if [ -x "$d/$t" ]; then ln -sf "$d/$t" "$NOJQ_BIN/$t"; break; fi
  done
done
ln -sf /usr/bin/grep "$NOJQ_BIN/grep"   # explicit, per the note above -- never rely on the loop's PATH search alone
if [ -x "$NOJQ_BIN/grep" ] && [ -x "$NOJQ_BIN/bash" ]; then
  pass "no-jq: jq-free PATH built ($(env -i PATH="$NOJQ_BIN" "$NOJQ_BIN/bash" -c 'command -v jq' 2>/dev/null && echo BAD || echo 'jq correctly absent'))"
else
  fail "no-jq: jq-free PATH built" "missing grep or bash symlink in $NOJQ_BIN"
fi

new_sandbox
install_repo >/dev/null   # the installer itself needs real jq -- install with the normal PATH first
mkws nojqws
NPROJ=$(proj_dir nojqws)

IN=$(hookjson "$NPROJ" "$(next_sid)" p1 SessionStart)
OUT=$(printf '%s' "$IN" | env -i PATH="$NOJQ_BIN" HOME="$HOME" "$NOJQ_BIN/bash" "$BIN/bro-session-start.sh")
assert_contains "no-jq: session-start sed-fallback still resolves the workspace" "$OUT" "workspace 'nojqws'"

FP="$ROOT/nojqws/$(date +%F).md"
IN=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$FP")
OUT=$(printf '%s' "$IN" | env -i PATH="$NOJQ_BIN" HOME="$HOME" "$NOJQ_BIN/bash" "$BIN/bro-write-guard.sh" 2>&1)
RC=$?
assert_exit "no-jq: write-guard denies via exit 2 (no jq JSON path)" "$RC" "2"
assert_contains "no-jq: write-guard denial still teaches bro-append.sh" "$OUT" "bro-append.sh"

IN=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/unrelated.txt","content":"x"}}' "$NPROJ")
OUT=$(printf '%s' "$IN" | env -i PATH="$NOJQ_BIN" HOME="$HOME" "$NOJQ_BIN/bash" "$BIN/bro-write-guard.sh")
RC=$?
assert_exit "no-jq: write-guard allows an unrelated file (exit 0)" "$RC" "0"
assert_eq "no-jq: write-guard allow produces no output" "$OUT" ""

IN=$(hookjson "$NPROJ" "$(next_sid)" p1 Stop)
OUT=$(printf '%s' "$IN" | env -i PATH="$NOJQ_BIN" HOME="$HOME" "$NOJQ_BIN/bash" "$BIN/bro-stop-turnstile.sh" 2>&1)
RC=$?
assert_exit "no-jq: stop hook blocks via exit 2 (no jq JSON path)" "$RC" "2"
assert_contains "no-jq: stop hook block text still intact without jq" "$OUT" "no journal for today"

cd "$NPROJ"
OUT=$(env -i PATH="$NOJQ_BIN" HOME="$HOME" PWD="$NPROJ" "$NOJQ_BIN/bash" -c "cd '$NPROJ' && printf 'DECIDED: no-jq append test\n' | '$BIN/bro-append.sh' --workspace nojqws --thread t --topic top")
cd "$REPO_DIR"
assert_contains "no-jq: bro-append.sh works end to end without jq" "$OUT" "wrote nojqws/"
assert_file_exists "no-jq: bro-append.sh actually wrote the journal" "$FP"

OUT=$(env -i PATH="$NOJQ_BIN" HOME="$HOME" "$NOJQ_BIN/bash" "$BIN/bro-harvest.sh" --workspace nojqws)
assert_contains "no-jq: bro-harvest.sh works end to end without jq" "$OUT" "+ decision"
NCNT=$(grep -c '^### ' "$ROOT/nojqws/decisions.md" 2>/dev/null || echo 0)
assert_eq "no-jq: harvested record actually landed in the register" "$NCNT" "1"

# ===========================================================================
echo ""
echo "==== bro regression suite: $PASS_N passed, $FAIL_N failed ===="
if [ "$FAIL_N" -gt 0 ]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
