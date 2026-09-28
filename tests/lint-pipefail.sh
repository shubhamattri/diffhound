#!/usr/bin/env bash
# tests/lint-pipefail.sh — fail on `producer | grep -q` in lib/ and bin/.
# Under set -o pipefail, grep -q exits at the first match, the producer still
# writing gets SIGPIPE, and the pipeline fails although it matched (#7642,
# #7693: complete chunk reviews reported as "Incomplete review"). Use a
# here-string or a file argument: grep -q PAT <<< "$var" / grep -q PAT file.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
hits=$(grep -rnE '(^|[^|])\|[[:space:]]*grep[^|]*[[:space:]]-[a-zA-Z]*q|^[[:space:]]*\|[[:space:]]*grep[^|]*[[:space:]]-[a-zA-Z]*q' \
         "$ROOT/lib" "$ROOT/bin" 2>/dev/null \
       | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
if [ -n "$hits" ]; then
  echo "FAIL pipefail lint: 'producer | grep -q' fails at random under set -o pipefail:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "ok   pipefail lint: no 'producer | grep -q' in lib/ or bin/"
