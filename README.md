# diffhound

AI-powered PR code review that actually finds bugs — not just style nits.

Multi-model pipeline: Claude reviews the diff and retrieved code context, Codex + Gemini cross-check findings, and a voice rewrite prepares one batched GitHub review. Uses the existing reviewer's GitHub account.

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

- **Code context** — Review prompts include retrieved repository context alongside the diff; the primary API call does not have repository tools
- **Multi-model peer review** — Codex + Gemini cross-check Claude's findings. Consensus = high confidence
- **Re-review mode** — Detects previous reviews, fetches only the incremental diff, checks if your comments were addressed
- **Thread tracking** — Knows which comments are resolved, which are still open, which the author got wrong
- **Voice rewrite** — Posts comments in your voice, not robotic AI-speak. Configurable via example JSONL
- **Inline comments** — Posts directly to GitHub with line-accurate placement (auto-snaps to valid diff lines)
- **Zero lint nits** — Trailing newlines, blank lines, import order? Banned. Only real bugs and design issues
- **Persistent summary and finding history** — One summary comment is updated after successful reviews. Submitted reviews store recoverable finding state, including overflow findings
- **Explicit commands** — `/ask`, `/describe`, `/labels`, and `/changelog`, with local previews before applying changes

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

- A funded `ANTHROPIC_API_KEY` for Diffhound's API backend
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated
- `jq`, Python 3.9+, Bash, Git, curl and timeout (`gtimeout` on macOS)
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
| `ANTHROPIC_API_KEY` | _(required)_ | Funded Diffhound API key. The runtime does not use personal Claude subscription credentials. |
| `GH_TOKEN` | `gh` authentication | Token for the existing reviewer account, with access to read code and write PR reviews and issue comments. |
| `ANTHROPIC_API_URL` | `https://api.anthropic.com/v1/messages` | API endpoint override; credentials are sent to this endpoint. |
| `DIFFHOUND_OFFLINE` | `0` | Set to `1` to force model-calling validators onto their passthrough branch. The test suite sets this. |
| `DIFFHOUND_MAX_INLINE` | `8` | Initial-review nonblocking inline limit; remaining findings go in the review body. |
| `DIFFHOUND_MAX_INLINE_REREVIEW` | `3` | Subsequent-review nonblocking inline limit. Blockers remain uncapped. |
| `DIFFHOUND_MAX_REPLIES` | `3` | Thread replies per review; overflow is included in the body. |
| `DIFFHOUND_MAX_BODY_CHARS` | `30000` | Legacy name for the final UTF-8 **byte** budget (1–60000), including hidden state and markers. Shared by assembly, review publishing, fallback bodies, and sticky summaries. Earlier findings stay in linked reviews; a single oversized round still fails without truncation. |
| `DIFFHOUND_DEDUP_MODEL` | `claude-haiku-4-5-20251001` | Judge for reworded repeats of known open, nonblocking findings. |
| `DIFFHOUND_COMMAND_MODEL` | `claude-sonnet-5` | Model for explicit PR commands. Each command makes one generation call. |
| `DIFFHOUND_LOCK_DIR` | `~/.cache/diffhound/locks` | Shared host directory for per-PR review locks. All processes on a host must use the same directory. |
| `DIFFHOUND_BIN` | `/opt/diffhound/bin/diffhound` | Entrypoint executable override; also supported by the fallback sweep. |

Reviews and commands use the funded API key. `CLAUDE_CODE_OAUTH_TOKEN` is explicitly
unset in model processes. Commands require exported environment variables; they
do not load interactive shell profiles.

### Explicit commands

```bash
diffhound /ask 123 --repo owner/repo --question 'Why does this change affect authentication?'
diffhound /describe 123 --repo owner/repo
diffhound /labels 123 --repo owner/repo
diffhound /changelog 123 --repo owner/repo

# Apply a reviewed result instead of printing a draft:
diffhound /describe 123 --repo owner/repo --apply
```

Each command returns JSON with the reviewed SHA, result, and whether it was applied.
`--apply` regenerates from current evidence and applies the result in the same invocation.
`/describe` and `/changelog` update separate marked sections of the PR description,
preserving human text. Changelog generation produces a PR release-note section;
it does not commit a repository CHANGELOG. Labels are additive and must already
exist in the repository. `/ask --apply` maintains one answer for CLI invocations;
comment-triggered questions each have their own answer, updated on retry.
Empty, invalid, truncated model output, or a changed PR head prevents writes.
Commands reject diffs over 200,000 characters instead of silently omitting code.

For comment-triggered commands, copy [the consumer workflow](examples/diffhound-workflow.yml)
and configure `DIFFHOUND_GITHUB_TOKEN` (your existing account), `ANTHROPIC_API_KEY`,
plus the existing SSH workflow's `DIFFHOUND_HOST` and `DIFFHOUND_SSH_KEY` secrets.
An explicit `/ask question`, `/describe`, `/labels`, or `/changelog` comment from a
repository writer applies that command. Other comments, bots, and read-only users
cannot trigger writes. The command workflow runs trusted Diffhound code, not PR code.
The consumer workflow includes `synchronize`, so pushes continue to trigger reviews.

### GitHub Action and Docker

The Docker Action accepts `pr-number`, `mode`, `auto-post`, and `repo-path` for
reviews. It also accepts `command`, `question`, and `apply` for explicit commands.
Pass `GH_TOKEN` for the existing account and `ANTHROPIC_API_KEY` through the step's
environment. `GITHUB_TOKEN` would post as the Actions bot, so use your account token
when retaining your reviewer identity.

```bash
docker build -t diffhound:local .
docker run --rm -e GH_TOKEN -e ANTHROPIC_API_KEY diffhound:local \
  /describe 123 --repo owner/repo
docker run --rm -e GH_TOKEN -e ANTHROPIC_API_KEY diffhound:local \
  123 --repo owner/repo --auto-post
```

Use `bin/diffhound` for CLI, SSH, and sweep invocations so the per-PR lock applies.
Locks serialize reviews on a shared host; they are not distributed locks between
independent runners. Use one review executor per repository. A review whose head
changes during generation is rejected before publishing and picked up by the next
push run or sweep.

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
6. Reconciles finding history using full paths and complete concern text. Exact repeats survive line movement; a judge can link reworded, nonblocking repeats to known open findings
7. Reads resolution from GitHub threads. A nearby edit or absence from an incremental review does not prove a fix. Rediscovered resolved findings and severity increases are reported again
8. Falls back to a full PR diff after force pushes or when ancestry cannot be established

One batched review contains new inline findings and substantive thread replies;
position failures move findings into its body. The initial successful run also
creates one persistent summary comment. Later runs edit that summary. Clean
COMMENT reruns with nothing new refresh the previous review in place. This is an
API publication contract, not a guarantee of exactly one GitHub email.

History is stored in submitted review bodies, so fresh Actions/Docker workers can
recover it. An unreadable history stops publication; an unavailable thread-status
read keeps findings rather than hiding them. Body-only findings stay open until
there is explicit resolution evidence; incremental silence never closes them.
A single oversized round fails visibly instead of dropping findings.
Exact matching is deterministic; semantic matching remains model-dependent and
keeps findings when the judge fails or is uncertain. It never suppresses a new
BLOCKING finding. See [the adoption matrix](docs/OSS-ADOPTION.md).

History format v2 stores only changed finding records and points to the prior submitted
review. A new round shows its selected/new/reopened findings in full and links to earlier
rounds; it does not copy the PR's complete history into every comment. Reading all review
pages reconstructs the full state, including older v1 snapshots. Missing, corrupt, foreign,
or unsubmitted parent reviews stop publication instead of resetting deduplication.
Quiet refreshes keep the replaced review's original parent and visible findings.

After v2 reviews have been published, use a v2-aware build when rolling back. Version
v0.7.60 and older cannot reconstruct v2 history. A legacy-reader guard makes them
stop rather than silently reuse stale state; pause publishing or use a v2-aware build. There is no database migration or runtime-secret change.

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
| **Explicit thread resolution** | Resolve after a nearby edit | A changed line does not prove the reported defect is fixed. GitHub resolution and recurrence drive the finding ledger. |
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
