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
# Dependencies: ANTHROPIC_API_KEY env var, jq, curl, awk.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Skip the verifier entirely if the API key isn't set — fall back to the
# regex pipeline output. This keeps unit-test runs (no network) working.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  cat
  exit 0
fi

# Verifier model — Haiku is fast and accurate enough for "compare claim
# to code" decisions. Override via DIFFHOUND_VERIFIER_MODEL for testing.
MODEL="${DIFFHOUND_VERIFIER_MODEL:-claude-haiku-4-5-20251001}"
MAX_OUTPUT_TOKENS=120
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

  # Call Haiku
  local req_file resp
  req_file=$(mktemp -t "verify-req.XXXXXX")
  jq -n --arg model "$MODEL" \
        --argjson max_tokens "$MAX_OUTPUT_TOKENS" \
        --arg user "$prompt" \
    '{model: $model, max_tokens: $max_tokens,
      messages: [{role: "user", content: $user}]}' > "$req_file"

  resp=$(timeout "$TIMEOUT_SECS" curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d @"$req_file" 2>/dev/null || echo "")
  rm -f "$req_file"

  if [ -z "$resp" ]; then
    # API error → fall back to TRUE (don't drop on infra failure)
    echo "TRUE"
    return
  fi

  local verdict reason
  local body
  body=$(printf '%s' "$resp" | jq -r '.content[0].text // empty' 2>/dev/null)
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
      # Downgrade BLOCKING→SHOULD-FIX, SHOULD-FIX→NIT
      printf '%s' "$block" | sed \
        -e '1s/:BLOCKING$/:SHOULD-FIX/' \
        -e '1s/:SHOULD-FIX$/:NIT/'
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
