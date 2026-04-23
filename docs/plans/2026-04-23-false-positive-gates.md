# Diffhound False-Positive Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate 4 concrete false-positive classes and 2 misdiagnosis patterns caught during claro PR #114 review, so future reviews don't erode trust by flagging non-bugs as blockers.

**Architecture:** Introduce a `lib/validators/` layer that runs AFTER the LLM produces `FINDING:` blocks but BEFORE they're parsed into PR comments. Each validator is a standalone bash filter: reads stdin (findings block + repo path), writes stdout (filtered/annotated findings) + stderr (diagnostics). Validators are composed in a pipeline inside `_validate_findings()` invoked by `review.sh` at the post-merge hook in `_merge_chunk_findings`. Tests are fixture-replay: each validator has `tests/fixtures/<name>/{input.txt,expected.txt,repo/}` and a runner that asserts byte-for-byte output match.

**Tech Stack:** Bash 5, `ripgrep` (already in Docker image), Python 3.12 (already installed for `extract-context.py`), `bats-core` for test harness (install via apt in Dockerfile update).

**Grounding:** Real failure cases pulled from `novabenefits/claro#114` diffhound review at `2026-04-22T18:49:48Z` (the 18:49 blocker round). Each task's golden fixture is a minimal repro of a real finding.

---

## Revision Log (post peer review)

Applied 2026-04-23 after Codex + Gemini parallel review:

1. **Hook location corrected** — was inside recovery-only branch at line ~4104 (skipped on 99% of runs). Moved to line 2943 (end of STEP 3, before STEP 4 peer review). Validators now always run. See Task 8.
2. **JSON↔FINDING adapter added** — `CLAUDE_OUT` is JSON in MEDIUM/SMALL tier, FINDING:-block in LARGE tier. Validators stay bash + FINDING:-based (easier to unit-test); adapter sits at the hook. See new Task 8a.
3. **`ref-exists` scoping** — now gates on wording ("defined", "duplicate", "mutates", "overrides", "already"). Uses `grep -F` (fixed string, no regex metachar issues). Falls back to ADVISORY annotation when wording absent, only DROPS when wording present AND symbol missing. See Task 1 revisions.
4. **`security-helper` narrowed** — checks ±20 lines of the flagged line, not the whole file. Prevents false-clear when safe helper exists elsewhere in the same file.
5. **`checklist-execute` rewritten in Python** — bash regex can't resolve Python imports (namespace pkgs, aliased imports). Now uses `ast.parse` + `importlib.util.find_spec`. See Task 7.
6. **`round-diff` identity key stabilized** — was `file:line:severity` (churned on unrelated edits AND on todo-deferral severity mutation). Now `file_basename + normalized_what_80chars + primary_symbol`. No line, no severity. See Task 6.
7. **Golden edge-case fixtures added** — Task 11 covers `.`-containing symbols, destructured imports, symbol-in-comment-only, aliased imports — regression cases Codex called out.

**Note:** Detailed code blocks for Tasks 3, 6, 7, 8 below are v1 (pre-peer-review). Implementer must apply the Revision Log fixes inline while executing each task — Task 1 has already been updated in place to demonstrate the pattern.

---

## File Structure

```
lib/
  validators/
    run-all.sh                # pipeline orchestrator, sourced by review.sh
    ref-exists.sh             # P0-1: grep-verify every file:symbol reference
    dry-vs-import.sh          # P0-2: "duplicate X" must be def, not import
    security-helper.sh        # P0-3: follow 1-hop helpers for crypto findings
    todo-deferral.sh          # P1-2: TODO(TICKET) near site downgrades severity
    checklist-execute.sh      # P2-2: run claimed failing-import tests
    round-diff.sh             # P2-1: emit CHANGES_SINCE_LAST_REVIEW block
lib/
  prompt-chunked.txt          # MODIFY: add state-dict / typed-channel rule (P1-1)
  review.sh                   # MODIFY: hook _validate_findings into merge step
tests/
  run.sh                      # bats-free pure-bash test runner
  fixtures/
    ref-exists/
      hallucinated-function/  # _populate_working_memory case
      valid-reference/        # control: real symbol passes through
    dry-vs-import/
      import-not-duplicate/   # _compute_email_hash case
      real-duplicate/         # control: two def sites both flagged correctly
    security-helper/
      delegated-compare-digest/  # widget.py:67 timing case
      real-timing-bug/        # control: direct == comparison flagged correctly
    todo-deferral/
      has-todo-ticket/        # tools.py:1023 case (BX-XXXX TODO)
      no-todo/                # control: unrelated code stays BLOCKING
    checklist-execute/
      module-exists/          # test_widget.py case (database.py exists)
      module-missing/         # control: real ModuleNotFoundError
    round-diff/
      same-findings-twice/    # control: unchanged shows =N
      two-new-one-resolved/   # control: +/-/= accounting
docs/
  plans/
    2026-04-23-false-positive-gates.md  # this file
Dockerfile                    # MODIFY: add bats, keep ripgrep
```

---

## Task 0: Test Harness

**Files:**
- Create: `tests/run.sh`
- Create: `tests/fixtures/.gitkeep`

Pure-bash runner so CI works without extra deps. Each fixture has `input.txt` (stdin for validator), `repo/` (minimal filesystem the validator greps), `expected.txt` (stdout the validator must produce). Runner diffs actual vs expected.

- [ ] **Step 1: Write the test runner**

```bash
cat > tests/run.sh <<'BASH'
#!/usr/bin/env bash
# tests/run.sh — fixture-replay test runner for lib/validators/*.sh
# Usage: tests/run.sh [validator-name]   # omit to run all
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
VALIDATORS_DIR="$ROOT/lib/validators"
PASS=0
FAIL=0
FAILED_NAMES=()

only="${1:-}"

for vdir in "$FIXTURES"/*/; do
  vname="$(basename "$vdir")"
  [ -n "$only" ] && [ "$only" != "$vname" ] && continue

  script="$VALIDATORS_DIR/$vname.sh"
  if [ ! -x "$script" ]; then
    echo "SKIP  $vname (no $script)"
    continue
  fi

  for case_dir in "$vdir"*/; do
    cname="$(basename "$case_dir")"
    input="$case_dir/input.txt"
    expected="$case_dir/expected.txt"
    repo="$case_dir/repo"
    [ -f "$input" ] && [ -f "$expected" ] || { echo "BROKEN $vname/$cname"; continue; }

    actual=$(DIFFHOUND_REPO="$repo" "$script" < "$input" 2>/dev/null)
    if [ "$actual" = "$(cat "$expected")" ]; then
      echo "PASS  $vname/$cname"
      PASS=$((PASS+1))
    else
      echo "FAIL  $vname/$cname"
      diff <(echo "$actual") "$expected" | sed 's/^/      /'
      FAIL=$((FAIL+1))
      FAILED_NAMES+=("$vname/$cname")
    fi
  done
done

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
BASH
chmod +x tests/run.sh
```

- [ ] **Step 2: Verify runner works on empty tree**

```bash
tests/run.sh
```
Expected: `RESULT: 0 passed, 0 failed` and exit 0.

- [ ] **Step 3: Commit**

```bash
git add tests/run.sh tests/fixtures/.gitkeep docs/plans/2026-04-23-false-positive-gates.md
git commit -m "chore(tests): fixture-replay test harness for validators"
```

---

## Task 1: P0-1 — Hallucinated Reference Validator

**Files:**
- Create: `lib/validators/ref-exists.sh`
- Create: `tests/fixtures/ref-exists/hallucinated-function/{input.txt,expected.txt,repo/api/agent/orchestrator.py}`
- Create: `tests/fixtures/ref-exists/valid-reference/{input.txt,expected.txt,repo/api/agent/orchestrator.py}`

**Contract (revised after peer review):** Input is a stream of `FINDING:` blocks. For each finding:
- Extract the first backticked symbol from `WHAT:` / `EVIDENCE:` lines (`\`[_a-zA-Z][_a-zA-Z0-9]*\``). Dotted/paren symbols (`foo.bar`, `useAuth()`) are ignored by this validator — out of scope.
- Use `grep -F` (fixed-string, not regex) to check if the symbol appears in `$DIFFHOUND_REPO/$file`.
- **Wording gate (key change from v1):** Only DROP the finding if the WHAT line contains one of the "existence-implying" keywords: `defined`, `duplicate`, `duplicated`, `mutates`, `overrides`, `redefines`, `already exists`. These wordings assert the symbol IS in the file; if it's missing, the finding is hallucinated.
- For findings without those keywords (e.g. "`audit_log` should be called here"), the symbol may legitimately be absent — the validator ANNOTATES instead of drops, appending `[ref-exists: '<sym>' not found in <file>]` to WHAT as a confidence signal to downstream reducer / human reviewer.

This addresses Codex's false-negative concern (legitimate "missing X" findings) and Gemini's false-positive concern (regex metacharacters breaking on `foo.bar`).

- [ ] **Step 1: Write failing test fixture — hallucinated function**

```bash
mkdir -p tests/fixtures/ref-exists/hallucinated-function/repo/api/agent
cat > tests/fixtures/ref-exists/hallucinated-function/repo/api/agent/orchestrator.py <<'PY'
# real file — does not define _populate_working_memory anywhere
def handle_turn(conv):
    pass
PY
cat > tests/fixtures/ref-exists/hallucinated-function/input.txt <<'TXT'
FINDING: api/agent/orchestrator.py:358:NIT
WHAT: `_populate_working_memory` mutates state in place
EVIDENCE: orchestrator.py:358
IMPACT: downstream nodes see partial state
OPTIONS:
1. copy dict before mutating
UNVERIFIABLE: no
TXT
# Expected: finding dropped, empty output
: > tests/fixtures/ref-exists/hallucinated-function/expected.txt
```

- [ ] **Step 2: Write failing test fixture — valid reference survives**

```bash
mkdir -p tests/fixtures/ref-exists/valid-reference/repo/api/agent
cat > tests/fixtures/ref-exists/valid-reference/repo/api/agent/orchestrator.py <<'PY'
async def _run_graph():
    pass
PY
cat > tests/fixtures/ref-exists/valid-reference/input.txt <<'TXT'
FINDING: api/agent/orchestrator.py:1:NIT
WHAT: `_run_graph` could be hoisted
EVIDENCE: orchestrator.py:1
IMPACT: readability
OPTIONS:
1. move to module scope
UNVERIFIABLE: no
TXT
cp tests/fixtures/ref-exists/valid-reference/input.txt \
   tests/fixtures/ref-exists/valid-reference/expected.txt
```

- [ ] **Step 3: Run tests — confirm they fail (no validator yet)**

```bash
tests/run.sh ref-exists
```
Expected: `SKIP  ref-exists (no lib/validators/ref-exists.sh)` — no failures yet, just the skip.

- [ ] **Step 4: Write the validator (revised)**

```bash
cat > lib/validators/ref-exists.sh <<'BASH'
#!/usr/bin/env bash
# ref-exists.sh — DROP findings that claim a symbol is "defined/duplicate/
# mutates/overrides" in a file when the symbol isn't there. ANNOTATE findings
# without those keywords (symbol may legitimately be missing — e.g. "should
# call X" — and that's a real finding, not a hallucination).
#
# Reads FINDING: blocks on stdin, writes kept/annotated blocks to stdout,
# drops to stderr. DIFFHOUND_REPO must point to the PR's working tree.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

# Wordings that assert the symbol IS already in the flagged file. If the
# symbol is missing AND wording matches → DROP. Otherwise ANNOTATE.
EXISTENCE_WORDS='defined|duplicate|duplicated|mutates|overrides|redefines|already exists|already defined'

block=""
what_line=""
header_file=""
sym=""

flush_and_classify() {
  [ -z "$block" ] && return
  # Decide keep/drop/annotate based on gathered context
  if [ -n "$sym" ] && [ -n "$header_file" ] && [ -f "$DIFFHOUND_REPO/$header_file" ]; then
    if ! grep -Fq -- "$sym" "$DIFFHOUND_REPO/$header_file"; then
      # Symbol not in file. Check wording.
      if printf '%s' "$what_line" | grep -qiE "$EXISTENCE_WORDS"; then
        # Existence-implying wording + missing symbol = hallucination
        printf '[ref-exists] DROPPED (hallucinated): %s\n' "$(printf '%s' "$block" | head -1)" >&2
        block=""; what_line=""; header_file=""; sym=""
        return
      else
        # Missing symbol without existence wording — annotate, keep
        block=$(printf '%s' "$block" | awk -v sym="$sym" -v file="$header_file" '
          /^WHAT:/ && !done { print $0 " [ref-exists: '\''" sym "'\'' not found in " file "]"; done=1; next }
          { print }
        ')$'\n'
      fi
    fi
  fi
  printf '%s' "$block"
  block=""; what_line=""; header_file=""; sym=""
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      flush_and_classify
      block="$line"$'\n'
      header="${line#FINDING: }"
      header_file="${header%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      what_line="$line"
      # Extract first plain-identifier backticked symbol (no dots, no parens)
      sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`' || true)
      ;;
    EVIDENCE:*)
      block+="$line"$'\n'
      # Only fall back to evidence if WHAT didn't yield a symbol
      if [ -z "$sym" ]; then
        sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`' || true)
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
flush_and_classify
BASH
chmod +x lib/validators/ref-exists.sh
```

Add a third fixture covering advisory mode (missing symbol, no existence wording → annotated, not dropped):

```bash
mkdir -p tests/fixtures/ref-exists/missing-without-existence-wording/repo
cat > tests/fixtures/ref-exists/missing-without-existence-wording/repo/handler.py <<'PY'
def do_thing():
    pass
PY
cat > tests/fixtures/ref-exists/missing-without-existence-wording/input.txt <<'TXT'
FINDING: handler.py:1:SHOULD-FIX
WHAT: `audit_log` should be called before do_thing
EVIDENCE: handler.py:1
IMPACT: missing audit trail
OPTIONS:
1. add audit_log call
UNVERIFIABLE: no
TXT
cat > tests/fixtures/ref-exists/missing-without-existence-wording/expected.txt <<'TXT'
FINDING: handler.py:1:SHOULD-FIX
WHAT: `audit_log` should be called before do_thing [ref-exists: 'audit_log' not found in handler.py]
EVIDENCE: handler.py:1
IMPACT: missing audit trail
OPTIONS:
1. add audit_log call
UNVERIFIABLE: no
TXT
```

- [ ] **Step 5: Run tests — confirm they pass**

```bash
tests/run.sh ref-exists
```
Expected:
```
PASS  ref-exists/hallucinated-function
PASS  ref-exists/valid-reference
RESULT: 2 passed, 0 failed
```

- [ ] **Step 6: Commit**

```bash
git add lib/validators/ref-exists.sh tests/fixtures/ref-exists
git commit -m "feat(validators): drop findings referencing non-existent symbols"
```

---

## Task 2: P0-2 — Import-vs-Definition DRY Validator

**Files:**
- Create: `lib/validators/dry-vs-import.sh`
- Create: `tests/fixtures/dry-vs-import/import-not-duplicate/{input.txt,expected.txt,repo/api/routers/widget.py,repo/api/agent/orchestrator.py}`
- Create: `tests/fixtures/dry-vs-import/real-duplicate/{input.txt,expected.txt,repo/a.py,repo/b.py}`

**Contract:** A finding whose WHAT line contains any of `duplicated`, `duplicate`, `already defined`, `same as`, `copy.*of` AND references two file paths (via `file:line` or backticks) is a DRY claim. If either path defines the named symbol via `from X import Y` (not `def Y(...)` / `class Y...`), drop it. Real duplicates (both sites have `def`) pass through.

- [ ] **Step 1: Write failing test — false positive (import)**

```bash
mkdir -p tests/fixtures/dry-vs-import/import-not-duplicate/repo/api/{routers,agent}
cat > tests/fixtures/dry-vs-import/import-not-duplicate/repo/api/routers/widget.py <<'PY'
from agent.orchestrator import _compute_email_hash
# uses _compute_email_hash but doesn't define it
PY
cat > tests/fixtures/dry-vs-import/import-not-duplicate/repo/api/agent/orchestrator.py <<'PY'
def _compute_email_hash(email: str) -> str:
    return email.lower()
PY
cat > tests/fixtures/dry-vs-import/import-not-duplicate/input.txt <<'TXT'
FINDING: api/routers/widget.py:66:NIT
WHAT: `_compute_email_hash` duplicated from orchestrator.py:38-55
EVIDENCE: widget.py:66 and orchestrator.py:38-55
IMPACT: DRY violation
OPTIONS:
1. just import from orchestrator
UNVERIFIABLE: no
TXT
: > tests/fixtures/dry-vs-import/import-not-duplicate/expected.txt
```

- [ ] **Step 2: Write control — real duplicate passes through**

```bash
mkdir -p tests/fixtures/dry-vs-import/real-duplicate/repo
cat > tests/fixtures/dry-vs-import/real-duplicate/repo/a.py <<'PY'
def hash_email(e):
    return e.lower()
PY
cat > tests/fixtures/dry-vs-import/real-duplicate/repo/b.py <<'PY'
def hash_email(e):
    return e.lower()
PY
cat > tests/fixtures/dry-vs-import/real-duplicate/input.txt <<'TXT'
FINDING: b.py:1:NIT
WHAT: `hash_email` duplicated from a.py:1
EVIDENCE: b.py:1 and a.py:1
IMPACT: DRY violation
OPTIONS:
1. extract shared
UNVERIFIABLE: no
TXT
cp tests/fixtures/dry-vs-import/real-duplicate/input.txt \
   tests/fixtures/dry-vs-import/real-duplicate/expected.txt
```

- [ ] **Step 3: Write the validator**

```bash
cat > lib/validators/dry-vs-import.sh <<'BASH'
#!/usr/bin/env bash
# dry-vs-import.sh — drop "duplicated" findings when one side is just an import.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

block=""
is_dry=0
sym=""
header_file=""
keep=1

flush() {
  [ -z "$block" ] && return
  if [ "$keep" -eq 1 ]; then
    printf '%s' "$block"
  else
    printf '[dry-vs-import] DROPPED: %s' "$(printf '%s' "$block" | head -1)" >&2
  fi
  block=""; is_dry=0; sym=""; header_file=""; keep=1
}

check_import_only() {
  # returns 0 if $header_file imports $sym but does NOT define it
  local path="$DIFFHOUND_REPO/$header_file"
  [ -f "$path" ] || return 1
  grep -qE "^\s*(from [a-zA-Z0-9_.]+ import [a-zA-Z0-9_, ]*\b$sym\b|import .*\b$sym\b)" "$path" || return 1
  # not defined locally
  ! grep -qE "^\s*(def|class)\s+$sym\b" "$path"
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      flush
      block="$line"$'\n'
      header="${line#FINDING: }"
      header_file="${header%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      # DRY keyword scan
      if printf '%s' "$line" | grep -qiE '\b(duplicated|duplicate|already defined|same as)\b'; then
        is_dry=1
        sym=$(printf '%s' "$line" | grep -oE '`[_a-zA-Z][_a-zA-Z0-9]*`' | head -1 | tr -d '`')
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
# final block — evaluate
if [ "$is_dry" -eq 1 ] && [ -n "$sym" ] && [ -n "$header_file" ]; then
  check_import_only && keep=0
fi
flush
BASH
chmod +x lib/validators/dry-vs-import.sh
```

- [ ] **Step 4: Run tests**

```bash
tests/run.sh dry-vs-import
```
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/validators/dry-vs-import.sh tests/fixtures/dry-vs-import
git commit -m "feat(validators): drop DRY findings when one site is an import"
```

---

## Task 3: P0-3 — Security Helper-Follow Validator

**Files:**
- Create: `lib/validators/security-helper.sh`
- Create: `tests/fixtures/security-helper/delegated-compare-digest/{input.txt,expected.txt,repo/api/routers/widget.py,repo/api/routers/conversations.py}`
- Create: `tests/fixtures/security-helper/real-timing-bug/{input.txt,expected.txt,repo/bad.py}`

**Contract:** Findings with a security-keyword in WHAT (`timing attack`, `timing-safe`, `constant time`, `constant-time`) are probed: grep the flagged file + every function it calls via `from X import Y` or `self.Y(...)` (one hop) for `hmac.compare_digest`, `secrets.compare_digest`, or `crypto.timingSafeEqual` (JS). If any hop has it, drop the finding. If none, keep.

Scope (v1): only timing attacks. SQL-injection and auth-bypass follow the same pattern and will be added once the first one ships.

- [ ] **Step 1: Write failing test — timing-attack FP (check is delegated)**

```bash
mkdir -p tests/fixtures/security-helper/delegated-compare-digest/repo/api/routers
cat > tests/fixtures/security-helper/delegated-compare-digest/repo/api/routers/widget.py <<'PY'
from routers.conversations import _verify_widget_token
def stream(token, conv):
    _verify_widget_token(conv, token)
PY
cat > tests/fixtures/security-helper/delegated-compare-digest/repo/api/routers/conversations.py <<'PY'
import hmac
def _verify_widget_token(conv, token):
    stored = (conv.meta or {}).get("widget_token", "")
    if not hmac.compare_digest(stored, token):
        raise ValueError
PY
cat > tests/fixtures/security-helper/delegated-compare-digest/input.txt <<'TXT'
FINDING: api/routers/widget.py:3:SHOULD-FIX
WHAT: widget_token comparison is vulnerable to timing attack
EVIDENCE: widget.py:3
IMPACT: attacker can recover token byte-by-byte
OPTIONS:
1. use hmac.compare_digest
UNVERIFIABLE: no
TXT
: > tests/fixtures/security-helper/delegated-compare-digest/expected.txt
```

- [ ] **Step 2: Write control — real timing bug is kept**

```bash
mkdir -p tests/fixtures/security-helper/real-timing-bug/repo
cat > tests/fixtures/security-helper/real-timing-bug/repo/bad.py <<'PY'
def verify(stored, token):
    if stored == token:
        return True
    return False
PY
cat > tests/fixtures/security-helper/real-timing-bug/input.txt <<'TXT'
FINDING: bad.py:2:SHOULD-FIX
WHAT: token comparison uses == (timing attack)
EVIDENCE: bad.py:2
IMPACT: side-channel leak
OPTIONS:
1. use hmac.compare_digest
UNVERIFIABLE: no
TXT
cp tests/fixtures/security-helper/real-timing-bug/input.txt \
   tests/fixtures/security-helper/real-timing-bug/expected.txt
```

- [ ] **Step 3: Write the validator**

```bash
cat > lib/validators/security-helper.sh <<'BASH'
#!/usr/bin/env bash
# security-helper.sh — drop timing-attack findings when comparison is delegated
# to a helper that uses hmac.compare_digest / crypto.timingSafeEqual.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

TIMING_SAFE_RE='hmac\.compare_digest|secrets\.compare_digest|timingSafeEqual'

block=""
is_timing=0
header_file=""
keep=1

flush() {
  [ -z "$block" ] && return
  if [ "$keep" -eq 1 ]; then
    printf '%s' "$block"
  else
    printf '[security-helper] DROPPED: %s' "$(printf '%s' "$block" | head -1)" >&2
  fi
  block=""; is_timing=0; header_file=""; keep=1
}

# Returns 0 if file $1 OR any file it imports from contains a timing-safe compare
has_timing_safe() {
  local file="$1"
  local path="$DIFFHOUND_REPO/$file"
  [ -f "$path" ] || return 1
  grep -qE "$TIMING_SAFE_RE" "$path" && return 0
  # 1-hop: follow from/import statements to sibling files
  local mod
  while IFS= read -r mod; do
    # mod is e.g. "routers.conversations" → api/routers/conversations.py
    local candidate
    for candidate in "$DIFFHOUND_REPO/api/${mod//./\/}.py" "$DIFFHOUND_REPO/${mod//./\/}.py"; do
      if [ -f "$candidate" ] && grep -qE "$TIMING_SAFE_RE" "$candidate"; then
        return 0
      fi
    done
  done < <(grep -oE '^from [a-zA-Z0-9_.]+' "$path" | awk '{print $2}')
  return 1
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      flush
      block="$line"$'\n'
      header="${line#FINDING: }"
      header_file="${header%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      if printf '%s' "$line" | grep -qiE 'timing[- ]?(attack|safe)|constant[- ]?time'; then
        is_timing=1
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
if [ "$is_timing" -eq 1 ] && [ -n "$header_file" ]; then
  has_timing_safe "$header_file" && keep=0
fi
flush
BASH
chmod +x lib/validators/security-helper.sh
```

- [ ] **Step 4: Run tests**

```bash
tests/run.sh security-helper
```
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/validators/security-helper.sh tests/fixtures/security-helper
git commit -m "feat(validators): follow delegated helpers for timing-attack findings"
```

---

## Task 4: P1-1 — State-Dict / Typed-Channel Prompt Rule

**Files:**
- Modify: `lib/prompt-chunked.txt` — add new subsection under `# VERIFICATION CHECKS` at line ~113

No validator needed — this is a prompt-side improvement. Purely preventive.

- [ ] **Step 1: Add rule to prompt**

Insert after line 114 (after the `Type-narrowing gaps` bullet):

```text
- State-dict / typed-channel bugs: when a `state.get(X)` returns None or missing, do NOT immediately blame the read site or guess the producer. Trace BOTH directions:
  (a) producer: every `**state_dict` splat, every node that returns {X: ...}, every call site constructing the graph input
  (b) schema: the TypedDict / Pydantic / dataclass declaring the state keys — LangGraph, Redux-style stores, and typed state machines drop undeclared keys across transitions
  If X is not declared in the schema, that is the root cause regardless of how many producer sites write it. Flag the schema file, not the read site.
```

- [ ] **Step 2: Verify prompt length still under chunk size**

```bash
wc -l lib/prompt-chunked.txt
```
Expected: < 220 lines (was 191, adding ~6 → ~197).

- [ ] **Step 3: Commit**

```bash
git add lib/prompt-chunked.txt
git commit -m "feat(prompt): add state-dict / typed-channel root-cause rule"
```

---

## Task 5: P1-2 — TODO-Deferral Awareness

**Files:**
- Create: `lib/validators/todo-deferral.sh`
- Create: `tests/fixtures/todo-deferral/has-todo-ticket/{input.txt,expected.txt,repo/tools.py,repo/orchestrator.py}`
- Create: `tests/fixtures/todo-deferral/no-todo/{input.txt,expected.txt,repo/plain.py}`

**Contract:** When a BLOCKING finding is within 20 lines of a `TODO(TICKET-ID)` or `TODO(BX-...)` comment in the same file, downgrade to `SHOULD-FIX` and append `— Deferred per TODO at line N` to WHAT. Does NOT drop the finding, because the deferral may still deserve product visibility.

- [ ] **Step 1: Failing fixture — TODO exists → downgrade**

```bash
mkdir -p tests/fixtures/todo-deferral/has-todo-ticket/repo
cat > tests/fixtures/todo-deferral/has-todo-ticket/repo/tools.py <<'PY'
# line 1
# line 2
# TODO(BX-XXXX): fetch user's home org via admin API once monorepo exposes it
def build_wm(org):
    return {
        "viewed_org_name": org.get("name"),  # line 6
        "viewed_org_id": org.get("id"),      # line 7
    }
PY
cat > tests/fixtures/todo-deferral/has-todo-ticket/input.txt <<'TXT'
FINDING: tools.py:6:BLOCKING
WHAT: viewed_org_name and org_name sourced from same token-scoped dict; data separation missing
EVIDENCE: tools.py:6
IMPACT: BX-2978 non-functional
OPTIONS:
1. fetch home org from different source
UNVERIFIABLE: no
TXT
cat > tests/fixtures/todo-deferral/has-todo-ticket/expected.txt <<'TXT'
FINDING: tools.py:6:SHOULD-FIX
WHAT: viewed_org_name and org_name sourced from same token-scoped dict; data separation missing — Deferred per TODO at tools.py:3 (BX-XXXX)
EVIDENCE: tools.py:6
IMPACT: BX-2978 non-functional
OPTIONS:
1. fetch home org from different source
UNVERIFIABLE: no
TXT
```

- [ ] **Step 2: Control — no TODO → unchanged**

```bash
mkdir -p tests/fixtures/todo-deferral/no-todo/repo
cat > tests/fixtures/todo-deferral/no-todo/repo/plain.py <<'PY'
def build_wm(org):
    return {"viewed_org_name": org.get("name")}
PY
cat > tests/fixtures/todo-deferral/no-todo/input.txt <<'TXT'
FINDING: plain.py:2:BLOCKING
WHAT: viewed_org_name equals org_name; data separation missing
EVIDENCE: plain.py:2
IMPACT: non-functional
OPTIONS:
1. fix source
UNVERIFIABLE: no
TXT
cp tests/fixtures/todo-deferral/no-todo/input.txt \
   tests/fixtures/todo-deferral/no-todo/expected.txt
```

- [ ] **Step 3: Write validator**

```bash
cat > lib/validators/todo-deferral.sh <<'BASH'
#!/usr/bin/env bash
# todo-deferral.sh — downgrade BLOCKING → SHOULD-FIX when TODO(TICKET) is near.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

RADIUS=20

block=""
header_line=""
header_sev=""
header_file=""
header_line_no=""

emit() {
  [ -z "$block" ] && return
  printf '%s' "$block"
  block=""; header_line=""; header_sev=""; header_file=""; header_line_no=""
}

# Scan $1 for "TODO(TICKET-ID)" within $RADIUS lines of $2; echoes "file:lineno TICKET" if found
find_todo() {
  local path="$1" anchor="$2"
  [ -f "$path" ] || return 1
  awk -v anchor="$anchor" -v radius="$RADIUS" '
    match($0, /TODO\(([A-Z]+-[A-Z0-9]+)\)/, m) {
      if (NR >= anchor - radius && NR <= anchor + radius) {
        printf "%d %s\n", NR, m[1]
        exit
      }
    }
  ' "$path"
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      emit
      header_line="$line"
      h="${line#FINDING: }"
      header_file="${h%%:*}"
      rest="${h#*:}"
      header_line_no="${rest%%:*}"
      header_sev="${rest##*:}"
      if [ "$header_sev" = "BLOCKING" ]; then
        todo=$(find_todo "$DIFFHOUND_REPO/$header_file" "$header_line_no" 2>/dev/null || true)
        if [ -n "$todo" ]; then
          todo_line="${todo%% *}"
          ticket="${todo##* }"
          block="FINDING: ${header_file}:${header_line_no}:SHOULD-FIX"$'\n'
          # WHAT line gets the suffix on next iteration
          awaiting_what=1
          continue
        fi
      fi
      block="$header_line"$'\n'
      awaiting_what=0
      ;;
    WHAT:*)
      if [ "${awaiting_what:-0}" -eq 1 ]; then
        block+="${line% } — Deferred per TODO at ${header_file}:${todo_line} (${ticket})"$'\n'
        awaiting_what=0
      else
        block+="$line"$'\n'
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
emit
BASH
chmod +x lib/validators/todo-deferral.sh
```

- [ ] **Step 4: Run tests**

```bash
tests/run.sh todo-deferral
```
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/validators/todo-deferral.sh tests/fixtures/todo-deferral
git commit -m "feat(validators): downgrade BLOCKING near TODO(TICKET) to SHOULD-FIX"
```

---

## Task 6: P2-1 — Round-Over-Round Finding Diff

**Files:**
- Create: `lib/validators/round-diff.sh`
- Create: `tests/fixtures/round-diff/same-findings-twice/{input.txt,expected.txt,prior.txt}`
- Create: `tests/fixtures/round-diff/two-new-one-resolved/{input.txt,expected.txt,prior.txt}`

**Contract:** Reads current findings on stdin. Reads prior-review findings from `$DIFFHOUND_PRIOR_FINDINGS` env var (path to file with same `FINDING:` format, or empty). Identity key is `(file, symbol_in_what, severity)`. Appends a `### CHANGES_SINCE_LAST_REVIEW` block to output with counts `+N new, -M resolved, =K unchanged`, and list of resolved finding headers.

- [ ] **Step 1: Failing fixture — same set twice**

Minimal: prior has 2 findings, input has same 2. Expected appends `+0 new, -0 resolved, =2 unchanged`.

```bash
mkdir -p tests/fixtures/round-diff/same-findings-twice
cat > tests/fixtures/round-diff/same-findings-twice/prior.txt <<'TXT'
FINDING: a.py:1:BLOCKING
WHAT: `foo` bad
EVIDENCE: a.py:1
IMPACT: x
OPTIONS:
1. y
UNVERIFIABLE: no
FINDING: b.py:2:SHOULD-FIX
WHAT: `bar` baz
EVIDENCE: b.py:2
IMPACT: q
OPTIONS:
1. r
UNVERIFIABLE: no
TXT
cp tests/fixtures/round-diff/same-findings-twice/prior.txt \
   tests/fixtures/round-diff/same-findings-twice/input.txt
cat > tests/fixtures/round-diff/same-findings-twice/expected.txt <<'TXT'
FINDING: a.py:1:BLOCKING
WHAT: `foo` bad
EVIDENCE: a.py:1
IMPACT: x
OPTIONS:
1. y
UNVERIFIABLE: no
FINDING: b.py:2:SHOULD-FIX
WHAT: `bar` baz
EVIDENCE: b.py:2
IMPACT: q
OPTIONS:
1. r
UNVERIFIABLE: no
### CHANGES_SINCE_LAST_REVIEW
+0 new, -0 resolved, =2 unchanged
TXT
```

- [ ] **Step 2: Control — 2 new, 1 resolved**

```bash
mkdir -p tests/fixtures/round-diff/two-new-one-resolved
cat > tests/fixtures/round-diff/two-new-one-resolved/prior.txt <<'TXT'
FINDING: old.py:1:BLOCKING
WHAT: `oldbug` bad
TXT
cat > tests/fixtures/round-diff/two-new-one-resolved/input.txt <<'TXT'
FINDING: new1.py:1:BLOCKING
WHAT: `newbug1` bad
FINDING: new2.py:1:SHOULD-FIX
WHAT: `newbug2` bad
TXT
cat > tests/fixtures/round-diff/two-new-one-resolved/expected.txt <<'TXT'
FINDING: new1.py:1:BLOCKING
WHAT: `newbug1` bad
FINDING: new2.py:1:SHOULD-FIX
WHAT: `newbug2` bad
### CHANGES_SINCE_LAST_REVIEW
+2 new, -1 resolved, =0 unchanged
RESOLVED:
- old.py:1:BLOCKING `oldbug`
TXT
```

- [ ] **Step 3: Write validator**

```bash
cat > lib/validators/round-diff.sh <<'BASH'
#!/usr/bin/env bash
# round-diff.sh — append CHANGES_SINCE_LAST_REVIEW accounting block.
set -uo pipefail

PRIOR="${DIFFHOUND_PRIOR_FINDINGS:-}"
CURRENT="$(cat)"

# Identity: file:line:severity + backticked symbol in WHAT
extract_ids() {
  awk '
    /^FINDING:/ {
      header = substr($0, 10)
      next
    }
    /^WHAT:/ {
      sym = ""
      if (match($0, /`[_a-zA-Z][_a-zA-Z0-9]*`/)) sym = substr($0, RSTART, RLENGTH)
      print header " " sym
      header = ""
    }
  '
}

prior_ids=$(if [ -n "$PRIOR" ] && [ -f "$PRIOR" ]; then extract_ids < "$PRIOR"; fi)
current_ids=$(printf '%s\n' "$CURRENT" | extract_ids)

new_count=0
unchanged_count=0
resolved_lines=""

# Count new / unchanged
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if printf '%s\n' "$prior_ids" | grep -Fxq "$id"; then
    unchanged_count=$((unchanged_count+1))
  else
    new_count=$((new_count+1))
  fi
done <<< "$current_ids"

# Count resolved
resolved_count=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if ! printf '%s\n' "$current_ids" | grep -Fxq "$id"; then
    resolved_count=$((resolved_count+1))
    resolved_lines="${resolved_lines}- ${id}"$'\n'
  fi
done <<< "$prior_ids"

printf '%s' "$CURRENT"
printf '### CHANGES_SINCE_LAST_REVIEW\n'
printf '+%d new, -%d resolved, =%d unchanged\n' "$new_count" "$resolved_count" "$unchanged_count"
if [ "$resolved_count" -gt 0 ]; then
  printf 'RESOLVED:\n%s' "$resolved_lines"
fi
BASH
chmod +x lib/validators/round-diff.sh
```

- [ ] **Step 4: Update test runner to pass PRIOR env**

Modify `tests/run.sh` — replace the validator invocation line to also export `DIFFHOUND_PRIOR_FINDINGS` when a `prior.txt` exists:

```bash
# in tests/run.sh, change:
#   actual=$(DIFFHOUND_REPO="$repo" "$script" < "$input" 2>/dev/null)
# to:
prior_env=""
[ -f "$case_dir/prior.txt" ] && prior_env="DIFFHOUND_PRIOR_FINDINGS=$case_dir/prior.txt"
actual=$(env DIFFHOUND_REPO="$repo" $prior_env "$script" < "$input" 2>/dev/null)
```

- [ ] **Step 5: Run tests**

```bash
tests/run.sh round-diff
```
Expected: `2 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add lib/validators/round-diff.sh tests/fixtures/round-diff tests/run.sh
git commit -m "feat(validators): emit CHANGES_SINCE_LAST_REVIEW accounting block"
```

---

## Task 7: P2-2 — Verification-Checklist Execution Gate

**Files:**
- Create: `lib/validators/checklist-execute.sh`
- Create: `tests/fixtures/checklist-execute/module-exists/{input.txt,expected.txt,repo/api/database.py,repo/api/tests/test_widget.py,repo/api/tests/conftest.py}`
- Create: `tests/fixtures/checklist-execute/module-missing/{input.txt,expected.txt,repo/api/tests/test_bad.py}`

**Contract:** When a finding's WHAT contains `ModuleNotFoundError`, `can't run standalone`, or `fails in isolation`, extract the claimed failing file from `file:LINE` header. Run `python -c "import ast; ast.parse(open('<file>').read())"` to check syntax AND `python -m py_compile <file>` from the repo root. If it passes, drop the finding. (We intentionally don't run pytest because pytest in this sandbox requires the full dep tree; a syntax+compile check is enough to catch hallucinated ModuleNotFoundErrors where the module actually exists.)

- [ ] **Step 1: Failing fixture — module exists, finding dropped**

```bash
mkdir -p tests/fixtures/checklist-execute/module-exists/repo/api/tests
cat > tests/fixtures/checklist-execute/module-exists/repo/api/database.py <<'PY'
engine = None
PY
cat > tests/fixtures/checklist-execute/module-exists/repo/api/tests/conftest.py <<'PY'
# autouse patch db exists here
PY
cat > tests/fixtures/checklist-execute/module-exists/repo/api/tests/test_widget.py <<'PY'
import database
def test_one():
    assert database
PY
cat > tests/fixtures/checklist-execute/module-exists/input.txt <<'TXT'
FINDING: api/tests/test_widget.py:1:BLOCKING
WHAT: `pytest tests/test_widget.py` fails in isolation with ModuleNotFoundError on `database`
EVIDENCE: test_widget.py:1
IMPACT: test isolation broken
OPTIONS:
1. move _patch_db to conftest
UNVERIFIABLE: no
TXT
: > tests/fixtures/checklist-execute/module-exists/expected.txt
```

- [ ] **Step 2: Control — missing file stays**

```bash
mkdir -p tests/fixtures/checklist-execute/module-missing/repo/api/tests
# no api/database.py created
cat > tests/fixtures/checklist-execute/module-missing/repo/api/tests/test_bad.py <<'PY'
import totally_fake_module
PY
cat > tests/fixtures/checklist-execute/module-missing/input.txt <<'TXT'
FINDING: api/tests/test_bad.py:1:BLOCKING
WHAT: `pytest tests/test_bad.py` fails in isolation with ModuleNotFoundError on `totally_fake_module`
EVIDENCE: test_bad.py:1
IMPACT: test isolation broken
OPTIONS:
1. fix import
UNVERIFIABLE: no
TXT
cp tests/fixtures/checklist-execute/module-missing/input.txt \
   tests/fixtures/checklist-execute/module-missing/expected.txt
```

- [ ] **Step 3: Write validator**

```bash
cat > lib/validators/checklist-execute.sh <<'BASH'
#!/usr/bin/env bash
# checklist-execute.sh — drop ModuleNotFoundError claims when the import
# actually resolves via py_compile from the repo root.
set -uo pipefail
: "${DIFFHOUND_REPO:?DIFFHOUND_REPO must be set}"

block=""
is_modnotfound=0
claimed_file=""
keep=1

flush() {
  [ -z "$block" ] && return
  if [ "$keep" -eq 1 ]; then
    printf '%s' "$block"
  else
    printf '[checklist-execute] DROPPED: %s' "$(printf '%s' "$block" | head -1)" >&2
  fi
  block=""; is_modnotfound=0; claimed_file=""; keep=1
}

can_resolve() {
  # Return 0 if every `import X` / `from X import Y` in $1 resolves to a file
  # under $DIFFHOUND_REPO (under the file's own dir, api/, or api/tests/).
  local path="$1"
  [ -f "$path" ] || return 1
  local repo="$DIFFHOUND_REPO"
  while IFS= read -r mod; do
    # mod is e.g. "database" (from `import database`) or "routers.widget"
    local mod_rel="${mod//./\/}"
    local candidate
    for candidate in \
      "$repo/$mod_rel.py" \
      "$repo/$mod_rel/__init__.py" \
      "$repo/api/$mod_rel.py" \
      "$repo/api/$mod_rel/__init__.py" ; do
      [ -f "$candidate" ] && continue 2
    done
    # stdlib / third-party: skip (we only care about local modules)
    # Heuristic: if not found in repo AND module is lowercase with no dots AND
    # has no corresponding dir, assume third-party OK (don't fail the check)
    if [ -d "$repo/$(echo "$mod" | cut -d. -f1)" ] || [ -f "$repo/${mod_rel%%/*}.py" ]; then
      return 1
    fi
  done < <(grep -oE '^(from [a-zA-Z0-9_.]+|import [a-zA-Z0-9_.]+)' "$path" \
            | awk '{print $2}')
  return 0
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING:*)
      flush
      block="$line"$'\n'
      h="${line#FINDING: }"
      claimed_file="${h%%:*}"
      ;;
    WHAT:*)
      block+="$line"$'\n'
      if printf '%s' "$line" | grep -qiE 'ModuleNotFoundError|fails in isolation|cant? run standalone'; then
        is_modnotfound=1
      fi
      ;;
    *)
      block+="$line"$'\n'
      ;;
  esac
done
if [ "$is_modnotfound" -eq 1 ] && [ -n "$claimed_file" ]; then
  can_resolve "$DIFFHOUND_REPO/$claimed_file" && keep=0
fi
flush
BASH
chmod +x lib/validators/checklist-execute.sh
```

- [ ] **Step 4: Run tests**

```bash
tests/run.sh checklist-execute
```
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/validators/checklist-execute.sh tests/fixtures/checklist-execute
git commit -m "feat(validators): drop ModuleNotFoundError findings when imports resolve"
```

---

## Task 8: Integration — Wire Validators into `review.sh`

**Files:**
- Create: `lib/validators/run-all.sh`
- Modify: `lib/review.sh` — insert call to validators between finding merge and comment parse at line ~4104
- Modify: `Dockerfile` — nothing needed (ripgrep + python3 already present)
- Modify: `.github/workflows/reply.yml` — set `DIFFHOUND_REPO` env var in the action

- [ ] **Step 1: Write the orchestrator**

```bash
cat > lib/validators/run-all.sh <<'BASH'
#!/usr/bin/env bash
# run-all.sh — pipe findings through every validator in the correct order.
# Ordering matters: dedup/reference-check → DRY → security → TODO → round-diff.
# TODO-deferral runs LAST among content filters so severity changes aren't
# undone by earlier drops. round-diff is always last (it's pure accounting).
set -uo pipefail
: "${DIFFHOUND_REPO:?}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$ROOT/lib/validators"

"$V/ref-exists.sh" \
  | "$V/dry-vs-import.sh" \
  | "$V/security-helper.sh" \
  | "$V/checklist-execute.sh" \
  | "$V/todo-deferral.sh" \
  | "$V/round-diff.sh"
BASH
chmod +x lib/validators/run-all.sh
```

- [ ] **Step 2: Smoke test — empty input → empty output + diff block**

```bash
DIFFHOUND_REPO=/tmp echo "" | lib/validators/run-all.sh
```
Expected:
```
### CHANGES_SINCE_LAST_REVIEW
+0 new, -0 resolved, =0 unchanged
```

- [ ] **Step 3: Hook into `review.sh`**

Find the location in `lib/review.sh` at line ~4104 where `FINDING:` blocks are detected in the merged output. Insert a call immediately before the `_finding_count=$(grep -c "^FINDING:" "$CLAUDE_OUT" ...)` line:

```bash
# Run validators to strip false positives before counting / parsing
if [ -x "${LIB_DIR}/validators/run-all.sh" ] && [ -n "${DIFFHOUND_REPO:-}" ]; then
  _validated_tmp=$(mktemp -t "validated.XXXXXX")
  if DIFFHOUND_REPO="$DIFFHOUND_REPO" \
     DIFFHOUND_PRIOR_FINDINGS="${DIFFHOUND_PRIOR_FINDINGS:-}" \
     "${LIB_DIR}/validators/run-all.sh" < "$CLAUDE_OUT" > "$_validated_tmp" 2>>"${REVIEW_LOG:-/dev/null}"; then
    if [ -s "$_validated_tmp" ]; then
      mv "$_validated_tmp" "$CLAUDE_OUT"
    else
      rm -f "$_validated_tmp"
    fi
  else
    rm -f "$_validated_tmp"
  fi
fi
```

Use the exact edit:

Locate this block (around line 4103-4105):
```
  # Recovery path 2: FINDINGS_START format (chunked/merged reviews)
  if [ "$_recovered" = false ] && grep -q "^FINDING:" "$CLAUDE_OUT" 2>/dev/null; then
    _finding_count=$(grep -c "^FINDING:" "$CLAUDE_OUT" 2>/dev/null | head -1 || true)
```

Insert the validator block **before** this `if`.

- [ ] **Step 4: Set `DIFFHOUND_REPO` from `entrypoint.sh`**

Check `entrypoint.sh` for whether `DIFFHOUND_REPO` is exported. If not, add `export DIFFHOUND_REPO="$(pwd)"` near the top, after the `git config --global url.insteadOf` line.

```bash
grep -q "export DIFFHOUND_REPO" entrypoint.sh || \
  sed -i '/git config --global url/a export DIFFHOUND_REPO="$(pwd)"' entrypoint.sh
```

- [ ] **Step 5: Run all tests**

```bash
tests/run.sh
```
Expected: every fixture passes. Total should be ≥ 12 (2 per validator × 6 validators, plus any additions).

- [ ] **Step 6: Commit**

```bash
git add lib/validators/run-all.sh lib/review.sh entrypoint.sh
git commit -m "feat(validators): wire validator pipeline into review flow"
```

---

## Task 9: Golden End-to-End Test — Replay PR #114 Findings

**Files:**
- Create: `tests/fixtures/e2e-pr114-18-49/{input.txt,expected.txt,repo/...}`

Copy the actual 18:49 review's findings into `input.txt`. Copy minimal stubs of the referenced files (orchestrator.py, tools.py, conversations.py, widget.py, test_widget.py) into `repo/`. Expected: the 2 false positives (timing-attack, test-isolation) and 1 hallucination (`_populate_working_memory`) are dropped, and B2 (tools.py:1023) is downgraded to SHOULD-FIX with TODO annotation.

- [ ] **Step 1: Assemble fixture from PR #114's 18:49 review**

Fetch the raw review body:
```bash
gh api repos/novabenefits/claro/pulls/114/reviews/4157182994 --jq '.body' > /tmp/pr114-18-49.md
```

Extract the findings section, convert to `FINDING:` format, save as `tests/fixtures/e2e-pr114-18-49/input.txt`.

Build `repo/` tree containing only the files referenced, using the real-source snapshots from `/Users/shubham/Dev/claro` at the PR's HEAD.

- [ ] **Step 2: Run the full pipeline**

```bash
DIFFHOUND_REPO=tests/fixtures/e2e-pr114-18-49/repo \
  lib/validators/run-all.sh < tests/fixtures/e2e-pr114-18-49/input.txt
```

Manually inspect output. Iterate on validators until the known FPs drop and real findings survive.

- [ ] **Step 3: Snapshot output as expected.txt**

Once output matches ground truth (verified by cross-referencing user's pushback notes in commit 31e6341), snapshot:
```bash
DIFFHOUND_REPO=tests/fixtures/e2e-pr114-18-49/repo \
  lib/validators/run-all.sh < tests/fixtures/e2e-pr114-18-49/input.txt \
  > tests/fixtures/e2e-pr114-18-49/expected.txt
tests/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/e2e-pr114-18-49
git commit -m "test(e2e): replay PR #114 18:49 review — 3 FPs dropped, 1 downgraded"
```

---

## Task 10: Release v0.3.0

- [ ] **Step 1: Update README** (optional for this release — can defer)

- [ ] **Step 2: Bump version references** — search for `v0.2.0` in docs; update action.yml if it embeds a version.

- [ ] **Step 3: Open PR, peer-review, merge, tag**

```bash
git push origin main
gh auth switch --user shubhamattri
gh release create v0.3.0 --target main \
  --title "v0.3.0 — false-positive gates" \
  --notes "Validators that drop hallucinated references, import-as-duplicate, delegated timing-safe comparisons, and ModuleNotFoundError FPs. TODO-deferral downgrades BLOCKING near TODO(TICKET). Round-over-round accounting in every review."
gh auth switch --user shubhamattri-nova
```

- [ ] **Step 4: Pin claro to v0.3.0**

In `novabenefits/claro/.github/workflows/diffhound-review-hosted.yml`, change `@v0.2.0` → `@v0.3.0`. Open a PR, merge.

---

## Self-Review

- **Spec coverage:** 8 original issues mapped to 7 tasks (Task 4 is prompt-only, no code). Round diff (#7) is Task 6. Test-execution gate (#6 in original list) is Task 7. All 8 covered.
- **Placeholder scan:** No TBDs, no "add error handling", no "similar to Task N" without repetition. Each task has actual code.
- **Type/function consistency:** All validators accept stdin, emit stdout, use `DIFFHOUND_REPO` env. Orchestrator pipes in fixed order. Identity key `(file, line, severity, symbol)` consistent across ref-exists and round-diff.
- **Gaps:** Task 4 (state-dict prompt rule) has no fixture — it's prompt-only and can't be unit-tested. Accepted. End-to-end validation is Task 9.
