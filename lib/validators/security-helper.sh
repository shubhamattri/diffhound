#!/usr/bin/env bash
# security-helper.sh — drop timing-attack findings when the actual comparison
# is delegated to a helper that uses a timing-safe primitive
# (hmac.compare_digest, secrets.compare_digest, crypto.timingSafeEqual).
#
# Scoping (revised after peer review):
# - In-file check: ±20 lines around the flagged line (NOT file-wide). Prevents
#   false-clear when a safe compare exists elsewhere in the same file but the
#   flagged line is actually insecure.
# - Import hop: when an `import X` brings in a helper, scan the WHOLE helper
#   file (it's typically a small utility module). Detection: grep the flagged
#   file's ±20 window for any function called from imported modules, then scan
#   those modules for timing-safe primitives.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

TIMING_SAFE_RE='hmac\.compare_digest|secrets\.compare_digest|timingSafeEqual'
WINDOW=20

block=""
is_timing=0
header_file=""
header_line=""

_flush() {
  [ -z "$block" ] && return
  local path="$DIFFHOUND_REPO/$header_file"
  if [ "$is_timing" -eq 1 ] && [ -n "$header_file" ] && [ -n "$header_line" ] && [ -f "$path" ]; then
    if _has_timing_safe_near "$path" "$header_line"; then
      printf '[security-helper] DROPPED (timing-safe compare present): %s\n' "$(printf '%s' "$block" | head -1)" >&2
      block=""; is_timing=0; header_file=""; header_line=""
      return
    fi
  fi
  printf '%s' "$block"
  block=""; is_timing=0; header_file=""; header_line=""
}

# Return 0 if timing-safe compare is (a) within ±WINDOW lines of the flagged
# line in the same file, or (b) present in any module the ±WINDOW window imports
# from (1-hop only).
_has_timing_safe_near() {
  local path="$1" anchor="$2"
  local start=$((anchor - WINDOW))
  local end=$((anchor + WINDOW))
  [ "$start" -lt 1 ] && start=1

  # (a) Direct hit in the window
  if awk -v s="$start" -v e="$end" 'NR>=s && NR<=e' "$path" \
       | grep -qE "$TIMING_SAFE_RE"; then
    return 0
  fi

  # (b) 1-hop: any function referenced in the window that's imported from
  # another local module. Simplest heuristic: collect `from X import Y` at the
  # TOP of the file (imports typically aren't in the window), and for any Y
  # that appears in the window, scan the resolved module file for a timing-safe
  # compare.
  local mod fn candidate
  while IFS='|' read -r mod fn; do
    [ -z "$mod" ] && continue
    # Is this function actually called/referenced in the flagged window?
    if ! awk -v s="$start" -v e="$end" 'NR>=s && NR<=e' "$path" \
         | grep -qE "\b$fn\b"; then
      continue
    fi
    # Try to resolve the module to a file and scan it
    local mod_rel
    mod_rel=$(printf '%s' "$mod" | tr '.' '/')
    for candidate in \
      "$DIFFHOUND_REPO/$mod_rel.py" \
      "$DIFFHOUND_REPO/$mod_rel/__init__.py" \
      "$DIFFHOUND_REPO/api/$mod_rel.py" \
      "$DIFFHOUND_REPO/api/$mod_rel/__init__.py"; do
      if [ -f "$candidate" ] && grep -qE "$TIMING_SAFE_RE" "$candidate"; then
        return 0
      fi
    done
  done < <(_extract_from_imports "$path")
  return 1
}

# Emit "module|name" pairs from `from X import a, b, c` statements.
# BSD awk compat — no match(str,re,arr), using sed + shell split instead.
_extract_from_imports() {
  local path="$1"
  local line mod names name
  # Grab only `from X import Y` lines; ignore plain `import X`
  while IFS= read -r line; do
    # Normalize: strip leading space, collapse multi-space
    line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g; s/[(),]/ /g')
    case "$line" in
      "from "*" import "*)
        # Extract module (between "from " and " import")
        mod=$(printf '%s' "$line" | sed -E 's/^from ([A-Za-z0-9_.]+) import .*/\1/')
        # Extract everything after "import "
        names=$(printf '%s' "$line" | sed -E 's/^from [A-Za-z0-9_.]+ import //')
        for name in $names; do
          case "$name" in
            as|''|'*') continue ;;
            *) printf '%s|%s\n' "$mod" "$name" ;;
          esac
        done
        ;;
    esac
  done < <(grep -E '^[[:space:]]*from[[:space:]]+[A-Za-z0-9_.]+[[:space:]]+import[[:space:]]+' "$path" 2>/dev/null)
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _flush
      block="$line"$'\n'
      header="${line#FINDING: }"
      header_file="${header%%:*}"
      rest="${header#*:}"
      header_line="${rest%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      if printf '%s' "$line" | grep -qiE 'timing[- ]?(attack|safe)|constant[- ]?time'; then
        is_timing=1
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_flush
