# Changelog

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
