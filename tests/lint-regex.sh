#!/usr/bin/env bash
# tests/lint-regex.sh — fail-fast lint for known Mac-BSD vs. GNU-grep
# regex landmines in diffhound's shell scripts.
#
# Born from v0.7.5 (peer-review validator dead for 32 days) and v0.7.6
# (v0.7.3/v0.7.4 validators half-dead because `[^\n]` excluded letter `n`
# on GNU grep 3.11). Each rule below catches one of the dialect bombs.
# Add new rules as new bugs are found, not before — false positives in
# this lint are worse than missed bugs because they erode trust.
#
# Usage:
#   tests/lint-regex.sh           # check whole repo, exit non-zero on findings
#   tests/lint-regex.sh --quiet   # exit-only, no output
#
# Adds zero runtime to fixture tests. Run separately in CI.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# Scan shell scripts only. Skip Python (own regex engine), test fixtures
# (they're data not code), and the lint script itself.
SH_FILES=$(find "$ROOT" \
  \( -path "$ROOT/tests/fixtures" -o -path "$ROOT/.git" -o -path "$ROOT/node_modules" \) -prune -o \
  -type f \( -name '*.sh' -o -name 'diffhound' \) -not -name 'lint-regex.sh' \
  -print)

FINDINGS=0
_emit() {
  FINDINGS=$((FINDINGS + 1))
  [ "$QUIET" = "1" ] && return
  printf '%s\n' "$1" >&2
}

# Helper: skip comments, jq invocations, and other false-positive shapes.
_is_noise() {
  local line="$1"
  case "$line" in
    \#*|*' #'*) return 0 ;;       # comment line (leading or trailing #)
    *jq*|*'| jq '*) return 0 ;;   # jq has its own regex engine
    *scan\(*) return 0 ;;          # jq's `scan(...)` regex
    *) return 1 ;;
  esac
}

# Rule 1: `\n` inside a character class.
#   `[^.\n]` reads as "anything except dot or letter n" on GNU grep.
#   Bit Shubham on v0.7.3+v0.7.4. Almost always wrong.
for f in $SH_FILES; do
  while IFS=: read -r line_no line; do
    [ -z "$line" ] && continue
    _is_noise "$line" && continue
    _emit "[regex-lint] $f:$line_no  RULE-1  \`\\n\` inside [] — GNU grep treats as literal 'n'"
    _emit "             $line"
  done < <(grep -nE '\[[^]]*\\n[^]]*\]' "$f" 2>/dev/null || true)
done

# Rule 2: `\d`, `\D`, `\w`, `\W` shortcuts in grep -E.
#   GNU grep ERE treats `\d` as literal `d`. `\s`/`\b`/`\w` are GNU extensions
#   that DO work on GNU 3.0+ but break on Alpine/busybox grep.
#   `\d` is the loud broken one — catch it. `\s`/`\w` are noisy — flag only
#   inside [] (where they're definitely literal) or where -P would be needed.
for f in $SH_FILES; do
  while IFS=: read -r line_no line; do
    [ -z "$line" ] && continue
    _is_noise "$line" && continue
    _emit "[regex-lint] $f:$line_no  RULE-2  \`\\d\` is literal 'd' in grep ERE — use [0-9]"
    _emit "             $line"
  done < <(grep -nE 'grep[^|]*-[a-zA-Z]*E[^|]*\\d' "$f" 2>/dev/null || true)
done

# Rule 3: bracket expression with `]` not first inside `[…]`.
#   Original v0.7.5 bug: `[.!?)}\]"]` was supposed to include literal `]`,
#   but GNU grep closes the class on the first unescaped `]`. POSIX requires
#   `]` to be the first character to be literal: `[]"})]` not `[")\]}]`.
#   Detection: a character class that contains both `\]` and another `]`
#   AFTER it (the second one's the one that actually closes the class).
for f in $SH_FILES; do
  while IFS=: read -r line_no line; do
    [ -z "$line" ] && continue
    _is_noise "$line" && continue
    case "$line" in
      *'[]'*) continue ;;   # POSIX-safe form already
    esac
    if printf '%s' "$line" | grep -qE '\[[^]]*\\\][^]]*\]' 2>/dev/null; then
      _emit "[regex-lint] $f:$line_no  RULE-3  \`]\` not first inside [] — class may close early"
      _emit "             $line"
    fi
  done < <(printf '%s\n' "$(cat "$f" 2>/dev/null | awk '{print NR":"$0}')")
done

# Rule 4: `[-\s]` / `[\s-]` — `\s` inside [] is literal backslash-s on GNU.
for f in $SH_FILES; do
  while IFS=: read -r line_no line; do
    [ -z "$line" ] && continue
    _is_noise "$line" && continue
    _emit "[regex-lint] $f:$line_no  RULE-4  \`\\s\` inside [] is literal — use [[:space:]] or [[:space:]-]"
    _emit "             $line"
  done < <(grep -nE '\[[^]]*\\s[^]]*\]' "$f" 2>/dev/null || true)
done

if [ "$QUIET" = "1" ]; then
  [ "$FINDINGS" -eq 0 ]
  exit $?
fi

echo
if [ "$FINDINGS" -eq 0 ]; then
  echo "regex-lint: 0 findings — clean."
  exit 0
else
  echo "regex-lint: $FINDINGS finding(s). Fix before merging."
  exit 1
fi
