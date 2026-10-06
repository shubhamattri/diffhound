#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/voice.sh"
source "$ROOT/lib/parser.sh"
source "$ROOT/lib/publish.sh"
TMP=$(mktemp -d -t diffhound-voice-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
python3 - "$ROOT" "$TMP" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('test_voice', Path(sys.argv[1]) / 'tests/test-voice-output.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
Path(sys.argv[2], 'complete').write_text(m.COMPLETE)
Path(sys.argv[2], 'partial').write_text(m.COMPLETE.split('### INLINE_COMMENTS_END')[0])
PY
printf 'prompt' > "$TMP/prompt"
cp "$TMP/prompt" "$TMP/system"

printf '{"findings":[]}' > "$TMP/clean-primary"
printf '[]' > "$TMP/no-peers"
printf '[{"file":"a.py","line":1}]' > "$TMP/peers"
test "$(dh_voice_findings_expected "$TMP/clean-primary" "" "$TMP/no-peers")" = false
test "$(dh_voice_findings_expected "$TMP/clean-primary" "" "$TMP/peers")" = true
printf 'FINDING: a.py:1:NIT\n' > "$TMP/primary"
test "$(dh_voice_findings_expected "$TMP/primary" "" "$TMP/no-peers")" = true
test "$(dh_voice_findings_expected "$TMP/primary" "0" "$TMP/no-peers")" = false

# Stub the API boundary, including stop reason and response status.
_call_api_system() {
  cat >/dev/null
  echo "$2 $3 $5" >> "$TMP/calls"
  local n; n=$(wc -l < "$TMP/calls" | tr -d ' ')
  cat "$TMP/${BODIES[$((n-1))]}"
  printf '%s' "${STOPS[$((n-1))]}" > "$DIFFHOUND_STOP_REASON_FILE"
  return "${RCS[$((n-1))]}"
}

run() { : > "$TMP/calls"; dh_write_voice "$TMP/system" "$TMP/prompt" "$TMP/output" true 2>"$TMP/errors"; }
STOPS=(max_tokens end_turn); BODIES=(partial complete); RCS=(0 0)
run || { cat "$TMP/errors"; cat "$TMP/output".attempt-*.stderr; exit 1; }
cmp "$TMP/complete" "$TMP/output"
test "$(cat "$TMP/calls")" = $'128000 900 medium\n128000 900 low'
parse_summary "$TMP/output" "$TMP/summary"
! grep -q 'COMMENT:\|INLINE_COMMENTS' "$TMP/summary"
grep -q '## Scorecard' "$TMP/summary"

STOPS=(max_tokens max_tokens); BODIES=(partial complete); RCS=(0 0)
if run; then echo 'FAIL: token-exhausted retry accepted'; exit 1; fi
test ! -s "$TMP/output"

STOPS=(end_turn end_turn); BODIES=(complete partial); RCS=(1 0)
if run; then echo 'FAIL: failed API or partial retry accepted'; exit 1; fi
test ! -s "$TMP/output"

STOPS=(end_turn end_turn); BODIES=(complete complete); RCS=(0 0)
run
test "$(wc -l < "$TMP/calls" | tr -d ' ')" = 1

if parse_summary "$TMP/partial" "$TMP/summary" 2>/dev/null; then
  echo 'FAIL: parser accepted truncated voice response'; exit 1
fi
test ! -s "$TMP/summary"
test -n "$(dh_summary_leak_reason "$TMP/partial")"
echo 'PASS: voice attempts, retry exhaustion, parser and publish boundaries'
