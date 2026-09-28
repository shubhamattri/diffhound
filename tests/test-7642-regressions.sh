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

# review.sh runs with IFS=$'\n\t' (line 23); test its helpers under the same IFS.
# v0.7.41-v0.7.43 passed with the default IFS and broke on the VM.
IFS=$'\n\t'
PASS=0; FAIL=0; FAILED=()
TMP=$(mktemp -d -t diffhound-7642.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

eq() { # name, got, want
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — got [$2] want [$3]"; fi
}
has() { # name, haystack, needle
  if grep -qF -- "$3" <<< "$2"; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — missing: $3"; fi
}
lacks() { # name, haystack, needle
  if grep -qF -- "$3" <<< "$2"; then FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — unexpected: $3"
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
got=$(_select_merge_output "$merged" "end_turn" "$TMP/chunks" 0 1 2>/dev/null)
has   "merge: complete parseable merge is used" "$got" "(merged)"
got=$(_select_merge_output "$merged" "max_tokens" "$TMP/chunks" 0 1 2>/dev/null)
lacks "merge: truncated merge is not used"      "$got" "(merged)"
eq    "merge: truncated -> every raw finding"   "$(printf '%s\n' "$got" | grep -c '^FINDING:')" "2"
got=$(_select_merge_output "## Summary: requireEnabled declared twice, orphaned brace in preparation.ts" "end_turn" "$TMP/chunks" 0 1 2>/dev/null)
lacks "merge: prose-only merge is not used"     "$got" "requireEnabled"
eq    "merge: prose-only -> raw findings"       "$(printf '%s\n' "$got" | grep -c '^FINDING:')" "2"

# ── 4b. merge is split to fit its output limit, never truncated ────────────
eval "$(sed -n '/^_merge_chunk_group() {/,/^}/p' "$ROOT/lib/review.sh")"
eval "$(sed -n '/^_merge_chunk_findings() {/,/^}/p' "$ROOT/lib/review.sh")"
mk_chunk() { # dir idx findings-count pad-bytes
  local i n
  for ((n=0; n<$3; n++)); do printf 'FINDING: f%s.ts:%s:SHOULD-FIX\nWHAT: finding %s-%s\n' "$2" "$n" "$2" "$n"; done > "$1/chunk-$2.out"
  head -c "$4" /dev/zero | tr '\0' 'x' >> "$1/chunk-$2.out"; echo >> "$1/chunk-$2.out"
  printf 'f%s.ts\tSTANDARD\n' "$2" > "$1/chunk-$2.manifest"
}
_call_api() { # stub: merge = the first FINDING of its input, stop_reason from $STUB_STOP
  echo x >> "$CALLS"; [ -n "${DIFFHOUND_STOP_REASON_FILE:-}" ] && printf '%s' "${STUB_STOP:-end_turn}" > "$DIFFHOUND_STOP_REASON_FILE"
  grep -m1 -A1 '^FINDING:' | sed 's/WHAT: /WHAT: (merged) /'
}
M="$TMP/merge"; mkdir -p "$M"; CALLS="$TMP/calls"
mk_chunk "$M" 0 3 12000; mk_chunk "$M" 1 3 12000; mk_chunk "$M" 2 3 1000
eq "groups: split by byte budget" "$(_plan_merge_groups "$M" 3 20000 | tr '\n' '|')" "0|1 2|"
: > "$CALLS"; _merge_chunk_findings "$M" 3 "$TMP/merged.out" 2>/dev/null
eq "split merge: one model call per multi-chunk group" "$(wc -l < "$CALLS" | tr -d ' ')" "1"
has "split merge: single-chunk group keeps its raw findings" "$(cat "$TMP/merged.out")" "WHAT: finding 0-2"
has "split merge: merged group output is used" "$(cat "$TMP/merged.out")" "(merged)"
: > "$CALLS"; STUB_STOP=max_tokens _merge_chunk_findings "$M" 3 "$TMP/merged2.out" 2>/dev/null
eq "split merge: overflowing group falls back, all 9 findings kept" "$(grep -c '^FINDING:' "$TMP/merged2.out")" "9"
rm -f "$M"/chunk-*; : > "$CALLS"; _merge_chunk_findings "$M" 3 "$TMP/merged3.out" 2>/dev/null
eq "split merge: no chunk output, no model call" "$(wc -l < "$CALLS" | tr -d ' ')" "0"
unset -f _call_api

# ── 5. zero-findings guard on the voice pass ────────────────────────────────
echo '[]' > "$TMP/merged-empty.json"
echo '[{"file":"a.ts","line":1}]' > "$TMP/merged-one.json"
_voice_has_no_findings 0 "$TMP/merged-empty.json" && r=yes || r=no; eq "guard: 0 validated + [] peers fires"    "$r" "yes"
_voice_has_no_findings 0 ""                       && r=yes || r=no; eq "guard: 0 validated, no peer file fires" "$r" "yes"
_voice_has_no_findings 2 "$TMP/merged-empty.json" && r=yes || r=no; eq "guard: real findings do not fire"      "$r" "no"
_voice_has_no_findings 0 "$TMP/merged-one.json"   && r=yes || r=no; eq "guard: a peer finding does not fire"   "$r" "no"
eval "$(sed -n '/^    _count_findings() {/,/^    }/p' "$ROOT/lib/review.sh")"
printf 'prose only\n' > "$TMP/prose.txt"
eq "count: no findings is one line '0' (was '0\\n0')" "$(_count_findings "$TMP/prose.txt")" "0"
printf 'FINDING: a.ts:1:NIT\nWHAT: x\nEVIDENCE:\n```json\n{"a":1}\n```\n```json\n{"findings":[]}\n```\n  FINDING: b.ts:2:NIT\n' > "$TMP/two.txt"
eq "count: two findings despite quoted json fences" "$(_count_findings "$TMP/two.txt")" "2"
printf '```json\n{"findings":[{"file":"a.ts"},{"file":"b.ts"}]}\n```\n' > "$TMP/json.txt"
eq "count: JSON-format output still counted" "$(_count_findings "$TMP/json.txt")" "2"

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

# ── 8. --force-full is a full review, not a scoped re-review ─────────────────
LAST_REVIEWED_SHA=abc; PREV_SCORECARD_JSON='{"security":{"score":20,"max":25}}'
FORCE_FULL=false; _force_full_baseline && r=reset || r=kept
eq "force-full off: baseline kept" "$r:$LAST_REVIEWED_SHA" "kept:abc"
FORCE_FULL=true;  _force_full_baseline && r=reset || r=kept
eq "force-full: last-reviewed baseline dropped" "$r:$LAST_REVIEWED_SHA" "reset:"
eq "force-full: score anchor dropped" "$PREV_SCORECARD_JSON" ""
_rereview_verdict_capped true false REQUEST_CHANGES && r=capped || r=free; eq "cap: plain re-review capped"   "$r" "capped"
_rereview_verdict_capped true true  REQUEST_CHANGES && r=capped || r=free; eq "cap: force-full not capped"    "$r" "free"
_rereview_verdict_capped false false REQUEST_CHANGES && r=capped || r=free; eq "cap: fresh review not capped" "$r" "free"
eval "$(sed -n '/^_review_chunks_parallel() {/,/^}/p' "$ROOT/lib/review.sh")"
CD="$TMP/cchunks"; mkdir -p "$CD"
printf 'diff --git a/f0.ts b/f0.ts\n+x\n' > "$CD/chunk-0.diff"; printf 'f0.ts\tSTANDARD\n' > "$CD/chunk-0.manifest"
printf 'THREAD at f0.ts:1\n  REVIEWER: concern\n  AUTHOR_REPLY (dev): answered with evidence\n' > "$TMP/fthreads.txt"
printf 'f1.ts\n' > "$TMP/incr.txt"
LIB_DIR="$ROOT/lib"; _filter_rag_for_files() { : > "$3"; }; _trim_rag() { :; }; _call_api() { cat > /dev/null; }
FORCE_FULL=true _review_chunks_parallel "$CD" 1 "S" "" "$TMP" "" true "$TMP/fthreads.txt" "$TMP/incr.txt"; wait
got=$(cat "$CD/chunk-0.prompt")
has   "force-full chunk: full scrutiny header"     "$got" "EVERY FILE GETS FULL SCRUTINY"
has   "force-full chunk: author answer in context" "$got" "answered with evidence"
lacks "force-full chunk: no re-review blinders"     "$got" "# RE-REVIEW MODE"
FORCE_FULL=false _review_chunks_parallel "$CD" 1 "S" "" "$TMP" "" true "$TMP/fthreads.txt" "$TMP/incr.txt"; wait
has   "plain re-review chunk: blinders kept"       "$(cat "$CD/chunk-0.prompt")" "# RE-REVIEW MODE"
unset -f _call_api

# ── 9. post-review bookkeeping is time-boxed ────────────────────────────────
_within_time_budget 100 720 && r=run || r=defer; eq "budget: early run does bookkeeping" "$r" "run"
_within_time_budget 860 720 && r=run || r=defer; eq "budget: 14m run defers bookkeeping" "$r" "defer"
has "budget: the auto-learn loop checks the budget" "$(sed -n '/Auto-learn from ALL previous PR caches/,/Auto-learned from/p' "$ROOT/lib/review.sh")" "_within_time_budget"

# ── 10. v0.7.41 run 36394406728: an empty review must not post as a pass ─────
G="$TMP/gaps"; mkdir -p "$G"
for i in 0 1 2 3; do printf 'diff --git a/f%s b/f%s\n+x\n' $i $i > "$G/chunk-$i.diff"; done
printf '### CHUNK_FILES\nf0\n### FINDINGS_START\n### FINDINGS_END\n' > "$G/chunk-0.out"   # reviewed, nothing found
printf 'the code looks fine overall, nothing stands out\n' > "$G/chunk-1.out"             # prose, no findings block
: > "$G/chunk-2.out"                                                                     # empty text
printf '**FINDING:** f3.ts:1:NIT\nWHAT: x\n' > "$G/chunk-3.out"                          # decorated finding
eq "coverage: prose-only and empty chunks are gaps" "$(_chunk_coverage_gaps "$G" 4)" "1 2"
echo "CHUNK_0_FAILED" > "$G/chunk-0.out"
eq "coverage: failure marker is a gap" "$(_chunk_coverage_gaps "$G" 4)" "0 1 2"
_api_empty_is_failure "" && r=ok || r=fail;          eq "api: empty text is a failed call"   "$r" "fail"
_api_empty_is_failure $'  \n ' && r=ok || r=fail;    eq "api: whitespace text is a failed call" "$r" "fail"
_api_empty_is_failure "x" && r=ok || r=fail;         eq "api: text is a success"             "$r" "ok"
eq "gate: APPROVE with unreviewed chunks refused" \
  "$(_posting_gate_reason APPROVE 0 0 "1 2" false true HUGE)" "APPROVE while chunk(s) 1 2 produced no review"
has "gate: APPROVE when validators never ran (the #7642 shape) refused" \
  "$(_posting_gate_reason APPROVE 0 0 "" false false HUGE)" "validators never ran"
has "gate: APPROVE when validators failed refused" \
  "$(_posting_gate_reason APPROVE 0 0 "" true false HUGE)" "validator pipeline failed"
has "gate: validated findings but 0 comments refused, any verdict" \
  "$(_posting_gate_reason COMMENT 5 0 "" false true HUGE)" "findings were lost"
eq "gate: clean APPROVE with full coverage allowed" "$(_posting_gate_reason APPROVE 0 0 "" false true HUGE)" ""
eq "gate: APPROVE after validators dropped every finding allowed" "$(_posting_gate_reason APPROVE 0 0 "" false true HUGE)" ""
eq "gate: findings posted allowed" "$(_posting_gate_reason REQUEST_CHANGES 4 4 "" false true HUGE)" ""
eq "gate: small tier JSON path, validators optional" "$(_posting_gate_reason APPROVE 0 0 "" false false SMALL)" ""
has "gate: wired before posting" "$(sed -n '/REVIEW_EVENT=\$(parse_verdict/,/exit 1/p' "$ROOT/lib/review.sh")" "_posting_gate_reason"
has "api: _call_api fails on empty text" "$(sed -n '/^_call_api() {/,/^}/p' "$ROOT/lib/review.sh")" "_api_empty_is_failure"
has "api: _call_api_system fails on empty text" "$(sed -n '/^_call_api_system() {/,/^}/p' "$ROOT/lib/review.sh")" "_api_empty_is_failure"
rd=$(printf 'FINDING: a.ts:1:NIT\nWHAT: new thing\n' > "$TMP/cur.txt"; printf 'FINDING: b.ts:2:BLOCKING\nWHAT: `requireEnabled` declared twice\n' > "$TMP/prior.txt"; DIFFHOUND_PRIOR_FINDINGS="$TMP/prior.txt" python3 "$ROOT/lib/validators/round-diff.py" < "$TMP/cur.txt")
lacks "round-diff: a prior finding not repeated is not called resolved" "$rd" "RESOLVED:"
has   "round-diff: says it is not evidence of a fix" "$rd" "NOT evidence they were fixed"

# ── 11. run 36394406728 replay: chunk replies that were empty or cut off ────
# usage.tsv: 10 chunks wrote 71-4277 output tokens, one wrote 32000 with 30836
# thinking (cut off at max_tokens with a little text), and CLAUDE_OUT reached the
# validators as a single newline.
S="$TMP/stub"; mkdir -p "$S"
printf '#!/usr/bin/env bash\nshift; exec "$@"\n' > "$S/tmo"; chmod +x "$S/tmo"
printf '#!/usr/bin/env bash\ncat "$STUB_RESP"\n' > "$S/curl"; chmod +x "$S/curl"
eval "$(sed -n '/^_TEXT_BLOCKS=/p;/^_output_cfg() {/,/^}/p;/^_api_text_status() {/,/^}/p;/^_lower_effort() {/,/^}/p;/^_call_api() {/,/^}/p' "$ROOT/lib/review.sh")"
_cost_record() { cat > /dev/null; }
call() { # response-json -> "rc|stdout|stop"
  printf '%s' "$1" > "$S/resp.json"
  local out rc
  out=$(PATH="$S:$PATH" STUB_RESP="$S/resp.json" _TIMEOUT_CMD="$S/tmo" _ANTHROPIC_API_URL=x ANTHROPIC_API_KEY=x \
        DIFFHOUND_STOP_REASON_FILE="$S/stop" _call_api claude-opus-5 32000 600 "" < /dev/null 2>/dev/null); rc=$?
  printf '%s|%s|%s' "$rc" "$out" "$(cat "$S/stop" 2>/dev/null)"
}
eq "replay: thinking-only end_turn reply is a failed call, not an empty review" \
  "$(call '{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"x"}]}')" "1||end_turn"
eq "replay: whitespace-only text is a failed call" \
  "$(call '{"stop_reason":"end_turn","content":[{"type":"text","text":"\n\n"}]}')" "1||end_turn"
eq "replay: cut-off reply with text returns the text and records max_tokens" \
  "$(call '{"stop_reason":"max_tokens","content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"### FINDINGS_START\nFINDING: a.ts:1:NIT"}]}')" \
  "0|### FINDINGS_START
FINDING: a.ts:1:NIT|max_tokens"
R="$TMP/replay"; mkdir -p "$R"
for i in 0 1 2; do printf 'diff --git a/f%s b/f%s\n+x\n' $i $i > "$R/chunk-$i.diff"; done
printf '### FINDINGS_START\nFINDING: f0.ts:1:SHOULD-FIX\nWHAT: real\n' > "$R/chunk-0.out"; echo max_tokens > "$R/chunk-0.stop"
echo "CHUNK_1_FAILED" > "$R/chunk-1.out"
printf '### FINDINGS_START\n### FINDINGS_END\n' > "$R/chunk-2.out"; echo end_turn > "$R/chunk-2.stop"
eq "coverage: a cut-off chunk is a gap even with a findings block" "$(_chunk_coverage_gaps "$R" 3)" "0 1"
has "retry: a cut-off chunk retries at lower effort" "$(sed -n '/_CHUNK_GAPS=\$(_chunk_coverage_gaps/,/_retry_pids+=/p' "$ROOT/lib/review.sh")" '_geffort=$(_lower_effort high)'
lacks "chunk stderr no longer lands in the review text" "$(sed -n '/^_review_chunks_parallel() {/,/^}/p' "$ROOT/lib/review.sh")" 'chunk_out" 2>&1'
has "banner: unreviewed files are named on any verdict" "$(_coverage_banner "a.ts b.ts")" "a.ts b.ts"
has "banner: wired before the gate" "$(sed -n '/REVIEW_EVENT=\$(parse_verdict/,/_posting_gate_reason/p' "$ROOT/lib/review.sh")" "_coverage_banner"

# ── 12. run 36397076485 (v0.7.42): lists under IFS=$'\n\t', invented tool IO ──
M2="$TMP/merge2"; mkdir -p "$M2"
for i in 0 1 2 3; do printf 'FINDING: g%s.ts:1:SHOULD-FIX\nWHAT: finding %s\n' $i $i > "$M2/chunk-$i.out"; printf 'g%s.ts\tSTANDARD\n' $i > "$M2/chunk-$i.manifest"; done
_call_api() { cat > /dev/null; return 1; }   # merge model unavailable -> raw findings per group
DIFFHOUND_MERGE_GROUP_BYTES=80 _merge_chunk_findings "$M2" 4 "$TMP/m2.out" 2>/dev/null
eq "IFS: multi-chunk groups keep every chunk's findings" "$(grep -c '^FINDING:' "$TMP/m2.out")" "4"
DIFFHOUND_MERGE_GROUP_BYTES=100000 _merge_chunk_findings "$M2" 4 "$TMP/m3.out" 2>/dev/null
eq "IFS: one multi-chunk group keeps every chunk's findings" "$(grep -c '^FINDING:' "$TMP/m3.out")" "4"
unset -f _call_api
lacks "IFS: retry loop does not word-split the gap list" "$(cat "$ROOT/lib/review.sh")" 'for _gi in $_CHUNK_GAPS'
T2="$TMP/tool"; mkdir -p "$T2"
for i in 0 1; do printf 'diff --git a/t%s b/t%s\n+x\n' $i $i > "$T2/chunk-$i.diff"; done
cat > "$T2/chunk-0.out" <<'O'
{"name": "bash", "input": {"command": "cd /workspace && cat services/api/src/claims/claro/access.ts"}}
```text
export function requireEnabled() {}
export function requireEnabled() {}
```
### FINDINGS_START
FINDING: services/api/src/claims/claro/access.ts:2:BLOCKING
WHAT: `requireEnabled` is declared twice
### FINDINGS_END
O
printf '### FINDINGS_START\nFINDING: t1.ts:1:NIT\nWHAT: real\n### FINDINGS_END\n' > "$T2/chunk-1.out"
eq "tool IO: a reply with invented tool calls is a coverage gap" "$(_chunk_coverage_gaps "$T2" 2)" "0"
got=$(_select_merge_output "" "" "$T2" 0 1 2>/dev/null)
lacks "tool IO: findings built on invented file contents are not used" "$got" "requireEnabled"
has   "tool IO: other chunks' findings are kept" "$got" "FINDING: t1.ts:1:NIT"
lacks "prompt: chunk prompt no longer claims tools exist" "$(cat "$ROOT/lib/prompt-chunked.txt")" "access to the full codebase via Read and Bash tools"
lacks "prompt: monolithic prompt no longer claims tools exist" "$(cat "$ROOT/lib/review.sh")" "access to the full codebase via Read and Bash tools"
has   "prompt: chunk prompt says there are no tools" "$(cat "$ROOT/lib/prompt-chunked.txt")" "You have NO tools in this call"
has   "prompt: chunk prompt requires the findings block, empty allowed" "$(cat "$ROOT/lib/prompt-chunked.txt")" "leave it empty if you found nothing"
eval "$(sed -n '/^_run_log_dir() {/,/^}/p' "$ROOT/lib/review.sh")"
_LOG_TS=20260928T000000Z; _CACHE_REPO_ID=o-r; PR_NUMBER=1; HEAD_SHA=abcdef0123; unset _RUN_LOG_DIR
a=$(_run_log_dir); b=$(_run_log_dir)
eq "archive: every caller gets the same run log dir" "$a" "$b"
has "archive: _LOG_TS is set at startup (manifest used it unset under set -u)" "$(sed -n '1,600p' "$ROOT/lib/review.sh")" '_LOG_TS=$(date -u'
has "archive: chunk prompts are archived" "$(sed -n '/^_archive_chunk_outputs() {/,/^}/p' "$ROOT/lib/review.sh")" 'chunk-${i}.prompt'

# ── 13. run 36418822496: flaky coverage under pipefail; double posting ───────
# `producer | grep -q` under pipefail fails when grep exits before the producer
# finishes writing; a long complete reply was then judged "no findings block".
BIG="$TMP/big"; mkdir -p "$BIG"; printf 'diff --git a/b b/b\n+x\n' > "$BIG/chunk-0.diff"
{ printf '### FINDINGS_START\nFINDING: b.ts:1:NIT\nWHAT: x\n'; for i in $(seq 1 40000); do echo "EVIDENCE: long reply line $i"; done; printf '### FINDINGS_END\n'; } > "$BIG/chunk-0.out"
flaky=0; for r in 1 2 3; do [ -z "$(_chunk_coverage_gaps "$BIG" 1)" ] || flaky=$((flaky+1)); done
eq "pipefail: a long complete reply is never judged incomplete" "$flaky" "0"
ADIR="$TMP/adapter"; mkdir -p "$ADIR/repo"
{ printf 'FINDING: b.ts:1:NIT\nWHAT: `thing` could be named better\nUNVERIFIABLE: no\n'; for i in $(seq 1 20000); do echo "context line $i"; done; } > "$ADIR/in.txt"
got=$(DIFFHOUND_REPO="$ADIR/repo" DIFFHOUND_OFFLINE=1 DIFFHOUND_VALIDATORS_RUN=cat "$ROOT/lib/validators/format-adapter.sh" < "$ADIR/in.txt" 2>/dev/null | head -1)
eq "pipefail: format-adapter still sees FINDING blocks in a large input" "$got" "FINDING: b.ts:1:NIT"

# Posting: a POST that errors after GitHub created the review must not be repeated.
GH="$TMP/ghstub"; mkdir -p "$GH/bin"; : > "$GH/calls"
cat > "$GH/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GHSTATE/calls"
case "$*" in
  *"--method POST"*"/reviews"*)
    if [ -f "$GHSTATE/bulk_creates" ] && jq -e '.comments | length > 0' "${@: -1}" >/dev/null; then
      cp "${@: -1}" "$GHSTATE/created.json"; echo "HTTP 502" >&2; exit 1; fi
    if jq -e '.comments | length > 0' "${@: -1}" >/dev/null; then echo "HTTP 422 line" >&2; exit 1; fi
    exit 0 ;;
  *"--method POST"*"/comments"*) exit 0 ;;
  *"/reviews/77/comments"*) echo '[{"id":1},{"id":2}]' ;;
  *"/reviews"*)
    if [ -f "$GHSTATE/created.json" ]; then
      jq -c '[{id: 77, commit_id: .commit_id, user: {login: "bot"}, body: (.body + "\n")}]' "$GHSTATE/created.json"
    else echo '[]'; fi ;;
  *"/comments"*) cat "$GHSTATE/existing.json" 2>/dev/null || echo '[]' ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$GH/bin/gh"
printf 'diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -0,0 +1,3 @@\n+a\n+b\n+c\n' > "$GH/diff"
printf 'src/a.ts:1:BLOCKING — first\nsrc/a.ts:2:NIT — second\n' > "$GH/new"
mkrev() { jq -n '{commit_id: "sha1", event: "COMMENT", body: "## Scorecard 71/100", comments: [{path: "src/a.ts", line: 1, body: "first"}, {path: "src/a.ts", line: 2, body: "second"}]}' > "$GH/review.json"; }
spinner_fail() { :; }
mkrev; touch "$GH/bulk_creates"
( export GHSTATE="$GH" PATH="$GH/bin:$PATH" REVIEWER_LOGIN=bot
  post_review o r 1 sha1 COMMENT "$GH/summary" "$GH/review.json" "$GH/new" "$GH/diff" 2>/dev/null
  echo "$_POSTED_OK $_FINAL_COMMENT_COUNT" > "$GH/result" )
eq "post: review created despite a POST error is not posted again" "$(grep -c -- '--method POST' "$GH/calls")" "1"
eq "post: counted as posted with its inline comments" "$(cat "$GH/result")" "true 2"
rm -f "$GH/bulk_creates" "$GH/created.json"; : > "$GH/calls"
mkrev; : > "$GH/calls"
( export GHSTATE="$GH" PATH="$GH/bin:$PATH" REVIEWER_LOGIN=bot
  post_review o r 1 sha1 COMMENT "$GH/summary" "$GH/review.json" "$GH/new" "$GH/diff" >/dev/null 2>&1 )
first_body=$(grep -- '--method POST' "$GH/calls" | grep '/comments' | head -1)
eq "post: real bulk failure still falls back (failed bulk + body + each comment once)" "$(grep -c -- '--method POST' "$GH/calls")" "4"
bodyA=$(append_marker src/a.ts "first")
jq -n --arg b "$bodyA" '[{user: {login: "bot"}, path: "src/a.ts", line: 1, body: $b}]' > "$GH/existing.json"; : > "$GH/calls"
mkrev; : > "$GH/calls"
( export GHSTATE="$GH" PATH="$GH/bin:$PATH" REVIEWER_LOGIN=bot
  post_review o r 1 sha1 COMMENT "$GH/summary" "$GH/review.json" "$GH/new" "$GH/diff" >/dev/null 2>&1 )
eq "post: a comment already on the PR is not posted again in the fallback" "$(grep -- '--method POST' "$GH/calls" | grep -c '/comments')" "1"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf '  failed: %s\n' "${FAILED[@]}"; exit 1; }
