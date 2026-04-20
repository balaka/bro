# bro — your chat holds the thread

Lightweight session continuity for Claude Desktop. Captures conversation state so your context survives `/compact` resets.

---

## Why bro exists

`/compact` wipes the middle layer of a conversation — your tone preferences, the shortcuts you invented, the options you rejected, the rules you taught Claude over hours of work.

Formal docs don't capture this. Raw transcripts are too dense to re-read.

bro writes a small markdown file per day that captures exactly this middle layer. After `/compact`, Claude reads the file first and picks up where you left off.

---

## What bro remembers

- Your mood, preferences, and fatigue markers
- Shortcut vocabulary you introduced
- People referenced in context
- Live threads — OPEN / DECIDED / REJECTED
- Architecture & design decisions (with rationale)
- Design tokens & interaction patterns
- Investigation state mid-debug
- Assumptions to verify
- Blockers you're waiting on
- Environment quirks (versions, secrets, local config)
- File / module map for navigation
- Working discipline — rules you taught Claude
- Meta-insights about the work itself

Only the sections that have real material. Empty sections don't clutter the file.

---

## Real-world examples

### Example 1 — "Did you actually check?"

```
You: "This library's docs are probably outdated."
Claude (fresh session): builds solution on assumed behavior.
You: Have you actually checked the changelog?
Claude: ...no.
You: Check.
Claude: [checks] Oh. Two breaking changes in v3. My code used v2 API.
```

**Without bro**, after `/compact` — Claude confidently asserts stuff again. Same loop.

**With bro:**

```markdown
## Operator state
- Treats assumptions as hypotheses, not facts. Verification required before action.

## Working discipline
- Before non-trivial claims: state "what I know" vs "what I'm guessing" explicitly
- If guessing → verify via source before committing
```

Claude stops pretending guesses are facts.

---

### Example 2 — "Don't resurface what we rejected"

Over a long session you rejected three options — each with a nickname:

```markdown
## Shortcut vocabulary
- "Card-in-card" — double-wrapped layout we rejected (adds visual noise)
- "Pipe headline" — multi-claim pipe-separated format (feels generic)
- "Deep-nest drawer" — 3+ level navigation inside drawer (usability bad)

## REJECTED
- Card-in-card layout — rejected earlier this week
- Pipe headline format — rejected after testing alternatives
- Deep-nest drawer — rejected during user testing
```

**Without bro**, after `/compact`: Claude cheerfully proposes card-in-card again. You groan, explain again, reject again.

**With bro**: Claude sees these are closed doors. No relapse, no re-litigation.

---

### Example 3 — Fatigue markers

Your marker for "I'm tired of dense explanations" is the phrase **"this is getting long"** — or any distinctive signal you use.

```markdown
## Operator state
- Tires of verbose synthesis — switch to conversational tone on cue
- Fatigue marker: "this is getting long" → simplify immediately
- Prefers short bullets over walls of prose
```

**Without bro**, every new chat starts with walls of formal text. You re-explain your preferences for the fifth time.

**With bro**: Claude adapts from hello, in the register you prefer.

---

### Example 4 — Working discipline (methodology, not data)

The killer feature for technical work. bro remembers **rules you taught Claude**, not just facts.

```markdown
## Working discipline

### Before component port
- List all nested layers (children, slots, snippets)
- Ask: "top layer only, or all the way down?"
- Default if no answer: work to leaf

### Before data model change
- Re-read the relevant spec doc first
- Cross-reference with governing canon
- If conflict: articulate it, ask operator

### Pre-action self-check
- State in one sentence: "what should logically be here"
- State in one sentence: "what state this edit creates"
- If these don't match → stop, ask
```

**Without bro**, after `/compact`: Claude loses all discipline. Charges into edits without checking specs. Ports components shallow. You re-teach the same rules.

**With bro**: Claude reads the discipline section first thing. Rules stick across sessions.

---

## Install

### One-liner (quickest)

```bash
mkdir -p ~/.claude/commands && \
  curl -o ~/.claude/commands/bro.md \
  https://raw.githubusercontent.com/balaka/bro/main/bro.md
```

Restart Claude Desktop → `/bro` is available.

### Or via git clone (for easy updates)

```bash
git clone https://github.com/balaka/bro.git ~/Projects/bro
ln -s ~/Projects/bro/bro.md ~/.claude/commands/bro.md
```

To update later:

```bash
cd ~/Projects/bro && git pull
```

---

## Usage

| Command | What it does |
|---|---|
| `/bro` | Update today's memory file for the current thread (auto-detects or asks) |
| `/bro <tag>` | Update/create memory file for a named thread — e.g. `/bro api-refactor` |
| `/bro list` | Show today's threads and when each was last updated |
| `/bro setup` | Change storage location |
| `/bro update` | Pull the latest bro version from GitHub |
| `bro, recall today` (natural language) | After `/compact` — reads the relevant thread file back into context |

bro also checks for updates automatically once per week and offers to pull new versions — silent if you're already current, non-blocking if GitHub is unreachable. Disable with `BRO_NO_UPDATE_CHECK=1` in your environment.

---

## Thread folders — one folder per work stream

bro uses a **folder-per-thread** layout. Parallel work streams don't collide:

```
.claude/bro/
├── api-refactor/
│   ├── 2026-04-18.md
│   ├── 2026-04-19.md
│   └── 2026-04-20.md         ← today's memory for this thread
├── design-system/
│   └── 2026-04-20.md         ← separate today's memory for design work
└── default/
    └── 2026-04-20.md         ← if you didn't specify a tag
```

Why: a single day often spans multiple contexts — you debug an API bug in the morning, design tokens in the afternoon. Mixing both in one file turns post-`/compact` reads into a mess. Folders keep each thread clean and let you read the full history of a single topic by listing the folder.

**Thread tag resolution** (in priority order):

1. Explicit — `/bro design-system` or `/bro tag=design-system`
2. Env var — `export BRO_TAG=design-system` in your shell / direnv
3. Recent activity — if exactly one thread was updated in the last 2 hours, bro continues it
4. Interactive — bro shows existing threads and asks which to continue
5. Fallback — `default` folder

---

## First run

On first `/bro`, the skill asks where to store memory files:

```
1. .claude/bro/      — per-project (recommended)
2. ~/.claude/bro/    — global
3. Custom path
4. Skip (uses option 1)
```

Pick once — remembered afterwards. Change anytime with `/bro setup`.

---

## After /compact

Just tell the chat: **"bro, recall today"** — Claude lists today's threads and reads the right one. Or explicitly:

```
Read ~/.claude/bro/<thread>/2026-04-20.md
```

Working context re-hydrated. Continue where you stopped.

---

## Self-install

If you got `bro.md` some other way (forwarded by a friend, downloaded somewhere weird) — just run `/bro` once. The skill detects it's not in the standard location and offers to install itself properly.

---

## Safety

bro is a markdown file, not executable code. It contains instructions for Claude, which runs within its normal safety boundaries.

Before installing, you can open `bro.md` and read it — it's plain text describing what Claude should do.

---

## How it works technically

Claude Desktop auto-discovers markdown files in `~/.claude/commands/`. Each file becomes a slash command matching its filename (`bro.md` → `/bro`).

`bro.md` contains:
- YAML frontmatter (description — so Claude knows what the skill does)
- Logic (how to create/update memory files)
- Template (structure of the memory file)
- Explanation (why the protocol exists)

When you run `/bro`, Claude reads the skill file and executes the instructions — checking where to save, loading or creating today's file, updating sections based on recent conversation.

---

## Storage root

The folder that contains all your thread folders. Pick once on first run:

| Option | Path | When to use |
|---|---|---|
| Per-project | `.claude/bro/` (relative to cwd) | Separate memory per project |
| Global | `~/.claude/bro/` | One place for all work |
| Custom | Any path you choose | You know what you want |

Thread folders live inside this root (`<root>/<thread>/<date>.md`). Change root anytime with `/bro setup` — existing files don't move automatically.

---

## Auto-update

bro checks GitHub for a new version once per week. If a new version exists, it tells you and offers to pull — non-blocking if you're offline or busy.

- Manual update: `/bro update`
- Disable weekly check: `export BRO_NO_UPDATE_CHECK=1` in your shell

After updating, restart Claude Desktop (or open a new chat) to load the new skill version.

---

## Changelog

- **v1.1.0** — folder-per-thread layout (parallel work streams no longer collide); `/bro list`, `/bro <tag>`, `/bro update`; weekly version check
- **v1.0.0** — initial release

---

## Why "bro"

Because that's literally what it does. Your chat remembers what you talked about and brings it back when you need it. Like a bro.

---

## License

MIT — see [LICENSE](./LICENSE)

## Author

Yuriy Balaka ([@balaka](https://github.com/balaka))
