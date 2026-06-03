#!/usr/bin/env bash
# claim-checkers.sh — the ONE set of ground-truth checkers (invariant #1: one
# abstraction). Sourced by both the fresh-path engine (lib/validators/claim-verify.sh)
# and the re-review adapter (lib/parser.sh::_reverify_absence_claims) so there is a
# single implementation of "does this claim hold against the repo?".
#
# Each _check_* returns TRUE | FALSE | UNVERIFIABLE on stdout.
# Requires DIFFHOUND_REPO (the PR working tree). Pure functions, source-safe.

_gt_symbol_defined() {  # $1 symbol -> "yes"/"no" (defined anywhere in repo?)
  local s="$1" repo="${DIFFHOUND_REPO:?}"
  if grep -rqE "(export[[:space:]]+(const|default|function|class)|const|let|var|function|class|def)[[:space:]]+${s}([[:space:]]|=|\(|:|<)|[\"']${s}[\"'][[:space:]]*:|^[[:space:]]*${s}[[:space:]]*[:(]" \
       "$repo" \
       --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' --include='*.py' --include='*.graphql' \
       --exclude-dir=node_modules 2>/dev/null; then echo yes; else echo no; fi
}

_gt_dependency_declared_range() {  # $1 pkg -> declared range or empty
  local p="$1" repo="${DIFFHOUND_REPO:?}" pj
  while IFS= read -r pj; do
    jq -r --arg p "$p" '((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {}) + (.optionalDependencies // {}))[$p] // empty' "$pj" 2>/dev/null
  done < <(find "$repo" -name package.json -not -path '*/node_modules/*' 2>/dev/null) | head -1
}

_check_symbol_defined() {  # $1 subject  $2 expected(true|false) -> verdict
  local defined; defined=$(_gt_symbol_defined "$1")
  if [ "$2" = "false" ]; then
    [ "$defined" = "no" ] && echo TRUE || echo FALSE
  else
    [ "$defined" = "yes" ] && echo TRUE || echo FALSE
  fi
}

_check_dependency_version() {  # $1 subject  $2 expected ("<4.0.0"|missing|false)
  local pkg="$1" expected="$2" range major exp_major
  range=$(_gt_dependency_declared_range "$pkg")
  if [ "$expected" = "missing" ] || [ "$expected" = "false" ]; then
    [ -z "$range" ] && echo TRUE || echo FALSE; return
  fi
  [ -z "$range" ] && { echo UNVERIFIABLE; return; }
  major=$(printf '%s' "$range" | grep -oE '[0-9]+' | head -1)
  exp_major=$(printf '%s' "$expected" | grep -oE '[0-9]+' | head -1)
  { [ -z "$major" ] || [ -z "$exp_major" ]; } && { echo UNVERIFIABLE; return; }
  case "$expected" in
    \<*) [ "$major" -lt "$exp_major" ] && echo TRUE || echo FALSE ;;
    =*)  [ "$major" = "$exp_major" ] && echo TRUE || echo FALSE ;;  # claim: declared major == N
    *)   echo UNVERIFIABLE ;;
  esac
}

_check_file_contains() {  # $1 subject  $2 location  $3 expected(true|false)
  local f="${DIFFHOUND_REPO:?}/$2" present
  [ -f "$f" ] || { echo UNVERIFIABLE; return; }
  if grep -qF -- "$1" "$f" 2>/dev/null; then present=yes; else present=no; fi
  if [ "$3" = "false" ]; then
    [ "$present" = "no" ] && echo TRUE || echo FALSE
  else
    [ "$present" = "yes" ] && echo TRUE || echo FALSE
  fi
}

_check_call_reachable() { echo UNVERIFIABLE; }  # best-effort placeholder

# Dispatch "type:subject:scopeOrLoc:expected" -> verdict.
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

  # dependency_version (explicit version assertion): "marked@0.7.0" / "in marked@^0.7.0"
  # -> claim the declared major equals the asserted major. If the real range has a
  # different major, the version premise is FALSE (monorepo #7317 marked@0.7.0; real ^1.1.0).
  local verclaim
  verclaim=$(printf '%s' "$what" | grep -oiE '[a-z0-9_-]+@\^?~?[0-9]+\.[0-9]+' | head -1)
  if [ -n "$verclaim" ]; then
    local vp vmaj
    vp=$(printf '%s' "$verclaim" | cut -d@ -f1)
    vmaj=$(printf '%s' "$verclaim" | sed 's/^[^@]*@//' | grep -oE '[0-9]+' | head -1)
    [ -n "$vp" ] && [ -n "$vmaj" ] && claims="${claims:+$claims; }dependency_version:${vp}::=${vmaj}"
  fi

  printf '%s' "$claims"
}
