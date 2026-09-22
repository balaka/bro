# bro v3.9 — tests/parts/d-translate.sh (Builder M: §4)
#
# Sourced by tests/regress.sh AFTER the main suite's own sections — shares
# its helpers (pass/fail, assert_*, new_sandbox, install_repo, mkws,
# proj_dir) and counters (PASS_N/FAIL_N/FAILED_NAMES), same discipline as
# tests/parts/b-write-path.sh and tests/parts/c-hooks.sh. Do not `exit`
# from this file — a failure must fall through to the rest of the suite
# and the final summary (this suite runs under `set -uo pipefail`, no
# `-e`, so a failing assertion or a non-zero bro-translate-registers.sh
# exit never aborts the sourcing shell on its own).
#
# Every check below calls scripts/bro-translate-registers.sh and
# scripts/bro-harvest.sh directly from $SCRIPTS_DIR — never through
# install_repo/$BIN — so this file has no dependency on the installer
# wiring (Builder V's own, separate, parallel change) and no jq
# requirement of its own.
#
# Covers:
#   D1  — a register bro-translate-registers.sh produces from an old
#         Russian store has the exact same header, byte for byte, as one
#         bro-harvest.sh itself creates from nothing for a brand-new
#         register of the same kind — the specific comparison §4 of the
#         v3.9 plan asks for, not a copy of either script's own idea of
#         the text
#   D2  — full round trip: an old-Russian store, mechanically derived from
#         a REAL bro-harvest.sh run's own output (attribution, a closed
#         item, entry text including a Cyrillic clause the operator
#         wrote), translates back to be byte-for-byte IDENTICAL to that
#         same harvest output — proves entries are never touched, not
#         just that the six structural substitutions individually work
#   D3  — decisions.md's own-line attribution (no space before the dash —
#         the one shape that differs from every other register's inline
#         form) is translated
#   D4  — open.md's closed-item shape (both "— from:" and "— closed:" on
#         one bullet line) is translated
#   D5  — idempotent: a second --all run over an already-translated store
#         changes zero bytes
#   D6  — every translated file was backed up, unmodified, before the
#         write; a repeated run creates no second backup
#   D7  — after translation, bro-harvest.sh --all --full adds zero new
#         records and mints no id-collision suffix
#   D8  — _rule-candidates.md's four accept/reject forms, including the
#         real hand-edited "[x] принят …" shape (§4), each translate
#         independently
#   D9  — --dry-run writes nothing, creates no backup, exits 0, and
#         reports nonzero per-file counts
#   D10 — journals, _workspace.md, _principles.md, INDEX.md, and a file
#         already under _archive/ are byte-identical after a real --all
#         run, even though (confirmed in this project's own real store)
#         they can legitimately contain the very same Russian substrings
#         as plain prose or history
#   D11 — a busy lock leaves its file byte-identical and uncorrupted, and
#         the run still exits 0; once free, a later run translates it
#   D12 — --workspace touches only that workspace's four files;
#         --all also translates the two root files
#   D13 — CLI validation: neither/both of --workspace and --all, a
#         nonexistent --root, a nonexistent or reserved --workspace, and
#         an unknown flag are all hard errors
#   D14 — a workspace missing some of its four register files is not an
#         error, and the missing ones are not synthesized
#
# D15-D22 below cover a review round on this exact script: a bare
# "wherever this substring occurs" scan translated text INSIDE an entry
# that quotes the old format as an example, and, in _state.md, a SIDE line
# (the operator's own words) that happens to use "записано"/"проект" in an
# unrelated sentence — both confirmed real, not hypothetical. Fixed by
# anchoring every substitution to a structural position (decisions.md: a
# line that STARTS with the marker; every inline register: only the LAST
# match on the line; _state.md: only lines 1 and 4). Each fix below is
# paired with its own idempotency check — the first fix attempt here
# protected a quote on the FIRST run but then corrupted that same quote on
# a SECOND run (nothing left to be "the last match" except the quote, once
# the real one was already translated); D17/D18 in particular exist
# because that regression was caught here, not shipped.
#   D15 — decisions.md: an entry that quotes the old own-line attribution
#         format as an example is left untouched; the entry's own real
#         attribution still translates; survives a second run unchanged
#   D16 — open.md: an entry that quotes the old inline attribution/closed
#         format is left untouched; the entry's own real attribution+
#         closed still translate; survives a second run unchanged
#   D17 — _rule-candidates.md: an entry that quotes "[x] принят " mid-line
#         (not right after its own checkbox) is left untouched; the
#         entry's own real trailing "— принят " still translates; survives
#         a second run unchanged
#   D18 — _state.md: side lines (line 5 onward) that use the plain words
#         "записано"/"проект" in an unrelated sentence are left completely
#         untouched, even though line 1 and line 4 are correctly
#         translated; survives a second run unchanged
#   D19 — _state.md: a title line with trailing whitespace ("# Состояние
#         оператора " — a real hand-edit shape) is still recognized and
#         translated — the file no longer ends up half-Russian
#   D20 — _state.md: a genuinely unrecognized title prints the same kind of
#         NOTE process_register() prints for its own case, leaves the
#         title untouched, but still translates line 4 independently
#   D21 — an empty register (and an empty _state.md) is reported as
#         "empty — skipped" in both --dry-run and a real run, not silently
#         omitted from the output
#   D22 — control: an ordinary quote-free entry in each of decisions.md/
#         open.md/_rule-candidates.md translates exactly as D1-D14 already
#         established — the D15-D18 anchoring fix changed nothing about
#         the common case

# d_assert_same NAME FILE_A FILE_B — byte-for-byte comparison; on failure
# shows the actual diff (truncated) instead of just "not equal", the same
# usefulness assert_contains already gives over a plain assert_eq.
d_assert_same() {
  if cmp -s "$2" "$3"; then
    pass "$1"
  else
    fail "$1" "files differ ($2 vs $3): $(diff "$2" "$3" 2>&1 | head -6 | tr '\n' '|')"
  fi
}

# d_ruize_common — stdin: a register body already in v3.9's English shape
# -> stdout: the same bytes with the two structural forms every register
# OTHER than decisions.md used before v3.9 ("— from:"/"— closed DATE:")
# turned back into their old Russian originals ("— родился:"/
# "— закрыт DATE:"). Used below to build a faithful "old store" fixture
# out of a REAL bro-harvest.sh run's own output, rather than hand-typing
# one — the round trip in D1-D2 then proves the translator's output
# matches bro-harvest.sh's own idea of these bytes, not just this test
# file's idea of them. decisions.md's own attribution ("— родилось:", the
# neuter form, no space before the dash) is reversed separately at its
# own call site below — it is the one register that never shares this
# helper's masculine "— родился:" form.
d_ruize_common() {
  sed -E 's/— from: /— родился: /g; s/— closed ([0-9]{4}-[0-9]{2}-[0-9]{2}): /— закрыт \1: /g'
}

# ===========================================================================
# D1-D7. round trip vs a REAL bro-harvest.sh run, byte for byte
# ===========================================================================
echo "-- D1-D7. round trip vs a live harvest, byte for byte --"

# ---- build the reference: a live harvest of one journal, in English (v3.9
# bro-harvest.sh already writes it that way) — decisions/open(+closed)/
# vocab/insights/rule-candidate/state, one of each, so every register kind
# this script touches gets a real, non-empty header AND at least one real
# entry to round-trip. RULE's body ends in a short Cyrillic clause — the
# operator's own words, never a structural token — to prove D2 preserves
# entry text, not just ASCII entry text.
#
# Two harvest passes, not one: OPEN gets no explicit id here (bro-lib.sh's
# MRE only accepts a leading id token before ":" for CLOSED and the Russian
# keywords, not for the plain English ones — deliberately, not this file's
# business to second-guess), so the id CLOSED needs to resolve the item two
# sections later is read back from whatever bro-harvest.sh itself assigned
# the open item on pass 1, the same way an operator would (the register
# itself is the only place that id is ever visible), then written into a
# second journal section and harvested incrementally on pass 2.
new_sandbox
mkws dproj
D_DATE=$(date +%F)
D_REFJOURNAL="$ROOT/dproj/$D_DATE.md"
cat > "$D_REFJOURNAL" <<EOF
# bro — $D_DATE / dproj

## 10:00 · t — setup

DECIDED: chose Postgres over Mongo because relational fit is better

OPEN: write the onboarding doc

TERM: bro — the journal tool

INSIGHT: small daily journals compound into a searchable history

RULE: keep every record short — оператор попросил короче

STATE: calm and focused, two coffees in

EOF
"$SCRIPTS_DIR/bro-harvest.sh" --root "$ROOT" --workspace dproj --full >/dev/null 2>&1
D_REFROOT="$ROOT"
assert_file_exists "D1-D7 setup: a live harvest produced open.md" "$D_REFROOT/dproj/open.md"
D_ONBOARD_ID=$(grep -oE 't-[a-f0-9]+' "$D_REFROOT/dproj/open.md" 2>/dev/null | head -1)
assert_contains "D1-D7 setup: the open item got a real t-<hash> id to close" "$D_ONBOARD_ID" "t-"

cat >> "$D_REFJOURNAL" <<EOF

## 11:00 · t — wrap-up

CLOSED $D_ONBOARD_ID: doc written and shipped

EOF
"$SCRIPTS_DIR/bro-harvest.sh" --root "$ROOT" --workspace dproj >/dev/null 2>&1
assert_contains "D1-D7 setup: the live harvest's open.md really has a '— closed' entry to round-trip" "$(cat "$D_REFROOT/dproj/open.md")" "— closed $D_DATE:"

# ---- build the old store: SAME workspace name, a different sandbox, every
# register mechanically reverse-translated from the reference's own actual
# bytes (never hand-typed), so what's being round-tripped is real
# bro-harvest.sh output, not this test's guess at it. The old-format
# blockquote description lines are the operator's real pre-3.9 store's own
# wording (verified by hand against ~/bro before this test was written),
# copied here as literal Russian DATA, never as an instruction.
new_sandbox
mkws dproj
D_OLDROOT="$ROOT"
cp "$D_REFJOURNAL" "$D_OLDROOT/dproj/$D_DATE.md"

{
  echo "# dproj — decisions"
  echo ""
  echo "> Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать."
  echo "> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать."
  echo ""
  tail -n "+6" "$D_REFROOT/dproj/decisions.md" | sed -E 's/— from: /— родилось: /g'
} > "$D_OLDROOT/dproj/decisions.md"

{
  echo "# dproj — open items"
  echo ""
  echo "> Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает."
  echo "> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать."
  echo ""
  tail -n "+6" "$D_REFROOT/dproj/open.md" | d_ruize_common
} > "$D_OLDROOT/dproj/open.md"

{
  echo "# dproj — vocabulary"
  echo ""
  echo "> Словарь: термин — значение, словами оператора, с датой рождения."
  echo "> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать."
  echo ""
  tail -n "+6" "$D_REFROOT/dproj/vocab.md" | d_ruize_common
} > "$D_OLDROOT/dproj/vocab.md"

{
  echo "# dproj — insights"
  echo ""
  echo "> Закономерности, идеи, новые подходы к работе. Пополняется жатвой; подъём в принципы — отдельно (3.9), не здесь."
  echo "> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать."
  echo ""
  tail -n "+6" "$D_REFROOT/dproj/insights.md" | d_ruize_common
} > "$D_OLDROOT/dproj/insights.md"

{
  echo "# rule candidates (global queue)"
  echo ""
  echo "> Кандидаты в _principles.md. В принципы — только после подтверждения оператора: [x] принят / [-] отклонён."
  echo "> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать."
  echo ""
  tail -n "+6" "$D_REFROOT/_rule-candidates.md" | d_ruize_common
} > "$D_OLDROOT/_rule-candidates.md"

{
  echo "# Состояние оператора"
  tail -n "+2" "$D_REFROOT/_state.md" | sed -E 's/^recorded: /записано: /; s/ · project / · проект /'
} > "$D_OLDROOT/_state.md"

# snapshot the just-built old-Russian bytes for D6's backup check, before
# anything below is allowed to translate them
D_BK=$(mktemp -d "${TMPDIR:-/tmp}/bro-regress-dbk.XXXXXX")
cp "$D_OLDROOT/dproj/decisions.md" "$D_OLDROOT/dproj/open.md" "$D_OLDROOT/dproj/vocab.md" \
   "$D_OLDROOT/dproj/insights.md" "$D_OLDROOT/_rule-candidates.md" "$D_OLDROOT/_state.md" "$D_BK/" 2>/dev/null

"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$D_OLDROOT" --all >/dev/null 2>&1
D1_RC=$?
assert_exit "D1-D7 setup: translating the old store exits 0" "$D1_RC" "0"

# ---- D1: header byte-for-byte against the live harvest's own header ----
d_assert_same "D1: decisions.md header matches a live harvest's own ensure_register() output" \
  <(sed -n '1,5p' "$D_OLDROOT/dproj/decisions.md") <(sed -n '1,5p' "$D_REFROOT/dproj/decisions.md")
d_assert_same "D1: open.md header matches a live harvest's own ensure_register() output" \
  <(sed -n '1,5p' "$D_OLDROOT/dproj/open.md") <(sed -n '1,5p' "$D_REFROOT/dproj/open.md")
d_assert_same "D1: vocab.md header matches a live harvest's own ensure_register() output" \
  <(sed -n '1,5p' "$D_OLDROOT/dproj/vocab.md") <(sed -n '1,5p' "$D_REFROOT/dproj/vocab.md")
d_assert_same "D1: insights.md header matches a live harvest's own ensure_register() output" \
  <(sed -n '1,5p' "$D_OLDROOT/dproj/insights.md") <(sed -n '1,5p' "$D_REFROOT/dproj/insights.md")
d_assert_same "D1: _rule-candidates.md header matches a live harvest's own ensure_register() output" \
  <(sed -n '1,5p' "$D_OLDROOT/_rule-candidates.md") <(sed -n '1,5p' "$D_REFROOT/_rule-candidates.md")
d_assert_same "D1: _state.md title line matches a live harvest's own write_state_snapshot() output" \
  <(sed -n '1p' "$D_OLDROOT/_state.md") <(sed -n '1p' "$D_REFROOT/_state.md")

# ---- D2: FULL content byte-for-byte — proves entries (including the
# Cyrillic clause in RULE's body) are never touched, not just that headers
# and attributions individually translate right.
d_assert_same "D2: decisions.md round-trips to be byte-identical to the live harvest" \
  "$D_OLDROOT/dproj/decisions.md" "$D_REFROOT/dproj/decisions.md"
d_assert_same "D2: open.md (with its closed item) round-trips to be byte-identical" \
  "$D_OLDROOT/dproj/open.md" "$D_REFROOT/dproj/open.md"
d_assert_same "D2: vocab.md round-trips to be byte-identical" \
  "$D_OLDROOT/dproj/vocab.md" "$D_REFROOT/dproj/vocab.md"
d_assert_same "D2: insights.md round-trips to be byte-identical" \
  "$D_OLDROOT/dproj/insights.md" "$D_REFROOT/dproj/insights.md"
d_assert_same "D2: _rule-candidates.md round-trips to be byte-identical" \
  "$D_OLDROOT/_rule-candidates.md" "$D_REFROOT/_rule-candidates.md"
d_assert_same "D2: _state.md round-trips to be byte-identical" \
  "$D_OLDROOT/_state.md" "$D_REFROOT/_state.md"
assert_contains "D2: RULE's Cyrillic clause (the operator's own words) survived translation verbatim" \
  "$(cat "$D_OLDROOT/_rule-candidates.md")" "оператор попросил короче"

# ---- D3: decisions.md's own-line attribution specifically (no space
# before the dash — the shape that a literal " — родилось: " pattern with
# a mandatory leading space would miss) ----
assert_contains "D3: decisions.md's own-line attribution translates to '— from:'" \
  "$(cat "$D_OLDROOT/dproj/decisions.md")" $'\n— from: '
assert_not_contains "D3: decisions.md has no leftover 'родилось' anywhere" \
  "$(cat "$D_OLDROOT/dproj/decisions.md")" "родилось"

# ---- D4: open.md's closed-item shape (both tokens on one bullet line) ----
assert_contains "D4: open.md's closed item carries both '— from:' and '— closed DATE:'" \
  "$(cat "$D_OLDROOT/dproj/open.md")" "— from: $D_DATE · «10:00 · t — setup» — closed $D_DATE: doc written and shipped"
assert_not_contains "D4: open.md has no leftover 'родился'/'закрыт' anywhere" \
  "$(cat "$D_OLDROOT/dproj/open.md")" "родился"

# ---- D5: idempotent — a second --all run changes nothing ----
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$D_OLDROOT" --all >/dev/null 2>&1
D5_RC=$?
assert_exit "D5: a second --all run over an already-translated store exits 0" "$D5_RC" "0"
d_assert_same "D5: decisions.md is unchanged by the second run" "$D_OLDROOT/dproj/decisions.md" "$D_REFROOT/dproj/decisions.md"
d_assert_same "D5: open.md is unchanged by the second run" "$D_OLDROOT/dproj/open.md" "$D_REFROOT/dproj/open.md"
d_assert_same "D5: _rule-candidates.md is unchanged by the second run" "$D_OLDROOT/_rule-candidates.md" "$D_REFROOT/_rule-candidates.md"
d_assert_same "D5: _state.md is unchanged by the second run" "$D_OLDROOT/_state.md" "$D_REFROOT/_state.md"

# ---- D6: backup — the ORIGINAL Russian bytes, not the translated ones,
# under _archive/pre-english-<timestamp>/<path relative to root>; the
# idempotent second run above created no additional backup directory.
D_ARCH=$(find "$D_OLDROOT/_archive" -maxdepth 1 -type d -name 'pre-english-*' 2>/dev/null | sort)
D_ARCH_N=$(printf '%s\n' "$D_ARCH" | grep -c . || true)
assert_eq "D6: exactly one backup directory exists (the idempotent re-run added none)" "$D_ARCH_N" "1"
d_assert_same "D6: the backup of decisions.md is the untranslated original" "$D_ARCH/dproj/decisions.md" "$D_BK/decisions.md"
d_assert_same "D6: the backup of open.md is the untranslated original" "$D_ARCH/dproj/open.md" "$D_BK/open.md"
d_assert_same "D6: the backup of _rule-candidates.md is the untranslated original" "$D_ARCH/_rule-candidates.md" "$D_BK/_rule-candidates.md"
d_assert_same "D6: the backup of _state.md is the untranslated original" "$D_ARCH/_state.md" "$D_BK/_state.md"

# ---- D7: a full re-harvest of the now-translated store adds nothing and
# mints no id-collision suffix (the same "x<hash>" shape bro-harvest.sh's
# own glued-duplicate disambiguator would produce on a real collision) ----
D_H7_BEFORE=$(shasum "$D_OLDROOT/dproj/decisions.md" "$D_OLDROOT/dproj/open.md" "$D_OLDROOT/dproj/vocab.md" \
  "$D_OLDROOT/dproj/insights.md" "$D_OLDROOT/_rule-candidates.md" "$D_OLDROOT/_state.md")
"$SCRIPTS_DIR/bro-harvest.sh" --root "$D_OLDROOT" --all --full >/dev/null 2>&1
D7_RC=$?
D_H7_AFTER=$(shasum "$D_OLDROOT/dproj/decisions.md" "$D_OLDROOT/dproj/open.md" "$D_OLDROOT/dproj/vocab.md" \
  "$D_OLDROOT/dproj/insights.md" "$D_OLDROOT/_rule-candidates.md" "$D_OLDROOT/_state.md")
assert_exit "D7: bro-harvest.sh --all --full over the translated store exits 0" "$D7_RC" "0"
assert_eq "D7: --all --full adds zero new records to the translated registers (identical checksums)" "$D_H7_AFTER" "$D_H7_BEFORE"
D_COLLISIONS=$(LC_ALL=C grep -noE '[a-z]-[a-f0-9]+x[a-f0-9]+' "$D_OLDROOT/dproj/decisions.md" "$D_OLDROOT/dproj/open.md" \
  "$D_OLDROOT/dproj/vocab.md" "$D_OLDROOT/dproj/insights.md" "$D_OLDROOT/_rule-candidates.md" 2>/dev/null | grep -c . || true)
assert_eq "D7: no id-collision suffix anywhere (no duplicate records were filed)" "$D_COLLISIONS" "0"

rm -rf "$D_BK"

# ===========================================================================
# D8. _rule-candidates.md's four accept/reject forms, independently
# ===========================================================================
echo "-- D8. _rule-candidates.md: all four accept/reject forms --"
new_sandbox
mkdir -p "$ROOT"
cat > "$ROOT/_rule-candidates.md" <<'RUEOF'
# rule candidates (global queue)

> Кандидаты в _principles.md. В принципы — только после подтверждения оператора: [x] принят / [-] отклонён.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [x] r-aaa111 (proj) · normal accepted rule — родился: 2026-09-06 · «topic» — принят 2026-09-06, вписан в _principles.md §22
- [-] r-bbb222 (proj) · normal rejected rule — родился: 2026-09-09 · «topic» — отклонён 2026-09-09: duplicate
- [x] принят 2026-09-16 (§48) r-ccc333 (proj) · hand-edited checkbox-in-body shape — родился: 2026-09-16 · «topic»
- [-] отклонён 2026-09-10 r-ddd444 (proj) · another hand-edited shape — родился: 2026-09-10 · «topic»
RUEOF
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all >/dev/null 2>&1
D8_OUT=$(cat "$ROOT/_rule-candidates.md")
assert_contains "D8: normal '— принят ' translates to '— accepted '" "$D8_OUT" "— accepted 2026-09-06, вписан"
assert_contains "D8: normal '— отклонён ' translates to '— rejected '" "$D8_OUT" "— rejected 2026-09-09: duplicate"
assert_contains "D8: hand-edited '[x] принят ' translates to '[x] accepted '" "$D8_OUT" "[x] accepted 2026-09-16 (§48)"
assert_contains "D8: hand-edited '[-] отклонён ' translates to '[-] rejected '" "$D8_OUT" "[-] rejected 2026-09-10 r-ddd444"
assert_not_contains "D8: no leftover 'принят' anywhere" "$D8_OUT" "принят"
assert_not_contains "D8: no leftover 'отклонён' anywhere" "$D8_OUT" "отклонён"

# ===========================================================================
# D9. --dry-run: no writes, no backup, counts reported
# ===========================================================================
echo "-- D9. --dry-run writes nothing --"
new_sandbox
mkws dw9
cat > "$ROOT/dw9/open.md" <<'RUEOF'
# dw9 — open items

> Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [ ] t-zzz999 · pending item — родился: 2026-09-20 · «14:24 · topic»
RUEOF
cp "$ROOT/dw9/open.md" "$SB/dw9-open-before.md"
D9_OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace dw9 --dry-run 2>&1)
D9_RC=$?
assert_exit "D9: --dry-run exits 0" "$D9_RC" "0"
d_assert_same "D9: --dry-run writes nothing — file is byte-identical to before" "$ROOT/dw9/open.md" "$SB/dw9-open-before.md"
assert_file_absent "D9: --dry-run creates no _archive/ directory" "$ROOT/_archive"
assert_contains "D9: --dry-run reports a nonzero header count" "$D9_OUT" "header=1"
assert_contains "D9: --dry-run reports a nonzero total" "$D9_OUT" "total=2"
assert_contains "D9: the final summary says nothing was written" "$D9_OUT" "dry run, nothing written"

# ===========================================================================
# D10. protected paths untouched, even when they contain matching text
# ===========================================================================
echo "-- D10. journals, _workspace.md, _principles.md, INDEX.md, _archive/ untouched --"
new_sandbox
mkws d10
D10_JOURNAL="$ROOT/d10/2026-01-01.md"
cat > "$D10_JOURNAL" <<'RUEOF'
# bro — 2026-01-01 / d10

## 10:00 · t — history note
This journal quotes an old-style closing note like "— закрыт 2026-01-01: shipped" and an
attribution-looking phrase "— родился: 2026-01-01 · «note»" purely as history text, not as a
live marker.
RUEOF
cat > "$ROOT/d10/_workspace.md" <<'RUEOF'
# d10 — workspace notes

Free-form notes. Historically we wrote "— закрыт 2026-01-02: done" here by hand once, as an example.
RUEOF
cat > "$ROOT/_principles.md" <<'RUEOF'
# bro principles

### 1. some rule
**Категория:** речь
**Правило:** an example rule that happens to quote "— родился: 2026-01-01" as an illustration
**Родилось:** 2026-01-01
RUEOF
cat > "$ROOT/INDEX.md" <<'RUEOF'
# bro index

| workspace | files | last entry | open items |
|---|---|---|---|
| d10 | 1 | 2026-01-01 | 0 |
RUEOF
mkdir -p "$ROOT/_archive/some-old-migration/d10"
cat > "$ROOT/_archive/some-old-migration/d10/decisions.md" <<'RUEOF'
# d10 — decisions

> Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

### x-old (2020-01-01) [active]
an already-archived decision, from before this run ever started
— родилось: 2020-01-01 · «topic»
RUEOF
cp "$D10_JOURNAL" "$SB/d10-journal-before.md"
cp "$ROOT/d10/_workspace.md" "$SB/d10-workspace-before.md"
cp "$ROOT/_principles.md" "$SB/d10-principles-before.md"
cp "$ROOT/INDEX.md" "$SB/d10-index-before.md"
cp "$ROOT/_archive/some-old-migration/d10/decisions.md" "$SB/d10-archived-before.md"

"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all >/dev/null 2>&1

d_assert_same "D10: the journal (YYYY-MM-DD.md) is byte-identical after the run" "$D10_JOURNAL" "$SB/d10-journal-before.md"
d_assert_same "D10: _workspace.md is byte-identical after the run" "$ROOT/d10/_workspace.md" "$SB/d10-workspace-before.md"
d_assert_same "D10: _principles.md is byte-identical after the run" "$ROOT/_principles.md" "$SB/d10-principles-before.md"
d_assert_same "D10: INDEX.md is byte-identical after the run" "$ROOT/INDEX.md" "$SB/d10-index-before.md"
d_assert_same "D10: a decisions.md already under _archive/ is byte-identical after the run" \
  "$ROOT/_archive/some-old-migration/d10/decisions.md" "$SB/d10-archived-before.md"

# ===========================================================================
# D11. busy lock — no corruption, no silent loss
# ===========================================================================
echo "-- D11. a busy lock leaves the file untouched --"
new_sandbox
mkws d11
cat > "$ROOT/d11/open.md" <<'RUEOF'
# d11 — open items

> Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [ ] t-lock1 · pending — родился: 2026-09-20 · «topic»
RUEOF
cp "$ROOT/d11/open.md" "$SB/d11-open-before.md"
mkdir "$ROOT/d11/open.md.lock"   # simulate another writer (e.g. a concurrent harvest) already holding the lock
D11_OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d11 2>&1)
D11_RC=$?
assert_exit "D11: the run still exits 0 with one file locked" "$D11_RC" "0"
assert_contains "D11: the busy file is reported as skipped" "$D11_OUT" "SKIP d11/open.md — lock busy"
d_assert_same "D11: the locked file is byte-identical — not corrupted, not partially written" "$ROOT/d11/open.md" "$SB/d11-open-before.md"
assert_file_absent "D11: no backup was made for a file that was never actually translated" "$ROOT/_archive"
rmdir "$ROOT/d11/open.md.lock"   # the other writer is done — lock is free again
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d11 >/dev/null 2>&1
assert_contains "D11: once the lock is free, a later run translates it normally" "$(cat "$ROOT/d11/open.md")" "— from:"

# ===========================================================================
# D12. --workspace touches only that workspace; --all also does the root
# ===========================================================================
echo "-- D12. --workspace vs --all: root file scoping --"
new_sandbox
mkws d12
cat > "$ROOT/d12/open.md" <<'RUEOF'
# d12 — open items

> Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [ ] t-scope1 · pending — родился: 2026-09-20 · «topic»
RUEOF
cat > "$ROOT/_rule-candidates.md" <<'RUEOF'
# rule candidates (global queue)

> Кандидаты в _principles.md. В принципы — только после подтверждения оператора: [x] принят / [-] отклонён.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [x] r-scope1 (d12) · a rule — родился: 2026-09-06 · «topic» — принят 2026-09-06
RUEOF
cp "$ROOT/_rule-candidates.md" "$SB/d12-rcand-before.md"

"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d12 >/dev/null 2>&1
d_assert_same "D12: --workspace leaves the shared _rule-candidates.md untouched" "$ROOT/_rule-candidates.md" "$SB/d12-rcand-before.md"
assert_contains "D12: --workspace still translates that workspace's own open.md" "$(cat "$ROOT/d12/open.md")" "— from:"

"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all >/dev/null 2>&1
assert_contains "D12: --all does translate the shared _rule-candidates.md" "$(cat "$ROOT/_rule-candidates.md")" "— accepted 2026-09-06"

# ===========================================================================
# D13. CLI validation
# ===========================================================================
echo "-- D13. CLI validation --"
new_sandbox
mkws d13

OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" 2>&1); RC=$?
assert_exit "D13: neither --workspace nor --all is a hard error" "$RC" "1"
assert_contains "D13: the error names the missing choice" "$OUT" "--workspace"

OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d13 --all 2>&1); RC=$?
assert_exit "D13: --workspace and --all together is a hard error" "$RC" "1"

OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT/does-not-exist" --all 2>&1); RC=$?
assert_exit "D13: a --root that does not exist is a hard error" "$RC" "1"

OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace nope 2>&1); RC=$?
assert_exit "D13: --workspace naming a workspace that does not exist is a hard error" "$RC" "1"

OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace _archive 2>&1); RC=$?
assert_exit "D13: --workspace _archive is rejected, not treated as a real workspace" "$RC" "1"

OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all --bogus-flag 2>&1); RC=$?
assert_exit "D13: an unknown flag is a hard error" "$RC" "1"

# ===========================================================================
# D14. a workspace missing some register files is not an error
# ===========================================================================
echo "-- D14. missing register files are skipped, not synthesized --"
new_sandbox
mkws d14
cat > "$ROOT/d14/open.md" <<'RUEOF'
# d14 — open items

> Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [ ] t-only1 · the only file present — родился: 2026-09-20 · «topic»
RUEOF
# decisions.md/vocab.md/insights.md are deliberately absent
OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d14 2>&1); RC=$?
assert_exit "D14: a workspace with only one of its four registers present does not error" "$RC" "0"
assert_file_absent "D14: a register that never existed is still absent (not synthesized)" "$ROOT/d14/decisions.md"
assert_file_absent "D14: same for vocab.md" "$ROOT/d14/vocab.md"
assert_file_absent "D14: same for insights.md" "$ROOT/d14/insights.md"
assert_contains "D14: the one file that IS present still gets translated" "$(cat "$ROOT/d14/open.md")" "— from:"

# ===========================================================================
# D15. decisions.md: a quoted example of the old format is left untouched
# ===========================================================================
echo "-- D15. decisions.md: an entry quoting the old format survives --"
new_sandbox
mkws d15
cat > "$ROOT/d15/decisions.md" <<'RUEOF'
# d15 — decisions

> Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

### d-quote1 (2026-09-22) [active]
an insight about the v3.9 migration: подпись выглядела так: «— родилось: 2026-01-01 · «пример»» и теперь иначе
— родилось: 2026-09-22 · «01:40 · migration notes»
RUEOF
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d15 >/dev/null 2>&1
D15_OUT=$(cat "$ROOT/d15/decisions.md")
assert_contains "D15: the entry's own real attribution translates to '— from:'" "$D15_OUT" $'\n— from: 2026-09-22'
assert_contains "D15: the quoted example inside the entry still says 'родилось' — untouched" "$D15_OUT" "«— родилось: 2026-01-01 · «пример»»"
assert_contains "D15: the quote's own wrapping sentence is intact, byte for byte" "$D15_OUT" "подпись выглядела так:"
cp "$ROOT/d15/decisions.md" "$SB/d15-after-run1.md"
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d15 >/dev/null 2>&1
d_assert_same "D15: a second run does not corrupt the quote (the exact regression this fix closes)" "$ROOT/d15/decisions.md" "$SB/d15-after-run1.md"

# ===========================================================================
# D16. open.md: a quoted example of the old inline format survives
# ===========================================================================
echo "-- D16. open.md: an entry quoting the old inline/closed format survives --"
new_sandbox
mkws d16
cat > "$ROOT/d16/open.md" <<'RUEOF'
# d16 — open items

> Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [x] t-abc123 · do the thing — родился: 2026-09-20 · «14:24 · topic» — закрыт 2026-09-22: done, shipped
- [ ] t-quote1 · quoting the old shape as an example: «— родился: 2020-01-01 · «old»» here — родился: 2026-09-22 · «01:41 · topic»
RUEOF
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d16 >/dev/null 2>&1
D16_OUT=$(cat "$ROOT/d16/open.md")
assert_contains "D16: a normal closed item's real attribution+closed both translate" "$D16_OUT" "— from: 2026-09-20 · «14:24 · topic» — closed 2026-09-22: done, shipped"
assert_contains "D16: the quoted example inside the second entry still says 'родился' — untouched" "$D16_OUT" "«— родился: 2020-01-01 · «old»»"
assert_contains "D16: that same entry's own real (last) attribution still translates" "$D16_OUT" "old»» here — from: 2026-09-22 · «01:41 · topic»"
cp "$ROOT/d16/open.md" "$SB/d16-after-run1.md"
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d16 >/dev/null 2>&1
d_assert_same "D16: a second run does not corrupt the quote" "$ROOT/d16/open.md" "$SB/d16-after-run1.md"

# ===========================================================================
# D17. _rule-candidates.md: a mid-line quote of "[x] принят " survives
# ===========================================================================
echo "-- D17. _rule-candidates.md: a mid-line quote of the anomaly shape survives --"
new_sandbox
mkdir -p "$ROOT"
cat > "$ROOT/_rule-candidates.md" <<'RUEOF'
# rule candidates (global queue)

> Кандидаты в _principles.md. В принципы — только после подтверждения оператора: [x] принят / [-] отклонён.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [x] r-quote1 (d17) · quoting an old anomaly as example: «[x] принят » was a real bug shape — родился: 2026-09-22 · «topic» — принят 2026-09-22: real accept
RUEOF
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all >/dev/null 2>&1
D17_OUT=$(cat "$ROOT/_rule-candidates.md")
assert_contains "D17: the mid-line quote of '[x] принят ' is untouched — it is not at the start of the line" "$D17_OUT" "«[x] принят »"
assert_contains "D17: the entry's own real trailing '— принят ' still translates" "$D17_OUT" "— accepted 2026-09-22: real accept"
assert_contains "D17: the entry's own real attribution still translates" "$D17_OUT" "— from: 2026-09-22"
cp "$ROOT/_rule-candidates.md" "$SB/d17-after-run1.md"
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all >/dev/null 2>&1
d_assert_same "D17: a second run does not corrupt the mid-line quote" "$ROOT/_rule-candidates.md" "$SB/d17-after-run1.md"

# ===========================================================================
# D18. _state.md: side lines using "записано"/"проект" as prose survive
# ===========================================================================
echo "-- D18. _state.md: a side line's own unrelated sentence survives --"
new_sandbox
mkdir -p "$ROOT"
cat > "$ROOT/_state.md" <<'RUEOF'
# Состояние оператора
<!-- ts: 1790019420 2026-09-21 23:37 -->
<!-- written by bro-harvest; do not edit by hand -->
записано: 2026-09-21 23:37 · проект d18 · «23:37 · topic»
- то, что сегодня записано: в реестрах, ещё не полное
- ушёл на · проект целиком не похож на вчерашний
RUEOF
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all >/dev/null 2>&1
D18_OUT=$(cat "$ROOT/_state.md")
assert_contains "D18: the title line translates" "$D18_OUT" "# Operator state"
assert_contains "D18: the real service line (line 4) translates" "$D18_OUT" "recorded: 2026-09-21 23:37 · project d18 · «23:37 · topic»"
assert_contains "D18: side 1's own unrelated 'записано:' sentence is byte-for-byte intact" "$D18_OUT" "- то, что сегодня записано: в реестрах, ещё не полное"
assert_contains "D18: side 2's own unrelated '· проект' sentence is byte-for-byte intact" "$D18_OUT" "- ушёл на · проект целиком не похож на вчерашний"
cp "$ROOT/_state.md" "$SB/d18-after-run1.md"
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all >/dev/null 2>&1
d_assert_same "D18: a second run does not corrupt either side line" "$ROOT/_state.md" "$SB/d18-after-run1.md"

# ===========================================================================
# D19. _state.md: a title line with trailing whitespace still translates
# ===========================================================================
echo "-- D19. _state.md: title with trailing whitespace --"
new_sandbox
mkdir -p "$ROOT"
printf '# Состояние оператора \n<!-- ts: 1 2026-01-01 00:00 -->\n<!-- written by bro-harvest; do not edit by hand -->\nзаписано: 2026-01-01 00:00 · проект d19 · «topic»\n- a side\n' > "$ROOT/_state.md"
D19_OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all 2>&1)
assert_not_contains "D19: no NOTE is printed for a title that only has trailing whitespace" "$D19_OUT" "NOTE"
D19_FILE=$(cat "$ROOT/_state.md")
assert_contains "D19: the title with trailing whitespace still translates to '# Operator state'" "$D19_FILE" "# Operator state"
assert_contains "D19: line 4 also translates normally" "$D19_FILE" "recorded: 2026-01-01 00:00 · project d19"
assert_not_contains "D19: the file is not left half-Russian (no leftover 'Состояние')" "$D19_FILE" "Состояние"

# ===========================================================================
# D20. _state.md: a genuinely unrecognized title gets a NOTE, not silence
# ===========================================================================
echo "-- D20. _state.md: an unrecognized title prints a NOTE --"
new_sandbox
mkdir -p "$ROOT"
printf '# something else entirely\n<!-- ts: 1 2026-01-01 00:00 -->\n<!-- written by bro-harvest; do not edit by hand -->\nзаписано: 2026-01-01 00:00 · проект d20 · «topic»\n- a side\n' > "$ROOT/_state.md"
D20_OUT=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all 2>&1)
assert_contains "D20: an unrecognized title line prints a NOTE (same courtesy process_register() gives its own case)" "$D20_OUT" "NOTE"
D20_FILE=$(cat "$ROOT/_state.md")
assert_contains "D20: the unrecognized title itself is left exactly as it was" "$D20_FILE" "# something else entirely"
assert_contains "D20: line 4 still translates independently of the title miss" "$D20_FILE" "recorded: 2026-01-01 00:00 · project d20"

# ===========================================================================
# D21. empty registers are reported, not silently omitted
# ===========================================================================
echo "-- D21. empty files: reported as 'empty — skipped', not silent --"
new_sandbox
mkws d21
: > "$ROOT/d21/open.md"
mkdir -p "$ROOT"
: > "$ROOT/_state.md"
D21_DRY=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all --dry-run 2>&1)
assert_contains "D21: an empty open.md is reported as empty — skipped, in --dry-run" "$D21_DRY" "d21/open.md — empty — skipped"
assert_contains "D21: an empty _state.md is reported as empty — skipped, in --dry-run" "$D21_DRY" "_state.md — empty — skipped"
D21_REAL=$("$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --all 2>&1)
assert_contains "D21: an empty open.md is reported as empty — skipped, in a real run" "$D21_REAL" "d21/open.md — empty — skipped"
assert_contains "D21: an empty _state.md is reported as empty — skipped, in a real run" "$D21_REAL" "_state.md — empty — skipped"
assert_file_absent "D21: an empty file that was 'skipped' is never backed up (nothing to back up)" "$ROOT/_archive"

# ===========================================================================
# D22. control: an ordinary quote-free entry still translates as before
# ===========================================================================
echo "-- D22. control: ordinary quote-free entries are unaffected by the anchoring fix --"
new_sandbox
mkws d22
cat > "$ROOT/d22/decisions.md" <<'RUEOF'
# d22 — decisions

> Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

### d-plain1 (2026-09-22) [active]
an ordinary decision with no quotes in it at all
— родилось: 2026-09-22 · «10:00 · topic»
RUEOF
cat > "$ROOT/d22/open.md" <<'RUEOF'
# d22 — open items

> Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает.
> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.

- [x] t-plain1 · an ordinary closed item — родился: 2026-09-22 · «10:00 · topic» — закрыт 2026-09-23: shipped
RUEOF
"$SCRIPTS_DIR/bro-translate-registers.sh" --root "$ROOT" --workspace d22 >/dev/null 2>&1
assert_contains "D22 control: an ordinary decisions.md entry translates exactly as before" \
  "$(cat "$ROOT/d22/decisions.md")" $'\n— from: 2026-09-22 · «10:00 · topic»'
assert_contains "D22 control: an ordinary open.md closed item translates exactly as before" \
  "$(cat "$ROOT/d22/open.md")" "— from: 2026-09-22 · «10:00 · topic» — closed 2026-09-23: shipped"
assert_not_contains "D22 control: no leftover Russian attribution anywhere" "$(cat "$ROOT/d22/decisions.md")$(cat "$ROOT/d22/open.md")" "родил"
