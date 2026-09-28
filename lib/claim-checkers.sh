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

# Declared in the repo: a const/let/var/function/class/interface/type/enum/def
# declaration, a method with a body, or a quoted object key. NOT a call site
# (`beforeEach(...)`) or an option key (`searchPath: [...]`): those are uses of
# library/global symbols, and #7642 run 36450368674 dropped true findings by
# reading them as "defined in the repo".
_gt_symbol_declared() {  # $1 symbol -> yes/no
  local s="$1" repo="${DIFFHOUND_REPO:?}"
  if grep -rqE "(export[[:space:]]+(const|default|function|class|interface|type|enum|async[[:space:]]+function)|const|let|var|function|class|interface|type|enum|def)[[:space:]]+${s}([[:space:]]|=|\(|:|<|$)|[\"']${s}[\"'][[:space:]]*:|^[[:space:]]*(async[[:space:]]+)?(static[[:space:]]+)?${s}[[:space:]]*\([^)]*\)[[:space:]]*(:[^={]*)?\{" \
       "$repo" \
       --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' --include='*.py' --include='*.graphql' \
       --exclude-dir=node_modules 2>/dev/null; then echo yes; else echo no; fi
}

# The symbol appears as a whole word on a non-comment line of the given files.
_gt_symbol_in_files() {  # $1 symbol, $2.. repo-relative paths -> yes/no
  local s="$1" repo="${DIFFHOUND_REPO:?}" f; shift
  for f in "$@"; do
    [ -f "$repo/$f" ] || continue
    if grep -qwF -- "$s" <<< "$(grep -v -E '^[[:space:]]*(#|//|\*)' "$repo/$f")"; then echo yes; return; fi
  done
  echo no
}

# $1 subject  $2 expected(true|false)  $3 scope: repo | file=<a,b,...>
#   expected=true  ("X is an unscoped resolver"): X must exist at all: declared,
#                  or used/named anywhere in the repo's code (a table name counts).
#   expected=false ("X doesn't exist"): refuted only by a DECLARATION when the
#                  claim is repo-wide, or by any use in the files it is about.
_check_symbol_defined() {
  local subj="$1" exp="${2:-true}" scope="${3:-repo}"
  if [ "$exp" = "false" ]; then
    local found
    case "$scope" in
      file=*) local IFS=','; # shellcheck disable=SC2086
              found=$(_gt_symbol_in_files "$subj" ${scope#file=}) ;;
      *)      found=$(_gt_symbol_declared "$subj") ;;
    esac
    [ "$found" = "no" ] && echo TRUE || echo FALSE
  else
    if [ "$(_gt_symbol_defined "$subj")" = "yes" ]; then echo TRUE; return; fi
    if grep -rqwF -- "$subj" "${DIFFHOUND_REPO:?}" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
         --include='*.vue' --include='*.py' --include='*.graphql' --exclude-dir=node_modules 2>/dev/null; then
      echo TRUE
    else
      echo FALSE
    fi
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

# Whether a third-party dependency exposes a method/API at the installed version.
# This is ALWAYS UNVERIFIABLE here: a shallow clone has no node_modules, so the
# dep's real API can't be inspected. (An earlier version grepped for `.method(`
# in committed code as "evidence it exists" — that was UNSOUND: `.parse(` matches
# the very call being flagged, so a genuine "calls a method this version lacks"
# bug self-cancels, and it also matches JSON.parse / path.parse / etc. That
# heuristic suppressed REAL dep-API mismatches.) The correct, sound behavior:
# a pure method-existence claim about a third-party dep is UNVERIFIABLE, and the
# reconcile policy turns it into an OPEN_QUESTION (never a blocker). When the
# version IS the real basis (e.g. "marked < 1.0.0 lacks .parse"), the model
# should ground it as a `dependency_version` claim instead — which IS verifiable
# against package.json. Args: $1 subject(pkg) $2 method (both ignored).
_check_method_exists() { echo UNVERIFIABLE; }

# Data-flow usage: is `subject` actually present within `scope`'s call/region?
# Falsifies "X is never passed to / used by Y" claims: if X clearly DOES appear in
# scope's args/region, the absence claim is FALSE -> the finding drops (this is the
# #7291 clientNames FP: "clientNames dropped before getEffectiveClientIds" when it is
# in fact passed in). CONSERVATIVE + DIRECTIONAL by design:
#   - expected=false ("not used"): only return FALSE when we POSITIVELY find subject
#     near scope; if not found -> UNVERIFIABLE (NEVER confirm an absence — a window/
#     naming miss must not manufacture a "real" finding).
#   - scope not locatable -> UNVERIFIABLE (don't judge).
# SAFETY (learned from the #7291 auth-bypass case, where a REAL missing-guard finding
# had a drifted citation): this checker is ONLY for plain "value X flows into Y"
# assertions. It must NEVER be used to verify "a security guard is missing" — those
# can be real with a wrong line cite and must never be auto-suppressed.
# Args: $1 subject  $2 scope(function/call token)  $3 expected(true|false)
_check_usage() {
  local subject="$1" scope="$2" expected="${3:-false}" repo="${DIFFHOUND_REPO:?}"
  { [ -z "$subject" ] || [ -z "$scope" ]; } && { echo UNVERIFIABLE; return; }
  local hits present=no file ln s e
  hits=$(grep -rnF -- "$scope" "$repo" \
      --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' \
      --exclude-dir=node_modules 2>/dev/null | head -40)
  [ -z "$hits" ] && { echo UNVERIFIABLE; return; }
  while IFS=: read -r file ln _; do
    { [ -z "$file" ] || [ -z "$ln" ]; } && continue
    s=$((ln>3?ln-3:1)); e=$((ln+8))
    if grep -qF -- "$subject" <<< "$(sed -n "${s},${e}p" "$file" 2>/dev/null)"; then present=yes; break; fi
  done <<< "$hits"
  if [ "$expected" = "false" ]; then
    [ "$present" = "yes" ] && echo FALSE || echo UNVERIFIABLE
  else
    [ "$present" = "yes" ] && echo TRUE || echo UNVERIFIABLE
  fi
}

# Dispatch "type:subject:scopeOrLoc:expected" -> verdict.
_verify_claim() {
  local c="$1" type subject loc expected
  type=$(printf '%s' "$c" | cut -d: -f1)
  subject=$(printf '%s' "$c" | cut -d: -f2)
  loc=$(printf '%s' "$c" | cut -d: -f3)
  expected=$(printf '%s' "$c" | cut -d: -f4-)
  case "$type" in
    symbol_defined)     _check_symbol_defined "$subject" "${expected:-true}" "${loc:-repo}" ;;
    dependency_version) _check_dependency_version "$subject" "${expected:-missing}" ;;
    file_contains)      _check_file_contains "$subject" "$loc" "${expected:-true}" ;;
    method_exists)      _check_method_exists "$subject" "$loc" ;;
    usage)              _check_usage "$subject" "$loc" "${expected:-false}" ;;
    call_reachable)     _check_call_reachable ;;
    *)                  echo UNVERIFIABLE ;;
  esac
}
# ── implicit claim extraction (no explicit CLAIMS: line) ─────────────────────
# Returns "; "-separated claims derived from the block's prose, or empty.
_extract_implicit_claims() {
  # $2 (optional): the cited file. An absence claim that is not stated repo-wide
  # ("anywhere", "in the repo/codebase") is about that file and the files the
  # finding names, not about the whole repository.
  local block="$1" cited="${2:-}" what claims=""
  what=$(printf '%s' "$block")

  local absence_re="does(n'?t| not) exist|do(n'?t| not) exist|not defined|don'?t exist anywhere|doesn'?t exist anywhere|missing entirely|not found anywhere|exist anywhere in the codebase"
  local vuln_re="is (the |a |an )?(companion )?(resolver|endpoint|query|mutation|handler)|companion (resolver|query|endpoint|to)|unscoped|can (be )?quer|queryable|directly via graphql|is exposed"
  local dep_absence_re="not in (any )?package\.json|missing from package\.json|not (a )?dependenc|aren'?t in (any )?package\.json|are not in (any )?package\.json|missing entirely|neither .* nor .* (appear|exist)"
  local nm_re="node_modules/[A-Za-z0-9_.@/-]+"
  local sym

  # symbol_defined (absence): "X doesn't exist" -> claim X absent
  if grep -qiE "$absence_re" <<< "$what"; then
    local scope="repo"
    if [ -n "$cited" ] && ! grep -qiE "anywhere|in the (repo|repository|codebase|project|monorepo)|nowhere|the only exports" <<< "$what"; then
      local named
      named=$(grep -oE '[A-Za-z0-9_@./-]+\.(tsx?|jsx?|vue|py|cjs|mjs)\b' <<< "$what" | grep '/' | sort -u | tr '\n' ',')
      scope="file=${cited}${named:+,${named%,}}"
    fi
    while IFS= read -r sym; do
      [ -n "$sym" ] && claims="${claims:+$claims; }symbol_defined:${sym}:${scope}:false"
    done < <(printf '%s' "$what" | grep -iE "$absence_re" | grep -oE '`@?[A-Za-z_][A-Za-z0-9_]{2,}`|[A-Z][A-Z0-9_]{3,}' | tr -d '`' | sort -u)
  fi

  # symbol_defined (phantom vuln): "`X` is unscoped/resolver" -> claim X exists
  if grep -qiE "$vuln_re" <<< "$what"; then
    sym=$(printf '%s' "$what" | grep -oiE "\`[A-Za-z_][A-Za-z0-9_]+\`[^.\`]{0,45}(${vuln_re})" | grep -oE "\`[A-Za-z_][A-Za-z0-9_]+\`" | head -1 | tr -d '`')
    [ -n "$sym" ] && claims="${claims:+$claims; }symbol_defined:${sym}:repo:true"
  fi

  # dependency_version: node_modules citation or "not in package.json"
  if grep -qoiE "$nm_re" <<< "$what"; then
    local cited; cited=$(printf '%s' "$what" | grep -oiE "$nm_re" | head -1)
    local pkg; pkg=$(printf '%s' "$cited" | sed -E 's#.*node_modules/(@[^/]+/[^/]+|[^/]+).*#\1#')
    [ -n "$pkg" ] && claims="${claims:+$claims; }dependency_version:${pkg}:nm:missing"
  fi
  if grep -qiE "$dep_absence_re" <<< "$what"; then
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

# ── declaration / import facts (v0.7.40) ─────────────────────────────────────
# "X is declared twice" / "X is used without an import" are facts about ONE file,
# checkable at the PR head. monorepo #7642 posted a dozen of them about code that
# compiled and passed CI (requireEnabled, PORTAL_INTAKE_KIND, params `ss`/`ctx__`
# that exist in no commit). Prints NOCLAIM | TRUE | FALSE | UNVERIFIABLE.
# Args: $1 path relative to DIFFHOUND_REPO   $2 claim text
_CLAIM_CHECKERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_check_decl_text() {
  local rel="$1" text="$2" repo="${DIFFHOUND_REPO:-}"
  { [ -z "$repo" ] || [ -z "$rel" ]; } && { echo NOCLAIM; return; }
  command -v python3 >/dev/null 2>&1 || { echo UNVERIFIABLE; return; }
  printf '%s' "$text" | python3 "${_CLAIM_CHECKERS_DIR}/decl_facts.py" "$repo" "$rel" 2>/dev/null || echo UNVERIFIABLE
}

# "X.y is unguarded / may be undefined / can throw" at file:line. FALSE when an
# early exit on the same identifier dominates the line (lib/guard_facts.py).
# Prints NOCLAIM | TRUE | FALSE | UNVERIFIABLE.  Args: $1 rel path  $2 line  $3 text
_check_guard_text() {
  local rel="$1" ln="$2" text="$3" repo="${DIFFHOUND_REPO:-}"
  { [ -z "$repo" ] || [ -z "$rel" ] || [ -z "$ln" ]; } && { echo NOCLAIM; return; }
  command -v python3 >/dev/null 2>&1 || { echo UNVERIFIABLE; return; }
  printf '%s' "$text" | python3 -B "${_CLAIM_CHECKERS_DIR}/guard_facts.py" "$repo" "$rel" "$ln" 2>/dev/null || echo UNVERIFIABLE
}
