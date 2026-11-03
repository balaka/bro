#!/bin/bash
# bro-harvest.sh — journal markers -> logs (SPEC §4/§5). Idempotent via .harvest-state.
#   bro-harvest.sh [--workspace <ws>] [--all]
# --all resets state, truncates every log+archive+misses, rebuilds all workspaces
# from all journals in date order (--workspace is ignored then: global logs are shared).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"

WS=""; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || { echo "[bro-harvest] --workspace needs a value" >&2; exit 1; }; WS="$2"; shift ;;
    --all) ALL=1 ;;
    *) echo "[bro-harvest] unknown argument '$1'" >&2; exit 1 ;;
  esac
  shift
done
ROOT=$(bro_root); [ -d "$ROOT" ] || exit 0
RE_ID='[a-z]-[0-9a-f]{6}'
RE_FIND='(^|[^A-Za-z0-9_-])([a-z]-[0-9a-f]{6})([^A-Za-z0-9_]|$)'
RE_SUP='^(.*[^ ]) +\(supersedes ([a-z]-[0-9a-f]{6})\)[[:space:]]*$'
RE_SRC=' \| [^ |]+\.md(#[0-9]{2}:[0-9]{2})?$'
KINDS=$(bro_kinds)

ws_list() { # workspaces with journals
  local d
  for d in "$ROOT"/*/; do
    d=$(basename "$d"); case "$d" in _*|.*) continue ;; esac
    ls "$ROOT/$d" 2>/dev/null | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}.*\.md$' && echo "$d"
  done
}
# log path of the live-or-not record id (by prefix), local first then global
log_of() { # ws id -> log path that holds it open
  local k sc fl p
  while IFS=$'\t' read -r k sc _ p fl _; do
    [ "$p" = "${2%%-*}" ] || continue
    if [ "$sc" = global ]; then p="$ROOT/$fl.log"; else p="$ROOT/$1/$fl.log"; fi
    [ -f "$p" ] && grep -q "^$2 | " "$p" && { echo "$p"; return 0; }
  done <<EOT
$KINDS
EOT
  return 1
}
# awk: rewrite field 3 (touch, only forward) or field 4 (status) of record id
touch_rec() { # log id date
  bro_lock "$1"
  awk -v id="$2" -v d="$3" 'index($0,id" | ")==1 { s=$0; out=""
    for (i=0;i<2;i++) { p=index(s," | "); out=out substr(s,1,p+2); s=substr(s,p+3) }
    p=index(s," | "); t=substr(s,1,p-1); if (d>t) t=d; print out t substr(s,p); next } {print}' "$1" > "$1.tmp$$" && mv "$1.tmp$$" "$1"
  bro_unlock "$1"
}
archive_rec() { # log id status
  local arc="${1%.log}.archive"
  bro_lock "$1"
  awk -v id="$2" -v st="$3" -v arc="$arc" 'index($0,id" | ")==1 { s=$0; out=""
    for (i=0;i<3;i++) { p=index(s," | "); out=out substr(s,1,p+2); s=substr(s,p+3) }
    p=index(s," | "); print out st substr(s,p) >> arc; next } {print}' "$1" > "$1.tmp$$" && mv "$1.tmp$$" "$1"
  bro_unlock "$1"
}
rec_text() { # log line -> text field (source stripped)
  local r="$1"; r="${r#* | }"; r="${r#* | }"; r="${r#* | }"; r="${r#* | }"
  [[ $r =~ $RE_SRC ]] && r="${r%"${BASH_REMATCH[0]}"}"
  printf '%s' "$r"
}
miss() { printf '%s | %s | %s\n' "$DATE" "$1" "$2" >> "$ROOT/$W/misses.log"; }
retire() { # id status line — archive id wherever it is open, else miss
  local l; l=$(log_of "$W" "$1") && archive_rec "$l" "$1" "$2" || miss "$1" "$3"
}

do_line() { # one journal line
  local line="$1" k sc mk p fl lv text newid log sup="" l id s
  if [[ $line =~ ^DONE\ ($RE_ID):\ *(.*)$ ]]; then
    retire "${BASH_REMATCH[1]}" "done:$DATE" "$line"
  else
    while IFS=$'\t' read -r k sc mk p fl lv _; do
      case "$line" in "$mk "*) ;; *) continue ;; esac
      text="${line#"$mk "}"; text="${text%"${text##*[![:space:]]}"}"
      [ -n "$text" ] || break
      if [[ $text =~ $RE_SUP ]]; then text="${BASH_REMATCH[1]}"; sup="${BASH_REMATCH[2]}"; fi
      newid=$(bro_id "$k" "$DATE" "$text")
      if [ "$sc" = global ]; then log="$ROOT/$fl.log"; else log="$ROOT/$W/$fl.log"; fi
      mkdir -p "$(dirname "$log")"; touch "$log"
      id=""
      while IFS= read -r l; do
        [ "$(rec_text "$l")" = "$text" ] && { id="${l%% | *}"; break; }
      done < "$log"
      if [ -n "$id" ]; then touch_rec "$log" "$id" "$DATE"; newid="$id"
      else
        if [ "$lv" = last ]; then
          while IFS= read -r l; do archive_rec "$log" "${l%% | *}" "superseded:$newid"; done < <(cut -d' ' -f1 "$log")
        fi
        bro_lock "$log"
        printf '%s | %s | %s | open | %s | %s\n' "$newid" "$DATE" "$DATE" "$text" "$SRC" >> "$log"
        bro_unlock "$log"
      fi
      [ -n "$sup" ] && [ "$sup" != "$newid" ] && retire "$sup" "superseded:$newid" "$line"
      break
    done <<EOT
$KINDS
EOT
  fi
  s="$line"   # touch every open id mentioned
  while [[ $s =~ $RE_FIND ]]; do
    id="${BASH_REMATCH[2]}"; s="${s#*"$id"}"
    log=$(log_of "$W" "$id") && touch_rec "$log" "$id" "$DATE"
  done
}

harvest_file() { # ws file
  local f="$ROOT/$1/$2" st="$ROOT/$1/.harvest-state" have n=0 sec="" line
  have=$(awk -F'\t' -v f="$2" '$1==f {print $2}' "$st" 2>/dev/null); have=${have:-0}
  DATE="${2:0:10}"; W="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); line="${line%$'\r'}"
    [[ $line =~ ^##\ ([0-9]{2}:[0-9]{2}) ]] && sec="${BASH_REMATCH[1]}"
    [ "$n" -le "$have" ] && continue
    SRC="$1/$2"; [ -n "$sec" ] && SRC="$SRC#$sec"
    do_line "$line"
  done < "$f"
  { grep -v -F "$2"$'\t' "$st" 2>/dev/null; printf '%s\t%s\n' "$2" "$n"; } > "$st.tmp$$"; mv "$st.tmp$$" "$st"
}

if [ "$ALL" = 1 ]; then
  WSS=$(ws_list)
  for w in $WSS; do rm -f "$ROOT/$w/.harvest-state" "$ROOT/$w/misses.log"; done
  while IFS=$'\t' read -r k sc _ _ fl _; do
    if [ "$sc" = global ]; then : > "$ROOT/$fl.log"; : > "$ROOT/$fl.archive"
    else for w in $WSS; do : > "$ROOT/$w/$fl.log"; : > "$ROOT/$w/$fl.archive"; done; fi
  done <<EOT
$KINDS
EOT
elif [ -n "$WS" ]; then WSS="$WS"; else WSS=$(ws_list); fi

LOCKS=""
for w in $WSS; do
  [ -d "$ROOT/$w" ] || continue
  bro_lock "$ROOT/$w/.harvest-state" || { echo "[bro-harvest] $w busy" >&2; continue; }
  LOCKS="$LOCKS $w"
done
trap 'for w in $LOCKS; do bro_unlock "$ROOT/$w/.harvest-state"; done' EXIT
# all journals of all workspaces, oldest first
for w in $LOCKS; do
  ls "$ROOT/$w" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}.*\.md$' | sed "s|^|$w	|"
done | sort -t$'\t' -k2,2 -k1,1 | while IFS=$'\t' read -r w f; do
  harvest_file "$w" "$f"
done
exit 0
