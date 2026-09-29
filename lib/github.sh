#!/bin/bash
# diffhound — GitHub API interaction
# List pagination, identity markers, voice indexing.
# Publishing a review lives in lib/publish.sh.

# Source marker utilities (compute_identity_tuple / compose_marker / append_marker).
# Use the same lib dir as the caller to support both VM and dev-machine paths.
_GITHUB_SH_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=marker-utils.sh
. "${_GITHUB_SH_DIR}/marker-utils.sh"

# Every page of a GitHub list endpoint as ONE JSON array. A bare `gh api` returns
# only the first 30 items; on monorepo #7642 (204 inline comments, 145 reviews)
# that froze the "last reviewed" commit at round 3 and hid every author reply
# after it. `--paginate` alone is not enough: it prints one array per page.
# Usage: _gh_api_all /repos/o/r/pulls/N/comments
_gh_api_all() {
  local ep="$1" sep='?' out
  case "$ep" in *\?*) sep='&' ;; esac
  out=$(gh api --paginate "${ep}${sep}per_page=100" 2>/dev/null) || return 1
  printf '%s\n' "$out" | jq -ce -s 'if length > 0 and all(.[]; type == "array") then add else error("invalid list response") end'
}

# An incremental range is safe only if the previously reviewed head is an
# ancestor. Force pushes and unavailable ancestry fall back to the full PR diff.
# Args: local_repo owner repo previous_sha head_sha
dh_incremental_base_ok() {
  if git -C "$1" cat-file -e "$4^{commit}" 2>/dev/null && git -C "$1" cat-file -e "$5^{commit}" 2>/dev/null; then
    git -C "$1" merge-base --is-ancestor "$4" "$5"
  else
    local status
    status=$(gh api "/repos/$2/$3/compare/$4...$5" --jq .status 2>/dev/null) || return 1
    [ "$status" = ahead ] || [ "$status" = identical ]
  fi
}

# Inject diffhound-id markers into review_json's comments[].body in-place.
# The bulk-POST path embeds comments inside the review JSON; we append a marker
# to each comment body so future rounds can extract the prior identity tuple
# verbatim instead of reverse-engineering it from rendered markdown.
_inject_markers_into_review_json() {
  local review_json="$1"
  [ -f "$review_json" ] || return 0

  local _tmp
  _tmp=$(mktemp -t "review-json-marked.XXXXXX")

  # Walk comments[] as JSON lines so tabs and paragraphs survive transport;
  # write back via jq with --slurpfile of the marked bodies. Done this way to
  # keep the shell-only base64/jq composition in compose_marker rather than
  # duplicating it inside a jq program.
  local _bodies_in _bodies_out
  _bodies_in=$(mktemp -t "bodies-in.XXXXXX")
  _bodies_out=$(mktemp -t "bodies-out.XXXXXX")

  jq -c '.comments[] | {path, body}' \
    "$review_json" > "$_bodies_in" 2>/dev/null || { rm -f "$_tmp" "$_bodies_in" "$_bodies_out"; return 1; }

  # If there are no comments (empty array, body-only review), nothing to do.
  if [ ! -s "$_bodies_in" ]; then
    rm -f "$_tmp" "$_bodies_in" "$_bodies_out"
    return 0
  fi

  # Build a JSON array of marked bodies, indexed in order, for slurp-merge.
  printf '[' > "$_bodies_out"
  local _first=true _row _path _body _marked
  while IFS= read -r _row; do
    _path=$(jq -r .path <<< "$_row")
    _body=$(jq -r .body <<< "$_row")
    _marked=$(append_marker "$_path" "$_body")
    [ "$_first" = false ] && printf ',' >> "$_bodies_out"
    _first=false
    printf '%s' "$_marked" | jq -Rs . >> "$_bodies_out"
  done < "$_bodies_in"
  printf ']' >> "$_bodies_out"

  # Merge marked bodies back into review_json by index.
  if jq --slurpfile marked "$_bodies_out" '
    .comments |= (
      to_entries | map(
        .value.body = ($marked[0][.key] // .value.body) | .value
      )
    )
  ' "$review_json" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$review_json"
  else
    rm -f "$_tmp"
  fi

  rm -f "$_bodies_in" "$_bodies_out"
}

# Id of a review already on the PR from $5 at commit $4 whose body equals the
# body in review JSON $6, or nothing. A POST that errors client-side (timeout,
# 5xx after the write) may still have created the review; on #7642 run
# 36418822496 that happened and the fallback posted the body and 16 inline
# comments a second time.  Args: owner repo pr head_sha login review_json
_find_posted_review() {
  local body
  body=$(jq -r '.body // ""' "$6" 2>/dev/null)
  _gh_api_all "/repos/$1/$2/pulls/$3/reviews" | jq -L "$_GITHUB_SH_DIR" -r --arg sha "$4" --arg login "$5" --arg body "$body" \
    'include "review-identity";
     def norm: gsub("\r"; "") | sub("\\s+$"; "");
     [.[] | select(dh_submitted and .commit_id == $sha and dh_author($login) and ((.body // "") | norm) == ($body | norm))] | last | .id // empty' 2>/dev/null
}

# Index posted comments to voice JSONL for continuous learning
# Args: $1=new_comments_file $2=pr_number $3=voice_jsonl $4=cache_dir (optional)
index_voice_comments() {
  local new_comments_file="$1" pr_number="$2" voice_jsonl="$3"
  local cache_dir="${4:-}"

  [ -f "$new_comments_file" ] || { echo "0"; return 0; }
  [ -f "$voice_jsonl" ] || touch "$voice_jsonl"

  local indexed=0
  while IFS= read -r comment_line; do
    # Format: COMMENT: prefix already stripped — path:LINE:SEVERITY — text
    [[ "$comment_line" =~ ^(.+):[~]?([0-9]+):(BLOCKING|SHOULD-FIX|NIT)[[:space:]](—|–|-)[[:space:]](.+)$ ]] || continue
    local filepath="${BASH_REMATCH[1]}"
    local severity="${BASH_REMATCH[3]}"
    local comment_text="${BASH_REMATCH[5]}"
    # Decode multi-line join character back to newlines
    comment_text=$(printf '%s' "$comment_text" | tr $'\x1f' '\n')

    [ "${#comment_text}" -lt 50 ] && continue

    local cat subcat
    if grep -qi "token\|secret\|auth\|password\|credential\|security" <<< "$comment_text"; then
      cat="security"; subcat="auto-detected"
    elif grep -qi "prod\|null.*column\|wrong.*column\|meta->" <<< "$comment_text"; then
      cat="data-bug"; subcat="auto-detected"
    elif grep -qi "sibling\|same.*file\|same.*pattern\|lateral" <<< "$comment_text"; then
      cat="pattern-propagation"; subcat="auto-detected"
    elif grep -qi "consist\|also has\|same pattern" <<< "$comment_text"; then
      cat="consistency"; subcat="auto-detected"
    elif grep -qi "assuming.*intentional\|intent\|comment.*why" <<< "$comment_text"; then
      cat="intent-check"; subcat="auto-detected"
    elif grep -qi "test\|mock\|coverage" <<< "$comment_text"; then
      cat="test-gap"; subcat="auto-detected"
    elif grep -qi "nit\|ignore\|actually.*fine" <<< "$comment_text"; then
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
