# Architecture

Diffhound is a Bash/Python review pipeline with GitHub-backed finding history.
The CLI, Docker Action, and shared-server workflow converge on the same review
entry point. Explicit PR commands use a separate, smaller pipeline.

## Review lifecycle

1. **Lock and identify.** `bin/diffhound` dispatches reviews to `lib/review.sh`.
   `lib/run_locked.py` serializes reviews by GitHub host, repository, and PR on
   one executor. The lock survives process replacement and is released when its
   holders exit.
2. **Capture repository state.** Fetch PR metadata, including base/head SHAs,
   prior submitted reviews, and thread state. Materialize the head in a separate
   worktree so context extraction can inspect the reviewed code. Set
   `DIFFHOUND_REQUIRE_HEAD=1` to make materialization failure fatal.
3. **Acquire the diff.** `lib/pr-diff.sh` normally uses GitHub's PR diff.
   An explicit patch-size rejection selects a local three-dot diff from the
   captured base/head commits. Missing commits are fetched and shallow ancestry
   is completed. Other API errors remain failures; failed output is removed.
4. **Prepare context.** `lib/rag.sh` retrieves bounded code, callers, types,
   sibling patterns, history, and prior comments. `extract-context.py` prefers
   Tree-sitter extraction and falls back to line windows. Static analysis and
   repository guidance add evidence before generation.
5. **Route and analyze.** The cleaned diff determines the route below. Opus
   receives a prepared prompt through `lib/api.sh`; the primary API request
   does not have repository tools.
6. **Challenge findings.** Validators check repository evidence. Sonnet and
   Gemini run peer passes in parallel, followed by finding verification where
   applicable. Fast mode scopes peer context rather than disabling this stage.
   The final review reports how many peer responses were usable.
7. **Write and validate.** Sonnet rewrites findings using voice examples.
   `lib/voice.sh` and `voice_output.py` require completed generation and valid
   comment/summary sections. One further attempt is allowed after validation
   failure; invalid output never becomes the published review body.
8. **Reconcile and publish.** Finding history, inline/reply limits, body bytes,
   and the current PR head are checked before submission. Overflow findings
   enter the body. A successful review updates the persistent summary.
9. **Archive and clean up.** Save available run artifacts and remove temporary
   worktrees/files. The peer watchdog is cancelled and reaped on normal and
   exit cleanup paths. An optional advisory design check runs after publication
   only when the configured runtime budget allows it.

## Diff routing

Thresholds apply to the cleaned diff, after generated-file and configured
exclusions. Deletion-only hunks remain in the active review path.

| Tier | Size | Strategy |
| --- | --- | --- |
| Small | Up to 30 KiB | Single primary review prompt. |
| Medium | Above 30 KiB, up to 80 KiB | Reduce unchanged context before the primary review. |
| Large | Above 80 KiB, up to 200 KiB | File triage, parallel chunks, and findings merge. |
| Huge | Above 200 KiB | File triage, parallel chunks, and findings merge. |

Chunks receive shared PR context and file-specific evidence. Triage suggestions
to skip a file are demoted to low priority. Model context remains bounded;
Gemini's peer prompt is currently capped at 14 KB. Chunk stop reasons and
coverage checks expose incomplete primary analysis.

Re-reviews use ancestry-checked incremental information where available. The
large-diff route retains full-diff chunks for context and supplies the changed
file list to focus feedback. `--force-full` removes that incremental baseline.

## Publication and history

`review_state.py` stores finding transitions in submitted review bodies.
History v2 records deltas linked to earlier submitted reviews, allowing fresh
workers to reconstruct state without a separate database. Invalid history
stops publication. Thread-status failure retains findings; edits near an old
comment do not establish resolution. Exact matches are deterministic; semantic
deduplication uses a model and keeps findings when uncertain.

`review_body.py` owns the shared UTF-8 byte budget for review and summary
envelopes. `publish.sh` and `lifecycle.sh` handle submission, recovery, overflow,
and the persistent summary. A quiet rerun can refresh an earlier review.
These are publication rules, not a guarantee of a particular notification count.

Locks coordinate processes sharing one lock directory. Independent hosts need
external coordination. Individual model timeouts and watchdogs do not replace
a deadline and process cleanup for the whole executor job.

## Other entry points

| Module | Responsibility |
| --- | --- |
| `commands.py`, `command-model.sh` | `/ask`, `/describe`, `/labels`, and `/changelog`; preview/apply and permission-checked event handling. |
| `design.sh` | Advisory UX checks from UI diffs and supported GitHub-hosted screenshots; separate from the code-review verdict. |
| `bin/diffhound-sweep` | Poll open PRs, consult GitHub review identity and local state, and invoke the normal review entry point. |
| `cost.sh` | Record Anthropic response usage and estimate cost from the local rate table; Gemini is counted separately. |

See the [README](../README.md) for current model defaults, budgets, setup, and
operational limitations; [Sweep](SWEEP.md) covers scheduling and state.
