# Customization

## Repository guidance

Add `.diffhound.yml` or `.diffhound.yaml` to the reviewed repository:

```yaml
review:
  priorities:
    - Authorization boundaries
    - Transaction consistency and retry behavior
  ignore:
    - Formatting already enforced by the repository linter
  skip_files:
    - "docs/generated/**"
  context: |
    Background jobs can receive the same event more than once.
    Public APIs must remain compatible with the deployed mobile client.
```

The runtime parses YAML with PyYAML or a compatible `yq`. Priorities and
ignore guidance enter the review prompt; `skip_files` affects diff filtering.
Use exclusions carefully because excluded code is outside review coverage.

If no YAML file is present, `.diffhound.md` supplies plain-text context.
Runtime settings such as repository path and GitHub identity use environment
variables, not the repository guidance schema. See [Configuration](../README.md#configuration).

## Reviewer voice

Examples live at `~/.diffhound/voice-examples.jsonl`. The current review runtime
uses this fixed path; exporting `VOICE_JSONL` does not override it.

```jsonl
{"category":"security","subcategory":"authorization","file_type":"ts","comment":"Can this lookup also include the account scope? A valid record ID alone should not grant access."}
{"category":"data-bug","subcategory":"retry","file_type":"py","comment":"If the worker retries after the API call succeeds, this path sends the request again. Where is the completed operation recorded?"}
```

Each line is one object. Categories such as `security`, `data-bug`,
`pattern-propagation`, `consistency`, `intent-check`, `test-gap`, and `re-review`
help retrieve relevant examples. Keep examples representative of the desired
tone and remove sensitive or misleading content.

Publication indexes selected posted comments into the voice examples.
`diffhound <pr> --repo owner/repo --learn` processes edits, deletions, and
developer replies. Learning can write replies and update local learned state;
it is not a read-only preview command.

## Review principles and severity

Review prompts and validators live under `lib/`. They cover design, security,
reliability, observability, tests, and performance. Repository guidance adds
project context without requiring a fork of those shared rules.

| Finding type | Interpretation |
| --- | --- |
| `BLOCKING` | A defect that needs correction before merge. |
| `SHOULD-FIX` | An actionable concern that may be handled in a follow-up. |
| `NIT` | A lower-priority improvement; mechanical formatting belongs in lint. |
| `OPEN_QUESTION` | A question requiring clarification rather than an asserted defect. |

The final verdict also depends on verification, peer coverage, and re-review
guards. Severity labels alone are not the complete publication policy.

## Custom context retrieval

Set `REVIEW_RAG_SCRIPT` to replace the bundled retriever:

```bash
export REVIEW_RAG_SCRIPT="$HOME/tools/review-context.sh"
```

The pipeline invokes it with:

```text
review-context.sh <diff_file> <repo_path> <pr_number> <reviewer_login>
```

Write context to stdout and diagnostics to stderr. The invocation has a
60-second timeout. Context is cached and may be trimmed or filtered for
individual chunks. The supplied repository path points to the materialized
review worktree when that step succeeds.

Optional Tree-sitter language packages improve function extraction in the
bundled retriever. Without them, `extract-context.py` uses a window around
changed lines; if the extractor itself fails, the retriever has a file-header
fallback.
