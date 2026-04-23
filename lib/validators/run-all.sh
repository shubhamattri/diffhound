#!/usr/bin/env bash
# run-all.sh — pipe findings through the validator chain in the correct order.
# Each validator reads FINDING: blocks on stdin, writes kept/annotated blocks
# on stdout. Validators drop findings by emitting an empty line in place.
#
# Order matters:
#   1. security-helper (narrow wording check; runs early so a later filter
#      can't hide evidence of the safe primitive)
#   2. dry-vs-import (narrow wording check)
#   3. ref-exists (broader; can drop hallucinations not caught above, and
#      annotates legitimate "missing X" findings — runs last so upstream
#      validators see the unannotated block)
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$ROOT/lib/validators"

"$V/security-helper.sh" \
  | "$V/dry-vs-import.sh" \
  | "$V/ref-exists.sh"
