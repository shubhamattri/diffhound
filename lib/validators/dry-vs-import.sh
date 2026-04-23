#!/usr/bin/env bash
# dry-vs-import.sh — drop "duplicated" findings when the flagged file only
# imports the symbol (no local def/class). The LLM sometimes sees
# `from X import Y` and claims it's a duplicate of X.Y.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

DRY_WORDS='duplicated|duplicate|already defined|same as|copy of'

block=""
is_dry=0
sym=""
header_file=""

_flush() {
  [ -z "$block" ] && return
  local path="$DIFFHOUND_REPO/$header_file"
  if [ "$is_dry" -eq 1 ] && [ -n "$sym" ] && [ -n "$header_file" ] && [ -f "$path" ]; then
    # Import found AND no local def/class → it's just an import, drop.
    if grep -qE "^[[:space:]]*(from [a-zA-Z0-9_.]+ import [a-zA-Z0-9_, ]*\b$sym\b|import[[:space:]]+.*\b$sym\b)" "$path" \
       && ! grep -qE "^[[:space:]]*(def|class|async def)[[:space:]]+$sym\b" "$path"; then
      printf '[dry-vs-import] DROPPED (import, not duplicate): %s\n' "$(printf '%s' "$block" | head -1)" >&2
      block=""; is_dry=0; sym=""; header_file=""
      return
    fi
  fi
  printf '%s' "$block"
  block=""; is_dry=0; sym=""; header_file=""
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _flush
      block="$line"$'\n'
      header="${line#FINDING: }"
      header_file="${header%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      if printf '%s' "$line" | grep -qiE "$DRY_WORDS"; then
        is_dry=1
        sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`' || true)
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_flush
