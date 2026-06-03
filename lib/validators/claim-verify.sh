#!/usr/bin/env bash
# claim-verify.sh — the single claim-verification engine.
#
# THE ABSTRACTION (replaces the pile of wording-specific validators):
#   Every finding rests on falsifiable factual claims about the code. Verify each
#   claim against ground truth before the finding influences verdict/score/output.
#   FALSE claim -> drop. UNVERIFIABLE -> cap at OPEN_QUESTION. TRUE -> keep.
#
# Claims come from two sources, in priority order:
#   1. EXPLICIT — a `CLAIMS:` line the model emits, "; "-separated, each claim:
#        type:subject:scopeOrLocation:expected
#      e.g.  CLAIMS: symbol_defined:usersCount:repo:false; dependency_version:marked::<4.0.0
#   2. IMPLICIT — extracted from the WHAT/EVIDENCE prose when no CLAIMS: line is
#      present (so the engine works before the model adopts the schema, and
#      subsumes ref-exists / vuln-symbol / reverify-absence / node-modules /
#      dependency-exists).
#
# Checker registry — one function per claim type, returns: TRUE | FALSE | UNVERIFIABLE
#   symbol_defined      — is `subject` defined anywhere in the repo?
#   dependency_version  — does `subject`'s package.json range satisfy `expected`?
#   file_contains       — does `location` contain `subject`?
#   call_reachable      — best-effort; UNVERIFIABLE unless clearly traceable.
#
# Gated by DIFFHOUND_CLAIM_VERIFY=1 (default off -> pass-through). Reads FINDING:
# blocks on stdin, writes kept/downgraded blocks to stdout, audit notes to stderr.
# DIFFHOUND_REPO must point to the PR working tree.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Pass-through when disabled — keeps it a safe no-op until we flip the default.
if [ "${DIFFHOUND_CLAIM_VERIFY:-0}" != "1" ]; then
  cat
  exit 0
fi

# ── ground-truth checkers ────────────────────────────────────────────────────
_gt_symbol_defined() {  # $1 = symbol ; echoes "yes"/"no"
  local s="$1"
  if grep -rqE "(export[[:space:]]+(const|default|function|class)|const|let|var|function|class|def)[[:space:]]+${s}([[:space:]]|=|\(|:|<)|[\"']${s}[\"'][[:space:]]*:|^[[:space:]]*${s}[[:space:]]*[:(]" \
       "$DIFFHOUND_REPO" \
       --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' --include='*.py' --include='*.graphql' \
       --exclude-dir=node_modules 2>/dev/null; then
    echo yes
  else
    echo no
  fi
}

_gt_dependency_declared_range() {  # $1 = pkg ; echoes range or empty
  local p="$1" pj
  while IFS= read -r pj; do
    jq -r --arg p "$p" '((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {}) + (.optionalDependencies // {}))[$p] // empty' "$pj" 2>/dev/null
  done < <(find "$DIFFHOUND_REPO" -name package.json -not -path '*/node_modules/*' 2>/dev/null) | head -1
}

# Compare a declared caret/tilde range against an "expected" predicate string.
# Supports the only predicate we need today: "<MAJOR.x" style "older-than" claims
# (the marked@0.7.0 class). Returns TRUE if the claim holds, FALSE if the declared
# range contradicts it, UNVERIFIABLE if we can't decide.
_check_dependency_version() {  # $1 subject  $2 expected (e.g. "<4.0.0" or "missing")
  local pkg="$1" expected="$2" range major exp_major
  range=$(_gt_dependency_declared_range "$pkg")
  if [ "$expected" = "missing" ] || [ "$expected" = "false" ]; then
    [ -z "$range" ] && { echo TRUE; return; } || { echo FALSE; return; }
  fi
  [ -z "$range" ] && { echo UNVERIFIABLE; return; }
  # declared major from ^1.1.0 / ~1.2 / 1.x
  major=$(printf '%s' "$range" | grep -oE '[0-9]+' | head -1)
  exp_major=$(printf '%s' "$expected" | grep -oE '[0-9]+' | head -1)
  [ -z "$major" ] || [ -z "$exp_major" ] && { echo UNVERIFIABLE; return; }
  case "$expected" in
    \<*) # claim: version is OLDER than exp_major. TRUE only if declared major < exp_major.
      if [ "$major" -lt "$exp_major" ]; then echo TRUE; else echo FALSE; fi ;;
    *) echo UNVERIFIABLE ;;
  esac
}

_check_symbol_defined() {  # $1 subject  $2 expected(true|false)
  local defined; defined=$(_gt_symbol_defined "$1")
  if [ "$2" = "false" ]; then
    # model claims subject is ABSENT. TRUE iff actually absent.
    [ "$defined" = "no" ] && echo TRUE || echo FALSE
  else
    # model claims subject EXISTS (e.g. "X is a vulnerable resolver"). TRUE iff present.
    [ "$defined" = "yes" ] && echo TRUE || echo FALSE
  fi
}

_check_file_contains() {  # $1 subject  $2 location  $3 expected(true|false)
  local f="$DIFFHOUND_REPO/$2"
  [ -f "$f" ] || { echo UNVERIFIABLE; return; }
  if grep -qF -- "$1" "$f" 2>/dev/null; then present=yes; else present=no; fi
  if [ "$3" = "false" ]; then
    [ "$present" = "no" ] && echo TRUE || echo FALSE
  else
    [ "$present" = "yes" ] && echo TRUE || echo FALSE
  fi
}

_check_call_reachable() { echo UNVERIFIABLE; }  # best-effort placeholder

# Dispatch one claim string "type:subject:scopeOrLoc:expected" -> verdict.
_verify_claim() {
  local c="$1" type subject loc expected
  type=$(printf '%s' "$c" | cut -d: -f1)
  subject=$(printf '%s' "$c" | cut -d: -f2)
  loc=$(printf '%s' "$c" | cut -d: -f3)
  expected=$(printf '%s' "$c" | cut -d: -f4-)
  case "$type" in
    symbol_defined)     _check_symbol_defined "$subject" "${expected:-true}" ;;
    dependency_version) _check_dependency_version "$subject" "${expected:-missing}" ;;
    file_contains)      _check_file_contains "$subject" "$loc" "${expected:-true}" ;;
    call_reachable)     _check_call_reachable ;;
    *)                  echo UNVERIFIABLE ;;
  esac
}

# ── implicit claim extraction (no explicit CLAIMS: line) ─────────────────────
# Returns "; "-separated claims derived from the block's prose, or empty.
_extract_implicit_claims() {
  local block="$1" what claims=""
  what=$(printf '%s' "$block")

  local absence_re="does(n'?t| not) exist|do(n'?t| not) exist|not defined|don'?t exist anywhere|doesn'?t exist anywhere|missing entirely|not found anywhere|exist anywhere in the codebase"
  local vuln_re="is (the |a |an )?(companion )?(resolver|endpoint|query|mutation|handler)|companion (resolver|query|endpoint|to)|unscoped|can (be )?quer|queryable|directly via graphql|is exposed"
  local dep_absence_re="not in (any )?package\.json|missing from package\.json|not (a )?dependenc|aren'?t in (any )?package\.json|are not in (any )?package\.json|missing entirely|neither .* nor .* (appear|exist)"
  local nm_re="node_modules/[A-Za-z0-9_.@/-]+"
  local sym

  # symbol_defined (absence): "X doesn't exist" -> claim X absent
  if printf '%s' "$what" | grep -qiE "$absence_re"; then
    while IFS= read -r sym; do
      [ -n "$sym" ] && claims="${claims:+$claims; }symbol_defined:${sym}:repo:false"
    done < <(printf '%s' "$what" | grep -iE "$absence_re" | grep -oE '`@?[A-Za-z_][A-Za-z0-9_]{2,}`|[A-Z][A-Z0-9_]{3,}' | tr -d '`' | sort -u)
  fi

  # symbol_defined (phantom vuln): "`X` is unscoped/resolver" -> claim X exists
  if printf '%s' "$what" | grep -qiE "$vuln_re"; then
    sym=$(printf '%s' "$what" | grep -oiE "\`[A-Za-z_][A-Za-z0-9_]+\`[^.\`]{0,45}(${vuln_re})" | grep -oE "\`[A-Za-z_][A-Za-z0-9_]+\`" | head -1 | tr -d '`')
    [ -n "$sym" ] && claims="${claims:+$claims; }symbol_defined:${sym}:repo:true"
  fi

  # dependency_version: node_modules citation or "not in package.json"
  if printf '%s' "$what" | grep -qoiE "$nm_re"; then
    local cited; cited=$(printf '%s' "$what" | grep -oiE "$nm_re" | head -1)
    local pkg; pkg=$(printf '%s' "$cited" | sed -E 's#.*node_modules/(@[^/]+/[^/]+|[^/]+).*#\1#')
    [ -n "$pkg" ] && claims="${claims:+$claims; }dependency_version:${pkg}:nm:missing"
  fi
  if printf '%s' "$what" | grep -qiE "$dep_absence_re"; then
    while IFS= read -r sym; do
      [ -n "$sym" ] && claims="${claims:+$claims; }dependency_version:${sym}::missing"
    done < <(printf '%s' "$what" | grep -iE "$dep_absence_re" | grep -oE '`[a-z0-9@/_-]+`' | tr -d '`' | sort -u)
  fi

  printf '%s' "$claims"
}

# ── main loop ────────────────────────────────────────────────────────────────
block=""
_flush() {
  [ -z "$block" ] && return 0
  local claims explicit
  explicit=$(printf '%s\n' "$block" | grep -m1 '^CLAIMS:' | sed 's/^CLAIMS:[[:space:]]*//')
  if [ -n "$explicit" ]; then claims="$explicit"; else claims=$(_extract_implicit_claims "$block"); fi

  if [ -n "$claims" ]; then
    local worst="TRUE" c v IFS_save="$IFS"
    IFS=';'
    for c in $claims; do
      c=$(printf '%s' "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -z "$c" ] && continue
      v=$(_verify_claim "$c")
      if [ "$v" = "FALSE" ]; then worst="FALSE"; bad="$c"; break
      elif [ "$v" = "UNVERIFIABLE" ] && [ "$worst" = "TRUE" ]; then worst="UNVERIFIABLE"; bad="$c"; fi
    done
    IFS="$IFS_save"
    if [ "$worst" = "FALSE" ]; then
      printf '[claim-verify: DROP — claim FALSE: %s]\n' "$bad" >&2
      block=""; return 0
    elif [ "$worst" = "UNVERIFIABLE" ]; then
      printf '%s\n' "$(printf '%s' "$block" | sed -E "1 s#:[A-Za-z_-]+[[:space:]]*\$#:OPEN_QUESTION#")"
      printf '[claim-verify: DOWNGRADE to OPEN_QUESTION — claim unverifiable: %s]\n' "$bad" >&2
      block=""; return 0
    fi
  fi
  printf '%s\n' "$block"
  block=""
}

while IFS= read -r line || [ -n "$line" ]; do
  if [ "${line#FINDING:}" != "$line" ]; then _flush; fi
  block="${block:+$block$'\n'}$line"
done
_flush
