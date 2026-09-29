# OSS mechanisms adopted in Diffhound

These are independent implementations of useful patterns. This is not a merge
of seven products, and no AGPL source was copied into Diffhound.

| Reference | Useful mechanism | Diffhound implementation |
| --- | --- | --- |
| [PR-Agent](https://github.com/The-PR-Agent/pr-agent) | Persistent output, incremental review, explicit commands | `lifecycle.sh`, `review_state.py`, ancestry-aware incremental review, `/ask`, `/describe`, `/labels`, `/changelog` |
| [Tag1 AI PR Review](https://github.com/tag1consulting/ai-pr-review) | Sticky summary, batched inline comments, overflow in body | One author-scoped summary; existing batched publisher retained; all overflow enters the ledger |
| [Claude PR Reviewer](https://github.com/indoor47/claude-pr-reviewer) | One review with a verdict and inline comments | Existing COMMENT/APPROVE/REQUEST_CHANGES support retained, including GitHub's own-PR fallback |
| [Claude Code Action](https://github.com/anthropics/claude-code-action) | GitHub event integration and explicit commands | Docker Action inputs, consumer synchronize trigger, permission-checked issue-comment command workflow |
| [Robin](https://github.com/antongulin/robin) | Self-hosting, bounded output | Existing host/token model and comment budgets retained; opened-only cadence excluded because pushes must still trigger review |
| [Kodus](https://github.com/kodustech/kodus-ai) | Finding lifecycle and self-hosted review | GitHub-backed OPEN/RESOLVED state, NEW/ESCALATED/REOPENED transitions, aliases for rewordings; no separate platform or license change |
| [AI Code Reviewer](https://github.com/villesau/ai-codereviewer) | Small Action-based entrypoint | Action and direct Docker arguments now reach the same CLI |

The table's “one AI call” is implemented for each explicit command. A full
Diffhound review intentionally retains verification and multi-model stages;
reducing that entire pipeline to one call would remove existing safeguards.

## Corrections to the previous loop fix

- Removed line-proximity suppression: changing authentication near an old nit
  no longer hides a new blocker.
- Removed edit-proximity and reply-keyword thread resolution (including premature “will do” acknowledgments), plus early cross-round dedup based on
  basenames/truncated text. Publication-time state owns cross-round suppression.
- Pending reviews never count as submitted, including POST-error recovery.
- Sweep, review discovery, and recovery share review identity rules. Sweep's
  legacy-scorecard branch no longer indexes a body string as a review object.
- Failed history reads stop publication; failed thread-state reads retain findings.
- Current summary and state replace stale content on quiet reruns.
- Selected findings and overflow are recorded; interactive deselection is not
  treated as successful publication.
- CLI review locks cover same-host workflow/sweep concurrency; stale-head reviews
  are rejected before publishing. Locks are not distributed across hosts.

## Validation

Run `DIFFHOUND_OFFLINE=1 bash tests/run.sh`. New tests exercise multiple review
rounds, rewording aliases, moved findings, escalation, recurrence, pending-review
recovery, summary identity, overflow, command output validation, draft/apply,
and the real CLI/model-transport path using strict GitHub/curl fakes.

Offline tests cannot establish live GitHub notification counts or model finding
quality. Before rollout, build the Docker image and use a disposable PR to check
initial review, unchanged rerun, fixed finding, new blocker near an old thread,
force push, summary reuse, and one explicit command. No production deployment is
part of these source changes.
