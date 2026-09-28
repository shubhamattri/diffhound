#!/usr/bin/env bash
# tests/test-7642-regressions.sh — regressions from monorepo PR #7642 (Sep 2026):
#   - comment/review lists read only GitHub's first page (30 items)
#   - chunked re-reviews dropped the body and replies of every prior thread
#   - the chunk merge was cut off at 4096 tokens / unparseable, bypassing validators
#   - the voice pass's zero-findings guard could never fire
#   - "declared twice" / "no import" claims were posted about code that compiled
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/parser.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/github.sh"

PASS=0; FAIL=0; FAILED=()
TMP=$(mktemp -d -t diffhound-7642.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

eq() { # name, got, want
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — got [$2] want [$3]"; fi
}
has() { # name, haystack, needle
  if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — missing: $3"; fi
}
lacks() { # name, haystack, needle
  if printf '%s' "$2" | grep -qF -- "$3"; then FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — unexpected: $3"
  else PASS=$((PASS+1)); echo "ok   $1"; fi
}

# ── 1. pagination: every page, as ONE array ─────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# Stub: without --paginate return page 1 only, like the real gh api.
case " $* " in *" --paginate "*) all=1 ;; *) all=0 ;; esac
page() { python3 -c "import json,sys; s,e=int(sys.argv[1]),int(sys.argv[2]); print(json.dumps([{'id':i,'user':{'login':'bot'},'body':'r%d'%i,'commit_id':'sha%03d'%i,'submitted_at':'2026-09-%02dT00:00:00Z'%(1+i//10)} for i in range(s,e)]))" "$1" "$2"; }
page 0 30
[ "$all" = 1 ] && { page 30 60; page 60 75; }
SH
chmod +x "$TMP/bin/gh"
got=$(PATH="$TMP/bin:$PATH" _gh_api_all "/repos/o/r/pulls/1/reviews")
eq "pagination: one JSON array"                "$(printf '%s' "$got" | jq -s 'length')" "1"
eq "pagination: all 75 items, not the first 30" "$(printf '%s' "$got" | jq 'length')" "75"
last=$(printf '%s' "$got" | jq -r '[.[] | {user: .user.login, body, commit_id, submitted_at} | select(.user == "bot" and .body != "")] | sort_by(.submitted_at) | last | .commit_id')
eq "pagination: last reviewed commit is the newest one" "$last" "sha074"
eq "pagination: gh failure yields []" "$(PATH="$TMP/nobin:/usr/bin:/bin" _gh_api_all /x 2>/dev/null | jq -c .)" "[]"

# ── 2. chunk thread filter keeps whole threads, exact paths only ────────────
cat > "$TMP/threads.txt" <<'T'
THREAD at services/api/src/claims/handler.ts:513
  REVIEWER: cache invalidation failures are silently swallowed on the trx path
  AUTHOR_REPLY (dev): Leaving as is. invalidateBalanceSiCache never rejects, it logs its own Redis failure in utils/cache.ts:47.
THREAD at services/api/src/claims/claro/access.ts:19
  REVIEWER: requireEnabled naming
THREAD at services/api/src/claimsXhandler.ts:4
  REVIEWER: regex metachar decoy
T
printf 'services/api/src/claims/handler.ts\tCRITICAL\n' > "$TMP/manifest.tsv"
got=$(_filter_threads_for_files "$TMP/threads.txt" "$TMP/manifest.tsv")
has   "threads: keeps the reviewer's concern"   "$got" "REVIEWER: cache invalidation failures"
has   "threads: keeps the author's answer"      "$got" "AUTHOR_REPLY (dev): Leaving as is."
lacks "threads: drops other files' threads"     "$got" "requireEnabled naming"
lacks "threads: '.' in a path is not a regex"   "$got" "regex metachar decoy"

# ── 3. markdown-decorated findings become parseable ─────────────────────────
got=$(printf '**FINDING:** `a/b.ts:12:BLOCKING`\n- WHAT: x\n### EVIDENCE: y\n1. **FINDING**: c.ts:3:NIT\nprose WHAT: stays\n' | _normalize_finding_markup)
eq "normalize: FINDING lines recognised" "$(printf '%s\n' "$got" | grep -c '^FINDING: ')" "2"
has "normalize: header is plain"          "$got" "FINDING: a/b.ts:12:BLOCKING"
has "normalize: field is plain"           "$got" "WHAT: x"
has "normalize: prose untouched"          "$got" "prose WHAT: stays"

# ── 4. merge selection: never a truncated or unparseable merge ──────────────
mkdir -p "$TMP/chunks"
printf 'FINDING: a.ts:1:BLOCKING\nWHAT: real one\n' > "$TMP/chunks/chunk-0.out"
printf '**FINDING:** b.ts:2:SHOULD-FIX\nWHAT: real two\n' > "$TMP/chunks/chunk-1.out"
merged='FINDING: a.ts:1:BLOCKING
WHAT: real one (merged)'
got=$(_select_merge_output "$merged" "end_turn" "$TMP/chunks" 2 2>/dev/null)
has   "merge: complete parseable merge is used" "$got" "(merged)"
got=$(_select_merge_output "$merged" "max_tokens" "$TMP/chunks" 2 2>/dev/null)
lacks "merge: truncated merge is not used"      "$got" "(merged)"
eq    "merge: truncated -> every raw finding"   "$(printf '%s\n' "$got" | grep -c '^FINDING:')" "2"
got=$(_select_merge_output "## Summary: requireEnabled declared twice, orphaned brace in preparation.ts" "end_turn" "$TMP/chunks" 2 2>/dev/null)
lacks "merge: prose-only merge is not used"     "$got" "requireEnabled"
eq    "merge: prose-only -> raw findings"       "$(printf '%s\n' "$got" | grep -c '^FINDING:')" "2"

# ── 5. zero-findings guard on the voice pass ────────────────────────────────
echo '[]' > "$TMP/merged-empty.json"
echo '[{"file":"a.ts","line":1}]' > "$TMP/merged-one.json"
_voice_has_no_findings 0 "$TMP/merged-empty.json" && r=yes || r=no; eq "guard: 0 validated + [] peers fires"    "$r" "yes"
_voice_has_no_findings 0 ""                       && r=yes || r=no; eq "guard: 0 validated, no peer file fires" "$r" "yes"
_voice_has_no_findings 2 "$TMP/merged-empty.json" && r=yes || r=no; eq "guard: real findings do not fire"      "$r" "no"
_voice_has_no_findings 0 "$TMP/merged-one.json"   && r=yes || r=no; eq "guard: a peer finding does not fire"   "$r" "no"
eval "$(sed -n '/^    _count_findings() {/,/^    }/p' "$ROOT/lib/review.sh")"
_extract_json() { :; }
printf 'prose only\n' > "$TMP/prose.txt"
eq "count: no findings is one line '0' (was '0\\n0')" "$(_count_findings "$TMP/prose.txt")" "0"
printf 'FINDING: a.ts:1:NIT\nWHAT: x\n  FINDING: b.ts:2:NIT\n' > "$TMP/two.txt"
eq "count: two findings" "$(_count_findings "$TMP/two.txt")" "2"

printf 'prose\n### SCORECARD_START\nSecurity: 20/25 — ok\nBlocking: a.ts:1\nShouldFix: NONE\nTotal: 80/100 — COMMENT\n### SCORECARD_END\n' > "$TMP/sc.txt"
got=$(_scorecard_only "$TMP/sc.txt")
has   "guard: scorecard still reaches the voice pass" "$got" "Security: 20/25"
lacks "guard: rejected finding list is stripped"     "$got" "Blocking: a.ts:1"
lacks "guard: prose is not passed"                   "$got" "prose"

# ── 6. inline comments: false declaration/import claims never post ─────────
mkdir -p "$TMP/repo/src"
cat > "$TMP/repo/src/access.ts" <<'TS'
import { v4 as uuid } from "uuid";
export function requireEnabled() {
  if (process.env.X !== "true") throw new Error("off");
}
export const makeId = () => uuid();
TS
cat > "$TMP/repo/src/dup.ts" <<'TS'
export const KIND = "a";
export const KIND = "b";
export const make = () => randomUUID();
TS
cat > "$TMP/comments.txt" <<'C'
COMMENT: src/access.ts:2:BLOCKING — requireEnabled is declared twice here, both with identical bodies. won't compile.
COMMENT: src/access.ts:5:BLOCKING — `uuid()` is called with no import, ReferenceError at runtime.
COMMENT: src/dup.ts:2:BLOCKING — `KIND` is declared twice in this file, duplicate identifier.
COMMENT: src/dup.ts:3:BLOCKING — `randomUUID()` is used without an import.
COMMENT: src/access.ts:3:SHOULD-FIX — the flag check reads process.env on every call, cache it.
COMMENT: src/access.ts:1:BLOCKING — duplicate const declarations, fails TS compile.
COMMENT: src/dup.ts:1:BLOCKING — duplicate const declarations here, fails TS compile.
REPLY: 123:src/access.ts:2 — still open, requireEnabled is declared twice.
C
_claim_verify_comments "$TMP/comments.txt" "$TMP/repo" 2>/dev/null
got=$(cat "$TMP/comments.txt")
lacks "comments: false duplicate claim removed"      "$got" "requireEnabled is declared twice here"
lacks "comments: false missing-import claim removed" "$got" "is called with no import"
has   "comments: real duplicate kept"                "$got" "\`KIND\` is declared twice"
has   "comments: real missing import kept"           "$got" "\`randomUUID()\` is used without an import"
has   "comments: unrelated finding kept"             "$got" "cache it"
lacks "comments: unnamed duplicate, none in file, removed" "$got" "src/access.ts:1:BLOCKING"
has   "comments: unnamed duplicate, real, kept"      "$got" "src/dup.ts:1:BLOCKING"
has   "comments: thread replies untouched"           "$got" "REPLY: 123"

# ── 7. summary bullets get the same check ───────────────────────────────────
cat > "$TMP/summary.md" <<'S'
### Blockers (must fix before merge)
- `src/access.ts:2` — requireEnabled declared twice with identical body
- `src/dup.ts:2` — `KIND` declared twice, duplicate identifier
S
_claim_verify_summary "$TMP/summary.md" "$TMP/repo" "" 2>/dev/null
got=$(cat "$TMP/summary.md")
lacks "summary: false duplicate bullet removed" "$got" "requireEnabled declared twice"
has   "summary: real duplicate bullet kept"     "$got" "KIND"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf '  failed: %s\n' "${FAILED[@]}"; exit 1; }
