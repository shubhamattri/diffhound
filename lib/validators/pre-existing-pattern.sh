#!/usr/bin/env bash
# pre-existing-pattern.sh — DROP findings that flag a pattern as "new X per
# request" when the same pattern already exists in the flagged file >= 3
# times. Those findings aren't introduced by this PR — they're tech debt
# that pre-dates it. Flagging them as diff nits creates noise and inflates
# reviewer count.
#
# Conservative matching: only activates when WHAT/EVIDENCE contains one of
# the trigger phrases AND a backticked symbol can be extracted AND the
# symbol has >=3 non-diff occurrences in the flagged file.
#
# Non-matches pass through unchanged. We'd rather miss a real case than
# drop a legitimate finding.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Wording that signals "this pattern is new here". If the pattern is
# actually >=3 pre-existing occurrences, the finding is a false positive.
TRIGGER_WORDS='new .* per request|per-request|creates a new|instantiat(es|ing) a new|repeatedly creates'
MIN_OCCURRENCES=3

block=""
header_file=""
what_line=""
evidence_line=""
matched_trigger=0
sym=""

_emit() {
  [ -z "$block" ] && return

  if [ "$matched_trigger" -eq 1 ] && [ -n "$sym" ] && [ -n "$header_file" ]; then
    local path="$DIFFHOUND_REPO/$header_file"
    if [ -f "$path" ]; then
      # Count non-comment occurrences. Strip Python #, JS/TS //, and
      # lines starting with * (block comment continuations) before counting.
      local count
      count=$(grep -v -E '^[[:space:]]*(#|//|\*)' "$path" 2>/dev/null | grep -Fc -- "$sym" || true)
      if [ "${count:-0}" -ge "$MIN_OCCURRENCES" ]; then
        printf '[pre-existing-pattern] DROPPED (%s occurs %dx in %s): %s\n' \
          "$sym" "$count" "$header_file" "$(printf '%s' "$block" | head -1)" >&2
        block=""; header_file=""; what_line=""; evidence_line=""
        matched_trigger=0; sym=""
        return
      fi
    fi
  fi

  printf '%s' "$block"
  block=""; header_file=""; what_line=""; evidence_line=""
  matched_trigger=0; sym=""
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _emit
      block="$line"$'\n'
      header="${line#FINDING: }"
      header_file="${header%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      what_line="$line"
      if printf '%s' "$line" | grep -qiE "$TRIGGER_WORDS"; then
        matched_trigger=1
      fi
      # First plain-identifier backticked symbol.
      sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9.]+`' | head -1 | tr -d '`' || true)
      ;;
    EVIDENCE:*)
      block+="$line"$'\n'
      evidence_line="$line"
      if [ "$matched_trigger" -eq 0 ] && printf '%s' "$line" | grep -qiE "$TRIGGER_WORDS"; then
        matched_trigger=1
      fi
      if [ -z "$sym" ]; then
        sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9.]+`' | head -1 | tr -d '`' || true)
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_emit
