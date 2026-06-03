#!/usr/bin/env bash
# claim-verify.sh — the single claim-verification engine.
#
# THE ABSTRACTION (replaces the pile of wording-specific validators):
#   Every finding rests on falsifiable factual claims about the code. Verify each
#   claim against ground truth before the finding influences verdict/score/output.
#   FALSE claim -> drop. UNVERIFIABLE -> cap at OPEN_QUESTION. TRUE -> keep.
#
# Claims come from two sources, in priority order:
#   1. EXPLICIT — a `CLAIMS:` line the model emits, "; "-separated, each claim:
#        type:subject:scopeOrLocation:expected
#      e.g.  CLAIMS: symbol_defined:usersCount:repo:false; dependency_version:marked::<4.0.0
#   2. IMPLICIT — extracted from the WHAT/EVIDENCE prose when no CLAIMS: line is
#      present (so the engine works before the model adopts the schema, and
#      subsumes ref-exists / vuln-symbol / reverify-absence / node-modules /
#      dependency-exists).
#
# Checker registry — one function per claim type, returns: TRUE | FALSE | UNVERIFIABLE
#   symbol_defined      — is `subject` defined anywhere in the repo?
#   dependency_version  — does `subject`'s package.json range satisfy `expected`?
#   file_contains       — does `location` contain `subject`?
#   call_reachable      — best-effort; UNVERIFIABLE unless clearly traceable.
#
# Gated by DIFFHOUND_CLAIM_VERIFY=1 (default off -> pass-through). Reads FINDING:
# blocks on stdin, writes kept/downgraded blocks to stdout, audit notes to stderr.
# DIFFHOUND_REPO must point to the PR working tree.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Default ON as of v0.7.18 (strangler flag flipped after the corpus + real-PR
# safety runs passed). Set DIFFHOUND_CLAIM_VERIFY=0 to force pass-through.
if [ "${DIFFHOUND_CLAIM_VERIFY:-1}" != "1" ]; then
  cat
  exit 0
fi

# Ground-truth checkers — single shared implementation (lib/claim-checkers.sh).
source "$(dirname "${BASH_SOURCE[0]}")/../claim-checkers.sh"


# ── main loop ────────────────────────────────────────────────────────────────
block=""
_flush() {
  [ -z "$block" ] && return 0
  local claims explicit
  explicit=$(printf '%s\n' "$block" | grep -m1 '^CLAIMS:' | sed 's/^CLAIMS:[[:space:]]*//')
  if [ -n "$explicit" ]; then claims="$explicit"; else claims=$(_extract_implicit_claims "$block"); fi

  if [ -n "$claims" ]; then
    local worst="TRUE" c v IFS_save="$IFS"
    IFS=';'
    for c in $claims; do
      c=$(printf '%s' "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$c" ] && continue
      v=$(_verify_claim "$c")
      if [ "$v" = "FALSE" ]; then worst="FALSE"; bad="$c"; break
      elif [ "$v" = "UNVERIFIABLE" ] && [ "$worst" = "TRUE" ]; then worst="UNVERIFIABLE"; bad="$c"; fi
    done
    IFS="$IFS_save"
    if [ "$worst" = "FALSE" ]; then
      printf '[claim-verify: DROP — claim FALSE: %s]\n' "$bad" >&2
      block=""; return 0
    elif [ "$worst" = "UNVERIFIABLE" ]; then
      printf '%s\n' "$(printf '%s' "$block" | sed -E "1 s#:[A-Za-z_-]+[[:space:]]*\$#:OPEN_QUESTION#")"
      printf '[claim-verify: DOWNGRADE to OPEN_QUESTION — claim unverifiable: %s]\n' "$bad" >&2
      block=""; return 0
    fi
  fi
  printf '%s\n' "$block"
  block=""
}

while IFS= read -r line || [ -n "$line" ]; do
  if [ "${line#FINDING:}" != "$line" ]; then _flush; fi
  block="${block:+$block$'\n'}$line"
done
_flush
