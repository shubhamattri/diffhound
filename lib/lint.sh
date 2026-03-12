#!/bin/bash
# diffhound — Static analyzer pre-pass
# Runs eslint (JS/TS) and ruff (Python) on changed files.
# Output is injected into prompt so LLM doesn't waste tokens on lint issues.

_LINT_SOURCED=true

# Run static analysis on changed files extracted from diff.
# $1 = diff_file, $2 = repo_path
# Outputs formatted lint findings to stdout.
_run_static_analysis() {
  local diff_file="$1"
  local repo_path="$2"

  # Extract unique changed file paths from diff
  local changed_files
  changed_files=$(grep '^diff --git' "$diff_file" 2>/dev/null | \
    sed 's|^diff --git a/.* b/||' | sort -u)
  [ -z "$changed_files" ] && return 0

  local has_eslint=false has_ruff=false
  command -v eslint &>/dev/null && has_eslint=true
  command -v ruff &>/dev/null && has_ruff=true

  # Nothing to run
  [ "$has_eslint" = false ] && [ "$has_ruff" = false ] && return 0

  local output=""
  local file_count=0

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local full_path="${repo_path}/${file}"
    [ -f "$full_path" ] || continue

    local ext="${file##*.}"
    local lint_result=""

    case "$ext" in
      ts|tsx|js|jsx|vue)
        if [ "$has_eslint" = true ]; then
          # Minimal rules — no .eslintrc needed. 10s timeout per file.
          lint_result=$(timeout 10 eslint --no-eslintrc \
            --rule 'no-unused-vars: warn' \
            --rule 'no-undef: error' \
            --rule 'eqeqeq: warn' \
            --parser-options=ecmaVersion:2022 \
            --format compact \
            "$full_path" 2>/dev/null | grep -v "^$" | head -20) || true
        fi
        ;;
      py)
        if [ "$has_ruff" = true ]; then
          # E=errors, W=warnings, F=pyflakes. 10s timeout.
          lint_result=$(timeout 10 ruff check --select E,W,F \
            --output-format concise \
            "$full_path" 2>/dev/null | head -20) || true
        fi
        ;;
    esac

    if [ -n "$lint_result" ]; then
      output+="### ${file}"$'\n'
      output+="${lint_result}"$'\n'$'\n'
      file_count=$((file_count + 1))
    fi
  done <<< "$changed_files"

  if [ -n "$output" ] && [ "$file_count" -gt 0 ]; then
    echo "## STATIC ANALYSIS FINDINGS (pre-computed — do NOT re-flag these)"
    echo "The following lint issues were found by automated tools."
    echo "Do NOT include these as findings — they are already reported to the developer separately."
    echo "Focus your review on logic, design, and security issues instead."
    echo ""
    echo "$output"
  fi
}
