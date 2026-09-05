# bro — your chat holds the thread

[![Version](https://img.shields.io/badge/version-3.1.0-blue)](https://github.com/balaka/bro)
[![GitHub stars](https://img.shields.io/github/stars/balaka/bro?style=social)](https://github.com/balaka/bro/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude-Code-D97757)](https://claude.ai/download)

**Enforced session journal for Claude Code / Claude Desktop.** Captures what `/compact` wipes — your preferences, vocabulary, decisions, rejected options, debugging hypotheses, the rules you taught Claude. v3 stores everything in **one central place** and keeps itself alive with **hooks**: the journal is read into every session automatically, a turn can't end while today's entry is stale, and retired storage paths are write-protected. No more "remember to run /bro".

## Install (60 seconds)

```bash
curl -fsSL https://raw.githubusercontent.com/balaka/bro/main/scripts/bro-install.sh | bash
```

Open a new session, `cd` your project, type `/bro setup` once per project. Done — from then on the hooks do the remembering.

Upgrading from v1/v2? Same command, then `/bro migrate` when the session-start hook flags your old logs. See [MIGRATION.md](./MIGRATION.md) — nothing is ever deleted.

---

## Why v3 exists

v2 had two structural failures, reported by real daily use:

1. **A folder per chat.** Parallel chats didn't know about each other; per-chat summaries went stale; principles accumulated in per-repo copies that drifted apart. After a few months: 16 storage folders across the disk, 14 of them dead, and no way to answer "where is my stuff?"
2. **Discipline instead of enforcement.** bro worked only while the model remembered to call it. Models forget — reliably. A rule without an enforcer is a wish.

v3 answers both:

- **One store.** `~/bro/` — global principles (one copy), one folder per project, one `INDEX.md` registry over everything. The unit is **project + day**, not chat: every chat of the day writes sections into the same daily file. Nothing to synchronize.
- **Hooks as enforcers.** The harness — not the model's memory — injects the read-order at session start, blocks the end of a turn while today's journal is stale, and denies writes to legacy paths so an old chat can't clobber the migrated store.

## Layout

```
~/bro/
  INDEX.md            registry: one line per workspace — files, last entry
  _principles.md      global principles (working discipline, privacy, people) — the only copy
  cowork/
    _workspace.md     summary: what we build, sticky decisions, vocabulary, open questions
    2026-09-06.md     daily journal — all chats of the day, in "## HH:MM — topic" sections
    _legacy-v2/       preserved v2 thread summaries
  _archive/           migrated v1/v2 storages, byte-for-byte
```

Journal entries use three markers, English or Russian: `DECIDED:` / `RULE:` / `TAIL:` (`РЕШЕНИЕ:` / `ПРАВИЛО:` / `ХВОСТ:`). Decisions that prove stable move up to `_workspace.md` as `Chose / Over / Because / Revisit if`. Operator-confirmed universals move up to `_principles.md`. Operator's verbatim words are never translated or trimmed.

## The hooks

| Hook | Event | What it guarantees |
|---|---|---|
| `bro-session-start.sh` | SessionStart (startup / resume / compact / clear) | Read-order injected into every session; storage-version mismatch flagged → `/bro migrate` |
| `bro-stop-turnstile.sh` | Stop | A turn can't end while today's journal is missing or stale (default 30 min; configurable). Blocks at most once per prompt — can't loop |
| `bro-write-guard.sh` | PreToolUse (Write\|Edit) | Writes to retired v2 paths denied, redirected to the central store |

Config: `~/.claude/bro-config.json` — `root` (store location), `staleMinutes` (turnstile threshold), `workspaces` (path→name overrides).

## Commands

- `/bro` — capture now (classify since last entry: journal / workspace summary / principles-candidate)
- `/bro status` — freshness table for all workspaces, hook state, conflicts
- `/bro setup` — enable bro for the current project
- `/bro off` / `/bro on` — switch bro off/on for the current chat only (project stays enabled; the write guard stays on)
- `/bro migrate` — deterministic migration of v1/v2 storages ([MIGRATION.md](./MIGRATION.md))
- `/bro update` — pull latest + reinstall (idempotent)

## Migration guarantees (v1/v2 → v3)

Migration is a **script** (`scripts/bro-migrate.sh`), not model improvisation — same input, same output, any machine:

- tar.gz backup first; originals archived wholesale to `~/bro/_archive/`; pointer file left behind
- daily logs byte-for-byte; same-date threads merged under explicit `## (thread: …)` headers
- v2 thread summaries kept verbatim; principles concatenated with provenance
- duplicate headings listed in `CONFLICTS.md` for a human to resolve — the script never decides which rule wins
- idempotent; `--dry-run` prints the plan and changes nothing

## Changelog

- **3.1.0** — per-chat off switch: `/bro off` / `/bro on` (session-scoped; hooks check `~/.claude/bro/off/<session_id>`)
- **3.0.0** — central store; project+day unit (thread folders retired); global principles; hook enforcement (session-start injection, stop turnstile, write guard, version check); deterministic script migration; skill rewritten to current Anthropic skill guidelines
- **2.1.1** — removed hidden `.claude/bro/` storage option
- **2.1.0** — chat-title tag resolution, UUID postfix, `/bro migrate`
- **2.0.0** — three-tier layout, per-repo storage

## License

MIT — see [LICENSE](./LICENSE).
