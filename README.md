# bro — your chat holds the thread

[![Version](https://img.shields.io/badge/version-2.1.1-blue)](https://github.com/balaka/bro)
[![GitHub stars](https://img.shields.io/github/stars/balaka/bro?style=social)](https://github.com/balaka/bro/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Claude Desktop](https://img.shields.io/badge/Claude-Desktop-D97757)](https://claude.ai/download)

**Session continuity memory for Claude Desktop / Claude Code.** Captures what `/compact` wipes — your preferences, vocabulary, decisions, rejected options, design tokens, debugging hypotheses, and rules you taught Claude. Stores **per-repo** in a three-tier layout that separates persistent context (project descriptor, sticky rules, architecture, vocabulary) from ephemeral daily state. Tag derives from chat title (manual rename → AI-generated → first message), with UUID postfix for guaranteed collision safety. `/bro migrate` performs LLM-driven full conversion of legacy logs without data loss.

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
{cwd}/bro/                                  ← single canonical visible location (always)
├── .gitignore                              ← ignores own contents by default
├── _principles.md                          ← REPO-WIDE persistent (universal context)
└── {tag-with-postfix}/
    ├── .session.json                       ← session marker — uuid, title history, rename tracking
    ├── _thread.md                          ← THREAD-WIDE persistent (this work topic)
    └── 2026-04-29.md                       ← DAILY ephemeral
```

**Why three tiers?** Daily files used to bloat with persistent content copy-pasted day after day. v2 splits that out — `_principles.md` is written once for the repo (project descriptor, git rules), `_thread.md` per work topic (architecture, vocabulary, roadmap), and daily files contain only what changed. After `/compact`, Claude reads in order: principles → thread → today.

---

## How tag is derived (v2.1)

bro reads your chat session's metadata and resolves the tag with priority:

1. **`customTitle`** — if you renamed the chat manually in the UI sidebar
2. **`aiTitle`** — Claude's auto-generated chat summary (visible in sidebar)
3. **First user message** — fallback when titles aren't computed yet
4. **`chat-{HHMM}`** — last resort

Then slugify with stop-word filter (drops `the`, `a`, `давай`, `сделаем`, prepositions, etc.) and append a 6-hex postfix from the session UUID:

```
"Bro Migration Fix"
  ↓ filter + slugify
"bro-migration-fix"
  ↓ append postfix
"bro-migration-fix-9e0988"          ← session UUID = 9e09887a-c861-...
```

**Why UUID postfix?** Two parallel chats started in the same minute would collide if postfix were time-based. UUIDs are unique per chat (one in 16 million collision probability for the 6-char prefix) → guaranteed isolation. UUID is itself a function of time + entropy, just not the literal time.

**Rename detection.** When you rename a chat mid-conversation, the next `/bro` notices and offers to rename the tag folder:

```
Title changed:
  was: ai: "Fix plugin log storage and multiple chat handling"
  now: custom: "Bro Migration Fix"

Rename tag folder?
  1. Yes — move fix-plugin-log-storage-9e0988 → bro-migration-fix-9e0988 (default)
  2. No — keep current tag
```

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
3. Не останавливать оператора по соображениям токенов или лимитов
   — у нас нет лимитов, на полную глубину работаем

## Working discipline  (in _thread.md, topic-specific)

### Before component port
- List all nested layers (children, slots, snippets)
- Ask: "top layer only, or all the way down?"

### Before data model change
- Re-read the relevant spec doc first
- Cross-reference with governing canon
```

**Without bro**, after `/compact`: Claude loses all discipline. Charges into edits without checking specs. Asks about token budgets. You re-teach the same rules.

**With bro**: Discipline persists. Rules carry across sessions with `(carried since YYYY-MM-DD)` markers showing they're still current.

---

### Example 3 — Parallel chats in one repo

Two chats open in the same folder, both about auth bugs. bro derives unique tags from session UUIDs:

```
{cwd}/bro/
├── _principles.md
├── fix-auth-bug-9e0988/
│   ├── .session.json   (sessionUuid: 9e0988...)
│   └── 2026-04-29.md
└── fix-auth-bug-a3f1c0/
    ├── .session.json   (sessionUuid: a3f1c0...)
    └── 2026-04-29.md
```

Same chat title → different UUID postfixes → no collision. Even started in the same minute.

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

## Migration from older versions

If you've been using bro v1.x or v2.0 and have logs scattered in old locations, `/bro migrate` performs **LLM-driven semantic conversion** to the v2.1 three-tier format:

1. **Backup** — full tar archive of legacy storage
2. **Capture current chat first** — write today's daily in new format before touching legacy (preserves working context if migration crashes)
3. **Discover** — scan `~/Desktop/bro-workspace/`, `~/.claude/bro/`, current repo's `bro/`, and other `bro/` folders on disk
4. **Per-tag conversion** — for each legacy tag:
   - Read all daily files
   - LLM classifies every section as persistent (universal → `_principles.md`, topic → `_thread.md`) or ephemeral (stays in daily)
   - Cross-file dedupe (same architecture decision in 5 files → one entry in `_thread.md` with `(carried since YYYY-MM-DD)`)
   - Rewrite daily files in v2.1 format with persistent stripped (refs added)
   - Move originals to `{tag}/_legacy-pre-v2.1/` (never deleted)
   - Apply UUID postfix to legacy tag name
5. **Aggregate** — universal rules deduplicated across tags into one `_principles.md`
6. **Verify** — counts before/after, spot-check report

LLM-driven (not regex) because old logs come in many formats — v1 single-file, v2.0 partial, mixed bro/nerve, inconsistent markers. Semantic understanding wins over pattern matching.

After migration, review the generated `_principles.md` and `_thread.md` files. If something looks wrong, restore from the backup tar archive (path printed at end). If correct, run `/bro clean-legacy` later to delete the `_legacy-pre-v2.1/` folders (manual command — never automatic).

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
| `/bro` | Update memory for the current chat (auto-resolves tag from chat title) |
| `/bro <tag>` | Use explicit tag — e.g. `/bro api-refactor` (postfix still applied) |
| `/bro list` | Show today's threads + persistent files in this repo with title history |
| `/bro setup` | Configure storage location for this repo (default `{cwd}/bro/`; custom paths supported but rarely needed) |
| `/bro migrate` | LLM-driven conversion of legacy logs into v2.1 three-tier format |
| `/bro clean-legacy` | Delete `_legacy-pre-v2.1/` folders after manual review (irreversible) |
| `/bro update` | Pull the latest bro version from GitHub |
| `bro, recall today` (natural language) | After `/compact` — reads back the relevant files |

bro also checks for updates automatically once per week and offers to pull new versions — silent if you're already current, non-blocking if GitHub is unreachable. Disable with `BRO_NO_UPDATE_CHECK=1` in your environment.

---

## First run

On first `/bro` in a repo, the skill confirms storage location:

```
Storage for this repo will be {cwd}/bro/.

Press Enter to accept, or type a custom path if you have a specific reason.
```

The default is `{cwd}/bro/` — single canonical visible location. **The previously-supported hidden `.claude/bro/` option was removed in v2.1.1** to eliminate guessing about where logs live and prevent invisible-storage data loss.

Custom paths are still supported via the prompt but rarely needed (use case: shared multi-repo workspace).

A `.gitignore` is added that ignores all contents by default. If you want to commit `_principles.md` or `_thread.md` files (e.g., to share repo-wide context with the team), uncomment the relevant lines in that gitignore.

If legacy logs are detected (from v1, v2.0, or v2.1.0 hidden install), bro suggests `/bro migrate` or offers to relocate to canonical visible.

Change location anytime with `/bro setup`.

---

## After /compact

Just tell the chat: **"bro, recall today"** — Claude lists today's threads and reads them in tier order. Or explicitly:

```
Read bro/_principles.md, bro/<tag-with-postfix>/_thread.md, bro/<tag-with-postfix>/2026-04-29.md
```

Working context re-hydrated. Continue where you stopped.

---

## Markers

bro uses a vocabulary of parenthetical markers consistently across files:

| Marker | Where | Meaning |
|---|---|---|
| `(sticky)` | persistent decisions | Append-only; supersede with note, don't rewrite |
| `(carried since YYYY-MM-DD)` | rules / vocabulary | Inherited from prior session, still valid; date = first appearance |
| `(reinforced YYYY-MM-DD)` | rules | Repeated for emphasis |
| `(new YYYY-MM-DD)` | new items | Added today |
| `(refined YYYY-MM-DD)` | vocabulary terms | Definition updated; latest definition wins |
| `(consolidated YYYY-MM-DD from N source files)` | top of `_thread.md` | Migration audit trail |
| `(чтобы не возвращались)` | REJECTED items | Hard do-not-revisit |
| `(WAIT: <reason>)` | OPEN items | Blocked on external condition |
| `(parking-lot)` / `(deferred)` / `(YAGNI)` | items | Postponed |
| `(supersedes prior, dated YYYY-MM-DD)` | sticky decisions | Pivot replaces earlier decision |
| `(renamed from {old-tag} since YYYY-MM-DD)` | top of daily | Tag was renamed when chat title changed |

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
- Logic (how to detect/setup storage, resolve tags from chat title, classify material, write files, migrate legacy)
- Templates (structure of `_principles.md`, `_thread.md`, daily file, `.session.json`)
- Markers vocabulary
- Bilingual rules
- Explanation (why three-tier, why UUID postfix, why LLM-driven migration)

When you run `/bro`, Claude reads the skill file and executes the instructions:
1. Looks up session UUID via `~/.claude/sessions/{ppid}.json` (PPID lookup, fallback to mtime in `~/.claude/projects/{encoded-cwd}/`)
2. Reads chat title from session jsonl (`type:"custom-title"` > `type:"ai-title"` > first user message)
3. Resolves tag = slug + `-{6-hex}` postfix
4. Detects rename if marker has different `lastKnownTitle`
5. Loads existing `_principles.md`, `_thread.md`, today's daily
6. Classifies recent conversation into persistent vs ephemeral
7. Writes what's new

---

## Storage root

Single canonical visible location: `{cwd}/bro/`.

| Option | Path | When |
|---|---|---|
| Default (canonical) | `{cwd}/bro/` | Always — single source of truth, visible alongside code |
| Custom | Any path you choose | Edge cases (shared multi-repo workspace, etc.) — rarely needed |

The hidden `.claude/bro/` option was removed in v2.1.1. If you have an old v2.1.0 install with hidden storage, `/bro setup` will offer to relocate to the canonical visible path.

Files inside the chosen root:
- `_principles.md` — repo-wide persistent
- `{tag-with-postfix}/_thread.md` — thread-wide persistent
- `{tag-with-postfix}/.session.json` — session marker (UUID, title history, rename tracking)
- `{tag-with-postfix}/{YYYY-MM-DD}.md` — daily ephemeral

Change root anytime with `/bro setup` — switching offers to copy `_principles.md` and `_thread.md` to the new location (daily files stay put).

---

## Auto-update

bro checks GitHub for a new version once per week. If a new version exists, it tells you and offers to pull — non-blocking if you're offline or busy.

- Manual update: `/bro update`
- Disable weekly check: `export BRO_NO_UPDATE_CHECK=1` in your shell

After updating, restart Claude Desktop (or open a new chat) to load the new skill version.

**Major version bumps** (e.g., v1.x → v2.x): the skill warns explicitly during update if the storage layout changed. v2 added per-repo storage; v2.1 added `/bro migrate` for LLM-driven legacy conversion. Old logs always preserved.

---

## Changelog

- **v2.1.1** — Removed hidden `.claude/bro/` storage option. Single canonical visible location `{cwd}/bro/` is now the only default; custom paths still supported via prompt for edge cases (shared multi-repo workspace). Rationale: hidden storage caused invisible-data losses (operator's `~/.claude/bro/product-os-design/2026-04-25.md` had unique content that would have been missed if not surfaced explicitly during migration). Single visible path eliminates guessing about where logs live. v2.1.0 hidden installs auto-detected at next `/bro setup` and offered relocation to canonical visible.
- **v2.1.0** — Tag now derives from chat title (`customTitle` > `aiTitle` > first user message > timestamp fallback). UUID postfix (6 hex chars from session UUID) appended to every tag for guaranteed collision safety in parallel chats. Rename detection on every `/bro` — when chat title changes, prompts to rename tag folder. New `/bro migrate` command — LLM-driven semantic conversion of any legacy logs (v1, v2.0, mixed bro/nerve) into v2.1 format with zero data loss; originals preserved in `_legacy-pre-v2.1/`. Stop-word filter for slug generation (RU + EN). Session resolution via `~/.claude/sessions/{ppid}.json` for reliability over mtime heuristic. Explicit "no token economy" rule in default working discipline.
- **v2.0.0** — Three-tier architecture (`_principles.md` repo-wide + `_thread.md` thread-wide + daily ephemeral). Per-repo storage (no centralized location). Auto-tag from chat's first user message. Visible storage default (`bro/` in repo root) with auto-`.gitignore`. Interactive promotion prompts (ephemeral → persistent). Markers vocabulary standardized (`(sticky)`, `(carried since)`, `(чтобы не возвращались)`). Bilingual handling rules explicit. Major-bump warning on `/bro update`. **Breaking:** v1 logs not auto-migrated; v2 starts fresh per repo (v2.1 added `/bro migrate` to fix this).
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
