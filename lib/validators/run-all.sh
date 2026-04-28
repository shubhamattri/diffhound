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
#      Expanded v0.5.7: scans ALL backticked symbols, sibling-dir search,
#      jest skiplist, absence-wording exemption.
#   5a. migration-column-check — drops claims that a column is missing from
#       a named migration when the column literal exists in that file
#       (PR #7145 F1, F2). v0.5.7.
#   5b. no-validation-check — drops "no validation" claims when the named
#       function body has validation tells (PR #7145 F7). Tiered tells
#       guard against state-check false drops. v0.5.7.
#   5c. cross-file-comparison-check — drops "X has fix, Y doesn't" /
#       "Y is missing the guard" findings when the FINDING file has
#       2+ ensure/assert/verify/check/require guard-helper invocations.
#       Driven by PR #7145 v0.5.7-deployed FP at exportHandlers.ts:71
#       ("graphql path has fix, REST doesn't" — REST had the call at 4
#       distinct line numbers in the same file). v0.5.8.
#   5d. auth-gate-precedes-check — drops IDOR / "missing org-scope" /
#       "any account admin can X" findings when the named function is
#       gated by a restrictive ensureAuthorized predicate (isAdmin ||
#       isBatman / userHasGlobalBrDeckAccess) before the body. Driven
#       by 5 repeats of the same delete-mutation FP across PR #7145
#       rounds 19:48-20:55: model claimed userCanAccessBrDeck was the
#       gate when the actual code uses isAdmin || isBatman, blocking
#       account admins entirely. v0.5.9.
#   5e. line-cite-verify-check — drops findings whose backticked
#       identifiers don't appear within ±5 lines of the FINDING's cited
#       file:line. Catches the inverse of v0.6.0's evidence injection:
#       v0.6.0 stops the LLM from claiming "X doesn't exist" against a
#       symbol that does; this validator stops "X exists at line N"
#       claims against a line N that doesn't have X. PR #7145 22:10
#       round had `forUpdate at line 276` (real forUpdate is at 875)
#       and `computeEarnedPremium at line 146` (function doesn't exist
#       at all). Both wrong-line and hallucinated-symbol cases drop.
#       v0.6.1.
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
  | "$V/migration-column-check.sh" \
  | "$V/no-validation-check.sh" \
  | "$V/cross-file-comparison-check.sh" \
  | "$V/auth-gate-precedes-check.sh" \
  | "$V/line-cite-verify-check.sh" \
  | "$V/pre-existing-pattern.sh" \
  | "$V/consumer-check.sh" \
  | "$V/todo-deferral.sh" \
  | "$V/citation-discipline.sh" \
  | "$V/dedup-helper.py"
