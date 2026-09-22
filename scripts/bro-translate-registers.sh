#!/bin/bash
# bro v3.9 — bro-translate-registers.sh: one-time translator for EXISTING
# registers (§4 of the v3.9 plan). bro-harvest.sh (this same v3.9) already
# writes every NEW register line in English; this script is the other
# half — it walks a store built by an OLDER bro and rewrites the
# structural (service) words already on disk to match, so an English-
# speaking operator (or anyone reading the store after upgrading) never
# hits a leftover Russian header or attribution. It is not part of the
# normal read/write path and nothing else in this project calls it
# automatically — an operator runs it themselves, once, when they choose
# to translate their store (the v3.9 plan's own "what's out of scope"
# section: the operator's real store is only ever touched after an
# explicit --dry-run and a separate go-ahead, both outside this script).
#
# Usage:
#   bro-translate-registers.sh [--root DIR] (--workspace WS | --all) [--dry-run]
#
# What it touches, and how it decides a file is one of its targets:
#   - per workspace: <root>/<ws>/decisions.md, open.md, vocab.md, insights.md
#   - once per run, only under --all (see below): <root>/_rule-candidates.md,
#     <root>/_state.md
#   Nothing else, ever — matched by exact basename, never by content. A
#   workspace directory routinely holds other files that happen to CONTAIN
#   the same Russian substrings this script looks for (a dated journal
#   recording that something "— закрыт …", or a hand-written _workspace.md
#   quoting an old register line, or an unrelated *.md doc) — these are
#   real, confirmed shapes in this project's own store, not hypothetical,
#   and none of them is one of the six names above, so none of them is
#   ever opened by this script. Journals (YYYY-MM-DD*.md), _principles.md
#   (the operator's own text), _workspace.md, INDEX.md (bro-harvest.sh's
#   own regenerated view) and anything already under _archive/ are
#   structurally impossible to select, not just excluded by a rule that
#   could later be forgotten.
#
# --workspace WS translates only that workspace's four files. --all also
# translates the two root files, once, after every workspace — they are
# not owned by any single workspace (_rule-candidates.md interleaves every
# workspace's rule candidates in one file; _state.md is a single
# whole-store snapshot), so a single --workspace run leaves them alone
# rather than silently rewriting shared state on behalf of one project.
# Translate everything in one store with --all.
#
# What "translate" means, exactly. Entry text — the operator's own words —
# is never touched: every substitution below is anchored to a STRUCTURAL
# position (the start of a line, or the LAST match on a line), never a bare
# "wherever this substring occurs" scan — a real review round on this exact
# script found that a bare scan corrupts an entry that itself QUOTES the old
# format as an example ("…the old signature read «— родилось: 2026-01-01 ·
# «example»»…" — a real illustrative insight, not hypothetical) and, in
# _state.md, corrupts a SIDE line that happens to use the words "записано"/
# "проект" in an unrelated sentence (an operator's own state note, e.g. "то,
# что сегодня записано: в реестрах…", is not the structural recorded: line
# and must never be touched by this script):
#   - the register's own header block — from the "# …" title line through
#     the first blank line that follows its "> …" description lines — is
#     replaced WHOLESALE by the English block bro-harvest.sh's own
#     ensure_register() writes for a brand-new register of the same kind.
#     tests/parts/d-translate.sh checks this the way the v3.9 plan asks:
#     byte-for-byte against a register bro-harvest.sh itself just created
#     from nothing, not against a copy of this file's own idea of the text.
#   - decisions.md: "— родилось: " only on a line that STARTS with it (its
#     own dedicated attribution line, never the preceding body line, even
#     when that body line itself quotes "— родилось: " as running prose)
#     -> "— from: "
#   - open.md/vocab.md/insights.md/_rule-candidates.md: "— родился: " only
#     the LAST such match on its line (that inline attribution is always
#     the last thing bro-harvest.sh appends to the line; an earlier match
#     on the same line can only be the entry's own quoted example) ->
#     "— from: ". Same rule, same reasoning, for "— закрыт YYYY-MM-DD: "
#     (open.md) -> "— closed YYYY-MM-DD: " and, _rule-candidates.md only,
#     "— принят " -> "— accepted " / "— отклонён " -> "— rejected " (always
#     a hand-added note strictly after the auto-attribution, so "last
#     match" is always the real one here too).
#   - _rule-candidates.md only, additionally: "[x] принят " ->
#     "[x] accepted " / "[-] отклонён " -> "[-] rejected ", but ONLY when
#     it is the very first thing on the line, right after the checkbox —
#     not the same rule as "— принят "/"— отклонён " above (this is a
#     genuinely different, independent shape). Not hypothetical: a real
#     hand-edited line in this project's own _rule-candidates.md reads
#     "- [x] принят 2026-09-16 (§48) r-b98425 …" — the checkbox token typed
#     straight into the entry instead of the usual trailing "— принят …"
#     note. Neither text contains the other, so both need their own rule,
#     and this one is anchored so it can never fire on a mid-line quote of
#     the same words.
#   - _state.md only, and only on two specific lines, never the sides
#     (which are the operator's own words, line 5 onward): line 1, the
#     title ("# Состояние оператора" -> "# Operator state", trailing
#     whitespace on that line tolerated either way — see process_state()),
#     and line 4, the one service line "записано: … · проект … · «…»"
#     that always sits right after the two "<!-- … -->" comment lines ->
#     "recorded: " / " · project "
#
# Guarantees:
#   - idempotent: a file with nothing left to translate is left completely
#     alone — not opened for writing, not backed up. A second run over an
#     already-translated store changes zero bytes anywhere.
#   - every file this script is about to change is copied first,
#     unmodified, to <root>/_archive/pre-english-<YYYYMMDD-HHMMSS>/<path
#     relative to root> — one timestamp for the whole run, so one
#     invocation's backups land together.
#   - every file is only ever read or written while its own lock() (bro-
#     lib.sh — the same lock bro-harvest.sh/bro-append.sh take, on the
#     exact same path) is held, so a chat harvesting the same store at the
#     same moment cannot interleave with this script. A lock that is
#     genuinely busy for the whole spin is left untouched — this script
#     skips that one file (counted and reported at the end) and moves on;
#     it does not corrupt the file and does not abort the run.
#   - --dry-run opens nothing for writing and creates no backup — it only
#     counts, per file, what each of the replacements above would do
#     there, and prints the counts.
#
# bash 3.2 + BSD/GNU userland, same target as the rest of this project (see
# bro-lib.sh's own header). No tolower()/toupper() on Cyrillic anywhere
# here — every Russian string below is a fixed, fully-spelled-out literal,
# matched and replaced as bytes, never as a case-folded pattern.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -z "$LIB_DIR" ] || [ ! -f "$LIB_DIR/bro-lib.sh" ]; then
  echo "[bro-translate-registers] bro-lib.sh not found next to $0 — reinstall (bro-install.sh) or check the repo layout" >&2
  exit 1
fi
. "$LIB_DIR/bro-lib.sh"

say() { echo "[bro-translate-registers] $*"; }
err() { echo "[bro-translate-registers] $*" >&2; exit 1; }

CONFIG="$HOME/.claude/bro-config.json"
if command -v jq >/dev/null 2>&1; then
  ROOT=$(jq -r '.root // "~/bro"' "$CONFIG" 2>/dev/null || echo "~/bro")
else
  ROOT="~/bro"
fi
ROOT="${ROOT/#\~/$HOME}"

ONLY_WS=""; ALL=0; DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || err "--root needs a value. Usage: bro-translate-registers.sh [--root DIR] (--workspace WS | --all) [--dry-run]"
      ROOT="$2"; ROOT="${ROOT/#\~/$HOME}"; shift ;;
    --workspace)
      [ $# -ge 2 ] || err "--workspace needs a value. Usage: bro-translate-registers.sh [--root DIR] (--workspace WS | --all) [--dry-run]"
      ONLY_WS="$2"; shift ;;
    --all) ALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) err "unknown argument '$1'. Usage: bro-translate-registers.sh [--root DIR] (--workspace WS | --all) [--dry-run]" ;;
  esac
  shift
done

[ -n "$ONLY_WS" ] && [ "$ALL" = 1 ] && err "pass either --workspace WS or --all, not both"
[ -n "$ONLY_WS" ] || [ "$ALL" = 1 ] || err "pass either --workspace WS or --all. Usage: bro-translate-registers.sh [--root DIR] (--workspace WS | --all) [--dry-run]"
[ -d "$ROOT" ] || err "store root '$ROOT' does not exist"
if [ -n "$ONLY_WS" ]; then
  case "$ONLY_WS" in
    _archive|_principles-sources) err "'$ONLY_WS' is not a workspace" ;;
  esac
  [ -d "$ROOT/$ONLY_WS" ] || err "workspace '$ONLY_WS' does not exist under $ROOT"
fi

if [ "$DRY_RUN" = 1 ]; then TAG="DRY"; else TAG="OK "; fi
TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE_BASE="$ROOT/_archive/pre-english-$TS"

# One scratch dir for the whole run, INSIDE $ROOT (same filesystem as every
# target file, so the final mv onto a locked register is a true rename, not
# a cross-device copy) and dot-prefixed, so --all's own "$ROOT"/*/ glob
# below never mistakes it for a workspace — same trick bro-harvest.sh's own
# .harvest-run.* scratch dirs already rely on.
SCRATCH=$(mktemp -d "$ROOT/.translate-run.XXXXXX" 2>/dev/null) || err "could not create a scratch dir under $ROOT"
CURRENT_LOCK=""
cleanup_on_exit() {
  [ -n "$CURRENT_LOCK" ] && unlock "$CURRENT_LOCK" 2>/dev/null
  rm -rf "$SCRATCH" 2>/dev/null
}
trap cleanup_on_exit EXIT

N_TRANSLATED=0
N_CLEAN=0
N_SKIPPED=0
N_REPLACEMENTS=0

# ---- canonical EN header text — copied verbatim from bro-harvest.sh's own
# ensure_register() and its five call sites (v3.9 §4 requires this
# byte-for-byte; tests/parts/d-translate.sh checks it against a register
# bro-harvest.sh itself just created). Not retyped from the plan's own
# prose copy — this file and bro-harvest.sh are the only two places this
# sentence is allowed to live, so the next edit to either one is the only
# thing that can ever drift them apart.
FILLED_LINE="Filled automatically from the daily journals (bro-harvest.sh); statuses are edited by hand. Never delete entries — supersede them."

canonical_header() { # $1=title $2=description -> the exact bytes ensure_register() writes, on stdout
  printf '# %s\n\n> %s\n> %s\n\n' "$1" "$2" "$FILLED_LINE"
}

# ---- the structural search patterns (extended regex) — each one named
# once and reused for BOTH counting (count_lines, for --dry-run and for the
# summary every real run also prints) and replacing (body_subs/
# process_state), so the two can never silently drift apart. Patterns
# marked "base" below are the literal text alone, used as-is for counting
# ("does this line contain it at all") and wrapped with a greedy "^(.*)"
# capture at its body_subs()/process_state() use site to target only the
# LAST match on the line for replacement — see the top-of-file comment for
# why "last match on the line" is always the real, structural one and
# never an entry's own quoted example. Patterns already anchored (^...) are
# used identically, unwrapped, in both places — anchoring already pins them
# to one specific spot, so there is no "last occurrence" ambiguity to
# resolve for those.
P_FROM_DECISIONS='^— родилось: '                                # anchored: decisions.md's own attribution line only
P_FROM='— родился: '                                             # base: open.md/vocab.md/insights.md/_rule-candidates.md's inline attribution
P_CLOSED='— закрыт ([0-9]{4}-[0-9]{2}-[0-9]{2}): '               # base (open.md)
P_ACCEPTED='— принят '                                           # base (_rule-candidates.md)
P_REJECTED='— отклонён '                                         # base (_rule-candidates.md)
P_XACCEPTED='^- \[x\] принят '                                   # anchored (_rule-candidates.md hand-edited shape)
P_DASHREJECTED='^- \[-\] отклонён '                              # anchored (_rule-candidates.md hand-edited shape)
P_STATE_TITLE_RU='^# Состояние оператора[[:space:]]*$'          # anchored, line 1 only, trailing whitespace tolerated
P_STATE_TITLE_EN='^# Operator state[[:space:]]*$'                # anchored, line 1 only — "already translated", not a NOTE-worthy miss
P_RECORDED='^записано: '                                         # anchored, restricted to line 4 at its use site (4s/…)
P_PROJECT=' · проект '                                           # base, restricted to line 4 at its use site (4s/…) — first match only, protects a quoted section title later on the same line

# ---- the English forms of every "last match" base pattern above, used
# ONLY as a guard, never themselves counted or replaced. A line already
# holding its real, structural EN marker — because a PRIOR run already
# translated it — can still legitimately carry an EARLIER, untouched
# Russian quote of the same words (that quote is never itself translated,
# by design: it is the entry's own illustrative text, not the structural
# marker). Without this guard, a second run's greedy "last match" would
# have nothing left to land on except that quote, and would corrupt it —
# a real idempotency break this file's own regression test caught before
# this shipped. Every place a base pattern above is used for a "last
# match" replacement or its matching count is gated "found the Russian
# form, and NOT already this English one" — see count_lines_needing() and
# body_subs()/process_state()'s own sed "/EN/!s/…/…/" guards below.
P_FROM_EN='— from: '
P_CLOSED_EN='— closed [0-9]{4}-[0-9]{2}-[0-9]{2}: '
P_ACCEPTED_EN='— accepted '
P_REJECTED_EN='— rejected '
P_PROJECT_EN=' · project '

# header_end_line FILE -> the 1-based line number of the LAST line of
# FILE's header block: the "# title" line, through the first blank line
# that follows its "> …" description lines (mirrors ensure_register()'s
# own shape; §4 of the plan: "from the '# …' line to the first blank line
# after the '> …' lines"). Prints 0 if line 1 is not itself a "# " title —
# callers then leave the header alone rather than guess at one.
header_end_line() {
  local f="$1" n=0 saw_quote=0 last=0 first=1 line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    if [ "$first" = 1 ]; then
      first=0
      case "$line" in
        "# "*) last=$n; continue ;;
        *) echo 0; return ;;
      esac
    fi
    case "$line" in
      "> "*) saw_quote=1; last=$n ;;
      "")
        last=$n
        [ "$saw_quote" = 1 ] && { echo "$last"; return; }
        ;;
      *) echo "$last"; return ;;
    esac
  done < "$f"
  echo "$last"
}

# count_lines FILE PATTERN(extended regex) -> number of LINES matching, on
# stdout. For an ANCHORED pattern (decisions.md's own attribution, the
# bracket hand-edit forms, _state.md's "записано: ") this alone is exactly
# "how many replacements body_subs()/process_state() will make" — anchoring
# pins the match to one spot, so a translated line can never match again on
# a later run (see count_lines_needing() just below for the OTHER kind of
# pattern, where that is not true).
count_lines() {
  local n
  n=$(grep -c -E -- "$2" "$1" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# count_lines_needing FILE RU_PATTERN EN_PATTERN -> number of lines matching
# RU_PATTERN but NOT ALSO already matching EN_PATTERN, on stdout. This is
# the counting half of body_subs()'s "/EN/!s/RU/…/" guard just below —
# needed for every "last match on the line" pattern (— родился:/— from:,
# — закрыт:/— closed:, — принят /— accepted , — отклонён /— rejected ):
# once a line's real structural marker has been translated by an earlier
# run, an untouched Russian QUOTE of the same words can still legitimately
# remain on that same line (the entry's own illustrative text, left alone
# on purpose) — a plain "does RU_PATTERN match" count would wrongly count
# that line as still needing work, and a plain last-match REPLACE would
# then have nothing left to land on except that quote and corrupt it. Both
# halves check the same thing the same way so the printed count and the
# actual write can never disagree.
count_lines_needing() {
  local n
  n=$(grep -E -- "$2" "$1" 2>/dev/null | grep -c -v -E -- "$3" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# body_subs KIND < in > out — the structural substitutions, one sed pass,
# built from the SAME P_* base patterns count_lines()/count_lines_needing()
# above count with, so what gets counted and what gets replaced can never
# disagree. KIND:
#   "decisions"  — decisions.md's own-line attribution: only a line that
#                  STARTS with "— родилось: " (^-anchored — see the
#                  top-of-file comment for why this, not "last match",
#                  is the correct rule for this one register). Anchored, so
#                  no "/EN/!" guard needed — see count_lines_needing()'s
#                  own comment for why that guard exists at all.
#   "plain"      — open.md/vocab.md/insights.md: the LAST "— родился: " on
#                  a line, and (open.md) the LAST "— закрыт DATE: " on a
#                  line — via a greedy "^(.*)" capture that can only ever
#                  stop at the final occurrence, POSIX leftmost-longest
#                  matching (confirmed empirically: a line with an earlier
#                  quoted "— родился: …" AND a real trailing one only ever
#                  has the trailing one replaced). Each is gated
#                  "/EN-form/!" first — a line whose real marker a PRIOR
#                  run already translated, but which still carries an
#                  untouched Russian quote of the same words, must not have
#                  THIS run's "last match" land on that quote instead (the
#                  exact idempotency break this file's own regression test
#                  caught before this shipped).
#   "rcand"      — _rule-candidates.md: the same guarded greedy-last-match
#                  rule for "— родился: "/"— принят "/"— отклонён ", PLUS
#                  the two independently-anchored "[x] принят "/
#                  "[-] отклонён " hand-edit forms (start of line only,
#                  never mid-line, so — like decisions.md above — they
#                  need no "/EN/!" guard either).
body_subs() {
  case "$1" in
    decisions)
      sed -E -e "s/${P_FROM_DECISIONS}/— from: /"
      ;;
    rcand)
      sed -E \
        -e "/${P_FROM_EN}/!s/^(.*)${P_FROM}/\\1— from: /" \
        -e "/${P_ACCEPTED_EN}/!s/^(.*)${P_ACCEPTED}/\\1— accepted /" \
        -e "/${P_REJECTED_EN}/!s/^(.*)${P_REJECTED}/\\1— rejected /" \
        -e "s/${P_XACCEPTED}/- [x] accepted /" \
        -e "s/${P_DASHREJECTED}/- [-] rejected /"
      ;;
    *)
      sed -E \
        -e "/${P_FROM_EN}/!s/^(.*)${P_FROM}/\\1— from: /" \
        -e "/${P_CLOSED_EN}/!s/^(.*)${P_CLOSED}/\\1— closed \\2: /"
      ;;
  esac
}

# process_register FILE TITLE DESC KIND — the one blockquote-header shape
# ensure_register() writes, shared by decisions.md/open.md/vocab.md/
# insights.md/_rule-candidates.md. KIND is "decisions", "plain" or "rcand"
# (body_subs above). A file that does not exist at all is silently skipped
# (nothing to report — creating a register from nothing is bro-harvest.sh's
# job, not this script's); an EMPTY file that DOES exist (ensure_register()
# ran, nothing harvested into it yet) still gets one reported line, so a
# --dry-run/run's output accounts for every file it looked at, not just the
# ones with something to do.
process_register() {
  local f="$1" title="$2" desc="$3" kind="$4"
  local rel hdrN c_hdr c_from c_closed c_acc c_rej c_xacc c_drej total backup_path

  [ -f "$f" ] || return 0
  rel="${f#$ROOT/}"
  if [ ! -s "$f" ]; then
    say "$TAG $rel — empty — skipped"
    N_CLEAN=$((N_CLEAN+1))
    return 0
  fi

  if ! lock "$f"; then
    say "SKIP $rel — lock busy, left untouched"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  CURRENT_LOCK="$f"

  hdrN=$(header_end_line "$f")
  if [ "$hdrN" -gt 0 ] 2>/dev/null; then
    sed -n "1,${hdrN}p" "$f" > "$SCRATCH/old_hdr"
    canonical_header "$title" "$desc" > "$SCRATCH/new_hdr"
    if cmp -s "$SCRATCH/old_hdr" "$SCRATCH/new_hdr"; then c_hdr=0; else c_hdr=1; fi
  else
    hdrN=0
    : > "$SCRATCH/new_hdr"
    c_hdr=0
    say "NOTE $rel — line 1 is not '# title'; header left as-is"
  fi
  # body counted and replaced separately from the header: a register's own
  # DESCRIPTION line legitimately spells out these same Russian words as
  # instructional text (_rule-candidates.md's own header literally reads
  # "...: [x] принят / [-] отклонён.") — counting the whole file would count
  # that occurrence twice, once for c_hdr and again here, though it is the
  # header swap alone that removes it. $SCRATCH/old_body is exactly the
  # bytes body_subs() below will transform, so what's counted here is
  # exactly what gets replaced, one substitution each.
  tail -n "+$((hdrN+1))" "$f" > "$SCRATCH/old_body"

  # decisions.md's attribution is line-anchored (own line, "^— родилось: ")
  # and it never gets a "— closed:" (that is an open.md-only concept) — a
  # plain count_lines() is exact for it (anchored, see that function's own
  # comment). Every other kind's attribution is inline ("— родился: ", last
  # match on the line — see body_subs()'s own comment) and needs
  # count_lines_needing()'s "already-English" guard for the same reason
  # body_subs() itself does.
  if [ "$kind" = "decisions" ]; then
    c_from=$(count_lines "$SCRATCH/old_body" "$P_FROM_DECISIONS")
    c_closed=0
  else
    c_from=$(count_lines_needing "$SCRATCH/old_body" "$P_FROM" "$P_FROM_EN")
    c_closed=$(count_lines_needing "$SCRATCH/old_body" "$P_CLOSED" "$P_CLOSED_EN")
  fi
  c_acc=0; c_rej=0; c_xacc=0; c_drej=0
  if [ "$kind" = "rcand" ]; then
    c_acc=$(count_lines_needing "$SCRATCH/old_body" "$P_ACCEPTED" "$P_ACCEPTED_EN")
    c_rej=$(count_lines_needing "$SCRATCH/old_body" "$P_REJECTED" "$P_REJECTED_EN")
    c_xacc=$(count_lines "$SCRATCH/old_body" "$P_XACCEPTED")
    c_drej=$(count_lines "$SCRATCH/old_body" "$P_DASHREJECTED")
  fi
  total=$((c_hdr + c_from + c_closed + c_acc + c_rej + c_xacc + c_drej))

  if [ "$kind" = "rcand" ]; then
    say "$TAG $rel — header=$c_hdr from=$c_from closed=$c_closed accepted=$c_acc rejected=$c_rej x-accepted=$c_xacc dash-rejected=$c_drej total=$total"
  else
    say "$TAG $rel — header=$c_hdr from=$c_from closed=$c_closed total=$total"
  fi

  if [ "$total" -eq 0 ]; then
    N_CLEAN=$((N_CLEAN+1))
    unlock "$f"; CURRENT_LOCK=""
    return 0
  fi
  N_REPLACEMENTS=$((N_REPLACEMENTS+total))

  if [ "$DRY_RUN" = 1 ]; then
    unlock "$f"; CURRENT_LOCK=""
    return 0
  fi

  backup_path="$ARCHIVE_BASE/$rel"
  mkdir -p "$(dirname "$backup_path")" && cp "$f" "$backup_path" \
    || { unlock "$f"; CURRENT_LOCK=""; err "could not back up $rel before translating it"; }

  { cat "$SCRATCH/new_hdr"; body_subs "$kind" < "$SCRATCH/old_body"; } > "$SCRATCH/new_whole"
  mv "$SCRATCH/new_whole" "$f" || { unlock "$f"; CURRENT_LOCK=""; err "could not write translated $rel"; }
  N_TRANSLATED=$((N_TRANSLATED+1))
  say "    $rel — backed up to _archive/pre-english-$TS/$rel, translated"
  unlock "$f"; CURRENT_LOCK=""
}

# process_state FILE — _state.md's own shape (an HTML-comment timestamp
# block, not ensure_register()'s blockquote header). Exactly two lines are
# ever touched: line 1 (the title) and line 4 (the one service line,
# "записано: … · проект … · «…»", which write_state_snapshot() — bro-
# harvest.sh — always places right after the two "<!-- … -->" comment
# lines). Line 5 onward is the operator's own state, one side per line
# ("- …") — never scanned by any pattern here, so a side that happens to
# use the plain Russian words "записано" or "проект" in an unrelated
# sentence (real example this fixes: "то, что сегодня записано: в
# реестрах…") is never mistaken for the structural line.
process_state() {
  local f="$1" rel c_hdr c_rec c_proj total backup_path title_line line4

  [ -f "$f" ] || return 0
  rel="${f#$ROOT/}"
  if [ ! -s "$f" ]; then
    say "$TAG $rel — empty — skipped"
    N_CLEAN=$((N_CLEAN+1))
    return 0
  fi

  if ! lock "$f"; then
    say "SKIP $rel — lock busy, left untouched"
    N_SKIPPED=$((N_SKIPPED+1))
    return 0
  fi
  CURRENT_LOCK="$f"

  # title (line 1): the Russian form (trailing whitespace tolerated — a
  # hand-edit can leave one, and it must not make this script think the
  # title is unrecognized while translating everything else, leaving the
  # file half-Russian) counts as 1 to translate; the English form already
  # counts as 0 with no NOTE (this is the expected, idempotent shape, not
  # a miss); anything else is a genuine miss and gets the same NOTE
  # process_register() prints for its own unrecognized-header case.
  title_line=$(sed -n '1p' "$f")
  if printf '%s\n' "$title_line" | grep -qE -- "$P_STATE_TITLE_RU"; then
    c_hdr=1
  elif printf '%s\n' "$title_line" | grep -qE -- "$P_STATE_TITLE_EN"; then
    c_hdr=0
  else
    c_hdr=0
    say "NOTE $rel — line 1 is not a recognized title; header left as-is"
  fi

  # the service line (line 4): counted and replaced on ITS OWN EXTRACTED
  # TEXT, never against the whole file — the whole-file scan this replaced
  # is exactly what let a side line's unrelated sentence get corrupted.
  # "записано: " is anchored (only ever the line's own first word) so a
  # plain match is exact; " · проект " is not anchored, and — same reason
  # as count_lines_needing() above — must not re-match inside the quoted
  # «…» source on a line a prior run already translated, so it is gated on
  # "found the Russian form, and the English one is not already there too".
  line4=$(sed -n '4p' "$f")
  c_rec=$(printf '%s\n' "$line4" | grep -c -E -- "$P_RECORDED" 2>/dev/null)
  case "$c_rec" in ''|*[!0-9]*) c_rec=0 ;; esac
  if printf '%s\n' "$line4" | grep -qE -- "$P_PROJECT" && ! printf '%s\n' "$line4" | grep -qE -- "$P_PROJECT_EN"; then
    c_proj=1
  else
    c_proj=0
  fi
  total=$((c_hdr + c_rec + c_proj))

  say "$TAG $rel — header=$c_hdr recorded=$c_rec project=$c_proj total=$total"

  if [ "$total" -eq 0 ]; then
    N_CLEAN=$((N_CLEAN+1))
    unlock "$f"; CURRENT_LOCK=""
    return 0
  fi
  N_REPLACEMENTS=$((N_REPLACEMENTS+total))

  if [ "$DRY_RUN" = 1 ]; then
    unlock "$f"; CURRENT_LOCK=""
    return 0
  fi

  backup_path="$ARCHIVE_BASE/$rel"
  mkdir -p "$(dirname "$backup_path")" && cp "$f" "$backup_path" \
    || { unlock "$f"; CURRENT_LOCK=""; err "could not back up $rel before translating it"; }

  # 1s/…/…/ and 4s/…/…/ restrict every substitution to exactly the two
  # lines counted above — sed line addresses, not a bare "s/…/…/g" over the
  # whole pattern space, so a side line is structurally unreachable here.
  sed -E \
    -e "1s/${P_STATE_TITLE_RU}/# Operator state/" \
    -e "4s/${P_RECORDED}/recorded: /" \
    -e "4{/${P_PROJECT_EN}/!s/${P_PROJECT}/ · project /;}" \
    "$f" > "$SCRATCH/state_new"
  mv "$SCRATCH/state_new" "$f" || { unlock "$f"; CURRENT_LOCK=""; err "could not write translated $rel"; }
  N_TRANSLATED=$((N_TRANSLATED+1))
  say "    $rel — backed up to _archive/pre-english-$TS/$rel, translated"
  unlock "$f"; CURRENT_LOCK=""
}

process_workspace() { # $1 = workspace dir name (basename under $ROOT)
  local ws="$1" wdir="$ROOT/$1"
  process_register "$wdir/decisions.md" "$ws — decisions" \
    "Decision register: what was chosen, instead of what, and why. Obsolete entries are marked [superseded by <id>] — never deleted." decisions
  process_register "$wdir/open.md" "$ws — open items" \
    "Open items: promised and not yet done. Close one with a \`CLOSED <id>: <what closed it>\` line in the journal." plain
  process_register "$wdir/vocab.md" "$ws — vocabulary" \
    "Terms and what they mean, in the operator's own words." plain
  process_register "$wdir/insights.md" "$ws — insights" \
    "Patterns, ideas and new approaches worth keeping." plain
}

process_root_files() {
  process_register "$ROOT/_rule-candidates.md" "Rule candidates (global queue)" \
    "Candidates for _principles.md. A rule enters the principles only with the operator's word: [x] accepted / [-] rejected." rcand
  process_state "$ROOT/_state.md"
}

if [ "$ALL" = 1 ]; then
  for D in "$ROOT"/*/; do
    [ -d "$D" ] || continue
    B=$(basename "$D")
    # same reserved-name/lock-dir exclusion bro-harvest.sh's own --all loop
    # uses — a workspace is any OTHER top-level directory under $ROOT.
    case "$B" in _archive|_principles-sources|*.lock) continue ;; esac
    process_workspace "$B"
  done
  process_root_files
else
  process_workspace "$ONLY_WS"
fi

SUFFIX=""
[ "$DRY_RUN" = 1 ] && SUFFIX=" — dry run, nothing written"
say "done: $N_TRANSLATED translated, $N_CLEAN already English, $N_SKIPPED skipped (lock busy), $N_REPLACEMENTS total replacement(s)$SUFFIX"
exit 0
