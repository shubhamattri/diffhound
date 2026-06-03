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
      total=$(echo "$json_content" | jq -r '[.scorecard[]? | .score] | add // 0')
      local total_max
      total_max=$(echo "$json_content" | jq -r '[.scorecard[]? | .max] | add // 100')
      verdict=$(echo "$json_content" | jq -r '.verdict')
      echo "| **Total** | **${total}/${total_max}** | **${verdict}** |"
      echo ""
      echo "## Verification & Test Checklist"
      echo "$json_content" | jq -r '(.checklist // [])[] | "- [ ] \(.)"'
      # Requirement coverage from Jira integration
      local has_req_cov
      has_req_cov=$(echo "$json_content" | jq -e '.requirement_coverage.ticket // empty' 2>/dev/null || true)
      if [ -n "$has_req_cov" ] && [ "$has_req_cov" != "null" ]; then
        echo ""
        echo "## Requirement Coverage ($(echo "$json_content" | jq -r '.requirement_coverage.ticket'))"
        echo "### Addressed"
        echo "$json_content" | jq -r '(.requirement_coverage.addressed // [])[] | "- ✅ \(.)"'
        local missing_count
        missing_count=$(echo "$json_content" | jq -r '(.requirement_coverage.missing // []) | length' | tr -d '[:space:]')
        missing_count=${missing_count:-0}
        if [ "$missing_count" -gt 0 ] 2>/dev/null; then
          echo "### Missing"
          echo "$json_content" | jq -r '(.requirement_coverage.missing // [])[] | "- ⚠️ \(.)"'
        fi
        local req_notes
        req_notes=$(echo "$json_content" | jq -r '.requirement_coverage.notes // empty')
        if [ -n "$req_notes" ]; then
          echo ""
          echo "*${req_notes}*"
        fi
      fi
    } > "$summary_file"
    # Enforce canonical /100 weighting on the JSON path too (model controls
    # per-category max in JSON output, so it can drift the same way).
    _normalize_markdown_scorecard_total "$summary_file"
    return 0
  fi

  # Fallback: regex-based
  if grep -q "SUMMARY_START" "$structured_file"; then
    sed -n '/SUMMARY_START/,/SUMMARY_END/p' "$structured_file" | \
      grep -v "SUMMARY_START" | grep -v "SUMMARY_END" > "$summary_file"
  elif grep -q "SCORECARD_START" "$structured_file"; then
    # Chunked merge format: extract SCORECARD_START/END and convert to markdown table
    {
      # Build markdown scorecard table from "Category: X/Y — reason" lines
      echo "| Category | Score | Notes |"
      echo "|----------|-------|-------|"
      sed -n '/SCORECARD_START/,/SCORECARD_END/p' "$structured_file" | \
        grep -v "SCORECARD_START\|SCORECARD_END\|^Blocking:\|^ShouldFix:\|^Nits:\|^Checklist:" | \
        while IFS= read -r _sline; do
          [ -z "$_sline" ] && continue
          _cat=$(echo "$_sline" | sed 's/:.*//' | sed 's/^ *//')
          _rest=$(echo "$_sline" | sed 's/^[^:]*: //')
          _score=$(echo "$_rest" | grep -oE '^[0-9]+/[0-9]+' || true)
          _reason=$(echo "$_rest" | sed 's/^[0-9]*\/[0-9]* *[—–-]* *//')
          if echo "$_cat" | grep -qi "total"; then
            echo "| **${_cat}** | **${_score}** | ${_reason} |"
          elif [ -n "$_score" ]; then
            echo "| ${_cat} | ${_score} | ${_reason} |"
          fi
        done
      echo ""
      echo "## Verification & Test Checklist"
      sed -n '/SCORECARD_START/,/SCORECARD_END/p' "$structured_file" | \
        grep "^Checklist:" | sed 's/^Checklist: //' | tr ',' '\n' | \
        while IFS= read -r _item; do
          _item=$(echo "$_item" | sed 's/^ *//')
          [ -n "$_item" ] && echo "- [ ] ${_item}"
        done
    } > "$summary_file"
  else
    cat "$structured_file" > "$summary_file"
  fi

  _normalize_markdown_scorecard_total "$summary_file"
}

# Re-verify "X doesn't exist / not defined / missing" claims against the CURRENT
# tree, and emit ground-truth corrections for any symbol that IS actually
# defined. Used on re-reviews: the model re-asserts a round-1 STILL_OPEN concern
# ("SEARCH_ORGS doesn't exist anywhere") without re-checking the code, and that
# re-assertion bypasses the validator pipeline AND the peer cross-check. This
# grep is deterministic — if the symbol is defined now, the absence claim is a
# false positive (real incident: monorepo #7317, SEARCH_ORGS at queries.js:83).
#
# Args: $1 = model-output file (CLAUDE_OUT), $2 = repo working tree.
# Stdout: markdown correction bullets (empty if none). Caller injects them into
# the voice/format pass so the final review can't render the claim as a blocker.
_reverify_absence_claims() {
  local out="$1" repo="$2"
  [ -f "$out" ] || return 0
  [ -d "$repo" ] || return 0

  # Lines that assert a symbol is absent.
  local absence_re="does(n'?t| not) exist|do(n'?t| not) exist|not defined|don'?t exist anywhere|doesn'?t exist anywhere|missing entirely|not found anywhere|exist anywhere in the codebase"

  # Candidate symbols from absence lines: backticked identifiers OR ALL_CAPS
  # constants (gql query consts like SEARCH_ORGS). Defs-only check below keeps
  # noise tokens (HTTP/JSON/API) from producing corrections.
  grep -iE "$absence_re" "$out" 2>/dev/null \
    | grep -oE '`@?[A-Za-z_][A-Za-z0-9_]{2,}`|[A-Z][A-Z0-9_]{3,}' \
    | tr -d '`' | sort -u \
    | while IFS= read -r sym; do
        [ -z "$sym" ] && continue
        local hit loc
        # Look for a DEFINITION (export/const/function/class/def or `SYM =`/`SYM:`).
        hit=$(grep -rnE "(export[[:space:]]+(const|default|function|class)|const|let|var|function|class|def)[[:space:]]+${sym}([[:space:]]|=|\(|:|<|\$)|^[[:space:]]*${sym}[[:space:]]*[:=]" "$repo" \
              --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' --include='*.py' \
              2>/dev/null | grep -v '/node_modules/' | head -1)
        if [ -n "$hit" ]; then
          loc=$(printf '%s' "$hit" | cut -d: -f1-2 | sed "s#${repo}/##")
          printf -- '- `%s` IS defined at %s — any claim it does not exist is a FALSE POSITIVE; mark that thread RESOLVED and do not emit it as a blocker/comment.\n' "$sym" "$loc"
        fi
      done
}

# Normalize the markdown scorecard to canonical, weight-enforced scoring.
#
# Canonical weights (sum = 100):
#   Security 25, Tests 20, Observability 10, Performance 15, Readability 15, Compatibility 15
#
# Why this is script-owned and not trusted from the model:
#   The model used to control each category's denominator. When it dropped a
#   category the total denominator silently became /85; when it emitted a wrong
#   max (e.g. "Security: 18/20") the total was both wrong and un-weighted. This
#   function pins each category to its canonical max, rescales the model's score
#   onto that max, back-fills any missing category at full marks, and always
#   denominates the total /100. The verdict word in the Total row is preserved.
_normalize_markdown_scorecard_total() {
  local summary_file="$1"
  [ -f "$summary_file" ] || return 0

  local tmp_file
  tmp_file=$(mktemp -t "diffhound-summary.XXXXXX")

  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function rnd(x)  { return int(x + 0.5) }
    # Map any model category label to a canonical key (or "" if not a category).
    function canon(name,   n) {
      n = tolower(name); gsub(/\*/, "", n); sub(/\(.*$/, "", n); n = trim(n)
      if (n ~ /^secur/)                 return "Security"
      if (n ~ /^test/)                  return "Tests"
      if (n ~ /^observ/)                return "Observability"
      if (n ~ /^perf/)                  return "Performance"
      if (n ~ /^read/)                  return "Readability"
      if (n ~ /^(compat|backward|api)/) return "Compatibility"
      return ""
    }
    BEGIN {
      cmax["Security"]=25; cmax["Tests"]=20; cmax["Observability"]=10
      cmax["Performance"]=15; cmax["Readability"]=15; cmax["Compatibility"]=15
      n = split("Security Tests Observability Performance Readability Compatibility", ord, " ")
    }
    {
      lines[NR] = $0
      if ($0 !~ /^\|/) next
      split($0, cols, /\|/)
      col1 = trim(cols[2]); col2 = trim(cols[3])
      c1 = col1; c2 = col2; gsub(/\*/, "", c1); gsub(/\*/, "", c2)

      if (tolower(trim(c1)) == "total") { total_row = NR; total_verdict = trim(cols[4]); next }

      if (c2 ~ /^-?[0-9]+\/[0-9]+$/) {
        k = canon(c1)
        if (k != "") {
          split(c2, sp, "/"); sc = sp[1] + 0; mx = sp[2] + 0
          if (mx > 0) {
            v = rnd(sc / mx * cmax[k])
            if (v > cmax[k]) v = cmax[k]; if (v < 0) v = 0
            cscore[k] = v; cnote[k] = trim(cols[4]); seen[k] = 1
            if (firstcat == 0 || NR < firstcat) firstcat = NR
          }
          found = 1
        }
      }
    }
    END {
      if (!found || total_row == 0) { for (i = 1; i <= NR; i++) print lines[i]; exit }
      # Total is normalized to /100 over the dimensions the model ACTUALLY
      # scored. A missing dimension is shown as "not scored" and excluded from
      # the denominator — we never invent a full-marks score for a dimension the
      # model did not evaluate (that would silently inflate toward APPROVE), nor
      # penalize it to zero. Present dimensions are pinned to canonical weights.
      pscore = 0; pmax = 0
      for (i = 1; i <= n; i++) { k = ord[i]; if (k in seen) { pscore += cscore[k]; pmax += cmax[k] } }
      tot = (pmax > 0) ? int(pscore / pmax * 100 + 0.5) : 0
      for (i = 1; i <= NR; i++) {
        if (i == total_row) { print "| **Total** | **" tot "/100** | " total_verdict " |"; continue }
        is_cat = 0
        if (lines[i] ~ /^\|/) {
          split(lines[i], cc, /\|/); a = trim(cc[2]); b = trim(cc[3]); gsub(/\*/, "", a); gsub(/\*/, "", b)
          if (tolower(trim(a)) != "total" && b ~ /^-?[0-9]+\/[0-9]+$/ && canon(a) != "") is_cat = 1
        }
        if (is_cat) {
          if (i == firstcat) {
            for (j = 1; j <= n; j++) {
              k = ord[j]
              if (k in seen) print "| " k " (" cmax[k] "%) | " cscore[k] "/" cmax[k] " | " cnote[k] " |"
              else           print "| " k " (" cmax[k] "%) | — | not scored (excluded from total) |"
            }
          }
          continue
        }
        print lines[i]
      }
    }
  ' "$summary_file" > "$tmp_file" && mv "$tmp_file" "$summary_file" || rm -f "$tmp_file"
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
  has_blocking=$(grep -ci ':BLOCKING' "$comments_file" 2>/dev/null | head -1 || true)
  has_blocking=$(echo "${has_blocking:-0}" | tr -d '[:space:]')
  has_blocking=${has_blocking:-0}
  has_shouldfix=$(grep -ciE ':SHOULD[-_]FIX' "$comments_file" 2>/dev/null | head -1 || true)
  has_shouldfix=$(echo "${has_shouldfix:-0}" | tr -d '[:space:]')
  has_shouldfix=${has_shouldfix:-0}
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
