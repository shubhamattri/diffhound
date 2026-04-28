#!/usr/bin/env bash
# auth-gate-precedes-check.sh — DROP findings that claim a function is
# vulnerable to IDOR / cross-org access / missing org-scope when the function
# definition is preceded by an `ensureAuthorized` (or similar) call that
# restricts to a privileged role (admin / batman / cx_manager / system_admin).
#
# Driven by PR #7145 v0.5.7 + v0.5.8 reviews: the SAME delete-mutation FP
# repeated across rounds 19:48, 20:10, 20:34, 20:44, 20:55. Every round
# flagged `deleteBrDeckJob` / `deleteBrDeckRun` as "any account admin can
# delete other orgs' jobs (IDOR)" while the actual code restricts to
# `(user) => user.isAdmin || user.isBatman` at the auth gate — account
# admins are blocked at `ensureAuthorized` and never reach the body.
#
# Trigger conditions (BOTH must hold):
#   1. WHAT contains explicit IDOR / missing-scope wording — see IDOR_WORDS.
#   2. WHAT names a backticked function symbol (e.g. `deleteBrDeckJob`)
#      whose definition exists in the FINDING file path.
#
# Action:
#   - Locate the function definition inside the FINDING file.
#   - Within ~25 lines after the definition (the typical mutation-body
#     window before the actual work begins), search for an
#     `ensureAuthorized` call whose predicate restricts to a privileged
#     role pattern: literal `isAdmin` / `isBatman` / `isCxManager` in
#     the body, or a delegated helper `userHasGlobalBrDeckAccess` /
#     `userIsSystemAdmin`.
#   - If such a gate is found → DROP. The "any user can reach this" claim
#     is contradicted by the auth gate that runs before the body.
#
# False-drop guard:
#   - Restrictive predicates only — `userCanAccessBrDeck` / `userCanX` style
#     helpers that DO permit account admins are NOT considered restrictive.
#     Specifically requires `isAdmin` + `isBatman` (or the global-access
#     helper) — the patterns Nova uses for "platform operators only" gates.
#   - ABSENCE_WORDS exemption (mirrors sibling validators): if WHAT contains
#     deletion / removal phrasing about the auth gate itself, the gate may
#     have been removed in this PR — keep the finding.
#   - File-not-readable / function-not-found / no auth gate present →
#     no-op (can't verify, don't drop).
#
# Pipeline placement: AFTER cross-file-comparison-check, BEFORE
# pre-existing-pattern. Same band as the other v0.5.7+ evidence-grep
# validators.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# IDOR / missing-scope wording families. Conservative — we want to fire on
# claims that allege a body-reachability gap, not generic auth concerns.
IDOR_WORDS_1='\b(IDOR|cross-?org|cross-?tenant)\b'
IDOR_WORDS_2='\b(missing|no|without|skips?)\s+(org|tenant|account|ownership)[-\s]+(scope|scoping|check|verification|guard|isolation)'
IDOR_WORDS_3='\b(any|every)\s+(account[\s-]?admin|user|caller|admin)\s+(can|could|may)\s+(delete|update|modify|access|fetch|read|export|view|trigger)\s+(other|another|any|cross-org)'
IDOR_WORDS_4='\borg\s+A\s+(admin|user|caller).*\b(delete|access|export|fetch|read)\s+org\s+B\b'

# Auth-gate predicates that count as "platform operators only." The patterns
# Nova uses are `isAdmin || isBatman` (sometimes plus `isCxManager`) or the
# `userHasGlobalBrDeckAccess` helper that wraps the same set. Treating
# `userCanAccessBrDeck` as NON-restrictive is intentional: it returns true
# for account admins, so a finding that flags an IDOR on a function gated
# only by `userCanAccessBrDeck` is potentially legitimate (account admins
# can reach the body — body-side org-scope is what saves them).
RESTRICTIVE_GATE_RE='ensureAuthorized.*(isAdmin.*isBatman|isBatman.*isAdmin|userHasGlobalBrDeckAccess|userIsSystemAdmin|isSystemAdmin)'

# Absence-wording exemption. Same shape as ref-exists / migration-column-check.
ABSENCE_WORDS='deleted|removed|dropped|drops the|drop the|after .* drops|removes the|no longer (defined|present|exists|enforces|checks|guards)|was renamed|has been (deleted|removed|renamed|dropped)'

# File-extension whitelist — only check source files where the auth-gate
# pattern makes sense.
SRC_EXTS='ts|tsx|js|jsx|py'

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
  printf '[auth-gate-precedes-check] DROPPED (%s): %s\n' \
    "$reason" "$header_prefix" >&2
}

# Match any of the 4 IDOR-wording alternatives.
_has_idor_wording() {
  local text="$1"
  printf '%s' "$text" | grep -qiE -- "$IDOR_WORDS_1" && return 0
  printf '%s' "$text" | grep -qiE -- "$IDOR_WORDS_2" && return 0
  printf '%s' "$text" | grep -qiE -- "$IDOR_WORDS_3" && return 0
  printf '%s' "$text" | grep -qiE -- "$IDOR_WORDS_4" && return 0
  return 1
}

_extract_path() {
  local header="$1"
  header="${header#FINDING: }"
  printf '%s' "${header%%:*}"
}

_check_and_emit() {
  if [ -z "$block" ]; then return; fi

  # Absence-wording exemption — finding might be about an auth gate that was
  # removed by THIS PR. Don't drop.
  if printf '%s' "$what" | grep -qiE -- "$ABSENCE_WORDS"; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi

  # Need IDOR wording.
  if ! _has_idor_wording "$what"; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi

  # Need a resolvable source-file anchor.
  if [ -z "$finding_path" ]; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi
  case "$finding_path" in
    *.ts|*.tsx|*.js|*.jsx|*.py) ;;
    *) _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return ;;
  esac

  local full_path="$DIFFHOUND_REPO/$finding_path"
  if [ ! -f "$full_path" ]; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi

  # Extract backticked function-shaped symbols. Match identifier characters
  # only (no spaces, no dots) so we don't grab phrases.
  local syms
  syms=$(printf '%s' "$what" \
    | grep -oE '`[A-Za-z_][A-Za-z0-9_]+`' \
    | tr -d '`' \
    | sort -u || true)

  if [ -z "$syms" ]; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; return
  fi

  local found_gate=""
  while IFS= read -r sym; do
    [ -z "$sym" ] && continue
    # Find the line where the symbol is defined as a top-level export /
    # const / function / mutation. Conservative — match common shapes used
    # in Nova's GraphQL mutation files. The (Mutation|Resolver|Query|Handler|
    # Function|Service|Helper)? suffix list lets findings refer to the
    # operation name (e.g. `deleteBrDeckJob`) when the file actually defines
    # a suffixed identifier (`deleteBrDeckJobMutation`):
    #   export const fooMutation = mutationWithClientMutationId({
    #   export const foo = mutation...
    #   async function foo(...)
    #   const foo = ... =>
    local def_line
    def_line=$(grep -nE "(export\s+(const|function|async\s+function)\s+${sym}(Mutation|Resolver|Query|Handler|Function|Service|Helper)?\b|^\s*(const|function|async\s+function)\s+${sym}(Mutation|Resolver|Query|Handler|Function|Service|Helper)?\b)" "$full_path" \
                 | head -1 \
                 | cut -d: -f1 || true)

    if [ -z "$def_line" ]; then
      continue
    fi

    # Look for a restrictive ensureAuthorized within the next 25 lines.
    local gate_line
    gate_line=$(awk -v start="$def_line" -v window=25 \
      'NR >= start && NR <= start + window' "$full_path" \
      | grep -E "$RESTRICTIVE_GATE_RE" \
      | head -1 || true)

    if [ -n "$gate_line" ]; then
      found_gate="${found_gate}${sym} "
    fi
  done <<< "$syms"

  if [ -n "$found_gate" ]; then
    _drop_block "function(s) [${found_gate% }] gated by isAdmin/isBatman/global-access predicate before body; IDOR claim contradicted"
    block=""; what=""; header_prefix=""; finding_path=""
    return
  fi

  _emit_block; block=""; what=""; header_prefix=""; finding_path=""
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
