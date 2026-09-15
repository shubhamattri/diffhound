#!/usr/bin/env bash
# cost.sh — per-run token accounting for diffhound's Anthropic calls.
#
# v0.7.35 (BX-3010). Added because "what does a review cost?" had no answer.
# Until v0.7.31 the pipeline ran on a flat personal subscription where the
# question was meaningless; it now bills a metered key, and v0.7.34 added a peer
# pass to EVERY review without anyone being able to price that decision.
#
# The Anthropic usage/cost report endpoints need an ADMIN key (sk-ant-admin...);
# the runner only has a normal key, so spend cannot be read back from the API.
# Instead every response's own `usage` block is recorded here and priced locally.
# That is exact on token counts — they come from the API, not an estimate — and
# exact on rates as long as the table below is current.
#
# NOT counted: Gemini (Google, separate key and bill). Reported separately as a
# call count so nobody reads the Anthropic total as the whole cost of a review.
#
# ── Rates, USD per million tokens (checked against the published table) ───────
#   claude-opus-5       $5  in / $25 out      (same as opus-4-6 it replaced)
#   claude-opus-4-6     $5  in / $25 out
#   claude-sonnet-5     $2  in / $10 out      (cheaper than the 4-6 it replaced)
#   claude-sonnet-4-6   $3  in / $15 out
#   claude-haiku-4-5    $1  in / $5  out
# Cache multipliers on the INPUT rate: write x1.25, read x0.10.
# Thinking tokens are billed as OUTPUT and are already inside output_tokens —
# they are reported separately for visibility, never added on top.

_cost_rate_in() {
  case "$1" in
    claude-opus-5*|claude-opus-4-6*|claude-opus-4-7*|claude-opus-4-8*) echo "5.00" ;;
    claude-sonnet-5*)                                                  echo "2.00" ;;
    claude-sonnet-4-6*)                                                echo "3.00" ;;
    claude-haiku-4-5*)                                                 echo "1.00" ;;
    *)                                                                 echo "0"    ;;
  esac
}
_cost_rate_out() {
  case "$1" in
    claude-opus-5*|claude-opus-4-6*|claude-opus-4-7*|claude-opus-4-8*) echo "25.00" ;;
    claude-sonnet-5*)                                                  echo "10.00" ;;
    claude-sonnet-4-6*)                                                echo "15.00" ;;
    claude-haiku-4-5*)                                                  echo "5.00" ;;
    *)                                                                 echo "0"     ;;
  esac
}

# _cost_record MODEL STAGE < api_response_json
# Appends one TSV row. Never fails the caller: accounting must not break a review.
_cost_record() {
  local model="$1" stage="${2:-unknown}"
  [ -n "${DIFFHOUND_USAGE_LOG:-}" ] || return 0
  jq -r --arg m "$model" --arg s "$stage" \
    '[$m, $s,
      (.usage.input_tokens // 0),
      (.usage.output_tokens // 0),
      (.usage.cache_creation_input_tokens // 0),
      (.usage.cache_read_input_tokens // 0),
      (.usage.output_tokens_details.thinking_tokens // 0)] | @tsv' \
    2>/dev/null >> "$DIFFHOUND_USAGE_LOG" || true
  return 0
}

# _cost_summary [GEMINI_CALLS] — prints a per-stage table and the run total.
_cost_summary() {
  local gemini_calls="${1:-0}"
  [ -n "${DIFFHOUND_USAGE_LOG:-}" ] && [ -s "${DIFFHOUND_USAGE_LOG:-}" ] || {
    echo "  (no Anthropic usage recorded this run)"; return 0; }

  # Build "model<TAB>rate_in<TAB>rate_out" so awk can price without a shell loop.
  local rates; rates=$(mktemp -t dh-rates.XXXXXX)
  cut -f1 "$DIFFHOUND_USAGE_LOG" | sort -u | while IFS= read -r m; do
    [ -n "$m" ] && printf '%s\t%s\t%s\n' "$m" "$(_cost_rate_in "$m")" "$(_cost_rate_out "$m")"
  done > "$rates"

  awk -F'\t' -v G="$gemini_calls" '
    NR==FNR { rin[$1]=$2; rout[$1]=$3; next }
    {
      model=$1; stage=$2; inp=$3; out=$4; cw=$5; cr=$6; th=$7
      ri=rin[model]; ro=rout[model]
      c = (inp*ri + cw*ri*1.25 + cr*ri*0.10 + out*ro) / 1000000
      scost[stage]+=c; scalls[stage]++; tokin[stage]+=inp+cw+cr; tokout[stage]+=out; sth[stage]+=th
      mcost[model]+=c; mcalls[model]++
      total+=c; tin+=inp+cw+cr; tout+=out; tth+=th; tcalls++
      tcr+=cr
    }
    END {
      printf "  %-22s %6s %12s %10s %11s\n", "STAGE", "CALLS", "IN(tok)", "OUT(tok)", "COST(USD)"
      for (s in scost)
        printf "  %-22s %6d %12d %10d %11.4f\n", s, scalls[s], tokin[s], tokout[s], scost[s]
      printf "  %-22s %6s %12s %10s %11s\n", "----------------------", "-----", "-----------", "---------", "----------"
      printf "  %-22s %6d %12d %10d %11.4f\n", "TOTAL (Anthropic)", tcalls, tin, tout, total
      printf "\n  thinking tokens (inside OUT): %d\n", tth
      printf "  cache reads (billed at 10%%):  %d\n", tcr
      if (G+0 > 0) printf "  gemini calls (Google, billed separately): %d\n", G
      printf "\n  per-model:\n"
      for (m in mcost) printf "    %-26s %3d calls  $%.4f\n", m, mcalls[m], mcost[m]
    }' "$rates" "$DIFFHOUND_USAGE_LOG"
  rm -f "$rates"
}
