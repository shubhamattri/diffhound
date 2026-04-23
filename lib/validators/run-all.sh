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

# Pipeline order:
#   1. checklist-execute  — Python AST; drops ModuleNotFoundError FPs first
#      before content filters see them.
#   2. security-helper    — narrow wording gate, high-confidence drops.
#   3. dry-vs-import      — narrow wording gate.
#   4. ref-exists         — broader wording-conditional drop / annotate pass.
#   5. todo-deferral      — severity mutation runs AFTER drops so downstream
#      validators see unmutated severity. round-diff isn't in this pipeline
#      — it's invoked separately with access to the prior-findings state.
"$V/checklist-execute.py" \
  | "$V/security-helper.sh" \
  | "$V/dry-vs-import.sh" \
  | "$V/ref-exists.sh" \
  | "$V/todo-deferral.sh"
