#!/usr/bin/env bash
# tests/test-derive-score.sh — unit tests for parser.sh::_derive_scorecard_from_summary
# Score = 100 - 20*Blockers - 7*ShouldFix - 2*Nits, floored at 0. No findings -> 100.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/parser.sh"

PASS=0; FAIL=0; FAILED=()
run() { local f; f=$(mktemp -t derivesc.XXXXXX); printf '%s\n' "$1" > "$f"; _derive_scorecard_from_summary "$f"; cat "$f"; rm -f "$f"; }
has()  { if printf '%s' "$2" | grep -qF "$3"; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — want: $3"; printf '%s\n' "$2" | sed 's/^/     /'; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF "$3"; then FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — must NOT contain: $3"; else PASS=$((PASS+1)); echo "ok   $1"; fi; }

# Case 1: clean review (no findings) -> 100/100, old vibe-table replaced
C1=$(run 'great work.

## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| Security (25%) | 23/25 | fine |
| Tests (20%) | 12/20 | thin |
| **Total** | **86/100** | **APPROVE** |

### Blockers (must fix before merge)
none

### Should-Fix (merge ok, follow-up needed)
none

### Nits
none')
has   "1: clean -> 100/100"          "$C1" "100/100"
has   "1: verdict word preserved"     "$C1" "(APPROVE)"
has   "1: labeled derived"            "$C1" "Scorecard (derived from findings)"
hasnt "1: old 86 gone"                "$C1" "86/100"
hasnt "1: vibe category row gone"     "$C1" "Tests (20%)"

# Case 2: 1 blocker, 2 should-fix, 3 nits -> 100-20-14-6 = 60
C2=$(run '## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| Security (25%) | 10/25 | bad |
| **Total** | **40/100** | **REQUEST_CHANGES** |

### Blockers (must fix before merge)
- `a.ts:1` — guard removed

### Should-Fix (merge ok, follow-up needed)
- `b.ts:2` — no log
- `c.ts:3` — magic number

### Nits
- `d.ts:4` — naming
- `e.ts:5` — spacing
- `f.ts:6` — comment')
has "2: 1B/2S/3N -> 60/100"  "$C2" "60/100"
has "2: blocking count 1"     "$C2" "| Blocking | 1 |"
has "2: shouldfix count 2"    "$C2" "| Should-Fix | 2 |"
has "2: nit count 3"          "$C2" "| Nit | 3 |"

# Case 3: floor at 0 (many blockers)
C3=$(run '## Scorecard
| **Total** | **5/100** | **REQUEST_CHANGES** |

### Blockers (must fix before merge)
- `a:1` — x
- `b:2` — x
- `c:3` — x
- `d:4` — x
- `e:5` — x
- `f:6` — x')
has "3: 6 blockers floored at 0" "$C3" "0/100"

echo ""; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; }
