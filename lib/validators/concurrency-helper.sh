#!/usr/bin/env bash
# concurrency-helper.sh — downgrade race-condition findings to OPEN_QUESTION
# when the flagged code is structurally inside a `.transaction(...)` callback
# (DB engine serializes contending txns via row locks) OR adjacent to an
# explicit safe primitive (FOR UPDATE / advisory lock / SKIP LOCKED), AND the
# finding does not explicitly cite a concrete multi-process / multi-worker /
# cross-request concurrent flow.
#
# Same shape as security-helper.sh + citation-discipline.sh: scoped, evidence-
# required, downgrade-only (preserves signal but de-prioritises). Output sev is
# OPEN_QUESTION so a human reviewer can verify rather than dropping outright.
#
# Why brace-aware (not a flat ±50 line window): a transaction 60 lines away
# in a different function would otherwise falsely downgrade a real race.
# Peer-review feedback 2026-04-28.

set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

CONCURRENCY_KW_RE='\b(race[[:space:]]+condition|race-condition|concurrent[[:space:]]+(modification|access|write|read|deletion|update)|deadlock|mutex|atomic[[:space:]]+(update|operation))\b'
SAFE_PRIMITIVES_RE='FOR[[:space:]]+UPDATE|SKIP[[:space:]]+LOCKED|pg_advisory_lock|redlock|\.setnx|forUpdate\(\)'
MULTIPROCESS_RE='\b(worker|workers|cron|queue|job[-[:space:]]?grab|multi[-[:space:]]?process|cross[-[:space:]]?process|two[-[:space:]]+workers|multiple[[:space:]]+workers|across[[:space:]]+(requests|processes|workers)|different[[:space:]]+(requests|workers|processes))\b'
WINDOW=20
MAX_TXN_LOOKBACK=200

block=""
header_file=""
header_line=""
header_sev=""

_emit() {
  [ -z "$block" ] && return

  local should_downgrade=0
  local downgrade_reason=""

  if [ -n "$header_file" ] && [ -n "$header_line" ] \
     && [ "$header_sev" != "OPEN_QUESTION" ] \
     && printf '%s' "$block" | grep -qiE "$CONCURRENCY_KW_RE" \
     && ! printf '%s' "$block" | grep -qiE "$MULTIPROCESS_RE"; then
    local path="$DIFFHOUND_REPO/$header_file"
    if [ -f "$path" ]; then
      if _is_inside_transaction "$path" "$header_line"; then
        should_downgrade=1
        downgrade_reason="inside .transaction() block"
      elif _has_safe_primitive_near "$path" "$header_line"; then
        should_downgrade=1
        downgrade_reason="safe primitive within ${WINDOW} lines"
      fi
    fi
  fi

  if [ "$should_downgrade" -eq 1 ] \
     && { [ "$header_sev" = "BLOCKING" ] || [ "$header_sev" = "SHOULD-FIX" ] || [ "$header_sev" = "NIT" ]; }; then
    printf '[concurrency-helper] DOWNGRADED %s->OPEN_QUESTION (%s, no multi-process flow cited): %s\n' \
      "$header_sev" "$downgrade_reason" "${header_file}:${header_line}" >&2
    block=$(printf '%s' "$block" | awk -v old="$header_sev" -v reason="$downgrade_reason" '
      BEGIN { rewrote = 0; annotated = 0 }
      /^FINDING:/ && !rewrote {
        sub(":" old "$", ":OPEN_QUESTION")
        print
        rewrote = 1
        next
      }
      /^WHAT:/ && !annotated {
        print $0 " [concurrency-helper: downgraded from " old "; " reason "; cite multi-process flow to keep severity]"
        annotated = 1
        next
      }
      { print }
    ')
    block="${block}"$'\n'
  fi

  printf '%s' "$block"
  block=""
  header_file=""
  header_line=""
  header_sev=""
}

# Return 0 iff `anchor` line is structurally inside a `.transaction(` callback.
# Walks backward from `anchor` for the most recent `.transaction(` within
# MAX_TXN_LOOKBACK lines, then forward-counts net { vs } from that opener up to
# (but not including) `anchor`. Net depth > 0 = inside scope.
#
# Limitation: braces inside string literals or regexes are counted naively. In
# typical TS/JS/Python on the lines between a `.transaction(` opener and its
# callback body, this is rare enough that the heuristic holds.
_is_inside_transaction() {
  local path="$1" anchor="$2"

  local txn_line
  txn_line=$(awk -v anchor="$anchor" '
    NR > anchor { exit }
    /\.transaction\(/ { candidate = NR }
    END { print candidate }
  ' "$path")

  [ -z "$txn_line" ] && return 1
  [ "$((anchor - txn_line))" -gt "$MAX_TXN_LOOKBACK" ] && return 1

  local net_opens
  net_opens=$(awk -v start="$txn_line" -v end="$anchor" '
    NR < start { next }
    NR >= end { exit }
    {
      n = gsub(/\{/, "{")
      m = gsub(/\}/, "}")
      depth += n - m
    }
    END { print depth+0 }
  ' "$path")

  [ "${net_opens:-0}" -gt 0 ]
}

_has_safe_primitive_near() {
  local path="$1" anchor="$2"
  local start=$((anchor - WINDOW))
  local end=$((anchor + WINDOW))
  [ "$start" -lt 1 ] && start=1
  awk -v s="$start" -v e="$end" 'NR>=s && NR<=e' "$path" \
    | grep -qiE "$SAFE_PRIMITIVES_RE"
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
