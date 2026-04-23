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

  # Parse validated output into { "file:line" → {severity, what} }.
  # Keying on (file, line) — not severity — because todo-deferral mutates
  # BLOCKING → SHOULD-FIX. The validator-output severity is applied back.
  _survivors_json=$(printf '%s' "$_validated" | awk '
    BEGIN { key = ""; sev = ""; what = "" }
    /^FINDING: / {
      if (key != "") printf "%s\t%s\t%s\n", key, sev, what
      hdr = substr($0, 10)
      n = split(hdr, parts, ":")
      if (n >= 3) {
        key = parts[1] ":" parts[2]
        sev = parts[n]
      } else {
        key = hdr; sev = ""
      }
      what = ""
      next
    }
    /^WHAT: / {
      if (what == "") what = substr($0, 7)
      next
    }
    END { if (key != "") printf "%s\t%s\t%s\n", key, sev, what }
  ' | jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map({(.[0]): {severity: .[1], what: .[2]}})
    | add // {}
  ')

  # Rebuild findings: drop missing keys; apply severity + append annotations.
  _new_json=$(printf '%s' "$_json" | jq --argjson survivors "$_survivors_json" '
    .findings |= (
      map(
        . as $f |
        ("\($f.file):\($f.line)") as $k |
        $survivors[$k] as $match |
        if $match == null then empty
        else
          # Apply (possibly mutated) severity from validator output
          (if $match.severity != "" then .severity = $match.severity else . end) as $f2 |
          # Append any [xxx: ...] annotations to the body
          ($match.what | [scan("\\[[a-z-]+: [^\\]]+\\]")] | join(" ")) as $annotations |
          if ($annotations | length) > 0 then
            $f2 | .body = (.body // "") + (if (.body // "") == "" then "" else " " end) + $annotations
          else $f2 end
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
