#!/usr/bin/env bash
# Exercise the production planning and publishing helpers with strict API fakes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/github.sh"
source "$ROOT/lib/publish.sh"
source "$ROOT/lib/lifecycle.sh"
source "$ROOT/lib/parser.sh"
TMP=$(mktemp -d -t dh-lifecycle-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export DIFFHOUND_LOGIN=me
assert() { [ "$1" = "$2" ] || { echo "FAIL $3: [$1] != [$2]" >&2; exit 1; }; }
# Container images may use the byte-oriented C locale. Whole UTF-8 dash
# sequences must be removed, without leaving invalid bytes in the concern.
for dash in '—' '–' '-'; do
  assert "$(LC_ALL=C strip_severity_label "BLOCKING $dash Keep the full concern")" 'Keep the full concern' 'severity delimiter survives C locale'
  printf 'COMMENT: src/auth.ts:10:BLOCKING %s Keep the full concern\n' "$dash" > "$TMP/locale-overflow"
  assert "$(LC_ALL=C dh_overflow_section "$TMP/locale-overflow" | sed -n '/^- /p')" '- `src/auth.ts:10` (BLOCKING) Keep the full concern' 'overflow delimiter survives C locale'
  concern='Reject expired tokens before granting access to the private account.'
  printf 'src/auth.ts:10:BLOCKING %s %s\n' "$dash" "$concern" > "$TMP/locale-comments"
  : > "$TMP/locale-voice.jsonl"
  assert "$(LC_ALL=C index_voice_comments "$TMP/locale-comments" 1 "$TMP/locale-voice.jsonl")" 1 'learning indexes Unicode comments in C locale'
  assert "$(jq -r .comment "$TMP/locale-voice.jsonl")" "$concern" 'learning retains the exact concern'
done
# Render/inject the actual multiline publication payload, then recover its state.
rendered=$(strip_severity_label $'BLOCKING — Reject expired tokens\x1fAn expired token currently grants access.\x1f\tKeep this tab too.')
jq -n --arg body "$rendered" '{comments:[{path:"src/auth.ts",line:10,body:$body},{path:"next.ts",line:20,body:"Next finding"}]}' > "$TMP/multiline"
_inject_markers_into_review_json "$TMP/multiline"
assert "$(jq -r '.comments[0].body | split("\n\n<!-- diffhound-id")[0]' "$TMP/multiline")" "$rendered" 'multiline comment body preserved before marker'
assert "$(jq -r '.comments[1].body | split("\n\n<!-- diffhound-id")[0]' "$TMP/multiline")" 'Next finding' 'multiline transport does not shift later comments'
PYTHONPATH="$ROOT/lib" python3 - "$TMP/multiline" <<'PY'
import json, sys
import review_state as state
line = 'COMMENT: src/auth.ts:10:BLOCKING — Reject expired tokens\x1fAn expired token currently grants access.\x1f\tKeep this tab too.'
first = state.reconcile([], [], [], 'me', 'aaa', [line])
reviews = [{'user':'me','state':'COMMENTED','body':state.marker(first)}]
comment = dict(json.load(open(sys.argv[1]))['comments'][0], id=55, user='me')
second = state.reconcile(reviews, [comment], [{'db_id':55,'is_resolved':True}], 'me', 'bbb', [])
assert len(second['findings']) == 1, second
assert second['findings'][0]['status'] == 'RESOLVED', second
PY
# Actual Git commit ancestry, including an unrelated replacement after force push.
git init -qb main "$TMP/repo"
export GIT_AUTHOR_NAME=Fixture GIT_COMMITTER_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_EMAIL=fixture@example.invalid
tree=$(git -C "$TMP/repo" mktree < /dev/null)
base=$(printf base | git -C "$TMP/repo" commit-tree "$tree")
child=$(printf child | git -C "$TMP/repo" commit-tree "$tree" -p "$base")
replacement=$(printf replacement | git -C "$TMP/repo" commit-tree "$tree")
dh_incremental_base_ok "$TMP/repo" o r "$base" "$child"
if dh_incremental_base_ok "$TMP/repo" o r "$base" "$replacement"; then
  echo 'FAIL force push accepted as incremental' >&2; exit 1
fi
printf '[]' > "$TMP/comments"
printf '[]' > "$TMP/reviews"
printf '[]' > "$TMP/threads"
mkdir "$TMP/round1" "$TMP/round2"
cat > "$TMP/new" <<'EOF'
COMMENT: src/auth.ts:10:SHOULD-FIX — Reject expired tokens
COMMENT: src/auth.ts:20:NIT — Preserve the error cause
COMMENT: src/other.ts:10:BLOCKING — Prevent unauthorized access
EOF
_call_api() { cat >/dev/null; printf '1: DUP 1\n'; }
dh_plan_findings "$TMP/new" "$TMP/reviews" "$TMP/comments" "$TMP/threads" me aaa "$TMP/round1"
dh_cap_inline_comments "$TMP/new" 1 "$TMP/overflow"
sed 's/^COMMENT: //' "$TMP/new" > "$TMP/selected"
printf 'The authentication path rejects expired tokens. Three concerns remain: token expiry validation, error cause preservation, and authorization before granting access. These fixture findings exercise publication history across pushes, including findings outside the inline comment budget. No runtime behavior is inferred from an edited line.\n' > "$TMP/summary"
python3 "$ROOT/lib/review_state.py" finish "$TMP/round1/plan" "$TMP/selected" "$TMP/overflow" "$TMP/summary"
assert "$(jq '.findings | length' "$TMP/round1/plan")" 3 'overflow remembered'
jq -n --rawfile body "$TMP/summary" '[{id:1,user:"me",state:"COMMENTED",body:$body,submitted_at:"2026-09-29"}]' > "$TMP/reviews"
cat > "$TMP/new" <<'EOF'
COMMENT: src/auth.ts:99:SHOULD-FIX — Expired tokens must be rejected
COMMENT: src/auth.ts:20:BLOCKING — Check authentication before returning true
COMMENT: src/other.ts:80:BLOCKING — Prevent unauthorized access
EOF
dh_plan_findings "$TMP/new" "$TMP/reviews" "$TMP/comments" "$TMP/threads" me bbb "$TMP/round2"
assert "$(cat "$TMP/new")" 'COMMENT: src/auth.ts:20:BLOCKING — Check authentication before returning true' 'new blocker survives while exact and semantic repeats do not repost'
assert "$_DH_DEDUP_DROPPED" 2 'repeat accounting'
assert "$(jq '[.findings[].aliases // [] | length] | add' "$TMP/round2/plan")" 1 'semantic identity persists'

# The shared predicate used by sweep, including a real body string and legacy reviews.
jq -n '[{user:{login:"me"},state:"COMMENTED",commit_id:"aaa",body:"| Category | Score |"}]' > "$TMP/raw"
assert "$(jq -L "$ROOT/lib" 'include "review-identity"; any(.[]; dh_covers("me"; "aaa"))' "$TMP/raw")" true 'sweep legacy SHA'
for status in PENDING UNKNOWN; do
  jq --arg st "$status" '.[0].state=$st' "$TMP/raw" > "$TMP/invalid"
  assert "$(jq -L "$ROOT/lib" 'include "review-identity"; any(.[]; dh_covers("me"; "aaa"))' "$TMP/invalid")" false 'unsubmitted reviews never count'
done
jq '.[0].body="| Category | Score |\n<!-- diffhound-review v1 sha=bbb -->"' "$TMP/raw" > "$TMP/moved"
assert "$(jq -L "$ROOT/lib" 'include "review-identity"; any(.[]; dh_covers("me"; "aaa"))' "$TMP/moved")" false 'moved marker beats commit_id'

# Recovery must distinguish pending drafts from completed reviews.
echo '{"body":"summary"}' > "$TMP/review"
_gh_api_all() { printf '[{"id":901,"state":"%s","commit_id":"aaa","user":{"login":"me"},"body":"summary"}]' "$STATUS"; }
STATUS=PENDING
assert "$(_find_posted_review o r 1 aaa me "$TMP/review")" '' 'pending draft is not success'
STATUS=COMMENTED
assert "$(_find_posted_review o r 1 aaa me "$TMP/review")" 901 'submitted review recovered'

# Summary only updates our marked comment, ignoring another user's forged marker.
_gh_api_all() { cat "$TMP/issues"; }
gh() {
  case "$*" in
    'api --method PATCH /repos/o/r/issues/comments/7 --input '*) printf 'PATCH 7\n' >> "$TMP/calls" ;;
    'api --method POST /repos/o/r/issues/1/comments --input '*) printf 'POST\n' >> "$TMP/calls" ;;
    *) echo "Unexpected API call: $*" >&2; return 99 ;;
  esac
}
echo '[{"id":8,"user":{"login":"other"},"body":"<!-- diffhound-summary v1 -->"}]' > "$TMP/issues"
dh_upsert_summary o r 1 me "$TMP/summary"
jq '. + [{id:7,user:{login:"me"},body:"<!-- diffhound-summary v1 -->"}]' "$TMP/issues" > "$TMP/next"
mv "$TMP/next" "$TMP/issues"
dh_upsert_summary o r 1 me "$TMP/summary"
dh_upsert_summary o r 1 me "$TMP/summary"
assert "$(cat "$TMP/calls")" $'POST\nPATCH 7\nPATCH 7' 'one summary across three pushes'
echo 'PASS lifecycle: ancestry, two rounds, overflow, semantic history, blocker regression, submitted recovery, sticky summary'
