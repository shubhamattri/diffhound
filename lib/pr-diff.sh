#!/bin/bash
# Use the metadata snapshot's commits when GitHub refuses an oversized patch.
# Args: repository path, base SHA, head SHA, output file.
_dh_git_pr_diff() {
  local repo="$1" base="$2" head="$3" output="$4" sha shallow
  if ! [[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Cannot build PR diff: missing or invalid base/head SHA" >&2
    return 1
  fi
  for sha in "$base" "$head"; do
    if ! git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      if ! $_TIMEOUT_CMD 300 git -C "$repo" fetch --no-tags origin "$sha"; then
        echo "Cannot fetch pinned PR commit $sha" >&2
        return 1
      fi
    fi
  done
  shallow=$(git -C "$repo" rev-parse --is-shallow-repository) || return 1
  # A shallow boundary can hide the common ancestor. Fetch complete ancestry
  # for these exact commits; never substitute a branch tip or two-dot diff.
  if [ "$shallow" = true ]; then
    if ! $_TIMEOUT_CMD 300 git -C "$repo" fetch --no-tags --unshallow origin "$base" "$head"; then
      echo "Cannot fetch complete PR ancestry" >&2
      return 1
    fi
  fi
  $_TIMEOUT_CMD 300 git -C "$repo" diff --no-ext-diff --no-textconv \
    --no-color --no-relative --src-prefix=a/ --dst-prefix=b/ --find-renames \
    "$base...$head" -- > "$output"
}

# Args: PR number, repository path, base SHA, head SHA, output file.
# API errors stay on stderr, never in review input. Other API failures still
# fail closed; only GitHub's explicit patch-size rejection selects Git.
dh_fetch_pr_diff() (
  local pr="$1" repo="$2" base="$3" head="$4" output="$5" error
  error=$(mktemp -t dh-pr-diff.XXXXXX) || return 1
  trap 'rm -f "$error"' EXIT
  if $_TIMEOUT_CMD 300 gh pr diff "$pr" > "$output" 2> "$error"; then
    return 0
  fi
  cat "$error" >&2
  if grep -qF 'diff exceeded the maximum number of lines' "$error"; then
    echo "  GitHub diff too large; building complete diff from pinned Git commits" >&2
    if _dh_git_pr_diff "$repo" "$base" "$head" "$output"; then
      return 0
    fi
  fi
  rm -f "$output"
  return 1
)
