#!/bin/bash
# diffhound — identity marker utilities (v0.5.6+)
#
# Purpose: Append a self-describing identity marker to each posted inline
# comment so that future review rounds can extract the prior round's identity
# tuple verbatim, instead of reverse-engineering it from rendered markdown
# (which is lossy and was the root cause of cross-round dedup misses).
#
# Marker format (always APPENDED to comment body — never prepended; prepending
# would be misclassified by the anchored-signature `startswith` check at
# lib/review.sh:637 and break loop-prevention logic):
#
#   <!-- diffhound-id v1: <base64(json)> -->
#
# Where json = {"f":"<file_basename>","s":"<primary_symbol>","w":"<normalized_what_80>"}
#
# Identity computed identically to lib/validators/dedup-helper.py:
#   - file_basename: Path(file).name (no directory)
#   - primary_symbol: first backtick-quoted identifier in body, e.g. `decrement`
#                     → "decrement". Empty string if none.
#   - normalized_what: lowercased, [annotation: ...] groups removed,
#                      whitespace collapsed to single spaces, trimmed,
#                      first 80 chars.
#
# Why match dedup-helper.py exactly: we want the marker's identity tuple to be
# directly comparable to the tuple a future round would compute on a re-emitted
# version of the same finding. Divergence between shell and Python normalization
# would silently re-introduce the dedup miss this fix exists to prevent.

# Compute identity tuple from a rendered comment body.
# Args: $1=filepath (full path, used for basename)  $2=body (rendered comment text)
# Echoes: TAB-separated "basename<TAB>symbol<TAB>normalized_what80"
compute_identity_tuple() {
  local filepath="$1" body="$2"
  local basename="${filepath##*/}"

  # Strip [annotation: foo] groups (matches Python ANNOTATION_RE)
  local cleaned
  cleaned=$(printf '%s' "$body" | sed -E 's/\[[a-z-]+: [^]]+\]//g')

  # First backtick-quoted identifier matching [_a-zA-Z][_a-zA-Z0-9]*
  # Python uses re.search; first match wins. We use grep -oE + head -1.
  # Note: backticks containing dot-paths like `client.decr(redisKey)` will
  # match only `client` (the leading identifier), same as Python regex.
  local symbol
  symbol=$(printf '%s' "$cleaned" \
    | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*' \
    | head -1 \
    | tr -d '`' || true)

  # Lowercase, collapse whitespace, strip, take first 80 chars.
  # Python: re.sub(r"\s+", " ", stripped.lower()).strip()[:80]
  local norm_what
  norm_what=$(printf '%s' "$cleaned" \
    | tr '[:upper:]' '[:lower:]' \
    | tr '\n\t\r' '   ' \
    | tr -s ' ' \
    | sed 's/^ //; s/ $//' \
    | cut -c1-80)

  printf '%s\t%s\t%s\n' "$basename" "$symbol" "$norm_what"
}

# Compose marker HTML comment from filepath + body.
# Args: $1=filepath  $2=body
# Echoes: "<!-- diffhound-id v1: <base64> -->"
compose_marker() {
  local filepath="$1" body="$2"
  local tuple basename symbol norm_what
  tuple=$(compute_identity_tuple "$filepath" "$body")
  basename=$(printf '%s' "$tuple" | cut -f1)
  symbol=$(printf '%s' "$tuple" | cut -f2)
  norm_what=$(printf '%s' "$tuple" | cut -f3)

  # Compact JSON via jq for safe escaping.
  local json
  json=$(jq -nc \
    --arg f "$basename" \
    --arg s "$symbol" \
    --arg w "$norm_what" \
    '{f:$f, s:$s, w:$w}')

  # base64 -w0 (no line wrap); macOS uses base64 without -w; portable: tr -d '\n'
  local b64
  b64=$(printf '%s' "$json" | base64 | tr -d '\n')

  printf '<!-- diffhound-id v1: %s -->' "$b64"
}

# Extract identity tuple from a comment body that may contain a marker.
# Args: $1=body
# Echoes: TAB-separated "basename<TAB>symbol<TAB>normalized_what80" if marker present,
#         empty string otherwise.
extract_marker_tuple() {
  local body="$1"
  # Anchored regex to grab base64 payload. Tolerate trailing whitespace.
  local b64
  b64=$(printf '%s' "$body" \
    | grep -oE '<!-- diffhound-id v1: [A-Za-z0-9+/=]+ -->' \
    | head -1 \
    | sed -E 's/^<!-- diffhound-id v1: //; s/ -->$//' || true)
  [ -z "$b64" ] && return 0  # no marker → empty output

  local json
  json=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
  [ -z "$json" ] && return 0

  # jq -r prints empty string for missing fields, never errors.
  local f s w
  f=$(printf '%s' "$json" | jq -r '.f // ""' 2>/dev/null || true)
  s=$(printf '%s' "$json" | jq -r '.s // ""' 2>/dev/null || true)
  w=$(printf '%s' "$json" | jq -r '.w // ""' 2>/dev/null || true)

  # Empty f means malformed marker — treat as no marker rather than emitting
  # a partially-valid tuple that would false-match.
  [ -z "$f" ] && return 0

  printf '%s\t%s\t%s\n' "$f" "$s" "$w"
}

# Append marker to body if not already present.
# Args: $1=filepath  $2=body
# Echoes: body with marker appended (newline + marker), or original body if
#         it already ends with a marker (idempotent).
append_marker() {
  local filepath="$1" body="$2"
  if printf '%s' "$body" | grep -qE '<!-- diffhound-id v1: [A-Za-z0-9+/=]+ -->'; then
    # Already marked (e.g. this code ran twice). Don't double-append.
    printf '%s' "$body"
    return 0
  fi
  local marker
  marker=$(compose_marker "$filepath" "$body")
  # Append on a new line so rendering shows nothing visible (HTML comments are
  # invisible in markdown) and the prefix-match in _posted_cache (review.sh:459)
  # is unaffected — that grep uses -F (fixed string) on a body PREFIX, and we
  # only add to the SUFFIX.
  printf '%s\n\n%s' "$body" "$marker"
}
