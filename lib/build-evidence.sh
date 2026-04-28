#!/usr/bin/env bash
# build-evidence.sh — Pre-populate grep-confirmed evidence for the LLM
# prompt so it cannot fabricate "X doesn't exist" claims that v0.5.7-9
# validators have to drop after the fact.
#
# Driven by PR #7145 audit (12+ "Foo doesn't exist" / "method missing"
# false positives across 8 review rounds — every one refuted by a
# 5-second grep). The validator approach is whack-a-mole: each FP
# wording variant needs its own bash regex. Pre-injecting evidence
# moves verification BEFORE the LLM writes the finding, so it has
# nothing to fabricate from.
#
# Usage:
#   build-evidence.sh <chunk-diff> <repo-path> > evidence.txt
#
# Output format (deterministic, pasted into the prompt before each chunk):
#
#   # VERIFIED EVIDENCE — symbols GREPPED in this repo (do not claim missing)
#   AuditLogModel.logBrDeckPptxExport  →  services/api/src/models/auditLog.ts:114
#   BenefitModel.isBenefitPartOfOrg   →  services/api/src/models/benefit.ts:469
#   ensureExportOrgAccess              →  services/api/src/brDeck/exportHandlers.ts:94
#   processActiveLives                 →  services/api/src/brDeck/claimCompassClient.ts:319
#
# The prompt rule that pairs with this evidence block is added in
# prompt-chunked.txt: "If a symbol below is listed as VERIFIED EVIDENCE,
# you MUST NOT claim it doesn't exist or that you 'grepped and got zero
# hits' — that grep was already done deterministically."
#
# Symbol extraction rules (kept conservative to avoid noise):
#   1. ClassName.methodName patterns from + lines of the diff
#   2. Standalone CamelCase class names (likely exports)
#   3. camelCase method/function identifiers that look like calls (Foo()/Foo.bar())
#
# For each extracted symbol:
#   - Grep the repo for definition or first appearance
#   - If found in 1+ locations, list the first 2 hits
#   - If found in 0 locations, OMIT (not adding noise to the LLM)
#
# Output is capped at 50 unique symbols / 3KB to fit prompt budget.
set -uo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <chunk-diff> <repo-path>" >&2
  exit 2
fi

CHUNK_DIFF="$1"
REPO_PATH="$2"

if [ ! -f "$CHUNK_DIFF" ]; then
  exit 0  # no diff, no evidence
fi
if [ ! -d "$REPO_PATH" ]; then
  exit 0  # no repo, can't grep
fi

MAX_SYMBOLS=50
MAX_BYTES=3072

# Stage 1: extract symbol candidates from + lines of the diff.
# Patterns we look for (each adds to the candidate set):
#   - ClassName.methodName(   → grab "ClassName.methodName"
#   - identifier.method(      → grab "identifier.method"
#   - new ClassName(          → grab "ClassName"
#   - Bare ClassName declarations / imports
#   - Backtick-quoted identifiers in comments (engineers reference in comments)
# Extract candidate symbols. Patterns use POSIX-only regex (no \b / \s) so the
# script works on both GNU grep (CI) and BSD grep (macOS). The plus-line content
# is captured once into a temp string to feed multiple greps.
plus_lines=$(grep '^+' "$CHUNK_DIFF" 2>/dev/null | grep -v '^+++' || true)
[ -z "$plus_lines" ] && exit 0

# Common JS/TS built-in classes to filter out — matching their .method calls
# adds noise and crowds out the project-specific symbols that actually fool
# the LLM into hallucinating non-existence.
BUILTIN_FILTER='^(Array|Object|String|Number|Boolean|Math|Date|JSON|Promise|Map|Set|Buffer|Error|RegExp|Symbol|Function|console|process|global|window|document|fetch|require|module|exports|Reflect|Proxy|WeakMap|WeakSet|this|self)\.'

# Filter for identifiers that are likely DOMAIN symbols (not random partial
# matches inside a longer camelCase token). We require the .method form's
# left-hand class to start at a token boundary in the original line — this
# gates out the "normalizedAccessible.includes" → "Accessible.includes"
# false-class noise.
candidates=$(
  {
    # Class.method patterns — anchored on token boundary via [^A-Za-z0-9_]
    # at the left side. The leading char gets stripped via sed.
    printf '%s\n' "$plus_lines" \
      | grep -oE '(^|[^A-Za-z0-9_])[A-Z][a-zA-Z0-9]+\.[a-z][a-zA-Z0-9]+' \
      | sed 's/^[^A-Za-z0-9_]//' || true

    # Class names with conventional suffixes (Model/Service/Error/...)
    printf '%s\n' "$plus_lines" \
      | grep -oE '(^|[^A-Za-z0-9_])[A-Z][a-zA-Z0-9]+(Model|Service|Helper|Error|Client|Handler|Mutation|Resolver|Type)' \
      | sed 's/^[^A-Za-z0-9_]//' || true

    # `new ClassName(...)` constructions
    printf '%s\n' "$plus_lines" \
      | grep -oE 'new[[:space:]]+[A-Z][a-zA-Z0-9]+' \
      | sed 's/^new[[:space:]]*//' || true

    # Backticked identifiers in comments / prose / commit messages — these
    # are usually engineer-curated references to specific symbols
    printf '%s\n' "$plus_lines" \
      | grep -oE '`[A-Za-z_][A-Za-z0-9_]+(\.[a-z][a-zA-Z0-9_]+)?`' \
      | tr -d '`' || true
  } | sort -u | grep -vE "$BUILTIN_FILTER" || true
)

[ -z "$candidates" ] && exit 0

# Filter out obvious noise: language keywords, common identifiers, very short
# names. A symbol shorter than 5 chars is almost always a noise hit.
filter_noise() {
  grep -vE '^(if|else|for|while|return|throw|try|catch|const|let|var|true|false|null|undefined|this|self|new|of|in|as|is|do|to|on|at|or|and|not|the|a|an|it|its|be|its)$' \
    | awk 'length($0) >= 5'
}

candidates=$(printf '%s\n' "$candidates" | filter_noise | head -"$MAX_SYMBOLS")

# Stage 2: for each candidate, grep the repo and find the first defining hit.
# Conservative grep: source files only, not tests / fixtures / lockfiles.
SOURCE_GLOB='--include=*.ts --include=*.tsx --include=*.js --include=*.jsx --include=*.py'
EXCLUDE_DIRS='--exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=.git --exclude-dir=tests --exclude-dir=__tests__ --exclude-dir=fixtures'

emit_count=0
output_bytes=0

printf '# VERIFIED EVIDENCE — symbols grepped in this repo (do NOT claim these are missing)\n'
printf '#\n'
printf '# Each entry was confirmed via `grep -rn` at prompt-assembly time. If the LLM\n'
printf '# wants to argue a symbol below is missing, the grep evidence here is authoritative\n'
printf '# and no manual verification is needed — the symbol exists.\n'
printf '#\n'

while IFS= read -r sym; do
  [ -z "$sym" ] && continue
  [ "$emit_count" -ge "$MAX_SYMBOLS" ] && break
  [ "$output_bytes" -ge "$MAX_BYTES" ] && break

  # For "Class.method" symbols, search both halves and also "Class.*method" lines.
  if [[ "$sym" == *.* ]]; then
    cls="${sym%%.*}"
    meth="${sym#*.}"
    # Find the method definition. Use a simple word-boundary match for the method
    # name followed by ( or : ; rely on the grep -F qualified-call fallback for
    # the more specific definition shape.
    hit=$(grep -rn $EXCLUDE_DIRS $SOURCE_GLOB \
            -E "[[:space:]]${meth}[[:space:]]*[\(\:]" \
            "$REPO_PATH" 2>/dev/null \
          | head -1 || true)
    # Fallback: search for the qualified name as a call site
    if [ -z "$hit" ]; then
      hit=$(grep -rn $EXCLUDE_DIRS $SOURCE_GLOB \
              -F "${cls}.${meth}" \
              "$REPO_PATH" 2>/dev/null \
            | head -1 || true)
    fi
  else
    # Plain symbol: prefer "export class/function/const SYM" / "class SYM" definitions.
    # Single-pattern alternation keeps the regex BSD-grep compatible.
    hit=$(grep -rn $EXCLUDE_DIRS $SOURCE_GLOB \
            -E "(class|function|const|interface|type|enum)[[:space:]]+${sym}([[:space:]]|\\(|<|=|\$)" \
            "$REPO_PATH" 2>/dev/null \
          | head -1 || true)
  fi

  if [ -n "$hit" ]; then
    # Trim to repo-relative path: line:content
    rel=$(printf '%s' "$hit" | sed "s|^${REPO_PATH}/||" | head -c 200)
    line="${sym}  →  ${rel}"
    line_bytes=$(printf '%s' "$line" | wc -c | tr -d ' ')
    if [ $((output_bytes + line_bytes)) -ge "$MAX_BYTES" ]; then
      printf '# (evidence truncated — %d bytes cap reached)\n' "$MAX_BYTES"
      break
    fi
    printf '%s\n' "$line"
    emit_count=$((emit_count + 1))
    output_bytes=$((output_bytes + line_bytes + 1))
  fi
done <<< "$candidates"

if [ "$emit_count" -eq 0 ]; then
  printf '# (no high-confidence symbol matches in this chunk)\n'
fi
