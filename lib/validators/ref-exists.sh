#!/usr/bin/env bash
# ref-exists.sh — DROP findings claiming a symbol is "defined/duplicate/
# mutates/overrides" in a file when the symbol isn't actually there.
# ANNOTATE findings without those keywords (symbol may legitimately be
# missing — e.g. "should call X" — that's a real finding, not a hallucination).
#
# Reads FINDING: blocks on stdin, writes kept/annotated blocks to stdout,
# drops to stderr. DIFFHOUND_REPO must point to the PR's working tree.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Wordings that assert the symbol IS already in the flagged file. If symbol
# is missing AND wording matches → DROP. Otherwise ANNOTATE.
#
# Expanded 2026-04-23 (v0.5.0) for PR #127 hallucinated-comparison patterns.
# Expanded 2026-04-29 (v0.5.7) for PR #7145 F4 behavior-assertion patterns:
# "`persistWithRetry` runs 3 retries with 500ms backoff" — the LLM invents
# a function and confidently describes its (non-existent) behavior. Patterns
# like "X runs N", "X throws", "X returns", "X calls" are subject-verb
# assertions that require the subject to exist.
EXISTENCE_WORDS='defined|duplicate|duplicated|mutates|overrides|redefines|already exists|already defined|bypasses|inconsistent with|deviates from|differs from|breaks the .* pattern|should follow the pattern|unlike the existing|runs [0-9]+|throws (a|an)|returns (a|an|the)|calls [`a-zA-Z]|implements|emits|invokes|reads from|writes to|fires (a|an|the)'

# Wordings that assert the symbol IS supposed to be ABSENT — these are
# legit findings about deletions/removals/missing references and must NOT
# be dropped just because the symbol is absent. Added v0.5.7 per Gemini
# peer review counterexample: "Function `foo` was deleted but still
# referenced" — symbol absence is the finding, not a hallucination.
ABSENCE_WORDS='deleted|removed|missing|no longer|absent|stripped|dropped from|gone from|was renamed|has been (deleted|removed|renamed)|undefined export'

# Skiplist — well-known framework / runtime / test-harness names that are
# always "in scope" and shouldn't trigger absence-based drops. Expanded
# v0.5.7 per Gemini peer review for jest globals (PR #7145 had hallucinated
# function-name claims in spec files where jest globals abound).
SKIPLIST='^(expect|it|describe|test|jest|beforeEach|afterEach|beforeAll|afterAll|fn|spyOn|mock|requireActual|isolateModules|fail|console|process|Buffer|Array|Object|String|Number|Boolean|Date|RegExp|Error|Promise|Symbol|Map|Set|JSON|Math|setTimeout|setInterval|clearTimeout|clearInterval|require|module|exports|import|export|async|await|return|throw|true|false|null|undefined|toEqual|toBe|toBeTruthy|toBeFalsy|toBeDefined|toBeUndefined|toBeNull|toMatchObject|toMatchSnapshot|toContain|toContainEqual|toHaveBeenCalled|toHaveBeenCalledWith|toHaveBeenCalledTimes|toHaveLength|toHaveProperty|toThrow|toThrowError|toResolve|toReject|toMatch|mockResolvedValue|mockResolvedValueOnce|mockRejectedValue|mockRejectedValueOnce|mockImplementation|mockImplementationOnce|mockReturnValue|mockReturnValueOnce|mockClear|mockReset|mockRestore|each|resolves|rejects|not)$'

block=""
what_line=""
header_file=""
sym=""
# v0.5.7: track ALL backticked plain identifiers seen across WHAT/EVIDENCE,
# space-separated and deduped. The legacy `sym` (first only) is kept for
# the annotation path; existence-wording drops scan all.
all_syms=""

_check_symbol_present() {
  # Args: $1 = symbol. Returns 0 if symbol appears (outside comments) in
  # cited file OR a sibling .ts/.tsx/.js/.py file in the same directory.
  # Sibling-dir search added v0.5.7 (Gemini review): F4-class hallucinations
  # may name a function that lives in an adjacent file. Without sibling
  # search, false drops dominate when the LLM cites a test file but the
  # function is in the source file next to it.
  local s="$1"

  # Skip well-known framework names — they're "always present" and trying
  # to ground them produces noise.
  if printf '%s' "$s" | grep -qE -- "$SKIPLIST"; then
    return 0
  fi

  local primary="$DIFFHOUND_REPO/$header_file"
  if [ -f "$primary" ]; then
    if grep -v -E '^[[:space:]]*(#|//|\*)' "$primary" | grep -Fq -- "$s"; then
      return 0
    fi
    # Sibling-dir search — same comment-stripping as primary, applied to
    # each sibling file. Excludes the primary file (already checked) so
    # comment-only mentions in primary don't sneak in via the broader
    # find. Loops via -print0 for filenames with spaces (rare in source
    # trees but defensive).
    local sibdir
    sibdir=$(dirname "$primary")
    if [ -d "$sibdir" ]; then
      local sibfile
      while IFS= read -r -d '' sibfile; do
        [ "$sibfile" = "$primary" ] && continue
        if grep -v -E '^[[:space:]]*(#|//|\*)' "$sibfile" 2>/dev/null | grep -Fq -- "$s"; then
          return 0
        fi
      done < <(find "$sibdir" -maxdepth 1 -type f \
        \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.py' \) \
        -print0 2>/dev/null)
    fi
  fi
  return 1
}

_classify_and_flush() {
  if [ -z "$block" ]; then return; fi

  local path="$DIFFHOUND_REPO/$header_file"
  if [ -z "$header_file" ] || [ ! -f "$path" ]; then
    printf '%s' "$block"
    block=""; what_line=""; header_file=""; sym=""; all_syms=""
    return
  fi

  # Gemini-mitigation: if absence-wording is present, this is a finding
  # ABOUT something being missing. Symbol-not-found is the finding, not a
  # hallucination. Skip the drop logic entirely.
  if printf '%s' "$what_line" | grep -qiE "$ABSENCE_WORDS"; then
    printf '%s' "$block"
    block=""; what_line=""; header_file=""; sym=""; all_syms=""
    return
  fi

  local has_existence_wording=0
  if printf '%s' "$what_line" | grep -qiE "$EXISTENCE_WORDS"; then
    has_existence_wording=1
  fi

  # v0.5.7: scan ALL backticked symbols. Drop on FIRST missing one when
  # existence-wording is present. Need ALL symbols missing? No — single
  # missing-with-existence-wording is enough; F4 had `setTimeout` (present)
  # AND `persistWithRetry` (hallucinated). Dropping on persistWithRetry
  # alone is correct.
  local missing_sym=""
  if [ "$has_existence_wording" -eq 1 ]; then
    local s
    for s in $all_syms; do
      [ -z "$s" ] && continue
      if ! _check_symbol_present "$s"; then
        missing_sym="$s"
        break
      fi
    done
  fi

  if [ -n "$missing_sym" ]; then
    printf '[ref-exists] DROPPED (hallucinated symbol "%s" with existence-asserting wording): %s\n' \
      "$missing_sym" "$(printf '%s' "$block" | head -1)" >&2
    block=""; what_line=""; header_file=""; sym=""; all_syms=""
    return
  fi

  # Annotate-keep path: if first-extracted sym is missing and we got here
  # without existence wording, leave a hint for the reader.
  if [ -n "$sym" ] && ! _check_symbol_present "$sym"; then
    block=$(printf '%s' "$block" | awk -v sym="$sym" -v file="$header_file" '
      BEGIN { done = 0 }
      /^WHAT:/ && !done { print $0 " [ref-exists: '\''" sym "'\'' not found in " file "]"; done=1; next }
      { print }
    ')
    block="${block}"$'\n'
  fi

  printf '%s' "$block"
  block=""; what_line=""; header_file=""; sym=""; all_syms=""
}

_collect_syms() {
  # Args: $1 = line. Adds backticked plain identifiers to $all_syms (deduped).
  local line="$1" syms s
  syms=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | tr -d '`' | sort -u || true)
  for s in $syms; do
    case " $all_syms " in
      *" $s "*) ;;
      *) all_syms="${all_syms}${s} " ;;
    esac
  done
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _classify_and_flush
      block="$line"$'\n'
      header="${line#FINDING: }"
      header_file="${header%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      what_line="$line"
      sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`' || true)
      _collect_syms "$line"
      ;;
    EVIDENCE:*)
      block+="$line"$'\n'
      if [ -z "$sym" ]; then
        sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`' || true)
      fi
      _collect_syms "$line"
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_classify_and_flush
