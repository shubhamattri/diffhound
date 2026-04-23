#!/usr/bin/env bash
# format-adapter.sh — bridges CLAUDE_OUT's JSON format to the validators'
# FINDING: text format and back.
#
# Input (stdin or arg $1): file containing either
#   (a) raw JSON with `.findings[]` array
#   (b) ```json ... ``` fenced block with the same JSON inside
#   (c) FINDINGS_START / FINDING: block format (LARGE tier merge output)
#
# Output (stdout): same format as input, minus any findings the validator
# pipeline dropped, plus any annotations the pipeline appended to WHAT lines.
#
# Usage:
#   lib/validators/format-adapter.sh < CLAUDE_OUT > CLAUDE_OUT.validated
#   (or)  adapt_validator_run /path/to/claude_out /path/to/out
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VALIDATORS_RUN="${DIFFHOUND_VALIDATORS_RUN:-$ROOT/lib/validators/run-all.sh}"

INPUT=$(cat)

# Detect format
_extract_inline_json() {
  # Pull the JSON inside a ```json ... ``` fence, or return whole body if it
  # looks like JSON, else empty.
  local body="$1"
  if printf '%s' "$body" | grep -q '^```json'; then
    printf '%s' "$body" | awk '/^```json/{f=1; next} /^```/{f=0} f'
  elif printf '%s' "$body" | head -1 | grep -qE '^[[:space:]]*\{'; then
    printf '%s' "$body"
  fi
}

_json=$(_extract_inline_json "$INPUT")

if [ -n "$_json" ] && printf '%s' "$_json" | jq -e '.findings' >/dev/null 2>&1; then
  # JSON path: extract findings → FINDING: blocks → validators → re-merge
  _findings_text=$(printf '%s' "$_json" | jq -r '
    .findings[] |
    "FINDING: \(.file):\(.line):\(.severity)\nWHAT: \(.title // "")\(if (.body // "") != "" then ". \(.body)" else "" end)"
  ')

  _validated=$(printf '%s\n' "$_findings_text" | "$VALIDATORS_RUN" 2>/dev/null || true)

  # Parse validated output into { "file:line:severity" → annotated_what }
  # Findings without a FINDING: header are droppedl
  _survivors_json=$(printf '%s' "$_validated" | awk '
    BEGIN { key = "" }
    /^FINDING: / {
      if (key != "") { print key "\t" what }
      header = substr($0, 10)
      key = header
      what = ""
      next
    }
    /^WHAT: / {
      if (what == "") what = substr($0, 7)
      next
    }
    END { if (key != "") print key "\t" what }
  ' | jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map({(.[0]): .[1]})
    | add // {}
  ')

  # Rebuild findings array: drop findings whose key is not in survivors;
  # for survivors, if the validated WHAT differs from original title, append
  # any `[...]` annotations to the body.
  _new_json=$(printf '%s' "$_json" | jq --argjson survivors "$_survivors_json" '
    .findings |= (
      map(
        . as $f |
        ("\($f.file):\($f.line):\($f.severity)") as $k |
        $survivors[$k] as $new_what |
        if $new_what == null then empty
        else
          # Extract [xxx: ...] annotations from validated WHAT
          ($new_what | [scan("\\[[a-z-]+: [^\\]]+\\]")] | join(" ")) as $annotations |
          if ($annotations | length) > 0 then
            .body = (.body // "") + (if (.body // "") == "" then "" else " " end) + $annotations
          else . end
        end
      )
    )
  ')

  # Re-emit in the original format (fenced vs raw)
  if printf '%s' "$INPUT" | grep -q '^```json'; then
    printf '```json\n%s\n```\n' "$_new_json"
  else
    printf '%s\n' "$_new_json"
  fi
  exit 0
fi

# FINDING: path: pipe through validators as-is
if printf '%s' "$INPUT" | grep -q '^FINDING:'; then
  printf '%s' "$INPUT" | "$VALIDATORS_RUN"
  exit 0
fi

# Unknown format — pass through unchanged
printf '%s' "$INPUT"
