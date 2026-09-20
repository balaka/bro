# bro-lib.sh — shared primitives sourced by bro's scripts (harvest, append,
# hooks). Not executable on its own (no shebang line runs it) — every
# consumer sources it:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"
# which finds it both in the repo layout (scripts/bro-harvest.sh next to
# scripts/bro-lib.sh) and the installed layout (~/.claude/bro/bin/ holds
# both) — bro-install.sh copies this file into the same bin dir as every
# script that sources it.
#
# v3.7 — extracted out of bro-harvest.sh, where lock()/unlock() used to be
# the only copy (62-75) and MRE the only copy (86). Centralizing them here
# closes the exact duplication the project already hit once: the marker
# keyword list would otherwise need to be kept in sync by hand across
# harvest's own MRE, the stop hook's colon lint, and bro-append.sh's
# pre-write validator. One source of truth instead of three drifting ones.
# bash 3.2 + BSD/GNU userland only — no bashisms newer shells assume.

# lock() — mkdir-based mutex; $1 = path to protect (lockdir = $1.lock).
# mkdir is atomic even on old NFS/AFP shares, unlike a lockfile + test -f
# race. Bounded spin (~3 s) + stale-lock reclaim: a lock older than 5 min is
# a crash leftover, not a live holder — reclaiming it is what keeps a killed
# pass from silencing register appends (or a journal append, or INDEX
# regeneration) forever.
lock() {
  local l="$1.lock" i=0
  until mkdir "$l" 2>/dev/null; do
    if [ -n "$(find "$l" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      rmdir "$l" 2>/dev/null && continue
    fi
    i=$((i+1)); [ "$i" -gt 60 ] && return 1
    sleep 0.05
  done
  return 0
}
unlock() { rmdir "$1.lock" 2>/dev/null; return 0; }

# hash_range() — sha256 of a file's line range, for content-addressed trust:
# bro-append.sh logs this per write, and the stop hook's hybrid lint later
# re-hashes the same range and trusts it only while the bytes still match
# (a hand-edit or historical content changes the hash, so it still gets
# scrutiny). $1 = file  $2 = first line  $3 = last line  -> hex digest on
# stdout. Tries shasum first (macOS/BSD ships it, and Linux distros that
# have Perl do too), falls back to sha256sum (GNU coreutils, no Perl needed)
# so it works on either userland this project targets.
hash_range() {
  local f="$1" from="$2" to="$3"
  if command -v shasum >/dev/null 2>&1; then
    sed -n "${from},${to}p" "$f" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
  else
    sed -n "${from},${to}p" "$f" 2>/dev/null | sha256sum | cut -d' ' -f1
  fi
}

# MRE — the one marker-keyword regex every script that recognizes a marker
# must use (harvest's case-switch, the stop hook's colonless-marker lint,
# bro-append.sh's pre-write validator). Shape: optional indent, optional
# "- " bullet, optional **bold**, keyword, optional [-–—]suffix
# ("RULE-кандидат", "ХВОСТ-вопрос" — real chats write these), optional
# closing **, optional single pre-colon token (id or noise), colon.
# NB: [*][*] instead of \*\* — awk -v reprocesses backslash escapes and
# would corrupt the regex.
# v3.7 — CLOSED/ЗАКРЫТ added (§1 of the v3.7 plan): the sixth marker, closes
# an existing <ws>/open.md tail via harvest instead of a hand-edit. Unlike
# the other five, its pre-colon token is not optional noise — it must be the
# target tail's own id, or the close is unresolvable (see bro-harvest.sh).
MRE='^[[:space:]]*(-[[:space:]]+)?([*][*])?(DECIDED|RULE|TAIL|TERM|REJECTED|CLOSED|РЕШЕНИЕ|ПРАВИЛО|ХВОСТ|ТЕРМИН|ОТКАЗ|ЗАКРЫТ)([-–—][^ :]*)?([*][*])?( [^ :]+)?:'

# MRE_NOCOLON — a marker KEYWORD with no colon: the shape harvest's MRE above
# requires a colon to recognize a marker at all, so a line like "DECIDED chose
# X" (no ':') is invisible to harvest — silently dropped, not an error anyone
# sees. Two consumers need to catch this before it happens: the stop hook's
# lint (post-hoc, on whatever is already in the journal) and bro-append.sh's
# pre-write validator (reject before a byte is written). v3.7 — extracted out
# of bro-stop-turnstile.sh, which was the only copy before bro-append.sh
# became a second consumer; same duplication concern as MRE above (§0.1).
# Uses [*][*] not \*\* for the same awk -v reprocessing reason as MRE.
MRE_NOCOLON='^[[:space:]]*([*][*])?(DECIDED|RULE|TAIL|TERM|REJECTED|CLOSED|РЕШЕНИЕ|ПРАВИЛО|ХВОСТ|ТЕРМИН|ОТКАЗ|ЗАКРЫТ)([*][*])?[[:space:]][^:]*$'
