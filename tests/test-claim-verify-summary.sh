#!/usr/bin/env bash
# tests/test-claim-verify-summary.sh — unit tests for parser.sh::_claim_verify_summary
# (the single-chokepoint deterministic scrub over final summary bullets — the
# re-review FP fix for monorepo #7317 SEARCH_ORGS/usersCount/marked).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DIFFHOUND_CLAIM_VERIFY=1
# shellcheck disable=SC1091
source "$ROOT/lib/parser.sh"

PASS=0; FAIL=0; FAILED=()
TMP=$(mktemp -d -t cvsum.XXXXXX); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/services/portal/src/graphql"
printf 'export const SEARCH_ORGS = gql`q`;\nexport const users = async()=>[];\n' > "$TMP/repo/services/portal/src/graphql/queries.js"
printf '{"dependencies":{"marked":"^1.1.0"}}' > "$TMP/repo/package.json"

cat > "$TMP/summary.md" <<'EOF'
review body here.

### Blockers (must fix before merge)
- `SEARCH_ORGS` and `GET_ORG_ACTIVE_BENEFITS` don't exist anywhere in the repo — dead flow.
- the `users` resolver is unscoped — real cross-client leak, no scope applied.
- `usersCount` is the companion resolver to `users` and is unscoped — cross-client count leak.

### Should-Fix (merge ok, follow-up needed)
- `contactNumber` (full phone) is logged in structured logs on every failure — PII.

### Nits
- `enrichedPolicies` computed is dead, safe to delete.
EOF

_claim_verify_summary "$TMP/summary.md" "$TMP/repo"
OUT=$(cat "$TMP/summary.md")

has()  { if printf '%s' "$2" | grep -qF "$3"; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — wanted: $3"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF "$3"; then FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — must NOT contain: $3"; else PASS=$((PASS+1)); echo "ok   $1"; fi; }

hasnt "SEARCH_ORGS absence FP removed"   "$OUT" "SEARCH_ORGS"
hasnt "usersCount phantom-vuln removed"  "$OUT" "usersCount"
has   "real users-resolver kept"          "$OUT" "the \`users\` resolver is unscoped"
has   "real PII should-fix kept"          "$OUT" "contactNumber"
has   "nit kept"                          "$OUT" "enrichedPolicies"
has   "section headers intact"            "$OUT" "### Blockers"

echo ""; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }

# --- Scenario 2: EXPLICIT structured claims catch what prose-matching misses ---
# "defined nowhere" wording is NOT in the implicit absence_re, but the model's
# explicit file_contains claim (expected:false, but SEARCH_ORGS IS in queries.js)
# verifies FALSE -> bullet dropped via file:line match (the #7317 fix).
mkdir -p "$TMP/repo2/services/portal/src/portal/graphql" "$TMP/repo2/svc"
printf 'export const SEARCH_ORGS = gql`q`;\n' > "$TMP/repo2/services/portal/src/portal/graphql/queries.js"
printf '{"dependencies":{"marked":"^1.1.0"}}' > "$TMP/repo2/package.json"
cat > "$TMP/structured2.json" <<'JSON'
```json
{
  "summary": "x",
  "thread_statuses": [
    {"file":"services/portal/src/portal/pages/support/PolicyQaPane.vue","line":57,"status":"STILL_OPEN",
     "claims":[{"type":"file_contains","subject":"SEARCH_ORGS","location":"services/portal/src/portal/graphql/queries.js","expected":false}]}
  ],
  "findings": []
}
```
JSON
cat > "$TMP/summary2.md" <<'MD'
body.

### Blockers (must fix before merge)
- `PolicyQaPane.vue:57` — `SEARCH_ORGS` is imported but defined nowhere. dead flow.
- `RealFile.ts:10` — missing null check on user input.
MD
_claim_verify_summary "$TMP/summary2.md" "$TMP/repo2" "$TMP/structured2.json"
OUT2=$(cat "$TMP/summary2.md")
hasnt "S2: SEARCH_ORGS bullet dropped via EXPLICIT claim (defined nowhere)" "$OUT2" "SEARCH_ORGS"
has   "S2: unrelated real bullet kept" "$OUT2" "RealFile.ts:10"

echo ""; echo "FINAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }

# --- Scenario 3: method_exists (dep API) is UNVERIFIABLE -> must NOT block ---
mkdir -p "$TMP/repo3/services/portal/src/components"
printf 'import marked from "marked";\n' > "$TMP/repo3/services/portal/src/components/PolicyQaMessage.vue"
printf '{"dependencies":{"marked":"^1.1.0"}}' > "$TMP/repo3/package.json"
cat > "$TMP/structured3.json" <<'JSON'
```json
{"summary":"x","findings":[],"thread_statuses":[
  {"file":"services/portal/src/components/PolicyQaMessage.vue","line":53,"status":"STILL_OPEN",
   "claims":[{"type":"method_exists","subject":"marked","method":"parse","expected":false}]}
]}
```
JSON
cat > "$TMP/summary3.md" <<'MD'
body.

### Blockers (must fix before merge)
- `PolicyQaMessage.vue:53` — `marked.parse()` doesn't exist in marked@^1.1.0, throws TypeError.
- `Other.ts:9` — real off-by-one in loop bound.
MD
_claim_verify_summary "$TMP/summary3.md" "$TMP/repo3" "$TMP/structured3.json"
OUT3=$(cat "$TMP/summary3.md")
hasnt "S3: marked.parse dep-API blocker dropped (unverifiable -> not a blocker)" "$OUT3" "marked.parse"
has   "S3: unrelated real bullet kept" "$OUT3" "Other.ts:9"
echo ""; echo "FINAL2 PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }

# --- Scenario 4: dropping the sole FP blocker reconciles verdict to APPROVE ---
mkdir -p "$TMP/repo4/svc"
printf 'export const SEARCH_ORGS = gql`query{}`;\n' > "$TMP/repo4/svc/queries.js"
cat > "$TMP/structured4.json" <<'JSON'
```json
{"summary":"x","findings":[],"thread_statuses":[
  {"file":"svc/PolicyQaPane.vue","line":57,"status":"STILL_OPEN",
   "claims":[{"type":"file_contains","subject":"SEARCH_ORGS","location":"svc/queries.js","expected":false}]}
]}
```
JSON
cat > "$TMP/summary4.md" <<'MD'
re-review. one blocker still open.

### Blockers (must fix before merge)
- `PolicyQaPane.vue:57` — `SEARCH_ORGS` imported but never defined anywhere

## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| Compatibility (15%) | 5/15 | SEARCH_ORGS undefined |
| **Total** | **92/100** | **REQUEST_CHANGES** — one blocker needs fixing |
MD
_claim_verify_summary "$TMP/summary4.md" "$TMP/repo4" "$TMP/structured4.json"
OUT4=$(cat "$TMP/summary4.md")
hasnt "S4: FP blocker bullet dropped" "$OUT4" "imported but never defined"
has   "S4: verdict reconciled to APPROVE in Total row" "$OUT4" "**APPROVE**"
hasnt "S4: stale REQUEST_CHANGES gone from Total" "$OUT4" "REQUEST_CHANGES"
# parse_verdict must now return APPROVE (Total row is source of truth)
echo '{"verdict":"REQUEST_CHANGES"}' > "$TMP/sv4.json"
PV=$(parse_verdict "$TMP/summary4.md" "$TMP/sv4.comments" 2>/dev/null)
[ "$PV" = "APPROVE" ] && { echo "ok   S4: parse_verdict honors reconciled APPROVE"; PASS=$((PASS+1)); } || { echo "FAIL S4: parse_verdict=$PV (want APPROVE)"; FAIL=$((FAIL+1)); FAILED+=("S4 parse_verdict"); }
echo ""; echo "FINAL3 PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }

# --- Scenario 5: structured JSON with a LITERAL control char (newline in a
#     string value) must still parse (strict=False) and drop the FP. This is the
#     #7317 marked-leak root cause: json.load() threw -> silent no-op. ---
mkdir -p "$TMP/repo5/svc"
printf 'export const SEARCH_ORGS = gql`q`;\n' > "$TMP/repo5/svc/queries.js"
# NOTE: the "evidence" value below contains a REAL newline (invalid strict JSON).
printf '%s\n' '```json' > "$TMP/structured5.json"
printf '%s\n' '{"summary":"x","findings":[],"thread_statuses":[' >> "$TMP/structured5.json"
printf '%s\n' '  {"file":"svc/PolicyQaPane.vue","line":57,"status":"STILL_OPEN",' >> "$TMP/structured5.json"
printf '%s\n' '   "evidence":"grep across services/ returns only the import line' >> "$TMP/structured5.json"
printf '%s\n' 'on a second line — this raw newline breaks strict JSON",' >> "$TMP/structured5.json"
printf '%s\n' '   "claims":[{"type":"file_contains","subject":"SEARCH_ORGS","location":"svc/queries.js","expected":false}]}' >> "$TMP/structured5.json"
printf '%s\n' ']}' >> "$TMP/structured5.json"
printf '%s\n' '```' >> "$TMP/structured5.json"
cat > "$TMP/summary5.md" <<'MD'
re-review.

### Blockers (must fix before merge)
- `PolicyQaPane.vue:57` — `SEARCH_ORGS` imported but never defined anywhere

## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| **Total** | **92/100** | **REQUEST_CHANGES** — one blocker |
MD
_claim_verify_summary "$TMP/summary5.md" "$TMP/repo5" "$TMP/structured5.json"
OUT5=$(cat "$TMP/summary5.md")
hasnt "S5: FP dropped despite control-char in structured JSON" "$OUT5" "imported but never defined"
has   "S5: verdict reconciled to APPROVE" "$OUT5" "**APPROVE**"
echo ""; echo "FINAL4 PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }

# --- Scenario 6: empty Blockers/Should-Fix but Nits + Open-Question bullets
#     present must reconcile to APPROVE (not miscount later-section bullets as
#     blockers). This is the #7317 awk-interval portability bug. ---
mkdir -p "$TMP/repo6"
cat > "$TMP/summary6.md" <<'MD'
re-review: prior blockers resolved.

### Blockers (must fix before merge)
none

### Should-Fix (merge ok, follow-up needed)
none

### Nits
- `Foo.vue:55` — dead code, delete when convenient
- `Bar.vue:12` — naming nit

### Open Questions (needs an answer, not a code change)
- `~2000 lines, 0 tests` — follow-up ticket for coverage?

## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| **Total** | **88/100** | **REQUEST_CHANGES** — blocking issue(s) must be fixed before merge |
MD
_claim_verify_summary "$TMP/summary6.md" "$TMP/repo6" ""
OUT6=$(cat "$TMP/summary6.md")
# 88/100, no surviving blockers/should-fix -> APPROVE. If the awk-interval bug
# miscounted the Nits/Open-Q bullets as blockers, it would force REQUEST_CHANGES.
has   "S6: high score + nits/open-q only -> APPROVE (interval bug fixed)" "$OUT6" "**APPROVE**"
hasnt "S6: stale REQUEST_CHANGES gone" "$OUT6" "REQUEST_CHANGES"
has   "S6: nit bullets preserved" "$OUT6" "dead code, delete when convenient"

# --- Scenario 7: blocker dropped as FP but SCORE is low -> coherent
#     REQUEST_CHANGES, NEVER "low-score APPROVE" (Shubham's 58/100-APPROVE bug). ---
mkdir -p "$TMP/repo7/svc"
printf 'export const SEARCH_ORGS = gql`q`;\n' > "$TMP/repo7/svc/queries.js"
cat > "$TMP/structured7.json" <<'JSON'
```json
{"summary":"x","findings":[],"thread_statuses":[
  {"file":"svc/PolicyQaPane.vue","line":57,"status":"STILL_OPEN",
   "claims":[{"type":"file_contains","subject":"SEARCH_ORGS","location":"svc/queries.js","expected":false}]}
]}
```
JSON
cat > "$TMP/summary7.md" <<'MD'
re-review.

### Blockers (must fix before merge)
- `PolicyQaPane.vue:57` — `SEARCH_ORGS` imported but never defined anywhere

### Nits
- `Foo.vue:9` — dead code

## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| Tests (20%) | 2/20 | zero tests for ~2000 lines |
| **Total** | **58/100** | **REQUEST_CHANGES** — one blocker |
MD
_claim_verify_summary "$TMP/summary7.md" "$TMP/repo7" "$TMP/structured7.json"
OUT7=$(cat "$TMP/summary7.md")
hasnt "S7: FP blocker dropped" "$OUT7" "imported but never defined"
hasnt "S7: NEVER low-score APPROVE (the 58/100-APPROVE bug)" "$OUT7" "**APPROVE**"
has   "S7: coherent REQUEST_CHANGES at low score" "$OUT7" "**REQUEST_CHANGES**"
has   "S7: reason cites the score gap, not a phantom blocker" "$OUT7" "below the approval bar"
echo ""; echo "FINAL5 PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }

# --- Scenario 8: `usage` claim — data-flow FP (the #7291 clientNames class) +
#     the conservative safety direction (absent -> UNVERIFIABLE -> NOT dropped). ---
mkdir -p "$TMP/repo8/svc"
cat > "$TMP/repo8/svc/queries.js" <<'JS'
const clientIds = await getEffectiveClientIds(ctx.user, args.filter?.clientId, {
  orgId: args.filter?.orgId,
  clientNames: args.filter?.clientNames,
});
JS
cat > "$TMP/structured8.json" <<'JSON'
```json
{"summary":"x","findings":[],"thread_statuses":[
  {"file":"svc/queries.js","line":1,"status":"STILL_OPEN",
   "claims":[{"type":"usage","subject":"clientNames","scope":"getEffectiveClientIds","expected":false}]},
  {"file":"svc/queries.js","line":2,"status":"STILL_OPEN",
   "claims":[{"type":"usage","subject":"unicornFlag","scope":"getEffectiveClientIds","expected":false}]}
]}
```
JSON
cat > "$TMP/summary8.md" <<'MD'
re-review.

### Blockers (must fix before merge)
- `queries.js:1` — `clientNames` is never passed to `getEffectiveClientIds`, so claims client-name filtering silently does nothing
- `queries.js:2` — `unicornFlag` is never passed to `getEffectiveClientIds`, real gap

## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| **Total** | **80/100** | **REQUEST_CHANGES** — two blockers |
MD
_claim_verify_summary "$TMP/summary8.md" "$TMP/repo8" "$TMP/structured8.json"
OUT8=$(cat "$TMP/summary8.md")
hasnt "S8: clientNames data-flow FP dropped (it IS passed)" "$OUT8" "claims client-name filtering silently does nothing"
has   "S8: SAFETY — genuinely-absent usage claim NOT dropped (unverifiable, kept)" "$OUT8" "unicornFlag"
echo ""; echo "FINAL6 PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }
