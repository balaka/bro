#!/bin/bash
# bro-expire.sh — apply `lives` (Nd) to every log; expired records go to the archive (SPEC §5).
#   bro-expire.sh --workspace <ws> | --all [--force]
# Only --all uses the stamp (<root>/.expire-stamp = date of last run); --workspace always runs.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"

WS=""; ALL=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || { echo "[bro-expire] --workspace needs a value" >&2; exit 1; }; WS="$2"; shift ;;
    --all) ALL=1 ;;
    --force) FORCE=1 ;;
    *) echo "[bro-expire] unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done
[ "$ALL" = 1 ] || [ -n "$WS" ] || { echo "Usage: bro-expire.sh --workspace <ws> | --all [--force]" >&2; exit 1; }
ROOT=$(bro_root); [ -d "$ROOT" ] || exit 0
TODAY=$(bro_today)
if [ "$ALL" = 1 ] && [ "$FORCE" = 0 ] && [ "$(cat "$ROOT/.expire-stamp" 2>/dev/null)" = "$TODAY" ]; then exit 0; fi

# day number of YYYY-MM-DD (pure arithmetic, no date(1) dialect issues)
day_num() {
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2})) era yoe doy doe
  [ "$m" -le 2 ] && y=$((y-1))
  era=$((y/400)); yoe=$((y-era*400))
  doy=$(( (153*(m>2 ? m-3 : m+9)+2)/5 + d-1 ))
  doe=$((yoe*365 + yoe/4 - yoe/100 + doy))
  echo $((era*146097 + doe - 719468))
}
TN=$(day_num "$TODAY")

expire_log() { # log days
  local log="$1" n="$2" l t ids=""
  [ -f "$log" ] || return 0
  while IFS= read -r l; do
    t=$(printf '%s' "$l" | awk -F' [|] ' '{print $3}')
    [[ $t =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    [ $((TN - $(day_num "$t"))) -gt "$n" ] && ids="$ids ${l%% | *}"
  done < "$log"
  [ -n "$ids" ] || return 0
  bro_lock "$log"
  awk -v ids="$ids" -v st="expired:$TODAY" -v arc="${log%.log}.archive" '
    BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) x[a[i]] = 1 }
    { id = $0; sub(/ \| .*/, "", id) }
    id in x { s = $0; out = ""
      for (i = 0; i < 3; i++) { p = index(s, " | "); out = out substr(s, 1, p + 2); s = substr(s, p + 3) }
      p = index(s, " | "); print out st substr(s, p) >> arc; next }
    { print }' "$log" > "$log.tmp$$" && mv "$log.tmp$$" "$log"
  bro_unlock "$log"
}

if [ "$ALL" = 1 ]; then
  WSS=""
  for d in "$ROOT"/*/; do
    d=$(basename "$d"); case "$d" in _*|.*) continue ;; esac
    WSS="$WSS $d"
  done
else WSS="$WS"; fi
DONE_LOGS=""
for w in $WSS; do
  while IFS=$'\t' read -r k _ _ _ _ lv _; do
    case "$lv" in *d) n="${lv%d}" ;; *) continue ;; esac
    [[ $n =~ ^[0-9]+$ ]] || continue
    p=$(bro_log_path "$w" "$k")
    case "$DONE_LOGS" in *"|$p|"*) continue ;; esac
    DONE_LOGS="$DONE_LOGS|$p|"
    expire_log "$p" "$n"
  done <<EOT
$(bro_kinds)
EOT
done
[ "$ALL" = 1 ] && printf '%s\n' "$TODAY" > "$ROOT/.expire-stamp"
exit 0
