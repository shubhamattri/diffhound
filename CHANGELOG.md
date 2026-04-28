# Changelog

## [Unreleased]

## [0.5.2] - 2026-04-28 — Loop break, concurrency disambiguation, sweep fallback

### Bug 1 — runaway self-reply loop on PR review threads (P0)

monorepo PR #7132 had diffhound post 25 self-replies in one thread, ~30s apart,
after a single human reply. The shared identity `shubhamattri-nova` (used for
both bot and human comments) defeats author-equality checks. Two defensive
layers were broken: the consumer workflow guard relied on `parent_author !=
new_author` (fails on human-rooted threads where `in_reply_to_id` points to the
human root), and the script-level cache only stored *dev* reply IDs the bot
had answered, never the bot's own reply IDs — so each chained bot reply was
re-classified as fresh dev input.

#### Added — script (`lib/review.sh` `_respond_to_dev_replies`)
- **Anchored bot signature** on every reply (`<!-- diffhound-reply v0.5.2 -->`,
  prepended to the body). Anchored at start so GitHub Quote-reply (`> <!--…`)
  cannot be mistaken for bot output.
- **Per-PR registry** at `~/.diffhound/state/{owner}_{repo}/pr-{N}-bot-comments.txt`.
  Authoritative source for "is this comment from us?". Bootstrapped on every
  invocation from current PR comments matching the anchored signature, so a
  fresh VM / lost cache cannot restart the loop.
- **Loop-breaker at function entry**: skip if last comment in thread is a
  registered bot comment, or its body is anchored-signed.
- **Hard turn limit @ 2** counted by registry membership. On exceed: post one
  `<!-- diffhound-escalation v0.5.2 -->` comment per thread, then permanently
  stop responding to that thread.
- **Two-step write**: capture POST response `comment.id` into the registry
  immediately, so the next webhook fire sees the bot's own reply as ours.

#### Added — reusable workflow (`.github/workflows/reply.yml`)
- Anchored-signature short-circuit at step 1: skip if `github.event.comment.body`
  starts with `<!-- diffhound-`. Defends against the `in_reply_to_id`-points-to-
  root attack on human-rooted threads.
- PR-level concurrency lock (`diffhound-reply-${repo}-${pr}`,
  `cancel-in-progress: false`) so two webhooks ms apart do not both POST.

### Bug 3 — model conflates txn-scoped ops with concurrent lock-hold

Smoking gun: prompt rule 11 said *"Two separate DB calls updating related
fields with no transaction = SHOULD-FIX. In financial operations: BLOCKING."*
That trained the model to pattern-match on absence of `db.transaction()` syntax
without simulating runtime — so it issued race findings inside `transaction()`
blocks and prescribed `db.transaction()` for worker-stealing patterns where the
real fix is `FOR UPDATE SKIP LOCKED` or an advisory lock. Real evidence: PR
#7054 jobProcessingService.ts had two near-duplicate findings (ids 3136480730,
3139131016) that both correctly noted *"`forUpdate()` inside the transaction
makes concurrent deletion essentially impossible"* yet still posted with fuzzy
txn-vs-lock language.

#### Added — validator (`lib/validators/concurrency-helper.sh`)
- New stage in the validator pipeline (between security-helper and
  dry-vs-import). Mirrors security-helper.sh shape: scoped, evidence-required,
  downgrade-only.
- **Brace-aware scope check**, not flat ±50 line window. Walks back from the
  flagged line for the most recent `\.transaction\(`, then forward-counts net
  `{` vs `}` to verify the flagged line is structurally inside the callback.
  A `transaction()` 60 lines away in a different function will not falsely
  downgrade a real race.
- Trigger keywords: `race condition`, `concurrent {modification|access|write|read|deletion|update}`, `deadlock`, `mutex`, `atomic {update|operation}`.
- Downgrade to `OPEN_QUESTION` only when (a) flagged code is inside a
  `transaction()` block OR adjacent to a safe primitive (`FOR UPDATE`,
  `SKIP LOCKED`, `pg_advisory_lock`, `redlock`, `setnx`, `forUpdate()`), AND
  (b) the finding does not cite a concrete multi-process / multi-worker /
  cross-request flow.
- Downgrade preserves the finding (does not drop) so a human reviewer can
  verify, mirroring v0.5.0 citation-discipline behaviour.

#### Changed — prompt rules (`lib/review.sh`)
- **Rule 11 Race conditions** rewritten as runtime-simulation requirement:
  must cite (a) concrete concurrent flow, (b) contended rows/state,
  (c) which existing primitive is insufficient. Not-a-race cases (sequential
  awaits in single Node handler; awaits inside `transaction()` on
  `FOR UPDATE`-locked rows) explicitly enumerated. Worker-grab patterns
  require `FOR UPDATE SKIP LOCKED` / advisory lock (not just `transaction()`).
- **Rule 5 N+1 queries** rewritten — was syntax-prescriptive on
  `withGraphFetched`/DataLoader; now requires evidence (loop, parent query,
  iteration cap) and accepts JOIN/whereIn/DataLoader/custom-batcher equally.
- **Rule 12 Resilience** rewritten — `axios.create({ timeout })`, interceptors,
  and typed wrappers now count as valid timeout configuration. Flag only when
  no layer can be verified to set a timeout.
- **Rule 14 Timezone** rewritten — recognises `current_timestamp`, `sysdate`,
  `getdate()`, JS `new Date()`, dayjs/luxon equivalents, not just
  `CURRENT_DATE`/`NOW()`.

#### Added — fixtures (`tests/fixtures/concurrency-helper/`)
- `inside-transaction-flagged-as-race` → DOWNGRADED to OPEN_QUESTION
- `outside-transaction-real-race` → KEPT
- `worker-job-grab-no-skip-locked` → KEPT BLOCKING (multi-worker flow cited)
- `nearby-transaction-different-scope` → KEPT (brace-aware scope check)

### Bug 2 — cross-round dedup

The dedup at `lib/review.sh:4372` is `(file, line ± 5, dev-touched)` — too
narrow when the LLM rephrases a finding or the underlying line shifts beyond
five lines. Result: the same logical issue is re-posted across rounds even
after the dev addressed it.

#### Added — validator (`lib/validators/dedup-helper.py`)
- New stage at the **end** of the validator pipeline (after
  `citation-discipline`), so any severity mutations or annotations from
  upstream validators are part of the kept-or-dropped block.
- Drops a current-round finding whose `identity_key = (file_basename,
  primary_symbol, normalized_what[:80])` matches a prior-round finding.
- `file_basename` (no full path, no line number) is line-shift- and rename-
  tolerant. `primary_symbol` (first backtick-quoted identifier in WHAT) is
  the protection against the false-drop Gemini specifically flagged: two
  distinct findings on different vars (`userId` vs `accountId`) in the same
  function have different `primary_symbol` and therefore different
  `identity_key`, so both survive. `normalized_what[:80]` (lowercase,
  whitespace-collapsed, validator annotations stripped) is severity- and
  trailing-rephrase-tolerant.
- Opt-out: `DIFFHOUND_DEDUP_DISABLE=1`.
- No-op when `DIFFHOUND_PRIOR_FINDINGS` is unset, missing, or empty (first
  reviews pass through verbatim).

#### Changed — env propagation (`lib/review.sh`)
- The format-adapter call site now passes
  `DIFFHOUND_PRIOR_FINDINGS=${PRIOR_FINDINGS_FILE}` so the new dedup-helper
  in `run-all.sh` actually receives the prior baseline that lib/review.sh
  reconstructs at line 1772 from existing inline PR comments.

#### Added — fixtures (`tests/fixtures/dedup-helper/`)
- `prior-match-drops` — line-shift case (line 5 → line 8, same WHAT) DROPPED.
- `prior-different-symbol-keeps` — same wording template, different
  `primary_symbol` (`process` vs `validate`) — KEPT (false-drop protection).
- `no-prior-noop` — first-review case, no `DIFFHOUND_PRIOR_FINDINGS` env →
  pass-through verbatim.

#### Why a new validator and not extending round-diff.py
`round-diff.py` continues to compute the `CHANGES_SINCE_LAST_REVIEW` trailer
("+N new, -M resolved, =K unchanged") with its existing keep-and-count
semantics. Existing round-diff fixtures encode that contract; a separate
dedup-helper lets the **drop** behaviour live independently and be opt-ed out
cleanly without touching the trailer.

### Added — sweep fallback (carried forward from prior unreleased)
- **`bin/diffhound-sweep`** — poller that runs outside GitHub Actions and
  reviews unreviewed open PRs by calling the GitHub REST API directly.
  Single-instance via atomic `mkdir` lock. Per-`(repo, pr, sha)` state
  prevents duplicate reviews; 3-strike cap prevents infinite crash loops
  on a commit that deterministically breaks the binary; state key includes
  SHA so a new push automatically retries.
- **`docs/SWEEP.md`** — install doc with systemd timer and cron variants,
  env knobs (`DIFFHOUND_SWEEP_MAX_ATTEMPTS`, `DIFFHOUND_SWEEP_GRACE_MIN`,
  `DIFFHOUND_SWEEP_PR_LIMIT`), state layout, observability, troubleshooting.

### Tests
- 37/37 fixture tests pass (up from 30/30): 4 new for `concurrency-helper`,
  3 new for `dedup-helper`.
- `bash -n lib/review.sh` clean.

### Peer review
- Bug 1 fix design went through two rounds of Codex + Gemini peer review
  (2026-04-28). v1 was killed for "identity collapse" (author-equality on
  shared `shubhamattri-nova` account); v2 was killed for substring-spoofable
  signature and `in_reply_to_id`-points-to-root edge case. v3 (shipped here)
  uses anchored signature + per-comment-id registry as authority + PR-level
  concurrency lock + brace-aware scope check.

### Context (sweep fallback original notes)
- Monorepo (Apr 23-24 2026) stopped receiving `github-actions` check-suites
  for pushes despite webhooks still reaching Netlify / Cloudflare / Sonar.
  Runners were online and idle. Toggle-off/on of Actions did not clear
  the throttle. No remediation surface accessible without GitHub Support.
  The sweep provides an orthogonal review path that does not depend on
  Actions event delivery.
- Also covers runner crashes mid-review and binary `exit 1` failures
  (3-strike cap → silent thereafter until next push).

## [0.5.1] - 2026-04-23 — Consumer-check for "breaking API change" findings

### Added
- **`lib/validators/consumer-check.sh`** — downgrades BLOCKING/SHOULD-FIX
  findings that claim an API shape/contract change is "breaking" when no
  in-repo consumer of the named endpoint/symbol can be found. Downgrades
  to `OPEN_QUESTION` (per v0.5.0 severity model) and annotates with
  "no in-repo consumer found; confirm external consumers before blocking".
  Conservative match: trigger phrase + extractable target + zero grep hits
  outside the flagged file. Non-matches pass through unchanged.
- **Prompt rule** in `lib/prompt-chunked.txt` FINDING RULES: before flagging
  a response-shape change as BLOCKING for broken consumers, grep the repo.
  Zero callers → file as OPEN_QUESTION, not BLOCKING.

### Context
- Claro PR #127 (Apr 23 2026, v0.4.2) re-raised "list_conversations
  envelope shape is breaking" across 6 review passes. The flagged endpoint
  had zero in-repo consumers. Each pass had to be pushed back manually with
  the same grep evidence. v0.5.0 already introduced OPEN_QUESTION as the
  right home for this class of concern; v0.5.1 wires the validator so the
  downgrade happens mechanically instead of via author pushback.

### Tests
- 30/30 fixture tests pass (up from 27/27).
- 3 new fixtures for `consumer-check`: `downgrades-breaking-no-consumer`,
  `keeps-breaking-with-consumer`, `passes-through-without-trigger`.

## [0.5.0] - 2026-04-23 — Citation discipline

### Added
- **Layer 1 — Prompt hardening** (`lib/prompt-chunked.txt`)
  - Hard constraints #7-#10: citation discipline (DIFF_LINE / REACHABLE_PATH / REJECTED_ALTERNATIVE required for BLOCKING and SHOULD-FIX), docstring engagement before flagging documented-intentional behavior, pre-existing pattern check, comparison-claim verification.
  - New FINDING output fields: `DIFF_LINE`, `REACHABLE_PATH`, `REJECTED_ALTERNATIVE`.
  - New severity: `OPEN_QUESTION` for coordination/process concerns (does not count against scorecard).
  - DRIFT PREVENTION block in RE-REVIEW RULES: unchanged files cannot silently change severity across passes.
- **Layer 2 — New validators** (`lib/validators/`)
  - `citation-discipline.sh` — auto-downgrades BLOCKING/SHOULD-FIX findings missing any of the three citation fields. Ladder: BLOCKING -> SHOULD-FIX -> NIT. OPEN_QUESTION and NIT pass through.
  - `pre-existing-pattern.sh` — drops "new X per request" findings when the flagged pattern already exists >=3 times in the file (tech debt, not introduced by the PR).
  - `ref-exists.sh` wording list extended: now catches `bypasses`, `inconsistent with`, `deviates from`, `differs from`, `breaks the X pattern`, `should follow the pattern`, `unlike the existing` — all hallucinated-comparison tells.
- **Layer 3 — Scorecard enforcement** (`lib/review.sh`)
  - Merger prompt teaches citation discipline and OPEN_QUESTION handling.
  - JSON schema includes `diff_line` / `reachable_path` / `rejected_alternative` fields.
  - Review body renders an "Open Questions" section separate from Blockers/Should-Fix/Nits.
  - Verdict logic: OPEN_QUESTION alone never triggers REQUEST_CHANGES.
  - Severity capture regex recognizes OPEN_QUESTION in existing inline comments (re-review path).

### Context
- 10 failure patterns logged in `docs/diffhound-feedback-pr127.md` (claro repo) during the PR #127 review cycle. Top drivers of noise: scope discipline (flagging pre-existing code as BLOCKERS), unverified "inconsistent with X" claims, and BLOCKERS without rejected-alternative reasoning.
- Prior scorecard produced 25% severity swings on unchanged code across two passes. v0.5.0 removes the root cause by making citations a hard contract with mechanical enforcement.

### Tests
- 27/27 fixture tests pass.
- 7 new fixtures: 5 for `citation-discipline`, 2 for `pre-existing-pattern`, 1 for the extended `ref-exists` wording list. 3 pre-existing `format-adapter` fixtures updated to reflect the new citation-discipline gate.

## [0.1.0] - 2026-03-03

### Added
- Multi-model review pipeline (Claude + Codex + Gemini)
- Agentic Pass 1 — Claude reads codebase, not just diff
- Peer review Pass 2 — Codex + Gemini cross-check (parallel)
- Voice rewrite Pass 3+4 — Haiku rewrites in reviewer's voice
- 25 engineering principles for comprehensive code review
- Re-review mode with incremental diff (only new changes)
- Thread tracking (resolved / still open / author wrong)
- Line-snapping for GitHub API compatibility
- Voice RAG with auto-indexing from posted comments
- Lint-nit suppression (trailing newlines, blank lines banned)
- `--fast` mode (skip peer review)
- `--auto-post` mode (no confirmation prompt)
- Cross-platform support (macOS + Linux)
- Configurable via env vars (`REVIEW_REPO_PATH`, `REVIEW_LOGIN`)
- Modular architecture (`lib/` directory)
- One-command installer (`install.sh`)
