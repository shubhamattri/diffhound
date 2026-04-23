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
EXISTENCE_WORDS='defined|duplicate|duplicated|mutates|overrides|redefines|already exists|already defined'

block=""
what_line=""
header_file=""
sym=""

_classify_and_flush() {
  if [ -z "$block" ]; then return; fi

  # Decide keep / drop / annotate based on gathered context
  local path="$DIFFHOUND_REPO/$header_file"
  if [ -n "$sym" ] && [ -n "$header_file" ] && [ -f "$path" ]; then
    # Check symbol appears outside comment lines. Strips Python #, JS/TS //,
    # and lines starting with * (common inside /* ... */ blocks). Docstrings
    # and inline trailing comments are still searched — false-negative bias,
    # but we'd rather under-drop than over-drop.
    if ! grep -v -E '^[[:space:]]*(#|//|\*)' "$path" | grep -Fq -- "$sym"; then
      # Symbol not in file. Check wording.
      if printf '%s' "$what_line" | grep -qiE "$EXISTENCE_WORDS"; then
        # Existence-implying wording + missing symbol = hallucination → DROP
        printf '[ref-exists] DROPPED (hallucinated): %s\n' "$(printf '%s' "$block" | head -1)" >&2
        block=""; what_line=""; header_file=""; sym=""
        return
      else
        # Missing symbol without existence wording — annotate, keep
        block=$(printf '%s' "$block" | awk -v sym="$sym" -v file="$header_file" '
          BEGIN { done = 0 }
          /^WHAT:/ && !done { print $0 " [ref-exists: '\''" sym "'\'' not found in " file "]"; done=1; next }
          { print }
        ')
        # awk strips trailing newline — restore it to match block convention
        block="${block}"$'\n'
      fi
    fi
  fi

  printf '%s' "$block"
  block=""; what_line=""; header_file=""; sym=""
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
      # Extract first plain-identifier backticked symbol (no dots, no parens).
      # Dotted / paren / bracket symbols are out of scope — grep -F would match
      # too loosely, and we'd rather preserve the finding than risk a false drop.
      sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`' || true)
      ;;
    EVIDENCE:*)
      block+="$line"$'\n'
      if [ -z "$sym" ]; then
        sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`' || true)
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_classify_and_flush
