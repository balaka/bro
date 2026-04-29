---
description: Session continuity memory for Claude Desktop / Claude Code. Stores persistent context (project descriptor, sticky rules, architecture, vocabulary) per repo, plus ephemeral daily logs per chat thread. Auto-resolves thread tag from chat's first user message + session UUID, so parallel chats in the same folder don't collide. Three-tier layout — repo-wide _principles.md, thread-wide _thread.md, daily {date}.md.
---

# bro — session continuity memory

bro holds the middle layer of state that formal artifacts don't: mood, shortcut vocabulary, live threads, decisions, design tokens, debugging hypotheses, working-discipline rules. This layer is ephemeral in assistant attention but persistent if externalized.

**v2 architecture:** logs live **per-repo** (not centralized), in a **three-tier layout** that separates repo-wide universals (`_principles.md`), thread-wide stable context (`{tag}/_thread.md`), and daily ephemeral state (`{tag}/{date}.md`). Parallel chats in the same folder get distinct tags automatically — derived from each chat's first user message plus session UUID for collision safety.

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
     > **Note:** if this is a major bump (e.g., v1.x → v2.x), the storage layout may have changed. v2 stores per-repo (not centralized). Existing v1 logs stay where they are; v2 starts fresh in each repo.

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
- Argument in form `tag=<name>` or bare `<name>` (non-keyword) → **Section B** with `<name>` as explicit tag.
- No argument → **Section B** with auto-resolved tag.

---

## Section A — setup flow (storage location for this repo)

v2 stores **per-repo**. Each repo picks its own location. Default is **visible** (`{cwd}/bro/`) so logs are inspectable, searchable, and reviewable.

### Step 1 — show current state

```bash
# Detect existing storage in this repo
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

> Found legacy v1 storage at `{LEGACY}`. v2 stores per-repo. Old logs stay where they are — no auto-migration. Pick a new location for this repo below.

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

### Step 2 — resolve thread tag (auto-detection from chat)

#### 2a. Find current session UUID

```bash
ENCODED_CWD=$(pwd | sed 's|/|-|g')
PROJ_DIR="$HOME/.claude/projects/$ENCODED_CWD"
SESSION_JSONL=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
SESSION_UUID=$(basename "$SESSION_JSONL" .jsonl 2>/dev/null)
```

If no jsonl found (Claude Desktop without Code, edge case):
- Fallback `SESSION_UUID="$(date +%Y%m%d-%H%M%S)"` and `FIRST_MSG="chat-$(date +%H%M)"`

#### 2b. Check session marker (continuation of same chat)

```bash
SESSIONS_DIR="$HOME/.claude/bro-sessions"
mkdir -p "$SESSIONS_DIR"
MARKER_FILE="$SESSIONS_DIR/$SESSION_UUID.tag"

if [ -f "$MARKER_FILE" ]; then
  TAG=$(cat "$MARKER_FILE")
  # Same chat continuing; skip to Step 3
fi
```

#### 2c. Determine tag for new chat

If explicit argument provided (`/bro <tag>` or `/bro tag=<name>`):
```bash
TAG=$(echo "$ARG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zа-я0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
```

Otherwise — derive from chat's first user message:

```bash
# Extract first user message from session jsonl
FIRST_MSG=$(grep -m1 '"operation":"enqueue"' "$SESSION_JSONL" 2>/dev/null \
  | jq -r '.content // empty' 2>/dev/null \
  | head -c 200)

# Slugify with cyrillic preservation (use python3 if bash unicode is unreliable)
SLUG=$(python3 -c "
import re, sys
msg = '''$FIRST_MSG'''.lower().strip()
words = re.findall(r'[a-zа-я0-9]+', msg)
slug = '-'.join(words[:5])[:40].rstrip('-')
print(slug)
" 2>/dev/null)

# Fallback if extraction failed or slug too short
if [ -z "$SLUG" ] || [ ${#SLUG} -lt 3 ]; then
  SLUG="chat-$(date +%H%M)"
fi
```

#### 2d. Collision check

```bash
if [ -d "$STORAGE/$SLUG" ]; then
  EXISTING_UUID=$(jq -r '.sessionUuid // empty' "$STORAGE/$SLUG/.session.json" 2>/dev/null)
  if [ "$EXISTING_UUID" = "$SESSION_UUID" ]; then
    TAG="$SLUG"  # same chat reopened; reuse
  else
    # collision: another chat already owns this name
    SHORT="${SESSION_UUID:0:6}"
    TAG="$SLUG-$SHORT"
  fi
else
  TAG="$SLUG"
fi
```

#### 2e. Commit tag

```bash
mkdir -p "$STORAGE/$TAG"

# Write session marker inside tag folder
cat > "$STORAGE/$TAG/.session.json" <<EOF
{
  "sessionUuid": "$SESSION_UUID",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "firstMessage": "$(echo "$FIRST_MSG" | head -c 100 | tr '\n' ' ')"
}
EOF

# Save mapping for fast continuation
echo "$TAG" > "$MARKER_FILE"
```

**Edge case — first message is `/bro` itself (recursion):** scan further into jsonl for the next `enqueue` event whose content doesn't start with `/`. If none found within first 20 entries → fallback to `chat-{HHMM}`.

### Step 3 — read existing files

Before writing anything, load context:

1. **`$STORAGE/_principles.md`** — repo-wide persistent (universal context, descriptor, sticky rules)
2. **`$STORAGE/$TAG/_thread.md`** — thread-wide persistent (architecture, vocabulary, roadmap for this work topic) — may not exist yet
3. **`$STORAGE/$TAG/{YYYY-MM-DD}.md`** — today's daily ephemeral — may not exist yet

These files tell us **what's already captured**, so we don't duplicate.

### Step 4 — classify new material from recent conversation

Review the last 5–7 exchanges. For each piece of new material, run two tests:

**Test 1 — temporal:**
> If a fresh chat opens in this repo tomorrow, would this still be true / relevant?

- **YES** → persistent (_principles.md or _thread.md)
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
| "Term 'трек' = 3-line headline structure" | `_thread.md` → Shortcut vocabulary |
| "Decided: use SQLite, not Postgres" (today) | daily → DECIDED + ASK promote to `_thread.md` |
| "No Figma" (rejected today, hard) | daily → REJECTED (чтобы не возвращались) |
| "P0: no internal jargon leaks" | `_thread.md` → Design principles |
| "stripUndefined helper — don't remove" | `_thread.md` → Known subtleties / gotchas |

### Step 5 — interactive promotion prompts (when uncertain)

When material looks persistent but it's not 100% clear, **ask the operator** before cementing it.

**One promotion ask per /bro invocation, max.** Don't spam. Batch related items.

Format:

> Promote to persistent? I noticed a few candidates:
>
> 1. *"Storage is per-repo, not centralized"* — looks like architecture decision → `_thread.md`?
> 2. *"Auto mode active, minimize interruptions"* — looks like working discipline → `_principles.md`?
>
> y / n / pick (e.g., "1 only", "1 to thread, 2 skip")

**Don't ask** for material that's unambiguously ephemeral (operator state, daily decisions with explicit dates) — write directly to daily.

**Don't ask** for material that's already in persistent files — just skip.

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

📜 _principles.md — added: Sticky rules ("no --amend")
📂 {tag}/_thread.md — created: Architecture (3 decisions), Vocabulary (4 terms)
📝 {tag}/{date}.md — updated: Operator state, Live threads OPEN, REJECTED

Tag: {tag}
  Source: first message — "{first 60 chars}..."
  Session: {short UUID}
  Marker: {STORAGE}/{tag}/.session.json
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
   > v2 stores per-repo (not centralized) and uses three-tier layout (`_principles.md` + `_thread.md` + daily). Existing v1 logs at the old global location stay where they are — v2 starts fresh in each repo via `/bro setup`.
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
   > Updated to v{NEW_VERSION}. Restart Claude Desktop (or open a new chat) to load the new version. Run `/bro setup` in any repo on first use to pick a storage location.

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
4. For each daily file, read marker (`{tag}/.session.json`) for `firstMessage`.
5. Display:

```
bro storage for this repo: {STORAGE}

Persistent:
  📜 _principles.md          updated 5d ago    (8 sections)
  📜 fix-auth-bug/_thread.md updated 2d ago    (4 sections)

Today's daily threads:
  📝 я-сделал-плагин-бро     updated 12m ago   from: "я сделал плагин бро, и нерв но они..."
  📝 fix-the-auth-bug        updated 2h ago    from: "fix the auth bug in login flow"
  📝 fix-the-auth-bug-a3f1c0 updated 5h ago    from: "fix the auth bug — second look"

Total: 3 daily threads, 1 thread-context file, 1 principles file.

Run /bro <tag> to continue a specific thread, /bro to auto-resolve from current chat.
```

If no daily threads today → say "No bro threads created today in this repo. Run `/bro` to start."

---

## Templates

### `_principles.md` (repo-wide universal)

```markdown
# bro principles — {repo-name}

> Persistent context for this repo. Read on /compact and on first entry to a new chat.
> Updated rarely. Items here apply to ALL work threads in this repo.

## Project descriptor

- name: {project name}
- repo: {git URL}
- local path: `{cwd}`
- main branch: {branch}
- deploy branch: {if applicable}
- first canonical commit: {if known}

## Sticky rules (git / code safety / process)

- {Hard rule}
- {Hard rule}

## Working discipline (universal)

[Numbered rules with optional markers like (carried since YYYY-MM-DD), (reinforced YYYY-MM-DD)]

1. {Rule}
2. {Rule}

## People in context (cross-thread)

- **Name** — role, relevance across multiple threads
```

### `{tag}/_thread.md` (thread-wide stable)

```markdown
# bro thread context — {tag}

> Stable context for this work topic. Updated rarely. Read after `_principles.md` on /compact.
> Items here apply to THIS thread's work topic.

## Architecture (sticky)

### {Decision name}
- Chose: ...
- Over: ...
- Because: ...
- Revisit if: ...

## Design principles

[Numbered with priority — P0 most important]

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

1. {Question}
2. {Question}

## Known subtleties / gotchas

- {Tribal knowledge that's easy to forget — e.g., "gray-matter doesn't serialize undefined; stripUndefined helper required"}

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
# bro — {YYYY-MM-DD} / {tag}

- thread: {tag}
- workspace: {cwd}
- branch: {git branch} (if code work)
- previous bro: ./{prev-date}.md (if exists in this thread)
- nerve: {path} (if applicable)
- continues from: {if non-trivial gap}
- dominant theme today: {one-line summary}
- read order on /compact:
  1. THIS FILE FIRST
  2. ../_principles.md
  3. _thread.md (if exists)
  4. {specific files for current task}

---

## Operator state

[Today's energy, mode, mood markers; what changed from prior sessions]

## Live threads

### OPEN

- {Carried from prior days + new today; explicit status `Pending: ...` / `Waiting on: ...` / `Status: paused`}

### DECIDED — {topic 1}

- {Today's decisions for this topic}

### DECIDED — {topic 2}

- {Decisions on a different topic, group by topic within the day}

### REJECTED (чтобы не возвращались)

- {Hard do-not-revisit; with rationale}

---

<!-- Optional sections — added when material exists -->

## Что произошло сегодня (Session arc)

[Numbered narrative phases — 2-5 phases; for sessions with significant flow]

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

- {other thread name in this repo}: {state of that thread}

## Next steps (post-compact)

1. ...
2. ...
```

---

## Markers vocabulary

Standard markers across all bro files. Use them consistently — they signal status to future-you (or future Claude reading on /compact).

| Marker | Where | Meaning |
|---|---|---|
| `(sticky)` | `_principles.md` / `_thread.md` decisions | Append-only; supersede with note, don't rewrite |
| `(carried since YYYY-MM-DD)` | rules / vocabulary | Inherited from prior session, still valid |
| `(reinforced YYYY-MM-DD)` | rules | Repeated for emphasis on this date |
| `(new YYYY-MM-DD)` | rules / vocabulary / decisions | Added on this date |
| `(без изменений с YYYY-MM-DD)` | whole sections in daily | Anti-duplication signal |
| `(чтобы не возвращались)` | REJECTED items | Hard do-not-revisit; saves tokens on relitigation |
| `(P0)` … `(PN)` | design principles | Priority order |
| `(WAIT: <reason>)` | OPEN items | Blocked on external condition |
| `(parking-lot)` / `(deferred)` / `(YAGNI)` | items | Postponed; not actively in flight |
| `(stress-test #N: clean/found)` | verification artifacts | Test pass status |
| `(prototype-override)` | code-vs-canon gaps | Code is ahead of canon, temporarily acceptable |
| `(canon revision pending)` | canon gaps | Needs sync; flagged for owner |
| `(supersedes prior, dated YYYY-MM-DD)` | sticky decisions | Pivot replaces an earlier decision |

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

Formal docs capture **products** of work (the architecture spec, the API contract, the design system docs). bro captures **state of work in flight** — what you need to continue, not conclusions you've reached.
