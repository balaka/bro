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

# epoch_of() — $1 = YYYY-MM-DD  $2 = HH:MM  -> epoch seconds on stdout,
# nothing + exit 1 if unparseable. v3.8, for the STATE snapshot (§5):
# "newest wins" needs one sortable number built from a journal's own
# filename date plus a record's own "## HH:MM · …" header time — two plain
# strings the caller already has, joined back into a timestamp here. Both
# inputs are already local wall-clock (the filename date, and HH:MM from
# bro-append.sh's own `date +%H:%M`), so this deliberately does NOT force
# UTC — same local interpretation as the values were written under.
# BSD `date -j -f` first (macOS, the primary target), GNU `date -d` fallback
# — the exact dual-path already used for a fixed date in
# bro-session-start.sh's rule-review-cadence check (`date -j -f %Y-%m-%d
# "$LASTREV" +%s 2>/dev/null || date -d "$LASTREV" +%s`); this just adds the
# HH:MM half.
# Coordinator fix: BSD `date -j -f` fills any field the format string
# doesn't name (here, seconds) from the CURRENT wall clock, not zero — so
# without an explicit ":SS", this call's result depended on the moment it
# happened to run, not just on $1/$2 (confirmed: three calls a second apart
# returned three different numbers for the identical "2026-09-21 14:32").
# Two STATE snapshots minted in the same minute then raced on which wall-
# clock second harvest happened to run at, not on which was really later.
# The format now names %S and the input always supplies ":00" for it —
# deterministic, and matches how a marker's own time is already recorded
# (bro-append.sh timestamps a section to the minute, not the second).
epoch_of() {
  local d="$1" t="$2" e
  e=$(date -j -f '%Y-%m-%d %H:%M:%S' "$d $t:00" +%s 2>/dev/null) && { echo "$e"; return 0; }
  e=$(date -d "$d $t:00" +%s 2>/dev/null) && { echo "$e"; return 0; }
  return 1
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
#
# v3.8 (§1) — two writings per RU keyword now accepted: ALL CAPS (РЕШЕНИЕ)
# AND Capitalized (Решение) — a real chronicle line ("- Правило: файлы,
# карточки и журнал пишутся так, чтобы читалось через полгода без
# контекста") used the second writing and MRE used to miss it. EN keywords
# stay ALL-CAPS-only, unchanged: Title-case English (State:, Rule:, Term:)
# is common in ordinary technical prose and would false-positive as a
# marker — see bro/plan-v3.8.md §1 for the operator's own reasoning.
# Lowercase RU (решение:) still isn't accepted either writing — ambiguous
# at the start of a prose line, same reasoning as the EN case.
# No tolower()/toupper(): this awk's case folding doesn't touch Cyrillic
# (see this repo's environment note), so both writings are spelled out in
# full rather than derived — same discipline the original RU/EN split
# already required, just extended to a second RU case.
# STATE and INSIGHT (§5, §6) do NOT get the second RU writing, unlike the
# original six — coordinator follow-up after the real-data measurement
# (bro/plan-v3.8.md §1's own audit): "Состояние:"/"Инсайт:" (Capitalized)
# turned out to already be a long-standing informal habit for captioning
# ANY status (test counts, git branch, release state, document sections —
# 8 of 9 real matches), not the operator's own state — accepting the
# Capitalized writing would let an ordinary status caption silently
# overwrite the operator's real state in _state.md. СОСТОЯНИЕ/ИНСАЙТ and
# STATE/INSIGHT (ALL CAPS only, RU or EN) are the only accepted spellings
# for these two; "Состояние"/"Инсайт" are treated exactly like EN
# Title-case — not a marker, and (see NEAR_MRE below) not even counted as
# a near-miss, same reasoning as the EN case just above. The original six
# keywords are unaffected: the same audit found their new (Capitalized)
# catches were real markers (7 of 7), so they keep both writings.
# Whatever spelling matched here still funnels through marker_type() below
# to ONE canonical type — every consumer that behaves differently per
# marker type switches on THAT, never on the raw matched keyword text, so
# this alternation is the only place the spelling list itself lives.
#
# v3.9 (§1 of the v3.9 plan) — English rename: the open-item marker's
# canonical EN spelling is now OPEN (was TAIL); ДЕЛО is its new RU spelling,
# ALL-CAPS only, same discipline as STATE/INSIGHT above (no "Дело" writing —
# see NEAR_MRE's own v3.9 note further below for why it also gets no
# near-miss entries there). TAIL/ХВОСТ/Хвост are UNCHANGED and still
# recognized — an untranslated store must keep working exactly as before —
# so an open item now has FIVE accepted spellings instead of three.
# marker_type() below folds all five to one canonical token, OPEN (was
# TAIL) — every consumer that behaves differently per type switches on
# THAT, so this is the only place any of the five spellings is listed.
# Coordinator fix (post-3.9 review, round 1): the trailing "one word before
# the colon" group exists mainly for CLOSED <id>: — every EN keyword used
# to allow it too, and OPEN is also how an ordinary note starts ("OPEN
# QUESTIONS: …", "OPEN ISSUES: …" — real chronicle prose): each one hashed
# to a fake open item with body "QUESTIONS: …" etc. Round 1 simply dropped
# the word-before-colon group for every EN keyword but CLOSED.
#
# Coordinator fix, round 2: round 1 was too blunt — a real audit of the
# operator's own chronicles found 178 EN markers that DO carry a word
# before the colon and are all genuine: 117× "DECIDED d-0908-26:" and 52×
# "TAIL t-0909-2:" (the record's own id, typed by the chat), 9× a
# parenthetical note — "DECIDED (operator):", "RULE (его):", "REJECTED
# (02:26):", "TAIL (verify):". Checked against all 169 distinct ids in
# those chronicles (every one fits) and against ordinary words that must
# NOT match — "follow-ups", "to-do", "QUESTIONS", "ISSUES", "FACTOR" (none
# do). So EN keywords (CLOSED included now — its id token is exactly this
# same shape) allow exactly ONE optional token, but ONLY two narrow shapes:
#   (a) an id: 1-2 lowercase letters, a dash, then a run of [A-Za-z0-9-]
#       that contains at least one digit (matches an operator-typed number
#       like "d-0908-26" or "t-0909-2") — OR a single lowercase letter, a
#       dash, and exactly six [0-9a-f] characters (bro's own auto-hash ids
#       like "t-abcdef", which may have no digit in it at all, hence the
#       separate shape). No {n} interval expressions — BWK awk doesn't
#       reliably support them — six character classes are spelled out by
#       hand instead.
#   (b) a parenthetical note with no space inside — [(][^ )]*[)] — a colon
#       IS allowed inside it ("(02:26)"): bro-harvest.sh's own HEAD/BODY
#       split (which cuts at the line's first ':') has its own matching
#       fix for this, see that file's header.
# An ordinary word ("QUESTIONS", "follow-ups", "to-do") fits NEITHER shape
# and is correctly rejected. RU keywords (including ЗАКРЫТ/Закрыт and the
# new ДЕЛО) are UNCHANGED from round 1 — any single word before the colon,
# same as always; on five months of real chronicles that never produced a
# false marker ("Решение владельца:", "Правило подтверждено:" are both
# genuine markers, not prose) — only the EN false-positive was ever real.
# Coordinator note, BWK awk gotcha: literal parentheses in the (b) shape
# are written as the bracket expressions [(] and [)], never \( \) — same
# "awk -v reprocesses backslash escapes" reason [*][*] exists instead of
# \*\* elsewhere in this file (confirmed live: with \( \), plain awk -v
# silently turned the escaped paren into an unescaped GROUPING paren,
# and "OPEN follow-ups:" started matching MRE — grep -E alone never
# showed this, only awk did, so both engines must be checked by hand).
MRE='^[[:space:]]*(-[[:space:]]+)?([*][*])?((DECIDED|RULE|OPEN|TAIL|TERM|REJECTED|STATE|INSIGHT|CLOSED)([-–—][^ :]*)?([*][*])?( ([a-z][a-z]?-[A-Za-z0-9-]*[0-9][A-Za-z0-9-]*|[a-z]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]|[(][^ )]*[)]))?|(РЕШЕНИЕ|Решение|ПРАВИЛО|Правило|ДЕЛО|ХВОСТ|Хвост|ТЕРМИН|Термин|ОТКАЗ|Отказ|ЗАКРЫТ|Закрыт|СОСТОЯНИЕ|ИНСАЙТ)([-–—][^ :]*)?([*][*])?( [^ :]+)?):'

# MRE_NOCOLON — a marker KEYWORD with no colon: the shape harvest's MRE above
# requires a colon to recognize a marker at all, so a line like "DECIDED chose
# X" (no ':') is invisible to harvest — silently dropped, not an error anyone
# sees. Two consumers need to catch this before it happens: the stop hook's
# lint (post-hoc, on whatever is already in the journal) and bro-append.sh's
# pre-write validator (reject before a byte is written). v3.7 — extracted out
# of bro-stop-turnstile.sh, which was the only copy before bro-append.sh
# became a second consumer; same duplication concern as MRE above (§0.1).
# Uses [*][*] not \*\* for the same awk -v reprocessing reason as MRE.
# v3.8 — same keyword alternation as MRE above (two RU writings for the
# original six, STATE/INSIGHT added ALL-CAPS-only — see MRE's own comment
# for why) — kept textually in sync by hand with MRE; there is no way to
# derive one from the other in bash 3.2 without an associative array (not
# available on this project's bash 3.2 target).
# Coordinator fix: the optional "- " bullet MRE itself allows was missing
# here, so a bulleted colonless marker ("- Правило без двоеточия") matched
# neither MRE (no colon) nor this lint (no leading "- ") — invisible to
# harvest AND unflagged by the very lint built to catch exactly that.
# Coordinator fix: same two-group split as MRE just above, and CLOSED
# moved into the EN group there in round 2 (its token is now the same
# restricted id/parenthetical shape as the other EN keywords) — mirrored
# here for consistency, kept in the same shape either way (there is no
# word-before-colon group here to restrict either way — this regex only
# ever matches a COLONLESS line — so the split changes nothing it
# matches, only how the keyword list reads next to MRE's own).
MRE_NOCOLON='^[[:space:]]*(-[[:space:]]+)?([*][*])?((DECIDED|RULE|OPEN|TAIL|TERM|REJECTED|STATE|INSIGHT|CLOSED)|(РЕШЕНИЕ|Решение|ПРАВИЛО|Правило|ДЕЛО|ХВОСТ|Хвост|ТЕРМИН|Термин|ОТКАЗ|Отказ|ЗАКРЫТ|Закрыт|СОСТОЯНИЕ|ИНСАЙТ))([*][*])?[[:space:]][^:]*$'

# marker_type() — v3.8 (§1). The one place any accepted spelling of a marker
# keyword (either RU writing, or the EN ALL-CAPS form) maps to ONE canonical
# EN token. Before this, every consumer that behaves differently per marker
# type re-spelled its own "DECIDED|РЕШЕНИЕ) …"-style alternation by hand —
# this file's own MRE comment already flagged that pattern as the exact
# duplication v3.7 closed for the recognizer regex itself; the type-DISPATCH
# switches (bro-harvest.sh's id-prefix pick and its register-write dispatch)
# still had their own copies. Now both do
#   KW=$(marker_type "$RAWKEYWORD") || continue
# and switch on $KW — one list (this function's own case) instead of two.
# $1 = the keyword exactly as MRE matched it, with any bullet/bold/indent
# and [-–—]suffix already stripped by the caller (see bro-harvest.sh's
# CLEAN/HEAD/KW extraction, which already did this stripping pre-3.8).
# Prints the canonical token on stdout and returns 0 for a recognized
# spelling; prints nothing and returns 1 otherwise. Keep this in lockstep
# with MRE/MRE_NOCOLON's alternation by hand — same limitation noted above.
marker_type() {
  case "$1" in
    DECIDED|РЕШЕНИЕ|Решение)   echo DECIDED ;;
    RULE|ПРАВИЛО|Правило)      echo RULE ;;
    OPEN|ДЕЛО|TAIL|ХВОСТ|Хвост) echo OPEN ;;  # v3.9: canonical type renamed TAIL -> OPEN; ДЕЛО is new (ALL-CAPS only), TAIL/ХВОСТ/Хвост still read
    TERM|ТЕРМИН|Термин)        echo TERM ;;
    REJECTED|ОТКАЗ|Отказ)      echo REJECTED ;;
    CLOSED|ЗАКРЫТ|Закрыт)      echo CLOSED ;;
    STATE|СОСТОЯНИЕ)           echo STATE ;;    # ALL-CAPS only — no "Состояние" writing, see MRE's own comment
    INSIGHT|ИНСАЙТ)            echo INSIGHT ;;  # ALL-CAPS only — no "Инсайт" writing, same reason
    *) return 1 ;;
  esac
}

# NEAR_MRE / NEAR_MRE_DASH — v3.8 (§1), the "almost a marker" counter.
# Advisory only: bro-harvest.sh counts lines that match either regex and
# logs ONE passive summary line per pass to ~/.claude/bro/health.log (same
# style as its pre-existing glued-text counter) — never blocks, never
# rewrites anything. This file only owns the SHAPE of "almost"; the counting
# and logging live in bro-harvest.sh next to the marker scan they piggyback
# on. A line matching either regex is, by construction, one MRE above does
# NOT match (the keyword sets below are disjoint from MRE's own list), so a
# real marker is never also counted as a near-miss.
#
# Three shapes, all lifted from real chronicle near-misses (bro/plan-v3.8.md
# §1's own examples):
#   NEAR_MRE — the right RU keyword STEM, wrong grammatical form: "Решено:"
#     (participle "decided/resolved", not the noun "Решение"), "Правила:" /
#     "Хвосты:" (plural, not the singular MRE accepts). Enumerated by hand
#     per keyword — same reason marker_type() above can't be generated from
#     a stem: no tolower() for Cyrillic and no case-folding shortcut, and
#     Russian noun/participle endings are not a job for a guessed suffix
#     wildcard without over-matching unrelated words. Also covers the exact
#     keyword written lowercase ("решение:") — MRE requires ALL CAPS or
#     Capitalized, so lowercase never becomes a real marker, but it's still
#     worth counting.
#   NEAR_MRE_DASH — the exact ACCEPTED spelling (RU either writing, EN
#     ALL-CAPS) with a dash standing in for the colon: "Решение — …". EN
#     Title-case/lowercase ("State:", "rule:") is deliberately NOT in either
#     regex: those are ordinary English words, and counting them would
#     flood health.log with prose — exactly the false-positive MRE itself
#     was built to exclude (see MRE's own v3.8 comment above). Moving that
#     noise into a second counter would defeat the point of keeping it out
#     of the first one.
#
# Coordinator follow-up after the real-data measurement: СОСТОЯНИЕ/ИНСАЙТ
# get NO wrong-form or lowercase entries here at all (no "Состояние:",
# "Состояния:", "состояние:", "Инсайты:", …) — the audit's near-miss
# examples included "Состояния: 1 — пустое поле (Step 1 of 2 …" (an app's
# UI states) and "состояние: где что лежит …" (a document's own section),
# neither an attempted operator-state marker. Counting these would flood
# health.log on every status caption and every screen/document "state",
# exactly the noise the EN-Title-case exclusion above already exists to
# avoid — same reasoning, just RU this time. СОСТОЯНИЕ/ИНСАЙТ (ALL CAPS)
# keep only the dash-instead-of-colon shape in NEAR_MRE_DASH, same as
# STATE/INSIGHT (EN) — an ALL-CAPS Russian word is not how anyone casually
# captions a status, so that one shape stays low-noise. The original six
# keywords are unaffected — keep every one of their near-miss forms.
#
# v3.9 follow-up: ДЕЛО (the new RU spelling for an open item, §1 of the
# v3.9 plan) gets the SAME treatment as STATE/INSIGHT just above, and for
# the same reason, even without a matching real-data audit yet — "дело" is
# an ordinary, extremely common Russian noun ("my own business", "get to
# the point", "beside the point"), and "Дело:"/"дело:" at the start of a
# line is exactly the shape ordinary prose takes, not just a rare status
# caption. Counting it as a near-miss would flood health.log worse than
# "Состояние:" ever would have. So: no "Дело:", "дело:", "Дела:" or any
# other wrong-form/lowercase entry for ДЕЛО in NEAR_MRE below — only the
# dash-instead-of-colon shape in NEAR_MRE_DASH, same as every other
# ALL-CAPS-only marker. TAIL/ХВОСТ/Хвост's own existing near-miss entries
# (ХВОСТЫ/Хвосты/хвост, right below) are unaffected — that family keeps
# whatever it already had.
NEAR_MRE='^[[:space:]]*(-[[:space:]]+)?([*][*])?(РЕШЕНО|Решено|РЕШЕНИЯ|Решения|ПРАВИЛА|Правила|ХВОСТЫ|Хвосты|ТЕРМИНЫ|Термины|ОТКАЗЫ|Отказы|ОТКАЗАНО|Отказано|ЗАКРЫТО|Закрыто|решение|отказ|правило|хвост|термин|закрыт)([*][*])?:'
NEAR_MRE_DASH='^[[:space:]]*(-[[:space:]]+)?([*][*])?(DECIDED|RULE|OPEN|TAIL|TERM|REJECTED|CLOSED|STATE|INSIGHT|РЕШЕНИЕ|Решение|ОТКАЗ|Отказ|ПРАВИЛО|Правило|ДЕЛО|ХВОСТ|Хвост|ТЕРМИН|Термин|ЗАКРЫТ|Закрыт|СОСТОЯНИЕ|ИНСАЙТ)([*][*])?[[:space:]]+[-–—]'

# utf8_trunc() — v3.8, coordinator fix (§7). $1 = string  $2 = max bytes.
# Cuts to AT MOST $2 bytes without leaving a truncated multi-byte UTF-8
# sequence dangling at the end. Confirmed live: a plain `substr($0,1,60)`
# inside harvest's awk cut a Cyrillic near-marker example mid-character —
# awk's substr()/length() are byte- or character-precise depending on the
# ambient locale, and a hook's environment cannot be relied on to set one;
# under an unset/C locale even a UTF-8-aware awk build measures bytes. Once
# that happened, `grep`/`tail` on ~/.claude/bro/health.log stopped matching
# anything at all — a stray continuation byte at EOF reads as binary to them.
# Deliberately does NOT do this in awk at all — `head -c`/`tail -c`/`wc -c`
# are byte-exact by POSIX definition regardless of locale (unlike `-m`/`-c`
# on `wc`/`cut`, which are character-aware and locale-sensitive), so the
# byte-precise cut and the UTF-8 boundary fix-up both happen here instead.
# Algorithm (the one the coordinator specified): cut to $2 bytes, then drop
# trailing UTF-8 CONTINUATION bytes (0x80-0xBF, decimal 128-191) one at a
# time, then — the byte now last, if any, may itself be an orphaned LEAD
# byte (0xC0-0xFF, decimal >=192: its continuation bytes were just dropped,
# or never made it into the window) — drop that one too if so. Plain ASCII
# text is untouched (no byte in it is ever >=128).
utf8_trunc() {
  local s="$1" max="$2" cut b n
  [ "$max" -gt 0 ] 2>/dev/null || { printf ''; return 0; }
  cut=$(printf '%s' "$s" | head -c "$max")
  while :; do
    n=$(printf '%s' "$cut" | wc -c | tr -d ' ')
    [ "$n" -gt 0 ] 2>/dev/null || break
    b=$(printf '%s' "$cut" | tail -c1 | od -An -tu1 2>/dev/null | tr -d ' ')
    case "$b" in ''|*[!0-9]*) break ;; esac
    if [ "$b" -ge 128 ] && [ "$b" -le 191 ]; then
      # BSD head rejects "-c 0" ("illegal byte count") — go straight to
      # empty instead of relying on it to just print nothing.
      if [ "$n" -le 1 ]; then cut=""; break; fi
      cut=$(printf '%s' "$cut" | head -c $((n-1)))
    else
      break
    fi
  done
  n=$(printf '%s' "$cut" | wc -c | tr -d ' ')
  if [ "$n" -gt 0 ] 2>/dev/null; then
    b=$(printf '%s' "$cut" | tail -c1 | od -An -tu1 2>/dev/null | tr -d ' ')
    case "$b" in
      ''|*[!0-9]*) : ;;
      *) if [ "$b" -ge 192 ]; then
           if [ "$n" -le 1 ]; then cut=""; else cut=$(printf '%s' "$cut" | head -c $((n-1))); fi
         fi ;;
    esac
  fi
  printf '%s' "$cut"
}
