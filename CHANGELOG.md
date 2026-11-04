# Changelog

## 5.1.0 - 2026-11-05

**bro now warns you when you restate a task and flags the ones nobody touched.**

- **Restated task warning.** Writing a `TASK:` or `DECISION:` that looks like one already open prints `looks like t-372640 — add (supersedes t-372640) …` and still writes the line. Nothing is ever blocked.
- **Stale records are flagged.** A record untouched for more than `staleDays` (default 3, in `bro-config.json`) is printed with `· stale? touch or DONE`, and the clock block says `Stale tasks: N`.
- **Plural names work.** `bro-context.sh tasks` and `glossary` work like `task` and `term`; an unknown name fails with a clear message.
- **Principles vs rules.** A new global kind `principle` (`PRINCIPLE:`) holds how to work with you everywhere; `RULE:` is now per workspace. `bro-upgrade.sh` splits an existing store once (the installer runs it).
- The clock prompt now carries a concrete example of a superseding line.

## 5.0.0 - 2026-11-03

**Every new chat now starts with your rules, decisions, open tasks, state and glossary already in front of it, and with the real date and time.** Each kind of record arrives as its own block, newest first, so a long list of tasks can no longer push your rules out. A block that is too long is cut at a fixed size and tells you where to grep for the rest.

- **One flow for everything.** You write a marked line in the day's journal; a script files it into a log after every answer; records nobody touches expire into an archive; nothing is deleted. Rules, decisions, tasks, state, glossary and insights all behave the same way.
- **Kinds are configuration.** The kinds live in one table, `~/bro/kinds.md`. Add a row and you get a new marker, log, lifetime and start-up block, with no code change.
- **English markers only.** `RULE:`, `DECISION:`, `TASK:`, `STATE:`, `TERM:`, `INSIGHT:`, and `DONE <id>:` to close a record. A marker you mistype is refused when you write it, not lost later. A line that continues a record's story but mentions its id (`t-b58d76`) keeps it alive.
- **Tasks that stay current.** A task nobody touches for 30 days moves to the archive on its own; one you mention stays. Writing `(supersedes d-a1b2c3)` replaces an older decision. Closing something that is not open is recorded in `misses.log` and shown at the start of the next chat.
- **Upgrade in one command.** `bro-migrate.sh` converts a v4 store: a full copy goes to `~/bro/_archive/v4-<date>/` first, old markers become English, old registers become logs with their ids kept. `--dry-run` shows the plan. Nothing is deleted.
- **Smaller and faster.** Hooks only print and never wait for filing; the stop check runs harvest in the background.

Removed: the write guard (writing goes through `bro-append.sh`, which checks the text itself), the register translator, rule candidates, workspace summaries (`_workspace.md`), the generated `INDEX.md`, and the auto-connect after N answers. Russian markers are no longer read; migration rewrites them once.
