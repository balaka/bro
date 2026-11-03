# bro-lib.sh — shared functions, sourced by every bro script (v5). bash 3.2, jq required.
#   . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bro-lib.sh"

BRO_CONFIG="$HOME/.claude/bro-config.json"

# bro_config_get <key> [default] — value from bro-config.json
bro_config_get() {
  local v
  v=$(jq -r --arg k "$1" '.[$k] // empty' "$HOME/.claude/bro-config.json" 2>/dev/null)
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "${2:-}"; fi
}

# bro_root — expanded store root (default ~/bro)
bro_root() {
  local r; r=$(bro_config_get root "$HOME/bro")
  printf '%s\n' "${r/#\~/$HOME}"
}

# bro_workspace <cwd> — config map on cwd/ancestors, else git-root basename, else ''
bro_workspace() {
  local d="${1:-$PWD}" cfg="$HOME/.claude/bro-config.json" m g
  while :; do
    m=$(jq -r --arg c "$d" '.workspaces[$c] // empty' "$cfg" 2>/dev/null)
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
    [ "$d" = "/" ] || [ "$d" = "$HOME" ] || [ "$d" = "." ] && break
    d=$(dirname "$d")
  done
  g=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$g" ] && basename "$g" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-._' && echo
  return 0
}

# default kinds table (SPEC §2) — used when kinds.md is missing
bro__default_kinds() {
  cat <<'KINDS'
| kind | scope | marker | prefix | file | lives | counts |
|---|---|---|---|---|---|---|
| rule | global | RULE: | r | rules | forever | your instruction on how to work; one line; revoked only by your word |
| decision | local | DECISION: | d | decisions | 90d | a choice between options, what was chosen and why; superseded by a newer decision |
| task | local | TASK: | t | tasks | 30d | a promise or an assignment with a doer; "waiting for a reply" or "question open" is NOT a task |
| state | global | STATE: | s | state | last | the operator's mood, energy, work mode; the newest replaces the previous |
| term | local | TERM: | g | glossary | forever | a word with its own meaning in this workspace |
| insight | local | INSIGHT: | i | insights | 180d | a pattern or idea worth not losing; bold the conclusion |
KINDS
}

# bro_kinds — rows: kind<TAB>scope<TAB>marker<TAB>prefix<TAB>file<TAB>lives<TAB>counts
bro_kinds() {
  local f; f="$(bro_root)/kinds.md"
  { [ -f "$f" ] && cat "$f" || bro__default_kinds; } | awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[ \t]*\|/ && NF >= 8 {
      for (i = 2; i <= 8; i++) f[i] = trim($i)
      if (f[2] == "kind" || f[2] ~ /^:?-+:?$/ || f[2] == "") next
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f[2], f[3], f[4], f[5], f[6], f[7], f[8]
    }'
}

# bro_kind_field <kind> <column> — column by name (kind scope marker prefix file lives counts) or 1-7
bro_kind_field() {
  bro_kinds | awk -F'\t' -v k="$1" -v c="$2" '
    BEGIN { split("kind scope marker prefix file lives counts", n, " "); for (i = 1; i <= 7; i++) if (n[i] == c) c = i }
    $1 == k { print $(c + 0); exit }'
}

# bro_log_path <ws> <kind> / bro_archive_path <ws> <kind> — honors scope
bro__kind_path() {
  local file scope
  file=$(bro_kind_field "$2" file); scope=$(bro_kind_field "$2" scope)
  [ -n "$file" ] || return 1
  if [ "$scope" = global ]; then printf '%s/%s.%s\n' "$(bro_root)" "$file" "$3"
  else printf '%s/%s/%s.%s\n' "$(bro_root)" "$1" "$file" "$3"; fi
}
bro_log_path()     { bro__kind_path "$1" "$2" log; }
bro_archive_path() { bro__kind_path "$1" "$2" archive; }

# bro_id <kind> <date> <text> — prefix + first 6 hex of sha256("kind|date|text")
bro_id() {
  local p h
  p=$(bro_kind_field "$1" prefix)
  if command -v shasum >/dev/null 2>&1; then h=$(printf '%s' "$1|$2|$3" | shasum -a 256)
  else h=$(printf '%s' "$1|$2|$3" | sha256sum); fi
  printf '%s-%s\n' "$p" "${h:0:6}"
}

# bro_lock <path> / bro_unlock <path> — mkdir mutex (<path>.lock), 5 s wait, reclaims locks older than 5 min
bro_lock() {
  local l="$1.lock" i=0
  until mkdir "$l" 2>/dev/null; do
    if [ -n "$(find "$l" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$l" 2>/dev/null && continue; fi
    i=$((i+1)); [ "$i" -gt 100 ] && return 1
    sleep 0.05
  done
}
bro_unlock() { rmdir "$1.lock" 2>/dev/null; return 0; }

bro_today() { date +%F; }
bro_now()   { date +%H:%M; }

# bro_hook_input_field <json> <key> — top-level key of hook stdin JSON ('' if absent)
bro_hook_input_field() { printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null; }

# bro_session_context <text> — SessionStart hook JSON with additionalContext
bro_session_context() {
  jq -cn --arg t "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$t}}'
}
