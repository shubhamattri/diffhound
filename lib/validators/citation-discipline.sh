#!/usr/bin/env bash
# citation-discipline.sh — auto-downgrade BLOCKING/SHOULD-FIX findings that
# are missing the three citation fields: DIFF_LINE, REACHABLE_PATH,
# REJECTED_ALTERNATIVE.
#
# Rationale: PR #127 review produced 25% severity swings on unchanged code
# because findings lacked discipline. The prompt now requires the three
# fields for severity >= SHOULD-FIX. This validator enforces the gate
# mechanically — reviewers who skip the fields get their severity dropped,
# so the prompt contract has teeth.
#
# Downgrade ladder: BLOCKING -> SHOULD-FIX -> NIT. OPEN_QUESTION and NIT
# pass through unchanged (NIT has no stronger gate; OPEN_QUESTION is not a
# code-correctness finding, so the three-field rule doesn't apply).
#
# A field counts as "present" when the key appears AND the content after
# the colon contains at least one non-whitespace token. Bare "DIFF_LINE:"
# with nothing after fails. "DIFF_LINE: N/A" passes syntactically — the
# prompt is responsible for semantic validity; this validator only catches
# the "reviewer forgot to fill the field" class of failure.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

block=""
header_sev=""
header_prefix=""
has_diff_line=0
has_reachable_path=0
has_rejected_alt=0

_has_content() {
  # Return 0 if $1 has any non-whitespace after the first colon.
  local line="$1"
  local content="${line#*:}"
  content="${content#"${content%%[![:space:]]*}"}"
  [ -n "$content" ]
}

_downgrade() {
  # $1 = current severity, echoes new severity (or current if no downgrade).
  case "$1" in
    BLOCKING)    echo "SHOULD-FIX" ;;
    SHOULD-FIX)  echo "NIT" ;;
    *)           echo "$1" ;;
  esac
}

_emit() {
  [ -z "$block" ] && return
  if [ "$header_sev" = "BLOCKING" ] || [ "$header_sev" = "SHOULD-FIX" ]; then
    local missing=""
    [ "$has_diff_line" -eq 0 ]      && missing="${missing}DIFF_LINE "
    [ "$has_reachable_path" -eq 0 ] && missing="${missing}REACHABLE_PATH "
    [ "$has_rejected_alt" -eq 0 ]   && missing="${missing}REJECTED_ALTERNATIVE "
    if [ -n "$missing" ]; then
      local new_sev
      new_sev="$(_downgrade "$header_sev")"
      printf '[citation-discipline] DOWNGRADED %s->%s (missing: %s): %s\n' \
        "$header_sev" "$new_sev" "${missing% }" "$header_prefix" >&2
      block=$(printf '%s' "$block" | awk -v old="$header_sev" -v new="$new_sev" -v miss="${missing% }" '
        BEGIN { rewrote_finding = 0; annotated_what = 0 }
        /^FINDING:/ && !rewrote_finding {
          sub(":" old "$", ":" new)
          print
          rewrote_finding = 1
          next
        }
        /^WHAT:/ && !annotated_what {
          print $0 " [citation-discipline: downgraded from " old "; missing " miss "]"
          annotated_what = 1
          next
        }
        { print }
      ')
      block="${block}"$'\n'
    fi
  fi
  printf '%s' "$block"
  block=""; header_sev=""; header_prefix=""
  has_diff_line=0; has_reachable_path=0; has_rejected_alt=0
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      header_sev="${header_prefix##*:}"
      ;;
    DIFF_LINE:*)
      block+="$line"$'\n'
      _has_content "$line" && has_diff_line=1
      ;;
    REACHABLE_PATH:*)
      block+="$line"$'\n'
      _has_content "$line" && has_reachable_path=1
      ;;
    REJECTED_ALTERNATIVE:*)
      block+="$line"$'\n'
      _has_content "$line" && has_rejected_alt=1
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_emit
