#!/usr/bin/env bash
# tests/test-mono-cutoff-retry.sh — #7695: the single-call path got a reply cut
# off at max_tokens (text came back, so no failure retry) and APPROVE was capped.
# A cut-off reply must be retried once at lower effort; a complete one never.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/parser.sh"
# shellcheck disable=SC1090
eval "$(sed -n '/^_lower_effort() {/,/^}/p' "$ROOT/lib/api.sh")"
eval "$(sed -n '/^_mono_retry_cutoff() {/,/^}/p' "$ROOT/lib/review.sh")"
TMP=$(mktemp -d -t diffhound-monoretry.XXXXXX); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 — want [$3] got [$2]"; fi; }

# Stub: records each call's effort; writes RETRY_STOP to the stop file, prints RETRY_OUT, exits RETRY_RC.
_call_api() {
  cat > /dev/null
  echo "$4" >> "$TMP/calls"
  [ -n "${DIFFHOUND_STOP_REASON_FILE:-}" ] && printf '%s' "$RETRY_STOP" > "$DIFFHOUND_STOP_REASON_FILE"
  printf '%s' "$RETRY_OUT"
  return "$RETRY_RC"
}

run() { # first_stop retry_stop retry_out retry_rc
  : > "$TMP/calls"; echo prompt > "$TMP/prompt"; printf 'first reply' > "$TMP/out"
  printf '%s' "$1" > "$TMP/stop"
  RETRY_STOP="$2" RETRY_OUT="$3" RETRY_RC="$4" _mono_retry_cutoff "$TMP/prompt" "$TMP/out" "$TMP/stop" 60 2>/dev/null
}
calls() { wc -l < "$TMP/calls" | tr -d ' '; }

run max_tokens end_turn "full reply" 0
check "cut off -> exactly one retry" "$(calls)" "1"
check "cut off -> retry at medium effort" "$(cat "$TMP/calls")" "medium"
check "cut off, retry ends end_turn -> no gap" "$(_monolithic_gap "$TMP/stop")" ""
check "cut off -> retry reply replaces the partial one" "$(cat "$TMP/out")" "full reply"

run end_turn end_turn "unused" 0
check "end_turn -> no retry" "$(calls)" "0"
check "end_turn -> no gap" "$(_monolithic_gap "$TMP/stop")" ""
check "end_turn -> reply untouched" "$(cat "$TMP/out")" "first reply"

run max_tokens max_tokens "still partial" 0
check "retry also cut off -> still one retry only" "$(calls)" "1"
check "retry also cut off -> gap stays" "$(_monolithic_gap "$TMP/stop")" "all"

run max_tokens "" "" 1
check "retry fails -> gap stays (stop not blanked)" "$(_monolithic_gap "$TMP/stop")" "all"
check "retry fails -> partial reply kept" "$(cat "$TMP/out")" "first reply"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
