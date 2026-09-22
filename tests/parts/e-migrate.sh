# bro v4.0 — tests/parts/e-migrate.sh (builder V, §2 of the v4.0 fix-up):
# scripts/bro-migrate.sh's new v3 -> v4 register-language-translation step.
#
# Sourced by tests/regress.sh AFTER the main suite's own sections — shares
# its helpers (pass/fail, assert_*, new_sandbox, install_repo, mkws,
# proj_dir, hookjson, next_sid) and counters (PASS_N/FAIL_N/FAILED_NAMES).
# Do not `exit` from this file — a failure must fall through to the rest of
# the suite and the final summary, same discipline as every other part.
#
# Covers:
#   E1 — --dry-run on a v3 store: nothing written, shows the count,
#        .version stays 3
#   E2 — a real run on a v3 store: registers translated, a backup exists,
#        .version becomes 4
#   E3 — a repeat run on the now-v4 store: a no-op, says so
#   E4 — after a real migration, bro-session-start.sh's opening text no
#        longer carries the v3 advisory line
#   E5 — a machine with BOTH a legacy v1/v2 storage AND a pre-existing v3
#        store: the old (v1/v2 -> v3) path runs, AND the new (3 -> 4) path
#        also runs, in the SAME invocation (coordinator's own wording:
#        "old path first, then 3 -> 4")
#   E6 — bro-translate-registers.sh missing: bro-migrate.sh degrades with a
#        clear message instead of crashing, .version stays 3
#
# bro-migrate.sh's search path defaults to $HOME (maxdepth 5) when no
# positional search-path is given; every test below passes "$SB/proj"
# explicitly instead — the same tree mkws()/proj_dir() already use for
# workspace fixtures, and (crucially for E1/E2/E3/E6) guaranteed to hold no
# directory literally named "bro" unless a test puts one there itself, so
# "found a legacy storage" and "found none" are never ambiguous here.

# seed_v3_workspace() — a v3-shaped workspace under $ROOT with one register
# still carrying the OLD Russian service words (the exact shape
# bro-harvest.sh wrote before v3.9, and scripts/bro-translate-registers.sh
# exists to fix).
seed_v3_workspace() { # $1 = workspace name
  local ws="$1"
  mkdir -p "$ROOT/$ws"
  cat > "$ROOT/$ws/decisions.md" <<EOF
# $ws — decisions

> Decision register: what was chosen, instead of what, and why. Obsolete entries are marked [superseded by <id>] — never deleted.
> Filled automatically from the daily journals (bro-harvest.sh); statuses are edited by hand. Never delete entries — supersede them.

### d-abc123 (2026-01-01) [active]
some pre-existing decision, written by an older bro
— родилось: 2026-01-01 · «old»

EOF
}

echo "-- E1. bro-migrate.sh --dry-run on a v3 store: nothing written, shows the count --"
new_sandbox
install_repo >/dev/null
mkws wse1
seed_v3_workspace wse1
echo "3" > "$ROOT/.version"
BEFORE_E1=$(cat "$ROOT/wse1/decisions.md")
OUT_E1=$(bash "$BIN/bro-migrate.sh" --root "$ROOT" --dry-run "$SB/proj" 2>&1)
RC_E1=$?
assert_exit "E1: exits 0" "$RC_E1" "0"
assert_contains "E1: mentions the v3 -> v4 step ran" "$OUT_E1" "v3 -> v4"
assert_contains "E1: shows what bro-translate-registers.sh --dry-run found (total=1)" "$OUT_E1" "total=1"
assert_contains "E1: says nothing was written" "$OUT_E1" "nothing written"
VER_E1=$(cat "$ROOT/.version")
assert_eq "E1: .version stays 3 after a dry run" "$VER_E1" "3"
AFTER_E1=$(cat "$ROOT/wse1/decisions.md")
assert_eq "E1: decisions.md is byte-identical after a dry run (nothing written)" "$AFTER_E1" "$BEFORE_E1"
NARCH_E1=$(ls "$ROOT/_archive" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "E1: no backup directory created by a dry run" "${NARCH_E1:-0}" "0"

echo "-- E2. bro-migrate.sh (real run) on a v3 store: translated, backed up, .version becomes 4 --"
new_sandbox
install_repo >/dev/null
mkws wse2
seed_v3_workspace wse2
echo "3" > "$ROOT/.version"
OUT_E2=$(bash "$BIN/bro-migrate.sh" --root "$ROOT" "$SB/proj" 2>&1)
RC_E2=$?
assert_exit "E2: exits 0" "$RC_E2" "0"
assert_contains "E2: reports translation finished without errors" "$OUT_E2" "translation finished without errors"
VER_E2=$(cat "$ROOT/.version")
assert_eq "E2: .version is now 4" "$VER_E2" "4"
assert_contains "E2: decisions.md now carries the English '— from:' signature" "$(cat "$ROOT/wse2/decisions.md")" "— from: 2026-01-01"
assert_not_contains "E2: the old '— родилось:' signature is gone" "$(cat "$ROOT/wse2/decisions.md")" "родилось"
BACKUP_E2=$(find "$ROOT/_archive" -maxdepth 1 -type d -name "pre-english-*" 2>/dev/null | head -1)
if [ -n "$BACKUP_E2" ]; then pass "E2: a pre-english backup directory was created"; else fail "E2: a pre-english backup directory was created" "none found under $ROOT/_archive"; fi
assert_contains "E2: the backup holds the ORIGINAL (Russian-signed) content" "$(cat "$BACKUP_E2/wse2/decisions.md" 2>/dev/null)" "родилось"

# E3/E4 deliberately reuse E2's own sandbox (same $ROOT, now at v4, with
# workspace wse2) — both are about what happens NEXT, after that same
# migration, not a fresh scenario of their own.
echo "-- E3. bro-migrate.sh: a repeat run on the now-v4 store is a no-op --"
OUT_E3=$(bash "$BIN/bro-migrate.sh" --root "$ROOT" "$SB/proj" 2>&1)
RC_E3=$?
assert_exit "E3: exits 0" "$RC_E3" "0"
assert_contains "E3: says the store is already v4" "$OUT_E3" "already v4"
CONTENT_E3_BEFORE=$(cat "$ROOT/wse2/decisions.md")
bash "$BIN/bro-migrate.sh" --root "$ROOT" "$SB/proj" >/dev/null 2>&1
assert_eq "E3: decisions.md is unchanged by the repeat run" "$(cat "$ROOT/wse2/decisions.md")" "$CONTENT_E3_BEFORE"

echo "-- E4. after a real migration, session-start's opening text no longer carries the v3 advisory --"
SID_E4=$(next_sid)
OUT_E4=$(hookjson "$(proj_dir wse2)" "$SID_E4" p1 SessionStart | "$BIN/bro-session-start.sh")
CTXTXT_E4=$(printf '%s' "$OUT_E4" | jq -r '.hookSpecificOutput.additionalContext')
assert_not_contains "E4: no 'this store is in v3 format' advisory any more" "$CTXTXT_E4" "this store is in v3 format"
assert_contains "E4: ordinary opening text still appears" "$CTXTXT_E4" "workspace 'wse2'"

echo "-- E5. a machine with BOTH a legacy v1/v2 storage and a pre-existing v3 store: old path first, then 3 -> 4, in ONE run --"
new_sandbox
install_repo >/dev/null
mkws wse5
seed_v3_workspace wse5
echo "3" > "$ROOT/.version"
mkdir -p "$SB/proj/legacyrepo5/bro"
cat > "$SB/proj/legacyrepo5/bro/_principles.md" <<'EOF'
# legacy principles

### 1. some old rule
speak plainly
EOF
OUT_E5=$(bash "$BIN/bro-migrate.sh" --root "$ROOT" "$SB/proj" 2>&1)
RC_E5=$?
assert_exit "E5: exits 0" "$RC_E5" "0"
assert_contains "E5: the legacy (v1/v2 -> v3) path ran and found the storage" "$OUT_E5" "found 1 legacy storage"
assert_contains "E5: the v3 -> v4 path ALSO ran in the same invocation" "$OUT_E5" "v3 -> v4"
assert_contains "E5: the v3 -> v4 path reports success" "$OUT_E5" "translation finished without errors"
if [ -d "$ROOT/legacyrepo5" ]; then pass "E5: the legacy storage was migrated into a NEW workspace 'legacyrepo5'"; else fail "E5: the legacy storage was migrated into a NEW workspace 'legacyrepo5'" "$ROOT/legacyrepo5 not found"; fi
assert_contains "E5: the PRE-EXISTING v3 workspace's register was ALSO translated" "$(cat "$ROOT/wse5/decisions.md")" "— from: 2026-01-01"
assert_eq "E5: .version ends at 4" "$(cat "$ROOT/.version")" "4"

echo "-- E6. bro-translate-registers.sh missing: bro-migrate.sh degrades with a message, does not crash, .version stays 3 --"
new_sandbox
install_repo >/dev/null
mkws wse6
seed_v3_workspace wse6
echo "3" > "$ROOT/.version"
mv "$BIN/bro-translate-registers.sh" "$SB/bro-translate-registers.sh.hidden-e6"
OUT_E6=$(bash "$BIN/bro-migrate.sh" --root "$ROOT" "$SB/proj" 2>&1)
RC_E6=$?
mv "$SB/bro-translate-registers.sh.hidden-e6" "$BIN/bro-translate-registers.sh"
assert_exit "E6: exits 0 even when the translator is missing (degrades, does not crash)" "$RC_E6" "0"
assert_contains "E6: names the actual problem (translator not found)" "$OUT_E6" "bro-translate-registers.sh was not found"
assert_eq "E6: .version stays 3 -- nothing was translated" "$(cat "$ROOT/.version")" "3"
assert_contains "E6: decisions.md is untouched" "$(cat "$ROOT/wse6/decisions.md")" "родилось"
