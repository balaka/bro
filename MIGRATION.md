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

## After migration

- Old chats can be reopened safely: the write-guard hook denies writes to
  legacy `bro/` paths inside repos, pointing to the central store instead —
  a stale chat cannot clobber the migrated data.
- `~/bro/INDEX.md` is the registry: one line per workspace with file count
  and last-entry date.
- When you've reviewed the result, the archive and backup can be deleted
  manually. The script itself never does.
