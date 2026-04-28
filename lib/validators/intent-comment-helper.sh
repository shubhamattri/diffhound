#!/usr/bin/env bash
# intent-comment-helper.sh — downgrade findings whose flagged line is
# immediately preceded by an inline comment that explicitly documents the
# behaviour as intentional. Catches the case where a developer has already
# considered the "bug" and decided it is correct by design.
#
# Trigger: ANY finding (no keyword gate at the WHAT level — the gate is the
# proximity of an intent-marker comment in the source).
# Check: lines (anchor-WINDOW) through (anchor-1) in the flagged file for a
# comment line whose body matches an intent-marker phrase.
# Action: downgrade severity to OPEN_QUESTION with annotation citing the
# nearby comment. Mirrors security-helper.sh / concurrency-helper.sh shape.
#
# Why: diffhound v0.5.x findings on PR #7145 (Apr 28 2026) included one for
# `Math.round(reduce(...) / months.length)` flagged as "wrong denominator".
# The line above said `// Average TAT always over 3 months; no-endorsement
# months count as 0 (zero-padded)` — explicit intent. The model ignored it
# and posted a BLOCKING-shape comment anyway.

set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Conservative trigger set: only phrases that unambiguously mean "this is the
# intended behaviour", not coding-style admonitions ("always check input").
INTENT_MARKERS_RE='intentional|by design|deliberately|on purpose|zero-pad|zero padded|always over|always count|always return|always fall|same soft behaviour'
WINDOW=5

block=""
header_file=""
header_line=""
header_sev=""

_emit() {
  [ -z "$block" ] && return

  if [ -n "$header_file" ] && [ -n "$header_line" ] \
     && [ "$header_sev" != "OPEN_QUESTION" ]; then
    local path="$DIFFHOUND_REPO/$header_file"
    if [ -f "$path" ]; then
      local intent_evidence
      intent_evidence=$(_find_intent_comment "$path" "$header_line")
      if [ -n "$intent_evidence" ] \
         && { [ "$header_sev" = "BLOCKING" ] || [ "$header_sev" = "SHOULD-FIX" ] || [ "$header_sev" = "NIT" ]; }; then
        printf '[intent-comment-helper] DOWNGRADED %s->OPEN_QUESTION (intent comment within %d lines): %s\n' \
          "$header_sev" "$WINDOW" "${header_file}:${header_line}" >&2
        block=$(printf '%s' "$block" | awk -v old="$header_sev" -v evidence="$intent_evidence" '
          BEGIN { rewrote = 0; annotated = 0 }
          /^FINDING:/ && !rewrote {
            sub(":" old "$", ":OPEN_QUESTION")
            print
            rewrote = 1
            next
          }
          /^WHAT:/ && !annotated {
            print $0 " [intent-comment-helper: downgraded from " old "; nearby comment cites intentional behaviour: \"" evidence "\"; verify before blocking]"
            annotated = 1
            next
          }
          { print }
        ')
        block="${block}"$'\n'
      fi
    fi
  fi

  printf '%s' "$block"
  block=""
  header_file=""
  header_line=""
  header_sev=""
}

# Search lines (anchor-WINDOW) through (anchor-1) for a comment line whose
# (lowercased) body contains an intent-marker phrase. Echo a trimmed excerpt
# (≤80 chars) of the matching comment for annotation, or empty if no match.
_find_intent_comment() {
  local path="$1" anchor="$2"
  local start=$((anchor - WINDOW))
  [ "$start" -lt 1 ] && start=1
  awk -v s="$start" -v e="$anchor" -v re="$INTENT_MARKERS_RE" '
    BEGIN { IGNORECASE = 1 }
    NR < s { next }
    NR >= e { exit }
    /^[[:space:]]*(\/\/|\*|#|--)/ {
      if ($0 ~ re) {
        line = $0
        sub(/^[[:space:]]*(\/\/+|\*+|#+|--+)[[:space:]]*/, "", line)
        gsub(/[[:space:]]+/, " ", line)
        sub(/^[[:space:]]+/, "", line)
        if (length(line) > 80) line = substr(line, 1, 77) "..."
        gsub(/"/, "\\\"", line)
        print line
        exit
      }
    }
  ' "$path"
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      header_file="${header_prefix%%:*}"
      rest="${header_prefix#*:}"
      header_line="${rest%%:*}"
      header_sev="${rest#*:}"
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_emit
