#!/usr/bin/env bash
# tests/run.sh — fixture-replay test runner for lib/validators/*.sh
# Usage: tests/run.sh [validator-name]   # omit to run all
#
# Per-fixture env override: if a case directory contains an `env.sh` file,
# the runner sources it (in a subshell) before invoking the validator. Use
# this to opt specific fixtures into env vars like
# DIFFHOUND_VERIFIER_MOCK_FILE or ANTHROPIC_API_KEY without polluting the
# default offline-passthrough behavior other fixtures rely on.
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

    # Optional: prior-findings file for round-diff / dedup-helper legacy path,
    # and prior-keys.txt for dedup-helper v0.5.6+ exact-tuple path.
    _env_args=(DIFFHOUND_REPO="$repo")
    [ -f "$case_dir/prior.txt" ] && _env_args+=(DIFFHOUND_PRIOR_FINDINGS="$case_dir/prior.txt")
    [ -f "$case_dir/prior-keys.txt" ] && _env_args+=(DIFFHOUND_PRIOR_KEYS="$case_dir/prior-keys.txt")
    # Unset ANTHROPIC_API_KEY so verifier-stage fixtures take the offline
    # passthrough branch deterministically — tests must not depend on the
    # dev's parent-shell environment. Fixtures that need an API key in
    # scope (e.g. to exercise the mock verdict branch) can opt in by
    # dropping an env.sh file inside the case directory; it's sourced in
    # a subshell before the validator runs.
    if [ -f "$case_dir/env.sh" ]; then
      # Strip the trailing slash so env.sh can reference DIFFHOUND_FIXTURE_DIR
      # naturally (e.g. "$DIFFHOUND_FIXTURE_DIR/mock.jsonl").
      fixture_dir="${case_dir%/}"
      actual=$(env -u ANTHROPIC_API_KEY "${_env_args[@]}" \
        DIFFHOUND_FIXTURE_DIR="$fixture_dir" bash -c '
        # shellcheck disable=SC1090
        source "$1"
        shift
        "$@"
      ' _ "$case_dir/env.sh" "$script" < "$input" 2>/dev/null)
    else
      actual=$(env -u ANTHROPIC_API_KEY "${_env_args[@]}" "$script" < "$input" 2>/dev/null)
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
