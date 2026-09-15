#!/usr/bin/env bash
# peer-validate.sh — decide whether a peer model's raw CLI output is usable.
#
# Extracted from review.sh in v0.7.33 so it can be unit-tested (tests/test-peer-validate.sh).
# Behaviour is a superset of the inline version it replaces; nothing was dropped.
#
# The question this answers is narrow: "did the model's answer get CUT OFF?"
# It is NOT a quality judgement. A wrong-but-complete peer review is the merge
# model's problem, not this function's.
#
# ── v0.7.33 (BX-3010): the markdown-fence bug ────────────────────────────────
# Gemini wraps its answer in a ```json ... ``` fence despite the peer prompt
# asking for plain text. The truncation test required the last character to be
# sentence-ending punctuation, and a backtick is not in that set, so COMPLETE
# answers were thrown away. Measured on nova-dev-shubham against the real
# peer-prompt for reco #249, four consecutive runs:
#
#   run  exit  elapsed  stdout  last chars   old verdict
#   1    0     113s     3523B   ...}}```     DISCARDED  (valid JSON!)
#   2    0      89s     2333B   ...]}```     DISCARDED
#   3    0     134s     2522B   ...e}```     DISCARDED
#   4    0     138s     3130B   ...ession.   accepted
#
# So Gemini was working every time and 3 of 4 answers were binned. Peer coverage
# read 1/2 and the "no reliable 2nd peer" limitation recorded in v0.7.11/v0.7.12
# was, at least in part, this function.
#
# The fix strips wrapper fences before the terminator test rather than adding a
# backtick to the accepted set. That keeps the guard honest: output cut off
# mid-JSON has no closing fence, so it still fails the test and is still binned.
_validate_peer_output() {
  local file="$1" name="$2"

  # Nothing at all. Distinct from "short" — this is how a killed subshell looks,
  # because the `|| echo MARKER` fallback never runs when the SUBSHELL is the
  # thing that got signalled. Warn rather than fail silently; an unexplained
  # 0/2 coverage is what let this whole class of bug hide for months.
  if [ ! -s "$file" ]; then
    echo "  warning: ${name} produced no output at all -- discarding" >&2
    echo "${name}_UNAVAILABLE" > "$file"
    return
  fi

  # Strip known CLI wrapper noise that the underlying tools emit AFTER
  # the model's response. Patterns are conservative — only lines that
  # clearly belong to the tool, never to the model.
  local stripped="${file}.stripped"
  grep -vE '^(mcp startup:|OpenAI Codex v|workdir:|model:|provider:|approval:|sandbox:|reasoning effort:|tokens used|--------$|Reading prompt from stdin)' \
    "$file" > "$stripped" 2>/dev/null || cp "$file" "$stripped"

  # Trim trailing blank lines so tail -c 20 doesn't land in whitespace.
  awk 'BEGIN{blank=0} { if ($0 == "") { blank++ } else { for (i=0;i<blank;i++) print ""; blank=0; print $0 } }' \
    "$stripped" > "${stripped}.2" && mv "${stripped}.2" "$stripped"

  # Drop a markdown code fence that wraps the WHOLE response — opening fence on
  # the first non-empty line, closing fence on the last. Only ever at the two
  # ends, so fences around an inline code sample in the middle are untouched.
  awk '
    { line[NR] = $0 }
    END {
      first = 1; last = NR
      while (first <= last && line[first] ~ /^[[:space:]]*$/) first++
      while (last >= first && line[last]  ~ /^[[:space:]]*$/) last--
      if (last > first && line[last] ~ /^[[:space:]]*```[[:space:]]*$/) {
        last--
        if (line[first] ~ /^[[:space:]]*```[a-zA-Z0-9_-]*[[:space:]]*$/) first++
      }
      for (i = first; i <= last; i++) print line[i]
    }' "$stripped" > "${stripped}.3" && mv "${stripped}.3" "$stripped"

  mv "$stripped" "$file"

  # Truncated: file under 100 bytes or doesn't end with sentence-ending char.
  local size
  size=$(wc -c < "$file" | tr -d ' ')
  if [ "$size" -lt 100 ]; then
    echo "  warning: ${name} output too short (${size}B) -- discarding" >&2
    echo "${name}_UNAVAILABLE" > "$file"
    return
  fi

  local last_chars
  last_chars=$(tail -c 20 "$file" | tr -d '[:space:]')
  # POSIX-safe character class: literal `]` must appear first inside `[]`.
  if [ -n "$last_chars" ] && ! printf '%s' "$last_chars" | grep -qE '[]".!?)}]$'; then
    echo "  warning: ${name} output appears truncated -- discarding" >&2
    echo "${name}_UNAVAILABLE" > "$file"
  fi
}
