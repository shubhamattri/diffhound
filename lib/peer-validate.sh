#!/usr/bin/env bash
# Shared peer completeness gate. Markdown punctuation is presentation, not a
# provider stop reason. Keep complete emphasis/code blocks and reject malformed
# JSON, unclosed fences, empty/short output and unfinished prose.
_PEER_VALIDATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_validate_peer_output() {
  local file="$1" name="$2" archive="${3:-}"
  # Preserve rejected replies only in the private run archive, never stderr or
  # public CI artifacts. The caller leaves archive empty when archiving is off.
  if [ -n "$archive" ]; then
    if ! (umask 077; mkdir -p "$archive" && chmod 700 "$archive" &&
      cp "$file" "$archive/${name}-raw.txt" && chmod 600 "$archive/${name}-raw.txt"); then
      echo "  warning: ${name} private raw-output archive failed" >&2
    fi
  fi
  if ! python3 "$_PEER_VALIDATOR_DIR/peer_output.py" "$file" "$name"; then
    echo "  warning: ${name} output validation failed -- discarding" >&2
    printf '%s_UNAVAILABLE\n' "$name" > "$file"
    # A failed revalidation must not archive a previous successful decision.
    (umask 077; printf '%s\n' '{"status":"unavailable","reason":"validator_failure"}' > "${file}.validation.json" &&
      chmod 600 "${file}.validation.json")
  fi
  if [ -n "$archive" ] && [ -f "${file}.validation.json" ]; then
    if ! (umask 077; cp "${file}.validation.json" "$archive/${name}-validation.json" &&
      chmod 600 "$archive/${name}-validation.json"); then
      echo "  warning: ${name} private validation archive failed" >&2
    fi
  fi
}
