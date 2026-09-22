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
#
# v3.8 (§2) — the Bash branch stopped asking "does the journal's path
# appear anywhere in this command's TEXT" (true even when the path is
# sitting inert inside a heredoc BODY that writes a completely different
# file — a real false positive: 20 Sep denied creating ~/bro/bro/anatomy.md
# because its own heredoc body happened to quote a journal filename as a
# worked example) and instead asks "does a write-shaped OPERATOR in this
# command TARGET the journal" — redirects (>, >>, >|, &>, 1>, 2>), tee
# [-a], sed -i, perl -i, cp/mv/install/ln's destination, dd of=, truncate,
# rm/unlink. Heredoc bodies are cut before any of this runs (see
# strip_heredocs below) — but only when doing so is actually safe (see
# strip_heredocs' own comment for the two conditions); an unsafe heredoc is
# deliberately left FOR the scan below to see, never silently trusted.
#
# v3.8 review fixes (reviewer #2, confirmed by running each one) —
# five more precision gaps in the same direction as above:
#  - an UNQUOTED heredoc (<<EOF) was left fully unstripped, so ordinary
#    prose in its body ("Do not run: echo hi >> journal") false-positived
#    exactly like the quoted case §2 already fixed. Now unquoted bodies are
#    stripped too, UNLESS the body contains "$(" or a backtick anywhere in
#    it (checked over the WHOLE buffered body, not line by line — a live
#    substitution can span several physical lines) — kept whole in that
#    case, since a real $(...)/`...` runs for real and must still block;
#  - $HOME/bro/... and ${HOME}/bro/... (unexpanded, literal text) are now
#    recognized alongside ~/bro/... and $ROOT (ROOT_PREFIXES below);
#  - an operator glued to its target with no space (>>file, 2>file, &>file,
#    >|file) is now recognized, not just the spaced form;
#  - a RELATIVE target (no leading / or ~) is resolved against the last
#    `cd DIR` seen earlier in the same command, or the hook's own cwd if
#    none — Bash in Claude Code persists cwd across calls, so a bare
#    filename typed after an earlier `cd` is an everyday shape;
#  - mv now checks its SOURCE too (moving the journal away is a write, same
#    as rm), not just its destination; cp's source is still exempt (reading
#    FROM the journal is not a write).

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
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
else
  TOOL=$(printf '%s' "$INPUT" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  FP=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  CMD=$(printf '%s' "$INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)
  CWD=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
# v3.8 review fix (§4) — same fallback the other three hooks use
# (bro-session-start.sh, bro-stop-turnstile.sh, bro-harvest-hook.sh all do
# `CWD=$(jget cwd); [ -z "$CWD" ] && CWD=$(pwd)`): the hook's own cwd is
# needed below to resolve a RELATIVE write target ("echo x >> 2026-09-21.md"
# with no path at all) — Bash in Claude Code persists its working directory
# across calls, so a bare filename is a completely ordinary, expected shape,
# not an exotic one.
[ -z "$CWD" ] && CWD=$(pwd)

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
  printf "Append instead, via Bash (stdin = section body; put each marker DECIDED:/REJECTED:/RULE:/OPEN:/TERM:/CLOSED: on its own line — Russian aliases are also accepted — РЕШЕНИЕ, ОТКАЗ, ПРАВИЛО, ДЕЛО, ТЕРМИН, ЗАКРЫТ, СОСТОЯНИЕ, ИНСАЙТ — bro-append.sh inserts the blank line after it for you):\n~/.claude/bro/bin/bro-append.sh --workspace %s --thread '<work thread>' --topic '<topic with a distinguishing detail>' <<'EOF'\n<free text and/or marker lines>\nEOF\nIt stamps HH:MM from the real clock itself (no time argument exists), validates the body before writing a byte, and appends atomically under a lock — no interleaving with other chats." "${1:-<workspace>}"
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

# ---------------------------------------------------------------------
# v3.8 (§2) Bash-branch helpers. All narrow, best-effort heuristics — a
# nudge for the habitual case, NOT the safety net (the stop hook's
# hash-gated lint is that) — same character as the rest of this file.
# ---------------------------------------------------------------------

# strip_quotes() — $1 = a shell word. Strips one matching pair of outer
# quotes, then any trailing ')' or backtick left glued on by the
# whitespace-only tokenizer below when the word was the last thing inside
# a "$(...)"/`...` grouping (e.g. "$(echo x >> journal.md)" tokenizes, on
# whitespace alone, into a word "journal.md)" with the paren still stuck
# to it — stripped here so the target underneath still resolves).
strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  while :; do
    case "$s" in
      *')') s="${s%)}" ;;
      *'`') s="${s%\`}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

# journal_target() — $1 = a raw candidate word (quotes not yet stripped).
# True iff it resolves to exactly <workspace>/YYYY-MM-DD.md one level under
# the store — reuses journal_ws() above, so the Bash branch and the
# Write/Edit branch agree on what "is the journal" means. Sets WG_HIT_WS on
# a match.
#
# Three ways a word can resolve:
#  (1) it already starts with one of ROOT_PREFIXES — $ROOT itself, the
#      ~/<rel> shorthand, or (v3.8 review fix §2) the literal unexpanded
#      text "$HOME/<rel>" / "${HOME}/<rel>" — a chat is just as likely to
#      type $HOME as ~ (bro's own bro-append.sh and this very file use
#      $HOME, not ~, throughout);
#  (2) (v3.8 review fix §4) it is a RELATIVE word (no leading /, ~ or $) —
#      resolved against WG_CWD, which bash_write_target_hit keeps current
#      as it walks the command (starts at the hook's own cwd, advances on
#      every `cd DIR`/`pushd DIR` segment it passes — see maybe_update_cwd
#      below);
#  (3) (v3.8 review fix round 2 §2) it is a RELATIVE word and WG_CWD is
#      the sentinel "UNKNOWN" (a `cd` whose argument this hook can't
#      resolve statically — a variable, or `cd -`, saw one earlier in this
#      same command) — the real directory could be anywhere, so this can
#      neither be confirmed NOR ruled out. Erring toward catching it: a
#      relative word whose own name is already JOURNAL-SHAPED
#      (YYYY-MM-DD*.md) is treated as a hit (WG_HIT_UNKNOWN_CWD=1, so the
#      caller can print a different, honest reason); a relative word with
#      any OTHER name is let through — most relative writes are not a
#      journal by name, and flagging every one of them once cwd is merely
#      unknown would be far too noisy to be a "nudge" anyone keeps trusting.
journal_target() {
  local raw="$1" p rel pfx matched=0 resolved
  WG_HIT_UNKNOWN_CWD=0
  p=$(strip_quotes "$raw")
  for pfx in "${ROOT_PREFIXES[@]}"; do
    case "$p" in
      "$pfx"/*) rel="${p#"$pfx"/}"; matched=1; break ;;
    esac
  done
  if [ "$matched" != 1 ]; then
    case "$p" in
      /*|'~'*|'$'*) : ;;   # absolute-ish/var-ish and didn't match any prefix above -> not the journal
      *)
        if [ "$WG_CWD" = "UNKNOWN" ]; then
          case "$p" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.md)
              matched=1; WG_HIT_UNKNOWN_CWD=1 ;;
          esac
        else
          resolved="${WG_CWD%/}/$p"
          case "$resolved" in
            "$ROOT"/*) rel="${resolved#"$ROOT"/}"; matched=1 ;;
          esac
        fi
        ;;
    esac
  fi
  [ "$matched" = 1 ] || return 1
  if [ "$WG_HIT_UNKNOWN_CWD" = 1 ]; then
    WG_HIT_WS="<unknown>"
    return 0
  fi
  WG_HIT_WS=$(journal_ws "$rel")
  [ -n "$WG_HIT_WS" ]
}

# update_cwd_from_cd() — v3.8 review fix (§4), extended in review round 2
# (§2). $1 = the word right after "cd"/"pushd" in a "cd ARG" segment (may
# be empty — bare "cd" goes to $HOME, same as a real shell). Updates the
# running WG_CWD.
#
# Two shapes make the working directory genuinely UNKNOWABLE from static
# text alone, not just "not this exact path": an argument containing a
# variable/substitution ("cd \"\$WSDIR\"" — the real target depends on a
# value this hook never sees), and "cd -" (the previous directory, which
# this hook has no memory of either). Once WG_CWD becomes the sentinel
# "UNKNOWN", it STAYS unknown for the rest of THIS command, even past a
# later cd to a real, static path — this function's own first line
# refuses to change it again. journal_target's own UNKNOWN-cwd branch is
# what a relative target gets checked against while in this state.
update_cwd_from_cd() {
  local arg="$1"
  [ "$WG_CWD" = "UNKNOWN" ] && return
  [ -z "$arg" ] && { WG_CWD="$HOME"; return; }
  case "$arg" in
    *'$'*|*'`'*) WG_CWD="UNKNOWN"; return ;;
  esac
  arg=$(strip_quotes "$arg")
  case "$arg" in
    -) WG_CWD="UNKNOWN" ;;
    /*) WG_CWD="$arg" ;;
    '~') WG_CWD="$HOME" ;;
    '~/'*) WG_CWD="$HOME/${arg#\~/}" ;;
    *) WG_CWD="${WG_CWD%/}/$arg" ;;
  esac
}

# maybe_update_cwd() — v3.8 review fix (§4), extended in review round 2
# (§2). $1 = one statement segment (see bash_write_target_hit). If it's a
# "cd ARG" or "pushd ARG" command, advances WG_CWD for every segment that
# follows — textual order, same as a real shell would execute it left to
# right. pushd is treated exactly like cd (same running "current
# directory" this guard cares about; the rest of the directory STACK
# pushd/popd maintain is not modeled — out of scope, same "narrow
# heuristic" character as the rest of this file).
#
# A leading "(" — a subshell, "( cd DIR; ... )" — is stripped before
# looking at the segment's first word: the paren is not itself a word
# character, so a naive check would see "(" as word 0, never notice "cd"
# sitting right after it, and silently fail to track the subshell's own
# cd at all.
maybe_update_cwd() {
  local seg="$1"
  case "$seg" in '('*) seg="${seg#(}"; seg="${seg# }" ;; esac
  local words_cd
  IFS=$' \t' read -ra words_cd <<<"$seg"
  case "${words_cd[0]:-}" in
    cd|pushd) update_cwd_from_cd "${words_cd[1]:-}" ;;
  esac
}

# is_interpreter_line() — true if $1 (a heredoc introducer line) names, as
# a whole word anywhere on the line (basename-compared, so
# "/usr/bin/python3" still matches "python3"), a command that would
# EXECUTE a heredoc body fed to it, rather than just storing/passing it
# through as inert data. Quoting the delimiter (see strip_heredocs below)
# only stops the OUTER shell from expanding $(...)/`...`/$var in the body
# before handing it over — it does NOT stop a nested interpreter from then
# reading that same body AS ITS OWN SCRIPT and running a real
# "echo x >> journal" line inside it. A short, necessarily incomplete list
# of common interpreters/execution commands — an unrecognized one (an
# exotic interpreter, a wrapper script) is the same documented-gap class
# this guard already accepts elsewhere (see this file's own header).
is_interpreter_line() {
  local ln="$1" w
  local words_il
  IFS=$' \t' read -ra words_il <<<"$ln"
  for w in "${words_il[@]}"; do
    case "${w##*/}" in
      bash|sh|zsh|ksh|dash|csh|tcsh|fish|env|python|python2|python3|node|nodejs|deno|bun|perl|ruby|php|lua*|tclsh|Rscript|osascript|ssh|sudo|su|xargs|eval|source|docker|kubectl)
        return 0 ;;
    esac
  done
  return 1
}

# strip_heredocs() — $1 = a (possibly multi-line) command. Prints it with
# heredoc BODIES removed, so text sitting inert in one (e.g. a journal
# filename quoted as a worked example in anatomy.md's own body — the exact
# 20 Sep false positive this section exists to fix) is never seen by the
# write-target scan below. The introducer line itself is always kept — a
# real write target before the heredoc marker, e.g. "cat > FILE <<'EOF'",
# still needs to be seen.
#
# Three ways a heredoc body is handled, depending on what can and can't
# actually run for real once the shell has it:
#  - fed to a known interpreter (is_interpreter_line) — KEPT verbatim,
#    quoted or not: the body isn't prose, it's a script that genuinely
#    executes ("bash <<'EOF' ... echo x >> journal ... EOF" really appends,
#    even quoted — quoting the delimiter only ever controls the OUTER
#    shell's own expansion, never what a nested interpreter does once it
#    reads that text as ITS OWN stdin script);
#  - QUOTED delimiter (<<'WORD' / <<"WORD"), not an interpreter — STRIPPED
#    entirely: quoting any character of the delimiter disables ALL
#    expansion in the body (POSIX), so it cannot smuggle a live
#    $(...)/`...`, and a bare ">>"-looking word in body TEXT is never
#    itself a live redirect (heredoc bodies are data, not re-parsed for
#    shell syntax by the outer shell) — so there is nothing in a quoted,
#    non-executed body that can ever actually write anywhere;
#  - UNQUOTED delimiter (<<WORD), not an interpreter — v3.8 review fix
#    round 2 (§1): the WHOLE body (from right after the introducer to its
#    own terminator) is buffered FIRST, then decided ONCE, as a whole —
#    deliberately NOT a per-line "does this one line contain $(...)"
#    check (that was this section's own first cut, and it had a real gap:
#    a live substitution can OPEN on one physical line and CLOSE on a
#    later one — "$(echo x\necho y)" is completely ordinary bash — and a
#    per-line, no-memory-between-lines scan never sees the closing paren,
#    so it silently drops the whole thing instead of catching it). If the
#    buffered body contains "$(" or a backtick ANYWHERE, the outer shell
#    WILL expand something in it for real regardless of line boundaries —
#    kept verbatim, fed to the scan below exactly like an interpreter's
#    body. If it contains neither, nothing in it can ever expand to
#    anything — discarded entirely, same as the quoted case.
#
# Recognizes the plan's introducer shapes with a delimiter word
# ([A-Za-z_][A-Za-z0-9_]*) — every heredoc this project's own
# scripts/tests use (EOF, JSON, ...). A herestring (<<<) is NOT a
# heredoc — any line containing the literal substring "<<<" is skipped
# for introducer detection entirely (bash's regex has no lookbehind to
# tell "<<" apart from the last two characters of "<<<" more surgically
# than that; skipping the whole line is the safe direction to err in — at
# worst it under-strips that one line, it never over-blocks). Only the
# FIRST introducer on a given line is recognized — two heredocs opened on
# one source line is not a shape this project's own commands ever produce.
strip_heredocs() {
  local cmd="$1" line instate=0 term="" striptabs=0 chk
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$instate" = 1 ]; then
      chk="$line"
      if [ "$striptabs" = 1 ]; then
        while [ "${chk#$'\t'}" != "$chk" ]; do chk="${chk#$'\t'}"; done
      fi
      [ "$chk" = "$term" ] && instate=0
      continue
    fi
    printf '%s\n' "$line"
    case "$line" in
      *'<<<'*) ;;
      *'<<'*)
        if is_interpreter_line "$line"; then
          :   # kept verbatim -- see this function's own header
        elif [[ "$line" =~ \<\<(-)?[[:space:]]*\'([A-Za-z_][A-Za-z0-9_]*)\' ]] \
          || [[ "$line" =~ \<\<(-)?[[:space:]]*\"([A-Za-z_][A-Za-z0-9_]*)\" ]]; then
          term="${BASH_REMATCH[2]}"
          striptabs=0; [ "${BASH_REMATCH[1]:-}" = "-" ] && striptabs=1
          instate=1   # quoted -> plain swallow-and-discard below
        elif [[ "$line" =~ \<\<(-)?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*) ]]; then
          # unquoted, not an interpreter -- buffer the whole body here,
          # inline, using the SAME input stream the outer loop is already
          # reading (a nested `read` from a redirected here-string
          # continues from exactly where the outer one left off — this is
          # what lets the outer loop resume correctly right after the
          # terminator once this inner loop returns).
          local ut_term="${BASH_REMATCH[2]}" ut_striptabs=0 ut_line ut_chk ut_body="" ut_done=0
          [ "${BASH_REMATCH[1]:-}" = "-" ] && ut_striptabs=1
          while [ "$ut_done" != 1 ] && { IFS= read -r ut_line || [ -n "$ut_line" ]; }; do
            ut_chk="$ut_line"
            if [ "$ut_striptabs" = 1 ]; then
              while [ "${ut_chk#$'\t'}" != "$ut_chk" ]; do ut_chk="${ut_chk#$'\t'}"; done
            fi
            if [ "$ut_chk" = "$ut_term" ]; then
              ut_done=1
            else
              ut_body="$ut_body$ut_line"$'\n'
            fi
          done
          case "$ut_body" in
            *'$('*|*'`'*) printf '%s' "$ut_body" ;;   # a live substitution somewhere in the body -> keep it whole
            *) : ;;                                    # neither anywhere -> discard entirely
          esac
        fi
        ;;
    esac
  done <<<"$cmd"
}

# scan_segment() — $1 = one statement segment (see bash_write_target_hit).
# Checks every recognized write shape (§2 of the plan) for a target that
# resolves to the journal (journal_target). On a hit, sets WG_HIT (human-
# readable "target (via shape)") and WG_HIT_WS, returns 0.
#
# An operator may be its own whitespace-separated word ("echo x >> FILE")
# OR glued straight onto its target with no space ("echo x >>FILE" — v3.8
# review fix §3: >>, >, >|, 1>, 2>, &> are all matched as a PREFIX of the
# word, and whatever follows in that same word is tried as the target
# first, falling back to the next word when nothing follows). An operator
# glued onto the PRECEDING word too ("echo 'x'>>FILE", no space on either
# side — v3.9 fix: confirmed by an actual write, `( echo 'DECIDED:
# sneaky'>>~/bro/proj1/2026-09-22.md )`) is now recognized the same way,
# from the other side: whatever follows the LAST operator occurrence
# inside a word that does NOT start with one is tried as the target first,
# falling back to the next word when nothing follows — same precedence,
# same operator set, same fallback shape as the prefix case just above,
# only entered when the prefix case found nothing (so a word is never
# double-reported). journal_target()'s own precision (only an exact
# "<workspace>/YYYY-MM-DD.md" shape counts) is what keeps this from
# false-blocking ordinary text that merely CONTAINS a ">" character, e.g.
# awk's "$1>5" or a git --format string with a literal ">" in it.
#
# "cp"/"install"/"ln"/"truncate"/"sed -i"/"perl -i"'s target is taken as
# the LAST word of the segment — correct for the common invocation shapes
# this project and the plan's own examples use; a destination expressed
# via a FLAG placed after it (unusual, but some cp implementations permute
# flags) is not this scan's job to chase. "mv" (v3.8 review fix §5) checks
# EVERY non-flag word, like rm/unlink below — moving the journal away
# (`mv journal other-name`) removes it from its own path just as surely as
# rm does, so the journal-as-SOURCE case has to be caught too, not just
# journal-as-destination. cp is deliberately NOT in this any-word group:
# copying FROM the journal only reads it.
scan_segment() {
  local seg="$1"
  local words_ss
  IFS=$' \t' read -ra words_ss <<<"$seg"
  local n=${#words_ss[@]} i w op rest target
  for ((i=0; i<n; i++)); do
    w="${words_ss[i]}"
    op=""; rest=""
    case "$w" in
      '1>>'*) op='1>>'; rest="${w#1>>}" ;;
      '2>>'*) op='2>>'; rest="${w#2>>}" ;;
      '>>'*)  op='>>';  rest="${w#>>}" ;;
      '>|'*)  op='>|';  rest="${w#>|}" ;;
      '&>'*)  op='&>';  rest="${w#&>}" ;;
      '1>'*)  op='1>';  rest="${w#1>}" ;;
      '2>'*)  op='2>';  rest="${w#2>}" ;;
      '>'*)   op='>';   rest="${w#>}" ;;
    esac
    if [ -n "$op" ]; then
      if [ -n "$rest" ]; then target="$rest"; else target="${words_ss[i+1]:-}"; fi
      if journal_target "$target"; then WG_HIT="$target (via $op)"; return 0; fi
    fi
    # v3.9 fix: the SAME operator glued onto the TAIL of the PRECEDING text
    # instead of the front of the target — "echo 'x'>>FILE" tokenizes
    # (whitespace-only splitting, no real shell parsing) into one word
    # "x'>>FILE" that starts with neither a quote nor the operator, so the
    # prefix-only case above never looks at it at all. Only tried when the
    # prefix case just above found nothing in this word (never re-checks a
    # word already handled), and only the LAST operator occurrence in the
    # word is used, same precedence order (longest/most specific first) —
    # whatever follows it is the target, falling back to the next word when
    # nothing follows, exactly like the prefix case.
    if [ -z "$op" ]; then
      case "$w" in
        *'1>>'*) op='1>>'; rest="${w##*1>>}" ;;
        *'2>>'*) op='2>>'; rest="${w##*2>>}" ;;
        *'>>'*)  op='>>';  rest="${w##*>>}" ;;
        *'>|'*)  op='>|';  rest="${w##*>|}" ;;
        *'&>'*)  op='&>';  rest="${w##*&>}" ;;
        *'1>'*)  op='1>';  rest="${w##*1>}" ;;
        *'2>'*)  op='2>';  rest="${w##*2>}" ;;
        *'>'*)   op='>';   rest="${w##*>}" ;;
      esac
      if [ -n "$op" ]; then
        if [ -n "$rest" ]; then target="$rest"; else target="${words_ss[i+1]:-}"; fi
        if journal_target "$target"; then WG_HIT="$target (via $op, glued to preceding text)"; return 0; fi
      fi
    fi
    if [ "$w" = "tee" ]; then
      local nxt="${words_ss[i+1]:-}" tgt
      if [ "$nxt" = "-a" ]; then tgt="${words_ss[i+2]:-}"; else tgt="$nxt"; fi
      if journal_target "$tgt"; then WG_HIT="$tgt (via tee)"; return 0; fi
    fi
    case "$w" in
      of=*)
        if journal_target "${w#of=}"; then WG_HIT="${w#of=} (via dd of=)"; return 0; fi
        ;;
    esac
    if [ "$w" = "rm" ] || [ "$w" = "unlink" ] || [ "$w" = "mv" ]; then
      local j cand
      for ((j=i+1; j<n; j++)); do
        cand="${words_ss[j]}"
        case "$cand" in -*) continue ;; esac
        if journal_target "$cand"; then WG_HIT="$cand (via $w)"; return 0; fi
      done
    fi
  done
  local has_sed=0 has_perl=0 has_i=0 has_cpinstln=0 has_trunc=0
  for w in "${words_ss[@]}"; do
    case "$w" in
      sed) has_sed=1 ;;
      perl) has_perl=1 ;;
      -i|-i.*|--in-place|--in-place=*) has_i=1 ;;
      cp|install|ln) has_cpinstln=1 ;;
      truncate) has_trunc=1 ;;
    esac
  done
  if [ "$n" -gt 0 ]; then
    local lastw="${words_ss[n-1]}"
    if { [ "$has_sed" = 1 ] || [ "$has_perl" = 1 ]; } && [ "$has_i" = 1 ]; then
      if journal_target "$lastw"; then WG_HIT="$lastw (via sed/perl -i)"; return 0; fi
    fi
    if [ "$has_cpinstln" = 1 ] || [ "$has_trunc" = 1 ]; then
      if journal_target "$lastw"; then WG_HIT="$lastw (via cp/install/ln/truncate)"; return 0; fi
    fi
  fi
  return 1
}

# bash_write_target_hit() — $1 = heredoc-stripped command text. Walks it
# line by line; each line is cleaned of fd-duplication (2>&1) and
# /dev/null redirects (both common in harmless commands and would
# otherwise confuse the operator scan), then split into statement
# segments on ; && || & | so an unrelated LATER clause's own "last word"
# (a cp/sed -i/etc target) is never misattributed to an EARLIER command in
# the same line, or vice versa — e.g. "cp x other.md && cat journal.md"
# must not block on "journal.md" merely being the last word of the whole
# line, when cp's own destination is "other.md". >| and &> are protected
# (swapped for placeholders) around the split and restored after — their
# own '|' and '&' characters would otherwise be read as a pipe/background
# separator and cut the operator in half.
#
# WG_CWD (v3.8 review fix §4) is a RUNNING variable, not local to one
# call: it starts at the hook's own cwd (set by the caller before this
# function runs) and maybe_update_cwd advances it on every "cd DIR"
# segment, in the same left-to-right order a real shell would apply them —
# so a relative target later in the SAME command resolves against
# whatever directory the command itself just cd'd into.
bash_write_target_hit() {
  local text="$1" line cleaned segtext seg
  while IFS= read -r line || [ -n "$line" ]; do
    cleaned=$(printf '%s' "$line" | sed -E 's/[0-9]>&[0-9]//g; s/>[[:space:]]*\/dev\/null//g')
    segtext=$(printf '%s\n' "$cleaned" \
      | sed -E 's/>\|/\x01/g; s/&>/\x02/g' \
      | sed -E 's/(\|\||&&|[;&|])/\n/g' \
      | sed -E 's/\x01/>|/g; s/\x02/\&>/g')
    while IFS= read -r seg || [ -n "$seg" ]; do
      [ -n "$seg" ] || continue
      maybe_update_cwd "$seg"
      if scan_segment "$seg"; then return 0; fi
    done <<<"$segtext"
  done <<<"$text"
  return 1
}

# pynode_hit() — $1 = heredoc-stripped command text. A python/node
# one-liner writes files through a LANGUAGE-level API (open(...,'w'|'a'),
# writeFile, appendFile/appendFileSync), not a shell redirect — invisible
# to bash_write_target_hit above by construction. Kept coarse on purpose:
# journal path anywhere in the text AND an explicit write-call shape
# anywhere in the text — unlike the precise per-target scan above, this
# does not try to associate the write call with a specific argument (that
# would mean parsing Python/JS, out of scope for a shell heuristic).
# Two separate checks ANDed together (a date-shaped .md filename anywhere,
# one of ROOT_PREFIXES anywhere) rather than one combined regex with $ROOT
# spliced in — $ROOT comes from bro-config.json and splicing it unescaped
# into an ERE would misparse on a path containing a regex metacharacter;
# grep -F (fixed-string) sidesteps that entirely, same reason the
# Write/Edit branch above never regex-matches $ROOT either.
#
# v3.9 fix: the ROOT_PREFIXES scan above only sees a path that spells the
# store root out — open('2026-09-22.md','a'), a BARE relative filename
# with the working directory already inside the workspace (cwd=~/bro/
# proj1, say), never mentions $ROOT/~/bro/$HOME anywhere in the text, so
# it was invisible. A python/node one-liner has no cwd of its own — it
# inherits the SAME working directory this hook already tracks as WG_CWD
# (advanced past any `cd`/`pushd` earlier in this same command by
# bash_write_target_hit, which always runs before this function) — so this
# reuses journal_target()'s own relative-path resolution against WG_CWD,
# exactly like a bare relative shell redirect already gets. The quoted
# argument carrying the date pattern is extracted whole and handed to
# journal_target() as-is; it strips the quotes itself, same as every other
# caller.
pynode_hit() {
  local text="$1" pfx fname
  printf '%s' "$text" | grep -qE "open\([^)]*['\"](w|a)['\"]|writeFile|appendFile" || return 1
  printf '%s' "$text" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}\.md' || return 1
  for pfx in "${ROOT_PREFIXES[@]}"; do
    printf '%s' "$text" | grep -qF "$pfx" && return 0
  done
  fname=$(printf '%s' "$text" | grep -oE "['\"][^'\"]*[0-9]{4}-[0-9]{2}-[0-9]{2}\.md['\"]" | head -1)
  [ -n "$fname" ] && journal_target "$fname" && return 0
  return 1
}

if [ "$TOOL" = "Bash" ]; then
  [ -z "$CMD" ] && exit 0

  # ROOT_PREFIXES (v3.8 review fix §2) — every literal-text spelling of
  # "the store root" a command might actually type: the absolute path
  # itself, the ~/<rel> shorthand, and (new) the unexpanded literal text
  # "$HOME/<rel>" / "${HOME}/<rel>" — bro's own scripts use $HOME, not ~,
  # throughout, so a chat quoting one of ITS OWN worked examples is just as
  # likely to type the $HOME form. All of journal_target, pynode_hit and
  # the fast path below check against this one list instead of repeating
  # the ROOT/~-shorthand pair by hand.
  ROOT_PREFIXES=("$ROOT")
  case "$ROOT" in
    "$HOME"/*)
      ROOT_PREFIXES+=("~${ROOT#"$HOME"}")
      ROOT_PREFIXES+=("\$HOME${ROOT#"$HOME"}")
      ROOT_PREFIXES+=("\${HOME}${ROOT#"$HOME"}")
      ;;
  esac

  # fast path: skip every heavier scan below UNLESS the command names the
  # store root, OR (v3.8 review fix §4) the hook's own cwd already sits
  # inside it, OR (v3.8 review fix round 2 §2) the command contains a
  # `cd`/`pushd` at all — a relative target ("echo x >> 2026-09-21.md")
  # never mentions the root anywhere in the command text, yet is exactly
  # as real a write as a fully-qualified path once cwd is already inside
  # the workspace (Bash in Claude Code persists cwd across calls); and a
  # `cd`/`pushd` ANYWHERE in the command could change cwd to something
  # inside root, or to the UNKNOWN state (a variable, or "cd -") that
  # journal_target's own review-round-2 branch has to see to catch a
  # journal-shaped relative name — this fast path cannot tell in advance
  # which, so it has to let every `cd`/`pushd` command through to the real
  # scan rather than guess. Cheap and deliberately broad (whole-word
  # match, not "would this cd actually land somewhere relevant") — the
  # overwhelming common case (most Bash calls have nothing to do with bro,
  # from a cwd nowhere near it, and never cd at all) still never pays for
  # heredoc-stripping or tokenizing. Text side checked on the RAW command
  # (before heredoc-stripping) — deliberately: a false hit that only lived
  # inside a body about to be stripped just means the slower path runs
  # once for nothing, never a false block (the precise scan below is what
  # decides that), so checking raw text here is a pure optimization, not a
  # precision trade-off.
  CWD_IN_ROOT=0
  case "$CWD" in "$ROOT"|"$ROOT"/*) CWD_IN_ROOT=1 ;; esac
  if [ "$CWD_IN_ROOT" != 1 ]; then
    MENTIONS_ROOT=0
    for RPFX in "${ROOT_PREFIXES[@]}"; do
      case "$CMD" in *"$RPFX"*) MENTIONS_ROOT=1; break ;; esac
    done
    if [ "$MENTIONS_ROOT" != 1 ]; then
      printf '%s' "$CMD" | grep -qE '(^|[^A-Za-z0-9_])(cd|pushd)([^A-Za-z0-9_]|$)' || exit 0
    fi
  fi

  STRIPPED=$(strip_heredocs "$CMD")

  WG_HIT=""; WG_HIT_WS=""; WG_HIT_UNKNOWN_CWD=0; WG_CWD="$CWD"
  if bash_write_target_hit "$STRIPPED"; then
    if [ "$WG_HIT_UNKNOWN_CWD" = 1 ]; then
      deny "bro v3.8: this Bash command's working directory becomes unresolvable partway through (a \`cd\` with a variable, or \`cd -\`) — $WG_HIT is a relative target whose name is already journal-shaped, and with the working directory unknown this can't be ruled out. $(APPEND_HELP "")"
    else
      deny "bro v3.8: this Bash command's write target resolves to the shared daily journal — $WG_HIT, workspace '$WG_HIT_WS'. $(APPEND_HELP "$WG_HIT_WS")"
    fi
  fi
  if pynode_hit "$STRIPPED"; then
    deny "bro v3.8: this Bash command looks like a python/node one-liner writing directly into a shared daily journal (a journal path under $ROOT, or a bare relative journal-shaped filename while the working directory is already inside it, together with an open(...,'w'|'a')/writeFile/appendFile call). $(APPEND_HELP "")"
  fi

  exit 0
fi

exit 0
