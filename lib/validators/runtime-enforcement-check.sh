#!/usr/bin/env bash
# runtime-enforcement-check.sh — DROP findings that claim a server-side
# policy/validator rejects an input on the affected runtime path, when no
# call site in the affected feature directory actually invokes the policy's
# enforcement function.
#
# Driven by monorepo PR #7297 (BX-3223), 2026-05-29, v0.7.2: bot posted 3
# BLOCKING inline comments + 4 REQUEST_CHANGES rounds claiming `.docx` would
# fail `assertUploadAllowed` because `services/api/src/files/uploadPolicy.ts`'s
# `ClaimDocument` policy only allows pdf+images. In reality, the claim-upload
# mutation (`services/api/src/claims/claimFiles/mutations.ts`) doesn't call
# `assertUploadAllowed` at all, and the lower-level call chain
# (`ClaimFilesHandler.uploadFile` → `uploadFileToCloud`) drops the `action`
# discriminator before reaching the policy gate — `assertUploadAllowed`
# early-returns on `undefined` action. Server pass-through. No 500.
#
# Citation-discipline (v0.5.0) didn't catch it: the bot wrote a syntactically
# valid REACHABLE_PATH pointing at the policy *declaration* lines, satisfying
# the presence gate. The verifier (v0.7.0) didn't catch it either: every
# backticked symbol existed, the cited code window matched the claim — but
# the failure mode requires a call chain Haiku doesn't trace.
#
# Trigger (ALL must hold):
#   1. WHAT contains an enforcement-firing phrase signalling "server will
#      reject" / "fails at the server after client" / "throws CustomError" /
#      "passes (client|picker|vue) validation and fails server-side" / etc.
#      Conservative wording match — see ENFORCE_WORDS below.
#   2. REACHABLE_PATH cites a file that looks like a policy-config declaration
#      (uploadPolicy*.ts, *Policies*.ts, files declaring `const X_POLICIES`
#      or `Partial<Record<...>>`-shape lookup tables).
#   3. FINDING line carries a resolvable feature path under $DIFFHOUND_REPO
#      (the side accused of triggering server rejection).
#
# Action:
#   - Parse the policy file to extract the exported enforcement-gate function
#     name(s) — declarations like `export function assert*` / `validate*` /
#     `enforce*` / `check*` followed by an UpperCamel identifier.
#   - Identify the affected feature directory from the FINDING file path
#     (take the first 3 path segments — e.g., `services/api/src/claims` from
#     `services/api/src/claims/claimFiles/mutations.ts`, or for client-side
#     findings, infer the server twin by mapping `services/portal/src/...` →
#     `services/api/src/<terminal-segment-of-portal-path>`).
#   - grep the affected feature dir for invocations of the enforcement
#     function(s).
#   - If 0 reachable call sites → DROP. The "server will reject" claim is
#     unreachable; finding is a false positive.
#
# False-drop guards:
#   - ABSENCE_WORDS exemption: claims about a guard that was *deleted* or
#     *removed* might be legitimately calling out a regression on the path
#     where the guard USED to fire. Skip drop.
#   - File-not-readable for policy file → no-op (can't verify, don't drop).
#   - No enforcement function name extractable from policy file → no-op.
#   - Affected feature dir is missing → no-op.
#   - If ANY call site to the enforcement function exists anywhere in the
#     repo's affected service directory (e.g., services/api/src) → no-op.
#     Leaves the finding alone unless we can prove the call-graph gap.
#   - Opt-out: `DIFFHOUND_DISABLE_RUNTIME_ENFORCEMENT_CHECK=1` → pass-through.
#
# Pipeline placement: AFTER cross-file-comparison-check, BEFORE
# pre-existing-pattern. Same band as the other "structural reachability"
# validators. High-confidence drops short-circuit the citation/severity gate
# downstream.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Opt-out switch for emergency disable without code edit.
if [ "${DIFFHOUND_DISABLE_RUNTIME_ENFORCEMENT_CHECK:-0}" = "1" ]; then
  cat
  exit 0
fi

# ────────────────────────────────────────────────────────────────────
# Wording gates

# Enforcement-firing phrases. Any one match triggers consideration; the
# policy-file and reachability checks then decide drop-vs-keep.
ENFORCE_WORDS_1='\b(server[- ]side|server)\s+(will\s+)?(reject|throws?|returns?\s+[0-9]{3}|400|500)\b'
ENFORCE_WORDS_2='\b(passes?|passing|pass)\s+(the\s+)?(client|picker|file\s+picker|vue|vue-side|client-side)\s+(validation|check|validator)\b'
ENFORCE_WORDS_3='\b(fails?|failing|fail)\s+(at\s+the\s+)?(server|server[- ]side|api\s+side|api)\b'
ENFORCE_WORDS_4='\bthrows?\s+(a\s+)?(custom[- ]?error|errors?|exception)\b.*\b(server|api|policy)'
ENFORCE_WORDS_5='\b(policy|allow-?list|allowlist)\s+(will\s+)?(reject|rejects?|throws?|fails?|enforces?)\b'
ENFORCE_WORDS_6='\bclient[- ]server\s+(mismatch|gap|disconnect)\b'
ENFORCE_WORDS_7='\b(assertUpload[A-Za-z_]*|assert[A-Z][A-Za-z]+Allowed|validate[A-Z][A-Za-z]+Allowed)\b'
ENFORCE_WORDS_8='\b(after|then)\s+(it\s+)?(passes?|passing|client[- ]validation)\b.*\b(server|api)\b.*\b(error|reject)'
# v0.7.3 broaden: PR #7297 round 3 (claimDocUploadSchema.js) inline body said
# "server `ClaimDocument` policy still only allows pdf/jpg/jpeg/png/webp"
# without any reject/throw/fail verb — the structural shape is "X policy
# (still) only allows Y", which still implies server-side enforcement on
# the affected path. Catch that.
# Use `.{0,N}` (any char) — `[^.]` would block matches across file paths
# like `uploadPolicy.ts:29-33`. grep is line-oriented so `.` doesn't cross
# newlines; we accept potential sentence-boundary crossing in exchange for
# tolerating filename periods.
ENFORCE_WORDS_9='\bpolicy\b.{0,80}\b(only allows|only permits|disallows|allows only|restricts to)\b'
# Bidirectional mismatch wording — finding may say "doc/docx mismatch" or
# "client-server mismatch" or "allowlist mismatch" without the verb.
ENFORCE_WORDS_10='\b(client[- ]?server|extension|policy|allow-?list|allowlist|server[- ]side)\b.{0,40}\b(mismatch|gap|inconsistency|disconnect)\b'
ENFORCE_WORDS_11='\b(mismatch|gap|inconsistency)\b.{0,40}\b(client[- ]?server|client|server|policy|allowlist)\b'

# Absence wording exemption — same shape as cross-file-comparison-check.sh.
ABSENCE_WORDS='deleted|removed|dropped|drops? the|removes? the|no longer (defined|present|exists|enforces|checks|guards)|was renamed|has been (deleted|removed|renamed|dropped)|used to (call|invoke|enforce)|previously (called|invoked|enforced)'

# Policy-file heuristics. Either path-pattern OR content-shape qualifies.
POLICY_PATH_RE='(^|/)(upload[Pp]olicy|.*[Pp]olicies?|policy)\.(ts|js|tsx)$'
POLICY_CONTENT_RE='(const\s+[A-Z_]+_POLICIES?\b|Partial<Record<[^>]*Policy|export\s+(const|function)\s+(UPLOAD_POLICIES|ACTION_POLICIES))'

# Enforcement function declaration pattern. Nova convention: assert* /
# validate* / enforce* / check*  ensure*  followed by an UpperCamel suffix.
ENFORCE_FN_DECL='export\s+function\s+(assert|validate|enforce|check|ensure)[A-Z][A-Za-z0-9_]*\s*\('

# Source extensions to grep for call sites.
SRC_GREP_GLOBS=(
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx'
  --include='*.py' --include='*.vue'
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build
  --exclude-dir=.git --exclude-dir=__pycache__
)

# ────────────────────────────────────────────────────────────────────
# State

block=""
what=""
finding_path=""
header_prefix=""
reachable_path_raw=""

_emit_block() {
  [ -z "$block" ] && return
  printf '%s' "$block"
}

_drop_block() {
  local reason="$1"
  printf '[runtime-enforcement-check] DROPPED (%s): %s\n' \
    "$reason" "$header_prefix" >&2
}

# Extract a file path from a colon-prefixed header like "FINDING: a/b.ts:42".
_extract_path() {
  local header="$1"
  header="${header#FINDING: }"
  header="${header#REACHABLE_PATH: }"
  # Take the first whitespace-delimited token then strip ":line[-line]" tail.
  local tok="${header%% *}"
  printf '%s' "${tok%%:*}"
}

# Pull the first path-like token from arbitrary prose (REACHABLE_PATH content
# can be free-form). Matches "<segs>.<ext>" with optional "::line" trailer.
_first_path_in_prose() {
  local prose="$1"
  printf '%s' "$prose" \
    | grep -oE '([A-Za-z0-9_\-]+/){1,}[A-Za-z0-9_\-]+\.(ts|tsx|js|jsx|py|vue)' \
    | head -1
}

# Decide whether a file looks like a policy-config file. Path-pattern wins
# if it matches; otherwise content-shape match.
_is_policy_file() {
  local full="$1"
  [ -f "$full" ] || return 1
  local rel="${full#$DIFFHOUND_REPO/}"
  if printf '%s' "$rel" | grep -qE -- "$POLICY_PATH_RE"; then
    return 0
  fi
  if grep -qE -- "$POLICY_CONTENT_RE" "$full" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Extract exported enforcement function names from the policy file.
# One name per output line.
_extract_enforce_fns() {
  local full="$1"
  grep -oE -- "$ENFORCE_FN_DECL" "$full" 2>/dev/null \
    | sed -E 's/.*function[[:space:]]+//' \
    | sed -E 's/[[:space:]]*\(.*//' \
    | sort -u
}

# Map the FINDING file to the affected service-side feature directory.
# Strategy:
#   - If finding lives in services/api/src/<feature>/... → that feature dir.
#   - If finding lives in services/portal/src/.../<terminal>... → look for
#     a same-name feature dir under services/api/src (claims, endorsements,
#     orgs etc). Falls back to services/api/src if no twin found.
#   - Otherwise → return parent dir of finding (best-effort).
_affected_feature_dir() {
  local rel="$1"
  local dir
  # services/api/src/<feature> case
  if printf '%s' "$rel" | grep -qE '^services/api/src/[A-Za-z0-9_\-]+/'; then
    dir=$(printf '%s' "$rel" | sed -E 's|^(services/api/src/[A-Za-z0-9_\-]+)/.*|\1|')
    printf '%s\n' "$dir"
    return
  fi
  # services/portal/src/.../<feature-keyword>/... → twin under api
  if printf '%s' "$rel" | grep -qE '^services/portal/src/'; then
    # Try every path segment after "src/" as a candidate feature name and
    # see if services/api/src/<seg> exists.
    local IFS='/'
    local seg
    for seg in $(printf '%s' "$rel" | sed -E 's|^services/portal/src/||'); do
      [ -z "$seg" ] && continue
      [ -d "$DIFFHOUND_REPO/services/api/src/$seg" ] && {
        printf 'services/api/src/%s\n' "$seg"
        return
      }
    done
    # Specific known mappings for files that don't carry the feature in path.
    # Match on filename / path substrings (no leading-slash anchor).
    case "$rel" in
      *ClaimAssist*|*ClaimForm*|*claim*|*Claim*)   printf 'services/api/src/claims\n'; return ;;
      *Endorsement*|*endorsement*)                 printf 'services/api/src/endorsements\n'; return ;;
      *OrgDoc*|*orgDoc*|*orgs/*|*organisation*|*organization*) printf 'services/api/src/orgs\n'; return ;;
    esac
    # Generic fallback — return empty so the call-site count is 0 and we
    # err on the side of "can't verify reachability" → no drop.
    printf '\n'
    return
  fi
  # Fallback: parent dir of finding file.
  printf '%s\n' "$(dirname "$rel")"
}

# Count call sites of any enforcement function in the affected dir.
_count_call_sites() {
  # Count CALL sites of any enforcement function in $feature_dir. Excludes
  # the function's own declaration (export function fn() / function fn()) and
  # excludes the policy file itself (where the declaration lives).
  local fns_file="$1" feature_dir="$2" policy_rel="$3"
  [ -z "$feature_dir" ] && { printf '0'; return; }
  local full_feature="$DIFFHOUND_REPO/$feature_dir"
  [ -d "$full_feature" ] || { printf '0'; return; }
  local total=0
  local fn
  while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    local hits
    hits=$(grep -rE "\\b${fn}\\(" "$full_feature" "${SRC_GREP_GLOBS[@]}" 2>/dev/null \
      | grep -vE "(export[[:space:]]+)?function[[:space:]]+${fn}[[:space:]]*\\(" \
      | grep -vE "(^|:)([^:]*/)?${policy_rel##*/}:" \
      || true)
    local n
    n=$(printf '%s' "$hits" | grep -c . || true)
    total=$((total + ${n:-0}))
  done < "$fns_file"
  printf '%s' "$total"
}

_check_and_emit() {
  if [ -z "$block" ]; then return; fi

  # Absence-wording exemption.
  if printf '%s' "$what" | grep -qiE -- "$ABSENCE_WORDS"; then
    _emit_block; block=""; what=""; finding_path=""; header_prefix=""; reachable_path_raw=""; return
  fi

  # Need at least one enforcement-firing phrase.
  local has_trigger=0
  if printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_1" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_2" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_3" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_4" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_5" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_6" \
   || printf '%s' "$what" | grep -qE  -- "$ENFORCE_WORDS_7" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_8" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_9" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_10" \
   || printf '%s' "$what" | grep -qiE -- "$ENFORCE_WORDS_11"; then
    has_trigger=1
  fi
  if [ "$has_trigger" -eq 0 ]; then
    _emit_block; block=""; what=""; finding_path=""; header_prefix=""; reachable_path_raw=""; return
  fi

  # Need a policy-config file reference in REACHABLE_PATH (preferred) or
  # WHAT prose as fallback.
  local policy_rel=""
  policy_rel=$(_first_path_in_prose "$reachable_path_raw")
  if [ -z "$policy_rel" ]; then
    policy_rel=$(_first_path_in_prose "$what")
  fi
  if [ -z "$policy_rel" ]; then
    _emit_block; block=""; what=""; finding_path=""; header_prefix=""; reachable_path_raw=""; return
  fi
  local policy_full="$DIFFHOUND_REPO/$policy_rel"
  if ! _is_policy_file "$policy_full"; then
    _emit_block; block=""; what=""; finding_path=""; header_prefix=""; reachable_path_raw=""; return
  fi

  # Extract enforcement function name(s) from the policy file. If none
  # found, can't verify reachability — pass through.
  local fns_tmp
  fns_tmp=$(mktemp -t "ref-fns.XXXXXX")
  _extract_enforce_fns "$policy_full" > "$fns_tmp"
  if [ ! -s "$fns_tmp" ]; then
    rm -f "$fns_tmp"
    _emit_block; block=""; what=""; finding_path=""; header_prefix=""; reachable_path_raw=""; return
  fi

  # Need a resolvable FINDING file.
  if [ -z "$finding_path" ]; then
    rm -f "$fns_tmp"
    _emit_block; block=""; what=""; finding_path=""; header_prefix=""; reachable_path_raw=""; return
  fi
  local finding_full="$DIFFHOUND_REPO/$finding_path"
  # finding file may not exist on disk in some run modes; that's OK — we
  # only need it to derive the feature dir from the path string.

  # Derive the affected feature dir and count call sites.
  local feature_dir
  feature_dir=$(_affected_feature_dir "$finding_path")
  local n_calls
  n_calls=$(_count_call_sites "$fns_tmp" "$feature_dir" "$policy_rel")
  rm -f "$fns_tmp"

  if [ "$n_calls" -eq 0 ]; then
    local fn_list
    fn_list=$(_extract_enforce_fns "$policy_full" | head -3 | tr '\n' ',' | sed 's/,$//')
    _drop_block "policy $policy_rel declares [$fn_list] but no call site in $feature_dir invokes any"
    block=""; what=""; finding_path=""; header_prefix=""; reachable_path_raw=""
    return
  fi

  _emit_block; block=""; what=""; finding_path=""; header_prefix=""; reachable_path_raw=""
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _check_and_emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
      finding_path=$(_extract_path "$line")
      ;;
    REACHABLE_PATH:*)
      block+="$line"$'\n'
      reachable_path_raw="${reachable_path_raw}${line#REACHABLE_PATH: } "
      ;;
    WHAT:*|EVIDENCE:*|IMPACT:*|OPTIONS:*)
      block+="$line"$'\n'
      what="${what}${line} "
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
_check_and_emit
