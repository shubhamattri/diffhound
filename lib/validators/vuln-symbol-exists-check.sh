#!/usr/bin/env bash
# vuln-symbol-exists-check.sh — DOWNGRADE to OPEN_QUESTION a finding that asserts
# a named code element (resolver / endpoint / query / mutation / handler /
# function) is vulnerable, unscoped, exposed, or missing a protection — WHEN that
# element is not defined anywhere in the repo.
#
# WHY: the model invents a "companion"/"sibling" by analogy and then asserts it
# as a security hole. Real incident (monorepo #7268): it saw a `users` resolver
# and claimed a `usersCount` resolver was unscoped — no such resolver exists
# anywhere. Downgrade (not drop) keeps it visible as a question for the author
# while removing it from the blocking/should-fix tally and the score.
#
# Narrow + safe: only acts when (a) the block uses vuln/active-element wording AND
# (b) the SUBJECT symbol (backticked, adjacent to that wording) is absent
# repo-wide. Findings about symbols that DO exist are untouched.
#
# Reads FINDING: blocks on stdin, writes to stdout, notes to stderr.
# DIFFHOUND_REPO must point to the PR working tree.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

VULN_RE="is (the |a |an )?(companion )?(resolver|endpoint|query|mutation|handler)|companion (resolver|query|endpoint|to)|unscoped|can (be )?quer|queryable|directly via graphql|is exposed|exposed (via|to)|missing (an |a )?(auth|access|scope|client.?scope)"

_defined_anywhere() {
  local s="$1"
  grep -rqE "(export[[:space:]]+(const|default|function|class)|const|let|var|function|class|def)[[:space:]]+${s}([[:space:]]|=|\(|:|<)|[\"']${s}[\"'][[:space:]]*:|^[[:space:]]*${s}[[:space:]]*[:(]" \
    "$DIFFHOUND_REPO" \
    --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.vue' --include='*.py' --include='*.graphql' \
    --exclude-dir=node_modules 2>/dev/null
}

block=""
_flush() {
  [ -z "$block" ] && return 0
  if printf '%s' "$block" | grep -qiE "$VULN_RE"; then
    # Subject = a backticked symbol sitting just before the vuln wording.
    local subj
    subj=$(printf '%s' "$block" \
      | grep -oiE "\`[A-Za-z_][A-Za-z0-9_]+\`[^.\`]{0,45}(${VULN_RE})" \
      | grep -oE "\`[A-Za-z_][A-Za-z0-9_]+\`" | head -1 | tr -d '`')
    if [ -n "$subj" ] && ! _defined_anywhere "$subj"; then
      printf '%s\n' "$(printf '%s' "$block" | sed -E "1 s#:[A-Za-z_-]+[[:space:]]*\$#:OPEN_QUESTION#")"
      printf '[vuln-symbol-exists-check: downgraded to OPEN_QUESTION — asserts `%s` is a vulnerable resolver/endpoint, but it is not defined anywhere in the repo]\n' "$subj" >&2
      block=""
      return 0
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
