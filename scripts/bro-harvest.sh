#!/bin/bash
# bro v3.3 — harvest: collect typed markers from daily journals into registers.
#
#   DECIDED / РЕШЕНИЕ  → <ws>/decisions.md      TAIL / ХВОСТ  → <ws>/open.md
#   TERM    / ТЕРМИН   → <ws>/vocab.md          RULE / ПРАВИЛО → <root>/_rule-candidates.md
#   CLOSED  / ЗАКРЫТ   → flips an existing <ws>/open.md tail's [ ] to [x];
#                         creates no register record of its own (see v3.7 below)
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

# MRE now comes from bro-lib.sh (sourced above) — the one canonical
# marker-keyword regex, shared with the stop hook and bro-append.sh.

harvest_ws() {
  local WS="$1" WS_DIR="$ROOT/$1"
  [ -d "$WS_DIR" ] || return 0
  local DEC="$WS_DIR/decisions.md" OPEN="$WS_DIR/open.md" VOC="$WS_DIR/vocab.md"
  local RCAND="$ROOT/_rule-candidates.md"

  # ---- which journals, and from which line (v3.6 incremental) ----
  local STAMP="$WS_DIR/.harvest-stamp" STATE="$WS_DIR/.harvest-state"
  local RUN INCR=1 F B DATE TOTAL FROM PREV PN PS BACK
  # scratch dirs of passes that were killed long ago
  find "$WS_DIR" -maxdepth 1 -type d -name '.harvest-run.*' -mmin +60 -exec rm -rf {} + 2>/dev/null
  # mktemp, not $$: a leftover dir of a killed pass plus a reused pid must not silence this workspace
  RUN=$(mktemp -d "$WS_DIR/.harvest-run.XXXXXX" 2>/dev/null) || { say "$WS: cannot create a scratch dir in $WS_DIR — workspace skipped"; return 0; }
  : > "$RUN/start"   # its mtime is the start of this pass — it becomes the stamp if the pass completes
  # …minus 2 s: where mtimes are coarse (1–2 s), a journal written in the very second a pass
  # starts would tie with the stamp and never look "newer". Re-reading costs nothing. UTC: no DST.
  BACK=$(TZ=UTC0 date -v-2S +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC0 date -d '2 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$BACK" ] && TZ=UTC0 touch -t "$BACK" "$RUN/start" 2>/dev/null
  if [ "$FULL" = 1 ] || [ ! -f "$STAMP" ] || [ ! -f "$STATE" ]; then
    INCR=0
    find "$WS_DIR" -maxdepth 1 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" -type f | sort > "$RUN/list"
  else
    find "$WS_DIR" -maxdepth 1 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" -type f -newer "$STAMP" | sort > "$RUN/list"
  fi
  say "$WS: $(wc -l < "$RUN/list" | tr -d ' ') journal(s) to read$([ "$INCR" = 0 ] && echo ' (full pass)')"

  while IFS= read -r F; do
    B=$(basename "$F"); DATE="${B%.md}"
    # awk 'END{print NR}', not `wc -l`: wc -l counts NEWLINES, so a journal
    # whose last physical line has no trailing '\n' (a hand-edit, or any
    # pre-bro-append.sh content) undercounts by one. The awk bound below
    # (`NR > to { exit }`) uses this TOTAL as its cutoff, so an undercount
    # doesn't just mis-scan — it makes the file's true last line invisible
    # to every pattern, silently: a CLOSED marker sitting there produces no
    # register write, no CLOSE-MISS, no health.log line, nothing.
    TOTAL=$(awk 'END{print NR}' "$F" 2>/dev/null); [ -n "$TOTAL" ] || TOTAL=0
    FROM=0
    if [ "$INCR" = 1 ]; then
      # lines already harvested stay skipped only while they are byte-identical
      PREV=$(awk -F'\t' -v f="$B" '$1 == f { print $2 "\t" $3; exit }' "$STATE" 2>/dev/null)
      PN="${PREV%%$'\t'*}"; PS="${PREV#*$'\t'}"
      if [ -n "$PREV" ] && [ "$PN" -gt 0 ] 2>/dev/null && [ "$TOTAL" -ge "$PN" ] \
         && [ "$(head -n "$PN" "$F" | shasum | cut -c1-40)" = "$PS" ]; then
        FROM="$PN"
      fi
    fi
    rm -f "$RUN/fail"
    # awk emits: LINE_NO \x1f SECTION \x1f BODY(own line only) \x1f HASHTEXT(joined) \x1e
    # per marker record (only markers born after line FROM; lines past TOTAL
    # belong to the next pass). v3.7 glue fix: BODY is exactly the marker's
    # own physical line — adjacent non-blank lines (until blank/next marker/
    # next section, same boundary as before) are counted (ndrop) but no
    # longer folded in. HASHTEXT still glues them, same as pre-3.7 BODY did —
    # it feeds only the id hash below, so an id computed over an unchanged
    # old journal doesn't change just because what gets STORED now does (see
    # the id-stability note in this file's header).
    awk -v mre="$MRE" -v from="$FROM" -v to="$TOTAL" -v dropfile="$RUN/dropped" '
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
      { if (ln) { line=$0; sub(/^[[:space:]]+/, "", line); joined=joined " " line; hasdrop=1 } }
      END { flush(); printf "%d\n", ndrop >> dropfile; close(dropfile) }
    ' "$F" | while IFS=$'\x1f' read -r -d $'\x1e' LN SEC LINE HTXT; do
      [ -n "$LINE" ] || continue
      # normalize: strip indent, bullet, bold
      local CLEAN KW HEAD TOK ID BODY H CH OLN OLDLINE NEWLINE MISS OTMP
      CLEAN=$(printf '%s' "$LINE" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?//; s/\*\*//g')
      HEAD="${CLEAN%%:*}"                      # keyword [+ optional token]
      BODY="${CLEAN#*:}"; BODY="${BODY# }"
      KW="${HEAD%% *}"
      KW="${KW%%-*}"; KW="${KW%%–*}"; KW="${KW%%—*}"   # strip «-кандидат»-style suffixes
      TOK=""; [ "$HEAD" != "${HEAD%% *}" ] && TOK="${HEAD#* }"
      # id hash over HTXT (joined, pre-3.7-shaped), not LINE/BODY (own line
      # only) — see the id-stability note in this file's header: this is
      # what keeps a re-read of an unchanged old journal computing the same id.
      H=$(printf '%s|%s' "$(basename "$F")" "$HTXT" | shasum | cut -c1-6)
      CH=$(printf '%s' "$BODY" | shasum | cut -c1-4)
      if printf '%s' "$TOK" | grep -qE '^[A-Za-z]-[A-Za-z0-9-]+$'; then
        ID="$TOK"
      else
        [ -n "$TOK" ] && BODY="$TOK: $BODY"    # noise token was not an id — keep it in the body
        case "$KW" in
          DECIDED|РЕШЕНИЕ)  ID="d-$H" ;;
          RULE|ПРАВИЛО)     ID="r-$H" ;;
          TAIL|ХВОСТ)       ID="t-$H" ;;
          TERM|ТЕРМИН)      ID="v-$H" ;;
          REJECTED|ОТКАЗ)   ID="o-$H" ;;
          CLOSED|ЗАКРЫТ)    ID="c-$H" ;;  # no real tail id given — unresolvable; routes to CLOSE-MISS below
          *) continue ;;
        esac
      fi
      local SRC="$DATE · «${SEC:-без секции}»"

      case "$KW" in
        REJECTED|ОТКАЗ)
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
        DECIDED|РЕШЕНИЕ)
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
        TAIL|ХВОСТ)
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
        CLOSED|ЗАКРЫТ)
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
        TERM|ТЕРМИН)
          lock "$VOC" || { : > "$RUN/fail"; continue; }
          ensure_register "$VOC" "$WS — vocabulary" "Словарь: термин — значение, словами оператора, с датой рождения."
          grep -q "^- \*\*${ID}\*\*" "$VOC" || {
            printf -- '- **%s** · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$VOC"
            say "+ term $ID → $WS/vocab.md"; }
          unlock "$VOC"
          ;;
        RULE|ПРАВИЛО)
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
      esac
      :
    done || : > "$RUN/fail"   # pipefail: a killed awk or loop must not count as "read"
    # this journal is done up to line TOTAL — unless a register lock was missed
    if [ -f "$RUN/fail" ]; then
      : > "$RUN/incomplete"
    else
      printf '%s\t%s\t%s\n' "$B" "$TOTAL" "$(head -n "$TOTAL" "$F" | shasum | cut -c1-40)" >> "$RUN/state"
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
