#!/bin/bash
# diffhound — platform detection & compatibility
# Handles macOS vs Linux differences for timeout, awk, etc.

if [ "$(uname -s)" = "Darwin" ]; then
  _TIMEOUT_CMD="gtimeout"
  _AWK_CMD="gawk"
  # Fallback: if gawk not installed on macOS, use awk (will error on 3-arg match)
  command -v gawk >/dev/null 2>&1 || _AWK_CMD="awk"
else
  _TIMEOUT_CMD="timeout"
  _AWK_CMD="awk"
fi

# Verify required dependencies
_check_deps() {
  local missing=()

  command -v gh >/dev/null 2>&1 || missing+=("gh (GitHub CLI)")
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v claude >/dev/null 2>&1 || missing+=("claude (Claude Code CLI)")
  command -v "$_TIMEOUT_CMD" >/dev/null 2>&1 || missing+=("$_TIMEOUT_CMD")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: Missing required dependencies:" >&2
    for dep in "${missing[@]}"; do
      echo "  - $dep" >&2
    done
    if [ "$(uname -s)" = "Darwin" ]; then
      echo "" >&2
      echo "Install via: brew install coreutils gawk jq gh" >&2
    fi
    exit 1
  fi
}
