---
name: bro
description: Session continuity for Claude Code. One flow for every kind of record - journal, harvest, log, expire, archive - and hooks that print the live records (rules, decisions, tasks, operator state, glossary, insights) plus the clock into every new, resumed, compacted or cleared chat. The chat writes the day's journal through one script (bro-append.sh) using plain markers like TASK: and DECISION:; scripts do the rest, no model involved. Use /bro to capture the conversation now; also /bro status, /bro setup and /bro migrate (from v4).
---

# bro v5 - your chat holds the thread

## What bro is

bro keeps what a chat would otherwise forget: your rules, the decisions you made and why, the tasks someone promised, how you are doing today, words that mean something special in a project, ideas worth keeping.

Every record travels the same road:

```
journal  ->  harvest  ->  log  ->  expire  ->  archive
```

1. **Journal** - during the chat you append a short section to today's journal file. Records are single lines that start with a marker (`TASK: ...`).
2. **Harvest** - a script reads the new journal lines after every answer and files each marked line into a log, one line per record.
3. **Log** - the live records of one kind. `wc -l tasks.log` is the number of live tasks.
4. **Expire** - once a day a script moves records that were not touched for too long (30 days for a task, for example) out of the log.
5. **Archive** - expired, closed and replaced records live on in a `.archive` file next to the log. Nothing is ever deleted.

At the start of every chat, hooks print the logs back into the conversation, one block per kind, plus a clock block. No model is involved in moving or printing: the chat writes, scripts move and print.

## Vocabulary

| word | meaning |
|---|---|
| store | `~/bro/` (config key `root` in `~/.claude/bro-config.json`) |
| workspace | one project; folder `~/bro/<ws>/`; found from the chat's directory (git root name, or the `workspaces` map in the config) |
| journal | `~/bro/<ws>/YYYY-MM-DD.md` - the day's chronicle, append-only, never edited by hand |
| record | one marked line in a journal; one line in a log |
| kind | a type of record, defined in `~/bro/kinds.md` |
| marker | the label a record starts with in the journal, e.g. `TASK:` |
| log | `<file>.log` - the live records of one kind |
| archive | `<file>.archive` - expired, done or superseded records, same format |
| context | the text hooks inject into a chat at start, resume, compact and clear |
| scope | `global` - the file lives in `~/bro/`; `local` - in `~/bro/<ws>/` |

## Kinds are configuration

`~/bro/kinds.md` (a copy of `scripts/kinds.md` is installed if you have none) is a Markdown table, the only place kinds are defined:

```
| kind | scope | marker | prefix | file | lives | counts |
```

- `marker` - the label at line start. `prefix` + 6 hex digits is the record id (`t-b58d76`).
- `file` - the log name (`tasks` -> `tasks.log` / `tasks.archive`). Names of kinds and files must be unique.
- `lives` - `forever` (leaves only by your word), `Nd` (archived N days after the last touch), `last` (only the newest record stays live).
- `counts` - one sentence on what belongs in this kind; it is printed to the chat at start as the marker guide.

Default kinds: `rule` (RULE:, global, forever), `decision` (DECISION:, 90d), `task` (TASK:, 30d), `state` (STATE:, global, last), `term` (TERM:, forever, file `glossary`), `insight` (INSIGHT:, 180d).

**To add a kind**, add a row to `~/bro/kinds.md` and re-run `scripts/bro-install.sh` (it registers one more start-up hook per kind). No code changes. Lines in the table that are not rows (header, separator, prose) are ignored.

## How to write

Always through the one script - never Edit/Write the journal:

```
printf '%s\n' 'body' | ~/.claude/bro/bin/bro-append.sh --workspace <ws> --thread '<thread>' --topic '<topic>'
```

`--thread` is the line of work, `--topic` says what this section is about (with a detail that tells it from other sections). The script stamps the real time, builds the header `## HH:MM · <thread> - <topic>`, checks the body and appends under a lock. The clock block printed at start shows the exact command with the workspace filled in.

Body rules, checked before anything is written:
- No line starts with `## `.
- A line that starts with `WORD:` in capitals must be a marker from `kinds.md` (so `NOTE:` or `TODO:` is refused - write it as plain prose), followed by one space and text.
- One record is one line. One marker per line.
- `DONE <id>: <what closed it>` closes a record, e.g. `DONE t-b58d76: sent the results`. The id must look like `t-b58d76`.

Example body:

```
Talked through the July report with Dana; agreed to resend after the fix.
TASK: Dana - send the July test results
DECISION: keep weekly reports, drop the monthly one (supersedes d-a1b2c3)
t-4e19aa - moved to Wednesday
DONE t-b58d76: results sent, Dana confirmed
```

- `(supersedes <id>)` at the end of a record replaces that record: the old one is archived as `superseded:<newid>`. Works for any kind.
- **Touching**: mentioning an existing id (`t-4e19aa`) anywhere in a line sets its `touched` date to today. That is what keeps a live task from expiring. Prefer touching an existing id over writing a duplicate record. Writing the exact same text again also just touches.
- A `DONE` or `supersedes` with an id that is not live goes to `~/bro/<ws>/misses.log`.
- Free text is welcome: only marked lines become records.

Log format (one line per record): `id | created | touched | status | text | source`. Status is `open`, `done:<date>`, `superseded:<id>` or `expired:<date>`; a log holds only `open` lines.

## What arrives at the start of a chat

Hooks (SessionStart for startup, resume, compact, clear, fork) print one block per kind, each starting with its own `## bro ·` heading:

```
## bro · tasks (cowork) - 7 live
t-b58d76 · 2026-10-27 · Dana - send the July test results
...
(+3 more in ~/bro/cowork/tasks.log - grep them)
```

Newest `touched` first, capped at `contextChars` (default 10000) characters per block; an empty kind prints `none`. Plus the **clock** block: bro version, workspace, the real date and time, the journal path and exact append command, the marker list from `kinds.md`, and the miss count if `misses.log` is not empty. Take every timestamp from the clock block, never from feeling.

The Stop hook blocks an answer once if today's journal is older than `staleMinutes` (default 30): append a section, then finish. It also starts harvest in the background after every answer. The first chat of a day triggers expire.

## Sub-commands

### `/bro` - capture now

1. Find the workspace: the clock block names it. If there is none, offer `/bro setup`.
2. Read the conversation since the last journal section. Decide with one test: would this still be true and useful in a fresh chat tomorrow?
   - No -> plain sentences in the journal (the story of the day).
   - Yes -> a marker line of the fitting kind (see the `counts` text of each kind). If something already open was handled, use `DONE <id>:`; if it only continues, mention its id.
3. Append one section with `bro-append.sh` as shown above.
4. Run `~/.claude/bro/bin/bro-harvest.sh --workspace <ws>` so the logs update at once (hooks would do it after the answer anyway).
5. Report in one line what was written and where.

### `/bro status`

With Bash, for the current workspace `<ws>`:
- Live records per kind: `wc -l ~/bro/<ws>/*.log ~/bro/*.log` (local and global logs). Show `kind: N live` (and archive counts from `*.archive` if asked).
- Misses: line count of `~/bro/<ws>/misses.log`, and the last few lines.
- Expire stamp: `cat ~/bro/.expire-stamp` (date of the last expire run; today means it already ran).
- Today's journal: `ls -l ~/bro/<ws>/$(date +%F).md` and its age against `staleMinutes`.

### `/bro setup`

1. Run `scripts/bro-install.sh` from a clone of the repo (or the curl one-liner from the README). It copies scripts to `~/.claude/bro/bin/`, this skill to `~/.claude/skills/bro/`, creates `~/.claude/bro-config.json`, writes `~/bro/kinds.md` if missing and registers the hooks in `~/.claude/settings.json` (removing every older bro hook first, other hooks are untouched; a backup is saved beside it).
2. Create the workspace folder if it is missing: `mkdir -p ~/bro/<ws>`. If the chat's directory has no git root, add it to the `workspaces` map in `~/.claude/bro-config.json` (`{"workspaces": {"/path/to/project": "name"}}`).
3. If the installer prints `v4 store found`, continue with `/bro migrate`.
4. Tell the operator to reopen chats: hooks are read at session start.

### `/bro migrate`

Moves a v4 store to v5 once.
1. Run `~/.claude/bro/bin/bro-migrate.sh --dry-run` and show the plan and counts. Nothing is written.
2. On the operator's go-ahead run `~/.claude/bro/bin/bro-migrate.sh`. It copies the whole store to `~/bro/_archive/v4-<date>/` first, rewrites old markers in journals to the English ones, builds logs from the old registers keeping the old ids, expires what is old, and moves the old registers out of the live tree. Nothing is deleted. It refuses to run twice.
3. Print the per-workspace counts it reports.

### off / on

bro has no per-chat switch. If a chat should not use bro, it simply stops appending to the journal; the hooks still print context and the Stop hook will ask for a fresh section (it blocks once per answer). To remove bro completely, delete its entries from `~/.claude/settings.json` (commands containing `/.claude/bro/bin/`).

## Files

```
~/bro/
  kinds.md              the kinds table
  rules.log  state.log  (+ .archive)     global kinds
  .expire-stamp
  <ws>/
    YYYY-MM-DD.md       journals
    tasks.log decisions.log glossary.log insights.log  (+ .archive)
    misses.log  .harvest-state
  _archive/v4-<date>/   full copy of the v4 store, made by migrate
```

Configuration (`~/.claude/bro-config.json`): `root`, `staleMinutes` (30), `contextChars` (10000), `workspaces` map.
