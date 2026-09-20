#!/bin/bash
# bro v3.6 — SessionStart hook (matchers: startup, resume, compact, clear).
# Injects the read-order (principles, workspace summary, REGISTERS, journals),
# self-heals a missing store version stamp, flags legacy v2 logs in cwd,
# and teaches the journal/marker format so every chat can write typed records.
# Workspace resolution walks UP from cwd (config map first, then dir slugs),
# so sessions started in project subfolders still find their workspace.
# Silent when bro is not enabled for the project or /bro off is set for the chat.
#
# v3.6: this hook does NOTHING slow. Harvest used to run here, before the
# context was emitted; once a workspace grew (30 s of harvest against a 10 s
# hook timeout) the harness cancelled the hook and discarded its output — every
# session started blind, silently. Harvest now lives in its own async hook
# (bro-harvest-hook.sh). This hook also leaves a start mark
# (~/.claude/bro/started/<session_id>: "pending" on entry, "ok" once the context
# is out; bro-precompact.sh sets it back to "pending" before each compaction) so
# the stop hook can notice a start that never finished and recover it. Not
# covered: a resume where this hook is never launched at all — the old "ok" stays.
# --context-only: print the context as plain text and touch nothing (the stop
# hook's recovery path).

set -uo pipefail

CONTEXT_ONLY=0; [ "${1:-}" = "--context-only" ] && CONTEXT_ONLY=1

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
case "$SID" in *[!A-Za-z0-9_-]*) SID="" ;; esac   # it becomes a file name below — ids are uuids, nothing else passes
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

# start mark: "pending" now, "ok" right before the context goes out. A mark left
# at "pending" means this hook died on the way — the stop hook recovers from it.
MARK_DIR="$HOME/.claude/bro/started"
MARK=""
if [ "$CONTEXT_ONLY" = 0 ] && [ -n "$SID" ]; then
  mkdir -p "$MARK_DIR" 2>/dev/null
  MARK="$MARK_DIR/$SID"
  echo pending > "$MARK" 2>/dev/null
  find "$MARK_DIR" -type f -mtime +180 -delete 2>/dev/null   # far beyond the life of any chat process
fi

# version: self-heal an organic (never-migrated) store, then compare
SKILL_MAJOR=$(cut -d. -f1 "$HOME/.claude/bro/VERSION" 2>/dev/null || echo 3)
if [ "$CONTEXT_ONLY" = 0 ]; then
  [ -f "$ROOT/.version" ] || echo "$SKILL_MAJOR" > "$ROOT/.version" 2>/dev/null
fi
STORE_MAJOR=$(cat "$ROOT/.version" 2>/dev/null || echo 0)

emit() { # $1 = context string
  local OUT=""
  if [ "$CONTEXT_ONLY" = 0 ] && [ "$HAS_JQ" = 1 ]; then
    OUT=$(jq -cn --arg ctx "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null)
  fi
  [ -n "$OUT" ] || OUT="$1"   # no jq, jq failed, or --context-only: plain stdout is injected as context too
  # the mark turns "ok" only once the context is really out
  printf '%s\n' "$OUT" && [ -n "$MARK" ] && echo ok > "$MARK" 2>/dev/null
  return 0
}

if [ "$STORE_MAJOR" -lt "$SKILL_MAJOR" ] 2>/dev/null; then
  emit "bro: STORAGE FORMAT OUTDATED (store v$STORE_MAJOR, skill v$SKILL_MAJOR). Tell the user and run /bro migrate before writing any bro entries."
  exit 0
fi

# (harvest is NOT run here any more — see bro-harvest-hook.sh, registered async)

TODAY=$(date +%F)
NOW=$(date '+%H:%M')
DOW=$(date '+%A')
SKILL_FULL=$(cat "$HOME/.claude/bro/VERSION" 2>/dev/null || echo "3")
YESTERDAY=$(ls "$WS_DIR" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' | sort | grep -v "^$TODAY\.md$" | tail -1)

# read-order: only files that exist, registers included
N=1; RO=""
add() { [ -f "$1" ] && { RO="$RO $N) $1$2"; N=$((N+1)); }; return 0; }
add "$ROOT/_principles.md" ""
add "$WS_DIR/_workspace.md" ""
add "$WS_DIR/decisions.md" " (decision register)"
add "$WS_DIR/open.md" " (open items — close what today's work resolves)"
add "$WS_DIR/vocab.md" " (vocabulary)"
RO="$RO $N) $WS_DIR/$TODAY.md (today's journal; create if missing)"
N=$((N+1))
[ -n "$YESTERDAY" ] && RO="$RO $N) $WS_DIR/$YESTERDAY (previous day)"

CTX="bro v$SKILL_FULL active for workspace '$WS'. NOW: $TODAY $NOW ($DOW) — this is the time source; your inner sense of time is stale after any pause, so take timestamps and greetings from here or from date, never from feeling. Read now, in order:$RO."
CTX="$CTX Journal format: a section is '## HH:MM · <work thread> — <topic with a distinguishing detail>' (HH:MM from date) followed by free text and typed markers on their own lines: DECIDED: / REJECTED: / RULE: / TAIL: / TERM: (RU: РЕШЕНИЕ:/ОТКАЗ:/ПРАВИЛО:/ХВОСТ:/ТЕРМИН:) — harvest moves them into the registers automatically. Close a TAIL with CLOSED <its exact id from open.md>: <what closed it> (RU: ЗАКРЫТ <id>: ...) — no colon between the keyword and the id, harvest only reads the text before the FIRST colon as keyword+id; never hand-edit open.md; an id harvest can't find open is logged as a CLOSE-MISS, not silently lost. NEVER Write/Edit the journal file directly any more (the write guard denies it) — add a section with Bash: printf '%s\n' 'body text — one or more marker lines allowed' | ~/.claude/bro/bin/bro-append.sh --workspace $WS --thread '<work thread>' --topic '<topic>' — it stamps HH:MM from the real clock itself, validates the body before writing, and appends atomically under a lock. Keep the journal current — the stop hook enforces freshness."
if [ -f "$CONFIG" ] && [ "$HAS_JQ" = 1 ] && ! jq empty "$CONFIG" 2>/dev/null; then
  CTX="$CTX WARNING: ~/.claude/bro-config.json is broken JSON — bro is running on defaults; tell the user."
fi

cnt() { local c; c=$(grep -c "$1" "$2" 2>/dev/null || true); [ -n "$c" ] || c=0; printf '%s' "$c" | head -1; }
NOPEN=$(cnt '^- \[ \]' "$WS_DIR/open.md")
[ "$NOPEN" -gt 0 ] 2>/dev/null && CTX="$CTX Open items: $NOPEN unchecked."
# v3.7 (§1): a CLOSED:/ЗАКРЫТ: marker naming an id not open in this
# workspace's open.md is logged, not dropped — surface the count every
# session so it's never only visible by opening the log file by hand.
NMISS=0
[ -f "$WS_DIR/.close-misses.log" ] && NMISS=$(wc -l < "$WS_DIR/.close-misses.log" | tr -d ' ')
[ "$NMISS" -gt 0 ] 2>/dev/null && CTX="$CTX CLOSE-MISS: $NMISS CLOSED:/ЗАКРЫТ: marker(s) named a tail id not found open in open.md — see $WS_DIR/.close-misses.log."
NRULE=$(cnt '^- \[ \]' "$ROOT/_rule-candidates.md")
[ "$NRULE" -gt 0 ] 2>/dev/null && CTX="$CTX Rule candidates pending operator confirmation: $NRULE in $ROOT/_rule-candidates.md."
# review cadence: queue >= 10 OR 7+ days since last review with a non-empty queue
LASTREV=$(cat "$ROOT/.last-rule-review" 2>/dev/null || echo "")
if [ -n "$LASTREV" ]; then
  LASTSEC=$(date -j -f %Y-%m-%d "$LASTREV" +%s 2>/dev/null || date -d "$LASTREV" +%s 2>/dev/null || echo 0)
else
  LASTSEC=0
fi
REVDAYS=$(( ( $(date +%s) - LASTSEC ) / 86400 ))
if [ "$NRULE" -ge 10 ] 2>/dev/null || { [ "$NRULE" -gt 0 ] 2>/dev/null && [ "$REVDAYS" -ge 7 ]; }; then
  CTX="$CTX RULE REVIEW DUE (queue $NRULE, last review ${REVDAYS}d ago; trigger: >=10 or 7d): propose a batched review to the operator this session — group duplicates, recommend verdicts, they answer yes/no. After the review run: date +%F > $ROOT/.last-rule-review"
fi
NDUE=$(awk -v today="$TODAY" '/\*\*Пересмотр:\*\*/ { if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) { d=substr($0,RSTART,RLENGTH); if (d<=today) n++ } } END{print n+0}' "$ROOT/_principles.md" 2>/dev/null)
[ "$NDUE" -gt 0 ] 2>/dev/null && CTX="$CTX Principle reviews DUE: $NDUE (list in INDEX.md, section Reviews due) — walk the operator through them: alive → extend the date with a longer interval; stale → supersede."
[ -f "$ROOT/CONFLICTS.md" ] && CTX="$CTX NOTE: $ROOT/CONFLICTS.md exists — unresolved principle-merge conflicts."

# legacy v2 logs sitting in this project → tell the model to run migration
if [ -d "$CWD/bro" ] && { [ -f "$CWD/bro/_principles.md" ] || ls "$CWD/bro"/*/.session.json >/dev/null 2>&1; }; then
  CTX="$CTX NOTE: legacy v2 bro logs detected at $CWD/bro — run /bro migrate."
fi

emit "$CTX"
exit 0
