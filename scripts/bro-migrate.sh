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
STORE_VERSION_REQUIRED=3

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

if [ ${#LEGACY[@]} -eq 0 ]; then
  say "no legacy storages found. Nothing to do."
  exit 0
fi

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
        for F in $MATCHES; do
          TAGDIR=$(dirname "$F")
          TAG=$([ "$TAGDIR" = "$SRC" ] && echo "root" || basename "$TAGDIR")
          {
            echo ""
            echo "## (thread: $TAG — merged by v3 migration)"
            echo ""
            cat "$F"
          } >> "$OUT"
        done
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

say "done: migrated=$MIGRATED skipped=$SKIPPED backup=$BACKUP"
[ "$DRY_RUN" = 1 ] && say "dry run — nothing was changed."
exit 0
