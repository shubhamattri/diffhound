#!/bin/bash
# diffhound — AI-powered PR code review
# Ensure ~/.local/bin is in PATH (for claude CLI installed via npm)
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

# Source .profile for env vars (ANTHROPIC_API_KEY etc.) — needed for non-interactive SSH
[ -f "$HOME/.profile" ] && . "$HOME/.profile" 2>/dev/null || true
# Multi-model pipeline: Opus (review) + Sonnet (structured/verify) + Haiku (triage/merge) + → Codex+Gemini (peer review) → Haiku (voice rewrite)
# https://github.com/shubhamattri/diffhound

# Allow calling from inside a Claude Code session
unset CLAUDECODE 2>/dev/null || true

set -uo pipefail
IFS=$'\n\t'

# ── Resolve lib directory ────────────────────────────────────
DIFFHOUND_ROOT="${DIFFHOUND_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB_DIR="${DIFFHOUND_ROOT}/lib"

# ── Source modules ───────────────────────────────────────────
source "${LIB_DIR}/spinner.sh"
source "${LIB_DIR}/platform.sh"
source "${LIB_DIR}/parser.sh"
source "${LIB_DIR}/github.sh"
source "${LIB_DIR}/rag.sh" 2>/dev/null || true  # for _filter_rag_for_files, _trim_rag
source "${LIB_DIR}/jira.sh" 2>/dev/null || true  # for _extract_jira_ticket, _fetch_jira_ticket
source "${LIB_DIR}/lint.sh" 2>/dev/null || true  # for _run_static_analysis

# ── API Helper: direct Anthropic API calls ───────────────────────────────────
# Usage: printf '%s' "$prompt" | _call_api MODEL [MAX_TOKENS] [TIMEOUT_SECS]
#        _call_api MODEL [MAX_TOKENS] [TIMEOUT_SECS] < prompt_file
_call_api() {
  local model="$1"
  local max_tokens="${2:-4096}"
  local timeout_secs="${3:-120}"

  local _api_pf _api_jf
  _api_pf=$(mktemp -t "api-prompt.XXXXXX")
  _api_jf=$(mktemp -t "api-json.XXXXXX")
  cat > "$_api_pf"

  jq -n --arg model "$model" \
        --argjson max_tokens "$max_tokens" \
        --rawfile user "$_api_pf" \
    '{model: $model, max_tokens: $max_tokens,
      messages: [{role: "user", content: $user}]}' > "$_api_jf"
  rm -f "$_api_pf"

  local _api_r
  _api_r=$($_TIMEOUT_CMD "$timeout_secs" curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d @"$_api_jf" 2>/dev/null || echo "")
  rm -f "$_api_jf"

  printf '%s' "$_api_r" | jq -r '.content[0].text // empty' 2>/dev/null || true
}

# _call_api_system MODEL MAX_TOKENS TIMEOUT SYSTEM_FILE < user_prompt
_call_api_system() {
  local model="$1"
  local max_tokens="${2:-4096}"
  local timeout_secs="${3:-120}"
  local system_file="$4"

  local _api_pf _api_jf
  _api_pf=$(mktemp -t "api-prompt.XXXXXX")
  _api_jf=$(mktemp -t "api-json.XXXXXX")
  cat > "$_api_pf"

  jq -n --arg model "$model" \
        --argjson max_tokens "$max_tokens" \
        --rawfile system "$system_file" \
        --rawfile user "$_api_pf" \
    '{model: $model, max_tokens: $max_tokens,
      system: [{type: "text", text: $system, cache_control: {type: "ephemeral"}}],
      messages: [{role: "user", content: $user}]}' > "$_api_jf"
  rm -f "$_api_pf"

  local _api_r
  _api_r=$($_TIMEOUT_CMD "$timeout_secs" curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d @"$_api_jf" 2>/dev/null || echo "")
  rm -f "$_api_jf"

  printf '%s' "$_api_r" | jq -r '.content[0].text // empty' 2>/dev/null || true
}

# ── Verify dependencies ─────────────────────────────────────
_check_deps

# ── Health check — verify critical tools before starting ─────
_health_check() {
  local errors=0
  if \! gh auth status >/dev/null 2>&1; then
    echo "Error: gh not authenticated. Run: gh auth login" >&2
    errors=$((errors + 1))
  fi
  if \! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not found" >&2
    errors=$((errors + 1))
  fi
  local disk_avail
  disk_avail=$(df -m /tmp 2>/dev/null | awk "NR==2{print \$4}" || echo "999999")
  if [ "${disk_avail:-0}" -lt 100 ]; then
    echo "Error: Less than 100MB free in /tmp" >&2
    errors=$((errors + 1))
  fi
  return $errors
}

_health_check || exit 1

PR_NUMBER="${1:-}"
AUTO_POST=false
FAST_MODE=false
LEARN_MODE=false
REPO_ARG=""
FORCE_MONOLITHIC=false
FORCE_FULL=false
IS_SYNCHRONIZE=false

for _arg in "${@:2}"; do
  case "$_arg" in
    --auto-post)          AUTO_POST=true ;;
    --fast)               FAST_MODE=true ;;
    --learn)              LEARN_MODE=true ;;
    --force-monolithic)   FORCE_MONOLITHIC=true ;;
    --force-full)         FORCE_FULL=true ;;
    --synchronize)        IS_SYNCHRONIZE=true ;;
    --repo=*)             REPO_ARG="${_arg#--repo=}" ;;
    --repo)               ;; # value captured by next iteration hack below
  esac
done

# Handle --repo value (positional after flag)
_prev=""
for _arg in "${@:2}"; do
  if [ "$_prev" = "--repo" ]; then
    REPO_ARG="$_arg"
  fi
  _prev="$_arg"
done

# ── Configurable defaults (override via env vars) ────────────
REPO_PATH="${REVIEW_REPO_PATH:-}"
REVIEWER_LOGIN="${REVIEW_LOGIN:-}"

# Resolve repo path from --repo flag or env var
if [ -n "$REPO_ARG" ]; then
  _REPO_OWNER="${REPO_ARG%%/*}"
  _REPO_NAME="${REPO_ARG##*/}"
  _REPO_DIR="$HOME/repos/${_REPO_OWNER}/${_REPO_NAME}"

  if [ ! -d "$_REPO_DIR/.git" ]; then
    echo "  Cloning ${REPO_ARG}..."
    mkdir -p "$HOME/repos/${_REPO_OWNER}"
    if ! git clone --depth=50 "https://github.com/${REPO_ARG}.git" "$_REPO_DIR" 2>&1; then
      echo "Error: Failed to clone ${REPO_ARG}" >&2
      exit 1
    fi
  else
    # Pull latest
    (cd "$_REPO_DIR" && git fetch --all --prune -q && git pull -q 2>/dev/null || true)
  fi

  REPO_PATH="$_REPO_DIR"
  # Derive reviewer login from gh if not set
  [ -z "$REVIEWER_LOGIN" ] && REVIEWER_LOGIN=$(gh api user --jq '.login' 2>/dev/null || echo "")
fi

if [ -z "$REPO_PATH" ] || [ -z "$REVIEWER_LOGIN" ]; then
  echo "Error: REVIEW_REPO_PATH and REVIEW_LOGIN must be set (or use --repo owner/name)." >&2
  echo "  export REVIEW_REPO_PATH=\"\$HOME/path/to/your/repo\"" >&2
  echo "  export REVIEW_LOGIN=\"your-github-username\"" >&2
  echo "  Or: $0 <PR_NUMBER> --repo owner/name" >&2
  exit 1
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Usage: $0 <PR_NUMBER> [--auto-post] [--fast] [--repo owner/name]"
  exit 1
fi



if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: PR_NUMBER must be numeric" >&2
  exit 1
fi

cd "$REPO_PATH" || { echo "Error: Cannot cd to $REPO_PATH" >&2; exit 1; }

# ============================================================
# STEP 0: LOAD REPO CONFIG (.diffhound.yml or .diffhound.md)
# ============================================================
DIFFHOUND_CONFIG=""
DIFFHOUND_PRIORITIES=""
DIFFHOUND_IGNORE=""
DIFFHOUND_SKIP_FILES=""
DIFFHOUND_CONTEXT=""
DIFFHOUND_SEVERITY_OVERRIDES=""

_load_repo_config() {
  local config_file=""
  if [ -f "$REPO_PATH/.diffhound.yml" ]; then
    config_file="$REPO_PATH/.diffhound.yml"
  elif [ -f "$REPO_PATH/.diffhound.yaml" ]; then
    config_file="$REPO_PATH/.diffhound.yaml"
  elif [ -f "$REPO_PATH/.diffhound.md" ]; then
    # Markdown config — inject as-is into prompt context
    DIFFHOUND_CONTEXT=$(cat "$REPO_PATH/.diffhound.md" 2>/dev/null)
    echo "  📋 Loaded .diffhound.md config"
    return 0
  fi

  [ -z "$config_file" ] && return 0

  DIFFHOUND_CONFIG="$config_file"

  # Parse with python3 (yaml) or yq if available
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
    # Extract each section via python3 inline
    DIFFHOUND_PRIORITIES=$(python3 -c "
import yaml, sys
try:
    with open('$config_file') as f:
        cfg = yaml.safe_load(f)
    review = cfg.get('review', {})
    for p in review.get('priorities', []):
        print(p)
except: pass
" 2>/dev/null || true)

    DIFFHOUND_IGNORE=$(python3 -c "
import yaml, sys
try:
    with open('$config_file') as f:
        cfg = yaml.safe_load(f)
    review = cfg.get('review', {})
    for i in review.get('ignore', []):
        print(i)
except: pass
" 2>/dev/null || true)

    DIFFHOUND_SKIP_FILES=$(python3 -c "
import yaml, sys
try:
    with open('$config_file') as f:
        cfg = yaml.safe_load(f)
    review = cfg.get('review', {})
    for s in review.get('skip_files', []):
        print(s)
except: pass
" 2>/dev/null || true)

    DIFFHOUND_CONTEXT=$(python3 -c "
import yaml, sys
try:
    with open('$config_file') as f:
        cfg = yaml.safe_load(f)
    review = cfg.get('review', {})
    ctx = review.get('context', '')
    if ctx: print(ctx)
except: pass
" 2>/dev/null || true)

    DIFFHOUND_SEVERITY_OVERRIDES=$(python3 -c "
import yaml, json, sys
try:
    with open('$config_file') as f:
        cfg = yaml.safe_load(f)
    review = cfg.get('review', {})
    sev = review.get('severity', {})
    if sev: print(json.dumps(sev))
except: pass
" 2>/dev/null || true)

    echo "  📋 Loaded config from $config_file"
  elif command -v yq >/dev/null 2>&1; then
    DIFFHOUND_PRIORITIES=$(yq -r '.review.priorities[]?' "$config_file" 2>/dev/null || true)
    DIFFHOUND_IGNORE=$(yq -r '.review.ignore[]?' "$config_file" 2>/dev/null || true)
    DIFFHOUND_SKIP_FILES=$(yq -r '.review.skip_files[]?' "$config_file" 2>/dev/null || true)
    DIFFHOUND_CONTEXT=$(yq -r '.review.context // ""' "$config_file" 2>/dev/null || true)
    echo "  📋 Loaded config from $config_file (via yq)"
  else
    echo "  ⚠ .diffhound.yml found but no yaml parser available. Install: pip3 install pyyaml OR brew install yq" >&2
  fi
}

_load_repo_config

# Apply skip_files filter to diff if configured
_filter_diff_by_config() {
  local diff_file="$1"
  [ -z "$DIFFHOUND_SKIP_FILES" ] && return 0

  local filtered_diff
  filtered_diff=$(mktemp -t "pr-filtered-diff.XXXXXX")
  local skip_pattern=""
  while IFS= read -r skip; do
    [ -z "$skip" ] && continue
    # Convert glob to regex (basic: ** -> .*, * -> [^/]*)
    local regex
    regex=$(printf '%s' "$skip" | sed 's/\./\./g; s/\*\*/DOUBLESTAR/g; s/\*/[^\/]*/g; s/DOUBLESTAR/.*/g')
    if [ -z "$skip_pattern" ]; then
      skip_pattern="$regex"
    else
      skip_pattern="${skip_pattern}|${regex}"
    fi
  done <<< "$DIFFHOUND_SKIP_FILES"

  if [ -n "$skip_pattern" ]; then
    # Filter out diff hunks for matching files
    if awk -v pattern="$skip_pattern" '
      /^diff --git/ {
        split($0, parts, " b/")
        file = parts[2]
        if (match(file, pattern)) { skip = 1 } else { skip = 0 }
      }
      !skip { print }
      END { if (pending && hold != "") {} }
    ' "$diff_file" > "$filtered_diff" 2>/dev/null; then
      if [ -s "$filtered_diff" ]; then
        mv "$filtered_diff" "$diff_file"
      else
        echo "  Warning: skip_files matched ALL files - using unfiltered diff" >&2
        rm -f "$filtered_diff"
      fi
    else
      echo "  Warning: skip_files filter failed - using unfiltered diff" >&2
      rm -f "$filtered_diff"
    fi
  else
    rm -f "$filtered_diff"
  fi
}

# ── Review cache directory (persistent across runs) ─────────
# Per-repo cache directory
_CACHE_REPO_ID=$(cd "$REPO_PATH" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null | tr '/' '-' || basename "$REPO_PATH")
REVIEW_CACHE_DIR="$HOME/.diffhound/cache/${_CACHE_REPO_ID}"
mkdir -p "$REVIEW_CACHE_DIR"

# ── --learn: Feedback loop — learn from edited/deleted GitHub comments ──────
_learn_from_pr() {
  local pr="$1"
  local cache_file="$REVIEW_CACHE_DIR/pr-${pr}-posted.json"
  local voice_jsonl="$HOME/.diffhound/voice-examples.jsonl"

  if [ ! -f "$cache_file" ]; then
    echo "No posted-comment cache for PR #${pr}." >&2
    echo "Run the review first (without --learn) to generate a cache." >&2
    return 1
  fi

  echo "📚 Learning from PR #${pr} feedback..."

  local repo_owner repo_name
  repo_owner=$(gh repo view --json owner --jq '.owner.login')
  repo_name=$(gh repo view --json name --jq '.name')

  # Fetch current reviewer comments on this PR from GitHub
  local current_comments
  current_comments=$(gh api \
    "/repos/${repo_owner}/${repo_name}/pulls/${pr}/comments" \
    --jq "[.[] | select(.user.login == \"${REVIEWER_LOGIN}\") | {id,path,line,body,updated_at}]" \
    2>/dev/null || echo "[]")

  local posted_lines
  posted_lines=$(jq -r '.comments[]' "$cache_file" 2>/dev/null || true)

  local learned=0 removed=0 updated=0

  while IFS= read -r original_line; do
    [ -z "$original_line" ] && continue

    local orig_body orig_path
    orig_body=$(printf '%s' "$original_line" | sed -E 's/^[^:]+:[~]?[0-9]+:(BLOCKING|SHOULD-FIX|NIT)[[:space:]][—–-][[:space:]]*//')
    orig_path=$(printf '%s' "$original_line" | cut -d: -f1)
    local orig_prefix="${orig_body:0:60}"

    local gh_body
    gh_body=$(printf '%s' "$current_comments" | jq -r \
      --arg path "$orig_path" --arg prefix "$orig_prefix" \
      '[.[] | select(.path == $path and (.body | startswith($prefix)))] | first | .body // empty' \
      2>/dev/null || true)

    if [ -z "$gh_body" ]; then
      # Comment deleted — remove from JSONL
      if [ -f "$voice_jsonl" ]; then
        local _tmp
        _tmp=$(mktemp -t "voice-trim.XXXXXX")
        jq -c --arg prefix "$orig_prefix" \
          'select((.comment | startswith($prefix)) | not)' \
          "$voice_jsonl" > "$_tmp" 2>/dev/null && mv "$_tmp" "$voice_jsonl" || rm -f "$_tmp"
      fi
      removed=$((removed + 1))
    elif [ "$gh_body" != "$orig_body" ]; then
      # Comment edited — update JSONL with human-corrected version
      if [ -f "$voice_jsonl" ]; then
        local _tmp
        _tmp=$(mktemp -t "voice-update.XXXXXX")
        jq -c --arg old "$orig_prefix" --arg new "$gh_body" \
          'if (.comment | startswith($old)) then .comment = $new | .human_verified = true else . end' \
          "$voice_jsonl" > "$_tmp" 2>/dev/null && mv "$_tmp" "$voice_jsonl" || rm -f "$_tmp"
      fi
      updated=$((updated + 1))
    else
      learned=$((learned + 1))
    fi
  done <<< "$posted_lines"

  # ── Reply-based learning: detect dev replies that dismiss/reject a comment ──
  local replied=0
  # Fetch ALL comments on this PR (includes threads)
  local all_comments
  all_comments=$(gh api \
    "/repos/${repo_owner}/${repo_name}/pulls/${pr}/comments" \
    --paginate \
    --jq "[.[] | {id, user: .user.login, body, in_reply_to_id, path, line}]" \
    2>/dev/null || echo "[]")

  # Find reviewer comments that received replies
  local reviewer_comment_ids
  reviewer_comment_ids=$(printf '%s' "$all_comments" | jq -r \
    --arg login "$REVIEWER_LOGIN" \
    '[.[] | select(.user == $login and .in_reply_to_id == null) | .id] | .[]')

  while IFS= read -r cid; do
    [ -z "$cid" ] && continue

    # Get replies to this reviewer comment
    # NOTE: Can't filter by .user != $login because reviewer and dev may share the
    # same GitHub account. Instead, get ALL replies and filter out bot-posted ones
    # using the posted-comments cache (bot comments match the cache, human replies don't).
    local _all_replies
    _all_replies=$(printf '%s' "$all_comments" | jq -c \
      --argjson parent "$cid" \
      '[.[] | select(.in_reply_to_id == $parent)]')
    local _reply_count
    _reply_count=$(echo "$_all_replies" | jq 'length' 2>/dev/null || echo "0")
    [ "${_reply_count:-0}" -eq 0 ] && continue

    # Filter out bot-posted replies (match body prefix against posted cache)
    local _posted_cache="$REVIEW_CACHE_DIR/pr-${pr}-posted.json"
    local replies=""
    for _ri in $(seq 0 $((_reply_count - 1))); do
      local _r_body
      _r_body=$(echo "$_all_replies" | jq -r ".[$_ri].body")
      local _r_prefix="${_r_body:0:80}"
      local _is_bot=false
      if [ -f "$_posted_cache" ] && jq -r '.comments[]' "$_posted_cache" 2>/dev/null | grep -qF "$_r_prefix" 2>/dev/null; then
        _is_bot=true
      fi
      # Also check response cache (previous AI replies)
      local _r_id
      _r_id=$(echo "$_all_replies" | jq -r ".[$_ri].id")
      local _resp_cache="$REVIEW_CACHE_DIR/pr-${pr}-responses.txt"
      if [ -f "$_resp_cache" ] && grep -qx "$_r_id" "$_resp_cache" 2>/dev/null; then
        _is_bot=true
      fi
      if [ "$_is_bot" = false ]; then
        replies="${replies}${_r_body}
"
      fi
    done
    replies=$(echo "$replies" | sed '/^$/d')
    [ -z "$replies" ] && continue

    # Get the original reviewer comment body
    local orig_comment
    orig_comment=$(printf '%s' "$all_comments" | jq -r \
      --argjson cid "$cid" \
      '.[] | select(.id == $cid) | .body')

    # Record the feedback pair: reviewer comment + dev reply (with dedup)
    local feedback_file="$REVIEW_CACHE_DIR/pr-${pr}-feedback.jsonl"
    while IFS= read -r reply_body; do
      [ -z "$reply_body" ] && continue

      # ── Dedup: skip if same reviewer_comment prefix + dev_reply prefix already exists ──
      local _rc_prefix="${orig_comment:0:80}"
      local _dr_prefix="${reply_body:0:80}"
      if [ -f "$feedback_file" ]; then
        local _is_dup
        _is_dup=$(jq -r --arg rcp "$_rc_prefix" --arg drp "$_dr_prefix" \
          'select((.reviewer_comment | startswith($rcp)) and (.dev_reply | startswith($drp))) | "dup"' \
          "$feedback_file" 2>/dev/null | head -1 || true)
        [ "$_is_dup" = "dup" ] && continue
      fi

      printf '%s\n' "$(jq -nc \
        --arg review "$orig_comment" \
        --arg reply "$reply_body" \
        --argjson pr "$pr" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{pr: $pr, reviewer_comment: $review, dev_reply: $reply, timestamp: $ts}')" \
        >> "$feedback_file"
      replied=$((replied + 1))
    done <<< "$replies"
  done <<< "$reviewer_comment_ids"

  # Auto-purge cache files older than 30 days
  find "$REVIEW_CACHE_DIR" -name "pr-*-posted.json" -mtime +30 -delete 2>/dev/null || true

  echo ""
  echo "  ✅ $learned comments verified unchanged"
  echo "  ✏️  $updated comments updated (human edits applied)"
  echo "  🗑️  $removed comments removed (deleted on GitHub)"
  [ "$replied" -gt 0 ] && echo "  💬 $replied dev replies recorded for learning"

  # ── Reply-based response: generate AI replies to dev comments ──
  if [ "$replied" -gt 0 ]; then
    _respond_to_dev_replies "$pr" "$repo_owner" "$repo_name" "$all_comments"
  fi

  # ── Distill false positives into learned patterns ──
  _distill_false_positives "$pr" "$repo_owner" "$repo_name"

  # ── Auto-resolve threads where dev confirmed resolution ──
  _auto_resolve_replied_threads "$pr" "$repo_owner" "$repo_name" "$all_comments"
}

# ── Auto-resolve GitHub review threads based on dev replies ──
_auto_resolve_replied_threads() {
  local pr="$1" repo_owner="$2" repo_name="$3" all_comments="$4"
  local resolved=0

  # Resolution keywords: dev acknowledged or accepted the review comment
  local _resolution_re="(^fixed|^done|^addressed|^agreed|^correct|^good point|^will do|^updated|^by design|^intentional|^acceptable|^fair point|^makes sense)"

  # Get all reviewer top-level comment IDs
  local reviewer_ids
  reviewer_ids=$(printf '%s' "$all_comments" | jq -r \
    --arg login "$REVIEWER_LOGIN" \
    '[.[] | select(.user == $login and .in_reply_to_id == null) | .id] | .[]')

  # Response cache: threads where Diffhound posted an AI reply THIS run
  local response_cache="$REVIEW_CACHE_DIR/pr-${pr}-responses.txt"

  # Collect thread IDs to resolve
  local threads_to_resolve=()
  while IFS= read -r cid; do
    [ -z "$cid" ] && continue

    # Get the thread
    local thread
    thread=$(printf '%s' "$all_comments" | jq -c \
      --argjson parent "$cid" \
      '[.[] | select(.id == $parent or .in_reply_to_id == $parent)] | sort_by(.id)')

    local tlen
    tlen=$(echo "$thread" | jq 'length' 2>/dev/null || echo "0")
    [ "${tlen:-0}" -le 1 ] && continue

    # Get the last reply (from dev, not bot -- already filtered by cache in _respond_to_dev_replies)
    local last_body last_id
    last_body=$(echo "$thread" | jq -r '.[-1].body' | head -5)
    last_id=$(echo "$thread" | jq -r '.[-1].id')

    # Skip if Diffhound posted a pushback reply to this thread in this run
    # (means the AI disagreed with the dev -- don't auto-resolve)
    if [ -f "$response_cache" ] && grep -qx "$last_id" "$response_cache" 2>/dev/null; then
      continue
    fi

    # Check if dev's reply matches resolution keywords (case-insensitive, first line)
    local first_line
    first_line=$(echo "$last_body" | head -1 | tr '[:upper:]' '[:lower:]')
    if echo "$first_line" | grep -qiE "$_resolution_re"; then
      threads_to_resolve+=("$cid")
    fi
  done <<< "$reviewer_ids"

  [ "${#threads_to_resolve[@]}" -eq 0 ] && return 0

  # Fetch thread IDs via GraphQL (maps REST databaseId -> GraphQL thread id)
  local gql_query
  gql_query=$(printf '{"query":"query { repository(owner:\"%s\", name:\"%s\") { pullRequest(number:%s) { reviewThreads(first:100) { nodes { id isResolved comments(first:1) { nodes { databaseId } } } } } } }"}' \
    "$repo_owner" "$repo_name" "$pr")

  local threads_response
  threads_response=$(echo "$gql_query" | gh api graphql --input - 2>/dev/null)
  if [ -z "$threads_response" ]; then
    echo "  warning: GraphQL thread fetch failed -- skipping auto-resolve" >&2
    return 0
  fi

  local thread_map
  thread_map=$(printf '%s' "$threads_response" | jq -c '
    [.data.repository.pullRequest.reviewThreads.nodes[] |
     select(.comments.nodes | length > 0) |
     {db_id: .comments.nodes[0].databaseId, thread_id: .id, is_resolved: .isResolved}]' 2>/dev/null || echo "[]")

  for cid in "${threads_to_resolve[@]}"; do
    local thread_id is_resolved
    thread_id=$(printf '%s' "$thread_map" | jq -r --argjson dbid "$cid" \
      '.[] | select(.db_id == $dbid) | .thread_id' 2>/dev/null)
    is_resolved=$(printf '%s' "$thread_map" | jq -r --argjson dbid "$cid" \
      '.[] | select(.db_id == $dbid) | .is_resolved' 2>/dev/null)

    [ -z "$thread_id" ] && continue
    [ "$is_resolved" = "true" ] && continue

    if echo '{"query":"mutation { resolveReviewThread(input:{threadId:\"'"$thread_id"'\"}) { thread { isResolved } } }"}' \
      | gh api graphql --input - > /dev/null 2>&1; then
      resolved=$((resolved + 1))
    fi
  done

  [ "$resolved" -gt 0 ] && echo "  resolved ${resolved} thread(s) where dev confirmed fix" >&2
}

# ── Respond to dev replies with AI-generated conversational replies ──
_respond_to_dev_replies() {
  local pr="$1" repo_owner="$2" repo_name="$3" all_comments="$4"
  local responded=0 max_responses=5

  # Find reviewer top-level comment IDs
  local reviewer_ids
  reviewer_ids=$(printf '%s' "$all_comments" | jq -r \
    --arg login "$REVIEWER_LOGIN" \
    '[.[] | select(.user == $login and .in_reply_to_id == null) | .id] | .[]')

  while IFS= read -r cid; do
    [ -z "$cid" ] && continue
    [ "$responded" -ge "$max_responses" ] && break

    # Get the full thread for this comment: original + all replies, ordered by id
    local thread
    thread=$(printf '%s' "$all_comments" | jq -c \
      --argjson parent "$cid" \
      '[.[] | select(.id == $parent or .in_reply_to_id == $parent)] | sort_by(.id)')

    # Check if the last message in thread is from the bot (not a human dev)
    # Can't rely on username alone (reviewer and dev may share the same GH account).
    # Instead: check if the last message's body is in our posted-comments cache
    # or response cache. If it is, Diffhound posted it -- skip. If not, a human wrote it.
    local last_body last_reply_id_check
    last_body=$(printf '%s' "$thread" | jq -r '.[-1].body')
    last_reply_id_check=$(printf '%s' "$thread" | jq -r '.[-1].id')
    local _is_bot_message=false
    # Check response cache (previous AI replies)
    local response_cache="$REVIEW_CACHE_DIR/pr-${pr}-responses.txt"
    if [ -f "$response_cache" ] && grep -qx "$last_reply_id_check" "$response_cache" 2>/dev/null; then
      _is_bot_message=true
    fi
    # Check posted-comments cache (original review comments)
    if [ "$_is_bot_message" = false ]; then
      local _posted_cache="$REVIEW_CACHE_DIR/pr-${pr}-posted.json"
      if [ -f "$_posted_cache" ]; then
        # Match first 80 chars of the body against posted comments
        local _body_prefix="${last_body:0:80}"
        if jq -r '.comments[]' "$_posted_cache" 2>/dev/null | grep -qF "$_body_prefix" 2>/dev/null; then
          _is_bot_message=true
        fi
      fi
    fi
    [ "$_is_bot_message" = true ] && continue

    # Reuse last_reply_id_check as last_reply_id for the response cache write later
    local last_reply_id="$last_reply_id_check"

    # Gather context for the AI call
    local original_comment dev_reply file_path
    original_comment=$(printf '%s' "$thread" | jq -r '.[0].body')
    dev_reply=$(printf '%s' "$thread" | jq -r '.[-1].body')
    file_path=$(printf '%s' "$thread" | jq -r '.[0].path // empty')

    # Get minimal code context (~20 lines around the comment)
    local code_context=""
    if [ -n "$file_path" ] && [ -f "${REPO_PATH}/${file_path}" ]; then
      local comment_line
      comment_line=$(printf '%s' "$thread" | jq -r '.[0].line // 0')
      if [ "$comment_line" -gt 0 ] 2>/dev/null; then
        local start_line=$((comment_line > 10 ? comment_line - 10 : 1))
        code_context=$(sed -n "${start_line},$((comment_line + 10))p" "${REPO_PATH}/${file_path}" 2>/dev/null || true)
      fi
    fi

    # Build the prompt (use temp file to avoid quote-breaking from comment bodies)
    local _prompt_file
    _prompt_file=$(mktemp -t "respond-prompt-${pr}.XXXXXX")
    {
      cat << 'RESPOND_RULES'
You are a code reviewer replying to a developer's response on a PR comment.
RESPOND_RULES
      echo ""
      echo "YOUR ORIGINAL COMMENT:"
      printf '%s\n' "$original_comment"
      echo ""
      echo "DEVELOPER'S REPLY:"
      printf '%s\n' "$dev_reply"
      echo ""
      if [ -n "$code_context" ]; then
        echo "CODE CONTEXT (${file_path} around the comment):"
        printf '%s\n' "$code_context"
        echo ""
      fi
      cat << 'RESPOND_RULES_END'
Rules:
- If dev says "fixed"/"done" → reply "thanks, will verify on next push" (1 line)
- If dev chose an option you suggested → acknowledge briefly
- If dev says "intentional" → accept if reasonable, push back with evidence if not
- If dev asks a question → answer concisely
- If dev disagrees → re-evaluate honestly. Concede if they're right.
- Keep replies to 1-3 sentences. Same casual voice as your review comments.
- NEVER repeat the original concern verbatim. The thread already has it.
- NEVER mention AI, automated review, or any tool name.
RESPOND_RULES_END
    } > "$_prompt_file"
    local prompt
    prompt=$(cat "$_prompt_file")
    rm -f "$_prompt_file"

    # Call Claude Haiku via API (fast + cheap)
    local ai_reply=""
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      local _resp_json
      _resp_json=$(mktemp -t "respond-${pr}.XXXXXX")
      jq -n --arg prompt "$prompt" '{
        model: "claude-haiku-4-5-20251001",
        max_tokens: 256,
        messages: [{role: "user", content: $prompt}]
      }' > "$_resp_json"

      local _api_out
      _api_out=$(curl -sf https://api.anthropic.com/v1/messages \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d @"$_resp_json" 2>/dev/null || echo "")
      rm -f "$_resp_json"

      ai_reply=$(printf '%s' "$_api_out" | jq -r '.content[0].text // empty' 2>/dev/null || true)
    fi

    # Fallback: direct API (no CLI dependency)
    if [ -z "$ai_reply" ]; then
      ai_reply=$(printf '%s' "$prompt" | _call_api "claude-haiku-4-5-20251001" 256 30 || true)
    fi

    [ -z "$ai_reply" ] && continue

    # Post the reply to the thread
    if gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/repos/${repo_owner}/${repo_name}/pulls/${pr}/comments/${cid}/replies" \
      --field "body=${ai_reply}" > /dev/null 2>&1; then
      responded=$((responded + 1))
      # Record in response cache to prevent double-replying
      echo "$last_reply_id" >> "$response_cache"
    fi
  done <<< "$reviewer_ids"

  [ "$responded" -gt 0 ] && echo "  🗣️  $responded AI responses posted to dev replies"
}

# ── Distill false positives into learned patterns ────────────────────────────
# Reads feedback.jsonl, checks if Diffhound conceded, extracts lessons via Haiku
_distill_false_positives() {
  local pr="$1" repo_owner="$2" repo_name="$3"
  local feedback_file="$REVIEW_CACHE_DIR/pr-${pr}-feedback.jsonl"
  local patterns_file="$HOME/.diffhound/learned-patterns.jsonl"

  [ -f "$feedback_file" ] || return 0
  mkdir -p "$HOME/.diffhound"
  [ -f "$patterns_file" ] || touch "$patterns_file"

  # Fetch all PR comments for thread context
  local all_comments
  all_comments=$(gh api \
    -H "Accept: application/vnd.github+json" \
    "/repos/${repo_owner}/${repo_name}/pulls/${pr}/comments" \
    --paginate \
    --jq "[.[] | {id, user: .user.login, body, in_reply_to_id}]" \
    2>/dev/null || echo "[]")

  # Concession phrases that indicate Diffhound acknowledged a false positive
  local concession_pattern="you're right|you are right|fair point|good point|acknowledged|missed that|makes sense|my mistake|correct|apologies|you're correct|actually fine|not an issue|false positive"

  local distilled=0
  local skipped=0

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue

    # Skip already distilled entries
    local is_distilled
    is_distilled=$(printf '%s' "$entry" | jq -r '.distilled // false')
    [ "$is_distilled" = "true" ] && { skipped=$((skipped + 1)); continue; }

    local reviewer_comment dev_reply
    reviewer_comment=$(printf '%s' "$entry" | jq -r '.reviewer_comment')
    dev_reply=$(printf '%s' "$entry" | jq -r '.dev_reply')

    # Skip blank/whitespace-only dev replies
    [ -z "$(printf '%s' "$dev_reply" | tr -d '[:space:]')" ] && continue

    # Check if Diffhound replied with concession to this thread
    local reviewer_replied_concession=false

    # Find the reviewer comment ID that matches this body prefix
    local rc_prefix="${reviewer_comment:0:80}"
    local matching_cid
    matching_cid=$(printf '%s' "$all_comments" | jq -r \
      --arg login "$REVIEWER_LOGIN" --arg prefix "$rc_prefix" \
      '[.[] | select(.user == $login and .in_reply_to_id == null and (.body | startswith($prefix)))] | .[0].id // empty')

    if [ -n "$matching_cid" ]; then
      # Check replies from reviewer that contain concession phrases
      local reviewer_concession
      reviewer_concession=$(printf '%s' "$all_comments" | jq -r \
        --argjson parent "$matching_cid" --arg login "$REVIEWER_LOGIN" \
        '[.[] | select(.in_reply_to_id == $parent and .user == $login)] | .[].body' 2>/dev/null || true)

      if [ -n "$reviewer_concession" ] && printf '%s' "$reviewer_concession" | grep -qiE "$concession_pattern"; then
        reviewer_replied_concession=true
      fi
    fi

    [ "$reviewer_replied_concession" = false ] && continue

    # ── Extract lesson via Claude Haiku ──
    local _lesson_prompt_file
    _lesson_prompt_file=$(mktemp -t "lesson-prompt-${pr}.XXXXXX")
    {
      cat << 'LESSON_RULES'
Extract a single one-line lesson from this false positive in code review.
LESSON_RULES
      echo ""
      echo "REVIEWER COMMENT (false positive):"
      printf '%s\n' "${reviewer_comment:0:500}"
      echo ""
      echo "DEV REPLY (correction):"
      printf '%s\n' "${dev_reply:0:500}"
      echo ""
      cat << 'LESSON_RULES_END'
Write EXACTLY one line in this format: Do not flag X when Y because Z.
No preamble, no explanation, just the one line.
LESSON_RULES_END
    } > "$_lesson_prompt_file"
    local lesson_prompt
    lesson_prompt=$(cat "$_lesson_prompt_file")
    rm -f "$_lesson_prompt_file"

    local lesson=""
    lesson=$(printf '%s' "$lesson_prompt" | _call_api "claude-haiku-4-5-20251001" 256 30 | head -1 || true)

    [ -z "$lesson" ] && continue
    # Sanitize: remove leading "- " or "* " if present
    lesson="${lesson#- }"
    lesson="${lesson#\* }"

    # ── Dedup: skip if same lesson prefix already in patterns ──
    local lesson_prefix="${lesson:0:60}"
    local _lesson_dup
    _lesson_dup=$(jq -r --arg lp "$lesson_prefix" \
      'select(.lesson | startswith($lp)) | "dup"' \
      "$patterns_file" 2>/dev/null | head -1 || true)
    [ "$_lesson_dup" = "dup" ] && continue

    # Append lesson
    jq -nc \
      --argjson pr "$pr" \
      --arg category "general" \
      --arg lesson "$lesson" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{pr: $pr, category: $category, lesson: $lesson, timestamp: $ts}' \
      >> "$patterns_file"
    distilled=$((distilled + 1))
  done < "$feedback_file"

  # ── Mark all entries as distilled (idempotency) ──
  if [ "$distilled" -gt 0 ] || [ "$skipped" -gt 0 ]; then
    local _tmp_feedback
    _tmp_feedback=$(mktemp -t "feedback-distill.XXXXXX")
    jq -c '. + {distilled: true}' "$feedback_file" > "$_tmp_feedback" 2>/dev/null \
      && mv "$_tmp_feedback" "$feedback_file" \
      || rm -f "$_tmp_feedback"
  fi

  [ "$distilled" -gt 0 ] && echo "  🧠 Distilled $distilled false positive lesson(s)"
  return 0
}

# ── --learn early exit ──────────────────────────────────────
if [ "$LEARN_MODE" = true ]; then
  cd "$REPO_PATH" 2>/dev/null || true
  REPO_OWNER=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null)
  REPO_NAME=$(gh repo view --json name --jq '.name' 2>/dev/null)
  echo "📚 Learning from PR #${PR_NUMBER}..."
  _learn_from_pr "$PR_NUMBER"
  exit 0
fi

echo ""
echo "🔍 PR #${PR_NUMBER}"
echo "──────────────────────────────────────────"

spinner_start "Fetching PR metadata..."
REPO_OWNER=$(gh repo view --json owner --jq '.owner.login')
REPO_NAME=$(gh repo view --json name --jq '.name')
if ! PR_DATA=$($_TIMEOUT_CMD 300 gh pr view "$PR_NUMBER" --json title,body,author,files,additions,deletions,headRefOid,headRefName 2>&1); then
  spinner_fail "Failed to fetch PR #${PR_NUMBER}"
  exit 1
fi

PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
PR_AUTHOR=$(echo "$PR_DATA" | jq -r '.author.login')
PR_BODY=$(echo "$PR_DATA" | jq -r '.body')
FILE_COUNT=$(echo "$PR_DATA" | jq -r '.files | length')
ADDITIONS=$(echo "$PR_DATA" | jq -r '.additions')
DELETIONS=$(echo "$PR_DATA" | jq -r '.deletions')
HEAD_SHA=$(echo "$PR_DATA" | jq -r '.headRefOid')
HEAD_REF_NAME=$(echo "$PR_DATA" | jq -r '.headRefName // empty')

spinner_stop "PR metadata fetched"

# ============================================================
# STEP 0.65: CHECKOUT PR BRANCH (so Read/Bash tools see PR code, not base branch)
# ============================================================
_ORIGINAL_REF=""
if [ -n "$REPO_PATH" ] && [ -d "$REPO_PATH/.git" ]; then
  _ORIGINAL_REF=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  # Fetch the PR's head commit and checkout
  if [ -n "$HEAD_SHA" ]; then
    (
      cd "$REPO_PATH"
      git fetch origin "$HEAD_SHA" --depth=50 -q 2>/dev/null || \
        git fetch origin "+refs/pull/${PR_NUMBER}/head:refs/remotes/origin/pr-${PR_NUMBER}" -q 2>/dev/null || true
      git checkout "$HEAD_SHA" -q 2>/dev/null || true
    )
    _CURRENT_SHA=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null || true)
    if [ "${_CURRENT_SHA:0:8}" = "${HEAD_SHA:0:8}" ]; then
      echo "  🔀 Repo checked out to PR HEAD (${HEAD_SHA:0:8})"
    else
      echo "  ⚠ Could not checkout PR HEAD — file reads may use base branch" >&2
    fi
  fi
fi

# ============================================================
# STEP 0.7: JIRA TICKET FETCH (requirement coverage)
# ============================================================
JIRA_CONTEXT=""
if [ "${_JIRA_SOURCED:-}" = true ]; then
  JIRA_TICKET=$(_extract_jira_ticket "$PR_TITLE" "$HEAD_REF_NAME" "$PR_BODY")
  if [ -n "$JIRA_TICKET" ]; then
    spinner_start "Fetching Jira ticket ${JIRA_TICKET}..."
    JIRA_CONTEXT=$(_fetch_jira_ticket "$JIRA_TICKET" 2>/dev/null || true)
    if [ -n "$JIRA_CONTEXT" ]; then
      spinner_stop "Jira context loaded (${JIRA_TICKET})"
    else
      spinner_stop "Jira fetch failed — skipping requirement coverage"
    fi
  fi
fi
echo "  📄 ${PR_TITLE}"
echo "  👤 @${PR_AUTHOR}  •  ${FILE_COUNT} files  +${ADDITIONS}/-${DELETIONS}"

# Temp files
DIFF_FILE=$(mktemp -t "pr-${PR_NUMBER}-diff.XXXXXX")
PROMPT_FILE=$(mktemp -t "pr-${PR_NUMBER}-prompt.XXXXXX")
CLAUDE_OUT=$(mktemp -t "pr-${PR_NUMBER}-claude.XXXXXX")
CODEX_OUT=$(mktemp -t "pr-${PR_NUMBER}-codex.XXXXXX")
GEMINI_OUT=$(mktemp -t "pr-${PR_NUMBER}-gemini.XXXXXX")
SYNTH_PROMPT=$(mktemp -t "pr-${PR_NUMBER}-synth-prompt.XXXXXX")
REVIEW_STRUCTURED=$(mktemp -t "pr-${PR_NUMBER}-structured.XXXXXX")
REVIEW_SUMMARY=$(mktemp -t "pr-${PR_NUMBER}-summary.XXXXXX")
REVIEW_JSON=$(mktemp -t "pr-${PR_NUMBER}-review.XXXXXX")

cleanup() {
  local exit_code=$?
  [ -n "${_spinner_pid:-}" ] && kill "$_spinner_pid" 2>/dev/null && wait "$_spinner_pid" 2>/dev/null || true
  _spinner_pid=""
  rm -f "${DIFF_FILE:-}" "${PROMPT_FILE:-}" "${CLAUDE_OUT:-}" "${CODEX_OUT:-}" "${GEMINI_OUT:-}" \
        "${PEER_PROMPT_FILE:-}" "${SYNTH_PROMPT:-}" "${REVIEW_STRUCTURED:-}" "${REVIEW_SUMMARY:-}" \
        "${REVIEW_JSON:-}" "${REVIEW_STRUCTURED:-}.comments" "${REVIEW_STRUCTURED:-}.new_comments" \
        "${REVIEW_STRUCTURED:-}.replies" "${SYNTH_FINDINGS:-}" "${STYLE_PROMPT:-}" \
        "${EXISTING_COMMENTS_FILE:-}" "${EXISTING_REVIEWS_FILE:-}" "${THREADS_SUMMARY_FILE:-}" \
        "${INCREMENTAL_DIFF_FILE:-}" "${INCREMENTAL_FILES_LIST:-}" \
        "${_USER_TMP:-}" "${VOICE_EXAMPLES_FILE:-}" "${RAG_CONTEXT_FILE:-}" \
        "${VERIFY_PROMPT:-}" "${VERIFY_OUT:-}" \
        "${CLEANED_DIFF:-}" "${COMPRESSED_DIFF:-}" "${TRIAGE_FILE:-}" "${PR_SUMMARY_HEADER_FILE:-}"
  [ -n "${CHUNK_DIR:-}" ] && rm -rf "$CHUNK_DIR" 2>/dev/null || true

  # Restore original branch after PR HEAD checkout
  if [ -n "${_ORIGINAL_REF:-}" ] && [ -d "${REPO_PATH:-}/.git" ]; then
    git -C "$REPO_PATH" checkout "$_ORIGINAL_REF" -q 2>/dev/null || true
  fi

  # Post failure comment if review crashed mid-way
  # Skip for signal kills (exit >= 128): these are GHA concurrency cancellations, not real failures
  # SIGTERM=143, SIGINT=130, SIGHUP=129 — all from cancel-in-progress: true
  if [ "$exit_code" -ne 0 ] && [ "$exit_code" -lt 128 ] && [ -n "${REPO_OWNER:-}" ] && [ -n "${REPO_NAME:-}" ] && [ -n "${PR_NUMBER:-}" ]; then
    gh api --method POST \
      -H "Accept: application/vnd.github+json" \
      "/repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments" \
      -f "body=Diffhound review failed (exit code $exit_code). Check logs on the review VM." \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ============================================================
# HYBRID LARGE DIFF STRATEGY — Functions (v2)
# 4-tier router: SMALL (≤30KB) → MEDIUM (30-80KB) → LARGE (80-200KB) → HUGE (200KB+)
# ============================================================

# ── Diff Preprocessor: strip noise from diff before routing ──────────────────
# Strips lockfiles, generated code, source maps, snapshots, compiled output, binary diffs.
# For MEDIUM+ tiers (when $1 = "strip-deletions"), also strips deletion-only hunks.
# Pure bash/awk, zero LLM cost.
_preprocess_diff() {
  local raw_diff="$1"
  local output_file="$2"
  local strip_deletions="${3:-false}"

  # Patterns to always skip (lockfiles, generated, compiled, binary)
  local skip_patterns='(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|\.lock$|\.generated\.|\.min\.|\.bundle\.|\.map$|__snapshots__|dist/|build/|\.next/|\.jpg$|\.jpeg$|\.png$|\.gif$|\.svg$|\.ico$|\.woff|\.ttf$|\.eot$|\.pdf$)'

  # Also apply .diffhound.yml skip_files if present
  local extra_skip=""
  local config_file="${REPO_PATH}/.diffhound.yml"
  if [ -f "$config_file" ]; then
    extra_skip=$(grep -A100 'skip_files:' "$config_file" 2>/dev/null \
      | grep '^ *- ' | sed 's/^ *- //' | tr '\n' '|' | sed 's/|$//' || true)
  fi

  # Build combined pattern
  local full_pattern="$skip_patterns"
  [ -n "$extra_skip" ] && full_pattern="${skip_patterns}|($extra_skip)"

  # Phase 1: Strip entire file diffs that match skip patterns
  $_AWK_CMD -v pat="$full_pattern" '
    BEGIN { skip = 0 }
    /^diff --git/ {
      skip = 0
      if (match($0, pat)) { skip = 1; next }
    }
    skip { next }
    { print }
      END { if (pending && hold != "") {} }
  ' "$raw_diff" > "${output_file}.phase1"

  if [ "$strip_deletions" = "true" ]; then
    # Phase 2: Strip deletion-only hunks (Qodo technique)
    # A deletion-only hunk has - lines but no + lines (only deletions, no additions)
    $_AWK_CMD '
      /^@@/ {
        if (hunk != "" && has_add) printf "%s", hunk
        hunk = $0 "\n"; has_add = 0; next
      }
      /^diff --git/ {
        if (hunk != "" && has_add) printf "%s", hunk
        hunk = ""; has_add = 0; print; next
      }
      hunk != "" {
        hunk = hunk $0 "\n"
        if (/^\+[^+]/ || /^\+$/) has_add = 1
        next
      }
      { print }
      END { if (pending && hold != "") {} }
      END { if (hunk != "" && has_add) printf "%s", hunk }
    ' "${output_file}.phase1" > "$output_file"
    rm -f "${output_file}.phase1"
  else
    mv "${output_file}.phase1" "$output_file"
  fi
}

# ── Size Router: determine tier based on cleaned diff size ───────────────────
_route_tier() {
  local size_bytes="$1"
  if [ "$size_bytes" -le 30720 ]; then
    echo "SMALL"
  elif [ "$size_bytes" -le 81920 ]; then
    echo "MEDIUM"
  elif [ "$size_bytes" -le 204800 ]; then
    echo "LARGE"
  else
    echo "HUGE"
  fi
}

# ── Medium Tier Compression: reduce context lines + trim RAG ─────────────────
_compress_medium() {
  local diff_file="$1"
  local output_file="$2"
  # Reduce unchanged context lines from 3 to 1 per hunk.
  # IMPORTANT: only compress inside hunks — leave diff/file headers untouched.
  $_AWK_CMD '
    /^diff --git/ { in_hunk=0; print; next }
    /^@@/ { in_hunk=1; ctx=0; print; next }
    in_hunk && /^[+-]/ { ctx=0; print; next }
    in_hunk { ctx++; if (ctx <= 1) print; next }
    { print }
      END { if (pending && hold != "") {} }
  ' "$diff_file" > "$output_file"
}

# ── File Triage via Haiku (large/huge only) ──────────────────────────────────
# Extracts per-file stats, feeds to Haiku for priority classification.
# Output: filepath\tpriority\treason (TSV) written to $2
_triage_files() {
  local diff_file="$1"
  local output_file="$2"

  # Extract per-file stats: filename, additions, deletions, hunk count
  local file_stats
  file_stats=$($_AWK_CMD '
    /^diff --git/ {
      if (file != "") printf "%s\t%d\t%d\t%d\n", file, adds, dels, hunks
      file = ""; adds = 0; dels = 0; hunks = 0
      # Extract filename from diff --git line as fallback (handles deleted files)
      n = split($0, parts, " b/")
      if (n >= 2) { pending_file = parts[n]; sub(/"$/, "", pending_file) }
    }
    /^\+\+\+ b\// { file = substr($0, 7); sub(/"$/, "", file) }
    /^\+\+\+ \/dev\/null/ { file = pending_file }
    /^@@/ { hunks++ }
    /^\+[^+]/ { adds++ }
    /^-[^-]/ { dels++ }
    END { if (file != "") printf "%s\t%d\t%d\t%d\n", file, adds, dels, hunks }
  ' "$diff_file")

  # Extract first 10 lines of each file's diff for context
  local file_previews
  file_previews=$($_AWK_CMD '
    /^diff --git/ {
      count = 0; printing = 1
    }
    printing && count < 12 {
      print; count++
      if (count >= 12) { printing = 0; print "..." }
    }
  ' "$diff_file")

  # Build triage prompt
  local triage_prompt="Classify each file by review priority. Output ONLY TSV lines: filepath<TAB>priority<TAB>reason

Priority levels:
- CRITICAL: migrations, auth, payments, queue processors, API contracts, security
- STANDARD: normal business logic, services, resolvers, controllers
- LOW: tests, configs, type-only files, documentation, .env.example
- SKIP: auto-generated, purely deletion-only, lock files

File stats (file, +lines, -lines, hunks):
${file_stats}

First 10 lines of each file diff:
${file_previews}

Output format (TSV, one line per file, no headers, no explanation):
path/to/file.ts	CRITICAL	migration with schema change
path/to/test.ts	LOW	test file"

  local triage_result=""
  triage_result=$(printf '%s' "$triage_prompt" | _call_api "claude-haiku-4-5-20251001" 2048 30 || true)

  if [ -n "$triage_result" ]; then
    # Filter to only valid TSV lines with known priorities
    printf '%s\n' "$triage_result" | grep -E $'^[^[:space:]]+\t(CRITICAL|STANDARD|LOW|SKIP)\t' > "$output_file" || true
  fi

  # Fallback: if Haiku failed or returned nothing, use file extension heuristics
  if [ ! -s "$output_file" ]; then
    while IFS=$'\t' read -r file adds dels hunks; do
      [ -z "$file" ] && continue
      local priority="STANDARD"
      local reason="default"
      case "$file" in
        *migration*|*migrate*) priority="CRITICAL"; reason="migration" ;;
        *auth*|*login*|*session*|*permission*) priority="CRITICAL"; reason="auth-related" ;;
        *payment*|*billing*|*invoice*) priority="CRITICAL"; reason="payment-related" ;;
        *queue*|*processor*|*job*|*worker*) priority="CRITICAL"; reason="queue/job processor" ;;
        *.test.*|*.spec.*|*__tests__*) priority="LOW"; reason="test file" ;;
        *.config.*|*.env*|*tsconfig*) priority="LOW"; reason="config file" ;;
        *.d.ts) priority="LOW"; reason="type declarations only" ;;
        *.md|*.txt|*.yml|*.yaml) priority="LOW"; reason="documentation/config" ;;
      esac
      # Pure deletion files → SKIP
      if [ "$adds" -eq 0 ] && [ "$dels" -gt 0 ]; then
        priority="SKIP"; reason="deletion-only"
      fi
      printf '%s\t%s\t%s\n' "$file" "$priority" "$reason"
    done <<< "$file_stats" > "$output_file"
  fi
}

# ── PR Summary Header (large/huge only) ─────────────────────────────────────
# Haiku generates a compact structured summary. Every chunk receives this for cross-file awareness.
_build_pr_summary_header() {
  local diff_file="$1"
  local triage_file="$2"
  local pr_title="$3"
  local pr_body="$4"

  # Build file map from triage
  local file_map=""
  while IFS=$'\t' read -r file prio reason; do
    [ -z "$file" ] && continue
    file_map+="  ${prio}: ${file} (${reason})"$'\n'
  done < "$triage_file"

  local summary_prompt="Generate a concise PR summary header (max 2KB) for code reviewers.

PR Title: ${pr_title}
PR Description: ${pr_body:0:500}

File Classification:
${file_map}

Output this exact structure:
## PR CHANGE MAP
[2-3 sentence overview of what this PR does]

## FILE GROUPS
[group related files by feature/domain, 1 line per group]

## CROSS-FILE DEPENDENCIES
[which files call/import each other, based on names and paths]

## KEY PATTERNS TO WATCH
[what types of bugs are most likely given these file types]

## RISK AREAS
[highest risk files and why]

Be concise. This header is prepended to each review chunk for context."

  local summary_result
  summary_result=$(printf '%s' "$summary_prompt" | _call_api "claude-haiku-4-5-20251001" 2048 30 || true)

  if [ -n "$summary_result" ]; then
    printf '%s\n' "$summary_result"
  else
    # Fallback: minimal header from triage data
    printf '## PR CHANGE MAP\n%s\n\n## FILES\n%s\n' "$pr_title" "$file_map"
  fi
}

# ── Chunk Builder: bin-pack files into ≤30KB chunks ──────────────────────────
# Sorts by priority (CRITICAL first) then size (largest first).
# Outputs chunk files to $CHUNK_DIR/chunk-N.diff and chunk-N.manifest
_build_review_chunks() {
  local diff_file="$1"
  local triage_file="$2"
  local chunk_dir="$3"
  local max_chunk_bytes=51200  # 50KB — balance between cross-chunk blindness (too small) and attention drift (too large)

  mkdir -p "$chunk_dir"

  # Extract individual file diffs into temp files and measure sizes
  local file_diffs_dir="${chunk_dir}/file-diffs"
  mkdir -p "$file_diffs_dir"

  # Extract individual file diffs. Handle both quoted and unquoted paths.
  # Use +++ line (always present, unambiguous) to get the filename.
  $_AWK_CMD -v outdir="$file_diffs_dir" '
    /^diff --git/ {
      if (file != "") close(outdir "/" file)
      file = ""
      pending = $0 "\n"
      next
    }
    /^\+\+\+ / {
      # +++ b/path or +++ "b/path" or +++ /dev/null
      f = $0
      sub(/^\+\+\+ "?b\//, "", f)
      sub(/"$/, "", f)
      if (f == "/dev/null" || f == "") { file = ""; pending = ""; next }
      gsub(/\//, "_SLASH_", f)
      file = f
      if (pending != "") { printf "%s", pending > (outdir "/" file); pending = "" }
      print >> (outdir "/" file)
      next
    }
    pending != "" { pending = pending $0 "\n"; next }
    file != "" { print >> (outdir "/" file) }
    END { if (file != "") close(outdir "/" file) }
  ' "$diff_file"

  # Build sorted file list: priority order (CRITICAL=1, STANDARD=2, LOW=3), then by size desc
  local _sort_tmp="${chunk_dir}/sort-input.tmp"
  : > "$_sort_tmp"
  while IFS=$'\t' read -r file prio reason; do
    [ -z "$file" ] && continue
    # Safety: never fully skip files — demote SKIP to LOW so they still get reviewed
    # (in the last chunk, with minimal priority). Haiku can misclassify.
    [ "$prio" = "SKIP" ] && prio="LOW" && reason="demoted-from-skip: ${reason}"
    local safe_name="${file//\//_SLASH_}"
    local fsize=0
    [ -f "${file_diffs_dir}/${safe_name}" ] && fsize=$(wc -c < "${file_diffs_dir}/${safe_name}" | tr -d ' ')
    local sort_key=2
    if [ "$prio" = "CRITICAL" ]; then sort_key=1
    elif [ "$prio" = "STANDARD" ]; then sort_key=2
    elif [ "$prio" = "LOW" ]; then sort_key=3
    fi
    printf '%d\t%d\t%s\t%s\n' "$sort_key" "$fsize" "$file" "$prio" >> "$_sort_tmp"
  done < "$triage_file"
  local sorted_files
  sorted_files=$(sort -t$'\t' -k1,1n -k2,2rn "$_sort_tmp")
  rm -f "$_sort_tmp"

  # Bin-pack into chunks
  local chunk_num=0
  local current_size=0

  # Start first chunk
  : > "${chunk_dir}/chunk-${chunk_num}.diff"
  : > "${chunk_dir}/chunk-${chunk_num}.manifest"

  while IFS=$'\t' read -r sort_key fsize file prio; do
    [ -z "$file" ] && continue
    local safe_name="${file//\//_SLASH_}"
    local file_diff="${file_diffs_dir}/${safe_name}"
    [ ! -f "$file_diff" ] && continue

    # If adding this file exceeds chunk limit, start new chunk
    if [ "$current_size" -gt 0 ] && [ $((current_size + fsize)) -gt "$max_chunk_bytes" ]; then
      chunk_num=$((chunk_num + 1))
      current_size=0
      : > "${chunk_dir}/chunk-${chunk_num}.diff"
      : > "${chunk_dir}/chunk-${chunk_num}.manifest"
    fi

    cat "$file_diff" >> "${chunk_dir}/chunk-${chunk_num}.diff"
    printf '%s\t%s\n' "$file" "$prio" >> "${chunk_dir}/chunk-${chunk_num}.manifest"
    current_size=$((current_size + fsize))
  done <<< "$sorted_files"

  # Cleanup file diffs
  rm -rf "$file_diffs_dir"

  # Return chunk count (0-indexed, so add 1)
  echo $((chunk_num + 1))
}

# ── PR-wide file manifest for cross-chunk awareness ─────────────────────────
# Extracts key definitions (classes, functions, exports) from each file's diff
# so chunk reviewers know what exists in OTHER chunks without tool calls.
_build_pr_manifest() {
  local diff_file="$1"
  local triage_file="$2"
  local output_file="$3"

  {
    echo "## ALL FILES IN THIS PR (your chunk is a subset)"
    echo "Use this manifest to avoid false positives about missing code."
    echo "If something is listed here, it EXISTS — do NOT flag it as missing."
    echo ""
    # List every file with its priority
    while IFS=$'\t' read -r file prio reason; do
      [ -z "$file" ] && continue
      echo "### ${file} [${prio}]"
      # Extract key definitions from this file's diff (+ lines only)
      $_AWK_CMD -v target="$file" '
        /^diff --git/ { in_file = (index($0, "b/" target) > 0) }
        in_file && /^\+/ {
          line = substr($0, 2)
          # Python: class/def/async def
          if (line ~ /^[[:space:]]*(class |def |async def )[A-Za-z_]/) { print "  - " line }
          # TypeScript/JS: export, function, class, interface, enum, const
          else if (line ~ /^[[:space:]]*(export |function |class |interface |enum |const |type )[A-Za-z_]/) { print "  - " line }
          # Config: key assignments (settings, env vars)
          else if (line ~ /^[[:space:]]*[A-Za-z_]+[[:space:]]*[:=].*/) {
            # Only capture top-level config-like assignments (not deep nesting)
            if (line ~ /^[[:space:]]{0,4}[A-Za-z_]/) { print "  - " line }
          }
        }
      ' "$diff_file" | head -15
      echo ""
    done < "$triage_file"
  } > "$output_file"

  # Cap manifest at 8KB to prevent prompt bloat
  local _msize
  _msize=$(wc -c < "$output_file" | tr -d ' ')
  if [ "$_msize" -gt 8192 ]; then
    head -c 8192 "$output_file" > "${output_file}.tmp"
    echo "" >> "${output_file}.tmp"
    echo "[manifest truncated — use Read/Bash tools to verify anything not listed]" >> "${output_file}.tmp"
    mv "${output_file}.tmp" "$output_file"
  fi
}

# ── Parallel Chunk Review ────────────────────────────────────────────────────
# Launches API calls for each chunk in parallel. Collects results.
_review_chunks_parallel() {
  local chunk_dir="$1"
  local chunk_count="$2"
  local pr_summary_header="$3"
  local rag_context_file="$4"
  local repo_path="$5"
  local pr_manifest="${6:-}"
  local is_rereview="${7:-false}"
  local threads_file="${8:-}"
  local incr_files="${9:-}"

  local chunked_prompt_file="${LIB_DIR}/prompt-chunked.txt"
  local pids=()

  for ((i=0; i<chunk_count; i++)); do
    local chunk_diff="${chunk_dir}/chunk-${i}.diff"
    local chunk_manifest="${chunk_dir}/chunk-${i}.manifest"
    local chunk_out="${chunk_dir}/chunk-${i}.out"
    local chunk_prompt="${chunk_dir}/chunk-${i}.prompt"

    [ ! -s "$chunk_diff" ] && continue

    # Get file list for this chunk
    local file_list
    file_list=$(cut -f1 "$chunk_manifest" | tr '\n' ', ')

    # Filter RAG to relevant files
    local chunk_rag="${chunk_dir}/chunk-${i}.rag"
    if [ -s "$rag_context_file" ]; then
      _filter_rag_for_files "$rag_context_file" "$chunk_manifest" "$chunk_rag"
      # Trim to 15KB per chunk
      _trim_rag "$chunk_rag" 15360
    else
      : > "$chunk_rag"
    fi

    # Build chunk prompt
    {
      cat "$chunked_prompt_file"
      echo ""
      echo "---"
      echo ""
      # Inject PR-wide manifest so this chunk knows what exists in other chunks
      if [ -n "$pr_manifest" ] && [ -s "$pr_manifest" ]; then
        echo "# CROSS-CHUNK AWARENESS (READ THIS FIRST)"
        echo ""
        cat "$pr_manifest"
        echo ""
        echo "---"
        echo ""
      fi
      # Inject re-review context with CONTEXTUAL BLINDERS approach:
      # - Full diff visibility (already provided as chunk diff)
      # - Scoped instructions: what to complain about depends on file type + change status
      if [ "$is_rereview" = true ]; then
        # Filter threads to only this chunk's files
        local _chunk_threads="${chunk_dir}/chunk-${i}.threads"
        if [ -n "$threads_file" ] && [ -s "$threads_file" ]; then
          local _chunk_files_pattern=""
          while IFS=$'\t' read -r _cf _cp; do
            [ -n "$_chunk_files_pattern" ] && _chunk_files_pattern+="|"
            _chunk_files_pattern+="$_cf"
          done < "$chunk_manifest"
          if [ -n "$_chunk_files_pattern" ]; then
            grep -E "$_chunk_files_pattern" "$threads_file" > "$_chunk_threads" 2>/dev/null || true
          else
            : > "$_chunk_threads"
          fi
        else
          : > "$_chunk_threads"
        fi

        # Determine which files in this chunk were changed incrementally
        local _chunk_incr_files="${chunk_dir}/chunk-${i}.incr-files"
        local _chunk_has_security_files=false
        : > "$_chunk_incr_files"
        if [ -n "$incr_files" ] && [ -s "$incr_files" ]; then
          while IFS=$'\t' read -r _cf _cp; do
            if grep -qF "$_cf" "$incr_files" 2>/dev/null; then
              echo "$_cf" >> "$_chunk_incr_files"
            fi
            # Check for security-sensitive files
            case "$_cf" in
              *auth*|*permission*|*rbac*|*acl*|*security*|*secret*|*token*|*session*|*middleware/auth*|*guard*|*policy*|*migration*|*\.env*) _chunk_has_security_files=true ;;
            esac
          done < "$chunk_manifest"
        fi

        echo "# RE-REVIEW MODE — CONTEXTUAL BLINDERS"
        echo ""
        echo "This is a RE-REVIEW. You see the FULL diff for context, but your feedback is SCOPED."
        echo ""
        echo "## TASK 1: Verify existing threads (highest priority)"
        if [ -s "$_chunk_threads" ]; then
          echo "Check each thread below — is the concern now FIXED in the current code?"
          echo ""
          cat "$_chunk_threads"
        else
          echo "(No existing threads for your files)"
        fi
        echo ""
        echo "## TASK 2: Scan for regressions and new critical issues"
        if [ -s "$_chunk_incr_files" ]; then
          echo "Files changed since last review (FULL SCRUTINY on these):"
          sed 's/^/  - /' "$_chunk_incr_files"
          echo ""
          echo "Files NOT changed since last review (LIMITED SCRUTINY — security/data-corruption only):"
          while IFS=$'\t' read -r _cf _cp; do
            if ! grep -qF "$_cf" "$_chunk_incr_files" 2>/dev/null; then
              echo "  - $_cf (unchanged — only flag security/data-corruption)"
            fi
          done < "$chunk_manifest"
        else
          echo "All files in this chunk should receive FULL scrutiny (no incremental info available)."
        fi
        echo ""
        if [ "$_chunk_has_security_files" = true ]; then
          echo "## ⚠ SECURITY-SENSITIVE FILES DETECTED"
          echo "Files matching auth/permissions/migrations/secrets patterns found in this chunk."
          echo "These files ALWAYS get FULL scrutiny regardless of change status."
          echo "Check: auth bypass, privilege escalation, missing guards, removed checks."
          echo ""
        fi
        echo "## SCOPING RULES:"
        echo "- Changed files: flag ANY real issue (blocking, should-fix, security)"
        echo "- Unchanged files: ONLY flag security vulnerabilities or data corruption"
        echo "- Security-sensitive files (auth, permissions, migrations): ALWAYS full scrutiny"
        echo "- Do NOT re-flag issues already in the threads above (unless still broken)"
        echo "- Do NOT nitpick style, naming, or formatting on ANY file"
        echo "- If the first review missed a real bug and you see it now: FLAG IT (with note: missed in round 1)"
        echo ""
        echo "---"
        echo ""
      fi
      # Inject Jira context if available (PR-wide, not per-chunk)
      if [ -n "${JIRA_CONTEXT:-}" ]; then
        echo "$JIRA_CONTEXT"
        echo ""
        echo "---"
        echo ""
      fi
      echo "# PR SUMMARY (applies to entire PR — your chunk is a subset)"
      echo "$pr_summary_header"
      echo ""
      echo "---"
      echo ""
      echo "# YOUR CHUNK: files [${file_list}]"
      echo ""
      # Inject per-chunk lint findings
      if [ -n "${LINT_CONTEXT:-}" ]; then
        # Filter lint to only this chunk's files
        local _chunk_lint=""
        while IFS=$'\t' read -r _cf _cp; do
          [ -z "$_cf" ] && continue
          local _file_lint
          _file_lint=$(echo "$LINT_CONTEXT" | awk -v f="### ${_cf}" '
            $0 == f { found=1; print; next }
            found && /^### / { found=0; next }
            found { print }
      END { if (pending && hold != "") {} }
          ')
          [ -n "$_file_lint" ] && _chunk_lint+="${_file_lint}"$'\n'
        done < "$chunk_manifest"
        if [ -n "$_chunk_lint" ]; then
          echo "## STATIC ANALYSIS FINDINGS (pre-computed — do NOT re-flag these)"
          echo "Do NOT include these as findings — they are already reported separately."
          echo ""
          echo "$_chunk_lint"
          echo ""
          echo "---"
          echo ""
        fi
      fi
      echo "# DIFF (this chunk only)"
      echo ""
      if [ -n "${_FRAMEWORK_FACTS:-}" ]; then
        echo "# FRAMEWORK GROUND TRUTH (verified from repo dependencies)"
        printf '%b\n' "$_FRAMEWORK_FACTS"
        echo "Do NOT contradict these facts. If uncertain, mark finding as UNVERIFIABLE."
        echo ""
      fi
      if [ -n "${_ARCH_CHECKLIST:-}" ]; then
        echo "# ARCHITECTURAL CHECKLIST (check in addition to line-level review)"
        echo "$_ARCH_CHECKLIST"
        echo ""
      fi
      cat "$chunk_diff"
      if [ -s "$chunk_rag" ]; then
        echo ""
        echo "---"
        echo ""
        echo "# CODEBASE CONTEXT (RAG — filtered for this chunk's files)"
        echo ""
        cat "$chunk_rag"
      fi
    } > "$chunk_prompt"

    # Launch API call in background (Opus 4.6 for thorough code review)
    (
      _call_api "claude-opus-4-6" 16384 480 < "$chunk_prompt" > "$chunk_out" 2>&1 || \
        echo "CHUNK_${i}_FAILED" > "$chunk_out"
    ) &
    pids+=($!)
  done

  # Wait for all chunks
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

}

# ── Findings Merger: combine chunk outputs into single review ────────────────
_merge_chunk_findings() {
  local chunk_dir="$1"
  local chunk_count="$2"
  local output_file="$3"

  # If only 1 chunk, pass through
  if [ "$chunk_count" -eq 1 ] && [ -s "${chunk_dir}/chunk-0.out" ]; then
    cp "${chunk_dir}/chunk-0.out" "$output_file"
    return
  fi

  # Collect all chunk outputs
  local all_findings=""
  for ((i=0; i<chunk_count; i++)); do
    local chunk_out="${chunk_dir}/chunk-${i}.out"
    [ ! -s "$chunk_out" ] && continue
    all_findings+="
## CHUNK $((i+1)) FINDINGS (files: $(cut -f1 "${chunk_dir}/chunk-${i}.manifest" 2>/dev/null | tr '\n' ', '))
$(cat "$chunk_out")
"
  done

  # Merge via Haiku
  local merge_prompt="Merge these code review findings from separate chunks into a single unified review.

${all_findings}

YOUR TASK:
1. Deduplicate: if two chunks flag the same issue, keep the most detailed version. NEVER drop a finding — if in doubt, keep it.
2. Link cross-file findings: if chunk A mentions a function and chunk B reviews its caller, create a COMBINED finding that references both files with the full evidence chain.
3. Resolve CROSS_FILE_NOTES (CRITICAL — this is where chunking can miss bugs):
   - For each CROSS_FILE_NOTE: search ALL other chunks for the referenced function/type/enum
   - If chunk A says 'calls X in another file' and chunk B mentions X → link them into one finding
   - If a cross-file concern is NOT answered by any other chunk → ELEVATE it as a finding with UNVERIFIABLE: yes
   - Do NOT silently discard unresolved cross-file notes — they represent potential bugs the chunking missed
4. Produce a single FINDINGS_START...FINDINGS_END block with all unique findings
5. Produce a single SCORECARD_START...SCORECARD_END with overall scores
6. Include a CROSS_FILE_RESOLUTION section showing how each cross-file note was resolved (or marked unverifiable)

Use the same output format as the individual chunks but with a unified scorecard:

### FINDINGS_START
FINDING: file/path.ts:LINE:SEVERITY
WHAT: ...
EVIDENCE: ...
IMPACT: ...
OPTIONS: ...
UNVERIFIABLE: ...
### FINDINGS_END

### SCORECARD_START
Security: X/25 — [reason]
Tests: X/20 — [reason]
Observability: X/10 — [reason]
Performance: X/15 — [reason]
Readability: X/15 — [reason]
Compatibility: X/15 — [reason]
Total: X/100 — REQUEST_CHANGES|APPROVE|COMMENT

Blocking: [file:line list or NONE]
ShouldFix: [file:line list or NONE]
Nits: [file:line list or NONE]
Checklist: [verification steps]
### SCORECARD_END"

  local merge_result=""
  merge_result=$(printf '%s' "$merge_prompt" | _call_api "claude-haiku-4-5-20251001" 4096 60 || true)

  if [ -n "$merge_result" ]; then
    printf '%s\n' "$merge_result" > "$output_file"
  else
    # Fallback: concatenate all chunk outputs
    for ((i=0; i<chunk_count; i++)); do
      [ -s "${chunk_dir}/chunk-${i}.out" ] && cat "${chunk_dir}/chunk-${i}.out"
    done > "$output_file"
  fi
}

# ============================================================
# STEP 0.5: FETCH EXISTING COMMENTS & DETECT RE-REVIEW MODE
# (must run BEFORE diff fetch so we know whether to get incremental diff)
# ============================================================
spinner_start "Fetching existing review comments..."

EXISTING_COMMENTS_FILE=$(mktemp -t "pr-${PR_NUMBER}-existing.XXXXXX")
IS_REREVIEW=false
LAST_REVIEWED_SHA=""

# Fetch all inline comments (with thread structure)
gh api "/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/comments" \
  --jq '[.[] | {id, path, line, body, user: .user.login, in_reply_to_id, created_at}]' \
  > "$EXISTING_COMMENTS_FILE" 2>/dev/null || echo "[]" > "$EXISTING_COMMENTS_FILE"

# Fetch review-level comments (summary bodies + commit_id for incremental diff)
EXISTING_REVIEWS_FILE=$(mktemp -t "pr-${PR_NUMBER}-reviews.XXXXXX")
gh api "/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/reviews" \
  --jq '[.[] | {id, state, body, user: .user.login, submitted_at, commit_id}]' \
  > "$EXISTING_REVIEWS_FILE" 2>/dev/null || echo "[]" > "$EXISTING_REVIEWS_FILE"

# Reconstruct prior FINDING: blocks from our existing inline PR comments.
# round-diff.py uses these as the "previous round" baseline to compute
# new/resolved/unchanged accounting (DIFFHOUND_PRIOR_FINDINGS env var).
# We do this unconditionally — on first reviews there are no prior comments
# so the file is empty and round-diff shows "+N new, -0 resolved".
PRIOR_FINDINGS_FILE=$(mktemp -t "pr-${PR_NUMBER}-prior-findings.XXXXXX")
jq -r --arg login "$REVIEWER_LOGIN" '
  [.[] | select(.in_reply_to_id == null and .user == $login and .path != null and .line != null)]
  | .[]
  | . as $c
  | ($c.body | capture("\\*\\*(?<sev>BLOCKING|SHOULD-FIX|NIT)\\*\\*") // {sev:"SHOULD-FIX"}) as $sv
  | ($c.body | gsub("\\*\\*(?:BLOCKING|SHOULD-FIX|NIT)\\*\\*\\s*[^a-zA-Z`]*"; "")
             | split(". ")[0] | ltrimstr(" ") | rtrimstr(" ")) as $what
  | "FINDING: \($c.path):\($c.line):\($sv.sev)\nWHAT: \($what)\n"
' "$EXISTING_COMMENTS_FILE" 2>/dev/null > "$PRIOR_FINDINGS_FILE" || true

# Check if reviewer has already posted comments → re-review mode
REVIEWER_COMMENT_COUNT=$(jq --arg login "$REVIEWER_LOGIN" \
  '[.[] | select(.user == $login)] | length' "$EXISTING_COMMENTS_FILE" 2>/dev/null || echo "0")

if [ "$REVIEWER_COMMENT_COUNT" -gt 0 ]; then
  IS_REREVIEW=true

  # Extract the commit SHA from our last review submission
  LAST_REVIEWED_SHA=$(jq -r --arg login "$REVIEWER_LOGIN" \
    '[.[] | select(.user == $login and .body != "")] | sort_by(.submitted_at) | last | .commit_id // empty' \
    "$EXISTING_REVIEWS_FILE" 2>/dev/null || echo "")

  # Extract previous scorecard as structured JSON for script-owned score merging
  # Format: {"security":{"score":20,"max":25},"tests":{"score":15,"max":20},...}
  PREV_SCORECARD_JSON=""
  _last_review_body=$(jq -r --arg login "$REVIEWER_LOGIN" \
    '[.[] | select(.user == $login and .body != "")] | sort_by(.submitted_at) | last | .body // empty' \
    "$EXISTING_REVIEWS_FILE" 2>/dev/null || echo "")

  if [ -n "$_last_review_body" ]; then
    # Try to extract scorecard from JSON block in review body (hidden comment format)
    _prev_json=$(echo "$_last_review_body" | sed -n '/^<!-- SCORECARD_JSON/,/^SCORECARD_JSON -->/p' 2>/dev/null | grep -v 'SCORECARD_JSON' || true)
    if [ -n "$_prev_json" ] && echo "$_prev_json" | jq -e '.' >/dev/null 2>&1; then
      PREV_SCORECARD_JSON="$_prev_json"
    else
      # Fallback: parse scorecard from markdown table rows
      # Extract rows like: | SECURITY (25%) | 20/25 | reason |
      _parsed=$(echo "$_last_review_body" | awk '
        /^\|[^|]+\|[[:space:]]*\*?\*?[0-9]+\/[0-9]+/ && !/[Tt]otal/ {
          split($0, cols, "|")
          # col 2 = category, col 3 = score/max
          cat = cols[2]; gsub(/^[ \t]+|[ \t]+$/, "", cat)
          score_str = cols[3]; gsub(/^[ \t*]+|[ \t*]+$/, "", score_str); gsub(/\*/, "", score_str)
          n = split(score_str, parts, "/")
          if (n == 2 && parts[1]+0 == parts[1] && parts[2]+0 == parts[2]) {
            # Normalize category name to lowercase key
            key = tolower(cat)
            gsub(/[^a-z].*/, "", key)  # "SECURITY (25%)" -> "security"
            if (key != "") {
              printf "%s\t%s\t%s\n", key, parts[1], parts[2]
            }
          }
        }
      ' 2>/dev/null || true)
      if [ -n "$_parsed" ]; then
        # Build JSON object from parsed TSV
        PREV_SCORECARD_JSON=$(echo "$_parsed" | awk -F'\t' '
          BEGIN { printf "{" }
          NR > 1 { printf "," }
          { printf "\"%s\":{\"score\":%s,\"max\":%s}", $1, $2, $3 }
          END { printf "}" }
        ')
        # Validate
        if ! echo "$PREV_SCORECARD_JSON" | jq -e '.' >/dev/null 2>&1; then
          PREV_SCORECARD_JSON=""
        fi
      fi
    fi
  fi

  if [ -n "$LAST_REVIEWED_SHA" ]; then
    spinner_stop "Re-review mode — ${REVIEWER_COMMENT_COUNT} comments, last reviewed at ${LAST_REVIEWED_SHA:0:8}"
  else
    spinner_stop "Re-review mode — ${REVIEWER_COMMENT_COUNT} existing comments found"
  fi
  echo "  ↻ Checking which previous comments are addressed..."
else
  spinner_stop "Fresh review — no prior comments from reviewer"
fi

# Build human-readable thread context for the prompt
THREADS_SUMMARY_FILE=$(mktemp -t "pr-${PR_NUMBER}-threads.XXXXXX")

jq -r --arg login "$REVIEWER_LOGIN" '
  # ONLY include threads started by the reviewer (Diffhound), not other humans or bots.
  # This prevents external comments from suppressing the reviewer own findings.
  . as $all |
  [ .[] | select(.in_reply_to_id == null and .user == $login) ] |
  .[] |
  . as $top |
  "THREAD at \(.path):\(.line // "general")\n" +
  "  REVIEWER: \(.body)\n" +
  ([$all[] | select(.in_reply_to_id == $top.id)] |
    if length > 0 then
      .[] | "  AUTHOR_REPLY (\(.user)): \(.body)\n"
    else ""
    end
  )
' "$EXISTING_COMMENTS_FILE" > "$THREADS_SUMMARY_FILE" 2>/dev/null || echo "" > "$THREADS_SUMMARY_FILE"

# ============================================================
# STEP 0.6: FETCH DIFF (full + incremental for re-reviews)
# ============================================================

# Edge case: no new commits since last review — skip entirely (unless --force-full)
if [ "$IS_REREVIEW" = true ] && [ -n "$LAST_REVIEWED_SHA" ] && [ "$LAST_REVIEWED_SHA" = "$HEAD_SHA" ] && [ "$FORCE_FULL" != true ]; then
  echo ""
  echo "  ✅ No new commits since last review (${LAST_REVIEWED_SHA:0:8}). Nothing to re-review."
  echo "  → https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PR_NUMBER}"
  exit 0
fi

spinner_start "Fetching diff..."
if ! $_TIMEOUT_CMD 300 gh pr diff "$PR_NUMBER" > "$DIFF_FILE" 2>&1; then
  spinner_fail "Failed to fetch diff"
  exit 1
fi
_filter_diff_by_config "$DIFF_FILE"
DIFF_SIZE=$(wc -c < "$DIFF_FILE")
if [ "$DIFF_SIZE" -gt 150000 ]; then
  spinner_stop "Diff fetched (large: ${DIFF_SIZE} bytes — focused review)"
else
  spinner_stop "Diff fetched ($(( DIFF_SIZE / 1024 ))KB)"
fi

# For re-reviews: fetch incremental diff (only changes since last review)
INCREMENTAL_DIFF_FILE=""
INCREMENTAL_FILES_LIST=""
if [ "$IS_REREVIEW" = true ] && [ -n "$LAST_REVIEWED_SHA" ]; then
  INCREMENTAL_DIFF_FILE=$(mktemp -t "pr-${PR_NUMBER}-incremental.XXXXXX")
  INCREMENTAL_FILES_LIST=$(mktemp -t "pr-${PR_NUMBER}-incr-files.XXXXXX")

  # Get list of files changed between last reviewed commit and current HEAD
  gh api "/repos/${REPO_OWNER}/${REPO_NAME}/compare/${LAST_REVIEWED_SHA}...${HEAD_SHA}" \
    --jq '.files[].filename' > "$INCREMENTAL_FILES_LIST" 2>/dev/null || true

  # Get actual diff — try local git first, fall back to GitHub compare API
  if git -C "$REPO_PATH" cat-file -e "$LAST_REVIEWED_SHA" 2>/dev/null; then
    git -C "$REPO_PATH" diff "${LAST_REVIEWED_SHA}...${HEAD_SHA}" > "$INCREMENTAL_DIFF_FILE" 2>/dev/null || true
  fi

  # Fallback: if local git diff failed or SHA not in repo, use GitHub API
  INCR_SIZE=$(wc -c < "$INCREMENTAL_DIFF_FILE" 2>/dev/null | tr -d ' ' || echo "0")
  if [ "$INCR_SIZE" -eq 0 ]; then
    gh api "/repos/${REPO_OWNER}/${REPO_NAME}/compare/${LAST_REVIEWED_SHA}...${HEAD_SHA}" \
      -H "Accept: application/vnd.github.v3.diff" > "$INCREMENTAL_DIFF_FILE" 2>/dev/null || true
    INCR_SIZE=$(wc -c < "$INCREMENTAL_DIFF_FILE" 2>/dev/null | tr -d ' ' || echo "0")
  fi

  CHANGED_FILES=$(wc -l < "$INCREMENTAL_FILES_LIST" 2>/dev/null | tr -d ' ' || echo "0")

  DIFF_SIZE_BYTES=$(wc -c < "$DIFF_FILE" 2>/dev/null | tr -d ' ' || echo "0")

  if [ "$INCR_SIZE" -gt 0 ] && [ "$CHANGED_FILES" -gt 0 ]; then
    # Safety: if incremental diff is LARGER than the PR diff, it means master was
    # merged into the branch — the SHA range includes unrelated commits. Fall back
    # to the PR diff to avoid blowing up the prompt.
    if [ "$INCR_SIZE" -gt "$DIFF_SIZE_BYTES" ]; then
      echo "  ↻ Incremental diff (${INCR_SIZE}B) > PR diff (${DIFF_SIZE_BYTES}B) — master merge detected"
      echo "  ↻ Using PR diff instead (more focused)"
      INCREMENTAL_DIFF_FILE=""
      INCREMENTAL_FILES_LIST=""
    else
      FULL_DIFF_FILES=$(grep -c '^diff --git' "$DIFF_FILE" || echo "0")
      UNCHANGED_FILES=$((FULL_DIFF_FILES - CHANGED_FILES))
      [ "$UNCHANGED_FILES" -lt 0 ] && UNCHANGED_FILES=0
      echo "  ↻ Re-review: ${CHANGED_FILES} files changed since last review (${INCR_SIZE} bytes)"
      echo "  ↻ Skipping ${UNCHANGED_FILES} unchanged files (already reviewed)"
    fi
  else
    # Incremental diff failed or empty — fall back to full review
    echo "  ↻ Could not compute incremental diff — using full diff"
    INCREMENTAL_DIFF_FILE=""
    INCREMENTAL_FILES_LIST=""
  fi
fi

# Determine re-review depth based on delta size (addresses bait-and-switch scenario)
# REREVIEW_DEPTH: "shallow" = skip peer review, "full" = run peer review with re-review prompt
REREVIEW_DEPTH="shallow"
if [ "$IS_REREVIEW" = true ]; then
  _INCR_BYTES=${INCR_SIZE:-0}
  _INCR_LINES=$(wc -l < "${INCREMENTAL_DIFF_FILE:-/dev/null}" 2>/dev/null | tr -d ' ' || echo "0")
  # Large delta (>=10KB or >=200 lines) = full review depth — substantial changes deserve scrutiny
  if [ "$_INCR_BYTES" -ge 10240 ] || [ "$_INCR_LINES" -ge 200 ]; then
    REREVIEW_DEPTH="full"
    echo "  ↻ Large re-review delta (${_INCR_BYTES}B, ${_INCR_LINES} lines) — running full peer review" >&2
  else
    echo "  ↻ Small re-review delta (${_INCR_BYTES}B, ${_INCR_LINES} lines) — skipping peer review" >&2
  fi
fi
# --force-full overrides all re-review depth decisions
if [ "$FORCE_FULL" = true ]; then
  REREVIEW_DEPTH="full"
  echo "  --force-full: overriding re-review depth to full" >&2
fi

# ============================================================
# STEP 1: RAG CONTEXT ENRICHMENT
# ============================================================
spinner_start "Retrieving codebase context (RAG)..."
RAG_CONTEXT_FILE=$(mktemp -t "pr-${PR_NUMBER}-rag.XXXXXX")

# RAG script: use bundled lib/rag.sh or override via REVIEW_RAG_SCRIPT
_RAG_SCRIPT="${REVIEW_RAG_SCRIPT:-${LIB_DIR}/rag.sh}"

# Cache key: repo + PR + HEAD SHA (auto-invalidates on new commits)
_RAG_CACHE_KEY="${REPO_NAME}-${PR_NUMBER}-${HEAD_SHA:0:8}"
_RAG_CACHE_FILE="$REVIEW_CACHE_DIR/rag-${_RAG_CACHE_KEY}.txt"

# Purge RAG cache entries older than 7 days
find "$REVIEW_CACHE_DIR" -name "rag-*.txt" -mtime +7 -delete 2>/dev/null || true

if [ -f "$_RAG_CACHE_FILE" ]; then
  cp "$_RAG_CACHE_FILE" "$RAG_CONTEXT_FILE"
  RAG_SIZE=$(wc -c < "$RAG_CONTEXT_FILE" | tr -d ' ')
  spinner_stop "RAG context loaded from cache ($(( RAG_SIZE / 1024 ))KB)"
elif [ -f "$_RAG_SCRIPT" ] && $_TIMEOUT_CMD 60 bash "$_RAG_SCRIPT" \
    "$DIFF_FILE" "$REPO_PATH" "$PR_NUMBER" "$REVIEWER_LOGIN" \
    > "$RAG_CONTEXT_FILE" 2>/dev/null; then
  RAG_SIZE=$(wc -c < "$RAG_CONTEXT_FILE" | tr -d ' ')
  cp "$RAG_CONTEXT_FILE" "$_RAG_CACHE_FILE" 2>/dev/null || true
  spinner_stop "RAG context ready ($(( RAG_SIZE / 1024 ))KB) — cached"
else
  spinner_stop "RAG context unavailable — proceeding with diff only"
  echo "" > "$RAG_CONTEXT_FILE"
fi

# ============================================================
# STEP 1.3: STATIC ANALYZER PRE-PASS (lint findings for prompt)
# ============================================================
LINT_CONTEXT=""
if [ "${_LINT_SOURCED:-}" = true ]; then
  spinner_start "Running static analysis..."
  LINT_CONTEXT=$(_run_static_analysis "$DIFF_FILE" "$REPO_PATH" 2>/dev/null || true)
  if [ -n "$LINT_CONTEXT" ]; then
    LINT_SIZE=${#LINT_CONTEXT}
    spinner_stop "Static analysis done (${LINT_SIZE}B)"
  else
    spinner_stop "No lint findings (or linters not installed)"
  fi
fi

# ============================================================
# STEP 1.5: PREPROCESS DIFF + ROUTE BY SIZE TIER
# ============================================================
CLEANED_DIFF=$(mktemp -t "pr-${PR_NUMBER}-cleaned.XXXXXX")

# Preprocess: strip lockfiles, generated code, binaries, source maps.
# NOTE: We do NOT strip deletion-only hunks — deleted guards/checks must be reviewed.
_preprocess_diff "$DIFF_FILE" "$CLEANED_DIFF" "false"
CLEANED_SIZE=$(wc -c < "$CLEANED_DIFF" | tr -d ' ')
REVIEW_TIER=$(_route_tier "$CLEANED_SIZE")

# Override: --force-monolithic flag bypasses tier routing (escape hatch)
if [ "$FORCE_MONOLITHIC" = true ]; then
  REVIEW_TIER="SMALL"
fi

RAW_DIFF_SIZE=$(wc -c < "$DIFF_FILE" | tr -d ' ')
echo "  📏 Diff: ${RAW_DIFF_SIZE}B raw → ${CLEANED_SIZE}B cleaned → tier: ${REVIEW_TIER}"

# ============================================================
# TIER ROUTING: SMALL uses existing monolithic path, others diverge
# ============================================================

if [ "$REVIEW_TIER" = "LARGE" ] || [ "$REVIEW_TIER" = "HUGE" ]; then
  # ── LARGE/HUGE: Triage → Summary → Chunk → Parallel Review → Merge ──
  spinner_start "Triaging files for chunked review..."
  TRIAGE_FILE=$(mktemp -t "pr-${PR_NUMBER}-triage.XXXXXX")
  _triage_files "$CLEANED_DIFF" "$TRIAGE_FILE"
  TRIAGE_COUNT=$(wc -l < "$TRIAGE_FILE" | tr -d ' ')
  CRITICAL_COUNT=$(grep -c $'\tCRITICAL\t' "$TRIAGE_FILE" || true)
  SKIP_COUNT=$(grep -c $'\tSKIP\t' "$TRIAGE_FILE" || true)
  spinner_stop "Triage complete: ${TRIAGE_COUNT} files (${CRITICAL_COUNT} critical, ${SKIP_COUNT} skipped)"

  # Safety: SKIP files are demoted to LOW (still reviewed). Log them for visibility.
  if [ "$SKIP_COUNT" -gt 0 ]; then
    echo "  ℹ️  Low-priority files (triage suggested skip, demoted to LOW — still reviewed):"
    grep $'\tSKIP\t' "$TRIAGE_FILE" | while IFS=$'\t' read -r _f _p _r; do
      echo "     ↳ $_f ($_r)"
    done
  fi

  spinner_start "Building PR summary header..."
  PR_SUMMARY_HEADER_FILE=$(mktemp -t "pr-${PR_NUMBER}-summary-hdr.XXXXXX")
  PR_SUMMARY_HEADER=$(_build_pr_summary_header "$CLEANED_DIFF" "$TRIAGE_FILE" "$PR_TITLE" "$PR_BODY")
  printf '%s\n' "$PR_SUMMARY_HEADER" > "$PR_SUMMARY_HEADER_FILE"
  spinner_stop "PR summary header ready"


# -- Framework ground truth: extract facts from repo dependencies --
_FRAMEWORK_FACTS=""
if [ -d "$REPO_PATH" ]; then
  _REQ_FILES=$(find "$REPO_PATH" -maxdepth 2 -name 'requirements*.txt' -o -name 'pyproject.toml' -o -name 'package.json' 2>/dev/null | head -5)
  _ALL_DEPS=$(cat "$_REQ_FILES" 2>/dev/null || true)
  if echo "$_ALL_DEPS" | grep -qi 'sqlalchemy'; then
    _FRAMEWORK_FACTS="${_FRAMEWORK_FACTS}- SQLAlchemy: create_engine() is LAZY -- does NOT connect at import time. Only connects on first query.\n"
  fi
  if echo "$_ALL_DEPS" | grep -qi 'httpx'; then
    _FRAMEWORK_FACTS="${_FRAMEWORK_FACTS}- httpx: AsyncClient must be explicitly closed or used with async with. NOT auto-closed.\n"
  fi
  if echo "$_ALL_DEPS" | grep -qi 'nest.asyncio\|nest_asyncio'; then
    _FRAMEWORK_FACTS="${_FRAMEWORK_FACTS}- nest_asyncio: when applied, run_until_complete() works inside already-running loops.\n"
  fi
  if echo "$_ALL_DEPS" | grep -qi 'pgvector\|sqlmodel'; then
    _FRAMEWORK_FACTS="${_FRAMEWORK_FACTS}- pgvector: Vector columns need HNSW or IVFFLAT indexes for production query performance.\n"
  fi
fi

# -- Architectural checklist: load relevant patterns --
_ARCH_CHECKLIST=""
_ARCH_PATTERNS_FILE="/home/ubuntu/diffhound/config/architectural-patterns.jsonl"
if [ -f "$_ARCH_PATTERNS_FILE" ]; then
  _HAS_PYTHON=$(grep -c '\.py' "$DIFF_FILE" 2>/dev/null || echo "0")
  _LANG_FILTER="all"
  [ "${_HAS_PYTHON:-0}" -gt 0 ] && _LANG_FILTER="python|all"
  _ARCH_CHECKLIST=$(while IFS= read -r _pline; do
    _langs=$(echo "$_pline" | jq -r '.languages[]' 2>/dev/null)
    _match=false
    for _l in $_langs; do echo "$_LANG_FILTER" | grep -q "$_l" && _match=true; done
    if [ "$_match" = true ]; then
      _sev=$(echo "$_pline" | jq -r '.severity' 2>/dev/null)
      _pat=$(echo "$_pline" | jq -r '.pattern' 2>/dev/null)
      _chk=$(echo "$_pline" | jq -r '.check' 2>/dev/null)
      echo "- [ ] [${_sev}] ${_pat}: ${_chk}"
    fi
  done < "$_ARCH_PATTERNS_FILE")
fi
export _FRAMEWORK_FACTS _ARCH_CHECKLIST

  spinner_start "Building review chunks..."
  CHUNK_DIR=$(mktemp -d -t "pr-${PR_NUMBER}-chunks.XXXXXX")

  # Re-reviews ALWAYS chunk the FULL diff (prevents temporal context loss).
  # But we also compute which files changed incrementally so the prompt can
  # apply "contextual blinders" — full visibility, scoped complaints.
  _CHUNK_SOURCE="$CLEANED_DIFF"
  _CHUNK_TRIAGE="$TRIAGE_FILE"
  _INCR_FILES_LIST=""
  if [ "$IS_REREVIEW" = true ] && [ -s "${INCREMENTAL_DIFF_FILE:-}" ]; then
    # Preprocess incremental diff to extract changed file list
    _INCR_CLEANED=$(mktemp -t "pr-${PR_NUMBER}-incr-cleaned.XXXXXX")
    _preprocess_diff "$INCREMENTAL_DIFF_FILE" "$_INCR_CLEANED" "false"
    _INCR_CLEAN_SIZE=$(wc -c < "$_INCR_CLEANED" | tr -d ' ')

    # Guard: empty incremental = merge commit or no real changes
    if [ "$_INCR_CLEAN_SIZE" -eq 0 ]; then
      echo "  ↻ Re-review: incremental diff is empty (merge commit?) — nothing to re-review"
      rm -f "$_INCR_CLEANED" 2>/dev/null
      echo "  ✅ No new code changes since last review. Skipping."
      exit 0
    fi

    # Build list of incrementally changed files (for contextual blinders)
    _INCR_FILES_LIST=$(mktemp -t "pr-${PR_NUMBER}-incr-files.XXXXXX")
    grep '^diff --git' "$_INCR_CLEANED" | sed 's|^diff --git a/.* b/||' | sort -u > "$_INCR_FILES_LIST"
    _INCR_FILE_COUNT=$(wc -l < "$_INCR_FILES_LIST" | tr -d ' ')
    echo "  ↻ Re-review: full diff for context, ${_INCR_FILE_COUNT} files changed since last review"
    rm -f "$_INCR_CLEANED" 2>/dev/null
  fi

  CHUNK_COUNT=$(_build_review_chunks "$_CHUNK_SOURCE" "$_CHUNK_TRIAGE" "$CHUNK_DIR")
  spinner_stop "Built ${CHUNK_COUNT} chunk(s)"

  # Build PR-wide manifest (always from FULL diff so chunks see all files)
  _PR_MANIFEST="${CHUNK_DIR}/pr-manifest.txt"
  _build_pr_manifest "$CLEANED_DIFF" "$TRIAGE_FILE" "$_PR_MANIFEST"

  _TOTAL_PASSES=$((CHUNK_COUNT + 2))  # chunks + peer + voice
  [ "$FAST_MODE" = "true" ] && _TOTAL_PASSES=$((CHUNK_COUNT + 1))
  spinner_start "Reviewing ${CHUNK_COUNT} chunks in parallel (pass 1/${_TOTAL_PASSES})..."
  _review_chunks_parallel "$CHUNK_DIR" "$CHUNK_COUNT" "$PR_SUMMARY_HEADER" "$RAG_CONTEXT_FILE" "$REPO_PATH" "$_PR_MANIFEST" "$IS_REREVIEW" "${THREADS_SUMMARY_FILE:-}" "${_INCR_FILES_LIST:-}"
  spinner_stop "Parallel chunk review complete"

  spinner_start "Merging findings from ${CHUNK_COUNT} chunks..."
  _merge_chunk_findings "$CHUNK_DIR" "$CHUNK_COUNT" "$CLAUDE_OUT"
  spinner_stop "Findings merged"

elif [ "$REVIEW_TIER" = "MEDIUM" ]; then
  # ── MEDIUM: Compress diff + trim RAG → single Claude call ──
  COMPRESSED_DIFF=$(mktemp -t "pr-${PR_NUMBER}-compressed.XXXXXX")
  _compress_medium "$CLEANED_DIFF" "$COMPRESSED_DIFF"
  COMPRESSED_SIZE=$(wc -c < "$COMPRESSED_DIFF" | tr -d ' ')
  echo "  📦 Medium tier: compressed ${CLEANED_SIZE}B → ${COMPRESSED_SIZE}B"

  # Trim RAG to 40KB for medium tier
  _trim_rag "$RAG_CONTEXT_FILE" 40960

  # Use compressed diff as the diff source for the standard prompt path
  cp "$COMPRESSED_DIFF" "$DIFF_FILE"

  # Fall through to standard STEP 2 + STEP 3 below
  :
fi

# ── For SMALL and MEDIUM tiers: use standard monolithic prompt + Claude call ──
if [ "$REVIEW_TIER" = "SMALL" ] || [ "$REVIEW_TIER" = "MEDIUM" ]; then

# ============================================================
# STEP 2: BUILD THE FULL REVIEW PROMPT
# ============================================================
cat > "$PROMPT_FILE" << 'PROMPT_EOF'
You are performing a senior-level code review. Your job here is ENGINEERING ONLY — find bugs, risks, and issues with precision. Do NOT worry about tone, style, or how you phrase things. Just be accurate. A separate pass will handle the writing style.

IMPORTANT: You have access to the full codebase via Read and Bash tools. Use them.
- When you see a changed function — read the full file to understand context before flagging anything
- When you see a pattern in the diff — grep sibling files to check if it exists elsewhere (lateral propagation)
- When you need to verify a type, interface, or enum — read the relevant file
- When you're unsure about intent — check git log for the file
- DO NOT flag something as BLOCKING based only on a diff line — read the surrounding context first
- Use tools actively. The diff is your starting point, not your only source.

# HARD CONSTRAINTS

1. Only flag issues that are verified — before flagging anything, confirm by reading the diff context that the issue actually applies. If you cannot confirm, mark it "UNVERIFIABLE: needs staging check" and include the exact file:line.
2. No "change-all-the-things" suggestions. Incremental fixes only.
3. Do not invent new infrastructure. Propose use of existing utils.
4. Always go deeper: if the diff touches shared helpers, resolvers, or metadata, reference that broader context.
5. If large architectural changes are needed, propose a follow-up ticket, not an in-PR rewrite.
6. NEVER flag lint-level nits. These are explicitly banned: trailing newlines, missing trailing newlines, extra blank lines, whitespace formatting, indentation style, line length, file-ending newlines, import ordering. These are linter/formatter concerns, not code review concerns. A human reviewer's time is too valuable for things a pre-commit hook should catch.

# NOTE ON OUTPUT STYLE
Do NOT worry about tone, casual language, or how comments read. Write your findings in plain technical English — clear, precise, factual. A dedicated style pass will rewrite everything into the right voice. Your job is just to find the right bugs with the right evidence.

# THE 25 PRINCIPLES — CHECK ALL OF THESE

Apply each as a lens. For each principle, perform the concrete check listed.

## Design & Architecture
- **SOLID / SRP**: Is any function doing more than one conceptual job? If yes, flag and suggest extraction.
- **SOLID / OCP**: Is new behavior added by extension (not modification)? Or is existing code being forked?
- **SOLID / LSP**: If subclasses/implementations exist, do they honour the base contract?
- **SOLID / ISP**: Are interfaces bloated? Are callers forced to depend on methods they do not use?
- **SOLID / DIP**: Does code depend on concretions instead of abstractions?
- **DRY**: Detect duplicated logic across files or functions. Propose consolidation into shared helpers.
- **KISS**: Flag unnecessary complexity. Prefer simpler alternatives.
- **YAGNI**: Flag speculative abstractions or features not needed right now.

## Readability & Maintainability
- **CRISP**: Variable/function names are clear, consistent, pronounceable, specific, predictable.
- **CLEAR**: Code is self-documenting. Comments explain WHY, not WHAT.
- **RIDER**: Code is readable, intentional, documented, explicit, reviewable.
- **SLAP** (Single Level of Abstraction): Functions should operate at one abstraction level. If mixed, flag as SLAP violation and suggest extraction.

## Reliability & Safety
- **SAFER** (for migrations/infra scripts): Simple, Auditable, Fail-safe, Extensible, Reversible. Migrations must be idempotent.
- **Defense in Depth**: Multiple validation layers (schema + runtime checks + tests).
- **Observability**: Structured logging (Pino) vs console.log. If the file already uses a logger, show the exact replacement snippet.

## Security & Privacy
- **STRIDE**: Spoofing, Tampering, Repudiation, Information disclosure, Denial of service, Elevation of privilege — check each.
- **CIA**: Confidentiality, Integrity, Availability.
- **PoLP** (Principle of Least Privilege): DB ops, API access, permissions — least privilege everywhere.
- Secrets in code: search diff for process.env.*KEY, AWS_ACCESS_KEY_ID, password, secret, base64 strings. If found: P0 BLOCKING.
- SQL injection: string concatenation in queries is BLOCKING.
- PII in logs: email, phone, ssn, aadhaar near log calls = BLOCKING.

## Tests & CI
- **FIRST**: Tests are Fast, Independent, Repeatable, Self-validating, Timely.
- **AAA**: Arrange, Act, Assert — each test follows this structure.
- **GWT**: Given, When, Then — test names/descriptions follow this pattern.
- For any logic change: verify presence of unit tests covering the changed behavior. If absent and non-trivial: SHOULD-FIX, include exact test cases to add.

## Performance & Scalability
- **N+1 Queries**: Detect DB queries in loops. Check if DataLoader or withGraphFetched exists but is not used — that is BLOCKING.
- For GraphQL field resolvers: N+1 cost = (queries per invocation) x (max list size). Evaluate the multiplied cost, not per-item cost.
- Pagination: loading unbounded data into memory = BLOCKING.

# CONCRETE VERIFICATION CHECKS (run in this order)

1. **Diff scanning**: Map changed files to domain (API, UI, migrations, infra). For each changed file, list functions and top-level changes.

2. **Type safety**: Flag any obvious type errors, use of `any`, `unknown`, `@ts-ignore`. Note whether tsc --noEmit would pass based on what you can see.

3. **Security**: Scan diff for secrets, SQL injection, PII in logs.

4. **Observability**: Search for console.log in changed files. If file already uses structured logger, show the exact replacement snippet.

5. **DB queries**: Detect queries in loops. If DataLoader/withGraphFetched exists in context but is not used: BLOCKING N+1.

6. **Migrations & idempotency**: For migration files — check IF NOT EXISTS guards, CONCURRENTLY, NOT VALID patterns. Verify the down() function is valid SQL and does not have duplicate WHERE clauses.

7. **Tests**: For any logic change, verify presence/absence of tests. If absent: recommend with exact test cases in GWT format.

8. **Copy-paste bugs**: For TPA/insurer integration files — does the file name say "Care" but reference "MEDIASSIST"? Check for wrong enum/constant from copied code.

9. **Enum completeness**: For any status filter array in the diff — check whether every likely enum value is covered. Missing values = SHOULD-FIX minimum.

10. **Vue guard audit**: For any removed v-if or conditional — does the same guard appear in a method body too? If yes, both must change together. Does removing it allow an unintended user cohort to initiate payment/booking/irreversible action? If yes: BLOCKING.

11. **Race conditions**: Two separate DB calls updating related fields with no transaction = SHOULD-FIX. In financial operations: BLOCKING.

12. **Resilience** (for external API calls, jobs, queues):
    - No timeout on axios/fetch = BLOCKING
    - Loop with no per-item try/catch (no bulkhead) = BLOCKING
    - No DLQ for async queue processing = BLOCKING
    - No retry/backoff = SHOULD-FIX

13. **Hardcoded values**: Config values, base TAT days, SLA values, URLs hardcoded in code instead of using a shared config object = SHOULD-FIX.

14. **Timezone**: CURRENT_DATE or NOW() in cron SQL — verify timezone context. UTC vs IST mismatch = BLOCKING.

15. **NO LAZY VERIFICATION — do the work yourself, never push it back to the author**:
    If you can verify something by reading the diff, you MUST verify it before commenting.
    NEVER write comments like:
    - "verify this could happen"
    - "confirm X matches Y"
    - "check if this is always set"
    - "make sure this exists in the admin dashboard"
    - "double check the behavior is identical"
    If you can read the diff and determine the answer: state it as fact.
    If you genuinely cannot determine it from the diff alone (e.g. requires a live DB query or external system state): say "needs staging verification — [exact command to run]" and classify it as a test checklist item, NOT an inline comment.
    An inline comment that says "verify X" with no evidence is noise. The author already knows to verify things that are uncertain — your job is to tell them things they DON'T know.
    STRONGER RULE: If a finding says "verify", "check", "confirm", or "make sure" and the answer IS determinable from the diff — determine it yourself and state it as fact. If NOT determinable from the diff, put it in the CHECKLIST section (### SCORECARD_END → Checklist), NOT as a FINDING.
    A FINDING that says "verify X" is noise — the author already knows to verify uncertain things. Your job is to tell them things they DON'T know.
    ANTI-HALLUCINATION RULE: Never claim production counts, DB state, runtime behavior, or staging verification results unless that evidence is explicitly included in this prompt. If you don't know → say so and classify as a test checklist item. Unknown is always better than fabricated certainty.

16. **BLOCKING context check — read surrounding lines before asserting**:
    Before marking anything BLOCKING, read 3-5 lines above the flagged line in the diff.
    Specifically: if you're flagging that a field is deleted/modified before being used — first check whether the value was already captured in a variable earlier in the same function. If yes, the risk may not exist. Never assert BLOCKING based on a single line in isolation.
    Example mistake to avoid: flagging `delete data.orgId` before `ensureAuthorized()` as a BLOCKING auth bypass — when `orgId` was captured into a separate `const orgId = data.orgId` two lines earlier and that captured value is what auth uses.

17. **Shared job/cron handler audit**:
    For any cron schedule, job processor, or queue handler in the diff — before suggesting a fix:
    Ask "does this handler/cron serve multiple branches (e.g. multiple claim types, multiple channels)?"
    If yes: a fix that changes the shared schedule/behavior will break the other branch.
    The correct fix is always to split by branch, not change the shared handler.
    Example mistake to avoid: changing `waReminder2` cron from `0 8 * * *` to `0 18 * * *` to fix cashless timing — when the same cron also runs reimbursement reminder 2 which is correctly scheduled at 8 AM.

18. **Bull/queue job: outer catch swallowing = BLOCKING**:
    In any Bull job processor: if the outer catch logs but does NOT rethrow, Bull marks the job as successfully completed with no retry.
    If two operations run sequentially inside the job (e.g. reimbursement then cashless), a throw in the first means the second is permanently skipped — no retry, no DLQ, no alert.
    D+N scheduling makes this permanent: you can't re-run yesterday's D+3 job today.
    This is BLOCKING, not SHOULD-FIX.

19. **Empty-payload → wrong branch = BLOCKING**:
    If an update call strips identity fields (orgId, entityId, etc.) from the payload and the handler checks `if (id && Object.keys(data).length)` to decide update vs create — a payload that contained ONLY identity fields becomes `{}` after stripping. `Object.keys({}).length === 0` falls into the create branch, inserting a duplicate row instead of patching.
    This is BLOCKING (data corruption), not SHOULD-FIX.

20. **Legacy data compatibility on field semantic change = BLOCKING**:
    If a PR changes the semantic meaning of a tracked field (e.g. `attemptNumber: 1` → `attemptNumber: 0` for the first attempt), check whether existing production rows already have the old value.
    If they do: after deploy, idempotency checks against the new value will treat old records as "not yet sent" or vice versa — causing double-sends or silent skips for every in-flight record.
    This is BLOCKING. Fix: migration to rewrite legacy values OR a compatibility shim that handles both old and new semantics.

21. **Lateral pattern propagation — scan for the same pattern in sibling files**:
    If a bug fix applies to function/file A using pattern P, ask: "are there other functions or files that implement the same pattern but were NOT updated?"
    Example: a fix to `endorsementValidators.ts` checking `pOrILFlag` — but `policyDataChecks/utils.ts` has `getCoverageMismatch()` with the same pattern and wasn't touched. That's a SHOULD-FIX minimum.
    Scan the diff for the pattern being fixed, then mentally check if it also appears in sibling files (utils, validators, processors with similar names).

22. **Sibling object field consistency**:
    When a field on one object is updated (e.g. `dependent.displayName` → `firstName + lastName`), check whether a sibling object (e.g. `employee`) uses the same field. If yes and it wasn't updated — flag as NIT minimum, SHOULD-FIX if it causes inconsistent behavior.

23. **Security: config-controlled attack surface**:
    For any value that originates from DB config, org meta, or admin-editable fields — ask: "who can change this value, and what happens if it's changed to something malicious?"
    Specifically: if a URL from org config is used to construct a redirect, embed, or token-passing operation — and an admin (compromised or misconfigured) changes that URL — what is the blast radius?
    Token/credential passed to an externally-controlled URL = BLOCKING.

24. **URL construction edge cases**:
    For any code that appends to a URL string:
    a) Double-fragment: if the base URL already contains `#`, appending `#key=val` creates two `#` symbols — the browser parses only the first and ignores the rest. Fix: detect existing fragment and append with `&` instead.
    b) Param collision: if using `append()` to add a param, and the source already contains a param with the same key (e.g. `token`), the consumer may pick the wrong one. Use `set()` or a namespaced key (e.g. `appAuthToken`).
    Either of these causing auth token misdirection = BLOCKING.

25. **Retract nits before posting — no noise comments**:
    Before writing a NIT, reason through it fully. If your own reasoning shows the concern is unfounded (e.g. "actually empty string is falsy so this is already handled"), do NOT post the comment. An inline comment that contradicts itself is worse than no comment — it wastes the author's time and signals uncertain review quality.
    LINT NITS ARE BANNED: trailing newlines, missing newlines, extra blank lines, whitespace, indentation, import order, file-ending newlines — these are linter territory, not review territory. If your comment is about formatting that any auto-formatter would fix, DROP IT. Zero tolerance.

# SEVERITY DEFINITIONS

- BLOCKING: Must fix before merge. Security, N+1 in list resolvers, missing timeout on external calls, data corruption, swallowed errors in financial paths, missing idempotency, SQL syntax errors in migrations.
- SHOULD-FIX: Fix soon, can merge with a follow-up ticket. Error handling, logging, validation gaps, missing tests.
- NIT: Nice to have. Naming, minor refactoring, style.

# SEVERITY ANCHOR TABLE (minimums)

| Condition | Minimum |
|-----------|---------|
| User can reach payment/booking they should not | BLOCKING |
| N+1 in GraphQL resolver used in any list query | BLOCKING |
| Guard removed, newly-reachable unintended cohort | BLOCKING |
| UTC/IST timezone mismatch in cron SQL | BLOCKING |
| Missing timeout on external API call | BLOCKING |
| Swallowed error in financial path | BLOCKING |
| SQL syntax error in migration down() | BLOCKING |
| Bull job outer catch swallowed — one processing branch permanently dropped | BLOCKING |
| Empty-payload stripped of identity fields → falls into create branch (duplicate row) | BLOCKING |
| Legacy field semantic change with no migration — in-flight records silently broken | BLOCKING |
| Enum value absent from filter constant | SHOULD-FIX |
| Missing test file for new functionality | SHOULD-FIX |
| Silent catch block with no warning log | SHOULD-FIX |
| Hardcoded value that duplicates a config object | SHOULD-FIX |
| Token/credential passed to a DB-config-controlled URL (org meta, admin-editable) | BLOCKING |
| URL fragment construction with potential double-`#` causing auth token misdirection | BLOCKING |
| Same bug fix pattern exists in sibling file not updated | SHOULD-FIX |
| Sibling object field updated inconsistently with sibling | NIT |

# SCORING RUBRIC

Produce a score 0-100:
- Security: 25%
- Tests: 20%
- Observability: 10%
- Performance (incl. N+1): 15%
- Readability & Maintainability: 15%
- Backwards compatibility / API stability: 15%

Verdict is severity-based, NOT score-based:
- Any BLOCKING findings → REQUEST_CHANGES
- SHOULD-FIX findings only (no BLOCKING) → COMMENT
- NITs only or clean → APPROVE

# REQUIRED OUTPUT FORMAT

You MUST output valid JSON. No text before or after the JSON block. Wrap in \`\`\`json fences.

SCORE RULE (critical): The "score" field MUST equal the sum of all scorecard category scores. Do NOT guess or estimate — add them: security.score + tests.score + observability.score + performance.score + readability.score + compatibility.score = score. Double-check your arithmetic.

BLOCKER-SCORE CONSISTENCY RULE (critical): Scores MUST reflect findings severity. If a category has BLOCKING findings, its score MUST be <= 50% of max (e.g. security with a blocker: max 12/25). If a category has 2+ SHOULD-FIX findings, its score MUST be <= 75% of max. A review with ANY blocking finding should score below 85 total. Do NOT give high scores while simultaneously flagging blockers -- that is contradictory and useless to reviewers.

RE-REVIEW SCORE RULE: When re-reviewing after fixes, if a category has NO new issues, its score MUST be >= the previous review's score. Do NOT deduct points with generic notes like "no regressions" or "no changes" — that is not a reason to lose points. Only deduct if you can cite a SPECIFIC file:line that justifies the deduction. If all prior blockers are fixed, the score should go UP, not down.

SCORE ANCHORING RULE (re-review only): Your scores MUST be justified relative to the previous round's scores (provided below if available). Rules:
- Category with FIXED issues (blockers resolved): score MUST increase (+2 minimum per resolved blocker)
- Category with NEW issues not in previous round: score MAY decrease (explain why)
- Category with NO CHANGES: score MUST stay within +-1 of previous
- Format each score change as: "Tests: 15->18 (fixed 3 contradicting assertions)"

LINE NUMBER RULES (critical — wrong lines cause GitHub to reject the comment):
- LINE must be a line number from the \`+\` side of the diff (i.e. a line shown with \`+\` prefix or unchanged context line inside a hunk)
- Count from the \`@@ +NEW,count @@\` hunk header to find the correct line number
- NEVER approximate or guess a line number — if you can\'t find the exact \`+\` line, use the nearest \`+\` line in the same hunk
- Only comment on lines that appear in the diff — never reference lines outside diff hunks

```json
{
  "summary": "Overall PR assessment in 1-2 sentences",
  "verdict": "REQUEST_CHANGES | COMMENT | APPROVE",
  "score": 0,
  "scorecard": {
    "security": {"score": 20, "max": 25, "reason": "..."},
    "tests": {"score": 15, "max": 20, "reason": "..."},
    "observability": {"score": 8, "max": 10, "reason": "..."},
    "performance": {"score": 12, "max": 15, "reason": "..."},
    "readability": {"score": 13, "max": 15, "reason": "..."},
    "compatibility": {"score": 14, "max": 15, "reason": "..."}
  },
  "findings": [
    {
      "file": "src/api/claims.ts",
      "line": 45,
      "severity": "BLOCKING",
      "confidence": 0.92,
      "title": "SQL injection via unsanitized input",
      "body": "The claimId parameter is interpolated directly into the query string...",
      "evidence": "Line 45: db.raw(SELECT * FROM claims WHERE id = ${claimId})",
      "impact": "Attacker can execute arbitrary SQL via claimId parameter",
      "suggestion": "Use parameterized query: db.raw('SELECT * FROM claims WHERE id = ?', [claimId])",
      "options": ["Use parameterized query", "Use Knex query builder .where()"],
      "unverifiable": false
    }
  ],
  "thread_statuses": [
    {
      "file": "path/to/file.ts",
      "line": 10,
      "status": "RESOLVED | STILL_OPEN | AUTHOR_WRONG | RESOLVED_BY_EXPLANATION | NO_RESPONSE",
      "original_concern": "...",
      "evidence": "...",
      "author_reply": "...",
      "reviewer_verdict": "..."
    }
  ],
  "checklist": ["Run staging test for X", "Verify Y in prod"],
  "requirement_coverage": {
    "ticket": "BX-1234 or null if no Jira ticket found",
    "addressed": ["requirement 1 that code implements", "requirement 2"],
    "missing": ["acceptance criteria not covered by code changes"],
    "notes": "Any caveats about partial coverage or ambiguous requirements"
  }
}
```

FINDING RULES:
- Only include findings for issues tied to a SPECIFIC line number visible in the diff
- LINE must be a line visible in the diff as a \`+\` line (added or modified). Never approximate.
- Use the EXACT file path from the diff
- Do NOT include findings for things that look good
- If uncertain after reading surrounding context: set unverifiable to true and explain in body
- confidence: 0.0-1.0 (how certain are you this is a real issue, not a false positive)
- thread_statuses: only include in re-review mode, otherwise empty array

# SCOPE DISCIPLINE (CRITICAL — violations of these rules waste developer time)

## Rule 1: ONLY review code CHANGED in this PR
- If a line is NOT in the diff (no \`+\` or \`-\` prefix), do NOT comment on it
- Pre-existing patterns, pre-existing tech debt, pre-existing missing tests = OUT OF SCOPE
- "This file also has X problem" = OUT OF SCOPE unless X was introduced by this PR
- If a sibling file has the same bug pattern, only flag it if THIS PR introduced or copied the pattern
- Exception: security vulnerabilities (secrets, SQL injection) are always in scope even if pre-existing

## Rule 2: CALLER REACHABILITY CHECK before flagging edge cases
- Before flagging "what if the caller sends X" — look for callers in the diff and RAG context
- If the function is only called from a UI form with fixed fields (visible in diff/context), "what if someone sends arbitrary JSON" is NOT a valid concern
- If the function is only called internally (not exposed via API, visible in diff/context), external attacker scenarios are NOT valid
- A theoretical edge case that requires a caller path that doesn't exist in the visible context = NOT A FINDING
- Ask: "Can a real user, through the actual UI or API, trigger this?" If the visible context shows NO → drop it
- Ask: "Has this pattern existed in production without issues?" If YES and the PR didn't change it → drop it
- IMPORTANT: If you CANNOT determine reachability from the diff + RAG context, do NOT speculate. Either mark UNVERIFIABLE or drop it. Never hallucinate that you checked callers you cannot see.

## Rule 3: PROPORTIONALITY — match review depth to PR risk
- BLOCKING and SECURITY findings: ALWAYS report, no cap. These are never suppressed.
- NON-BLOCKING findings (SHOULD-FIX, NIT) are capped by PR size:
  - Bug fix PR (< 100 lines): max 3 non-blocking findings
  - Feature PR (100-500 lines): max 5 non-blocking findings
  - Large PR (500+ lines): max 8 non-blocking findings
- If you have more non-blocking findings than the limit: keep only the highest severity ones, drop the rest
- A 3-file bug fix should NOT get 15 comments across 5 review rounds. That's a process failure.
- For out-of-scope issues worth tracking: put them in the Checklist section as "follow-up ticket", NOT as inline comments
- If a BLOCKING fix requires changing code outside the PR's scope, still flag it but note "follow-up ticket recommended" instead of demanding an in-PR fix

## Rule 4: FRONT-LOAD everything — no drip-feeding findings across rounds
- In re-review mode: ONLY check whether previous findings were addressed + review NEW code
- Do NOT find new non-blocking issues in code that was already reviewed in a previous round (unless the code changed)
- Exception: SECURITY and DATA CORRUPTION issues must ALWAYS be reported, even if missed in round 1 (apologize for the late find)
- For missed non-security issues: put in Checklist as "follow-up", NOT as inline comments
- The developer's job is to address YOUR findings, not to play whack-a-mole with new ones each round

PROMPT_EOF

# Append existing conversation context if present
if [ "$IS_REREVIEW" = true ]; then
  cat >> "$PROMPT_FILE" << REREVIEW_HEADER

---

# EXISTING REVIEW CONVERSATION (re-review mode)

The reviewer has already posted comments on this PR. Your job now is DIFFERENT from a fresh review:

## For each existing THREAD below:
1. Look at the current diff — is the concern now fixed in the code?
2. Did the author reply? Is their reply correct/sufficient?
   - If author said "fixed" → verify in diff. If actually fixed: output THREAD_STATUS: RESOLVED. If not fixed: THREAD_STATUS: STILL_OPEN with evidence.
   - If author gave a reason/explanation → evaluate if their reasoning is technically correct. If wrong: THREAD_STATUS: AUTHOR_WRONG with your counter-evidence. If right: THREAD_STATUS: RESOLVED_BY_EXPLANATION.
   - If author made no reply → THREAD_STATUS: NO_RESPONSE (flag if still an issue in diff)
3. Also look for NEW issues in the diff (new code since last review) — output these as regular FINDING blocks.

## CRITICAL RE-REVIEW CONSTRAINTS:
- Do NOT find new non-blocking issues in code that was already present in the previous review round
- Only flag NEW issues in lines that were ADDED or CHANGED since the last review
- Exception: SECURITY and DATA CORRUPTION issues must always be reported even if missed earlier
- For missed non-security issues: put in Checklist as "follow-up", NOT as inline findings
- Max NEW non-blocking findings in a re-review: 3. Security/data-corruption findings have no cap

## REGRESSION GATING (resolved threads):
- Do NOT reopen or re-flag issues from resolved threads UNLESS:
  1. The fix introduced a NEW bug in the same changed hunk (not just nearby code)
  2. A symbol/function/variable referenced in the original finding was modified in a way that reintroduces the concern
  3. The regression is HIGH-CONFIDENCE: you can point to a specific diff line that proves it
- If none of these apply: the thread stays resolved. Move on.
- "The code near this area changed" is NOT sufficient to reopen. The original concern must be demonstrably reintroduced.
- Patch fallout on unrelated code is a NEW finding, not a reopened thread. File it separately only if it meets the severity bar.

## Output format for existing threads:
THREAD_STATUS: path/to/file.ts:LINE
STATUS: RESOLVED | STILL_OPEN | AUTHOR_WRONG | RESOLVED_BY_EXPLANATION | NO_RESPONSE
ORIGINAL_CONCERN: [1-line summary of what was flagged]
EVIDENCE: [what in the diff shows it's fixed or still broken]
AUTHOR_REPLY: [what author said, if anything]
REVIEWER_VERDICT: [your assessment — is author's reply correct? what's the actual state?]

## EXISTING THREADS:
REREVIEW_HEADER

# -- Self-contradiction guard: inject prior suggestions --
_suggestions_file="$REVIEW_CACHE_DIR/pr-${PR_NUMBER}-suggestions.jsonl"
if [ "$IS_REREVIEW" = true ] && [ -f "$_suggestions_file" ] && [ -s "$_suggestions_file" ]; then
  _PRIOR_SUGGESTIONS=$(jq -r '"- " + .file + ":" + (.line|tostring) + " -- you suggested: \"" + .suggestion + "\""' "$_suggestions_file" 2>/dev/null | head -20)
  if [ -n "$_PRIOR_SUGGESTIONS" ]; then
    cat >> "$PROMPT_FILE" << SUGGESTIONS_BLOCK

YOUR PRIOR SUGGESTIONS (from previous review rounds):
${_PRIOR_SUGGESTIONS}

SELF-CONSISTENCY RULE: Do NOT flag code that implements your own prior
suggestions as a new bug. If you now believe a prior suggestion was wrong,
explicitly say "I previously suggested X but I now think that was incorrect
because Y" -- do not silently contradict yourself.

SUGGESTIONS_BLOCK
  fi
fi

# -- Score anchoring: inject previous scorecard --
if [ "$IS_REREVIEW" = true ] && [ -n "${PREV_SCORECARD_JSON:-}" ]; then
  _prev_score_summary=$(echo "$PREV_SCORECARD_JSON" | jq -r 'to_entries[] | "\(.key): \(.value.score)/\(.value.max)"' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
  _prev_total=$(echo "$PREV_SCORECARD_JSON" | jq '[.[].score] | add' 2>/dev/null || echo "?")
  cat >> "$PROMPT_FILE" << SCORE_ANCHOR_BLOCK

PREVIOUS SCORECARD (from last review round):
${_prev_score_summary}. Total: ${_prev_total}

Apply SCORE ANCHORING RULE above. Justify every score that changes by more than +-1.

SCORE_ANCHOR_BLOCK
fi
  cat "$THREADS_SUMMARY_FILE" >> "$PROMPT_FILE"
  echo "" >> "$PROMPT_FILE"
  echo "---" >> "$PROMPT_FILE"
  echo "" >> "$PROMPT_FILE"

  # Score anchoring is handled POST-LLM by script-owned merging (see after CLAUDE_OUT).
  # The LLM evaluates all categories fresh; the script clamps scores to ±5 of previous.

  # If incremental diff is available, add focused review instructions
  if [ -n "$INCREMENTAL_DIFF_FILE" ] && [ -s "$INCREMENTAL_DIFF_FILE" ]; then
    {
      echo "# RE-REVIEW MODE — FOCUS ON INCREMENTAL CHANGES"
      echo ""
      echo "## FILES CHANGED SINCE LAST REVIEW (at ${LAST_REVIEWED_SHA:0:8}):"
      cat "$INCREMENTAL_FILES_LIST"
      echo ""
      echo "## FILES UNCHANGED (already reviewed — skip unless referenced by a thread):"
      # Files in full diff but NOT in incremental list
      comm -23 \
        <(grep '^diff --git' "$DIFF_FILE" | sed 's|^diff --git a/.* b/||' | sort) \
        <(sort "$INCREMENTAL_FILES_LIST") 2>/dev/null || true
      echo ""
      echo "## YOUR PRIORITIES (in order):"
      echo "1. Check each EXISTING THREAD above — is the concern now fixed in the new code?"
      echo "2. Review ONLY the incremental diff below for NEW issues"
      echo "3. Do NOT re-flag issues in unchanged files — they were already reviewed"
      echo ""
      echo "---"
      echo ""
      echo "# INCREMENTAL DIFF (changes since last review at ${LAST_REVIEWED_SHA:0:8})"
      echo ""
    } >> "$PROMPT_FILE"
    cat "$INCREMENTAL_DIFF_FILE" >> "$PROMPT_FILE"
    {
      echo ""
      echo "---"
      echo ""
      echo "# FULL PR DIFF (for context only — reference when checking thread resolution)"
      echo ""
    } >> "$PROMPT_FILE"
  else
    echo "# NEW FINDINGS (issues not in previous review)" >> "$PROMPT_FILE"
    echo "" >> "$PROMPT_FILE"
  fi
fi

# Append PR details and diff
cat >> "$PROMPT_FILE" << PR_META

# PR DETAILS

Title: ${PR_TITLE}
Author: @${PR_AUTHOR}
Files changed: ${FILE_COUNT} (+${ADDITIONS}/-${DELETIONS})

PR_META

# For re-reviews with incremental diff, label the full diff as context-only
if [ "$IS_REREVIEW" = true ] && [ -n "$INCREMENTAL_DIFF_FILE" ] && [ -s "$INCREMENTAL_DIFF_FILE" ]; then
  cat >> "$PROMPT_FILE" << PR_META_REREVIEW

PR Description:
${PR_BODY}

---

# FULL PR DIFF (context reference — focus your analysis on the INCREMENTAL DIFF above)

PR_META_REREVIEW
else
  cat >> "$PROMPT_FILE" << PR_META_FRESH

PR Description:
${PR_BODY}

---

PR_META_FRESH

  # Inject Jira context if available (before diff for requirement priming)
  if [ -n "${JIRA_CONTEXT:-}" ]; then
    cat >> "$PROMPT_FILE" << JIRA_HEADER

${JIRA_CONTEXT}

---

JIRA_HEADER
  fi

  echo "# DIFF" >> "$PROMPT_FILE"
  echo "" >> "$PROMPT_FILE"
fi

cat "$DIFF_FILE" >> "$PROMPT_FILE"

# Append repo config context if available
if [ -n "$DIFFHOUND_CONTEXT" ]; then
  cat >> "$PROMPT_FILE" << CONFIG_HEADER

---

# REPO-SPECIFIC CONTEXT (from .diffhound.yml)
# This is project-level context the team has provided. Use it to understand patterns and conventions.

${DIFFHOUND_CONTEXT}

CONFIG_HEADER
fi

if [ -n "$DIFFHOUND_PRIORITIES" ]; then
  {
    echo ""
    echo "# REPO-SPECIFIC PRIORITIES (from .diffhound.yml)"
    echo "Pay extra attention to these areas:"
    while IFS= read -r _p; do
      [ -z "$_p" ] && continue
      echo "- $_p"
    done <<< "$DIFFHOUND_PRIORITIES"
    echo ""
  } >> "$PROMPT_FILE"
fi

if [ -n "$DIFFHOUND_IGNORE" ]; then
  {
    echo ""
    echo "# REPO-SPECIFIC IGNORE RULES (from .diffhound.yml)"
    echo "Do NOT flag the following — the team has explicitly deprioritized them:"
    while IFS= read -r _ig; do
      [ -z "$_ig" ] && continue
      echo "- $_ig"
    done <<< "$DIFFHOUND_IGNORE"
    echo ""
  } >> "$PROMPT_FILE"
fi

# Append RAG context if available
if [ -s "$RAG_CONTEXT_FILE" ]; then
  cat >> "$PROMPT_FILE" << RAG_HEADER

---

# CODEBASE CONTEXT (RAG-retrieved — sibling files, git history, past comments)
# Use this to verify patterns, check lateral propagation, and avoid false positives.

RAG_HEADER
  cat "$RAG_CONTEXT_FILE" >> "$PROMPT_FILE"
fi

# Inject static analysis findings if available
if [ -n "${LINT_CONTEXT:-}" ]; then
  cat >> "$PROMPT_FILE" << LINT_HEADER

---

${LINT_CONTEXT}

LINT_HEADER
fi

# ============================================================
# STEP 3: RUN CLAUDE — NON-AGENTIC PASS (inline context, no tools)
# ============================================================
echo ""
echo ""
# Pass count: Claude(1) + peer(1) + cross-verify(1) + voice(1) = 4
# Fast mode: Claude(1) + voice(1) = 2
# Re-review shallow: Claude(1) + cross-verify(1) + voice(1) = 3
# Re-review full: Claude(1) + peer(1) + cross-verify(1) + voice(1) = 4
_TOTAL_PASSES=4
[ "$FAST_MODE" = "true" ] && _TOTAL_PASSES=2
if [ "$IS_REREVIEW" = true ] && [ "$REREVIEW_DEPTH" = "shallow" ]; then
  _TOTAL_PASSES=3
fi
spinner_start "Analyzing code (pass 1/${_TOTAL_PASSES})......"

# Pass 1: Claude Opus via direct API — primary code review pass

# Pre-fetch file contents for changed files (replaces agentic tool calls)
# Budget: max 20KB total context to prevent prompt bloat
_CONTEXT_FILE=$(mktemp -t "pr-${PR_NUMBER}-context.XXXXXX")
_CONTEXT_BUDGET=20000  # bytes
_CONTEXT_USED=0
{
  echo ""
  echo "# FILE CONTENTS (changed files — for verifying findings)"
  echo ""
  # Only include source files (skip tests, configs, lockfiles)
  grep '^diff --git' "$DIFF_FILE" 2>/dev/null | sed 's|^diff --git a/.* b/||' | sort -u | while read -r _cf; do
    [ -z "$_cf" ] && continue
    # Skip test files and large generated files
    case "$_cf" in
      *test*|*spec*|*__test__*|*.lock|*.min.*|*package-lock*|*yarn.lock*) continue ;;
    esac
    _full_path="${REPO_PATH}/${_cf}"
    if [ -f "$_full_path" ]; then
      _file_size=$(wc -c < "$_full_path" 2>/dev/null || echo "0")
      # Skip files larger than 8KB (likely not reviewable inline)
      [ "${_file_size:-0}" -gt 8000 ] && continue
      # Check budget
      [ "$_CONTEXT_USED" -ge "$_CONTEXT_BUDGET" ] && break
      _snippet=$(head -150 "$_full_path" 2>/dev/null)
      _snippet_size=${#_snippet}
      if [ $((_CONTEXT_USED + _snippet_size)) -le "$_CONTEXT_BUDGET" ]; then
        echo "### FILE: ${_cf}"
        echo '```'
        echo "$_snippet"
        _total_lines=$(wc -l < "$_full_path" 2>/dev/null || echo "0")
        [ "${_total_lines:-0}" -gt 150 ] && echo "... (truncated at 150/${_total_lines} lines)"
        echo '```'
        echo ""
        _CONTEXT_USED=$((_CONTEXT_USED + _snippet_size))
      fi
    fi
  done
} > "$_CONTEXT_FILE"

_ctx_size=$(wc -c < "$_CONTEXT_FILE" 2>/dev/null || echo "0")
echo "  File context: ${_ctx_size}B (budget: ${_CONTEXT_BUDGET}B)" >&2

# Append file context to prompt
cat "$_CONTEXT_FILE" >> "$PROMPT_FILE"
rm -f "$_CONTEXT_FILE"

# Non-agentic pass: no tools needed, all context is inline
# Scale timeout with prompt size: base 180s + 1s per 300 chars, capped at 480s
# Non-agentic is faster than agentic but large prompts (50KB+) still need 3-5 min
_PROMPT_BYTES=$(wc -c < "$PROMPT_FILE" 2>/dev/null || echo "0")
_CLAUDE_TIMEOUT=$(( 180 + _PROMPT_BYTES / 300 ))
[ "$_CLAUDE_TIMEOUT" -gt 480 ] && _CLAUDE_TIMEOUT=480
[ "$_CLAUDE_TIMEOUT" -lt 180 ] && _CLAUDE_TIMEOUT=180
echo "  [debug] prompt=${_PROMPT_BYTES}B, timeout=${_CLAUDE_TIMEOUT}s" >&2
if ! _call_api "claude-opus-4-6" 16384 "$_CLAUDE_TIMEOUT" < "$PROMPT_FILE" > "$CLAUDE_OUT" 2>"${CLAUDE_OUT}.stderr"; then
  echo "  [debug] claude failed — out=$(wc -c < "$CLAUDE_OUT" 2>/dev/null)B stderr=$(cat "${CLAUDE_OUT}.stderr" 2>/dev/null | head -3)" >&2
  # Check if partial output is usable (timeout may kill mid-write but JSON is complete)
  _partial_json=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
  echo "  [debug] extract_json length=${#_partial_json}" >&2
  if [ -n "$_partial_json" ] && echo "$_partial_json" | jq -e '.findings' >/dev/null 2>&1; then
    spinner_fail "Analysis timed out but output is usable — continuing"
  else
    spinner_fail "Primary pass failed — retrying"
    if ! _call_api "claude-opus-4-6" 16384 360 < "$PROMPT_FILE" > "$CLAUDE_OUT" 2>&1; then
      _partial_json=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
      if [ -z "$_partial_json" ] || ! echo "$_partial_json" | jq -e '.findings' >/dev/null 2>&1; then
        spinner_fail "Analysis failed"
        cat "$CLAUDE_OUT" >&2
        exit 1
      fi
      spinner_fail "Fallback timed out but output is usable — continuing"
    fi
  fi
fi

spinner_stop "Pass 1 complete"

fi  # end SMALL/MEDIUM tier monolithic path

# ── Fix scorecard math: recompute score as sum of category scores ──
# Claude sometimes hallucinates the total score. Belt + suspenders.
_json_check=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
if [ -n "$_json_check" ] && echo "$_json_check" | jq -e '.scorecard' >/dev/null 2>&1; then
  _computed_score=$(echo "$_json_check" | jq '[.scorecard[].score] | add' 2>/dev/null || echo "")
  _claimed_score=$(echo "$_json_check" | jq '.score' 2>/dev/null || echo "")
  if [ -n "$_computed_score" ] && [ -n "$_claimed_score" ] && [ "$_computed_score" != "$_claimed_score" ]; then
    echo "  Fixing scorecard math: claimed ${_claimed_score}, actual ${_computed_score}" >&2
    _fixed_json=$(echo "$_json_check" | jq --argjson s "$_computed_score" '.score = $s')
    { echo '```json'; echo "$_fixed_json"; echo '```'; } > "$CLAUDE_OUT"
  fi

  # -- Blocker penalty: cap scores when findings contradict scorecard --
  _blocker_count=$(echo "$_json_check" | jq '[.findings[] | select(.severity == "BLOCKING")] | length' 2>/dev/null || echo "0")
  _blocker_count=$(echo "${_blocker_count:-0}" | tr -d '[:space:]')
  _shouldfix_count=$(echo "$_json_check" | jq '[.findings[] | select(.severity == "SHOULD-FIX")] | length' 2>/dev/null || echo "0")
  _shouldfix_count=$(echo "${_shouldfix_count:-0}" | tr -d '[:space:]')
  _current_score=$(echo "$_json_check" | jq '.score // 0' 2>/dev/null || echo "0")
  _current_score=$(echo "${_current_score:-0}" | tr -d '[:space:]')

  _cap=100
  if [ "${_blocker_count:-0}" -ge 3 ] 2>/dev/null; then
    _cap=65
  elif [ "${_blocker_count:-0}" -ge 1 ] 2>/dev/null; then
    _cap=80
  elif [ "${_shouldfix_count:-0}" -ge 5 ] 2>/dev/null; then
    _cap=85
  elif [ "${_shouldfix_count:-0}" -ge 3 ] 2>/dev/null; then
    _cap=90
  fi

  if [ "${_current_score:-0}" -gt "$_cap" ] 2>/dev/null; then
    echo "  Capping score: ${_current_score} -> ${_cap} (${_blocker_count} blockers, ${_shouldfix_count} should-fixes)" >&2
    # Scale all category scores proportionally to hit the cap
    _scale=$(awk "BEGIN {printf \"%.4f\", ${_cap}/${_current_score}}")
    _capped_json=$(echo "$_json_check" | jq --argjson cap "$_cap" --arg scale "$_scale" '
      .score = $cap |
      .scorecard |= with_entries(
        .value.score = ((.value.score * ($scale | tonumber)) | floor)
      ) |
      .scorecard |= with_entries(.value.reason = .value.reason + " [score capped]")
    ')
    if [ -n "$_capped_json" ]; then
      { echo '```json'; echo "$_capped_json"; echo '```'; } > "$CLAUDE_OUT"
      _json_check="$_capped_json"
    fi
  fi

  # Embed scorecard as hidden HTML comment for reliable extraction in future re-reviews.
  # Re-reviews will prefer this over markdown table parsing.
  if [ "$IS_REREVIEW" != true ]; then
    _json_check=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
    _sc_compact=$(echo "$_json_check" | jq -c '.scorecard' 2>/dev/null || true)
    if [ -n "$_sc_compact" ]; then
      _sc_comment="<!-- SCORECARD_JSON
${_sc_compact}
SCORECARD_JSON -->"
      _updated=$(echo "$_json_check" | jq --arg sc "$_sc_comment" '.summary = .summary + "\n\n" + $sc')
      { echo '```json'; echo "$_updated"; echo '```'; } > "$CLAUDE_OUT"
    fi
  fi
fi

# ── Script-owned score merging for re-reviews ──────────────────
# Two modes:
# 1. MONOTONIC (no new blockers/should-fix): scores can only go UP or stay flat
#    Rationale: if all prior issues are fixed and nothing new is flagged, the LLM
#    shouldn't randomly deduct points with generic notes like "no regressions"
# 2. BOUNDED (new issues found): clamp each category to ±5 of previous score
if [ "$IS_REREVIEW" = true ] && [ -n "$PREV_SCORECARD_JSON" ]; then
  _json_check=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
  if [ -n "$_json_check" ] && echo "$_json_check" | jq -e '.scorecard' >/dev/null 2>&1; then
    # Determine if there are new BLOCKING or SHOULD-FIX findings
    _new_blocking=$(echo "$_json_check" | jq '[.findings[]? | select(.severity == "BLOCKING" or .severity == "SHOULD-FIX")] | length' 2>/dev/null || echo "0")
    _score_mode="monotonic"
    [ "${_new_blocking:-0}" -gt 0 ] && _score_mode="bounded"

    _merged_json=$(echo "$_json_check" | jq --argjson prev "$PREV_SCORECARD_JSON" --arg mode "$_score_mode" '
      .scorecard as $new |
      reduce ($new | keys[]) as $cat ($new;
        if $prev[$cat] then
          .[$cat].score as $ns |
          $prev[$cat].score as $ps |
          if $mode == "monotonic" then
            # No new issues: scores can only go UP or stay flat
            if $ns < $ps then
              .[$cat].score = $ps |
              .[$cat].reason = .[$cat].reason + " [held: no new issues justify drop from \($ps)]"
            else . end
          else
            # New issues found: allow ±5 swing
            if ($ns - $ps) > 5 then
              .[$cat].score = ($ps + 5) |
              .[$cat].reason = .[$cat].reason + " [clamped: LLM scored \($ns), prev \($ps)]"
            elif ($ps - $ns) > 5 then
              .[$cat].score = ($ps - 5) |
              .[$cat].reason = .[$cat].reason + " [clamped: LLM scored \($ns), prev \($ps)]"
            else . end
          end
        else . end
      ) | { scorecard: . }
    ' 2>/dev/null || true)

    echo "  Score mode: ${_score_mode} (new blocking/should-fix: ${_new_blocking:-0})" >&2

    if [ -n "$_merged_json" ] && echo "$_merged_json" | jq -e '.scorecard' >/dev/null 2>&1; then
      _new_scorecard=$(echo "$_merged_json" | jq '.scorecard')
      _new_total=$(echo "$_new_scorecard" | jq '[.[].score] | add')

      # Apply merged scorecard back to the output
      _updated_json=$(echo "$_json_check" | jq --argjson sc "$_new_scorecard" --argjson t "$_new_total" '
        .scorecard = $sc | .score = $t
      ')

      _old_total=$(echo "$_json_check" | jq '[.scorecard[].score] | add' 2>/dev/null || echo "?")
      if [ "$_old_total" != "$_new_total" ]; then
        echo "  Score merge: LLM total ${_old_total} → clamped total ${_new_total}" >&2
        # Log which categories were clamped
        echo "$_new_scorecard" | jq -r 'to_entries[] | select(.value.reason | test("\\[clamped")) | "    ↳ \(.key): \(.value.reason | match("\\[clamped.*\\]").string)"' 2>/dev/null >&2 || true
      fi

      # Embed previous scorecard as hidden HTML comment for next re-review extraction
      _scorecard_comment="<!-- SCORECARD_JSON
$(echo "$_new_scorecard" | jq -c '.')
SCORECARD_JSON -->"

      _updated_json=$(echo "$_updated_json" | jq --arg sc "$_scorecard_comment" '
        .summary = .summary + "\n\n" + $sc
      ')

      { echo '```json'; echo "$_updated_json"; echo '```'; } > "$CLAUDE_OUT"
    fi
  fi
  # -- Persist findings for score anchoring in future re-reviews --
  _findings_json=$(echo "$_json_check" | jq -c '.findings // []' 2>/dev/null || echo "[]")
  if [ -n "$_findings_json" ] && [ "$_findings_json" != "[]" ]; then
    echo "$_findings_json" > "$REVIEW_CACHE_DIR/pr-${PR_NUMBER}-findings-latest.json"
  fi

  # -- Score anchoring: bump categories where blockers were resolved --
  _prev_findings_file="$REVIEW_CACHE_DIR/pr-${PR_NUMBER}-findings-latest.json"
  if [ -f "$_prev_findings_file" ] && [ -n "$_json_check" ]; then
    _categorize_finding() {
      local body="$1"
      if echo "$body" | grep -qiE 'token|secret|auth|password|credential|security|injection|XSS|SSRF'; then echo "security"
      elif echo "$body" | grep -qiE 'test|mock|assertion|eval|coverage|fixture'; then echo "tests"
      elif echo "$body" | grep -qiE 'log|metric|trace|monitor|observability'; then echo "observability"
      elif echo "$body" | grep -qiE 'N\+1|performance|latency|timeout|cache|index'; then echo "performance"
      elif echo "$body" | grep -qiE 'migration|backward|compatibility|breaking|API'; then echo "compatibility"
      else echo "readability"; fi
    }
    for _cat in security tests observability performance readability compatibility; do
      _prev_cat_blockers=$(jq -r '.[] | select(.severity == "BLOCKING") | .body' "$_prev_findings_file" 2>/dev/null | while IFS= read -r _b; do
        [ -z "$_b" ] && continue; _c=$(_categorize_finding "$_b"); [ "$_c" = "$_cat" ] && echo "x"
      done | grep -c . || echo "0")
      _curr_cat_blockers=$(echo "$_json_check" | jq -r '.findings[] | select(.severity == "BLOCKING") | .body' 2>/dev/null | while IFS= read -r _b; do
        [ -z "$_b" ] && continue; _c=$(_categorize_finding "$_b"); [ "$_c" = "$_cat" ] && echo "x"
      done | grep -c . || echo "0")
      if [ "${_prev_cat_blockers:-0}" -gt 0 ] && [ "${_curr_cat_blockers:-0}" -eq 0 ] 2>/dev/null; then
        _bump=$(( _prev_cat_blockers * 2 ))
        _json_check=$(echo "$_json_check" | jq --arg cat "$_cat" --argjson bump "$_bump" '
          if .scorecard[$cat] then
            .scorecard[$cat].score = ([.scorecard[$cat].score + $bump, .scorecard[$cat].max] | min) |
            .scorecard[$cat].reason = .scorecard[$cat].reason + " [+\($bump): resolved blockers]"
          else . end
        ' 2>/dev/null || echo "$_json_check")
        echo "  Score anchor: ${_cat} bumped +${_bump} (${_prev_cat_blockers} blockers resolved)" >&2
      fi
    done
    _new_total=$(echo "$_json_check" | jq '[.scorecard[].score] | add' 2>/dev/null || echo "")
    if [ -n "$_new_total" ]; then
      _json_check=$(echo "$_json_check" | jq --argjson t "$_new_total" '.score = $t')
      { echo '```json'; echo "$_json_check"; echo '```'; } > "$CLAUDE_OUT"
    fi
  fi
fi

# ============================================================
# STEP 3.5: FALSE-POSITIVE GATES — drop LLM-generated FPs before peer review
# sees them (saves tokens) and before voice rewrite polishes them for posting.
# Opt-out: DIFFHOUND_SKIP_VALIDATORS=1
# ============================================================
if [ "${DIFFHOUND_SKIP_VALIDATORS:-0}" != "1" ] \
   && [ -x "${LIB_DIR}/validators/format-adapter.sh" ] \
   && [ -s "$CLAUDE_OUT" ]; then
  _VALIDATED_OUT=$(mktemp -t "pr-${PR_NUMBER}-validated.XXXXXX")
  if DIFFHOUND_REPO="${DIFFHOUND_REPO:-${REPO_PATH:-$(pwd)}}" \
     "${LIB_DIR}/validators/format-adapter.sh" < "$CLAUDE_OUT" > "$_VALIDATED_OUT" 2>/dev/null \
     && [ -s "$_VALIDATED_OUT" ]; then
    # Count findings in either format (JSON .findings[] OR raw FINDING: lines).
    # LARGE tier emits FINDING:-format after chunked merge; MEDIUM/SMALL emit JSON.
    _count_findings() {
      local f="$1"
      [ -s "$f" ] || { echo 0; return; }
      # JSON path: only attempt if _extract_json produces non-empty output.
      # Piping empty output into jq makes it parse "" (empty JSON string),
      # which yields `.findings | length` → 0 — a false zero that hides the
      # LARGE-tier FINDING: lines from the grep fallback below.
      local _extracted n
      _extracted=$(_extract_json "$f" 2>/dev/null)
      if [ -n "$_extracted" ]; then
        n=$(printf '%s' "$_extracted" | jq '.findings | length' 2>/dev/null || echo "")
        if [ -n "$n" ] && [ "$n" != "null" ]; then
          echo "$n"; return
        fi
      fi
      # FINDING: format — bare (MEDIUM/SMALL) or indented (LARGE-tier Haiku merge)
      grep -cE '^\s*FINDING:' "$f" 2>/dev/null || echo 0
    }
    _before=$(_count_findings "$CLAUDE_OUT")
    _after=$(_count_findings "$_VALIDATED_OUT")
    if [ "$_before" != "$_after" ]; then
      echo "  🛡  Validators dropped $((_before - _after)) finding(s) (${_before} → ${_after})" >&2
    else
      echo "  🛡  Validators processed ${_before} finding(s), no drops" >&2
    fi
    # Track whether all findings were dropped — voice rewrite must not hallucinate
    # COMMENT: lines from prose when 0 validated findings remain.
    _VALIDATOR_FINDING_COUNT="$_after"
    mv "$_VALIDATED_OUT" "$CLAUDE_OUT"
  else
    rm -f "$_VALIDATED_OUT"
  fi
fi

# ============================================================
# STEP 3.6: ROUND-DIFF — append CHANGES_SINCE_LAST_REVIEW accounting block.
# Reads PRIOR_FINDINGS_FILE (reconstructed from existing inline comments) and
# computes new/resolved/unchanged relative to the current validated findings.
# On first reviews the prior file is empty → shows "+N new, -0 resolved".
# Opt-out: DIFFHOUND_SKIP_VALIDATORS=1 (shares the validators skip flag)
# ============================================================
_ROUND_DIFF_PY="${LIB_DIR}/validators/round-diff.py"
if [ "${DIFFHOUND_SKIP_VALIDATORS:-0}" != "1" ] \
   && [ -x "$_ROUND_DIFF_PY" ] \
   && [ -s "$CLAUDE_OUT" ]; then
  _RD_OUT=$(mktemp -t "pr-${PR_NUMBER}-rd.XXXXXX")
  if DIFFHOUND_PRIOR_FINDINGS="${PRIOR_FINDINGS_FILE}" \
     python3 "$_ROUND_DIFF_PY" < "$CLAUDE_OUT" > "$_RD_OUT" 2>/dev/null \
     && [ -s "$_RD_OUT" ]; then
    mv "$_RD_OUT" "$CLAUDE_OUT"
    echo "  🔄  round-diff: accounting block appended" >&2
  else
    rm -f "$_RD_OUT"
  fi
fi

# ============================================================
# STEP 4: PEER REVIEW — CODEX + GEMINI
# Routing: --fast → skip | fresh review → full aggressive | re-review shallow → skip | re-review full → incremental-scoped
# ============================================================
CODEX_CONTENT=""
GEMINI_CONTENT=""
PEER_COVERAGE=""

_RUN_PEER_REVIEW=false
_PEER_MODE="fresh"  # "fresh" = aggressive gap-hunt, "rereview" = incremental-only + softened

if [ "$FAST_MODE" = "true" ]; then
  echo "  Fast mode — peer review skipped" >&2
elif [ "$IS_REREVIEW" = "true" ] && [ "$REREVIEW_DEPTH" = "shallow" ]; then
  echo "  Re-review (small delta) — peer review skipped" >&2
elif [ "$IS_REREVIEW" = "true" ] && [ "$REREVIEW_DEPTH" = "full" ]; then
  _RUN_PEER_REVIEW=true
  _PEER_MODE="rereview"
  echo "  Re-review (large delta) — running scoped peer review on incremental diff" >&2
else
  _RUN_PEER_REVIEW=true
  _PEER_MODE="fresh"
fi

if [ "$_RUN_PEER_REVIEW" = true ]; then
  spinner_start "Cross-checking findings (pass 2/${_TOTAL_PASSES})..."

  PEER_PROMPT_FILE=$(mktemp -t "pr-${PR_NUMBER}-peer.XXXXXX")

  # Determine diff content for peer review based on mode
  _PEER_DIFF_CONTENT=""
  if [ "$_PEER_MODE" = "rereview" ] && [ -n "${INCREMENTAL_DIFF_FILE:-}" ] && [ -s "${INCREMENTAL_DIFF_FILE:-}" ]; then
    # Re-review: feed ONLY incremental diff to peers (Codex insight: targeted, not full)
    _PEER_DIFF_CONTENT=$(cat "$INCREMENTAL_DIFF_FILE")
  elif [ "$REVIEW_TIER" = "LARGE" ] || [ "$REVIEW_TIER" = "HUGE" ]; then
    # Large fresh review: send only CRITICAL-file diffs to keep peer prompt under 30KB
    if [ -f "${TRIAGE_FILE:-}" ]; then
      _critical_files=$(grep $'\tCRITICAL\t' "$TRIAGE_FILE" | cut -f1 || true)
      if [ -n "$_critical_files" ]; then
        _PEER_DIFF_CONTENT=$(while IFS= read -r _cf; do
          $_AWK_CMD -v file="$_cf" '
            /^diff --git/ { printing = (index($0, "b/" file) > 0) }
            printing { print }
      END { if (pending && hold != "") {} }
          ' "$CLEANED_DIFF"
        done <<< "$_critical_files")
      fi
    fi
    [ -z "$_PEER_DIFF_CONTENT" ] && _PEER_DIFF_CONTENT=$(head -c 30720 "$CLEANED_DIFF")
  else
    _PEER_DIFF_CONTENT=$(cat "$DIFF_FILE")
  fi

  # Build peer prompt — aggressive for fresh reviews, softened for re-reviews
  if [ "$_PEER_MODE" = "rereview" ]; then
    cat > "$PEER_PROMPT_FILE" << PEER_EOF
I need a peer review of this re-review analysis. Do NOT run any tools or execute code. Text response only.

## Context
This is a RE-REVIEW of a PR after the author pushed new commits. The primary reviewer checked thread resolution and reviewed only the incremental changes. You have the incremental diff below.

## Primary Analysis (FINDING blocks)
$(cat "$CLAUDE_OUT")

## Incremental Diff (changes since last review)
${_PEER_DIFF_CONTENT}

## Your Task (engineering only — no style concerns)
1. For each BLOCKING finding: do you agree? If wrong or overstated, explain why with diff evidence.
2. Any BLOCKING or SECURITY issues genuinely missed in the incremental diff? Reference exact file:line.
3. Any findings rated too low or too high severity?
4. Only flag genuinely missed issues — do not manufacture findings for completeness.

## SCOPE RULES (apply these strictly)
- ONLY comment on code CHANGED in the incremental diff above
- Do NOT flag pre-existing patterns or issues from the original review round
- Do NOT re-raise issues that were already flagged in the first review
- NON-BLOCKING findings cap: max 3. BLOCKING/SECURITY findings: no cap.

Respond in the same FINDING block format. Plain text. No style concerns.
PEER_EOF
  else
    cat > "$PEER_PROMPT_FILE" << PEER_EOF
I need a peer review of this engineering analysis. Do NOT run any tools or execute code. Text response only.

## Context
Code review PR. A primary reviewer produced FINDING blocks below. You also have the full diff to spot anything missed.

## Primary Analysis (FINDING blocks)
$(cat "$CLAUDE_OUT")

## Full PR Diff
${_PEER_DIFF_CONTENT}

## Your Task (engineering only — no style concerns)
1. For each BLOCKING finding: do you agree? If wrong or overstated, explain why with diff evidence.
2. Any BLOCKING or SHOULD-FIX issues the primary analysis missed? Reference exact file:line from diff.
3. Any findings rated too low or too high severity?
4. Assume there is at least one gap. Find it.

## SCOPE RULES (apply these strictly)
- ONLY comment on code CHANGED in this PR (lines with + or - prefix in the diff)
- Pre-existing patterns, tech debt, missing tests NOT introduced by this PR = OUT OF SCOPE
- Before flagging edge cases: verify the caller path actually exists in the diff context. Theoretical scenarios that can't happen via the real UI/API = NOT A FINDING
- Do NOT flag issues that require fixing code outside the PR's changed files
- NON-BLOCKING findings cap: max 5. BLOCKING/SECURITY findings: no cap.

Respond in the same FINDING block format. Plain text. No style concerns.
PEER_EOF
  fi

  # Run Codex in background (prompt via stdin to avoid ARG_MAX on large diffs)
  (cd "$REPO_PATH" 2>/dev/null || cd /tmp; \
    codex exec --skip-git-repo-check -s read-only < "$PEER_PROMPT_FILE" > "$CODEX_OUT" 2>&1 || \
    echo "CODEX_UNAVAILABLE" > "$CODEX_OUT") &
  CODEX_PID=$!

  # Run Gemini in background (prompt via stdin to avoid ARG_MAX on large diffs)
  (gemini -o text < "$PEER_PROMPT_FILE" > "$GEMINI_OUT" 2>&1 || \
    echo "GEMINI_UNAVAILABLE" > "$GEMINI_OUT") &
  GEMINI_PID=$!

  # Wait with 180s timeout — Codex hangs on websocket disconnects (seen on PRs #35, #45, #47).
  # Watchdog: background a sleep+kill, then wait for the real PIDs.
  _PEER_TIMEOUT=90
  ( sleep "$_PEER_TIMEOUT" && kill $CODEX_PID $GEMINI_PID 2>/dev/null ) &
  _WATCHDOG_PID=$!

  wait $CODEX_PID 2>/dev/null || true
  wait $GEMINI_PID 2>/dev/null || true

  # Kill the watchdog if peers finished before timeout
  kill $_WATCHDOG_PID 2>/dev/null || true
  wait $_WATCHDOG_PID 2>/dev/null || true

  # Validate peer output: empty or truncated = unusable
  _validate_peer_output() {
    local file="$1" name="$2"
    if [ ! -s "$file" ]; then
      echo "${name}_UNAVAILABLE" > "$file"
      return
    fi
    # Truncated: file under 100 bytes or doesn't end with sentence-ending char
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    if [ "$size" -lt 100 ]; then
      echo "  warning: ${name} output too short (${size}B) -- discarding" >&2
      echo "${name}_UNAVAILABLE" > "$file"
      return
    fi
    local last_chars
    last_chars=$(tail -c 20 "$file" | tr -d '[:space:]')
    if [ -n "$last_chars" ] && ! printf '%s' "$last_chars" | grep -qE '[.!?)}\]"]$'; then
      echo "  warning: ${name} output appears truncated -- discarding" >&2
      echo "${name}_UNAVAILABLE" > "$file"
    fi
  }
  _validate_peer_output "$CODEX_OUT" "CODEX"
  _validate_peer_output "$GEMINI_OUT" "GEMINI"

  CODEX_CONTENT=$(cat "$CODEX_OUT")
  GEMINI_CONTENT=$(cat "$GEMINI_OUT")

  # Track peer review coverage for transparency
  _PEER_COUNT=0
  _PEER_NAMES=""
  if [ -n "$CODEX_CONTENT" ] && [ "$CODEX_CONTENT" != "CODEX_UNAVAILABLE" ]; then
    _PEER_COUNT=$((_PEER_COUNT + 1)); _PEER_NAMES="Codex"
  fi
  if [ -n "$GEMINI_CONTENT" ] && [ "$GEMINI_CONTENT" != "GEMINI_UNAVAILABLE" ]; then
    _PEER_COUNT=$((_PEER_COUNT + 1)); _PEER_NAMES="${_PEER_NAMES:+$_PEER_NAMES + }Gemini"
  fi
  PEER_COVERAGE="${_PEER_COUNT}/2 peer models (${_PEER_NAMES:-none})"
  spinner_stop "Pass 2 complete — ${PEER_COVERAGE}"
fi

# SYNTH_FINDINGS points to Claude's raw output for Voice RAG category detection.
# The actual merge (in normal mode) happens in the combined Pass 3+4 curl call below.
SYNTH_FINDINGS=$(mktemp -t "pr-${PR_NUMBER}-findings.XXXXXX")
cp "$CLAUDE_OUT" "$SYNTH_FINDINGS"

# ============================================================
# STEP 4.5: CROSS-VERIFICATION PASS (kill false positives)
# For each finding, Haiku verifies against diff context + RAG + learned patterns.
# Drops FALSE_POSITIVE findings. Tags LIKELY findings with lower confidence.
# ALWAYS runs on re-reviews — incremental diffs have HIGHER hallucination rates
# and need the false-positive filter MORE than full diffs do.
# ============================================================
if [ "$FAST_MODE" != "true" ]; then
  spinner_start "Verifying findings (reducing false positives)..."

  VERIFY_PROMPT=$(mktemp -t "pr-${PR_NUMBER}-verify.XXXXXX")
  VERIFY_OUT=$(mktemp -t "pr-${PR_NUMBER}-verify-out.XXXXXX")

  # Extract JSON findings from Claude output (or parse FINDING blocks)
  _FINDINGS_JSON=""
  _json_block=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
  if [ -n "$_json_block" ] && echo "$_json_block" | jq -e '.findings' >/dev/null 2>&1; then
    _FINDINGS_JSON="$_json_block"
  fi

  if [ -n "$_FINDINGS_JSON" ]; then
    _FINDING_COUNT=$(echo "$_FINDINGS_JSON" | jq '.findings | length')

    if [ "$_FINDING_COUNT" -gt 0 ]; then
      # Short-circuit: skip verification for low-finding, non-blocking reviews
      _has_blocking=$(echo "$_FINDINGS_JSON" | jq '[.findings[] | select(.severity == "BLOCKING")] | length' 2>/dev/null || echo "0")
      if [ "$_FINDING_COUNT" -le 3 ] && [ "${_has_blocking:-0}" -eq 0 ]; then
        spinner_stop "Low-risk review (${_FINDING_COUNT} findings, no blockers) — verification skipped"
      else
      # Build verification prompt with all findings + context
      {
        cat << 'VERIFY_SYS'
You are a code review verifier. For each finding below, determine if it is a real issue or a false positive.

For each finding, you receive:
- The finding details (file, line, severity, body)
- The actual diff context around the flagged line
- Learned false positive patterns from past reviews

Your job: classify each finding as VALID, LIKELY, or FALSE_POSITIVE.
- VALID (confidence 0.85-1.0): Clear evidence in the diff/context confirms the issue
- LIKELY (confidence 0.5-0.84): Plausible but cannot fully confirm from available context
- FALSE_POSITIVE (confidence 0.0-0.49): The concern is unfounded, already handled, or out of scope

Output valid JSON only:
```json
{
  "verifications": [
    {"index": 0, "verdict": "VALID", "confidence": 0.92, "reason": "one line reason"},
    {"index": 1, "verdict": "FALSE_POSITIVE", "confidence": 0.15, "reason": "the guard already handles this case at line 42"}
  ]
}
```
VERIFY_SYS

        echo ""
        echo "## FINDINGS TO VERIFY"
        echo "$_FINDINGS_JSON" | jq -r '
          .findings | to_entries[] |
          "### Finding \(.key): \(.value.file):\(.value.line) [\(.value.severity)]
\(.value.title // .value.body)
Evidence: \(.value.evidence // "none")
"
        '

        echo ""
        echo "## DIFF CONTEXT (around flagged lines)"
        # For each finding, extract ±20 lines from the diff
        echo "$_FINDINGS_JSON" | jq -r '.findings[].file' | sort -u | while read -r _vf; do
          [ -z "$_vf" ] && continue
          echo "### $_vf"
          awk -v f="$_vf" '
            /^diff --git/ { in_file = 0 }
            /^diff --git a\// {
              split($0, parts, " b/")
              if (parts[2] == f) in_file = 1
            }
            in_file { print }
      END { if (pending && hold != "") {} }
          ' "$DIFF_FILE" 2>/dev/null | head -200
          echo ""
        done

        # Include learned patterns for context
        _lp_file="$HOME/.diffhound/learned-patterns.jsonl"
        if [ -f "$_lp_file" ] && [ -s "$_lp_file" ]; then
          echo ""
          echo "## LEARNED FALSE POSITIVE PATTERNS (from past reviews)"
          jq -r '.lesson' "$_lp_file" 2>/dev/null | sort -u | head -20 | while read -r _lesson; do
            echo "- $_lesson"
          done
        fi
      } > "$VERIFY_PROMPT"

      # Call Haiku for verification (cheap + fast)
      _verify_resp=""
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        _vj_tmp=$(mktemp -t "pr-${PR_NUMBER}-vj.XXXXXX")
        jq -n --rawfile prompt "$VERIFY_PROMPT" '{
          model: "claude-sonnet-4-6",
          max_tokens: 2048,
          messages: [{role: "user", content: $prompt}]
        }' > "$_vj_tmp"

        _verify_resp=$($_TIMEOUT_CMD 60 curl -sf https://api.anthropic.com/v1/messages           -H "x-api-key: ${ANTHROPIC_API_KEY}"           -H "anthropic-version: 2023-06-01"           -H "content-type: application/json"           -d @"$_vj_tmp" 2>/dev/null || echo "")
        rm -f "$_vj_tmp"
        _verify_resp=$(echo "$_verify_resp" | jq -r '.content[0].text // empty' 2>/dev/null || true)
      fi

      # Fallback: direct API call
      if [ -z "$_verify_resp" ]; then
        _verify_resp=$(_call_api "claude-sonnet-4-6" 2048 60 < "$VERIFY_PROMPT" 2>/dev/null || true)
      fi

      # Parse verification results and filter findings
      if [ -n "$_verify_resp" ]; then
        _verify_json=$(echo "$_verify_resp" | sed -n '/^```json/,/^```/{/^```/d;p;}' 2>/dev/null || echo "$_verify_resp")

        if echo "$_verify_json" | jq -e '.verifications' >/dev/null 2>&1; then
          _dropped=0; _downgraded=0

          # Build filtered findings JSON
          _filtered_json=$(echo "$_FINDINGS_JSON" | jq --argjson verifications "$(echo "$_verify_json" | jq '.verifications')" '
            # Filter findings based on verification results
            .findings = [
              .findings | to_entries[] |
              . as $entry |
              # If no verification for this index, keep as-is (safe default)
              ([$verifications[] | select(.index == $entry.key)] | first // {verdict: "VALID", confidence: 0.7}) as $v |
              if $v.verdict == "FALSE_POSITIVE" then
                empty
              elif $v.verdict == "LIKELY" then
                $entry.value + {confidence: ($v.confidence // 0.6)}
              else
                $entry.value + {confidence: ($v.confidence // 0.9)}
              end
            ] |
            # Recalculate verdict based on remaining findings
            if [.findings[] | select(.severity == "BLOCKING")] | length > 0 then
              .verdict = "REQUEST_CHANGES"
            elif [.findings[] | select(.severity == "SHOULD-FIX")] | length > 0 then
              .verdict = "COMMENT"
            else
              .verdict = "APPROVE"
            end
          ' 2>/dev/null || echo "")

          if [ -n "$_filtered_json" ] && echo "$_filtered_json" | jq -e '.findings' >/dev/null 2>&1; then
            _dropped=$(echo "$_verify_json" | jq '[.verifications[] | select(.verdict == "FALSE_POSITIVE")] | length' 2>/dev/null || echo "0")
            _downgraded=$(echo "$_verify_json" | jq '[.verifications[] | select(.verdict == "LIKELY")] | length' 2>/dev/null || echo "0")

            # Update CLAUDE_OUT with filtered findings
            # Rebuild the output as JSON-fenced block
            {
              echo '```json'
              echo "$_filtered_json"
              echo '```'
            } > "$CLAUDE_OUT"

            spinner_stop "Verified: ${_dropped} false positives dropped, ${_downgraded} downgraded"
          else
            spinner_stop "Verification parse failed — using unfiltered findings"
          fi
        else
          spinner_stop "Verification output invalid — using unfiltered findings"
        fi
      else
        spinner_stop "Verification call failed — using unfiltered findings"
      fi
    fi  # end short-circuit check
    else
      spinner_stop "No findings to verify"
    fi
  else
    spinner_stop "Non-JSON output — verification skipped (will use regex fallback)"
  fi

  rm -f "$VERIFY_PROMPT" "$VERIFY_OUT" 2>/dev/null || true
fi

# ============================================================
# STEP 4.7: MECHANICAL VERIFICATION (grep/test to drop false positives)
# ============================================================
# After LLM outputs findings, before posting, verify claims against the repo.
# Only DROP findings that are clearly contradicted by grep/test. If uncertain, KEEP.
if [ -s "$CLAUDE_OUT" ]; then
  _json_for_verify=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
  if [ -n "$_json_for_verify" ] && echo "$_json_for_verify" | jq -e '.findings' >/dev/null 2>&1; then
    _finding_count=$(echo "$_json_for_verify" | jq '.findings | length')
    if [ "$_finding_count" -gt 0 ]; then
      spinner_start "Mechanical verification (${_finding_count} findings)..."
      _dropped=0
      _verified_json="$_json_for_verify"

      # Build list of findings to drop (indices, 0-based)
      _drop_indices=""
      for (( _fi=0; _fi<_finding_count; _fi++ )); do
        _f_body=$(echo "$_json_for_verify" | jq -r ".findings[$_fi].body // \"\"")
        _f_title=$(echo "$_json_for_verify" | jq -r ".findings[$_fi].title // \"\"")
        _f_file=$(echo "$_json_for_verify" | jq -r ".findings[$_fi].file // \"\"")
        _f_line=$(echo "$_json_for_verify" | jq -r ".findings[$_fi].line // 0")
        _combined="${_f_title} ${_f_body}"
        _should_drop=false

        # Check 1: "function X never called" / "X is unused" / "X is not called"
        _unused_func=$(echo "$_combined" | grep -oiE '(function|method|const)\s+`?([a-zA-Z_][a-zA-Z0-9_]*)`?\s+(is\s+)?(never\s+called|unused|not\s+called|not\s+used|dead\s+code)' | \
          grep -oE '`?[a-zA-Z_][a-zA-Z0-9_]*`?' | head -1 | tr -d '`' || true)
        if [ -n "$_unused_func" ]; then
          _grep_result=$(cd "$REPO_PATH" && grep -r --include="*.ts" --include="*.js" --include="*.tsx" --include="*.vue" \
            "$_unused_func" . 2>/dev/null | grep -v "function ${_unused_func}\|const ${_unused_func}\|export.*function.*${_unused_func}\|\/\/" | head -1 || true)
          if [ -n "$_grep_result" ]; then
            _should_drop=true
          fi
        fi

        # Check 2: "file X doesn't exist" / "missing file X"
        _missing_file=$(echo "$_combined" | grep -oiE "(file|module)\s+\`?([a-zA-Z0-9_./-]+\.(ts|js|vue|py))\`?\s+(does\s?n.t\s+exist|is\s+missing|not\s+found)" | \
          grep -oE '`?[a-zA-Z0-9_./-]+\.(ts|js|vue|py)`?' | head -1 | tr -d '`' || true)
        if [ -n "$_missing_file" ]; then
          if [ -f "${REPO_PATH}/${_missing_file}" ]; then
            _should_drop=true
          fi
        fi

        # Check 3: "missing import for Y" — check if import actually exists
        _missing_import=$(echo "$_combined" | grep -oiE "missing\s+import\s+(for\s+)?\`?([a-zA-Z_][a-zA-Z0-9_]*)\`?" | \
          grep -oE '`?[a-zA-Z_][a-zA-Z0-9_]*`?$' | tr -d '`' || true)
        if [ -n "$_missing_import" ] && [ -n "$_f_file" ] && [ -f "${REPO_PATH}/${_f_file}" ]; then
          _imp_check=$(grep -E "import.*${_missing_import}" "${REPO_PATH}/${_f_file}" 2>/dev/null | head -1 || true)
          if [ -n "$_imp_check" ]; then
            _should_drop=true
          fi
        fi

        # Check 4: Line number validity — if line doesn't exist in file, drop
        if [ -n "$_f_file" ] && [ "$_f_line" -gt 0 ] 2>/dev/null && [ -f "${REPO_PATH}/${_f_file}" ]; then
          _line_content=$(sed -n "${_f_line}p" "${REPO_PATH}/${_f_file}" 2>/dev/null || true)
          _file_lines=$(wc -l < "${REPO_PATH}/${_f_file}" 2>/dev/null | tr -d ' ')
          if [ "$_f_line" -gt "$_file_lines" ] 2>/dev/null; then
            _should_drop=true
          fi
        fi

        if [ "$_should_drop" = true ]; then
          _drop_indices="${_drop_indices} ${_fi}"
          _dropped=$((_dropped + 1))
        fi
      done

      # Apply drops by filtering findings array
      if [ "$_dropped" -gt 0 ]; then
        _jq_filter="[.findings | to_entries[] | select("
        _first=true
        for _di in $_drop_indices; do
          if [ "$_first" = true ]; then
            _jq_filter+=".key != ${_di}"
            _first=false
          else
            _jq_filter+=" and .key != ${_di}"
          fi
        done
        _jq_filter+=") | .value]"

        _filtered_json=$(echo "$_json_for_verify" | jq --argjson drops "$(echo "$_drop_indices" | tr ' ' '\n' | grep -v '^$' | jq -R 'tonumber' | jq -s '.')" \
          '.findings = [.findings | to_entries[] | select(.key as $k | $drops | index($k) | not) | .value]')

        if [ -n "$_filtered_json" ] && echo "$_filtered_json" | jq -e '.' >/dev/null 2>&1; then
          # Rewrite CLAUDE_OUT with filtered JSON
          _before_json=$(sed -n '1,/^```json/p' "$CLAUDE_OUT")
          _after_json=$(sed -n '/^```$/,$p' "$CLAUDE_OUT" | tail -n +1)
          {
            echo "$_before_json"
            echo "$_filtered_json"
            echo '```'
          } > "${CLAUDE_OUT}.tmp" && mv "${CLAUDE_OUT}.tmp" "$CLAUDE_OUT"
        fi
        spinner_stop "Mechanical verification: dropped ${_dropped} false positive(s)"
      else
        spinner_stop "Mechanical verification: all ${_finding_count} findings confirmed"
      fi
    fi
  fi
fi


# ============================================================
# STEP 5: VOICE RAG — retrieve matching examples by category
# ============================================================
VOICE_JSONL="$HOME/.diffhound/voice-examples.jsonl"
VOICE_EXAMPLES_FILE=$(mktemp -t "pr-${PR_NUMBER}-voice.XXXXXX")

# Dynamic example cap: reduce examples when findings are large to keep Haiku focused
_FINDINGS_TOKEN_EST=0
if [ -s "$CLAUDE_OUT" ]; then
  _FINDINGS_TOKEN_EST=$(wc -c < "$CLAUDE_OUT" | awk '{printf "%d", $1 / 4}')  # ~4 chars per token
fi
if [ "$_RUN_PEER_REVIEW" = true ]; then
  [ -n "${CODEX_CONTENT:-}" ] && [ "$CODEX_CONTENT" != "CODEX_UNAVAILABLE" ] && \
    _FINDINGS_TOKEN_EST=$((_FINDINGS_TOKEN_EST + ${#CODEX_CONTENT} / 4))
  [ -n "${GEMINI_CONTENT:-}" ] && [ "$GEMINI_CONTENT" != "GEMINI_UNAVAILABLE" ] && \
    _FINDINGS_TOKEN_EST=$((_FINDINGS_TOKEN_EST + ${#GEMINI_CONTENT} / 4))
fi
_MAX_EXAMPLES=8
_MAX_PATTERNS=30
if [ "$_FINDINGS_TOKEN_EST" -gt 1500 ]; then
  _MAX_EXAMPLES=4
  _MAX_PATTERNS=10
  echo "  Large findings (~${_FINDINGS_TOKEN_EST} tokens) — capping examples=${_MAX_EXAMPLES}, patterns=${_MAX_PATTERNS}" >&2
fi

if [ -f "$VOICE_JSONL" ] && [ -s "$SYNTH_FINDINGS" ]; then
  echo "## REAL EXAMPLES — STUDY THESE CAREFULLY" >> "$VOICE_EXAMPLES_FILE"
  echo "" >> "$VOICE_EXAMPLES_FILE"
  echo "These are actual comments this engineer has written. Match this voice exactly." >> "$VOICE_EXAMPLES_FILE"
  echo "" >> "$VOICE_EXAMPLES_FILE"

  EXAMPLE_COUNT=0

  # Retrieve up to 2 examples per category using jq (safe JSON parsing, no Python spawn per line).
  # Uses process substitution (<()) to keep the while loop in the main shell scope —
  # avoids the subshell variable-scoping issue without a temp count file.
  # NOTE: grep on the raw JSONL is used purely to pre-filter candidate lines before jq parses them,
  # so we match on category/subcategory field values, not comment body text.
  add_examples_for_pattern() {
    local pattern="$1"
    local label="$2"
    [ "$EXAMPLE_COUNT" -ge "${_MAX_EXAMPLES:-8}" ] && return
    while IFS= read -r line; do
      [ "$EXAMPLE_COUNT" -ge "${_MAX_EXAMPLES:-8}" ] && break
      [ -z "$line" ] && continue
      cat_val=$(echo "$line" | jq -r '.category // ""' 2>/dev/null)
      subcat_val=$(echo "$line" | jq -r '.subcategory // ""' 2>/dev/null)
      comment_val=$(echo "$line" | jq -r '.comment // ""' 2>/dev/null)
      if [ -n "$comment_val" ]; then
        echo "---" >> "$VOICE_EXAMPLES_FILE"
        echo "EXAMPLE — ${label} (${cat_val}/${subcat_val}):" >> "$VOICE_EXAMPLES_FILE"
        echo "\"${comment_val}\"" >> "$VOICE_EXAMPLES_FILE"
        echo "" >> "$VOICE_EXAMPLES_FILE"
        EXAMPLE_COUNT=$((EXAMPLE_COUNT + 1))
      fi
    done < <(jq -c --arg pat "$pattern" 'select(.category | test($pat; "i") or .subcategory | test($pat; "i"))' "$VOICE_JSONL" 2>/dev/null | head -2)
  }

  # Priority order: security first, then data bugs, then URL/construction, then consistency, then nits
  add_examples_for_pattern "security" "security blocker"
  add_examples_for_pattern "data.bug|wrong.column|prod" "data bug"
  add_examples_for_pattern "url.construct|double.frag|param.collis" "URL construction"
  add_examples_for_pattern "consist|sibling" "consistency"
  add_examples_for_pattern "pattern.propag|lateral" "pattern propagation"
  add_examples_for_pattern "intent.check|assuming" "intent check"
  add_examples_for_pattern "test.gap|mock" "test gap"
  add_examples_for_pattern "nit|retract|self.retract" "nit/retraction"
  add_examples_for_pattern "re.review|still.open|author.wrong" "re-review"

  # Fallback: if no examples matched (empty findings or no JSONL hits), embed canonical examples inline
  if [ "$EXAMPLE_COUNT" -eq 0 ]; then
    cat >> "$VOICE_EXAMPLES_FILE" << 'FALLBACK_EXAMPLES'
---
EXAMPLE — security blocker:
"this is the user's full session token right? same one used in `validateToken` at line 206. passing it to an external embed means that app gets full user-level access to our API, not just the scoped endpoints.

couple of options:
1. generate a short-lived scoped token on backend specifically for embed operations (best option, most work)
2. at minimum, validate that `embedUrl` is a known/whitelisted URL before appending the token
3. if neither is feasible rn, add a comment explaining the trust assumption and create a follow-up ticket for scoped tokens

lmk what u think, happy to discuss"

---
EXAMPLE — data bug (blocking):
"`records.end_date` is NULL for every record in prod. expiry lives in `records.meta->>'endDate'` (JSONB) — that's what `types/record.ts:559` and the portal's `isActive()` both use. filter as written will silently exclude every item after deploy.

also — the test mock doesn't have `innerJoin` in `mockQueryChain`, so existing tests pass but none validate that expired records are actually excluded."

---
EXAMPLE — consistency nit:
"`user` object also has `firstName` and `lastName` (line 197 uses `displayName`). for consistency, might want to apply the same pattern there too"

FALLBACK_EXAMPLES
  fi

  echo "---" >> "$VOICE_EXAMPLES_FILE"
  VOICE_EXAMPLES_CONTENT=$(cat "$VOICE_EXAMPLES_FILE")
else
  # JSONL not available — use canonical fallback
  VOICE_EXAMPLES_CONTENT=$(cat << 'CANONICAL_FALLBACK'
## REAL EXAMPLES — STUDY THESE CAREFULLY

These are actual comments this engineer has written. Match this voice exactly.

---
EXAMPLE A — security blocker (large blast radius):
"this is the user's full session token right? same one used in `validateToken` at line 206. passing it to an external embed means that app gets full user-level access to our API, not just the scoped endpoints.

couple of options:
1. generate a short-lived scoped token on backend specifically for embed operations (best option, most work)
2. at minimum, validate that `embedUrl` is a known/whitelisted URL before appending the token — so a random URL in config can't harvest tokens
3. if neither is feasible rn, add a comment explaining the trust assumption and create a follow-up ticket for scoped tokens

lmk what u think, happy to discuss"

---
EXAMPLE B — subtle bug (URL construction):
"if `customUrl` already contains a hash fragment (like `https://app.example.com/page#sidebar=true`), this would produce a URL with two `#` symbols. browser parses only the first one, so the token appended after the second `#` gets silently ignored — the app won't be able to read it."

---
EXAMPLE C — consistency (sibling field):
"`user` object also has `firstName` and `lastName` (line 197 uses `displayName`). for consistency, might want to apply the same pattern there too"

---
EXAMPLE D — data bug (blocking):
"`records.end_date` is NULL for every record in prod. expiry lives in `records.meta->>'endDate'` (JSONB) — that's what `types/record.ts:559` and the portal's `isActive()` both use. filter as written will silently exclude every item after deploy."

---
EXAMPLE E — should-fix, missing test:
"no unit test covers the headless path that caused the original crash. the exact scenario — bulk upload via CLI with `ctx.user` null — needs a regression test. GWT: given a handler with headless context, when updateExistingClaim is called, then it should not throw TypeError. worth adding before this merges"

---
EXAMPLE F — nit, simplification:
"`(ctx && ctx.user?.isAdmin) || !ctx` can be simplified to `!ctx || ctx.user?.isAdmin`. the `ctx &&` prefix is redundant since `!ctx` already catches the falsy case. functionally identical, just easier to read"

---
CANONICAL_FALLBACK
)
fi


# ── Pre-merge peer findings at script level (avoids overloading Haiku) ──────
_MERGED_FINDINGS_FILE=""
if [ "$_RUN_PEER_REVIEW" = true ]; then
  _MERGED_FINDINGS_FILE=$(mktemp -t "pr-${PR_NUMBER}-merged.XXXXXX")

  # Start with Claude's findings as base
  _claude_merge_json=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
  if [ -n "$_claude_merge_json" ] && echo "$_claude_merge_json" | jq -e '.findings' >/dev/null 2>&1; then
    echo "$_claude_merge_json" | jq '.findings' > "$_MERGED_FINDINGS_FILE"
  else
    echo "[]" > "$_MERGED_FINDINGS_FILE"
  fi

  # Extract structured findings from Codex/Gemini text output
  for _peer_label in CODEX GEMINI; do
    _peer_text=""
    [ "$_peer_label" = "CODEX" ] && _peer_text="$CODEX_CONTENT"
    [ "$_peer_label" = "GEMINI" ] && _peer_text="$GEMINI_CONTENT"
    [ -z "$_peer_text" ] && continue
    [ "$_peer_text" = "CODEX_UNAVAILABLE" ] && continue
    [ "$_peer_text" = "GEMINI_UNAVAILABLE" ] && continue

    # Try extracting JSON findings from peer output
    _peer_json=$(echo "$_peer_text" | sed -n '/```json/,/```/{/```/d;p;}' 2>/dev/null | jq '.findings // []' 2>/dev/null || echo "[]")
    if [ "$_peer_json" != "null" ] && [ "$_peer_json" != "[]" ] && [ -n "$_peer_json" ]; then
      # Merge: append peer findings tagged with source
      _merged=$(jq -s --arg src "$_peer_label" \
        '.[0] + [.[1][] | . + {source: $src}]' \
        "$_MERGED_FINDINGS_FILE" <(echo "$_peer_json") 2>/dev/null || cat "$_MERGED_FINDINGS_FILE")
      echo "$_merged" > "$_MERGED_FINDINGS_FILE"
    fi
  done

  # Deduplicate by file:line proximity (±3 lines = same finding), keep highest severity
  _deduped=$(jq '
    def sev_rank: if . == "BLOCKING" then 3 elif . == "SHOULD-FIX" then 2 elif . == "NIT" then 1 else 0 end;
    group_by(.file) | map(
      sort_by(.line) |
      reduce .[] as $f ([];
        if length == 0 then [$f]
        else
          .[-1] as $last |
          if ($last.file == $f.file) and (($f.line - $last.line) | fabs <= 3) then
            if ($f.severity | sev_rank) > ($last.severity | sev_rank) then
              .[:-1] + [$f]
            else . end
          else . + [$f] end
        end
      )
    ) | flatten
  ' "$_MERGED_FINDINGS_FILE" 2>/dev/null || cat "$_MERGED_FINDINGS_FILE")

  echo "$_deduped" > "$_MERGED_FINDINGS_FILE"

# -- Pattern consolidation: collapse similar findings across different files --
# Runs on pre-rewrite JSON findings. Groups by title similarity (Jaccard >0.7).
if echo "$_deduped" | jq -e 'length > 5' >/dev/null 2>&1; then
  _consolidated=$(echo "$_deduped" | jq '
    def title: (.title // (.body | split(".")[0] // .body[:80]));
    def words: [title | ascii_downcase | split(" ")[] | select(length > 2)];
    def jaccard(a; b):
      if (a | length) == 0 or (b | length) == 0 then 0
      else
        ([a[], b[]] | unique | length) as $union |
        ([a[] as $w | b[] | select(. == $w)] | unique | length) as $inter |
        if $union == 0 then 0 else ($inter / $union) end
      end;
    . as $all |
    reduce range(length) as $i (
      {groups: [], assigned: {}};
      if .assigned[($i | tostring)] then .
      else
        ($all[$i] | words) as $w_i |
        if ($w_i | length) < 5 then
          .groups += [[$i]] | .assigned[($i | tostring)] = true
        else
          ([ range(length) | select(. > $i) |
             select(.assigned[(. | tostring)] | not) |
             select($all[.].file != $all[$i].file) |
             select(jaccard($w_i; $all[.] | words) > 0.7)
          ]) as $matches |
          if ($matches | length) >= 2 then
            .groups += [[$i] + $matches] |
            .assigned[($i | tostring)] = true |
            reduce $matches[] as $m (.; .assigned[($m | tostring)] = true)
          elif ($matches | length) == 1 and jaccard($w_i; $all[$matches[0]] | words) == 1.0 then
            .groups += [[$i] + $matches] |
            .assigned[($i | tostring)] = true |
            .assigned[($matches[0] | tostring)] = true
          else
            .groups += [[$i]] | .assigned[($i | tostring)] = true
          end
        end
      end
    ) |
    [.groups[] |
      if length == 1 then $all[.[0]]
      else
        . as $idxs |
        ($all[$idxs[0]]) * {
          body: (
            ($all[$idxs[0]].body | split("\u001f")[0]) +
            "\u001f\u001fSame pattern in " + ([$idxs[1:][] | $all[.].file + ":" + ($all[.].line | tostring)] | join(", "))
          ),
          severity: (
            [$idxs[] | $all[.].severity |
              if . == "BLOCKING" then 3 elif . == "SHOULD-FIX" then 2 else 1 end
            ] | max |
            if . == 3 then "BLOCKING" elif . == 2 then "SHOULD-FIX" else "NIT" end
          )
        }
      end
    ]
  ' 2>/dev/null)
  if [ -n "$_consolidated" ]; then
    _pre_count=$(echo "$_deduped" | jq 'length' 2>/dev/null || echo "?")
    _post_count=$(echo "$_consolidated" | jq 'length' 2>/dev/null || echo "?")
    if [ "$_pre_count" != "$_post_count" ]; then
      echo "  Pattern consolidation: ${_pre_count} -> ${_post_count} findings (collapsed similar patterns)" >&2
      echo "$_consolidated" > "$_MERGED_FINDINGS_FILE"
    fi
  fi
fi

# -- Same-file topic dedup: merge findings in same file with overlapping topics --
# Catches duplicates like two SSRF comments on doc_ingest.py at different lines.
# Wider tolerance than proximity dedup (+-20 lines) but requires title similarity.
_sf_deduped=$(jq '
  def title: (.title // (.body | split(".")[0] // .body[:80]));
  def words: [title | ascii_downcase | split(" ")[] | select(length > 2)];
  def jaccard(a; b):
    if (a | length) == 0 or (b | length) == 0 then 0
    else
      ([a[], b[]] | unique | length) as $union |
      ([a[] as $w | b[] | select(. == $w)] | unique | length) as $inter |
      if $union == 0 then 0 else ($inter / $union) end
    end;
  group_by(.file) | map(
    if length <= 1 then .
    else
      sort_by(.line) |
      reduce .[] as $f ([];
        if length == 0 then [$f]
        else
          .[-1] as $last |
          if jaccard(($last | words); ($f | words)) > 0.6 then
            # Same file + similar topic = keep the one with higher severity
            if ([$f.severity, $last.severity] | map(if . == "BLOCKING" then 3 elif . == "SHOULD-FIX" then 2 else 1 end) | .[0] > .[1]) then
              .[:-1] + [$f]
            else . end
          else . + [$f] end
        end
      )
    end
  ) | flatten
' "$_MERGED_FINDINGS_FILE" 2>/dev/null || cat "$_MERGED_FINDINGS_FILE")
_sf_pre=$(jq 'length' "$_MERGED_FINDINGS_FILE" 2>/dev/null || echo "?")
_sf_post=$(echo "$_sf_deduped" | jq 'length' 2>/dev/null || echo "?")
if [ "$_sf_pre" != "$_sf_post" ]; then
  echo "  Same-file topic dedup: ${_sf_pre} -> ${_sf_post} findings" >&2
  echo "$_sf_deduped" > "$_MERGED_FINDINGS_FILE"
fi
  _merge_count=$(echo "$_deduped" | jq 'length' 2>/dev/null || echo "?")
  echo "  Pre-merged findings: ${_merge_count} unique (from Claude + peers)" >&2
fi

# ============================================================
# -- PR-scope enforcement: downgrade findings on unchanged code to NIT --
# Parse diff to build set of changed lines (+lines), then check each finding.
# Findings on context lines (unchanged code) are downgraded to NIT unless security/data-corruption.
if [ -f "$_MERGED_FINDINGS_FILE" ] && [ -f "$DIFF_FILE" ]; then
  _changed_lines_set=$(mktemp -t "pr-${PR_NUMBER}-changed-set.XXXXXX")
  awk '
    /^diff --git/ { file="" }
    /^\+\+\+ b\// { file=substr($0,7) }
    /^@@ / {
      s=$0; sub(/.*\+/,"",s); sub(/,.*/,"",s)
      line=int(s)-1
    }
    /^\+/ && file!="" { line++; print file ":" line }
    /^ / && file!="" { line++ }
    /^-/ { next }
  ' "$DIFF_FILE" > "$_changed_lines_set" 2>/dev/null || true

  if [ -s "$_changed_lines_set" ]; then
    _scope_enforced=$(jq --rawfile changed "$_changed_lines_set" '
      ($changed | split("\n") | map(select(length > 0))) as $changed_lines |
      [.[] |
        . as $f |
        (($f.file + ":" + ($f.line | tostring)) as $pos |
          if ($changed_lines | any(. == $pos)) then
            $f  # Changed line: keep severity as-is
          else
            # Unchanged line: downgrade to NIT unless security/data-corruption
            if ($f.body | test("(?i)security|injection|XSS|SSRF|auth|token|secret|password|data.corruption|data.loss|SQL.inject")) then
              $f  # Security exception: keep severity
            elif $f.severity != "NIT" then
              $f + {severity: "NIT", body: ($f.body + " [scope: unchanged code, downgraded to NIT]")}
            else
              $f
            end
          end
        )
      ]
    ' "$_MERGED_FINDINGS_FILE" 2>/dev/null || cat "$_MERGED_FINDINGS_FILE")
    _downgraded=$(echo "$_scope_enforced" | jq '[.[] | select(.body | test("downgraded to NIT"))] | length' 2>/dev/null || echo "0")
    if [ "${_downgraded:-0}" -gt 0 ] 2>/dev/null; then
      echo "  Scope enforcement: ${_downgraded} finding(s) on unchanged code downgraded to NIT" >&2
      echo "$_scope_enforced" > "$_MERGED_FINDINGS_FILE"
    fi
  fi
  rm -f "$_changed_lines_set"
fi

# # STEP 6: MERGE + STYLE REWRITE — single cached Haiku call
# Combines old Pass 3 (merge) + Pass 4 (style) into one API call.
# Static system prompt is cached via prompt-caching-2024-07-31 beta.
# ============================================================
_STYLE_PASS_NUM="${_TOTAL_PASSES}"
spinner_start "Writing review comments (pass ${_STYLE_PASS_NUM}/${_TOTAL_PASSES})..."

# ── Static system prompt (cached between calls — voice rules + output format) ─
read -r -d '' _STATIC_SYSTEM << 'STATIC_SYS_EOF' || true
You are a ghostwriter. You have engineering findings from a code analysis. Your job is to rewrite them as PR review comments that sound exactly like a specific engineer.

## WHO YOU ARE WRITING AS

This engineer is a senior developer reviewing a teammate's PR. Comments are developer-to-developer. Direct, casual, sharp. The author is a colleague, not a subordinate.

## VOICE RULES

ALWAYS:
- All lowercase body text. Code identifiers keep their original casing (`markTokenAsUsed`, `orgId`, etc).
- First-person framing: "my concern is —", "i want us to think about...", "assuming thats intentional —"
- Confirm reading before asserting: "this is the full login token right?" — shows you understood their code
- Reveal reasoning as you go — don't just state conclusions
- For blockers with tradeoffs: numbered options (1/2/3), acknowledge feasibility ("if not feasible rn...")
- End security/data blockers with "lmk what u think" or "happy to pair on this"
- Natural casual markers — but ONLY where they fit: "rn", "lmk", "thats", "its", "right?", "u can"
- For subtle bugs: dive straight into the observation — no formulaic opener
- For missed patterns: "same pattern you've done here in X" — reference where they did it right

NEVER — SEVERITY LABELS IN COMMENT BODY (THIS IS THE #1 MISTAKE):
- NEVER start a comment with "BLOCKING —", "BLOCKER —", "SHOULD-FIX —", "NIT —", or any severity word
- The severity word lives ONLY in the COMMENT: metadata tag (e.g., COMMENT: file.ts:10:BLOCKING — ...)
- The comment BODY starts directly with the observation — no label, no prefix, no badge
- Wrong: "BLOCKING — the guard here is too broad..."
- Wrong: "NIT — this could be simplified..."
- Right: "the guard here is too broad..."
- Right: "this could be simplified..."

NEVER — OTHER:
- "Why:", "Fix:", "Impact:" as explicit labels
- Capital letters at start of sentences (except "I" as a pronoun — but prefer lowercase alternatives)
- "leverage", "utilize", "ensure", "it is worth noting", "I'd recommend", "please consider", "going forward"
- Force "lmk" or "right?" onto every comment — only where they read naturally
- Numbered options on simple 1-fix comments
- "lmk" on a NIT — only on blockers with genuine discussion needed
- Mention AI, automated review, Claude, Codex, Gemini anywhere
- **markdown bold** or *italic* in comment body — GitHub renders it but it looks unnatural in casual dev voice. Plain text only.
- "one suggestion —", "small thing —", "one more thing —", "typo:", or any formulaic opener — dive straight into the observation
- Long run-on sentences — if a comment exceeds 4 lines, break it into short punchy paragraphs

HOW TO OPEN EACH SEVERITY — the key rule is: start with the SUBSTANCE, not a label announcing what type of problem it is. No emoji prefixes, no visual flags — dive straight into the observation.

- BLOCKING security/data bug → "[the actual observation directly]"
  WRONG: "security concern — the guard is too broad"  ← "security concern" is a label, not substance
  WRONG: "wrong column — `benefits.end_date` is NULL"  ← "wrong column" is a label
  RIGHT: "the `|| !ctx.user` check makes this fail-open. if ctx exists but user is null..."
  RIGHT: "`benefits.end_date` is NULL for every benefit in prod. policy expiry lives in..."
  RIGHT: "this is the user's full login token right? passing it to an external retool embed..."
- BLOCKING scope/arch issue → "this feels unrelated to [PR title] — [explain the risk]"
- SHOULD-FIX → dive straight in, no opener at all
  e.g. "no unit test covers the headless path that caused the crash..."
  e.g. "the `ctx.user` null case falls through here — this whole block evaluates to false..."
- NIT → dive straight in, same as should-fix. no formulaic opener.
  e.g. "\`(ctx && ctx.user?.isAdmin) || !ctx\` can be simplified to \`!ctx || ctx.user?.isAdmin\`..."

CALIBRATE depth to blast radius:
- Big security/data bug → long comment, explain the attack path, give options, invite discussion
- Consistency nit → 1-2 sentences max, no fanfare
- Subtle bug → medium, explain the edge case naturally as you reason through it
- Unclear intent → short, non-accusatory, assume good intent ("assuming thats intentional —")

## REVIEW BODY STYLE

Opening: state the main blocker or overall verdict immediately. No "overall this looks good" fluff unless it's true.
Closing: one line genuine observation if warranted ("the approach is solid, just needs these fixed before merge")

**MANDATORY SEVERITY GROUPING:** The review body MUST group findings by severity with clear headers.
Use this structure (omit empty sections):

### Blockers (must fix before merge)
- `file.ts:LINE` — [what breaks]
- `file.ts:LINE` — [what breaks]

### Should-Fix (merge ok, follow-up needed)
- `file.ts:LINE` — [issue]

### Nits
- `file.ts:LINE` — [suggestion]

This makes it scannable in 5 seconds. Blockers jump out. Nits don't pollute the signal.

## YOUR OUTPUT

### INLINE_COMMENTS_START
COMMENT: path/to/file.ts:LINE:SEVERITY — [full comment in engineer's voice, multi-line ok]
(preserve exact file paths and line numbers from findings verbatim — do NOT change or approximate line numbers)
REPLY: COMMENT_ID:path/to/file.ts:LINE — [reply to existing thread, if re-review]
### INLINE_COMMENTS_END

### SUMMARY_START
[if fresh review: opening verdict, then MANDATORY severity-grouped sections:]

### Blockers (must fix before merge)
- `file.ts:LINE` — [what breaks]

### Should-Fix (merge ok, follow-up needed)
- `file.ts:LINE` — [issue]

### Nits
- `file.ts:LINE` — [suggestion]

[omit empty sections. brief genuine close if warranted.]

[if re-review: open with thread resolution status (X addressed, Y still open), then any new findings grouped by severity as above]

## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| Security (25%) | X/25 | ... |
| Tests (20%) | X/20 | ... |
| Observability (10%) | X/10 | ... |
| Performance (15%) | X/15 | ... |
| Readability (15%) | X/15 | ... |
| Compatibility (15%) | X/15 | ... |
| **Total** | **X/100** | **VERDICT** (any BLOCKING → REQUEST_CHANGES, SHOULD-FIX only → COMMENT, NITs/clean → APPROVE) |

## Verification & Test Checklist
- [ ] [exact command or step]
### SUMMARY_END

NO VERIFICATION REQUESTS: Never output a comment asking the author to "verify", "check", "confirm", or "make sure" something. Either state it as fact (if determinable from the diff) or drop the comment entirely. The author already knows to verify uncertain things — your job is to tell them things they don't know.

CRITICAL: Never mention AI, Claude, Codex, Gemini, or any automated tool. The review must read as if written by the engineer themselves.
STATIC_SYS_EOF

# ── Dynamic user message (findings + examples — not cached) ───────────────────
_USER_TMP=$(mktemp -t "pr-${PR_NUMBER}-user.XXXXXX")

_SEVERITY_RULE="CRITICAL RULE — READ FIRST: Never start a comment body with a severity label or emoji flag. The word BLOCKING, BLOCKER, SHOULD-FIX, or NIT must NEVER appear at the start of a comment body. It belongs only in the COMMENT: metadata tag. No emoji prefixes either. For ALL severities: dive straight into the observation. No formulaic opener, no visual flag."

if [ "$_RUN_PEER_REVIEW" = true ]; then
  _MERGE_INSTRUCTION="Here are pre-merged engineering findings (already deduplicated across models). Your ONLY job is to rewrite each finding as a COMMENT: line in the engineer's voice. Do NOT merge, synthesize, or analyze — just rewrite the voice.

${_SEVERITY_RULE}"
else
  _MERGE_INSTRUCTION="Here is one engineering analysis. Rewrite it in the engineer's voice using the rules above.

${_SEVERITY_RULE}"
fi

{
  echo "$_MERGE_INSTRUCTION"
  echo ""
  echo "$VOICE_EXAMPLES_CONTENT"

  # ── Inject learned patterns (false positive lessons) ──
  _learned_patterns_file="$HOME/.diffhound/learned-patterns.jsonl"
  if [ -f "$_learned_patterns_file" ] && [ -s "$_learned_patterns_file" ]; then
    _pattern_lines=$(jq -r '.lesson' "$_learned_patterns_file" 2>/dev/null | sort -u | head -"${_MAX_PATTERNS:-30}")
    if [ -n "$_pattern_lines" ]; then
      echo ""
      echo "## LEARNED PATTERNS — DO NOT REPEAT THESE MISTAKES"
      while IFS= read -r _pl; do
        [ -z "$_pl" ] && continue
        echo "- $_pl"
      done <<< "$_pattern_lines"
      echo ""
    fi
  fi
  echo ""
  echo "## ENGINEERING FINDINGS (Claude)"
  # If validators dropped all findings to 0, pass only the summary prose.
  # Do NOT cat the full CLAUDE_OUT — the LLM would hallucinate COMMENT: lines
  # from the prose text with invalid line numbers, producing comments that GitHub
  # rejects. With 0 validated findings there is nothing to post inline.
  if [ "${_VALIDATOR_FINDING_COUNT:-1}" = "0" ] && [ -z "${_RUN_PEER_REVIEW:-}" ]; then
    echo "(all findings were dropped by validators — 0 inline comments to post)"
    echo "DO NOT produce any COMMENT: lines. Produce only the ### SUMMARY_START block."
  else
    cat "$CLAUDE_OUT"
  fi

  if [ "$_RUN_PEER_REVIEW" = true ] && [ -n "${_MERGED_FINDINGS_FILE:-}" ] && [ -s "${_MERGED_FINDINGS_FILE:-/dev/null}" ]; then
    # Use pre-merged findings instead of raw peer outputs (smaller input for Haiku)
    echo ""
    echo "## ALL FINDINGS (pre-merged from Claude + Codex + Gemini)"
    echo "These findings are already deduplicated and severity-escalated. Rewrite each as a COMMENT: line."
    echo '```json'
    jq '.' "$_MERGED_FINDINGS_FILE" 2>/dev/null || cat "$_MERGED_FINDINGS_FILE"
    echo '```'
  elif [ "$_RUN_PEER_REVIEW" = true ]; then
    # Fallback: raw peer outputs if merge failed
    if [ -n "$CODEX_CONTENT" ] && [ "$CODEX_CONTENT" != "CODEX_UNAVAILABLE" ]; then
      echo ""
      echo "## CODEX FINDINGS"
      echo "$CODEX_CONTENT"
    fi
    if [ -n "$GEMINI_CONTENT" ] && [ "$GEMINI_CONTENT" != "GEMINI_UNAVAILABLE" ]; then
      echo ""
      echo "## GEMINI FINDINGS"
      echo "$GEMINI_CONTENT"
    fi
  fi

  echo ""
  echo "## PR CONTEXT"
  echo "Title: ${PR_TITLE}"
  echo "Author: @${PR_AUTHOR}"
  echo "Files changed: ${FILE_COUNT} (+${ADDITIONS}/-${DELETIONS})"
  echo "Re-review mode: ${IS_REREVIEW}"

  if [ "$IS_REREVIEW" = true ]; then
    echo ""
    echo "## EXISTING THREAD STATUSES (from engineering pass)"
    grep -A6 "^THREAD_STATUS:" "$CLAUDE_OUT" 2>/dev/null || echo "none"
    echo ""
    cat << 'REREVIEW_BLOCK'
## HOW TO HANDLE THREAD REPLIES

DEFAULT IS SILENCE. Only post a reply when you have substantive new information.

- If RESOLVED: NO reply. Auto-resolve handles it silently. Do NOT post "verified", "looks good", "addressed", "thanks", or any acknowledgement. Silence = resolved.
- If RESOLVED_BY_EXPLANATION: NO reply. The author's explanation was sufficient. Move on.
- If NO_RESPONSE but code is fixed: NO reply. Auto-resolve handles it.
- If STILL_OPEN and the concern genuinely persists: ONE reply with evidence. "the concern is still there — [specific diff evidence]. [what still needs to happen]"
- If AUTHOR_WRONG with technical counter-evidence: ONE reply. "actually [explanation with diff evidence]."

REPLY BUDGET: Maximum 2 thread replies per re-review. If more than 2 threads are still open, pick the highest-severity ones.

For THREAD_REPLY comments: REPLY: ORIGINAL_COMMENT_ID:path/to/file.ts:LINE — [reply in engineer's voice]

ANTI-CHATTER RULE: Before writing any reply, ask: "Does this reply contain information the author doesn't already have?" If no — don't write it. The review thread is not a chat.
REREVIEW_BLOCK
  fi

  echo ""
  echo "## OUTPUT FORMAT REMINDER (CRITICAL — follow this exactly)"
  echo "You MUST output in this exact structured format. Do NOT output free text analysis."
  echo "### INLINE_COMMENTS_START"
  echo "COMMENT: path/file.ts:LINE:SEVERITY — [comment body in engineer voice]"
  echo "(one COMMENT: line per finding — do NOT skip any)"
  echo "### INLINE_COMMENTS_END"
  echo "### SUMMARY_START"
  echo "[review body with scorecard table]"
  echo "### SUMMARY_END"
  echo ""
  echo "If you output anything other than this format, the review will FAIL. Every finding MUST become a COMMENT: line."

} > "$_USER_TMP"

# ── Call API with prompt caching (only if API key has credits, else claude CLI) ─
# Test API key validity with a minimal call before committing to the full request.
_API_CALLED=false
_KEY_HAS_CREDITS=false
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  _TEST_RESP=$(curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-sonnet-4-6","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
    2>/dev/null || echo "")
  if echo "$_TEST_RESP" | grep -q '"type":"message"'; then
    _KEY_HAS_CREDITS=true
  fi
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  _JSON_TMP=$(mktemp -t "pr-${PR_NUMBER}-json.XXXXXX")
  jq -n \
    --arg system "$_STATIC_SYSTEM" \
    --rawfile user "$_USER_TMP" \
    '{
      model: "claude-sonnet-4-6",
      max_tokens: 16384,
      system: [{type: "text", text: $system, cache_control: {type: "ephemeral"}}],
      messages: [{role: "user", content: $user}]
    }' > "$_JSON_TMP"

  _API_RESP=$($_TIMEOUT_CMD 120 curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d @"$_JSON_TMP" 2>/dev/null || echo "")
  rm -f "$_JSON_TMP"

  _REVIEW_TEXT=$(echo "$_API_RESP" | jq -r '.content[0].text // empty' 2>/dev/null || echo "")
  if [ -n "$_REVIEW_TEXT" ]; then
    echo "$_REVIEW_TEXT" > "$REVIEW_STRUCTURED"
    _API_CALLED=true
  fi
fi

if [ "$_API_CALLED" = false ]; then
  # Fallback: direct API call with system prompt
  _SYS_TMP=$(mktemp -t "pr-${PR_NUMBER}-sys.XXXXXX")
  printf '%s' "$_STATIC_SYSTEM" > "$_SYS_TMP"
  _call_api_system "claude-sonnet-4-6" 16384 120 "$_SYS_TMP" < "$_USER_TMP" > "$REVIEW_STRUCTURED" 2>&1 || \
    cp "$CLAUDE_OUT" "$REVIEW_STRUCTURED"
  rm -f "$_SYS_TMP"
fi

rm -f "$_USER_TMP"

[ "$FAST_MODE" = "true" ] \
  && spinner_stop "Fast review complete" \
  || spinner_stop "Pass ${_STYLE_PASS_NUM} complete — review ready"

# Cleanup extra temp files
rm -f "${SYNTH_FINDINGS:-}" "${VOICE_EXAMPLES_FILE:-}" "${_MERGED_FINDINGS_FILE:-}" 2>/dev/null || true

# ============================================================
# PARSE OUTPUT
# ============================================================
parse_comments "$REVIEW_STRUCTURED" "${REVIEW_STRUCTURED}.comments"
parse_summary "$REVIEW_STRUCTURED" "$REVIEW_SUMMARY"

# Fallback: if voice rewrite produced 0 comments but Claude's JSON has findings,
# use Claude's output directly. This catches cases where Haiku outputs free text
# instead of the structured COMMENT: format (seen on PRs #42, #45, #46).
_voice_comment_count=$(grep -c "^COMMENT:" "${REVIEW_STRUCTURED}.comments" 2>/dev/null | head -1 || true)
_voice_comment_count=$(echo "${_voice_comment_count:-0}" | tr -d '[:space:]')
_voice_comment_count=${_voice_comment_count:-0}
if [ "$_voice_comment_count" -eq 0 ] 2>/dev/null; then
  _recovered=false

  # Recovery path 1: JSON format (monolithic reviews)
  _claude_json=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
  if [ -z "$_claude_json" ]; then
    _claude_json=$(jq '.' "$CLAUDE_OUT" 2>/dev/null || true)
  fi
  _claude_findings=$(echo "$_claude_json" | jq '.findings | length' 2>/dev/null || echo "0")
  _claude_findings=$(echo "${_claude_findings:-0}" | tr -d '[:space:]')
  if [ "${_claude_findings:-0}" -gt 0 ] 2>/dev/null; then
    echo "  Voice rewrite lost findings — falling back to Claude's JSON output" >&2
    if ! grep -q '^```json' "$CLAUDE_OUT" 2>/dev/null; then
      _fenced_tmp=$(mktemp -t "pr-${PR_NUMBER}-fenced.XXXXXX")
      { echo '```json'; echo "$_claude_json"; echo '```'; } > "$_fenced_tmp"
      parse_comments "$_fenced_tmp" "${REVIEW_STRUCTURED}.comments"
      parse_summary "$_fenced_tmp" "$REVIEW_SUMMARY"
      rm -f "$_fenced_tmp"
    else
      parse_comments "$CLAUDE_OUT" "${REVIEW_STRUCTURED}.comments"
      parse_summary "$CLAUDE_OUT" "$REVIEW_SUMMARY"
    fi
    _recovered=true
  fi

  # Recovery path 2: FINDINGS_START format (chunked/merged reviews)
  if [ "$_recovered" = false ] && grep -q "^FINDING:" "$CLAUDE_OUT" 2>/dev/null; then
    _finding_count=$(grep -c "^FINDING:" "$CLAUDE_OUT" 2>/dev/null | head -1 || true)
    _finding_count=$(echo "${_finding_count:-0}" | tr -d '[:space:]')
    if [ "${_finding_count:-0}" -gt 0 ] 2>/dev/null; then
      echo "  Voice rewrite lost findings — falling back to merged FINDING: format (${_finding_count} findings)" >&2
      # Convert FINDING: lines to COMMENT: format for the posting pipeline
      # FINDING format: FINDING: file:LINE:SEVERITY\nWHAT: ...\nEVIDENCE: ...\nIMPACT: ...\nOPTIONS: ...
      {
        _current_finding=""
        _current_body=""
        while IFS= read -r _fline; do
          case "$_fline" in
            FINDING:*)
              # Flush previous finding
              if [ -n "$_current_finding" ]; then
                echo "COMMENT: ${_current_finding} — ${_current_body}"
              fi
              _current_finding="${_fline#FINDING: }"
              _current_body=""
              ;;
            WHAT:*|EVIDENCE:*|IMPACT:*)
              _val="${_fline#*: }"
              if [ -n "$_current_body" ]; then
                _current_body="${_current_body}$(printf '\x1f')${_val}"
              else
                _current_body="$_val"
              fi
              ;;
            OPTIONS:*)
              _val="${_fline#*: }"
              _current_body="${_current_body}$(printf '\x1f')Options: ${_val}"
              ;;
          esac
        done < "$CLAUDE_OUT"
        # Flush last finding
        if [ -n "$_current_finding" ]; then
          echo "COMMENT: ${_current_finding} — ${_current_body}"
        fi
      } > "${REVIEW_STRUCTURED}.comments"
      # Use CLAUDE_OUT as-is for summary (parse_summary handles SCORECARD_START/END)
      parse_summary "$CLAUDE_OUT" "$REVIEW_SUMMARY"
      _recovered=true
    fi
  fi
fi

# -- Diagnostic: log comment recovery status --
_final_comment_count=$(grep -c "^COMMENT:" "${REVIEW_STRUCTURED}.comments" 2>/dev/null || echo "0")
_final_comment_count=$(echo "${_final_comment_count:-0}" | tr -d '[:space:]')
if [ "${_final_comment_count:-0}" -gt 0 ] 2>/dev/null; then
  echo "  ${_final_comment_count} inline comments ready (source: $([ "${_voice_comment_count:-0}" -gt 0 ] && echo 'voice rewrite' || echo 'fallback recovery'))" >&2
else
  echo "  warning: No inline comments extracted -- check voice rewrite + fallback paths" >&2
  _debug_json=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
  _debug_count=$(echo "$_debug_json" | jq '.findings | length' 2>/dev/null || echo "?")
  echo "    Claude JSON has ${_debug_count} findings, voice_comment_count was ${_voice_comment_count:-0}" >&2
fi


# -- Scorecard fallback: recover from Claude JSON if voice rewrite dropped it --
if ! grep -q '| Category' "$REVIEW_SUMMARY" 2>/dev/null; then
  echo "  Voice rewrite dropped scorecard -- recovering from Claude JSON" >&2
  _sc_json=$(_extract_json "$CLAUDE_OUT" 2>/dev/null || true)
  if [ -z "$_sc_json" ]; then
    _sc_json=$(jq '.' "$CLAUDE_OUT" 2>/dev/null || true)
  fi
  if [ -n "$_sc_json" ] && echo "$_sc_json" | jq -e '.scorecard' >/dev/null 2>&1; then
    _sc_fenced=$(mktemp -t "pr-${PR_NUMBER}-sc.XXXXXX")
    { echo '```json'; echo "$_sc_json"; echo '```'; } > "$_sc_fenced"
    parse_summary "$_sc_fenced" "$REVIEW_SUMMARY"
    rm -f "$_sc_fenced"
  fi
fi

# Append peer review coverage note to summary
if [ -n "${PEER_COVERAGE:-}" ]; then
  echo "" >> "$REVIEW_SUMMARY"
  echo "*Cross-checked by ${PEER_COVERAGE}.*" >> "$REVIEW_SUMMARY"
fi

COMMENT_COUNT=$(grep -c "^COMMENT:" "${REVIEW_STRUCTURED}.comments" || true)
REPLY_COUNT_PREVIEW=$(grep -c "^REPLY:" "${REVIEW_STRUCTURED}.comments" || true)

echo ""
echo "──────────────────────────────────────────"
if [ "$IS_REREVIEW" = true ]; then
  echo "  Re-review: ${COMMENT_COUNT} new comment$([ "$COMMENT_COUNT" -ne 1 ] && echo 's' || true), ${REPLY_COUNT_PREVIEW} thread repl$([ "$REPLY_COUNT_PREVIEW" -ne 1 ] && echo 'ies' || echo 'y')"
else
  echo "  ${COMMENT_COUNT} inline comment$([ "$COMMENT_COUNT" -ne 1 ] && echo 's' || true)"
fi
echo "──────────────────────────────────────────"
cat "$REVIEW_SUMMARY"
echo "──────────────────────────────────────────"
echo ""

# ============================================================
# INTERACTIVE COMMENT SELECTION (TTY only, skipped with --auto-post)
# ============================================================

# -- False positive blocklist: suppress known hallucination patterns --
_BLOCKLIST_FILE="/home/ubuntu/diffhound/config/false-positive-blocklist.jsonl"
if [ -f "$_BLOCKLIST_FILE" ] && [ -s "${REVIEW_STRUCTURED}.comments" ]; then
  _blocklist_removed=0
  _blocklist_tmp=$(mktemp -t "pr-${PR_NUMBER}-blocklist.XXXXXX")
  _audit_log="/home/ubuntu/diffhound/config/blocklist-audit.log"
  while IFS= read -r _cline; do
    _blocked=false
    while IFS= read -r _bl_entry; do
      [ -z "$_bl_entry" ] && continue
      _keywords=$(echo "$_bl_entry" | jq -r '.pattern_keywords[]' 2>/dev/null)
      _all_match=true
      while IFS= read -r _kw; do
        [ -z "$_kw" ] && continue
        if ! echo "$_cline" | grep -qi "$_kw"; then
          _all_match=false
          break
        fi
      done <<< "$_keywords"
      if [ "$_all_match" = true ]; then
        _reality=$(echo "$_bl_entry" | jq -r '.reality' 2>/dev/null)
        echo "  Suppressed false positive: ${_reality}" >&2
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) PR#${PR_NUMBER} suppressed: ${_cline:0:100}... reason: ${_reality}" >> "$_audit_log"
        _bl_pattern=$(echo "$_bl_entry" | jq -c '.pattern_keywords')
        _bl_tmp=$(mktemp)
        jq -c --argjson pat "$_bl_pattern" 'if .pattern_keywords == $pat then .hit_count += 1 else . end' "$_BLOCKLIST_FILE" > "$_bl_tmp" && mv "$_bl_tmp" "$_BLOCKLIST_FILE"
        _blocked=true
        _blocklist_removed=$((_blocklist_removed + 1))
        break
      fi
    done < "$_BLOCKLIST_FILE"
    [ "$_blocked" = false ] && echo "$_cline" >> "$_blocklist_tmp"
  done < "${REVIEW_STRUCTURED}.comments"
  if [ "$_blocklist_removed" -gt 0 ]; then
    echo "  Blocklist: suppressed ${_blocklist_removed} known false positive(s)" >&2
    mv "$_blocklist_tmp" "${REVIEW_STRUCTURED}.comments"
  else
    rm -f "$_blocklist_tmp"
  fi
fi

# -- Re-review dedup: suppress duplicates ONLY if dev addressed the area --
# Logic: if a new comment targets the same file:line as an existing thread AND
# the dev modified that area in the incremental diff, suppress it (dev addressed it).
# If the dev did NOT touch that area, keep the comment (still a valid concern).
if [ "$IS_REREVIEW" = true ] && [ -f "$EXISTING_COMMENTS_FILE" ]; then
  _existing_positions=$(jq -r --arg login "$REVIEWER_LOGIN" \
    '[.[] | select(.user == $login and .in_reply_to_id == null and .path != null and .line != null) | "\(.path):\(.line)"] | .[]' \
    "$EXISTING_COMMENTS_FILE" 2>/dev/null || true)

  if [ -n "$_existing_positions" ]; then
    # Build set of changed lines from incremental diff (file:line format)
    _changed_lines_file=$(mktemp -t "pr-${PR_NUMBER}-changed-lines.XXXXXX")
    if [ -n "${INCREMENTAL_DIFF_FILE:-}" ] && [ -s "${INCREMENTAL_DIFF_FILE:-}" ]; then
      awk '
        /^diff --git/ { file="" }
        /^\+\+\+ b\// { file=substr($0,7) }
        /^@@ / {
          s=$0; sub(/.*\+/,"",s); sub(/,.*/,"",s)
          line=int(s)-1
        }
        /^\+/ && file!="" { line++; print file ":" line }
        /^ / && file!="" { line++ }
        /^-/ { next }
      ' "$INCREMENTAL_DIFF_FILE" > "$_changed_lines_file" 2>/dev/null || true
    fi

    _dedup_comments=$(mktemp -t "pr-${PR_NUMBER}-dedup-comments.XXXXXX")
    _dedup_removed=0
    while IFS= read -r _cline; do
      _should_suppress=false
      if [[ "$_cline" =~ ^COMMENT:\ (.+):([0-9]+): ]]; then
        _c_file="${BASH_REMATCH[1]}"
        _c_line="${BASH_REMATCH[2]}"
        # Check if this comment duplicates an existing thread
        _matches_existing=false
        while IFS= read -r _epos; do
          [ -z "$_epos" ] && continue
          _e_file="${_epos%:*}"
          _e_line="${_epos##*:}"
          if [ "$_c_file" = "$_e_file" ] && [ -n "$_e_line" ] && [ "$_e_line" -eq "$_e_line" ] 2>/dev/null; then
            _delta=$(( _c_line - _e_line ))
            [ "$_delta" -lt 0 ] && _delta=$(( -_delta ))
            if [ "$_delta" -le 5 ]; then
              _matches_existing=true
              break
            fi
          fi
        done <<< "$_existing_positions"

        if [ "$_matches_existing" = true ]; then
          # Check if dev actually modified this area in the incremental diff
          _dev_touched=false
          if [ -s "$_changed_lines_file" ]; then
            # Check if any changed line is within +-5 lines of the comment target
            while IFS=: read -r _ch_file _ch_line; do
              if [ "$_c_file" = "$_ch_file" ] && [ -n "$_ch_line" ] && [ "$_ch_line" -eq "$_ch_line" ] 2>/dev/null; then
                _delta=$(( _c_line - _ch_line ))
                [ "$_delta" -lt 0 ] && _delta=$(( -_delta ))
                if [ "$_delta" -le 5 ]; then
                  _dev_touched=true
                  break
                fi
              fi
            done < "$_changed_lines_file"
          fi

          if [ "$_dev_touched" = true ]; then
            # Dev modified this area + it duplicates existing thread = suppress
            _should_suppress=true
          fi
          # If dev did NOT touch it, keep the comment (still a valid unfixed concern)
        fi
      fi

      if [ "$_should_suppress" = true ]; then
        _dedup_removed=$((_dedup_removed + 1))
      else
        echo "$_cline" >> "$_dedup_comments"
      fi
    done < "${REVIEW_STRUCTURED}.comments"
    rm -f "$_changed_lines_file"
    if [ "$_dedup_removed" -gt 0 ]; then
      echo "  Deduped: suppressed ${_dedup_removed} comment(s) addressed in new commits" >&2
      mv "$_dedup_comments" "${REVIEW_STRUCTURED}.comments"
    else
      rm -f "$_dedup_comments"
    fi
  fi
fi

declare -a _ALL_COMMENTS=()
while IFS= read -r _line; do
  _ALL_COMMENTS+=("$_line")
done < "${REVIEW_STRUCTURED}.comments"

declare -a _COMMENT_INDICES=()
declare -a _REPLY_INDICES=()
for _i in "${!_ALL_COMMENTS[@]}"; do
  if [[ "${_ALL_COMMENTS[$_i]}" =~ ^COMMENT: ]]; then
    _COMMENT_INDICES+=("$_i")
  elif [[ "${_ALL_COMMENTS[$_i]}" =~ ^REPLY: ]]; then
    _REPLY_INDICES+=("$_i")
  fi
done

# bash 3.2 compat: use indexed array instead of associative (declare -A)
declare -a _SELECTED=()
for _i in "${!_ALL_COMMENTS[@]}"; do
  _SELECTED[$_i]=1
done

_tui_render() {
  local _num _idx _stripped _badge _preview
  printf '\n'
  printf '──────────────────────────────────────────\n'
  printf '  📍 Comments (%d total):\n\n' "${#_COMMENT_INDICES[@]}"
  _num=1
  for _idx in "${_COMMENT_INDICES[@]}"; do
    _stripped="${_ALL_COMMENTS[$_idx]#COMMENT: }"
    _badge="  "
    if [[ "$_stripped" =~ :BLOCKING ]]; then _badge="🔴"; fi
    if [[ "$_stripped" =~ :SHOULD-FIX ]]; then _badge="🟡"; fi
    if [[ "$_stripped" =~ :NIT ]]; then _badge="⚪"; fi
    _preview="${_stripped:0:80}"
    if [ "${_SELECTED[$_idx]}" = "1" ]; then
      printf '  \033[32m[✓]\033[0m %2d %s %s\n' "$_num" "$_badge" "$_preview"
    else
      printf '  \033[31m[✗]\033[0m %2d %s %s\n' "$_num" "$_badge" "$_preview"
    fi
    _num=$((_num + 1))
  done
  if [ "${#_REPLY_INDICES[@]}" -gt 0 ]; then
    printf '\n  ── Thread replies (always included): %d\n' "${#_REPLY_INDICES[@]}"
  fi
  printf '──────────────────────────────────────────\n'
  printf '  Commands: <N> toggle  e<N> edit  d<N> drop  a all  n none  p post  q cancel\n'
  printf '  > '
}

if [ "$AUTO_POST" = true ]; then
  POST_REVIEW=true
elif [ ! -t 0 ] || [ ! -t 1 ]; then
  POST_REVIEW=false
else
  while true; do
    _tui_render
    read -r _CMD </dev/tty
    case "$_CMD" in
      p|post)
        POST_REVIEW=true
        break
        ;;
      q|quit)
        POST_REVIEW=false
        break
        ;;
      a|all)
        for _idx in "${_COMMENT_INDICES[@]}"; do _SELECTED[$_idx]=1; done
        echo "  ✓ All comments selected"
        ;;
      n|none)
        for _idx in "${_COMMENT_INDICES[@]}"; do _SELECTED[$_idx]=0; done
        echo "  ✓ All comments deselected"
        ;;
      d[0-9]*)
        _n="${_CMD#d}"
        if [[ "$_n" =~ ^[0-9]+$ ]] && [ "$_n" -ge 1 ] && [ "$_n" -le "${#_COMMENT_INDICES[@]}" ]; then
          _idx="${_COMMENT_INDICES[$((_n - 1))]}"
          _SELECTED[$_idx]=0
          echo "  ✓ Dropped comment #$_n"
        else
          echo "  ✗ Invalid: d<number> (e.g. d3)"
        fi
        ;;
      e[0-9]*)
        _n="${_CMD#e}"
        if [[ "$_n" =~ ^[0-9]+$ ]] && [ "$_n" -ge 1 ] && [ "$_n" -le "${#_COMMENT_INDICES[@]}" ]; then
          _idx="${_COMMENT_INDICES[$((_n - 1))]}"
          _EDIT_TMP=$(mktemp -t "pr-comment-edit.XXXXXX")
          printf '%s\n' "${_ALL_COMMENTS[$_idx]}" > "$_EDIT_TMP"
          ${EDITOR:-vi} "$_EDIT_TMP" </dev/tty >/dev/tty
          _edited=$(cat "$_EDIT_TMP" | head -1)
          [ -n "$_edited" ] && _ALL_COMMENTS[$_idx]="$_edited"
          rm -f "$_EDIT_TMP"
          echo "  ✓ Updated comment #$_n"
        else
          echo "  ✗ Invalid: e<number> (e.g. e2)"
        fi
        ;;
      [0-9]*)
        if [[ "$_CMD" =~ ^[0-9]+$ ]] && [ "$_CMD" -ge 1 ] && [ "$_CMD" -le "${#_COMMENT_INDICES[@]}" ]; then
          _idx="${_COMMENT_INDICES[$((_CMD - 1))]}"
          if [ "${_SELECTED[$_idx]}" = "1" ]; then
            _SELECTED[$_idx]=0
            echo "  ✓ Excluded comment #$_CMD"
          else
            _SELECTED[$_idx]=1
            echo "  ✓ Included comment #$_CMD"
          fi
        else
          echo "  ✗ Invalid number (1-${#_COMMENT_INDICES[@]})"
        fi
        ;;
      *)
        echo "  Commands: <N> toggle  e<N> edit  d<N> drop  a all  n none  p post  q cancel"
        ;;
    esac
  done
fi

if [ "$POST_REVIEW" = true ]; then
  spinner_start "Posting review to GitHub..."

  # Separate COMMENT: lines from REPLY: lines (respecting TUI selections)
  : > "${REVIEW_STRUCTURED}.new_comments"
  : > "${REVIEW_STRUCTURED}.replies"
  if [ "${#_COMMENT_INDICES[@]}" -gt 0 ]; then
    for _idx in "${_COMMENT_INDICES[@]}"; do
      [ "${_SELECTED[$_idx]:-0}" = "1" ] || continue
      printf '%s\n' "${_ALL_COMMENTS[$_idx]#COMMENT: }" >> "${REVIEW_STRUCTURED}.new_comments"
    done
  fi
  if [ "${#_REPLY_INDICES[@]}" -gt 0 ]; then
    for _idx in "${_REPLY_INDICES[@]}"; do
      printf '%s\n' "${_ALL_COMMENTS[$_idx]#REPLY: }" >> "${REVIEW_STRUCTURED}.replies"
    done
  fi
  NEW_COMMENT_COUNT=$(wc -l < "${REVIEW_STRUCTURED}.new_comments" | tr -d ' ')
  REPLY_COUNT=$(wc -l < "${REVIEW_STRUCTURED}.replies" | tr -d ' ')

  # Parse verdict using lib function (3-method fallback)
  REVIEW_EVENT=$(parse_verdict "$REVIEW_SUMMARY" "${REVIEW_STRUCTURED}.new_comments")

  # Reorder summary: move scorecard table to the top (after first paragraph)
  # so it survives GitHub's silent body truncation on large reviews.
  if grep -q '| Category' "$REVIEW_SUMMARY" 2>/dev/null; then
    _reorder_tmp=$(mktemp -t "pr-${PR_NUMBER}-reorder.XXXXXX")
    _table_tmp=$(mktemp -t "pr-${PR_NUMBER}-table.XXXXXX")
    _body_tmp=$(mktemp -t "pr-${PR_NUMBER}-body.XXXXXX")

    # Extract table lines (| rows) and everything else
    _in_table=false
    while IFS= read -r _line; do
      if echo "$_line" | grep -q '^| Category'; then
        _in_table=true
      fi
      if [ "$_in_table" = true ]; then
        if echo "$_line" | grep -q '^|'; then
          echo "$_line" >> "$_table_tmp"
        else
          _in_table=false
          echo "$_line" >> "$_body_tmp"
        fi
      else
        echo "$_line" >> "$_body_tmp"
      fi
    done < "$REVIEW_SUMMARY"

    # Rebuild: first paragraph, then scorecard, then rest
    _found_break=false
    _seen_text=false
    while IFS= read -r _line; do
      echo "$_line" >> "$_reorder_tmp"
      # Insert table after first blank line that follows actual text
      if [ "$_found_break" = false ]; then
        if [ -n "$_line" ]; then
          _seen_text=true
        elif [ "$_seen_text" = true ] && [ -z "$_line" ]; then
          _found_break=true
          if [ -s "$_table_tmp" ]; then
            cat "$_table_tmp" >> "$_reorder_tmp"
            echo "" >> "$_reorder_tmp"
          fi
        fi
      fi
    done < "$_body_tmp"

    # If no blank line found, append table at end
    if [ "$_found_break" = false ] && [ -s "$_table_tmp" ]; then
      echo "" >> "$_reorder_tmp"
      cat "$_table_tmp" >> "$_reorder_tmp"
    fi

    # Only use reordered if valid
    if [ -s "$_reorder_tmp" ] && grep -q '| Category' "$_reorder_tmp" 2>/dev/null; then
      mv "$_reorder_tmp" "$REVIEW_SUMMARY"
    else
      rm -f "$_reorder_tmp"
    fi
    rm -f "$_table_tmp" "$_body_tmp" 2>/dev/null
  fi


  # -- Strip orphan ## Scorecard headers (not followed by a pipe table) --
  if grep -q '^## Scorecard' "$REVIEW_SUMMARY" 2>/dev/null; then
    _dedup_tmp=$(mktemp -t "pr-${PR_NUMBER}-dedup.XXXXXX")
    awk '
      /^## Scorecard/ {
        hold = $0; pending = 1; next
      }
      pending && /^[[:space:]]*$/ { next }
      pending {
        if (/^\|/) { print hold; print; pending = 0 }
        else { pending = 0; print }
        next
      }
      { print }
      END { if (pending && hold != "") {} }
    ' "$REVIEW_SUMMARY" > "$_dedup_tmp" && mv "$_dedup_tmp" "$REVIEW_SUMMARY"
    rm -f "$_dedup_tmp" 2>/dev/null || true
  fi

  # Build the review JSON (new inline comments only)
  cat > "$REVIEW_JSON" << JSONSTART
{
  "commit_id": "$HEAD_SHA",
  "event": "$REVIEW_EVENT",
  "body": $(jq -Rs . < "$REVIEW_SUMMARY"),
  "comments": [
JSONSTART

  if [ "$NEW_COMMENT_COUNT" -gt 0 ]; then
    FIRST=true
    while IFS=: read -r filepath line rest; do
      [[ ! "$filepath" =~ ^[a-zA-Z0-9/_.-]+$ ]] && continue
      line="${line#\~}"
      [[ ! "$line" =~ ^[0-9]+$ ]] && continue
      line=$(snap_to_diff_line "$filepath" "$line" "$DIFF_FILE")
      comment=$(strip_severity_label "$rest")
      [ -z "$(printf '%s' "$comment" | tr -d '[:space:]')" ] && continue
      [ "$FIRST" = false ] && echo "," >> "$REVIEW_JSON"
      FIRST=false
      ESCAPED_COMMENT=$(printf '%s\n' "$comment" | jq -Rs .)
      cat >> "$REVIEW_JSON" << COMMENTJSON
    {
      "path": "$filepath",
      "line": $line,
      "body": $ESCAPED_COMMENT
    }
COMMENTJSON
    done < "${REVIEW_STRUCTURED}.new_comments"
  fi

  cat >> "$REVIEW_JSON" << JSONEND
  ]
}
JSONEND

  # Post review + inline comments (with fallback)
  post_review "$REPO_OWNER" "$REPO_NAME" "$PR_NUMBER" \
    "$HEAD_SHA" "$REVIEW_EVENT" "$REVIEW_SUMMARY" "$REVIEW_JSON" \
    "${REVIEW_STRUCTURED}.new_comments" "$DIFF_FILE"

  if [ "$_POSTED_OK" = true ]; then
    NEW_COMMENT_COUNT="${_FINAL_COMMENT_COUNT:-$NEW_COMMENT_COUNT}"

    # Post thread replies if any
    if [ "$REPLY_COUNT" -gt 0 ]; then
      REPLY_POSTED=$(post_thread_replies "$REPO_OWNER" "$REPO_NAME" "$PR_NUMBER" "${REVIEW_STRUCTURED}.replies")
      spinner_stop "Posted (${REVIEW_EVENT}, ${NEW_COMMENT_COUNT} new inline, ${REPLY_POSTED} thread replies)"
    else
      spinner_stop "Posted (${REVIEW_EVENT}, ${NEW_COMMENT_COUNT} inline)"
    fi
  fi

  echo ""
  echo "  → https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PR_NUMBER}"

  # Save posted comments to cache for --learn feedback loop
  if [ "$_POSTED_OK" = true ] && [ -f "${REVIEW_STRUCTURED}.new_comments" ]; then
    _POSTED_CACHE="$REVIEW_CACHE_DIR/pr-${PR_NUMBER}-posted.json"
    {
      printf '{"pr":%s,"head_sha":"%s","posted_at":"%s","comments":' \
        "$PR_NUMBER" "$HEAD_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      jq -Rs '[split("\n")[] | select(length > 0)]' < "${REVIEW_STRUCTURED}.new_comments"
      printf '}'
    } > "$_POSTED_CACHE" 2>/dev/null || true
  fi

  # Voice indexer — continuous learning from posted comments
  VOICE_JSONL_INDEX="$HOME/.diffhound/voice-examples.jsonl"
  INDEXED=$(index_voice_comments "${REVIEW_STRUCTURED}.new_comments" "$PR_NUMBER" "$VOICE_JSONL_INDEX" "$REVIEW_CACHE_DIR")
  [ "$INDEXED" -gt 0 ] && echo "  📝 Indexed $INDEXED comments to voice RAG ($(wc -l < "$VOICE_JSONL_INDEX") total)"
  # -- Self-contradiction guard: save actionable suggestions for future re-reviews --
  if [ -f "${REVIEW_STRUCTURED}.new_comments" ]; then
    _suggestions_file="$REVIEW_CACHE_DIR/pr-${PR_NUMBER}-suggestions.jsonl"
    _round=$(jq -r --arg login "$REVIEWER_LOGIN" '[.[] | select(.user == $login)] | length' "$EXISTING_COMMENTS_FILE" 2>/dev/null || echo "1")
    _sug_extracted=0
    while IFS= read -r _sline; do
      _suggestion=""
      if echo "$_sline" | grep -qiE '(you should|change .+ to|use .+ instead|replace .+ with|add .+ to|remove .+ from)'; then
        _suggestion=$(echo "$_sline" | grep -oiE '(you should|change|use|replace|add|remove) [^.]{10,80}' | head -1)
      fi
      [ -z "$_suggestion" ] && continue
      if [[ "$_sline" =~ ^(.+):([0-9]+): ]]; then
        _s_file="${BASH_REMATCH[1]}"
        _s_line="${BASH_REMATCH[2]}"
        jq -n --arg round "$_round" --arg file "$_s_file" --arg line "$_s_line" \
          --arg suggestion "$_suggestion" \
          '{round:($round|tonumber),file:$file,line:($line|tonumber),suggestion:$suggestion}' \
          >> "$_suggestions_file"
        _sug_extracted=$((_sug_extracted + 1))
      fi
    done < "${REVIEW_STRUCTURED}.new_comments"
    [ "$_sug_extracted" -gt 0 ] && echo "  Logged ${_sug_extracted} suggestion(s) for self-contradiction tracking" >&2
  fi

  # Auto-learn from ALL previous PR caches (0 LLM tokens, just GitHub API)
  # Picks up human edits/deletions on previously posted comments
  _LEARNED_TOTAL=0
  for _cache_file in "$REVIEW_CACHE_DIR"/pr-*-posted.json; do
    [ -f "$_cache_file" ] || continue
    _cached_pr=$(jq -r '.pr' "$_cache_file" 2>/dev/null || true)
    [ -z "$_cached_pr" ] && continue
    [ "$_cached_pr" = "$PR_NUMBER" ] && continue  # skip current (just posted)
    # Only process caches older than 1 hour (give human time to review on GitHub)
    find "$_cache_file" -mmin +60 -print 2>/dev/null | grep -q . || continue
    _learn_from_pr "$_cached_pr" >/dev/null 2>&1 && _LEARNED_TOTAL=$((_LEARNED_TOTAL + 1)) || true
  done
  [ "$_LEARNED_TOTAL" -gt 0 ] && echo "  📚 Auto-learned from $_LEARNED_TOTAL previous review(s)"

  # Auto-resolve threads addressed by new commits (re-review only)
  if [ "$IS_REREVIEW" = true ] && [ -n "$INCREMENTAL_DIFF_FILE" ] && [ -f "$INCREMENTAL_DIFF_FILE" ]; then
    _RESOLVED=$(resolve_addressed_comments "$REPO_OWNER" "$REPO_NAME" "$PR_NUMBER" \
      "$EXISTING_COMMENTS_FILE" "$INCREMENTAL_DIFF_FILE" "$REVIEWER_LOGIN")
    [ "$_RESOLVED" -gt 0 ] && echo "  ✓ Auto-resolved $_RESOLVED addressed thread(s)"
  fi

  # Cleanup parse files
  rm -f "${REVIEW_STRUCTURED}.new_comments" "${REVIEW_STRUCTURED}.replies" 2>/dev/null || true
else
  echo "📋 Review not posted."
  echo "   Summary: $REVIEW_SUMMARY"
  echo "   Inline comments: ${REVIEW_STRUCTURED}.comments"
  trap - EXIT
fi
