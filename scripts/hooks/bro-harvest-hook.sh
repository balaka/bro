#!/bin/bash
# bro v3.8 — harvest hook, registered with "async": true under BOTH
# SessionStart (all matchers) and, since §3 of the v3.8 plan, Stop — same
# script, same behavior, whichever event fires it. Harvests the current
# workspace's markers into the registers in the background, so neither hook
# that actually injects context / enforces freshness ever waits for it (and
# can never be cancelled because of it). Emits nothing; harvest is
# incremental, so a normal run costs well under a second (measured: 0.74s
# for two fresh records) — only the first run after an upgrade, or a --full
# run, reads every journal.
# Workspace resolution is the same walk as bro-session-start.sh and
# bro-stop-turnstile.sh use — config map (cwd, then ancestors), then a
# dir-slug walk up to $HOME. This only reads "cwd" and "session_id" from the
# hook's stdin JSON, and both SessionStart's and Stop's payloads carry those
# two fields the same way (they differ in fields this script never touches —
# e.g. SessionStart's "source" vs Stop's "stop_hook_active"), so the exact
# same code below is already correct for either event with no branch on
# hook_event_name.
#
# v3.8 (§3) — Stop now fires this same hook every turn, not just once per
# session, so a workspace with a fast back-and-forth chat can trigger a
# second run before the first finished. A per-workspace, single-attempt
# lock (mkdir, no spin) below makes a second concurrent trigger for the SAME
# workspace exit immediately instead of queueing behind the first one or
# racing it — queueing would only delay a harvest that's already in flight
# and about to cover the same new lines anyway. Deliberately NOT
# bro-lib.sh's lock() (which spins ~3s waiting — built for a short critical
# section like one register write, not "skip if busy"); a whole harvest
# pass can legitimately run longer than that, and spinning here would just
# be a slower way to do the queueing this section explicitly rules out.
# Same 5-minute stale-lock reclaim convention as bro-lib.sh's lock(), so a
# killed hook process can't wedge every future harvest of this workspace
# shut.

set -uo pipefail

command -v jq >/dev/null 2>&1 && HAS_JQ=1 || HAS_JQ=0
CONFIG="$HOME/.claude/bro-config.json"

if [ "$HAS_JQ" = 1 ]; then
  ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
else
  ROOT="~/bro"
fi
ROOT="${ROOT/#\~/$HOME}"

INPUT=$(cat)
jget() { # $1 = key
  if [ "$HAS_JQ" = 1 ]; then
    echo "$INPUT" | jq -r ".$1 // empty" 2>/dev/null
  else
    printf '%s' "$INPUT" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}
CWD=$(jget cwd); [ -z "$CWD" ] && CWD=$(pwd)
SID=$(jget session_id)
case "$SID" in *[!A-Za-z0-9_-]*) SID="" ;; esac
[ -n "$SID" ] && [ -f "$HOME/.claude/bro/off/$SID" ] && exit 0

slug_of() { basename "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-._'; }

# resolution: config map (cwd, then ancestors) → dir-slug walk up to $HOME
WS=""
D="$CWD"
while :; do
  if [ "$HAS_JQ" = 1 ]; then
    M=$(jq -r --arg c "$D" '.workspaces[$c] // empty' "$CONFIG" 2>/dev/null)
    [ -n "$M" ] && { WS="$M"; break; }
  fi
  [ "$D" = "$HOME" ] || [ "$D" = "/" ] && break
  D=$(dirname "$D")
done
if [ -z "$WS" ]; then
  D="$CWD"
  while [ "$D" != "$HOME" ] && [ "$D" != "/" ]; do
    S=$(slug_of "$D")
    if [ -n "$S" ] && [ -d "$ROOT/$S" ]; then WS="$S"; break; fi
    D=$(dirname "$D")
  done
fi
[ -n "$WS" ] || exit 0
WS_DIR="$ROOT/$WS"
[ -d "$WS_DIR" ] || exit 0

# an outdated store is migrated first, never harvested into.
# v4.0 (coordinator fix, post-3.9-review): this used to skip harvesting
# whenever the store's major was behind the INSTALLED SKILL's major — fine
# while the skill was v3, but the moment the skill became v4 that same
# check would ALSO skip every still-untranslated v3 store, silently
# stopping decisions.md/open.md/vocab.md/insights.md from ever filling in
# again until the operator ran /bro migrate. A v3 store is fully readable
# by bro-harvest.sh (bilingual RU/EN register reads shipped in v3.9) — only
# a genuinely incompatible store (pre-3, a different on-disk architecture)
# should skip harvesting here, same hard-coded-3 threshold
# bro-session-start.sh's own version check now uses, for the same reason.
STORE_MAJOR=$(cat "$ROOT/.version" 2>/dev/null || echo 0)
[ "$STORE_MAJOR" -lt 3 ] 2>/dev/null && exit 0

HARVEST="$(dirname "$0")/bro-harvest.sh"
[ -x "$HARVEST" ] || HARVEST="$HOME/.claude/bro/bin/bro-harvest.sh"
[ -x "$HARVEST" ] || exit 0

# single-attempt lock — see header. Busy and fresh (<5min old) → another
# trigger for this workspace is already running; exit now, no queueing, no
# spin. Busy and stale (>5min, a crashed/killed hook) → reclaim and proceed,
# same threshold bro-lib.sh's lock() uses for the same reason.
PASSLOCK="$WS_DIR/.harvest-hook.lock"
if ! mkdir "$PASSLOCK" 2>/dev/null; then
  if [ -n "$(find "$PASSLOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ] && rmdir "$PASSLOCK" 2>/dev/null && mkdir "$PASSLOCK" 2>/dev/null; then
    :   # reclaimed a crash-leftover lock — proceed
  else
    exit 0
  fi
fi
trap 'rmdir "$PASSLOCK" 2>/dev/null' EXIT

"$HARVEST" --root "$ROOT" --workspace "$WS" --quiet >/dev/null 2>&1
exit 0
