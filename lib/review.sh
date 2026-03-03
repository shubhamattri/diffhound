#!/bin/bash
# diffhound — AI-powered PR code review
# Multi-model pipeline: Claude (agentic) → Codex+Gemini (peer review) → Haiku (voice rewrite)
# https://github.com/shubhamattri/diffhound

# Allow calling from inside a Claude Code session
unset CLAUDECODE 2>/dev/null || true

set -euo pipefail
IFS=$'\n\t'

# ── Resolve lib directory ────────────────────────────────────
DIFFHOUND_ROOT="${DIFFHOUND_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB_DIR="${DIFFHOUND_ROOT}/lib"

# ── Source modules ───────────────────────────────────────────
source "${LIB_DIR}/spinner.sh"
source "${LIB_DIR}/platform.sh"
source "${LIB_DIR}/parser.sh"
source "${LIB_DIR}/github.sh"

# ── Verify dependencies ─────────────────────────────────────
_check_deps

PR_NUMBER="${1:-}"
AUTO_POST=false
FAST_MODE=false

# ── Configurable defaults (override via env vars) ────────────
REPO_PATH="${REVIEW_REPO_PATH:-}"
REVIEWER_LOGIN="${REVIEW_LOGIN:-}"

if [ -z "$REPO_PATH" ] || [ -z "$REVIEWER_LOGIN" ]; then
  echo "Error: REVIEW_REPO_PATH and REVIEW_LOGIN must be set." >&2
  echo "  export REVIEW_REPO_PATH=\"\$HOME/path/to/your/repo\"" >&2
  echo "  export REVIEW_LOGIN=\"your-github-username\"" >&2
  exit 1
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Usage: $0 <PR_NUMBER> [--auto-post] [--fast]"
  exit 1
fi

for _arg in "${@:2}"; do
  case "$_arg" in
    --auto-post) AUTO_POST=true ;;
    --fast)      FAST_MODE=true ;;
  esac
done

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: PR_NUMBER must be numeric" >&2
  exit 1
fi

echo ""
echo "🔍 PR #${PR_NUMBER}"
echo "──────────────────────────────────────────"

cd "$REPO_PATH" || { echo "Error: Cannot cd to $REPO_PATH" >&2; exit 1; }

spinner_start "Fetching PR metadata..."
REPO_OWNER=$(gh repo view --json owner --jq '.owner.login')
REPO_NAME=$(gh repo view --json name --jq '.name')
if ! PR_DATA=$($_TIMEOUT_CMD 300 gh pr view "$PR_NUMBER" --json title,body,author,files,additions,deletions,headRefOid 2>&1); then
  spinner_fail "Failed to fetch PR #${PR_NUMBER}"
  exit 1
fi

PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
PR_AUTHOR=$(echo "$PR_DATA" | jq -r '.author.login')
PR_BODY=$(echo "$PR_DATA" | jq -r '.body')
FILE_COUNT=$(echo "$PR_DATA" | jq -r '.files | length')
ADDITIONS=$(echo "$PR_DATA" | jq -r '.additions')
DELETIONS=$(echo "$PR_DATA" | jq -r '.deletions')
HEAD_SHA=$(echo "$PR_DATA" | jq -r '.headRefOid')

spinner_stop "PR metadata fetched"
echo "  📄 ${PR_TITLE}"
echo "  👤 @${PR_AUTHOR}  •  ${FILE_COUNT} files  +${ADDITIONS}/-${DELETIONS}"

# Temp files
DIFF_FILE=$(mktemp -t "pr-${PR_NUMBER}-diff.XXXXXX")
PROMPT_FILE=$(mktemp -t "pr-${PR_NUMBER}-prompt.XXXXXX")
CLAUDE_OUT=$(mktemp -t "pr-${PR_NUMBER}-claude.XXXXXX")
CODEX_OUT=$(mktemp -t "pr-${PR_NUMBER}-codex.XXXXXX")
GEMINI_OUT=$(mktemp -t "pr-${PR_NUMBER}-gemini.XXXXXX")
SYNTH_PROMPT=$(mktemp -t "pr-${PR_NUMBER}-synth-prompt.XXXXXX")
REVIEW_STRUCTURED=$(mktemp -t "pr-${PR_NUMBER}-structured.XXXXXX")
REVIEW_SUMMARY=$(mktemp -t "pr-${PR_NUMBER}-summary.XXXXXX")
REVIEW_JSON=$(mktemp -t "pr-${PR_NUMBER}-review.XXXXXX")

cleanup() {
  [ -n "$_spinner_pid" ] && kill "$_spinner_pid" 2>/dev/null && wait "$_spinner_pid" 2>/dev/null || true
  _spinner_pid=""
  rm -f "$DIFF_FILE" "$PROMPT_FILE" "$CLAUDE_OUT" "$CODEX_OUT" "$GEMINI_OUT" \
        "${PEER_PROMPT_FILE:-}" "$SYNTH_PROMPT" "$REVIEW_STRUCTURED" "$REVIEW_SUMMARY" \
        "$REVIEW_JSON" "${REVIEW_STRUCTURED}.comments" "${REVIEW_STRUCTURED}.new_comments" \
        "${REVIEW_STRUCTURED}.replies" "${SYNTH_FINDINGS:-}" "${STYLE_PROMPT:-}" \
        "${EXISTING_COMMENTS_FILE:-}" "${EXISTING_REVIEWS_FILE:-}" "${THREADS_SUMMARY_FILE:-}" \
        "${INCREMENTAL_DIFF_FILE:-}" "${INCREMENTAL_FILES_LIST:-}"
}
trap cleanup EXIT INT TERM

# ============================================================
# STEP 0.5: FETCH EXISTING COMMENTS & DETECT RE-REVIEW MODE
# (must run BEFORE diff fetch so we know whether to get incremental diff)
# ============================================================
spinner_start "Fetching existing review comments..."

EXISTING_COMMENTS_FILE=$(mktemp -t "pr-${PR_NUMBER}-existing.XXXXXX")
IS_REREVIEW=false
LAST_REVIEWED_SHA=""

# Fetch all inline comments (with thread structure)
gh api "/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/comments" \
  --jq '[.[] | {id, path, line, body, user: .user.login, in_reply_to_id, created_at}]' \
  > "$EXISTING_COMMENTS_FILE" 2>/dev/null || echo "[]" > "$EXISTING_COMMENTS_FILE"

# Fetch review-level comments (summary bodies + commit_id for incremental diff)
EXISTING_REVIEWS_FILE=$(mktemp -t "pr-${PR_NUMBER}-reviews.XXXXXX")
gh api "/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/reviews" \
  --jq '[.[] | {id, state, body, user: .user.login, submitted_at, commit_id}]' \
  > "$EXISTING_REVIEWS_FILE" 2>/dev/null || echo "[]" > "$EXISTING_REVIEWS_FILE"

# Check if reviewer has already posted comments → re-review mode
REVIEWER_COMMENT_COUNT=$(jq --arg login "$REVIEWER_LOGIN" \
  '[.[] | select(.user == $login)] | length' "$EXISTING_COMMENTS_FILE" 2>/dev/null || echo "0")

if [ "$REVIEWER_COMMENT_COUNT" -gt 0 ]; then
  IS_REREVIEW=true

  # Extract the commit SHA from our last review submission
  LAST_REVIEWED_SHA=$(jq -r --arg login "$REVIEWER_LOGIN" \
    '[.[] | select(.user == $login)] | sort_by(.submitted_at) | last | .commit_id // empty' \
    "$EXISTING_REVIEWS_FILE" 2>/dev/null || echo "")

  if [ -n "$LAST_REVIEWED_SHA" ]; then
    spinner_stop "Re-review mode — ${REVIEWER_COMMENT_COUNT} comments, last reviewed at ${LAST_REVIEWED_SHA:0:8}"
  else
    spinner_stop "Re-review mode — ${REVIEWER_COMMENT_COUNT} existing comments found"
  fi
  echo "  ↻ Checking which previous comments are addressed..."
else
  spinner_stop "Fresh review — no prior comments from reviewer"
fi

# Build human-readable thread context for the prompt
THREADS_SUMMARY_FILE=$(mktemp -t "pr-${PR_NUMBER}-threads.XXXXXX")

jq -r --arg login "$REVIEWER_LOGIN" '
  # Group by thread: top-level comments and their replies
  . as $all |
  [ .[] | select(.in_reply_to_id == null) ] |
  .[] |
  . as $top |
  "THREAD at \(.path):\(.line // "general")\n" +
  "  REVIEWER: \(.body)\n" +
  ([$all[] | select(.in_reply_to_id == $top.id)] |
    if length > 0 then
      .[] | "  AUTHOR_REPLY (\(.user)): \(.body)\n"
    else ""
    end
  )
' "$EXISTING_COMMENTS_FILE" > "$THREADS_SUMMARY_FILE" 2>/dev/null || echo "" > "$THREADS_SUMMARY_FILE"

# ============================================================
# STEP 0.6: FETCH DIFF (full + incremental for re-reviews)
# ============================================================

# Edge case: no new commits since last review — skip entirely
if [ "$IS_REREVIEW" = true ] && [ -n "$LAST_REVIEWED_SHA" ] && [ "$LAST_REVIEWED_SHA" = "$HEAD_SHA" ]; then
  echo ""
  echo "  ✅ No new commits since last review (${LAST_REVIEWED_SHA:0:8}). Nothing to re-review."
  echo "  → https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PR_NUMBER}"
  exit 0
fi

spinner_start "Fetching diff..."
if ! $_TIMEOUT_CMD 300 gh pr diff "$PR_NUMBER" > "$DIFF_FILE" 2>&1; then
  spinner_fail "Failed to fetch diff"
  exit 1
fi
DIFF_SIZE=$(wc -c < "$DIFF_FILE")
if [ "$DIFF_SIZE" -gt 150000 ]; then
  spinner_stop "Diff fetched (large: ${DIFF_SIZE} bytes — focused review)"
else
  spinner_stop "Diff fetched ($(echo "$DIFF_SIZE / 1024" | bc)KB)"
fi

# For re-reviews: fetch incremental diff (only changes since last review)
INCREMENTAL_DIFF_FILE=""
INCREMENTAL_FILES_LIST=""
if [ "$IS_REREVIEW" = true ] && [ -n "$LAST_REVIEWED_SHA" ]; then
  INCREMENTAL_DIFF_FILE=$(mktemp -t "pr-${PR_NUMBER}-incremental.XXXXXX")
  INCREMENTAL_FILES_LIST=$(mktemp -t "pr-${PR_NUMBER}-incr-files.XXXXXX")

  # Get list of files changed between last reviewed commit and current HEAD
  gh api "/repos/${REPO_OWNER}/${REPO_NAME}/compare/${LAST_REVIEWED_SHA}...${HEAD_SHA}" \
    --jq '.files[].filename' > "$INCREMENTAL_FILES_LIST" 2>/dev/null || true

  # Get actual diff — try local git first, fall back to GitHub compare API
  if git -C "$REPO_PATH" cat-file -e "$LAST_REVIEWED_SHA" 2>/dev/null; then
    git -C "$REPO_PATH" diff "${LAST_REVIEWED_SHA}...${HEAD_SHA}" > "$INCREMENTAL_DIFF_FILE" 2>/dev/null || true
  fi

  # Fallback: if local git diff failed or SHA not in repo, use GitHub API
  INCR_SIZE=$(wc -c < "$INCREMENTAL_DIFF_FILE" 2>/dev/null | tr -d ' ' || echo "0")
  if [ "$INCR_SIZE" -eq 0 ]; then
    gh api "/repos/${REPO_OWNER}/${REPO_NAME}/compare/${LAST_REVIEWED_SHA}...${HEAD_SHA}" \
      -H "Accept: application/vnd.github.v3.diff" > "$INCREMENTAL_DIFF_FILE" 2>/dev/null || true
    INCR_SIZE=$(wc -c < "$INCREMENTAL_DIFF_FILE" 2>/dev/null | tr -d ' ' || echo "0")
  fi

  CHANGED_FILES=$(wc -l < "$INCREMENTAL_FILES_LIST" 2>/dev/null | tr -d ' ' || echo "0")

  if [ "$INCR_SIZE" -gt 0 ] && [ "$CHANGED_FILES" -gt 0 ]; then
    # Count files in full diff for comparison
    FULL_DIFF_FILES=$(grep -c '^diff --git' "$DIFF_FILE" || echo "0")
    UNCHANGED_FILES=$((FULL_DIFF_FILES - CHANGED_FILES))
    [ "$UNCHANGED_FILES" -lt 0 ] && UNCHANGED_FILES=0
    echo "  ↻ Re-review: ${CHANGED_FILES} files changed since last review (${INCR_SIZE} bytes)"
    echo "  ↻ Skipping ${UNCHANGED_FILES} unchanged files (already reviewed)"
  else
    # Incremental diff failed or empty — fall back to full review
    echo "  ↻ Could not compute incremental diff — using full diff"
    INCREMENTAL_DIFF_FILE=""
    INCREMENTAL_FILES_LIST=""
  fi
fi

# ============================================================
# STEP 1: RAG CONTEXT ENRICHMENT
# ============================================================
spinner_start "Retrieving codebase context (RAG)..."
RAG_CONTEXT_FILE=$(mktemp -t "pr-${PR_NUMBER}-rag.XXXXXX")

REVIEW_RAG_SCRIPT="${REVIEW_RAG_SCRIPT:-}"
if [ -n "$REVIEW_RAG_SCRIPT" ] && timeout 30 bash "$REVIEW_RAG_SCRIPT" \
    "$DIFF_FILE" "$REPO_PATH" "$PR_NUMBER" "$REVIEWER_LOGIN" \
    > "$RAG_CONTEXT_FILE" 2>/dev/null; then
  RAG_SIZE=$(wc -c < "$RAG_CONTEXT_FILE" | tr -d ' ')
  spinner_stop "RAG context ready ($(echo "$RAG_SIZE / 1024" | bc)KB)"
else
  spinner_stop "RAG context unavailable — proceeding with diff only"
  echo "" > "$RAG_CONTEXT_FILE"
fi

# ============================================================
# STEP 2: BUILD THE FULL REVIEW PROMPT
# ============================================================
cat > "$PROMPT_FILE" << 'PROMPT_EOF'
You are performing a senior-level code review. Your job here is ENGINEERING ONLY — find bugs, risks, and issues with precision. Do NOT worry about tone, style, or how you phrase things. Just be accurate. A separate pass will handle the writing style.

IMPORTANT: You have access to the full codebase via Read and Bash tools. Use them.
- When you see a changed function — read the full file to understand context before flagging anything
- When you see a pattern in the diff — grep sibling files to check if it exists elsewhere (lateral propagation)
- When you need to verify a type, interface, or enum — read the relevant file
- When you're unsure about intent — check git log for the file
- DO NOT flag something as BLOCKING based only on a diff line — read the surrounding context first
- Use tools actively. The diff is your starting point, not your only source.

# HARD CONSTRAINTS

1. Only flag issues that are verified — before flagging anything, confirm by reading the diff context that the issue actually applies. If you cannot confirm, mark it "UNVERIFIABLE: needs staging check" and include the exact file:line.
2. No "change-all-the-things" suggestions. Incremental fixes only.
3. Do not invent new infrastructure. Propose use of existing utils.
4. Always go deeper: if the diff touches shared helpers, resolvers, or metadata, reference that broader context.
5. If large architectural changes are needed, propose a follow-up ticket, not an in-PR rewrite.
6. NEVER flag lint-level nits. These are explicitly banned: trailing newlines, missing trailing newlines, extra blank lines, whitespace formatting, indentation style, line length, file-ending newlines, import ordering. These are linter/formatter concerns, not code review concerns. A human reviewer's time is too valuable for things a pre-commit hook should catch.

# NOTE ON OUTPUT STYLE
Do NOT worry about tone, casual language, or how comments read. Write your findings in plain technical English — clear, precise, factual. A dedicated style pass will rewrite everything into the right voice. Your job is just to find the right bugs with the right evidence.

# THE 25 PRINCIPLES — CHECK ALL OF THESE

Apply each as a lens. For each principle, perform the concrete check listed.

## Design & Architecture
- **SOLID / SRP**: Is any function doing more than one conceptual job? If yes, flag and suggest extraction.
- **SOLID / OCP**: Is new behavior added by extension (not modification)? Or is existing code being forked?
- **SOLID / LSP**: If subclasses/implementations exist, do they honour the base contract?
- **SOLID / ISP**: Are interfaces bloated? Are callers forced to depend on methods they do not use?
- **SOLID / DIP**: Does code depend on concretions instead of abstractions?
- **DRY**: Detect duplicated logic across files or functions. Propose consolidation into shared helpers.
- **KISS**: Flag unnecessary complexity. Prefer simpler alternatives.
- **YAGNI**: Flag speculative abstractions or features not needed right now.

## Readability & Maintainability
- **CRISP**: Variable/function names are clear, consistent, pronounceable, specific, predictable.
- **CLEAR**: Code is self-documenting. Comments explain WHY, not WHAT.
- **RIDER**: Code is readable, intentional, documented, explicit, reviewable.
- **SLAP** (Single Level of Abstraction): Functions should operate at one abstraction level. If mixed, flag as SLAP violation and suggest extraction.

## Reliability & Safety
- **SAFER** (for migrations/infra scripts): Simple, Auditable, Fail-safe, Extensible, Reversible. Migrations must be idempotent.
- **Defense in Depth**: Multiple validation layers (schema + runtime checks + tests).
- **Observability**: Structured logging (Pino) vs console.log. If the file already uses a logger, show the exact replacement snippet.

## Security & Privacy
- **STRIDE**: Spoofing, Tampering, Repudiation, Information disclosure, Denial of service, Elevation of privilege — check each.
- **CIA**: Confidentiality, Integrity, Availability.
- **PoLP** (Principle of Least Privilege): DB ops, API access, permissions — least privilege everywhere.
- Secrets in code: search diff for process.env.*KEY, AWS_ACCESS_KEY_ID, password, secret, base64 strings. If found: P0 BLOCKING.
- SQL injection: string concatenation in queries is BLOCKING.
- PII in logs: email, phone, ssn, aadhaar near log calls = BLOCKING.

## Tests & CI
- **FIRST**: Tests are Fast, Independent, Repeatable, Self-validating, Timely.
- **AAA**: Arrange, Act, Assert — each test follows this structure.
- **GWT**: Given, When, Then — test names/descriptions follow this pattern.
- For any logic change: verify presence of unit tests covering the changed behavior. If absent and non-trivial: SHOULD-FIX, include exact test cases to add.

## Performance & Scalability
- **N+1 Queries**: Detect DB queries in loops. Check if DataLoader or withGraphFetched exists but is not used — that is BLOCKING.
- For GraphQL field resolvers: N+1 cost = (queries per invocation) x (max list size). Evaluate the multiplied cost, not per-item cost.
- Pagination: loading unbounded data into memory = BLOCKING.

# CONCRETE VERIFICATION CHECKS (run in this order)

1. **Diff scanning**: Map changed files to domain (API, UI, migrations, infra). For each changed file, list functions and top-level changes.

2. **Type safety**: Flag any obvious type errors, use of `any`, `unknown`, `@ts-ignore`. Note whether tsc --noEmit would pass based on what you can see.

3. **Security**: Scan diff for secrets, SQL injection, PII in logs.

4. **Observability**: Search for console.log in changed files. If file already uses structured logger, show the exact replacement snippet.

5. **DB queries**: Detect queries in loops. If DataLoader/withGraphFetched exists in context but is not used: BLOCKING N+1.

6. **Migrations & idempotency**: For migration files — check IF NOT EXISTS guards, CONCURRENTLY, NOT VALID patterns. Verify the down() function is valid SQL and does not have duplicate WHERE clauses.

7. **Tests**: For any logic change, verify presence/absence of tests. If absent: recommend with exact test cases in GWT format.

8. **Copy-paste bugs**: For TPA/insurer integration files — does the file name say "Care" but reference "MEDIASSIST"? Check for wrong enum/constant from copied code.

9. **Enum completeness**: For any status filter array in the diff — check whether every likely enum value is covered. Missing values = SHOULD-FIX minimum.

10. **Vue guard audit**: For any removed v-if or conditional — does the same guard appear in a method body too? If yes, both must change together. Does removing it allow an unintended user cohort to initiate payment/booking/irreversible action? If yes: BLOCKING.

11. **Race conditions**: Two separate DB calls updating related fields with no transaction = SHOULD-FIX. In financial operations: BLOCKING.

12. **Resilience** (for external API calls, jobs, queues):
    - No timeout on axios/fetch = BLOCKING
    - Loop with no per-item try/catch (no bulkhead) = BLOCKING
    - No DLQ for async queue processing = BLOCKING
    - No retry/backoff = SHOULD-FIX

13. **Hardcoded values**: Config values, base TAT days, SLA values, URLs hardcoded in code instead of using a shared config object = SHOULD-FIX.

14. **Timezone**: CURRENT_DATE or NOW() in cron SQL — verify timezone context. UTC vs IST mismatch = BLOCKING.

15. **NO LAZY VERIFICATION — do the work yourself, never push it back to the author**:
    If you can verify something by reading the diff, you MUST verify it before commenting.
    NEVER write comments like:
    - "verify this could happen"
    - "confirm X matches Y"
    - "check if this is always set"
    - "make sure this exists in the admin dashboard"
    - "double check the behavior is identical"
    If you can read the diff and determine the answer: state it as fact.
    If you genuinely cannot determine it from the diff alone (e.g. requires a live DB query or external system state): say "needs staging verification — [exact command to run]" and classify it as a test checklist item, NOT an inline comment.
    An inline comment that says "verify X" with no evidence is noise. The author already knows to verify things that are uncertain — your job is to tell them things they DON'T know.
    STRONGER RULE: If a finding says "verify", "check", "confirm", or "make sure" and the answer IS determinable from the diff — determine it yourself and state it as fact. If NOT determinable from the diff, put it in the CHECKLIST section (### SCORECARD_END → Checklist), NOT as a FINDING.
    A FINDING that says "verify X" is noise — the author already knows to verify uncertain things. Your job is to tell them things they DON'T know.
    ANTI-HALLUCINATION RULE: Never claim production counts, DB state, runtime behavior, or staging verification results unless that evidence is explicitly included in this prompt. If you don't know → say so and classify as a test checklist item. Unknown is always better than fabricated certainty.

16. **BLOCKING context check — read surrounding lines before asserting**:
    Before marking anything BLOCKING, read 3-5 lines above the flagged line in the diff.
    Specifically: if you're flagging that a field is deleted/modified before being used — first check whether the value was already captured in a variable earlier in the same function. If yes, the risk may not exist. Never assert BLOCKING based on a single line in isolation.
    Example mistake to avoid: flagging `delete data.orgId` before `ensureAuthorized()` as a BLOCKING auth bypass — when `orgId` was captured into a separate `const orgId = data.orgId` two lines earlier and that captured value is what auth uses.

17. **Shared job/cron handler audit**:
    For any cron schedule, job processor, or queue handler in the diff — before suggesting a fix:
    Ask "does this handler/cron serve multiple branches (e.g. multiple claim types, multiple channels)?"
    If yes: a fix that changes the shared schedule/behavior will break the other branch.
    The correct fix is always to split by branch, not change the shared handler.
    Example mistake to avoid: changing `waReminder2` cron from `0 8 * * *` to `0 18 * * *` to fix cashless timing — when the same cron also runs reimbursement reminder 2 which is correctly scheduled at 8 AM.

18. **Bull/queue job: outer catch swallowing = BLOCKING**:
    In any Bull job processor: if the outer catch logs but does NOT rethrow, Bull marks the job as successfully completed with no retry.
    If two operations run sequentially inside the job (e.g. reimbursement then cashless), a throw in the first means the second is permanently skipped — no retry, no DLQ, no alert.
    D+N scheduling makes this permanent: you can't re-run yesterday's D+3 job today.
    This is BLOCKING, not SHOULD-FIX.

19. **Empty-payload → wrong branch = BLOCKING**:
    If an update call strips identity fields (orgId, entityId, etc.) from the payload and the handler checks `if (id && Object.keys(data).length)` to decide update vs create — a payload that contained ONLY identity fields becomes `{}` after stripping. `Object.keys({}).length === 0` falls into the create branch, inserting a duplicate row instead of patching.
    This is BLOCKING (data corruption), not SHOULD-FIX.

20. **Legacy data compatibility on field semantic change = BLOCKING**:
    If a PR changes the semantic meaning of a tracked field (e.g. `attemptNumber: 1` → `attemptNumber: 0` for the first attempt), check whether existing production rows already have the old value.
    If they do: after deploy, idempotency checks against the new value will treat old records as "not yet sent" or vice versa — causing double-sends or silent skips for every in-flight record.
    This is BLOCKING. Fix: migration to rewrite legacy values OR a compatibility shim that handles both old and new semantics.

21. **Lateral pattern propagation — scan for the same pattern in sibling files**:
    If a bug fix applies to function/file A using pattern P, ask: "are there other functions or files that implement the same pattern but were NOT updated?"
    Example: a fix to `endorsementValidators.ts` checking `pOrILFlag` — but `policyDataChecks/utils.ts` has `getCoverageMismatch()` with the same pattern and wasn't touched. That's a SHOULD-FIX minimum.
    Scan the diff for the pattern being fixed, then mentally check if it also appears in sibling files (utils, validators, processors with similar names).

22. **Sibling object field consistency**:
    When a field on one object is updated (e.g. `dependent.displayName` → `firstName + lastName`), check whether a sibling object (e.g. `employee`) uses the same field. If yes and it wasn't updated — flag as NIT minimum, SHOULD-FIX if it causes inconsistent behavior.

23. **Security: config-controlled attack surface**:
    For any value that originates from DB config, org meta, or admin-editable fields — ask: "who can change this value, and what happens if it's changed to something malicious?"
    Specifically: if a URL from org config is used to construct a redirect, embed, or token-passing operation — and an admin (compromised or misconfigured) changes that URL — what is the blast radius?
    Token/credential passed to an externally-controlled URL = BLOCKING.

24. **URL construction edge cases**:
    For any code that appends to a URL string:
    a) Double-fragment: if the base URL already contains `#`, appending `#key=val` creates two `#` symbols — the browser parses only the first and ignores the rest. Fix: detect existing fragment and append with `&` instead.
    b) Param collision: if using `append()` to add a param, and the source already contains a param with the same key (e.g. `token`), the consumer may pick the wrong one. Use `set()` or a namespaced key (e.g. `appAuthToken`).
    Either of these causing auth token misdirection = BLOCKING.

25. **Retract nits before posting — no noise comments**:
    Before writing a NIT, reason through it fully. If your own reasoning shows the concern is unfounded (e.g. "actually empty string is falsy so this is already handled"), do NOT post the comment. An inline comment that contradicts itself is worse than no comment — it wastes the author's time and signals uncertain review quality.
    LINT NITS ARE BANNED: trailing newlines, missing newlines, extra blank lines, whitespace, indentation, import order, file-ending newlines — these are linter territory, not review territory. If your comment is about formatting that any auto-formatter would fix, DROP IT. Zero tolerance.

# SEVERITY DEFINITIONS

- BLOCKING: Must fix before merge. Security, N+1 in list resolvers, missing timeout on external calls, data corruption, swallowed errors in financial paths, missing idempotency, SQL syntax errors in migrations.
- SHOULD-FIX: Fix soon, can merge with a follow-up ticket. Error handling, logging, validation gaps, missing tests.
- NIT: Nice to have. Naming, minor refactoring, style.

# SEVERITY ANCHOR TABLE (minimums)

| Condition | Minimum |
|-----------|---------|
| User can reach payment/booking they should not | BLOCKING |
| N+1 in GraphQL resolver used in any list query | BLOCKING |
| Guard removed, newly-reachable unintended cohort | BLOCKING |
| UTC/IST timezone mismatch in cron SQL | BLOCKING |
| Missing timeout on external API call | BLOCKING |
| Swallowed error in financial path | BLOCKING |
| SQL syntax error in migration down() | BLOCKING |
| Bull job outer catch swallowed — one processing branch permanently dropped | BLOCKING |
| Empty-payload stripped of identity fields → falls into create branch (duplicate row) | BLOCKING |
| Legacy field semantic change with no migration — in-flight records silently broken | BLOCKING |
| Enum value absent from filter constant | SHOULD-FIX |
| Missing test file for new functionality | SHOULD-FIX |
| Silent catch block with no warning log | SHOULD-FIX |
| Hardcoded value that duplicates a config object | SHOULD-FIX |
| Token/credential passed to a DB-config-controlled URL (org meta, admin-editable) | BLOCKING |
| URL fragment construction with potential double-`#` causing auth token misdirection | BLOCKING |
| Same bug fix pattern exists in sibling file not updated | SHOULD-FIX |
| Sibling object field updated inconsistently with sibling | NIT |

# SCORING RUBRIC

Produce a score 0-100:
- Security: 25%
- Tests: 20%
- Observability: 10%
- Performance (incl. N+1): 15%
- Readability & Maintainability: 15%
- Backwards compatibility / API stability: 15%

Verdict is severity-based, NOT score-based:
- Any BLOCKING findings → REQUEST_CHANGES
- SHOULD-FIX findings only (no BLOCKING) → COMMENT
- NITs only or clean → APPROVE

# REQUIRED OUTPUT FORMAT

Output each finding as a FINDING block. One block per issue. Be thorough but only flag real issues.

### FINDINGS_START
FINDING: file/path.ts:LINE:SEVERITY

LINE NUMBER RULES (critical — wrong lines cause GitHub to reject the comment):
- LINE must be a line number from the \`+\` side of the diff (i.e. a line shown with \`+\` prefix or unchanged context line inside a hunk)
- Count from the \`@@ +NEW,count @@\` hunk header to find the correct line number
- NEVER approximate or guess a line number — if you can't find the exact \`+\` line, use the nearest \`+\` line in the same hunk
- Only comment on lines that appear in the diff — never reference lines outside diff hunks

WHAT: [One sentence: what is wrong]
EVIDENCE: [What in the diff proves it — reference specific lines, function names, variable names]
IMPACT: [What breaks in production if this is not fixed]
OPTIONS:
1. [Concrete fix option 1]
2. [Concrete fix option 2, if applicable]
3. [Fallback option, if applicable]
UNVERIFIABLE: [yes/no — if yes, what staging command would verify it]
### FINDINGS_END

### SCORECARD_START
Security: X/25 — [reason]
Tests: X/20 — [reason]
Observability: X/10 — [reason]
Performance: X/15 — [reason]
Readability: X/15 — [reason]
Compatibility: X/15 — [reason]
Total: X/100 — REQUEST_CHANGES|APPROVE|COMMENT (verdict from severity: any BLOCKING → REQUEST_CHANGES, SHOULD-FIX only → COMMENT, NITs only/clean → APPROVE)

Blocking: [file:line, file:line, or NONE]
ShouldFix: [file:line, file:line, or NONE]
Nits: [file:line, file:line, or NONE]
Checklist: [staging commands or verification steps needed before merge]
### SCORECARD_END

FINDING RULES:
- Only include findings for issues tied to a SPECIFIC line number visible in the diff
- LINE must be a line visible in the diff as a \`+\` line (added or modified). Never approximate.
- Use the EXACT file path from the diff
- Do NOT include findings for things that look good
- If uncertain after reading surrounding context: mark UNVERIFIABLE: yes

PROMPT_EOF

# Append existing conversation context if present
if [ "$IS_REREVIEW" = true ]; then
  cat >> "$PROMPT_FILE" << REREVIEW_HEADER

---

# EXISTING REVIEW CONVERSATION (re-review mode)

The reviewer has already posted comments on this PR. Your job now is DIFFERENT from a fresh review:

## For each existing THREAD below:
1. Look at the current diff — is the concern now fixed in the code?
2. Did the author reply? Is their reply correct/sufficient?
   - If author said "fixed" → verify in diff. If actually fixed: output THREAD_STATUS: RESOLVED. If not fixed: THREAD_STATUS: STILL_OPEN with evidence.
   - If author gave a reason/explanation → evaluate if their reasoning is technically correct. If wrong: THREAD_STATUS: AUTHOR_WRONG with your counter-evidence. If right: THREAD_STATUS: RESOLVED_BY_EXPLANATION.
   - If author made no reply → THREAD_STATUS: NO_RESPONSE (flag if still an issue in diff)
3. Also look for NEW issues in the diff (new code since last review) — output these as regular FINDING blocks.

## Output format for existing threads:
THREAD_STATUS: path/to/file.ts:LINE
STATUS: RESOLVED | STILL_OPEN | AUTHOR_WRONG | RESOLVED_BY_EXPLANATION | NO_RESPONSE
ORIGINAL_CONCERN: [1-line summary of what was flagged]
EVIDENCE: [what in the diff shows it's fixed or still broken]
AUTHOR_REPLY: [what author said, if anything]
REVIEWER_VERDICT: [your assessment — is author's reply correct? what's the actual state?]

## EXISTING THREADS:
REREVIEW_HEADER

  cat "$THREADS_SUMMARY_FILE" >> "$PROMPT_FILE"
  echo "" >> "$PROMPT_FILE"
  echo "---" >> "$PROMPT_FILE"
  echo "" >> "$PROMPT_FILE"

  # If incremental diff is available, add focused review instructions
  if [ -n "$INCREMENTAL_DIFF_FILE" ] && [ -s "$INCREMENTAL_DIFF_FILE" ]; then
    {
      echo "# RE-REVIEW MODE — FOCUS ON INCREMENTAL CHANGES"
      echo ""
      echo "## FILES CHANGED SINCE LAST REVIEW (at ${LAST_REVIEWED_SHA:0:8}):"
      cat "$INCREMENTAL_FILES_LIST"
      echo ""
      echo "## FILES UNCHANGED (already reviewed — skip unless referenced by a thread):"
      # Files in full diff but NOT in incremental list
      comm -23 \
        <(grep '^diff --git' "$DIFF_FILE" | sed 's|^diff --git a/.* b/||' | sort) \
        <(sort "$INCREMENTAL_FILES_LIST") 2>/dev/null || true
      echo ""
      echo "## YOUR PRIORITIES (in order):"
      echo "1. Check each EXISTING THREAD above — is the concern now fixed in the new code?"
      echo "2. Review ONLY the incremental diff below for NEW issues"
      echo "3. Do NOT re-flag issues in unchanged files — they were already reviewed"
      echo ""
      echo "---"
      echo ""
      echo "# INCREMENTAL DIFF (changes since last review at ${LAST_REVIEWED_SHA:0:8})"
      echo ""
    } >> "$PROMPT_FILE"
    cat "$INCREMENTAL_DIFF_FILE" >> "$PROMPT_FILE"
    {
      echo ""
      echo "---"
      echo ""
      echo "# FULL PR DIFF (for context only — reference when checking thread resolution)"
      echo ""
    } >> "$PROMPT_FILE"
  else
    echo "# NEW FINDINGS (issues not in previous review)" >> "$PROMPT_FILE"
    echo "" >> "$PROMPT_FILE"
  fi
fi

# Append PR details and diff
cat >> "$PROMPT_FILE" << PR_META

# PR DETAILS

Title: ${PR_TITLE}
Author: @${PR_AUTHOR}
Files changed: ${FILE_COUNT} (+${ADDITIONS}/-${DELETIONS})

PR_META

# For re-reviews with incremental diff, label the full diff as context-only
if [ "$IS_REREVIEW" = true ] && [ -n "$INCREMENTAL_DIFF_FILE" ] && [ -s "$INCREMENTAL_DIFF_FILE" ]; then
  cat >> "$PROMPT_FILE" << PR_META_REREVIEW

PR Description:
${PR_BODY}

---

# FULL PR DIFF (context reference — focus your analysis on the INCREMENTAL DIFF above)

PR_META_REREVIEW
else
  cat >> "$PROMPT_FILE" << PR_META_FRESH

PR Description:
${PR_BODY}

---

# DIFF

PR_META_FRESH
fi

cat "$DIFF_FILE" >> "$PROMPT_FILE"

# Append RAG context if available
if [ -s "$RAG_CONTEXT_FILE" ]; then
  cat >> "$PROMPT_FILE" << RAG_HEADER

---

# CODEBASE CONTEXT (RAG-retrieved — sibling files, git history, past comments)
# Use this to verify patterns, check lateral propagation, and avoid false positives.

RAG_HEADER
  cat "$RAG_CONTEXT_FILE" >> "$PROMPT_FILE"
fi

# ============================================================
# STEP 3: RUN CLAUDE — AGENTIC PASS (primary review with tools)
# ============================================================
echo ""
echo ""
_TOTAL_PASSES=4
[ "$FAST_MODE" = "true" ] && _TOTAL_PASSES=2
spinner_start "Analyzing code (pass 1/${_TOTAL_PASSES})......"

# Pass 1: Claude agentic — uses Max subscription (claude.ai auth), NOT the API key.
# Unset ANTHROPIC_API_KEY temporarily so claude CLI doesn't fall back to pay-per-use billing.
# The key is restored after this block for the curl-based Haiku call in Pass 3+4.
_SAVED_API_KEY="${ANTHROPIC_API_KEY:-}"
unset ANTHROPIC_API_KEY

if ! claude -p \
    --allowedTools "Read,Bash" \
    --add-dir "$REPO_PATH" \
    --dangerously-skip-permissions \
    --output-format text \
    < "$PROMPT_FILE" > "$CLAUDE_OUT" 2>&1; then
  spinner_fail "Agentic pass failed — falling back to standard analysis"
  if ! claude -p < "$PROMPT_FILE" > "$CLAUDE_OUT" 2>&1; then
    spinner_fail "Analysis failed"
    cat "$CLAUDE_OUT" >&2
    export ANTHROPIC_API_KEY="$_SAVED_API_KEY"
    exit 1
  fi
fi

export ANTHROPIC_API_KEY="$_SAVED_API_KEY"
spinner_stop "Pass 1 complete"

# ============================================================
# STEP 4: PEER REVIEW — CODEX + GEMINI (skipped in --fast mode)
# ============================================================
CODEX_CONTENT=""
GEMINI_CONTENT=""

if [ "$FAST_MODE" != "true" ]; then
  spinner_start "Cross-checking findings (pass 2/${_TOTAL_PASSES})..."

  PEER_PROMPT_FILE=$(mktemp -t "pr-${PR_NUMBER}-peer.XXXXXX")
  cat > "$PEER_PROMPT_FILE" << PEER_EOF
I need a peer review of this engineering analysis. Do NOT run any tools or execute code. Text response only.

## Context
Code review PR. A primary reviewer produced FINDING blocks below. You also have the full diff to spot anything missed.

## Primary Analysis (FINDING blocks)
$(cat "$CLAUDE_OUT")

## Full PR Diff
$(cat "$DIFF_FILE")

## Your Task (engineering only — no style concerns)
1. For each BLOCKING finding: do you agree? If wrong or overstated, explain why with diff evidence.
2. Any BLOCKING or SHOULD-FIX issues the primary analysis missed? Reference exact file:line from diff.
3. Any findings rated too low or too high severity?
4. Assume there is at least one gap. Find it.

Respond in the same FINDING block format. Plain text. No style concerns.
PEER_EOF

  # Run Codex in background (prompt via stdin to avoid ARG_MAX on large diffs)
  (cd "$REPO_PATH" 2>/dev/null || cd /tmp; \
    codex exec --skip-git-repo-check -s read-only < "$PEER_PROMPT_FILE" > "$CODEX_OUT" 2>&1 || \
    echo "CODEX_UNAVAILABLE" > "$CODEX_OUT") &
  CODEX_PID=$!

  # Run Gemini in background (prompt via stdin to avoid ARG_MAX on large diffs)
  (gemini -o text < "$PEER_PROMPT_FILE" > "$GEMINI_OUT" 2>&1 || \
    echo "GEMINI_UNAVAILABLE" > "$GEMINI_OUT") &
  GEMINI_PID=$!

  wait $CODEX_PID $GEMINI_PID 2>/dev/null || true
  CODEX_CONTENT=$(cat "$CODEX_OUT")
  GEMINI_CONTENT=$(cat "$GEMINI_OUT")
  spinner_stop "Pass 2 complete"
else
  echo "  ⚡ Fast mode — peer review skipped" >&2
fi

# SYNTH_FINDINGS points to Claude's raw output for Voice RAG category detection.
# The actual merge (in normal mode) happens in the combined Pass 3+4 curl call below.
SYNTH_FINDINGS=$(mktemp -t "pr-${PR_NUMBER}-findings.XXXXXX")
cp "$CLAUDE_OUT" "$SYNTH_FINDINGS"

# ============================================================
# STEP 5: VOICE RAG — retrieve matching examples by category
# ============================================================
VOICE_JSONL="$HOME/.diffhound/voice-examples.jsonl"
VOICE_EXAMPLES_FILE=$(mktemp -t "pr-${PR_NUMBER}-voice.XXXXXX")

if [ -f "$VOICE_JSONL" ] && [ -s "$SYNTH_FINDINGS" ]; then
  echo "## REAL EXAMPLES — STUDY THESE CAREFULLY" >> "$VOICE_EXAMPLES_FILE"
  echo "" >> "$VOICE_EXAMPLES_FILE"
  echo "These are actual comments this engineer has written. Match this voice exactly." >> "$VOICE_EXAMPLES_FILE"
  echo "" >> "$VOICE_EXAMPLES_FILE"

  EXAMPLE_COUNT=0

  # Retrieve up to 2 examples per category using jq (safe JSON parsing, no Python spawn per line).
  # Uses process substitution (<()) to keep the while loop in the main shell scope —
  # avoids the subshell variable-scoping issue without a temp count file.
  # NOTE: grep on the raw JSONL is used purely to pre-filter candidate lines before jq parses them,
  # so we match on category/subcategory field values, not comment body text.
  add_examples_for_pattern() {
    local pattern="$1"
    local label="$2"
    [ "$EXAMPLE_COUNT" -ge 8 ] && return
    while IFS= read -r line; do
      [ "$EXAMPLE_COUNT" -ge 8 ] && break
      [ -z "$line" ] && continue
      cat_val=$(echo "$line" | jq -r '.category // ""' 2>/dev/null)
      subcat_val=$(echo "$line" | jq -r '.subcategory // ""' 2>/dev/null)
      comment_val=$(echo "$line" | jq -r '.comment // ""' 2>/dev/null)
      if [ -n "$comment_val" ]; then
        echo "---" >> "$VOICE_EXAMPLES_FILE"
        echo "EXAMPLE — ${label} (${cat_val}/${subcat_val}):" >> "$VOICE_EXAMPLES_FILE"
        echo "\"${comment_val}\"" >> "$VOICE_EXAMPLES_FILE"
        echo "" >> "$VOICE_EXAMPLES_FILE"
        EXAMPLE_COUNT=$((EXAMPLE_COUNT + 1))
      fi
    done < <(jq -c --arg pat "$pattern" 'select(.category | test($pat; "i") or .subcategory | test($pat; "i"))' "$VOICE_JSONL" 2>/dev/null | head -2)
  }

  # Priority order: security first, then data bugs, then URL/construction, then consistency, then nits
  add_examples_for_pattern "security" "security blocker"
  add_examples_for_pattern "data.bug|wrong.column|prod" "data bug"
  add_examples_for_pattern "url.construct|double.frag|param.collis" "URL construction"
  add_examples_for_pattern "consist|sibling" "consistency"
  add_examples_for_pattern "pattern.propag|lateral" "pattern propagation"
  add_examples_for_pattern "intent.check|assuming" "intent check"
  add_examples_for_pattern "test.gap|mock" "test gap"
  add_examples_for_pattern "nit|retract|self.retract" "nit/retraction"
  add_examples_for_pattern "re.review|still.open|author.wrong" "re-review"

  # Fallback: if no examples matched (empty findings or no JSONL hits), embed canonical examples inline
  if [ "$EXAMPLE_COUNT" -eq 0 ]; then
    cat >> "$VOICE_EXAMPLES_FILE" << 'FALLBACK_EXAMPLES'
---
EXAMPLE — security blocker:
"🔴 this is the user's full session token right? same one used in `validateToken` at line 206. passing it to an external embed means that app gets full user-level access to our API, not just the scoped endpoints.

couple of options:
1. generate a short-lived scoped token on backend specifically for embed operations (best option, most work)
2. at minimum, validate that `embedUrl` is a known/whitelisted URL before appending the token
3. if neither is feasible rn, add a comment explaining the trust assumption and create a follow-up ticket for scoped tokens

lmk what u think, happy to discuss"

---
EXAMPLE — data bug (blocking):
"🔴 `records.end_date` is NULL for every record in prod. expiry lives in `records.meta->>'endDate'` (JSONB) — that's what `types/record.ts:559` and the portal's `isActive()` both use. filter as written will silently exclude every item after deploy.

also — the test mock doesn't have `innerJoin` in `mockQueryChain`, so existing tests pass but none validate that expired records are actually excluded."

---
EXAMPLE — consistency nit:
"`user` object also has `firstName` and `lastName` (line 197 uses `displayName`). for consistency, might want to apply the same pattern there too"

FALLBACK_EXAMPLES
  fi

  echo "---" >> "$VOICE_EXAMPLES_FILE"
  VOICE_EXAMPLES_CONTENT=$(cat "$VOICE_EXAMPLES_FILE")
else
  # JSONL not available — use canonical fallback
  VOICE_EXAMPLES_CONTENT=$(cat << 'CANONICAL_FALLBACK'
## REAL EXAMPLES — STUDY THESE CAREFULLY

These are actual comments this engineer has written. Match this voice exactly.

---
EXAMPLE A — security blocker (large blast radius):
"🔴 this is the user's full session token right? same one used in `validateToken` at line 206. passing it to an external embed means that app gets full user-level access to our API, not just the scoped endpoints.

couple of options:
1. generate a short-lived scoped token on backend specifically for embed operations (best option, most work)
2. at minimum, validate that `embedUrl` is a known/whitelisted URL before appending the token — so a random URL in config can't harvest tokens
3. if neither is feasible rn, add a comment explaining the trust assumption and create a follow-up ticket for scoped tokens

lmk what u think, happy to discuss"

---
EXAMPLE B — subtle bug (URL construction):
"if `customUrl` already contains a hash fragment (like `https://app.example.com/page#sidebar=true`), this would produce a URL with two `#` symbols. browser parses only the first one, so the token appended after the second `#` gets silently ignored — the app won't be able to read it."

---
EXAMPLE C — consistency (sibling field):
"`user` object also has `firstName` and `lastName` (line 197 uses `displayName`). for consistency, might want to apply the same pattern there too"

---
EXAMPLE D — data bug (blocking):
"🔴 `records.end_date` is NULL for every record in prod. expiry lives in `records.meta->>'endDate'` (JSONB) — that's what `types/record.ts:559` and the portal's `isActive()` both use. filter as written will silently exclude every item after deploy."

---
EXAMPLE E — should-fix, missing test:
"no unit test covers the headless path that caused the original crash. the exact scenario — bulk upload via CLI with `ctx.user` null — needs a regression test. GWT: given a handler with headless context, when updateExistingClaim is called, then it should not throw TypeError. worth adding before this merges"

---
EXAMPLE F — nit, simplification:
"`(ctx && ctx.user?.isAdmin) || !ctx` can be simplified to `!ctx || ctx.user?.isAdmin`. the `ctx &&` prefix is redundant since `!ctx` already catches the falsy case. functionally identical, just easier to read"

---
CANONICAL_FALLBACK
)
fi

# ============================================================
# STEP 6: MERGE + STYLE REWRITE — single cached Haiku call
# Combines old Pass 3 (merge) + Pass 4 (style) into one API call.
# Static system prompt is cached via prompt-caching-2024-07-31 beta.
# ============================================================
_STYLE_PASS_NUM="${_TOTAL_PASSES}"
spinner_start "Writing review comments (pass ${_STYLE_PASS_NUM}/${_TOTAL_PASSES})..."

# ── Static system prompt (cached between calls — voice rules + output format) ─
read -r -d '' _STATIC_SYSTEM << 'STATIC_SYS_EOF' || true
You are a ghostwriter. You have engineering findings from a code analysis. Your job is to rewrite them as PR review comments that sound exactly like a specific engineer.

## WHO YOU ARE WRITING AS

This engineer is a senior developer reviewing a teammate's PR. Comments are developer-to-developer. Direct, casual, sharp. The author is a colleague, not a subordinate.

## VOICE RULES

ALWAYS:
- All lowercase body text. Code identifiers keep their original casing (`markTokenAsUsed`, `orgId`, etc).
- First-person framing: "my concern is —", "i want us to think about...", "assuming thats intentional —"
- Confirm reading before asserting: "this is the full login token right?" — shows you understood their code
- Reveal reasoning as you go — don't just state conclusions
- For blockers with tradeoffs: numbered options (1/2/3), acknowledge feasibility ("if not feasible rn...")
- End security/data blockers with "lmk what u think" or "happy to pair on this"
- Natural casual markers — but ONLY where they fit: "rn", "lmk", "thats", "its", "right?", "u can"
- For subtle bugs: dive straight into the observation — no formulaic opener
- For missed patterns: "same pattern you've done here in X" — reference where they did it right

NEVER — SEVERITY LABELS IN COMMENT BODY (THIS IS THE #1 MISTAKE):
- NEVER start a comment with "BLOCKING —", "BLOCKER —", "SHOULD-FIX —", "NIT —", or any severity word
- The severity word lives ONLY in the COMMENT: metadata tag (e.g., COMMENT: file.ts:10:BLOCKING — ...)
- The comment BODY starts directly with the observation — no label, no prefix, no badge
- Wrong: "BLOCKING — the guard here is too broad..."
- Wrong: "NIT — this could be simplified..."
- Right: "🔴 the guard here is too broad..."
- Right: "small thing — this could be simplified..."

NEVER — OTHER:
- "Why:", "Fix:", "Impact:" as explicit labels
- Capital letters at start of sentences (except "I" as a pronoun — but prefer lowercase alternatives)
- "leverage", "utilize", "ensure", "it is worth noting", "I'd recommend", "please consider", "going forward"
- Force "lmk" or "right?" onto every comment — only where they read naturally
- Numbered options on simple 1-fix comments
- "lmk" on a NIT — only on blockers with genuine discussion needed
- Mention AI, automated review, Claude, Codex, Gemini anywhere
- **markdown bold** or *italic* in comment body — GitHub renders it but it looks unnatural in casual dev voice. Plain text only.
- "one suggestion —", "small thing —", "one more thing —", "typo:", or any formulaic opener — dive straight into the observation
- Long run-on sentences — if a comment exceeds 4 lines, break it into short punchy paragraphs

HOW TO OPEN EACH SEVERITY — the key rule is: start with the SUBSTANCE, not a label announcing what type of problem it is.

- BLOCKING security/data bug → "🔴 [the actual observation directly]"
  WRONG: "🔴 security concern — the guard is too broad"  ← "security concern" is a label, not substance
  WRONG: "🔴 wrong column — `benefits.end_date` is NULL"  ← "wrong column" is a label
  RIGHT: "🔴 the `|| !ctx.user` check makes this fail-open. if ctx exists but user is null..."
  RIGHT: "🔴 `benefits.end_date` is NULL for every benefit in prod. policy expiry lives in..."
  RIGHT: "🔴 this is the user's full login token right? passing it to an external retool embed..."
  The 🔴 is just a visual flag. What follows is the observation itself — no category noun.
- BLOCKING scope/arch issue → "this feels unrelated to [PR title] — [explain the risk]"
- SHOULD-FIX → dive straight in, no opener at all
  e.g. "no unit test covers the headless path that caused the crash..."
  e.g. "the `ctx.user` null case falls through here — this whole block evaluates to false..."
- NIT → dive straight in, same as should-fix. no formulaic opener.
  e.g. "\`(ctx && ctx.user?.isAdmin) || !ctx\` can be simplified to \`!ctx || ctx.user?.isAdmin\`..."

CALIBRATE depth to blast radius:
- Big security/data bug → long comment, explain the attack path, give options, invite discussion
- Consistency nit → 1-2 sentences max, no fanfare
- Subtle bug → medium, explain the edge case naturally as you reason through it
- Unclear intent → short, non-accusatory, assume good intent ("assuming thats intentional —")

## REVIEW BODY STYLE

Opening: state the main blocker or overall verdict immediately. No "overall this looks good" fluff unless it's true.
Structure: verdict → blockers → should-fix → nit → brief genuine positive if warranted
Blockers: short bullets (file:line — what breaks)
Closing: one line genuine observation if warranted ("the approach is solid, just needs these fixed before merge")

## YOUR OUTPUT

### INLINE_COMMENTS_START
COMMENT: path/to/file.ts:LINE:SEVERITY — [full comment in engineer's voice, multi-line ok]
(preserve exact file paths and line numbers from findings verbatim — do NOT change or approximate line numbers)
REPLY: COMMENT_ID:path/to/file.ts:LINE — [reply to existing thread, if re-review]
### INLINE_COMMENTS_END

### SUMMARY_START
[review body — if re-review: open with which comments are now addressed vs still open, then any new issues]
[if fresh review: opening verdict, blockers, should-fix, brief genuine close]

## Scorecard
| Category | Score | Notes |
|----------|-------|-------|
| Security (25%) | X/25 | ... |
| Tests (20%) | X/20 | ... |
| Observability (10%) | X/10 | ... |
| Performance (15%) | X/15 | ... |
| Readability (15%) | X/15 | ... |
| Compatibility (15%) | X/15 | ... |
| **Total** | **X/100** | **VERDICT** (any BLOCKING → REQUEST_CHANGES, SHOULD-FIX only → COMMENT, NITs/clean → APPROVE) |

## Verification & Test Checklist
- [ ] [exact command or step]
### SUMMARY_END

NO VERIFICATION REQUESTS: Never output a comment asking the author to "verify", "check", "confirm", or "make sure" something. Either state it as fact (if determinable from the diff) or drop the comment entirely. The author already knows to verify uncertain things — your job is to tell them things they don't know.

CRITICAL: Never mention AI, Claude, Codex, Gemini, or any automated tool. The review must read as if written by the engineer themselves.
STATIC_SYS_EOF

# ── Dynamic user message (findings + examples — not cached) ───────────────────
_USER_TMP=$(mktemp -t "pr-${PR_NUMBER}-user.XXXXXX")

if [ "$FAST_MODE" = "true" ]; then
  _MERGE_INSTRUCTION="Here is one engineering analysis. Rewrite it in the engineer's voice using the rules above.

CRITICAL RULE — READ FIRST: Never start a comment body with a severity label. The word BLOCKING, BLOCKER, SHOULD-FIX, or NIT must NEVER appear at the start of a comment body. It belongs only in the COMMENT: metadata tag. Correct opener for a blocking bug: '🔴 [description]'. Correct opener for a nit: dive straight into the observation, no formulaic opener. Correct opener for a should-fix: dive straight into the observation."
else
  _MERGE_INSTRUCTION="Here are three engineering analyses. First merge them: use the highest severity where ≥2 models agree, discard speculative findings with no diff evidence, no attribution tags in output. Then rewrite the merged result in the engineer's voice.

CRITICAL RULE — READ FIRST: Never start a comment body with a severity label. The word BLOCKING, BLOCKER, SHOULD-FIX, or NIT must NEVER appear at the start of a comment body. It belongs only in the COMMENT: metadata tag. Correct opener for a blocking bug: '🔴 [description]'. Correct opener for a nit: dive straight into the observation, no formulaic opener. Correct opener for a should-fix: dive straight into the observation."
fi

{
  echo "$_MERGE_INSTRUCTION"
  echo ""
  echo "$VOICE_EXAMPLES_CONTENT"
  echo ""
  echo "## ENGINEERING FINDINGS (Claude)"
  cat "$CLAUDE_OUT"

  if [ "$FAST_MODE" != "true" ]; then
    if [ -n "$CODEX_CONTENT" ] && [ "$CODEX_CONTENT" != "CODEX_UNAVAILABLE" ]; then
      echo ""
      echo "## CODEX FINDINGS"
      echo "$CODEX_CONTENT"
    fi
    if [ -n "$GEMINI_CONTENT" ] && [ "$GEMINI_CONTENT" != "GEMINI_UNAVAILABLE" ]; then
      echo ""
      echo "## GEMINI FINDINGS"
      echo "$GEMINI_CONTENT"
    fi
  fi

  echo ""
  echo "## PR CONTEXT"
  echo "Title: ${PR_TITLE}"
  echo "Author: @${PR_AUTHOR}"
  echo "Files changed: ${FILE_COUNT} (+${ADDITIONS}/-${DELETIONS})"
  echo "Re-review mode: ${IS_REREVIEW}"

  if [ "$IS_REREVIEW" = true ]; then
    echo ""
    echo "## EXISTING THREAD STATUSES (from engineering pass)"
    grep -A6 "^THREAD_STATUS:" "$CLAUDE_OUT" 2>/dev/null || echo "none"
    echo ""
    cat << 'REREVIEW_BLOCK'
## HOW TO HANDLE THREAD REPLIES

For each thread with status STILL_OPEN or AUTHOR_WRONG:
- Write a REPLY comment addressing the author's response
- If STILL_OPEN: "hey, took another look — the concern is still there. [evidence]. [what still needs to happen]"
- If AUTHOR_WRONG: correct them clearly — "actually [explanation]. [correct explanation]"
- If RESOLVED: do NOT write a reply — silence = acknowledged

For THREAD_REPLY comments: REPLY: ORIGINAL_COMMENT_ID:path/to/file.ts:LINE — [reply in engineer's voice]

VOICE FOR REPLIES: same casual voice — "hey, took another look —", "actually —", "appreciate the context —"
If correcting: evidence first, tone stays collegial. Never snarky, never formal.
REREVIEW_BLOCK
  fi
} > "$_USER_TMP"

# ── Call API with prompt caching (only if API key has credits, else claude CLI) ─
# Test API key validity with a minimal call before committing to the full request.
_API_CALLED=false
_KEY_HAS_CREDITS=false
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  _TEST_RESP=$(curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
    2>/dev/null || echo "")
  if echo "$_TEST_RESP" | grep -q '"type":"message"'; then
    _KEY_HAS_CREDITS=true
  fi
fi
if [ "$_KEY_HAS_CREDITS" = "true" ]; then
  _JSON_TMP=$(mktemp -t "pr-${PR_NUMBER}-json.XXXXXX")
  jq -n \
    --arg system "$_STATIC_SYSTEM" \
    --rawfile user "$_USER_TMP" \
    '{
      model: "claude-haiku-4-5-20251001",
      max_tokens: 4096,
      system: [{type: "text", text: $system, cache_control: {type: "ephemeral"}}],
      messages: [{role: "user", content: $user}]
    }' > "$_JSON_TMP"

  _API_RESP=$(curl -sf https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d @"$_JSON_TMP" 2>/dev/null || echo "")
  rm -f "$_JSON_TMP"

  _REVIEW_TEXT=$(echo "$_API_RESP" | jq -r '.content[0].text // empty' 2>/dev/null || echo "")
  if [ -n "$_REVIEW_TEXT" ]; then
    echo "$_REVIEW_TEXT" > "$REVIEW_STRUCTURED"
    _API_CALLED=true
  fi
fi

if [ "$_API_CALLED" = false ]; then
  # Fallback: use claude CLI with Max subscription (unset API key so it doesn't fall back to pay-per-use)
  _SAVED_KEY2="${ANTHROPIC_API_KEY:-}"
  unset ANTHROPIC_API_KEY
  { echo "$_STATIC_SYSTEM"; echo ""; cat "$_USER_TMP"; } | \
    claude -p --model claude-haiku-4-5-20251001 > "$REVIEW_STRUCTURED" 2>&1 || \
    cp "$CLAUDE_OUT" "$REVIEW_STRUCTURED"
  export ANTHROPIC_API_KEY="$_SAVED_KEY2"
fi

rm -f "$_USER_TMP"

[ "$FAST_MODE" = "true" ] \
  && spinner_stop "Fast review complete" \
  || spinner_stop "Pass ${_STYLE_PASS_NUM} complete — review ready"

# Cleanup extra temp files
rm -f "${SYNTH_FINDINGS:-}" "${VOICE_EXAMPLES_FILE:-}" 2>/dev/null || true

# ============================================================
# PARSE OUTPUT
# ============================================================
parse_comments "$REVIEW_STRUCTURED" "${REVIEW_STRUCTURED}.comments"
parse_summary "$REVIEW_STRUCTURED" "$REVIEW_SUMMARY"

COMMENT_COUNT=$(grep -c "^COMMENT:" "${REVIEW_STRUCTURED}.comments" || true)
REPLY_COUNT_PREVIEW=$(grep -c "^REPLY:" "${REVIEW_STRUCTURED}.comments" || true)

echo ""
echo "──────────────────────────────────────────"
if [ "$IS_REREVIEW" = true ]; then
  echo "  Re-review: ${COMMENT_COUNT} new comment$([ "$COMMENT_COUNT" -ne 1 ] && echo 's' || true), ${REPLY_COUNT_PREVIEW} thread repl$([ "$REPLY_COUNT_PREVIEW" -ne 1 ] && echo 'ies' || echo 'y')"
else
  echo "  ${COMMENT_COUNT} inline comment$([ "$COMMENT_COUNT" -ne 1 ] && echo 's' || true)"
fi
echo "──────────────────────────────────────────"
cat "$REVIEW_SUMMARY"
echo "──────────────────────────────────────────"
echo ""

if [ "$COMMENT_COUNT" -gt 0 ] || [ "$REPLY_COUNT_PREVIEW" -gt 0 ]; then
  echo "📍 Comments Preview:"
  head -5 "${REVIEW_STRUCTURED}.comments"
  TOTAL=$((COMMENT_COUNT + REPLY_COUNT_PREVIEW))
  [ "$TOTAL" -gt 5 ] && echo "   ... and $((TOTAL - 5)) more"
  echo ""
fi

# ============================================================
# POST TO GITHUB
# ============================================================
if [ "$AUTO_POST" = true ]; then
  POST_REVIEW=true
elif [ ! -t 0 ]; then
  # No TTY (running in background/pipe) — skip posting, just show the review
  POST_REVIEW=false
else
  read -p "📤 Post this review to GitHub with inline comments? (y/n) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] && POST_REVIEW=true || POST_REVIEW=false
fi

if [ "$POST_REVIEW" = true ]; then
  spinner_start "Posting review to GitHub..."

  # Separate COMMENT: lines from REPLY: lines
  grep "^COMMENT:" "${REVIEW_STRUCTURED}.comments" | sed 's/^COMMENT: //' > "${REVIEW_STRUCTURED}.new_comments" || true
  grep "^REPLY:" "${REVIEW_STRUCTURED}.comments" | sed 's/^REPLY: //' > "${REVIEW_STRUCTURED}.replies" || true
  NEW_COMMENT_COUNT=$(wc -l < "${REVIEW_STRUCTURED}.new_comments" | tr -d ' ')
  REPLY_COUNT=$(wc -l < "${REVIEW_STRUCTURED}.replies" | tr -d ' ')

  # Parse verdict using lib function (3-method fallback)
  REVIEW_EVENT=$(parse_verdict "$REVIEW_SUMMARY" "${REVIEW_STRUCTURED}.new_comments")

  # Build the review JSON (new inline comments only)
  cat > "$REVIEW_JSON" << JSONSTART
{
  "commit_id": "$HEAD_SHA",
  "event": "$REVIEW_EVENT",
  "body": $(jq -Rs . < "$REVIEW_SUMMARY"),
  "comments": [
JSONSTART

  if [ "$NEW_COMMENT_COUNT" -gt 0 ]; then
    FIRST=true
    while IFS=: read -r filepath line rest; do
      [[ ! "$filepath" =~ ^[a-zA-Z0-9/_.-]+$ ]] && continue
      line="${line#\~}"
      [[ ! "$line" =~ ^[0-9]+$ ]] && continue
      line=$(snap_to_diff_line "$filepath" "$line" "$DIFF_FILE")
      comment=$(strip_severity_label "$rest")
      [ -z "$(printf '%s' "$comment" | tr -d '[:space:]')" ] && continue
      [ "$FIRST" = false ] && echo "," >> "$REVIEW_JSON"
      FIRST=false
      ESCAPED_COMMENT=$(printf '%s\n' "$comment" | jq -Rs .)
      cat >> "$REVIEW_JSON" << COMMENTJSON
    {
      "path": "$filepath",
      "line": $line,
      "body": $ESCAPED_COMMENT
    }
COMMENTJSON
    done < "${REVIEW_STRUCTURED}.new_comments"
  fi

  cat >> "$REVIEW_JSON" << JSONEND
  ]
}
JSONEND

  # Post review + inline comments (with fallback)
  post_review "$REPO_OWNER" "$REPO_NAME" "$PR_NUMBER" \
    "$HEAD_SHA" "$REVIEW_EVENT" "$REVIEW_SUMMARY" "$REVIEW_JSON" \
    "${REVIEW_STRUCTURED}.new_comments" "$DIFF_FILE"

  if [ "$_POSTED_OK" = true ]; then
    NEW_COMMENT_COUNT="${_FINAL_COMMENT_COUNT:-$NEW_COMMENT_COUNT}"

    # Post thread replies if any
    if [ "$REPLY_COUNT" -gt 0 ]; then
      REPLY_POSTED=$(post_thread_replies "$REPO_OWNER" "$REPO_NAME" "$PR_NUMBER" "${REVIEW_STRUCTURED}.replies")
      spinner_stop "Posted (${REVIEW_EVENT}, ${NEW_COMMENT_COUNT} new inline, ${REPLY_POSTED} thread replies)"
    else
      spinner_stop "Posted (${REVIEW_EVENT}, ${NEW_COMMENT_COUNT} inline)"
    fi
  fi

  echo ""
  echo "  → https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PR_NUMBER}"

  # Voice indexer — continuous learning from posted comments
  VOICE_JSONL_INDEX="$HOME/.diffhound/voice-examples.jsonl"
  INDEXED=$(index_voice_comments "${REVIEW_STRUCTURED}.new_comments" "$PR_NUMBER" "$VOICE_JSONL_INDEX")
  [ "$INDEXED" -gt 0 ] && echo "  📝 Indexed $INDEXED comments to voice RAG ($(wc -l < "$VOICE_JSONL_INDEX") total)"

  # Cleanup parse files
  rm -f "${REVIEW_STRUCTURED}.new_comments" "${REVIEW_STRUCTURED}.replies" 2>/dev/null || true
else
  echo "📋 Review not posted."
  echo "   Summary: $REVIEW_SUMMARY"
  echo "   Inline comments: ${REVIEW_STRUCTURED}.comments"
  trap - EXIT
fi
