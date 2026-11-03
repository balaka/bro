#!/bin/bash
# bro-context.sh <kind>|clock — SessionStart hook printer (v5). One hook = one kind, <= contextChars.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
arg="${1:-}"; [ -n "$arg" ] || exit 0
input=""; [ -t 0 ] || input=$(cat)
cwd=$(bro_hook_input_field "$input" cwd); [ -n "$cwd" ] || cwd="$PWD"
ws=$(bro_workspace "$cwd"); [ -n "$ws" ] || exit 0
root=$(bro_root)
short() { printf '%s\n' "${1/#$HOME/~}"; }

if [ "$arg" = clock ]; then
  today=$(bro_today)
  mkdir -p "$root/$ws" 2>/dev/null                # a new project gets its folder on first open
  if [ "$(cat "$root/.expire-stamp" 2>/dev/null)" != "$today" ] && [ -f "$HERE/bro-expire.sh" ]; then
    ( bash "$HERE/bro-expire.sh" --all >/dev/null 2>&1 & )
  fi
  ver=$(cat "$HOME/.claude/bro/VERSION" 2>/dev/null || echo "?")
  stale=$(bro_config_get staleMinutes 30)
  j=$(short "$root/$ws/$today.md")
  out="## bro v$ver · workspace $ws · now $today $(bro_now) ($(date +%A))
Take every timestamp from here, never from feeling.
Journal: $j — write ONLY via: printf '%s\\n' 'body' | ~/.claude/bro/bin/bro-append.sh --workspace $ws --thread '<thread>' --topic '<topic>'
Markers, one per line, at line start:
$(bro_kinds | awk -F'\t' '{printf "  %s — %s\n", $3, $7}')
  DONE <id>: <what closed it>      ·  (supersedes <id>) at the end of a record replaces it
Mention an id (t-b58d76) in any line to keep that record alive. Prefer touching an existing id over writing a new record.
Keep the journal current: the Stop hook blocks an answer when the journal is older than $stale min."
  n=$(grep -c . "$root/$ws/misses.log" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] && out="$out
Misses: $n (see $(short "$root/$ws/misses.log"))"
  bro_session_context "$out"; exit 0
fi

file=$(bro_kind_field "$arg" file); [ -n "$file" ] || exit 0
scope=$(bro_kind_field "$arg" scope)
log=$(bro_log_path "$ws" "$arg")
where="$ws"; [ "$scope" = global ] && where=global
cap=$(bro_config_get contextChars 10000)
n=0; [ -f "$log" ] && n=$(grep -c . "$log")
if [ "$n" -eq 0 ]; then bro_session_context "## bro · $file ($where) — none"; exit 0; fi

head="## bro · $file ($where) — $n live"
foot_max=$((${#log} + 40))                 # room for the "(+N more …)" line
used=$((${#head} + foot_max)); shown=0; body=""
while IFS= read -r line; do
  id="${line%% | *}"; r="${line#* | }"; r="${r#* | }"; touched="${r%% | *}"; r="${r#* | }"; r="${r#* | }"
  r=$(printf '%s' "$r" | sed -E 's/ \| [^ |]*\.md(#[0-9:]*)?$//')
  l="$id · $touched · $r"
  [ $((used + ${#l} + 1)) -gt "$cap" ] && break
  body="$body
$l"; used=$((used + ${#l} + 1)); shown=$((shown+1))
done <<EOT
$(grep . "$log" | awk -F' [|] ' '{print $3 "\t" $0}' | sort -s -r -k1,1 | cut -f2-)
EOT
out="$head$body"
[ "$shown" -lt "$n" ] && out="$out
(+$((n - shown)) more in $(short "$log") — grep them)"
bro_session_context "$out"
