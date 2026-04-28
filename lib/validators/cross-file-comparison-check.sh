#!/usr/bin/env bash
# cross-file-comparison-check.sh — DROP findings that assert "X has the fix, Y
# doesn't" / "Y is missing the check" / "Y lacks the guard" when the file/path
# named on the FINDING line itself contains the supposedly-missing guard call.
#
# Driven by PR #7145 v0.5.7-deployed run (20:10 scorecard): a BLOCKING finding
# claimed "graphql path has the fix, REST doesn't" while the REST handlers in
# the very same file (exportHandlers.ts) called ensureExportOrgAccess at four
# distinct line numbers. The model wrote a comparison without grepping the
# "doesn't" side. This validator runs that grep.
#
# Trigger conditions (BOTH must hold):
#   1. WHAT contains an explicit comparison phrase signalling "X has it, Y
#      doesn't" — see CMP_WORDS below. Conservative wording match.
#   2. FINDING line carries a file path the validator can resolve under
#      $DIFFHOUND_REPO. The file path is what the finding *anchors on* —
#      so it represents the side being accused of missing the guard.
#
# Action:
#   - Grep the FINDING file for guard-helper call sites — names beginning
#     with ensure/assert/verify/check/require followed by an UpperCamel
#     identifier (Nova convention: ensureAccountAdminCanAccessBrDeckOrg,
#     ensureAuthorized, verifyToken, etc.).
#   - If the file contains TWO OR MORE such helper invocations → DROP. The
#     "Y lacks any guard" claim is contradicted by visible evidence.
#
# False-drop guard:
#   - Threshold is 2+ helpers, not 1, so files with a single legacy guard
#     don't trigger the drop when the finding might legitimately call for
#     more layered defense.
#   - ABSENCE_WORDS exemption (mirrors ref-exists.sh / migration-column-check
#     pattern): if WHAT contains deletion/removal phrasing, the comparison
#     might be about a guard that *was* there and got removed. Skip.
#   - File-not-readable → no-op (can't verify, don't drop).
#
# Pipeline placement: AFTER ref-exists, BEFORE pre-existing-pattern, in the
# same band as migration-column-check. High-confidence drops short-circuit
# the citation/severity gate downstream.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Comparison phrases that signal "one side has the fix, the other doesn't."
# Conservative — must include both an asymmetry verb (has/have) on the "good"
# side and a negation on the "bad" side, OR an explicit "missing in"/"lacks"
# pattern. Each phrase is one regex alternative; we look for ANY match.
CMP_WORDS='has (the |a )?(fix|check|guard|guard pattern|scoping|auth|authorization|validation|protection|safeguard).*\b(doesn'"'"'t|does not|lacks|is missing|are missing|fails to)\b'
CMP_WORDS_2='\b(missing|absent|lacking)\b\s+(in|on|from|at)\s+(\b(REST|graphql|GraphQL|frontend|backend|UI|the (REST|graphql|frontend|backend))\b|\`?[A-Za-z][A-Za-z0-9._/-]+\.(ts|tsx|js|jsx|py|vue)\b)'
CMP_WORDS_3='\b(only|just)\s+(graphql|REST|frontend|backend)\s+(has|have|enforces|checks)'
CMP_WORDS_4='\b(REST|graphql|frontend|backend)\s+(doesn'"'"'t|does not|fails to)\s+(check|verify|guard|enforce|scope|validate|authenticate|authorize)'

# Absence-wording exemption — the comparison is about a guard that was
# deleted/removed, not invented. Same shape used by sibling validators.
ABSENCE_WORDS='deleted|removed|dropped|drops the|drop the|after .* drops|removes the|no longer (defined|present|exists|enforces|checks|guards)|was renamed|has been (deleted|removed|renamed|dropped)'

# Guard-helper invocation pattern. Nova uses ensure/assert/verify/check/require
# helpers heavily; one of these in a file body is a strong signal that the
# file is not guard-less. Match must look like a function call (paren after).
GUARD_RE='\b(ensure|assert|verify|check|require)[A-Z][A-Za-z0-9_]*\s*\('

# File-extension whitelist — only check source files we know how to grep
# meaningfully. Avoid trying to grep migrations / .md / config files where
# helper-call patterns don't apply.
SRC_EXTS='ts|tsx|js|jsx|py|vue'

block=""
what=""
header_prefix=""
finding_path=""

_emit_block() {
  [ -z "$block" ] && return
  printf '%s' "$block"
}

_drop_block() {
  local reason="$1"
  printf '[cross-file-comparison-check] DROPPED (%s): %s\n' \
    "$reason" "$header_prefix" >&2
}

_check_and_emit() {
  if [ -z "$block" ]; then return; fi

  # Absence-wording exemption — finding might legitimately call out a guard
  # that was removed. Don't drop.
  if printf '%s' "$what" | grep -qiE -- "$ABSENCE_WORDS"; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi

  # Need a comparison phrase. Any of the four alternatives counts.
  if ! printf '%s' "$what" | grep -qiE -- "$CMP_WORDS" \
     && ! printf '%s' "$what" | grep -qiE -- "$CMP_WORDS_2" \
     && ! printf '%s' "$what" | grep -qiE -- "$CMP_WORDS_3" \
     && ! printf '%s' "$what" | grep -qiE -- "$CMP_WORDS_4"; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi

  # Need a resolvable source-file anchor on the FINDING line. The file path
  # is what the finding accuses; if the path is unreachable we can't verify.
  if [ -z "$finding_path" ]; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi
  case "$finding_path" in
    *.ts|*.tsx|*.js|*.jsx|*.py|*.vue) ;;
    *) _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return ;;
  esac

  local full_path="$DIFFHOUND_REPO/$finding_path"
  if [ ! -f "$full_path" ]; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi

  # Count guard-helper invocations in the accused file. 2+ → file is guarded;
  # the "Y lacks the guard" claim is false on its face.
  local guard_count
  guard_count=$(grep -cE "$GUARD_RE" "$full_path" 2>/dev/null || true)
  guard_count=${guard_count:-0}

  if [ "$guard_count" -ge 2 ]; then
    _drop_block "file $finding_path has $guard_count guard-helper invocations; comparison contradicted"
    block=""; what=""; header_prefix=""; finding_path=""
    return
  fi

  _emit_block; block=""; what=""; header_prefix=""; finding_path=""
}

# Extract the file path from a "FINDING: <path>:<line>" header.
_extract_path() {
  local header="$1"
  # Strip the "FINDING: " prefix if present.
  header="${header#FINDING: }"
  # Take everything before the first ':' (which separates path from line).
  printf '%s' "${header%%:*}"
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _check_and_emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      finding_path=$(_extract_path "$line")
      ;;
    WHAT:*)
      block+="$line"$'\n'
      what="${what}${line} "
      ;;
    EVIDENCE:*|IMPACT:*|OPTIONS:*)
      block+="$line"$'\n'
      what="${what}${line} "
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_check_and_emit
