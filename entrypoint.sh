#!/bin/bash
# Diffhound GitHub Action entrypoint
# Translates composite-action inputs into diffhound CLI args.

set -euo pipefail

PR_NUMBER="${INPUT_PR_NUMBER:-${1:-}}"
MODE="${INPUT_MODE:-full}"
AUTO_POST="${INPUT_AUTO_POST:-true}"
REPO_PATH="${INPUT_REPO_PATH:-${GITHUB_WORKSPACE:-}}"
REPO_NAME="${GITHUB_REPOSITORY:-}"

if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: pr-number input required" >&2
  exit 2
fi

# Diffhound reads the current repo from $PWD — cd into the checkout
if [ -n "$REPO_PATH" ] && [ -d "$REPO_PATH" ]; then
  cd "$REPO_PATH"
fi

ARGS=("$PR_NUMBER")

# Pass --repo so diffhound knows repo identity without REVIEW_REPO_PATH/LOGIN env vars
if [ -n "$REPO_NAME" ]; then
  ARGS+=(--repo "$REPO_NAME")
fi

case "$MODE" in
  full)   ;;  # no flag — full is the default
  fast)   ARGS+=(--fast) ;;
  learn)  ARGS+=(--learn) ;;
  *)
    echo "ERROR: mode must be one of: full, fast, learn (got: $MODE)" >&2
    exit 2
    ;;
esac

if [ "$AUTO_POST" = "true" ]; then
  ARGS+=(--auto-post)
fi

exec /opt/diffhound/bin/diffhound "${ARGS[@]}"
