#!/usr/bin/env bash
# Keep the existing two-attempt policy, but validate every response before use.
_DH_VOICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dh_voice_findings_expected() {
  local primary="$1" count="$2" peers="$3" json
  if [ -z "$count" ]; then
    count=$(grep -c '^FINDING:' "$primary" || true)
    if [ "$count" -eq 0 ]; then
      json=$(_extract_json "$primary")
      [ -n "$json" ] || json=$(cat "$primary")
      count=$(printf '%s' "$json" | jq '.findings | length' 2>/dev/null || echo 0)
    fi
  fi
  if _voice_has_no_findings "$count" "$peers"; then echo false; else echo true; fi
}

dh_write_voice() {
  local system="$1" prompt="$2" output="$3" findings_expected="$4"
  local attempt candidate stop effort=medium
  for attempt in 1 2; do
    candidate="${output}.attempt-${attempt}"
    stop="${candidate}.stop"
    : > "$stop"
    if DIFFHOUND_STAGE=voice-rewrite DIFFHOUND_STOP_REASON_FILE="$stop" \
         _call_api_system "claude-sonnet-5" 128000 900 "$system" "$effort" \
         < "$prompt" > "$candidate" 2>"${candidate}.stderr"; then
      if python3 "$_DH_VOICE_DIR/voice_output.py" "$candidate" "$stop" "$findings_expected" \
           2>>"${candidate}.stderr"; then
        cp "$candidate" "$output"
        return 0
      fi
    fi
    echo "  Voice attempt $attempt failed completeness checks; diagnostics: ${candidate}.stderr" >&2
    tail -3 "${candidate}.stderr" >&2
    effort=low
  done
  : > "$output"
  echo "  Voice formatting failed twice; no review will be posted" >&2
  return 1
}
