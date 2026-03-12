#!/bin/bash
# diffhound — Jira ticket fetch for requirement coverage
# Extracts ticket ID from PR metadata and fetches details via Jira REST API.
# Skips silently if JIRA_BASE_URL, JIRA_EMAIL, or JIRA_API_TOKEN are not set.

_JIRA_SOURCED=true

# Extract Jira ticket ID from PR title, branch name, or body.
# Returns first match of pattern [A-Z][A-Z0-9]+-[0-9]+
_extract_jira_ticket() {
  local pr_title="${1:-}"
  local branch_name="${2:-}"
  local pr_body="${3:-}"

  local ticket=""

  # Try title first (highest signal)
  if [ -n "$pr_title" ]; then
    ticket=$(echo "$pr_title" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  fi

  # Try branch name
  if [ -z "$ticket" ] && [ -n "$branch_name" ]; then
    ticket=$(echo "$branch_name" | grep -oiE '[A-Z][A-Z0-9]+-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
  fi

  # Try body (least reliable — take first match)
  if [ -z "$ticket" ] && [ -n "$pr_body" ]; then
    ticket=$(echo "$pr_body" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
  fi

  echo "$ticket"
}

# Fetch Jira ticket details via REST API.
# Returns formatted markdown suitable for prompt injection.
# Requires: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN
_fetch_jira_ticket() {
  local ticket_id="$1"

  # Validate env vars
  if [ -z "${JIRA_BASE_URL:-}" ] || [ -z "${JIRA_EMAIL:-}" ] || [ -z "${JIRA_API_TOKEN:-}" ]; then
    return 1
  fi

  [ -z "$ticket_id" ] && return 1

  local api_url="${JIRA_BASE_URL}/rest/api/3/issue/${ticket_id}?fields=summary,status,issuetype,description"

  local response
  response=$(curl -s --http1.1 --max-time 10 \
    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H "Accept: application/json" \
    "$api_url" 2>/dev/null) || return 1

  # Check for errors
  if echo "$response" | jq -e '.errorMessages' >/dev/null 2>&1; then
    return 1
  fi

  local summary status issue_type description_text
  summary=$(echo "$response" | jq -r '.fields.summary // "N/A"')
  status=$(echo "$response" | jq -r '.fields.status.name // "N/A"')
  issue_type=$(echo "$response" | jq -r '.fields.issuetype.name // "N/A"')

  # Parse ADF (Atlassian Document Format) description to plain text
  # ADF is nested JSON; extract text content from paragraph/heading/listItem nodes
  description_text=$(echo "$response" | jq -r '
    def extract_text:
      if type == "object" then
        if .type == "text" then (.text // "")
        elif .type == "mention" then ("@" + (.attrs.text // "unknown"))
        elif .type == "hardBreak" then "\n"
        elif .type == "heading" then
          ([.content[]? | extract_text] | join("")) + "\n"
        elif .type == "bulletList" or .type == "orderedList" then
          [.content[]? | extract_text] | join("")
        elif .type == "listItem" then
          "- " + ([.content[]? | extract_text] | join("")) + "\n"
        elif .type == "paragraph" then
          ([.content[]? | extract_text] | join("")) + "\n"
        elif .type == "codeBlock" then
          "```\n" + ([.content[]? | extract_text] | join("")) + "\n```\n"
        else
          [.content[]? | extract_text] | join("")
        end
      elif type == "array" then
        [.[] | extract_text] | join("")
      else ""
      end;
    .fields.description | if . then extract_text else "(no description)" end
  ' 2>/dev/null) || description_text="(failed to parse description)"

  # Extract acceptance criteria (common patterns: "Acceptance Criteria", "AC:", h2/h3 headers)
  local ac_text=""
  ac_text=$(echo "$description_text" | sed -n '/[Aa]cceptance [Cc]riteria/,/^$/p' | head -30)

  # Build output
  cat <<JIRA_EOF
## REQUIREMENTS FROM JIRA (${ticket_id})
**Summary:** ${summary}
**Status:** ${status} | **Type:** ${issue_type}
### Description
${description_text}
JIRA_EOF

  if [ -n "$ac_text" ]; then
    cat <<AC_EOF
### Acceptance Criteria
${ac_text}
AC_EOF
  fi

  cat <<JIRA_TAIL
---
Verify implementation addresses these requirements. Flag any acceptance criteria not covered by the code changes.
JIRA_TAIL
}
