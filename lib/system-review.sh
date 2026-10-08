#!/usr/bin/env bash
# Mandatory gate for both JSON and chunked findings, including peer additions.
dh_system_review() {
  local repo="$1" sha="$2" directory="$3" primary="$4" peer1="$5" peer2="$6"
  local prompt base remaining deadline=$((SECONDS + 1200)) pid failed=0
  local -a pids=()
  "$_TIMEOUT_CMD" "$((deadline - SECONDS))" python3 "$LIB_DIR/system_review.py" prepare "$repo" "$sha" "$directory" \
    "$primary" "$peer1" "$peer2" || return 1
  for prompt in "$directory"/batch-*.prompt; do
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
  [ "$failed" -eq 0 ] || return 1
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || { echo 'System review deadline exceeded' >&2; return 1; }
  "$_TIMEOUT_CMD" "$remaining" python3 "$LIB_DIR/system_review.py" apply "$directory"
}
