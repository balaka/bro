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

- store missing, or older than v3 → blocks: the hook tells the operator the
  storage format is outdated and demands `/bro migrate` before any bro entry
  is written;
- store exactly one major behind the skill's (a v3 store under a v4 skill)
  → NOT blocked: the ordinary full session-start text still injects, and
  harvest still runs normally — one advisory line is added on top, naming
  `/bro migrate`; see **Updating from 3.x to 4.0**, below, for its exact
  wording;
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
- Closing a `TAIL:` item is no longer a hand-edit of `open.md`: a
  `CLOSED:` marker naming the tail's own id closes it through
  harvest instead. Nothing in `open.md` changes shape or moves — an item
  left `[x]` from before the update is unaffected either way.
- Harvest's marker parser no longer folds the paragraph after a marker into
  its body when the blank line was forgotten; ids are computed the same way
  as before the update, so re-harvesting an old journal (`--full`, or an
  incremental pass widened by an edited prefix) does not duplicate anything
  already in a register.

What to expect after 3.7 → 3.8:

- Nothing to migrate: `~/bro/_state.md` and every workspace's `insights.md` are
  brand new and start out empty. The two new markers, `STATE:`
  and `INSIGHT:`, only exist from this version forward, so there is
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
- The original six markers now also recognize a Capitalized Russian writing,
  not only ALL CAPS — `STATE:`/`INSIGHT:` stay
  ALL-CAPS-only in either language (see SKILL.md's **Journal format** and
  **Russian aliases** for the exact forms and why). Harvest also now reads a journal filename with a topic suffix
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

What to expect after 3.8.0 → 3.8.1:

- Nothing to migrate: this is a harvest bugfix, not a storage-format change.
  Re-running the installer is the whole upgrade.
- If you ran a **full re-harvest on 3.8.0** (`bro-harvest.sh --all --full`)
  over registers that a pre-3.7 harvest had already collected, check for
  duplicates it may have produced: two records under the same base id and
  the same journal source (`— родилось:`/`— родился:`), one body a plain
  prefix of the other. That shape is the fingerprint of a marker whose
  explicit id collided with another one — pre-3.7 harvest hashed its body
  glued to the next paragraph, current harvest hashes the shorter, un-glued
  body, so the same physical marker line ends up under two different
  collision suffixes. Nothing was lost or deleted — mark the newer of the
  pair `[duplicate of <older id>]` in its header/status field, same as the
  other four already found and marked this way in `cowork/decisions.md`.
  Running `--all --full` again on 3.8.1 does not produce any more of
  these — it recognizes the same shape itself now and reuses the existing
  record instead of writing a second one.

## Updating from 3.x to 4.0

Unlike every 3.x → 3.y update above, this one is a real major-version bump: `~/bro/.version` (currently `3`, for any store on 3.4 through 3.8.1) no longer matches the skill's major version (`4`). The version-check hook treats that gap differently from a v1/v2 store's: it does NOT block — the ordinary full session-start text still injects, everything still works, harvest still updates the registers normally — it just prepends one advisory line, verbatim:

> bro: this store is in v3 format — its registers still hold service words in Russian. Run /bro migrate once, with the store owner's consent, to translate them (a backup is made automatically); until then, everything works exactly as before.

1. Re-run the installer (`/bro update`, or the install one-liner again) — same as any update.
2. Run `~/.claude/bro/bin/bro-migrate.sh --dry-run` with Bash; show the operator the plan.
3. On their confirmation, run it again without `--dry-run`.

The same script also still runs the legacy v1/v2 → v3 path above first, in the same invocation, if it finds any storages left to migrate — "old path, then 3 → 4" is the order when a machine has both, not a choice between them.

What the 3 → 4 part does: it calls `bro-translate-registers.sh --all` itself (`--dry-run` previews it exactly the same way, through the same call) — translating the registers' own service words to English (see **Translating an existing store to English**, above, for exactly which ones), never the operator's own decisions, open items, terms, insights or principles. Every file it's about to change is backed up first by that same call, unmodified, to `_archive/pre-english-<timestamp>/`. `~/bro/.version` becomes `4` only once that call finishes without an error — a failed or partial run leaves the store at `3`, so a later `/bro migrate` picks up exactly where this one left off, never silently claiming success. Once the store reads `4`, running `/bro migrate` again does nothing.

What happens if you skip it: nothing breaks, ever. A v3 store is read, harvested and written to exactly the same as a v4 one — every reader in this codebase already understands both the old Russian service words and the new English ones (see SKILL.md's **Russian aliases**). The only visible effect is that one advisory line at the start of every chat, until `/bro migrate` is run.

The marker rename itself needs no migration either way: `OPEN:` is the new canonical spelling of what was `TAIL:`, but `TAIL:`, `ХВОСТ:` and `Хвост:` keep being read exactly as before, forever, whether or not the store is ever migrated.

## After migration

- Old chats can be reopened safely: the write-guard hook denies writes to
  legacy `bro/` paths inside repos, pointing to the central store instead —
  a stale chat cannot clobber the migrated data.
- `~/bro/INDEX.md` is the registry: one line per workspace with file count
  and last-entry date.
- When you've reviewed the result, the archive and backup can be deleted
  manually. The script itself never does.
