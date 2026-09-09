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
# Deterministic, idempotent, append-only. Registers' statuses are managed by hand.
# Usage: bro-harvest.sh [--root <dir>] [--workspace <name> | --all] [--quiet]

set -uo pipefail

CONFIG="$HOME/.claude/bro-config.json"
if command -v jq >/dev/null 2>&1; then
  ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
else
  ROOT="~/bro"
fi
ROOT="${ROOT/#\~/$HOME}"
ONLY_WS=""; ALL=0; QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; ROOT="${ROOT/#\~/$HOME}"; shift ;;
    --workspace) ONLY_WS="$2"; shift ;;
    --all) ALL=1 ;;
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
MRE='^[[:space:]]*(-[[:space:]]+)?([*][*])?(DECIDED|RULE|TAIL|TERM|РЕШЕНИЕ|ПРАВИЛО|ХВОСТ|ТЕРМИН)([*][*])?( [^ :]+)?:'

harvest_ws() {
  local WS="$1" WS_DIR="$ROOT/$1"
  [ -d "$WS_DIR" ] || return 0
  local DEC="$WS_DIR/decisions.md" OPEN="$WS_DIR/open.md" VOC="$WS_DIR/vocab.md"
  local RCAND="$ROOT/_rule-candidates.md"

  find "$WS_DIR" -maxdepth 1 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" -type f | sort | while IFS= read -r F; do
    local DATE; DATE=$(basename "$F" .md)
    # awk emits: LINE_NO \x1f SECTION \x1f BODY(joined) \x1e  per marker record
    awk -v mre="$MRE" '
      function flush() { if (ln) printf "%d\x1f%s\x1f%s\x1e", ln, sec, body; ln=0; body="" }
      /^## / { flush(); sec=$0; sub(/^## /, "", sec); next }
      /^[[:space:]]*$/ { flush(); next }
      $0 ~ mre { flush(); ln=NR; body=$0; next }
      { if (ln) { line=$0; sub(/^[[:space:]]+/, "", line); body=body " " line } }
      END { flush() }
    ' "$F" | while IFS=$'\x1f' read -r -d $'\x1e' LN SEC LINE; do
      [ -n "$LINE" ] || continue
      # normalize: strip indent, bullet, bold
      local CLEAN KW HEAD TOK ID BODY H
      CLEAN=$(printf '%s' "$LINE" | sed -E 's/^[[:space:]]*(-[[:space:]]+)?//; s/\*\*//g')
      HEAD="${CLEAN%%:*}"                      # keyword [+ optional token]
      BODY="${CLEAN#*:}"; BODY="${BODY# }"
      KW="${HEAD%% *}"
      TOK=""; [ "$HEAD" != "$KW" ] && TOK="${HEAD#* }"
      if printf '%s' "$TOK" | grep -qE '^[A-Za-z]-[A-Za-z0-9-]+$'; then
        ID="$TOK"
      else
        [ -n "$TOK" ] && BODY="$TOK: $BODY"    # noise token was not an id — keep it in the body
        H=$(printf '%s|%s' "$(basename "$F")" "$LINE" | shasum | cut -c1-6)
        case "$KW" in
          DECIDED|РЕШЕНИЕ) ID="d-$H" ;;
          RULE|ПРАВИЛО)    ID="r-$H" ;;
          TAIL|ХВОСТ)      ID="t-$H" ;;
          TERM|ТЕРМИН)     ID="v-$H" ;;
          *) continue ;;
        esac
      fi
      local SRC="$DATE · «${SEC:-без секции}»"

      case "$KW" in
        DECIDED|РЕШЕНИЕ)
          lock "$DEC" || continue
          ensure_register "$DEC" "$WS — decisions" "Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать."
          grep -q "^### ${ID} (" "$DEC" || {
            printf '### %s (%s) [active]\n%s\n— родилось: %s\n\n' "$ID" "$DATE" "$BODY" "$SRC" >> "$DEC"
            say "+ decision $ID → $WS/decisions.md"; }
          unlock "$DEC"
          ;;
        TAIL|ХВОСТ)
          lock "$OPEN" || continue
          ensure_register "$OPEN" "$WS — open items" "Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает."
          grep -q "^- \[.\] ${ID} ·" "$OPEN" || {
            printf -- '- [ ] %s · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$OPEN"
            say "+ tail $ID → $WS/open.md"; }
          unlock "$OPEN"
          ;;
        TERM|ТЕРМИН)
          lock "$VOC" || continue
          ensure_register "$VOC" "$WS — vocabulary" "Словарь: термин — значение, словами оператора, с датой рождения."
          grep -q "^- \*\*${ID}\*\*" "$VOC" || {
            printf -- '- **%s** · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$VOC"
            say "+ term $ID → $WS/vocab.md"; }
          unlock "$VOC"
          ;;
        RULE|ПРАВИЛО)
          lock "$RCAND" || continue
          ensure_register "$RCAND" "rule candidates (global queue)" "Кандидаты в _principles.md. В принципы — только после подтверждения оператора: [x] принят / [-] отклонён."
          grep -q "^- \[.\] ${ID} (" "$RCAND" || {
            printf -- '- [ ] %s (%s) · %s — родился: %s\n' "$ID" "$WS" "$BODY" "$SRC" >> "$RCAND"
            say "+ rule-candidate $ID → _rule-candidates.md"; }
          unlock "$RCAND"
          ;;
      esac
    done
  done
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
