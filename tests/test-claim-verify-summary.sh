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
