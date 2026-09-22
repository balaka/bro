---
name: bro
version: 4.0.0
description: Session continuity journal with hook enforcement. One central store (~/bro) — global principles, one summary and shared daily journals per workspace, an INDEX over everything. Hooks inject read-order at session start, enforce journal freshness at stop, harvest markers into registers in the background after every answer, and guard legacy paths and the journal's own write path (bro-append.sh is the sole way in). Use /bro to capture now; also status, setup, off/on per chat, migrate, update.
---

# bro v3 — enforced session journal

bro captures the middle layer of state that formal artifacts don't: operator state, live decisions, shortcut vocabulary, open items, working discipline. In v3 this layer is **enforced by hooks**, not by model discipline: the harness injects the read-order into every session, blocks the end of a turn while the journal is stale, and denies writes to retired v2 paths.

## Storage layout (v3)

```
~/bro/                      ← root; configurable via ~/.claude/bro-config.json "root"
  INDEX.md                  ← registry: one line per workspace (files, last entry)
  _principles.md            ← GLOBAL principles — the only copy
  _state.md                 ← operator-state snapshot — ONE for the whole store, newest wins (see Operator state)
  CONFLICTS.md              ← unresolved principle-merge conflicts (delete when resolved)
  _rule-candidates.md       ← global queue of RULE: markers awaiting operator confirmation
  <workspace>/              ← one folder per project; name = slug of the git repo root (auto-created since 3.8 — see Setup)
    _workspace.md           ← what this is + people + pointers (thin; registers hold the rest)
    decisions.md            ← decision register (harvested from DECIDED: markers, ADR-style)
    open.md                 ← open-items register (harvested from OPEN: markers; closed by a CLOSED: marker, never by hand)
    vocab.md                ← vocabulary register (harvested from TERM: markers)
    insights.md             ← insight register (harvested from INSIGHT: markers — see Insights)
    2026-09-06.md           ← daily journal — ALL chats of the day write here, in sections
    _legacy-v2/             ← preserved v2 thread summaries (read-only history)
  _archive/                 ← migrated v1/v2 storages, untouched
```

The **chronicle** (journal body) is free-form and append-only. **Decisions**, **open items**, **terms**, **insights** and **rule candidates** are typed records born as journal markers and harvested into registers by script — one rule each. **Operator state** is a typed marker too, but it does not accumulate: instead it replaces a single store-wide snapshot, so only the newest survives (see **Operator state**, below). **Views** (INDEX.md) are generated, never hand-edited.

The unit is **workspace + day**, not chat. Parallel chats write sections into the same daily file — nothing to synchronize. A workspace is "enabled" when `~/bro/<workspace>/` exists — created by `/bro setup`, by migration, or (since 3.8) automatically; in projects without it, all hooks stay silent. Resolution walks UP from cwd: the `workspaces` map in `~/.claude/bro-config.json` (cwd, then its ancestors) wins; otherwise the first ancestor directory whose lowercased-basename slug exists in the store — so a session started in `project/active/subtask/` still lands in `project`'s workspace. If neither finds anything, session start asks git for cwd's repository root (each `git` call capped at ~2s, so a hung or hostile one can't cost the hook its whole budget) — a path under `.../.claude/worktrees/...`, a submodule, or a linked `git worktree` all collapse to the one real project they belong to (the part before `.claude/worktrees/`, the submodule's superproject, the worktree's main copy), so opening the same project through several entry points never creates several throwaway workspaces. If that root is `$HOME`, `~/Desktop`, `~/Downloads`, `/`, or sits inside `~/bro` or `~/.claude`, nothing happens — the opening text just points at `/bro setup` (same hint when cwd is not a git repository at all, or when the repo's own name has no Latin letters or digits for bro to build a slug from). Otherwise the workspace is **not** created on the spot — seeing the folder is not "work starting": the opening text names the project and says how many responses (`autoCreateAfterAnswers` in `~/.claude/bro-config.json`, default 5) until it connects itself; the stop hook counts this chat's own responses (deduped by prompt, so a retried block never counts twice) and, once the threshold is crossed, checks whether `~/bro/<slug>/` is still missing and creates it together under one lock keyed to that path. Only whichever chat actually finds it missing and creates it is required to start the chronicle that same turn; a chat that finds it already there — a sibling worktree, or another chat's own threshold crossed at nearly the same moment — adopts it silently instead, no wait, no second announcement.

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

1. Resolve workspace as the hooks do: `.workspaces` map (cwd, then ancestors), else walk up from cwd taking the first ancestor whose slug exists in `~/bro/`. If none, offer `/bro setup` and stop — unless the opening text already named a pending project and a response count, in which case it self-connects on its own once that count is reached (see **Setup**); no need to intervene.
2. Re-read `~/bro/_principles.md` NOW, always — even if it was read earlier this session: another chat may have changed it, and /bro is the manual "pull the latest rules" button. Then read, if not already in context this session: `~/bro/<ws>/_workspace.md`, the registers (`decisions.md`, `open.md`, `vocab.md`, `insights.md`), today's and the previous daily.
3. Review the conversation since the last journal entry. Classify each piece of material with the **temporal test**: would this still be true and relevant in a fresh chat tomorrow?
   - **No** → journal free text (events, the story of the day).
   - **Yes, project-scoped** → a typed MARKER in the journal: `DECIDED:` / `OPEN:` / `TERM:` — harvest moves it to the register.
   - **Yes, universal** → a `RULE:` marker (lands in the candidates queue); confirm with the operator before it enters `_principles.md` (max one batched ask per capture).
   - **An open item just got resolved** → a `CLOSED:` marker naming its exact id (never a hand-edit of `open.md`).
   - **The operator's mood, energy or work mode changed** → a `STATE:` marker, one side per line (this is about right now, not the temporal test above — see **Operator state**).
   - **A pattern, idea or new approach worth not losing** → an `INSIGHT:` marker, bold conclusion + 1–4 sentences on one line (see **Insights**).
4. Append to `~/bro/<ws>/YYYY-MM-DD.md` through the script, not Edit/Write (see **Appending — bro-append.sh** below; the write guard denies a direct Write/Edit or a Bash write into it).
5. Run `~/.claude/bro/bin/bro-harvest.sh --workspace <ws> --quiet` with Bash (also regenerates INDEX.md) for immediate confirmation — the background hooks harvest this workspace anyway, at session start and after every answer, so this step is a courtesy, not the only path in. Check `open.md` — close items the session resolved with a `CLOSED:` marker (see below), never a hand-edit.
6. Report in one line what was written and where.

## Journal format (daily file)

```markdown
# bro — 2026-09-06 / cowork

## 14:30 · <work thread> — <topic with a distinguishing detail>
Free text. Operator's verbatim quotes in the language spoken. What happened,
what mattered, current state.
DECIDED d-0906-1: chose X | over: Y | because: Z | revisit-if: W
REJECTED: <what was turned down, in the operator's words; nothing chosen instead>
RULE: <new operator instruction, verbatim>
OPEN: <one open item carried forward — one thing per line, never a list>
TERM: <term> — <meaning, in the operator's words>
STATE: <one side of the operator's current snapshot — mood/energy/work mode>
INSIGHT: **<bold conclusion>** <1-4 sentences, all on this one line>
CLOSED t-71bd06: <what closed it — id must be the exact one already on that line in open.md>
```

Rules:
- Section time HH:MM comes from the date command — never from your sense of time (the hook hands you NOW at session start; after any pause it is the only truth).
- Header line 1 exactly `# bro — YYYY-MM-DD / <workspace>` (the lint checks it).
- One section per sitting; append, don't rewrite. The section header carries an ANCHOR: time · work thread — topic with a detail that distinguishes it ("the `/bro off` switch", not "some fixes"). A cold reader a year later must place the section without any context.
- Markers at line start, single line each: `DECIDED:` / `REJECTED:` / `RULE:` / `OPEN:` / `TERM:` / `CLOSED:` / `STATE:` / `INSIGHT:`. Every one also accepts a Russian alias on read — see **Russian aliases**, below, for exactly which capitalization each accepts; a Capitalized Russian writing of `OPEN:`/`STATE:`/`INSIGHT:` reads as ordinary prose on purpose (a real-journal check found the Capitalized form is mostly an old habit of captioning test/branch/build status or an unrelated idea, not a real marker — accepting it would let an ordinary caption silently overwrite real data). Lowercase never counts, any language, any marker. An English keyword allows exactly one optional token between it and the colon, and only in one of two shapes: an id — either 1-2 letters, a dash, then digits/letters with at least one digit (`DECIDED d-0908-26:`), or a letter, a dash, and six hex characters, bro's own auto-hash shape (`OPEN t-abcdef:`) — or a parenthetical note with no space inside it, a colon allowed within (`DECIDED (operator):`, `REJECTED (02:26):`). An ordinary word fits neither shape and is correctly not a marker at all: `OPEN ISSUES:` and `OPEN QUESTIONS:` are prose, not open items. A Russian keyword still allows any single word before the colon, as always. For DECIDED/REJECTED/RULE/OPEN/TERM/INSIGHT this token is optional — harvest hashes an id when it's absent. `CLOSED`'s token is NOT optional: it must be the target open item's own id, in the shape above, exactly as printed in `open.md` (`CLOSED t-71bd06: <what closed it>`) — nothing can guess which item is meant, and a missing or wrong id becomes a CLOSE-MISS instead of closing anything. `STATE:` carries no token at all.
- A line that looks like an attempted marker but isn't one in the form harvest accepts (wrong grammatical form of a Russian alias, lowercase, or a dash where the colon belongs) is never silently lost: harvest counts these "near-markers" and logs one summary line per pass to `~/.claude/bro/health.log` — passive, never a block, worth a glance if something you wrote seems to have gone missing.
- **One open item per `OPEN:` line.** `bro-append.sh` rejects the whole call, before writing a byte, when an OPEN line packs several items: two or more TOP-LEVEL `; `-separated clauses (a `; ` inside `(…)`, `«…»` or `"…"` doesn't count, so one parenthetical aside with its own semicolons is fine), a REAL numbered list (both `(1)` and `(2)` present, or both `1)` and `2)` — each anchored at the start of the line or right after a space, so a date like `03.09)` or a field reference never counts), or a line over 400 characters — counted under an explicitly forced UTF-8 locale so the limit is characters, not bytes, on any system with UTF-8 installed at all; only when even that fails does it fall back to a 750-byte limit. The error echoes back whichever spelling was actually typed — `OPEN:`, `ДЕЛО:`, `TAIL:`, `ХВОСТ:` or `Хвост:` — and asks to split the rest into their own lines of that same spelling, not necessarily `OPEN:`. One clause with a clarifying aside is fine (`OPEN: one item; with a clarifying aside`); a running list is not. No other marker type is checked by this rule. The same rule applies no matter which accepted spelling of `OPEN:` was used — see **Russian aliases**, below.
- Markers are SEEDS, not final records: harvest moves them into the registers (decisions.md / open.md / vocab.md / insights.md / _rule-candidates.md) — or, for `STATE:`, replaces the one store-wide snapshot. Never hand-edit registers to add records — write a marker in the journal instead; hand-edit registers only to change status (supersede a decision, accept a rule). Closing an open item is also not a hand-edit any more — write a `CLOSED:` marker; harvest flips the checkbox.
- **`STATE:`** — one side of the operator-state snapshot per line; see **Operator state**, below, for what it is and where it goes.
- **`INSIGHT:`** — a pattern, idea or new approach worth not losing, bold conclusion + 1–4 sentences on one line; see **Insights**, below.
- Bilingual: write in the language the exchange happened in; verbatim quotes never translated; code/paths/URLs in backticks as-is.
- Never trim or summarize existing entries. The journal is append-only history.
- **Outcomes are complete** (§36): a finished discussion leaves its typed outcome — chose → DECIDED, turned down → REJECTED, deferred → OPEN, rule born → RULE, word born → TERM.
- **Proof lives inside the record** (§37): the number, table, exact phrase or link a record rests on goes into the record verbatim — a paraphrase loses the evidence.
- **A promise becomes an open item the moment it is spoken** (§38) — deadlines, callbacks, "I'll check" — not at session end from memory.
- **Side work is logged like main work** (§39) — especially anything touching security or irreversibly changing data.

### Russian aliases

Every marker's canonical spelling is English; a store the operator writes in Russian, or never translates, keeps working exactly the same. This is the one place these spellings are listed — nowhere else in this document repeats them.

| Marker | Canonical (English) | Russian alias | Old, read-only |
|---|---|---|---|
| Decision | `DECIDED:` | `РЕШЕНИЕ:` / `Решение:` | — |
| Rejection | `REJECTED:` | `ОТКАЗ:` / `Отказ:` | — |
| Rule | `RULE:` | `ПРАВИЛО:` / `Правило:` | — |
| Open item | `OPEN:` | `ДЕЛО:` (ALL CAPS only) | `TAIL:`, `ХВОСТ:`, `Хвост:` |
| Term | `TERM:` | `ТЕРМИН:` / `Термин:` | — |
| Closed | `CLOSED <id>:` | `ЗАКРЫТ <id>:` / `Закрыт <id>:` | — |
| State | `STATE:` | `СОСТОЯНИЕ:` (ALL CAPS only) | — |
| Insight | `INSIGHT:` | `ИНСАЙТ:` (ALL CAPS only) | — |

The six original markers — `DECIDED`, `REJECTED`, `RULE`, `TAIL`, `TERM`, `CLOSED` — accept their Russian alias ALL CAPS or Capitalized. `OPEN:`, `STATE:` and `INSIGHT:` accept theirs ALL CAPS only — a Capitalized writing (`Дело:`, `Состояние:`, `Инсайт:`) is common, ordinary prose in Russian (a diary caption, "the matter is...", an unrelated idea), so it is read as prose, not logged as a near-miss, and never overwrites real data. Every register above is about the label alone — capitalize only `STATE:`/`INSIGHT:`/`OPEN:` (or `ДЕЛО:`) itself, never the sentence that follows it.

Separately: `OPEN:`'s old English spelling, `TAIL:`, and its old Russian spellings, `ХВОСТ:`/`Хвост:`, are unaffected by the rename and still read exactly as before — same dual-case register `TAIL` always had, as one of the six original markers above. `marker_type()` folds all five accepted open-item spellings (`OPEN`, `ДЕЛО`, `TAIL`, `ХВОСТ`, `Хвост`) to the one canonical type, and an open item's id keeps its existing `t-xxxxxx` prefix no matter which one wrote it.

Every string harvest itself writes into a register, from this version on, is English regardless of which spelling or language triggered it: the origin signature is `— from: <source>` (was `— родилось:` for decisions, `— родился:` elsewhere), and a closed item gets `— closed <date>: <text>` (was `— закрыт <date>:`). Reading stays bilingual on purpose: harvest's own duplicate check, and `CLOSED:`'s line-finder, still recognize a pre-4.0 register's old Russian signatures exactly as before, so a store that is never translated keeps working precisely as it does today — see **Translate registers to English**, below, for the optional one-time script that makes an existing store's files match the new spelling.

## Appending — `bro-append.sh` (the sole write path)

A daily journal is shared by every parallel chat in a workspace; a direct Write/Edit, or a Bash command whose write TARGET resolves to `~/bro/<ws>/YYYY-MM-DD.md` (a redirect, `tee`, `sed`/`perl -i`, `cp`/`mv`/`install`/`ln`, `dd of=`, `truncate`, `rm`/`unlink`, or a python/node one-liner that opens it for writing), is denied by the write guard and pointed here instead. The guard checks where a command actually writes, not whether the journal's path merely appears somewhere in its text — a heredoc body that only quotes a journal filename as a worked example no longer false-blocks (see **What the hooks enforce** for the exact shapes it catches and the gaps it honestly doesn't). Use Bash:

```
printf '%s\n' 'DECIDED: chose X | over: Y | because: Z' | ~/.claude/bro/bin/bro-append.sh --workspace <ws> --thread '<work thread>' --topic '<topic with a distinguishing detail>'
```

(or a heredoc — `<<'EOF' ... EOF` — for a multi-line body; `--workspace` can be omitted when cwd resolves to one workspace, the same walk the hooks use). It:

- stamps `HH:MM`/the date from the real clock itself — there is no time/date argument, so an invented section time is not merely checked for, it cannot be typed in the first place;
- validates the body before writing a single byte: a stray `## ` line (would be misread as a new section) or a marker keyword missing its colon (invisible to harvest) rejects the whole call with a precise, line-numbered error, nothing touched;
- auto-inserts the blank line after a marker line if the body didn't already have one, so a marker can never glue to the paragraph that follows it;
- creates today's file with the canonical header (`# bro — YYYY-MM-DD / <workspace>`) the first time it's needed;
- appends atomically under a lock (`bro-lib.sh`'s `lock()`) — parallel chats queue, never interleave or overwrite each other's section;
- logs the line range it wrote plus a sha256 of those bytes to `<ws>/.append-log` — the stop hook's lint reads this to skip re-scrutinizing content it already validated (a hand-edit or historical content, whose hash won't match, still gets full scrutiny);
- prints one confirmation line on success.

## Registers and harvest

`bro-harvest.sh` collects markers from journals into registers. It runs automatically for the current workspace via its own background hook — at session start, and (since 3.8) again after every answer (the Stop hook), so registers no longer lag a whole chat behind; either way it can never delay or cancel the context injection or the freshness check. `/bro harvest` runs it by hand, over all workspaces. A per-workspace lock makes a second trigger for the same workspace (a fast back-and-forth chat, or two parallel chats) exit immediately instead of queueing or racing — a stale (>5 min) lock left by a killed hook is reclaimed, never wedges harvest shut. It is idempotent (stable ids, append-only) and never closes or edits existing records. It is incremental: a pass reads only journals changed since the last completed pass, and in them only the lines added since then; if already-harvested lines were edited, that journal is re-read whole. Before parsing a journal it copies it under the very same lock `bro-append.sh` takes to write it, and reads only that copy — with harvest now running after every answer, the moment where a write is only half-flushed is no longer rare, and reading the live file mid-write could file a truncated line as a second, permanent record; a copy whose last physical line has no trailing newline is left out of that pass entirely rather than trusted, and picked up whole next time. A journal filename with a topic suffix (`2026-04-22-offerings-banner.md`) is recognized too, not only the bare date. A record is taken as it stands the first time it is seen — a marker's harvested body is exactly its own physical line; `bro-append.sh` auto-inserts the blank line after it so nothing from a later paragraph ever glues on (a hand-edited marker without one just drops the adjacent text instead of gluing it in — logged passively to `~/.claude/bro/health.log`, never a block). `--full` re-reads everything (use after restoring journals with old file dates, or after hand-removing records from a register — see MIGRATION.md for when a `--full` re-harvest of existing journals is actually worth running).

- `decisions.md` — one `### <id> (date) [active]` block per decision; rejections land here too as `[rejected]` (id prefix o-), with the journal section it was born in. To retire a decision, change `[active]` to `[superseded by <id>]` — never delete.
- `open.md` — checklist. Close via a `CLOSED:` journal marker, never a hand-edit: `CLOSED <id>: <text>` (id = the open item's own id, exactly as printed on its `open.md` line). Harvest flips that one line to `- [x] … — closed YYYY-MM-DD: <text>` under lock, and it's idempotent — an already-`[x]` id, or the same `CLOSED:` seen again on a `--full` re-read, is a no-op, never a double-close. An id that is not currently open in this workspace's `open.md` (wrong id, typo, already closed under a different id) is a CLOSE-MISS: logged to `<ws>/.close-misses.log` (deduped, so a `--full` pass never re-logs it) and its count surfaced at the next session start — check it, it's the only place a bad `CLOSED:` shows up. The session-start hook also reports the count of unchecked items — review them against the day's work; close what got done with a `CLOSED:` marker.
- `vocab.md` — terms in the operator's words with birth dates.
- `insights.md` — same shape as `vocab.md`, one entry per `INSIGHT:` occurrence. See **Insights**, below.
- `_rule-candidates.md` (global) — every `RULE:` lands here. Review cadence is enforced: when the queue reaches 10 or 7 days pass since the last review, the session-start hook demands a batched review; after it, stamp `date +%F > ~/bro/.last-rule-review`. On capture or `/bro status`, surface pending candidates to the operator; on confirmation, write the rule into `_principles.md` (category + anchors form) and mark `[x] accepted`; on rejection mark `[-] rejected`. Never move a rule into principles without the operator's word.
- `_state.md` (global, root-level — NOT per workspace, and not an accumulating register at all) — harvest keeps only the single newest snapshot store-wide, overwriting the file atomically under lock. See **Operator state**, below.
- Near-marker counter — a line shaped like an intended marker that harvest does not recognize (wrong RU grammatical form, lowercase, or a dash where the colon belongs) is counted per pass and, only when the count is > 0, logged once to `~/.claude/bro/health.log`: `<workspace>: N near-marker line(s) not harvested — e.g. '<the first ~60 bytes, cut on a whole character>'` (never mid-character, even on Cyrillic text). Same passive, never-blocking style as the pre-existing glued-text counter above.
- A `STATE:` line under a section header that isn't a readable `HH:MM · …` (missing or malformed) can't be placed in time, so it can't be compared for "newest" — skipped, and logged the same passive way: `<workspace>: N STATE marker(s) skipped — record has no readable 'HH:MM · …' section header`.

## Operator state

How the operator is doing and what mode we're working in — tired, irritated, energized, what length/format of answer they'll tolerate right now, what they're focused on. In the first version of bro (the nerve plugin) this lived in 13 of 16 files; by v3 it had quietly disappeared everywhere. In the operator's own words, why it matters: it used to understand my work, my tiredness, my irritation, better.

- **Write it as** `STATE:` (Russian alias in the table above — ALL CAPS only, see **Journal format** above for why) — capitalize ONLY the label itself, never the sentence after it. One side of the snapshot per line, in the operator's own words, each side its own line — don't fold a paragraph into one. Every `STATE:` line in the same journal section is a side of the SAME snapshot, not a separate one.
- **Where it lives:** `~/bro/_state.md` — ONE file for the whole store, not per workspace. Harvest keeps only the single newest snapshot; "newest" is by when it was written (the journal's own date + the section's own `HH:MM`), never by the order harvest happened to read it in, so a `--full` re-read of old journals, or two workspaces both writing STATE the same pass, can never regress a current snapshot to something older. Written atomically under lock — never hand-edit it. If another pass is mid-write and the lock is busy, the candidate is never just dropped: it waits in `~/bro/.state-pending` and the very next harvest pass (any workspace) offers it to `_state.md` first, before its own new candidate.
- **How it's read:** every session's opening text leads with it — before even the "bro vX active" line, and before a workspace has even resolved (the snapshot is one per STORE, not per project, so a chat opened outside any project, or one still waiting on its own self-create threshold, still opens with it) — tagged with its age in hours (`bro OPERATOR STATE (3h ago): …`). A stale, missing, or malformed file never breaks the hook; it just means nothing is shown.

## Insights

A pattern, idea or new approach worth not losing — the kind of thing that otherwise surfaces once, in passing, and is gone. In the operator's own words: insights, ideas, new approaches to the work are genuinely important, and they get lost. Before this marker existed, such an idea had nowhere to go but a `RULE:` — the operator's ProductOS module-marketplace idea ended up stranded inside rule candidate `r-fe98c8`, not a rule at all, just an idea with no other slot to fit in.

- **Write it as** `INSIGHT:` (Russian alias in the table above — ALL CAPS only) — same rule, capitalize ONLY the label. Bold the conclusion, then 1–4 sentences, all on one line: `INSIGHT: **<conclusion>** <supporting sentences>`.
- **Where it lives:** `<ws>/insights.md` — accumulates, one entry per occurrence, numbered `i-xxxxxx`, same shape as `vocab.md`. Never hand-edited.
- **How it's read:** every session's opening text ends with the last 10 insights for that workspace, by their own birth date (the record's own `— from:` signature), not file position — a `--full` re-read of an old journal can append an old insight after ones already in the register, since harvest only ever appends, never reorders — text and date; older ones are found by search, not shown automatically.
- Raising an insight into a working principle (`_principles.md`) is separate, later work — not automatic, and not part of this release.

## `_workspace.md` format (thin)

```markdown
# <workspace> — bro summary

## What this is
2-4 lines: the project, its goal, key consumers.

## People
- **Name** — role in this workspace.

## Pointers
- <what> → `<path>` — one line per key project file a cold session must find
  (runbooks, income logs, canonical specs). Optional but load-bearing: this
  block is read at EVERY session start, so it is the reliable bridge from
  bro to the project's own knowledge files.
```

Decisions, vocabulary and open questions live in the registers — do not duplicate them here.

## `_principles.md` (global)

Universal rules that apply in every workspace: working discipline, privacy boundaries, communication norms, people that cross projects. Promote a `RULE:` here only with operator confirmation. Append-only; supersede with `(supersedes YYYY-MM-DD)` notes. If `CONFLICTS.md` exists, remind the operator until it's resolved.

Each entry carries six fields — write a new one with the English names, `Category`, `Rule`, `Origin`, `Enforcement`, `Bounds`, `Review`. This file is the operator's own text and nothing here ever rewrites it, so an existing entry using the Russian field names (`Категория`, `Правило`, `Родилось`, `Исполнение`, `Границы`, `Пересмотр`) is left exactly as it is — harvest's review-date scan (below, and **Status**) reads `Rule`/`Origin`/`Review` or their Russian names interchangeably, so a principle written before this version needs no editing to keep working.

## Status

1. Use Bash: `~/.claude/bro/bin/bro-harvest.sh --all --quiet && cat ~/bro/INDEX.md`; show per-workspace freshness, open-item counts, and the **Reviews due** section.
2. Report threshold and hook state: `jq '.staleMinutes, .root' ~/.claude/bro-config.json` and whether `~/.claude/bro/bin/` scripts are registered in `~/.claude/settings.json`. Show the last lines of `~/.claude/bro/health.log` if it exists — every line there is a session start that failed and was recovered by the stop hook; tell the operator when it happened last.
3. Flag stale workspaces (last entry > 7 days), pending `_rule-candidates.md` entries (walk the operator through accept/reject), and `CONFLICTS.md` if present.
4. When **Reviews due** is non-empty, run the review cycle with the operator, one principle at a time: still alive and correct → extend the `Review:` field with a LONGER interval than the last one (spaced-repetition logic: proven rules get checked less often); needs change → supersede with a new entry referencing the old id; dead → mark superseded, never delete.

## Harvest (manual)

Run `~/.claude/bro/bin/bro-harvest.sh --all` with Bash; report what was added per register. Use after bulk journal edits or to rebuild INDEX.md. Add `--full` to ignore the incremental state and re-read every journal.

## Setup

Since 3.8, a git repository bro has never seen recognizes itself the moment a session opens there — name = slug of the repository root, not of cwd (see **Storage layout**) — but does not connect right away: it waits for `autoCreateAfterAnswers` responses (default 5) in that chat, so merely opening a folder (an isolated background-task worktree, someone else's repo) never mints a throwaway workspace. Manual setup below is for what that can't cover: a folder that is NOT a git repository, a repository whose own name has no Latin letters or digits to slug, or connecting immediately / under a different name instead of waiting.

1. Ensure installation: if `~/.claude/bro/bin/bro-session-start.sh` is missing, run `scripts/bro-install.sh` from the repo (or: `curl -fsSL https://raw.githubusercontent.com/balaka/bro/main/scripts/bro-install.sh | bash`).
2. Create the workspace: `mkdir -p ~/bro/<ws>` (name = lowercased basename of cwd, or ask the operator what they'd rather call it). Add the cwd→name mapping to `.workspaces` in `~/.claude/bro-config.json` when it differs from the default.
3. Create `_workspace.md` from the format above with what is known from this session. Add the workspace line to `INDEX.md`.
4. Confirm: hooks will now inject read-order and enforce freshness here.

## Migrate

Migration is a **deterministic script** — never improvise it by hand:

1. Run `~/.claude/bro/bin/bro-migrate.sh --dry-run` with Bash; show the operator the plan.
2. On their confirmation, run it without `--dry-run`.
3. Read the resulting `~/bro/CONFLICTS.md`; walk the operator through duplicate-heading conflicts; edit `_principles.md` accordingly; delete CONFLICTS.md when done.
4. Hard rules (enforced by the script, documented in MIGRATION.md): nothing deleted, everything archived with a tar.gz backup; dailies byte-for-byte (same-date threads merged under explicit headers); v2 thread summaries kept verbatim in `_legacy-v2/`; principles concatenated with provenance, semantic dedup left to step 3.

Coming from a v3 store (the major-version bump to 4): the same script — the same run also still does the legacy v1/v2 path above first, if it finds any storages left to migrate — same order, `--dry-run` first, then without it only on the operator's confirmation. For the 3 → 4 part specifically, `bro-migrate.sh` calls `bro-translate-registers.sh --all` itself (`--dry-run` previews it the same way); it marks the store's `~/bro/.version` as `4` only once that call finishes without an error — a failed or partial run leaves the store at `3`, so a later `/bro migrate` picks up where it left off instead of silently claiming success. Re-running it once the store is already `4` does nothing. See MIGRATION.md's **Updating from 3.x to 4.0** for the full detail.

## Translate registers to English

Installed automatically by `bro-install.sh`, alongside the other scripts. `/bro migrate` (above) already runs this as part of moving a store from 3 to 4 — use this section to run it directly instead: on its own, against one workspace only, or again later over a workspace the store-wide migrate pass never saw (restored from backup, or migrated from v1/v2 after the store was already on 4). Optional to ever run, and only with the operator's go-ahead — nothing needs it to keep working; a store that is never translated is read exactly the same as one that is.

1. Run `~/.claude/bro/bin/bro-translate-registers.sh --all --dry-run` with Bash — or `--workspace <ws>` to preview one project's own four registers only (`decisions.md`, `open.md`, `vocab.md`, `insights.md`). The two store-wide files, `_rule-candidates.md` and `_state.md`, are translated only under `--all`, once for the whole store (not per workspace), since neither belongs to a single project — `--workspace` alone leaves both of them untouched. Either way `--dry-run` writes nothing: for every file it prints the count of each kind of replacement it would make (header, origin signature, closed signature, and — in `_rule-candidates.md` — accepted/rejected) and a total; show the operator these counts.
2. On their confirmation, run the same command again without `--dry-run`.
3. It rewrites service words only, each one anchored to its own structural position — never a bare "this substring, wherever it appears" scan, so an entry that itself quotes the old format as a worked example, or an operator-state snapshot's own side text, is never touched:
   - `decisions.md`: only its own dedicated attribution line, the one that STARTS with the origin signature — `— родилось: ` → `— from: ` — never a body line, even one that quotes the old signature as an example.
   - `open.md` / `vocab.md` / `insights.md` / `_rule-candidates.md`: only the LAST signature on a line — `— родился: ` → `— from: `, and (`open.md` only) `— закрыт <date>: ` → `— closed <date>: `, and (`_rule-candidates.md` only) `— принят ` → `— accepted ` / `— отклонён ` → `— rejected ` — the real one is always the last thing harvest appends to the line, so an earlier occurrence can only be the entry's own quoted example.
   - `_rule-candidates.md` only, separately: the hand-edited `[x] принят ` / `[-] отклонён ` checkbox forms, translated only when at the very start of the line, right after the checkbox.
   - `_state.md`: only line 1 (the title — `# Состояние оператора` → `# Operator state`, recognized with trailing whitespace tolerated; a line 1 that matches neither the Russian nor the already-translated English title prints a `NOTE` in the output and is left as-is) and line 4 (`записано: … · проект …` → `recorded: … · project …`) — never the operator's own snapshot sides from line 5 on, even one that happens to use the words "записано"/"проект" in an unrelated sentence.

   Each register's own header block — from the `# …` line through the first blank line after its `> …` lines — is replaced whole, the same byte-for-byte text `bro-harvest.sh` itself writes for a brand-new register of that kind; a line 1 that isn't a recognized title prints a `NOTE` and is left as-is, same as `_state.md` above. An existing but empty register file is reported `empty — skipped` and counted as already clean, without being opened for writing.

   Every file it's about to change is copied first, unmodified, to `_archive/pre-english-<timestamp>/<path from the store root>` — one timestamp for the whole run, so everything one invocation touches lands together. It writes under the same per-register lock harvest uses, so a chat harvesting the very same second is safe; a file whose lock is genuinely busy the whole time is skipped and reported, never corrupted. Idempotent — a file with nothing left to translate is left completely untouched (no write, no backup), and re-running over an already-translated store reports it all as already English and changes zero bytes.
4. Never touches: daily journals, `_principles.md` (the operator's own text), `_workspace.md`, or `INDEX.md` (harvest regenerates that anyway) — and nothing already inside `_archive/`.

## Update

1. `git -C <repo> pull` if a clone exists, else fetch the repo fresh; then run `scripts/bro-install.sh` (idempotent — it replaces its own hook entries and bumps `~/.claude/bro/VERSION`).
2. If the new major > `~/bro/.version`, the session-start hook will demand `/bro migrate` on the next session — follow it. Within one major (3.x → 3.y) there is never a data migration: the store format is the same, re-running the installer is the whole upgrade.
3. Tell the operator what to expect: hook registrations are read when a session starts, so chats that are already open keep the old set until they are reopened (after such a chat's next compaction the stop hook says so once, and has the chat run the harvest itself meanwhile). Coming from 3.5 or older: the first session start runs one full harvest in the background (tens of seconds on a busy store); if session starts had been timing out there, the registers now catch up with the journals — a jump in open items and decisions is the backlog arriving, not duplication. Coming from 3.7 or older: offer the operator one optional `bro-harvest.sh --all --full` — 3.8 also recognizes a Capitalized Russian writing of the original six markers and dated journals with a suffix in the name, which older versions skipped; the pass only adds, never duplicates, and takes a minute or two on a busy store. Ask first — it adds records to their registers. Coming from 3.8 or older (any pre-4.0 store): unlike the two upgrades above, this release adds no new hook registrations and widens no matcher — only what the already-registered scripts read and write changes — so there is no reopen-to-pick-it-up step for the mechanics themselves: the moment the installer replaces the scripts, every chat's next append, harvest pass and `CLOSED:` already runs on the new logic. The open-item marker's canonical spelling is now `OPEN:` (was `TAIL:`; old spellings still read — see **Russian aliases** above); every register harvest writes to is now English. This is the major-version bump step 2 above describes: the session-start hook will demand `/bro migrate` once — `--dry-run` first, same as step 2's own instruction — to translate the store's service words and mark it `4`; an untranslated store keeps reading fine in the meantime, just with that one reminder line each session. See MIGRATION.md's **Updating from 3.x to 4.0** for the full notes.

## What the hooks enforce (installed by bro-install.sh)

| Hook | Event | Effect |
|---|---|---|
| bro-session-start.sh | SessionStart (startup/resume/compact/clear) | Injects read-order for the workspace, leading with the operator-state snapshot (if any — shown even before a workspace resolves) and its age, and ending with the workspace's last 10 insights (by their own birth date). Storage-version check, two tiers: a store older than v3 blocks — `STORAGE FORMAT OUTDATED`, tells the operator, and demands `/bro migrate` before any bro entries are written; a v3 store under a v4 skill is NOT blocked — the ordinary full context still injects, just with one advisory line prepended (verbatim: "bro: this store is in v3 format — its registers still hold service words in Russian. Run /bro migrate once, with the store owner's consent, to translate them (a backup is made automatically); until then, everything works exactly as before."); versions matching is silent. Since 3.8: when cwd resolves to no workspace but sits inside a git repository (worktrees/submodules/linked copies collapsed to their real project, exclusions apply — see **Storage layout**), it records the candidate and hints how many responses until it self-connects, but does NOT create it — see `bro-stop-turnstile.sh` below for the other half; outside a git repository, or when the repo's own name can't be slugged, hints `/bro setup` instead. Every `git` call is capped at ~2s so a hung one can't cost the hook its budget. Does nothing slow; leaves a start mark (`~/.claude/bro/started/<session_id>`) for the stop hook |
| bro-harvest-hook.sh | SessionStart, and (since 3.8) Stop — both `async` | Harvests the workspace's markers in the background — never in the way of the injection or the turnstile. Only a store older than v3 is skipped entirely (an outdated store is migrated first, never harvested into); a v3 store under a v4 skill harvests exactly like a v4 one — nothing pauses waiting for `/bro migrate`. Since Stop now fires it every turn, a per-workspace, single-attempt lock (not `bro-lib.sh`'s spinning `lock()`, which waits) makes a second concurrent trigger for the same workspace exit immediately instead of queueing behind or racing the first; a stale (>5 min) lock from a killed hook is reclaimed |
| bro-precompact.sh | PreCompact | Sets the session's start mark back to `pending`, so the injection that must follow every compaction is checked by the watchdog, not assumed |
| bro-stop-turnstile.sh | Stop (shares its group with bro-harvest-hook.sh above; each hook keeps its own timeout) | Since 3.8, also carries the other half of self-create: for a chat sitting on a not-yet-connected git repository (session start's own hint), counts this chat's own responses (deduped by prompt, so a retried block never counts twice) against `autoCreateAfterAnswers`; below threshold, stays completely silent. At the threshold, checking whether the folder is still missing and creating it happen together under one lock, keyed to that project's own path — if two chats in the same repo cross the threshold together, only the one that actually finds it missing and creates it gets blocked to start the chronicle; the other finds it already there under the same lock and falls through to the ordinary flow, no second "just connected" message. Otherwise: blocks end of turn once per prompt when today's journal is missing/stale (> `staleMinutes`, default 30) or fails lint; the model writes the entry and finishes. Lint is hash-gated (§5): a range `bro-append.sh` already validated and logged to `.append-log` is skipped as long as its bytes still match the logged hash — a hand-edit or historical content still gets full scrutiny. Watchdog, two checks: (1) if the session-start hook never finished in this session (or after a compaction), hands the chat the same context, logs it to `~/.claude/bro/health.log` and has the operator told; (2) if ten minutes after the session's start no harvest pass has completed for the workspace, has the chat run the harvest itself and tell the operator (typical cause: a chat opened before a bro update) |
| bro-write-guard.sh | PreToolUse (Write\|Edit\|Bash) | Denies writes to retired v2 storage paths (`bro/` inside repos, pointing to the central store), and a direct Write/Edit or a Bash command whose write TARGET resolves to a shared daily journal (`<ws>/YYYY-MM-DD.md`) — redirects (spaced, or glued to either side of the operator — `>>file`, and, since 4.0, `'x'>>file` too), `tee`, `sed`/`perl -i`, `cp`/`install`/`ln`, `dd of=`, `truncate`, `rm`/`unlink`, `mv` (checks both its source and destination — moving the journal away is a write too), or a python/node one-liner that opens it for writing (a journal path spelled out under the store root, or — since 4.0 — a bare relative journal-shaped filename when the command's own cwd already resolves inside the store) — pointing to `bro-append.sh` instead. It scans for the write TARGET rather than the journal's path merely appearing in the command text: a quoted-delimiter heredoc body is dropped outright; an unquoted one is buffered whole and, if `$(` or a backtick appears anywhere in it (a live substitution can open on one line and close on a later one), the WHOLE body is scanned as command text — the same treatment every heredoc got before this 3.8 fix; with neither, the whole body is dropped. A heredoc fed to a nested interpreter (`bash`, `python`, …) is never dropped either way, since its whole body genuinely executes. Recognizes `$ROOT`, `~/…`, and the literal unexpanded `$HOME/…`/`${HOME}/…` spellings, and resolves a relative target against the hook's own cwd, tracking `cd`/`pushd` earlier in the same command, including inside a `( cd DIR; … )` subshell. After a `cd` whose argument is a variable, or `cd -`, the working directory becomes unknowable for the rest of that command — a relative target is then blocked only if its own name is already journal-shaped (`YYYY-MM-DD*.md`); any other name is let through, since flagging every relative write once cwd is merely unknown would be too noisy to trust. Registers, `_workspace.md` and files outside the store are untouched. Known gaps, stated honestly: a target's own path built from a shell variable (`>> "$J"`) or an earlier command substitution, a `cp`/`sed -i`/etc. destination expressed via a flag placed after the path, and an `eval` whose write call — or the write target inside it — is itself sitting in a variable. Narrow, best-effort nudge (documented in the script), not the safety net — the stop hook's hash-gated lint is |

Config `~/.claude/bro-config.json`: `root` (store path), `staleMinutes` (turnstile threshold), `autoCreateAfterAnswers` (responses before a self-recognized git repo actually becomes a workspace, default 5), `workspaces` (cwd→name overrides). All operator-tunable.

## Discipline carried from v2 (unchanged)

- **No token economy against the operator.** Depth is the default; never trim journal content to save tokens.
- **Nothing is ever deleted.** Append, archive, supersede — never erase history.
- **Verbatim over paraphrase.** The operator's words are the record; your summary is commentary.
