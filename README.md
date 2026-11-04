# bro - your chat holds the thread

[![Version](https://img.shields.io/badge/version-5.1.0-blue)](https://github.com/balaka/bro)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude-Code-D97757)](https://claude.ai/download)

**Session continuity for Claude Code.** A chat forgets everything when it ends or gets compacted. bro makes the next chat start already knowing your rules, your decisions, who promised what, how you are doing and which words mean something special in the project.

## What you get

While you work, the chat jots a short note into today's journal and marks the lines worth keeping: `TASK: Dana - send the July test results`, `DECISION: keep weekly reports (supersedes d-a1b2c3)`, `RULE: answer short`. After every answer a small script files each marked line into a log, one line per record. No model is involved in filing.

When a new chat starts (or is resumed, compacted or cleared), hooks print those logs back into it: one block per kind, newest first, plus a clock block with the real date and time and the exact command for writing the journal. Tasks you keep mentioning stay alive; tasks nobody touches for 30 days move to an archive. Nothing is ever deleted.

Kinds are not built in. They are rows in one table, `~/bro/kinds.md`: add a row and you have a new kind with its own marker, log, lifetime and start-up block.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/balaka/bro/main/scripts/bro-install.sh | bash
```

or clone and run it:

```bash
git clone https://github.com/balaka/bro && ./bro/scripts/bro-install.sh
```

The installer copies the scripts to `~/.claude/bro/bin/`, the `/bro` skill to `~/.claude/skills/bro/`, writes `~/bro/kinds.md` if you have none and registers the hooks in `~/.claude/settings.json` (it saves a backup first and leaves other people's hooks alone). Reopen your chats afterwards: hooks are read at session start.

Then create a folder for your project in the store: `mkdir -p ~/bro/<project>` (the name is the git root folder name in lowercase, or an entry in the `workspaces` map of `~/.claude/bro-config.json`). In a chat, `/bro setup` does this for you.

**Requirements:** macOS or Linux, bash 3.2 or newer, `jq`, `git` (for workspace names and curl-pipe install).

## Using it

| command | what it does |
|---|---|
| `/bro` | capture now: write a section into today's journal |
| `/bro status` | live records per kind, misses, last expire date |
| `/bro setup` | run the installer, create the workspace folder |
| `/bro migrate` | move a v4 store to v5 (dry run first) |

Writing is always done with one command (the clock block prints it with your project filled in):

```bash
printf '%s\n' 'body' | ~/.claude/bro/bin/bro-append.sh --workspace <ws> --thread '<thread>' --topic '<topic>'
```

Close a record with `DONE t-b58d76: what closed it`, replace one with `(supersedes d-a1b2c3)` at the end of the line, keep one alive by mentioning its id in any line. The full writing guide is in [SKILL.md](./SKILL.md).

## Kinds

`~/bro/kinds.md` ships with these rows. A global kind lives in `~/bro/`, a local one in `~/bro/<project>/`.

| kind | scope | marker | prefix | file | lives | counts |
|---|---|---|---|---|---|---|
| rule | global | RULE: | r | rules | forever | your instruction on how to work; one line; revoked only by your word |
| decision | local | DECISION: | d | decisions | 90d | a choice between options, what was chosen and why; superseded by a newer decision |
| task | local | TASK: | t | tasks | 30d | a promise or an assignment with a doer; "waiting for a reply" or "question open" is NOT a task |
| state | global | STATE: | s | state | last | the operator's mood, energy, work mode; the newest replaces the previous |
| term | local | TERM: | g | glossary | forever | a word with its own meaning in this workspace |
| insight | local | INSIGHT: | i | insights | 180d | a pattern or idea worth not losing; bold the conclusion |

`lives`: `forever` leaves only by your word; `90d` is archived 90 days after the last touch; `last` keeps only the newest record. The id of a record is the prefix plus 6 hex digits (`t-b58d76`). After adding a row, re-run the installer so each kind gets its start-up hook.

## What lives in ~/bro

```
~/bro/
  kinds.md                      the table above
  rules.log   rules.archive     global kinds: rules, state
  state.log   state.archive
  .expire-stamp                 date of the last expire run
  <project>/
    2026-11-03.md               one journal per day, all chats append to it
    tasks.log   tasks.archive   one pair per local kind
    decisions.log  glossary.log  insights.log  (+ .archive)
    misses.log                  DONE / supersedes that named an id not found
  _archive/v4-<date>/           full copy of a v4 store, made by migrate
```

A log line reads `id | created | touched | status | text | source`. The log holds only `open` lines, so `wc -l tasks.log` is your live task count.

## Upgrading from v4

Run the installer (it removes the v4 hooks and prints `v4 store found`), then:

```bash
~/.claude/bro/bin/bro-migrate.sh --dry-run   # plan and counts, writes nothing
~/.claude/bro/bin/bro-migrate.sh             # for real
```

Before touching anything, a full copy of the store goes to `~/bro/_archive/v4-<date>/`. Old markers in journals are rewritten to the English ones, the old registers become logs with their ids kept, and old tasks land in the archive at once. Nothing is deleted. It refuses to run twice.

## Tests

```bash
tests/v5.sh
```

Self-contained: it runs on a throwaway HOME with a synthetic store and prints one `PASS:` or `FAIL:` line per check.

## License

MIT, see [LICENSE](./LICENSE).
