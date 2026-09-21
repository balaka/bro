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

# v3.8 (§5) — operator-state snapshot. Computed HERE, before workspace
# resolution even starts, and used in TWO places below: prepended to the
# early "not connected" hint (coordinator fix after review #3 — the
# snapshot is one per STORE, not per project, so a chat opened outside any
# project should still open with it) and prepended to the normal CTX
# further down. A stale/missing/empty file or an unparseable ts must never
# break this hook (3.6 already fixed one class of "chat opens with no
# context at all" bug; this must not reopen it) — every step below
# degrades instead of failing: no file or no "записано:" line found →
# STATE_BLOCK stays empty and nothing is shown; ts present but not a bare
# integer → age falls back to "age unknown" while the snapshot itself
# still prints.
STATE_FILE="$ROOT/_state.md"
STATE_BLOCK=""
if [ -f "$STATE_FILE" ]; then
  STATE_TS=$(sed -n 's/^<!-- ts: \([0-9][0-9]*\) .*-->$/\1/p' "$STATE_FILE" 2>/dev/null | head -1)
  case "$STATE_TS" in ''|*[!0-9]*) STATE_TS="" ;; esac
  # from the "записано: …" line to EOF — everything the file shows below
  # its own title + two "do not edit by hand" comments, matched by shape
  # rather than a hardcoded line number so a harmless format tweak upstream
  # (bro-harvest.sh) can't silently break this into showing nothing.
  STATE_BODY=$(awk '/^записано: /{f=1} f' "$STATE_FILE" 2>/dev/null)
  if [ -n "$STATE_BODY" ]; then
    AGE_TXT="age unknown"
    NOWSEC=$(date +%s 2>/dev/null)
    case "$NOWSEC" in ''|*[!0-9]*) NOWSEC="" ;; esac
    if [ -n "$STATE_TS" ] && [ -n "$NOWSEC" ]; then
      DIFFSEC=$((NOWSEC - STATE_TS))
      [ "$DIFFSEC" -lt 0 ] 2>/dev/null && DIFFSEC=0
      AGE_TXT="$((DIFFSEC / 3600))h ago"
    fi
    # $(...) strips ALL trailing newlines, so the "\n\n" separator has to be
    # appended OUTSIDE the substitution (at each of this block's two use
    # sites below) — inside it, it would just vanish and glue this block
    # onto whatever follows with no space at all.
    STATE_BLOCK="$(printf 'bro OPERATOR STATE (%s):\n%s' "$AGE_TXT" "$STATE_BODY")"
  fi
fi

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

# v3.8 (§4) — self-create. Normal resolution above (config map, then the
# dir-slug walk-up) found nothing. Ask git for this cwd's own repository
# root and, if it looks like a real project (not $HOME/~/Desktop/~/Downloads
# //, not inside the bro store itself or ~/.claude), adopt it: mkdir the
# workspace and fall straight through into the rest of this script exactly
# as if it had already been connected — everything below only cares that
# WS/WS_DIR are set and WS_DIR exists.
# early_emit() is a minimal, self-contained twin of emit() (defined later,
# once MARK exists) — needed here because a "not connected" exit must still
# print something (unlike before v3.8, where no workspace meant a silent
# exit 0) and that can happen before MARK is ever set up. Keeping it
# separate rather than hoisting emit() itself up is deliberate: emit()'s
# MARK side effect is tied to the start-mark bookkeeping below, and this is
# the one file where a refactor accidentally reordering that bookkeeping is
# the exact class of bug 3.6 had to chase down (a silently context-less
# chat) — smaller, self-contained addition, smaller risk.
early_emit() { # $1 = context string
  if [ "$CONTEXT_ONLY" = 0 ] && [ "$HAS_JQ" = 1 ]; then
    jq -cn --arg ctx "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null && return 0
  fi
  printf '%s\n' "$1"
}
# realdir() — physical (symlink-resolved) form of a path that currently
# exists, else the literal path unchanged (nothing to resolve, and nothing
# a real repo root could be "inside" if it doesn't exist). Needed because
# git rev-parse --show-toplevel already resolves symlinks, but $HOME itself
# can sit behind a symlinked ancestor (this project's own sandboxed tests
# do, via $TMPDIR on macOS) — comparing a resolved TOPLEVEL against an
# unresolved literal $HOME would then miss the exclusion below even though
# the two paths are the same directory.
realdir() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }
inside_or_eq() { case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac; }   # $1=path $2=base

# git_2s() — v3.8 (§4), coordinator fix after review #3. Runs a git
# subcommand capped at a hard ~2s wall clock. There is no timeout/gtimeout
# binary on the operator's machine, so this hand-rolls the same thing. On
# timeout (or any other failure) this prints nothing and returns non-zero
# — indistinguishable from an ordinary git failure, which every caller
# below already treats as "could not determine this" and degrades safely.
# This is what keeps a hung (or hostile) `git` off the hook's 10s budget:
# a `git` shim that sleeps 10s must still let the whole hook finish in
# about 2s with real opening text — the exact class of "chat opens with no
# context" bug 3.6 already had to fix once.
# $@ = the full git command line to run.
#
# POLLS for completion (kill -0 every 0.2s, up to 2s) rather than
# backgrounding a separate "killer" subshell that races a `wait` on the
# command's own pid. A first version did exactly that (background command,
# background killer, `wait "$cmd_pid"`) and it mostly worked, but inside
# this project's own 300+-check test suite — never reproduced standalone,
# not with 20 genuinely parallel copies of the same scenario, not under
# synthetic CPU load — `wait` occasionally returned late enough that a
# slow shim's OWN output had already landed in $out before the kill
# reached it, and a 4s elapsed-time backstop on top of that STILL didn't
# catch every case. Rather than keep chasing a two-background-job race
# blind, this removes the second job entirely: one sequential loop in this
# function's own body decides pass/fail, so there is nothing left to race
# against. kill_tree() reaches a wrapper script's OWN children too (killing
# only the top pid leaves a shim's `sleep 10 &` running to the full 10s,
# confirmed live) without relying on process GROUPS: an earlier version put
# the job in its own group with `set -m` and killed it by negative pid, but
# that makes bash call setpgid() on a non-interactive/no-controlling-tty
# shell — which this hook always is — and that call fails outright on some
# invocation shapes ("child setpgid: Operation not permitted", also seen
# live from inside the test harness). pgrep -P (direct children only,
# read-only, no permission needed beyond signaling processes this user
# already owns) sidesteps that whole problem too.
# On timeout this does NOT wait() for the child after killing it (see the
# comment at that exact line below) — a process stuck in an
# uninterruptible kernel wait (dead network mount) ignores SIGKILL until
# the kernel itself lets it go, and waiting for that would silently
# reopen the "hook hangs past its budget" bug this function exists to close.
kill_tree() { # $1 = pid; kills it and its direct children (one level)
  pkill -9 -P "$1" 2>/dev/null   # children first (by parent pid, one syscall-ish call, no find-then-kill race window)
  kill -9 "$1" 2>/dev/null
}
git_2s() {
  local out cmd_pid rc ticks
  out=$(mktemp "${TMPDIR:-/tmp}/bro-git2s.XXXXXX" 2>/dev/null) || return 1
  "$@" >"$out" 2>/dev/null &
  cmd_pid=$!
  ticks=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep 0.2
    ticks=$((ticks + 1))
    if [ "$ticks" -ge 10 ]; then   # 10 * 0.2s = 2s
      kill_tree "$cmd_pid"
      # v3.8, coordinator fix (re-review): do NOT wait() for it here. A
      # process stuck in an uninterruptible kernel wait (D state — a dead
      # network mount is the classic case) does not honor SIGKILL until
      # the kernel-level I/O itself resolves, which can take far longer
      # than the 2s cap this function exists to enforce — waiting here
      # would silently reopen the exact "hook hangs past its budget" bug
      # this whole mechanism was built to close. Return failure right
      # away; kill_tree already sent the signal, so the process dies the
      # moment the kernel actually lets it, and — since this hook's own
      # process exits shortly after anyway — any leftover child is
      # reparented to init and reaped there, not by anything in this
      # script waiting around for it.
      rm -f "$out" 2>/dev/null
      return 1
    fi
  done
  # the loop exited because kill -0 stopped finding the pid — it has
  # already exited (or is a zombie awaiting reap); wait() collects its
  # real exit status without any further delay.
  wait "$cmd_pid" 2>/dev/null
  rc=$?
  cat "$out" 2>/dev/null
  rm -f "$out" 2>/dev/null
  return $rc
}

# resolve_repo_root() — v3.8 (§4), coordinator fix after review #3. $1=cwd.
# Prints the project root git rev-parse --show-toplevel would give, except
# collapsed to what a human actually means by "this project" in three
# cases, checked in order:
#   1. a path under .../.claude/worktrees/... — where THIS environment's
#      own agents run isolated copies, one per background task — always
#      collapses to the part before that segment. Checked first, by plain
#      string match, no git call needed at all: confirmed against the
#      operator's real disk that without this, every isolated-worktree run
#      would self-create its OWN throwaway project (16 of them, found by
#      review #3's sandbox run).
#   2. a submodule collapses to its superproject's working tree, via
#      `git rev-parse --show-superproject-working-tree` (empty = not a
#      submodule) — a submodule is a DIFFERENT nested project, not a copy
#      of the same one, but still not what opening a chat inside it means.
#   3. a linked worktree (`git worktree add` elsewhere) collapses to the
#      MAIN worktree, via `git worktree list --porcelain`'s own first
#      entry — git always lists the main worktree first, from whichever
#      worktree you ask — a linked copy and its main are the same project.
# Every git call goes through git_2s() above. Prints nothing on any
# failure (not even a partial path) — the caller treats that exactly like
# "not a git repository".
resolve_repo_root() {
  local cwd="$1" toplevel super main_wt
  case "$cwd" in
    */.claude/worktrees/*) printf '%s' "${cwd%%/.claude/worktrees/*}"; return 0 ;;
  esac
  toplevel=$(git_2s git -C "$cwd" rev-parse --show-toplevel) || return 1
  [ -n "$toplevel" ] || return 1
  case "$toplevel" in
    */.claude/worktrees/*) printf '%s' "${toplevel%%/.claude/worktrees/*}"; return 0 ;;
  esac
  super=$(git_2s git -C "$cwd" rev-parse --show-superproject-working-tree)
  if [ -n "$super" ]; then printf '%s' "$super"; return 0; fi
  main_wt=$(git_2s git -C "$cwd" worktree list --porcelain | sed -n 's/^worktree //p' | head -1)
  if [ -n "$main_wt" ]; then printf '%s' "$main_wt"; return 0; fi
  printf '%s' "$toplevel"
  return 0
}

NOWS_HINT=""
if [ -z "$WS" ]; then
  TOPLEVEL=""
  command -v git >/dev/null 2>&1 && TOPLEVEL=$(resolve_repo_root "$CWD")
  if [ -z "$TOPLEVEL" ]; then
    NOWS_HINT="bro: this folder is not connected to bro and is not a git repository — suggest the operator run /bro setup, but only once real work actually starts here."
  elif [ "$TOPLEVEL" = "$(realdir "$HOME")" ] \
     || [ "$TOPLEVEL" = "$(realdir "$HOME/Desktop")" ] \
     || [ "$TOPLEVEL" = "$(realdir "$HOME/Downloads")" ] \
     || [ "$TOPLEVEL" = "/" ] \
     || inside_or_eq "$TOPLEVEL" "$(realdir "$ROOT")" \
     || inside_or_eq "$TOPLEVEL" "$(realdir "$HOME/.claude")"; then
    NOWS_HINT="bro: this git repository's root ($TOPLEVEL) is out of bounds for an auto-created workspace — connect it by hand with /bro setup if you want it tracked, but only once real work actually starts here."
  else
    NEWNAME=$(slug_of "$TOPLEVEL")
    if [ -z "$NEWNAME" ]; then
      # v3.8 (§4), coordinator fix: this is NOT the same failure as mkdir
      # failing below — mkdir was never even called, so saying "mkdir
      # failed" would be a lie. Say what actually happened: the repo's own
      # name has nothing bro's slug_of() can build a folder name from
      # (tr -cd 'a-z0-9-._' strips non-latin bytes entirely — a repo named
      # e.g. "Проект" slugs to "").
      NOWS_HINT="bro: this git repository's root ($TOPLEVEL) has no latin letters or digits in its own name for bro to build a workspace name from — connect it by hand with /bro setup and give it your own name."
    elif [ -d "$ROOT/$NEWNAME" ]; then
      # v3.8 (§4), coordinator fix: already exists — adopt it silently, no
      # mkdir, no announcement. This is NOT the same as the plain dir-slug
      # walk above finding it (that walk only checks ANCESTORS OF CWD, and
      # resolve_repo_root() can now hand back a root that is NOT an
      # ancestor of cwd at all — a linked worktree living at a completely
      # different path, or a submodule's superproject one level up). The
      # first time either is opened, this workspace may already be
      # connected from the main/super copy; without this check every such
      # open would re-announce "a new project" every single time —
      # confirmed live with a real `git worktree add` copy.
      WS="$NEWNAME"
    else
      # v3.8, operator's own decision (after review #3's sandbox run found
      # this WOULD have self-created 16 throwaway projects on the real
      # disk — one per isolated-worktree run that never turned into real
      # work): do NOT create the folder here, at first sight. Only bro
      # SEEING this cwd is not "work starting" — record the candidate
      # name+root next to this session's own start mark instead, and let
      # bro-stop-turnstile.sh (the ONLY other file that touches this — git
      # itself is never re-run there, only read from what this hook
      # decided here) count this chat's own responses against it, creating
      # the workspace only once $autoCreateAfterAnswers responses have
      # actually happened (config key, bro-install.sh default 5 — see that
      # file). name<TAB>root, one line, no trailing content to parse around.
      PENDING_THRESHOLD=5
      if [ "$HAS_JQ" = 1 ]; then
        PENDING_THRESHOLD=$(jq -r '.autoCreateAfterAnswers // 5' "$CONFIG" 2>/dev/null)
        case "$PENDING_THRESHOLD" in ''|*[!0-9]*) PENDING_THRESHOLD=5 ;; esac
      fi
      if [ -n "$SID" ]; then
        mkdir -p "$HOME/.claude/bro/started" 2>/dev/null
        printf '%s\t%s\n' "$NEWNAME" "$TOPLEVEL" > "$HOME/.claude/bro/started/$SID.pending-project" 2>/dev/null
      fi
      NOWS_HINT="bro: project '$NEWNAME' (root $TOPLEVEL) is not yet connected to bro — it will connect itself once work actually starts, after $PENDING_THRESHOLD response(s) in this chat."
    fi
  fi
  if [ -z "$WS" ]; then
    # v3.8 (§5), coordinator fix: the operator-state snapshot is one per
    # STORE, not per project — show it here too, first, same as the
    # connected-project path further down, instead of only when a
    # workspace was actually found.
    early_emit "$STATE_BLOCK${STATE_BLOCK:+$'\n\n'}$NOWS_HINT"
    exit 0
  fi
fi
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

# STATE_BLOCK (§5) was already computed near the top of this file, before
# workspace resolution — see the comment there. It's used here exactly the
# same way it was used in the early "not connected" exit above: prepended
# first, with its own separator added outside the $(...) that built it
# ($(...) strips trailing newlines, so the blank-line separator has to be
# added at each use site instead of baked into the captured value).
CTX="$STATE_BLOCK${STATE_BLOCK:+$'\n\n'}bro v$SKILL_FULL active for workspace '$WS'. NOW: $TODAY $NOW ($DOW) — this is the time source; your inner sense of time is stale after any pause, so take timestamps and greetings from here or from date, never from feeling. Read now, in order:$RO."
CTX="$CTX Journal format: a section is '## HH:MM · <work thread> — <topic with a distinguishing detail>' (HH:MM from date) followed by free text and typed markers on their own lines: DECIDED: / REJECTED: / RULE: / TAIL: / TERM: / STATE: / INSIGHT: (RU: РЕШЕНИЕ:/ОТКАЗ:/ПРАВИЛО:/ХВОСТ:/ТЕРМИН:/СОСТОЯНИЕ:/ИНСАЙТ:) — harvest moves them into the registers automatically. Write STATE: when the operator's mood, energy, or work mode changes — one side per line (several STATE: lines in the same section become several sides of one snapshot; RU/EN must be ALL CAPS, no 'Состояние:'/'State:' — those are read as ordinary prose, not a marker). Write INSIGHT: for a pattern, idea, or new approach worth not losing — bold the conclusion, 1–4 sentences, one line (also ALL CAPS only). Close a TAIL with CLOSED <its exact id from open.md>: <what closed it> (RU: ЗАКРЫТ <id>: ...) — no colon between the keyword and the id, harvest only reads the text before the FIRST colon as keyword+id; never hand-edit open.md; an id harvest can't find open is logged as a CLOSE-MISS, not silently lost. NEVER Write/Edit the journal file directly any more (the write guard denies it) — add a section with Bash: printf '%s\n' 'body text — one or more marker lines allowed' | ~/.claude/bro/bin/bro-append.sh --workspace $WS --thread '<work thread>' --topic '<topic>' — it stamps HH:MM from the real clock itself, validates the body before writing, and appends atomically under a lock. Keep the journal current — the stop hook enforces freshness."
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

# v3.8 (§6) — last 10 insights for this workspace, briefly (text + date);
# the rest are found by search. Same degrade-don't-crash discipline as the
# STATE block above: missing file, empty file, or a line that doesn't match
# the expected register shape all fall through to "show nothing"/"show the
# raw line" rather than an error — never the reason this hook comes back
# with no context at all.
#
# v3.8, coordinator fix after review #3: "last 10" means last by the
# insight's OWN "родился: <date>", not by its position in the file. A
# --full re-parse of an old chronicle can APPEND an old insight after ones
# already in the register (harvest only ever appends, never reorders — see
# bro-harvest.sh), so file order alone would surface a years-old insight as
# the "newest". Below: pull the date out of each line with awk (anchored on
# the literal "родился: " keyword via match()+substr() on ASCII-only output
# — never a hand-counted byte offset past the preceding Cyrillic text; see
# bro-lib.sh's own header for why that specific shortcut is unsafe under
# this awk), pair it with the line's own position (NR) as an explicit
# tiebreaker, sort by (date, NR) — no reliance on `sort`'s stability, the
# tiebreaker is already a real sort key — then take the last 10 and drop
# the two sort-key columns back off.
INS_FILE="$WS_DIR/insights.md"
if [ -f "$INS_FILE" ]; then
  INS_TAB=$(printf '\t')
  INS_KEYED=$(grep '^- \*\*i-' "$INS_FILE" 2>/dev/null | awk -v OFS="$INS_TAB" '
    {
      date = "0000-00-00"
      if (match($0, /родился: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        seg = substr($0, RSTART, RLENGTH)
        if (match(seg, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) date = substr(seg, RSTART, RLENGTH)
      }
      print date, NR, $0
    }')
  if [ -n "$INS_KEYED" ]; then
    INS_LINES=$(printf '%s\n' "$INS_KEYED" | sort -t "$INS_TAB" -k1,1 -k2,2n | tail -n 10 | cut -f3-)
    INS_N=$(printf '%s\n' "$INS_LINES" | wc -l | tr -d ' ')
    # "- **i-xxxxxx** · <body> — родился: <date> · «<section>»" -> "- <body> (<date>)"
    # the body itself may contain its own em dashes (real insights do — see
    # tests/parts/c-hooks.sh); (.*) is greedy so it always stops at the
    # LAST " — родился: " on the line, which is the one the register format
    # itself appends, not anything the body could contain. A line that
    # doesn't match this shape (hand-edited register, format drift) is
    # printed unchanged by sed rather than dropped.
    INS_FMT=$(printf '%s\n' "$INS_LINES" | sed -E 's/^- \*\*i-[^*]+\*\* · (.*) — родился: ([0-9]{4}-[0-9]{2}-[0-9]{2}).*$/- \1 (\2)/')
    CTX="$CTX Last $INS_N insight(s) for this workspace (more via search):
$INS_FMT"
  fi
fi

# legacy v2 logs sitting in this project → tell the model to run migration
if [ -d "$CWD/bro" ] && { [ -f "$CWD/bro/_principles.md" ] || ls "$CWD/bro"/*/.session.json >/dev/null 2>&1; }; then
  CTX="$CTX NOTE: legacy v2 bro logs detected at $CWD/bro — run /bro migrate."
fi

emit "$CTX"
exit 0
