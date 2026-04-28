#!/usr/bin/env bash
# no-validation-check.sh — DROP findings that claim a function has "no
# validation" / "no format check" / "missing validation" when the function
# body actually contains 2+ validation-pattern tells.
#
# Driven by PR #7145 v0.5.6 review F7: claimed `fromMaybeGlobalId` and
# `toRawBrDeckOrgId` had "no format validation" — both functions have
# explicit validation (RAW_UUID_RE.test, gid: prefix check, base64 regex,
# decoded.includes(":")).
#
# Trigger conditions:
#   - WHAT contains "no (format )?validation", "no \w+ check",
#     "missing validation", "no format check", or "without validation"
#   - WHAT names a backticked function (first plain identifier)
#
# Action:
#   - Locate the function definition in the FINDING's file (or REACHABLE_PATH)
#   - Read the body up to the first ^} (rough — top-level closing brace)
#   - Count validation tells. If >= 2, DROP with annotation.
#
# Validation tells (each match counts once):
#   .test(            — regex test
#   if\s*\(\s*!       — guard clauses
#   throw new         — explicit error throwing
#   instanceof        — type check
#   typeof\s+\w+\s*===  — typeof check
#   Number\.isFinite|Array\.isArray|Object\.keys
#   \.parse\(|\.safeParse\(  — Zod-style schema validation
#   validate\(|assert\(      — explicit validators
#   isValid|isValidUUID
#   trim\(\)\s*\.|\.trim\(\)  — defensive normalization (weak signal)
#
# Threshold: 2 tells. One could be incidental; two suggests deliberate
# validation. False-drop risk: low — a function with no validation has
# zero tells, so two-tell threshold has comfortable margin.
#
# Brace-matching is rough (find first ^} after function def line). Heavily
# nested closures with only top-level closes may be misjudged. Acceptable
# for the "did the LLM read this body at all" question; not a strict parser.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

block=""
what=""
header_prefix=""
header_file=""

_emit() {
  [ -z "$block" ] && return
  printf '%s' "$block"
}

_drop() {
  local reason="$1"
  printf '[no-validation-check] DROPPED (%s): %s\n' \
    "$reason" "$header_prefix" >&2
}

_count_tells() {
  # Args: $1 = function-body text. Echoes: number of distinct validation
  # patterns matched.
  #
  # Tiered v0.5.7 (Gemini peer review counterexample):
  # `if (!input.ready) throw new Error(...)` matches 2 weak tells but is
  # not real format validation. Solution — distinguish STRONG tells
  # (specific to format/type validation: regex .test, instanceof, schema
  # parse, isValid*) from WEAK tells (any guard-clause + any throw, which
  # are state-checks not format validation). Threshold: ≥1 strong tell
  # OR ≥3 weak tells. Single strong tell is decisive (e.g. `RAW_UUID_RE.test`
  # on its own is unambiguous format validation).
  local body="$1"
  local strong=0 weak=0 pat
  # Strong tells — unambiguous format/type/schema validation.
  for pat in \
    '\.test\s*\(' \
    'instanceof' \
    'Number\.isFinite' \
    'Array\.isArray' \
    'Number\.isInteger' \
    '\.parse\s*\(' \
    '\.safeParse\s*\(' \
    'isValid' \
    'isUUID|isEmail|isURL' \
    'RegExp\s*\(' \
    '/.*[\\^$|+*?].*/.test' \
    'typeof\s+[A-Za-z_][A-Za-z0-9_]*\s*===\s*[\"'\'']('; do
    if printf '%s' "$body" | grep -qE -- "$pat"; then
      strong=$((strong + 1))
    fi
  done
  # Weak tells — present in many functions, not validation-specific.
  for pat in \
    'if\s*\(\s*!' \
    'throw\s+new' \
    'validate\s*\(' \
    'assert\s*\('; do
    if printf '%s' "$body" | grep -qE -- "$pat"; then
      weak=$((weak + 1))
    fi
  done
  # Compose: 1 strong = decisive; 0 strong + ≥3 weak = enough; otherwise insufficient.
  if [ "$strong" -ge 1 ]; then
    echo "$((strong + weak))"
  elif [ "$weak" -ge 3 ]; then
    echo "$weak"
  else
    echo 0
  fi
}

_extract_function_body() {
  # Args: $1 = filepath, $2 = function name
  # Echoes the function body (def line through first matching close brace).
  #
  # Brace counting is depth-aware AND indentation-agnostic — Gemini peer
  # review noted v1 used regex-only ^} which would miss class-method
  # closes. We count chars across all lines until depth returns to 0,
  # which works regardless of indentation (class methods, nested IIFEs,
  # arrow functions all close correctly).
  #
  # Patterns recognized for function start:
  #   function NAME(            — top-level / nested function declaration
  #   async function NAME(      — async variant
  #   const NAME = (            — arrow function or function expression
  #   const NAME = async (
  #   const NAME = function(
  #   NAME(...): T {            — class/object method (with or without modifiers)
  #   NAME(...) {               — short method form
  #   public/private/protected/static NAME(  — TS class method modifiers
  local path="$1" fn="$2"
  [ -f "$path" ] || return 0
  awk -v fn="$fn" '
    BEGIN { in_fn = 0; brace_depth = 0; started = 0 }
    !in_fn {
      # Method on a class — modifiers optional.
      method_re = "(^|[[:space:]])(public|private|protected|static|readonly|async)?[[:space:]]*(public|private|protected|static|readonly|async)?[[:space:]]*" fn "[[:space:]]*\\("
      # Top-level function.
      func_re = "(^|[[:space:]])(async[[:space:]]+)?function[[:space:]]+" fn "[[:space:]]*\\("
      # Variable assignment to function/arrow.
      var_re = "(const|let|var)[[:space:]]+" fn "[[:space:]]*=[[:space:]]*(async[[:space:]]*)?(\\(|function)"
      # Object-literal property assignment.
      obj_re = "[\"'\''`]?" fn "[\"'\''`]?[[:space:]]*:[[:space:]]*(async[[:space:]]*)?(\\(|function)"

      if ($0 ~ func_re || $0 ~ var_re || $0 ~ obj_re || $0 ~ method_re) {
        in_fn = 1
        print
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (c == "{") { brace_depth++; started = 1 }
          else if (c == "}" && started) { brace_depth-- }
        }
        if (started && brace_depth == 0) exit
        next
      }
      next
    }
    in_fn {
      print
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") { brace_depth++; started = 1 }
        else if (c == "}" && started) { brace_depth-- }
      }
      if (started && brace_depth == 0) exit
    }
  ' "$path"
}

_check_and_emit() {
  if [ -z "$block" ]; then return; fi

  # Trigger phrase check (case-insensitive).
  if ! printf '%s' "$what" | grep -qiE 'no[[:space:]]+(format[[:space:]]+)?validation|no[[:space:]]+\w+[[:space:]]+check|missing[[:space:]]+validation|no[[:space:]]+format[[:space:]]+check|without[[:space:]]+(any[[:space:]]+)?validation'; then
    _emit; block=""; what=""; header_prefix=""; header_file=""; return
  fi

  # Need a backticked function name in WHAT.
  local fn
  fn=$(printf '%s' "$what" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`' || true)
  if [ -z "$fn" ]; then
    _emit; block=""; what=""; header_prefix=""; header_file=""; return
  fi

  # File to inspect — header file (FINDING: <path>:line:sev) is primary.
  local fpath="$DIFFHOUND_REPO/$header_file"
  if [ ! -f "$fpath" ]; then
    _emit; block=""; what=""; header_prefix=""; header_file=""; return
  fi

  local body
  body=$(_extract_function_body "$fpath" "$fn")
  if [ -z "$body" ]; then
    _emit; block=""; what=""; header_prefix=""; header_file=""; return
  fi

  local tells
  tells=$(_count_tells "$body")
  if [ "$tells" -ge 2 ]; then
    _drop "function '$fn' has $tells validation tells; claim contradicted"
    block=""; what=""; header_prefix=""; header_file=""; return
  fi

  _emit; block=""; what=""; header_prefix=""; header_file=""
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _check_and_emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      header_file="${header_prefix%%:*}"
      ;;
    WHAT:*|EVIDENCE:*)
      block+="$line"$'\n'
      what="${what}${line} "
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_check_and_emit
