# Changelog

## [Unreleased]

## [0.5.6] - 2026-04-28 — Self-describing comment markers for cross-round dedup

Driven by monorepo PR #7145 — 74 inline comments + 8 CHANGES_REQUESTED reviews
in 7.5 hours, with developers reporting that diffhound resurfaced
already-addressed findings on every force-push. Investigation traced the noise
to two compounding bugs and a force-push fan-out that exposed both at scale.

### Root cause

The cross-round dedup pipeline relied on **lossy reverse-engineering** of
prior `FINDING:` blocks from rendered comment markdown at `lib/review.sh:1772`
(jq `split(". ")[0]` produced a ~30-char first-sentence fragment vs the LLM's
full ~200-char `WHAT`), and a **brittle identity tuple**
`(file_basename, primary_symbol, normalized_what[:80])` that drifted whenever
the LLM rephrased — e.g. `DECR` vs `client.decr(redisKey)` produced different
`primary_symbol` values for the same logical issue (`redisRateLimit.ts:248`
on PR #7145, two distinct comments at 14:05 and 16:25).

The dedup-helper's identity computation was correct in isolation; the
upstream reconstruction couldn't feed it a comparable prior-round identity.

### Fixed — self-describing comment markers (`lib/marker-utils.sh` — new)

Each inline comment now carries an appended HTML trailer:

```
<!-- diffhound-id v1: <base64({"f":basename,"s":symbol,"w":what80})> -->
```

The marker preserves the exact identity tuple at post time. On the next
review round, `lib/review.sh` extracts it verbatim and passes it via the new
`DIFFHOUND_PRIOR_KEYS` env var to `dedup-helper.py` — apples-to-apples
comparison, no reverse-engineering, no fidelity loss across LLM rephrasings.

Markers are **appended, never prepended** — prepending would be misclassified
by the anchored-signature `startswith` check at `review.sh:637` and break
the loop-prevention logic. Idempotent: `append_marker` skips bodies that
already carry a marker, so re-runs are safe.

### Fixed — exact-key dedup path (`lib/validators/dedup-helper.py`)

`dedup-helper.py` now reads `DIFFHOUND_PRIOR_KEYS` (TSV: basename TAB symbol
TAB normalized_what80) as the preferred prior-round source. The legacy
`DIFFHOUND_PRIOR_FINDINGS` path is preserved and merged in for backward
compatibility with unmarked comments posted by pre-v0.5.6 versions on the
same PR.

Severity remains **out of the identity key** — the dedup-helper's
severity-tolerance contract (so a BLOCKING→SHOULD-FIX downgrade doesn't
re-post) is preserved.

### Two-tier reconstruction at `review.sh:1772`

- Marked comments → exact tuple via base64 decode (Python helper, since
  base64+JSON in pure bash is error-prone; `dedup-helper.py` already
  requires python3 so no new dependency).
- Unmarked legacy comments → existing lossy regex (unchanged), so PRs
  reviewed under earlier diffhound versions still benefit from
  imperfect-but-better-than-nothing dedup as comments turn over.

### Tests

42/42 fixtures pass (37 prior + 5 new):

- `dedup-helper/prior-keys-symbol-drift` — the PR #7145 case: prior key has
  symbol `DECR`, current finding rephrases as `client.decr(...)` but
  `primary_symbol` regex still picks `DECR` → exact match → drop.
- `dedup-helper/prior-keys-empty-noop` — empty `DIFFHOUND_PRIOR_KEYS` is a
  pass-through (no false drops).
- Marker round-trip + idempotency verified via `lib/marker-utils.sh`
  smoke test (compose → append → extract recovers identity tuple
  unchanged; double-append is a no-op).

### Out of scope (deferred)

- LLM-judge dedup for residual rephrasings where `primary_symbol` itself
  shifts (Haiku one-shot comparing new findings against prior canonical
  blocks). Marker is the precondition; deferred to v0.6.0.
- Smart-skip on `synchronize` events when no dev replies / <50 LOC changed
  / no prior BLOCKING. Deferred to v0.5.7.
- Pin VM checkout to tag instead of `origin/master` HEAD. Deferred —
  process change, not code.

### Peer review

Plan reviewed in parallel by Codex + Gemini. Both flagged the original
draft's SHA256-of-content marker (can't survive LLM rephrasing) and Jaccard
fuzzy-matching (false-drop risk on security findings — Codex counterexample:
same file with `orders`+`userId` symbols, N+1 vs tenant-filter leak; Gemini:
boilerplate nil-check on different vars). Both rejected the 600s hard
cooldown (breaks fix-and-rereview flow). Final scope reflects their
recommendation: literal-tuple marker only, no fuzzing, no cooldown.

[BX-3010]

## [0.5.5] - 2026-04-28 — Knex idempotency recognition + sibling-test omission

Two small prompt-rule additions driven by PR #7145 round-6 findings.

### Changed — prompt rules in `lib/review.sh`

- **Rule 30 (new)** — Knex / migration idempotency recognition. Before flagging
  a migration's `alterTable` / `createTable` as missing `IF NOT EXISTS`, the
  model must check for a JS-level guard (`knex.schema.hasTable`,
  `knex.schema.hasColumn`, `knex.schema.hasIndex`) in the surrounding `up()`
  body. Those checks are the JS spelling of `IF NOT EXISTS` — same idempotency
  contract — and should not be flagged as missing.
  - Catches the round-6 false positive where `alterTable("br_deck_jobs", ...)`
    was flagged despite the surrounding `if (!hasRunId)` guard providing exact
    same partial-failure-rerun safety.

- **Rule 29 (extended)** — Test-file anti-pattern sweep adds a sibling-test
  omission check: when a happy-path test asserts a side-effect, check whether
  the matching failure/error-path test in the same describe block has the
  equivalent assertion. If absent, flag.
  - Catches the round-6 finding where the happy-path test asserted
    `expect(releaseSlot).toHaveBeenCalled()` but the CC-failure test in the
    same describe didn't — even though the slot-release invariant holds on
    both paths.

### Tests
- 40/40 fixtures still pass (no fixture change — these are prompt-rule
  additions, no validator code).
- `bash -n lib/review.sh` clean.

### Why this release
DNA rule (memory: feedback_above_beyond_dna.md) — every PR-review iteration
ships a tool fix in the same session. Round 6 of PR #7145 produced 8 findings;
4 were valid (shipped as fixes on the PR), 1 was a false positive driven by
diffhound not recognising knex JS-level idempotency guards (closed with rule
30), 1 was a sibling-test gap I should have caught when adding the happy-path
assertion in round 5 (closed with rule 29 extension), 2 are NIT/defer.

## [0.5.4] - 2026-04-28 — Intent-aware validators + anti-pattern prompt sweep

Driven by feedback on Gurupriyan's BR deck PR #7145. After 27 + 8 diffhound
findings across 5 review rounds, three classes of recurring failure showed up
that the prompt and validator pipeline were missing. v0.5.4 closes those.

### Added — `lib/validators/intent-comment-helper.sh`
- New stage in the validator pipeline (after concurrency-helper, before
  dry-vs-import). Mirrors security-helper.sh / concurrency-helper.sh shape.
- For ANY finding (no keyword gate at WHAT level), scans the 5 lines above the
  flagged line in the source file for an inline comment containing intent
  markers: `intentional`, `by design`, `deliberately`, `on purpose`,
  `zero-pad(ded)`, `always over/count/return/fall`, `same soft behaviour`.
- If found AND severity is BLOCKING/SHOULD-FIX/NIT, downgrades to
  OPEN_QUESTION and annotates the WHAT line with the matched comment excerpt.
- Catches the PR #7145 case of `Math.round(reduce(...) / months.length)`
  flagged as a "wrong denominator" when the directly-above comment said
  *"Average TAT always over 3 months; no-endorsement months count as 0
  (zero-padded)"* — explicit intent the model ignored.

### Changed — prompt rules in `lib/review.sh`
Four new rules in the CONCRETE VERIFICATION CHECKS list:

- **Rule 26** — Intent-comment recognition. Upstream guard so the model does
  not generate the finding in the first place; the validator above is the
  mechanical catcher when rule 26 still misses.
- **Rule 27** — Already-applied check. Before suggesting "declare X as Y",
  grep the file for the suggested form. If already in place, drop the
  finding. Catches the PR #7145 `Promise<Buffer>` hallucination (the function
  was already typed `Promise<Buffer>` two lines above the flagged location).
- **Rule 28** — Constant-value verification. When citing a numeric bound,
  grep the constant declaration and quote the actual value. Off-by-one is a
  recurring hallucination class — `SANITIZE_MAX_NESTING_DEPTH = 5` does not
  "cap at 6". If the constant cannot be found, describe the bound abstractly.
- **Rule 29** — Test-file anti-pattern sweep. When reviewing `*.spec.ts` /
  `*.test.ts`, explicitly look for: loose comparison assertions where a MAX/
  MIN constant applies (`toBeLessThan(N)` should be `toBe(MAX_X)`); mocks
  declared but never asserted (`jest.fn()` for a side-effect with no
  `expect(mock).toHaveBeenCalled()`); dead mocks (mocked identifiers that the
  source never calls); type-only imports being mocked at runtime. These four
  produce real findings with near-zero hallucination risk.

### Added — fixtures (`tests/fixtures/intent-comment-helper/`)
- `intent-comment-present-downgrades` — mirrors the PR #7145 zero-padded case
  exactly. Finding flagged at line 3 with intent comment at line 2 → DOWNGRADED
  SHOULD-FIX → OPEN_QUESTION with annotation.
- `no-intent-comment-keeps` — a cautionary comment ("Caller is expected to
  handle empty input") is NOT an intent marker → KEPT at original severity.
- `intent-comment-far-away-keeps` — intent text in the file header (lines 1-3)
  but flagged finding is at line 11, outside the 5-line window → KEPT.

### Tests
- 40/40 fixtures pass (up from 37/37): 3 new for `intent-comment-helper`.
- `bash -n lib/review.sh` clean.

### Why this release
PR #7145 exposed that diffhound v0.5.3, while loop-safe, still generated noise
on (a) intentional behaviour the dev had already documented, (b) suggestions
that were already in the code, (c) numeric bounds quoted incorrectly (off by
one), (d) test files with mock setups that no assertion exercised. v0.5.4
addresses each: one new validator (a), three new prompt rules (a/b/c/d). The
DNA is "every PR-review iteration ships a tool fix in the same session"
(memory: feedback_above_beyond_dna.md).

## [0.5.3] - 2026-04-28 — Hotfix: thread-engagement guard

### Bug — spurious bot replies on threads with no dev engagement

**Regression introduced by v0.5.2.** Saw on monorepo PR #7145: one legitimate
dev reply produced **five** bot replies — one real (on the thread the dev
actually engaged with) and **four spurious** (on threads where only the bot's
original review comment existed).

**Root cause.** `_respond_to_dev_replies` is invoked once per `--learn` run
when ANY thread receives a fresh dev reply (gated at line 521 by
`replied > 0`). Once invoked, it iterates EVERY reviewer top-level comment
and processes the corresponding thread.

In v0.5.1 the per-thread check had two layers — the response_cache (dev reply
IDs already answered) AND a `_posted_cache` body-prefix match against the
bot's own original review comments. The body-prefix check was the implicit
filter for "thread has only the root, no dev engagement → skip."

In v0.5.2 I replaced both with a registry + anchored-signature check.
Critically: original review comments **don't carry the anchored signature**
(only replies do — that was a v0.5.2 change too) and **are not in the
registry** (registry tracks REPLIES posted, not root review comments).
So a thread containing only the bot's root review comment slips both checks
and gets responded to.

### Fix

`lib/review.sh:_respond_to_dev_replies` now skips any thread whose
`length <= 1` before reaching the registry / signature checks. A thread with
no replies has nothing to respond to.

```bash
local _thread_length
_thread_length=$(printf '%s' "$thread" | jq 'length' 2>/dev/null || echo 0)
if [ "${_thread_length:-0}" -le 1 ]; then
  continue
fi
```

This is a strict super-set of the implicit filter v0.5.1's body-prefix check
provided, but doesn't depend on the posted_cache being present (which the
v0.5.2 plan was deliberately moving away from anyway).

### Tests
- 37/37 fixture tests still pass (no fixture change needed — this is a flow
  guard, not a validator).
- `bash -n lib/review.sh` clean.

### Why this wasn't caught in v0.5.2 review
The two rounds of Codex + Gemini peer review focused on the loop-back attack
vectors (signature spoofing, identity collapse, in_reply_to_id pointing to
root, race conditions on POST). None of us simulated the "thread without dev
engagement during a learn run triggered by a sibling thread" case. Adding
this scenario to the standard peer-review prompt for any reply-loop fix.

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
