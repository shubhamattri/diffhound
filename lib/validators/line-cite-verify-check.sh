#!/usr/bin/env bash
# line-cite-verify-check.sh — drop a finding only when the repository proves its
# code claim false; re-anchor a finding whose line number is merely off.
#
# Born from PR #7145 fabrications (`computeEarnedPremium`, which exists nowhere;
# "redundant `.forUpdate()` at line 276", whose only occurrence is at 873). Until
# v0.7.49 it dropped any finding with a backticked token more than ±5 lines from
# the cited line, counting path fragments, other files' symbols and proposed fixes
# as "absent": on monorepo #7642 (run 36443530901) that removed 28 of 50 findings.
# Rules and rationale: lib/validators/line_cite_facts.py.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"
exec python3 "$(dirname "${BASH_SOURCE[0]}")/line_cite_facts.py"
