#!/bin/bash
# diffhound — GitHub API interaction
# Handles review posting, comment threading, and fallback logic

# Post a complete review with inline comments to GitHub
# Falls back to body-only + individual comments if bulk fails
post_review() {
  local repo_owner="$1" repo_name="$2" pr_number="$3"
  local head_sha="$4" review_event="$5"
  local review_summary="$6" review_json="$7"
  local new_comments_file="$8" diff_file="$9"

  local posted_ok=true
  local new_comment_count
  new_comment_count=$(wc -l < "$new_comments_file" | tr -d ' ')

  local _post_err
  _post_err=$(mktemp)
  if ! gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/repos/${repo_owner}/${repo_name}/pulls/${pr_number}/reviews" \
    --input "$review_json" > /dev/null 2>"$_post_err"; then

    # Inline comments may have invalid line numbers — retry with body-only review
    local _fallback_json
    _fallback_json=$(mktemp)
    jq '{commit_id: .commit_id, event: .event, body: .body, comments: []}' "$review_json" > "$_fallback_json"

    if gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/repos/${repo_owner}/${repo_name}/pulls/${pr_number}/reviews" \
      --input "$_fallback_json" > /dev/null 2>&1; then

      # Body posted, now post inline comments individually
      local inline_posted=0
      if [ "$new_comment_count" -gt 0 ]; then
        while IFS=: read -r filepath line rest; do
          [[ ! "$filepath" =~ ^[a-zA-Z0-9/_.-]+$ ]] && continue
          line="${line#\~}"
          [[ ! "$line" =~ ^[0-9]+$ ]] && continue
          line=$(snap_to_diff_line "$filepath" "$line" "$diff_file")
          comment=$(strip_severity_label "$rest")
          [ -z "$(printf '%s' "$comment" | tr -d '[:space:]')" ] && continue
          gh api --method POST \
            -H "Accept: application/vnd.github+json" \
            "/repos/${repo_owner}/${repo_name}/pulls/${pr_number}/comments" \
            -f "body=${comment}" \
            -f "commit_id=${head_sha}" \
            -f "path=${filepath}" \
            -F "line=${line}" > /dev/null 2>&1 && inline_posted=$((inline_posted + 1))
        done < "$new_comments_file"
      fi
      new_comment_count=$inline_posted
    else
      spinner_fail "Failed to post review to GitHub"
      echo "  Summary saved: $review_summary" >&2
      posted_ok=false
    fi
    rm -f "$_fallback_json"
  fi
  rm -f "$_post_err"

  # Export for caller
  _POSTED_OK="$posted_ok"
  _FINAL_COMMENT_COUNT="$new_comment_count"
}

# Post reply comments to existing review threads
post_thread_replies() {
  local repo_owner="$1" repo_name="$2" pr_number="$3"
  local replies_file="$4"

  local reply_posted=0
  while IFS=: read -r comment_id filepath line rest; do
    reply_body="${rest}"
    [[ ! "$comment_id" =~ ^[0-9]+$ ]] && continue
    if gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/repos/${repo_owner}/${repo_name}/pulls/${pr_number}/comments/${comment_id}/replies" \
      --field "body=${reply_body}" > /dev/null 2>&1; then
      reply_posted=$((reply_posted + 1))
    fi
  done < "$replies_file"

  echo "$reply_posted"
}

# Index posted comments to voice JSONL for continuous learning
index_voice_comments() {
  local new_comments_file="$1" pr_number="$2" voice_jsonl="$3"

  [ -f "$new_comments_file" ] || return 0
  [ -f "$voice_jsonl" ] || return 0

  local indexed=0
  while IFS= read -r comment_line; do
    [[ "$comment_line" =~ ^COMMENT:\ (.+):[~]?([0-9]+):(BLOCKING|SHOULD-FIX|NIT)\ [—–-]\ (.+)$ ]] || continue
    local filepath="${BASH_REMATCH[1]}"
    local severity="${BASH_REMATCH[3]}"
    local comment_text="${BASH_REMATCH[4]}"

    [ "${#comment_text}" -lt 50 ] && continue

    local cat subcat
    if echo "$comment_text" | grep -qi "token\|secret\|auth\|password\|credential\|security"; then
      cat="security"; subcat="auto-detected"
    elif echo "$comment_text" | grep -qi "prod\|null.*column\|wrong.*column\|meta->"; then
      cat="data-bug"; subcat="auto-detected"
    elif echo "$comment_text" | grep -qi "sibling\|same.*file\|same.*pattern\|lateral"; then
      cat="pattern-propagation"; subcat="auto-detected"
    elif echo "$comment_text" | grep -qi "consist\|also has\|same pattern"; then
      cat="consistency"; subcat="auto-detected"
    elif echo "$comment_text" | grep -qi "assuming.*intentional\|intent\|comment.*why"; then
      cat="intent-check"; subcat="auto-detected"
    elif echo "$comment_text" | grep -qi "test\|mock\|coverage"; then
      cat="test-gap"; subcat="auto-detected"
    elif echo "$comment_text" | grep -qi "nit\|ignore\|actually.*fine"; then
      cat="nit"; subcat="auto-detected"
    else
      cat="general"; subcat="auto-detected"
    fi

    local file_ext="${filepath##*.}"

    jq -n \
      --arg cat "$cat" \
      --arg sub "$subcat" \
      --arg ext "$file_ext" \
      --argjson pr "$pr_number" \
      --arg comm "$comment_text" \
      '{category:$cat,subcategory:$sub,file_type:$ext,pr:$pr,auto_indexed:true,comment:$comm}' \
      >> "$voice_jsonl"
    indexed=$((indexed + 1))
  done < "$new_comments_file"

  echo "$indexed"
}
