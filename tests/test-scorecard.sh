#!/usr/bin/env bash
# tests/test-scorecard.sh — unit tests for canonical scorecard normalization
# in lib/parser.sh::_normalize_markdown_scorecard_total
#
# Canonical weights (sum = 100):
#   Security 25, Tests 20, Observability 10, Performance 15, Readability 15, Compatibility 15
#
# Run: tests/test-scorecard.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/parser.sh"

PASS=0; FAIL=0; FAILED=()

# run_norm <summary-markdown> -> prints normalized summary
run_norm() {
  local f; f=$(mktemp -t diffhound-sc.XXXXXX)
  printf '%s\n' "$1" > "$f"
  _normalize_markdown_scorecard_total "$f"
  cat "$f"
  rm -f "$f"
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF "$needle"; then
    PASS=$((PASS+1)); echo "ok   $name"
  else
    FAIL=$((FAIL+1)); FAILED+=("$name"); echo "FAIL $name"
    echo "     expected to find: $needle"
    echo "     in:"; printf '%s\n' "$hay" | sed 's/^/       /'
  fi
}

# --- Case A: dropped category (Performance missing) → maxes sum to 85, must become /100 ---
A=$(run_norm '| Category | Score | Notes |
|----------|-------|-------|
| Security | 25/25 | fine |
| Tests | 20/20 | ok |
| Observability | 10/10 | ok |
| Readability | 15/15 | ok |
| Compatibility | 15/15 | ok |
| **Total** | **85/85** | **APPROVE** |')
# five present cats all full (85/85) → normalized 100/100; Performance shown not-scored
assert_contains "A: total is /100 not /85" "$A" "100/100"
assert_contains "A: Performance marked not scored" "$A" "not scored (excluded from total)"

# --- Case B: wrong max (Security 18/20 instead of /25) → rescale to /25, total /100 ---
B=$(run_norm '| Category | Score | Notes |
|----------|-------|-------|
| Security | 18/20 | weak |
| Tests | 20/20 | ok |
| Observability | 10/10 | ok |
| Performance | 15/15 | ok |
| Readability | 15/15 | ok |
| Compatibility | 15/15 | ok |
| **Total** | **93/110** | **COMMENT** |')
# 18/20 -> round(18/20*25)=23 ; total = 23+20+10+15+15+15 = 98 / 100
assert_contains "B: security rescaled to /25" "$B" "23/25"
assert_contains "B: total is /100" "$B" "98/100"

# --- Case C: all six correct → denominator already 100, total preserved ---
C=$(run_norm '| Category | Score | Notes |
|----------|-------|-------|
| Security | 20/25 | x |
| Tests | 18/20 | x |
| Observability | 9/10 | x |
| Performance | 12/15 | x |
| Readability | 14/15 | x |
| Compatibility | 13/15 | x |
| **Total** | **86/100** | **COMMENT** |')
assert_contains "C: total stays /100" "$C" "86/100"

# --- Case D: JSON-path style names with (25%) suffix + UPPERCASE ---
D=$(run_norm '| Category | Score | Notes |
|----------|-------|-------|
| SECURITY (25%) | 25/25 | x |
| TESTS (20%) | 20/20 | x |
| OBSERVABILITY (10%) | 10/10 | x |
| PERFORMANCE (15%) | 15/15 | x |
| READABILITY (15%) | 15/15 | x |
| COMPATIBILITY (15%) | 15/15 | x |
| **Total** | **100/100** | **APPROVE** |')
assert_contains "D: parses (NN%) names, total /100" "$D" "100/100"

# --- Case E: missing category with NON-full present scores → proportional normalize, no invented score ---
E=$(run_norm '| Category | Score | Notes |
|----------|-------|-------|
| Security | 20/25 | x |
| Tests | 16/20 | x |
| Observability | 8/10 | x |
| Readability | 12/15 | x |
| Compatibility | 12/15 | x |
| **Total** | **68/85** | **COMMENT** |')
# present sum 68/85 → round(68/85*100)=80 ; Performance not scored, NOT back-filled to 15/15
assert_contains "E: total normalized to /100" "$E" "80/100"
assert_contains "E: missing cat not invented" "$E" "not scored (excluded from total)"
# guard against the old back-fill-full behavior leaking back
if printf '%s' "$E" | grep -qF "15/15"; then
  FAIL=$((FAIL+1)); FAILED+=("E: must NOT back-fill Performance to 15/15"); echo "FAIL E: must NOT back-fill Performance to 15/15"
else
  PASS=$((PASS+1)); echo "ok   E: does not back-fill missing category"
fi

# --- Case F: out-of-range NEGATIVE score (real #7317 bug) → clamp to 0/max, no leak, single row ---
F=$(run_norm '| Category | Score | Notes |
|----------|-------|-------|
| Security | 22/25 | x |
| Tests | 2/20 | x |
| Observability | 5/10 | x |
| Performance | 13/15 | x |
| Readability | 12/15 | x |
| Compatibility | -16/15 | build breaks |
| **Total** | **38/110** | **REQUEST_CHANGES** |')
# -16 clamped to 0 → Compatibility 0/15 ; total = 22+2+5+13+12+0 = 54/100
assert_contains "F: negative clamped to 0/15" "$F" "Compatibility (15%) | 0/15"
assert_contains "F: total 54/100" "$F" "54/100"
if printf '%s' "$F" | grep -qF -- "-16/15"; then
  FAIL=$((FAIL+1)); FAILED+=("F: leaked raw -16/15"); echo "FAIL F: leaked raw -16/15"
else
  PASS=$((PASS+1)); echo "ok   F: no leaked -16/15"
fi
_compat_rows=$(printf '%s\n' "$F" | grep -c "Compatibility (15%)")
if [ "$_compat_rows" = "1" ]; then
  PASS=$((PASS+1)); echo "ok   F: single Compatibility row"
else
  FAIL=$((FAIL+1)); FAILED+=("F: $_compat_rows Compatibility rows (want 1)"); echo "FAIL F: $_compat_rows Compatibility rows (want 1)"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
