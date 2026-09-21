#!/bin/bash
# bro v3.3 — harvest: collect typed markers from daily journals into registers.
#
#   DECIDED / РЕШЕНИЕ  → <ws>/decisions.md      TAIL / ХВОСТ  → <ws>/open.md
#   TERM    / ТЕРМИН   → <ws>/vocab.md          RULE / ПРАВИЛО → <root>/_rule-candidates.md
#   CLOSED  / ЗАКРЫТ   → flips an existing <ws>/open.md tail's [ ] to [x];
#                         creates no register record of its own (see v3.7 below)
#   INSIGHT / ИНСАЙТ   → <ws>/insights.md, numbered i-xxxxxx (see v3.8 below)
#   STATE   / СОСТОЯНИЕ → <root>/_state.md, ONE store-wide snapshot, newest
#                          record wins — not per-occurrence like the rest
#                          (see v3.8 below)
#
# Any accepted spelling of a keyword (EN ALL-CAPS, or RU ALL-CAPS/Capitalized
# — see bro-lib.sh's MRE) is folded to one canonical type by marker_type()
# in bro-lib.sh before this file switches on it — spellings live in ONE
# place (bro-lib.sh), not re-listed in every case statement below.
#
# v3.3 hardening (post-audit):
#  - markers may be indented, bulleted ("- DECIDED: …") or bold ("**DECIDED:** …");
#  - a marker's continuation lines (until blank line / next marker / next section)
#    are joined into the record body — nothing silently truncated;
#  - a malformed id token before the colon no longer drops the record (hash id used);
#  - dedup is ANCHORED to the register's own id field — "d-1" no longer hides in "d-10";
#  - every check+append runs under a per-register lock; INDEX.md is written
#    atomically (tmp + mv) under its own lock — concurrent sessions can't corrupt it;
#  - review dates are extracted by shape (YYYY-MM-DD anywhere on the line), not $NF.
#
# v3.6 — incremental. Every run used to re-read every journal from day one
# (~40 ms per marker: 30 s in a two-week-old busy workspace). Now a pass looks
# only at journals modified since the last COMPLETED pass (<ws>/.harvest-stamp),
# and inside such a journal only at the lines added since then
# (<ws>/.harvest-state: file, line count, hash of those lines). If the already
# harvested part of a journal was edited, the hash no longer matches and the
# whole file is re-read — ids are stable, so nothing is duplicated. Stamp and
# state advance only when the pass finished and every register lock was
# obtained; a killed or contended pass is simply redone next time.
# A record is taken as it stands the first time a pass sees it: once an id is
# in a register, a later pass over the same (or a re-read) marker with the
# SAME body is a no-op, and a DIFFERENT body under that id is a collision —
# written under a disambiguated id, the original left untouched. Nothing a
# later pass sees ever rewrites or shrinks what an earlier pass already wrote.
# --full ignores stamp and state (use after restoring files with old mtimes,
# or after hand-removing records from a register).
#
# v3.7 — glue fix. Before 3.7, a marker's body swallowed every non-blank line
# after it up to the next blank line / marker / section — a writer who forgot
# the blank line got an unrelated paragraph glued verbatim into the register
# record (and a later pass would re-glue a longer body under a NEW id, since
# the id is a hash of the marker's text — the second-record duplication this
# version now avoids). Now a marker's harvested body is exactly its own
# physical line; adjacent non-blank lines are never folded into it — nothing
# is lost (the journal itself keeps them forever, append-only), just not
# duplicated into a register. Each pass counts markers this happened to and,
# only when that count is > 0, say()s one line and appends one line to
# ~/.claude/bro/health.log — passive, never a block.
# Id stability across this change: an id is still a hash of the marker's own
# line PLUS whatever adjacent text would have glued onto it (bro-lib.sh's
# MRE match through blank line/next marker/next section, same boundary as
# before) — only the harvested BODY dropped the glue, not the id input. So a
# --full pass, or an incremental pass forced wide by an edited prefix, over a
# journal written before this upgrade and left BYTE-IDENTICAL since (marker
# line AND every adjacent line that would have glued onto it) recomputes the
# SAME id a pre-3.7 (or earlier v3.7) pass already filed a record under, and
# it's recognized as already seen — never duplicated, never rewritten.
#
# Known limitation, deliberately NOT fixed here: that "byte-identical" clause
# is load-bearing. Editing ANY line inside the old glue span — even one v3.7
# no longer stores in the register body — still changes the hashed text and
# therefore the id, so the next pass computes a NEW id, doesn't find it in
# the register, and appends a second record for what is, in the persisted
# BODY, the exact same single marker line (confirmed live: editing only a
# word in an already-dropped continuation line produces a second `decisions.md`
# entry for an unchanged `DECIDED:` line). This is not a new v3.7 regression
# — the pre-3.7 script hashed the same joined text and had the identical
# exposure — but this header previously overclaimed that the fix above
# closed it; it does not.
# Why it's not fixed here: the two properties are in real tension and this
# file can't satisfy both with a small change. Hashing only the marker's own
# physical line (what v3.7 actually stores) would make the id immune to
# glue-tail edits, but it would ALSO change the id of every already-glued
# marker in an existing store on its very first post-upgrade read — breaking
# the OTHER, more load-bearing guarantee this release depends on: a first
# pass over an existing v3.6/v3.7 store must not duplicate what's already
# harvested (see tests/regress.sh's `--all --full` idempotency coverage).
# Properly closing this gap needs either a one-time id-reconciliation
# migration or persisting each record's original glue-boundary hash
# separately from its id, so a later edit inside vs. outside that boundary
# can be told apart — both bigger than this release's build-order steps
# 1/2/4/5. Until then: editing journal prose adjacent to an already-
# harvested marker can produce an extra register record for the same
# underlying event — harmless (nothing lost, nothing silently rewritten),
# same as any other id collision this file already handles, just not the
# airtight guarantee the words used to claim.
#
# v3.7 — CLOSED:/ЗАКРЫТ: marker (§1 of the v3.7 plan). Before this, closing a
# tail meant hand-editing open.md directly — the one register mutation in the
# whole codebase that went through no lock() and no script at all. Now
# "CLOSED <id>: <text>" (id = the exact id already printed on that tail's own
# line in open.md — not optional, and not hashed the way other markers' ids
# are: nothing here could guess which tail is meant) flips that one line's
# "- [ ]" to "- [x] … — закрыт <journal-date>: <text>" under lock("$OPEN"),
# touching no other byte. Already-[x] is a no-op — idempotent, so a --full
# pass or a repeated CLOSED for the same id never double-closes. An id this
# workspace's open.md doesn't have open (wrong id, typo, already closed under
# a different id, or omitted entirely) is a CLOSE-MISS: appended to
# <ws>/.close-misses.log, deduped on the marker's own stable per-occurrence
# hash (H below) so a --full re-read never re-logs the same miss twice, and
# surfaced as a count at the next session start — a CLOSE-MISS is a persistent
# log, never a silently-lost one-off. CLOSED creates no register record.
#
# v3.8 — INSIGHT/ИНСАЙТ and STATE/СОСТОЯНИЕ (§5, §6 of the v3.8 plan), plus
# the near-marker counter (§1).
#   INSIGHT behaves like TERM: each occurrence gets its own id (i-xxxxxx)
#   and a line in <ws>/insights.md — same shape and dedup as vocab.md (grep
#   the id, append only if not already there).
#   STATE is NOT per-occurrence. Every STATE/СОСТОЯНИЕ line under the SAME
#   '## HH:MM · …' journal section is one SIDE of one snapshot; all of a
#   pass's STATE lines are collected into $RUN/state-lines (date, section,
#   body) while journals are scanned, and only AFTER the whole pass (below,
#   past the per-journal loop) is the newest-timestamped group in THIS pass
#   compared against whatever <root>/_state.md already holds — older never
#   overwrites newer, so re-reading old journals (--full, or a wide
#   incremental re-read after an edited prefix) can never regress the
#   operator's current snapshot. Timestamp = journal filename date + the
#   section's own HH:MM (epoch_of(), bro-lib.sh) — not parse order.
#   Near-marker counter: lines that look like an intended marker but that
#   MRE does not recognize (wrong RU grammatical form, lowercase RU, or a
#   dash where the colon belongs — NEAR_MRE/NEAR_MRE_DASH, bro-lib.sh) are
#   counted per pass and, only when the count is > 0, reported the same way
#   the pre-existing glue-drop counter already is: one say() line and one
#   passive ~/.claude/bro/health.log line, never a block.
#
# Deterministic, idempotent, append-only. Registers' statuses: open.md's tail
# checkboxes are flipped by CLOSED:/ЗАКРЫТ: (above, under lock, never by
# hand); everything else (supersede a decision, accept/reject a rule
# candidate) is still managed by hand.
# Usage: bro-harvest.sh [--root <dir>] [--workspace <name> | --all] [--full] [--quiet]

set -uo pipefail

# bro-lib.sh sits next to this script in both layouts this project ships
# (repo scripts/, installed ~/.claude/bro/bin/) — see its own header. Never
# fail silently on a missing lib: without it there is no lock()/MRE and
# every harvest below would be wrong in a way that's easy to miss.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -z "$LIB_DIR" ] || [ ! -f "$LIB_DIR/bro-lib.sh" ]; then
  echo "[bro-harvest] bro-lib.sh not found next to $0 — reinstall (bro-install.sh) or check the repo layout" >&2
  exit 1
fi
. "$LIB_DIR/bro-lib.sh"

CONFIG="$HOME/.claude/bro-config.json"
if command -v jq >/dev/null 2>&1; then
  ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
else
  ROOT="~/bro"
fi
ROOT="${ROOT/#\~/$HOME}"
ONLY_WS=""; ALL=0; QUIET=0; FULL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; ROOT="${ROOT/#\~/$HOME}"; shift ;;
    --workspace) ONLY_WS="$2"; shift ;;
    --all) ALL=1 ;;
    --full) FULL=1 ;;
    --quiet) QUIET=1 ;;
  esac
  shift
done
[ -d "$ROOT" ] || exit 0
[ -z "$ONLY_WS" ] && ALL=1

say() { [ "$QUIET" = 1 ] || echo "[bro-harvest] $*"; }

# lock()/unlock() now come from bro-lib.sh (sourced above).

ensure_register() { # call ONLY under lock($1)
  [ -f "$1" ] && return
  printf '# %s\n\n> %s\n> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.\n\n' "$2" "$3" > "$1"
}

# write_state_snapshot() — v3.8 (§5). $1=workspace $2=record date (YYYY-MM-DD)
# $3=record HH:MM $4=record epoch (epoch_of(), bro-lib.sh) $5=the record's
# own "## HH:MM · …" text (sans "## ", for the quoted attribution line)
# $6=the sides, one per line (already just the marker bodies, in the order
# they appeared in the journal).
# "Newest wins": $ROOT/_state.md holds exactly ONE snapshot for the whole
# store, never a history. Reads whatever <!-- ts: N … --> epoch is already
# in the file (0 if the file doesn't exist yet) and overwrites only when
# $4 is strictly greater — so a --full re-read of old journals, or two
# workspaces both finding a STATE line in the same --all pass, can never
# make the file regress to something older than what an operator already
# has. Lock + tmp-file + mv: atomic, same discipline as every other write
# in this file (INDEX.md at the bottom of this script is the closest
# cousin — also a single whole-file rewrite under lock, not an append).
# Coordinator follow-up: a busy lock used to just mean "this candidate is
# lost" — the journal line that produced it is already past FROM by the
# time harvest gets here, so no later pass would ever see it again. Now a
# busy lock hands the candidate to save_state_pending() instead of
# dropping it — see that function and flush_state_pending() just below.
# Returns 0 once the lock was obtained (whether or not it actually won the
# newest-wins compare — either way the candidate was fairly considered);
# 1 only when the lock itself could not be obtained.
write_state_snapshot() {
  local ws="$1" d="$2" t="$3" ep="$4" sec="$5" sides="$6"
  local sf="$ROOT/_state.md" cur=0 tmp side
  if ! lock "$sf"; then
    save_state_pending "$ws" "$d" "$t" "$ep" "$sec" "$sides"
    return 1
  fi
  if [ -f "$sf" ]; then
    cur=$(sed -n 's/^<!-- ts: \([0-9][0-9]*\) .*-->$/\1/p' "$sf" | head -1)
    [ -n "$cur" ] || cur=0
  fi
  if [ "$ep" -gt "$cur" ] 2>/dev/null; then
    tmp=$(mktemp "$ROOT/.state.XXXXXX" 2>/dev/null || echo "$ROOT/.state.$$")
    {
      echo "# Состояние оператора"
      printf '<!-- ts: %s %s %s -->\n' "$ep" "$d" "$t"
      echo "<!-- written by bro-harvest; do not edit by hand -->"
      printf 'записано: %s %s · проект %s · «%s»\n' "$d" "$t" "$ws" "$sec"
      printf '%s\n' "$sides" | while IFS= read -r side; do
        [ -n "$side" ] && printf -- '- %s\n' "$side"
      done
    } > "$tmp" && mv "$tmp" "$sf" \
      && say "+ STATE snapshot ($ws, $d $t) → $sf"
  fi
  unlock "$sf"
}

# save_state_pending() — v3.8 (§5), coordinator follow-up. Called ONLY by
# write_state_snapshot() above when $ROOT/_state.md's own lock is busy.
# $ROOT/.state-pending holds AT MOST ONE candidate — same newest-wins rule
# as _state.md itself (compares against whatever is already pending, by
# epoch, before overwriting), so a run of several failed attempts across
# passes still converges on the single newest one, never a growing queue.
# On-disk shape: line 1 is "ws\td\tt\tep\tsec" (sec last, so it may itself
# contain a literal tab — read with 5 named vars below absorbs everything
# past the 4th tab into sec, same trick bash's own `read` already gives
# every other tab-separated file in this project); the rest of the file is
# the sides, one per line.
# If .state-pending's OWN lock is busy too (a genuine pile-up, or two
# passes racing at once) the candidate is dropped rather than risk
# corrupting the pending file — rare, and the operator's state view is
# simply not updated this one time, same low-stakes tradeoff already
# accepted for a busy _state.md lock before this fix existed at all.
save_state_pending() {
  local ws="$1" d="$2" t="$3" ep="$4" sec="$5" sides="$6"
  local pf="$ROOT/.state-pending" cur=0 tmp
  lock "$pf" || return 1
  if [ -f "$pf" ]; then
    cur=$(head -1 "$pf" 2>/dev/null | cut -f4)
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  fi
  if [ "$ep" -gt "$cur" ] 2>/dev/null; then
    tmp=$(mktemp "$ROOT/.state-pending.XXXXXX" 2>/dev/null || echo "$ROOT/.state-pending.$$")
    { printf '%s\t%s\t%s\t%s\t%s\n' "$ws" "$d" "$t" "$ep" "$sec"; printf '%s\n' "$sides"; } > "$tmp" \
      && mv "$tmp" "$pf"
  fi
  unlock "$pf"
}

# flush_state_pending() — v3.8 (§5), coordinator follow-up. Call at the
# START of every STATE-snapshot attempt (harvest_ws does, just below),
# before even looking at this pass's own candidate — a pending candidate
# from an earlier pass's lock contention is, by definition, older, so it
# must be offered to _state.md first (write_state_snapshot's own
# newest-wins compare decides whether it actually wins). Removes
# .state-pending once it has been fairly considered — written (it was
# newer) or discarded (something newer already won) — either way there is
# nothing left to retry. Leaves the file untouched if the lock is STILL
# busy, for the next call (next workspace in this pass, or next pass) to
# try again — never loses it, never loops.
# Coordinator fix (§2): the read used to be unlocked AND in two separate
# commands (a `read` for the metadata line, then a `tail` for the sides) —
# a save_state_pending() landing a NEWER candidate exactly between those
# two reads produced a hybrid record (one candidate's metadata glued to a
# DIFFERENT candidate's sides), and the real new candidate could then be
# deleted having never actually been written anywhere. Now the whole file
# is read in ONE command under $pf's own lock, and — since
# write_state_snapshot() below is called only AFTER that lock is released
# (holding it across write_state_snapshot's own _state.md lock would risk
# the two locks deadlocking against each other) — .state-pending is only
# ever deleted after re-locking and confirming its bytes still match
# exactly what was just processed; a fresher candidate that arrived while
# write_state_snapshot() was running is left in place for the next call.
flush_state_pending() {
  local pf="$ROOT/.state-pending" raw firstline ws d t ep sec sides
  [ -f "$pf" ] || return 0
  lock "$pf" || return 0   # busy — leave it for the next attempt
  raw=$(cat "$pf" 2>/dev/null)
  unlock "$pf"
  [ -n "$raw" ] || return 0
  firstline="${raw%%$'\n'*}"
  sides="${raw#*$'\n'}"
  [ "$sides" = "$raw" ] && sides=""   # no newline at all in the file — malformed, no sides to recover
  IFS=$'\t' read -r ws d t ep sec <<< "$firstline"
  case "$ep" in ''|*[!0-9]*) return 0 ;; esac   # malformed — leave it; deleting could throw away a newer write that lands right after
  if write_state_snapshot "$ws" "$d" "$t" "$ep" "$sec" "$sides"; then
    lock "$pf" || return 0
    [ -f "$pf" ] && [ "$(cat "$pf" 2>/dev/null)" = "$raw" ] && rm -f "$pf"
    unlock "$pf"
  fi
}

# MRE now comes from bro-lib.sh (sourced above) — the one canonical
# marker-keyword regex, shared with the stop hook and bro-append.sh.

harvest_ws() {
  local WS="$1" WS_DIR="$ROOT/$1"
  [ -d "$WS_DIR" ] || return 0
  local DEC="$WS_DIR/decisions.md" OPEN="$WS_DIR/open.md" VOC="$WS_DIR/vocab.md" INS="$WS_DIR/insights.md"
  local RCAND="$ROOT/_rule-candidates.md"

  # ---- which journals, and from which line (v3.6 incremental) ----
  local STAMP="$WS_DIR/.harvest-stamp" STATE="$WS_DIR/.harvest-state"
  local RUN INCR=1 F B DATE DATE10 TOTAL FROM PREV PN PS BACK COPY CPRC
  # scratch dirs of passes that were killed long ago
  find "$WS_DIR" -maxdepth 1 -type d -name '.harvest-run.*' -mmin +60 -exec rm -rf {} + 2>/dev/null
  # mktemp, not $$: a leftover dir of a killed pass plus a reused pid must not silence this workspace
  RUN=$(mktemp -d "$WS_DIR/.harvest-run.XXXXXX" 2>/dev/null) || { say "$WS: cannot create a scratch dir in $WS_DIR — workspace skipped"; return 0; }
  : > "$RUN/start"   # its mtime is the start of this pass — it becomes the stamp if the pass completes
  # …minus 2 s: where mtimes are coarse (1–2 s), a journal written in the very second a pass
  # starts would tie with the stamp and never look "newer". Re-reading costs nothing. UTC: no DST.
  BACK=$(TZ=UTC0 date -v-2S +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC0 date -d '2 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$BACK" ] && TZ=UTC0 touch -t "$BACK" "$RUN/start" 2>/dev/null
  # v3.8 (§4, coordinator fix): "*.md" after the date, not an exact
  # "YYYY-MM-DD.md" — a journal named with a topic suffix
  # (2026-04-22-offerings-banner.md, a real filename in this operator's
  # store) matched neither branch below before this, --full included, and
  # was invisible to harvest forever, silently, with no error anywhere.
  if [ "$FULL" = 1 ] || [ ! -f "$STAMP" ] || [ ! -f "$STATE" ]; then
    INCR=0
    find "$WS_DIR" -maxdepth 1 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.md" -type f | sort > "$RUN/list"
  else
    find "$WS_DIR" -maxdepth 1 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.md" -type f -newer "$STAMP" | sort > "$RUN/list"
  fi
  say "$WS: $(wc -l < "$RUN/list" | tr -d ' ') journal(s) to read$([ "$INCR" = 0 ] && echo ' (full pass)')"

  while IFS= read -r F; do
    B=$(basename "$F"); DATE="${B%.md}"
    # DATE10: the first 10 characters of the filename — always a clean
    # "YYYY-MM-DD" even when the file has a topic suffix (DATE above does
    # not: for "2026-04-22-offerings-banner.md" it's the whole
    # "2026-04-22-offerings-banner", fine for the "родилось: …" attribution
    # text every OTHER register already prints, but STATE's epoch_of()
    # (bro-lib.sh) below needs an exact date, not a slug — v3.8 (§4).
    DATE10="${B:0:10}"

    # v3.8 (§3, coordinator fix): copy the journal under the SAME lock
    # bro-append.sh takes on it (lock(), bro-lib.sh) — then parse ONLY the
    # copy from here on, never the live file again. Harvest now runs after
    # every response (Stop hook, sborshchik V's async hook), so the window
    # where bro-append.sh is mid-write (lock held, section header already
    # on disk, body not yet flushed) is no longer rare. Reading the live
    # file could catch "DECIDED: chose Pos" moments before bro-append.sh
    # finishes writing "DECIDED: chose Postgres over Mongo" to that same
    # physical line — and since a marker's id is a hash of its text, the
    # later-completed line hashes differently and gets filed as a SECOND,
    # permanent record; the truncated one is never removed, only ever
    # added next to.
    # A held lock is still not proof enough by itself: a writer killed
    # mid-write leaves a stale lock that lock()'s own >5min reclaim rule
    # will eventually take over, so belt-and-braces — if the COPY's last
    # physical line has no trailing '\n', it is dropped from THIS pass
    # entirely below (excluded from TOTAL, never parsed, never counted
    # toward the incremental state hash) rather than trusted. Nothing is
    # lost, only deferred: it becomes visible normally, complete, the
    # moment it does end in '\n' — which happens on bro-append.sh's very
    # next write to this journal (its own "repair a dangling last line"
    # step guarantees that).
    rm -f "$RUN/fail"
    COPY="$RUN/journal-copy"
    rm -f "$COPY"
    if ! lock "$F"; then
      say "$WS: could not lock $B to copy it — skipped this pass, will retry next pass"
      : > "$RUN/fail"
    else
      cp "$F" "$COPY" 2>/dev/null; CPRC=$?
      unlock "$F"
      if [ "$CPRC" -ne 0 ] || [ ! -f "$COPY" ]; then
        say "$WS: could not copy $B — skipped this pass, will retry next pass"
        : > "$RUN/fail"
      fi
    fi
    if [ -f "$RUN/fail" ]; then
      : > "$RUN/incomplete"
      continue
    fi

    # awk 'END{print NR}', not `wc -l`: wc -l counts NEWLINES, so a journal
    # whose last physical line has no trailing '\n' undercounts by one —
    # see the dangling-last-line comment above for why that can still
    # legitimately happen even though $COPY was taken under lock.
    TOTAL=$(awk 'END{print NR}' "$COPY" 2>/dev/null); [ -n "$TOTAL" ] || TOTAL=0
    if [ "$TOTAL" -gt 0 ] && [ -n "$(tail -c1 "$COPY" 2>/dev/null)" ]; then
      TOTAL=$((TOTAL-1))   # dangling last line, no trailing '\n' — not this pass's business
    fi
    FROM=0
    if [ "$INCR" = 1 ]; then
      # lines already harvested stay skipped only while they are byte-identical
      PREV=$(awk -F'\t' -v f="$B" '$1 == f { print $2 "\t" $3; exit }' "$STATE" 2>/dev/null)
      PN="${PREV%%$'\t'*}"; PS="${PREV#*$'\t'}"
      if [ -n "$PREV" ] && [ "$PN" -gt 0 ] 2>/dev/null && [ "$TOTAL" -ge "$PN" ] \
         && [ "$(head -n "$PN" "$COPY" | shasum | cut -c1-40)" = "$PS" ]; then
        FROM="$PN"
      fi
    fi
    # awk emits: LINE_NO \x1f SECTION \x1f BODY(own line only) \x1f HASHTEXT(joined) \x1e
    # per marker record (only markers born after line FROM; lines past TOTAL
    # belong to the next pass). v3.7 glue fix: BODY is exactly the marker's
    # own physical line — adjacent non-blank lines (until blank/next marker/
    # next section, same boundary as before) are counted (ndrop) but no
    # longer folded in. HASHTEXT still glues them, same as pre-3.7 BODY did —
    # it feeds only the id hash below, so an id computed over an unchanged
    # old journal doesn't change just because what gets STORED now does (see
    # the id-stability note in this file's header).
    # v3.8 (§1): also counts near-miss lines (NEAR_MRE/NEAR_MRE_DASH, from
    # bro-lib.sh) in the same from-gated window — a line only counts once it
    # is past FROM, same discipline as ndrop above, so a re-scanned already-
    # harvested prefix never gets re-logged pass after pass. One example
    # (the first near-miss found) rides along for health.log; a literal tab
    # in it would break nearfile's own tab-separated shape, so it's
    # scrubbed before being written out. Coordinator fix (§7): the example
    # is captured FULL-LENGTH here, not cut to 60 here — awk's substr()/
    # length() are byte- or character-precise depending on the ambient
    # locale (a hook's environment cannot be relied on to set one), so a
    # cut done here confirmed live to land mid-character on Cyrillic text —
    # after which health.log reads as binary to grep/tail from that point
    # on. The byte-safe cut now happens once, in bash, via bro-lib.sh's
    # utf8_trunc() — see the aggregation below.
    awk -v mre="$MRE" -v from="$FROM" -v to="$TOTAL" -v dropfile="$RUN/dropped" \
        -v near="$NEAR_MRE" -v neardash="$NEAR_MRE_DASH" -v nearfile="$RUN/near" '
      function flush() {
        if (ln && ln > from) {
          printf "%d\x1f%s\x1f%s\x1f%s\x1e", ln, sec, body, joined
          if (hasdrop) ndrop++
        }
        ln=0; body=""; joined=""; hasdrop=0
      }
      NR > to { exit }
      /^## / { flush(); sec=$0; sub(/^## /, "", sec); next }
      /^[[:space:]]*$/ { flush(); next }
      $0 ~ mre { flush(); ln=NR; body=$0; joined=$0; next }
      (NR > from) && ($0 ~ near || $0 ~ neardash) {
        nnear++
        if (nearex == "") { nearex = $0; gsub(/\t/, " ", nearex) }
      }
      { if (ln) { line=$0; sub(/^[[:space:]]+/, "", line); joined=joined " " line; hasdrop=1 } }
      END {
        flush()
        printf "%d\n", ndrop >> dropfile; close(dropfile)
        printf "%d\t%s\n", nnear, nearex >> nearfile; close(nearfile)
      }
    ' "$COPY" | while IFS=$'\x1f' read -r -d $'\x1e' LN SEC LINE HTXT; do
      [ -n "$LINE" ] || continue
      # normalize: strip indent and bullet, split on the FIRST colon, THEN
      # strip ** only from the keyword side (HEAD). Coordinator fix (§6):
      # `s/\*\*//g` used to run on the whole line before the split, so any
      # bold the OPERATOR wrote INSIDE the body (INSIGHT's own spec: "вывод
      # жирным") — "ИНСАЙТ: **вывод** — пояснение" — lost its ** along with
      # the marker's own optional bold-wrapping. BODY is now taken from the
      # bullet-stripped line as-is, never touched by the ** strip below.
      local CLEAN KW HEAD TOK ID BODY H CH OLN OLDLINE NEWLINE MISS OTMP
      CLEAN=$(printf '%s' "$LINE" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?//')
      HEAD="${CLEAN%%:*}"                      # keyword [+ optional token], ** (if any) still in place
      BODY="${CLEAN#*:}"; BODY="${BODY# }"      # everything after the first colon — untouched, own ** intact
      HEAD=$(printf '%s' "$HEAD" | sed -E 's/\*\*//g')   # now safe: only the keyword side loses its **
      KW="${HEAD%% *}"
      KW="${KW%%-*}"; KW="${KW%%–*}"; KW="${KW%%—*}"   # strip «-кандидат»-style suffixes
      TOK=""; [ "$HEAD" != "${HEAD%% *}" ] && TOK="${HEAD#* }"
      # id hash over HTXT (joined, pre-3.7-shaped), not LINE/BODY (own line
      # only) — see the id-stability note in this file's header: this is
      # what keeps a re-read of an unchanged old journal computing the same id.
      H=$(printf '%s|%s' "$(basename "$F")" "$HTXT" | shasum | cut -c1-6)
      CH=$(printf '%s' "$BODY" | shasum | cut -c1-4)
      # v3.8 (§1): KW is whatever spelling MRE actually matched (either RU
      # writing, or EN ALL-CAPS) — marker_type() (bro-lib.sh) folds it to
      # ONE canonical token so the two switches below (id prefix, register
      # dispatch) list a type exactly once each, not once per spelling.
      local KC; KC=$(marker_type "$KW") || continue
      if printf '%s' "$TOK" | grep -qE '^[A-Za-z]-[A-Za-z0-9-]+$'; then
        ID="$TOK"
      else
        [ -n "$TOK" ] && BODY="$TOK: $BODY"    # noise token was not an id — keep it in the body
        case "$KC" in
          DECIDED)  ID="d-$H" ;;
          RULE)     ID="r-$H" ;;
          TAIL)     ID="t-$H" ;;
          TERM)     ID="v-$H" ;;
          REJECTED) ID="o-$H" ;;
          CLOSED)   ID="c-$H" ;;  # no real tail id given — unresolvable; routes to CLOSE-MISS below
          STATE)    ID="s-$H" ;;  # unused by STATE's own branch below (no per-occurrence register) — computed anyway to keep this switch's shape uniform
          INSIGHT)  ID="i-$H" ;;
        esac
      fi
      local SRC="$DATE · «${SEC:-без секции}»"

      case "$KC" in
        REJECTED)
          lock "$DEC" || { : > "$RUN/fail"; continue; }
          ensure_register "$DEC" "$WS — decisions" "Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать."
          if grep -q "^### ${ID} (" "$DEC"; then
            if ! grep -A1 "^### ${ID} (" "$DEC" | grep -qF "$(printf '%s' "$BODY" | cut -c1-50)"; then
              ID="${ID}x${CH}"
              grep -q "^### ${ID} (" "$DEC" || {
                printf '### %s (%s) [rejected]\n%s\n— родилось: %s\n\n' "$ID" "$DATE" "$BODY" "$SRC" >> "$DEC"
                say "COLLISION: id reused — wrote rejection $ID → $WS/decisions.md"; }
            fi
          else
            printf '### %s (%s) [rejected]\n%s\n— родилось: %s\n\n' "$ID" "$DATE" "$BODY" "$SRC" >> "$DEC"
            say "+ rejection $ID → $WS/decisions.md"
          fi
          unlock "$DEC"
          ;;
        DECIDED)
          lock "$DEC" || { : > "$RUN/fail"; continue; }
          ensure_register "$DEC" "$WS — decisions" "Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать."
          if grep -q "^### ${ID} (" "$DEC"; then
            # same id already in register — same record, or a collision with different content?
            if ! grep -A1 "^### ${ID} (" "$DEC" | grep -qF "$(printf '%s' "$BODY" | cut -c1-50)"; then
              ID="${ID}x${CH}"
              grep -q "^### ${ID} (" "$DEC" || {
                printf '### %s (%s) [active]\n%s\n— родилось: %s\n\n' "$ID" "$DATE" "$BODY" "$SRC" >> "$DEC"
                say "COLLISION: id reused with different content — wrote decision $ID → $WS/decisions.md"; }
            fi
          else
            printf '### %s (%s) [active]\n%s\n— родилось: %s\n\n' "$ID" "$DATE" "$BODY" "$SRC" >> "$DEC"
            say "+ decision $ID → $WS/decisions.md"
          fi
          unlock "$DEC"
          ;;
        TAIL)
          lock "$OPEN" || { : > "$RUN/fail"; continue; }
          ensure_register "$OPEN" "$WS — open items" "Хвосты и открытые вопросы. Закрытие — маркером CLOSED:/ЗАКРЫТ: в дневнике (жатва проставляет [x]), не руками. Жатва закрытые не переоткрывает."
          if grep -q "^- \[.\] ${ID} ·" "$OPEN"; then
            if ! grep "^- \[.\] ${ID} ·" "$OPEN" | grep -qF "$(printf '%s' "$BODY" | cut -c1-50)"; then
              ID="${ID}x${CH}"
              grep -q "^- \[.\] ${ID} ·" "$OPEN" || {
                printf -- '- [ ] %s · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$OPEN"
                say "COLLISION: id reused with different content — wrote tail $ID → $WS/open.md"; }
            fi
          else
            printf -- '- [ ] %s · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$OPEN"
            say "+ tail $ID → $WS/open.md"
          fi
          unlock "$OPEN"
          ;;
        CLOSED)
          # v3.7 (§1): flip ONE existing open.md line's "- [ ]" to "- [x]" —
          # never a new record, never touching any byte outside that line.
          # Plain shell (head/tail/printf), not awk -v, builds the replacement:
          # BODY is free operator text and must never pass through awk's -v
          # backslash-escape reprocessing (see bro-lib.sh's MRE comment for the
          # same concern about regex — here it's the printed text that matters).
          lock "$OPEN" || { : > "$RUN/fail"; continue; }
          OLN=""
          [ -f "$OPEN" ] && OLN=$(grep -n "^- \[ \] ${ID} ·" "$OPEN" | head -1 | cut -d: -f1)
          if [ -n "$OLN" ]; then
            OLDLINE=$(sed -n "${OLN}p" "$OPEN")
            # NB: unescaped [ ] in a #-pattern is a glob character CLASS, not
            # literal brackets — "- [ ]" would then match "- " + one char from
            # {space}, never the real 5-char prefix, leaving OLDLINE untouched
            # and duplicating it after "- [x]". Escape both brackets.
            NEWLINE="- [x]${OLDLINE#- \[ \]} — закрыт $DATE: $BODY"
            OTMP=$(mktemp "$WS_DIR/.open.XXXXXX" 2>/dev/null || echo "$WS_DIR/.open.$$")
            # BSD head rejects "-n 0" (macOS: "illegal line count") — skip the
            # call outright when the matched line is line 1, instead of relying
            # on it to just print nothing the way GNU head would.
            { [ "$OLN" -gt 1 ] && head -n $((OLN-1)) "$OPEN"; printf '%s\n' "$NEWLINE"; tail -n +$((OLN+1)) "$OPEN"; } > "$OTMP" \
              && mv "$OTMP" "$OPEN"
            say "closed tail $ID → $WS/open.md"
          elif [ -f "$OPEN" ] && grep -q "^- \[x\] ${ID} ·" "$OPEN"; then
            : # already closed — idempotent, never double-closes (a re-run, or a repeated CLOSED, is a no-op)
          else
            # CLOSE-MISS: this id isn't open (wrong id, typo, already closed
            # under a different id, or the marker gave no id at all) in this
            # workspace's open.md. Deduped on H — the marker's own stable
            # per-occurrence hash, unchanged across --full re-reads (same
            # id-stability property the glue-fix header above relies on) — so
            # re-harvesting the same journal never re-logs the same miss.
            MISS="$WS_DIR/.close-misses.log"
            grep -qF "$(printf '\t%s\t' "$H")" "$MISS" 2>/dev/null \
              || printf '%s\t%s\t%s\t%s\n' "$(date '+%F %H:%M')" "$ID" "$H" "$BODY" >> "$MISS"
            say "CLOSE-MISS: $ID not open in $WS/open.md → $MISS"
          fi
          unlock "$OPEN"
          ;;
        TERM)
          lock "$VOC" || { : > "$RUN/fail"; continue; }
          ensure_register "$VOC" "$WS — vocabulary" "Словарь: термин — значение, словами оператора, с датой рождения."
          grep -q "^- \*\*${ID}\*\*" "$VOC" || {
            printf -- '- **%s** · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$VOC"
            say "+ term $ID → $WS/vocab.md"; }
          unlock "$VOC"
          ;;
        INSIGHT)
          # v3.8 (§6): same shape and dedup as TERM/vocab.md above — one id
          # per occurrence, append-only, "already have this id" is a no-op
          # (no collision-disambiguation dance like DECIDED/TAIL/RULE do;
          # spec is explicit that insights.md mirrors vocab.md exactly).
          lock "$INS" || { : > "$RUN/fail"; continue; }
          ensure_register "$INS" "$WS — insights" "Закономерности, идеи, новые подходы к работе. Пополняется жатвой; подъём в принципы — отдельно (3.9), не здесь."
          grep -q "^- \*\*${ID}\*\*" "$INS" || {
            printf -- '- **%s** · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$INS"
            say "+ insight $ID → $WS/insights.md"; }
          unlock "$INS"
          ;;
        RULE)
          lock "$RCAND" || { : > "$RUN/fail"; continue; }
          ensure_register "$RCAND" "rule candidates (global queue)" "Кандидаты в _principles.md. В принципы — только после подтверждения оператора: [x] принят / [-] отклонён."
          if grep -q "^- \[.\] ${ID} (" "$RCAND"; then
            if ! grep "^- \[.\] ${ID} (" "$RCAND" | grep -qF "$(printf '%s' "$BODY" | cut -c1-50)"; then
              ID="${ID}x${CH}"
              grep -q "^- \[.\] ${ID} (" "$RCAND" || {
                printf -- '- [ ] %s (%s) · %s — родился: %s\n' "$ID" "$WS" "$BODY" "$SRC" >> "$RCAND"
                say "COLLISION: id reused with different content — wrote rule-candidate $ID"; }
            fi
          else
            printf -- '- [ ] %s (%s) · %s — родился: %s\n' "$ID" "$WS" "$BODY" "$SRC" >> "$RCAND"
            say "+ rule-candidate $ID → _rule-candidates.md"
          fi
          unlock "$RCAND"
          ;;
        STATE)
          # v3.8 (§5): NOT a per-occurrence register write like every other
          # branch above — a STATE line is one SIDE of a snapshot shared by
          # every STATE/СОСТОЯНИЕ line under the same journal section. Just
          # record it (date, section, side) in this pass's own scratch file;
          # the newest group across the WHOLE pass is picked and written to
          # $ROOT/_state.md ONCE, after the per-journal loop below (see
          # write_state_snapshot()) — never here, and never under lock, since
          # $RUN is this pass's own private mktemp'd dir, not a shared file.
          # DATE10, not DATE (§4, coordinator fix): a suffixed filename
          # ("2026-04-22-offerings-banner.md") makes DATE the whole slug —
          # fine for the "родилось: …" text other registers print, wrong
          # for epoch_of() below, which needs a plain YYYY-MM-DD.
          printf '%s\t%s\t%s\n' "$DATE10" "$SEC" "$(printf '%s' "$BODY" | tr '\t' ' ')" >> "$RUN/state-lines"
          ;;
      esac
      :
    done || : > "$RUN/fail"   # pipefail: a killed awk or loop must not count as "read"
    # this journal is done up to line TOTAL — unless a register lock was missed
    if [ -f "$RUN/fail" ]; then
      : > "$RUN/incomplete"
    else
      printf '%s\t%s\t%s\n' "$B" "$TOTAL" "$(head -n "$TOTAL" "$COPY" | shasum | cut -c1-40)" >> "$RUN/state"
    fi
  done < "$RUN/list"

  # v3.7 glue-fix visibility: sum this pass's per-journal dropped-marker
  # counts (one line per journal read above) and, only when the total is
  # >0, say() it and log ONE line to the global health.log — passive
  # signal, not a block, and silent (no line at all) when nothing dropped.
  if [ -f "$RUN/dropped" ]; then
    NDROP=$(awk '{s+=$1} END{print s+0}' "$RUN/dropped")
    if [ "$NDROP" -gt 0 ] 2>/dev/null; then
      say "$WS: $NDROP marker(s) had adjacent text not captured — see journal"
      mkdir -p "$HOME/.claude/bro" 2>/dev/null
      printf '%s  %s: %d marker(s) had adjacent text not captured — see journal\n' \
        "$(date '+%F %H:%M')" "$WS" "$NDROP" >> "$HOME/.claude/bro/health.log" 2>/dev/null
    fi
  fi

  # v3.8 (§1) near-marker visibility: same shape as the glue-fix counter
  # just above — sum this pass's per-journal counts, and only when >0,
  # say() one line and log one passive health.log line naming a first
  # example. Silent (no line at all) when nothing near-missed this pass.
  if [ -f "$RUN/near" ]; then
    NNEAR=$(awk -F'\t' '{s+=$1} END{print s+0}' "$RUN/near")
    if [ "$NNEAR" -gt 0 ] 2>/dev/null; then
      NEAREX=$(awk -F'\t' '$1+0 > 0 && $2 != "" { print $2; exit }' "$RUN/near")
      NEAREX=$(utf8_trunc "$NEAREX" 60)   # coordinator fix (§7): byte-safe cut, see this journal's awk-scan comment above
      say "$WS: $NNEAR near-marker line(s) not harvested — e.g. '$NEAREX'"
      mkdir -p "$HOME/.claude/bro" 2>/dev/null
      printf "%s  %s: %d near-marker line(s) not harvested — e.g. '%s'\n" \
        "$(date '+%F %H:%M')" "$WS" "$NNEAR" "$NEAREX" >> "$HOME/.claude/bro/health.log" 2>/dev/null
    fi
  fi

  # v3.8 (§5), coordinator follow-up: try a previous pass's stranded
  # candidate (busy _state.md lock) BEFORE this pass's own — it's older by
  # definition, so it must get first crack at the newest-wins compare.
  # Every harvest_ws call is one "attempt" in the sense the instruction
  # means; running it here whether or not THIS workspace has new STATE
  # lines of its own is intentional — the pending candidate is store-wide,
  # not tied to this workspace, so any workspace's pass is a fair chance
  # to retry it. Cheap no-op when nothing is pending.
  flush_state_pending

  # v3.8 (§5) STATE snapshot: $RUN/state-lines has one "date \t section \t
  # body" line per STATE/СОСТОЯНИЕ occurrence this pass emitted (written by
  # the STATE branch above). Group by (date, section) — everything sharing
  # one journal record is one snapshot's sides — and keep only the group
  # with the latest record time (journal date + the section's own HH:MM,
  # via epoch_of() from bro-lib.sh). Only THAT one group is even a
  # candidate; write_state_snapshot() then compares it against whatever
  # $ROOT/_state.md already holds and keeps whichever is newer (and, if
  # the lock is busy, hands it to save_state_pending() instead of losing it).
  if [ -s "$RUN/state-lines" ]; then
    BESTDATE=""; BESTSEC=""; BESTEPOCH=0; NSTATE_NOTIME=0
    while IFS=$'\t' read -r SDATE SSEC SBODY; do
      [ -n "$SDATE" ] || continue
      STIME="${SSEC%% *}"
      SEP=""
      case "$STIME" in
        [0-9][0-9]:[0-9][0-9]) SEP=$(epoch_of "$SDATE" "$STIME") ;;
      esac
      # v3.8 (§8, coordinator fix): a STATE line under a record whose
      # section header does not start "HH:MM · …" (missing entirely, or
      # malformed) used to just `continue` here — silently dropped, no
      # trace anywhere, same class of problem the ndrop/near-marker
      # counters already exist to surface for OTHER markers. Now counted
      # and reported the same passive way, below.
      case "$SEP" in
        ''|*[!0-9]*) NSTATE_NOTIME=$((NSTATE_NOTIME+1)); continue ;;
      esac
      if [ "$SEP" -gt "$BESTEPOCH" ] 2>/dev/null; then
        BESTEPOCH="$SEP"; BESTDATE="$SDATE"; BESTSEC="$SSEC"
      fi
    done < "$RUN/state-lines"
    if [ "$NSTATE_NOTIME" -gt 0 ] 2>/dev/null; then
      say "$WS: $NSTATE_NOTIME STATE marker(s) skipped — record has no readable 'HH:MM · …' section header"
      mkdir -p "$HOME/.claude/bro" 2>/dev/null
      printf "%s  %s: %d STATE marker(s) skipped — record has no readable 'HH:MM · …' section header\n" \
        "$(date '+%F %H:%M')" "$WS" "$NSTATE_NOTIME" >> "$HOME/.claude/bro/health.log" 2>/dev/null
    fi
    if [ "$BESTEPOCH" -gt 0 ] 2>/dev/null && [ -n "$BESTDATE" ]; then
      SIDES=$(awk -F'\t' -v d="$BESTDATE" -v s="$BESTSEC" '$1==d && $2==s { print $3 }' "$RUN/state-lines")
      [ -n "$SIDES" ] && write_state_snapshot "$WS" "$BESTDATE" "${BESTSEC%% *}" "$BESTEPOCH" "$BESTSEC" "$SIDES"
    fi
  fi

  # new state lines win over old ones; the stamp moves only after a complete pass
  { [ -f "$RUN/state" ] && cat "$RUN/state"; [ -f "$STATE" ] && cat "$STATE"; } 2>/dev/null \
    | awk -F'\t' '!seen[$1]++' > "$RUN/state.merged"
  mv "$RUN/state.merged" "$STATE"
  if [ -f "$RUN/incomplete" ]; then
    say "$WS: pass incomplete (busy register lock or interrupted read) — those journals will be re-read next pass"
  elif [ ! -f "$STAMP" ] || [ "$RUN/start" -nt "$STAMP" ]; then
    # forward only: a slow pass that began earlier must not pull the stamp back
    # behind a quicker pass that began later and has already completed
    mv "$RUN/start" "$STAMP"
  fi
  rm -rf "$RUN"
}

if [ "$ALL" = 1 ]; then
  for D in "$ROOT"/*/; do
    B=$(basename "$D")
    case "$B" in _archive|_principles-sources|*.lock) continue ;; esac
    harvest_ws "$B"
  done
else
  harvest_ws "$ONLY_WS"
fi

# ---- regenerate INDEX.md atomically (a view — never hand-edited) ----
if lock "$ROOT/INDEX.md"; then
  # half-written index files of passes that were killed mid-write (pre-3.6 hook timeouts)
  find "$ROOT" -maxdepth 1 -type f -name '.index.*' -mmin +60 -delete 2>/dev/null
  TMP=$(mktemp "$ROOT/.index.XXXXXX" 2>/dev/null || echo "$ROOT/.index.$$")
  {
    echo "# bro index"
    echo ""
    echo "| workspace | files | last entry | open tails |"
    echo "|---|---|---|---|"
    for D in "$ROOT"/*/; do
      B=$(basename "$D")
      case "$B" in _archive|_principles-sources|*.lock) continue ;; esac
      NF=$(find "$D" -name "*.md" -type f | wc -l | tr -d ' ')
      LAST=$(find "$D" -maxdepth 1 -name "[0-9]*.md" -type f -exec basename {} .md \; 2>/dev/null | sort | tail -1)
      NOPEN=$(grep -c '^- \[ \]' "$D/open.md" 2>/dev/null || true); [ -n "$NOPEN" ] || NOPEN=0
      echo "| $B | $NF | ${LAST:-—} | $NOPEN |"
    done
    TODAY=$(date +%F)
    DUE=$(awk -v today="$TODAY" '
      /^### / { sub(/^### /, ""); hdr = $0 }
      /\*\*Пересмотр:\*\*/ { if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) { d=substr($0,RSTART,RLENGTH); if (d<=today) printf "- %s — срок был %s\n", hdr, d } }
    ' "$ROOT/_principles.md" 2>/dev/null)
    echo ""
    echo "## Reviews due"
    if [ -n "$DUE" ]; then
      echo "$DUE"
      echo ""
      echo "Пересмотр: правило живо и верно → продлить дату (интервал больше прошлого); устарело → заместить записью со ссылкой."
    else
      echo "_(нет — ближайшие даты внутри _principles.md)_"
    fi
    PWARN=$(awk '
      function flush() { if (blk != "") { m=""; if (!hasR) m=m" Правило"; if (!hasB) m=m" Родилось"; if (!hasP) m=m" Пересмотр"; if (m != "") printf "- %s — нет поля:%s\n", blk, m } }
      /^### / { flush(); blk=$0; sub(/^### /, "", blk); hasR=0; hasP=0; hasB=0 }
      /\*\*Правило:\*\*/ { hasR=1 }
      /\*\*Пересмотр:\*\*/ { hasP=1 }
      /\*\*Родилось:\*\*/ { hasB=1 }
      END { flush() }
    ' "$ROOT/_principles.md" 2>/dev/null)
    if [ -n "$PWARN" ]; then
      echo ""
      echo "## Format warnings"
      echo "$PWARN"
    fi
    echo ""
    echo "_Generated by bro-harvest; do not edit by hand._"
  } > "$TMP"
  mv "$TMP" "$ROOT/INDEX.md"
  unlock "$ROOT/INDEX.md"
fi

say "done"
exit 0
