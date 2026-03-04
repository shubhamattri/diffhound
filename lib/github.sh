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
# Args: $1=new_comments_file $2=pr_number $3=voice_jsonl $4=cache_dir (optional)
index_voice_comments() {
  local new_comments_file="$1" pr_number="$2" voice_jsonl="$3"
  local cache_dir="${4:-}"

  [ -f "$new_comments_file" ] || { echo "0"; return 0; }
  [ -f "$voice_jsonl" ] || { echo "0"; return 0; }

  local indexed=0
  while IFS= read -r comment_line; do
    # Format: COMMENT: prefix already stripped — path:LINE:SEVERITY — text
    [[ "$comment_line" =~ ^(.+):[~]?([0-9]+):(BLOCKING|SHOULD-FIX|NIT)[[:space:]][—–-][[:space:]](.+)$ ]] || continue
    local filepath="${BASH_REMATCH[1]}"
    local severity="${BASH_REMATCH[3]}"
    local comment_text="${BASH_REMATCH[4]}"
    # Decode multi-line join character back to newlines
    comment_text=$(printf '%s' "$comment_text" | tr $'\x1f' '\n')

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

    # ── Deduplication: skip if same category + first 80 chars already in JSONL ──
    local _comment_prefix="${comment_text:0:80}"
    local _is_dup
    _is_dup=$(jq -r --arg cat "$cat" --arg prefix "$_comment_prefix" \
      'select(.category == $cat and (.comment | startswith($prefix))) | "dup"' \
      "$voice_jsonl" 2>/dev/null | head -1 || true)
    [ "$_is_dup" = "dup" ] && continue

    # ── Cap at 200 entries: evict oldest auto_indexed entries if over limit ──
    local _current_count
    _current_count=$(wc -l < "$voice_jsonl" | tr -d ' ')
    if [ "$_current_count" -ge 200 ]; then
      local _jsonl_tmp
      _jsonl_tmp=$(mktemp -t "voice-jsonl.XXXXXX")
      {
        jq -c 'select(.auto_indexed != true)' "$voice_jsonl" 2>/dev/null || true
        jq -c 'select(.auto_indexed == true)' "$voice_jsonl" 2>/dev/null | tail -150
      } | grep -v '^$' > "$_jsonl_tmp"
      mv "$_jsonl_tmp" "$voice_jsonl"
    fi

    jq -n \
      --arg cat "$cat" \
      --arg sub "$subcat" \
      --arg ext "$file_ext" \
      --argjson pr "$pr_number" \
      --arg comm "$comment_text" \
      '{category:$cat,subcategory:$sub,file_type:$ext,pr:$pr,auto_indexed:true,comment:$comm}' \
      >> "$voice_jsonl"
    indexed=$((indexed + 1))

    # ── File pattern cache: track which files get BLOCKING findings ──
    if [ -n "$cache_dir" ]; then
      local _patterns_file="$cache_dir/file-patterns.json"
      [ ! -f "$_patterns_file" ] && echo '{}' > "$_patterns_file"
      local _pat_tmp
      _pat_tmp=$(mktemp -t "patterns.XXXXXX")
      jq --arg path "$filepath" --arg sev "$severity" --arg today "$(date +%Y-%m-%d)" \
        '
        .[$path] //= {"blocking_count":0,"total_reviews":0,"last_reviewed":""}
        | .[$path].total_reviews += 1
        | .[$path].last_reviewed = $today
        | if $sev == "BLOCKING" then .[$path].blocking_count += 1 else . end
        ' "$_patterns_file" > "$_pat_tmp" 2>/dev/null && mv "$_pat_tmp" "$_patterns_file" || rm -f "$_pat_tmp"
    fi

  done < "$new_comments_file"

  echo "$indexed"
}

# Auto-resolve review threads that have been addressed by new commits
# Args: repo_owner repo_name pr_number existing_comments_file incremental_diff_file reviewer_login
resolve_addressed_comments() {
  local repo_owner="$1" repo_name="$2" pr_number="$3"
  local existing_comments_file="$4" incremental_diff_file="$5"
  local reviewer_login="$6"
  local tolerance=2
  local resolved_count=0

  # 1. Extract reviewer's top-level comment positions (path + line)
  local reviewer_comments
  reviewer_comments=$(jq -c --arg login "$reviewer_login" \
    '[.[] | select(.user == $login and .in_reply_to_id == null and .path != null and .line != null) | {id, path, line}]' \
    "$existing_comments_file" 2>/dev/null || echo "[]")

  local comment_count
  comment_count=$(printf '%s' "$reviewer_comments" | jq 'length')
  [ "$comment_count" -eq 0 ] && { echo "0"; return 0; }

  # 2. Parse incremental diff line-by-line to find actually changed lines per file
  #    Only +/- lines count as changed; context lines (space prefix) are skipped.
  local -A changed_lines  # file -> space-separated line numbers
  local current_file="" new_line=0
  while IFS= read -r diff_line; do
    case "$diff_line" in
      "--- "*)  ;;
      "+++ /dev/null")
        current_file=""  # file deletion — no new-side lines to track
        ;;
      "+++ b/"*)
        current_file="${diff_line#+++ b/}"
        ;;
      "@@"*)
        # Parse @@ -old,count +new,count @@ — track new-side line counter
        if [[ "$diff_line" =~ \+([0-9]+)(,([0-9]+))? ]]; then
          new_line="${BASH_REMATCH[1]}"
        fi
        ;;
      "+"*)
        # Added/modified line on new side — this is an actual change
        [ -n "$current_file" ] && changed_lines["$current_file"]+="$new_line "
        new_line=$((new_line + 1))
        ;;
      "-"*)
        # Deleted line — doesn't advance new-side counter
        ;;
      " "*)
        # Context line — unchanged, just advance counter
        new_line=$((new_line + 1))
        ;;
    esac
  done < "$incremental_diff_file"

  # 3. Match: for each reviewer comment, check if any changed line is within ±tolerance
  local addressed_ids=()
  local addressed_paths=()
  local i=0
  while [ "$i" -lt "$comment_count" ]; do
    local cid cpath cline
    cid=$(printf '%s' "$reviewer_comments" | jq -r ".[$i].id")
    cpath=$(printf '%s' "$reviewer_comments" | jq -r ".[$i].path")
    cline=$(printf '%s' "$reviewer_comments" | jq -r ".[$i].line")
    i=$((i + 1))

    local lines="${changed_lines[$cpath]:-}"
    [ -z "$lines" ] && continue

    local matched=false
    for cl in $lines; do
      local diff=$((cline - cl))
      [ "$diff" -lt 0 ] && diff=$((-diff))
      if [ "$diff" -le "$tolerance" ]; then
        matched=true
        break
      fi
    done

    if [ "$matched" = true ]; then
      addressed_ids+=("$cid")
      addressed_paths+=("$cpath:$cline")
    fi
  done

  [ "${#addressed_ids[@]}" -eq 0 ] && { echo "0"; return 0; }

  # 4. Fetch thread IDs via GraphQL (maps REST databaseId → GraphQL thread id)
  local gql_query
  gql_query=$(printf '{"query":"query { repository(owner:\"%s\", name:\"%s\") { pullRequest(number:%s) { reviewThreads(first:100) { nodes { id isResolved path line comments(first:1) { nodes { databaseId } } } } } } }"}' \
    "$repo_owner" "$repo_name" "$pr_number")

  local threads_response
  threads_response=$(echo "$gql_query" | gh api graphql --input - 2>/dev/null)
  if [ -z "$threads_response" ]; then
    echo "  ⚠ GraphQL thread fetch failed — skipping auto-resolve" >&2
    echo "0"; return 0
  fi

  # Build map: databaseId → {thread_id, isResolved}
  local thread_map
  thread_map=$(printf '%s' "$threads_response" | jq -c '
    [.data.repository.pullRequest.reviewThreads.nodes[] |
     select(.comments.nodes | length > 0) |
     {db_id: .comments.nodes[0].databaseId, thread_id: .id, is_resolved: .isResolved}]' 2>/dev/null || echo "[]")

  # 5. Resolve addressed + unresolved threads (with logging)
  local idx=0
  for aid in "${addressed_ids[@]}"; do
    local thread_id is_resolved
    thread_id=$(printf '%s' "$thread_map" | jq -r --argjson dbid "$aid" \
      '.[] | select(.db_id == $dbid) | .thread_id' 2>/dev/null)
    is_resolved=$(printf '%s' "$thread_map" | jq -r --argjson dbid "$aid" \
      '.[] | select(.db_id == $dbid) | .is_resolved' 2>/dev/null)

    [ -z "$thread_id" ] && { idx=$((idx + 1)); continue; }
    [ "$is_resolved" = "true" ] && { idx=$((idx + 1)); continue; }

    if echo '{"query":"mutation { resolveReviewThread(input:{threadId:\"'"$thread_id"'\"}) { thread { isResolved } } }"}' \
      | gh api graphql --input - > /dev/null 2>&1; then
      echo "    ↳ Resolved: ${addressed_paths[$idx]}" >&2
      resolved_count=$((resolved_count + 1))
    else
      echo "    ↳ Failed to resolve: ${addressed_paths[$idx]}" >&2
    fi
    idx=$((idx + 1))
  done

  echo "$resolved_count"
}
