---
description: Session continuity memory for Claude Desktop. Captures operator preferences, shortcut vocabulary, live threads, decisions, and design/code/investigation context in a daily markdown file per work thread — so context survives /compact resets.
---

# bro — session continuity memory

bro holds the middle layer of state that formal artifacts don't: mood, shortcut vocabulary, live threads, decisions, design tokens, debugging hypotheses, working-discipline rules. This layer is ephemeral in assistant attention but persistent if externalized.

---

## Step 0 — installation check (run once per invocation)

Check if this skill lives at the canonical path:

```bash
test -f ~/.claude/commands/bro.md && echo canonical || echo other
```

**If file IS at canonical path** → proceed to Step 0a.

**If file is NOT at canonical path** (copied somewhere else, or running inline):

Tell the user:

> I notice I'm not installed in the standard location. Claude Desktop auto-discovers skills from `~/.claude/commands/` — if I live there, `/bro` becomes a proper slash command available in every new chat, and updates are easier.
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
2. Read the installed version from the local `bro.md` frontmatter the same way (local path: `~/.claude/commands/bro.md`).
3. Compare:
   - **Different versions** → tell the user:
     > bro v{REMOTE} available (you have v{LOCAL}). Update? I can fetch it now — just say yes.
     
     If user confirms → run update flow (Section C).
     If user declines → proceed; re-check in 7 days.
   - **Same version** → silent, no interruption.
4. Regardless of outcome, write the current ISO timestamp to `lastVersionCheck` in config so we don't re-check for another 7 days.

**Network failure or curl error** → silent, skip check, don't block. Try again next time.

**Skip version check entirely** if env var `BRO_NO_UPDATE_CHECK=1` is set.

---

## Step 1 — argument routing

- Invoked with argument `setup` or `config` → go to **Section A** (configure storage).
- Invoked with argument `list` → go to **Section D** (list today's threads).
- Invoked with argument `update` → go to **Section C** (self-update).
- Invoked with argument in form `tag=<name>` or bare `<name>` (non-keyword) → go to **Section B** using `<name>` as tag.
- No argument → go to **Section B** with tag resolution per priority order.

---

## Section A — setup flow (change storage location)

1. Read `~/.claude/bro-config.json` if it exists. Show the user the current `storageDir` (or "not configured yet").
2. Ask: "Where should bro save memory files? You can use an absolute path, a tilde path, or a relative path."
3. Resolve the answer:
   - Expand `~` to `$HOME`
   - Resolve relative paths against current working directory
4. `mkdir -p <resolved path>` if directory missing
5. Write config:
   ```json
   {
     "storageDir": "<resolved absolute path>",
     "initialized": true
   }
   ```
6. Report: "bro will save to `<path>`."

---

## Section B — normal flow

### Step 1 — resolve storage directory

Read `~/.claude/bro-config.json`:

- **Exists with `initialized: true`** → use `storageDir`, proceed to Step 2.
- **Missing or `initialized` false** → run first-time setup (Step 1a).

### Step 1a — first-time setup

Ask:

> Hey — first time running bro. Where should memory files be stored?
>
> 1. `.claude/bro/` — per-project (stored in current working directory; recommended)
> 2. `~/.claude/bro/` — global (all projects in one place)
> 3. Custom path — you specify
> 4. Skip — use option 1 as default
>
> Pick 1–4 or type a path.

Based on answer:
- `1` → `.claude/bro/` relative to cwd
- `2` → `~/.claude/bro/`
- `3` or direct path → their input
- `4` or empty → default to option 1

Resolve to absolute path. Create directory. Save config. Continue to Step 2.

### Step 2 — resolve thread tag and determine today's file

**Thread structure:** bro uses a **folder-per-thread** layout so parallel work streams don't collide in one file:

```
{storageDir}/
├── {thread-tag-1}/
│   ├── 2026-04-20.md
│   └── 2026-04-21.md
├── {thread-tag-2}/
│   └── 2026-04-20.md
└── default/
    └── 2026-04-20.md          ← if no tag provided
```

**Tag resolution priority (highest wins):**

1. **Explicit argument** — if user invoked `/bro <tag>` or `/bro tag=<tag>` → use `<tag>`.
2. **Env var** — if `BRO_TAG` is set in environment → use its value.
3. **Recent-file heuristic** — scan `{storageDir}/*/` for files modified in the last 2 hours. If exactly one match → use that thread-tag (continuation). If multiple → ask user to pick.
4. **Interactive** — if existing threads exist for today (`{storageDir}/*/2026-04-20.md`), show the list and ask: "Continue one of these threads or create new? (1, 2, ... or type a new tag name)".
5. **Fallback** — if no existing threads or user skipped → tag = `default`.

**Tag normalization:** lowercase, spaces → dashes, strip special chars. E.g. `"Bro Plugin Work"` → `bro-plugin-work`.

**Compute file path:**
```
{storageDir}/{resolved-tag}/{YYYY-MM-DD}.md
```

Create the tag folder if it doesn't exist: `mkdir -p {storageDir}/{tag}/`.

### Step 3 — create or update

- **File does not exist** → create from template (see Template section below).
- **File exists** → review the last 3–7 exchanges, add material to relevant sections only.

### Step 4 — decide which sections to include

**Always include:**
- Operator state
- Live threads
- Current mode
- Read-first instruction

**Include contextual sections only when there's real material:**

| Section | Include when |
|---|---|
| Shortcut vocabulary | new terms/metaphors introduced |
| People in context | specific names referenced |
| Architecture decisions | code/system choices made |
| Design decisions | UX/visual choices made |
| Design tokens & conventions | system values locked in |
| Interaction patterns | behavior rules established |
| User behavior observations | field notes from testing/analytics |
| Investigation state | actively debugging/researching |
| Assumptions to verify | unverified hypotheses exist |
| Blockers / waiting on | progress depends on external input |
| Environment & setup | non-standard setup quirks |
| File / module map | navigation aid in large codebase |
| References | external links matter for continuity |
| Working discipline | methodology rules operator established |
| Meta-insights | insight about the work itself emerged |

**Empty sections are removed, not left as placeholders.**

### Step 5 — report

- File path (created or updated)
- Thread tag used
- Sections changed or added
- If nothing new worth writing → say so, skip the write

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
   ```
4. Atomic swap:
   ```bash
   mv ~/.claude/commands/bro.md.new ~/.claude/commands/bro.md
   ```
5. Update config `~/.claude/bro-config.json`:
   - Set `installedVersion` to new version
   - Set `lastVersionCheck` to current ISO timestamp
6. Report:
   > Updated to v{NEW_VERSION}. Restart Claude Desktop (or start a new chat) to load the new version.

**If curl fails or version check fails** → report clearly: "Update failed: {reason}. You're still on v{current}. Try again later or update manually: `curl -o ~/.claude/commands/bro.md https://raw.githubusercontent.com/balaka/bro/main/bro.md`"

---

## Section D — list today's threads

Invoked via `/bro list`.

1. Resolve storage directory from config (same as Section B Step 1).
2. Find all today's thread files:
   ```bash
   find {storageDir} -maxdepth 2 -name "{YYYY-MM-DD}.md" -type f
   ```
3. For each file, extract the tag (parent folder name) and last-modified time.
4. Display:

```
Today's bro threads in {storageDir}:

  📝 bro-plugin     updated 12m ago   (3 sections)
  📝 xovi-scoring   updated 2h ago    (5 sections)
  📝 default        updated 5h ago    (1 section)

Total: 3 threads.
Run /bro <tag> to continue a specific thread, or /bro to pick interactively.
```

5. If no threads today → say "No bro threads created today yet. Run `/bro` to start."

---

## Template

````markdown
# bro — {YYYY-MM-DD}

- instance of: bro memory (middle-layer state between raw transcript and formal docs)
- purpose: capture what would otherwise need re-explaining after /compact
- test: "would I have to explain this again?" → yes → belongs here
- read order on /compact: THIS FILE FIRST

## Operator state

{Mood, fatigue signals, preferences. 2–5 bullets.}

## Live threads

### OPEN
- {In progress / paused / waiting}

### DECIDED {date}
- {Decisions made, possibly not yet in formal docs}

### REJECTED
- {Options explicitly rejected — not to resurface}

## Current mode

{e.g., ad-hoc discussion / active debugging / design system work / feature implementation}

---

<!-- Contextual sections below — include only when there's material -->

## Shortcut vocabulary

- **Term** — meaning. (Who + when)

## People in context

- **Name** — role, relevance to current thread

## Architecture decisions

### {Decision name}
- Chose: ...
- Over: ...
- Because: ...
- Revisit if: ...

## Design decisions

### {Decision name}
- Chose: ...
- Over: ...
- Because: ...
- Revisit if: ...

## Design tokens & conventions

- Spacing: ...
- Typography: ...
- Colors: ...
- Radius: ...
- Breakpoints: ...
- Motion: ...
- Class naming: ...

## Interaction patterns

- Loading states: ...
- Empty states: ...
- Error states: ...
- Hover: ...
- Focus: ...
- Disabled: ...

## User behavior observations

- {Field notes from testing, analytics, or interviews}

## Investigation state

- Current hypothesis: ...
- Checked (clean): ...
- Checked (found): ...
- Not yet checked: ...
- Next probe: ...

## Assumptions to verify

- {Unverified hypotheses}

## Blockers / waiting on

- {External dependencies}

## Environment & setup

- {Non-standard requirements — versions, secrets, local config}

## File / module map

- `path/to/file` — relevance

## References

- {External links — tickets, docs, PRs}

## Working discipline

### Before {action type}
- {Rule 1}
- {Rule 2}

## Meta-insights

- {Insights about methodology or architecture of the work itself}

---

## Read-first instruction for post-compact

> Read this file first. Check Live threads — continue from there.
> Next reads: {specific artifacts relevant to current work}
````

---

## Why bro exists

Assistants can't inspect their own context structurally — it's an architectural property of transformer models. The interpretation layer (what the conversation means) is ephemeral. Only input tokens, output tokens, and training weights persist across sessions.

bro externalizes that ephemeral interpretation into text while attention is still active on it. After `/compact`, reading the bro file re-hydrates working understanding instead of starting from zero.

Formal docs capture **products** of work. bro captures **state of work in flight** — what you need to continue, not conclusions you've reached.
