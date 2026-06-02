#!/usr/bin/env bash
# node-modules-claim-check.sh — DROP findings whose evidence is grounded in a
# node_modules/ path that does NOT exist in the checkout.
#
# WHY: diffhound reviews a shallow `git clone` with NO `npm install`, so
# node_modules is never present. Any finding that claims to have "checked
# node_modules/<pkg>/package.json" (and derives a version / behavior from it)
# is a hallucination — the file it cites does not exist in what was reviewed.
#
# Real incident (v0.7.8, monorepo PR #7317, 3 rounds): the bot claimed
# "checked node_modules/marked/package.json — you're on marked 0.7.0;
# marked.parse() doesn't exist until v4.0.0; this will throw TypeError." The
# pinned version was ^1.1.0 (never 0.7.0) and marked.parse works fine. Posted
# unrefuted because peer review was down. This guard drops that class.
#
# Scope is deliberately narrow (node_modules only, must cite a concrete path
# that is absent on disk) to avoid false drops — per the project rule to build
# guards only for FPs observed on real PRs.
#
# Reads FINDING: blocks on stdin, writes kept blocks to stdout, drops to stderr.
# DIFFHOUND_REPO must point to the PR's working tree.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

block=""

_flush() {
  [ -z "$block" ] && return 0
  # Pull the first concrete node_modules/<...> path cited anywhere in the block.
  local cited rel
  cited=$(printf '%s\n' "$block" | grep -oiE 'node_modules/[A-Za-z0-9_.@/-]+' | head -1 || true)
  if [ -n "$cited" ]; then
    # Normalize to a repo-relative path (defensive: re-anchor at node_modules/).
    rel="node_modules/${cited#*[Nn]ode_modules/}"
    if [ ! -e "$DIFFHOUND_REPO/$rel" ]; then
      printf '%s\n' "$block" >&2
      printf '[node-modules-claim-check: dropped — cites %s, absent in checkout (no npm install); version/behavior claim is unverifiable]\n' "$rel" >&2
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
