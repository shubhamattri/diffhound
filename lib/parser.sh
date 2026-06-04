#!/bin/bash
# diffhound — output parsing & comment extraction
# Supports JSON structured output (primary) with regex fallback

# Shared claim checkers (single ground-truth implementation) — used by the
# fresh-path engine (validators/claim-verify.sh) AND the summary-level scrub
# below, so re-review blockers (generated as summary prose) get the SAME
# deterministic verification as fresh findings (the single chokepoint).
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/claim-checkers.sh" 2>/dev/null || true

# Deterministic claim-verify pass over the FINAL summary's finding bullets.
# This is the single chokepoint for the POSTED text: re-review thread
# re-assertions become Blockers/Should-Fix bullets in the model's summary prose,
# bypassing the FINDING-block pipeline — so verify them here too. A bullet whose
# extracted claim is contradicted by the repo is removed (FP). Gated by the same
# DIFFHOUND_CLAIM_VERIFY flag. Real incident: monorepo #7317 re-asserted
# SEARCH_ORGS/marked.parse blockers that the fresh-path engine never saw.
_claim_verify_summary() {
  local summary_file="$1" repo="$2" structured="${3:-}"
  [ -f "$summary_file" ] || return 0
  [ -d "$repo" ] || return 0
  [ "${DIFFHOUND_CLAIM_VERIFY:-1}" = "1" ] || return 0
  type _verify_claim >/dev/null 2>&1 || return 0
  local DIFFHOUND_REPO="$repo"  # dynamic scope -> shared checkers use it

  # 1) PRIMARY (robust, wording-independent): build the FP set from the model's
  #    EXPLICIT structured claims. "basename:line" of any finding/thread_status
  #    whose claim verifies FALSE against the repo. This is the real chokepoint —
  #    we read the model's claims, NOT the rendered prose.
  local fpset=" "
  if [ -n "$structured" ] && [ -f "$structured" ] && command -v python3 >/dev/null 2>&1; then
    local _json; _json=$(_extract_json "$structured" 2>/dev/null); [ -z "$_json" ] && _json=$(cat "$structured" 2>/dev/null)
    local bn ln ctype subj loc exp c v
    while IFS=$'\t' read -r bn ln ctype subj loc exp; do
      [ -z "$bn" ] && continue
      case "$ctype" in
        file_contains)      c="file_contains:${subj}:${loc}:${exp:-true}" ;;
        symbol_defined)     c="symbol_defined:${subj}:repo:${exp:-true}" ;;
        dependency_version) c="dependency_version:${subj}::${exp:-missing}" ;;
        method_exists)      c="method_exists:${subj}:${loc}:" ;;
        usage)              c="usage:${subj}:${loc}:${exp:-false}" ;;
        *) continue ;;
      esac
      v=$(_verify_claim "$c")
      # FALSE -> hallucination, drop. method_exists UNVERIFIABLE -> a dep API
      # claim we cannot confirm statically must NOT block -> drop from blockers too.
      if [ "$v" = "FALSE" ] || { [ "$ctype" = "method_exists" ] && [ "$v" = "UNVERIFIABLE" ]; }; then
        fpset="${fpset}${bn}:${ln} "
      fi
    done < <(printf '%s' "$_json" | python3 -c '
import json,sys,os
# strict=False: LLMs routinely emit LITERAL newlines/tabs inside string values
# (multi-line "body"/"evidence" fields). Plain json.load() raises
# "Invalid control character" on those and the old silent sys.exit(0) then left
# the FP-scrub a no-op (marked FP leaked on #7317 this way). Tolerate control
# chars; warn LOUDLY (never silently) if it still cannot parse.
try: j=json.loads(sys.stdin.read(), strict=False)
except Exception as e:
    sys.stderr.write("[claim-verify-summary: WARN could not parse structured claims (%s); FP scrub fell back to prose-only]\n" % e)
    sys.exit(0)
def emit(it):
    bn=os.path.basename(str(it.get("file","")))
    ln=str(it.get("line",""))
    for cl in (it.get("claims") or []):
        t=cl.get("type",""); subj=cl.get("subject","")
        loc=cl.get("location","") or cl.get("method","") or cl.get("scope","") or ""
        exp=cl.get("expected", cl.get("expected_satisfies",""))
        if isinstance(exp,bool): exp="true" if exp else "false"
        print("\t".join([bn,ln,t,str(subj),str(loc),str(exp)]))
for k in ("findings","thread_statuses"):
    for it in (j.get(k) or []): emit(it)
' 2>/dev/null)
  fi

  # 2) Scrub finding-bullets in Blockers/Should-Fix: drop if its file:line is in
  #    the explicit FP set, OR (fallback) its own prose claim verifies FALSE.
  local tmp; tmp=$(mktemp -t "diffhound-cvsum.XXXXXX")
  local line bl claims c v drop insec=""
  while IFS= read -r line; do
    case "$line" in
      "### Blockers"*|"### Should-Fix"*) insec=1 ;;
      "## "*|"### "*) insec="" ;;
    esac
    if [ -n "$insec" ] && printf '%s' "$line" | grep -qE '^- '; then
      drop=0
      bl=$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_./-]+\.(vue|ts|tsx|js|jsx|py):[0-9]+' | head -1)
      [ -n "$bl" ] && bl=$(basename "$bl")
      if [ -n "$bl" ] && printf '%s' "$fpset" | grep -qF " $bl "; then drop=1; fi
      if [ "$drop" = "0" ] && type _extract_implicit_claims >/dev/null 2>&1; then
        claims=$(_extract_implicit_claims "$line")
        if [ -n "$claims" ]; then
          local IFS_s="$IFS"; IFS=';'
          for c in $claims; do c=$(printf '%s' "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); [ -z "$c" ] && continue; v=$(_verify_claim "$c"); [ "$v" = "FALSE" ] && { drop=1; break; }; done
          IFS="$IFS_s"
        fi
      fi
      if [ "$drop" = "1" ]; then
        printf '[claim-verify-summary: removed FP bullet: %s]\n' "$(printf '%s' "$line" | cut -c1-80)" >&2
        continue
      fi
    fi
    printf '%s\n' "$line"
  done < "$summary_file" > "$tmp" && mv "$tmp" "$summary_file" || rm -f "$tmp"

  # 3) Reconcile the verdict with the SURVIVING bullets. Dropping an FP blocker
  #    bullet must also drop the verdict it drove (plan invariant 4: verdict is a
  #    function of verified findings, not the model's self-assessment). Without
  #    this, #7317 dropped both FP blockers yet still read REQUEST_CHANGES.
  _reconcile_summary_verdict "$summary_file"
}

# Make the **Total** row's VERDICT cohere with BOTH the surviving findings AND the
# score, so "58/100 APPROVE" can never happen. Rules (one rubric, no second source
# of truth):
#   - any surviving BLOCKER bullet            -> REQUEST_CHANGES  (hard gate)
#   - else derive from the score band:
#       score >= 85 -> APPROVE   (a high score == approvable; matches Shubham's
#                                 "approve should be ~86+")
#       score >= 70 -> COMMENT
#       score <  70 -> REQUEST_CHANGES
#   - a surviving SHOULD-FIX can't be APPROVE -> cap at COMMENT
# The score NUMBER stays the model's weighted category total (per Shubham: keep the
# structured table). Dropping an FP blocker only docks ~a few points of one
# category, which doesn't move the band — the dominant driver (e.g. Tests 2/20 on
# an untested PR) is legit, so a low-score REQUEST_CHANGES is the CORRECT, coherent
# call, not a hallucination. (Surgical per-category point restoration + note/checklist
# FP-clause scrubbing is the remaining cosmetic follow-up.)
_reconcile_summary_verdict() {
  local sf="$1"
  [ -f "$sf" ] || return 0
  [ "${DIFFHOUND_CLAIM_VERIFY:-1}" = "1" ] || return 0
  grep -qiE '\*\*Total\*\*' "$sf" || return 0
  local nb ns total v cur
  # NOTE: section terminator is `/^#+ /` (any markdown heading), NOT `/^#{2,3} /`.
  # awk interval expressions `{2,3}` are NON-PORTABLE — the VM's awk treats them
  # LITERALLY, so the terminator never matched, `f` stayed on past the section, and
  # it miscounted the Nits/Open-Question bullets as blockers (#7317 -> wrong
  # REQUEST_CHANGES). `+` is standard ERE everywhere. (CLAUDE.md hard rule #5.)
  nb=$(awk '/^### Blockers/{f=1;next} /^#+ /{f=0} f&&/^- /{c++} END{print c+0}' "$sf")
  ns=$(awk '/^### Should-Fix/{f=1;next} /^#+ /{f=0} f&&/^- /{c++} END{print c+0}' "$sf")
  total=$(grep -iE '\*\*Total\*\*' "$sf" | grep -oE '[0-9]+/100' | grep -oE '^[0-9]+' | head -1)
  if [ "${nb:-0}" -gt 0 ]; then
    v=REQUEST_CHANGES
  elif [ -n "$total" ]; then
    if   [ "$total" -ge 85 ]; then v=APPROVE
    elif [ "$total" -ge 70 ]; then v=COMMENT
    else v=REQUEST_CHANGES; fi
    [ "${ns:-0}" -gt 0 ] && [ "$v" = "APPROVE" ] && v=COMMENT   # should-fix can't APPROVE
  elif [ "${ns:-0}" -gt 0 ]; then
    v=COMMENT
  else
    v=APPROVE
  fi
  cur=$(grep -iE '\*\*Total\*\*' "$sf" | grep -oiE 'REQUEST_CHANGES|APPROVE|COMMENT' | head -1)
  # Skip the rewrite only if the verdict already matches AND is coherent. The
  # incoherent case to still fix: verdict==REQUEST_CHANGES but NO blocker survives
  # (it's score-driven), where the model's reason still cites a now-dropped
  # "blocker" — rewrite so the reason matches reality (Shubham's "REQUEST_CHANGES —
  # one blocker" with an empty Blockers section).
  if [ -n "$cur" ] && [ "$cur" = "$v" ]; then
    { [ "$v" != "REQUEST_CHANGES" ] || [ "${nb:-0}" -gt 0 ]; } && return 0
  fi
  local tmp; tmp=$(mktemp -t "diffhound-rv.XXXXXX")
  awk -v V="$v" -v NB="${nb:-0}" -v T="${total:-}" '
    /\*\*Total\*\*/ {
      n=split($0, a, "|")
      if (n >= 4) {
        if (V=="APPROVE")      reason = "no blocking issues; quality bar met"
        else if (V=="COMMENT") reason = "merge ok; should-fix / quality items remain"
        else if (NB+0 > 0)     reason = "blocking issue(s) must be fixed before merge"
        else                   reason = "score " T "/100 below the approval bar — address quality gaps (e.g. test coverage)"
        a[4] = " **" V "** \xe2\x80\x94 " reason " "
        out=a[1]; for(i=2;i<=n;i++) out=out "|" a[i]
        print out; next
      }
    }
    { print }
  ' "$sf" > "$tmp" && mv "$tmp" "$sf" || { rm -f "$tmp"; return 0; }
  printf '[claim-verify-summary: verdict reconciled %s -> %s (total=%s/100, %s blockers, %s should-fix survive)]\n' "${cur:-?}" "$v" "${total:-?}" "${nb:-0}" "${ns:-0}" >&2
}

# Extract JSON block from LLM output (between ```json and ```)
_extract_json() {
  local file="$1"
  sed -n '/^```json/,/^```/{/^```/d;p;}' "$file" 2>/dev/null
}

# Parse findings from structured review output
# Primary: JSON parsing via jq
# Fallback: regex extraction of COMMENT:/REPLY: lines
parse_comments() {
  local structured_file="$1"
  local comments_file="$2"

  # Try JSON parsing first
  local json_content
  json_content=$(_extract_json "$structured_file")

  if [ -n "$json_content" ] && echo "$json_content" | jq -e '.findings' >/dev/null 2>&1; then
    # JSON mode — extract findings as COMMENT: lines
    # Join multi-line bodies with Unit Separator (\x1f) to preserve them on one line
    echo "$json_content" | jq -r '
      .findings[] |
      "COMMENT: \(.file):\(.line):\(.severity) — \(.body | gsub("\n"; "\u001f"))"
    ' > "$comments_file" 2>/dev/null || true

    # Thread statuses go into summary, not as duplicate inline comments.
    # STILL_OPEN/AUTHOR_WRONG threads will be handled by the re-review
    # reply logic in review.sh which matches against existing comment IDs.

    # Save parsed JSON for downstream use (verification pass, confidence scores)
    echo "$json_content" > "${structured_file}.json"
    return 0
  fi

  # Fallback: regex-based parsing (backward compatible)
  if grep -q "INLINE_COMMENTS_START" "$structured_file"; then
    sed -n '/INLINE_COMMENTS_START/,/INLINE_COMMENTS_END/p' "$structured_file" | \
      awk '
        /^COMMENT:|^REPLY:/ {
          if (buf != "") print buf
          buf = $0
          next
        }
        /INLINE_COMMENTS/ || /^###/ { next }
        buf != "" && /^[[:space:]]*$/ { next }
        buf != "" {
          gsub(/^[ \t]+/, "")
          buf = buf "\x1f" $0
        }
        END { if (buf != "") print buf }
      ' > "${comments_file}.raw" || true

    # Post-processing: drop lint nits
    grep -viE '(trailing newline|missing newline|extra blank line|end of file|trailing whitespace|import order|file.ending|no newline at end)' \
      "${comments_file}.raw" > "$comments_file" 2>/dev/null || \
      cp "${comments_file}.raw" "$comments_file"
    rm -f "${comments_file}.raw"
  else
    touch "$comments_file"
  fi
}

# Extract review summary from structured output
parse_summary() {
  local structured_file="$1"
  local summary_file="$2"

  # Try JSON parsing first
  local json_content
  json_content=$(_extract_json "$structured_file")

  if [ -n "$json_content" ] && echo "$json_content" | jq -e '.summary' >/dev/null 2>&1; then
    # Build summary from JSON
    {
      echo "$json_content" | jq -r '.summary'
      echo ""
      echo "## Scorecard"
      echo "| Category | Score | Notes |"
      echo "|----------|-------|-------|"
      echo "$json_content" | jq -r '
        .scorecard | to_entries[] |
        "| \(.key | gsub("_"; " ") | ascii_upcase) (\(.value.max)%) | \(.value.score)/\(.value.max) | \(.value.reason) |"
      '
      local total verdict
      total=$(echo "$json_content" | jq -r '[.scorecard[]? | .score] | add // 0')
      local total_max
      total_max=$(echo "$json_content" | jq -r '[.scorecard[]? | .max] | add // 100')
      verdict=$(echo "$json_content" | jq -r '.verdict')
      echo "| **Total** | **${total}/${total_max}** | **${verdict}** |"
      echo ""
      echo "## Verification & Test Checklist"
      echo "$json_content" | jq -r '(.checklist // [])[] | "- [ ] \(.)"'
      # Requirement coverage from Jira integration
      local has_req_cov
      has_req_cov=$(echo "$json_content" | jq -e '.requirement_coverage.ticket // empty' 2>/dev/null || true)
      if [ -n "$has_req_cov" ] && [ "$has_req_cov" != "null" ]; then
        echo ""
        echo "## Requirement Coverage ($(echo "$json_content" | jq -r '.requirement_coverage.ticket'))"
        echo "### Addressed"
        echo "$json_content" | jq -r '(.requirement_coverage.addressed // [])[] | "- ✅ \(.)"'
        local missing_count
        missing_count=$(echo "$json_content" | jq -r '(.requirement_coverage.missing // []) | length' | tr -d '[:space:]')
        missing_count=${missing_count:-0}
        if [ "$missing_count" -gt 0 ] 2>/dev/null; then
          echo "### Missing"
          echo "$json_content" | jq -r '(.requirement_coverage.missing // [])[] | "- ⚠️ \(.)"'
        fi
        local req_notes
        req_notes=$(echo "$json_content" | jq -r '.requirement_coverage.notes // empty')
        if [ -n "$req_notes" ]; then
          echo ""
          echo "*${req_notes}*"
        fi
      fi
    } > "$summary_file"
    # Enforce canonical /100 weighting on the JSON path too (model controls
    # per-category max in JSON output, so it can drift the same way).
    _normalize_markdown_scorecard_total "$summary_file"
    return 0
  fi

  # Fallback: regex-based
  if grep -q "SUMMARY_START" "$structured_file"; then
    sed -n '/SUMMARY_START/,/SUMMARY_END/p' "$structured_file" | \
      grep -v "SUMMARY_START" | grep -v "SUMMARY_END" > "$summary_file"
  elif grep -q "SCORECARD_START" "$structured_file"; then
    # Chunked merge format: extract SCORECARD_START/END and convert to markdown table
    {
      # Build markdown scorecard table from "Category: X/Y — reason" lines
      echo "| Category | Score | Notes |"
      echo "|----------|-------|-------|"
      sed -n '/SCORECARD_START/,/SCORECARD_END/p' "$structured_file" | \
        grep -v "SCORECARD_START\|SCORECARD_END\|^Blocking:\|^ShouldFix:\|^Nits:\|^Checklist:" | \
        while IFS= read -r _sline; do
          [ -z "$_sline" ] && continue
          _cat=$(echo "$_sline" | sed 's/:.*//' | sed 's/^ *//')
          _rest=$(echo "$_sline" | sed 's/^[^:]*: //')
          _score=$(echo "$_rest" | grep -oE '^[0-9]+/[0-9]+' || true)
          _reason=$(echo "$_rest" | sed 's/^[0-9]*\/[0-9]* *[—–-]* *//')
          if echo "$_cat" | grep -qi "total"; then
            echo "| **${_cat}** | **${_score}** | ${_reason} |"
          elif [ -n "$_score" ]; then
            echo "| ${_cat} | ${_score} | ${_reason} |"
          fi
        done
      echo ""
      echo "## Verification & Test Checklist"
      sed -n '/SCORECARD_START/,/SCORECARD_END/p' "$structured_file" | \
        grep "^Checklist:" | sed 's/^Checklist: //' | tr ',' '\n' | \
        while IFS= read -r _item; do
          _item=$(echo "$_item" | sed 's/^ *//')
          [ -n "$_item" ] && echo "- [ ] ${_item}"
        done
    } > "$summary_file"
  else
    cat "$structured_file" > "$summary_file"
  fi

  _normalize_markdown_scorecard_total "$summary_file"
}

# Derive the scorecard from the actual findings instead of trusting the model's
# free-form per-category guesses (v0.7.13). The old scorecard let the model pick
# "Tests 12/20" on vibes, so a CLEAN review (zero findings) still scored 86 with
# no finding to justify the deduction — verdict and score disagreed. Now: start
# at 100, deduct per finding by severity. No findings → 100. APPROVE (no
# blockers/should-fix) therefore lands high, and every lost point maps to a
# comment you can read. Counts come from the rendered ### Blockers / ### Should-
# Fix / ### Nits sections of the summary. Replaces the "## Scorecard" table.
#   Blocking -20, Should-Fix -7, Nit -2 (OPEN_QUESTION excluded), floored at 0.
_derive_scorecard_from_summary() {
  local summary_file="$1"
  [ -f "$summary_file" ] || return 0
  local tmp; tmp=$(mktemp -t "diffhound-derivesc.XXXXXX")
  awk '
    function lc(s){ return tolower(s) }
    { lines[NR]=$0 }
    /^### / {
      cur=""
      if ($0 ~ /^### Blockers/)            cur="B"
      else if ($0 ~ /^### Should[- ]?[Ff]ix/) cur="S"
      else if ($0 ~ /^### Nits/)           cur="N"
      next
    }
    /^## / { cur="" }
    {
      if (cur!="" && $0 ~ /^- / && lc($0) !~ /^- *none/) {
        if (cur=="B") B++; else if (cur=="S") S++; else if (cur=="N") N++
      }
    }
    END {
      B=B+0; S=S+0; N=N+0
      score = 100 - 20*B - 7*S - 2*N
      if (score < 0) score = 0
      # Locate the scorecard table: "## Scorecard" (or a "| Category" header) → **Total** row.
      start=0; end=0
      for (i=1;i<=NR;i++){ if (lines[i] ~ /^##[ ]*Scorecard/){ start=i; break } }
      if (start==0) for (i=1;i<=NR;i++){ if (lines[i] ~ /^\|[ ]*Category/){ start=i; break } }
      verdict=""
      if (start>0) for (i=start;i<=NR;i++){
        if (lines[i] ~ /\*\*Total\*\*/){
          end=i
          # Preserve the model verdict word so parse_verdict still works if it
          # runs after this (and so the derived row stays informative).
          if (lines[i] ~ /REQUEST_CHANGES/)   verdict="REQUEST_CHANGES"
          else if (lines[i] ~ /APPROVE/)      verdict="APPROVE"
          else if (lines[i] ~ /COMMENT/)      verdict="COMMENT"
          break
        }
      }
      vsuffix = (verdict != "") ? " (" verdict ")" : ""

      for (i=1;i<=NR;i++){
        if (start>0 && i==start){
          print "## Scorecard (derived from findings)"
          print ""
          print "| Severity | Count | Penalty | Deduction |"
          print "|----------|-------|---------|-----------|"
          print "| Blocking | " B " | -20 | -" 20*B " |"
          print "| Should-Fix | " S " | -7 | -" 7*S " |"
          print "| Nit | " N " | -2 | -" 2*N " |"
          print "| **Total** | | | **" score "/100**" vsuffix " |"
          if (end>=start){ i=end; continue }   # skip the old table rows
        } else if (start>0 && end>=start && i>start && i<=end){
          continue
        } else {
          print lines[i]
        }
      }
      if (start==0){
        print ""
        print "## Scorecard (derived from findings)"
        print ""
        print "| Severity | Count | Penalty | Deduction |"
        print "|----------|-------|---------|-----------|"
        print "| Blocking | " B " | -20 | -" 20*B " |"
        print "| Should-Fix | " S " | -7 | -" 7*S " |"
        print "| Nit | " N " | -2 | -" 2*N " |"
        print "| **Total** | | | **" score "/100**" vsuffix " |"
      }
    }
  ' "$summary_file" > "$tmp" && mv "$tmp" "$summary_file" || rm -f "$tmp"
}

# Re-verify "X doesn't exist / not defined / missing" claims against the CURRENT
# tree, and emit ground-truth corrections for any symbol that IS actually
# defined. Used on re-reviews: the model re-asserts a round-1 STILL_OPEN concern
# ("SEARCH_ORGS doesn't exist anywhere") without re-checking the code, and that
# re-assertion bypasses the validator pipeline AND the peer cross-check. This
# grep is deterministic — if the symbol is defined now, the absence claim is a
# false positive (real incident: monorepo #7317, SEARCH_ORGS at queries.js:83).
#
# Args: $1 = model-output file (CLAUDE_OUT), $2 = repo working tree.
# Stdout: markdown correction bullets (empty if none). Caller injects them into
# the voice/format pass so the final review can't render the claim as a blocker.
_reverify_absence_claims() {
  local out="$1" repo="$2"
  [ -f "$out" ] || return 0
  [ -d "$repo" ] || return 0

  # Lines that assert a symbol is absent.
  local absence_re="does(n'?t| not) exist|do(n'?t| not) exist|not defined|don'?t exist anywhere|doesn'?t exist anywhere|missing entirely|not found anywhere|exist anywhere in the codebase"

  # Candidate symbols from absence lines: backticked identifiers OR ALL_CAPS
  # constants (gql query consts like SEARCH_ORGS). Defs-only check below keeps
  # noise tokens (HTTP/JSON/API) from producing corrections.
  grep -iE "$absence_re" "$out" 2>/dev/null \
    | grep -oE '`@?[A-Za-z_][A-Za-z0-9_]{2,}`|[A-Z][A-Z0-9_]{3,}' \
    | tr -d '`' | sort -u \
    | while IFS= read -r sym; do
        [ -z "$sym" ] && continue
        local hit loc
        # Look for a DEFINITION (export/const/function/class/def or `SYM =`/`SYM:`).
        hit=$(grep -rnE "(export[[:space:]]+(const|default|function|class)|const|let|var|function|class|def)[[:space:]]+${sym}([[:space:]]|=|\(|:|<|\$)|^[[:space:]]*${sym}[[:space:]]*[:=]" "$repo" \
              --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' --include='*.py' \
              2>/dev/null | grep -v '/node_modules/' | head -1)
        if [ -n "$hit" ]; then
          loc=$(printf '%s' "$hit" | cut -d: -f1-2 | sed "s#${repo}/##")
          printf -- '- `%s` IS defined at %s — any claim it does not exist is a FALSE POSITIVE; mark that thread RESOLVED and do not emit it as a blocker/comment.\n' "$sym" "$loc"
        fi
      done

  # v0.7.16: the INVERSE — a re-review concern asserting a named element IS a
  # vulnerable/unscoped resolver/endpoint when that element does NOT exist (the
  # "invented companion resolver" hallucination; monorepo #7268 `usersCount`).
  # The vuln-symbol-exists-check validator catches this on fresh findings, but
  # re-review thread re-assertions bypass the validator pipeline — so re-verify
  # it here too and inject a correction into the re-review voice pass.
  local vuln_re="is (the |a |an )?(companion )?(resolver|endpoint|query|mutation|handler)|companion (resolver|query|endpoint|to)|unscoped|can (be )?quer|queryable|directly via graphql|is exposed|missing (an |a )?(auth|access|scope|client.?scope)"
  grep -iE "$vuln_re" "$out" 2>/dev/null \
    | grep -oiE "\`[A-Za-z_][A-Za-z0-9_]+\`[^.\`]{0,45}(${vuln_re})" \
    | grep -oE "\`[A-Za-z_][A-Za-z0-9_]+\`" | tr -d '`' | sort -u \
    | while IFS= read -r vsym; do
        [ -z "$vsym" ] && continue
        if ! grep -rqE "(export[[:space:]]+(const|default|function|class)|const|let|var|function|class|def)[[:space:]]+${vsym}([[:space:]]|=|\(|:|<)|[\"']${vsym}[\"'][[:space:]]*:|^[[:space:]]*${vsym}[[:space:]]*[:(]" "$repo" \
              --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' --include='*.py' --include='*.graphql' \
              --exclude-dir=node_modules 2>/dev/null; then
          printf -- '- `%s` is NOT defined anywhere in the repo — there is no such resolver/endpoint/function. Any claim that `%s` is unscoped/vulnerable/exposed is a FALSE POSITIVE (invented by analogy); mark that thread RESOLVED and do not emit it as a blocker/comment.\n' "$vsym" "$vsym"
        fi
      done
}

# Normalize the markdown scorecard to canonical, weight-enforced scoring.
#
# Canonical weights (sum = 100):
#   Security 25, Tests 20, Observability 10, Performance 15, Readability 15, Compatibility 15
#
# Why this is script-owned and not trusted from the model:
#   The model used to control each category's denominator. When it dropped a
#   category the total denominator silently became /85; when it emitted a wrong
#   max (e.g. "Security: 18/20") the total was both wrong and un-weighted. This
#   function pins each category to its canonical max, rescales the model's score
#   onto that max, back-fills any missing category at full marks, and always
#   denominates the total /100. The verdict word in the Total row is preserved.
_normalize_markdown_scorecard_total() {
  local summary_file="$1"
  [ -f "$summary_file" ] || return 0

  local tmp_file
  tmp_file=$(mktemp -t "diffhound-summary.XXXXXX")

  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function rnd(x)  { return int(x + 0.5) }
    # Map any model category label to a canonical key (or "" if not a category).
    function canon(name,   n) {
      n = tolower(name); gsub(/\*/, "", n); sub(/\(.*$/, "", n); n = trim(n)
      if (n ~ /^secur/)                 return "Security"
      if (n ~ /^test/)                  return "Tests"
      if (n ~ /^observ/)                return "Observability"
      if (n ~ /^perf/)                  return "Performance"
      if (n ~ /^read/)                  return "Readability"
      if (n ~ /^(compat|backward|api)/) return "Compatibility"
      return ""
    }
    BEGIN {
      cmax["Security"]=25; cmax["Tests"]=20; cmax["Observability"]=10
      cmax["Performance"]=15; cmax["Readability"]=15; cmax["Compatibility"]=15
      n = split("Security Tests Observability Performance Readability Compatibility", ord, " ")
    }
    {
      lines[NR] = $0
      if ($0 !~ /^\|/) next
      split($0, cols, /\|/)
      col1 = trim(cols[2]); col2 = trim(cols[3])
      c1 = col1; c2 = col2; gsub(/\*/, "", c1); gsub(/\*/, "", c2)

      if (tolower(trim(c1)) == "total") { total_row = NR; total_verdict = trim(cols[4]); next }

      if (c2 ~ /^-?[0-9]+\/[0-9]+$/) {
        k = canon(c1)
        if (k != "") {
          split(c2, sp, "/"); sc = sp[1] + 0; mx = sp[2] + 0
          if (mx > 0) {
            v = rnd(sc / mx * cmax[k])
            if (v > cmax[k]) v = cmax[k]; if (v < 0) v = 0
            cscore[k] = v; cnote[k] = trim(cols[4]); seen[k] = 1
            if (firstcat == 0 || NR < firstcat) firstcat = NR
          }
          found = 1
        }
      }
    }
    END {
      if (!found || total_row == 0) { for (i = 1; i <= NR; i++) print lines[i]; exit }
      # Total is normalized to /100 over the dimensions the model ACTUALLY
      # scored. A missing dimension is shown as "not scored" and excluded from
      # the denominator — we never invent a full-marks score for a dimension the
      # model did not evaluate (that would silently inflate toward APPROVE), nor
      # penalize it to zero. Present dimensions are pinned to canonical weights.
      pscore = 0; pmax = 0
      for (i = 1; i <= n; i++) { k = ord[i]; if (k in seen) { pscore += cscore[k]; pmax += cmax[k] } }
      tot = (pmax > 0) ? int(pscore / pmax * 100 + 0.5) : 0
      for (i = 1; i <= NR; i++) {
        if (i == total_row) { print "| **Total** | **" tot "/100** | " total_verdict " |"; continue }
        is_cat = 0
        if (lines[i] ~ /^\|/) {
          split(lines[i], cc, /\|/); a = trim(cc[2]); b = trim(cc[3]); gsub(/\*/, "", a); gsub(/\*/, "", b)
          if (tolower(trim(a)) != "total" && b ~ /^-?[0-9]+\/[0-9]+$/ && canon(a) != "") is_cat = 1
        }
        if (is_cat) {
          if (i == firstcat) {
            for (j = 1; j <= n; j++) {
              k = ord[j]
              if (k in seen) print "| " k " (" cmax[k] "%) | " cscore[k] "/" cmax[k] " | " cnote[k] " |"
              else           print "| " k " (" cmax[k] "%) | — | not scored (excluded from total) |"
            }
          }
          continue
        }
        print lines[i]
      }
    }
  ' "$summary_file" > "$tmp_file" && mv "$tmp_file" "$summary_file" || rm -f "$tmp_file"
}

# Parse review verdict from summary (3-method fallback)
parse_verdict() {
  local summary_file="$1"
  local comments_file="$2"
  local verdict=""

  # Method 0a (claim-verify regime): the **Total** row is reconciled from the
  # SURVIVING verified bullets by _reconcile_summary_verdict, so it is the source
  # of truth — it must win over the model's self-assigned .verdict (which still
  # reflects findings that claim-verify dropped as hallucinations).
  if [ "${DIFFHOUND_CLAIM_VERIFY:-1}" = "1" ]; then
    verdict=$(grep -i '\*\*Total\*\*' "$summary_file" | grep -oiE 'REQUEST_CHANGES|APPROVE|COMMENT' | head -1 || true)
    if [ -n "$verdict" ]; then
      echo "$verdict" | tr '[:lower:]' '[:upper:]'
      return
    fi
  fi

  # Method 0: Check for parsed JSON
  local json_file="${comments_file%.comments}.json"
  if [ -f "$json_file" ]; then
    verdict=$(jq -r '.verdict // empty' "$json_file" 2>/dev/null || true)
    if [ -n "$verdict" ]; then
      echo "$verdict" | tr '[:lower:]' '[:upper:]'
      return
    fi
  fi

  # Method 1: Extract verdict word from scorecard **Total** row
  verdict=$(grep -i '\*\*Total\*\*' "$summary_file" | grep -oiE 'REQUEST_CHANGES|APPROVE|COMMENT' | head -1 || true)
  if [ -n "$verdict" ]; then
    echo "$verdict" | tr '[:lower:]' '[:upper:]'
    return
  fi

  # Method 2: Parse numeric score from **Total** row
  local score
  score=$(grep -i '\*\*Total\*\*' "$summary_file" | grep -oE '[0-9]+/100' | grep -oE '^[0-9]+' || true)
  if [ -n "$score" ]; then
    if [ "$score" -ge 90 ]; then
      echo "APPROVE"
    elif [ "$score" -lt 85 ]; then
      echo "REQUEST_CHANGES"
    else
      echo "COMMENT"
    fi
    return
  fi

  # Method 3: Derive from comment severities
  local has_blocking has_shouldfix
  has_blocking=$(grep -ci ':BLOCKING' "$comments_file" 2>/dev/null | head -1 || true)
  has_blocking=$(echo "${has_blocking:-0}" | tr -d '[:space:]')
  has_blocking=${has_blocking:-0}
  has_shouldfix=$(grep -ciE ':SHOULD[-_]FIX' "$comments_file" 2>/dev/null | head -1 || true)
  has_shouldfix=$(echo "${has_shouldfix:-0}" | tr -d '[:space:]')
  has_shouldfix=${has_shouldfix:-0}
  if [ "$has_blocking" -gt 0 ]; then
    echo "REQUEST_CHANGES"
  elif [ "$has_shouldfix" -gt 0 ]; then
    echo "COMMENT"
  else
    echo "APPROVE"
  fi
}

# Snap line number to nearest valid diff line
# GitHub rejects comments on lines not in the diff
snap_to_diff_line() {
  local file="$1" target_line="$2" diff_file="$3"
  local valid_lines
  valid_lines=$(awk -v f="$file" '
    /^diff --git/ { in_file = 0 }
    /^diff --git a\// {
      split($0, parts, " b/")
      if (parts[2] == f) in_file = 1; else in_file = 0
      next
    }
    in_file && /^@@ / {
      # Parse @@ -old,count +new,count @@ (POSIX-compatible)
      s = $0
      sub(/.*\+/, "", s)
      sub(/,.*/, "", s)
      cur_line = int(s) - 1
      next
    }
    in_file && /^-/ { next }
    in_file && /^\+/ { cur_line++; print cur_line; next }
    in_file && /^ / { cur_line++; print cur_line; next }
    in_file { cur_line++ }
  ' "$diff_file" | sort -n -u)

  if [ -z "$valid_lines" ]; then
    echo "$target_line"
    return
  fi

  echo "$valid_lines" | awk -v t="$target_line" '
    BEGIN { best = -1; best_dist = 999999 }
    {
      d = ($1 > t) ? ($1 - t) : (t - $1)
      if (d < best_dist) { best_dist = d; best = $1 }
    }
    END { print (best > 0) ? best : t }
  '
}

# Strip severity label from comment body
# COMMENT: format is "path:LINE:SEVERITY — body". Returns only body.
strip_severity_label() {
  local text="$1"
  printf '%s' "$text" | sed -e 's/^[A-Z][A-Z_-]* [—–-] *//' -e "s/^[A-Z][A-Z_-]*$(printf '\x1f')//" | tr $'\x1f' '\n'
}

# Extract confidence scores from parsed JSON for verification pass
# Returns: file:line:confidence (one per line)
get_confidence_scores() {
  local json_file="$1"
  [ -f "$json_file" ] || return 0
  jq -r '.findings[] | "\(.file):\(.line):\(.confidence // 0.5)"' "$json_file" 2>/dev/null || true
}
