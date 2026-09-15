#!/usr/bin/env bash
# tests/test-peer-validate.sh — unit tests for peer-validate.sh::_validate_peer_output
#
# The bug this pins (v0.7.33): Gemini returns its answer inside a ```json fence,
# and the truncation guard demanded sentence-ending punctuation as the final
# character. A backtick is not in that set, so COMPLETE peer reviews were binned
# and coverage read 1/2. Measured 3-of-4 live runs discarded this way.
#
# The cases below deliberately test BOTH directions: fenced-and-complete must be
# kept, and cut-off-mid-answer must still be thrown away. A fix that just added
# a backtick to the accepted set would pass the first and fail the second.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/peer-validate.sh"

PASS=0; FAIL=0; FAILED=()

# run <content> -> prints the file contents after validation; stderr captured to $ERRF
ERRF=$(mktemp -t pverr.XXXXXX)
run() {
  local f; f=$(mktemp -t pvin.XXXXXX)
  printf '%s' "$1" > "$f"
  : > "$ERRF"
  _validate_peer_output "$f" "GEMINI" 2>"$ERRF"
  cat "$f"; rm -f "$f"
}
kept() {
  if [ "$2" != "GEMINI_UNAVAILABLE" ] && [ -n "$2" ]; then
    PASS=$((PASS+1)); echo "ok   $1"
  else
    FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — expected KEPT, got marker. stderr: $(cat "$ERRF")"
  fi
}
binned() {
  if [ "$2" = "GEMINI_UNAVAILABLE" ]; then
    PASS=$((PASS+1)); echo "ok   $1"
  else
    FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — expected DISCARDED, got: $(printf '%s' "$2" | head -c 80)"
  fi
}
contains() {
  if printf '%s' "$2" | grep -qF "$3"; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — want substring: $3"; fi
}
lacks() {
  if printf '%s' "$2" | grep -qF "$3"; then FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — must NOT contain: $3"
  else PASS=$((PASS+1)); echo "ok   $1"; fi
}

# ── Case 1: THE BUG. Complete fenced JSON, exactly the shape Gemini returns. ──
C1=$(run '```json
{
  "verdict": "the primary review is broadly right about the deleted suite",
  "findings": [
    { "file": "tests/reports.spec.ts", "severity": "NIT", "what": "trailing newline removed" }
  ],
  "claims": [],
  "unverifiable": false
}
```')
kept     "1: complete fenced JSON is KEPT (was discarded pre-v0.7.33)" "$C1"
contains "1: content survives the fence strip" "$C1" '"verdict"'
lacks    "1: wrapper fence removed" "$C1" '```json'

# ── Case 2: the guard must still work — cut off mid-JSON, no closing fence ────
C2=$(run '```json
{
  "verdict": "this response was cut off by the model hitting its output cap",
  "findings": [
    { "file": "tests/reports.spec.ts", "severity": "BLOCKING", "what": "incomp')
binned "2: truncated mid-JSON still DISCARDED (guard intact)" "$C2"

# ── Case 3: plain prose ending in a full stop (how the Sonnet peer answers) ───
C3=$(run 'AFFIRMED: the deletion of the migrateAsset suite is safe because the export
is gone from the module, confirmed against the diff at reports.ts:41.
FALSE_POSITIVES: none worth reporting in this changeset.')
kept "3: plain text ending in '.' is KEPT" "$C3"

# ── Case 4: real answers are never this small ────────────────────────────────
C4=$(run 'ok.')
binned   "4: under 100 bytes DISCARDED" "$C4"
contains "4: warns with the byte count" "$(cat "$ERRF")" "too short"

# ── Case 5: nothing at all — the killed-subshell signature ───────────────────
C5=$(run '')
binned   "5: empty output DISCARDED" "$C5"
contains "5: empty case now WARNS (was silent)" "$(cat "$ERRF")" "no output at all"

# ── Case 6: CLI wrapper noise after a complete answer ────────────────────────
C6=$(run 'AFFIRMED: nothing in this diff changes runtime behaviour, it is a test-only
deletion and the remaining suite still covers the reporting queries end to end.
mcp startup: no servers
tokens used 1423')
kept  "6: trailing CLI noise stripped, answer KEPT" "$C6"
lacks "6: noise line gone" "$C6" "mcp startup:"

# ── Case 7: opening fence but no closing fence = still truncated ─────────────
C7=$(run '```
AFFIRMED: the primary analysis is correct that the export was removed, and the
integration suite no longer references it anywhere in the changed files, so')
binned "7: unclosed fence still DISCARDED" "$C7"

# ── Case 8: a fence in the MIDDLE is content, not a wrapper ──────────────────
C8=$(run 'AFFIRMED: the suggested replacement is right. Use this instead:

```ts
const rows = await db.select().from(reports);
```

That keeps the FK-violation path covered without the deleted helper.')
kept     "8: mid-text fence is left alone" "$C8"
contains "8: inline code block preserved" "$C8" 'db.select()'

rm -f "$ERRF"
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '  failed: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
