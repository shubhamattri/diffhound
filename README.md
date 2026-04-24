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

# Learn from GitHub feedback (edited/deleted comments update voice JSONL)
diffhound 1234 --learn
```

### Fallback sweep

`bin/diffhound-sweep` polls open PRs via the GitHub REST API and invokes
diffhound on anything that hasn't been reviewed yet. Independent of
GitHub Actions — use it as a safety net when event-driven workflows drop
events or get throttled. See [`docs/SWEEP.md`](docs/SWEEP.md).

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

### RAG context retrieval

Before the AI sees the diff, diffhound gathers surrounding codebase context (5 sections, 4 in parallel):

| Section | What | How |
|---------|------|-----|
| Function context | Complete function/method around each changed hunk | Tree-sitter AST extraction (falls back to ±35 line window) |
| Sibling files | Other files in the same directory | `find` for pattern propagation checks |
| Git history | Last 5 commits per changed file | `git log --oneline` |
| Past comments | Previous review comments on these files | GitHub API |
| Enums & constants | Definitions of constants referenced in the diff | `git grep` |

**Optional:** Install `tree-sitter` for precise function extraction (60-70% fewer tokens vs file headers):

```bash
pip3 install tree-sitter tree-sitter-typescript tree-sitter-javascript tree-sitter-python
```

Without tree-sitter, falls back to showing the first 80 lines of each changed file.

### Re-review optimization

When you've already reviewed a PR and the author pushes fixes:

1. Detects your previous review via GitHub API
2. Extracts the commit SHA your last review was against
3. Fetches only the incremental diff (changes since your last review)
4. Checks each existing thread — resolved? still open? author wrong?
5. Focuses analysis on new/changed files only
6. **Auto-resolves addressed threads** — if a changed line falls within ±2 lines of a previous comment, that thread is automatically resolved via GraphQL API

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
│   ├── github.sh              # GitHub API posting + voice indexer + learning
│   ├── rag.sh                 # RAG context retrieval (parallel sections)
│   └── extract-context.py     # AST-based function extraction (tree-sitter)
├── config/
│   └── diffhound.example.yml  # Example configuration
├── docs/
│   ├── ARCHITECTURE.md        # Pipeline deep-dive
│   └── CUSTOMIZATION.md       # Voice, principles, config
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

## Architecture Deep Dive

### RAG — What it is and why it matters

**RAG (Retrieval-Augmented Generation)** means giving the AI relevant context _before_ it generates a response. Without RAG, the model only sees the diff — 3 changed lines with no idea what the surrounding function does, what other files exist, or what was reviewed before. With RAG, it sees the full picture.

There are several RAG architectures, each with different tradeoffs:

| Type | How it works | Tradeoff |
|------|-------------|----------|
| **Naive RAG** | Fixed retrieval strategy → stuff into prompt | Simple, predictable, but can't adapt to what the model actually needs |
| **Advanced RAG** | Pre-retrieval query rewriting + post-retrieval re-ranking and compression | Better relevance, but more complex pipeline |
| **Graph RAG** | Builds a knowledge graph (e.g., call graph), retrieves subgraphs | Captures relationships ("A calls B which uses table C"), expensive to build |
| **Agentic RAG** | The LLM decides what to retrieve, evaluates, retrieves more if needed | Most flexible — self-correcting, iterative. Slower, less predictable |
| **Hybrid RAG** | Keyword search (BM25) + semantic/vector search combined | Best of both — exact matches AND conceptual matches |

#### What diffhound uses: Naive + Agentic hybrid

```
┌──────────────────────────────────────────────────────────────────────┐
│                        RAG PIPELINE                                  │
│                                                                      │
│  ┌─────────────────────┐     ┌────────────────────────────────────┐  │
│  │  LAYER 1: Naive RAG │     │  LAYER 2: Agentic RAG             │  │
│  │  (rag.sh — fixed)   │     │  (Claude Pass 1 — adaptive)       │  │
│  │                     │     │                                    │  │
│  │  • Function context │────▶│  • Reads additional files on demand│  │
│  │  • Sibling files    │     │  • Follows import chains           │  │
│  │  • Git history      │     │  • Greps for patterns              │  │
│  │  • Past comments    │     │  • Checks test coverage            │  │
│  │  • Enums/constants  │     │  • Verifies findings before posting│  │
│  │                     │     │                                    │  │
│  │  Deterministic,     │     │  Adaptive, self-correcting,        │  │
│  │  5-10 seconds       │     │  follows the code wherever it leads│  │
│  └─────────────────────┘     └────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

**Why this combination?**
- Layer 1 (Naive) guarantees a baseline context floor — every review sees function bodies, sibling files, and history regardless of what the model decides to do
- Layer 2 (Agentic) lets Claude go deeper where needed — if it spots a suspicious pattern, it can read the actual implementation, check callers, verify test coverage
- Neither layer alone is sufficient. Naive RAG misses adaptive exploration. Pure agentic RAG has no guaranteed baseline and may skip obvious context.

**Why not the others?**
- **Graph RAG** — would need to build and maintain a call graph for the entire codebase. High build cost, marginal gain over agentic exploration for PR-sized reviews
- **Vector/semantic search** — useful for large doc collections, overkill for code review where you know exactly which files changed and can deterministically retrieve their context
- **Chunking** — not needed. A large PR diff (~150KB) + RAG context (~44KB) is ~48K tokens, well within Claude's 200K context window. Chunking would _degrade_ review quality by losing cross-file context

### Tree-sitter AST extraction

Most code review tools dump the first N lines of each file as context. This wastes tokens on imports, license headers, and unrelated functions.

Diffhound uses **tree-sitter** (a concrete syntax tree parser) to extract only the enclosing function/method around each changed hunk:

```
Traditional:               Tree-sitter:
┌─────────────────────┐    ┌─────────────────────┐
│ import ...          │    │                     │
│ import ...          │    │                     │
│ import ...          │    │                     │
│ const CONFIG = ...  │    │                     │
│                     │    │                     │
│ function unrelated  │    │                     │
│   ...50 lines...    │    │                     │
│                     │    ├─────────────────────┤
│ function changed()  │    │ function changed()  │
│   line A            │    │   line A            │
│   line B  ← diff    │    │   line B  ← diff    │
│   line C            │    │   line C            │
│   line D            │    │   line D            │
├─────────────────────┤    ├─────────────────────┤
│ ... truncated ...   │    │                     │
└─────────────────────┘    └─────────────────────┘
   ~100 lines, 30%            ~20 lines, 100%
   relevant                    relevant
```

Result: **60-70% fewer tokens** with higher signal density. Falls back to a ±35 line window if tree-sitter isn't installed.

### Multi-model peer review

On new PRs, diffhound doesn't trust a single model. It runs three independent reviewers in parallel:

```
                    ┌──────────┐
              ┌────▶│  Codex   │────┐
              │     └──────────┘    │
┌──────────┐  │     ┌──────────┐    │     ┌───────────────┐
│  Claude   │──┼────▶│  Gemini  │────┼────▶│  Merge + Post │
│  Pass 1-2 │  │     └──────────┘    │     └───────────────┘
└──────────┘  │                      │
              └──────────────────────┘
                   (parallel)
```

- **Agreements** across models = high confidence findings
- **Unique findings** = things one model caught that others missed
- **Disagreements** = presented as-is for the developer to judge

Skipped with `--fast` (re-reviews use Claude only for speed).

### Voice rewrite system

AI review comments sound robotic by default. Diffhound rewrites every comment to match the reviewer's natural writing style using a JSONL file of real examples as style reference.

The system also **learns continuously**:
- If you edit a posted comment on GitHub → the voice file updates
- If you delete a comment (it was wrong) → the example is removed
- If a developer replies with "this is intentional" → recorded as feedback

This creates a feedback loop where reviews get more natural and more accurate over time.

### Auto-resolve on re-review

When a developer pushes fixes, diffhound detects which previous comments are addressed:

1. Parses the incremental diff **line-by-line** (not hunk ranges — avoids false positives from unchanged context lines)
2. Matches each previous comment to actually-changed lines with ±2 line tolerance
3. Resolves matched threads via GitHub's GraphQL API

This eliminates the manual "Resolve conversation" clicking that adds friction to the review cycle.

### Design decisions and why

| Decision | Alternative considered | Why we chose this |
|----------|----------------------|-------------------|
| **No chunking** | Split large diffs into file-level chunks | Cross-file bugs are the highest-value findings. Chunking kills them. Context window isn't a bottleneck. |
| **Naive + Agentic RAG** | Pure agentic, vector DB, graph RAG | Guaranteed baseline + adaptive depth. No infrastructure to maintain. |
| **Tree-sitter over regex** | Regex-based function extraction, head -N | AST-aware extraction is language-agnostic and precise. 60-70% token reduction. |
| **±2 tolerance for auto-resolve** | ±5 (more aggressive) | Peer-reviewed by Codex + Gemini. ±5 resolved unrelated nearby comments. Conservative is safer. |
| **GraphQL for thread resolution** | REST API | REST doesn't expose thread IDs. GraphQL is the only way to resolve review threads programmatically. |
| **Line-by-line diff parsing** | Hunk range matching | Hunk ranges include context lines (unchanged). Line-by-line only counts actual `+`/`-` lines as changed. |
| **Parallel RAG sections** | Sequential retrieval | 4 sections run in parallel with 15s timeouts each. Total RAG time: ~5-10s instead of ~40s. |
| **Voice JSONL over fine-tuning** | Fine-tune a model on past comments | JSONL is transparent, editable, version-controllable. Fine-tuning is a black box. |

## Cost

| Pass | What | Cost |
|------|------|------|
| Pass 1 | Claude agentic review | Free (Max subscription) or API |
| Pass 2 | Codex + Gemini peer review | API costs. Skipped with `--fast` |
| Pass 3+4 | Haiku voice rewrite | Free (Max) or ~$0.01/review |

With `--fast` and Claude Max: **$0 per review.**

## License

MIT
