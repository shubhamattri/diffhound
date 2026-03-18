#!/bin/bash
# diffhound — Static analyzer pre-pass
# Runs eslint (JS/TS), type-shape pattern detector (TS), and ruff (Python) on changed files.
# Output is injected into prompt so LLM doesn't waste tokens on lint issues.

_LINT_SOURCED=true

# Detect data-shape mismatches in TS/JS files using grep patterns.
# These are bugs where Object methods are used on arrays or vice versa.
# $1 = changed_files (newline-separated), $2 = repo_path
_run_shape_check() {
  local changed_files="$1"
  local repo_path="$2"

  local output=""
  local file_count=0

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local ext="${file##*.}"
    case "$ext" in ts|tsx|js|jsx) ;; *) continue ;; esac
    local full_path="${repo_path}/${file}"
    [ -f "$full_path" ] || continue

    local findings=""

    # Pattern 1: Object.entries/fromEntries/keys/values usage — flag for type verification
    local obj_calls
    obj_calls=$(grep -nE 'Object\.(entries|fromEntries|keys|values)\s*\(' "$full_path" 2>/dev/null | head -10)
    if [ -n "$obj_calls" ]; then
      findings+="  SHAPE-CHECK: Object.entries/fromEntries/keys/values found. Verify the argument is NOT an array:"$'\n'
      findings+="$obj_calls"$'\n'
    fi

    # Pattern 2: typeof x === "string" near Object.entries — classic array-of-objects trap
    local typeof_in_entries
    typeof_in_entries=$(grep -nE 'typeof\s+\w+\s*===?\s*"string"' "$full_path" 2>/dev/null | head -5)
    if [ -n "$obj_calls" ] && [ -n "$typeof_in_entries" ]; then
      findings+="  SHAPE-CHECK: typeof string check + Object.entries in same file. If entries come from array elements (objects), typeof will never be 'string':"$'\n'
      findings+="$typeof_in_entries"$'\n'
    fi

    # Pattern 3: Array method chained on Object.entries
    local array_on_entries
    array_on_entries=$(grep -nE 'Object\.entries\([^)]+\)\s*\.\s*(map|filter|reduce|forEach)\(' "$full_path" 2>/dev/null | head -5)
    if [ -n "$array_on_entries" ]; then
      findings+="  SHAPE-CHECK: Array method chained on Object.entries. Verify the source is a plain object, not an array:"$'\n'
      findings+="$array_on_entries"$'\n'
    fi

    if [ -n "$findings" ]; then
      output+="### ${file} (type-shape warnings)"$'\n'
      output+="${findings}"$'\n'
      file_count=$((file_count + 1))
    fi
  done <<< "$changed_files"

  if [ -n "$output" ] && [ "$file_count" -gt 0 ]; then
    echo "## TYPE-SHAPE WARNINGS (pattern-based — MUST verify by reading the actual types)"
    echo "The following patterns MAY indicate data-shape mismatches (e.g., Object.entries on an array)."
    echo "You MUST Read the type definition of each flagged variable to confirm or dismiss."
    echo "If the variable is an array and Object.entries/fromEntries is used on it, this is BLOCKING."
    echo ""
    echo "$output"
  fi
}

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

  # Run type-shape pattern detection (these ARE actionable — reviewer must verify)
  _run_shape_check "$changed_files" "$repo_path"
}
