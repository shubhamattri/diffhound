#!/usr/bin/env bash
# run-all.sh — pipe findings through the validator chain in the correct order.
# Each validator reads FINDING: blocks on stdin, writes kept/annotated blocks
# on stdout. Validators drop findings by emitting nothing in place.
#
# Order matters:
#   1. checklist-execute  — Python AST; drops ModuleNotFoundError FPs first
#      before content filters see them.
#   2. security-helper    — narrow wording gate, high-confidence drops.
#   3. concurrency-helper — brace-aware scope check; downgrades race-condition
#      findings to OPEN_QUESTION when flagged code is inside a .transaction()
#      block (or adjacent to FOR UPDATE / advisory lock) AND finding does not
#      cite a concrete multi-process flow. Mirrors security-helper shape.
#   3a. intent-comment-helper — downgrades any finding whose flagged line is
#      immediately preceded (within 5 lines) by an inline comment containing
#      intent markers ("intentional", "by design", "zero-padded", etc.).
#      Same shape as security/concurrency helpers; downgrade-only.
#   4. dry-vs-import      — narrow wording gate.
#   5. ref-exists         — broader wording-conditional drop / annotate pass.
#   6. pre-existing-pattern — drops "new X per request" findings when the
#      pattern already exists >=3 times in the file (pre-dates the PR).
#   7. consumer-check     — downgrades "breaking API change" BLOCKERS when
#      no in-repo consumer of the flagged endpoint/symbol can be found.
#      Runs before citation-discipline so the downgraded severity is what
#      the final gate sees.
#   8. todo-deferral      — severity mutation (BLOCKING→SHOULD-FIX when a
#      TODO(TICKET) documents the deferral).
#   9. citation-discipline — final severity gate. Any BLOCKING/SHOULD-FIX
#      missing DIFF_LINE/REACHABLE_PATH/REJECTED_ALTERNATIVE gets downgraded.
#      Enforces the citation contract against the final severity after all
#      other mutations/drops.
#  10. dedup-helper       — drops current findings whose logical identity_key
#      matches a prior finding (cross-round dedup; line-shift- and severity-
#      mutation-tolerant). No-op when DIFFHOUND_PRIOR_FINDINGS env unset.
#      Runs LAST so any severity mutations / annotations from upstream
#      validators are part of the block_raw that's either kept or dropped.
#
# round-diff isn't in this pipeline — it's invoked separately with access
# to the prior-findings state.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$ROOT/lib/validators"

"$V/checklist-execute.py" \
  | "$V/security-helper.sh" \
  | "$V/concurrency-helper.sh" \
  | "$V/intent-comment-helper.sh" \
  | "$V/dry-vs-import.sh" \
  | "$V/ref-exists.sh" \
  | "$V/pre-existing-pattern.sh" \
  | "$V/consumer-check.sh" \
  | "$V/todo-deferral.sh" \
  | "$V/citation-discipline.sh" \
  | "$V/dedup-helper.py"
