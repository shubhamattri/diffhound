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
# v0.5.7: track unverifiable tool-run claims in WHAT/EVIDENCE prose. The
# LLM has no shell — phrases like "i ran a grep and got zero hits" are
# guaranteed hallucinations. Stacks with the missing-citation downgrade.
has_unverifiable_toolrun=0
toolrun_phrase=""

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
  local current_sev="$header_sev"

  # Pass 1: missing-citation-fields downgrade (existing logic from v0.5.0).
  if [ "$current_sev" = "BLOCKING" ] || [ "$current_sev" = "SHOULD-FIX" ]; then
    local missing=""
    [ "$has_diff_line" -eq 0 ]      && missing="${missing}DIFF_LINE "
    [ "$has_reachable_path" -eq 0 ] && missing="${missing}REACHABLE_PATH "
    [ "$has_rejected_alt" -eq 0 ]   && missing="${missing}REJECTED_ALTERNATIVE "
    if [ -n "$missing" ]; then
      local new_sev
      new_sev="$(_downgrade "$current_sev")"
      printf '[citation-discipline] DOWNGRADED %s->%s (missing: %s): %s\n' \
        "$current_sev" "$new_sev" "${missing% }" "$header_prefix" >&2
      block=$(printf '%s' "$block" | awk -v old="$current_sev" -v new="$new_sev" -v miss="${missing% }" '
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
      current_sev="$new_sev"
    fi
  fi

  # Pass 2: unverifiable tool-run claim downgrade (v0.5.7). Stacks with
  # Pass 1 — a finding both missing all 3 fields AND containing "I ran grep"
  # prose drops two tiers (BLOCKING→SHOULD-FIX→NIT). Independent evidence
  # for the same hallucination class, stacking is correct.
  if [ "$has_unverifiable_toolrun" -eq 1 ] && \
     { [ "$current_sev" = "BLOCKING" ] || [ "$current_sev" = "SHOULD-FIX" ] || [ "$current_sev" = "NIT" ]; }; then
    local new_sev2
    new_sev2="$(_downgrade "$current_sev")"
    if [ "$new_sev2" != "$current_sev" ]; then
      printf '[citation-discipline] DOWNGRADED %s->%s (unverifiable tool-run: %s): %s\n' \
        "$current_sev" "$new_sev2" "${toolrun_phrase}" "$header_prefix" >&2
      block=$(printf '%s' "$block" | awk -v old="$current_sev" -v new="$new_sev2" -v phrase="$toolrun_phrase" '
        BEGIN { rewrote_finding = 0; annotated_what = 0 }
        /^FINDING:/ && !rewrote_finding {
          sub(":" old "$", ":" new)
          print
          rewrote_finding = 1
          next
        }
        /^WHAT:/ && !annotated_what {
          print $0 " [citation-discipline: downgraded from " old "; unverifiable tool-run: " phrase "]"
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
  has_unverifiable_toolrun=0; toolrun_phrase=""
}

_check_unverifiable_toolrun() {
  # Args: $1 = line text. Sets has_unverifiable_toolrun=1 if a hallucinated
  # tool-run claim is detected. Patterns target first-person assertions of
  # running shell commands (which the LLM cannot do).
  local txt="$1"
  local pat
  for pat in \
    "i ran (a |the )?(grep|search|find|rg|ag)[^.]*(and got|returned|found|saw)[^.]*(zero|no|0)" \
    "confirmed with (grep|search|find|rg|ag|ack)" \
    "verified[^.]*(zero|no|0) (hits|matches|results|occurrences)" \
    "(i'?ve?|i'?d) (grep'?d?|grepped|searched|checked)[^.]*(and got|returned|found|across)[^.]*(zero|no|0)" \
    "ran (a |the )?(grep|search|find)[^.]*(across|over|on)[^.]*(and got|and found)" \
    "got (zero|no|0) (hits|matches|results) (when|after) (i|searching|grep)" \
    "(grep|search) (across|over|on) [^.]+ (returned|got|gave) (zero|no|0)"; do
    if printf '%s' "$txt" | grep -qiE -- "$pat"; then
      has_unverifiable_toolrun=1
      local snippet
      snippet=$(printf '%s' "$txt" | grep -oiE -- "$pat" | head -1 | cut -c1-80)
      toolrun_phrase="$snippet"
      return 0
    fi
  done
  return 0
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
    WHAT:*|EVIDENCE:*|IMPACT:*|OPTIONS:*)
      block+="$line"$'\n'
      _check_unverifiable_toolrun "$line"
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_emit
