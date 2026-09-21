# Migrating to bro v3

v3 changes the storage model. This document is the contract: the migration is
performed by a **deterministic script** (`scripts/bro-migrate.sh`), not by the
model improvising. Same input → same output, on any machine.

## What changes

| | v1 / v2.x | v3 |
|---|---|---|
| Location | one `bro/` folder inside every repo | one central store, `~/bro/` by default (configurable) |
| Unit | folder per **chat thread**, dailies inside | file per **workspace + day**; parallel chats write sections into the same daily |
| Thread summary | `_thread.md` per chat | one `_workspace.md` per workspace |
| Principles | `_principles.md` per repo (copies drift apart) | one global `_principles.md` |
| Activation | you invoke `/bro` and hope the model remembers | hooks: injected on session start, enforced on stop, guarded on write |
| Format check | model discipline | lint script in the stop hook |

## Hard rules of the migration script

1. **Nothing is deleted.** Every legacy storage is archived wholesale into
   `~/bro/_archive/<workspace>--<hash>/`. A `README-MOVED.md` pointer is left
   at the old path. A tar.gz backup of everything is written first.
2. **Daily logs move byte-for-byte.** When two chat threads have entries for
   the same date, the files are merged in alphabetical tag order, each part
   under an explicit `## (thread: <tag> — merged by v3 migration)` header.
   Content is never summarized, trimmed, or "cleaned up" — operator states,
   verbatim quotes, everything rides along untouched.
3. **Thread summaries are kept**, verbatim, at
   `~/bro/<workspace>/_legacy-v2/<tag>--thread.md`. The new `_workspace.md`
   is written later, by you and the model, from the living work — not
   auto-generated from stale summaries.
4. **Principles are merged mechanically, not semantically.** All legacy
   `_principles.md` files are concatenated into the global one with
   provenance comments; originals stay in `~/bro/_principles-sources/`.
   Duplicate headings across sources are listed in `~/bro/CONFLICTS.md`
   as a checklist. Resolving conflicts is a human/LLM step — the script
   never decides which version of a rule wins.
5. **Idempotent.** Re-running skips storages that are already archived.
   `--dry-run` prints the full plan and changes nothing.

## How the migration is triggered

You never have to remember it. The version-check hook compares the skill's
`VERSION` with `~/bro/.version` on every session start:

- store missing or version lower → the hook injects an instruction to run
  `/bro migrate`;
- versions match → silence.

So the flow for any user, including future updates, is: update the skill →
open any session → the hook flags the mismatch → `/bro migrate` runs the
script → done, centrally, once.

## Updating inside v3 (3.x → 3.y) — no migration

The store format does not change inside a major version, so there is nothing
to migrate: `~/bro/.version` stays `3` and the hook stays silent about it. The
whole upgrade is re-running the installer (`/bro update`, or the install
one-liner again): it replaces the scripts and its own hook entries in
`~/.claude/settings.json`, and touches nothing else.

What to expect after 3.5 → 3.6:

- Chats that were open during the update keep the old hook set until they are
  reopened — Claude Code reads hook registrations when a session starts.
  After such a chat's next compaction the stop hook notices this, has the
  chat run the harvest itself, and tells you once. Any newly opened chat
  harvests the whole workspace anyway, so nothing is lost meanwhile.
- The first session start runs one full harvest in the background (tens of
  seconds on a busy store); afterwards harvest is incremental. It writes two
  small state files per workspace, `.harvest-stamp` and `.harvest-state`.
- If your session starts had been timing out (big workspace, 10 s hook cap),
  the registers were lagging behind the journals. They catch up on that first
  pass: a jump in decisions and open items is the backlog arriving.
- Migrating a v1/v2 storage into a store that is already on 3.6 needs nothing
  extra: migrated journals get fresh file dates, so the next pass reads them.

What to expect after 3.6 → 3.7:

- The write guard's matcher widens from `Write|Edit` to `Write|Edit|Bash`. A
  chat that was already open when the update runs keeps its old, narrower
  guard (and can still Write/Edit the shared daily journal directly) until
  it is reopened — same rule as always: hook registrations are read at
  session start. Once reopened, a direct Write/Edit on `<ws>/YYYY-MM-DD.md`
  (or an obvious Bash redirect/`tee`/`sed -i` into it) is denied and
  redirected to `~/.claude/bro/bin/bro-append.sh`, the new sole write path —
  the denial message itself carries the exact command to run, so a chat
  holding stale skill text in context does not need to re-read anything to
  recover.
- Closing a `TAIL:`/`ХВОСТ:` item is no longer a hand-edit of `open.md`: a
  `CLOSED:`/`ЗАКРЫТ:` marker naming the tail's own id closes it through
  harvest instead. Nothing in `open.md` changes shape or moves — an item
  left `[x]` from before the update is unaffected either way.
- Harvest's marker parser no longer folds the paragraph after a marker into
  its body when the blank line was forgotten; ids are computed the same way
  as before the update, so re-harvesting an old journal (`--full`, or an
  incremental pass widened by an edited prefix) does not duplicate anything
  already in a register.

What to expect after 3.7 → 3.8:

- Nothing to migrate: `~/bro/_state.md` and every workspace's `insights.md` are
  brand new and start out empty. The two new markers, `STATE:`/`СОСТОЯНИЕ:`
  and `INSIGHT:`/`ИНСАЙТ:`, only exist from this version forward, so there is
  nothing in old journals for them to reconcile with. Re-running the
  installer is the whole upgrade, same as every 3.x → 3.y before this one.
- A chat already open when the update runs keeps its old hook set until it is
  reopened — same rule as always, hook registrations are read at session
  start. Concretely, until reopened it keeps harvesting only at session start
  (not also in the background after each answer), keeps the older write
  guard (matches the journal's path appearing anywhere in a Bash command's
  text, not specifically where the command writes), and will not self-create
  a workspace or show the new operator-state/insights blocks in the context
  it already has. Reopen it to pick all of that up.
- The original six markers now also recognize a Capitalized RU writing
  (`Решение:`, `Правило:`, …), not only ALL CAPS — `STATE:`/`INSIGHT:` stay
  ALL-CAPS-only in either language (see SKILL.md's **Journal format** for
  why). Harvest also now reads a journal filename with a topic suffix
  (`2026-04-22-offerings-banner.md`), not only the bare date — before this
  fix such a file was invisible to harvest forever, silently, `--full`
  included. A **full re-harvest of existing journals**
  (`~/.claude/bro/bin/bro-harvest.sh --all --full`) would pick up any pre-3.8
  lines written in the Capitalized form, or sitting in a suffixed filename,
  and missed until now — but run it only when the operator explicitly asks
  for it, not automatically as part of an update, and run it in the
  background: a real measurement across every non-archived journal already
  in the store found it takes about a minute and a half across every
  project, and would add 8 lines total, all of them genuine markers (one of
  the 8 only turned up once the suffixed-filename fix above went in — a
  `cowork` journal with a `testing` suffix) — small and safe, but still the
  operator's call.

## After migration

- Old chats can be reopened safely: the write-guard hook denies writes to
  legacy `bro/` paths inside repos, pointing to the central store instead —
  a stale chat cannot clobber the migrated data.
- `~/bro/INDEX.md` is the registry: one line per workspace with file count
  and last-entry date.
- When you've reviewed the result, the archive and backup can be deleted
  manually. The script itself never does.
