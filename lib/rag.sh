#!/bin/bash
# RAG Context Retriever for PR Reviews
# Usage: ./review-rag.sh <diff_file> <repo_path> <pr_number> <reviewer_login>
# Outputs: enriched context block to stdout (inject into Pass 1 prompt)
#
# What it retrieves:
#   1. Full function context around each changed hunk (not just diff lines)
#   2. Sibling files using the same patterns (for lateral propagation check)
#   3. Git history for each changed file (why was this touched before?)
#   4. Past review comments on these files (what has been flagged here before?)
#   5. Import/dependency graph (what calls what)
#
# Sections 2-5 run in parallel for speed (~5-10s faster on 5+ file PRs).

# Note: intentionally no set -e — this is a best-effort data gathering script.
# Partial output is fine; set -e would kill background subshells on benign failures.
set -uo pipefail

# Platform compat: macOS needs gtimeout from coreutils
if [ "$(uname -s)" = "Darwin" ]; then
  _TIMEOUT_CMD="gtimeout"
  command -v gtimeout >/dev/null 2>&1 || _TIMEOUT_CMD="timeout"
else
  _TIMEOUT_CMD="timeout"
fi

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

# ── Extract changed files and their changed line ranges ──────────────────────
declare -a CHANGED_FILES=()
CURRENT_FILE=""

while IFS= read -r line; do
  if [[ "$line" =~ ^\+\+\+\ b/(.+)$ ]]; then
    CURRENT_FILE="${BASH_REMATCH[1]}"
    CHANGED_FILES+=("$CURRENT_FILE")
  fi
done < "$DIFF_FILE"

# Deduplicate (guard: if no files found, exit gracefully)
if [ "${#CHANGED_FILES[@]}" -eq 0 ]; then
  echo "# RAG CONTEXT — NO CHANGED FILES FOUND IN DIFF"
  echo "# Diff file may be empty or in an unexpected format."
  exit 0
fi
CHANGED_FILES=($(printf '%s\n' "${CHANGED_FILES[@]}" | sort -u))

# ── File pattern cache: decide depth per file based on past review findings ──
_PATTERNS_FILE="$HOME/.claude/review-cache/file-patterns.json"

# bash 3.2 compat: use a function instead of associative array (declare -A)
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

echo "# RAG CONTEXT — AUTO-RETRIEVED FOR THIS PR"
echo "# This section provides additional codebase context beyond the diff."
echo "# The reviewer should use this to verify patterns, check sibling files, and avoid false positives."
echo ""

# ── 1. ENCLOSING FUNCTION CONTEXT (tree-sitter precision) ────────────────────
# Section 1 runs first (sequential) — highest value, feeds into reviewer understanding.
# extract-context.py extracts the exact function/method containing each changed
# hunk instead of the first 100 lines of the file. Falls back to ±35 line window
# if tree-sitter is not installed. 60-70% fewer tokens vs the old head -100 path.

DIFFHOUND_ROOT="${DIFFHOUND_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 "${DIFFHOUND_ROOT}/lib/extract-context.py" "$REPO_PATH" "$DIFF_FILE" 2>/dev/null || {
  # Hard fallback if python3 or script unavailable: show head -80 per file
  echo "## 1. FULL FILE CONTEXT (key files — fallback mode)"
  echo ""
  for file in "${CHANGED_FILES[@]}"; do
    full_path="$REPO_PATH/$file"
    [ ! -f "$full_path" ] && continue
    ext="${file##*.}"
    if [[ "$ext" =~ ^(ts|tsx|vue|js|jsx|py|go|sql)$ ]]; then
      lines=$(wc -l < "$full_path" 2>/dev/null || echo 0)
      echo "### $file ($lines lines total)"
      head -80 "$full_path" 2>/dev/null
      echo "  ... [full file at $full_path]"
      echo ""
    fi
  done
}

# ── Sections 2-5 run in parallel using temp files ────────────────────────────
_SEC2=$(mktemp -t "rag-sec2.XXXXXX")
_SEC3=$(mktemp -t "rag-sec3.XXXXXX")
_SEC4=$(mktemp -t "rag-sec4.XXXXXX")
_SEC5=$(mktemp -t "rag-sec5.XXXXXX")

# Each section wrapped in $_TIMEOUT_CMD to prevent any single section from hanging

# Section 2: Sibling files (background)
$_TIMEOUT_CMD 15 bash -c '
  echo "## 2. SIBLING FILES (same domain/pattern — check for lateral propagation)"
  echo ""
  for file in '"$(printf "'%s' " "${CHANGED_FILES[@]}")"'; do
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
' > "$_SEC2" 2>/dev/null &
_PID2=$!

# Section 3: Git history (background)
$_TIMEOUT_CMD 15 bash -c '
  echo "## 3. GIT HISTORY (last 5 commits per changed file)"
  echo ""
  for file in '"$(printf "'%s' " "${CHANGED_FILES[@]}")"'; do
    [ -f "'"$REPO_PATH"'/$file" ] || continue
    echo "### $file"
    cd "'"$REPO_PATH"'" && git log --oneline -5 -- "$file" 2>/dev/null || echo "  (no history)"
    echo ""
  done
' > "$_SEC3" 2>/dev/null &
_PID3=$!

# Section 4: Past review comments (background)
# Single API call for THIS PR's comments only (not all repo comments)
$_TIMEOUT_CMD 15 bash -c '
  echo "## 4. PAST REVIEW COMMENTS (what has been flagged in these files before)"
  echo ""
  if [ -n "'"$PR_NUMBER"'" ] && command -v gh &>/dev/null; then
    gh api "/repos/'"${REPO_OWNER}"'/'"${REPO_NAME}"'/pulls/'"${PR_NUMBER}"'/comments?per_page=100" 2>/dev/null | \
      jq -r --arg login "'"$REVIEWER_LOGIN"'" \
      "group_by(.path) | .[] | select(.[0].user.login == \$login) | \"### Past comments on \(.[0].path):\", (.[] | \"  [\(.created_at[0:10])] \(.body[0:200])\"), \"\"" \
      2>/dev/null || true
  fi
' > "$_SEC4" 2>/dev/null &
_PID4=$!

# Section 5: Enum/constant files (background)
# Use git grep (index-aware, much faster than grep -rn on large repos)
$_TIMEOUT_CMD 15 bash -c '
  echo "## 5. RELATED ENUMS & CONSTANTS (check completeness)"
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
' > "$_SEC5" 2>/dev/null &
_PID5=$!

# Wait for all background sections — each has its own 15s timeout
wait "$_PID2" "$_PID3" "$_PID4" "$_PID5" 2>/dev/null || true

# Concatenate in order
cat "$_SEC2" "$_SEC3" "$_SEC4" "$_SEC5"

# Cleanup temp files
rm -f "$_SEC2" "$_SEC3" "$_SEC4" "$_SEC5"

echo "# END RAG CONTEXT"
