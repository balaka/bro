#!/bin/bash
# bro-upgrade.sh — one-shot v5.0 -> v5.1 store upgrade. Refuses a second run (~/bro/.v5.1-upgraded).
#   1. kinds.md: add the principle row, make rule local.  2. rules.log -> principles.log + <ws>/rules.log.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"
ROOT=$(bro_root); STAMP="$ROOT/.v5.1-upgraded"; CUT=2026-11-04
[ -d "$ROOT" ] || { echo "[bro-upgrade] no store at $ROOT" >&2; exit 1; }
[ -f "$STAMP" ] && { echo "[bro-upgrade] already upgraded ($STAMP)" >&2; exit 1; }

# (a) kinds.md, edited in place
K="$ROOT/kinds.md"
if [ -f "$K" ]; then
  if ! grep -Eq '^[[:space:]]*\|[[:space:]]*principle[[:space:]]*\|' "$K"; then
    awk '/^[ \t]*\|[ \t]*rule[ \t]*\|/ && !done { print "| principle | global | PRINCIPLE: | p | principles | forever | how to work with the operator everywhere; written ONLY when he says so explicitly (\"это принцип\", \"во всех проектах\") |"; done=1 } { print }' "$K" > "$K.tmp" && mv "$K.tmp" "$K"
  fi
  awk -F'|' 'BEGIN{OFS="|"} { k=$2; gsub(/[ \t]/,"",k); if (k=="rule" && NF>=8) $3=" local " } { print }' "$K" > "$K.tmp" && mv "$K.tmp" "$K"
fi

# (b) split rules.log / rules.archive: old-dated or source-less -> principles, the rest -> <ws>/rules.*
np=0; nl=0
for ext in log archive; do
  f="$ROOT/rules.$ext"; [ -f "$f" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    src=$(printf '%s\n' "$line" | awk -F' [|] ' 'NF>=6 {print $NF}'); ws="${src%%/*}"
    created="${line#* | }"; created="${created%% | *}"
    if [[ "$created" < "$CUT" ]] || [ -z "$src" ] || [ -z "$ws" ] || [ ! -d "$ROOT/$ws" ]; then
      printf '%s\n' "p${line#?}" >> "$ROOT/principles.$ext"; np=$((np+1))
    else
      printf '%s\n' "$line" >> "$ROOT/$ws/rules.$ext"; nl=$((nl+1))
    fi
  done < "$f"
  rm -f "$f"
done
touch "$STAMP"
echo "[bro-upgrade] principles: $np · workspace rules: $nl · kinds.md updated · rules.log removed"
