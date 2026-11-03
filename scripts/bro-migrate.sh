#!/bin/bash
# bro-migrate.sh — v4 store -> v5 store, once. bash 3.2 + BSD/GNU userland. No model.
#   bro-migrate.sh [--dry-run]
# Steps (SPEC §5): 1 backup · 2 kinds.md · 3 journal markers · 4 registers -> logs
#                  5 expire · 6 move old registers away · 7 counts.
# Everything is built in a staging dir first; --dry-run prints the counts and discards it.
# Nothing is ever deleted: the whole v4 tree is copied to _archive/v4-<date>/ first.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$HERE/bro-lib.sh"

DRY=0
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; -h|--help) sed -n 2,4p "$0"; exit 0 ;; *) echo "bro-migrate: unknown arg $a" >&2; exit 2 ;; esac; done

ROOT="$(bro_root)"
TODAY="$(bro_today)"
[ -d "$ROOT" ] || { echo "bro-migrate: no store at $ROOT" >&2; exit 1; }
if [ -e "$ROOT/.v5-migrated" ] && [ "$DRY" = 0 ]; then
  echo "bro-migrate: already migrated ($(cat "$ROOT/.v5-migrated" 2>/dev/null)); refusing to run twice" >&2; exit 1
fi
command -v jq >/dev/null || { echo "bro-migrate: jq required" >&2; exit 1; }

STAGE="$ROOT/.migrate-stage.$$"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE"; mkdir -p "$STAGE" || exit 1
say() { echo "[bro-migrate] $*"; }
[ "$DRY" = 1 ] && say "DRY RUN — nothing will be written"

# ---- inventory --------------------------------------------------------------
WS_LIST="$STAGE/.ws"
find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '_*' ! -name '.*' | while IFS= read -r d; do basename "$d"; done | sort > "$WS_LIST"
JOURNALS="$STAGE/.journals"          # absolute paths
: > "$JOURNALS"
while IFS= read -r ws; do
  find "$ROOT/$ws" -mindepth 1 -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.md' 2>/dev/null
done < "$WS_LIST" | sort > "$JOURNALS"
NWS=$(wc -l < "$WS_LIST" | tr -d ' '); NJ=$(wc -l < "$JOURNALS" | tr -d ' ')

# ---- 1. backup --------------------------------------------------------------
BK="$ROOT/_archive/v4-$TODAY"
n=2; while [ -e "$BK" ]; do BK="$ROOT/_archive/v4-$TODAY-$n"; n=$((n+1)); done
say "1/7 backup: $ROOT (minus _archive) -> $BK ($NWS workspaces, $NJ journals)"
if [ "$DRY" = 0 ]; then
  mkdir -p "$BK" || exit 1
  (cd "$ROOT" && tar --exclude='./_archive' --exclude='./.migrate-stage.*' -cf - .) | (cd "$BK" && tar -xf -) || { echo "bro-migrate: backup failed" >&2; exit 1; }
fi

# ---- 2. kinds.md ------------------------------------------------------------
if [ -f "$ROOT/kinds.md" ]; then say "2/7 kinds.md: present, kept"
else
  say "2/7 kinds.md: writing default table"
  [ "$DRY" = 0 ] && { bro__default_kinds > "$ROOT/kinds.md.tmp.$$" && mv "$ROOT/kinds.md.tmp.$$" "$ROOT/kinds.md"; }
fi
KINDMAP="$STAGE/.kinds"              # kind<TAB>scope<TAB>file
bro_kinds | awk -F'\t' '{print $1 "\t" $2 "\t" $5}' > "$KINDMAP"

# ---- 3. journals ------------------------------------------------------------
say "3/7 journals: rewriting v4 markers at line start"
JSTAGE="$STAGE/journals"; mkdir -p "$JSTAGE"
CAND="$STAGE/.cand"
: > "$CAND"
if [ -s "$JOURNALS" ]; then
  tr '\n' '\0' < "$JOURNALS" | xargs -0 grep -lE '^(ДЕЛО|РЕШЕНИЕ|ОТКАЗ|ПРАВИЛО|ТЕРМИН|СОСТОЯНИЕ|ИНСАЙТ|OPEN|DECIDED|REJECTED|CLOSED|ЗАКРЫТ)[ :]' > "$CAND" 2>/dev/null
fi
REWRITE_AWK='
BEGIN {
  n = split("ДЕЛО:|РЕШЕНИЕ:|ПРАВИЛО:|ТЕРМИН:|СОСТОЯНИЕ:|ИНСАЙТ:|OPEN:|DECIDED:", o, "|")
  split("TASK:|DECISION:|RULE:|TERM:|STATE:|INSIGHT:|TASK:|DECISION:", w, "|")
}
function conv(l,   i, rest, r, id) {
  if (match(l, /^(CLOSED|OPEN|DECIDED|REJECTED) [a-z]-[0-9a-zA-Z-]+:/)) {      # id-carrying English forms
    r = substr(l, 1, RLENGTH); rest = substr(l, RLENGTH + 1)
    split(r, p, " "); id = p[2]; sub(/:$/, "", id)
    if (p[1] == "CLOSED") return "DONE " id ":" rest
    sub(/^ +/, "", rest)
    if (p[1] == "REJECTED") return "DECISION: rejected — " rest
    return (p[1] == "OPEN" ? "TASK: " : "DECISION: ") rest
  }
  if (index(l, "ЗАКРЫТ ") == 1) {
    rest = substr(l, length("ЗАКРЫТ ") + 1)
    if (match(rest, /^[a-z]-[0-9a-zA-Z-]+:/)) return "DONE " rest
    return l
  }
  if (index(l, "ОТКАЗ:") == 1)    { rest = substr(l, length("ОТКАЗ:") + 1);    sub(/^ +/, "", rest); return "DECISION: rejected — " rest }
  if (index(l, "REJECTED:") == 1) { rest = substr(l, length("REJECTED:") + 1); sub(/^ +/, "", rest); return "DECISION: rejected — " rest }
  for (i = 1; i <= n; i++) if (index(l, o[i]) == 1) return w[i] substr(l, length(o[i]) + 1)
  return l
}
{ print conv($0) }'
NCH=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#$ROOT/}"; mkdir -p "$JSTAGE/$(dirname "$rel")"
  awk "$REWRITE_AWK" "$f" > "$JSTAGE/$rel"
  if cmp -s "$f" "$JSTAGE/$rel"; then rm -f "$JSTAGE/$rel"; else NCH=$((NCH+1)); fi
done < "$CAND"
say "    $NCH of $NJ journals change"

# ---- 4. registers -> logs ---------------------------------------------------
say "4/7 registers -> logs (old ids kept)"
REC="$STAGE/.records"                # ws kind id created status src text   (TAB separated)
: > "$REC"
PARSE_COMMON='
function lastidx(s, t,   i, last) { last = 0; i = index(s, t); while (i) { last = last + i; s = substr(s, i + 1); i = index(s, t) } return last }
function isdate(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ }
function clean(s) { gsub(/\t/, " ", s); gsub(/\r/, "", s); gsub(/^ +| +$/, "", s); return s }
function emit(kind, id, created, status, src, text) {
  if (!isdate(created)) created = today
  print ws "\t" kind "\t" id "\t" created "\t" status "\t" src "\t" clean(text)
}
function srcof(d) { return isdate(d) ? ws "/" d ".md" : "" }
function ident(s,   m) { if (match(s, /[a-z]-[0-9a-zA-Z]+(-[0-9a-zA-Z]+)*/)) return substr(s, RSTART, RLENGTH); return "" }'

while IFS= read -r ws; do
  d="$ROOT/$ws"
  # open.md: "- [ ] id · text — from: DATE · «title»"   [x] closed, [~] partial -> open
  [ -f "$d/open.md" ] && awk -v ws="$ws" -v today="$TODAY" "$PARSE_COMMON"'
    /^- \[[ x~]\] / {
      st = substr($0, 4, 1); rest = substr($0, 7)
      id = rest; sub(/[ \t].*$/, "", id); rest = substr(rest, length(id) + 1)
      sub(/^ *(·|—) */, "", rest)
      p = lastidx(rest, " — from: ")
      if (p) { pre = substr(rest, 1, p - 1); post = substr(rest, p + length(" — from: ")) } else { pre = rest; post = "" }
      from = substr(post, 1, 10); if (!isdate(from)) from = ""
      status = "open"; why = ""
      if (st == "x") {
        a = lastidx(post, " — closed "); b = lastidx(post, " — закрыт ")
        if (b > a) { a = b; tl = length(" — закрыт ") } else tl = length(" — closed ")
        cd = ""
        if (a) { after = substr(post, a + tl); cd = substr(after, 1, 10); why = substr(after, 12); sub(/^[:· ]+/, "", why) }
        if (!isdate(cd)) cd = isdate(from) ? from : today
        status = "done:" cd
        if (why != "") pre = pre " — closed: " why
      }
      emit("task", id, from, status, srcof(from), pre)
    }' "$d/open.md" >> "$REC"
  # decisions.md: "### id (DATE) [status]" + body lines + "— from: DATE · «…»"
  [ -f "$d/decisions.md" ] && awk -v ws="$ws" -v today="$TODAY" "$PARSE_COMMON"'
    function flush(   st, ls, target) {
      if (!inrec) return
      st = "open"; ls = tolower(status)
      if (ls ~ /^superseded by / && ls !~ /restored/) { target = ident(substr(status, 15)); if (target != "") st = "superseded:" target }
      else if (ls ~ /^duplicate of /) { target = ident(substr(status, 14)); if (target != "") st = "superseded:" target }
      else if (ls ~ /^rejected/ && ls !~ /reversed/) body = "rejected — " body
      emit("decision", id, date, st, srcof(src != "" ? src : date), body)
      inrec = 0
    }
    /^### / {
      flush(); inrec = 1; body = ""; src = ""; status = ""
      line = substr($0, 5); id = line; sub(/[ \t].*$/, "", id)
      if (match(line, /\([^)]*\)/)) date = substr(line, RSTART + 1, 10); else date = ""
      b = index(line, "["); if (b) { status = substr(line, b + 1); sub(/\][^\]]*$/, "", status) }
      next
    }
    inrec && index($0, "— from: ") == 1 { src = substr($0, length("— from: ") + 1, 10); next }
    inrec && $0 !~ /^[ \t]*$/ { body = body (body == "" ? "" : " ") $0 }
    END { flush() }' "$d/decisions.md" >> "$REC"
  # insights.md / vocab.md: "- **id** · text — from: DATE · «…»"
  for pair in "insights.md:insight" "vocab.md:term"; do
    f="$d/${pair%%:*}"; k="${pair##*:}"
    [ -f "$f" ] && awk -v ws="$ws" -v today="$TODAY" -v kind="$k" "$PARSE_COMMON"'
      /^- \*\*[^*]+\*\*/ {
        match($0, /^- \*\*[^*]+\*\*/); id = substr($0, 5, RLENGTH - 6); rest = substr($0, RLENGTH + 1)
        sub(/^ *(·|—) */, "", rest)
        p = lastidx(rest, " — from: ")
        if (p) { pre = substr(rest, 1, p - 1); post = substr(rest, p + length(" — from: ")) } else { pre = rest; post = "" }
        from = substr(post, 1, 10); if (!isdate(from)) from = ""
        emit(kind, id, from, "open", srcof(from), pre)
      }' "$f" >> "$REC"
  done
done < "$WS_LIST"

# global: state.log from _state.md, rules.log from _rules-draft.md (or _principles.md headings)
if [ -f "$ROOT/_state.md" ]; then
  sdate=$(sed -n 's/^<!-- ts: [0-9]* \([0-9-]*\) .*-->.*$/\1/p' "$ROOT/_state.md" | head -1)
  stext=$(awk '/^recorded:/{on=1;next} on && /^[ \t]*$/{next} on{sub(/^- /,""); a = a (a==""?"":"; ") $0} END{print a}' "$ROOT/_state.md" | tr '\t' ' ')
  [ -n "$sdate" ] || sdate="$TODAY"
  if [ -n "$stext" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "-" state "$(bro_id state "$sdate" "$stext")" "$sdate" open "" "$stext" >> "$REC"
  fi
fi
RULES_TMP="$STAGE/.rules"
if [ -f "$ROOT/_rules-draft.md" ]; then grep -v '^[[:space:]]*$' "$ROOT/_rules-draft.md" > "$RULES_TMP"
elif [ -f "$ROOT/_principles.md" ]; then
  grep -E '^## §|^### [0-9]+ ·' "$ROOT/_principles.md" | sed 's/^#* *//' > "$RULES_TMP"
else : > "$RULES_TMP"; fi
SEEN_RULES=" "
while IFS= read -r rl; do
  rl=$(printf '%s' "$rl" | tr '\t' ' '); [ -n "$rl" ] || continue
  rid=$(bro_id rule "$TODAY" "$rl")
  case "$SEEN_RULES" in *" $rid "*) continue ;; esac
  SEEN_RULES="$SEEN_RULES$rid "
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "-" rule "$rid" "$TODAY" open "" "$rl" >> "$REC"
done < "$RULES_TMP"

# touched: latest journal date that mentions each id (one pass over all journals)
TOUCH="$STAGE/.touch"                # ws id maxdate
cut -f1,3 "$REC" | sort -u > "$STAGE/.ids"
if [ -s "$JOURNALS" ]; then
  tr '\n' '\0' < "$JOURNALS" | xargs -0 awk -v root="$ROOT/" -v idf="$STAGE/.ids" '
    BEGIN { while ((getline l < idf) > 0) { split(l, a, "\t"); want[a[1] "\t" a[2]] = 1 } }
    FNR == 1 { f = FILENAME; sub("^" root, "", f); ws = f; sub(/\/.*$/, "", ws); b = f; sub(/^.*\//, "", b); dt = substr(b, 1, 10) }
    {
      s = $0; off = 0
      while (match(s, /[a-z]-[0-9a-zA-Z]+(-[0-9a-zA-Z]+)*/)) {
        tok = substr(s, RSTART, RLENGTH)
        pc = (RSTART > 1) ? substr(s, RSTART - 1, 1) : " "
        if (pc !~ /[0-9a-zA-Z-]/ && ((ws "\t" tok) in want)) { k = ws "\t" tok; if (!(k in mx) || dt > mx[k]) mx[k] = dt }
        s = substr(s, RSTART + RLENGTH)
      }
    }
    END { for (k in mx) print k "\t" mx[k] }' > "$TOUCH"
else : > "$TOUCH"; fi

# join -> staged log/archive files
mkdir -p "$STAGE/out"
while IFS= read -r ws; do mkdir -p "$STAGE/out/$ws"; done < "$WS_LIST"
awk -F'\t' -v out="$STAGE/out" -v kmap="$KINDMAP" -v tf="$TOUCH" '
  BEGIN {
    while ((getline l < kmap) > 0) { split(l, a, "\t"); scope[a[1]] = a[2]; file[a[1]] = a[3] }
    while ((getline l < tf) > 0) { split(l, a, "\t"); tm[a[1] "\t" a[2]] = a[3] }
  }
  {
    ws = $1; kind = $2; id = $3; cr = $4; st = $5; src = $6; tx = $7
    if (!(kind in file)) { skipped++; next }
    t = cr; k = ws "\t" id
    if ((k in tm) && tm[k] > t) t = tm[k]
    ext = (st == "open") ? ".log" : ".archive"
    p = (scope[kind] == "global") ? out "/" file[kind] ext : out "/" ws "/" file[kind] ext
    line = id " | " cr " | " t " | " st " | " tx (src != "" ? " | " src : "")
    print p "\t" line
  }
  END { if (skipped) print "bro-migrate: skipped " skipped " records of kinds missing in kinds.md" > "/dev/stderr" }' "$REC" \
  | sort -s -t "$(printf '\t')" -k1,1 \
  | awk -F'\t' '{ if ($1 != cur) { if (cur != "") close(cur); cur = $1 } print $2 >> cur }'
NREC=$(wc -l < "$REC" | tr -d ' ')
say "    $NREC records written to staging"

# ---- counts helper ----------------------------------------------------------
print_counts() { # <base dir holding <ws>/*.log and global *.log>
  local base="$1" ws kind scope file lg ar nl na
  printf '    %-24s %-10s %6s %9s\n' workspace kind live archived
  { cat "$WS_LIST"; echo "(global)"; } | while IFS= read -r ws; do
    bro_kinds | while IFS="$(printf '\t')" read -r kind scope _ _ file _ _; do
      if [ "$ws" = "(global)" ]; then [ "$scope" = global ] || continue; lg="$base/$file.log"; ar="$base/$file.archive"
      else [ "$scope" = local ] || continue; lg="$base/$ws/$file.log"; ar="$base/$ws/$file.archive"; fi
      nl=0; na=0
      [ -f "$lg" ] && nl=$(wc -l < "$lg" | tr -d ' ')
      [ -f "$ar" ] && na=$(wc -l < "$ar" | tr -d ' ')
      [ "$nl$na" = "00" ] || printf '    %-24s %-10s %6s %9s\n' "$ws" "$kind" "$nl" "$na"
    done
  done
}

if [ "$DRY" = 1 ]; then
  say "5/7 expire: skipped in dry run (live tasks older than 30 days would be archived)"
  say "6/7 would move old registers into $BK and stamp $ROOT/.v5-migrated"
  say "7/7 counts that would be written (before expire):"
  print_counts "$STAGE/out"
  say "journals to rewrite: $NCH"
  exit 0
fi

# ---- install staged files (atomic mv, same filesystem) ------------------------
find "$JSTAGE" -type f | while IFS= read -r f; do mv -f "$f" "$ROOT/${f#$JSTAGE/}"; done
find "$STAGE/out" -type f | while IFS= read -r f; do mv -f "$f" "$ROOT/${f#$STAGE/out/}"; done

# ---- 5. expire --------------------------------------------------------------
if [ -x "$HERE/bro-expire.sh" ]; then
  say "5/7 expire: bro-expire.sh --all --force"
  "$HERE/bro-expire.sh" --all --force || say "    expire exited non-zero (continuing)"
else say "5/7 expire: bro-expire.sh not found next to this script — skipped (run it later)"; fi

# ---- 6. move old registers away ----------------------------------------------
say "6/7 moving v4 registers into $BK (copies already there)"
mv_away() { # <live path> <archive dir>
  local src="$1" dst="$2"
  [ -e "$src" ] || return 0
  mkdir -p "$dst"
  [ -d "$src" ] && rm -rf "$dst/$(basename "$src")"
  mv -f "$src" "$dst/"
}
while IFS= read -r ws; do
  for f in open.md decisions.md insights.md vocab.md _workspace.md .close-misses.log .harvest-state .harvest-stamp .append-log; do
    mv_away "$ROOT/$ws/$f" "$BK/$ws"
  done
done < "$WS_LIST"
for f in INDEX.md _principles.md _state.md _rules-draft.md .close-misses.log .harvest-state .harvest-stamp .append-log .last-rule-review _principles-sources; do
  mv_away "$ROOT/$f" "$BK"
done
for f in "$ROOT"/_principles*.md "$ROOT"/_rule-candidates*.md "$ROOT"/*.bak-*; do mv_away "$f" "$BK"; done

# harvest must not re-read what the migration already converted: mark every journal as fully read
while IFS= read -r ws; do
  : > "$ROOT/$ws/.harvest-state.tmp.$$"
  for j in "$ROOT/$ws"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.md; do
    [ -f "$j" ] || continue
    printf '%s\t%s\n' "$(basename "$j")" "$(wc -l < "$j" | tr -d ' ')" >> "$ROOT/$ws/.harvest-state.tmp.$$"
  done
  mv "$ROOT/$ws/.harvest-state.tmp.$$" "$ROOT/$ws/.harvest-state"
done < "$WS_LIST"
echo "$TODAY" > "$ROOT/.v5-migrated.tmp.$$" && mv "$ROOT/.v5-migrated.tmp.$$" "$ROOT/.v5-migrated"

# ---- 7. counts ----------------------------------------------------------------
say "7/7 counts (after expire)"
print_counts "$ROOT"
say "done. Backup: $BK"
exit 0
