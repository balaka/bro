#!/bin/bash
# bro-append.sh — the only way to write the journal (SPEC §3).
#   printf '%s\n' 'body' | bro-append.sh --workspace <ws> --thread '<t>' --topic '<topic>'
# Stamps the real clock, validates the body, appends under the journal lock.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"

USAGE="Usage: bro-append.sh [--workspace <ws>] --thread '<thread>' --topic '<topic>' < body"
err() { echo "[bro-append] $*" >&2; exit 1; }

WS=""; THREAD=""; TOPIC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace|--thread|--topic) [ $# -ge 2 ] || err "'$1' needs a value. $USAGE" ;;
  esac
  case "$1" in
    --workspace) WS="$2" ;;
    --thread)    THREAD="$2" ;;
    --topic)     TOPIC="$2" ;;
    *) err "unknown argument '$1'. $USAGE" ;;
  esac
  shift 2
done
[ -n "$WS" ] || WS=$(bro_workspace "$PWD")
[ -n "$WS" ] || err "cannot resolve a workspace from $PWD — pass --workspace <name>"
[ -n "$THREAD" ] || err "--thread is required"
[ -n "$TOPIC" ] || err "--topic is required"
case "$THREAD$TOPIC$WS" in *$'\n'*|*/*) err "--workspace, --thread and --topic must be single-line and contain no '/'" ;; esac

# ---- read and validate the body
BODY=$(cat | tr -d '\r')
while [ -n "$BODY" ] && [ -z "$(printf '%s' "${BODY##*$'\n'}" | tr -d '[:space:]')" ]; do
  case "$BODY" in *$'\n'*) BODY="${BODY%$'\n'*}" ;; *) BODY="" ;; esac
done
[ -n "$BODY" ] || err "body (stdin) is empty — nothing to append"

KNOWN=$(bro_kinds | cut -f3 | tr '\n' ' ')
RE_LEAD='^[A-Z][A-Z0-9_-]*:'
RE_ID='^[a-z]-[0-9a-f]{6}:$'
N=0
while IFS= read -r LINE || [ -n "$LINE" ]; do
  N=$((N+1))
  case "$LINE" in "## "*) err "line $N starts with '## ' — a section header is built from --thread/--topic: $LINE" ;; esac
  # leading WORD: must be a known marker, followed by a space and text
  if [[ $LINE =~ $RE_LEAD ]]; then
    W="${BASH_REMATCH[0]}"
    case " $KNOWN" in *" $W "*) ;; *) err "line $N: unknown marker '$W' (known: ${KNOWN% }). Reword the line, or add the kind to kinds.md: $LINE" ;; esac
    REST="${LINE#"$W"}"
    case "$REST" in " "?*) ;; *) err "line $N: marker '$W' needs one space and then text: $LINE" ;; esac
  fi
  case "$LINE" in
    "DONE "*:*) set -f; set -- $LINE; set +f
      [[ ${2:-} =~ $RE_ID ]] || err "line $N: 'DONE' must read 'DONE <id>: <what closed it>' (id like t-b58d76): $LINE" ;;
  esac
done <<EOT
$BODY
EOT

# ---- append under the journal lock
ROOT=$(bro_root); DIR="$ROOT/$WS"; TODAY=$(bro_today); NOW=$(bro_now)
FILE="$DIR/$TODAY.md"
[ -d "$DIR" ] || err "unknown workspace $WS"
bro_lock "$FILE" || err "journal $FILE is locked (busy over 5 s) — try again"
trap 'bro_unlock "$FILE"' EXIT

PRE=0; [ -f "$FILE" ] && PRE=$(wc -l < "$FILE" | tr -d ' ')
{
  if [ ! -s "$FILE" ]; then printf '# %s — %s\n\n' "$WS" "$TODAY"; PRE=0
  else
    [ -n "$(tail -c1 "$FILE")" ] && printf '\n'
    [ -n "$(tail -n1 "$FILE")" ] && printf '\n'
  fi
  printf '## %s · %s — %s\n%s\n\n' "$NOW" "$THREAD" "$TOPIC" "$BODY"
} >> "$FILE" || err "write to $FILE failed"

POST=$(wc -l < "$FILE" | tr -d ' ')
# header line = first line after PRE (+2 for new file's title, +1 blank when needed); body ends 1 before POST
BLEN=$(printf '%s\n' "$BODY" | wc -l | tr -d ' ')
TO=$((POST-1)); FROM=$((TO-BLEN))
echo "[bro-append] wrote $WS/$TODAY.md lines $FROM-$TO"
