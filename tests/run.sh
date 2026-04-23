#!/usr/bin/env bash
# tests/run.sh — fixture-replay test runner for lib/validators/*.sh
# Usage: tests/run.sh [validator-name]   # omit to run all
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
VALIDATORS_DIR="$ROOT/lib/validators"
PASS=0
FAIL=0
FAILED_NAMES=()

only="${1:-}"

if [ ! -d "$FIXTURES" ]; then
  echo "No fixtures directory at $FIXTURES"
  exit 0
fi

for vdir in "$FIXTURES"/*/; do
  [ -d "$vdir" ] || continue
  vname="$(basename "$vdir")"
  [ -n "$only" ] && [ "$only" != "$vname" ] && continue

  script="$VALIDATORS_DIR/$vname.sh"
  if [ ! -x "$script" ]; then
    # Also support .py validators (for checklist-execute)
    py_script="$VALIDATORS_DIR/$vname.py"
    if [ -x "$py_script" ]; then
      script="$py_script"
    else
      echo "SKIP  $vname (no $script or $py_script)"
      continue
    fi
  fi

  for case_dir in "$vdir"*/; do
    [ -d "$case_dir" ] || continue
    cname="$(basename "$case_dir")"
    input="$case_dir/input.txt"
    expected="$case_dir/expected.txt"
    repo="$case_dir/repo"
    if [ ! -f "$input" ] || [ ! -f "$expected" ]; then
      echo "BROKEN $vname/$cname (missing input.txt or expected.txt)"
      continue
    fi

    # Optional: prior-findings file for round-diff
    if [ -f "$case_dir/prior.txt" ]; then
      actual=$(env DIFFHOUND_REPO="$repo" DIFFHOUND_PRIOR_FINDINGS="$case_dir/prior.txt" "$script" < "$input" 2>/dev/null)
    else
      actual=$(env DIFFHOUND_REPO="$repo" "$script" < "$input" 2>/dev/null)
    fi
    expected_content=$(cat "$expected")
    if [ "$actual" = "$expected_content" ]; then
      echo "PASS  $vname/$cname"
      PASS=$((PASS+1))
    else
      echo "FAIL  $vname/$cname"
      diff <(printf '%s' "$actual") <(printf '%s' "$expected_content") 2>&1 | sed 's/^/      /' | head -30
      FAIL=$((FAIL+1))
      FAILED_NAMES+=("$vname/$cname")
    fi
  done
done

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
