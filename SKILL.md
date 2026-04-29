---
description: Session continuity memory for Claude Desktop / Claude Code. Stores persistent context (project descriptor, sticky rules, architecture, vocabulary) per repo, plus ephemeral daily logs per chat thread. Resolves thread tag from chat title (manual rename → AI-generated → first message), suffixed with 6 hex chars from session UUID for guaranteed collision safety. Three-tier layout — repo-wide _principles.md, thread-wide _thread.md, daily {date}.md. Includes /bro migrate for LLM-driven full conversion of pre-v2.1 legacy logs into the new format without data loss.
---


# bro — session continuity memory

bro holds the middle layer of state that formal artifacts don't: mood, shortcut vocabulary, live threads, decisions, design tokens, debugging hypotheses, working-discipline rules. This layer is ephemeral in assistant attention but persistent if externalized.

**v2.1 architecture:** logs live **per-repo** (not centralized), in a **three-tier layout** — repo-wide universals (`_principles.md`), thread-wide stable context (`{tag}/_thread.md`), daily ephemeral state (`{tag}/{date}.md`). Tag derives from chat title (manual rename → AI-generated → first message), with a 6-hex postfix from session UUID for guaranteed uniqueness across parallel chats. Rename-aware: when operator renames a chat, bro detects the change and offers to rename the tag folder. `/bro migrate` performs LLM-driven semantic conversion of any pre-v2.1 logs into the new format with zero data loss.

---

## Step 0 — installation check (run once per invocation)

Check if this skill lives at the canonical path:

```bash
test -f ~/.claude/commands/bro.md && echo canonical || echo other
```

**If file IS at canonical path** → proceed to Step 0a.

**If file is NOT at canonical path** (copied somewhere else, or running inline):

Tell the user:

> I notice I'm not installed in the standard location. Claude Desktop / Claude Code auto-discovers skills from `~/.claude/commands/` — if I live there, `/bro` becomes a proper slash command available in every new chat, and updates are easier.
>
> Install me to the standard path? I can do it myself — just say yes.

If user confirms:
1. Find the current file location (via `find` or ask user)
2. `mkdir -p ~/.claude/commands`
3. `cp <current-path> ~/.claude/commands/bro.md`
4. Report: "Done. Restart Claude Desktop and `/bro` will work from any chat."

If user declines → continue from current location (still works, just not as a slash command).

---

## Step 0a — version check (weekly, non-blocking)

Read `~/.claude/bro-config.json`. Check the `lastVersionCheck` field (ISO timestamp).

**If `lastVersionCheck` is missing or older than 7 days ago:**

1. Fetch the latest version number from GitHub:
   ```bash
   REMOTE_VERSION=$(curl -sfL --max-time 5 \
     https://raw.githubusercontent.com/balaka/bro/main/bro.md \
     | head -5 | grep "^version:" | awk '{print $2}')
   ```
2. Read installed version from local `bro.md` frontmatter the same way (path: `~/.claude/commands/bro.md`).
3. Compare:
   - **Different versions** → tell the user:
     > bro v{REMOTE} available (you have v{LOCAL}). Update? I can fetch it now — just say yes.
     >
     > **Note:** if this is a major bump (e.g., v1.x → v2.x), the storage layout changed. v2 stores per-repo (not centralized). v2.1 added LLM-driven migration via `/bro migrate` that converts any legacy logs into the new format without data loss.

     If user confirms → run update flow (Section C).
     If user declines → proceed; re-check in 7 days.
   - **Same version** → silent, no interruption.
4. Write current ISO timestamp to `lastVersionCheck` in config so we don't re-check for another 7 days.

**Network failure or curl error** → silent, skip check, don't block. Try again next time.

**Skip version check entirely** if env var `BRO_NO_UPDATE_CHECK=1` is set.

---

## Step 1 — argument routing

- Argument `setup` or `config` → **Section A** (configure storage for this repo).
- Argument `list` → **Section D** (list today's threads in this repo).
- Argument `update` → **Section C** (self-update from GitHub).
- Argument `migrate` → **Section E** (LLM-driven migration of legacy logs).
- Argument in form `tag=<name>` or bare `<name>` (non-keyword) → **Section B** with `<name>` as explicit tag (postfix appended automatically).
- No argument → **Section B** with auto-resolved tag.

---

## Section A — setup flow (storage location for this repo)

v2.1 stores **per-repo**. Each repo picks its own location. Default is **visible** (`{cwd}/bro/`) so logs are inspectable, searchable, and reviewable.

### Step 1 — show current state

```bash
if [ -d "$(pwd)/bro" ] && [ -f "$(pwd)/bro/.gitignore" ]; then
  CURRENT="$(pwd)/bro/"
elif [ -d "$(pwd)/.claude/bro" ] && [ -f "$(pwd)/.claude/bro/.gitignore" ]; then
  CURRENT="$(pwd)/.claude/bro/"
else
  CURRENT="(not configured for this repo)"
fi
```

Tell user: "Current storage for this repo: `{CURRENT}`."

### Step 2 — check for legacy v1 config

```bash
if [ -f ~/.claude/bro-config.json ]; then
  LEGACY=$(jq -r '.storageDir // empty' ~/.claude/bro-config.json 2>/dev/null)
fi
```

If `LEGACY` is non-empty and not pointing to `{cwd}/bro/` or `{cwd}/.claude/bro/`:

> Found legacy v1 storage at `{LEGACY}`. v2.1 stores per-repo. After picking a location below, run `/bro migrate` to convert any legacy logs into the new three-tier format (zero data loss; originals preserved in `_legacy-pre-v2.1/`).

### Step 3 — ask for new location

> Where to store memory for this repo?
>
> 1. `{cwd}/bro/`         — visible in repo root (recommended for analysis & review)
> 2. `{cwd}/.claude/bro/` — hidden inside `.claude/`
> 3. Custom path
>
> Pick 1-3 or type a path.

Resolve choice:
- `1` → `{cwd}/bro/`
- `2` → `{cwd}/.claude/bro/`
- `3` or path → user input (expand `~`, resolve relative)

### Step 4 — create storage + .gitignore

```bash
mkdir -p "$STORAGE"
cat > "$STORAGE/.gitignore" <<'EOF'
# bro storage — local session memory, not for commit by default.
# Uncomment a line to share repo-wide or thread-wide context with the team:
# !_principles.md
# !*/_thread.md

*
!.gitignore
EOF
```

### Step 5 — optional copy from existing location

If switching from one location to another **within the same repo** (e.g., user previously had `.claude/bro/` and now picks `bro/`):

> Existing storage at `{OLD}` has {N} files. Copy `_principles.md` and `_thread.md` files to new location? (Daily logs not copied — they reflect historical state.)
>
> y / n

If `y`: copy `_principles.md` and `*/_thread.md` to new location (daily files stay at old).

### Step 6 — report

> bro will store memory for this repo in `{STORAGE}`.
> A `.gitignore` was added to keep daily logs local (you can edit it to commit principles/thread files if desired).
>
> If you have legacy bro logs (from v1 or v2.0) anywhere on disk, run `/bro migrate` next to convert them into the new format.

---

## Section B — normal flow

### Step 1 — resolve storage location for this repo

Detection (no per-repo config file — checked by existence):

```bash
CWD=$(pwd)
if [ -d "$CWD/bro" ] && [ -f "$CWD/bro/.gitignore" ]; then
  STORAGE="$CWD/bro"
elif [ -d "$CWD/.claude/bro" ] && [ -f "$CWD/.claude/bro/.gitignore" ]; then
  STORAGE="$CWD/.claude/bro"
else
  # No bro storage in this repo yet → first-time setup
  go to Step 1a
fi
```

### Step 1a — first-time setup in this repo

Run the prompt from **Section A Step 3** (asking where to store), then **Section A Step 4** (create dir + gitignore). After creation, return here and continue to Step 2.

### Step 1b — auto-trigger migration if needed

After resolving storage, check for legacy state:

```bash
needs_migration=0
# Storage exists but no _principles.md AND has daily files → likely pre-v2.1
if [ ! -f "$STORAGE/_principles.md" ] && find "$STORAGE" -maxdepth 2 -name "*.md" -type f 2>/dev/null | head -1 | grep -q .; then
  needs_migration=1
fi
# OR storage has *.nerve.md files at top level (pre-extraction)
if find "$STORAGE" -maxdepth 2 -name "*.nerve.md" -type f 2>/dev/null | head -1 | grep -q .; then
  needs_migration=1
fi
```

If `needs_migration=1`:

> Detected pre-v2.1 logs in `{STORAGE}` without `_principles.md` (or with mixed `.nerve.md` files at top level).
>
> Run `/bro migrate` to convert into the new three-tier format? It will:
> - Backup current state
> - Extract persistent material into `_principles.md` / `_thread.md`
> - Strip persistent from daily logs (keep refs)
> - Move originals to `{tag}/_legacy-pre-v2.1/` (never deleted)
> - Apply UUID postfix to existing tag names
>
> y / n / skip-this-time

If `y` → run **Section E**, then return here for current chat capture.
If `n` or `skip` → continue to Step 2 in degraded mode (creates empty `_principles.md` if absent).

### Step 2 — resolve thread tag

#### 2a. Find current session UUID

Two strategies, in priority order:

**Strategy 1 — via PPID (most reliable):**

```bash
# Claude Desktop writes ~/.claude/sessions/{PPID}.json mapping its pid to sessionUuid
SESSIONS_DIR="$HOME/.claude/sessions"
# Walk up the process tree from current shell to find Claude Desktop's pid
# (the slash command runs as a child of Claude's helper process)
for cand_pid in $PPID $(ps -o ppid= -p $PPID 2>/dev/null) $(ps -o ppid= -p $(ps -o ppid= -p $PPID 2>/dev/null) 2>/dev/null); do
  if [ -f "$SESSIONS_DIR/$cand_pid.json" ]; then
    SESSION_UUID=$(jq -r '.sessionId // empty' "$SESSIONS_DIR/$cand_pid.json" 2>/dev/null)
    SESSION_CWD=$(jq -r '.cwd // empty' "$SESSIONS_DIR/$cand_pid.json" 2>/dev/null)
    if [ -n "$SESSION_UUID" ] && [ "$SESSION_CWD" = "$(pwd)" ]; then
      break
    fi
  fi
done
```

**Strategy 2 — via mtime (fallback if PPID lookup fails):**

```bash
ENCODED_CWD=$(pwd | sed 's| |-|g; s|/|-|g')
PROJ_DIR="$HOME/.claude/projects/$ENCODED_CWD"
SESSION_JSONL=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
SESSION_UUID=$(basename "$SESSION_JSONL" .jsonl 2>/dev/null)
```

If both fail (Claude Desktop without Code, edge case):
- Set `SESSION_UUID="$(date +%Y%m%d-%H%M%S)-$RANDOM"`
- Skip title resolution; use `chat-{HHMM}` for slug

Set `SESSION_JSONL="$HOME/.claude/projects/$ENCODED_CWD/$SESSION_UUID.jsonl"` for next steps.

#### 2b. Resolve title from jsonl (priority chain)

Read jsonl entries, extract title with priority:

```bash
# 1. customTitle (manual rename via UI) — HIGHEST PRIORITY
TITLE=$(grep '"type":"custom-title"' "$SESSION_JSONL" 2>/dev/null \
  | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
TITLE_SOURCE="custom"

# 2. aiTitle (auto-generated by Claude) — SECOND
if [ -z "$TITLE" ]; then
  TITLE=$(grep '"type":"ai-title"' "$SESSION_JSONL" 2>/dev/null \
    | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)
  TITLE_SOURCE="ai"
fi

# 3. First user message — FALLBACK
if [ -z "$TITLE" ]; then
  # Skip enqueue events whose content starts with /  (avoid recursion if first action is /bro)
  TITLE=$(grep '"operation":"enqueue"' "$SESSION_JSONL" 2>/dev/null \
    | jq -r '.content // empty' 2>/dev/null \
    | grep -v '^/' \
    | head -1 \
    | head -c 200)
  TITLE_SOURCE="first-message"
fi

# 4. Timestamp fallback — LAST RESORT
if [ -z "$TITLE" ] || [ ${#TITLE} -lt 3 ]; then
  TITLE="chat-$(date +%H%M)"
  TITLE_SOURCE="fallback"
fi
```

**Multiple `custom-title` / `ai-title` entries:** take the LAST occurrence (most recent rename wins). Use `tail -1`.

#### 2c. Slugify with stop-word filter (Python preferred for unicode)

Use python3 for reliable Cyrillic handling:

```bash
SLUG=$(python3 <<PYEOF
import re

title = """$TITLE"""

STOP_RU = {"давай", "сделаем", "сделать", "сделай", "хочу", "нужно", "надо",
           "помоги", "помоги-ка", "посмотри", "проверь", "поправь", "исправь",
           "и", "в", "на", "по", "с", "со", "из", "о", "об", "у", "к", "от",
           "для", "это", "тут", "там", "этот", "эта", "эти", "тот", "та", "те",
           "чтобы", "если", "когда", "как", "что", "так", "же", "ли", "бы"}

STOP_EN = {"hey", "hi", "hello", "let", "lets", "let's", "can", "could", "would",
           "please", "help", "look", "check", "fix", "make", "do",  # keep these for now: removing 'fix' would hurt; reconsider
           "the", "a", "an", "and", "or", "of", "for", "to", "in", "on", "at",
           "is", "are", "was", "were", "be", "been", "this", "that", "these",
           "those", "it", "its", "they", "them"}

# Lowercase + tokenize (preserve cyrillic + latin + digits)
words = re.findall(r'[a-zа-я0-9]+', title.lower())

# Filter: drop stop-words, drop words shorter than 2 chars
filtered = [w for w in words
            if len(w) >= 2
            and w not in STOP_RU
            and w not in STOP_EN]

# If filtering removed everything, fall back to unfiltered first 5 words
if not filtered:
    filtered = words

# Take first 5 words, join with -
slug = '-'.join(filtered[:5])

# Truncate to 40 chars on word boundary
if len(slug) > 40:
    truncated = slug[:40]
    last_dash = truncated.rfind('-')
    if last_dash > 20:  # only truncate at word boundary if it's not too aggressive
        slug = truncated[:last_dash]
    else:
        slug = truncated.rstrip('-')

print(slug)
PYEOF
)

# Final fallback if slug is somehow empty
if [ -z "$SLUG" ] || [ ${#SLUG} -lt 3 ]; then
  SLUG="chat-$(date +%H%M)"
fi
```

**Notes on stop-words:**
- `fix`, `make`, `do` are kept in EN list because they often start titles like "Fix auth bug" — without them slug becomes just "auth bug". Operator can override per repo by editing local copy of bro.md if desired. (Future improvement: per-repo stop-word config.)

#### 2d. Append UUID postfix

```bash
# First 6 hex chars of sessionUuid — deterministic uniqueness
POSTFIX="${SESSION_UUID:0:6}"
TAG="${SLUG}-${POSTFIX}"
```

**Why this postfix scheme:**
- UUIDv4 is itself a function of time + entropy → meets operator requirement "функция от времени, но не само время"
- Two chats started in same minute have different UUIDs → different postfix → no collision
- Same chat continued days later has same UUID → same postfix → seamless continuation
- 6 hex chars = 16M variants; within one repo, collision probability negligible

#### 2e. Check session marker (continuation logic)

```bash
MARKER_FILE="$STORAGE/$TAG/.session.json"

if [ -f "$MARKER_FILE" ]; then
  STORED_UUID=$(jq -r '.sessionUuid // empty' "$MARKER_FILE" 2>/dev/null)
  STORED_TITLE=$(jq -r '.lastKnownTitle // empty' "$MARKER_FILE" 2>/dev/null)
  
  if [ "$STORED_UUID" = "$SESSION_UUID" ]; then
    # Same chat continuing in same tag — proceed to Step 2f (rename detection)
    :
  else
    # COLLISION: tag folder exists but belongs to a different chat
    # This shouldn't happen if postfix is correct, but defensive:
    # append a second postfix from current UUID
    EXTRA="${SESSION_UUID:6:4}"
    TAG="${TAG}-${EXTRA}"
    MARKER_FILE="$STORAGE/$TAG/.session.json"
  fi
fi
```

#### 2f. Rename detection

If marker exists and `STORED_TITLE` differs from current `TITLE`:

```bash
if [ -n "$STORED_TITLE" ] && [ "$STORED_TITLE" != "$TITLE" ]; then
  STORED_SOURCE=$(jq -r '.titleSource // empty' "$MARKER_FILE" 2>/dev/null)
  
  # Only prompt if source priority improved or title genuinely changed
  # (e.g., aiTitle → customTitle is a clear upgrade; first-message → aiTitle too)
  
  echo "Title changed:"
  echo "  was: ${STORED_SOURCE}: \"${STORED_TITLE}\""
  echo "  now: ${TITLE_SOURCE}: \"${TITLE}\""
  echo ""
  echo "Rename tag folder to reflect new title?"
  echo "  1. Yes — move $TAG → {new-tag} (recommended; default)"
  echo "  2. No — keep $TAG, just save new files there"
fi
```

If user picks `1` (or empty input = default):
- Recompute slug from new title (steps 2c-2d)
- Compute new tag: `${NEW_SLUG}-${POSTFIX}`
- Move folder: `mv "$STORAGE/$TAG" "$STORAGE/$NEW_TAG"`
- Update marker: write new `lastKnownTitle`, `titleSource`, append to `previousTitles[]` array
- Add a marker line to today's daily file: `(renamed from $TAG since YYYY-MM-DD)`
- Set `TAG="$NEW_TAG"` for the rest of this `/bro` invocation

If user picks `2`:
- Keep current tag
- Update marker `lastKnownTitle` to new title (so we don't ask again next /bro)
- Append previous title to `previousTitles[]` array

#### 2g. Commit tag (create folder + marker)

```bash
mkdir -p "$STORAGE/$TAG"

# Write/update session marker
cat > "$STORAGE/$TAG/.session.json" <<JSONEOF
{
  "sessionUuid": "$SESSION_UUID",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "firstMessage": "$(echo "$FIRST_MSG_RAW" | head -c 200 | tr '\n' ' ')",
  "lastKnownTitle": "$TITLE",
  "titleSource": "$TITLE_SOURCE",
  "previousTitles": [...]
}
JSONEOF
```

**Explicit-tag override:** if operator passed `/bro <tag>` or `/bro tag=<name>`:
- Use their `<name>` directly as slug (after normalization: lowercase, spaces→dashes, strip non-alphanumeric)
- Still append postfix from session UUID
- Skip rename detection (operator said exactly what they wanted)

### Step 3 — read existing files

Before writing anything, load context:

1. **`$STORAGE/_principles.md`** — repo-wide persistent
2. **`$STORAGE/$TAG/_thread.md`** — thread-wide persistent (may not exist yet)
3. **`$STORAGE/$TAG/{YYYY-MM-DD}.md`** — today's daily ephemeral (may not exist yet)

These tell us **what's already captured**, so we don't duplicate.

### Step 4 — classify new material from recent conversation

Review the last 5–7 exchanges. For each piece of new material, run two tests:

**Test 1 — temporal:**
> If a fresh chat opens in this repo tomorrow, would this still be true / relevant?

- **YES** → persistent (`_principles.md` or `_thread.md`)
- **NO**  → ephemeral (daily file)

**Test 2 — scope (only for persistent):**
> Is this universal across all work in this repo, or specific to the current topic / thread?

- **Universal** (project descriptor, git rules, working discipline that applies everywhere, people across multiple threads) → `_principles.md`
- **Topic-specific** (architecture decisions for this work, vocabulary in this domain, roadmap of this slice, file map for this area) → `_thread.md`

**Anti-duplication:**
- If material is already in `_principles.md` or `_thread.md` → don't repeat in daily, optionally write `(see _principles.md)` ref.
- If it was in yesterday's daily file unchanged → either skip, or add `(без изменений с YYYY-MM-DD)` note in daily.

**Classification table (concrete examples):**

| Material | Destination |
|---|---|
| "Project on Bash + TS, not MCP" | `_thread.md` → Architecture (sticky) |
| "Never push without confirmation" | `_principles.md` → Sticky rules |
| "Tired today" | daily → Operator state |
| "Slice 2 = parsing layer for X" | `_thread.md` → Roadmap structure |
| "Slice 2 done" (status today) | daily → Roadmap status |
| "Term 'трек' = 3-line headline" | `_thread.md` → Shortcut vocabulary |
| "Decided: use SQLite, not Postgres" (today) | daily → DECIDED + ASK promote to `_thread.md` |
| "No Figma" (rejected today, hard) | daily → REJECTED (чтобы не возвращались) |
| "P0: no internal jargon leaks" | `_thread.md` → Design principles |
| "stripUndefined helper — don't remove" | `_thread.md` → Known subtleties / gotchas |
| "Не останавливать оператора по соображениям токенов" | `_principles.md` → Working discipline |

### Step 5 — interactive promotion prompts (when uncertain)

When material looks persistent but it's not 100% clear, **ask the operator** before cementing it.

**One promotion ask per /bro invocation, max.** Don't spam. Batch related items.

Format:

> Promote to persistent? I noticed candidates:
>
> 1. *"Storage is per-repo, not centralized"* — looks like architecture decision → `_thread.md`?
> 2. *"Auto mode active, minimize interruptions"* — looks like working discipline → `_principles.md`?
>
> y / n / pick (e.g., "1 only", "1 to thread, 2 skip")

**Don't ask** for material that's unambiguously ephemeral (operator state, daily decisions with explicit dates) — write directly to daily.

**Don't ask** for material that's already in persistent files — just skip.

**Token-flow rule:** *Never stop the operator on token concerns.* If operator's `_principles.md` contains the rule "no token economy in flow" — bypass any habit of warning about response length, depth, or budget.

### Step 6 — write files

Write order:

1. **`_principles.md`** — create if missing (use template below). Otherwise append/update relevant sections.
2. **`{tag}/_thread.md`** — create only if there's persistent thread-specific material to write. Otherwise append/update relevant sections.
3. **`{tag}/{YYYY-MM-DD}.md`** — create from minimal template if missing. Append/update relevant sections.

**Section editing rules:**
- Persistent files (`_principles.md`, `_thread.md`): **append-only** for new items; existing items rarely change. Use `(supersedes prior, dated YYYY-MM-DD)` if a sticky decision is overridden.
- Daily files: sections like Operator state, Current mode, "Что произошло сегодня" are **rewritten daily** (no carryover). Live threads sections are **carried + updated** (OPEN items roll forward unless closed; DECIDED accumulates with date stamps).

**Sections in daily file are optional** — include only when there's material. Empty sections are removed, not left as placeholders. Minimum viable daily file = metadata header + Operator state + Live threads OPEN + Read order at end.

### Step 7 — report

```
Updated for this /bro:

📜 _principles.md — added: Sticky rules ("no --amend"), Working discipline #4 (token flow)
📂 {tag}/_thread.md — created: Architecture (3 decisions), Vocabulary (4 terms), Roadmap (6 slices)
📝 {tag}/{date}.md — updated: Operator state, Live threads OPEN, REJECTED (чтобы не возвращались)

Tag: bro-migration-fix-9e0988
  Source: custom-title — "Bro Migration Fix" (you renamed it from "Fix plugin log storage...")
  Postfix: 9e0988 (from session UUID 9e09887a-c861-4916-a49f-9d0fee261393)
  Marker: bro/bro-migration-fix-9e0988/.session.json
```

If nothing new worth writing → say so explicitly, skip the writes:
> No new persistent or ephemeral material since last update. Nothing written.

---

## Section C — self-update flow

Invoked via `/bro update` or accepted from Step 0a prompt.

1. Download latest `bro.md` from GitHub:
   ```bash
   curl -sfL --max-time 10 \
     -o ~/.claude/commands/bro.md.new \
     https://raw.githubusercontent.com/balaka/bro/main/bro.md
   ```
2. Verify fetched file is non-empty and contains a `version:` line. If invalid → abort, delete `.new` file, report error.
3. Extract new version:
   ```bash
   NEW_VERSION=$(head -5 ~/.claude/commands/bro.md.new | grep "^version:" | awk '{print $2}')
   OLD_VERSION=$(head -5 ~/.claude/commands/bro.md | grep "^version:" | awk '{print $2}')
   ```
4. **Major-version bump warning** — if NEW major != OLD major (e.g., 1.x → 2.x):
   > Major version bump: v{OLD} → v{NEW}. Storage layout may have changed.
   >
   > After update, run `/bro migrate` in any repo with legacy logs — it will perform LLM-driven semantic conversion to the new format with zero data loss.
   >
   > Continue update? y / n
5. Atomic swap (after confirmation):
   ```bash
   mv ~/.claude/commands/bro.md.new ~/.claude/commands/bro.md
   ```
6. Update config `~/.claude/bro-config.json`:
   - Set `installedVersion` to new version
   - Set `lastVersionCheck` to current ISO timestamp
7. Report:
   > Updated to v{NEW_VERSION}. Restart Claude Desktop (or open a new chat) to load the new version.
   > If you have legacy bro logs anywhere, run `/bro migrate` in those repos.

**If curl fails or version check fails** → report clearly: "Update failed: {reason}. You're still on v{current}. Try again later or update manually: `curl -o ~/.claude/commands/bro.md https://raw.githubusercontent.com/balaka/bro/main/bro.md`"

---

## Section D — list today's threads

Invoked via `/bro list`.

1. Resolve storage directory for this repo (Section B Step 1).
2. List persistent files:
   ```bash
   [ -f "$STORAGE/_principles.md" ] && stat -f "%Sm" "$STORAGE/_principles.md"
   find "$STORAGE" -maxdepth 2 -name "_thread.md" -type f
   ```
3. List today's daily files:
   ```bash
   find "$STORAGE" -maxdepth 2 -name "$(date +%Y-%m-%d).md" -type f
   ```
4. For each daily file's tag folder, read marker (`{tag}/.session.json`) for `lastKnownTitle`, `titleSource`, `previousTitles`.
5. Display:

```
bro storage for this repo: {STORAGE}

Persistent:
  📜 _principles.md                       updated 5d ago    (8 sections)
  📜 fix-auth-bug-a3f1c0/_thread.md       updated 2d ago    (4 sections)

Today's daily threads:
  📝 bro-migration-fix-9e0988             updated 12m ago   custom: "Bro Migration Fix"
  📝 fix-auth-bug-a3f1c0                  updated 2h ago    ai: "Fix authentication bug in login flow"
  📝 explore-roadmap-7b2ed5               updated 5h ago    first-message: "let's explore the roadmap"

Total: 3 daily threads, 1 thread-context file, 1 principles file.

Renamed today:
  📝 bro-migration-fix-9e0988 was "fix-plugin-log-storage-..." (renamed 2026-04-29)

Run /bro <tag> to continue a specific thread, /bro to auto-resolve from current chat.
```

If no daily threads today → say "No bro threads created today in this repo. Run `/bro` to start."

---

## Section E — `/bro migrate` (LLM-driven legacy conversion)

Invoked via `/bro migrate`, or auto-suggested from Step 1b when pre-v2.1 logs detected.

**Operating principles (from operator):**
- **No data loss.** Originals always preserved in `{tag}/_legacy-pre-v2.1/`.
- **No token economy.** This is a deep semantic conversion — operator explicit: *"на полную глубину без экономии ресурсов"*.
- **Capture current chat first.** Before touching legacy logs, write a fresh new-format daily for the current session. If migration crashes mid-way, current context is preserved.

### Step 1 — backup

```bash
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$HOME/Desktop/_bro-migrate-backup-$TS.tar.gz"

# Backup the storage in this repo
tar czf "$BACKUP" "$STORAGE" 2>/dev/null
echo "Backup: $BACKUP"
```

If migrate is invoked across multiple legacy locations (Step 3), include all of them in backup.

### Step 2 — capture current chat in new format FIRST

Run **Section B Steps 1-7** for current session. This:
- Resolves current tag (custom-title → ai-title → first-message → fallback)
- Creates/updates `_principles.md` (universal context if any)
- Creates `{tag}/_thread.md` (topic context if any)
- Writes today's daily for current chat
- Captures current operational rules into persistent

This guarantees that even if migration of legacy logs crashes, the current chat's working context is preserved in the new format.

### Step 3 — discover legacy locations

Search in priority order:

```bash
LEGACY_LOCATIONS=()

# 1. Current storage in this repo (may have pre-v2.1 layout inside)
[ -d "$STORAGE" ] && LEGACY_LOCATIONS+=("$STORAGE")

# 2. v1 central storages
for cand in ~/Desktop/bro-workspace ~/.claude/bro; do
  [ -d "$cand" ] && [ "$cand" != "$STORAGE" ] && LEGACY_LOCATIONS+=("$cand")
done

# 3. Other bro/ folders in operator's Desktop
while IFS= read -r line; do
  [ -d "$line" ] && [ "$line" != "$STORAGE" ] && LEGACY_LOCATIONS+=("$line")
done < <(find ~/Desktop -maxdepth 4 \( -name "bro" -o -path "*/.claude/bro" \) -type d 2>/dev/null)
```

Report findings:

```
Found legacy logs at:
  1. /Users/y/Desktop/frontend/xovi ai svelte/bro/  (10 tags, 25 files)
  2. /Users/y/Desktop/frontend/product-os-design/bro/  (1 tag, 7 files)
  3. /Users/y/Desktop/cowork/bro/  (3 tags, 14 files)

Migrate all? y / pick / n
```

If `pick` → ask which to include.

### Step 4 — per-location, per-tag migration via LLM

For each legacy location, for each tag folder:

#### 4a. Inventory the tag

```bash
for tag_dir in "$LEGACY_LOC"/*/; do
  tag=$(basename "$tag_dir")
  files=$(find "$tag_dir" -maxdepth 2 -name "*.md" -type f | sort)
  count=$(echo "$files" | wc -l)
  has_thread=$(test -f "$tag_dir/_thread.md" && echo y || echo n)
  has_marker=$(test -f "$tag_dir/.session.json" && echo y || echo n)
  echo "[$tag] $count files, _thread: $has_thread, marker: $has_marker"
done
```

#### 4b. Read all daily files for this tag

```bash
ALL_FILES=$(find "$tag_dir" -maxdepth 2 -name "*.md" -type f ! -name "_thread.md" ! -name "_principles.md" | sort)
```

Read each file's full content into context. Multiple files capture evolution of the topic.

#### 4c. LLM semantic classification

For each section in each file, classify:

**Persistent universal** (→ candidate for `_principles.md`):
- Project descriptor (repo URL, paths, branches)
- Sticky rules (git/code safety, hard process constraints applying everywhere)
- Working discipline that applies across all work
- People mentioned across multiple threads

**Persistent topic-specific** (→ candidate for `_thread.md`):
- Architecture decisions for this work (sticky)
- Design principles (P0-PN)
- Shortcut vocabulary used in this thread
- Roadmap structure
- Open architectural items (long-running questions)
- Known subtleties / gotchas
- File / module map for this area
- References / external resources for this work

**Ephemeral** (→ daily file):
- Operator state (energy, mood, fatigue today)
- Live threads (OPEN/DECIDED/REJECTED) for that day
- "Что произошло сегодня" / Session arc
- Roadmap status (deltas)
- Investigation state (today's hypotheses)
- Outputs this session (commits, files committed today)
- Не сделано сегодня
- Meta-insights (today's reflections)
- Cross-thread links (state of related threads on that day)
- Next steps (post-compact)

**Use markers as hints (not gospel):**
- `(sticky)` → strong signal for persistent
- `(carried since YYYY-MM-DD)` → persistent, retain origin date
- `(reinforced YYYY-MM-DD)` → persistent, retain reinforcement dates
- `(без изменений с YYYY-MM-DD)` → was carried over from prior daily, possibly persistent
- `(чтобы не возвращались)` → REJECTED, ephemeral but with lasting do-not-revisit semantic
- `(P0)` … `(PN)` → priority annotation on persistent

#### 4d. Cross-file deduplication within tag

When same architectural decision appears in 5 daily files in this tag → write to `_thread.md` once, with `(carried since YYYY-MM-DD)` from earliest mention.

When same vocabulary term defined in 3 files → write once in `_thread.md`. If definition evolved between files, keep latest, optionally note `(refined YYYY-MM-DD)`.

When working-discipline rule appears across multiple tags (i.e., universal) → defer to Step 5 cross-tag aggregation; flag for `_principles.md`.

#### 4e. Write `{tag}/_thread.md`

Use the template from this file (see Templates section). Populate:
- Architecture (sticky) — extracted decisions with Chose/Over/Because/Revisit
- Design principles — numbered with priorities
- Shortcut vocabulary — terms with definitions and origin dates
- Roadmap — table from earliest file's structure (statuses move to dailies)
- Open architectural items — long-running questions
- Known subtleties / gotchas — tribal knowledge
- File / module map — current state at latest daily
- References / external resources

Add markers `(carried since YYYY-MM-DD)` for items extracted from older files; `(consolidated 2026-04-29 from N source files)` to top of file as audit trail.

#### 4f. Rewrite each daily file in v2.1 format

For each `{date}.md` original:

1. Strip persistent content already extracted to `_thread.md`. Replace with: `(see _thread.md → Architecture)` ref where useful.
2. Preserve all ephemeral content as-is — operator state for that day, live threads OPEN/DECIDED/REJECTED, daily-specific outputs and not-done items.
3. Update metadata at top:
   - thread: tag-with-postfix
   - workspace: cwd
   - read order: includes `../_principles.md`, `_thread.md`
4. Normalize markers (e.g., `(чтобы не возвращались)` for explicit do-not-revisit on REJECTED).
5. Preserve operator's verbatim quotes including Russian idioms.
6. Daily structure follows v2.1 daily template.

If a file is mostly persistent material that's already been extracted — daily becomes very short. That's fine; do not pad. Minimal daily = metadata + brief operator state + Live threads OPEN.

#### 4g. Move originals to `{tag}/_legacy-pre-v2.1/`

```bash
mkdir -p "$tag_dir/_legacy-pre-v2.1"
for orig in $ORIGINAL_FILES; do
  mv "$orig" "$tag_dir/_legacy-pre-v2.1/"
done
```

Originals never deleted. Operator can `/bro clean-legacy` later (manual command, not auto).

#### 4h. Apply UUID postfix to old tag name

If old tag has no `.session.json` marker (legacy):
- Generate deterministic postfix: `sha256(tag_name + earliest_file_creation_time).hex[:6]`
- Rename folder: `mv "$tag_dir" "$LEGACY_LOC/${tag}-${postfix}"`

This unifies all tags under the v2.1 naming convention.

If old tag had a `.session.json` marker (rare in legacy, common in our v2.0 storage):
- Use the existing UUID's first 6 hex chars as postfix
- Rename if needed

### Step 5 — write `_principles.md` (consolidated repo-wide)

After processing all tags in this storage:

1. Aggregate "persistent universal" candidates from Step 4c across all tags
2. Deduplicate (same git rule may appear in multiple `_thread.md` candidates → write once in `_principles.md`)
3. Sources cite tag for each rule: `(observed in tags: foo, bar, baz; carried since 2026-04-15)`
4. Write `_principles.md` from template, populated with consolidated content

### Step 6 — verify

```bash
echo "═══ VERIFICATION ═══"
echo "Total files before: $(tar tzf $BACKUP | grep -c '\.md$')"
echo "Total files after:"
find "$STORAGE" -name "*.md" -type f | wc -l

# Spot-check: did persistent appear in _principles.md / _thread.md?
echo "_principles.md sections:"
grep "^## " "$STORAGE/_principles.md" 2>/dev/null

# Spot-check: did dailies shrink?
for tag_dir in "$STORAGE"/*/; do
  tag=$(basename "$tag_dir")
  for daily in "$tag_dir"*.md; do
    [ -f "$daily" ] || continue
    [[ "$(basename "$daily")" == "_thread.md" ]] && continue
    new_size=$(wc -l < "$daily")
    legacy=$(ls "$tag_dir/_legacy-pre-v2.1/$(basename "$daily")" 2>/dev/null)
    if [ -n "$legacy" ]; then
      old_size=$(wc -l < "$legacy")
      echo "  [$tag/$(basename "$daily")] $old_size → $new_size lines"
    fi
  done
done
```

### Step 7 — report

```
═══ MIGRATION COMPLETE ═══

Locations migrated: 3
Tags processed: 14
Files extracted to persistent: 47 sections → _principles.md + _thread.md (× tags)
Daily files rewritten: 35
Originals preserved at: {tag}/_legacy-pre-v2.1/ (35 files, untouched)

Backup: ~/Desktop/_bro-migrate-backup-{ts}.tar.gz

Next steps:
- Open _principles.md and {one}/_thread.md to spot-check classification
- If migration looks correct after a few days → /bro clean-legacy to delete _legacy-pre-v2.1/ folders
- If migration looks wrong → restore from backup: tar xzf backup.tar.gz -C /
```

### Step 8 — `/bro clean-legacy` (separate command, only run manually)

After operator has reviewed migration and is confident:

```bash
# Find all _legacy-pre-v2.1/ folders in this repo's storage
find "$STORAGE" -name "_legacy-pre-v2.1" -type d
```

Confirm with operator:

> Found N _legacy-pre-v2.1/ folders. Delete them? Backup at {path} still exists; deletion is irreversible.
> y / n

Only on `y` → `rm -rf` each. Tar backup remains as final fallback.

---

## Templates

### `_principles.md` (repo-wide universal)

```markdown
# bro principles — {repo-name}

> Persistent context for this repo. Read on /compact and on first entry to a new chat.
> Updated rarely. Items here apply to ALL work threads in this repo.

## Project descriptor

- name: {project name}
- repo: `{git URL}`
- local path: `{cwd}`
- main branch: `{branch}`
- deploy branch: `{if applicable}`
- first canonical commit: `{if known}`

## Sticky rules (git / code safety / process)

- {Hard rule}
- {Hard rule}

## Working discipline (universal)

[Numbered rules with optional markers like (carried since YYYY-MM-DD), (reinforced YYYY-MM-DD)]

1. **{Rule name}.** {Description, optionally with operator's verbatim quote.}
2. **{Rule name}.** {Description.}

## People in context (cross-thread)

- **Name** — role, relevance across multiple threads
```

### `{tag}/_thread.md` (thread-wide stable)

```markdown
# bro thread context — {tag-with-postfix}

> Stable context for this work topic. Updated rarely. Read after `_principles.md` on /compact.
> Items here apply to THIS thread's work topic.

## Architecture (sticky)

### {Decision name}
- **Chose:** ...
- **Over:** ...
- **Because:** ...
- **Revisit if:** ...

## Design principles (numbered, P0 most important)

- **P0** — {principle}
- **P1** — {principle}

## Shortcut vocabulary

- **Term** — definition. (Origin: who/when introduced)
- **Русский термин** — definition (Russian idioms preserved verbatim)

## Roadmap

| Slice | Focus | Estimated | Status (in daily) |
|---|---|---|---|
| 1 | ... | ... | (see today's daily for current status) |
| 2 | ... | ... | |

## Open architectural items

[Long-term questions, not currently in flight]

1. {Question} *(open since YYYY-MM-DD)*
2. {Question} *(open since YYYY-MM-DD)*

## Known subtleties / gotchas

- {Tribal knowledge that's easy to forget}

## File / module map

[ASCII tree or annotated list]

```
src/
├── runtime/
│   └── ...
└── cli.ts
```

- `path/to/file` — relevance, what it does

## References / external resources

- {Path or URL with one-line description}
```

### `{tag}/{YYYY-MM-DD}.md` (daily ephemeral)

```markdown
# bro — {YYYY-MM-DD} / {tag-with-postfix}

- thread: {tag-with-postfix}
- workspace: `{cwd}`
- branch: `{git branch}` (if code work)
- previous bro: `./{prev-date}.md` (if exists in this thread)
- continues from: {if non-trivial gap}
- dominant theme today: {one-line summary}
- read order on /compact:
  1. THIS FILE FIRST
  2. `../_principles.md`
  3. `_thread.md` (if exists)
  4. {specific files for current task}

---

## Operator state

[Today's energy, mode, mood markers; what changed from prior sessions]

## Live threads

### OPEN

- {Carried from prior days + new today; explicit status `Pending: ...` / `Waiting on: ...` / `Status: paused`}

### DECIDED — {topic 1}

- {Today's decisions for this topic}

### REJECTED (чтобы не возвращались)

- {Hard do-not-revisit; with rationale}

---

<!-- Optional sections — added when material exists -->

## Что произошло сегодня (Session arc)

[Numbered narrative phases — for sessions with significant flow]

### 1. {Phase name}
[Prose description]

## Roadmap status

- Slice {N}: {status delta from `_thread.md` Roadmap}

## Canon gaps surfaced today

- {Discrepancy between code and product truth, flagged for next sync}

## Investigation state

- Current hypothesis: ...
- Checked (clean): ...
- Checked (found): ...
- Not yet checked: ...
- Next probe: ...

## Outputs this session

- Reports (committed): ...
- Canon (committed): ...
- Project branches/commits: `{commit hash}` — {description}

## Не сделано сегодня

- {Deferred, with reason}

## Meta-insights (today)

- {Reflection — candidate for promotion to `_thread.md` or `_principles.md` next /bro}

## Cross-thread links

- {other thread name in this repo}: {state of that thread today}

## Next steps (post-compact)

1. ...
2. ...
```

### `{tag}/.session.json` (session marker)

```json
{
  "sessionUuid": "9e09887a-c861-4916-a49f-9d0fee261393",
  "createdAt": "2026-04-29T05:52:44Z",
  "firstMessage": "...first 200 chars of first user message...",
  "lastKnownTitle": "Bro Migration Fix",
  "titleSource": "custom",
  "previousTitles": [
    {"source": "ai", "title": "Fix plugin log storage and multiple chat handling"},
    {"source": "custom", "title": "Bro Migration Fix"}
  ]
}
```

---

## Markers vocabulary

Standard markers across all bro files. Use them consistently — they signal status to future-you (or future Claude reading on /compact).

| Marker | Where | Meaning |
|---|---|---|
| `(sticky)` | `_principles.md` / `_thread.md` decisions | Append-only; supersede with note, don't rewrite |
| `(carried since YYYY-MM-DD)` | rules / vocabulary | Inherited from prior session, still valid; date = first appearance |
| `(reinforced YYYY-MM-DD)` | rules | Repeated for emphasis on this date |
| `(new YYYY-MM-DD)` | rules / vocabulary / decisions | Added on this date |
| `(refined YYYY-MM-DD)` | vocabulary terms | Definition updated on this date (latest definition wins) |
| `(consolidated YYYY-MM-DD from N source files)` | top of `_thread.md` after migration | Audit trail of migration |
| `(без изменений с YYYY-MM-DD)` | whole sections in daily | Anti-duplication signal |
| `(чтобы не возвращались)` | REJECTED items | Hard do-not-revisit; saves tokens on relitigation |
| `(P0)` … `(PN)` | design principles | Priority order |
| `(WAIT: <reason>)` | OPEN items | Blocked on external condition |
| `(parking-lot)` / `(deferred)` / `(YAGNI)` | items | Postponed; not actively in flight |
| `(stress-test #N: clean/found)` | verification artifacts | Test pass status |
| `(prototype-override)` | code-vs-canon gaps | Code is ahead of canon, temporarily acceptable |
| `(canon revision pending)` | canon gaps | Needs sync; flagged for owner |
| `(supersedes prior, dated YYYY-MM-DD)` | sticky decisions | Pivot replaces an earlier decision |
| `(renamed from {old-tag} since YYYY-MM-DD)` | top of daily file | Tag was renamed when chat title changed |
| `(observed in tags: foo, bar; carried since YYYY-MM-DD)` | `_principles.md` rules | Cross-tag deduplication source citation |

---

## Bilingual handling

The operator may work in any language (typically Russian + English mix). Rules:

- **Headers** are in English for predictable parsing across files (`## Operator state`, `### OPEN`, `### REJECTED`, `## Architecture`).
- **Optional secondary labels** in parentheses, where a Russian label adds clarity: `### REJECTED (чтобы не возвращались)`, `## Live threads (незавершённые разговоры)`, `## Shortcut vocabulary (выработанные в разговоре термины)`. Use sparingly, only where it captures a distinct nuance.
- **Operator's verbatim quotes** — preserve language as spoken. Do not translate or paraphrase. E.g., `> "груз отпал"`, `> "эта война нам не нужна"`.
- **Vocabulary terms** — preserve original. Russian idioms and operator-coined phrases stay in Russian. Define them in the language they were introduced.
- **Body content** — write in whichever language the operator was using in the relevant exchange. Bilingual mix within a section is fine (e.g., English structural framing with Russian idiomatic phrases).
- **Code, paths, URLs, commit hashes** — always in their original form, in backticks.

---

## Why bro exists

Assistants can't inspect their own context structurally — it's an architectural property of transformer models. The interpretation layer (what the conversation means) is ephemeral. Only input tokens, output tokens, and training weights persist across sessions.

bro externalizes that ephemeral interpretation into text while attention is still active on it. After `/compact`, reading `_principles.md` + `_thread.md` + today's daily file re-hydrates working understanding instead of starting from zero.

**Why three tiers, not one file?** Because operators don't write everything fresh every day. Project descriptors, git safety rules, architecture decisions, and shortcut vocabulary persist across sessions. Daily logs of "what we decided today" don't. Mixing them in one file means rewriting the persistent material every day (waste) or losing it (worse). Three tiers map onto three real timescales:

- `_principles.md` — repo-lifetime: project descriptor, sticky rules, universal discipline
- `_thread.md` — topic-lifetime: architecture, vocabulary, roadmap structure for this work
- `{date}.md` — session-lifetime: today's state, decisions, what changed

**Why tag from chat title + UUID postfix?** v2.0 derived tag from first user message. That works but produces low-quality tags when the first message is "let's do X" or contains stop-words. v2.1 reads the chat title (manual rename via UI takes priority over auto-generated AI title) — what operators see in the sidebar and reason about. UUID postfix guarantees uniqueness without depending on time-of-day heuristics that break for parallel chats started in the same minute.

**Why LLM-driven migration?** Old logs come in many forms — v1 single-file, v2.0 partial multi-tier, mixed bro/nerve, inconsistent markers. Regex parsers are brittle on this variety. LLM-driven semantic classification reads each file in context, recognizes recurring decisions across files, deduplicates, and writes faithful new-format output. It costs more tokens than regex but loses no nuance — operator's explicit constraint is *"на полную глубину без экономии ресурсов"*.

Formal docs capture **products** of work (the architecture spec, the API contract, the design system docs). bro captures **state of work in flight** — what you need to continue, not conclusions you've reached.
