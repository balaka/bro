# bro v3.8 — tests/parts/c-hooks.sh (Сборщик В: §3, §4, §5/§6-opening, marker hints)
#
# Sourced by tests/regress.sh AFTER the main suite's own sections — shares
# its helpers (pass/fail, assert_*, new_sandbox, install_repo, mkws,
# proj_dir, hookjson, next_sid) and counters (PASS_N/FAIL_N/FAILED_NAMES).
# Do not `exit` from this file — a failure must fall through to the rest of
# the suite and the final summary, same discipline as every section above.
#
# Covers:
#   C1      — installer: Stop group gets bro-harvest-hook.sh too (§3)
#   C2-C4   — bro-harvest-hook.sh under the Stop event: resolves the same
#             way other hooks do, harvests, dedups, and the new
#             single-attempt "already running" lock (§3)
#   C5-C9   — bro-session-start.sh self-creates a workspace from a git
#             root, with the required exclusions, or hints /bro setup (§4)
#   C10-C11 — operator-state snapshot is first in the opening text, with
#             its age, and never breaks the hook (§5, opening half)
#   C12     — last 10 insights in the opening text, never more (§6, opening half)
#   C13     — the opening text's marker list teaches STATE:/INSIGHT: with
#             a hint on when to write each (§"Общее")

# ===========================================================================
# C1. installer: Stop group registers bro-harvest-hook.sh (async) alongside
#     bro-stop-turnstile.sh, in the SAME group (not a second top-level group)
# ===========================================================================
echo "-- C1. installer: Stop gets the async harvest hook too --"
new_sandbox
RC_C1=$(install_repo)
assert_exit "C1: installer exits 0" "$RC_C1" "0"
STOPCMDS_C1=$(jq -c '[.hooks.Stop[].hooks[].command]' "$HOME/.claude/settings.json")
assert_contains "C1: Stop still runs bro-stop-turnstile.sh" "$STOPCMDS_C1" "bro-stop-turnstile.sh"
assert_contains "C1: Stop now also runs bro-harvest-hook.sh" "$STOPCMDS_C1" "bro-harvest-hook.sh"
STOPGROUPS_C1=$(jq '.hooks.Stop | length' "$HOME/.claude/settings.json")
assert_eq "C1: still ONE Stop group (harvest hook joined it, not a new group)" "$STOPGROUPS_C1" "1"
HOOKSINGROUP_C1=$(jq '.hooks.Stop[0].hooks | length' "$HOME/.claude/settings.json")
assert_eq "C1: that group now carries 2 hooks" "$HOOKSINGROUP_C1" "2"
ASYNC_C1=$(jq -r '.hooks.Stop[0].hooks[] | select(.command | endswith("bro-harvest-hook.sh")) | .async' "$HOME/.claude/settings.json")
assert_eq "C1: bro-harvest-hook.sh under Stop is async:true" "$ASYNC_C1" "true"
TURNTO_C1=$(jq -r '.hooks.Stop[0].hooks[] | select(.command | endswith("bro-stop-turnstile.sh")) | .timeout' "$HOME/.claude/settings.json")
assert_eq "C1: bro-stop-turnstile.sh keeps its own 15s timeout" "$TURNTO_C1" "15"
# re-run: idempotent, still exactly one group with two hooks (no accumulation)
install_repo >/dev/null
STOPGROUPS_C1B=$(jq '.hooks.Stop | length' "$HOME/.claude/settings.json")
assert_eq "C1: a second install run does not accumulate Stop groups" "$STOPGROUPS_C1B" "1"
HOOKSINGROUP_C1B=$(jq '.hooks.Stop[0].hooks | length' "$HOME/.claude/settings.json")
assert_eq "C1: ...or duplicate hooks inside the group" "$HOOKSINGROUP_C1B" "2"

# ===========================================================================
# C2-C4. bro-harvest-hook.sh under the Stop event
# ===========================================================================
echo "-- C2. harvest-hook: Stop-shaped input resolves the workspace and harvests --"
new_sandbox
install_repo >/dev/null
mkws wsh
DATE_C2=$(date +%F)
PROJ_C2=$(proj_dir wsh)
cat > "$ROOT/wsh/$DATE_C2.md" <<EOF
# bro — $DATE_C2 / wsh

## 09:00 · t — topic
DECIDED: something decided via a Stop-triggered harvest pass
EOF
SID_C2=$(next_sid)
OUT_C2=$(hookjson "$PROJ_C2" "$SID_C2" p1 Stop | "$BIN/bro-harvest-hook.sh")
RC_C2=$?
assert_exit "C2: exits 0 on a Stop-shaped payload" "$RC_C2" "0"
assert_eq "C2: emits nothing (async hook, no stdout)" "$OUT_C2" ""
assert_file_exists "C2: decisions.md created from the Stop-triggered pass" "$ROOT/wsh/decisions.md"
assert_contains "C2: the new DECIDED: marker landed in the register" "$(cat "$ROOT/wsh/decisions.md")" "something decided via a Stop-triggered harvest pass"

echo "-- C3. harvest-hook: two Stop runs in a row do not duplicate --"
DCNT_C3A=$(grep -c '^### d-' "$ROOT/wsh/decisions.md")
SID_C3=$(next_sid)
hookjson "$PROJ_C2" "$SID_C3" p2 Stop | "$BIN/bro-harvest-hook.sh"
DCNT_C3B=$(grep -c '^### d-' "$ROOT/wsh/decisions.md")
assert_eq "C3: a second Stop-triggered pass adds no second record" "$DCNT_C3B" "$DCNT_C3A"

echo "-- C4. harvest-hook: single-attempt lock, no queueing --"
# 4a: a FRESH lock (another pass "in flight") -> this trigger must skip
# harvesting entirely and return fast, not wait for the lock to free up.
printf 'DECIDED: a second decision that must be skipped while the lock is held\n' >> "$ROOT/wsh/$DATE_C2.md"
mkdir "$ROOT/wsh/.harvest-hook.lock"
T0_C4=$(now_ms)
SID_C4A=$(next_sid)
hookjson "$PROJ_C2" "$SID_C4A" p3 Stop | "$BIN/bro-harvest-hook.sh"
RC_C4A=$?
T1_C4=$(now_ms)
assert_exit "C4a: exits 0 even when the workspace's lock is busy" "$RC_C4A" "0"
ELAPSED_C4=$((T1_C4-T0_C4))
if [ "$ELAPSED_C4" -lt 2000 ]; then pass "C4a: returns fast when busy (${ELAPSED_C4}ms, no 3s-class spin)"; else fail "C4a: returns fast when busy" "${ELAPSED_C4}ms"; fi
DCNT_C4A=$(grep -c '^### d-' "$ROOT/wsh/decisions.md")
assert_eq "C4a: the pending marker was NOT harvested while locked (still just 1 record)" "$DCNT_C4A" "1"
# the lock is a directory (mkdir-based, same convention as bro-lib.sh's own
# lock()) -- assert_file_exists is `-f`-based and would always fail on it
if [ -d "$ROOT/wsh/.harvest-hook.lock" ]; then pass "C4a: a busy lock is left exactly as found (not stolen)"; else fail "C4a: a busy lock is left exactly as found (not stolen)" "lock dir is gone"; fi

# 4b: the SAME lock, backdated past the 5-minute staleness threshold — a
# crash-leftover, not a live holder — must be reclaimed and harvested.
OLD_C4=$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M.%S)
touch -t "$OLD_C4" "$ROOT/wsh/.harvest-hook.lock"
SID_C4B=$(next_sid)
hookjson "$PROJ_C2" "$SID_C4B" p4 Stop | "$BIN/bro-harvest-hook.sh"
RC_C4B=$?
assert_exit "C4b: exits 0 after reclaiming a stale lock" "$RC_C4B" "0"
DCNT_C4B=$(grep -c '^### d-' "$ROOT/wsh/decisions.md")
assert_eq "C4b: a stale (>5min) lock is reclaimed and the pending marker harvested" "$DCNT_C4B" "2"
assert_file_absent "C4b: the lock is released once the pass completes" "$ROOT/wsh/.harvest-hook.lock"

# ===========================================================================
# C5-C9. bro-session-start.sh: self-created workspace from a git root (§4)
# ===========================================================================
echo "-- C5. session-start + stop-turnstile: creation is DEFERRED to the Nth response, not at open (coordinator decision after review #3: immediate creation gave 16 throwaway projects on the real disk) --"
new_sandbox
install_repo >/dev/null
mkdir -p "$SB/proj/myrepo/a/b"
( cd "$SB/proj/myrepo" && git init -q . )
SID_C5=$(next_sid)
PROJ_C5="$SB/proj/myrepo/a/b"

# (a) opening: no folder, a "will connect itself" line, .pending-project written
OUT_C5=$(hookjson "$PROJ_C5" "$SID_C5" p1 SessionStart | "$BIN/bro-session-start.sh")
RC_C5=$?
assert_exit "C5a: exits 0" "$RC_C5" "0"
if [ -d "$ROOT/myrepo" ]; then fail "C5a: nothing created yet at open" "~/bro/myrepo already exists"; else pass "C5a: nothing created yet at open"; fi
assert_not_contains "C5a: no workspace is claimed as active yet" "$OUT_C5" "active for workspace"
assert_contains "C5a: names the project and says it will connect itself" "$OUT_C5" "project 'myrepo'"
assert_contains "C5a: ...once work actually starts" "$OUT_C5" "connect itself once work actually starts"
PENDING_C5="$HOME/.claude/bro/started/$SID_C5.pending-project"
assert_file_exists "C5a: .pending-project written next to this session's start mark" "$PENDING_C5"
# git resolves symlinks in --show-toplevel (e.g. macOS's $TMPDIR itself
# sits behind one), so the stored root is the PHYSICAL path, not $SB's own
# literal (possibly symlinked) spelling — resolve the same way to compare.
REALPROJ_C5=$(cd "$SB/proj/myrepo" && pwd -P)
assert_contains "C5a: .pending-project names the workspace and its git root" "$(cat "$PENDING_C5")" "myrepo	$REALPROJ_C5"

# (b) responses 1-4: silence, no folder, no block
i=1
while [ "$i" -le 4 ]; do
  OUT_C5R=$(hookjson "$PROJ_C5" "$SID_C5" "resp$i" Stop | "$BIN/bro-stop-turnstile.sh")
  assert_eq "C5b: response $i produces no block" "$OUT_C5R" ""
  i=$((i+1))
done
if [ -d "$ROOT/myrepo" ]; then fail "C5b: still nothing created after 4 responses" "~/bro/myrepo exists too early"; else pass "C5b: still nothing created after 4 responses"; fi

# (c) response 5 (default autoCreateAfterAnswers): folder appears, blocked
# with the exact bro-append.sh invocation plus the _workspace.md instruction
OUT_C5F=$(hookjson "$PROJ_C5" "$SID_C5" resp5 Stop | "$BIN/bro-stop-turnstile.sh")
if [ -d "$ROOT/myrepo" ]; then pass "C5c: the 5th response creates ~/bro/myrepo"; else fail "C5c: the 5th response creates ~/bro/myrepo" "still missing"; fi
assert_contains "C5c: blocks" "$OUT_C5F" '"decision":"block"'
assert_contains "C5c: names the project as now connected" "$OUT_C5F" "project 'myrepo' is now connected"
assert_contains "C5c: gives the exact bro-append.sh invocation" "$OUT_C5F" "bro-append.sh --workspace myrepo"
assert_contains "C5c: also asks to fill in _workspace.md" "$OUT_C5F" "myrepo/_workspace.md (what this is / people / pointers)"
assert_file_absent "C5c: .pending-project cleaned up" "$PENDING_C5"
assert_file_absent "C5c: .pending-count cleaned up" "$HOME/.claude/bro/started/$SID_C5.pending-count"

# a later session in the same repo now resolves normally (no pending note,
# no re-creation) via the ordinary dir-slug walk-up — the folder is just there
SID_C5B=$(next_sid)
OUT_C5B=$(hookjson "$PROJ_C5" "$SID_C5B" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_not_contains "C5: a later session is not told it will connect itself again" "$OUT_C5B" "connect itself"
assert_contains "C5: ...it just resolves to the same workspace" "$OUT_C5B" "workspace 'myrepo'"

echo "-- C6. session-start: not a git repo, not connected -> /bro setup hint --"
new_sandbox
install_repo >/dev/null
mkdir -p "$SB/proj/randomfolder"
SID_C6=$(next_sid)
OUT_C6=$(hookjson "$SB/proj/randomfolder" "$SID_C6" p1 SessionStart | "$BIN/bro-session-start.sh")
RC_C6=$?
assert_exit "C6: exits 0" "$RC_C6" "0"
assert_contains "C6: opening text hints at /bro setup" "$OUT_C6" "/bro setup"
assert_not_contains "C6: no workspace name is claimed" "$OUT_C6" "active for workspace"
NEWDIRS_C6=$(ls "$ROOT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "C6: nothing was created under the bro root" "$NEWDIRS_C6" "0"

echo "-- C7. session-start: an ALREADY-connected project is unaffected, even if it is ALSO a git repo --"
new_sandbox
install_repo >/dev/null
mkws wsexisting
( cd "$(proj_dir wsexisting)" && git init -q . )   # deliberately also a repo
SID_C7=$(next_sid)
OUT_C7=$(hookjson "$(proj_dir wsexisting)" "$SID_C7" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C7: resolves via the normal (pre-existing) mechanism" "$OUT_C7" "workspace 'wsexisting'"
assert_not_contains "C7: self-create logic never fires for an already-connected project" "$OUT_C7" "connect itself"
NEWDIRS_C7=$(ls "$ROOT" | wc -l | tr -d ' ')
assert_eq "C7: no second workspace folder appeared" "$NEWDIRS_C7" "1"

echo "-- C8. session-start: \$HOME itself is a git repo -> nothing created --"
new_sandbox
install_repo >/dev/null
( cd "$HOME" && git init -q . )
mkdir -p "$HOME/somesubdir"
SID_C8=$(next_sid)
OUT_C8=$(hookjson "$HOME/somesubdir" "$SID_C8" p1 SessionStart | "$BIN/bro-session-start.sh")
RC_C8=$?
assert_exit "C8: exits 0" "$RC_C8" "0"
assert_not_contains "C8: no workspace is claimed" "$OUT_C8" "active for workspace"
assert_not_contains "C8: definitely no self-create hint for \$HOME" "$OUT_C8" "connect itself"
NEWDIRS_C8=$(ls "$ROOT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "C8: nothing created under the bro root" "$NEWDIRS_C8" "0"

echo "-- C9. session-start: Desktop / Downloads / ~/.claude / ~/bro itself are also out of bounds --"
new_sandbox
install_repo >/dev/null
mkdir -p "$HOME/Desktop"
( cd "$HOME/Desktop" && git init -q . )
SID_C9A=$(next_sid)
OUT_C9A=$(hookjson "$HOME/Desktop" "$SID_C9A" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C9: ~/Desktop as a repo root -> /bro setup hint, not a new workspace" "$OUT_C9A" "/bro setup"
assert_not_contains "C9: ~/Desktop -> no self-create hint" "$OUT_C9A" "connect itself"

new_sandbox
install_repo >/dev/null
mkdir -p "$HOME/Downloads"
( cd "$HOME/Downloads" && git init -q . )
SID_C9B=$(next_sid)
OUT_C9B=$(hookjson "$HOME/Downloads" "$SID_C9B" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C9: ~/Downloads as a repo root -> /bro setup hint" "$OUT_C9B" "/bro setup"
assert_not_contains "C9: ~/Downloads -> no self-create hint" "$OUT_C9B" "connect itself"

new_sandbox
install_repo >/dev/null
mkdir -p "$HOME/.claude/somepkg"
( cd "$HOME/.claude/somepkg" && git init -q . )
SID_C9C=$(next_sid)
OUT_C9C=$(hookjson "$HOME/.claude/somepkg" "$SID_C9C" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C9: a repo inside ~/.claude -> /bro setup hint" "$OUT_C9C" "/bro setup"
assert_not_contains "C9: repo inside ~/.claude -> no self-create hint" "$OUT_C9C" "connect itself"
NEWDIRS_C9C=$(ls "$ROOT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "C9: nothing created under the bro root for the ~/.claude case" "$NEWDIRS_C9C" "0"

new_sandbox
install_repo >/dev/null
( cd "$ROOT" && git init -q . )   # the bro store's own root is itself a repo
SID_C9D=$(next_sid)
OUT_C9D=$(hookjson "$ROOT" "$SID_C9D" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C9: the bro store's own root as a repo -> /bro setup hint, not self-adopted" "$OUT_C9D" "/bro setup"
assert_not_contains "C9: bro store root -> no self-create hint" "$OUT_C9D" "connect itself"

echo "-- C9b. session-start: /bro off still suppresses everything, self-create included --"
new_sandbox
install_repo >/dev/null
mkdir -p "$SB/proj/offrepo"
( cd "$SB/proj/offrepo" && git init -q . )
SID_C9E=$(next_sid)
mkdir -p "$HOME/.claude/bro/off"
: > "$HOME/.claude/bro/off/$SID_C9E"
OUT_C9E=$(hookjson "$SB/proj/offrepo" "$SID_C9E" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_eq "C9b: /bro off -> completely silent, no self-create, no hint" "$OUT_C9E" ""
NEWDIRS_C9E=$(ls "$ROOT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "C9b: nothing created while off" "$NEWDIRS_C9E" "0"

# ===========================================================================
# C10-C11. operator-state snapshot in the opening text (§5, opening half)
# ===========================================================================
echo "-- C10. session-start: the STATE snapshot opens the text, with its age --"
new_sandbox
install_repo >/dev/null
mkws ws10
PROJ_C10=$(proj_dir ws10)
TS_C10=$(( $(date +%s) - 3*3600 ))   # 3 hours ago
cat > "$ROOT/_state.md" <<EOF
# Состояние оператора
<!-- ts: $TS_C10 2026-09-21 14:32 -->
<!-- written by bro-harvest; do not edit by hand -->
записано: 2026-09-21 14:32 · проект ws10 · «14:32 · bro — v3.8 build»
- бодрый
- готов к деталям
EOF
SID_C10=$(next_sid)
OUT_C10=$(hookjson "$PROJ_C10" "$SID_C10" p1 SessionStart | "$BIN/bro-session-start.sh")
CTXTXT_C10=$(printf '%s' "$OUT_C10" | jq -r '.hookSpecificOutput.additionalContext')
case "$CTXTXT_C10" in
  "bro OPERATOR STATE"*) pass "C10: opening text STARTS with the operator-state block" ;;
  *) fail "C10: opening text STARTS with the operator-state block" "starts with: $(printf '%s' "$CTXTXT_C10" | head -c 80)" ;;
esac
assert_contains "C10: names its age in hours" "$CTXTXT_C10" "(3h ago)"
assert_contains "C10: shows the recorded line" "$CTXTXT_C10" "проект ws10"
assert_contains "C10: shows side 1" "$CTXTXT_C10" "бодрый"
assert_contains "C10: shows side 2" "$CTXTXT_C10" "готов к деталям"
assert_contains "C10: the snapshot is separated from the rest of the text" "$CTXTXT_C10" "готов к деталям

bro v"

echo "-- C11. session-start: STATE robustness -- missing / empty / malformed / broken ts never break the hook --"
new_sandbox
install_repo >/dev/null
mkws ws11
PROJ_C11=$(proj_dir ws11)

rm -f "$ROOT/_state.md"
SID_C11A=$(next_sid)
OUT_C11A=$(hookjson "$PROJ_C11" "$SID_C11A" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C11a: no _state.md at all -> still produces normal opening text" "$OUT_C11A" "workspace 'ws11'"
assert_not_contains "C11a: ...and no stray OPERATOR STATE block" "$OUT_C11A" "OPERATOR STATE"

: > "$ROOT/_state.md"
SID_C11B=$(next_sid)
OUT_C11B=$(hookjson "$PROJ_C11" "$SID_C11B" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C11b: empty _state.md -> still produces normal opening text" "$OUT_C11B" "workspace 'ws11'"
assert_not_contains "C11b: ...and no stray OPERATOR STATE block" "$OUT_C11B" "OPERATOR STATE"

cat > "$ROOT/_state.md" <<'EOF'
# Состояние оператора
<!-- ts: NOTANUMBER garbage -->
<!-- written by bro-harvest; do not edit by hand -->
записано: broken · проект ws11 · «garbage»
- something survives a broken ts
EOF
SID_C11C=$(next_sid)
OUT_C11C=$(hookjson "$PROJ_C11" "$SID_C11C" p1 SessionStart | "$BIN/bro-session-start.sh")
RC_C11C=$?
assert_exit "C11c: a broken (non-numeric) ts still exits 0" "$RC_C11C" "0"
assert_contains "C11c: the snapshot still prints" "$OUT_C11C" "something survives a broken ts"
assert_contains "C11c: age falls back to 'age unknown' instead of crashing" "$OUT_C11C" "age unknown"
assert_contains "C11c: the rest of the opening text still follows" "$OUT_C11C" "workspace 'ws11'"

cat > "$ROOT/_state.md" <<'EOF'
this file does not match the expected shape at all
no "записано:" line, no ts comment, nothing
EOF
SID_C11D=$(next_sid)
OUT_C11D=$(hookjson "$PROJ_C11" "$SID_C11D" p1 SessionStart | "$BIN/bro-session-start.sh")
RC_C11D=$?
assert_exit "C11d: a totally malformed _state.md still exits 0" "$RC_C11D" "0"
assert_contains "C11d: opening text is still produced" "$OUT_C11D" "workspace 'ws11'"
assert_not_contains "C11d: no bogus OPERATOR STATE block from unmatched content" "$OUT_C11D" "OPERATOR STATE"

# ===========================================================================
# C12. last 10 insights in the opening text (§6, opening half)
# ===========================================================================
echo "-- C12. session-start: last 10 insights shown, never more --"
new_sandbox
install_repo >/dev/null
mkws ws12
PROJ_C12=$(proj_dir ws12)
DATE_C12=$(date +%F)
{
  echo "# ws12 — insights"
  echo ""
  echo "> Закономерности, идеи, новые подходы к работе."
  echo ""
  i=1
  while [ "$i" -le 12 ]; do
    printf -- '- **i-%06d** · insight number %d — родился: %s · «09:%02d · t — n%d»\n' "$i" "$i" "$DATE_C12" "$i" "$i"
    i=$((i+1))
  done
} > "$ROOT/ws12/insights.md"
SID_C12=$(next_sid)
OUT_C12=$(hookjson "$PROJ_C12" "$SID_C12" p1 SessionStart | "$BIN/bro-session-start.sh")
CTXTXT_C12=$(printf '%s' "$OUT_C12" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "C12: says exactly 10 shown" "$CTXTXT_C12" "Last 10 insight"
INSHOWN_C12=$(printf '%s' "$CTXTXT_C12" | grep -c '^- insight number')
assert_eq "C12: exactly 10 insight lines appear, not 12" "$INSHOWN_C12" "10"
assert_not_contains "C12: the oldest (1st) insight is NOT shown" "$CTXTXT_C12" "insight number 1 "
assert_contains "C12: the newest (12th) insight IS shown" "$CTXTXT_C12" "insight number 12 (2026"
assert_contains "C12: the 3rd-oldest (first of the last 10) IS shown" "$CTXTXT_C12" "insight number 3 ("
# a real insight's own body can contain an em dash — must not confuse the
# id/date extraction (see bro-lib.sh's own test fixture wording)
printf -- '- **i-999999** · маркетплейс модулей для ProductOS — отдельная идея, не путать с правилом — родился: %s · «09:99 · t — dash»\n' "$DATE_C12" >> "$ROOT/ws12/insights.md"
SID_C12B=$(next_sid)
OUT_C12B=$(hookjson "$PROJ_C12" "$SID_C12B" p1 SessionStart | "$BIN/bro-session-start.sh" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "C12: a body containing its own em dash still extracts cleanly" "$OUT_C12B" "маркетплейс модулей для ProductOS — отдельная идея, не путать с правилом ($DATE_C12)"

echo "-- C12b. session-start: insights robustness -- missing / empty file --"
new_sandbox
install_repo >/dev/null
mkws ws12c
PROJ_C12C=$(proj_dir ws12c)
SID_C12C=$(next_sid)
OUT_C12C=$(hookjson "$PROJ_C12C" "$SID_C12C" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C12b: no insights.md at all -> normal opening text" "$OUT_C12C" "workspace 'ws12c'"
: > "$ROOT/ws12c/insights.md"
SID_C12D=$(next_sid)
OUT_C12D=$(hookjson "$PROJ_C12C" "$SID_C12D" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C12b: empty insights.md -> normal opening text" "$OUT_C12D" "workspace 'ws12c'"
assert_not_contains "C12b: ...and no stray 'Last N insight' line" "$OUT_C12D" "insight(s) for this workspace"

# ===========================================================================
# C13. opening text's marker list teaches STATE:/INSIGHT: with a hint (§Общее)
# ===========================================================================
echo "-- C13. session-start: marker list teaches STATE:/INSIGHT: and when to write them --"
new_sandbox
install_repo >/dev/null
mkws ws13c
SID_C13=$(next_sid)
OUT_C13=$(hookjson "$(proj_dir ws13c)" "$SID_C13" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C13: marker list includes STATE:" "$OUT_C13" "STATE:"
assert_contains "C13: marker list includes INSIGHT:" "$OUT_C13" "INSIGHT:"
assert_contains "C13: RU alias СОСТОЯНИЕ: is taught" "$OUT_C13" "СОСТОЯНИЕ:"
assert_contains "C13: RU alias ИНСАЙТ: is taught" "$OUT_C13" "ИНСАЙТ:"
assert_contains "C13: hints WHEN to write STATE: (mood/work mode changes)" "$OUT_C13" "mood"
assert_contains "C13: hints STATE: is one side per line" "$OUT_C13" "one side per line"
assert_contains "C13: hints WHEN to write INSIGHT: (pattern/idea/approach)" "$OUT_C13" "pattern, idea, or new approach"
assert_contains "C13: hints INSIGHT:'s bolded-conclusion shape" "$OUT_C13" "bold the conclusion"

# ===========================================================================
# C14-C16. review #3 fix: git worktrees and submodules collapse to ONE
# project instead of self-creating a new one per copy (§4)
# ===========================================================================
echo "-- C14. session-start: a REAL 'git worktree add' elsewhere collapses to the main repo's project --"
new_sandbox
install_repo >/dev/null
mkdir -p "$SB/proj/mainrepo14"
( cd "$SB/proj/mainrepo14" && git init -q . && git config user.email t@t.com && git config user.name t && echo x > f && git add f && git commit -q -m init )
# baseline: mainrepo14 is ALREADY a connected project -- created directly
# (mkdir, same as mkws) rather than via session-start, since creation is
# now deferred to the Nth response (coordinator decision) and that timing
# is not what THIS test is about; C5 covers the timing itself.
mkdir -p "$ROOT/mainrepo14"
( cd "$SB/proj/mainrepo14" && git worktree add -q -b wt14 "$SB/elsewhere14/linked" )
SID_C14B=$(next_sid)
OUT_C14=$(hookjson "$SB/elsewhere14/linked" "$SID_C14B" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C14: a linked worktree resolves to the SAME workspace as the main repo" "$OUT_C14" "workspace 'mainrepo14'"
assert_not_contains "C14: not announced as a pending/new project" "$OUT_C14" "connect itself"
DIRS_C14=$(ls "$ROOT" | wc -l | tr -d ' ')
assert_eq "C14: no second (garbage) workspace was created for the worktree copy" "$DIRS_C14" "1"

echo "-- C15. session-start: a submodule collapses to the SUPERPROJECT's project --"
new_sandbox
install_repo >/dev/null
mkdir -p "$SB/subowner15"
( cd "$SB/subowner15" && git init -q . && git config user.email t@t.com && git config user.name t && echo s > s.txt && git add s.txt && git commit -q -m init )
mkdir -p "$SB/proj/super15"
( cd "$SB/proj/super15" && git init -q . && git config user.email t@t.com && git config user.name t && echo x > f && git add f && git commit -q -m init \
  && git -c protocol.file.allow=always submodule add -q "$SB/subowner15" sub >/dev/null 2>&1 )
# baseline: super15 is ALREADY connected -- see C14's own comment above
mkdir -p "$ROOT/super15"
SID_C15B=$(next_sid)
OUT_C15=$(hookjson "$SB/proj/super15/sub" "$SID_C15B" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C15: a chat opened inside the submodule resolves to the SUPERPROJECT's workspace" "$OUT_C15" "workspace 'super15'"
assert_not_contains "C15: not announced as a pending/new project" "$OUT_C15" "connect itself"
DIRS_C15=$(ls "$ROOT" | wc -l | tr -d ' ')
assert_eq "C15: no second workspace was created for the submodule" "$DIRS_C15" "1"

echo "-- C16. session-start: any path under .claude/worktrees/ collapses to the repo before it --"
new_sandbox
install_repo >/dev/null
mkdir -p "$SB/proj/repo16/.claude/worktrees/abc/x"
( cd "$SB/proj/repo16" && git init -q . )
# repo16 is NOT connected yet -- creation is deferred (§ coordinator
# decision), so this checks the COLLAPSE itself: the pending candidate
# must name "repo16" (the repo before .claude/worktrees/), never "x" or
# "abc" or any other fragment of the worktree's own path.
SID_C16=$(next_sid)
OUT_C16=$(hookjson "$SB/proj/repo16/.claude/worktrees/abc/x" "$SID_C16" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C16: <repo>/.claude/worktrees/abc/x is offered as project <repo>, not a copy of its own" "$OUT_C16" "project 'repo16'"
assert_contains "C16: .pending-project's root is the repo itself, not the worktree subpath" "$(cat "$HOME/.claude/bro/started/$SID_C16.pending-project" 2>/dev/null)" "repo16	$SB/proj/repo16"
if [ -d "$ROOT/repo16" ]; then fail "C16: nothing created yet (creation is deferred)" "~/bro/repo16 already exists"; else pass "C16: nothing created yet (creation is deferred)"; fi

# once actually connected (baseline, same shortcut as C14/C15), the SAME
# worktree path must resolve to it directly, not re-offer it as pending
mkdir -p "$ROOT/repo16"
SID_C16B=$(next_sid)
OUT_C16B=$(hookjson "$SB/proj/repo16/.claude/worktrees/abc/x" "$SID_C16B" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C16: once connected, the worktree path resolves straight to it" "$OUT_C16B" "workspace 'repo16'"
DIRS_C16=$(ls "$ROOT" | wc -l | tr -d ' ')
assert_eq "C16: exactly one workspace folder, not one per worktree copy" "$DIRS_C16" "1"

# ===========================================================================
# C17. review #3 fix: every git call at session-open is capped at ~2s, so a
# hung (or malicious) git cannot stall the whole hook (§4)
# ===========================================================================
echo "-- C17. session-start: a git that hangs for 10s does not hang the hook --"
new_sandbox
install_repo >/dev/null
FAKEGIT_C17=$(mktemp -d "${TMPDIR:-/tmp}/bro-fakegit-c17.XXXXXX")
cat > "$FAKEGIT_C17/git" <<'EOF'
#!/bin/bash
sleep 10
echo "/should/never/reach/the/hook"
EOF
chmod +x "$FAKEGIT_C17/git"
mkdir -p "$SB/proj/slowrepo17"
SID_C17=$(next_sid)
T0_C17=$(now_ms)
OUT_C17=$(hookjson "$SB/proj/slowrepo17" "$SID_C17" p1 SessionStart | PATH="$FAKEGIT_C17:$PATH" "$BIN/bro-session-start.sh")
RC_C17=$?
T1_C17=$(now_ms)
assert_exit "C17: still exits 0 with a hung git on PATH" "$RC_C17" "0"
ELAPSED_C17=$((T1_C17-T0_C17))
# generous upper bound (git_2s's own backstop discards anything past ~4s
# internally; this outer check leaves headroom for a loaded CI/dev box)
# while still clearly telling "capped" (a few seconds) apart from "not
# capped at all" (the shim's full 10000ms, or worse if chained git calls
# each hung the full duration)
if [ "$ELAPSED_C17" -lt 8000 ]; then pass "C17: finishes in about 2s, not 10s (${ELAPSED_C17}ms)"; else fail "C17: finishes in about 2s, not 10s" "${ELAPSED_C17}ms (git shim sleeps 10000ms)"; fi
assert_contains "C17: still produces real opening text (not connected -- git never answered in time)" "$OUT_C17" "/bro setup"
rm -rf "$FAKEGIT_C17"

# ===========================================================================
# C18. review #3 fix: the STATE snapshot must show even when the chat opens
# outside any project (early_emit branch: not a repo, or an excluded root) —
# it is one snapshot for the whole store, not per project (§5)
# ===========================================================================
echo "-- C18. session-start: STATE snapshot shows first even when not connected to a project --"
new_sandbox
install_repo >/dev/null
TS_C18=$(( $(date +%s) - 5*3600 ))
cat > "$ROOT/_state.md" <<EOF
# Состояние оператора
<!-- ts: $TS_C18 2026-09-21 14:32 -->
<!-- written by bro-harvest; do not edit by hand -->
записано: 2026-09-21 14:32 · проект elsewhere · «14:32 · unrelated»
- раздражён
- хочет коротких ответов
EOF
mkdir -p "$SB/proj/randomfolder18"
SID_C18A=$(next_sid)
OUT_C18A=$(hookjson "$SB/proj/randomfolder18" "$SID_C18A" p1 SessionStart | "$BIN/bro-session-start.sh")
CTXTXT_C18A=$(printf '%s' "$OUT_C18A" | jq -r '.hookSpecificOutput.additionalContext')
case "$CTXTXT_C18A" in
  "bro OPERATOR STATE"*) pass "C18a: not-a-repo case still opens with the STATE snapshot" ;;
  *) fail "C18a: not-a-repo case still opens with the STATE snapshot" "starts with: $(printf '%s' "$CTXTXT_C18A" | head -c 80)" ;;
esac
assert_contains "C18a: age is shown" "$CTXTXT_C18A" "(5h ago)"
assert_contains "C18a: the /bro setup hint still follows" "$CTXTXT_C18A" "/bro setup"

( cd "$HOME" && git init -q . )   # excluded root: $HOME itself
SID_C18B=$(next_sid)
OUT_C18B=$(hookjson "$HOME" "$SID_C18B" p1 SessionStart | "$BIN/bro-session-start.sh")
CTXTXT_C18B=$(printf '%s' "$OUT_C18B" | jq -r '.hookSpecificOutput.additionalContext')
case "$CTXTXT_C18B" in
  "bro OPERATOR STATE"*) pass "C18b: excluded-root (\$HOME) case ALSO opens with the STATE snapshot" ;;
  *) fail "C18b: excluded-root (\$HOME) case ALSO opens with the STATE snapshot" "starts with: $(printf '%s' "$CTXTXT_C18B" | head -c 80)" ;;
esac
assert_contains "C18b: out-of-bounds hint still follows" "$CTXTXT_C18B" "out of bounds"

# the /bro off case must stay completely silent -- STATE must NOT leak there
new_sandbox
install_repo >/dev/null
cat > "$ROOT/_state.md" <<EOF
# Состояние оператора
<!-- ts: $TS_C18 2026-09-21 14:32 -->
<!-- written by bro-harvest; do not edit by hand -->
записано: 2026-09-21 14:32 · проект elsewhere · «14:32 · unrelated»
- раздражён
EOF
mkdir -p "$SB/proj/offrepo18"
SID_C18C=$(next_sid)
mkdir -p "$HOME/.claude/bro/off"
: > "$HOME/.claude/bro/off/$SID_C18C"
OUT_C18C=$(hookjson "$SB/proj/offrepo18" "$SID_C18C" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_eq "C18c: /bro off stays completely silent -- STATE does not leak through it either" "$OUT_C18C" ""

# ===========================================================================
# C19. review #3 fix: an empty workspace-name slug (repo name has no latin
# letters or digits) gets an HONEST message, not a false "mkdir failed" (§4)
# ===========================================================================
echo "-- C19. session-start: a repo name slug_of can't build a name from -> honest message --"
new_sandbox
install_repo >/dev/null
mkdir -p "$SB/proj/Проект"
( cd "$SB/proj/Проект" && git init -q . )
SID_C19=$(next_sid)
OUT_C19=$(hookjson "$SB/proj/Проект" "$SID_C19" p1 SessionStart | "$BIN/bro-session-start.sh")
assert_contains "C19: names the real problem (no latin letters or digits in the name)" "$OUT_C19" "no latin letters or digits"
assert_not_contains "C19: does NOT falsely claim mkdir failed" "$OUT_C19" "mkdir failed"
assert_contains "C19: still suggests /bro setup with the operator's own name" "$OUT_C19" "/bro setup"
DIRS_C19=$(ls "$ROOT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "C19: nothing was created (mkdir genuinely never ran)" "$DIRS_C19" "0"

# ===========================================================================
# C20. review #3 fix: "last 10 insights" sorts by the "родился:" date, not
# by file/discovery order (§6)
# ===========================================================================
echo "-- C20. session-start: last-10 insights sorted by date, not by append order --"
new_sandbox
install_repo >/dev/null
mkws ws20
PROJ_C20=$(proj_dir ws20)
DATE_C20=$(date +%F)
{
  echo "# ws20 — insights"
  echo ""
  i=1
  while [ "$i" -le 10 ]; do
    printf -- '- **i-%06d** · свежий инсайт номер %d — родился: %s · «09:%02d · t — n%d»\n' "$i" "$i" "$DATE_C20" "$i" "$i"
    i=$((i+1))
  done
  # appended LAST (latest discovery order) but dated YEARS ago -- a re-parse
  # of an old chronicle can do exactly this; it must not bump a real recent
  # insight out of "last 10"
  echo "- **i-999999** · древний инсайт, дописанный в реестр позже всех остальных — родился: 2020-01-01 · «09:99 · t — old»"
} > "$ROOT/ws20/insights.md"
SID_C20=$(next_sid)
OUT_C20=$(hookjson "$PROJ_C20" "$SID_C20" p1 SessionStart | "$BIN/bro-session-start.sh")
CTXTXT_C20=$(printf '%s' "$OUT_C20" | jq -r '.hookSpecificOutput.additionalContext')
assert_not_contains "C20: the 2020 insight (newest by FILE position) is excluded -- it's oldest by date" "$CTXTXT_C20" "древний инсайт"
assert_contains "C20: all 10 genuinely recent insights are shown instead" "$CTXTXT_C20" "Last 10 insight"
N_C20=$(printf '%s' "$CTXTXT_C20" | grep -c '^- свежий инсайт')
assert_eq "C20: exactly the 10 dated-recent insights appear" "$N_C20" "10"
assert_contains "C20: the oldest of the 10 RECENT ones (number 1) is still included" "$CTXTXT_C20" "свежий инсайт номер 1 ("

# same-date entries must still keep their discovery order as the tiebreak
# (no dependency on `sort`'s own stability -- NR is an explicit sort key)
new_sandbox
install_repo >/dev/null
mkws ws20b
PROJ_C20B=$(proj_dir ws20b)
{
  echo "# ws20b — insights"
  echo ""
  echo "- **i-100001** · первым по дате и по обнаружению — родился: $DATE_C20 · «09:01 · t — a»"
  echo "- **i-100002** · вторым по обнаружению, та же дата — родился: $DATE_C20 · «09:02 · t — b»"
  echo "- **i-100003** · третьим по обнаружению, та же дата — родился: $DATE_C20 · «09:03 · t — c»"
} > "$ROOT/ws20b/insights.md"
SID_C20B=$(next_sid)
OUT_C20B=$(hookjson "$PROJ_C20B" "$SID_C20B" p1 SessionStart | "$BIN/bro-session-start.sh" | jq -r '.hookSpecificOutput.additionalContext')
ORDER_C20B=$(printf '%s' "$OUT_C20B" | grep '^- ' | grep -E "первым|вторым|третьим")
FIRSTLINE_C20B=$(printf '%s\n' "$ORDER_C20B" | sed -n '1p')
LASTLINE_C20B=$(printf '%s\n' "$ORDER_C20B" | sed -n '3p')
assert_contains "C20b: same-date entries keep discovery order (1st stays first)" "$FIRSTLINE_C20B" "первым"
assert_contains "C20b: same-date entries keep discovery order (3rd stays last)" "$LASTLINE_C20B" "третьим"

# ===========================================================================
# C21. bro-stop-turnstile.sh's degraded (no bro-lib.sh) MRE_NOCOLON fallback
# had fallen behind bro-lib.sh's own canonical copy by one thing — an
# optional leading "- " bullet, added there to match MRE's own shape — and
# the coordinator asked for the literal copy here to be brought back in
# sync (same file this section already lives in). Main regress.sh's own
# "dual-case: degraded fallback" test (§10) only exercises a NON-bulleted
# colonless marker, so it would have passed even with the stale copy —
# this specifically exercises the bulleted case the sync fix was about.
# ===========================================================================
echo "-- C21. stop-turnstile degraded fallback: bulleted colonless marker still caught --"
new_sandbox
install_repo >/dev/null
mkws ws21nolib
DATE_C21=$(date +%F)
F21="$ROOT/ws21nolib/$DATE_C21.md"
printf '# bro — %s / ws21nolib\n\n## 09:00 · t — topic\n- Правило без двоеточия, с буллетом\n' "$DATE_C21" > "$F21"
mv "$BIN/bro-lib.sh" "$SB/bro-lib.sh.hidden-c21"
OUT_C21=$(hookjson "$(proj_dir ws21nolib)" "$(next_sid)" p1 Stop | "$BIN/bro-stop-turnstile.sh" 2>&1)
mv "$SB/bro-lib.sh.hidden-c21" "$BIN/bro-lib.sh"
assert_contains "C21: degraded fallback catches a BULLETED colonless Capitalized-RU marker" "$OUT_C21" "marker-like line(s) without ':'"

# ===========================================================================
# C22. re-review fix: two chats reaching the pending-project THRESHOLD at
# the same instant must not both get the "is now connected... start its
# chronicle" block — genuinely concurrent Stop calls, not sequential (§4)
# ===========================================================================
echo "-- C22. stop-turnstile: real concurrent Stop calls at the threshold -- exactly one chronicle-start block --"
new_sandbox
install_repo >/dev/null
jq '.autoCreateAfterAnswers = 1' "$CONFIG" > "$SB/cfg-c22.tmp" && mv "$SB/cfg-c22.tmp" "$CONFIG"
mkdir -p "$SB/proj/racerepo22"
( cd "$SB/proj/racerepo22" && git init -q . )
SID_C22A=$(next_sid)
SID_C22B=$(next_sid)
hookjson "$SB/proj/racerepo22" "$SID_C22A" p0 SessionStart | "$BIN/bro-session-start.sh" >/dev/null
hookjson "$SB/proj/racerepo22" "$SID_C22B" p0 SessionStart | "$BIN/bro-session-start.sh" >/dev/null
OUTFILE_C22A="$SB/c22-outA.json"
OUTFILE_C22B="$SB/c22-outB.json"
# actually backgrounded and waited on together -- not run one after another
(hookjson "$SB/proj/racerepo22" "$SID_C22A" pa1 Stop | "$BIN/bro-stop-turnstile.sh" > "$OUTFILE_C22A" 2>&1) &
C22_PIDA=$!
(hookjson "$SB/proj/racerepo22" "$SID_C22B" pb1 Stop | "$BIN/bro-stop-turnstile.sh" > "$OUTFILE_C22B" 2>&1) &
C22_PIDB=$!
wait "$C22_PIDA" "$C22_PIDB"
N_C22=$(cat "$OUTFILE_C22A" "$OUTFILE_C22B" | grep -c "is now connected")
assert_eq "C22: exactly one of the two concurrent responses gets the chronicle-start block" "$N_C22" "1"
if [ -d "$ROOT/racerepo22" ]; then pass "C22: the workspace was created exactly once (no crash from the race)"; else fail "C22: the workspace was created exactly once" "missing"; fi

# ===========================================================================
# C23. re-review fix: git_2s must not wait() on the killed process after a
# timeout — a process stuck in an uninterruptible kernel wait does not
# honor SIGKILL promptly, and waiting for it would reopen the exact
# "hook hangs past its budget" bug this whole mechanism exists to close (§4)
# ===========================================================================
echo "-- C23. session-start: git_2s does not wait() after killing a timed-out process --"
# 23a: literal coordinator scenario -- a git that ignores SIGTERM. Note:
# this cannot truly simulate a SIGKILL-immune (uninterruptible-wait) git —
# nothing in userland can trap or block SIGKILL, so this shim would die
# instantly from kill_tree's kill -9 regardless of old or new code. It is
# included because it is exactly what review #3 asked for, and it does
# confirm the observable property (hook returns in ~2s) holds; C23b below
# is the part that actually distinguishes "waits after kill" from "does not".
new_sandbox
install_repo >/dev/null
FAKEGIT_C23=$(mktemp -d "${TMPDIR:-/tmp}/bro-fakegit-c23.XXXXXX")
cat > "$FAKEGIT_C23/git" <<'EOF'
#!/bin/bash
trap '' TERM
sleep 10
echo "/should/never/reach/the/hook"
EOF
chmod +x "$FAKEGIT_C23/git"
mkdir -p "$SB/proj/trapterm23"
SID_C23=$(next_sid)
T0_C23=$(now_ms)
OUT_C23=$(hookjson "$SB/proj/trapterm23" "$SID_C23" p1 SessionStart | PATH="$FAKEGIT_C23:$PATH" "$BIN/bro-session-start.sh")
T1_C23=$(now_ms)
ELAPSED_C23=$((T1_C23-T0_C23))
if [ "$ELAPSED_C23" -lt 8000 ]; then pass "C23a: hook still returns in about 2s against a TERM-ignoring git shim (${ELAPSED_C23}ms)"; else fail "C23a: hook still returns in about 2s" "${ELAPSED_C23}ms"; fi
assert_contains "C23a: still produces real opening text" "$OUT_C23" "/bro setup"
rm -rf "$FAKEGIT_C23"

# 23b: structural check -- the actual fix. In the timeout branch of
# git_2s(), between kill_tree(...) and the `return 1` that follows it,
# there must be no `wait` call — that specific wait is what would block
# past the 2s cap against a process genuinely stuck in an uninterruptible
# kernel wait (unsimulable in a portable test, see 23a's own comment).
TIMEOUT_BRANCH_C23=$(awk '/kill_tree "\$cmd_pid"/{p=1} p{print} p&&/return 1/{exit}' "$BIN/bro-session-start.sh")
assert_not_contains "C23b: the timeout branch calls kill_tree then returns, with no wait() in between" "$TIMEOUT_BRANCH_C23" "wait \"\$cmd_pid\""
