#!/usr/bin/env bash
# Run the real CLI -> Python command -> shared API transport, all IO faked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d -t dh-command-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
export TEST_STATE="$TMP" ANTHROPIC_API_KEY=test-placeholder-not-a-secret
export PATH="$TMP/bin:$PATH"
unset DIFFHOUND_OFFLINE GH_TOKEN
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'auth setup-git') echo configured > "$TEST_STATE/git-auth" ;;
  'api /repos/o/r/pulls/7 -H Accept: application/vnd.github.diff') printf 'diff --git a/auth.ts b/auth.ts\n+rejectExpired()\n' ;;
  'api /repos/o/r/pulls/7') echo '{"title":"Validate tokens","body":"Human notes","head":{"sha":"aaa"}}' ;;
  'api /repos/o/r/pulls/7 --method PATCH --input -') cat > "$TEST_STATE/written"; echo '{"id":7}' ;;
  *) echo "Unexpected gh invocation: $*" >&2; exit 91 ;;
esac
SH
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
prev=''
for arg in "$@"; do
  if [ "$prev" = '-d' ]; then cp "${arg#@}" "$TEST_STATE/model-input"; fi
  prev="$arg"
done
printf 'call\n' >> "$TEST_STATE/model-calls"
jq -n --arg stop "${TEST_STOP:-end_turn}" '{content:[{type:"text",text:"{\"body\":\"Reject expired tokens; no test result supplied.\"}"}],stop_reason:$stop,usage:{input_tokens:100,output_tokens:10}}'
SH
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"
bash "$ROOT/bin/diffhound" /describe 7 --repo o/r > "$TMP/result"
jq -e '.applied == false and .head_sha == "aaa"' "$TMP/result" >/dev/null
test ! -e "$TMP/written"
test "$(wc -l < "$TMP/model-calls" | tr -d ' ')" = 1
jq -e '.messages[0].content | contains("rejectExpired")' "$TMP/model-input" >/dev/null
bash "$ROOT/bin/diffhound" /changelog 7 --repo o/r --apply > "$TMP/result"
jq -e '.body | contains("Human notes") and contains("diffhound-changelog start")' "$TMP/written" >/dev/null
rm "$TMP/written"
if TEST_STOP=max_tokens bash "$ROOT/bin/diffhound" /describe 7 --repo o/r --apply > "$TMP/out" 2> "$TMP/err"; then
  echo 'FAIL truncated model reply accepted' >&2; exit 1
fi
test ! -e "$TMP/written"

# Docker direct CLI forwards every argument; Action inputs are mapped safely.
cat > "$TMP/bin/capture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_STATE/args"
SH
chmod +x "$TMP/bin/capture"
export DIFFHOUND_BIN="$TMP/bin/capture"
GH_TOKEN=test-placeholder-not-a-secret bash "$ROOT/entrypoint.sh" /ask 7 --repo o/r --question 'What changed?'
test -f "$TMP/git-auth"
diff -u <(printf '%s\n' /ask 7 --repo o/r --question 'What changed?') "$TMP/args"
INPUT_PR_NUMBER=7 INPUT_COMMAND=describe INPUT_APPLY=false GITHUB_REPOSITORY=o/r bash "$ROOT/entrypoint.sh"
diff -u <(printf '%s\n' /describe 7 --repo o/r) "$TMP/args"
echo '{"action":"synchronize"}' > "$TMP/event"
INPUT_PR_NUMBER=7 INPUT_MODE=fast GITHUB_REPOSITORY=o/r GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/event" bash "$ROOT/entrypoint.sh"
diff -u <(printf '%s\n' 7 --repo o/r --fast --auto-post --synchronize) "$TMP/args"
echo 'PASS command entrypoint: CLI, shared API, draft/apply, truncated output, Docker args, Action synchronize'
