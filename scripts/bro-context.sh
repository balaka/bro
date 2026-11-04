#!/bin/bash
# bro-context.sh <kind>|clock — SessionStart hook printer (v5). One hook = one kind, <= contextChars.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
arg="${1:-}"; [ -n "$arg" ] || exit 0
if [ "$arg" != clock ]; then   # a kind name or its file name (tasks -> task)
  kind=$(bro_kinds | awk -F'\t' -v a="$arg" '$1 == a || $5 == a {print $1; exit}')
  [ -n "$kind" ] || { echo "[bro-context] unknown kind: $arg" >&2; exit 1; }
  arg="$kind"
fi
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
  Example: TASK: Юрий: buy the domain (supersedes t-372640)
Mention an id (t-b58d76) in any line to keep that record alive. Restating a task or decision? Do not write a new record — add (supersedes <id>) or DONE <id>:.
Keep the journal current: the Stop hook blocks an answer when the journal is older than $stale min."
  nstale=$(awk -F' [|] ' -v c="$(bro_days_ago "$(bro_config_get staleDays 3)")" '$3 < c' "$(bro_log_path "$ws" task)" 2>/dev/null | grep -c .)
  [ "${nstale:-0}" -gt 0 ] && out="$out
Stale tasks: $nstale — touch or DONE them"
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
lives=$(bro_kind_field "$arg" lives); cutoff=""
[ "$arg" = task ] && cutoff=$(bro_days_ago "$(bro_config_get staleDays 3)")   # stale marks: tasks only
used=$((${#head} + foot_max)); shown=0; body=""
while IFS= read -r line; do
  id="${line%% | *}"; r="${line#* | }"; r="${r#* | }"; touched="${r%% | *}"; r="${r#* | }"; r="${r#* | }"
  r=$(printf '%s' "$r" | sed -E 's/ \| [^ |]*\.md(#[0-9:]*)?$//')
  l="$id · $touched · $r"
  [ -n "$cutoff" ] && [[ "$touched" < "$cutoff" ]] && l="$l · stale? touch or DONE"
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
