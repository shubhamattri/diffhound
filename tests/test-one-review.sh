#!/usr/bin/env bash
# tests/test-one-review.sh — one GitHub notification per run (lib/publish.sh).
# Regressions from monorepo #7642 (Sep 2026): 566 reviews and ~1,229 posted
# objects on one PR, from per-comment fallback posting, separate thread replies,
# a new "review failed" comment per failure, and repeated findings each push.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/marker-utils.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/github.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/publish.sh"

# review.sh runs with IFS=$'\n\t'; test under the same IFS.
IFS=$'\n\t'
PASS=0; FAIL=0; FAILED=()
TMP=$(mktemp -d -t diffhound-onereview.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"
       else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — got [$2] want [$3]"; fi; }
has() { if grep -qF -- "$3" <<< "$2"; then PASS=$((PASS+1)); echo "ok   $1"
        else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — missing: $3"; fi; }
lacks() { if grep -qF -- "$3" <<< "$2"; then FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — unexpected: $3"
          else PASS=$((PASS+1)); echo "ok   $1"; fi; }

# ── caps ────────────────────────────────────────────────────────────────────
C="$TMP/comments"
cat > "$C" <<'EOF'
COMMENT: a.ts:1:NIT — n1
COMMENT: a.ts:2:BLOCKING — b1
COMMENT: a.ts:3:SHOULD-FIX — s1
REPLY: 55:a.ts:9:r1
COMMENT: b.ts:4:SHOULD-FIX — s2
COMMENT: b.ts:5:BLOCKING — b2
COMMENT: b.ts:6:SHOULD-FIX — s3
COMMENT: b.ts:7:NIT — n2
REPLY: 56:a.ts:9:r2
REPLY: 57:a.ts:9:r3
REPLY: 58:a.ts:9:r4
EOF
dh_cap_inline_comments "$C" 2 "$TMP/over"
eq "cap: every BLOCKING stays inline" "$(grep -c ':BLOCKING' "$C")" "2"
eq "cap: SHOULD-FIX fills the cap before NIT, in order" "$(grep -oE 's[0-9]|n[0-9]' "$C" | tr '\n' ' ')" "s1 s2 "
eq "cap: overflow holds the rest in order" "$(grep -oE 's[0-9]|n[0-9]' "$TMP/over" | tr '\n' ' ')" "n1 s3 n2 "
eq "cap: replies pass through untouched" "$(grep -c '^REPLY: ' "$C")" "4"
dh_cap_replies "$C" 3 "$TMP/rover" 2>/dev/null
eq "cap: replies capped at 3, first three kept" "$(grep '^REPLY: ' "$C" | cut -d: -f2 | tr -d ' ' | tr '\n' ' ')" "55 56 57 "
eq "cap: capped reply kept for the summary, not lost" "$(cat "$TMP/rover")" "58:a.ts:9:r4"
sec=$(dh_overflow_section "$TMP/over")
has "overflow: summary lists capped findings with location" "$sec" '- `b.ts:6` (SHOULD-FIX) s3'
has "overflow: collapsible with a count" "$sec" "<summary>3 more finding(s)"
eq "overflow: nothing to say when nothing was capped" "$(: > "$TMP/none"; dh_overflow_section "$TMP/none")" ""

# ── last diffhound review ──────────────────────────────────────────────────
jq -n '[
  {id: 1, user: "me", submitted_at: "2026-09-01", commit_id: "aaa", body: "| Category | Score | Notes |\n| x |"},
  {id: 2, user: "me", submitted_at: "2026-09-02", commit_id: "bbb", body: "lgtm, ship it"},
  {id: 3, user: "other", submitted_at: "2026-09-03", commit_id: "ccc", body: "| Category | Score | Notes |"}
]' > "$TMP/reviews"
eq "last review: legacy scorecard body, manual review ignored, falls back to commit_id" \
  "$(dh_last_diffhound_review "$TMP/reviews" me)" $'1\taaa'
jq '. + [{id: 4, user: "me", submitted_at: "2026-09-04", commit_id: "ddd", body: "summary\n<!-- diffhound-review v1 sha=eeeeeee1 -->"}]' "$TMP/reviews" > "$TMP/reviews2"
eq "last review: marker sha wins over commit_id (review edited in place)" \
  "$(dh_last_diffhound_review "$TMP/reviews2" me)" $'4\teeeeeee1'
jq '. + [{id: 9, user: "me", state: "PENDING", submitted_at: "2026-09-09", commit_id: "zzz", body: "| Category | Score |\n<!-- diffhound-review v1 sha=fff -->"}]' "$TMP/reviews2" > "$TMP/reviews3"
eq "last review: an unsubmitted draft does not count" "$(dh_last_diffhound_review "$TMP/reviews3" me)" $'4\teeeeeee1'
eq "last review: none for a PR diffhound never reviewed" "$(dh_last_diffhound_review "$TMP/reviews" nobody)" ""
body=$(_dh_body_with_marker $'old\n<!-- diffhound-review v1 sha=abc1234 -->' "def5678")
eq "marker: exactly one marker, for the new commit" "$(grep -o 'diffhound-review v1 sha=[0-9a-f]*' <<< "$body")" "diffhound-review v1 sha=def5678"

# ── quiet rerun: only when there is truly nothing new ─────────────────────
q() { dh_quiet_rerun_ok "$@" && echo quiet || echo post; }
eq "quiet: clean re-review refreshes in place" "$(q true false COMMENT COMMENT "" 0 0 123)" "quiet"
eq "quiet: fresh review always posts" "$(q false false COMMENT COMMENT "" 0 0 123)" "post"
eq "quiet: --force-full always posts" "$(q true true COMMENT COMMENT "" 0 0 123)" "post"
eq "quiet: a capped REQUEST_CHANGES posts (summary-only blocker)" "$(q true false COMMENT REQUEST_CHANGES "" 0 0 123)" "post"
eq "quiet: APPROVE posts" "$(q true false APPROVE APPROVE "" 0 0 123)" "post"
eq "quiet: unreviewed chunks post" "$(q true false COMMENT COMMENT "2" 0 0 123)" "post"
eq "quiet: any inline comment posts" "$(q true false COMMENT COMMENT "" 1 0 123)" "post"
eq "quiet: any reply posts" "$(q true false COMMENT COMMENT "" 0 1 123)" "post"
eq "quiet: nothing to refresh posts" "$(q true false COMMENT COMMENT "" 0 0 "")" "post"

# ── gh stub ────────────────────────────────────────────────────────────────
GH="$TMP/gh"; mkdir -p "$GH/bin"
cat > "$GH/bin/gh" <<'SH'
#!/usr/bin/env bash
# Records every call; behaviour switched by flag files in $GHSTATE.
input=""; prev=""
for a in "$@"; do [ "$prev" = "--input" ] && input="$a"; prev="$a"; done
if [ -n "$input" ] && [ "$input" != "-" ]; then
  n=$(ls "$GHSTATE"/body.* 2>/dev/null | wc -l | tr -d ' '); cp "$input" "$GHSTATE/body.$n"
fi
if [ "$input" = "-" ]; then cat > "$GHSTATE/stdin.last"; cat "$GHSTATE/stdin.last" >> "$GHSTATE/graphql"; fi
echo "$*" >> "$GHSTATE/calls"
case "$*" in
  *"--method DELETE"*) exit 0 ;;
  *"--method PUT"*) exit 0 ;;
  *"--method PATCH"*) exit 0 ;;
  *"--method POST"*"/events"*)
    [ -f "$GHSTATE/submit_fails" ] && { echo "HTTP 422" >&2; exit 1; }
    echo '{"id": 900}' ;;
  *"--method POST"*"/reviews"*)
    if ! jq -e 'has("event")' "$input" >/dev/null; then
      [ -f "$GHSTATE/pending_fails" ] && { echo "HTTP 422 pending exists" >&2; exit 1; }
      echo '{"id": 900, "node_id": "PRR_900"}'; exit 0
    fi
    if [ -f "$GHSTATE/self_approve_rejected" ] && [ "$(jq -r .event "$input")" != COMMENT ]; then echo "HTTP 422 own" >&2; exit 1; fi
    if [ -f "$GHSTATE/bulk_creates" ] && jq -e '.comments | length > 0' "$input" >/dev/null; then
      cp "$input" "$GHSTATE/created.json"; echo "HTTP 502" >&2; exit 1; fi
    if [ -f "$GHSTATE/bad_lines" ] && jq -e '.comments | length > 0' "$input" >/dev/null; then echo "HTTP 422 line" >&2; exit 1; fi
    echo '{"id": 901}' ;;
  *"--method POST"*"/issues/"*"/comments"*) exit 0 ;;
  *"--method POST"*"/comments"*) exit 0 ;;
  *"api graphql"*)
    if grep -q addPullRequestReviewThreadReply "$GHSTATE/stdin.last"; then echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"C1"}}}}'; exit 0; fi
    if grep -q '"c":"CUR1"' "$GHSTATE/stdin.last"; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"T2","isResolved":true,"comments":{"nodes":[{"databaseId":56}]}}]}}}}}'
    else
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"id":"T1","isResolved":false,"comments":{"nodes":[{"databaseId":55}]}}]}}}}}'
    fi ;;
  *"/issues/"*"/comments"*) cat "$GHSTATE/issue_comments.json" 2>/dev/null || echo '[]' ;;
  *"/reviews/900"*) if [ -f "$GHSTATE/submit_applied" ]; then echo '{"id":900,"state":"COMMENTED"}'; else echo '{"id":900,"state":"PENDING"}'; fi ;;
  *"/reviews"*)
    if [ -f "$GHSTATE/reviews.json" ]; then cat "$GHSTATE/reviews.json"; exit 0; fi
    if [ -f "$GHSTATE/created.json" ]; then
      jq -c '[{id: 77, commit_id: .commit_id, user: {login: "me"}, body: (.body + "\n")}]' "$GHSTATE/created.json"
    else echo '[]'; fi ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$GH/bin/gh"
reset_gh() { rm -rf "$GH/state"; mkdir -p "$GH/state"; : > "$GH/state/calls"; : > "$GH/state/graphql"; }
mkrev() { jq -n --arg e "${1:-COMMENT}" '{commit_id: "sha1", event: $e, body: "## Scorecard 71/100",
  comments: [{path: "src/a.ts", line: 1, body: "first finding"}, {path: "src/a.ts", line: 2, body: "second finding"}]}' > "$GH/review.json"; }
run_pub() { # event replies_file [author]
  ( export GHSTATE="$GH/state" PATH="$GH/bin:$PATH" DIFFHOUND_LOGIN=me DIFFHOUND_PR_AUTHOR="${3:-someone}"
    dh_publish_review o r 1 sha1 "$1" "$GH/review.json" "$2" 2>/dev/null
    echo "$_DH_POSTED $_DH_EVENT $_DH_INLINE_POSTED $_DH_REPLIES_POSTED" > "$GH/state/result" )
}
posts() { grep -c -- '--method POST' "$GH/state/calls"; }
: > "$TMP/noreplies"

# One review, one call, on the normal path.
reset_gh; mkrev APPROVE; run_pub APPROVE "$TMP/noreplies"
eq "publish: normal path is one POST" "$(posts)" "1"
eq "publish: result" "$(cat "$GH/state/result")" "true APPROVE 2 0"

# Own PR: GitHub rejects self-approval, so the review goes as COMMENT first time.
reset_gh; touch "$GH/state/self_approve_rejected"; mkrev APPROVE; run_pub APPROVE "$TMP/noreplies" me
eq "publish: own PR posts once, as COMMENT" "$(posts) $(jq -r .event "$GH/state/body.0")" "1 COMMENT"
eq "publish: own PR keeps its inline comments" "$(cat "$GH/state/result")" "true COMMENT 2 0"

# Bad inline positions: comments move into the body. Never one call per comment.
reset_gh; touch "$GH/state/bad_lines"; mkrev COMMENT; run_pub COMMENT "$TMP/noreplies"
eq "publish: bad lines → 2 POSTs (full, then body-only), no per-comment posts" \
  "$(posts) $(grep -- '--method POST' "$GH/state/calls" | grep -c '/pulls/1/comments')" "2 0"
last_body=$(jq -r .body "$GH/state/body.1")
has "publish: body-only review lists the findings" "$last_body" '- `src/a.ts:2` second finding'
eq "publish: body-only review has no inline comments" "$(jq '.comments | length' "$GH/state/body.1")" "0"

# Bad lines on a blocking review: the verdict survives, only the comments move.
reset_gh; touch "$GH/state/bad_lines"; mkrev REQUEST_CHANGES; run_pub REQUEST_CHANGES "$TMP/noreplies"
eq "publish: bad lines keep REQUEST_CHANGES (body-only with the verdict)" \
  "$(posts) $(jq -r .event "$GH/state/body.1") $(cut -d' ' -f1-2 "$GH/state/result")" "2 REQUEST_CHANGES true REQUEST_CHANGES"

# A POST that errored after GitHub created the review is not posted again.
reset_gh; touch "$GH/state/bulk_creates"; mkrev COMMENT; run_pub COMMENT "$TMP/noreplies"
eq "publish: created-despite-error review is not posted again" "$(posts)" "1"
eq "publish: counted as posted" "$(cut -d' ' -f1 "$GH/state/result")" "true"

# Replies ride in the same review: pending → thread replies → submit.
printf '55:a.ts:9:fair, that is fixed now\n56:b.ts:3:still open\n' > "$TMP/replies"
reset_gh; mkrev REQUEST_CHANGES; run_pub REQUEST_CHANGES "$TMP/replies"
eq "replies: opened as a pending review (no event)" "$(jq 'has("event")' "$GH/state/body.0")" "false"
eq "replies: no REST reply calls (each would be its own review)" "$(grep -c '/replies' "$GH/state/calls")" "0"
eq "replies: both attached via GraphQL to the pending review" \
  "$(grep -o 'addPullRequestReviewThreadReply' "$GH/state/graphql" | wc -l | tr -d ' ')" "2"
has "replies: each reply carries the leading diffhound signature (skips the learn trigger)" \
  "$(cat "$GH/state/graphql")" '"b":"<!-- diffhound-reply v1 -->\n\nfair, that is fixed now"'
eq "replies: submitted once with the verdict" "$(grep -c '/reviews/900/events' "$GH/state/calls") $(jq -r .event "$GH/state/body.1")" "1 REQUEST_CHANGES"
eq "replies: result" "$(cat "$GH/state/result")" "true REQUEST_CHANGES 2 2"

# An escalation keeps its own signature (not double-signed).
printf '55:x:0:<!-- diffhound-escalation v0.5.2 --> limit reached\n' > "$TMP/esc"
reset_gh; mkrev COMMENT; run_pub COMMENT "$TMP/esc"
has "replies: escalation body keeps its own leading signature" "$(cat "$GH/state/graphql")" '"b":"<!-- diffhound-escalation v0.5.2 --> limit reached"'

# A reply whose thread cannot be found is listed in the submitted body.
printf '55:a.ts:9:threaded\n99:c.ts:1:thread gone\n' > "$TMP/replies2"
reset_gh; mkrev COMMENT; run_pub COMMENT "$TMP/replies2"
sub=$(ls "$GH/state"/body.* | sort -t. -k2 -n | tail -1)
eq "replies: one threaded, one not" "$(cat "$GH/state/result")" "true COMMENT 2 1"
has "replies: the unthreaded one is in the submitted body" "$(jq -r .body "$sub")" "#discussion_r99): thread gone"

# Submit errors after GitHub applied it: counted as posted, nothing re-posted.
reset_gh; touch "$GH/state/submit_fails" "$GH/state/submit_applied"; mkrev COMMENT; run_pub COMMENT "$TMP/replies"
eq "replies: submit-after-write is not re-posted or deleted" \
  "$(grep -c -- '--method DELETE' "$GH/state/calls") $(grep -c -- '/pulls/1/reviews --input' "$GH/state/calls") $(cut -d' ' -f1 "$GH/state/result")" "0 1 true"

# Leftover diffhound pending drafts are deleted first; Shubham's own draft is not.
reset_gh; jq -n '[{id: 5, state: "PENDING", user: {login: "me"}, body: "x <!-- diffhound-review v1 sha=abc -->"},
                  {id: 6, state: "PENDING", user: {login: "me"}, body: "my own draft"}]' > "$GH/state/reviews.json"
mkrev COMMENT; run_pub COMMENT "$TMP/replies"
eq "pending: only diffhound's leftover draft is deleted" "$(grep -- '--method DELETE' "$GH/state/calls" | grep -oE 'reviews/[0-9]+' | tr '\n' ' ')" "reviews/5 "

# Submit fails: the pending review is deleted, replies go into the body.
reset_gh; touch "$GH/state/submit_fails"; mkrev COMMENT; run_pub COMMENT "$TMP/replies"
eq "replies: failed submit deletes the pending draft" "$(grep -c -- '--method DELETE.*/reviews/900' "$GH/state/calls")" "1"
final=$(ls "$GH/state"/body.* | sort -t. -k2 -n | tail -1)
has "replies: then posts one review with replies listed in the body" "$(jq -r .body "$final")" "#discussion_r55): fair, that is fixed now"

# Pending cannot open (Shubham has his own draft on the PR): replies in body.
reset_gh; touch "$GH/state/pending_fails"; mkrev COMMENT; run_pub COMMENT "$TMP/replies"
eq "replies: no pending → one direct review" "$(grep -c '/events' "$GH/state/calls") $(jq 'has("event")' "$GH/state/body.1")" "0 true"
has "replies: listed in that review's body" "$(jq -r .body "$GH/state/body.1")" "#discussion_r56): still open"

# Threads beyond the first 100 are read (pagination).
reset_gh
threads=$(export GHSTATE="$GH/state" PATH="$GH/bin:$PATH"; dh_review_threads o r 1)
eq "threads: all pages read" "$(jq -c '[.[].thread_id]' <<< "$threads")" '["T1","T2"]'

# Status comment: edited in place when one exists, created only once.
reset_gh; jq -n '[{id: 42, body: "<!-- diffhound-status v1 -->\nold failure"}]' > "$GH/state/issue_comments.json"
( export GHSTATE="$GH/state" PATH="$GH/bin:$PATH"; dh_upsert_status_comment o r 1 "failed again" )
eq "status: existing comment is PATCHed, nothing new posted" \
  "$(grep -c -- '--method PATCH.*/issues/comments/42' "$GH/state/calls") $(posts)" "1 0"
reset_gh
( export GHSTATE="$GH/state" PATH="$GH/bin:$PATH"; dh_upsert_status_comment o r 1 "failed" )
eq "status: first failure creates one comment" "$(grep -c -- '--method POST.*/issues/1/comments' "$GH/state/calls")" "1"

# ── semantic dedup ─────────────────────────────────────────────────────────
jq -n '[{id: 11, user: "me", in_reply_to_id: null, path: "src/a.ts", line: 10, body: "`retry` swallows the error\n<!-- diffhound-id v1: x -->"},
        {id: 12, user: "dev", in_reply_to_id: null, path: "src/b.ts", line: 3, body: "not ours"}]' > "$TMP/existing"
cat > "$TMP/new" <<'EOF'
COMMENT: src/a.ts:14:SHOULD-FIX — retry() eats the exception, callers never see it
COMMENT: src/a.ts:30:NIT — magic number 7
COMMENT: src/b.ts:3:SHOULD-FIX — unrelated file only the dev commented on
REPLY: 11:src/a.ts:10:ok
EOF
_call_api() { cat > "$TMP/judge-prompt"; printf '%s' "$JUDGE_OUT"; }
cp "$TMP/new" "$TMP/n1"; JUDGE_OUT=$'1: DUP 11\n2: NEW'
dh_semantic_dedup "$TMP/n1" "$TMP/existing" me 2>/dev/null
eq "dedup: repeat of an earlier concern dropped, the rest kept" "$(grep -c . "$TMP/n1") $_DH_DEDUP_DROPPED" "3 1"
lacks "dedup: the dropped line is the repeat" "$(cat "$TMP/n1")" "eats the exception"
has "dedup: judge sees the prior comment without its hidden marker" "$(cat "$TMP/judge-prompt")" "[11] src/a.ts:10 \`retry\` swallows the error"
lacks "dedup: judge not asked about files with no prior reviewer comment" "$(cat "$TMP/judge-prompt")" "unrelated file"
cp "$TMP/new" "$TMP/n2"; JUDGE_OUT="sorry, I cannot help"
dh_semantic_dedup "$TMP/n2" "$TMP/existing" me 2>/dev/null
eq "dedup: unusable judge answer keeps every finding" "$(cmp -s "$TMP/new" "$TMP/n2" && echo same) $_DH_DEDUP_DROPPED" "same 0"
cp "$TMP/new" "$TMP/n3"; JUDGE_OUT=""; echo '[]' > "$TMP/empty-existing"
dh_semantic_dedup "$TMP/n3" "$TMP/empty-existing" me 2>/dev/null
eq "dedup: fresh PR (no prior comments) is untouched" "$(cmp -s "$TMP/new" "$TMP/n3" && echo same)" "same"

cp "$TMP/new" "$TMP/n4"; printf 'COMMENT: src/a.ts:15:BLOCKING — retry swallows errors\n' >> "$TMP/n4"
JUDGE_OUT=$'1: DUP 11\n2: DUP 11\n3: DUP 11\n4: DUP 11\n5: DUP 11\n2: DUP 12'
dh_semantic_dedup "$TMP/n4" "$TMP/existing" me 2>/dev/null
eq "dedup: judge obeyed only for asked findings; BLOCKING, REPLY and other files kept" \
  "$(grep -c . "$TMP/n4") $_DH_DEDUP_DROPPED" "3 2"
has "dedup: BLOCKING repeat is never dropped" "$(cat "$TMP/n4")" "BLOCKING — retry swallows errors"
has "dedup: reply lines survive a bogus DUP" "$(cat "$TMP/n4")" "REPLY: 11:"
has "dedup: other-file finding survives a bogus DUP" "$(cat "$TMP/n4")" "unrelated file"

# ── summary leak guard ─────────────────────────────────────────────────────
printf '### CHUNK_FILES\n- a.ts\n### THREAD_STATUS (TASK 1)\n' > "$TMP/leak"
has "leak: internal chunk notes are refused" "$(dh_summary_leak_reason "$TMP/leak")" "internal notes"
printf 'FINDING: a.ts:1:NIT\nWHAT: x\n' > "$TMP/leak2"
has "leak: raw FINDING blocks are refused" "$(dh_summary_leak_reason "$TMP/leak2")" "internal notes"
head -c 40000 /dev/zero | tr '\0' 'a' > "$TMP/big"
has "leak: runaway body is refused" "$(dh_summary_leak_reason "$TMP/big")" "40000 characters"
printf '## Summary\n| Category | Score |\nall good\n' > "$TMP/ok"
eq "leak: a normal summary passes" "$(dh_summary_leak_reason "$TMP/ok")" ""
fb=$(dh_fallback_summary "$C")
has "fallback: counts by severity (capped file: 2 blocking, 2 should-fix)" "$fb" "| 2 | 2 | 0 |"
has "fallback: lists files" "$fb" '- `b.ts`'
eq "fallback summary itself passes the leak guard" "$(printf '%s' "$fb" > "$TMP/fb"; dh_summary_leak_reason "$TMP/fb")" ""

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { printf '  failed: %s\n' "${FAILED[@]}"; exit 1; }
