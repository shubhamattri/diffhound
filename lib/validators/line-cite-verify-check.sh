#!/usr/bin/env bash
# line-cite-verify-check.sh — DROP findings whose backticked identifiers
# don't appear within ±5 lines of the FINDING's cited file:line.
#
# Driven by PR #7145 v0.6.0-deployed FPs at the 22:10 (79/100) round:
#   - "redundant `.forUpdate()` at exportHandlers.ts:276" — the only forUpdate
#     in the file is at line 875; line 276 is inside sanitizeJsonNode (no SQL).
#   - "`computeEarnedPremium` formula untested at metricsService.ts:146" —
#     no function by that name exists anywhere in services/api/src/brDeck/.
#
# Both slip through ref-exists.sh because the wording isn't "X doesn't exist"
# — it asserts X exists at a specific location. v0.6.0's evidence injection
# blocks negative-existence hallucinations; this validator blocks the
# positive-assertion-at-a-specific-line variant.
#
# Trigger conditions (BOTH must hold):
#   1. FINDING line carries a resolvable file:line citation
#   2. WHAT contains at least one backticked function-shaped identifier
#      (`fooBar`, `Foo.bar`, `.fooBar()` etc.)
#
# Action:
#   - For each backticked identifier in WHAT, search ±5 lines around the
#     cited line in the FINDING file (10-line window).
#   - If the identifier is not found in that window AND not found anywhere
#     in the file → DROP. The line citation is detached from what's being
#     claimed.
#   - If the identifier IS in the file but not in the window → also DROP.
#     The cited line number is wrong; reviewer can't verify the claim
#     against the cited evidence.
#
# False-drop guards:
#   - SKIPLIST of common framework / language tokens (forEach, map, filter,
#     await, async, return, ...) so generic verbs don't trigger the validator
#     against legitimate findings.
#   - ABSENCE_WORDS exemption — "X was deleted from line N" / "removed at line N"
#     should keep the finding (the symbol legitimately isn't there because the
#     PR removed it).
#   - Min identifier length 5 chars — single-word noun matches add noise.
#   - Only fires when the finding has at least one backticked id (otherwise
#     it's commentary, not a verifiable claim).
#   - File-not-readable / line-out-of-range → no-op.
#
# Pipeline placement: AFTER auth-gate-precedes-check, BEFORE pre-existing-
# pattern. Same v0.5.7+ evidence-grep band.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Common JS/TS / English filler that appears as backticked tokens in legit
# findings without being claims about a specific line's contents.
SKIPLIST_RE='^(forEach|map|filter|reduce|find|findOne|findIndex|some|every|includes|indexOf|slice|splice|push|pop|shift|unshift|sort|reverse|join|split|trim|toLowerCase|toUpperCase|charAt|charCodeAt|substring|substr|replace|replaceAll|match|test|exec|valueOf|toString|hasOwnProperty|then|catch|finally|resolve|reject|all|race|allSettled|any|next|prev|done|value|key|name|type|id|err|error|true|false|null|undefined|this|self|new|of|in|as|is|do|to|on|at|or|and|not|the|a|an|it|its|be|its|util|utils|src|test|tests|spec|specs|exports|module|require|import|export|default|async|await|return|throw|try|class|function|const|let|var|interface|enum|type|extends|implements)$'

# Wording families that LEGITIMATELY claim a symbol is absent from a line —
# don't fire when the finding is precisely about a deletion / removal.
ABSENCE_WORDS='deleted|removed|dropped|never (called|invoked|used|appears|references)|no longer (defined|present|exists)|was renamed|has been (deleted|removed|renamed|dropped)|not in the (file|module|source)|not present|missing from|nowhere'

block=""
what=""
header_prefix=""
finding_path=""
finding_line=""

_emit_block() {
  [ -z "$block" ] && return
  printf '%s' "$block"
}

_drop_block() {
  local reason="$1"
  printf '[line-cite-verify-check] DROPPED (%s): %s\n' \
    "$reason" "$header_prefix" >&2
}

_extract_path_and_line() {
  local header="$1"
  header="${header#FINDING: }"
  finding_path="${header%%:*}"
  local rest="${header#*:}"
  finding_line="${rest%%:*}"
  case "$finding_line" in
    ''|*[!0-9]*) finding_line="" ;;
  esac
}

_check_and_emit() {
  if [ -z "$block" ]; then return; fi

  # Need an absence-wording exemption check first — otherwise we'd drop
  # legitimate "X was removed from this line" findings.
  if printf '%s' "$what" | grep -qiE -- "$ABSENCE_WORDS"; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; finding_line=""; return
  fi

  # Need both file path and line number from the FINDING.
  if [ -z "$finding_path" ] || [ -z "$finding_line" ]; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; finding_line=""; return
  fi
  case "$finding_path" in
    *.ts|*.tsx|*.js|*.jsx|*.py|*.vue) ;;
    *) _emit_block; block=""; what=""; header_prefix=""; finding_path=""; finding_line=""; return ;;
  esac

  local full_path="$DIFFHOUND_REPO/$finding_path"
  if [ ! -f "$full_path" ]; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; finding_line=""; return
  fi

  # Extract backticked identifiers. Trim trailing punctuation / parens and
  # any leading dot (writers often put `.forUpdate()` to indicate a method
  # call rather than `forUpdate` directly — both should match against the
  # same source identifier).
  local syms
  syms=$(printf '%s' "$what" \
    | grep -oE '`\.?[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?(\(\))?`' \
    | tr -d '`' \
    | sed 's/()$//' \
    | sed 's/^\.//' \
    | sort -u || true)

  if [ -z "$syms" ]; then
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; finding_line=""; return
  fi

  # Compute window bounds: ±5 lines around the cited line.
  local window_start=$((finding_line - 5))
  [ "$window_start" -lt 1 ] && window_start=1
  local window_end=$((finding_line + 5))

  # Pull the window contents.
  local window
  window=$(awk -v s="$window_start" -v e="$window_end" 'NR >= s && NR <= e' "$full_path" 2>/dev/null || true)
  [ -z "$window" ] && {
    _emit_block; block=""; what=""; header_prefix=""; finding_path=""; finding_line=""; return
  }

  # For each backticked symbol, check window membership. We only DROP if
  # AT LEAST ONE backticked id is missing from the window — that's the
  # signal of a wrong-line or hallucinated-symbol citation.
  local missing=""
  while IFS= read -r sym; do
    [ -z "$sym" ] && continue
    # Skip generic/framework tokens.
    if printf '%s' "$sym" | grep -qiE -- "$SKIPLIST_RE"; then
      continue
    fi
    # Skip very short identifiers.
    if [ "${#sym}" -lt 5 ]; then
      continue
    fi

    # For Foo.bar, check the unqualified method name too — the file may
    # use an aliased import or destructured form.
    local methonly="${sym##*.}"

    # Window check (fixed-string match — don't accidentally regex-meta the dot).
    if printf '%s' "$window" | grep -qF -- "$sym"; then
      continue  # found in window
    fi
    if [ "$methonly" != "$sym" ] && printf '%s' "$window" | grep -qF -- "$methonly"; then
      continue  # qualified-name mismatch but unqualified found — accept
    fi

    # Not in window. Check whole file before flagging — if the symbol is
    # in the file at all, the finding's LINE citation is wrong (still a
    # drop). If not in the file at all, the symbol is hallucinated.
    if grep -qF -- "$sym" "$full_path" 2>/dev/null; then
      missing="${missing}${sym}#wrong-line "
    elif [ "$methonly" != "$sym" ] && grep -qF -- "$methonly" "$full_path" 2>/dev/null; then
      # qualified-name not in file but method name is — accept (different class)
      continue
    else
      missing="${missing}${sym}#absent "
    fi
  done <<< "$syms"

  if [ -n "$missing" ]; then
    _drop_block "cited identifiers not at line $finding_line: ${missing% }"
    block=""; what=""; header_prefix=""; finding_path=""; finding_line=""
    return
  fi

  _emit_block; block=""; what=""; header_prefix=""; finding_path=""; finding_line=""
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _check_and_emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      _extract_path_and_line "$line"
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
