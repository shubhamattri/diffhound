#!/bin/bash
# ── Model backend: direct Anthropic API on diffhound's own key ───────────────
# v0.7.31 (BX-3010): reverts the v0.7.29 `claude -p` backend. That backend
# authenticated with CLAUDE_CODE_OAUTH_TOKEN, i.e. Shubham's PERSONAL Claude
# subscription, and every call deliberately scrubbed ANTHROPIC_API_KEY so the
# subscription was the only credential it could use. Diffhound now has a funded
# key of its own, so every model call goes back to api.anthropic.com with
# x-api-key. Two reasons this is a revert and not a new design:
#   1. Provability. With the CLI, which credential paid is a precedence question
#      between an env key, an OAuth token and ~/.claude.json. With x-api-key the
#      billed account is the header, and nothing can silently fall back to a
#      personal subscription.
#   2. Prompt caching. The cache_control breakpoint below is worth ~90% off the
#      repeated system prefix and the CLI path had no equivalent.
# Do NOT reintroduce a `claude` CLI call anywhere in this pipeline — it bills
# the wrong account and does it silently. _api_backend_ok is the loud gate.
_ANTHROPIC_API_URL="${ANTHROPIC_API_URL:-https://api.anthropic.com/v1/messages}"

# v0.7.32: thinking models put a `thinking` block FIRST in content, so the old
# `.content[0].text` read null and every Opus call returned an empty string —
# the exact silent-empty failure mode v0.7.30 exists to prevent. Always select
# the text blocks by type, never by position. Proven on claude-opus-5:
#   block_types=thinking,text   content[0].text=null
_TEXT_BLOCKS='[.content[] | select(.type == "text") | .text] | join("")'

# Effort + adaptive thinking are sent ONLY when a caller asks for an effort
# level. Haiku 4.5 rejects `output_config.effort`, so the cheap layers must keep
# omitting it; Opus 5 / Sonnet 5 think by default either way.
_output_cfg() {
  [ -z "${1:-}" ] && { printf '{}'; return; }
  jq -nc --arg e "$1" '{thinking: {type: "adaptive"}, output_config: {effort: $e}}'
}

# A response that spent every output token thinking has stop_reason max_tokens and
# no text block. Returning 0 there posted content-free "merge ok" reviews (PR #347).
# Usage: printf '%s' "$resp" | _api_text_status  -> prints text; exit 2 if truncated-empty
_api_text_status() {
  local _r _t
  _r=$(cat)
  _t=$(printf '%s' "$_r" | jq -r "$_TEXT_BLOCKS" 2>/dev/null || true)
  printf '%s' "$_t"
  if [ -z "${_t//[[:space:]]/}" ] && [ "$(printf '%s' "$_r" | jq -r '.stop_reason // empty' 2>/dev/null)" = "max_tokens" ]; then
    return 2
  fi
  return 0
}

_lower_effort() {
  case "${1:-}" in max|xhigh) echo high ;; high) echo medium ;; medium) echo low ;; *) echo "" ;; esac
}

# Usage: printf '%s' "$prompt" | _call_api MODEL [MAX_TOKENS] [TIMEOUT_SECS] [EFFORT]
#        _call_api MODEL [MAX_TOKENS] [TIMEOUT_SECS] [EFFORT] < prompt_file
_call_api() {
  local model="$1"
  local max_tokens="${2:-4096}"
  local timeout_secs="${3:-120}"
  local effort="${4:-}"

  local _api_pf _api_jf
  _api_pf=$(mktemp -t "api-prompt.XXXXXX")
  _api_jf=$(mktemp -t "api-json.XXXXXX")
  cat > "$_api_pf"
  local _api_pf_keep; _api_pf_keep=$(mktemp -t "api-keep.XXXXXX"); cp "$_api_pf" "$_api_pf_keep"

  jq -n --arg model "$model" \
        --argjson max_tokens "$max_tokens" \
        --argjson extra "$(_output_cfg "$effort")" \
        --rawfile user "$_api_pf" \
    '{model: $model, max_tokens: $max_tokens,
      messages: [{role: "user", content: $user}]} + $extra' > "$_api_jf"
  rm -f "$_api_pf"

  local _api_r
  _api_r=$($_TIMEOUT_CMD "$timeout_secs" curl -sf "$_ANTHROPIC_API_URL" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d @"$_api_jf" 2>/dev/null || echo "")
  rm -f "$_api_jf"

  printf '%s' "$_api_r" | _cost_record "$model" "${DIFFHOUND_STAGE:-other}"
  [ -n "${DIFFHOUND_STOP_REASON_FILE:-}" ] && \
    printf '%s' "$_api_r" | jq -r '.stop_reason // empty' > "$DIFFHOUND_STOP_REASON_FILE" 2>/dev/null
  local _api_txt _api_rc=0
  _api_txt=$(printf '%s' "$_api_r" | _api_text_status) || _api_rc=$?
  if [ "$_api_rc" = 2 ]; then
    local _lower; _lower=$(_lower_effort "$effort")
    echo "  [diffhound] ${model} spent all ${max_tokens} output tokens thinking (stop_reason=max_tokens, no text)${_lower:+; retrying at effort ${_lower}}" >&2
    if [ -n "$_lower" ] && [ "${_DIFFHOUND_EFFORT_RETRY:-0}" != 1 ]; then
      _DIFFHOUND_EFFORT_RETRY=1 _call_api "$model" "$max_tokens" "$timeout_secs" "$_lower" < "$_api_pf_keep"
      local _rc=$?; rm -f "$_api_pf_keep"; return $_rc
    fi
    rm -f "$_api_pf_keep"; return 1
  fi
  rm -f "$_api_pf_keep"
  # No text at all (empty body, network failure, content-free reply) is a
  # failed call. Returning 0 here let a chunk review write an empty file that
  # every later stage read as "nothing found".
  _api_empty_is_failure "$_api_txt" || return 1
  printf '%s' "$_api_txt"
}

# _call_api_system MODEL MAX_TOKENS TIMEOUT SYSTEM_FILE [EFFORT] < user_prompt
_call_api_system() {
  local model="$1"
  local max_tokens="${2:-4096}"
  local timeout_secs="${3:-120}"
  local system_file="$4"
  local effort="${5:-}"

  local _api_pf _api_jf
  _api_pf=$(mktemp -t "api-prompt.XXXXXX")
  _api_jf=$(mktemp -t "api-json.XXXXXX")
  cat > "$_api_pf"
  local _api_pf_keep; _api_pf_keep=$(mktemp -t "api-keep.XXXXXX"); cp "$_api_pf" "$_api_pf_keep"

  jq -n --arg model "$model" \
        --argjson max_tokens "$max_tokens" \
        --argjson extra "$(_output_cfg "$effort")" \
        --rawfile system "$system_file" \
        --rawfile user "$_api_pf" \
    '{model: $model, max_tokens: $max_tokens,
      system: [{type: "text", text: $system, cache_control: {type: "ephemeral"}}],
      messages: [{role: "user", content: $user}]} + $extra' > "$_api_jf"
  rm -f "$_api_pf"

  local _api_r
  _api_r=$($_TIMEOUT_CMD "$timeout_secs" curl -sf "$_ANTHROPIC_API_URL" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d @"$_api_jf" 2>/dev/null || echo "")
  rm -f "$_api_jf"

  printf '%s' "$_api_r" | _cost_record "$model" "${DIFFHOUND_STAGE:-other}"
  [ -n "${DIFFHOUND_STOP_REASON_FILE:-}" ] && \
    printf '%s' "$_api_r" | jq -r '.stop_reason // empty' > "$DIFFHOUND_STOP_REASON_FILE" 2>/dev/null
  local _api_txt _api_rc=0
  _api_txt=$(printf '%s' "$_api_r" | _api_text_status) || _api_rc=$?
  if [ "$_api_rc" = 2 ]; then
    local _lower; _lower=$(_lower_effort "$effort")
    echo "  [diffhound] ${model} spent all ${max_tokens} output tokens thinking (stop_reason=max_tokens, no text)${_lower:+; retrying at effort ${_lower}}" >&2
    if [ -n "$_lower" ] && [ "${_DIFFHOUND_EFFORT_RETRY:-0}" != 1 ]; then
      _DIFFHOUND_EFFORT_RETRY=1 _call_api_system "$model" "$max_tokens" "$timeout_secs" "$system_file" "$_lower" < "$_api_pf_keep"
      local _rc=$?; rm -f "$_api_pf_keep"; return $_rc
    fi
    rm -f "$_api_pf_keep"; return 1
  fi
  rm -f "$_api_pf_keep"
  # No text at all (empty body, network failure, content-free reply) is a
  # failed call. Returning 0 here let a chunk review write an empty file that
  # every later stage read as "nothing found".
  _api_empty_is_failure "$_api_txt" || return 1
  printf '%s' "$_api_txt"
}

# Proves the backend ANSWERS, not merely that a key is present. v0.7.30 exists
# because a revoked-but-still-exported key passed a `-z` presence check and
# diffhound posted content-free APPROVEs onto live monorepo PRs. Keep it a real
# call. Echoes the model's reply on stdout so callers can show the failure.
_api_backend_ok() {
  [ -n "${ANTHROPIC_API_KEY:-}" ] || return 1
  local _r
  _r=$($_TIMEOUT_CMD 60 curl -s "$_ANTHROPIC_API_URL" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,
         "messages":[{"role":"user","content":"Reply with exactly: OK"}]}' 2>/dev/null || echo "")
  printf '%s' "$_r" | jq -r '.error.message // empty' 2>/dev/null
  printf '%s' "$_r" | jq -e "($_TEXT_BLOCKS) | length > 0" >/dev/null 2>&1
}
