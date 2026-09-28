#!/usr/bin/env bash
# tests/test-coverage-integrity.sh — #7693 run 20260928T114454Z-5920d40: three
# complete chunk replies (stop end_turn, findings present) were reported as
# unreviewed. On the runner the 17.9KB reply was a false gap in 25 of 50 checks.
# The check must be deterministic under set -o pipefail, as review.sh runs it.
# Set DIFFHOUND_REAL_CHUNK to a real archived chunk reply to test that file too
# (review archives hold private code, so none is committed here).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/parser.sh"
IFS=$'\n\t'
RUNS="${RUNS:-50}"
TMP=$(mktemp -d -t diffhound-covpf.XXXXXX); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# Shaped like the real reply (17.9KB, findings block ~2KB in): ~19KB, many writes.
mkfixture() {
  { for i in $(seq 1 15); do printf 'Context line %02d about the chunk under review, thread status and notes.......................................................................................................................\n' "$i"; done
    echo "### FINDINGS_START"
    for i in $(seq 1 76); do printf 'FINDING: src/file%02d.ts:%d:NIT\nEVIDENCE: %s\n' "$i" "$i" "$(printf 'x%.0s' $(seq 1 180))"; done
    echo "### FINDINGS_END"; } > "$1"
}

check() { # name file
  local d="$TMP/$1" n=0 r
  mkdir -p "$d"; cp "$2" "$d/chunk-0.out"; printf 'diff --git a/x b/x\n+x\n' > "$d/chunk-0.diff"; echo end_turn > "$d/chunk-0.stop"
  for ((r=0; r<RUNS; r++)); do [ -z "$(_chunk_coverage_gaps "$d" 1)" ] || n=$((n+1)); done
  if [ "$n" -eq 0 ]; then PASS=$((PASS+1)); echo "ok   $1: 0 false gaps in $RUNS runs"
  else FAIL=$((FAIL+1)); echo "FAIL $1: $n false gaps in $RUNS runs"; fi
}

mkfixture "$TMP/synthetic.out"
check "synthetic 7693-shaped reply" "$TMP/synthetic.out"
if [ -n "${DIFFHOUND_REAL_CHUNK:-}" ] && [ -s "$DIFFHOUND_REAL_CHUNK" ]; then
  check "real reply $(basename "$DIFFHOUND_REAL_CHUNK")" "$DIFFHOUND_REAL_CHUNK"
fi

# A reply without a findings block is still a gap.
printf 'I looked at the files.\n' > "$TMP/nofind.out"
d="$TMP/nofind"; mkdir -p "$d"; cp "$TMP/nofind.out" "$d/chunk-0.out"; printf 'diff\n' > "$d/chunk-0.diff"
if [ "$(_chunk_coverage_gaps "$d" 1)" = "0" ]; then PASS=$((PASS+1)); echo "ok   reply without findings block is a gap"
else FAIL=$((FAIL+1)); echo "FAIL reply without findings block is a gap"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
