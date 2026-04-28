# Diffhound Comment Storm — Fix Plan (v0.5.6 clean reissue)

**Date:** 2026-04-28
**Driver:** Developer complaints. PR #7145 (monorepo, 18.8K LOC) accumulated 74 inline comments + 8 CHANGES_REQUESTED reviews in 7.5 hours. Mix of new findings + already-addressed ones across rebases.

## Verified evidence (Phase 1+2 — already confirmed)

1. **Trigger fan-out is force-push driven, not a loop.** Workflow run history shows 5+ distinct SHAs in `pull_request` events. v0.5.3 thread-engagement-guard is correctly preventing the bot-reply-to-self loop. `pull_request_review_comment` runs all `skipped`/`cancelled` per workflow `if:` filter.

2. **Cross-round dedup (`dedup-helper.py`) is failing in practice.** Concrete case on PR #7145:
   - 14:05 line 248: `` `DECR` on a key that doesn't exist creates it at `-1`... ``
   - 16:25 line 248: `` `client.decr(redisKey)` has no floor check... ``
   - Same logical issue. Different `primary_symbol` (`DECR` vs `client`), different first 80 chars of WHAT, identity_keys diverge, dedup misses, finding re-posted.
   - 15:42 line 266: same orphan-key concern at *different anchor line* — file_basename matches but symbol drifts too.

3. **Prior-findings reconstruction (`review.sh:1772`) is lossy.** It reverse-engineers `FINDING:` blocks from rendered inline-comment markdown via jq regex (`split(". ")[0]` for WHAT). Reconstructed WHAT is a ~30-char first-sentence-fragment; current-round LLM WHAT is full ~200 chars. `normalized_what[:80]` cannot match.

4. **No PR-level cooldown / batching.** Each force-push runs an independent fast review. Concurrency cancels in-progress, but reviews 30+ min apart all complete.

5. **VM uses HEAD of master, not pinned tag.** `git checkout origin/master -f` in workflow → reverts of v0.5.6/v0.5.7 land instantly.

## Root cause (single sentence)

The dedup pipeline relies on lossy reverse-engineering of WHAT from rendered markdown and a brittle (file_basename, first-backtick-symbol, 80-char-prefix) identity tuple, both of which fail under normal LLM rephrasing across review rounds — so re-reviews triggered by routine force-pushes resurface logically-resolved findings as new comments.

## Fixes (v0.5.6 clean — ordered by impact)

### Fix 1: Embedded identity marker in posted comments (P0, primary)
- **What:** When `lib/post-review.sh` (or wherever the comment body is rendered) emits an inline comment, append an HTML comment trailer:
  `<!-- diffhound-id: sha256(file_basename|primary_symbol_normalized|severity|first_512_chars_what)[:16] -->`
- **Why:** Eliminates reverse-engineering. Prior round's identity is read verbatim from prior comments via regex, no markdown parsing.
- **Reconstruction at `review.sh:1772` becomes:** for each existing reviewer comment, extract the `<!-- diffhound-id: ... -->` trailer; collect into `prior_ids` set. Pass to `dedup-helper.py` via `DIFFHOUND_PRIOR_IDS` (new env, alongside existing `DIFFHOUND_PRIOR_FINDINGS`).
- **dedup-helper.py change:** Compute the same hash over current FINDING block. Drop if hash in `prior_ids`. The lossy 80-char-prefix path stays as fallback for backward-compat (older comments without markers).
- **Backward compat:** Markers only appear on v0.5.6+ posts. Mixed-PR case: old comments fall through to fallback dedup; new ones use exact match.

### Fix 2: Symbol-set instead of symbol-singleton in fallback identity (P1)
- **What:** Change `primary_symbol` from "first backtick-quoted ID" to "sorted set of ALL backtick-quoted IDs in WHAT, top-3".
- **Why:** Fixes the `DECR`-vs-`client.decr(redisKey)`-vs-`decrement` drift. As long as any 1 of top-3 symbols overlaps, the identity treats them as the same finding family.
- **Match rule:** identity matches if file_basename equal AND symbol-sets have ≥1 common element AND normalized_what Jaccard similarity ≥ 0.6 over word-shingles (use simple set intersection, no library).
- **No-false-drop guard:** require ALL of file_basename match + symbol overlap + Jaccard ≥ 0.6. False-drop risk is low; false-match is the bug we're fixing.

### Fix 3: PR-level cooldown for synchronize re-reviews (P1)
- **What:** At start of `lib/review.sh`, if `EVENT_NAME=pull_request` and `EVENT_ACTION=synchronize` and prior diffhound review is < `DIFFHOUND_REVIEW_COOLDOWN_SEC` (default 600s) old, skip with summary "no review — last review N min ago, push again or `/diffhound review` to force".
- **Override:** comment `/diffhound review` on PR forces full review (read in `_check_force_review` step before the cooldown check).
- **Why:** Devs rebasing repeatedly during integration shouldn't trigger 8 reviews. Stops the bleeding even if dedup were perfect.
- **Telemetry:** structured log `diffhound.cooldown.skipped` with PR + age so we know if 600s is right.

### Fix 4: Pin VM checkout to a tag (P2 — process)
- **What:** Workflow's SSH step uses `git checkout v0.5.6 -f` instead of `git checkout origin/master -f`. Add `~/scripts/diffhound-bump.sh` step to update VM checkout when bumping consumers.
- **Why:** Today's reverts of v0.5.6/v0.5.7 reached production within seconds because VM tracks master. A tagged pin gives revert-as-rollback and explicit upgrade.
- **Out of scope this PR if it complicates rollout** — tracked as follow-up.

## Out of scope (explicitly)

- Fixing LARGE-tier multi-chunk uneven findings ("why not all in beginning") — fundamentally bounded by LLM context. Better dedup mitigates the *appearance* of this; not solving it directly.
- Retroactive cleanup of PR #7145's 74 comments. Manual or separate tool.
- Re-evaluating v0.5.6/v0.5.7 reverts (test-rule false positives) — separate concern.

## Validation plan

New fixtures (`tests/fixtures/`):
1. `cross-round-symbol-drift`: two FINDING blocks, same logical issue, `primary_symbol` differs (`DECR` vs `client.decr`). Current behavior: dedup miss. Expected: drop.
2. `cross-round-line-drift`: same FINDING posted at line 248 and 266 (file_basename + symbol-set match). Expected: drop.
3. `marker-roundtrip`: post comment with embedded identity marker, parse back, assert hash recovered.
4. `cooldown-skip`: simulate two synchronize events 60s apart, expect second to skip. Third event at 700s expected to run.
5. `cooldown-override`: `/diffhound review` comment within cooldown window expected to force review.

Existing fixtures (37/37 currently passing) must still pass.

## Rollout

1. Land in `feat/SA/BX-3010-comment-storm-fix` branch on `shubhamattri/diffhound`.
2. Codex + Gemini parallel peer review on this plan (in progress).
3. Implementation commit-by-commit per fix.
4. Tag v0.5.6 (re-using the slot — the prior v0.5.6 was reverted same-day).
5. `~/scripts/diffhound-bump.sh v0.5.6` cascades to all 4 consumer repos.
6. Watch PR #7145 next force-push run + 2-3 other active monorepo PRs for: (a) "diffhound-id" markers appearing in comments, (b) cooldown skip messages on rapid-fire pushes, (c) duplicate-comment count dropping.

## Open questions for peer review

1. **Hash inputs:** is `(file_basename, symbols_set, severity, first_512_chars_what)` the right tuple? Should severity be excluded so a downgrade doesn't break match?
2. **Jaccard threshold 0.6:** too tight (false-drop) or too loose (false-match)?
3. **Cooldown default 600s:** does this hurt the legitimate "I just fixed it, please re-review" workflow? Should it be event-aware (e.g. 600s for synchronize, 0s for opened)?
4. **Force-review trigger phrasing:** `/diffhound review` vs `@diffhound review` vs label? What plays best with existing workflow filters?
5. **What did the v0.5.6 / v0.5.7 reverts protect against that we should preserve here?** (per the meta-bundle "removing-existing-protection" rule — must enumerate).
