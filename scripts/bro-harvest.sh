#!/bin/bash
# bro v3.3 — harvest: collect typed markers from daily journals into registers.
#
#   DECIDED / РЕШЕНИЕ  → <ws>/decisions.md      TAIL / ХВОСТ  → <ws>/open.md
#   TERM    / ТЕРМИН   → <ws>/vocab.md          RULE / ПРАВИЛО → <root>/_rule-candidates.md
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
# A record is taken as it stands the first time a pass sees it. Text that a later
# write glues onto an already harvested marker (no blank line in between) is not
# harvested again — before 3.6 every run re-read it and appended a second record
# with the glued body under a new id. --full still behaves that way.
# --full ignores stamp and state (use after restoring files with old mtimes,
# or after hand-removing records from a register).
#
# Deterministic, idempotent, append-only. Registers' statuses are managed by hand.
# Usage: bro-harvest.sh [--root <dir>] [--workspace <name> | --all] [--full] [--quiet]

set -uo pipefail

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

lock() { # $1 = path to lock (lockdir = $1.lock); bounded spin + stale-lock reclaim
  local l="$1.lock" i=0
  until mkdir "$l" 2>/dev/null; do
    # a lock older than 5 min is a crash leftover — reclaim it, else it silences
    # register appends and INDEX regeneration forever
    if [ -n "$(find "$l" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      rmdir "$l" 2>/dev/null && continue
    fi
    i=$((i+1)); [ "$i" -gt 60 ] && return 1
    sleep 0.05
  done
  return 0
}
unlock() { rmdir "$1.lock" 2>/dev/null; return 0; }

ensure_register() { # call ONLY under lock($1)
  [ -f "$1" ] && return
  printf '# %s\n\n> %s\n> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.\n\n' "$2" "$3" > "$1"
}

# marker start: optional indent, optional "- " bullet, optional **, keyword,
# optional single pre-colon token (id or noise), colon
# NB: [*][*] instead of \*\* — awk -v reprocesses backslash escapes and would corrupt the regex
# keyword may carry a suffix («RULE-кандидат», «ХВОСТ-вопрос») — real chats write these
MRE='^[[:space:]]*(-[[:space:]]+)?([*][*])?(DECIDED|RULE|TAIL|TERM|REJECTED|РЕШЕНИЕ|ПРАВИЛО|ХВОСТ|ТЕРМИН|ОТКАЗ)([-–—][^ :]*)?([*][*])?( [^ :]+)?:'

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
    TOTAL=$(wc -l < "$F" | tr -d ' ')
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
    # awk emits: LINE_NO \x1f SECTION \x1f BODY(joined) \x1e  per marker record
    # (only markers born after line FROM; lines past TOTAL belong to the next pass)
    awk -v mre="$MRE" -v from="$FROM" -v to="$TOTAL" '
      function flush() { if (ln && ln > from) printf "%d\x1f%s\x1f%s\x1e", ln, sec, body; ln=0; body="" }
      NR > to { exit }
      /^## / { flush(); sec=$0; sub(/^## /, "", sec); next }
      /^[[:space:]]*$/ { flush(); next }
      $0 ~ mre { flush(); ln=NR; body=$0; next }
      { if (ln) { line=$0; sub(/^[[:space:]]+/, "", line); body=body " " line } }
      END { flush() }
    ' "$F" | while IFS=$'\x1f' read -r -d $'\x1e' LN SEC LINE; do
      [ -n "$LINE" ] || continue
      # normalize: strip indent, bullet, bold
      local CLEAN KW HEAD TOK ID BODY H CH
      CLEAN=$(printf '%s' "$LINE" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?//; s/\*\*//g')
      HEAD="${CLEAN%%:*}"                      # keyword [+ optional token]
      BODY="${CLEAN#*:}"; BODY="${BODY# }"
      KW="${HEAD%% *}"
      KW="${KW%%-*}"; KW="${KW%%–*}"; KW="${KW%%—*}"   # strip «-кандидат»-style suffixes
      TOK=""; [ "$HEAD" != "${HEAD%% *}" ] && TOK="${HEAD#* }"
      H=$(printf '%s|%s' "$(basename "$F")" "$LINE" | shasum | cut -c1-6)
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
          ensure_register "$OPEN" "$WS — open items" "Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает."
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
