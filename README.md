# diffhound

AI-powered PR code review that actually finds bugs — not just style nits.

Multi-model pipeline: Claude (agentic, reads your codebase) → Codex + Gemini (peer review) → Haiku (voice rewrite). Posts inline comments directly to GitHub.

## What it does

```
$ diffhound 7030 --fast

🔍 PR #7030
──────────────────────────────────────────
  ✓ PR metadata fetched
  ✓ Re-review mode — 6 comments, last reviewed at e866dd2f
  ↻ Re-review: 2 files changed since last review (4KB)
  ↻ Skipping 8 unchanged files (already reviewed)
  ✓ Pass 1 complete
  ✓ Fast review complete

──────────────────────────────────────────
  Re-review: 2 new comments, 3 thread replies
──────────────────────────────────────────
```

- **Agentic review** — Claude reads your actual codebase (not just the diff) to verify findings before flagging
- **Multi-model peer review** — Codex + Gemini cross-check Claude's findings. Consensus = high confidence
- **Re-review mode** — Detects previous reviews, fetches only the incremental diff, checks if your comments were addressed
- **Thread tracking** — Knows which comments are resolved, which are still open, which the author got wrong
- **Voice rewrite** — Posts comments in your voice, not robotic AI-speak. Configurable via example JSONL
- **Inline comments** — Posts directly to GitHub with line-accurate placement (auto-snaps to valid diff lines)
- **Zero lint nits** — Trailing newlines, blank lines, import order? Banned. Only real bugs and design issues

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/shubhamattri/diffhound/main/install.sh | bash
```

Or manually:

```bash
git clone https://github.com/shubhamattri/diffhound.git ~/.diffhound
ln -s ~/.diffhound/bin/diffhound ~/.local/bin/diffhound
```

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`) — with Max subscription or API key
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- `jq` — JSON processor
- **Optional:** [Codex CLI](https://github.com/openai/codex) (`codex`) + [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`gemini`) for multi-model peer review

### macOS

```bash
brew install coreutils gawk jq gh
```

### Linux

```bash
# jq, gh, awk, timeout are typically available by default
sudo apt-get install jq gh
```

## Usage

```bash
# Fast review (Claude only — no peer review)
diffhound 1234 --fast

# Full review (Claude + Codex + Gemini peer review)
diffhound 1234

# Auto-post without confirmation prompt
diffhound 1234 --auto-post

# Fast + auto-post
diffhound 1234 --fast --auto-post
```

## Configuration

```bash
# Add to ~/.zshrc or ~/.bashrc
export REVIEW_REPO_PATH="$HOME/path/to/your/repo"
export REVIEW_LOGIN="your-github-username"
```

| Env Var | Default | Description |
|---------|---------|-------------|
| `REVIEW_REPO_PATH` | _(required)_ | Path to your local git repo |
| `REVIEW_LOGIN` | _(required)_ | Your GitHub username (for re-review detection) |
| `ANTHROPIC_API_KEY` | _(optional)_ | If set, used for Haiku style pass. If unset, uses Claude Max subscription |

## How it works

```
┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐    ┌──────────────┐
│  Pass 1      │    │  Pass 2          │    │  Pass 3+4       │    │  Post        │
│  Claude      │ →  │  Codex + Gemini  │ →  │  Haiku          │ →  │  GitHub API  │
│  (agentic)   │    │  (peer review)   │    │  (voice rewrite)│    │  (inline)    │
│              │    │  --fast skips     │    │                 │    │              │
│  Reads code  │    │  Runs parallel   │    │  Merges + rewrites   │  Posts review │
│  Uses tools  │    │  Finds gaps      │    │  in your voice  │    │  + comments  │
└─────────────┘    └──────────────────┘    └─────────────────┘    └──────────────┘
```

### Re-review optimization

When you've already reviewed a PR and the author pushes fixes:

1. Detects your previous review via GitHub API
2. Extracts the commit SHA your last review was against
3. Fetches only the incremental diff (changes since your last review)
4. Checks each existing thread — resolved? still open? author wrong?
5. Focuses analysis on new/changed files only

### 25 engineering principles

The review checks for real issues across 5 categories:

- **Design** — SOLID violations, DRY, KISS, YAGNI
- **Security** — STRIDE, secrets in code, SQL injection, PII in logs
- **Performance** — N+1 queries, missing pagination, no timeouts
- **Reliability** — Race conditions, swallowed errors, missing transactions
- **Domain-specific** — Copy-paste bugs, enum completeness, timezone mismatches

### What it won't flag

Lint nits are banned. Trailing newlines, extra blank lines, whitespace, import ordering — these are linter concerns, not review concerns.

## Project Structure

```
diffhound/
├── bin/
│   └── diffhound              # CLI entry point
├── lib/
│   ├── review.sh              # Main review pipeline
│   ├── spinner.sh             # Terminal spinner utilities
│   ├── platform.sh            # OS detection + dependency checks
│   ├── parser.sh              # LLM output parsing + line-snapping
│   └── github.sh              # GitHub API posting + fallback logic
├── config/
│   └── diffhound.example.yml  # Example configuration
├── docs/
│   ├── ARCHITECTURE.md        # Pipeline deep-dive
│   └── CUSTOMIZATION.md       # Voice, principles, config
├── review-pr.sh               # Standalone single-file version (backup)
├── install.sh                 # One-command installer
├── CHANGELOG.md
├── LICENSE                    # MIT
└── README.md
```

## Voice customization

diffhound rewrites review comments to match your writing style. Provide examples via a JSONL file:

```jsonl
{"category":"security","subcategory":"token-leak","file_type":"ts","comment":"🔴 this is the user's full login token right? passing it to an external embed means..."}
{"category":"data-bug","subcategory":"wrong-column","file_type":"ts","comment":"🔴 benefits.end_date is NULL for every benefit in prod..."}
```

See [docs/CUSTOMIZATION.md](docs/CUSTOMIZATION.md) for full details.

## Cost

| Pass | What | Cost |
|------|------|------|
| Pass 1 | Claude agentic review | Free (Max subscription) or API |
| Pass 2 | Codex + Gemini peer review | API costs. Skipped with `--fast` |
| Pass 3+4 | Haiku voice rewrite | Free (Max) or ~$0.01/review |

With `--fast` and Claude Max: **$0 per review.**

## License

MIT
