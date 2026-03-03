# Changelog

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
