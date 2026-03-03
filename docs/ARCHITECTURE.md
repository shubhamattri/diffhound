# Architecture

## Pipeline Overview

```
PR Number
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  STEP 0: Metadata + Re-review Detection                       │
│  ├── Fetch PR metadata (title, author, files, HEAD SHA)       │
│  ├── Fetch existing review comments + reviews                  │
│  ├── Detect re-review mode (previous comments from reviewer)   │
│  └── Extract last-reviewed commit SHA for incremental diff     │
└────────────────────────────────────────────────────────────────┘
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  STEP 0.6: Diff Fetch                                          │
│  ├── Full PR diff (always)                                     │
│  ├── Incremental diff: LAST_SHA...HEAD_SHA (re-reviews only)   │
│  └── Edge case: no new commits → skip entirely                 │
└────────────────────────────────────────────────────────────────┘
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  STEP 1: RAG Context Enrichment                                │
│  └── Retrieves sibling files, git history, past comments       │
└────────────────────────────────────────────────────────────────┘
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  STEP 2: Build Review Prompt                                   │
│  ├── 25 engineering principles (SOLID, security, perf, etc.)   │
│  ├── Severity definitions + anchor table                       │
│  ├── Re-review: thread context + incremental diff focus        │
│  └── Output format: FINDING blocks + SCORECARD                 │
└────────────────────────────────────────────────────────────────┘
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  PASS 1: Claude Agentic Review                                 │
│  ├── Uses Claude Code CLI with Read + Bash tools               │
│  ├── Reads actual codebase (not just diff)                     │
│  ├── Verifies findings before flagging                         │
│  └── Output: FINDING blocks with file:line:severity            │
└────────────────────────────────────────────────────────────────┘
    │
    ▼ (skipped with --fast)
┌────────────────────────────────────────────────────────────────┐
│  PASS 2: Peer Review (Codex + Gemini)                          │
│  ├── Runs in parallel                                          │
│  ├── Cross-checks Claude's findings                            │
│  ├── Finds gaps Claude missed                                  │
│  └── Output: additional FINDING blocks                         │
└────────────────────────────────────────────────────────────────┘
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  STEP 5: Voice RAG                                             │
│  ├── Retrieves matching examples from voice JSONL              │
│  ├── Category-based matching (security, data-bug, etc.)        │
│  └── Falls back to canonical examples if no JSONL              │
└────────────────────────────────────────────────────────────────┘
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  PASS 3+4: Merge + Voice Rewrite (Haiku)                       │
│  ├── Merges findings from all models (if multi-model)          │
│  ├── Rewrites in reviewer's voice (from examples)              │
│  ├── Outputs COMMENT:/REPLY: blocks + SUMMARY                  │
│  └── Uses prompt caching for cost efficiency                   │
└────────────────────────────────────────────────────────────────┘
    │
    ▼
┌────────────────────────────────────────────────────────────────┐
│  POST: GitHub API                                              │
│  ├── Parse verdict (3-method fallback)                         │
│  ├── Snap line numbers to valid diff lines                     │
│  ├── Post review + inline comments (with fallback)             │
│  ├── Post thread replies (re-review mode)                      │
│  └── Index posted comments to voice JSONL                      │
└────────────────────────────────────────────────────────────────┘
```

## Module Structure

```
lib/
├── review.sh      Main orchestration — runs the full pipeline
├── spinner.sh     Terminal spinner (start/stop/fail)
├── platform.sh    OS detection, dependency checks
├── parser.sh      LLM output parsing, comment extraction, line-snapping
└── github.sh      GitHub API posting, fallback logic, voice indexing
```

## Key Design Decisions

### Why agentic (not just diff)?
The diff alone causes false positives. Claude reads the full file, checks git history, and greps sibling files before flagging anything. This eliminates ~40% of bad findings.

### Why multi-model?
Each model has different blind spots. Running Codex + Gemini in parallel catches things Claude misses (and vice versa). Consensus findings are high confidence.

### Why voice rewrite?
AI review comments sound robotic. The voice pass rewrites them to match the reviewer's actual writing style, making reviews indistinguishable from human-written ones.

### Why incremental diff for re-reviews?
Re-reviewing a 50-file PR when only 2 files changed is wasteful. The incremental diff focuses analysis on what's new, while still checking if previous comments were addressed.

### Why line-snapping?
GitHub's review API rejects comments on lines not in the diff. The snap function finds the nearest valid diff line, preventing API errors without losing the finding.
