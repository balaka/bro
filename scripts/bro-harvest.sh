#!/bin/bash
# bro v3.2 — harvest: collect typed markers from daily journals into registers.
#
# Journals are the birthplace of typed records; registers are where they live:
#   DECIDED / РЕШЕНИЕ  → <ws>/decisions.md   (decision register, ADR-style)
#   TAIL    / ХВОСТ    → <ws>/open.md        (open items; closing is manual)
#   TERM    / ТЕРМИН   → <ws>/vocab.md       (vocabulary register)
#   RULE    / ПРАВИЛО  → <root>/_rule-candidates.md  (global queue; enters
#                        _principles.md only after operator confirmation)
#
# Deterministic and idempotent: every record gets a stable id — the author's
# own id when the marker carries one (e.g. "DECIDED d-0906-2: …"), otherwise
# a 6-hex hash of (file basename | line). A record whose id is already present
# in the target register is skipped. Harvest APPENDS ONLY — it never edits or
# closes anything; humans and models manage statuses in the registers.
#
# Also regenerates INDEX.md (registry view: files, last entry, open tails).
#
# Usage: bro-harvest.sh [--root <dir>] [--workspace <name> | --all] [--quiet]

set -uo pipefail

CONFIG="$HOME/.claude/bro-config.json"
ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
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

MARKER_RE='^(DECIDED|РЕШЕНИЕ|RULE|ПРАВИЛО|TAIL|ХВОСТ|TERM|ТЕРМИН)([[:space:]][A-Za-z]-[A-Za-z0-9-]+)?:[[:space:]]'
ADDED=0

ensure_register() { # $1=path $2=title $3=hint
  [ -f "$1" ] && return
  printf '# %s\n\n> %s\n> Пополняется жатвой (bro-harvest) из дневников; статусы правятся руками. Записи не удалять — замещать.\n\n' "$2" "$3" > "$1"
}

harvest_ws() {
  local WS="$1" WS_DIR="$ROOT/$1"
  [ -d "$WS_DIR" ] || return
  local DEC="$WS_DIR/decisions.md" OPEN="$WS_DIR/open.md" VOC="$WS_DIR/vocab.md"
  local RCAND="$ROOT/_rule-candidates.md"

  find "$WS_DIR" -maxdepth 1 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" -type f | sort | while IFS= read -r F; do
    local DATE; DATE=$(basename "$F" .md)
    grep -n -E "$MARKER_RE" "$F" 2>/dev/null | while IFS= read -r HIT; do
      local LN="${HIT%%:*}"
      local LINE="${HIT#*:}"
      local KW="${LINE%%[ :]*}"; KW="${KW%%:*}"
      # id: author's own, else hash of file|line
      local ID BODY
      if echo "$LINE" | grep -qE '^[А-ЯA-Z]+[[:space:]][A-Za-z]-[A-Za-z0-9-]+:'; then
        ID=$(echo "$LINE" | sed -E 's/^[^ ]+ ([A-Za-z]-[A-Za-z0-9-]+):.*/\1/')
      else
        local H; H=$(printf '%s|%s' "$(basename "$F")" "$LINE" | shasum | cut -c1-6)
        case "$KW" in
          DECIDED|РЕШЕНИЕ) ID="d-$H" ;;
          RULE|ПРАВИЛО)    ID="r-$H" ;;
          TAIL|ХВОСТ)      ID="t-$H" ;;
          TERM|ТЕРМИН)     ID="v-$H" ;;
        esac
      fi
      BODY=$(echo "$LINE" | sed -E 's/^[^:]+:[[:space:]]*//')
      # section anchor: nearest preceding "## " header
      local SEC; SEC=$(awk -v n="$LN" 'NR<n && /^## /{h=$0} END{sub(/^## /,"",h); print h}' "$F")
      local SRC="$DATE · «${SEC:-без секции}»"

      case "$KW" in
        DECIDED|РЕШЕНИЕ)
          ensure_register "$DEC" "$WS — decisions" "Реестр решений: выбрали/вместо/почему. Устаревшее — [superseded by <id>], не стирать."
          grep -qF "$ID" "$DEC" || {
            printf '### %s (%s) [active]\n%s\n— родилось: %s\n\n' "$ID" "$DATE" "$BODY" "$SRC" >> "$DEC"
            say "+ decision $ID → $WS/decisions.md"; ADDED=$((ADDED+1)); }
          ;;
        TAIL|ХВОСТ)
          ensure_register "$OPEN" "$WS — open items" "Хвосты и открытые вопросы. Закрытие: [x] + дата/чем закрыт. Жатва закрытые не переоткрывает."
          grep -qF "$ID" "$OPEN" || {
            printf -- '- [ ] %s · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$OPEN"
            say "+ tail $ID → $WS/open.md"; ADDED=$((ADDED+1)); }
          ;;
        TERM|ТЕРМИН)
          ensure_register "$VOC" "$WS — vocabulary" "Словарь: термин — значение, словами оператора, с датой рождения."
          grep -qF "$ID" "$VOC" || {
            printf -- '- **%s** · %s — родился: %s\n' "$ID" "$BODY" "$SRC" >> "$VOC"
            say "+ term $ID → $WS/vocab.md"; ADDED=$((ADDED+1)); }
          ;;
        RULE|ПРАВИЛО)
          ensure_register "$RCAND" "rule candidates (global queue)" "Кандидаты в _principles.md. В принципы — только после подтверждения оператора: [x] принят / [-] отклонён."
          grep -qF "$ID" "$RCAND" || {
            printf -- '- [ ] %s (%s) · %s — родился: %s\n' "$ID" "$WS" "$BODY" "$SRC" >> "$RCAND"
            say "+ rule-candidate $ID → _rule-candidates.md"; ADDED=$((ADDED+1)); }
          ;;
      esac
    done
  done
}

if [ "$ALL" = 1 ]; then
  for D in "$ROOT"/*/; do
    B=$(basename "$D")
    case "$B" in _archive|_principles-sources) continue ;; esac
    harvest_ws "$B"
  done
else
  harvest_ws "$ONLY_WS"
fi

# ---- regenerate INDEX.md (a view — never hand-edited) ----
{
  echo "# bro index"
  echo ""
  echo "| workspace | files | last entry | open tails |"
  echo "|---|---|---|---|"
  for D in "$ROOT"/*/; do
    B=$(basename "$D")
    case "$B" in _archive|_principles-sources) continue ;; esac
    NF=$(find "$D" -name "*.md" -type f | wc -l | tr -d ' ')
    LAST=$(find "$D" -maxdepth 1 -name "[0-9]*.md" -type f -exec basename {} .md \; 2>/dev/null | sort | tail -1)
    NOPEN=$(grep -c '^- \[ \]' "$D/open.md" 2>/dev/null || echo 0)
    echo "| $B | $NF | ${LAST:-—} | $NOPEN |"
  done
  # principles whose review date has arrived (ISO dates compare lexicographically)
  TODAY=$(date +%F)
  DUE=$(awk -v today="$TODAY" '
    /^### / { sub(/^### /, ""); hdr = $0 }
    /\*\*Пересмотр:\*\*/ { if ($NF <= today) printf "- %s — срок был %s\n", hdr, $NF }
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
  echo ""
  echo "_Generated by bro-harvest; do not edit by hand._"
} > "$ROOT/INDEX.md"

say "done"
exit 0
