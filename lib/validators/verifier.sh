#!/usr/bin/env bash
# verifier.sh — LLM-as-judge stage. For each BLOCKING/SHOULD-FIX finding,
# pulls the cited code + grep evidence for backticked identifiers, asks
# Haiku "is this finding TRUE, PARTIAL, or HALLUCINATED?", drops the
# hallucinated ones and downgrades the partial ones.
#
# Driven by PR #7145 audit (~12+ FPs across 9 rounds, every one refuted
# by a 5-second grep that the primary review LLM didn't run). The regex
# validators catch known wording families (migration columns, ref-exists,
# auth-gate-precedes, line-cite, cross-file-comparison) but each new
# wording variant slips through.
#
# A second LLM call dedicated ONLY to "given this finding and this code,
# is the claim true?" has lower hallucination rate than the primary call
# that's juggling 20K LOC, severity scoring, finding generation, and tone
# all at once. Specificity beats capability for accuracy.
#
# Usage:
#   verifier.sh < findings.txt > findings.verified
#
# Pipeline placement: LAST regex stage, just before citation-discipline
# (so a downgrade from BLOCKING→SHOULD-FIX still gets the citation gate
# applied at proper severity).
#
# Cost: each finding sends ~1500 input + 50 output tokens to Haiku.
# Roughly $0.0015 per finding. ~$0.01 per review at 8 findings.
#
# Dependencies: an authenticated `claude` CLI, jq, awk. (v0.7.29: was
# ANTHROPIC_API_KEY + curl.)
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Skip the verifier entirely when there is no model backend to call — fall back
# to the regex pipeline output. This keeps unit-test runs (no network) working.
# v0.7.29: the gate was `-z ANTHROPIC_API_KEY`; the backend is now the claude
# CLI, so the key no longer says anything about whether a call can be made. A
# configured mock always wins, so fixtures exercising the verdict branches still
# reach the mock even under DIFFHOUND_OFFLINE.
if [ -z "${DIFFHOUND_VERIFIER_MOCK_FILE:-}" ] \
   && { [ "${DIFFHOUND_OFFLINE:-0}" = "1" ] || ! command -v claude >/dev/null 2>&1; }; then
  cat
  exit 0
fi

# ────────────────────────────────────────────────────────────────────
# Mock verdict endpoint (opt-in via DIFFHOUND_VERIFIER_MOCK_FILE)
#
# When DIFFHOUND_VERIFIER_MOCK_FILE points at a JSONL file, the verifier
# skips the real Anthropic API call entirely and looks up each finding's
# verdict from that file. This is purely for deterministic fixture testing
# of the TRUE/PARTIAL/HALLUCINATED branches; production runs never set
# this env var.
#
# Format: one JSON object per line, with these keys:
#   {"key":"<path>:<line>:<what_prefix>","verdict":"TRUE|PARTIAL|HALLUCINATED","reason":"<text>"}
#
# Where:
#   path        = the file path from "FINDING: <path>:<line>:<sev>"
#   line        = the line number from the same header
#   what_prefix = first 30 chars of the WHAT: line, trimmed of leading space
#
# Lookup semantics:
#   - File set + file missing on disk → fall back to TRUE (safe default)
#   - File set + file exists + no matching key → fall back to TRUE (safe)
#   - File set + matching key found → use its verdict
#
# Mock takes precedence over the real API call when its env var is set.
# ────────────────────────────────────────────────────────────────────

# Verifier model — Haiku is fast and accurate enough for "compare claim
# to code" decisions. Override via DIFFHOUND_VERIFIER_MODEL for testing.
MODEL="${DIFFHOUND_VERIFIER_MODEL:-claude-haiku-4-5-20251001}"
# v0.7.29: was 120. Under the claude CLI, exceeding the output cap is a hard
# error with NO content returned, where the raw API returned a clipped but
# still-parseable body. An empty response here hits the "infra failure" branch
# below, which answers TRUE and keeps every finding — so a cap set too low
# silently switches false-positive filtering off. 1024 is the CLI floor.
MAX_OUTPUT_TOKENS=1024
TIMEOUT_SECS=30

# Verify only BLOCKING and SHOULD-FIX. NIT / OPEN_QUESTION findings aren't
# worth the API spend — even if they're FPs, the user filters them by
# severity already.
VERIFY_SEVERITIES='BLOCKING|SHOULD-FIX'

# ────────────────────────────────────────────────────────────────────
# Per-finding evidence builder

_window_around() {
  # Print lines [start, end] from $file
  local file="$1" start="$2" end="$3"
  [ "$start" -lt 1 ] && start=1
  awk -v s="$start" -v e="$end" 'NR >= s && NR <= e { printf "%6d  %s\n", NR, $0 }' "$file" 2>/dev/null
}

_grep_symbol() {
  # Find the first 3 source-file references for a backticked identifier.
  local sym="$1" repo="$2"
  grep -rn --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.py' \
    --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=.git \
    -F -- "$sym" "$repo" 2>/dev/null | head -3
}

# ────────────────────────────────────────────────────────────────────
# Verifier prompt

_verify_one() {
  # Inputs: $1 = block contents (FINDING:...WHAT:...etc.)
  # Output: VERDICT line on stdout, one of:
  #   TRUE       — finding is supported by the code
  #   PARTIAL    — claim is partially correct or overstated
  #   HALLUCINATED — claim contradicted by the code
  local block="$1"

  # Extract the file:line from FINDING line
  local header path line
  header=$(printf '%s' "$block" | sed -n '1p')        # FINDING: <path>:<line>:<sev>
  header="${header#FINDING: }"
  path="${header%%:*}"
  local rest="${header#*:}"
  line="${rest%%:*}"
  case "$line" in ''|*[!0-9]*) line="" ;; esac

  # Build code window (15 lines either side of cited line)
  local code_window=""
  if [ -n "$path" ] && [ -n "$line" ] && [ -f "$DIFFHOUND_REPO/$path" ]; then
    local s=$((line - 15)) e=$((line + 15))
    code_window=$(_window_around "$DIFFHOUND_REPO/$path" "$s" "$e")
  fi

  # Pull every backticked identifier from the block
  local what_text
  what_text=$(printf '%s' "$block" | grep -E '^(WHAT|EVIDENCE|IMPACT):' | tr '\n' ' ')
  local syms
  syms=$(printf '%s' "$what_text" \
    | grep -oE '`\.?[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?`' \
    | tr -d '`' | sed 's/^\.//' | sort -u | head -8)

  # Grep evidence for each symbol
  local evidence=""
  if [ -n "$syms" ]; then
    while IFS= read -r sym; do
      [ -z "$sym" ] && continue
      [ "${#sym}" -lt 4 ] && continue
      local hits
      hits=$(_grep_symbol "$sym" "$DIFFHOUND_REPO")
      if [ -n "$hits" ]; then
        evidence+="$sym → FOUND:"$'\n'"$hits"$'\n'
      else
        evidence+="$sym → NOT FOUND in source"$'\n'
      fi
    done <<< "$syms"
  fi

  # Build the verifier prompt via concatenated printf calls. Avoids heredoc
  # parsing quirks on older bash where parens inside the body get treated
  # as case-statement syntax even with a quoted terminator.
  local prompt
  prompt=$(
    printf '%s\n\n' "You are a code-review FACT CHECKER. Your only job is to compare a finding's claim against ground-truth grep results and the actual code at the cited line. Do NOT evaluate severity, write new analysis, or invent fixes. Output one of three verdicts and a brief reason."
    printf '# FINDING\n\n%s\n\n' "$block"
    printf '# CITED CODE around %s:%s\n\n%s\n\n' "$path" "$line" "$code_window"
    printf '# GREP EVIDENCE\n\n%s\n\n' "$evidence"
    printf '# YOUR TASK\n\n'
    printf 'Reply in this EXACT format, no markdown, no preamble:\n\n'
    printf 'VERDICT: <TRUE or PARTIAL or HALLUCINATED>\n'
    printf 'REASON: <one short sentence>\n\n'
    printf 'Verdict criteria:\n'
    printf -- '- HALLUCINATED: at least one of these is true:\n'
    printf '  a. a backticked symbol the finding claims exists is "NOT FOUND in source"\n'
    printf '  b. the cited line range does NOT contain what the finding describes\n'
    printf '  c. the finding asserts behavior contradicted by the visible code\n'
    printf -- '- PARTIAL: the finding core claim is plausible but overstated; example, flags a BLOCKING IDOR when the auth gate visible in the cited code restricts access to admin-only roles\n'
    printf -- '- TRUE: the cited code matches the claim, the symbols exist, the asserted behavior is consistent with the visible code\n'
  )

  # Mock branch: opt-in via DIFFHOUND_VERIFIER_MOCK_FILE. Bypasses curl
  # entirely so fixtures can exercise verdict handling deterministically.
  if [ -n "${DIFFHOUND_VERIFIER_MOCK_FILE:-}" ]; then
    local mock_verdict mock_reason
    if [ ! -f "$DIFFHOUND_VERIFIER_MOCK_FILE" ]; then
      # File set but missing → safe default = keep finding.
      printf 'TRUE|mock file not found, defaulting to TRUE\n'
      return
    fi
    # Build the lookup key: <path>:<line>:<first 30 chars of WHAT>
    local what_line what_prefix
    what_line=$(printf '%s' "$block" | grep -E '^WHAT:' | head -1 | sed 's/^WHAT:[[:space:]]*//')
    what_prefix="${what_line:0:30}"
    local mock_key="${path}:${line}:${what_prefix}"
    # Find a matching line in the JSONL file. Use jq for safe field extraction.
    local match
    match=$(jq -r --arg k "$mock_key" \
      'select(.key == $k) | "\(.verdict)|\(.reason // "mocked")"' \
      "$DIFFHOUND_VERIFIER_MOCK_FILE" 2>/dev/null | head -1)
    if [ -z "$match" ]; then
      # No matching key → safe default = keep finding.
      printf 'TRUE|no mock entry for %s, defaulting to TRUE\n' "$mock_key"
      return
    fi
    mock_verdict="${match%%|*}"
    mock_reason="${match#*|}"
    case "$mock_verdict" in
      HALLUCINATED|PARTIAL|TRUE) ;;
      *) mock_verdict="TRUE" ;;
    esac
    printf '%s|%s\n' "$mock_verdict" "$mock_reason"
    return
  fi

  # Call Haiku through the claude CLI. The neutral system prompt is required:
  # the CLI's default agent prompt makes the model conversational, and this
  # parser is anchored on ^VERDICT: / ^REASON: lines.
  local sys_file resp
  sys_file=$(mktemp -t "verify-sys.XXXXXX")
  printf '%s\n' \
    "You are a non-interactive verification engine inside a shell pipeline." \
    "Answer only in the demanded VERDICT/REASON line format." \
    "Never ask a clarifying question. Never add preamble or commentary." \
    > "$sys_file"

  # Inline form only; see the note in lib/review.sh on why there is no probe.
  local sys_args=( --system-prompt "$(cat "$sys_file")" )

  resp=$(printf '%s' "$prompt" | env -u ANTHROPIC_API_KEY -u CLAUDECODE \
    CLAUDE_CODE_MAX_OUTPUT_TOKENS="$MAX_OUTPUT_TOKENS" \
    timeout "$TIMEOUT_SECS" claude \
      -p --output-format json \
      --model "$MODEL" \
      "${sys_args[@]}" \
      --allowedTools '' \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --setting-sources '' 2>/dev/null || echo "")
  rm -f "$sys_file"

  if [ -z "$resp" ]; then
    # Backend error → fall back to TRUE (don't drop on infra failure)
    echo "TRUE"
    return
  fi

  local verdict reason
  local body
  body=$(printf '%s' "$resp" | jq -r 'if (.is_error // false) then empty else (.result // empty) end' 2>/dev/null)
  verdict=$(printf '%s' "$body" | grep -E '^VERDICT:' | head -1 | sed 's/^VERDICT:[[:space:]]*//')
  reason=$(printf '%s' "$body" | grep -E '^REASON:' | head -1 | sed 's/^REASON:[[:space:]]*//')

  case "$verdict" in
    HALLUCINATED|PARTIAL|TRUE) ;;
    *) verdict="TRUE" ;;  # parse failure → keep
  esac

  printf '%s|%s\n' "$verdict" "$reason"
}

# ────────────────────────────────────────────────────────────────────
# Main loop

block=""
header_severity=""

_emit_block_if_kept() {
  [ -z "$block" ] && return

  # Only verify BLOCKING / SHOULD-FIX findings. NITs pass through.
  if ! printf '%s' "$header_severity" | grep -qE -- "$VERIFY_SEVERITIES"; then
    printf '%s' "$block"
    return
  fi

  local result verdict reason
  result=$(_verify_one "$block")
  verdict="${result%%|*}"
  reason="${result#*|}"

  case "$verdict" in
    HALLUCINATED)
      printf '[verifier] DROPPED (HALLUCINATED): %s — %s\n' \
        "$(printf '%s' "$block" | head -1)" "$reason" >&2
      # Drop — emit nothing
      ;;
    PARTIAL)
      printf '[verifier] DOWNGRADED (PARTIAL): %s — %s\n' \
        "$(printf '%s' "$block" | head -1)" "$reason" >&2
      # Downgrade exactly one tier: BLOCKING→SHOULD-FIX, SHOULD-FIX→NIT.
      # Rewrite the FINDING header (first line) in shell so we don't risk
      # the BLOCKING→SHOULD-FIX→NIT double-downgrade a two-stage sed chain
      # would produce.
      local _first _rest _new_first
      _first="${block%%$'\n'*}"
      _rest="${block#*$'\n'}"
      case "$_first" in
        *:BLOCKING)    _new_first="${_first%:BLOCKING}:SHOULD-FIX" ;;
        *:SHOULD-FIX)  _new_first="${_first%:SHOULD-FIX}:NIT" ;;
        *)             _new_first="$_first" ;;
      esac
      printf '%s\n%s' "$_new_first" "$_rest"
      ;;
    *)
      # TRUE or unknown → keep unchanged
      printf '%s' "$block"
      ;;
  esac
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _emit_block_if_kept
      block="$line"$'\n'
      header_severity="${line##*:}"
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_emit_block_if_kept
