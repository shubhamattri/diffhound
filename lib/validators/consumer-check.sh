#!/usr/bin/env bash
# consumer-check.sh — DOWNGRADE findings that claim an API shape/contract
# change is "breaking" when NO in-repo consumer can be found for the named
# endpoint/symbol.
#
# Rationale: PR #127 looped on "the envelope shape of GET /api/conversations
# is a breaking change" across 6 review passes. The dashboard app in the
# same repo called only /api/analytics/*; nothing consumed the flagged
# endpoint. The BLOCKER was re-raised with no grep evidence each pass.
# Making the reviewer do the grep before it hits the user is cheap and
# removes a recurring false-positive class.
#
# Conservative matching. Activates only when ALL of these hold:
#   1. Severity is BLOCKING or SHOULD-FIX.
#   2. WHAT or EVIDENCE contains a "breaking" trigger phrase.
#   3. A target is extractable — either a backticked symbol or a quoted
#      API path (e.g. "/api/conversations").
#   4. The target has ZERO non-definition occurrences in the repo.
#
# If any of (1)-(4) fail, the finding passes through unchanged. False
# negatives (legit breaking change slips through) are fine — the finding
# still lands; we just didn't annotate it. False positives are what we're
# eliminating.
#
# Downgrade action: BLOCKING/SHOULD-FIX -> OPEN_QUESTION. OPEN_QUESTION
# doesn't count against the scorecard per v0.5.0 severity rules, matching
# the finding's actual nature (it's a coordination question: "do any
# external consumers exist?"). WHAT gets annotated with the zero-consumer
# note so downstream readers see the gap.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Wording that signals "this is breaking for existing consumers". Conservative
# list — only unambiguous phrases. "Contract change" alone isn't enough; we
# require the caller-impact framing.
TRIGGER_WORDS='breaking (api|contract) change|breaking change.*(consumer|caller)|breaks (existing )?(consumer|caller)s?|breaking.*contract|response shape change.*(breaking|consumer|caller)|breaks the (existing )?(api|endpoint|contract|consumer)'

block=""
header_prefix=""
header_sev=""
header_file=""
what_line=""
evidence_line=""
matched_trigger=0
target=""

_emit() {
  [ -z "$block" ] && return

  if { [ "$header_sev" = "BLOCKING" ] || [ "$header_sev" = "SHOULD-FIX" ]; } \
     && [ "$matched_trigger" -eq 1 ] \
     && [ -n "$target" ] \
     && [ -n "$header_file" ]; then

    # Count occurrences across the repo, excluding common vendor dirs and
    # the file where the endpoint is defined (the flagged file itself).
    local count
    count=$(grep -rn --fixed-strings \
              --exclude-dir=node_modules \
              --exclude-dir=.git \
              --exclude-dir=__pycache__ \
              --exclude-dir=dist \
              --exclude-dir=build \
              --exclude-dir=venv \
              --exclude-dir=.venv \
              --exclude="$(basename "$header_file")" \
              -- "$target" "$DIFFHOUND_REPO" 2>/dev/null | wc -l | tr -d ' ')

    if [ "${count:-0}" -eq 0 ]; then
      local annot="[consumer-check: no in-repo consumer found for \`$target\`; confirm external consumers before blocking]"
      printf '[consumer-check] DOWNGRADED %s->OPEN_QUESTION (0 consumers of %s): %s\n' \
        "$header_sev" "$target" "$header_prefix" >&2
      block=$(printf '%s' "$block" | awk -v old="$header_sev" -v annot="$annot" '
        BEGIN { rewrote_finding = 0; annotated_what = 0 }
        /^FINDING:/ && !rewrote_finding {
          sub(":" old "$", ":OPEN_QUESTION")
          print
          rewrote_finding = 1
          next
        }
        /^WHAT:/ && !annotated_what {
          print $0 " " annot
          annotated_what = 1
          next
        }
        { print }
      ')
      block="${block}"$'\n'
    fi
  fi

  printf '%s' "$block"
  block=""; header_prefix=""; header_sev=""; header_file=""
  what_line=""; evidence_line=""; matched_trigger=0; target=""
}

_extract_target() {
  # $1 = line; echo first target candidate found.
  # Preference order: API path > backticked symbol.
  local line="$1"
  # Quoted API path, e.g. "/api/conversations" or '/api/widget/stream'
  local path
  path=$(printf '%s' "$line" | grep -oE '["'\''`][/][a-zA-Z0-9_/-]+["'\''`]' | head -1 \
           | tr -d '"'"'"'`' || true)
  if [ -n "$path" ]; then
    echo "$path"
    return
  fi
  # Backticked identifier (function name, class name)
  local sym
  sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]+`' | head -1 | tr -d '`' || true)
  if [ -n "$sym" ]; then
    echo "$sym"
    return
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      header_sev="${header_prefix##*:}"
      header_file="${header_prefix%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      what_line="$line"
      if printf '%s' "$line" | grep -qiE "$TRIGGER_WORDS"; then
        matched_trigger=1
      fi
      if [ -z "$target" ]; then
        target="$(_extract_target "$line")"
      fi
      ;;
    EVIDENCE:*)
      block+="$line"$'\n'
      evidence_line="$line"
      if [ "$matched_trigger" -eq 0 ] && printf '%s' "$line" | grep -qiE "$TRIGGER_WORDS"; then
        matched_trigger=1
      fi
      if [ -z "$target" ]; then
        target="$(_extract_target "$line")"
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_emit
