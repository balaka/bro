# bro v5 — specification

One flow for every kind of record: **journal → harvest → log → expire → archive**, and **context** printed from the logs into every new chat. No model anywhere in the scripts; the chat writes, scripts move and print.

Target: bash 3.2 + BSD/GNU userland (macOS default). `jq` required. Everything the hooks print to the chat is **English**. Russian is accepted nowhere in v5 (migration rewrites old journals).

## 1. Vocabulary

| word | meaning |
|---|---|
| store | `~/bro/` (config key `root`) |
| workspace | one project; folder `~/bro/<ws>/`; resolved from the chat's cwd (git root basename, or the `workspaces` map in `~/.claude/bro-config.json`) |
| journal | `~/bro/<ws>/YYYY-MM-DD.md` — the day's chronicle, append-only, never edited |
| record | one marked line in a journal; one line in a log |
| kind | the type of a record; defined in `~/bro/kinds.md` |
| marker | the label a record starts with in the journal (`TASK:`) |
| log | `<file>.log` — live records of one kind |
| archive | `<file>.archive` — expired or closed records, same format, never deleted |
| context | text a hook injects into a chat at start / resume / compact / clear |
| scope | `global` → file lives in `~/bro/`; `local` → in `~/bro/<ws>/` |

## 2. `~/bro/kinds.md` — the only configuration of kinds

Markdown table. Columns, in order:

```
| kind | scope | marker | prefix | file | lives | counts |
|---|---|---|---|---|---|---|
| rule | global | RULE: | r | rules | forever | your instruction on how to work; one line; revoked only by your word |
| decision | local | DECISION: | d | decisions | 90d | a choice between options, what was chosen and why; superseded by a newer decision |
| task | local | TASK: | t | tasks | 30d | a promise or an assignment with a doer; "waiting for a reply" or "question open" is NOT a task |
| state | global | STATE: | s | state | last | the operator's mood, energy, work mode; the newest replaces the previous |
| term | local | TERM: | g | glossary | forever | a word with its own meaning in this workspace |
| insight | local | INSIGHT: | i | insights | 180d | a pattern or idea worth not losing; bold the conclusion |
```

- `lives`: `forever` (leaves only by word), `Nd` (archived N days after last touch), `last` (only the newest record is live; the older one is archived at once).
- `prefix` + 6 hex = record id (`t-b58d76`). Hex = first 6 of sha256 of `<kind>|<date>|<text>`.
- Context limit is one number for all kinds: **10 000 characters** per hook, in `~/.claude/bro-config.json` key `contextChars` (default 10000). Not per kind.
- Every kind name is unique. Adding a row adds a kind; no code changes. `file` must be unique too.
- The table is parsed by `bro_kinds` in bro-lib.sh; lines that are not table rows (header, separator, prose) are ignored.

## 3. Journal

File `~/bro/<ws>/YYYY-MM-DD.md`. Written **only** through `bro-append.sh`:

```
printf '%s\n' 'body…' | bro-append.sh --workspace <ws> --thread '<thread>' --topic '<topic>'
```

Appended section:

```
## HH:MM · <thread> — <topic>
body lines…
TASK: text
DONE t-b58d76: what closed it
```

Marker rules (what harvest reads):
- a marker is `<MARKER>` from kinds.md at the **start of a line**, followed by one space and the text. One record = one line.
- `DONE <id>: <text>` closes a task (any kind whose record has an id, actually — harvest looks the id up in every log of the workspace and in global logs).
- `DECISION: text (supersedes d-xxxxxx)` — harvest marks `d-xxxxxx` superseded by the new id. Same trailing `(supersedes <id>)` works for any kind.
- A bare id mentioned anywhere in a journal line (`t-b58d76 — moved to Wednesday`) **touches** that record: its `touched` date becomes today. This is what keeps a live task alive.
- bro-append validates: no `## ` headings in the body; at most one marker per line; a marker must be one from kinds.md or `DONE`.

## 4. Log format

One record per line, fields separated by ` | ` (space pipe space). Text never contains a newline; a literal `|` in text is kept (split on the first 4 separators only).

```
<id> | <created> | <touched> | <status> | <text>
t-b58d76 | 2026-10-27 | 2026-11-03 | open | Dana — send the July test results
d-d12e09 | 2026-09-20 | 2026-09-20 | superseded:d-a1b2c3 | reading volume at start is not a separate task
```

- `status`: `open` (live) · `done:<YYYY-MM-DD>` · `superseded:<id>` · `expired:<YYYY-MM-DD>`.
- A log holds only `open` records. Any other status moves the line to the `.archive` file next to it (same format). So `wc -l tasks.log` = number of live tasks.
- Source is recorded as a 6th field for traceability: `<ws>/<YYYY-MM-DD>.md#<HH:MM>` (optional, may be empty).

Files: `<file>.log` and `<file>.archive`; global kinds in `~/bro/`, local in `~/bro/<ws>/`. `~/bro/<ws>/misses.log` — `DONE`/`supersedes` with an id not found live: `<date> | <id> | <journal line>`.

## 5. Scripts (`scripts/`, installed to `~/.claude/bro/bin/`)

| script | role | size target |
|---|---|---|
| `bro-lib.sh` | shared functions (sourced) | ~120 |
| `bro-append.sh` | writer: stamp time, validate, append under lock | ~100 |
| `bro-harvest.sh` | mover: new journal lines → logs; DONE/supersedes/touch | ~150 |
| `bro-expire.sh` | timer: apply `lives` to every log → archive; once a day | ~60 |
| `bro-context.sh <kind>\|clock` | printer: one hook = one kind, ≤ contextChars | ~80 |
| `bro-stop.sh` | Stop hook: journal freshness (staleMinutes) + run harvest | ~50 |
| `bro-migrate.sh` | v4 store → v5, once | ~200 |
| `bro-install.sh` | copy scripts, write kinds.md if missing, register hooks | ~120 |

Removed from v4: write-guard, translate-registers, harvest-hook wrapper, precompact, session-start (replaced by context), rule candidates, autoCreateAfterAnswers, INDEX, `_workspace.md` summaries, `started/` marks.

### bro-lib.sh — contract (every other script sources it)

```
bro_config_get <key> [default]       # from ~/.claude/bro-config.json
bro_root                             # expanded root, default ~/bro
bro_workspace <cwd>                  # workspace name for a cwd ('' if none)
bro_kinds                            # prints rows: kind<TAB>scope<TAB>marker<TAB>prefix<TAB>file<TAB>lives<TAB>counts
bro_kind_field <kind> <column>       # one value
bro_log_path <ws> <kind>             # .../<file>.log honoring scope
bro_archive_path <ws> <kind>
bro_id <kind> <date> <text>          # prefix-xxxxxx
bro_lock <path> / bro_unlock <path>  # mkdir lock, 5 s wait
bro_today / bro_now                  # YYYY-MM-DD / HH:MM (real clock)
bro_hook_input_field <json> <key>    # jq read of hook stdin
bro_session_context <text>           # prints SessionStart JSON with additionalContext
```

### bro-harvest.sh

`bro-harvest.sh [--workspace <ws>] [--all]`. State: `~/bro/<ws>/.harvest-state` — `<journal file>\t<lines read>`. Reads only lines past that count. For each line:
1. starts with `DONE <id>:` → find id live in any log (local, then global) → status `done:<today>`, move to archive; else append to misses.log.
2. starts with a marker from kinds.md → new record; if text ends with `(supersedes <id>)` → mark that id `superseded:<newid>` → archive. If kind `lives=last` → archive the previous open record of that kind. Dedupe: identical text already open in that log → touch instead of adding.
3. else, for every id pattern `[a-z]-[0-9a-f]{6}` in the line that is open in a log → touch.
Runs under the log's lock. Idempotent on re-run (state file). `--all` resets state and rebuilds logs from every journal (used by migrate).

### bro-expire.sh

`bro-expire.sh [--workspace <ws>|--all]`. Stamp `~/bro/.expire-stamp` holds the date of last run; context hook calls it when the stamp isn't today. For each log: `lives=Nd` and `touched` older than N days → `expired:<today>` → archive. `forever`/`last` untouched.

### bro-context.sh

`bro-context.sh <kind>` — reads hook stdin (cwd → workspace), prints SessionStart JSON. Body:

```
## bro · tasks (cowork) — 7 live
t-b58d76 · 2026-10-27 · Dana — send the July test results
…
```

Newest `touched` first; stop before the line that would exceed `contextChars`; then one line `(+N more in ~/bro/cowork/tasks.log — grep them)`. Empty log → one line `## bro · tasks (cowork) — none`.

`bro-context.sh clock` prints the instruction block (the only non-data hook):

```
## bro v5.0.0 · workspace cowork · now 2026-11-03 21:58 (Tuesday)
Take every timestamp from here, never from feeling.
Journal: ~/bro/cowork/2026-11-03.md — write ONLY via: printf '%s\n' 'body' | ~/.claude/bro/bin/bro-append.sh --workspace cowork --thread '<thread>' --topic '<topic>'
Markers, one per line, at line start:
  RULE: — your instruction on how to work; …        (from kinds.md `counts`)
  TASK: — a promise …
  …
  DONE <id>: <what closed it>      ·  (supersedes <id>) at the end of a record replaces it
Mention an id (t-b58d76) in any line to keep that record alive. Prefer touching an existing id over writing a new record.
Keep the journal current: the Stop hook blocks an answer when the journal is older than 30 min.
Misses: 1 (see ~/bro/cowork/misses.log)
```

Registered for matchers `startup resume compact clear fork` — one entry per kind + clock, all with `timeout: 10`. Hook order in the context is not guaranteed; every block starts with its own `## bro ·` heading.

### bro-stop.sh

Stop hook. Reads stdin, resolves workspace, checks today's journal mtime against `staleMinutes` (default 30): if stale **and** `stop_hook_active` is false → `{"decision":"block","reason":"bro: journal is N min old — append a section via bro-append.sh, then finish"}`; otherwise exit 0. Then runs `bro-harvest.sh --workspace <ws>` in the background (`&` + disown) so the chat never waits for it.

### bro-migrate.sh

`bro-migrate.sh [--dry-run]`. Refuses to run twice (`~/bro/.v5-migrated`). Steps, printed one per line:
1. copy `~/bro` (minus `_archive`) → `~/bro/_archive/v4-<date>/`.
2. write `~/bro/kinds.md` if missing (default table).
3. journals: in every `<ws>/YYYY-MM-DD*.md` rewrite markers at line start: `ДЕЛО:`→`TASK:`, `РЕШЕНИЕ:`→`DECISION:`, `ОТКАЗ:`→`DECISION:` (prefix text with `rejected — `), `ПРАВИЛО:`→`RULE:`, `ТЕРМИН:`→`TERM:`, `СОСТОЯНИЕ:`→`STATE:`, `ИНСАЙТ:`→`INSIGHT:`, `ЗАКРЫТ <id>:`→`DONE <id>:`, `OPEN:`→`TASK:`, `DECIDED:`→`DECISION:`, `REJECTED:`→`DECISION: rejected — `, `CLOSED <id>:`→`DONE <id>:`. Lower-case or Title-case labels are prose, untouched.
4. registers → logs, keeping the **old ids**: `open.md` (`- [ ] t-xxx · text — from: DATE · «…»` → open; `- [x] … — closed DATE: …` → archive `done:DATE`), `decisions.md` (`### d-id (DATE) [active|superseded by …]` + text line), `insights.md`, `vocab.md` (`- **i-id** · text — from: DATE …`), `_state.md` → `~/bro/state.log` (one open record), `_principles.md` → `~/bro/rules.log` from `_rules-draft.md` if present (one line per rule) else each `## §N` heading line as the rule text. `touched` = created unless a later journal mentions the id (scan journals once).
5. run `bro-expire.sh --all` (so old tasks land in archives immediately).
6. move old registers (`open.md decisions.md insights.md vocab.md _workspace.md INDEX.md _principles*.md _rule-candidates*.md _state.md .close-misses.log .harvest-state .harvest-stamp .append-log`) into `_archive/v4-<date>/` (they are already copied; this step just removes them from the live tree). Nothing is deleted.
7. print counts per workspace: live / archived per kind.

### bro-install.sh

Same shape as v4 (atomic copies to `~/.claude/bro/bin`, skill to `~/.claude/skills/bro/SKILL.md`, config merge). Registers hooks in `~/.claude/settings.json` with jq: first **removes every entry whose command contains `/.claude/bro/bin/`** (that purges v4 hooks), then adds v5 entries. Does not touch other people's hooks. Writes `~/bro/kinds.md` if missing. If `~/bro/.v5-migrated` is absent and `~/bro/*/open.md` exists → prints "run bro-migrate.sh" and does not run it.

## 6. Tests

`tests/v5.sh` — self-contained, HOME overridden to a mktemp dir, synthetic store. Must cover: kinds parsing; append validation; harvest (new record, DONE, supersedes, touch, dedupe, miss, lives=last); expire; context size cap and ordering; stop block/allow; migrate on a tiny v4 fixture (markers rewritten, ids kept, done → archive). One `PASS:`/`FAIL:` line per check, non-zero exit on failure.

## 7. Docs (after code)

`SKILL.md` (the `/bro` skill: capture, status, setup, migrate), `README.md` for a newcomer (what you get, install, kinds.md), `CHANGELOG` entry 5.0.0. `VERSION` = `5.0.0`.
