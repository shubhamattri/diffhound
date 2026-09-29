#!/bin/bash
# Diffhound GitHub Action entrypoint
# Translates composite-action inputs into diffhound CLI args.

set -euo pipefail

DIFFHOUND_BIN="${DIFFHOUND_BIN:-/opt/diffhound/bin/diffhound}"

PR_NUMBER="${INPUT_PR_NUMBER:-${1:-}}"
MODE="${INPUT_MODE:-full}"
AUTO_POST="${INPUT_AUTO_POST:-true}"
REPO_PATH="${INPUT_REPO_PATH:-${GITHUB_WORKSPACE:-}}"
REPO_NAME="${GITHUB_REPOSITORY:-}"

if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: pr-number input required" >&2
  exit 2
fi

# Diffhound runs `git clone` internally for --repo mode. GH_TOKEN in env is not
# picked up by raw git. Use gh's credential helper without storing the token in
# a git config URL (which can appear in logs and persisted image volumes).
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git
fi

# Direct Docker invocation follows the CLI exactly, including slash commands.
# Configure credentials first so private --repo clones work here too.
if [ "$#" -gt 0 ] && [ -z "${INPUT_PR_NUMBER:-}" ]; then
  exec "$DIFFHOUND_BIN" "$@"
fi

# Diffhound reads the current repo from $PWD — cd into the checkout
if [ -n "$REPO_PATH" ] && [ -d "$REPO_PATH" ]; then
  cd "$REPO_PATH"
fi

ARGS=("$PR_NUMBER")

COMMAND="${INPUT_COMMAND:-review}"
if [ "$COMMAND" != review ]; then
  case "$COMMAND" in ask|describe|labels|changelog) ;; *) echo "Unknown command: $COMMAND" >&2; exit 2 ;; esac
  ARGS=("/$COMMAND" "$PR_NUMBER")
  [ -z "${INPUT_QUESTION:-}" ] || ARGS+=(--question "$INPUT_QUESTION")
  [ "${INPUT_APPLY:-false}" != true ] || ARGS+=(--apply)
  [ -z "$REPO_NAME" ] || ARGS+=(--repo "$REPO_NAME")
  exec "$DIFFHOUND_BIN" "${ARGS[@]}"
fi

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

[ "${GITHUB_EVENT_NAME:-}" != pull_request ] || [ -z "${GITHUB_EVENT_PATH:-}" ] \
  || [ "$(jq -r '.action' "$GITHUB_EVENT_PATH")" != synchronize ] || ARGS+=(--synchronize)

exec "$DIFFHOUND_BIN" "${ARGS[@]}"
