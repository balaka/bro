# bro — your chat holds the thread

[![Version](https://img.shields.io/badge/version-2.0.0-blue)](https://github.com/balaka/bro)
[![GitHub stars](https://img.shields.io/github/stars/balaka/bro?style=social)](https://github.com/balaka/bro/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Claude Desktop](https://img.shields.io/badge/Claude-Desktop-D97757)](https://claude.ai/download)

**Session continuity memory for Claude Desktop / Claude Code.** Captures what `/compact` wipes — your preferences, vocabulary, decisions, rejected options, design tokens, debugging hypotheses, and rules you taught Claude. Stores **per-repo** in a three-tier layout that separates persistent context (project descriptor, sticky rules, architecture, vocabulary) from ephemeral daily state. Parallel chats in the same folder don't collide — each gets its own thread automatically.

## Install (30 seconds)

```bash
mkdir -p ~/.claude/commands && \
  curl -o ~/.claude/commands/bro.md \
  https://raw.githubusercontent.com/balaka/bro/main/bro.md
```

Restart Claude Desktop → type `/bro` in any chat. Done.

---

## Why bro exists

`/compact` wipes the middle layer of a conversation — your tone preferences, the shortcuts you invented, the options you rejected, the rules you taught Claude over hours of work.

Formal docs don't capture this. Raw transcripts are too dense to re-read.

bro writes small markdown files that capture exactly this middle layer. After `/compact`, Claude reads them first and picks up where you left off.

---

## What bro remembers

**Persistent (across sessions, repo-wide or thread-wide):**
- Project descriptor (repo URL, paths, branches)
- Sticky rules — git/code safety, hard process constraints
- Working discipline — methodology rules you taught Claude
- Architecture decisions with `Chose / Over / Because / Revisit if`
- Design principles, ranked
- Shortcut vocabulary — terms and idioms you introduced
- Roadmap structure (status updates flow into daily logs)
- Known subtleties / gotchas — tribal knowledge
- File / module map for navigation
- People in context

**Ephemeral (rewritten or accumulated per day):**
- Operator state, mood, fatigue markers
- Live threads — OPEN / DECIDED / REJECTED (`чтобы не возвращались`)
- What happened today (session arc)
- Roadmap status changes
- Canon gaps surfaced today
- Investigation state mid-debug
- Outputs this session (commits, reports, canon docs)
- "Не сделано сегодня" (deferred items with reason)
- Meta-insights (candidates for promotion to persistent)
- Cross-thread links

Only sections with material are written. Empty sections don't clutter the file.

---

## Three-tier architecture

```
{cwd}/bro/                                  ← visible in repo root (or .claude/bro/ if hidden)
├── .gitignore                              ← ignores own contents by default
├── _principles.md                          ← REPO-WIDE persistent (universal context)
└── {thread-tag}/
    ├── .session.json                       ← session marker for collision safety
    ├── _thread.md                          ← THREAD-WIDE persistent (this work topic)
    └── 2026-04-29.md                       ← DAILY ephemeral
```

**Why three tiers?** Daily files used to bloat with persistent content copy-pasted day after day. v2 splits that out — `_principles.md` is written once for the repo (project descriptor, git rules), `_thread.md` per work topic (architecture, vocabulary, roadmap), and daily files contain only what changed. After `/compact`, Claude reads in order: principles → thread → today.

---

## Real-world examples

### Example 1 — "Don't resurface what we rejected"

Over a long session you rejected three options — each with a nickname:

```markdown
## Shortcut vocabulary  (in _thread.md)
- "Card-in-card" — double-wrapped layout (adds visual noise)
- "Pipe headline" — multi-claim pipe-separated format (feels generic)

## REJECTED (чтобы не возвращались)  (in today's daily)
- Card-in-card layout — rejected after testing alternatives
- Pipe headline format — rejected during user testing
```

**Without bro**, after `/compact`: Claude cheerfully proposes card-in-card again. You groan, explain again, reject again.

**With bro**: Claude sees these are closed doors. The `(чтобы не возвращались)` marker is hard — no relapse, no re-litigation.

---

### Example 2 — Working discipline (rules, not data)

The killer feature for technical work. bro remembers **rules you taught Claude**.

```markdown
## Working discipline (universal)  (in _principles.md)

1. Never --amend (always new commits)
2. Push to main requires explicit operator authorization

## Working discipline  (in _thread.md, topic-specific)

### Before component port
- List all nested layers (children, slots, snippets)
- Ask: "top layer only, or all the way down?"

### Before data model change
- Re-read the relevant spec doc first
- Cross-reference with governing canon
```

**Without bro**, after `/compact`: Claude loses all discipline. Charges into edits without checking specs. Ports components shallow. You re-teach the same rules.

**With bro**: Discipline persists. Rules carry across sessions with `(carried since YYYY-MM-DD)` markers showing they're still current.

---

### Example 3 — Parallel chats in one repo

You have two chats open in the same folder — one debugging auth, one redesigning onboarding. Without isolation, they'd write to the same thread file and overwrite each other.

bro derives a tag from each chat's first user message and disambiguates with session UUID:

```
{cwd}/bro/
├── _principles.md
├── fix-the-auth-bug/
│   ├── .session.json   (sessionUuid: 9e09887...)
│   └── 2026-04-29.md
└── redesign-onboarding/
    ├── .session.json   (sessionUuid: a3f1c0b...)
    └── 2026-04-29.md
```

If both chats start with the same first message, the second gets a UUID-suffix tag (`fix-the-auth-bug-a3f1c0`) — collision-safe.

---

### Example 4 — Promotion ephemeral → persistent

You're discussing architecture. Claude offers to promote a sticky decision:

```
> Promote to persistent? I noticed:
>
> 1. "Storage is per-repo, not centralized" — looks like architecture decision → _thread.md?
> 2. "Auto mode active, minimize interruptions" — looks like working discipline → _principles.md?
>
> y / n / pick
```

Interactive — you decide. Discipline against cementing one-off remarks as repo-wide laws.

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
| `/bro` | Update memory for the current chat (auto-resolves tag from chat's first message) |
| `/bro <tag>` | Use explicit tag — e.g. `/bro api-refactor` |
| `/bro list` | Show today's threads + persistent files in this repo |
| `/bro setup` | Configure storage location for this repo |
| `/bro update` | Pull the latest bro version from GitHub |
| `bro, recall today` (natural language) | After `/compact` — reads back the relevant files |

bro also checks for updates automatically once per week and offers to pull new versions — silent if you're already current, non-blocking if GitHub is unreachable. Disable with `BRO_NO_UPDATE_CHECK=1` in your environment.

---

## Tag auto-resolution

When you run `/bro` without an argument, the tag is derived from your chat:

1. **Same chat continuing** — session marker remembers the tag from a prior `/bro` in this chat. Reused as-is.
2. **New chat, no explicit tag** — bro reads the first user message in this chat from Claude Code's session log, slugifies the first 5 words (preserving Cyrillic), and uses that as the tag.
3. **Collision check** — if the tag folder already exists with a different session UUID, the new chat gets a UUID suffix (`fix-auth-bug-a3f1c0`).
4. **Explicit override** — `/bro <tag>` always wins.
5. **Fallback** — if first message can't be extracted, defaults to `chat-{HHMM}`.

Tags are stable for a chat's lifetime via `~/.claude/bro-sessions/{uuid}.tag` mapping.

---

## First run

On first `/bro` in a repo, the skill asks where to store memory files:

```
Where to store memory for this repo?

1. {cwd}/bro/         — visible in repo root (recommended for analysis & review)
2. {cwd}/.claude/bro/ — hidden inside .claude/
3. Custom path

Pick 1-3 or type a path.
```

Default is **(1) visible**, so you can read, search, and analyze your logs alongside your code.

A `.gitignore` is added to the chosen folder that ignores all contents by default. If you want to commit `_principles.md` or `_thread.md` files (e.g., to share repo-wide context with the team), uncomment the relevant lines in that gitignore.

Change location anytime with `/bro setup`.

---

## After /compact

Just tell the chat: **"bro, recall today"** — Claude lists today's threads and reads them in tier order. Or explicitly:

```
Read bro/_principles.md, bro/<tag>/_thread.md, bro/<tag>/2026-04-29.md
```

Working context re-hydrated. Continue where you stopped.

---

## Markers

bro uses a vocabulary of parenthetical markers consistently across files:

| Marker | Where | Meaning |
|---|---|---|
| `(sticky)` | persistent decisions | Append-only; supersede with note, don't rewrite |
| `(carried since YYYY-MM-DD)` | rules / vocabulary | Inherited from prior session, still valid |
| `(reinforced YYYY-MM-DD)` | rules | Repeated for emphasis |
| `(new YYYY-MM-DD)` | new items | Added today |
| `(чтобы не возвращались)` | REJECTED items | Hard do-not-revisit |
| `(WAIT: <reason>)` | OPEN items | Blocked on external condition |
| `(parking-lot)` / `(deferred)` / `(YAGNI)` | items | Postponed |
| `(supersedes prior, dated YYYY-MM-DD)` | sticky decisions | Pivot replaces earlier decision |

---

## Bilingual handling

bro is built for operators who work bilingually (e.g., Russian + English):

- **Headers** stay in English for predictable parsing.
- **Operator verbatim quotes** — preserved as spoken, no translation: `> "груз отпал"`.
- **Vocabulary terms** — preserved in original language. Russian idioms and operator-coined phrases stay in Russian.
- **Body content** — whichever language was used in the relevant exchange. Mix is fine.

---

## Self-install

If you got `bro.md` some other way (forwarded, downloaded somewhere weird) — just run `/bro` once. The skill detects it's not in the standard location and offers to install itself properly.

---

## Safety

bro is a markdown file, not executable code. It contains instructions for Claude, which runs within its normal safety boundaries.

Before installing, you can open `bro.md` and read it — it's plain text describing what Claude should do.

---

## How it works technically

Claude Desktop / Claude Code auto-discovers markdown files in `~/.claude/commands/`. Each file becomes a slash command matching its filename (`bro.md` → `/bro`).

`bro.md` contains:
- YAML frontmatter (description — so Claude knows what the skill does)
- Logic (how to detect/setup storage, resolve tags, classify material, write files)
- Templates (structure of `_principles.md`, `_thread.md`, daily file)
- Markers vocabulary
- Bilingual rules
- Explanation (why three-tier protocol exists)

When you run `/bro`, Claude reads the skill file and executes the instructions — detecting where to save in this repo, resolving tag from session, loading existing files, classifying recent conversation into persistent vs ephemeral, writing what's new.

---

## Storage root

Picked once per repo on first `/bro`:

| Option | Path | When to use |
|---|---|---|
| Visible | `{cwd}/bro/` | Default — for analysis, search, review |
| Hidden | `{cwd}/.claude/bro/` | If you don't want a top-level `bro/` folder |
| Custom | Any path you choose | You know what you want |

Files inside the chosen root:
- `_principles.md` — repo-wide persistent
- `{tag}/_thread.md` — thread-wide persistent
- `{tag}/{YYYY-MM-DD}.md` — daily ephemeral

Change root anytime with `/bro setup` — switching offers to copy `_principles.md` and `_thread.md` to the new location (daily files stay put).

---

## Auto-update

bro checks GitHub for a new version once per week. If a new version exists, it tells you and offers to pull — non-blocking if you're offline or busy.

- Manual update: `/bro update`
- Disable weekly check: `export BRO_NO_UPDATE_CHECK=1` in your shell

After updating, restart Claude Desktop (or open a new chat) to load the new skill version.

**Major version bumps** (e.g., v1.x → v2.x): the skill warns explicitly during update if the storage layout changed. v1 stored centrally in `~/.claude/bro/` or `~/Desktop/bro-workspace/`; v2 stores per-repo. Old logs stay where they are — v2 starts fresh in each repo via `/bro setup`.

---

## Migration from v1

v2 doesn't auto-migrate v1 logs. Old logs (typically in `~/Desktop/bro-workspace/` or `~/.claude/bro/`) stay where they were as an archive. New logs in v2 go per-repo into `{cwd}/bro/` (or `.claude/bro/`).

If you want to keep using old logs as reference, just leave them. If you want to manually move thread folders into new repos, copy the relevant `{tag}/` folders into the appropriate `{repo}/bro/` location.

---

## Changelog

- **v2.0.0** — three-tier architecture (`_principles.md` repo-wide + `_thread.md` thread-wide + daily ephemeral). Per-repo storage (no centralized location). Auto-tag from chat's first user message + session UUID for collision safety. Visible storage default (`bro/` in repo root) with auto-`.gitignore`. Interactive promotion prompts (ephemeral → persistent). Markers vocabulary standardized (`(sticky)`, `(carried since)`, `(чтобы не возвращались)`, etc.). Bilingual handling rules explicit. Major-bump warning on `/bro update`. **Breaking:** v1 logs not auto-migrated; v2 starts fresh per repo.
- **v1.1.0** — folder-per-thread layout (parallel work streams no longer collide); `/bro list`, `/bro <tag>`, `/bro update`; weekly version check. Added `SKILL.md` mirror.
- **v1.0.0** — initial release.

## Files in this repo

- **`bro.md`** — canonical skill file, install target (curl one-liner points here)
- **`SKILL.md`** — mirror of `bro.md` for external directory indexers (skillsdirectory.com, oneskill.dev) that expect the standard `SKILL.md` filename convention
- **`README.md`** — this file
- **`LICENSE`** — MIT

When updating the skill, keep `bro.md` and `SKILL.md` in sync (they have identical body content; frontmatter may differ slightly).

---

## Why "bro"

Because that's literally what it does. Your chat remembers what you talked about and brings it back when you need it. Like a bro.

---

## License

MIT — see [LICENSE](./LICENSE)

## Author

Yuriy Balaka ([@balaka](https://github.com/balaka))
