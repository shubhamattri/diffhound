#!/usr/bin/env bash
# Mandatory gate for both JSON and chunked findings, including peer additions.
dh_system_review() {
  local repo="$1" sha="$2" directory="$3" primary="$4" peer1="$5" peer2="$6"
  local deadline=$((SECONDS + 1200)) remaining base
  "$_TIMEOUT_CMD" "$((deadline - SECONDS))" python3 "$LIB_DIR/system_review.py" prepare "$repo" "$sha" "$directory" \
    "$primary" "$peer1" "$peer2" || return 1
  _dh_system_wave "$directory" batch "$deadline" || return 1
  # Second look: claims the checker could not settle get the code it asked for, once.
  # Best effort: if it fails or time is short, the first decisions stand.
  remaining=$((deadline - SECONDS))
  if [ "$remaining" -gt 240 ]; then
    if ! { "$_TIMEOUT_CMD" "$((remaining - 120))" python3 "$LIB_DIR/system_review.py" retry "$repo" "$sha" "$directory" \
        && _dh_system_wave "$directory" retry "$((deadline - 120))"; }; then
      echo 'Second look failed; keeping the first decisions' >&2
      for base in "$directory"/retry-*.json; do [ -f "$base" ] && mv "$base" "${base%.json}.failed"; done
    fi
  fi
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || { echo 'System review deadline exceeded' >&2; return 1; }
  "$_TIMEOUT_CMD" "$remaining" python3 "$LIB_DIR/system_review.py" apply "$directory"
}

# Run every <prefix>-*.prompt in the directory, four at a time.
# Args: directory prefix deadline
_dh_system_wave() {
  local directory="$1" prefix="$2" deadline="$3" prompt base remaining pid failed=0
  local -a pids=()
  for prompt in "$directory"/"$prefix"-*.prompt; do
    [ -f "$prompt" ] || continue
    base="${prompt%.prompt}"
    remaining=$((deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then
      echo 'System review deadline exceeded' >&2
      failed=1
      break
    fi
    [ "$remaining" -le 900 ] || remaining=900
    (
      _DIFFHOUND_EFFORT_RETRY=1 DIFFHOUND_STAGE=system-review DIFFHOUND_STOP_REASON_FILE="${base}.stop" \
        _call_api "claude-sonnet-5" 128000 "$remaining" medium "$LIB_DIR/system-review-schema.json" \
        < "$prompt" > "${base}.response" 2>"${base}.stderr" || exit 1
      [ "$(cat "${base}.stop" 2>/dev/null)" = end_turn ] || {
        echo 'Source verification output incomplete; stopping this wave' >> "${base}.stderr"
        exit 1
      }
    ) &
    pids+=("$!")
    if [ "${#pids[@]}" -eq 4 ]; then
      for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
      pids=()
      [ "$failed" -eq 0 ] || return 1
    fi
  done
  if [ "${#pids[@]}" -gt 0 ]; then
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  fi
  [ "$failed" -eq 0 ]
}
