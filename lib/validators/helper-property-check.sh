#!/usr/bin/env bash
# helper-property-check.sh — DROP findings that claim the calling code is
# missing a safety/quality property (timeout, caching, retry) when the
# called helper function actually provides that property in its definition.
#
# Driven by monorepo PR #7303 (BF-44) review, 2026-05-29, v0.7.3: bot
# scored Performance 5/15 on the cf-backfill processor citing "missing
# timeouts on CRM API calls" and "token re-fetch per SO is wasteful if
# getZohoCrmAccessToken isn't caching". both claims were false:
#   - every CRM/Books axios call in zohoCrmProducts.ts and zohoBooks.ts
#     uses ZOHO_REQUEST_TIMEOUT_MS / ZOHO_BOOKS_REQUEST_TIMEOUT_MS
#     (zohoCrmProducts.ts:14,92,104,117,146,163,209,230,243 + zohoBooks.ts:
#     193,213,249,490,519,558).
#   - getZohoCrmAccessToken is exported as tokenCache.getAccessToken
#     (zohoCrmProducts.ts:69-81 — wraps createZohoTokenCache).
# bot read calling code in isolation, didn't open the helper definitions.
# this is the sibling pattern to runtime-enforcement-check (v0.7.3):
# v0.7.3 catches "policy enforces on this path" → check if it actually does.
# this catches "calling code lacks property P" → check if the called
# helper provides P.
#
# trigger (BOTH must hold):
#   1. WHAT contains a missing-property phrase:
#      - timeout family: "missing timeout", "no timeout", "without timeout",
#        "lacks a timeout", "risks hang", "could hang", "hang indefinitely",
#        "block indefinitely"
#      - cache family: "uncached", "not cached", "wasteful (if ... isn't|not)
#        caching", "re-fetch (per|each)", "fetched each time", "token .* per",
#        "per (call|request|iteration|item|run)"
#   2. WHAT contains at least one backticked function-call-like identifier
#      that looks like a helper (camelCase verb-prefix: fetch/get/load/post/
#      put/delete/upload/etc., or wrapper helpers ending in *Cache, *Client).
#
# action: for each candidate helper identifier:
#   - grep $DIFFHOUND_REPO for its definition:
#       `function <name>`, `const <name> =`, `export ... <name> =`,
#       `<name>:` (object-method shorthand only when preceded by `,` or `{`).
#   - if a definition is found, extract the body window (next ~60 lines
#     or until column-0 `}`, whichever first).
#   - check the body for the asserted property:
#       timeout claim → body matches `\btimeout(Ms)?\s*[:=]` OR `\bsignal\s*:`
#                       OR helper itself is named *Timeout / *WithTimeout.
#       cache claim   → body matches `[Cc]ache|memoize|TTL|expir`
#                       OR helper itself is wrapped in *Cache, *Memoized.
#   - if ANY candidate helper has the property → DROP. the FP is contradicted
#     by visible evidence in the helper source.
#
# false-drop guards:
#   - ABSENCE_WORDS exemption (claims about removed timeout/cache).
#   - 0 candidate identifiers → no-op (can't verify).
#   - 0 candidates with a findable definition → no-op (can't verify).
#   - file-not-readable → no-op.
#   - opt-out: DIFFHOUND_DISABLE_HELPER_PROPERTY_CHECK=1.
#
# pipeline placement: AFTER runtime-enforcement-check, BEFORE
# auth-gate-precedes-check. Same band as the "structural reachability"
# validators. High-confidence drops short-circuit the downstream gates.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

if [ "${DIFFHOUND_DISABLE_HELPER_PROPERTY_CHECK:-0}" = "1" ]; then
  cat
  exit 0
fi

# ────────────────────────────────────────────────────────────────────
# Wording gates

# timeout-family triggers — any match qualifies the finding for verification.
TIMEOUT_WORDS_1='\b(missing|no|without|lacks|lack of|absent)\b.{0,40}\btimeouts?\b'
TIMEOUT_WORDS_2='\b(risks?|may|could|might)\b.{0,40}\bhang(ing)?\b'
TIMEOUT_WORDS_3='\b(hang|hangs|hanging|block|blocks|blocking)\b\s+(indefinitely|forever|the (job|loop|process|hourly job|worker))'
TIMEOUT_WORDS_4='\bno\s+timeout\s+on\b'

# cache-family triggers.
CACHE_WORDS_1='\b(uncached|not\s+cached|no\s+cach(e|ing))\b'
CACHE_WORDS_2='\bwasteful\b.{0,60}\b(if\b.{0,40}(isn'"'"'t|not|aren'"'"'t)\b.{0,20}\bcach(e|ing)|cach(e|ing))'
CACHE_WORDS_3='\bre-?fetch(ed|ing|es)?\b.{0,40}\b(per|each|every)\b'
CACHE_WORDS_4='\b(token|access[- ]token|credential[s]?|secret[s]?)\b.{0,40}\b(per|each|every)\s+(call|request|iteration|item|run|so|loop)'
CACHE_WORDS_5='\b(fetched|loaded|retrieved)\s+(each|every|on\s+each|on\s+every)\b'

# absence-wording exemption — claims about a property that was removed.
ABSENCE_WORDS='deleted|removed|dropped|removes? the|no longer (has|defines|sets|caches|uses)|was renamed|has been (deleted|removed|renamed|dropped)|used to (have|set|cache|use)|previously (had|set|cached|used)'

# Source extensions to grep for definitions.
# Test/mock dirs are excluded — Jest's `jest.mock('module', () => ({ fn: ... }))`
# stubs commonly set `timeout: 1000` or fake caches, which would false-drop a
# real "missing X" finding if `head -1` happened to rank the mock before the
# production definition. Safer to ignore tests entirely; if a real prod helper
# happens to live under tests/ (rare), this validator no-ops rather than
# false-drops.
SRC_GLOBS=(
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx'
  --include='*.py' --include='*.vue'
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build
  --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=coverage
  --exclude-dir=tests --exclude-dir=test --exclude-dir=__tests__
  --exclude-dir=__mocks__ --exclude-dir=mocks --exclude-dir=fixtures
)

# Reasonable verb-prefix list for helper-shaped identifiers.
HELPER_PREFIX_RE='^(fetch|get|load|post|put|delete|upload|download|send|invoke|call|create|build|make|run|exec|query|find|lookup|read|write|stream|ensure|resolve|sign|encrypt|decrypt|hash)[A-Z]'

# Suffix hints that often imply a wrapper helper carrying the property.
HELPER_SUFFIX_RE='(Cache|Cached|Memoized|Client|Pool|Conn|Connection|WithTimeout|WithRetry|Bounded|Limited)$'

# Property-presence regexes for helper bodies.
TIMEOUT_PROP_RE='\b(timeout(Ms)?|signal)\s*[:=]'
TIMEOUT_NAME_RE='([Tt]imeout|[Ww]ithTimeout)\b'
CACHE_PROP_RE='([Cc]ache|memoize|memoise|TTL|expiresAt|expiresIn|cachedAt|getAccessToken)'
CACHE_NAME_RE='(Cache|Cached|Memoized|TokenCache)\b'

# ────────────────────────────────────────────────────────────────────
# State

block=""
what=""
header_prefix=""

_emit_block() {
  [ -z "$block" ] && return
  printf '%s' "$block"
}

_reset() {
  block=""; what=""; header_prefix=""
}

_drop_block() {
  local reason="$1"
  printf '[helper-property-check] DROPPED (%s): %s\n' \
    "$reason" "$header_prefix" >&2
}

# Extract backticked identifiers that look like helper functions from $what.
# Match: word chars (and optional dot path), optional trailing "()". Drop
# anything that doesn't pass either HELPER_PREFIX_RE or HELPER_SUFFIX_RE.
_extract_candidates() {
  printf '%s' "$what" \
    | grep -oE '`[A-Za-z_][A-Za-z0-9_]*(\(\))?`' \
    | tr -d '`()' \
    | sort -u \
    | while IFS= read -r id; do
        [ -z "$id" ] && continue
        [ "${#id}" -lt 4 ] && continue
        if printf '%s' "$id" | grep -qE -- "$HELPER_PREFIX_RE" \
           || printf '%s' "$id" | grep -qE -- "$HELPER_SUFFIX_RE"; then
          printf '%s\n' "$id"
        fi
      done
}

# Locate a definition for an identifier. Returns "<file>:<line>" or empty.
# Search patterns:
#   - function <name>(           (function declaration)
#   - const <name> =             (assigned)
#   - let <name> =
#   - export const <name> =
#   - export function <name>(
#   - export async function <name>(
#   - <name>:                    (object-method shorthand) — too noisy, skip
_find_definition() {
  local id="$1"
  local pat="(function|async\s+function|const|let|export\s+(const|let|function|async\s+function|default\s+(async\s+)?function))\s+${id}\b"
  grep -rEn "${SRC_GLOBS[@]}" -- "$pat" "$DIFFHOUND_REPO" 2>/dev/null \
    | head -1
}

# Extract the next N lines after a definition's file:line as the body window.
_def_body() {
  local file="$1" line="$2" max="${3:-60}"
  awk -v start="$line" -v n="$max" 'NR >= start && NR < start + n' "$file" 2>/dev/null
}

_check_and_emit() {
  if [ -z "$block" ]; then return; fi

  # Absence-wording exemption.
  if printf '%s' "$what" | grep -qiE -- "$ABSENCE_WORDS"; then
    _emit_block; _reset; return
  fi

  # Detect which claim families fire.
  local is_timeout_claim=0 is_cache_claim=0
  if printf '%s' "$what" | grep -qiE -- "$TIMEOUT_WORDS_1" \
   || printf '%s' "$what" | grep -qiE -- "$TIMEOUT_WORDS_2" \
   || printf '%s' "$what" | grep -qiE -- "$TIMEOUT_WORDS_3" \
   || printf '%s' "$what" | grep -qiE -- "$TIMEOUT_WORDS_4"; then
    is_timeout_claim=1
  fi
  if printf '%s' "$what" | grep -qiE -- "$CACHE_WORDS_1" \
   || printf '%s' "$what" | grep -qiE -- "$CACHE_WORDS_2" \
   || printf '%s' "$what" | grep -qiE -- "$CACHE_WORDS_3" \
   || printf '%s' "$what" | grep -qiE -- "$CACHE_WORDS_4" \
   || printf '%s' "$what" | grep -qiE -- "$CACHE_WORDS_5"; then
    is_cache_claim=1
  fi
  if [ "$is_timeout_claim" -eq 0 ] && [ "$is_cache_claim" -eq 0 ]; then
    _emit_block; _reset; return
  fi

  # Candidate helper identifiers from backticks in WHAT.
  local cands_tmp
  cands_tmp=$(mktemp -t "hpc-cands.XXXXXX")
  _extract_candidates > "$cands_tmp"
  if [ ! -s "$cands_tmp" ]; then
    rm -f "$cands_tmp"
    _emit_block; _reset; return
  fi

  # For each candidate, find a definition; if found, check property.
  local any_def_found=0
  local id def file line body
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    def=$(_find_definition "$id")
    [ -z "$def" ] && continue
    any_def_found=1

    # def looks like  /abs/path/to/file.ts:42:export function foo(...
    file=$(printf '%s' "$def" | awk -F: '{print $1}')
    line=$(printf '%s' "$def" | awk -F: '{print $2}')
    case "$line" in ''|*[!0-9]*) continue ;; esac

    body=$(_def_body "$file" "$line" 80)

    if [ "$is_timeout_claim" -eq 1 ]; then
      if printf '%s' "$body" | grep -qE -- "$TIMEOUT_PROP_RE"; then
        rm -f "$cands_tmp"
        _drop_block "helper $id at ${file#$DIFFHOUND_REPO/}:$line sets a timeout/signal in its body"
        _reset; return
      fi
      if printf '%s' "$id" | grep -qE -- "$TIMEOUT_NAME_RE"; then
        rm -f "$cands_tmp"
        _drop_block "helper $id name itself signals timeout property"
        _reset; return
      fi
    fi

    if [ "$is_cache_claim" -eq 1 ]; then
      if printf '%s' "$body" | grep -qE -- "$CACHE_PROP_RE"; then
        rm -f "$cands_tmp"
        _drop_block "helper $id at ${file#$DIFFHOUND_REPO/}:$line shows caching in its body"
        _reset; return
      fi
      if printf '%s' "$id" | grep -qE -- "$CACHE_NAME_RE"; then
        rm -f "$cands_tmp"
        _drop_block "helper $id name itself signals caching"
        _reset; return
      fi
    fi
  done < "$cands_tmp"

  rm -f "$cands_tmp"
  # Couldn't find any helper definition OR no helper had the property → keep.
  _emit_block; _reset
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      _check_and_emit
      block="$line"$'\n'
      header_prefix="${line#FINDING: }"
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
