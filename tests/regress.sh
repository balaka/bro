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
assert_contains "CLOSED: closed-reason text appended" "$FLIPPED" "— closed "
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

# regression (v3.8 §3, coordinator fix -- supersedes the pre-3.8 contract
# tested here before): a marker that is the literal last physical line of a
# journal, with NO trailing newline after it, must NOT be acted on in a
# pass that sees it in that state -- it may be bro-append.sh mid-write,
# caught between its own header write and its own body write, now that
# harvest runs after every response. It must become visible normally,
# complete, once it DOES end in '\n' -- exactly what bro-append.sh's own
# "repair a dangling last line" step guarantees on its very next write.
# (The underlying reason `awk 'END{print NR}'` and not `wc -l` computes
# TOTAL is unchanged and still load-bearing here -- `wc -l` would already
# undercount a dangling last line by one on its own, and this new
# dangling-line exclusion subtracts a further one on top of that count.)
mkws wseof
OPENE="$ROOT/wseof/open.md"
printf '# wseof — open items\n\n- [ ] t-fix00 · closing at EOF with no trailing newline — родился: 2026-09-19\n\n' > "$OPENE"
JEOF="$ROOT/wseof/$(date +%F).md"
printf '# bro — %s / wseof\n\n## 09:00 · t — topic\nCLOSED t-fix00: closing at EOF with no trailing newline' "$(date +%F)" > "$JEOF"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wseof --full >/dev/null
assert_contains "EOF marker: a CLOSED on the file's unterminated last line is NOT yet acted on" "$(grep -F 't-fix00' "$OPENE")" "- [ ] t-fix00"
assert_file_absent "EOF marker: not-yet-acted-on means no false CLOSE-MISS either" "$ROOT/wseof/.close-misses.log"
printf '\n' >> "$JEOF"   # the newline bro-append.sh's own repair step would add on its next write to this journal
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace wseof --full >/dev/null
assert_contains "EOF marker: once terminated with a newline, the same marker closes normally" "$(grep -F 't-fix00' "$OPENE")" "- [x] t-fix00"

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
# 10. marker recognition: dual-case RU, EN caps-only (v3.8 §1)
# ===========================================================================
echo "-- 10. marker recognition: dual-case RU, EN caps-only --"
new_sandbox
install_repo >/dev/null
mkws ws10
DATE=$(date +%F)
F="$ROOT/ws10/$DATE.md"
cat > "$F" <<EOF
# bro — $DATE / ws10

## 09:00 · t — bulleted rule
- Правило: файлы и журнал пишутся так, чтобы читалось через полгода без контекста

## 09:05 · t — capitalized decision
Решение: выбрали Sonnet для сборки 3.8

## 09:10 · t — non-markers
State: pending
Rule: x
решение: строчными не считается меткой
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws10 --full > "$SB/ws10-out.log" 2>&1
RCAND="$ROOT/_rule-candidates.md"
DEC10="$ROOT/ws10/decisions.md"
assert_contains "dual-case: bulleted 'Правило:' (Capitalized) becomes a rule candidate" "$(cat "$RCAND" 2>/dev/null)" "файлы и журнал пишутся так"
assert_contains "dual-case: 'Решение:' (Capitalized) becomes a decision" "$(cat "$DEC10" 2>/dev/null)" "выбрали Sonnet для сборки 3.8"
assert_not_contains "dual-case: 'State: pending' (EN Title-case) is not a marker" "$(cat "$DEC10" "$RCAND" 2>/dev/null)" "pending"
assert_not_contains "dual-case: 'Rule: x' (EN Title-case) creates no rule candidate" "$(cat "$RCAND" 2>/dev/null)" "Rule: x"
assert_not_contains "dual-case: 'решение:' (RU lowercase) is not a marker" "$(cat "$DEC10" 2>/dev/null)" "строчными не считается"
assert_file_absent "dual-case: none of the non-markers created a STATE snapshot" "$ROOT/_state.md"

# end-to-end: the Capitalized RU writing closes a tail exactly like CLOSED/ЗАКРЫТ
mkws ws10closed
PROJc=$(proj_dir ws10closed)
cd "$PROJc"
printf 'TAIL: dual-case close target\n' | "$BIN/bro-append.sh" --workspace ws10closed --thread t --topic seed >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws10closed >/dev/null
OPEN10="$ROOT/ws10closed/open.md"
TID10=$(grep -oE '^- \[ \] [a-z0-9-]+' "$OPEN10" | head -1 | awk '{print $4}')
cd "$PROJc"
printf 'Закрыт %s: closed via the Capitalized RU writing\n' "$TID10" | "$BIN/bro-append.sh" --workspace ws10closed --thread t --topic close >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws10closed >/dev/null
assert_contains "dual-case: 'Закрыт <id>:' (Capitalized) closes a tail same as CLOSED/ЗАКРЫТ" "$(grep -F "$TID10" "$OPEN10")" "- [x] $TID10"

# bro-append.sh's pre-write colon check recognizes the Capitalized RU writing too
mkws ws10val
PROJv=$(proj_dir ws10val)
cd "$PROJv"
OUT=$(printf 'Решение chose X without a colon\n' | "$BIN/bro-append.sh" --workspace ws10val --thread t --topic top 2>&1); RC=$?
cd "$REPO_DIR"
assert_exit "dual-case: bro-append.sh rejects a colonless Capitalized-RU marker (exit 1)" "$RC" "1"
assert_contains "dual-case: rejection names the colon problem" "$OUT" "missing its ':'"

# bro-stop-turnstile.sh's degraded fallback (bro-lib.sh missing) also uses
# the v3.8 keyword set for its colonless-marker lint, not the pre-3.8 list
mkws ws10nolib
PROJnl=$(proj_dir ws10nolib)
FNL="$ROOT/ws10nolib/$(date +%F).md"
printf '# bro — %s / ws10nolib\n\n## 09:00 · t — topic\nПравило без двоеточия тут\n' "$(date +%F)" > "$FNL"
mv "$BIN/bro-lib.sh" "$SB/bro-lib.sh.hidden"
IN=$(hookjson "$PROJnl" "$(next_sid)" p1 Stop)
OUT=$(printf '%s' "$IN" | "$BIN/bro-stop-turnstile.sh" 2>&1)
mv "$SB/bro-lib.sh.hidden" "$BIN/bro-lib.sh"
assert_contains "dual-case: degraded (no bro-lib.sh) fallback still catches a colonless Capitalized-RU marker" "$OUT" "marker-like line(s) without ':'"
assert_contains "dual-case: degraded fallback logs why it's degraded" "$(cat "$HOME/.claude/bro/health.log" 2>/dev/null)" "bro-lib.sh not found next to"

# ===========================================================================
# 11. near-marker counter (v3.8 §1)
# ===========================================================================
echo "-- 11. near-marker counter --"
new_sandbox
install_repo >/dev/null
mkws ws11
DATE=$(date +%F)
F="$ROOT/ws11/$DATE.md"
cat > "$F" <<EOF
# bro — $DATE / ws11

## 09:00 · t — near misses and one real marker
Решено: перешли на новый формат
Правила: два новых правила добавлены
DECIDED: настоящее решение, должно остаться меткой
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws11 --full > "$SB/ws11-out.log" 2>&1
DEC11="$ROOT/ws11/decisions.md"
assert_not_contains "near-marker: 'Решено:' (wrong grammatical form) is not harvested as a decision" "$(cat "$DEC11" 2>/dev/null)" "перешли на новый формат"
assert_not_contains "near-marker: 'Правила:' (plural, wrong form) creates no rule candidate" "$(cat "$ROOT/_rule-candidates.md" 2>/dev/null)" "два новых правила добавлены"
assert_contains "near-marker: a real 'DECIDED:' next to near-misses is still harvested normally" "$(cat "$DEC11" 2>/dev/null)" "настоящее решение"
assert_contains "near-marker: passive counter reports exactly 2 near-miss lines" "$(cat "$SB/ws11-out.log")" "2 near-marker line(s) not harvested"
HEALTH="$HOME/.claude/bro/health.log"
assert_file_exists "near-marker: health.log written" "$HEALTH"
HCNT11=$(grep -c 'near-marker line(s) not harvested' "$HEALTH" 2>/dev/null || echo 0)
assert_eq "near-marker: exactly one health.log line for this pass" "$HCNT11" "1"
assert_contains "near-marker: health.log names the workspace and count" "$(cat "$HEALTH")" "ws11: 2 near-marker line(s) not harvested"

# a clean pass (nothing near-missed) stays silent — same N=0 contract as the pre-existing glue counter
new_sandbox
install_repo >/dev/null
mkws ws11clean
F2="$ROOT/ws11clean/$DATE.md"
cat > "$F2" <<EOF
# bro — $DATE / ws11clean

## 09:00 · t — clean
DECIDED: nothing near this at all
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws11clean --full > "$SB/ws11clean-out.log" 2>&1
assert_not_contains "near-marker: N=0 case prints nothing about near-misses" "$(cat "$SB/ws11clean-out.log")" "near-marker line(s)"
assert_file_absent "near-marker: N=0 case writes no health.log" "$HOME/.claude/bro/health.log"

# dash-instead-of-colon and lowercase RU are also near-misses
new_sandbox
install_repo >/dev/null
mkws ws11dash
F3="$ROOT/ws11dash/$DATE.md"
cat > "$F3" <<EOF
# bro — $DATE / ws11dash

## 09:00 · t — dash and lowercase
Решение — сделали так, а не иначе
решение: то же самое, но строчными
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws11dash --full > "$SB/ws11dash-out.log" 2>&1
assert_contains "near-marker: dash-instead-of-colon and lowercase both counted (2)" "$(cat "$SB/ws11dash-out.log")" "2 near-marker line(s) not harvested"
assert_file_absent "near-marker: dash/lowercase lines create no decision record" "$ROOT/ws11dash/decisions.md"

# an immediate incremental (non-full) re-run must not re-report the same
# near-misses — same file-level stamp gate that already keeps a plain re-run
# from re-adding records (see section 3's "unchanged re-run adds no records")
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws11dash > "$SB/ws11dash-out2.log" 2>&1
HCNT11D=$(grep -c 'near-marker line(s) not harvested' "$HOME/.claude/bro/health.log" 2>/dev/null || echo 0)
assert_eq "near-marker: an immediate incremental re-run does not add a second health.log line" "$HCNT11D" "1"

# ===========================================================================
# 12. STATE snapshot (v3.8 §5)
# ===========================================================================
echo "-- 12. STATE snapshot --"
new_sandbox
install_repo >/dev/null
mkws ws12a
DATE=$(date +%F)
F12A="$ROOT/ws12a/$DATE.md"
cat > "$F12A" <<EOF
# bro — $DATE / ws12a

## 09:00 · t — earlier state
СОСТОЯНИЕ: подустал, третий час подряд
СОСТОЯНИЕ: хочет короткие ответы
СОСТОЯНИЕ: без иронии сегодня

## 09:05 · t — ignored non-marker
State: pending
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws12a --full >/dev/null 2>&1
SMD="$ROOT/_state.md"
assert_file_exists "STATE: _state.md created" "$SMD"
NSIDES=$(grep -c '^- ' "$SMD" 2>/dev/null || echo 0)
assert_eq "STATE: three СОСТОЯНИЕ: lines in one record become exactly 3 sides" "$NSIDES" "3"
assert_contains "STATE: side 1 text present" "$(cat "$SMD")" "подустал, третий час подряд"
assert_contains "STATE: side 3 text present" "$(cat "$SMD")" "без иронии сегодня"
assert_contains "STATE: header is the exact required title" "$(head -1 "$SMD")" "# Operator state"
assert_contains "STATE: ts comment present" "$(cat "$SMD")" "<!-- ts: "
assert_contains "STATE: do-not-edit-by-hand comment present" "$(cat "$SMD")" "written by bro-harvest; do not edit by hand"
assert_contains "STATE: recorded line names the project" "$(cat "$SMD")" "project ws12a"
assert_not_contains "STATE: 'State: pending' (EN Title-case) contributes no side" "$(cat "$SMD")" "pending"

# coordinator follow-up: 'Состояние:' (Capitalized) is deliberately NOT
# accepted (the real-data measurement showed 8 of 9 real "Состояние:" lines
# were an old habit of captioning test/build/release status, not the
# operator's own state) — and, just as deliberately, NOT counted as a
# near-miss either (same reasoning as EN Title-case: it would flood
# health.log on every status caption). Only ALL CAPS (СОСТОЯНИЕ/STATE) works.
new_sandbox
install_repo >/dev/null
mkws ws12b
F12B="$ROOT/ws12b/$DATE.md"
cat > "$F12B" <<EOF
# bro — $DATE / ws12b

## 10:00 · t — capitalized, must be ignored
Состояние: 282 vitest, всё зелёное

## 10:05 · t — plural, must also be ignored
Состояния: пустое поле, Step 1 of 2
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws12b --full > "$SB/ws12b-out.log" 2>&1
assert_file_absent "STATE: 'Состояние:' (Capitalized RU) creates no snapshot at all" "$ROOT/_state.md"
assert_not_contains "STATE: 'Состояние:' is not even counted as a near-miss" "$(cat "$SB/ws12b-out.log")" "near-marker line(s)"
assert_file_absent "STATE: 'Состояние:'/'Состояния:' write no health.log near-marker line" "$HOME/.claude/bro/health.log"

# newer wins across workspaces; older never regresses the current snapshot
new_sandbox
install_repo >/dev/null
mkws wsold
mkws wsnew
YEST=$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)
FOLD="$ROOT/wsold/$YEST.md"
cat > "$FOLD" <<EOF
# bro — $YEST / wsold

## 08:00 · t — yesterday, older
STATE: yesterday state, must lose to today
EOF
FNEW="$ROOT/wsnew/$DATE.md"
cat > "$FNEW" <<EOF
# bro — $DATE / wsnew

## 09:00 · t — today, newer
STATE: today state, must win
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --all --full >/dev/null 2>&1
assert_contains "STATE: the newer (today) record wins the snapshot" "$(cat "$ROOT/_state.md")" "today state, must win"
assert_not_contains "STATE: the older (yesterday) record does not appear" "$(cat "$ROOT/_state.md")" "yesterday state"

# repeating the --full pass over BOTH again must still not regress
"$BIN/bro-harvest.sh" --root "$ROOT" --all --full >/dev/null 2>&1
assert_contains "STATE: a repeated --all --full pass over older+newer still keeps the newer snapshot" "$(cat "$ROOT/_state.md")" "today state, must win"

# coordinator follow-up: a busy _state.md lock must not lose the snapshot —
# the journal line that produced it is already past FROM by the time
# harvest gets here, so without this a later pass would never see it again.
# It must land in $ROOT/.state-pending instead, and the NEXT pass (once the
# lock is free) must write it into _state.md from there.
new_sandbox
install_repo >/dev/null
mkws ws12pending
FPEND="$ROOT/ws12pending/$DATE.md"
cat > "$FPEND" <<EOF
# bro — $DATE / ws12pending

## 11:00 · t — pending test
STATE: candidate that must survive a busy lock
EOF
mkdir -p "$ROOT/_state.md.lock"   # simulate another writer already holding the lock
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws12pending --full >/dev/null 2>&1
assert_file_absent "STATE pending: busy lock means no _state.md yet" "$ROOT/_state.md"
assert_file_exists "STATE pending: candidate lands in .state-pending instead of being lost" "$ROOT/.state-pending"
assert_contains "STATE pending: .state-pending carries the actual side text" "$(cat "$ROOT/.state-pending")" "candidate that must survive a busy lock"
rmdir "$ROOT/_state.md.lock"   # the other writer is done — lock is free again
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws12pending >/dev/null 2>&1
assert_contains "STATE pending: the next pass writes the pending candidate into _state.md" "$(cat "$ROOT/_state.md" 2>/dev/null)" "candidate that must survive a busy lock"
assert_file_absent "STATE pending: .state-pending is cleaned up once written" "$ROOT/.state-pending"

# ===========================================================================
# 13. INSIGHT registry (v3.8 §6)
# ===========================================================================
echo "-- 13. INSIGHT registry --"
new_sandbox
install_repo >/dev/null
mkws ws13
DATE=$(date +%F)
F13="$ROOT/ws13/$DATE.md"
cat > "$F13" <<EOF
# bro — $DATE / ws13

## 09:00 · t — the real insight
ИНСАЙТ: маркетплейс модулей для ProductOS — отдельная идея, не путать с правилом

## 09:05 · t — coordinator follow-up: Capitalized and plural must be ignored entirely
Инсайт: golden-вопросы работают как эталонные фразы, стоит применить и здесь
Инсайты: два инсайта сразу, тоже должно игнорироваться
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws13 --full > "$SB/ws13-out.log" 2>&1
INS13="$ROOT/ws13/insights.md"
assert_file_exists "INSIGHT: insights.md created" "$INS13"
assert_contains "INSIGHT: 'ИНСАЙТ:' (ALL CAPS) harvested with an i-xxxxxx id" "$(cat "$INS13")" "маркетплейс модулей"
assert_contains "INSIGHT: line shape matches vocab.md's own pattern (id · body — from: date)" "$(grep 'маркетплейс' "$INS13")" "— from: $DATE"
assert_contains "INSIGHT: register header matches the ensure_register shape" "$(sed -n '1p' "$INS13")" "# ws13 — insights"
IDCNT13=$(grep -c '^- \*\*i-' "$INS13")
assert_eq "INSIGHT: exactly one entry — only the ALL-CAPS line counts" "$IDCNT13" "1"
# coordinator follow-up: 'Инсайт:'/'Инсайты:' (Capitalized RU) are deliberately
# NOT accepted (same real-data reasoning as СОСТОЯНИЕ) and NOT near-misses either
assert_not_contains "INSIGHT: 'Инсайт:' (Capitalized) is not harvested" "$(cat "$INS13")" "golden-вопросы работают"
assert_not_contains "INSIGHT: 'Инсайт:'/'Инсайты:' are not counted as near-misses" "$(cat "$SB/ws13-out.log")" "near-marker line(s)"
assert_file_absent "INSIGHT: 'Инсайт:'/'Инсайты:' write no health.log near-marker line" "$HOME/.claude/bro/health.log"

# re-harvest (--full) does not duplicate
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws13 --full >/dev/null 2>&1
LCNT13=$(grep -c '^- \*\*i-' "$INS13")
assert_eq "INSIGHT: a repeated --full pass does not duplicate entries" "$LCNT13" "1"

# ===========================================================================
# 14. reviewer #1 fixes (v3.8, coordinator follow-up round 2)
# ===========================================================================
echo "-- 14. reviewer fixes: epoch_of/pending/copy-under-lock/suffix/bullet/bold/utf8/notime --"

# §1: epoch_of() must not depend on the wall-clock second it happens to run at
new_sandbox
install_repo >/dev/null
. "$SCRIPTS_DIR/bro-lib.sh"
E1=$(epoch_of "2026-09-21" "14:32")
sleep 1.2
E2=$(epoch_of "2026-09-21" "14:32")
assert_eq "§1 epoch_of: two calls >1s apart for the identical date+time give the identical number" "$E2" "$E1"

# §4: a journal filename with a topic suffix (real example in this
# operator's store: cowork/2026-04-22-offerings-banner.md) must be picked
# up at all, and a STATE marker inside one must get a clean YYYY-MM-DD date
new_sandbox
install_repo >/dev/null
mkws ws14suffix
DATE=$(date +%F)
FSUF="$ROOT/ws14suffix/${DATE}-topic-suffix.md"
cat > "$FSUF" <<EOF
# bro — $DATE / ws14suffix

## 09:00 · t — suffixed filename
DECIDED: harvested even though the filename has a topic suffix
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws14suffix --full > "$SB/ws14suffix-out.log" 2>&1
assert_contains "§4 suffixed filename: a YYYY-MM-DD-topic.md journal is found at all" "$(cat "$SB/ws14suffix-out.log")" "1 journal(s) to read"
assert_contains "§4 suffixed filename: its marker is harvested" "$(cat "$ROOT/ws14suffix/decisions.md" 2>/dev/null)" "harvested even though the filename has a topic suffix"

mkws ws14suffixstate
FSUFS="$ROOT/ws14suffixstate/${DATE}-state-test.md"
cat > "$FSUFS" <<EOF
# bro — $DATE / ws14suffixstate

## 09:30 · t — suffixed filename with STATE
STATE: suffixed filename state must still get a clean date
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws14suffixstate --full >/dev/null 2>&1
TSLINE=$(grep '<!-- ts:' "$ROOT/_state.md" 2>/dev/null)
assert_contains "§4 suffixed filename: STATE snapshot's date is the clean YYYY-MM-DD" "$TSLINE" " $DATE 09:30 -->"
assert_not_contains "§4 suffixed filename: ts comment does NOT carry the filename's own topic slug" "$TSLINE" "state-test"

# §5: MRE_NOCOLON must allow the same optional "- " bullet MRE itself does
new_sandbox
install_repo >/dev/null
mkws ws14bullet
PROJb14=$(proj_dir ws14bullet)
cd "$PROJb14"
OUT=$(printf -- '- Правило без двоеточия здесь\n' | "$BIN/bro-append.sh" --workspace ws14bullet --thread t --topic top 2>&1); RC=$?
cd "$REPO_DIR"
assert_exit "§5 bulleted colonless marker: bro-append.sh rejects it too (exit 1)" "$RC" "1"
assert_contains "§5 bulleted colonless marker: rejection names the missing colon, not silently accepted" "$OUT" "missing its ':'"

# §6: INSIGHT's own bold body text must survive — only the KEYWORD's own **
# wrapping is stripped, never bold the operator wrote in the body
new_sandbox
install_repo >/dev/null
mkws ws14bold
DATE=$(date +%F)
FBOLD="$ROOT/ws14bold/$DATE.md"
cat > "$FBOLD" <<EOF
# bro — $DATE / ws14bold

## 09:00 · t — bold body must survive
ИНСАЙТ: **вывод** — пояснение
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws14bold --full >/dev/null 2>&1
assert_contains "§6 INSIGHT bold: ** around 'вывод' in the body survives into insights.md" "$(cat "$ROOT/ws14bold/insights.md" 2>/dev/null)" "**вывод** — пояснение"

# §7: a near-marker example containing Cyrillic text must not corrupt
# health.log — the byte-safe cut must never land mid-character
new_sandbox
install_repo >/dev/null
mkws ws14utf8
DATE=$(date +%F)
FUTF="$ROOT/ws14utf8/$DATE.md"
cat > "$FUTF" <<EOF
# bro — $DATE / ws14utf8

## 09:00 · t — near-miss with long cyrillic text straddling the 60-byte cut
Решено: этот текст специально длиннее шестидесяти байт, чтобы обрезка попала точно в середину кириллической буквы где-нибудь здесь
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws14utf8 --full >/dev/null 2>&1
HEALTH="$HOME/.claude/bro/health.log"
assert_file_exists "§7 UTF-8 safe cut: health.log written for the cyrillic near-miss" "$HEALTH"
if iconv -f UTF-8 -t UTF-8 < "$HEALTH" > /dev/null 2>&1; then
  pass "§7 UTF-8 safe cut: health.log round-trips through iconv -f UTF-8 -t UTF-8 cleanly"
else
  fail "§7 UTF-8 safe cut: health.log round-trips through iconv -f UTF-8 -t UTF-8 cleanly" "iconv rejected the file — the truncated example likely cut mid-character"
fi

# §8: a STATE marker under a record with no readable 'HH:MM · …' section
# header must not vanish silently — same passive health.log line as the
# other counters
new_sandbox
install_repo >/dev/null
mkws ws14notime
DATE=$(date +%F)
FNT="$ROOT/ws14notime/$DATE.md"
cat > "$FNT" <<EOF
# bro — $DATE / ws14notime
STATE: no section header above this line at all
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws14notime --full > "$SB/ws14notime-out.log" 2>&1
assert_file_absent "§8 STATE no-time: no snapshot written — nothing to date it with" "$ROOT/_state.md"
assert_contains "§8 STATE no-time: passive counter reports the skip" "$(cat "$SB/ws14notime-out.log")" "STATE marker(s) skipped"
assert_contains "§8 STATE no-time: health.log records it too" "$(cat "$HOME/.claude/bro/health.log" 2>/dev/null)" "STATE marker(s) skipped"

# ===========================================================================
# 15. v3.8.1 — glued-duplicate COLLISION fix (coordinator, real incident)
# ===========================================================================
echo "-- 15. glued-duplicate COLLISION fix (v3.8.1) --"

# (a) a register "collected by the old version": a suffixed record with a
# long GLUED body under source S; the bare base id is taken by an
# unrelated decision; a journal line with the SAME explicit id and the
# SAME source, whose body is the START of the glued one -- --full must
# add NO new record, and must say so.
new_sandbox
install_repo >/dev/null
mkws ws15old
DATE=$(date +%F)
DEC15="$ROOT/ws15old/decisions.md"
cat > "$DEC15" <<EOF
# ws15old — decisions

> Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать.

### d-dup001 (2026-01-01) [active]
an unrelated older decision under the bare base id
— родилось: 2026-01-01 · «old unrelated»

### d-dup001x5030 (2026-01-01) [active]
chose Postgres over Mongo because it handles JSON natively and the team already knows it well, this glued body continues into unrelated prose that a pre-3.7 harvest pass stitched on by accident
— родилось: $DATE · «Evening S»

EOF
F15A="$ROOT/ws15old/$DATE.md"
cat > "$F15A" <<EOF
# bro — $DATE / ws15old

## Evening S
РЕШЕНИЕ d-dup001: chose Postgres over Mongo because it handles JSON natively and the team already knows it well
EOF
CNT15A_BEFORE=$(grep -c '^### ' "$DEC15")
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws15old --full > "$SB/ws15old-out.log" 2>&1
CNT15A_AFTER=$(grep -c '^### ' "$DEC15")
assert_eq "(a) old-glued-duplicate: --full adds NO new record" "$CNT15A_AFTER" "$CNT15A_BEFORE"
assert_contains "(a) old-glued-duplicate: reports '= already present as' the old suffixed id" "$(cat "$SB/ws15old-out.log")" "= already present as d-dup001x5030"

# (c, part 1) --full a second time in a row: still nothing added
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws15old --full >/dev/null 2>&1
CNT15A_TWICE=$(grep -c '^### ' "$DEC15")
assert_eq "(c) old-glued-duplicate: a second --full in a row still adds nothing" "$CNT15A_TWICE" "$CNT15A_BEFORE"

# (b) two GENUINELY different decisions given the SAME explicit id in ONE
# journal record -- different beginnings, no prefix relationship -- both
# must land as separate records, nothing lost.
new_sandbox
install_repo >/dev/null
mkws ws15both
DATE=$(date +%F)
F15B="$ROOT/ws15both/$DATE.md"
cat > "$F15B" <<EOF
# bro — $DATE / ws15both

## 09:00 · t — both real
РЕШЕНИЕ d-samenum: chose the blue color scheme for the landing page header
РЕШЕНИЕ d-samenum: switched the database backend from MySQL to Postgres entirely
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws15both --full > "$SB/ws15both-out.log" 2>&1
DEC15B="$ROOT/ws15both/decisions.md"
assert_contains "(b) two real collisions: the first decision lands" "$(cat "$DEC15B")" "chose the blue color scheme"
assert_contains "(b) two real collisions: the second (genuinely different) decision ALSO lands" "$(cat "$DEC15B")" "switched the database backend from MySQL to Postgres"
CNT15B=$(grep -c '^### ' "$DEC15B")
assert_eq "(b) two real collisions: exactly 2 separate records, nothing merged or lost" "$CNT15B" "2"
assert_not_contains "(b) two real collisions: neither is mistaken for 'already present'" "$(cat "$SB/ws15both-out.log")" "already present"

# (c, part 2) --full a second time over the two-real-collisions case: still exactly 2
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws15both --full >/dev/null 2>&1
CNT15B_TWICE=$(grep -c '^### ' "$DEC15B")
assert_eq "(c) two real collisions: a second --full in a row still leaves exactly 2 records" "$CNT15B_TWICE" "2"

# ===========================================================================
# 16. English rename (v3.9 §1-§3): OPEN/ДЕЛО marker, English storage
#     strings, bilingual reads
# ===========================================================================
echo "-- 16. English rename: OPEN/ДЕЛО marker, English writes, bilingual reads --"

# marker_type() unit-level: all five open-item spellings fold to the one
# canonical OPEN token (was TAIL pre-3.9); an unrecognized word returns 1
new_sandbox
install_repo >/dev/null
. "$SCRIPTS_DIR/bro-lib.sh"
for kw in OPEN ДЕЛО TAIL ХВОСТ Хвост; do
  GOT=$(marker_type "$kw")
  assert_eq "marker_type: '$kw' folds to the canonical OPEN token" "$GOT" "OPEN"
done
marker_type NOTAMARKER >/dev/null 2>&1
assert_eq "marker_type: an unrecognized word returns exit 1" "$?" "1"

# end-to-end: OPEN: (new canonical EN spelling) is harvested into open.md,
# still with a t- id (the id prefix is unchanged by the rename)
new_sandbox
install_repo >/dev/null
mkws ws16open
PROJ16=$(proj_dir ws16open)
cd "$PROJ16"
printf 'OPEN: something new to follow up on\n' | "$BIN/bro-append.sh" --workspace ws16open --thread t --topic seed >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16open >/dev/null
OPEN16="$ROOT/ws16open/open.md"
assert_contains "OPEN: harvested into open.md" "$(cat "$OPEN16" 2>/dev/null)" "something new to follow up on"
TID16=$(grep -oE '^- \[ \] t-[a-f0-9]+' "$OPEN16" | head -1 | awk '{print $3}')
if [ -n "$TID16" ]; then pass "OPEN: id still uses the t- prefix"; else fail "OPEN: id still uses the t- prefix" "no t-* id found in $OPEN16"; fi
IDX16A=$(cat "$ROOT/INDEX.md" 2>/dev/null)
assert_contains "INDEX.md: column header says 'open items', not 'open tails'" "$IDX16A" "open items"
assert_not_contains "INDEX.md: no more 'open tails' column header" "$IDX16A" "open tails"
assert_contains "INDEX.md: empty Reviews-due case uses the new English text" "$IDX16A" "_(none — the next review dates are inside _principles.md)_"

# end-to-end: ДЕЛО: (new RU spelling, ALL CAPS only) is harvested the same way
new_sandbox
install_repo >/dev/null
mkws ws16delo
DATE=$(date +%F)
F16D="$ROOT/ws16delo/$DATE.md"
cat > "$F16D" <<EOF
# bro — $DATE / ws16delo

## 09:00 · t — ДЕЛО marker
ДЕЛО: новое незакрытое дело оператора
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16delo --full > "$SB/ws16delo-out.log" 2>&1
OPEN16D="$ROOT/ws16delo/open.md"
assert_contains "ДЕЛО: (ALL CAPS RU) harvested into open.md" "$(cat "$OPEN16D" 2>/dev/null)" "новое незакрытое дело оператора"

# "Дело:" (Capitalized RU) is NOT a marker — same treatment as "Состояние:"/
# "Инсайт:" — and, by the same design choice, not even a near-miss either
new_sandbox
install_repo >/dev/null
mkws ws16delocap
F16DC="$ROOT/ws16delocap/$DATE.md"
cat > "$F16DC" <<EOF
# bro — $DATE / ws16delocap

## 09:00 · t — capitalized Дело must be ignored
Дело: обычная фраза оператора, не метка
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16delocap --full > "$SB/ws16delocap-out.log" 2>&1
assert_file_absent "'Дело:' (Capitalized) creates no open.md at all" "$ROOT/ws16delocap/open.md"
assert_not_contains "'Дело:' is not counted as a near-miss either (same design as Состояние:/Инсайт:)" "$(cat "$SB/ws16delocap-out.log")" "near-marker line(s)"

# old spellings TAIL / ХВОСТ / Хвост still land in open.md exactly like OPEN
new_sandbox
install_repo >/dev/null
mkws ws16old
DATE=$(date +%F)
F16O="$ROOT/ws16old/$DATE.md"
cat > "$F16O" <<EOF
# bro — $DATE / ws16old

## 09:00 · t — old EN spelling
TAIL: still read the old EN way

## 09:05 · t — old RU ALL CAPS
ХВОСТ: всё ещё читается заглавными

## 09:10 · t — old RU Capitalized
Хвост: всё ещё читается с большой буквы
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16old --full > "$SB/ws16old-out.log" 2>&1
OPEN16O="$ROOT/ws16old/open.md"
assert_contains "old TAIL: still harvested" "$(cat "$OPEN16O" 2>/dev/null)" "still read the old EN way"
assert_contains "old ХВОСТ: (ALL CAPS) still harvested" "$(cat "$OPEN16O" 2>/dev/null)" "всё ещё читается заглавными"
assert_contains "old Хвост: (Capitalized) still harvested" "$(cat "$OPEN16O" 2>/dev/null)" "всё ещё читается с большой буквы"
OCNT16=$(grep -c '^- \[ \] t-' "$OPEN16O")
assert_eq "old TAIL/ХВОСТ/Хвост: three lines -> three distinct open items" "$OCNT16" "3"
assert_contains "new open item uses the English '— from: ' signature" "$(grep 'still read the old EN way' "$OPEN16O")" "— from: "
assert_not_contains "new open item does NOT use the old RU '— родился: ' signature" "$(grep 'still read the old EN way' "$OPEN16O")" "родился"

# new records in every register use "— from: ", never the old RU signatures
new_sandbox
install_repo >/dev/null
mkws ws16from
DATE=$(date +%F)
F16F="$ROOT/ws16from/$DATE.md"
cat > "$F16F" <<EOF
# bro — $DATE / ws16from

## 09:00 · t — from signature
DECIDED: chose the English "from" signature everywhere
TERM: fromterm - a term to check the signature on
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16from --full >/dev/null 2>&1
assert_contains "decisions.md: new record uses '— from: '" "$(cat "$ROOT/ws16from/decisions.md")" "— from: $DATE"
assert_not_contains "decisions.md: no old '— родилось: ' signature written" "$(cat "$ROOT/ws16from/decisions.md")" "родилось"
assert_contains "vocab.md: new record uses '— from: '" "$(cat "$ROOT/ws16from/vocab.md")" "— from: $DATE"
assert_contains "decisions.md: header/description are the new English text" "$(sed -n '1,4p' "$ROOT/ws16from/decisions.md")" "Filled automatically from the daily journals"

# CLOSED now appends the English "closed" text, not the old RU "закрыт"
new_sandbox
install_repo >/dev/null
mkws ws16closed
PROJ16c=$(proj_dir ws16closed)
cd "$PROJ16c"
printf 'OPEN: to be closed in English\n' | "$BIN/bro-append.sh" --workspace ws16closed --thread t --topic seed >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16closed >/dev/null
OPEN16C="$ROOT/ws16closed/open.md"
TID16C=$(grep -oE '^- \[ \] [a-z0-9-]+' "$OPEN16C" | head -1 | awk '{print $4}')
cd "$PROJ16c"
printf 'CLOSED %s: closed it, English text now\n' "$TID16C" | "$BIN/bro-append.sh" --workspace ws16closed --thread t --topic close >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16closed >/dev/null
CLOSEDLINE16=$(grep -F "$TID16C" "$OPEN16C")
assert_contains "CLOSED write uses the English '— closed ' text" "$CLOSEDLINE16" "— closed "
assert_not_contains "CLOSED write no longer uses the old RU '— закрыт ' text" "$CLOSEDLINE16" "закрыт"

# dash-instead-of-colon near-misses now also cover OPEN/ДЕЛО
new_sandbox
install_repo >/dev/null
mkws ws16dash
DATE=$(date +%F)
F16DASH="$ROOT/ws16dash/$DATE.md"
cat > "$F16DASH" <<EOF
# bro — $DATE / ws16dash

## 09:00 · t — dash instead of colon
OPEN — dash instead of colon, EN
ДЕЛО — тире вместо двоеточия, RU
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16dash --full > "$SB/ws16dash-out.log" 2>&1
assert_contains "near-marker: 'OPEN —'/'ДЕЛО —' (dash instead of colon) both counted (2)" "$(cat "$SB/ws16dash-out.log")" "2 near-marker line(s) not harvested"
assert_file_absent "near-marker: dash lines create no open.md record" "$ROOT/ws16dash/open.md"

# --- a registry with the OLD Russian signatures still parses: 3.8.1 glued-
# dedup, CLOSED, and a repeated --full all keep working on a register that
# was never translated (scripts/bro-translate-registers.sh not run) ---
new_sandbox
install_repo >/dev/null
mkws ws16legacy
DATE=$(date +%F)

# (a) open.md: a glued pre-3.7-style record under a suffixed id, plus an
# unrelated bare-id record, both with the old "— родился: " signature —
# same shape as section 15(a) above, but for the oneline (open.md) form,
# which section 15 does not cover.
OPEN16L="$ROOT/ws16legacy/open.md"
cat > "$OPEN16L" <<EOF
# ws16legacy — open items

> Хвосты и открытые вопросы. Закрытие — маркером CLOSED:/ЗАКРЫТ: в дневнике (жатва проставляет [x]), не руками. Жатва закрытые не переоткрывает.

- [ ] t-legacy1 · an unrelated older open item under the bare base id — родился: 2026-01-01

- [ ] t-legacy1x9999 · an old open item, body continues glued on from a pre-3.7 harvest pass here — родился: $DATE · «Evening L»

- [ ] t-legacy3 · a plain old open item waiting to be closed — родился: 2026-01-02

EOF
F16L="$ROOT/ws16legacy/$DATE.md"
cat > "$F16L" <<EOF
# bro — $DATE / ws16legacy

## Evening L
ХВОСТ t-legacy1: an old open item, body continues glued on from a pre-3.7 harvest pass
CLOSED t-legacy3: closing a plain legacy item, the new text should be English
EOF
OPENCNT16L_BEFORE=$(grep -c '^- \[' "$OPEN16L")
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16legacy --full > "$SB/ws16legacy-out.log" 2>&1
OPENCNT16L_AFTER=$(grep -c '^- \[' "$OPEN16L")
assert_eq "legacy RU signature: 3.8.1 glued-dedup over an old '— родился: ' record adds no new open item" "$OPENCNT16L_AFTER" "$OPENCNT16L_BEFORE"
assert_contains "legacy RU signature: dedup reports the old record as already present" "$(cat "$SB/ws16legacy-out.log")" "already present as t-legacy1x9999"

CLOSEDLINE16L=$(grep -F "t-legacy3" "$OPEN16L")
assert_contains "legacy RU signature: CLOSED still finds a bare old-signature item and flips its checkbox" "$CLOSEDLINE16L" "- [x] t-legacy3"
assert_contains "legacy RU signature: the appended closing text is the new English 'closed'" "$CLOSEDLINE16L" "— closed $DATE:"
assert_contains "legacy RU signature: the item's original '— родился: ' text is preserved, not rewritten" "$CLOSEDLINE16L" "— родился: 2026-01-02"
assert_file_absent "legacy RU signature: closing a real id produces no CLOSE-MISS" "$ROOT/ws16legacy/.close-misses.log"

# repeated --full: still no duplicates anywhere
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws16legacy --full >/dev/null 2>&1
OPENCNT16L_TWICE=$(grep -c '^- \[' "$OPEN16L")
assert_eq "legacy RU signature: a second --full in a row still adds nothing to open.md" "$OPENCNT16L_TWICE" "$OPENCNT16L_BEFORE"

# --- principles: review-date parsing understands both the RU field names
# and the EN ones (§3); a repository INDEX.md never carries Cyrillic
# service text regardless of which language _principles.md is written in ---
new_sandbox
install_repo >/dev/null
mkws ws16princ
PASTDATE="2020-01-01"
cat > "$ROOT/_principles.md" <<EOF
# principles

### 1. english-fielded principle
**Category:** speech
**Rule:** say it plainly
**Origin:** 2026-01-01
**Enforcement:** none yet
**Bounds:** —
**Review:** $PASTDATE

### 2. russian-fielded principle
**Категория:** речь
**Правило:** говори по делу
**Родилось:** 2026-01-01
**Исполнение:** пока нет
**Границы:** —
**Пересмотр:** $PASTDATE
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --all --full >/dev/null 2>&1
IDX16P="$ROOT/INDEX.md"
assert_contains "INDEX.md: an English-fielded principle ('**Review:**') is listed as due" "$(cat "$IDX16P")" "english-fielded principle"
assert_contains "INDEX.md: a Russian-fielded principle ('**Пересмотр:**') is still listed as due too" "$(cat "$IDX16P")" "russian-fielded principle"
# NB: NOT a plain `grep -c '[А-Яа-яЁё]'` -- under the unset/"C" locale this
# suite runs under, this system's BSD grep (2.6.0-FreeBSD) mis-widens that
# multi-byte bracket range and also matches the em-dash/arrow bytes (UTF-8
# 0xE2 0x80/0x86 ...) this very file's own English text legitimately uses
# ("— was due", "→ push"), turning a locale artifact into a false failure
# (confirmed live: 0 real Cyrillic bytes, 4 lines reported under plain
# LC_ALL=C; forcing LC_ALL=en_US.UTF-8 also fixes it, but that assumes the
# locale is installed). Matching the raw UTF-8 lead byte of the Cyrillic
# block (0xD0/0xD1) under an explicit C locale sidesteps the bracket-range
# bug entirely and needs no UTF-8 locale installed -- same byte-precise
# discipline bro-lib.sh's own utf8_trunc() already uses for the identical
# BSD-userland reason.
CYR_IN_INDEX=$(LC_ALL=C grep -c $'[\xd0\xd1]' "$IDX16P" 2>/dev/null)
[ -n "$CYR_IN_INDEX" ] || CYR_IN_INDEX=0
assert_eq "INDEX.md: no Cyrillic characters anywhere in the generated file" "$CYR_IN_INDEX" "0"

# ===========================================================================
# 17. coordinator fixes after the 3.9 review (two rounds): EN keywords
#     (CLOSED included) accept exactly ONE optional token, but only an id
#     (with a digit, or bro's own 6-hex-char auto id) or a parenthetical
#     note — never an ordinary word; find_glued_dup_oneline() cuts
#     body/source at the SAME point
# ===========================================================================
echo "-- 17. coordinator fixes: EN restricted token, dedup same-cut-point --"

# marker recognition, round 2: real audit numbers -- 117x "DECIDED d-xxx:",
# 52x "TAIL t-xxx:", 9x a parenthetical note -- all real; "follow-ups",
# "to-do", "QUESTIONS", "ISSUES", "FACTOR" -- never real. RU keywords are
# unaffected: any single word, as always.
new_sandbox
install_repo >/dev/null
mkws ws17mre
DATE=$(date +%F)
F17MRE="$ROOT/ws17mre/$DATE.md"
cat > "$F17MRE" <<EOF
# bro — $DATE / ws17mre

## 09:00 · t — ordinary EN prose must still be rejected
OPEN QUESTIONS: unresolved topics for the retro
OPEN ISSUES: a list, not a single open item
OPEN follow-ups: two hyphenated words, not an id
OPEN to-do: hyphenated word with no digit in it
DECIDED FACTOR: not a real decision, just a heading

## 09:05 · t — real EN markers, no token at all
OPEN: a real open item, no word before the colon
DECIDED: a real decision, no word before the colon

## 09:10 · t — real EN markers, an operator-typed id (contains a digit)
DECIDED d-0908-26: the record's own number, typed by the chat
TAIL t-0909-2: the record's own number, typed by the chat

## 09:15 · t — real EN markers, bro's own 6-hex-char auto id (may have no digit)
OPEN t-abc123: auto id with a digit in it
OPEN t-abcdef: auto id, pure hex letters, no digit at all

## 09:20 · t — real EN markers, a parenthetical note (colon allowed inside)
DECIDED (operator): who decided, not what
RULE (его): whose rule, not what
REJECTED (02:26): a timestamp reference, not what

## 09:25 · t — seed for the CLOSED-by-id checks below
TAIL: closing target for the CLOSED/ЗАКРЫТ cases below

## 09:30 · t — RU markers with a word before the colon, unaffected
Решение владельца: настоящая метка, слово перед двоеточием — не мешает
Правило подтверждено: тоже настоящая метка
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws17mre --full > "$SB/ws17mre-out.log" 2>&1
DEC17="$ROOT/ws17mre/decisions.md"
OPEN17="$ROOT/ws17mre/open.md"
RCAND17="$ROOT/_rule-candidates.md"

assert_not_contains "round 2: 'OPEN QUESTIONS:' is not harvested as an open item" "$(cat "$OPEN17" 2>/dev/null)" "unresolved topics for the retro"
assert_not_contains "round 2: 'OPEN ISSUES:' is not harvested as an open item" "$(cat "$OPEN17" 2>/dev/null)" "a list, not a single open item"
assert_not_contains "round 2: 'OPEN follow-ups:' is not harvested (two words, no digit)" "$(cat "$OPEN17" 2>/dev/null)" "two hyphenated words, not an id"
assert_not_contains "round 2: 'OPEN to-do:' is not harvested (hyphenated word, no digit)" "$(cat "$OPEN17" 2>/dev/null)" "hyphenated word with no digit in it"
assert_not_contains "round 2: 'DECIDED FACTOR:' is not harvested as a decision" "$(cat "$DEC17" 2>/dev/null)" "not a real decision, just a heading"

assert_contains "round 2: plain 'OPEN:' (no token) still harvested" "$(cat "$OPEN17" 2>/dev/null)" "a real open item, no word before the colon"
assert_contains "round 2: plain 'DECIDED:' (no token) still harvested" "$(cat "$DEC17" 2>/dev/null)" "a real decision, no word before the colon"

assert_contains "round 2: 'DECIDED d-0908-26:' (operator-typed id, real example) is harvested" "$(cat "$DEC17" 2>/dev/null)" "the record's own number, typed by the chat"
assert_eq "round 2: 'DECIDED d-0908-26:' keeps the explicit id, not a hash" "$(grep -c '^### d-0908-26 ' "$DEC17")" "1"
assert_contains "round 2: 'TAIL t-0909-2:' (operator-typed id, real example) is harvested" "$(cat "$OPEN17" 2>/dev/null)" "the record's own number, typed by the chat"
assert_eq "round 2: 'TAIL t-0909-2:' keeps the explicit id, not a hash" "$(grep -c '^- \[ \] t-0909-2 ' "$OPEN17")" "1"

assert_contains "round 2: 'OPEN t-abc123:' (auto id, has a digit) keeps that exact id" "$(cat "$OPEN17" 2>/dev/null)" "t-abc123 · auto id with a digit in it"
assert_contains "round 2: 'OPEN t-abcdef:' (auto id, pure hex letters, no digit) keeps that exact id" "$(cat "$OPEN17" 2>/dev/null)" "t-abcdef · auto id, pure hex letters, no digit at all"

assert_contains "round 2: 'DECIDED (operator):' (parenthetical note) is harvested, body clean" "$(cat "$DEC17" 2>/dev/null)" "who decided, not what"
assert_not_contains "round 2: 'DECIDED (operator):' note is not prepended to the body" "$(cat "$DEC17" 2>/dev/null)" "(operator): who decided"
assert_contains "round 2: 'RULE (его):' (parenthetical note) is harvested, body clean" "$(cat "$RCAND17" 2>/dev/null)" "whose rule, not what"
assert_not_contains "round 2: 'RULE (его):' note is not prepended to the body" "$(cat "$RCAND17" 2>/dev/null)" "(его): whose rule"
assert_contains "round 2: 'REJECTED (02:26):' (note with its OWN internal colon) is harvested, body clean" "$(cat "$DEC17" 2>/dev/null)" "a timestamp reference, not what"
assert_not_contains "round 2: the split is not fooled by the token's own colon -- body does not start with the tail of '(02:26)'" "$(cat "$DEC17" 2>/dev/null)" "26): a timestamp reference"
assert_not_contains "round 2: '(02:26)' note is not prepended to the body either" "$(cat "$DEC17" 2>/dev/null)" "(02:26): a timestamp reference"

assert_contains "round 2: RU 'Решение владельца:' (word before colon) still a marker" "$(cat "$DEC17" 2>/dev/null)" "настоящая метка, слово перед двоеточием"
assert_contains "round 2: RU 'Правило подтверждено:' (word before colon) still a marker" "$(cat "$RCAND17" 2>/dev/null)" "тоже настоящая метка"

# CLOSED <id>: (EN) still takes its id
TID17=$(grep 'closing target for the CLOSED' "$OPEN17" | grep -oE 't-[a-f0-9]+' | head -1)
cd "$(proj_dir ws17mre)"
printf 'CLOSED %s: closing via EN, id still parses\n' "$TID17" | "$BIN/bro-append.sh" --workspace ws17mre --thread t --topic close17 >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws17mre >/dev/null
assert_contains "coordinator fix: CLOSED <id>: (EN) still closes by id" "$(grep -F "$TID17" "$OPEN17")" "- [x] $TID17"

# ЗАКРЫТ <id>: (RU) still takes its id, on its own fresh seed
mkws ws17ru
F17RU="$ROOT/ws17ru/$DATE.md"
cat > "$F17RU" <<EOF
# bro — $DATE / ws17ru

## 09:00 · t — seed
TAIL: closing target for ЗАКРЫТ
EOF
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws17ru --full >/dev/null 2>&1
OPEN17RU="$ROOT/ws17ru/open.md"
TID17RU=$(grep 'closing target for ЗАКРЫТ' "$OPEN17RU" | grep -oE 't-[a-f0-9]+' | head -1)
cd "$(proj_dir ws17ru)"
printf 'ЗАКРЫТ %s: closing via RU, id still parses\n' "$TID17RU" | "$BIN/bro-append.sh" --workspace ws17ru --thread t --topic close17ru >/dev/null
cd "$REPO_DIR"
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws17ru >/dev/null
assert_contains "coordinator fix: ЗАКРЫТ <id>: (RU) still closes by id" "$(grep -F "$TID17RU" "$OPEN17RU")" "- [x] $TID17RU"

# the same fix, mirrored in bro-stop-turnstile.sh's degraded fallback copy of
# MRE_NOCOLON (bro-lib.sh hidden) -- must still catch a genuine colonless
# marker
mkws ws17deg
FDEG="$ROOT/ws17deg/$(date +%F).md"
printf '# bro — %s / ws17deg\n\n## 09:00 · t — topic\nOPEN missing its colon here\n' "$(date +%F)" > "$FDEG"
mv "$BIN/bro-lib.sh" "$SB/bro-lib.sh.hidden"
IN=$(hookjson "$(proj_dir ws17deg)" "$(next_sid)" p1 Stop)
OUT=$(printf '%s' "$IN" | "$BIN/bro-stop-turnstile.sh" 2>&1)
mv "$SB/bro-lib.sh.hidden" "$BIN/bro-lib.sh"
assert_contains "coordinator fix: degraded fallback still catches a colonless OPEN" "$OUT" "marker-like line(s) without ':'"

# --- find_glued_dup_oneline(): a body that itself legally contains
# "— from: "/"— родился: " text must not shift where body and source get
# cut -- coordinator's own repro ---
new_sandbox
install_repo >/dev/null
mkws ws17dedup
DATE=$(date +%F)
OPEN17D="$ROOT/ws17dedup/open.md"
cat > "$OPEN17D" <<EOF
# ws17dedup — open items

> Open items: promised and not yet done.

- [ ] t-abc123 · renamed — from: dash — from: $DATE · «00:00 · seed»

EOF
F17D="$ROOT/ws17dedup/$DATE.md"
cat > "$F17D" <<EOF
# bro — $DATE / ws17dedup

## 00:00 · seed
ДЕЛО t-abc123: renamed — from: dash and now continues with more detail
EOF
CNT17D_BEFORE=$(grep -c '^- \[' "$OPEN17D")
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws17dedup --full > "$SB/ws17dedup-out.log" 2>&1
CNT17D_AFTER=$(grep -c '^- \[' "$OPEN17D")
assert_eq "dedup fix: a body containing its own '— from: ' text adds no duplicate open item" "$CNT17D_AFTER" "$CNT17D_BEFORE"
assert_contains "dedup fix: recognized as already present (not a COLLISION)" "$(cat "$SB/ws17dedup-out.log")" "already present as t-abc123"
assert_not_contains "dedup fix: no COLLISION / suffixed id was minted" "$(cat "$SB/ws17dedup-out.log")" "COLLISION"
assert_not_contains "dedup fix: open.md carries no x-suffixed duplicate of t-abc123" "$(cat "$OPEN17D")" "t-abc123x"

# repeated --full: still no duplicate
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws17dedup --full >/dev/null 2>&1
CNT17D_TWICE=$(grep -c '^- \[' "$OPEN17D")
assert_eq "dedup fix: a second --full in a row still adds nothing" "$CNT17D_TWICE" "$CNT17D_BEFORE"

# same scenario against the OLD RU '— родился: ' signature
new_sandbox
install_repo >/dev/null
mkws ws17dedupru
DATE=$(date +%F)
OPEN17DR="$ROOT/ws17dedupru/open.md"
cat > "$OPEN17DR" <<EOF
# ws17dedupru — open items

> Хвосты и открытые вопросы.

- [ ] t-xyz789 · renamed — родился: dash — родился: $DATE · «00:00 · seed»

EOF
F17DR="$ROOT/ws17dedupru/$DATE.md"
cat > "$F17DR" <<EOF
# bro — $DATE / ws17dedupru

## 00:00 · seed
ХВОСТ t-xyz789: renamed — родился: dash and now continues with more detail
EOF
CNT17DR_BEFORE=$(grep -c '^- \[' "$OPEN17DR")
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws17dedupru --full > "$SB/ws17dedupru-out.log" 2>&1
CNT17DR_AFTER=$(grep -c '^- \[' "$OPEN17DR")
assert_eq "dedup fix (old RU signature): a self-referential body adds no duplicate" "$CNT17DR_AFTER" "$CNT17DR_BEFORE"
assert_contains "dedup fix (old RU signature): recognized as already present" "$(cat "$SB/ws17dedupru-out.log")" "already present as t-xyz789"

# --- find_glued_dup_multiline() (decisions.md): confirm it was never
# vulnerable to the same bug -- body and signature are two separate
# physical lines there, never split out of one combined string ---
new_sandbox
install_repo >/dev/null
mkws ws17mline
DATE=$(date +%F)
DEC17M="$ROOT/ws17mline/decisions.md"
cat > "$DEC17M" <<EOF
# ws17mline — decisions

> Decision register: what was chosen, instead of what, and why.

### d-unrelated (2026-01-01) [active]
an unrelated older decision under the bare base id
— from: 2026-01-01 · «old unrelated»

### d-unrelatedx9999 (2026-01-01) [active]
chose Postgres — from: our old MySQL setup, this glued body continues into unrelated prose that a pre-3.7 harvest pass stitched on by accident
— from: $DATE · «Evening M»

EOF
F17M="$ROOT/ws17mline/$DATE.md"
cat > "$F17M" <<EOF
# bro — $DATE / ws17mline

## Evening M
РЕШЕНИЕ d-unrelated: chose Postgres — from: our old MySQL setup
EOF
CNT17M_BEFORE=$(grep -c '^### ' "$DEC17M")
"$BIN/bro-harvest.sh" --root "$ROOT" --workspace ws17mline --full > "$SB/ws17mline-out.log" 2>&1
CNT17M_AFTER=$(grep -c '^### ' "$DEC17M")
assert_eq "dedup multiline: a body containing its own '— from: ' text still adds no duplicate decision" "$CNT17M_AFTER" "$CNT17M_BEFORE"
assert_contains "dedup multiline: recognized as already present as the glued suffixed id" "$(cat "$SB/ws17mline-out.log")" "already present as d-unrelatedx9999"

# ===========================================================================
# parts — additional per-builder test files land here (tests/parts/*.sh),
# one file per builder so they don't step on each other. Each part is
# SOURCED, not run as a subprocess, so it shares this suite's helpers
# (pass/fail, assert_*, new_sandbox, install_repo, mkws, proj_dir,
# PASS_N/FAIL_N/FAILED_NAMES) and its checks count toward the one summary
# below. A missing or empty tests/parts/ directory is a silent no-op.
# ===========================================================================
PARTS_DIR="$REPO_DIR/tests/parts"
if [ -d "$PARTS_DIR" ]; then
  for p in "$PARTS_DIR"/*.sh; do
    [ -e "$p" ] || continue   # unexpanded literal glob when the dir has no .sh files in it
    echo "-- part: $(basename "$p") --"
    . "$p"
  done
fi
# ===========================================================================
echo ""
echo "==== bro regression suite: $PASS_N passed, $FAIL_N failed ===="
if [ "$FAIL_N" -gt 0 ]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
