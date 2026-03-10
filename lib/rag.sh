#!/bin/bash
# RAG Context Retriever for PR Reviews
# Usage: ./rag.sh <diff_file> <repo_path> <pr_number> <reviewer_login>
# Outputs: enriched context block to stdout (inject into Pass 1 prompt)
#
# What it retrieves:
#   1. Full function context around each changed hunk (tree-sitter or fallback)
#   2. Full file content for changed files (up to 500 lines per file)
#   3. Callers of changed functions (git grep across repo)
#   4. Interface/type definitions referenced by changed code
#   5. Sibling files using the same patterns (for lateral propagation check)
#   6. Git history for each changed file
#   7. Past review comments on these files
#   8. Related enums & constants
#
# Context budget: 60KB max total output to stay in prompt cache sweet spot.

set -uo pipefail

# ── Helper functions are always defined (safe to source) ──
# Main body only runs when invoked directly, not when sourced.
_RAG_SOURCED=false
if [ "${BASH_SOURCE[0]}" != "${0}" ] 2>/dev/null; then
  _RAG_SOURCED=true
fi

# Platform compat
if [ "$(uname -s)" = "Darwin" ]; then
  _TIMEOUT_CMD="gtimeout"
  command -v gtimeout >/dev/null 2>&1 || _TIMEOUT_CMD="timeout"
else
  _TIMEOUT_CMD="timeout"
fi

# ── Main body: only run when invoked directly (not sourced) ──
if [ "$_RAG_SOURCED" = true ]; then
  # Skip to helper function definitions at the bottom
  :
else

DIFF_FILE="${1:-}"
REPO_PATH="${2:-}"
PR_NUMBER="${3:-}"
REVIEWER_LOGIN="${4:-shubhamattri-nova}"

if [ -z "$DIFF_FILE" ] || [ -z "$REPO_PATH" ]; then
  echo "Usage: $0 <diff_file> <repo_path> <pr_number> <reviewer_login>" >&2
  exit 1
fi

REPO_OWNER=$(cd "$REPO_PATH" && gh repo view --json owner --jq '.owner.login' 2>/dev/null || echo "novabenefits")
REPO_NAME=$(cd "$REPO_PATH" && gh repo view --json name --jq '.name' 2>/dev/null || echo "monorepo")

# ── Extract changed files ────────────────────────────────────────────────────
declare -a CHANGED_FILES=()
CURRENT_FILE=""

while IFS= read -r line; do
  if [[ "$line" =~ ^\+\+\+\ b/(.+)$ ]]; then
    CURRENT_FILE="${BASH_REMATCH[1]}"
    CHANGED_FILES+=("$CURRENT_FILE")
  fi
done < "$DIFF_FILE"

if [ "${#CHANGED_FILES[@]}" -eq 0 ]; then
  echo "# RAG CONTEXT — NO CHANGED FILES FOUND IN DIFF"
  exit 0
fi
CHANGED_FILES=($(printf '%s\n' "${CHANGED_FILES[@]}" | sort -u))

# ── Extract changed function names from diff ─────────────────────────────────
_extract_changed_functions() {
  # Parse diff for function/method names near changed lines
  grep -E '^\+.*\b(function|const|export|async)\s+\w+|^\+.*\w+\s*[=(]\s*(async\s*)?\(' "$DIFF_FILE" 2>/dev/null | \
    grep -oE '\b[a-zA-Z_][a-zA-Z0-9_]*\s*[=(]' | \
    sed 's/[=(]//g' | \
    sort -u | head -20
}

# ── File pattern cache ───────────────────────────────────────────────────────
_PATTERNS_FILE="$HOME/.claude/review-cache/file-patterns.json"

_file_depth() {
  local file="$1"
  if [ -f "$_PATTERNS_FILE" ]; then
    local _blocking
    _blocking=$(jq -r --arg f "$file" '.[$f].blocking_count // 0' "$_PATTERNS_FILE" 2>/dev/null || echo "0")
    if [ "$_blocking" -ge 2 ]; then
      echo "deep"
      return
    fi
  fi
  echo "shallow"
}

# ── Track total output size (60KB budget) ─────────────────────────────────────
_TOTAL_BYTES=0
_MAX_BYTES=61440  # 60KB

_check_budget() {
  local new_content="$1"
  local new_size=${#new_content}
  if [ $((_TOTAL_BYTES + new_size)) -gt "$_MAX_BYTES" ]; then
    return 1  # over budget
  fi
  _TOTAL_BYTES=$((_TOTAL_BYTES + new_size))
  return 0
}

_emit() {
  local content="$1"
  if _check_budget "$content"; then
    printf '%s' "$content"
  fi
}

echo "# RAG CONTEXT — AUTO-RETRIEVED FOR THIS PR"
echo "# Budget: 60KB max. Sections prioritized by review value."
echo ""

# ============================================================
# SECTION 1: ENCLOSING FUNCTION CONTEXT (tree-sitter precision)
# ============================================================
DIFFHOUND_ROOT="${DIFFHOUND_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
_sec1=$($_TIMEOUT_CMD 20 python3 "${DIFFHOUND_ROOT}/lib/extract-context.py" "$REPO_PATH" "$DIFF_FILE" 2>/dev/null || true)

if [ -n "$_sec1" ]; then
  _emit "$_sec1"
else
  # Hard fallback: head -80 per file
  _fb=""
  _fb+="## 1. FULL FILE CONTEXT (key files — fallback mode)"$'\n\n'
  for file in "${CHANGED_FILES[@]}"; do
    full_path="$REPO_PATH/$file"
    [ ! -f "$full_path" ] && continue
    ext="${file##*.}"
    if [[ "$ext" =~ ^(ts|tsx|vue|js|jsx|py|go|sql)$ ]]; then
      lines=$(wc -l < "$full_path" 2>/dev/null || echo 0)
      _fb+="### $file ($lines lines total)"$'\n'
      _fb+="$(head -80 "$full_path" 2>/dev/null)"$'\n'
      _fb+="  ... [full file at $full_path]"$'\n\n'
    fi
  done
  _emit "$_fb"
fi

# ============================================================
# SECTION 1.5: FULL FILE CONTENT (up to 500 lines per file)
# For files not fully covered by tree-sitter extraction
# ============================================================
_sec1_5=""
_sec1_5+=$'\n'"## 1.5. FULL FILE CONTENT (changed files, up to 500 lines)"$'\n\n'
for file in "${CHANGED_FILES[@]}"; do
  full_path="$REPO_PATH/$file"
  [ ! -f "$full_path" ] && continue
  ext="${file##*.}"
  [[ "$ext" =~ ^(ts|tsx|vue|js|jsx|py|go)$ ]] || continue

  file_lines=$(wc -l < "$full_path" 2>/dev/null || echo 0)
  if [ "$file_lines" -le 500 ]; then
    _sec1_5+="### $file (full — $file_lines lines)"$'\n'
    _sec1_5+='```'"$ext"$'\n'
    _sec1_5+="$(cat "$full_path" 2>/dev/null)"$'\n'
    _sec1_5+='```'$'\n\n'
  else
    # For large files, extract changed functions + ±50 lines around each hunk
    _sec1_5+="### $file (large — $file_lines lines, showing changed regions)"$'\n'
    _sec1_5+='```'"$ext"$'\n'
    # Extract hunk start lines from diff for this file
    _hunk_lines=$(awk -v f="$file" '
      /^diff --git/ { in_file = 0 }
      /^diff --git a\// { split($0, parts, " b/"); if (parts[2] == f) in_file = 1; else in_file = 0 }
      in_file && /^@@ / {
        s = $0; sub(/.*\+/, "", s); sub(/,.*/, "", s)
        print int(s)
      }
    ' "$DIFF_FILE" 2>/dev/null)

    for _hl in $_hunk_lines; do
      _start=$((_hl > 50 ? _hl - 50 : 1))
      _end=$((_hl + 50))
      _sec1_5+="// ... lines ${_start}-${_end} ..."$'\n'
      _sec1_5+="$(sed -n "${_start},${_end}p" "$full_path" 2>/dev/null)"$'\n'
    done
    _sec1_5+='```'$'\n\n'
  fi
done
_emit "$_sec1_5"

# ============================================================
# SECTIONS 2-7 run in parallel using temp files
# ============================================================
# Write changed files to temp file for safe subshell access (avoids shell injection)
_CHANGED_FILES_TMP=$(mktemp -t "rag-files.XXXXXX")
printf '%s\n' "${CHANGED_FILES[@]}" > "$_CHANGED_FILES_TMP"

_SEC2=$(mktemp -t "rag-sec2.XXXXXX")
_SEC3=$(mktemp -t "rag-sec3.XXXXXX")
_SEC4=$(mktemp -t "rag-sec4.XXXXXX")
_SEC5=$(mktemp -t "rag-sec5.XXXXXX")
_SEC6=$(mktemp -t "rag-sec6.XXXXXX")
_SEC7=$(mktemp -t "rag-sec7.XXXXXX")

# ── Section 2: CALLERS of changed functions ──
# Pre-extract function names for subshell use
_CHANGED_FUNCS=$(_extract_changed_functions 2>/dev/null || true)

$_TIMEOUT_CMD 15 bash -c '
  echo "## 2. CALLERS (who calls the changed functions)"
  echo ""
  funcs="'"$_CHANGED_FUNCS"'"
  [ -z "$funcs" ] && { echo "  (no function names extracted from diff)"; echo ""; exit 0; }

  count=0
  while IFS= read -r func; do
    [ -z "$func" ] && continue
    [ "$count" -ge 10 ] && break
    callers=$(cd "'"$REPO_PATH"'" && git grep -n "$func" -- "*.ts" "*.js" "*.tsx" "*.vue" 2>/dev/null | \
      grep -v "function ${func}\|const ${func}\|export.*${func}" | head -5 || true)
    if [ -n "$callers" ]; then
      echo "### Callers of \`$func\`:"
      echo "$callers" | while IFS= read -r cl; do
        caller_file=$(echo "$cl" | cut -d: -f1)
        caller_line=$(echo "$cl" | cut -d: -f2)
        # Show ±5 lines around the caller
        start_l=$((caller_line > 5 ? caller_line - 5 : 1))
        end_l=$((caller_line + 5))
        echo "  $cl"
        sed -n "${start_l},${end_l}p" "'"$REPO_PATH"'/${caller_file}" 2>/dev/null | sed "s/^/    /"
        echo ""
      done
      count=$((count + 1))
    fi
  done <<< "$funcs"
' > "$_SEC2" 2>/dev/null &
_PID2=$!

# Export function for subshell use

# ── Section 3: INTERFACES & TYPES ──
$_TIMEOUT_CMD 15 bash -c '
  echo "## 3. INTERFACES & TYPES (contracts the changed code must satisfy)"
  echo ""
  # Extract type/interface names from the diff
  types=$(grep -oE "(interface|type)\s+[A-Z][a-zA-Z0-9]+" "'"$DIFF_FILE"'" 2>/dev/null | \
    awk "{print \$2}" | sort -u | head -10)

  # Also look for type annotations in changed lines
  more_types=$(grep -oE ":\s*[A-Z][a-zA-Z0-9]+[<\[\|]?" "'"$DIFF_FILE"'" 2>/dev/null | \
    grep -oE "[A-Z][a-zA-Z0-9]+" | sort -u | head -10)
  types=$(printf "%s\n%s" "$types" "$more_types" | sort -u | head -15)

  [ -z "$types" ] && { echo "  (no type references found in diff)"; echo ""; exit 0; }

  while IFS= read -r tname; do
    [ -z "$tname" ] && continue
    defn=$(cd "'"$REPO_PATH"'" && git grep -n "export.*\(interface\|type\)\s\+${tname}\b" -- "*.ts" "*.d.ts" 2>/dev/null | head -1 || true)
    if [ -n "$defn" ]; then
      def_file=$(echo "$defn" | cut -d: -f1)
      def_line=$(echo "$defn" | cut -d: -f2)
      echo "### $tname (defined in $def_file:$def_line)"
      # Show the full interface/type definition (up to 30 lines)
      end_l=$((def_line + 30))
      sed -n "${def_line},${end_l}p" "'"$REPO_PATH"'/${def_file}" 2>/dev/null
      echo ""
    fi
  done <<< "$types"
' > "$_SEC3" 2>/dev/null &
_PID3=$!

# ── Section 4: Sibling files ──
$_TIMEOUT_CMD 15 bash -c '
  echo "## 4. SIBLING FILES (same domain/pattern — check for lateral propagation)"
  echo ""
  for file in $(cat "'"$_CHANGED_FILES_TMP"'"); do
    dir=$(dirname "$file")
    full_dir="'"$REPO_PATH"'/$dir"
    [ ! -d "$full_dir" ] && continue
    siblings=$(find "$full_dir" -maxdepth 1 -type f \( -name "*.ts" -o -name "*.vue" -o -name "*.js" \) \
      ! -name "$(basename "$file")" 2>/dev/null | head -8)
    if [ -n "$siblings" ]; then
      echo "### Siblings of $file:"
      while IFS= read -r sibling; do
        echo "  - ${sibling#'"$REPO_PATH"'/}"
      done <<< "$siblings"
      echo ""
    fi
  done
' > "$_SEC4" 2>/dev/null &
_PID4=$!

# ── Section 5: Git history ──
$_TIMEOUT_CMD 15 bash -c '
  echo "## 5. GIT HISTORY (last 5 commits per changed file)"
  echo ""
  for file in $(cat "'"$_CHANGED_FILES_TMP"'"); do
    [ -f "'"$REPO_PATH"'/$file" ] || continue
    echo "### $file"
    cd "'"$REPO_PATH"'" && git log --oneline -5 -- "$file" 2>/dev/null || echo "  (no history)"
    echo ""
  done
' > "$_SEC5" 2>/dev/null &
_PID5=$!

# ── Section 6: Past review comments ──
$_TIMEOUT_CMD 15 bash -c '
  echo "## 6. PAST REVIEW COMMENTS (what has been flagged in these files before)"
  echo ""
  if [ -n "'"$PR_NUMBER"'" ] && command -v gh &>/dev/null; then
    gh api "/repos/'"${REPO_OWNER}"'/'"${REPO_NAME}"'/pulls/'"${PR_NUMBER}"'/comments?per_page=100" 2>/dev/null | \
      jq -r --arg login "'"$REVIEWER_LOGIN"'" \
      "group_by(.path) | .[] | select(.[0].user.login == \$login) | \"### Past comments on \(.[0].path):\", (.[] | \"  [\(.created_at[0:10])] \(.body[0:200])\"), \"\"" \
      2>/dev/null || true
  fi
' > "$_SEC6" 2>/dev/null &
_PID6=$!

# ── Section 7: Enums & constants ──
$_TIMEOUT_CMD 15 bash -c '
  echo "## 7. RELATED ENUMS & CONSTANTS (check completeness)"
  echo ""
  candidates=$(grep -oE "[A-Z][A-Z_]{3,}" "'"$DIFF_FILE"'" | sort -u | head -10 || true)
  if [ -n "$candidates" ]; then
    while IFS= read -r candidate; do
      definition=$(cd "'"$REPO_PATH"'" && git grep -n "export.*${candidate}\|const ${candidate}\|enum ${candidate}" -- "*.ts" "*.js" 2>/dev/null | head -3 || true)
      if [ -n "$definition" ]; then
        echo "### $candidate:"
        echo "$definition"
        echo ""
      fi
    done <<< "$candidates"
  fi
' > "$_SEC7" 2>/dev/null &
_PID7=$!

# Wait for all background sections
wait $_PID2 $_PID3 $_PID4 $_PID5 $_PID6 $_PID7 2>/dev/null || true

# Concatenate in priority order (callers + types first, then supporting context)
for _secfile in "$_SEC2" "$_SEC3" "$_SEC4" "$_SEC5" "$_SEC6" "$_SEC7"; do
  _sec_content=$(cat "$_secfile" 2>/dev/null || true)
  if [ -n "$_sec_content" ]; then
    _emit "$_sec_content"$'\n'
  fi
done

# Cleanup temp files
rm -f "$_SEC2" "$_SEC3" "$_SEC4" "$_SEC5" "$_SEC6" "$_SEC7"

echo "# END RAG CONTEXT"

fi  # end _RAG_SOURCED guard

# ── RAG Helper Functions (used by hybrid large diff strategy) ────────────────
# These are always defined, whether sourced or invoked directly.

# Filter RAG context to only sections relevant to given files.
# Sections are delimited by "### filename" or "## N. SECTION_NAME" headers.
# $1 = rag_context_file, $2 = manifest_file (TSV: filepath\tpriority), $3 = output_file
_filter_rag_for_files() {
  local rag_file="$1"
  local manifest_file="$2"
  local output_file="$3"

  # Extract file basenames and directory names from manifest for matching
  local match_patterns=""
  while IFS=$'\t' read -r file _prio; do
    [ -z "$file" ] && continue
    local basename="${file##*/}"
    local dirname="${file%/*}"
    match_patterns+="${basename}|${dirname##*/}|"
  done < "$manifest_file"
  match_patterns="${match_patterns%|}"  # Remove trailing |

  [ -z "$match_patterns" ] && { cp "$rag_file" "$output_file"; return; }

  # Extract sections whose headers mention any of the relevant files/dirs
  awk -v patterns="$match_patterns" '
    /^##/ {
      if (relevant) printf "%s", buf
      buf = $0 "\n"
      relevant = 0
      n = split(patterns, pats, "|")
      for (i = 1; i <= n; i++) {
        if (index($0, pats[i]) > 0) { relevant = 1; break }
      }
      next
    }
    { buf = buf $0 "\n" }
    END { if (relevant) printf "%s", buf }
  ' "$rag_file" > "$output_file"

  # If nothing matched, include header sections (general context)
  if [ ! -s "$output_file" ]; then
    head -c 15360 "$rag_file" > "$output_file"
  fi
}

# Trim RAG context to a max byte size, cutting at section boundaries.
# $1 = rag_file (modified in place), $2 = max_bytes
_trim_rag() {
  local rag_file="$1"
  local max_bytes="${2:-40960}"

  local current_size
  current_size=$(wc -c < "$rag_file" | tr -d ' ')
  [ "$current_size" -le "$max_bytes" ] && return

  # Truncate at a section boundary (## header) nearest to max_bytes
  local tmp
  tmp=$(mktemp -t "rag-trim.XXXXXX")
  head -c "$max_bytes" "$rag_file" > "$tmp"
  # Find last section header and truncate there for clean cut
  local last_header_line
  last_header_line=$(grep -n '^## ' "$tmp" | tail -1 | cut -d: -f1)
  if [ -n "$last_header_line" ] && [ "$last_header_line" -gt 5 ]; then
    head -n "$((last_header_line - 1))" "$tmp" > "$rag_file"
    echo "# [RAG trimmed to ${max_bytes} bytes — remaining sections omitted]" >> "$rag_file"
  else
    mv "$tmp" "$rag_file"
  fi
  rm -f "$tmp"
}
