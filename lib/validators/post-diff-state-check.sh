#!/usr/bin/env bash
# post-diff-state-check.sh — DROP findings asserting "no test exists for X" /
# "dead guard Y" / "X is missing" when the post-diff tree on disk actually
# contains the asserted-missing artifact.
#
# Driven by monorepo PR #7286 + PR #7293 (BF-43) reviews, 2026-05-29:
#
#   PR #7286: bot's nit said `zohoBooksCommissionStatement.ts:117 — dead
#   !matchedSalesOrder guard after the length-1 check on line 113, safe to
#   remove`. The named guard was REMOVED in this very diff. The bot read
#   pre-diff code as if it were post-diff current.
#
#   PR #7293: bot's SHOULD-FIX said `zohoBooksCommissionStatement.unit.spec.ts
#   — findSalesOrderMatch got meaningfully changed (...) but the processor
#   test file doesn't have corresponding updates`. False — a NEW dedicated
#   spec file findSalesOrderMatch.unit.spec.ts was added in the same diff,
#   covering exactly the changed surface. The bot read one spec, missed the
#   new sibling.
#
# Both FPs share a shape: an assertion about ABSENCE that can be falsified by
# greppting the post-diff state on disk for the named artifact. Citation-
# discipline + verifier didn't catch them — the file/line citations are
# syntactically valid, the symbols all exist; what the bot asserts is "this
# does NOT exist" and that claim isn't reachable through verifier's existence
# probe. This validator runs the inverse probe: did the bot say something is
# missing when in fact it's right here?
#
# Trigger (any one of three families):
#   1. DEAD GUARD: WHAT matches `\bdead\s+(guard|check|code|branch|condition)`
#      AND contains a backticked identifier. Bot claims guard is dead — must
#      verify the named identifier still exists post-diff.
#   2. MISSING TEST (explicit absence): WHAT matches
#      `\bno\s+(test|spec|coverage)\s+(file|for|covering|exists)` OR
#      `\bmissing\s+(test|spec|coverage)`. Bot claims a test is missing.
#   3. FILE LACKS UPDATES: WHAT matches
#      `\b(file|test|spec)\s+(doesn't|does not|isn't|is not)\s+(have|updated|been updated)`
#      OR `\bno corresponding (test|spec|update)`. Bot claims a file lacks
#      expected change.
#
# Action:
#   DEAD GUARD path:
#     - Identifier = first backticked token in WHAT matching
#       `[a-zA-Z_][a-zA-Z0-9_]*` with length >= 4 (skip "data"/"key"/etc.).
#     - Grep the FINDING file (post-diff version on disk) for the identifier
#       in a guard context: preceded by `!`, `if (`, `&&`, `||`, or `? :`.
#     - If found in guard context → DROP. The guard isn't actually dead.
#
#   MISSING TEST / FILE LACKS UPDATES path:
#     - Extract feature dir from the FINDING file path (parent dir).
#     - For each backticked symbol/function name in WHAT (len >= 4):
#       grep the test-file family under the same feature dir for that
#       symbol. Test-file family covers:
#         *.spec.ts *.test.ts *.spec.js *.test.js *.unit.spec.ts
#         tests/ __tests__/ subdirectories
#       Use a 3-level upward search (feature dir, parent, grandparent) to
#       catch reasonable sibling-test placements.
#     - If found in ANY test file → DROP. Bot missed the sibling test file.
#     - Fallback when WHAT has 0 backticked symbols but mentions a file by
#       name: extract the named file's BASENAME-without-spec-suffix as the
#       symbol candidate, then run the same test-file sweep. Driven by
#       PR #7293 wording variant ("the processor test file doesn't have
#       corresponding updates" — the symbol that matters lives in
#       findSalesOrderMatch which IS backticked elsewhere in WHAT).
#
# False-drop guards:
#   - ABSENCE_WORDS exemption — claims about a guard/test that was REMOVED in
#     this diff (regression). Same shape as sibling validators.
#   - DEAD GUARD: 0 backticked identifiers → no-op (can't verify).
#   - DEAD GUARD: identifier shorter than 4 chars → skip (too noisy).
#   - DEAD GUARD: FINDING file not readable on disk → no-op.
#   - MISSING TEST: 0 backticked identifiers AND 0 backticked filenames → no-op.
#   - MISSING TEST: feature dir doesn't exist on disk → no-op.
#   - Opt-out: DIFFHOUND_DISABLE_POST_DIFF_STATE_CHECK=1.
#
# Pipeline placement: AFTER helper-property-check (5ccc), BEFORE
# auth-gate-precedes-check (5d). Same band as the "structural reachability"
# validators that grep the post-diff tree for evidence.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

if [ "${DIFFHOUND_DISABLE_POST_DIFF_STATE_CHECK:-0}" = "1" ]; then
  cat
  exit 0
fi

# ────────────────────────────────────────────────────────────────────
# Wording gates

# DEAD GUARD family. Requires backticked identifier check downstream.
DEAD_GUARD_RE='\bdead\s+(guard|check|code|branch|condition)\b'

# MISSING TEST family (explicit absence).
MISSING_TEST_RE_1='\bno\s+(test|spec|coverage)\s+(file|for|covering|exists)\b'
MISSING_TEST_RE_2='\bmissing\s+(test|spec|coverage)\b'

# FILE LACKS UPDATES family.
LACKS_UPDATE_RE_1='\b(file|test|spec)\s+(doesn'"'"'t|does not|isn'"'"'t|is not)\s+(have|updated|been updated)\b'
LACKS_UPDATE_RE_2='\bno\s+corresponding\s+(test|spec|update)'

# ABSENCE_WORDS exemption — guard / test was just deleted in this diff.
ABSENCE_WORDS='deleted|removed|dropped|drops? the|removes? the|no longer (defined|present|exists|enforces|checks|guards|tested)|was renamed|has been (deleted|removed|renamed|dropped)|used to (have|cover|test|guard)|previously (had|covered|tested|guarded)|regression'

# Test-file globs. Longest alternative first to dodge BSD find regex gotcha.
TEST_GLOBS=(
  --include='*.unit.spec.ts'
  --include='*.spec.ts' --include='*.test.ts'
  --include='*.spec.tsx' --include='*.test.tsx'
  --include='*.spec.js' --include='*.test.js'
  --include='*.spec.jsx' --include='*.test.jsx'
  --include='*.spec.py' --include='*test*.py'
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build
  --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=coverage
)

# Source-file globs for the dead-guard grep (any TS/JS file).
SRC_GLOBS=(
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx'
  --include='*.py' --include='*.vue'
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build
  --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=coverage
)

# Built-in TS types and common short names to ignore in symbol candidates.
SKIP_IDENTS='^(Record|Promise|Array|Map|Set|String|Number|Boolean|Object|Date|RegExp|Error|null|true|false|undefined|void|any|unknown|never|this|self|data|item|args|opts|res|req|err|val|key|id|fn|cb|tmp|foo|bar|baz)$'

# ────────────────────────────────────────────────────────────────────
# State

block=""
what=""
header_prefix=""
finding_path=""

_emit_block() {
  [ -z "$block" ] && return
  printf '%s' "$block"
}

_reset() {
  block=""; what=""; header_prefix=""; finding_path=""
}

_drop_block() {
  local reason="$1"
  printf '[post-diff-state-check] DROPPED (%s): %s\n' \
    "$reason" "$header_prefix" >&2
}

# Extract file path from a FINDING header.
_extract_path() {
  local header="$1"
  header="${header#FINDING: }"
  local tok="${header%% *}"
  printf '%s' "${tok%%:*}"
}

# Extract backticked identifiers (len >= 4, not in SKIP_IDENTS). One per line.
# Tolerates leading `!` inside the backticks (bot wording often quotes the
# whole guard expression, e.g. `!matchedSalesOrder`).
_extract_identifiers() {
  printf '%s' "$what" \
    | grep -oE '`!?[A-Za-z_][A-Za-z0-9_]*(\(\))?`' \
    | tr -d '`()!' \
    | sort -u \
    | while IFS= read -r id; do
        [ -z "$id" ] && continue
        [ "${#id}" -lt 4 ] && continue
        printf '%s' "$id" | grep -qE -- "$SKIP_IDENTS" && continue
        printf '%s\n' "$id"
      done
}

# Extract backticked filenames (anything with a recognized source extension).
# Returns the basename without test-spec suffix as a candidate symbol.
_extract_filenames_as_symbols() {
  printf '%s' "$what" \
    | grep -oE '`[A-Za-z_][A-Za-z0-9_.-]*\.(unit\.spec|spec|test)\.(ts|tsx|js|jsx)`' \
    | tr -d '`' \
    | sed -E 's/\.(unit\.spec|spec|test)\.(ts|tsx|js|jsx)$//' \
    | sort -u
}

# Walk upward up to 3 dirs from $1 (relative path under repo).
# Emits absolute directory paths, deepest first.
_feature_search_dirs() {
  local rel="$1"
  [ -z "$rel" ] && return
  local cur
  cur=$(dirname "$rel")
  local i=0
  while [ "$i" -lt 3 ] && [ "$cur" != "." ] && [ "$cur" != "/" ] && [ -n "$cur" ]; do
    [ -d "$DIFFHOUND_REPO/$cur" ] && printf '%s/%s\n' "$DIFFHOUND_REPO" "$cur"
    cur=$(dirname "$cur")
    i=$((i + 1))
  done
}

# Check if identifier exists in a guard context inside the FINDING file.
# Guard contexts: `!ident`, `if (... ident`, `&& ident`, `|| ident`, `? ident`.
# Line-oriented grep (single line per match).
_ident_in_guard_context() {
  local id="$1" full="$2"
  # `!` prefix.
  grep -qE "!\s*\b${id}\b" "$full" 2>/dev/null && return 0
  # `if ( ... ident ... )` shape — ident appears on an `if` line.
  grep -qE "\bif\s*\(.{0,120}\b${id}\b" "$full" 2>/dev/null && return 0
  # `&&` or `||` before ident.
  grep -qE "(&&|\|\|)\s*!?\s*\b${id}\b" "$full" 2>/dev/null && return 0
  # Ternary `? ident : ...` or `ident ? ... : ...`.
  grep -qE "\?\s*!?\s*\b${id}\b" "$full" 2>/dev/null && return 0
  grep -qE "\b${id}\b\s*\?" "$full" 2>/dev/null && return 0
  return 1
}

# Search test-file family in feature dirs for any of the given identifiers.
# Returns 0 if any identifier is found in any test file.
_symbol_in_any_test_file() {
  local ids_file="$1"
  [ ! -s "$ids_file" ] && return 1
  local dir id
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      if grep -rqE "${TEST_GLOBS[@]}" "\b${id}\b" "$dir" 2>/dev/null; then
        # Record which file matched for the drop reason.
        local hit
        hit=$(grep -rlE "${TEST_GLOBS[@]}" "\b${id}\b" "$dir" 2>/dev/null | head -1)
        printf '%s|%s' "$id" "${hit#$DIFFHOUND_REPO/}"
        return 0
      fi
    done < "$ids_file"
  done < <(_feature_search_dirs "$finding_path")
  return 1
}

_check_and_emit() {
  if [ -z "$block" ]; then return; fi

  # Absence-wording exemption.
  if printf '%s' "$what" | grep -qiE -- "$ABSENCE_WORDS"; then
    _emit_block; _reset; return
  fi

  # Detect which trigger family fires.
  local is_dead_guard=0 is_missing_test=0
  if printf '%s' "$what" | grep -qiE -- "$DEAD_GUARD_RE"; then
    is_dead_guard=1
  fi
  if printf '%s' "$what" | grep -qiE -- "$MISSING_TEST_RE_1" \
   || printf '%s' "$what" | grep -qiE -- "$MISSING_TEST_RE_2" \
   || printf '%s' "$what" | grep -qiE -- "$LACKS_UPDATE_RE_1" \
   || printf '%s' "$what" | grep -qiE -- "$LACKS_UPDATE_RE_2"; then
    is_missing_test=1
  fi
  if [ "$is_dead_guard" -eq 0 ] && [ "$is_missing_test" -eq 0 ]; then
    _emit_block; _reset; return
  fi

  # ── DEAD GUARD path ──────────────────────────────────────────────
  # Three FP shapes all drop here:
  #   (a) Bot says "dead `X` guard" but `X` is still in guard context post-diff
  #       → bot's "dead" claim is wrong, guard is active.
  #   (b) Bot says "dead `X` guard" but `X` doesn't appear in the post-diff
  #       file at all → bot is reading pre-diff code (the guard was removed
  #       in this very diff, so the cited line doesn't exist in the post-diff).
  #   (c) Bot quotes a literal guard expression like `!matchedSalesOrder` —
  #       the `!`-prefixed phrase doesn't appear in the post-diff file even
  #       though the bare identifier might still be present as a value. This
  #       is the PR #7286 shape: the bot quoted pre-diff code where the
  #       guard expression `!matchedSalesOrder` lived, but in the post-diff
  #       the guard is gone and `matchedSalesOrder` only appears as a value
  #       (const destructure + property access). The quoted GUARD EXPRESSION
  #       not existing is the precise signal.
  # All three indicate the finding is unactionable — drop.
  if [ "$is_dead_guard" -eq 1 ]; then
    # Case (c) first: extract the literal backticked guard expression(s) that
    # carry a `!` prefix. If any such phrase is absent from the file → drop.
    local quoted_guard
    quoted_guard=$(printf '%s' "$what" \
      | grep -oE '`![A-Za-z_][A-Za-z0-9_]*`' \
      | tr -d '`' \
      | sort -u \
      | head -1 || true)
    if [ -n "$quoted_guard" ] && [ -n "$finding_path" ] && [ -f "$DIFFHOUND_REPO/$finding_path" ]; then
      # grep-F for literal string — `!` has no special meaning to grep but
      # using -F avoids any future regex surprise. Check word-ish boundary
      # with surrounding chars by simple substring match (sufficient for
      # the guard phrase shape).
      if ! grep -qF -- "$quoted_guard" "$DIFFHOUND_REPO/$finding_path" 2>/dev/null; then
        _drop_block "quoted guard expression '$quoted_guard' absent from post-diff ${finding_path} — bot quoting pre-diff/removed code"
        _reset; return
      fi
    fi

    local ids_tmp
    ids_tmp=$(mktemp -t "pdsc-ids.XXXXXX")
    _extract_identifiers > "$ids_tmp"
    if [ ! -s "$ids_tmp" ]; then
      rm -f "$ids_tmp"
      _emit_block; _reset; return
    fi
    # Need a resolvable finding file on disk for cases (a) and (b).
    if [ -z "$finding_path" ] || [ ! -f "$DIFFHOUND_REPO/$finding_path" ]; then
      rm -f "$ids_tmp"
      _emit_block; _reset; return
    fi
    local full="$DIFFHOUND_REPO/$finding_path"
    local id
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      # Case (a): guard still active post-diff.
      if _ident_in_guard_context "$id" "$full"; then
        rm -f "$ids_tmp"
        _drop_block "guard identifier '$id' still appears in guard context in ${finding_path} — 'dead' claim contradicted"
        _reset; return
      fi
      # Case (b): identifier doesn't appear in the post-diff file at all.
      if ! grep -qE "\b${id}\b" "$full" 2>/dev/null; then
        rm -f "$ids_tmp"
        _drop_block "guard identifier '$id' absent from post-diff ${finding_path} — bot quoting pre-diff/removed code"
        _reset; return
      fi
    done < "$ids_tmp"
    rm -f "$ids_tmp"
    # No drop trigger fired → keep.
    _emit_block; _reset; return
  fi

  # ── MISSING TEST path ────────────────────────────────────────────
  if [ "$is_missing_test" -eq 1 ]; then
    if [ -z "$finding_path" ]; then
      _emit_block; _reset; return
    fi
    local ids_tmp
    ids_tmp=$(mktemp -t "pdsc-ids.XXXXXX")
    _extract_identifiers > "$ids_tmp"
    # Fallback: if no plain identifiers, try basename-of-spec-file as symbol.
    if [ ! -s "$ids_tmp" ]; then
      _extract_filenames_as_symbols > "$ids_tmp"
    fi
    if [ ! -s "$ids_tmp" ]; then
      rm -f "$ids_tmp"
      _emit_block; _reset; return
    fi
    local hit_info
    if hit_info=$(_symbol_in_any_test_file "$ids_tmp"); then
      rm -f "$ids_tmp"
      local matched_id="${hit_info%%|*}"
      local matched_file="${hit_info#*|}"
      _drop_block "symbol '$matched_id' found in sibling test file ${matched_file}"
      _reset; return
    fi
    rm -f "$ids_tmp"
    _emit_block; _reset; return
  fi

  _emit_block; _reset
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _check_and_emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      finding_path=$(_extract_path "$line")
      ;;
    WHAT:*|EVIDENCE:*|IMPACT:*|OPTIONS:*|DIFF_LINE:*|REACHABLE_PATH:*|REJECTED_ALTERNATIVE:*)
      block+="$line"$'\n'
      what="${what}${line} "
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_check_and_emit
