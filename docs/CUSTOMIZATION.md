# Customization

## Voice Examples

diffhound rewrites review comments to match your writing style. Provide examples via a JSONL file:

```bash
export VOICE_JSONL="$HOME/.diffhound/voice-examples.jsonl"
```

### Format

```jsonl
{"category":"security","subcategory":"token-leak","file_type":"ts","comment":"🔴 this is the user's full login token right? passing it to an external embed means..."}
{"category":"data-bug","subcategory":"wrong-column","file_type":"ts","comment":"🔴 benefits.end_date is NULL for every benefit in prod..."}
{"category":"consistency","subcategory":"sibling-field","file_type":"ts","comment":"employee object also has firstName and lastName..."}
```

### Categories

| Category | What it matches |
|----------|----------------|
| `security` | Token leaks, auth bypass, injection |
| `data-bug` | Wrong columns, NULL fields, data corruption |
| `pattern-propagation` | Same bug in sibling files |
| `consistency` | Sibling object field mismatches |
| `intent-check` | Unclear intent, assumption verification |
| `test-gap` | Missing test coverage |
| `nit` | Style, simplification |
| `re-review` | Thread follow-ups |

### Auto-indexing

When you post a review, diffhound automatically indexes your comments to the JSONL file. Over time, your voice examples grow organically.

## Review Principles

The 25 engineering principles in the review prompt can be customized by editing `lib/review.sh`. They're organized by category:

- **Design & Architecture** — SOLID, DRY, KISS, YAGNI
- **Readability** — CRISP, CLEAR, RIDER, SLAP
- **Reliability** — SAFER, Defense in Depth, Observability
- **Security** — STRIDE, CIA, PoLP, secrets scanning
- **Tests** — FIRST, AAA, GWT
- **Performance** — N+1, pagination, timeouts

## Severity Levels

| Severity | Meaning | Verdict |
|----------|---------|---------|
| BLOCKING | Must fix before merge | REQUEST_CHANGES |
| SHOULD-FIX | Fix soon, can merge with follow-up | COMMENT |
| NIT | Nice to have | APPROVE |

## RAG Context (Optional)

If you have a `review-rag.sh` script that provides additional codebase context, set its path in `lib/review.sh`. It receives:

```
review-rag.sh <diff_file> <repo_path> <pr_number> <reviewer_login>
```

And should output relevant context (sibling files, git history, past review comments) to stdout.
