#!/bin/bash
# bro v5 regression suite — runs every tests/parts/v5-*.sh in its own temp HOME.
# Never reads or writes the real ~/bro. Prints PASS:/FAIL: lines; exit 1 on any FAIL.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "FAIL: setup — jq is required"; exit 1; }
total=0; failed=0
for part in "$DIR"/parts/v5-*.sh; do
  out=$(bash "$part" 2>&1)
  printf '%s\n' "$out"
  n=$(printf '%s\n' "$out" | grep -c '^PASS:'); f=$(printf '%s\n' "$out" | grep -c '^FAIL:')
  total=$((total + n + f)); failed=$((failed + f))
done
echo "== $total checks, $failed failed"
[ "$failed" -eq 0 ]
