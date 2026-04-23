#!/usr/bin/env bash
# todo-deferral.sh — downgrade BLOCKING → SHOULD-FIX when a documented
# deferral exists near the flagged line. Product decisions written as
# `TODO(TICKET-ID): ...` within ±RADIUS lines of the finding are treated as
# "known limitation, not a code bug" — keeping the finding visible as
# should-fix so reviewers see it, but not blocking the merge.
#
# Only `TODO(TICKET-ID)` counts — bare `TODO:` comments are informal notes,
# not product deferrals.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

RADIUS=20

block=""
header_file=""
header_line_no=""
header_sev=""
awaiting_what=0
todo_line=""
ticket=""

_emit() {
  [ -z "$block" ] && return
  printf '%s' "$block"
  block=""; header_file=""; header_line_no=""; header_sev=""
  awaiting_what=0; todo_line=""; ticket=""
}

# Find a `TODO(TICKET-ID)` within ±RADIUS lines of anchor in file. Emit
# "<lineno> <ticket>" on stdout if found, else nothing.
_find_todo() {
  local path="$1" anchor="$2"
  [ -f "$path" ] || return 0
  local start=$((anchor - RADIUS))
  [ "$start" -lt 1 ] && start=1
  local end=$((anchor + RADIUS))
  awk -v s="$start" -v e="$end" '
    NR > e { exit }
    NR >= s && NR <= e {
      if (match($0, /TODO\(([A-Z]+-[A-Z0-9]+)\)/)) {
        line_matched = substr($0, RSTART, RLENGTH)
        # Strip "TODO(" prefix and ")" suffix to get ticket
        tkt = line_matched
        sub(/^TODO\(/, "", tkt)
        sub(/\)$/, "", tkt)
        printf "%d %s\n", NR, tkt
        exit
      }
    }
  ' "$path"
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _emit
      header="${line#FINDING: }"
      header_file="${header%%:*}"
      rest="${header#*:}"
      header_line_no="${rest%%:*}"
      header_sev="${rest##*:}"

      if [ "$header_sev" = "BLOCKING" ]; then
        todo=$(_find_todo "$DIFFHOUND_REPO/$header_file" "$header_line_no" 2>/dev/null || true)
        if [ -n "$todo" ]; then
          todo_line="${todo%% *}"
          ticket="${todo##* }"
          # Downgrade the header severity
          block="FINDING: ${header_file}:${header_line_no}:SHOULD-FIX"$'\n'
          awaiting_what=1
          continue
        fi
      fi
      # No downgrade — pass through unchanged
      block="$line"$'\n'
      awaiting_what=0
      ;;
    WHAT:*)
      if [ "$awaiting_what" -eq 1 ]; then
        block+="${line} [todo-deferral: deferred per TODO at ${header_file}:${todo_line} (${ticket})]"$'\n'
        awaiting_what=0
      else
        block+="$line"$'\n'
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_emit
