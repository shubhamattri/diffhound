#!/bin/bash
# Publication-time history is the single owner of cross-round deduplication.
# Args: comments reviews previous_comments threads login sha output_directory
dh_plan_findings() {
  local comments="$1" reviews="$2" previous="$3" threads="$4" login="$5" sha="$6" dir="$7"
  local script="${BASH_SOURCE[0]%/*}/review_state.py" exact
  exact=$(python3 "$script" plan "$reviews" "$previous" "$threads" "$login" "$sha" "$comments" "$dir/plan") || return 1
  python3 "$script" prior "$dir/plan" "$login" > "$dir/prior" || return 1
  cp "$comments" "$dir/candidates"
  DH_DEDUP_MATCHES_FILE="$dir/matches" dh_semantic_dedup "$comments" "$dir/prior" "$login"
  # The semantic helper may return early with no candidates.
  touch "$dir/matches"
  python3 "$script" aliases "$dir/plan" "$dir/prior" "$dir/candidates" "$dir/matches" || return 1
  _DH_DEDUP_DROPPED=$((exact + _DH_DEDUP_DROPPED))
}

# Args: owner repo pr login body_file
# One persistent PR summary. Publication history remains in submitted reviews
# so a failed summary update never causes findings to be posted again.
dh_upsert_summary() {
  local owner="$1" repo="$2" pr="$3" login="$4" body_file="$5" comments id tmp rc
  local marker='<!-- diffhound-summary v1 -->'
  comments=$(_gh_api_all "/repos/$owner/$repo/issues/$pr/comments") || return 1
  id=$(jq -r --arg login "$login" --arg m "$marker" \
    '[.[] | select(.user.login == $login and ((.body // "") | startswith($m)))] | first | .id // empty' <<< "$comments") || return 1
  tmp=$(mktemp -t dh-summary.XXXXXX)
  jq -n --arg m "$marker" --rawfile b "$body_file" '{body: ($m + "\n" + $b)}' > "$tmp"
  if [ -n "$id" ]; then
    gh api --method PATCH "/repos/$owner/$repo/issues/comments/$id" --input "$tmp" >/dev/null 2>&1; rc=$?
  else
    # Do not retry an ambiguous creation here. Next run recovers by marker.
    gh api --method POST "/repos/$owner/$repo/issues/$pr/comments" --input "$tmp" >/dev/null 2>&1; rc=$?
  fi
  rm -f "$tmp"; return "$rc"
}
