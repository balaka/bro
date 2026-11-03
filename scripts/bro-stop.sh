#!/bin/bash
# bro-stop.sh — Stop hook (v5): journal freshness gate + background harvest.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
input=""; [ -t 0 ] || input=$(cat)
cwd=$(bro_hook_input_field "$input" cwd); [ -n "$cwd" ] || cwd="$PWD"
ws=$(bro_workspace "$cwd"); [ -n "$ws" ] || exit 0
active=$(bro_hook_input_field "$input" stop_hook_active)
stale=$(bro_config_get staleMinutes 30)
today=$(bro_today); j="$(bro_root)/$ws/$today.md"

if [ -f "$HERE/bro-harvest.sh" ]; then
  ( bash "$HERE/bro-harvest.sh" --workspace "$ws" >/dev/null 2>&1 & )
fi

[ "$active" = true ] && exit 0
if [ ! -f "$j" ]; then age="missing"
else
  m=$(stat -f %m "$j" 2>/dev/null || stat -c %Y "$j" 2>/dev/null)
  mins=$(( ($(date +%s) - ${m:-0}) / 60 ))
  [ "$mins" -lt "$stale" ] && exit 0
  age="$mins min old"
fi
jq -cn --arg r "bro: journal $ws/$today.md is $age — append a section via bro-append.sh, then finish" \
  '{decision:"block",reason:$r}'
exit 0
