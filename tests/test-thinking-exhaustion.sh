#!/usr/bin/env bash
# tests/test-thinking-exhaustion.sh — a response that spent every output token on
# thinking must be detected (exit 2), never returned as an empty "success".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_TEXT_BLOCKS='[.content[] | select(.type == "text") | .text] | join("")'
# shellcheck disable=SC1090
eval "$(sed -n '/^_api_text_status() {/,/^}/p;/^_lower_effort() {/,/^}/p' "$ROOT/lib/review.sh")"
PASS=0; FAIL=0
check(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 — want [$3] got [$2]"; fi; }

r='{"stop_reason":"max_tokens","content":[{"type":"thinking","thinking":""}]}'
out=$(printf '%s' "$r" | _api_text_status); rc=$?
check "thinking-only max_tokens -> rc 2" "$rc" "2"
check "thinking-only max_tokens -> no text" "$out" ""

r='{"stop_reason":"max_tokens","content":[{"type":"thinking","thinking":""},{"type":"text","text":"partial {"}]}'
out=$(printf '%s' "$r" | _api_text_status); rc=$?
check "truncated WITH text -> rc 0 (caller handles partial)" "$rc" "0"
check "truncated WITH text -> text kept" "$out" "partial {"

r='{"stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}'
out=$(printf '%s' "$r" | _api_text_status); rc=$?
check "normal -> rc 0" "$rc" "0"
check "normal -> text" "$out" "ok"

out=$(printf '' | _api_text_status); rc=$?
check "empty response (network fail) -> rc 0, caller's own checks apply" "$rc" "0"

check "effort high -> medium" "$(_lower_effort high)" "medium"
check "effort medium -> low" "$(_lower_effort medium)" "low"
check "effort low -> none" "$(_lower_effort low)" ""
check "effort unset -> none" "$(_lower_effort "")" ""

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
