#!/bin/bash
# diffhound — output parsing & comment extraction
# Supports JSON structured output (primary) with regex fallback

# Extract JSON block from LLM output (between ```json and ```)
_extract_json() {
  local file="$1"
  sed -n '/^```json/,/^```/{/^```/d;p;}' "$file" 2>/dev/null
}

# Parse findings from structured review output
# Primary: JSON parsing via jq
# Fallback: regex extraction of COMMENT:/REPLY: lines
parse_comments() {
  local structured_file="$1"
  local comments_file="$2"

  # Try JSON parsing first
  local json_content
  json_content=$(_extract_json "$structured_file")

  if [ -n "$json_content" ] && echo "$json_content" | jq -e '.findings' >/dev/null 2>&1; then
    # JSON mode — extract findings as COMMENT: lines
    # Join multi-line bodies with Unit Separator (\x1f) to preserve them on one line
    echo "$json_content" | jq -r '
      .findings[] |
      "COMMENT: \(.file):\(.line):\(.severity) — \(.body | gsub("\n"; "\u001f"))"
    ' > "$comments_file" 2>/dev/null || true

    # Thread statuses go into summary, not as duplicate inline comments.
    # STILL_OPEN/AUTHOR_WRONG threads will be handled by the re-review
    # reply logic in review.sh which matches against existing comment IDs.

    # Save parsed JSON for downstream use (verification pass, confidence scores)
    echo "$json_content" > "${structured_file}.json"
    return 0
  fi

  # Fallback: regex-based parsing (backward compatible)
  if grep -q "INLINE_COMMENTS_START" "$structured_file"; then
    sed -n '/INLINE_COMMENTS_START/,/INLINE_COMMENTS_END/p' "$structured_file" | \
      awk '
        /^COMMENT:|^REPLY:/ {
          if (buf != "") print buf
          buf = $0
          next
        }
        /INLINE_COMMENTS/ || /^###/ { next }
        buf != "" && /^[[:space:]]*$/ { next }
        buf != "" {
          gsub(/^[ \t]+/, "")
          buf = buf "\x1f" $0
        }
        END { if (buf != "") print buf }
      ' > "${comments_file}.raw" || true

    # Post-processing: drop lint nits
    grep -viE '(trailing newline|missing newline|extra blank line|end of file|trailing whitespace|import order|file.ending|no newline at end)' \
      "${comments_file}.raw" > "$comments_file" 2>/dev/null || \
      cp "${comments_file}.raw" "$comments_file"
    rm -f "${comments_file}.raw"
  else
    touch "$comments_file"
  fi
}

# Extract review summary from structured output
parse_summary() {
  local structured_file="$1"
  local summary_file="$2"

  # Try JSON parsing first
  local json_content
  json_content=$(_extract_json "$structured_file")

  if [ -n "$json_content" ] && echo "$json_content" | jq -e '.summary' >/dev/null 2>&1; then
    # Build summary from JSON
    {
      echo "$json_content" | jq -r '.summary'
      echo ""
      echo "## Scorecard"
      echo "| Category | Score | Notes |"
      echo "|----------|-------|-------|"
      echo "$json_content" | jq -r '
        .scorecard | to_entries[] |
        "| \(.key | gsub("_"; " ") | ascii_upcase) (\(.value.max)%) | \(.value.score)/\(.value.max) | \(.value.reason) |"
      '
      local total verdict
      total=$(echo "$json_content" | jq -r '.score')
      verdict=$(echo "$json_content" | jq -r '.verdict')
      echo "| **Total** | **${total}/100** | **${verdict}** |"
      echo ""
      echo "## Verification & Test Checklist"
      echo "$json_content" | jq -r '(.checklist // [])[] | "- [ ] \(.)"'
    } > "$summary_file"
    return 0
  fi

  # Fallback: regex-based
  if grep -q "SUMMARY_START" "$structured_file"; then
    sed -n '/SUMMARY_START/,/SUMMARY_END/p' "$structured_file" | \
      grep -v "SUMMARY_START" | grep -v "SUMMARY_END" > "$summary_file"
  else
    cat "$structured_file" > "$summary_file"
  fi
}

# Parse review verdict from summary (3-method fallback)
parse_verdict() {
  local summary_file="$1"
  local comments_file="$2"
  local verdict=""

  # Method 0: Check for parsed JSON
  local json_file="${comments_file%.comments}.json"
  if [ -f "$json_file" ]; then
    verdict=$(jq -r '.verdict // empty' "$json_file" 2>/dev/null || true)
    if [ -n "$verdict" ]; then
      echo "$verdict" | tr '[:lower:]' '[:upper:]'
      return
    fi
  fi

  # Method 1: Extract verdict word from scorecard **Total** row
  verdict=$(grep -i '\*\*Total\*\*' "$summary_file" | grep -oiE 'REQUEST_CHANGES|APPROVE|COMMENT' | head -1 || true)
  if [ -n "$verdict" ]; then
    echo "$verdict" | tr '[:lower:]' '[:upper:]'
    return
  fi

  # Method 2: Parse numeric score from **Total** row
  local score
  score=$(grep -i '\*\*Total\*\*' "$summary_file" | grep -oE '[0-9]+/100' | grep -oE '^[0-9]+' || true)
  if [ -n "$score" ]; then
    if [ "$score" -ge 90 ]; then
      echo "APPROVE"
    elif [ "$score" -lt 85 ]; then
      echo "REQUEST_CHANGES"
    else
      echo "COMMENT"
    fi
    return
  fi

  # Method 3: Derive from comment severities
  local has_blocking has_shouldfix
  has_blocking=$(grep -ci ':BLOCKING' "$comments_file" 2>/dev/null || echo "0")
  has_shouldfix=$(grep -ci ':SHOULD-FIX\|:SHOULD_FIX' "$comments_file" 2>/dev/null || echo "0")
  if [ "$has_blocking" -gt 0 ]; then
    echo "REQUEST_CHANGES"
  elif [ "$has_shouldfix" -gt 0 ]; then
    echo "COMMENT"
  else
    echo "APPROVE"
  fi
}

# Snap line number to nearest valid diff line
# GitHub rejects comments on lines not in the diff
snap_to_diff_line() {
  local file="$1" target_line="$2" diff_file="$3"
  local valid_lines
  valid_lines=$(awk -v f="$file" '
    /^diff --git/ { in_file = 0 }
    /^diff --git a\// {
      split($0, parts, " b/")
      if (parts[2] == f) in_file = 1; else in_file = 0
      next
    }
    in_file && /^@@ / {
      # Parse @@ -old,count +new,count @@ (POSIX-compatible)
      s = $0
      sub(/.*\+/, "", s)
      sub(/,.*/, "", s)
      cur_line = int(s) - 1
      next
    }
    in_file && /^-/ { next }
    in_file && /^\+/ { cur_line++; print cur_line; next }
    in_file && /^ / { cur_line++; print cur_line; next }
    in_file { cur_line++ }
  ' "$diff_file" | sort -n -u)

  if [ -z "$valid_lines" ]; then
    echo "$target_line"
    return
  fi

  echo "$valid_lines" | awk -v t="$target_line" '
    BEGIN { best = -1; best_dist = 999999 }
    {
      d = ($1 > t) ? ($1 - t) : (t - $1)
      if (d < best_dist) { best_dist = d; best = $1 }
    }
    END { print (best > 0) ? best : t }
  '
}

# Strip severity label from comment body
# COMMENT: format is "path:LINE:SEVERITY — body". Returns only body.
strip_severity_label() {
  local text="$1"
  printf '%s' "$text" | sed -e 's/^[A-Z][A-Z_-]* [—–-] *//' -e "s/^[A-Z][A-Z_-]*$(printf '\x1f')//" | tr $'\x1f' '\n'
}

# Extract confidence scores from parsed JSON for verification pass
# Returns: file:line:confidence (one per line)
get_confidence_scores() {
  local json_file="$1"
  [ -f "$json_file" ] || return 0
  jq -r '.findings[] | "\(.file):\(.line):\(.confidence // 0.5)"' "$json_file" 2>/dev/null || true
}
