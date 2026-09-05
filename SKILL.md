---
name: bro
version: 3.2.0
description: Session continuity journal with hook enforcement. One central store (~/bro) — global principles, one summary and shared daily journals per workspace, an INDEX over everything. Hooks inject read-order at session start, enforce journal freshness at stop, and guard legacy paths. Use /bro to capture now; also status, setup, off/on per chat, migrate, update.
---

# bro v3 — enforced session journal

bro captures the middle layer of state that formal artifacts don't: operator state, live decisions, shortcut vocabulary, open tails, working discipline. In v3 this layer is **enforced by hooks**, not by model discipline: the harness injects the read-order into every session, blocks the end of a turn while the journal is stale, and denies writes to retired v2 paths.

## Storage layout (v3)

```
~/bro/                      ← root; configurable via ~/.claude/bro-config.json "root"
  INDEX.md                  ← registry: one line per workspace (files, last entry)
  _principles.md            ← GLOBAL principles — the only copy
  CONFLICTS.md              ← unresolved principle-merge conflicts (delete when resolved)
  _rule-candidates.md       ← global queue of RULE: markers awaiting operator confirmation
  <workspace>/              ← one folder per project; name = lowercased basename of repo dir
    _workspace.md           ← what this is + people + pointers (thin; registers hold the rest)
    decisions.md            ← decision register (harvested from DECIDED: markers, ADR-style)
    open.md                 ← open-items register (harvested from TAIL: markers; close by hand)
    vocab.md                ← vocabulary register (harvested from TERM: markers)
    2026-09-06.md           ← daily journal — ALL chats of the day write here, in sections
    _legacy-v2/             ← preserved v2 thread summaries (read-only history)
  _archive/                 ← migrated v1/v2 storages, untouched
```

Five record types, one rule each: the **chronicle** (journal body) is free-form and append-only; **decisions**, **open items**, **terms** and **rule candidates** are typed records born as journal markers and harvested into registers by script; **views** (INDEX.md) are generated, never hand-edited.

The unit is **workspace + day**, not chat. Parallel chats write sections into the same daily file — nothing to synchronize. A workspace is "enabled" when `~/bro/<workspace>/` exists (created by `/bro setup` or migration); in projects without it, all hooks stay silent.

## Command routing

- `/bro` (no argument) → **Capture** (below).
- `/bro status` → **Status**.
- `/bro setup` → **Setup**.
- `/bro off` / `/bro on` → **Per-chat switch**.
- `/bro harvest` → **Harvest** (manual full run over all workspaces).
- `/bro migrate` → **Migrate**.
- `/bro update` → **Update**.

## Per-chat switch (off / on)

Enablement is per-project (a workspace in the store), but any single chat can opt out:

- `/bro off` — use Bash: `mkdir -p ~/.claude/bro/off && touch ~/.claude/bro/off/${CLAUDE_SESSION_ID}`. Report: bro is off for this chat only (session-start injection and the stop turnstile skip it; the write guard stays on — it protects data, not discipline). Other chats are unaffected; the switch survives reopening this same chat.
- `/bro on` — use Bash: `rm -f ~/.claude/bro/off/${CLAUDE_SESSION_ID}`. Report: bro is back on for this chat from the next session start.

## Capture (default)

1. Resolve workspace: use Bash to read `~/.claude/bro-config.json` (`.workspaces` map keyed by cwd; fallback = lowercased basename of cwd). If `~/bro/<workspace>/` does not exist, offer `/bro setup` and stop.
2. Read, if not already in context this session: `~/bro/_principles.md`, `~/bro/<ws>/_workspace.md`, today's and the previous daily.
3. Review the conversation since the last journal entry. Classify each piece of material with the **temporal test**: would this still be true and relevant in a fresh chat tomorrow?
   - **No** → journal free text (states, events, the story of the day).
   - **Yes, project-scoped** → a typed MARKER in the journal: `DECIDED:` / `TAIL:` / `TERM:` — harvest moves it to the register.
   - **Yes, universal** → a `RULE:` marker (lands in the candidates queue); confirm with the operator before it enters `_principles.md` (max one batched ask per capture).
4. Append to `~/bro/<ws>/YYYY-MM-DD.md` (create from the format below if missing). Use Edit/Write; never rewrite earlier sections of the day.
5. Run `~/.claude/bro/bin/bro-harvest.sh --workspace <ws> --quiet` with Bash (also regenerates INDEX.md). Check `open.md` — close items the session resolved.
6. Report in one line what was written and where.

## Journal format (daily file)

```markdown
# bro — 2026-09-06 / cowork

## 14:30 · <work thread> — <topic with a distinguishing detail>
Free text. Operator's verbatim quotes in the language spoken. What happened,
what mattered, current state.
DECIDED d-0906-1: chose X | over: Y | because: Z | revisit-if: W
RULE: <new operator instruction, verbatim>
TAIL: <open item carried forward>
TERM: <term> — <meaning, in the operator's words>
```

Rules:
- Header line 1 exactly `# bro — YYYY-MM-DD / <workspace>` (the lint checks it).
- One section per sitting; append, don't rewrite. The section header carries an ANCHOR: time · work thread — topic with a detail that distinguishes it («выключатель /bro off», not «доработки»). A cold reader a year later must place the section without any context.
- Markers at line start, single line each: `DECIDED:` / `RULE:` / `TAIL:` / `TERM:`. Russian aliases equally valid: `РЕШЕНИЕ:` / `ПРАВИЛО:` / `ХВОСТ:` / `ТЕРМИН:`. An explicit id after the keyword (`DECIDED d-0906-1:`) is optional — harvest assigns a stable hash id when absent.
- Markers are SEEDS, not final records: the harvest script moves them into the registers (decisions.md / open.md / vocab.md / _rule-candidates.md). Never hand-edit registers to add records — write a marker in the journal instead; hand-edit registers only to change status (close an item, supersede a decision, accept a rule).
- **Operator state is journal material.** Mood, energy, life context the operator shares — record it plainly, in their own words. It is often the most valuable line for whoever resumes tomorrow.
- Bilingual: write in the language the exchange happened in; verbatim quotes never translated; code/paths/URLs in backticks as-is.
- Never trim or summarize existing entries. The journal is append-only history.

## Registers and harvest

`bro-harvest.sh` (run automatically by the session-start hook for the current workspace; `/bro harvest` runs it over all workspaces) collects markers from journals into registers. It is idempotent (stable ids, append-only) and never closes or edits existing records.

- `decisions.md` — one `### <id> (date) [active]` block per decision, with the journal section it was born in. To retire a decision, change `[active]` to `[superseded by <id>]` — never delete.
- `open.md` — checklist. Close by hand: `- [x] … — закрыт YYYY-MM-DD: <чем>`. The session-start hook reports the count of unchecked items — review them against the day's work; close what got done.
- `vocab.md` — terms in the operator's words with birth dates.
- `_rule-candidates.md` (global) — every `RULE:` lands here. On capture or `/bro status`, surface pending candidates to the operator; on confirmation, write the rule into `_principles.md` (category + anchors form) and mark `[x] принят`; on rejection mark `[-] отклонён`. Never move a rule into principles without the operator's word.

## `_workspace.md` format (thin)

```markdown
# <workspace> — bro summary

## What this is
2-4 lines: the project, its goal, key consumers.

## People
- **Name** — role in this workspace.
```

Decisions, vocabulary and open questions live in the registers — do not duplicate them here.

## `_principles.md` (global)

Universal rules that apply in every workspace: working discipline, privacy boundaries, communication norms, people that cross projects. Promote a `RULE:` here only with operator confirmation. Append-only; supersede with `(supersedes YYYY-MM-DD)` notes. If `CONFLICTS.md` exists, remind the operator until it's resolved.

## Status

1. Use Bash: `cat ~/bro/INDEX.md`; show per-workspace freshness and open-tail counts.
2. Report threshold and hook state: `jq '.staleMinutes, .root' ~/.claude/bro-config.json` and whether `~/.claude/bro/bin/` scripts are registered in `~/.claude/settings.json`.
3. Flag stale workspaces (last entry > 7 days), pending `_rule-candidates.md` entries (walk the operator through accept/reject), and `CONFLICTS.md` if present.

## Harvest (manual)

Run `~/.claude/bro/bin/bro-harvest.sh --all` with Bash; report what was added per register. Use after bulk journal edits or to rebuild INDEX.md.

## Setup

1. Ensure installation: if `~/.claude/bro/bin/bro-session-start.sh` is missing, run `scripts/bro-install.sh` from the repo (or: `curl -fsSL https://raw.githubusercontent.com/balaka/bro/main/scripts/bro-install.sh | bash`).
2. Create the workspace: `mkdir -p ~/bro/<ws>` (name = lowercased basename of cwd; ask the operator only if the name is ambiguous). Add the cwd→name mapping to `.workspaces` in `~/.claude/bro-config.json` when it differs from the default.
3. Create `_workspace.md` from the format above with what is known from this session. Add the workspace line to `INDEX.md`.
4. Confirm: hooks will now inject read-order and enforce freshness here.

## Migrate

Migration is a **deterministic script** — never improvise it by hand:

1. Run `~/.claude/bro/bin/bro-migrate.sh --dry-run` with Bash; show the operator the plan.
2. On their confirmation, run it without `--dry-run`.
3. Read the resulting `~/bro/CONFLICTS.md`; walk the operator through duplicate-heading conflicts; edit `_principles.md` accordingly; delete CONFLICTS.md when done.
4. Hard rules (enforced by the script, documented in MIGRATION.md): nothing deleted, everything archived with a tar.gz backup; dailies byte-for-byte (same-date threads merged under explicit headers); v2 thread summaries kept verbatim in `_legacy-v2/`; principles concatenated with provenance, semantic dedup left to step 3.

## Update

1. `git -C <repo> pull` if a clone exists, else fetch the repo fresh; then run `scripts/bro-install.sh` (idempotent — it replaces its own hook entries and bumps `~/.claude/bro/VERSION`).
2. If the new major > `~/bro/.version`, the session-start hook will demand `/bro migrate` on the next session — follow it.

## What the hooks enforce (installed by bro-install.sh)

| Hook | Event | Effect |
|---|---|---|
| bro-session-start.sh | SessionStart (startup/resume/compact/clear) | Injects read-order for the workspace; flags storage-version mismatch → `/bro migrate` |
| bro-stop-turnstile.sh | Stop | Blocks end of turn once per prompt when today's journal is missing/stale (> `staleMinutes`, default 30) or fails lint; the model writes the entry and finishes |
| bro-write-guard.sh | PreToolUse (Write\|Edit) | Denies writes to retired v2 storage paths (`bro/` inside repos), pointing to the central store |

Config `~/.claude/bro-config.json`: `root` (store path), `staleMinutes` (turnstile threshold), `workspaces` (cwd→name overrides). All operator-tunable.

## Discipline carried from v2 (unchanged)

- **No token economy against the operator.** Depth is the default; never trim journal content to save tokens.
- **Nothing is ever deleted.** Append, archive, supersede — never erase history.
- **Verbatim over paraphrase.** The operator's words are the record; your summary is commentary.
