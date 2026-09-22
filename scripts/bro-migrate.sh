#!/bin/bash
# bro v3 migration — deterministic conversion of v1/v2.x storages into the v3 central store.
#
# Hard-coded rules, no LLM improvisation. Same input → same output, on any machine.
# Semantic work (deduplicating merged principles) is explicitly OUT of scope here:
# the script concatenates with provenance and flags heading collisions into CONFLICTS.md
# for a human (or a later /bro tidy pass) to resolve.
#
# Usage:
#   bro-migrate.sh [--dry-run] [--root <dir>] [search-path ...]
#
#   --root       target store (default: $BRO_ROOT, else ~/bro)
#   --dry-run    print the full plan, change nothing
#   search-path  where to look for legacy storages (default: $HOME, maxdepth 5)
#
# Guarantees:
#   1. NOTHING is deleted. Every legacy storage is moved wholesale into
#      <root>/_archive/<workspace>--<hash8>/ and a pointer file is left behind.
#   2. Daily logs are copied into the new layout byte-for-byte; when two chat
#      threads share a date, files are merged in alphabetical tag order, each
#      part under an explicit "## (thread: <tag>)" header. No content is dropped.
#   3. Idempotent: a legacy storage already archived (marker present) is skipped.
#   4. A tar.gz backup of every legacy storage is written before any move.

set -euo pipefail

DRY_RUN=0
ROOT="${BRO_ROOT:-$HOME/bro}"
SEARCH_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --root) ROOT="$2"; shift ;;
    *) SEARCH_PATHS+=("$1") ;;
  esac
  shift
done
[ ${#SEARCH_PATHS[@]} -eq 0 ] && SEARCH_PATHS=("$HOME")
ROOT="${ROOT/#\~/$HOME}"

TS=$(date +%Y%m%d-%H%M%S)
# one source of truth for the store major: the installed skill VERSION
STORE_VERSION_REQUIRED=$(cut -d. -f1 "$HOME/.claude/bro/VERSION" 2>/dev/null || echo 4)
# v4.0 (operator's own decision, 22 Sep 2026, §2 of the v4.0 fix-up):
# captured HERE, before either migration path below runs, so a store that
# STARTS at v3 is still correctly detected as "needs the 3 -> 4
# register-language translation" even when this SAME run also finds and
# migrates legacy v1/v2 storages into it — the legacy path below (further
# down, unchanged) stamps .version to STORE_VERSION_REQUIRED directly on
# completion; by the time that write happens, this snapshot has already
# been taken, so a pre-existing v3 store sitting next to freshly-migrated
# legacy ones is never silently skipped.
STORE_MAJOR_AT_START=$(cat "$ROOT/.version" 2>/dev/null || echo 0)

say()  { echo "[bro-migrate] $*"; }
act()  { if [ "$DRY_RUN" = 1 ]; then echo "  DRY: $*"; else "$@"; fi }

# ---------------------------------------------------------------- discovery
# A directory qualifies as legacy bro storage if it is named "bro" and contains
# at least one of the v1/v2 markers. The skill's own source repo does not match:
# its code files (SKILL.md, README.md, scripts/) are not storage-shaped.
is_legacy_storage() {
  local d="$1"
  [ "$(basename "$d")" = "bro" ] || return 1
  case "$d" in "$ROOT"|"$ROOT"/*) return 1 ;; esac        # never eat the new store
  [ -f "$d/_principles.md" ] && return 0
  compgen -G "$d/*/_thread.md" >/dev/null 2>&1 && return 0
  compgen -G "$d/*/.session.json" >/dev/null 2>&1 && return 0
  compgen -G "$d/*/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" >/dev/null 2>&1 && return 0
  compgen -G "$d/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" >/dev/null 2>&1 && return 0
  return 1
}

say "searching for legacy storages under: ${SEARCH_PATHS[*]} (maxdepth 5)"
LEGACY=()
while IFS= read -r d; do
  is_legacy_storage "$d" && LEGACY+=("$d")
done < <(find "${SEARCH_PATHS[@]}" -maxdepth 5 -type d -name bro -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | sort)

# v4.0 (§2): this used to `exit 0` right here when no legacy storage was
# found — correct back when this script had only the v1/v2 -> v3 path, but
# now it would ALSO skip the v3 -> v4 section further down on every machine
# that has no legacy v1/v2 folders left (the common case for an operator
# already on v3, wanting to reach v4). Falls through to an `else` that
# wraps the REST of this legacy-specific path instead (workspace naming
# through the index/version write below) — deliberately not re-indented,
# to keep this diff reviewable; bash does not care. Closed by the matching
# `fi` right after this path's own "done" line, below the index/version
# section.
if [ ${#LEGACY[@]} -eq 0 ]; then
  say "no legacy (v1/v2) storages found under: ${SEARCH_PATHS[*]} — nothing to do on that path."
else
say "found ${#LEGACY[@]} legacy storage(s):"
for d in "${LEGACY[@]}"; do echo "    $d"; done

# ---------------------------------------------------------------- workspace naming
# Workspace name = basename of the repo that contained bro/ (its parent dir),
# lowercased, spaces→dashes. Collisions get a numeric suffix deterministically
# (alphabetical order of source path decides who keeps the bare name).
ws_name_of() {
  basename "$(dirname "$1")" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-._'
}

hash8() { echo -n "$1" | shasum -a 256 | cut -c1-8; }

# ---------------------------------------------------------------- prepare store
say "target store: $ROOT"
act mkdir -p "$ROOT/_archive"

BACKUP="$HOME/bro-migrate-backup-$TS.tar.gz"
say "backup of all legacy storages → $BACKUP"
if [ "$DRY_RUN" = 0 ]; then
  tar czf "$BACKUP" "${LEGACY[@]}" 2>/dev/null || true
fi

WS_TAKEN=""
MIGRATED=0
SKIPPED=0

for SRC in "${LEGACY[@]}"; do
  H=$(hash8 "$SRC")
  WS=$(ws_name_of "$SRC")
  # deterministic collision suffix (bash-3.2 compatible name registry)
  if printf '%s\n' "$WS_TAKEN" | grep -qx "$WS"; then
    WS="${WS}-${H:0:4}"
  fi
  WS_TAKEN="$WS_TAKEN
$WS"

  ARCH="$ROOT/_archive/${WS}--${H}"
  if [ -d "$ARCH" ]; then
    say "SKIP (already archived): $SRC → $ARCH"
    SKIPPED=$((SKIPPED+1))
    continue
  fi

  say "migrating: $SRC → workspace '$WS'"
  WS_DIR="$ROOT/$WS"
  act mkdir -p "$WS_DIR/_legacy-v2"

  # -- 1. daily logs: per date, merge across tag folders in alphabetical order.
  if [ "$DRY_RUN" = 0 ]; then
    # dates from tag subfolders and from top level
    ALL_DAILIES=$(find "$SRC" -maxdepth 2 -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md" -type f \
                    -not -path "*/_legacy*" 2>/dev/null | sort)
    DATES=$(echo "$ALL_DAILIES" | xargs -I{} basename {} .md 2>/dev/null | sort -u)
    for DATE in $DATES; do
      OUT="$WS_DIR/$DATE.md"
      MATCHES=$(echo "$ALL_DAILIES" | grep "/$DATE\.md$" | sort)
      N=$(echo "$MATCHES" | grep -c . || true)
      if [ "$N" -eq 1 ] && [ ! -f "$OUT" ]; then
        cp "$MATCHES" "$OUT"
      else
        # newline-safe iteration (paths may contain spaces: "xovi ai svelte", …);
        # per-thread idempotency guard makes a re-run after a crash safe
        while IFS= read -r F; do
          [ -n "$F" ] || continue
          TAGDIR=$(dirname "$F")
          TAG=$([ "$TAGDIR" = "$SRC" ] && echo "root" || basename "$TAGDIR")
          if [ -f "$OUT" ] && grep -qF "## (thread: $TAG — merged by v3 migration)" "$OUT"; then
            continue
          fi
          {
            echo ""
            echo "## (thread: $TAG — merged by v3 migration)"
            echo ""
            cat "$F"
          } >> "$OUT"
        done <<< "$MATCHES"
      fi
    done

    # -- 2. per-thread summaries (_thread.md) → kept verbatim under _legacy-v2/
    find "$SRC" -maxdepth 2 -name "_thread.md" -type f -not -path "*/_legacy*" 2>/dev/null | while IFS= read -r F; do
      TAG=$(basename "$(dirname "$F")")
      cp "$F" "$WS_DIR/_legacy-v2/${TAG}--thread.md"
    done

    # -- 3. principles → staged for the global merge (nothing merged yet here)
    if [ -f "$SRC/_principles.md" ]; then
      mkdir -p "$ROOT/_principles-sources"
      cp "$SRC/_principles.md" "$ROOT/_principles-sources/${WS}--${H}.md"
    fi

    # -- 4. session markers and legacy folders ride along into the archive
    mkdir -p "$(dirname "$ARCH")"
    mv "$SRC" "$ARCH"

    # -- 5. pointer left where the storage used to be
    mkdir -p "$SRC"
    cat > "$SRC/README-MOVED.md" <<EOF
# bro storage moved (v3)

This repo's bro journal now lives in the central store:

    $WS_DIR/

Originals are preserved at:

    $ARCH/

Do not write here. See https://github.com/balaka/bro
EOF
  else
    say "  DRY: would merge dailies → $WS_DIR/, stash _thread.md files → _legacy-v2/,"
    say "  DRY: stage _principles.md, archive $SRC → $ARCH, leave pointer README-MOVED.md"
  fi

  MIGRATED=$((MIGRATED+1))
done

# ---------------------------------------------------------------- principles merge
# Deterministic: concatenate every staged source under a provenance header,
# then list duplicate section headings (potential conflicts) into CONFLICTS.md.
if [ "$DRY_RUN" = 0 ] && [ -d "$ROOT/_principles-sources" ]; then
  P="$ROOT/_principles.md"
  {
    echo "# bro principles (global, merged by v3 migration on $(date +%F))"
    echo ""
    echo "> Merged mechanically from $(ls "$ROOT/_principles-sources" | wc -l | tr -d ' ') legacy files."
    echo "> Semantic dedup is a human/LLM step: see CONFLICTS.md. Sources kept in _principles-sources/."
    echo ""
    for F in "$ROOT/_principles-sources"/*.md; do
      echo "---"
      echo ""
      echo "<!-- source: $(basename "$F") -->"
      echo ""
      cat "$F"
      echo ""
    done
  } > "$P"

  # heading collisions across sources → CONFLICTS.md
  {
    echo "# Possible conflicts (same heading in multiple legacy principle files)"
    echo ""
    echo "Resolve by editing _principles.md; delete this file when done."
    echo ""
    grep -h "^#\{1,3\} " "$ROOT/_principles-sources"/*.md \
      | sed 's/[[:space:]]*$//' | sort | uniq -c | awk '$1 > 1 {sub(/^ *[0-9]+ /,""); print "- [ ] " $0}'
  } > "$ROOT/CONFLICTS.md"
  # no collisions → still leave the file, but say so
  if ! grep -q "^- \[ \]" "$ROOT/CONFLICTS.md"; then
    echo "" >> "$ROOT/CONFLICTS.md"
    echo "(none detected mechanically — still worth one human read-through)" >> "$ROOT/CONFLICTS.md"
  fi
fi

# ---------------------------------------------------------------- index + version
if [ "$DRY_RUN" = 0 ]; then
  {
    echo "# bro index"
    echo ""
    echo "| workspace | files | last entry |"
    echo "|---|---|---|"
    for D in "$ROOT"/*/; do
      B=$(basename "$D")
      case "$B" in _archive|_principles-sources) continue ;; esac
      NF=$(find "$D" -name "*.md" -type f | wc -l | tr -d ' ')
      LAST=$(find "$D" -name "[0-9]*.md" -type f -exec basename {} .md \; 2>/dev/null | sort | tail -1)
      echo "| $B | $NF | ${LAST:-—} |"
    done
    echo ""
    echo "_Regenerated by bro-migrate.sh on $(date '+%F %T')_"
  } > "$ROOT/INDEX.md"

  echo "$STORE_VERSION_REQUIRED" > "$ROOT/.version"
fi

say "legacy (v1/v2 -> v3) path done: migrated=$MIGRATED skipped=$SKIPPED backup=$BACKUP"
[ "$DRY_RUN" = 1 ] && say "dry run — nothing was changed on that path."
fi   # closes the "if [ ${#LEGACY[@]} -eq 0 ]; then ... else" opened above

# ===========================================================================
# v3 -> v4 (operator's own decision, 22 Sep 2026, §2 of the v4.0 fix-up):
# translates an existing v3 store's REGISTER service words to English via
# scripts/bro-translate-registers.sh — the v1/v2 -> v3 path above is a
# different transition entirely (different on-disk architecture, not just a
# language) and is untouched by this section.
#
# STORE_MAJOR_AT_START (captured at the very top of this script, before
# either path ran) decides whether this runs, not a fresh re-read of
# .version: the legacy path above, when it ran, already stamped .version to
# STORE_VERSION_REQUIRED directly on completion (a store it just migrated
# today has no PRE-EXISTING registers of its own to translate — the first
# harvest pass over its freshly-placed journals already writes English,
# same as any other current-codebase workspace) — re-reading .version here
# would see that fresh stamp and wrongly conclude "already v4, nothing to
# do" even when this SAME run also needs to translate a separate,
# pre-existing v3 store that was sitting right there before either path
# started. Runs whether or not the legacy path above found anything to do —
# "old path, then 3 -> 4" (coordinator's own wording) means chronological
# ORDER when a machine has both, not "only one or the other" — and by
# running strictly AFTER the legacy path's own code above, a --all
# translate pass here also covers any workspace that path just created
# (harmless: freshly-harvested registers are already English, so those
# files simply count as "already English" below).
#
# --dry-run: run bro-translate-registers.sh --all --dry-run and print its
# own summary — .version is left untouched either way.
# without --dry-run: run bro-translate-registers.sh --all (it makes its own
# backup, under $ROOT/_archive/, before changing anything) and ONLY on a
# clean (exit 0) finish does .version become 4 — a failed or partial run
# leaves the store at v3, so a re-run of /bro migrate later picks up
# exactly where this one left off rather than silently claiming success.
if [ -d "$ROOT" ]; then
  if [ "$STORE_MAJOR_AT_START" = "3" ]; then
    TRANSLATE="$(dirname "$0")/bro-translate-registers.sh"
    [ -x "$TRANSLATE" ] || TRANSLATE="$HOME/.claude/bro/bin/bro-translate-registers.sh"
    if [ ! -x "$TRANSLATE" ]; then
      say "v3 -> v4: store $ROOT is v3, but bro-translate-registers.sh was not found next to $0 or in ~/.claude/bro/bin/ — reinstall (bro-install.sh) and run /bro migrate again."
    elif [ "$DRY_RUN" = 1 ]; then
      say "v3 -> v4: store $ROOT is v3 — previewing 'bro-translate-registers.sh --all --dry-run':"
      "$TRANSLATE" --root "$ROOT" --all --dry-run \
        || say "v3 -> v4: bro-translate-registers.sh --dry-run exited with an error (see its own output above)."
      say "v3 -> v4: dry run — nothing written, $ROOT/.version stays 3. Re-run without --dry-run, with the store owner's consent, to translate for real (bro-translate-registers.sh makes its own backup first)."
    else
      say "v3 -> v4: store $ROOT is v3 — running 'bro-translate-registers.sh --all' (it backs itself up before changing anything):"
      if "$TRANSLATE" --root "$ROOT" --all; then
        echo "4" > "$ROOT/.version"
        say "v3 -> v4: translation finished without errors — $ROOT/.version is now 4."
      else
        say "v3 -> v4: bro-translate-registers.sh exited with an error (see its own output above) — $ROOT/.version left at 3, nothing else changed. Fix the problem and run /bro migrate again."
      fi
    fi
  elif [ "$STORE_MAJOR_AT_START" = "4" ]; then
    say "v3 -> v4: store $ROOT is already v4 — nothing to do."
  fi
fi

say "done."
exit 0
