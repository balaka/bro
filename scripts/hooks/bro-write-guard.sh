#!/bin/bash
# bro v3.3 — PreToolUse hook on Write|Edit (the guard).
# Denies writes to (a) legacy v2 storage paths (bro/ inside repos) and
# (b) generated read-mirrors (bro-view/ — rsync --delete erases local edits).
# Works without jq (sed fallback), so a degraded PATH cannot silently disarm it.
#
# v3.7 (§5) — matcher widens to Write|Edit|Bash. bro-append.sh is now the
# sole way to add a section to a shared daily journal (<ws>/YYYY-MM-DD.md):
# a direct Write/Edit on that one file shape is denied (registers,
# _workspace.md, INDEX.md and everything else under the store are untouched
# — only the date-shaped journal filename triggers this), and a Bash command
# that looks like a write-shaped redirect into that same file shape is
# denied too. Both denials teach the exact bro-append.sh invocation inline,
# because a chat may still be holding pre-3.7 skill text in context that
# says "Edit/Write the journal directly."

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
if [ "$HAS_JQ" = 1 ]; then
  TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
  FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  TOOL=$(printf '%s' "$INPUT" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  FP=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  CMD=$(printf '%s' "$INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)
fi

deny() { # $1 = reason
  if [ "$HAS_JQ" = 1 ]; then
    jq -cn --arg r "$1" '{decision:"block", reason:$r,
      hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  else
    echo "$1" >&2
    exit 2
  fi
}

# the exact bro-append.sh invocation, shown in full in every journal-write
# denial below — a chat needs no other context to recover from this
APPEND_HELP() { # $1 = workspace name (may be empty — still teaches the shape)
  printf "Append instead, via Bash (stdin = section body; put each marker DECIDED:/REJECTED:/RULE:/TAIL:/TERM:/CLOSED: — RU aliases equally valid — on its own line, bro-append.sh inserts the blank line after it for you):\n~/.claude/bro/bin/bro-append.sh --workspace %s --thread '<work thread>' --topic '<topic with a distinguishing detail>' <<'EOF'\n<free text and/or marker lines>\nEOF\nIt stamps HH:MM from the real clock itself (no time argument exists), validates the body before writing a byte, and appends atomically under a lock — no interleaving with other chats." "${1:-<workspace>}"
}

# a shared daily journal's own filename shape, one level under the store:
# <root>/<workspace>/YYYY-MM-DD.md — matched on the workspace-relative
# remainder so $ROOT (a $HOME path) never has to be regex-escaped.
journal_ws() { # $1 = workspace-relative path; prints workspace name if it matches, else nothing
  case "$1" in
    */*)
      local rest="${1#*/}"
      case "$rest" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md) printf '%s' "${1%%/*}" ;;
      esac
      ;;
  esac
}

if [ "$TOOL" = "Write" ] || [ "$TOOL" = "Edit" ]; then
  [ -z "$FP" ] && exit 0

  # central store → fine, EXCEPT the one file shape that now has a sole
  # write path (bro-append.sh); registers, _workspace.md, INDEX.md, etc.
  # are untouched by this — hand status flips on them stay allowed.
  case "$FP" in
    "$ROOT"/*)
      WSNAME=$(journal_ws "${FP#"$ROOT"/}")
      if [ -n "$WSNAME" ]; then
        deny "bro v3.7: $FP is the shared daily journal — a direct Write/Edit can clobber a parallel chat's own section, and the old free-form body let an invented (non-clock) time or a malformed marker slip past unnoticed. $(APPEND_HELP "$WSNAME")"
      fi
      exit 0
      ;;
  esac

  # generated read-mirror: local edits get erased by the next rsync --delete
  if echo "$FP" | grep -qE '(^|/)bro-view/'; then
    deny "bro v3: $FP is inside a generated read-mirror (bro-view/) — local edits are erased on the next refresh. Write to the central store instead: $ROOT/<workspace>/."
  fi

  # legacy v2 storage-shaped paths inside a repo-level bro/ folder
  if echo "$FP" | grep -qE '(^|/)bro/(_principles\.md|_index\.md|[0-9]{4}-[0-9]{2}-[0-9]{2}\.md|[^/]+/(_thread\.md|[0-9]{4}-[0-9]{2}-[0-9]{2}\.md))$'; then
    deny "bro v3: $FP is a legacy bro storage path (v2 layout, archived). Write to the central store instead: $ROOT/<workspace>/. If migration has not run yet, run /bro migrate first."
  fi

  exit 0
fi

if [ "$TOOL" = "Bash" ]; then
  [ -z "$CMD" ] && exit 0
  # Narrow, best-effort heuristic — a nudge for the habitual case, NOT the
  # safety net (the stop hook's hash-gated lint is that). Fires only when
  # the command text contains BOTH a literal journal-shaped filename
  # (YYYY-MM-DD.md) AND a write-shaped shell operator, AND the command text
  # also names the store root (mirrors the Write/Edit branch's
  # `"$ROOT"/*` scoping above) — either $ROOT's absolute path, or the
  # equivalent ~/<rel> shorthand a chat is far more likely to actually
  # type (bro's own default root is ~/bro; every test and worked example
  # in this repo writes paths that way). Without this, ANY unrelated
  # project's own dated .md file (changelog, log rotation, a daily note in
  # a completely different repo) would be denied as if it were a bro
  # journal write — this file shape (YYYY-MM-DD.md) is common far outside
  # bro. Deliberately does NOT catch: a dynamically-built path
  # ($(date +%F).md, a shell variable, a wrapper script); sed/perl -i
  # spelled with no space or a different flag order; a `tee`/redirect
  # whose target isn't literally a date-shaped name (e.g. writing through
  # a symlink); anything piped through a second process before it reaches
  # the file. It also does NOT catch, and must not catch, commands that
  # merely READ a journal (cat/grep/head/tail with no redirect out) or
  # writes to registers/_workspace.md (neither is date-shaped, so the
  # filename half of the match never fires for them).
  if echo "$CMD" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}\.md'; then
    ROOT_TILDE=""
    case "$ROOT" in "$HOME"/*) ROOT_TILDE="~${ROOT#"$HOME"}" ;; esac
    if echo "$CMD" | grep -qF "$ROOT" || { [ -n "$ROOT_TILDE" ] && echo "$CMD" | grep -qF "$ROOT_TILDE"; }; then
      # strip fd-duplication (2>&1) and /dev/null redirects before looking for
      # a write operator — both are common in harmless read-only commands and
      # would otherwise false-positive on the bare ">" check below
      STRIPPED=$(echo "$CMD" | sed -E 's/[0-9]>&[0-9]//g; s/>[[:space:]]*\/dev\/null//g')
      if echo "$STRIPPED" | grep -qE '(>>|[^>]>[^>&]|\btee\b|\bsed[[:space:]]+-i)'; then
        deny "bro v3.7: this Bash command looks like it writes directly into a shared daily journal (matched a YYYY-MM-DD.md path under $ROOT together with a write-shaped redirect/tee/sed -i). $(APPEND_HELP "")"
      fi
    fi
  fi
  exit 0
fi

exit 0
