#!/usr/bin/env bash
# dependency-exists-check.sh — DROP findings claiming a package is "missing from
# package.json / not a dependency / not installed" when that package IS actually
# declared in some package.json in the repo.
#
# WHY: with peer review down, the model hallucinates dependency-absence in
# different shapes. After v0.7.9 killed the "marked@0.7.0" version variant, the
# claim morphed (monorepo #7317, round 4) to "marked and dompurify are not in
# any package.json — build fails." Both are in services/portal/package.json
# (marked ^1.1.0, dompurify ^3.4.0) — a false positive that hard-blocks merge.
# This grounds the absence claim against the committed package.json files.
#
# Narrow by design: only acts when (a) the block uses an absence phrase AND
# (b) a backticked package named in the block is genuinely present in a
# package.json. Genuinely-missing deps are kept (real findings).
#
# Reads FINDING: blocks on stdin, writes kept blocks to stdout, drops to stderr.
# DIFFHOUND_REPO must point to the PR's working tree.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Build the set of declared dependency names across every package.json.
_DEPS_FILE=$(mktemp -t diffhound-deps.XXXXXX)
trap 'rm -f "$_DEPS_FILE"' EXIT
if command -v jq >/dev/null 2>&1; then
  while IFS= read -r _pj; do
    jq -r '((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {}) + (.optionalDependencies // {})) | keys[]' "$_pj" 2>/dev/null
  done < <(find "$DIFFHOUND_REPO" -name package.json -not -path '*/node_modules/*' 2>/dev/null) | sort -u > "$_DEPS_FILE"
fi

# Absence-claim phrasing. Tight on purpose — must assert the dep is ABSENT.
ABSENCE_RE='not in (any )?package\.json|missing from package\.json|not (a |an )?(declared |listed )?(depend|dev ?depend)|isn'\''t (a |an )?(depend|listed)|not (a )?dependenc|not installed|not present in package\.json|aren'\''t in (any )?package\.json|are not in (any )?package\.json|no longer in package\.json|missing entirely|neither .* nor .* (appear|exist|are)|do(es)? ?n'\''?t appear in|not appear in (any )?(`?package\.json)|they'\''?re missing|they are missing'

block=""

_flush() {
  [ -z "$block" ] && return 0
  # Only consider blocks that actually assert absence.
  if printf '%s' "$block" | grep -qiE "$ABSENCE_RE"; then
    # Backticked identifiers that look like npm package names (incl. @scope/name).
    local tok present=""
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      if grep -qxF "$tok" "$_DEPS_FILE" 2>/dev/null; then present="$tok"; break; fi
    done < <(printf '%s\n' "$block" | grep -oE '`@?[a-z0-9][a-z0-9._/-]+`' | tr -d '`' | sort -u)
    if [ -n "$present" ]; then
      printf '%s\n' "$block" >&2
      printf '[dependency-exists-check: dropped — claims a dep is missing, but `%s` IS declared in a package.json]\n' "$present" >&2
      block=""
      return 0
    fi
  fi
  printf '%s\n' "$block"
  block=""
}

while IFS= read -r line || [ -n "$line" ]; do
  if [ "${line#FINDING:}" != "$line" ]; then
    _flush
  fi
  block="${block:+$block$'\n'}$line"
done
_flush
