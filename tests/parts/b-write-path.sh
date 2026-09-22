# bro v3.8 — tests/parts/b-write-path.sh (Builder B: §2, §7)
#
# Sourced by tests/regress.sh AFTER the main suite's own sections — shares
# its helpers (pass/fail, assert_*, new_sandbox, install_repo, mkws,
# proj_dir) and counters (PASS_N/FAIL_N/FAILED_NAMES). Also reuses
# deny_write/deny_edit/deny_bash, defined by the main suite's own
# "-- 7. write guard --" section (sourced before this file ever runs) —
# not redefined here, so there is exactly one copy of "how to call the
# guard" in the whole suite. Do not `exit` from this file — a failure must
# fall through to the rest of the suite and the final summary, same
# discipline as every section above (this suite runs under `set -uo
# pipefail`, no `-e`, so a failing assertion or a non-zero bro-append.sh
# exit never aborts the sourcing shell on its own).
#
# Covers:
#   B1     — bro-write-guard.sh: heredoc BODY no longer confuses the guard
#            (the exact 20 Sep anatomy.md false positive, plus the
#            double-quoted and <<- variants) (§2)
#   B2     — bro-write-guard.sh: write-TARGET precision — an unrelated
#            write elsewhere in a compound statement no longer false-blocks,
#            and a real write buried in a later clause still blocks (§2)
#   B3     — bro-write-guard.sh: the full write-shape list from §2 (perl -i,
#            install, ln, dd of=, truncate, unlink, rm) plus a python/node
#            one-liner (§2)
#   B4     — bro-write-guard.sh: two ways to bypass heredoc-stripping found
#            while building this (unquoted-heredoc command substitution;
#            a heredoc body fed to a nested interpreter) — closed, not just
#            documented (§2)
#   B5     — bro-append.sh: TAIL/ХВОСТ/Хвост — 2+ "; " items rejected pre-
#            write, 1 allowed, across all three spellings; other marker
#            types are not checked by this rule (§7)
#   B6     — bro-append.sh: TAIL/ХВОСТ/Хвост — 2+ numbered-list items
#            rejected, both "(1)/(2)" and "1)/2)" shapes (§7)
#   B7     — bro-append.sh: TAIL/ХВОСТ/Хвост — length over threshold
#            rejected, with the character-vs-byte boundary actually
#            exercised in both directions (§7)
#
# B8-B12 and B13-B15 below cover reviewer #2's review round: false
# positives and bypasses confirmed by actually running them, fixed, and
# tested here so they can't come back silently.
#   B8     — bro-write-guard.sh: an UNQUOTED heredoc's prose no longer
#            false-positives (the same anatomy.md-class bug B1 fixed for
#            quoted heredocs), while a REAL $(...)/`...` substitution
#            inside one still blocks (§2 review fix)
#   B9     — bro-write-guard.sh: $HOME/... and ${HOME}/... (literal,
#            unexpanded) are recognized the same as ~/... and $ROOT (§2
#            review fix)
#   B10    — bro-write-guard.sh: an operator glued straight onto its
#            target with no space (>>file, 2>file, &>file, >|file) is
#            recognized (§2 review fix)
#   B11    — bro-write-guard.sh: a relative write target resolves against
#            the last `cd DIR` in the same command, or the hook's own cwd
#            when there is none — including the "no cd at all, cwd
#            already inside the workspace" shape (§2 review fix)
#   B12    — bro-write-guard.sh: mv now checks its SOURCE too (moving the
#            journal away is a write); cp's source stays exempt (reading
#            FROM the journal) (§2 review fix)
#   B13    — bro-append.sh: the numbered-list check only fires on a REAL
#            enumeration (both "(1)" and "(2)", or both "1)" and "2)"),
#            not a date/field-reference/code that merely contains a
#            "digit)" substring (§7 review fix)
#   B14    — bro-append.sh: "; " is only counted at the TOP level — one
#            inside (...), «...» or "..." does not count towards the limit
#            (§7 review fix)
#   B15    — bro-append.sh: the length check forces LC_ALL=en_US.UTF-8
#            itself, so character-counting is what actually runs
#            regardless of the caller's own environment (§7 review fix)
#
# B16-B17 below cover reviewer #2's SECOND review round: two more real
# writes confirmed after round 1's fixes landed.
#   B16    — bro-write-guard.sh: a live $(...)/`...` substitution that
#            SPANS more than one physical line inside an unquoted heredoc
#            body still blocks (round 1's per-line, no-memory extraction
#            silently dropped it); plain prose with no substitution at all
#            still passes (§2 review round 2)
#   B17    — bro-write-guard.sh: four ways to defeat cd-tracking — a
#            subshell's leading "(", pushd, cd with a variable, and cd -
#            (the last two make cwd UNKNOWN for the rest of the command,
#            which blocks only a relative target whose OWN name is already
#            journal-shaped) — plus the false positives that must not
#            follow from being this cautious (§2 review round 2)
#   B18    — bro-append.sh: v3.9 rename (§1) — OPEN and ДЕЛО, the new
#            canonical EN/RU open-item spellings, join the one-item rule
#            exactly like the old TAIL/ХВОСТ/Хвост already did; capitalized
#            "Дело:" (not ALL-CAPS) stays a non-marker the rule never sees;
#            the rejection message itself is English scaffolding around
#            whichever spelling the caller actually typed, never
#            translated Russian prose
#   B19    — bro-write-guard.sh: two v3.9 review-round-3 holes, both
#            present since 3.8.1 and both confirmed by an actual write —
#            an operator glued to the PRECEDING word, not just the
#            following one (the same hole B10 closed, now from the other
#            side); a python/node one-liner naming a BARE relative
#            journal-shaped filename now resolves it against WG_CWD, the
#            same way a bare relative shell redirect already does; plus
#            the false positives that must not follow from either fix

# ===========================================================================
# B1. write-guard: heredoc BODY text no longer confuses the guard
# ===========================================================================
echo "-- B1. write-guard: heredoc body no longer false-positives --"
new_sandbox
install_repo >/dev/null
mkws wsb1
JF_B1="$ROOT/wsb1/$(date +%F).md"
mkdir -p "$ROOT/wsb1"
printf '# bro — %s / wsb1\n\n## 09:00 · t — topic\nDECIDED: x\n' "$(date +%F)" > "$JF_B1"

# the exact reported case: a heredoc writes a DIFFERENT file (anatomy.md);
# its own body just happens to quote a journal filename as prose/example
OUT=$(deny_bash "cat > $SB/proj/anatomy.md <<'EOF'
# anatomy
see also ~/bro/wsb1/$(date +%F).md for context
EOF")
assert_eq "B1: heredoc body mentioning the journal, writing elsewhere, is allowed (single-quoted delimiter)" "$OUT" ""

OUT=$(deny_bash 'cat > '"$SB"'/proj/anatomy2.md <<"EOF"
double-quoted delimiter, also mentions '"~/bro/wsb1/$(date +%F).md"' in prose
EOF')
assert_eq "B1: heredoc body mentioning the journal, writing elsewhere, is allowed (double-quoted delimiter)" "$OUT" ""

OUT=$(deny_bash "cat > $SB/proj/anatomy3.md <<-'EOF'
	tab-indented body (<<- form), mentions ~/bro/wsb1/$(date +%F).md too
	EOF")
assert_eq "B1: heredoc body mentioning the journal is allowed under the <<- (tab-strip) form" "$OUT" ""

# same shape, but the introducer line ITSELF targets the real journal —
# must still block (the target is on the introducer line, not the body)
OUT=$(deny_bash "cat > ~/bro/wsb1/$(date +%F).md <<'EOF'
DECIDED: x
EOF")
assert_contains "B1: a heredoc whose INTRODUCER line targets the journal still blocks" "$OUT" '"decision":"block"'
assert_contains "B1: ...and names the resolved workspace in the fix-it text" "$OUT" "bro-append.sh --workspace wsb1"

# ===========================================================================
# B2. write-guard: write-TARGET precision across compound statements
# ===========================================================================
echo "-- B2. write-guard: compound-statement precision --"
OUT=$(deny_bash "cp $SB/proj/x.txt $SB/proj/other.md && cat ~/bro/wsb1/$(date +%F).md")
assert_eq "B2: cp to an unrelated file, then reading the journal, is allowed" "$OUT" ""
OUT=$(deny_bash "cat ~/bro/wsb1/$(date +%F).md && cp $SB/proj/x.txt $SB/proj/other.md")
assert_eq "B2: reading the journal, then cp to an unrelated file, is allowed" "$OUT" ""
OUT=$(deny_bash "cat $SB/proj/other.md && cp $SB/proj/x.txt ~/bro/wsb1/$(date +%F).md")
assert_contains "B2: an unrelated read, then a REAL cp onto the journal in a later clause, still blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "cat $SB/proj/other.md | tee ~/bro/wsb1/$(date +%F).md")
assert_contains "B2: piping a read into tee onto the journal still blocks" "$OUT" '"decision":"block"'

# ===========================================================================
# B3. write-guard: the full write-shape list, plus python/node one-liners
# ===========================================================================
echo "-- B3. write-guard: full write-shape list + python/node --"
JT_B3="~/bro/wsb1/$(date +%F).md"
# the plan's own literal must-block list (§2): cp x <journal>, mv x <journal>,
# rm <journal> — bare, no flags, exactly as written there
OUT=$(deny_bash "cp $SB/proj/x.txt $JT_B3"); assert_contains "B3: cp onto the journal blocks (plan's own example)" "$OUT" '"decision":"block"'
OUT=$(deny_bash "mv $SB/proj/x.txt $JT_B3"); assert_contains "B3: mv onto the journal blocks (plan's own example)" "$OUT" '"decision":"block"'
OUT=$(deny_bash "rm $JT_B3"); assert_contains "B3: bare rm (no flags) of the journal blocks (plan's own example)" "$OUT" '"decision":"block"'
# additional shapes named in §2 beyond the plan's own worked examples
OUT=$(deny_bash "perl -i -pe 's/x/y/' $JT_B3"); assert_contains "B3: perl -i onto the journal blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "install $SB/proj/x.txt $JT_B3"); assert_contains "B3: install onto the journal blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "ln -s $SB/proj/x.txt $JT_B3"); assert_contains "B3: ln onto the journal blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "dd if=/dev/zero of=$JT_B3 bs=1"); assert_contains "B3: dd of= onto the journal blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "truncate -s 0 $JT_B3"); assert_contains "B3: truncate onto the journal blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "unlink $JT_B3"); assert_contains "B3: unlink (delete) of the journal blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "rm -f $JT_B3"); assert_contains "B3: rm -f (flag before the target) of the journal still blocks" "$OUT" '"decision":"block"'
# plan's own must-PASS list (§2), not already covered by the main suite's
# own "-- 7. write guard --" section: sed -n (read) and the literal
# UNQUOTED "cat > <journal> <<EOF" must-BLOCK shape (target sits on the
# introducer line itself, independent of whatever heredoc-stripping does)
OUT=$(deny_bash "sed -n '1,5p' $JT_B3"); assert_eq "B3: sed -n (read, no -i) on the journal is allowed (plan's own example)" "$OUT" ""
OUT=$(deny_bash "cat > $JT_B3 <<EOF
x
EOF")
assert_contains "B3: unquoted 'cat > <journal> <<EOF' blocks (plan's own literal must-block example)" "$OUT" '"decision":"block"'

JABS_B3="$ROOT/wsb1/$(date +%F).md"
OUT=$(deny_bash "python3 -c \"open('$JABS_B3','a').write('x')\""); assert_contains "B3: python open(...,'a').write onto the journal blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "node -e \"require('fs').appendFileSync('$JABS_B3','x')\""); assert_contains "B3: node appendFileSync onto the journal blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "python3 -c \"print(open('$JABS_B3').read())\""); assert_eq "B3: python read-only (no write call) is allowed" "$OUT" ""

# ===========================================================================
# B4. write-guard: bypasses found while building this — closed
# ===========================================================================
echo "-- B4. write-guard: heredoc-stripping bypasses closed --"
# an UNQUOTED heredoc still undergoes $(...) / backtick substitution in the
# OUTER shell even though the outer command (cat) only writes the expanded
# text elsewhere -- $(echo pwned >> journal) would run for real regardless.
# Left unstripped (see strip_heredocs), so the scan below still sees it.
OUT=$(deny_bash 'cat > '"$SB"'/proj/notes.md <<EOF
some text $(echo pwned >> '"~/bro/wsb1/$(date +%F).md"') more text
EOF')
assert_contains "B4: \$(...) inside an UNQUOTED heredoc body still blocks (real substitution risk)" "$OUT" '"decision":"block"'

OUT=$(deny_bash 'cat > '"$SB"'/proj/notes2.md <<EOF
`echo pwned >> '"~/bro/wsb1/$(date +%F).md"'`
EOF')
assert_contains "B4: backtick substitution inside an UNQUOTED heredoc body still blocks" "$OUT" '"decision":"block"'

# a heredoc fed to a nested interpreter really executes its body, no matter
# how the delimiter is quoted -- quoting only controls the OUTER shell's
# expansion, not whether bash (the inner one) runs "echo x >> journal" as
# a real command once it reads its own stdin script
OUT=$(deny_bash "bash <<'EOF'
echo x >> ~/bro/wsb1/$(date +%F).md
EOF")
assert_contains "B4: a quoted heredoc fed to a nested bash still blocks (body really executes)" "$OUT" '"decision":"block"'

# the SAFE counterpart: a quoted heredoc fed to cat (never executes its
# stdin) mentioning a worked example must still be ALLOWED -- confirms B4's
# fixes didn't undo B1's own fix for the real reported case
OUT=$(deny_bash "cat > $SB/proj/notes3.md <<'EOF'
run: echo hi >> ~/bro/wsb1/$(date +%F).md
EOF")
assert_eq "B4: same worked-example text, quoted and fed to cat (not executed), is still allowed" "$OUT" ""

# ===========================================================================
# B5. bro-append.sh: TAIL/ХВОСТ/Хвост — packed "; " items rejected pre-write
# ===========================================================================
echo "-- B5. bro-append.sh: TAIL semicolon-packing rejected --"
new_sandbox
install_repo >/dev/null
mkws wsb5
PROJ_B5=$(proj_dir wsb5)
cd "$PROJ_B5"
JF_B5="$ROOT/wsb5/$(date +%F).md"

OUT=$(printf 'ХВОСТ: а; б; в\n' | "$BIN/bro-append.sh" --workspace wsb5 --thread t --topic s1 2>&1); RC=$?
assert_exit "B5: ХВОСТ with 2 '; ' items is rejected (exit 1)" "$RC" "1"
assert_contains "B5: rejection explains one-item-per-line and how to fix it" "$OUT" "one open item per line"
assert_file_absent "B5: rejected ХВОСТ wrote zero bytes (no journal created yet)" "$JF_B5"

OUT=$(printf 'TAIL: a; b; c\n' | "$BIN/bro-append.sh" --workspace wsb5 --thread t --topic s2 2>&1); RC=$?
assert_exit "B5: EN TAIL: with 2 '; ' items is rejected the same way" "$RC" "1"

OUT=$(printf 'Хвост: a; b; c\n' | "$BIN/bro-append.sh" --workspace wsb5 --thread t --topic s3 2>&1); RC=$?
assert_exit "B5: Capitalized RU 'Хвост:' with 2 '; ' items is rejected the same way" "$RC" "1"

OUT=$(printf '- ХВОСТ: а; б; в\n' | "$BIN/bro-append.sh" --workspace wsb5 --thread t --topic s4 2>&1); RC=$?
assert_exit "B5: a bulleted '- ХВОСТ:' line is still checked (bullet stripped before counting)" "$RC" "1"

# exactly one '; ' must pass -- this is the plan's own worked example
OUT=$(printf 'ХВОСТ: одно дело; с пояснением\n' | "$BIN/bro-append.sh" --workspace wsb5 --thread t --topic ok1 2>&1); RC=$?
assert_exit "B5: ХВОСТ with exactly 1 '; ' (one item, one clarification) passes" "$RC" "0"
assert_file_exists "B5: the passing ХВОСТ actually wrote the journal" "$JF_B5"

# the rule is scoped to TAIL only -- another marker with 2+ '; ' is untouched
OUT=$(printf 'DECIDED: a; b; c\n' | "$BIN/bro-append.sh" --workspace wsb5 --thread t --topic ok2 2>&1); RC=$?
assert_exit "B5: DECIDED with 2+ '; ' is NOT checked by this rule (passes)" "$RC" "0"

cd "$REPO_DIR"

# ===========================================================================
# B6. bro-append.sh: TAIL/ХВОСТ/Хвост — numbered-list items rejected
# ===========================================================================
echo "-- B6. bro-append.sh: TAIL numbered-list packing rejected --"
mkws wsb6
PROJ_B6=$(proj_dir wsb6)
cd "$PROJ_B6"

OUT=$(printf 'ХВОСТ: сделать (1) первое и (2) второе\n' | "$BIN/bro-append.sh" --workspace wsb6 --thread t --topic n1 2>&1); RC=$?
assert_exit "B6: '(1) ... (2)' numbered ХВОСТ is rejected" "$RC" "1"
assert_contains "B6: rejection calls out the numbered-list shape" "$OUT" "numbered list"

OUT=$(printf 'ХВОСТ: пункт 1) один пункт 2) два\n' | "$BIN/bro-append.sh" --workspace wsb6 --thread t --topic n2 2>&1); RC=$?
assert_exit "B6: '1) ... 2)' numbered ХВОСТ is rejected" "$RC" "1"

OUT=$(printf 'ХВОСТ: единственный пункт (1) без продолжения\n' | "$BIN/bro-append.sh" --workspace wsb6 --thread t --topic n3 2>&1); RC=$?
assert_exit "B6: a single '(1)' with no second item passes" "$RC" "0"

cd "$REPO_DIR"

# ===========================================================================
# B7. bro-append.sh: TAIL/ХВОСТ/Хвост — length over threshold rejected,
#     character-vs-byte boundary exercised in both directions
# ===========================================================================
echo "-- B7. bro-append.sh: TAIL length threshold (chars, byte fallback) --"
mkws wsb7
PROJ_B7=$(proj_dir wsb7)
cd "$PROJ_B7"

# byte-fallback path (this suite's own runtime locale isn't UTF-8-aware,
# same environment bro-append.sh itself will actually run under most
# often) -- 760 plain ASCII bytes/chars is unambiguous either way: over
# both the 400-char and 750-byte thresholds
LONG_ASCII=$(printf 'x%.0s' $(seq 1 760))
OUT=$(printf 'ХВОСТ: %s\n' "$LONG_ASCII" | "$BIN/bro-append.sh" --workspace wsb7 --thread t --topic long1 2>&1); RC=$?
assert_exit "B7: a 760-char/byte ХВОСТ line is rejected" "$RC" "1"

# exact boundary, char-counted explicitly under a UTF-8 locale: 400 passes,
# 401 does not -- proves the limit is inclusive at exactly 400
X400=$(printf 'x%.0s' $(seq 1 400))
OUT=$(printf 'ХВОСТ: %s' "$X400" | LC_ALL=en_US.UTF-8 "$BIN/bro-append.sh" --workspace wsb7 --thread t --topic b400 2>&1); RC=$?
assert_exit "B7: exactly 400 characters passes (boundary inclusive)" "$RC" "0"
X401=$(printf 'x%.0s' $(seq 1 401))
OUT=$(printf 'ХВОСТ: %s' "$X401" | LC_ALL=en_US.UTF-8 "$BIN/bro-append.sh" --workspace wsb7 --thread t --topic b401 2>&1); RC=$?
assert_exit "B7: exactly 401 characters is rejected" "$RC" "1"
assert_contains "B7: the 401-char rejection reports it as characters, not bytes, under a UTF-8 locale" "$OUT" "characters"

# v3.8 review fix (reviewer #2, §8): bro-append.sh now forces
# LC_ALL=en_US.UTF-8 itself for the length check (both the probe and the
# real measurement), so it counts CHARACTERS regardless of whatever locale
# the CALLING process/environment happens to have (a chat/hook environment
# commonly has none set at all) -- 380 Cyrillic characters = 760 UTF-8
# bytes; char-aware, 380<=400, passes -- and it now passes EITHER way,
# whether or not the caller's own shell happens to have LC_ALL set, proving
# the fix no longer depends on the ambient environment.
CYR380=$(python3 -c "print('ё'*380)" 2>/dev/null || perl -CS -e 'print "ё" x 380')
OUT=$(printf 'ХВОСТ: %s' "$CYR380" | "$BIN/bro-append.sh" --workspace wsb7 --thread t --topic cyr1 2>&1); RC=$?
assert_exit "B7: 380 Cyrillic chars (760 bytes) passes even with NO locale set by the caller (bro-append.sh forces its own)" "$RC" "0"
OUT=$(printf 'ХВОСТ: %s' "$CYR380" | LC_ALL=en_US.UTF-8 "$BIN/bro-append.sh" --workspace wsb7 --thread t --topic cyr2 2>&1); RC=$?
assert_exit "B7: the SAME 380 Cyrillic chars also passes when the caller's own LC_ALL is already UTF-8" "$RC" "0"

# the byte-fallback path is now reachable only when characters genuinely
# can't be counted, even after forcing UTF-8 -- 760 ASCII bytes is
# unambiguous under either counting method (760 chars AND 760 bytes, both
# over their own threshold), so this still exercises the reject message
# naming "characters" (the path actually taken on this system).
LONG_ASCII_B7=$(printf 'x%.0s' $(seq 1 760))
OUT=$(printf 'ХВОСТ: %s' "$LONG_ASCII_B7" | "$BIN/bro-append.sh" --workspace wsb7 --thread t --topic asciilong 2>&1); RC=$?
assert_exit "B7: 760 plain ASCII chars/bytes still rejects (over both thresholds either way)" "$RC" "1"
assert_contains "B7: ...and on this system (UTF-8 locale installed) the message names characters, not bytes" "$OUT" "characters"

cd "$REPO_DIR"

# deny_bash_cwd() — like the main suite's own deny_bash(), but also passes
# a "cwd" field, which deny_bash() does not (its JSON has no cwd key at
# all). Needed only for B11 below (relative-path resolution needs a
# specific, controlled cwd) — every other check here either doesn't care
# about cwd or deliberately relies on bro-write-guard.sh's own fallback
# (CWD=$(pwd) when the hook JSON carries none), which deny_bash() already
# exercises implicitly.
deny_bash_cwd() { jq -n --arg cmd "$1" --arg cwd "$2" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}' | "$BIN/bro-write-guard.sh"; }

# ===========================================================================
# B8. write-guard: UNQUOTED heredoc prose no longer false-positives, a REAL
#     substitution inside one still blocks
# ===========================================================================
echo "-- B8. write-guard: unquoted heredoc prose vs. real substitution --"
new_sandbox
install_repo >/dev/null
mkws wsb8
JT_B8="~/bro/wsb8/$(date +%F).md"

OUT=$(deny_bash "cat > $SB/proj/docs-note.md <<EOF
Do not run: echo hi >> $JT_B8
EOF")
assert_eq "B8: unquoted heredoc, plain prose mentioning the journal, writing elsewhere, is allowed" "$OUT" ""

OUT=$(deny_bash 'cat > '"$SB"'/proj/notes.md <<EOF
some text $(echo pwned >> '"$JT_B8"') more text
EOF')
assert_contains "B8: unquoted heredoc, a REAL \$(...) substitution inside it, still blocks" "$OUT" '"decision":"block"'

OUT=$(deny_bash 'cat > '"$SB"'/proj/notes2.md <<EOF
`echo pwned >> '"$JT_B8"'`
EOF')
assert_contains "B8: unquoted heredoc, a REAL backtick substitution inside it, still blocks" "$OUT" '"decision":"block"'

# regressions: quoted heredoc prose and nested-interpreter heredoc (B1/B4's
# own cases) must still behave the same after this change
OUT=$(deny_bash "cat > $SB/proj/anatomy.md <<'EOF'
mentions $JT_B8 in prose
EOF")
assert_eq "B8: quoted heredoc prose is still allowed (regression check)" "$OUT" ""
OUT=$(deny_bash "bash <<'EOF'
echo x >> $JT_B8
EOF")
assert_contains "B8: heredoc fed to a nested bash still blocks (regression check)" "$OUT" '"decision":"block"'

# ===========================================================================
# B9. write-guard: $HOME/... and ${HOME}/... recognized like ~/... / $ROOT
# ===========================================================================
echo "-- B9. write-guard: \$HOME and \${HOME} path forms --"
OUT=$(deny_bash "echo x >> \$HOME/bro/wsb8/$(date +%F).md")
assert_contains "B9: literal \$HOME/bro/... is recognized as the journal" "$OUT" '"decision":"block"'
OUT=$(deny_bash "echo x >> \${HOME}/bro/wsb8/$(date +%F).md")
assert_contains "B9: literal \${HOME}/bro/... is recognized as the journal" "$OUT" '"decision":"block"'

# ===========================================================================
# B10. write-guard: operator glued straight onto its target (no space)
# ===========================================================================
echo "-- B10. write-guard: glued operator+target --"
OUT=$(deny_bash "echo x >>$JT_B8"); assert_contains "B10: glued '>>file' blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "some-cmd 2>$JT_B8"); assert_contains "B10: glued '2>file' blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "some-cmd &>$JT_B8"); assert_contains "B10: glued '&>file' blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "some-cmd >|$JT_B8"); assert_contains "B10: glued '>|file' blocks" "$OUT" '"decision":"block"'
# regression: >| and &> must not corrupt the statement-splitter (their own
# '|'/'&' could otherwise be misread as a pipe/background separator)
OUT=$(deny_bash "cp x.txt other.md && echo hi >|$JT_B8")
assert_contains "B10: glued '>|' after '&&' still blocks (splitter doesn't eat the operator)" "$OUT" '"decision":"block"'

# ===========================================================================
# B11. write-guard: relative target resolved via cd (same command) or cwd
# ===========================================================================
echo "-- B11. write-guard: relative path via cd / hook cwd --"
mkws wsb11
DATE_B11=$(date +%F)
OUT=$(deny_bash_cwd "cd ~/bro/wsb11 && echo x >> $DATE_B11.md" "$SB/proj")
assert_contains "B11: cd into the workspace, then a bare relative filename, blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash_cwd "cd /tmp/somewhere-else && echo x >> $DATE_B11.md" "$SB/proj")
assert_eq "B11: cd somewhere UNRELATED, then the same bare filename, is allowed" "$OUT" ""
OUT=$(deny_bash_cwd "echo x >> $DATE_B11.md" "$ROOT/wsb11")
assert_contains "B11: no cd at all, but the hook's own cwd already IS the workspace, blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash_cwd "echo x >> $DATE_B11.md" "$SB/proj")
assert_eq "B11: no cd at all, cwd elsewhere, the same bare filename is allowed" "$OUT" ""
# fast-path check: cwd inside the store root, but the command text itself
# never mentions the root at all -- must still be analyzed, not skipped
OUT=$(deny_bash_cwd "cat other.txt" "$ROOT/wsb11")
assert_eq "B11: cwd inside root but a harmless unrelated command is still allowed (no false block from the cwd fast-path change)" "$OUT" ""

# ===========================================================================
# B12. write-guard: mv checks its SOURCE too; cp's source stays exempt
# ===========================================================================
echo "-- B12. write-guard: mv source vs. cp source --"
OUT=$(deny_bash "mv $JT_B8 $SB/proj/renamed.md")
assert_contains "B12: mv with the journal as SOURCE (renaming it away) blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "mv $SB/proj/x.txt $JT_B8")
assert_contains "B12: mv with the journal as DESTINATION still blocks (regression check)" "$OUT" '"decision":"block"'
OUT=$(deny_bash "cp $JT_B8 $SB/proj/copy.md")
assert_eq "B12: cp with the journal as SOURCE (a read) is allowed" "$OUT" ""
OUT=$(deny_bash "cp $SB/proj/x.txt $JT_B8")
assert_contains "B12: cp with the journal as DESTINATION still blocks (regression check)" "$OUT" '"decision":"block"'

# ===========================================================================
# B13. bro-append.sh: numbered-list check needs a REAL enumeration
# ===========================================================================
echo "-- B13. bro-append.sh: real numbered lists only --"
mkws wsb13
PROJ_B13=$(proj_dir wsb13)
cd "$PROJ_B13"

OUT=$(printf 'ХВОСТ: Оле два сообщения: (1) картина жизни Марка, (2) деньги за школу\n' | "$BIN/bro-append.sh" --workspace wsb13 --thread t --topic real1 2>&1); RC=$?
assert_exit "B13: a genuine (1)...(2) enumeration still rejects (coordinator's own example)" "$RC" "1"

OUT=$(printf 'ХВОСТ: встреча назначена на 03.09) уточнить время\n' | "$BIN/bro-append.sh" --workspace wsb13 --thread t --topic date1 2>&1); RC=$?
assert_exit "B13: a date like '03.09)' no longer false-rejects" "$RC" "0"

OUT=$(printf 'ХВОСТ: видел баг в поле (20) миграции, до этого было похоже в (15)\n' | "$BIN/bro-append.sh" --workspace wsb13 --thread t --topic field1 2>&1); RC=$?
assert_exit "B13: field references '(20)'/'(15)' no longer false-reject" "$RC" "0"

OUT=$(printf 'ХВОСТ: заказ (58Q7G810295) завис на складе\n' | "$BIN/bro-append.sh" --workspace wsb13 --thread t --topic code1 2>&1); RC=$?
assert_exit "B13: a code like '(58Q7G810295)' no longer false-rejects" "$RC" "0"

OUT=$(printf 'ХВОСТ: пункт 1) один пункт 2) два\n' | "$BIN/bro-append.sh" --workspace wsb13 --thread t --topic real2 2>&1); RC=$?
assert_exit "B13: a genuine 1)...2) enumeration still rejects" "$RC" "1"

cd "$REPO_DIR"

# ===========================================================================
# B14. bro-append.sh: "; " counted only at the top level
# ===========================================================================
echo "-- B14. bro-append.sh: top-level-only semicolon counting --"
mkws wsb14
PROJ_B14=$(proj_dir wsb14)
cd "$PROJ_B14"

OUT=$(printf 'ХВОСТ: 28.09 — отправить Ане ровно: «Аня, поздравляю тебя с днём рождения, рад что ты есть» (утверждено 01.09; не редактировать; больше ничего)\n' | "$BIN/bro-append.sh" --workspace wsb14 --thread t --topic bracket1 2>&1); RC=$?
assert_exit "B14: two '; ' inside one (...) aside no longer false-rejects (coordinator's own example)" "$RC" "0"

OUT=$(printf 'ХВОСТ: а; б; в\n' | "$BIN/bro-append.sh" --workspace wsb14 --thread t --topic plain1 2>&1); RC=$?
assert_exit "B14: two top-level '; ' (no brackets at all) still rejects" "$RC" "1"

OUT=$(printf 'ХВОСТ: сказать "иди сюда; садись; молчи" и уйти\n' | "$BIN/bro-append.sh" --workspace wsb14 --thread t --topic quote1 2>&1); RC=$?
assert_exit "B14: two '; ' inside a double-quoted span no longer false-rejects" "$RC" "0"

cd "$REPO_DIR"

# ===========================================================================
# B15. bro-append.sh: length check forces LC_ALL=en_US.UTF-8 itself
# ===========================================================================
echo "-- B15. bro-append.sh: length forces its own UTF-8 locale --"
mkws wsb15
PROJ_B15=$(proj_dir wsb15)
cd "$PROJ_B15"

CYR380_B15=$(python3 -c "print('ё'*380)" 2>/dev/null || perl -CS -e 'print "ё" x 380')
# no LC_ALL/LANG set for bro-append.sh's own process at all -- this is the
# realistic hook/chat shape the review found always fell back to the
# 750-byte threshold before (env -u unsets both just for the right-hand
# command; printf on the left of the pipe is unaffected and doesn't need
# a locale to emit a literal byte string anyway)
OUT=$(printf 'ХВОСТ: %s' "$CYR380_B15" | env -u LC_ALL -u LANG "$BIN/bro-append.sh" --workspace wsb15 --thread t --topic nolocale 2>&1); RC=$?
assert_exit "B15: 380 Cyrillic chars passes with NO locale set for bro-append.sh at all (was rejecting before this fix)" "$RC" "0"

cd "$REPO_DIR"

# ===========================================================================
# B16. write-guard: a live substitution spanning MULTIPLE physical lines
#      inside an unquoted heredoc body still blocks
# ===========================================================================
echo "-- B16. write-guard: multi-line \$(...) / backtick substitution --"
new_sandbox
install_repo >/dev/null
mkws wsb16
JT_B16="~/bro/wsb16/$(date +%F).md"

# round 1's own fix scanned each swallowed line separately with no memory
# between them, so a $(...) that OPENS on one line and CLOSES on a later
# one (completely ordinary bash) was silently missed -- the opening line
# alone never reaches depth 0, and the extractor found nothing on either
# line taken alone. Now the whole body is buffered before deciding.
OUT=$(deny_bash "cat > $SB/proj/notes.md <<EOF
prefix \$(echo pwned >> $JT_B16
echo done) suffix
EOF")
assert_contains "B16: a \$(...) substitution split across two heredoc body lines still blocks" "$OUT" '"decision":"block"'

OUT=$(deny_bash 'cat > '"$SB"'/proj/notes2.md <<EOF
prefix `echo pwned >> '"$JT_B16"'
echo done` suffix
EOF')
assert_contains "B16: a backtick substitution split across two heredoc body lines still blocks" "$OUT" '"decision":"block"'

# regression: plain prose with NO $(...) or backtick anywhere in the body
# is still discarded entirely (round 1's own B8 case), not accidentally
# swept up by this round's "contains \$( or backtick anywhere -> keep
# whole" rule -- there must be NEITHER marker anywhere for this to hold
OUT=$(deny_bash "cat > $SB/proj/docs-note.md <<EOF
Do not run: echo hi >> $JT_B16
EOF")
assert_eq "B16: unquoted heredoc, plain prose with no substitution at all, is still allowed" "$OUT" ""

# regression: a single-line substitution (round 1's own case) still blocks
OUT=$(deny_bash 'cat > '"$SB"'/proj/notes3.md <<EOF
text $(echo pwned >> '"$JT_B16"') more text
EOF')
assert_contains "B16: a single-line \$(...) substitution still blocks (round 1 regression check)" "$OUT" '"decision":"block"'

# ===========================================================================
# B17. write-guard: cd-tracking bypasses — subshell, pushd, cd with a
#      variable, cd - (unknown cwd), plus the false positives to avoid
# ===========================================================================
echo "-- B17. write-guard: cd-tracking bypasses --"
mkws wsb17
DATE_B17=$(date +%F)

OUT=$(deny_bash "( cd ~/bro/wsb17; echo x >> $DATE_B17.md )")
assert_contains "B17: a subshell's own 'cd DIR' is tracked despite the leading '('" "$OUT" '"decision":"block"'

OUT=$(deny_bash "pushd ~/bro/wsb17 && echo x >> $DATE_B17.md")
assert_contains "B17: pushd is tracked the same way cd is" "$OUT" '"decision":"block"'

OUT=$(deny_bash 'WSDIR=~/bro/wsb17; cd "$WSDIR" && echo x >> '"$DATE_B17"'.md')
assert_contains "B17: cd with a variable makes cwd unknown, and a journal-shaped relative name blocks" "$OUT" '"decision":"block"'
assert_contains "B17: ...with an honest reason naming the working directory as unresolvable" "$OUT" "unresolvable"

OUT=$(deny_bash "cd - && echo x >> $DATE_B17.md")
assert_contains "B17: cd - also makes cwd unknown, and a journal-shaped relative name blocks" "$OUT" '"decision":"block"'

# false positives that must NOT follow from being this cautious
OUT=$(deny_bash 'cd "$SOME_DIR" && echo x >> notes.txt')
assert_eq "B17: cd with a variable, but a relative name that is NOT journal-shaped, is allowed" "$OUT" ""
OUT=$(deny_bash "pushd /tmp && ls")
assert_eq "B17: pushd to an unrelated absolute dir, then a harmless command, is allowed" "$OUT" ""
OUT=$(deny_bash "cd /tmp/somewhere-else && echo x >> $DATE_B17.md")
assert_eq "B17: cd to a real, unrelated absolute dir (not unknown) still resolves normally and passes" "$OUT" ""

# ===========================================================================
# B18. bro-append.sh: v3.9 rename — OPEN/ДЕЛО join the one-item rule, old
#      spellings keep working, capitalized "Дело:" stays a non-marker, and
#      the rejection message is English scaffolding around the caller's
#      own marker spelling, never translated Russian prose
# ===========================================================================
echo "-- B18. bro-append.sh: OPEN/ДЕЛО join the one-item rule --"
new_sandbox
install_repo >/dev/null
mkws wsb18
PROJ_B18=$(proj_dir wsb18)
cd "$PROJ_B18"
JF_B18="$ROOT/wsb18/$(date +%F).md"

# all five accepted open-item spellings reject the same 2-'; '-item shape
# identically: marker_type() (bro-lib.sh) folds canonical EN (OPEN),
# canonical RU (ДЕЛО, ALL CAPS only) and the three old spellings (TAIL,
# ХВОСТ, Хвост) to the one canonical type OPEN, and this rule checks that
# canonical type, not a re-spelled keyword list -- so all five must reject
# identically, the same discipline B5-B7 already proved for the three old
# spellings alone
for kw in OPEN ДЕЛО TAIL ХВОСТ Хвост; do
  OUT=$(printf '%s: a; b; c\n' "$kw" | "$BIN/bro-append.sh" --workspace wsb18 --thread t --topic "reject-$kw" 2>&1); RC=$?
  assert_exit "B18: '$kw:' with 2 '; ' items is rejected (one-item rule now covers all five OPEN-type spellings)" "$RC" "1"
  assert_contains "B18: ...and the rejection names the shape in English ('one open item per line')" "$OUT" "one open item per line"
done
assert_file_absent "B18: all five rejected attempts above wrote zero bytes (no journal created yet)" "$JF_B18"

# exactly one '; ' still passes for the two NEW spellings, same as it
# already did for the three old ones (B5)
OUT=$(printf 'OPEN: one item; with a clarification\n' | "$BIN/bro-append.sh" --workspace wsb18 --thread t --topic openok 2>&1); RC=$?
assert_exit "B18: OPEN: with exactly 1 '; ' passes" "$RC" "0"
OUT=$(printf 'ДЕЛО: одно дело; с пояснением\n' | "$BIN/bro-append.sh" --workspace wsb18 --thread t --topic deloOK 2>&1); RC=$?
assert_exit "B18: ДЕЛО: (ALL CAPS RU) with exactly 1 '; ' passes" "$RC" "0"
assert_contains "B18: both passing lines actually landed in the journal" "$(cat "$JF_B18" 2>/dev/null)" "одно дело; с пояснением"

# the rejection message echoes back whatever spelling the caller actually
# typed -- OPEN: is plain ASCII, so its own rejection contains zero
# Cyrillic bytes anywhere, proving the scaffolding AROUND the echoed
# spelling is genuinely English prose, not just "no RU keyword happens to
# be tested here". Same byte-precise check tests/regress.sh's own INDEX.md
# Cyrillic check uses (BSD grep's bracket-range handling is locale-buggy on
# this system -- see that check's own comment for the confirmed false
# positives on plain em-dash/arrow bytes).
OUT=$(printf 'OPEN: a; b; c\n' | "$BIN/bro-append.sh" --workspace wsb18 --thread t --topic openmsg 2>&1)
CYR_IN_MSG=$(LC_ALL=C printf '%s' "$OUT" | grep -c $'[\xd0\xd1]' 2>/dev/null)
[ -n "$CYR_IN_MSG" ] || CYR_IN_MSG=0
assert_eq "B18: the OPEN: rejection message is fully English (zero Cyrillic bytes)" "$CYR_IN_MSG" "0"

# capitalized "Дело:" (not ALL-CAPS) is not a marker at all -- same
# treatment as "Состояние:"/"Инсайт:" elsewhere in this project (neither
# MRE nor MRE_NOCOLON list the mixed-case form) -- so the one-item rule
# never even sees it, and 2 '; ' items pass straight through unchecked
OUT=$(printf 'Дело: а; б; в\n' | "$BIN/bro-append.sh" --workspace wsb18 --thread t --topic delocap 2>&1); RC=$?
assert_exit "B18: capitalized 'Дело:' (not ALL-CAPS) is not a marker, so the one-item rule does not apply (passes)" "$RC" "0"
assert_contains "B18: the passing 'Дело:' line's own text actually landed in the journal" "$(cat "$JF_B18" 2>/dev/null)" "а; б; в"

cd "$REPO_DIR"

# ===========================================================================
# B19. write-guard: review-round-3 — operator glued to the PRECEDING word,
#      and python/node one-liners resolved against WG_CWD like a bare
#      relative shell redirect already is
# ===========================================================================
echo "-- B19. write-guard: operator glued left, pynode cwd-relative --"
new_sandbox
install_repo >/dev/null
mkws wsb19
DATE_B19=$(date +%F)
JT_B19="~/bro/wsb19/$DATE_B19.md"

# the coordinator's own reported case, confirmed by an actual write: glued
# on BOTH sides at once, no space anywhere around the operator
OUT=$(deny_bash "( echo 'DECIDED: sneaky'>>$JT_B19 )")
assert_contains "B19: an operator glued to the PRECEDING word (target glued to the operator too) blocks" "$OUT" '"decision":"block"'
assert_contains "B19: ...and still names the resolved workspace" "$OUT" "workspace 'wsb19'"

# glued only on the left -- the word ends exactly at the operator, so the
# target is the NEXT (whitespace-separated) word -- exercises the
# fallback-to-next-word branch of this same fix, not just the "target glued
# to the operator too" shape above
OUT=$(deny_bash "echo 'DECIDED: x'>> $JT_B19")
assert_contains "B19: an operator glued only to the PRECEDING word, target as the next word, blocks" "$OUT" '"decision":"block"'

# other operators glued to preceding text, not just >>
OUT=$(deny_bash "some-cmd'&>$JT_B19")
assert_contains "B19: '&>' glued to preceding text blocks" "$OUT" '"decision":"block"'
OUT=$(deny_bash "some-cmd'>|$JT_B19")
assert_contains "B19: '>|' glued to preceding text blocks" "$OUT" '"decision":"block"'

# regression: B10's own case (operator glued to the FOLLOWING word only,
# nothing glued on the left) must still work exactly as before -- the new
# left-side scan only runs when the prefix case found nothing, so a word
# already handled by the prefix case is never re-processed
OUT=$(deny_bash "echo x >>$JT_B19")
assert_contains "B19: glued-to-next-word only (B10's own case) still blocks (regression)" "$OUT" '"decision":"block"'

# --- pynode_hit: a BARE relative filename, resolved via WG_CWD ---
mkws wsb19py
WSDIR_B19PY="$ROOT/wsb19py"
JABS_B19="$WSDIR_B19PY/$DATE_B19.md"

OUT=$(deny_bash_cwd "python3 -c \"open('$DATE_B19.md','a').write('DECIDED: x')\"" "$WSDIR_B19PY")
assert_contains "B19: python open(...,'a') with a BARE relative filename blocks when cwd is already inside the workspace" "$OUT" '"decision":"block"'

OUT=$(deny_bash_cwd "node -e \"require('fs').appendFileSync('$DATE_B19.md','x')\"" "$WSDIR_B19PY")
assert_contains "B19: node appendFileSync with a BARE relative filename blocks when cwd is already inside the workspace" "$OUT" '"decision":"block"'

# regression: the SAME bare relative filename with cwd OUTSIDE the store is
# still allowed -- this is what was already correct before the fix
OUT=$(deny_bash_cwd "python3 -c \"open('$DATE_B19.md','a').write('DECIDED: x')\"" "$(proj_dir wsb19py)")
assert_eq "B19: the same bare relative filename with cwd OUTSIDE the store is still allowed" "$OUT" ""

# regression: the pre-existing FULL-path detection (v3.8) is untouched
OUT=$(deny_bash "python3 -c \"open('$JABS_B19','a').write('x')\"")
assert_contains "B19: python open(...,'a') with the full path (pre-existing v3.8 detection) still blocks" "$OUT" '"decision":"block"'

cd "$REPO_DIR"

# --- no NEW false positives from either fix above ---
new_sandbox
install_repo >/dev/null
OUT=$(deny_bash "awk '\$1>5' file")
assert_eq "B19: awk with a literal comparison operator ('\$1>5') is allowed (no new false positive)" "$OUT" ""
OUT=$(deny_bash "cmd 2>&1")
assert_eq "B19: fd duplication (2>&1) is allowed (no new false positive)" "$OUT" ""
OUT=$(deny_bash "x>/dev/null")
assert_eq "B19: a glued /dev/null redirect is allowed (no new false positive)" "$OUT" ""
OUT=$(deny_bash "git log --format='%h>%s'")
assert_eq "B19: a git --format string containing a literal '>' is allowed (no new false positive)" "$OUT" ""
