#!/usr/bin/env bash
# tests/test-reverify.sh — unit tests for parser.sh::_reverify_absence_claims
# (re-review re-verification: drop "X doesn't exist" when X is actually defined).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/parser.sh"

PASS=0; FAIL=0; FAILED=()
TMP=$(mktemp -d -t diffhound-reverify.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Fake repo with a real gql constant definition.
mkdir -p "$TMP/repo/services/portal/src/graphql"
cat > "$TMP/repo/services/portal/src/graphql/queries.js" <<'JS'
export const GET_JOBS = gql`query { jobs }`;
export const SEARCH_ORGS = gql`query SearchOrgs($q: String!) { orgs(q: $q) { id } }`;
export const GET_ORG_ACTIVE_BENEFITS = gql`query($id: ID!) { benefits(orgId: $id) { id } }`;
JS

chk() { # name, haystack, needle
  if printf '%s' "$2" | grep -qF "$3"; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — wanted: $3"; echo "$2" | sed 's/^/     /'; fi
}
chk_empty() { # name, haystack
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — wanted empty, got:"; echo "$2" | sed 's/^/     /'; fi
}

# Case 1: defined symbols claimed absent → corrections emitted
out1="$TMP/out1.txt"
cat > "$out1" <<'TXT'
THREAD_STATUS: PolicyQaPane.vue:57
STATUS: STILL_OPEN
SEARCH_ORGS and GET_ORG_ACTIVE_BENEFITS don't exist anywhere in the codebase. the org-selection flow is dead.
TXT
r1=$(_reverify_absence_claims "$out1" "$TMP/repo")
chk "1: SEARCH_ORGS correction emitted" "$r1" '`SEARCH_ORGS` IS defined at'
chk "1: GET_ORG_ACTIVE_BENEFITS correction emitted" "$r1" '`GET_ORG_ACTIVE_BENEFITS` IS defined at'
chk "1: correction cites the file" "$r1" 'services/portal/src/graphql/queries.js'

# Case 2: genuinely-absent symbol → no correction
out2="$TMP/out2.txt"
echo "FOOBARXYZ doesn't exist anywhere in the codebase." > "$out2"
r2=$(_reverify_absence_claims "$out2" "$TMP/repo")
chk_empty "2: genuinely-missing symbol → no correction" "$r2"

# Case 3: absence phrase with a noise token that has no definition → no correction
out3="$TMP/out3.txt"
echo "the retry wrapper does not exist for HTTP calls here." > "$out3"
r3=$(_reverify_absence_claims "$out3" "$TMP/repo")
chk_empty "3: noise token without definition → no correction" "$r3"

# Case 4: no absence phrasing at all → no correction (even though SEARCH_ORGS appears)
out4="$TMP/out4.txt"
echo "SEARCH_ORGS query looks well-formed and is used correctly." > "$out4"
r4=$(_reverify_absence_claims "$out4" "$TMP/repo")
chk_empty "4: no absence claim → no correction" "$r4"

# Case 5: vuln claim on a NON-EXISTENT resolver -> correction (phantom resolver)
out5="$TMP/out5.txt"
cat > "$out5" <<'TXT'
THREAD_STATUS: queries.ts:546
STATUS: STILL_OPEN
`usersCount` is the companion resolver to `users` and it's unscoped — a restricted org admin can query cross-client count directly via GraphQL.
TXT
r5=$(_reverify_absence_claims "$out5" "$TMP/repo")
chk "5: phantom usersCount flagged as not-defined FP" "$r5" '`usersCount` is NOT defined anywhere'

# Case 6: vuln claim on a REAL symbol -> NO correction (it exists)
out6="$TMP/out6.txt"
echo "the \`SEARCH_ORGS\` query is unscoped and can query cross-client data." > "$out6"
r6=$(_reverify_absence_claims "$out6" "$TMP/repo")
if printf '%s' "$r6" | grep -qF 'SEARCH_ORGS` is NOT defined'; then
  FAIL=$((FAIL+1)); FAILED+=("6: must NOT flag real SEARCH_ORGS as phantom"); echo "FAIL 6: flagged real symbol as phantom"
else
  PASS=$((PASS+1)); echo "ok   6: real symbol vuln claim not flagged as phantom"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }
