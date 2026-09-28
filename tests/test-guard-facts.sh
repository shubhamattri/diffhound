#!/usr/bin/env bash
# tests/test-guard-facts.sh — "unguarded / can throw on X.y" claims are dropped
# only when an early exit on the same identifier dominates the cited line
# (monorepo #7693). Covers the inline-comment path; fixtures cover claim-verify.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/claim-checkers.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/parser.sh"
IFS=$'\n\t'
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 — got [$2] want [$3]"; fi; }
FX="$ROOT/tests/fixtures/claim-verify"
P=services/api/src/processors/zohoCrmProductWebhook.ts
W='unguarded payload.productId/productStage in the catch path can throw'

g() { DIFFHOUND_REPO="$FX/$1/repo" _check_guard_text "$P" "$2" "$3"; }
eq "guard before the only call dominates the param use" "$(g guard-dominates-fp-7693 11 "$W")" "FALSE"
eq "guard on another identifier proves nothing" "$(g keep-guard-other-identifier 11 "$W")" "TRUE"
eq "guard inside a branch does not dominate" "$(g keep-guard-in-sibling-branch 11 "$W")" "TRUE"
eq "a second, unguarded caller keeps the finding" "$(g keep-guard-unguarded-caller 11 "$W")" "TRUE"
eq "value claim needs a guard on that exact member" \
   "$(g guard-dominates-fp-7693 13 'payload.productStage may be undefined here')" "TRUE"
eq "value claim on the guarded member is false" \
   "$(g guard-dominates-fp-7693 11 'payload.productId may be undefined here')" "FALSE"
eq "text without a null-safety claim is not judged" "$(g guard-dominates-fp-7693 11 'payload.productId is logged twice')" "NOCLAIM"

TMP=$(mktemp -d -t diffhound-guard.XXXXXX); trap 'rm -rf "$TMP"' EXIT
printf 'COMMENT: %s:11 — %s\nCOMMENT: %s:13 — payload.productStage may be undefined here\n' "$P" "$W" "$P" > "$TMP/c"
_claim_verify_comments "$TMP/c" "$FX/guard-dominates-fp-7693/repo" 2>/dev/null
eq "inline comment with a dominated claim is removed, the other kept" "$(grep -c . "$TMP/c")/$(grep -c ':13 ' "$TMP/c")" "1/1"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
