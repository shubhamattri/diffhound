#!/usr/bin/env bash
# lib/design.sh — design check for PRs that change screens.
#
# Runs only when the diff touches UI files. Reviews the user experience (not the
# code) from the UI diff plus any screenshots the author attached, and upserts
# ONE advisory PR comment marked <!-- diffhound-design ... -->. It never changes
# the code-review score or verdict, and every failure is logged and swallowed.
# Callers run it last, under a hard time cap. Kill switch: DIFFHOUND_DESIGN=0.

_DESIGN_MARKER_PREFIX="<!-- diffhound-design"
_DESIGN_MAX_IMAGES=5
_DESIGN_MAX_IMAGE_BYTES=3500000   # base64 adds a third; keeps each image under the API's 5MB limit
_DESIGN_MAX_TOTAL_BYTES=12000000
_DESIGN_MAX_DIFF_BYTES=80000
_DESIGN_MAX_COMMENT_CHARS=60000   # GitHub rejects comments over 65536
_DESIGN_MODEL="${DIFFHOUND_DESIGN_MODEL:-claude-opus-5}"
_DESIGN_TIMEOUT_CMD="${_TIMEOUT_CMD:-timeout}"

# stdin: changed paths, one per line. stdout: the ones that render UI.
_design_ui_files() {
  grep -E '\.(vue|tsx|jsx|svelte|html|css|scss|sass|less)$' \
    | grep -vE '(\.spec\.|\.test\.|\.stories\.|/__tests__/|/tests?/|/e2e/|/fixtures?/)' \
    || true
}

# stdin: rendered PR/comment HTML. stdout: unique screenshot URLs, entities
# decoded. Only GitHub-hosted uploads count; bot badges and external icons do not.
_design_extract_image_urls() {
  grep -oE '<img[^>]+src="[^"]+"' \
    | sed -E 's/.*src="([^"]+)"/\1/; s/&amp;/\&/g' \
    | grep -E '^https://(private-user-images\.githubusercontent\.com|user-images\.githubusercontent\.com|github\.com/user-attachments/assets)/' \
    | awk '!seen[$0]++' \
    || true
}

# stdout: the diff restricted to UI files, capped.
_design_ui_diff() {
  local diff_file="$1" ui_list="$2"
  awk -v list="$ui_list" '
    BEGIN { n = split(list, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") keep[a[i]] = 1 }
    /^diff --git / { f = $4; sub(/^b\//, "", f); on = (f in keep) }
    on { print }
  ' "$diff_file" | head -c "$_DESIGN_MAX_DIFF_BYTES"
}

# Fingerprint of what the check looks at: the UI diff plus the screenshot
# identities (signed-URL query strings stripped, they change on every fetch).
_design_fingerprint() {
  local ui_diff_file="$1" urls="$2"
  { cat "$ui_diff_file"; printf '%s\n' "$urls" | sed 's/?.*//'; } \
    | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
}

# stdin: raw model text. stdout: the first JSON object in it, or nothing.
_design_extract_json() {
  python3 -c '
import json, sys
t = sys.stdin.read()
i = t.find("{")
while i != -1:
    try:
        obj, _ = json.JSONDecoder().raw_decode(t[i:])
        if isinstance(obj, dict):
            print(json.dumps(obj)); break
    except ValueError:
        pass
    i = t.find("{", i + 1)
' 2>/dev/null || true
}

# Secrets go through a 0600 file, never the command line, so other users on
# the shared runner cannot read them from ps or /proc.
_design_curl_headers() {
  local f="$1"; shift
  ( umask 077; printf '%s\n' "$@" > "$f" )
}

# Downloads screenshots from the PR description and the author's own comments.
# Private-repo uploads are only reachable through the short-lived signed URLs
# GitHub puts in body_html. stdout: the kept URLs, one per line; images saved
# as $outdir/shot-N with a .mime sidecar.
_design_fetch_images() {
  local owner="$1" repo="$2" pr="$3" author="$4" outdir="$5"
  local html urls n=0 total=0 url f mime size kept=""
  html=$( {
    $_DESIGN_TIMEOUT_CMD 30 gh api "repos/${owner}/${repo}/pulls/${pr}" -H 'Accept: application/vnd.github.full+json' --jq '.body_html // ""'
    $_DESIGN_TIMEOUT_CMD 30 gh api "repos/${owner}/${repo}/issues/${pr}/comments" --paginate -H 'Accept: application/vnd.github.full+json' \
      | jq -r --arg a "$author" '.[] | select(.user.login == $a) | .body_html // ""'
  } 2>/dev/null || true)
  urls=$(printf '%s' "$html" | _design_extract_image_urls)
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    [ "$n" -ge "$_DESIGN_MAX_IMAGES" ] && break
    f="${outdir}/shot-$((n + 1))"
    $_DESIGN_TIMEOUT_CMD 30 curl -sfL --max-filesize "$_DESIGN_MAX_IMAGE_BYTES" -o "$f" "$url" 2>/dev/null || { rm -f "$f"; continue; }
    mime=$(file --mime-type -b "$f" 2>/dev/null || echo "")
    size=$(wc -c < "$f" | tr -d ' ')
    case "$mime" in image/png|image/jpeg|image/gif|image/webp) ;; *) rm -f "$f"; continue ;; esac
    if [ "$size" -gt "$_DESIGN_MAX_IMAGE_BYTES" ] || [ $((total + size)) -gt "$_DESIGN_MAX_TOTAL_BYTES" ]; then
      rm -f "$f"; continue
    fi
    printf '%s' "$mime" > "${f}.mime"
    total=$((total + size)); n=$((n + 1))
    kept="${kept}${url}"$'\n'
  done <<< "$urls"
  printf '%s' "$kept"
}

# Builds the Messages API request: screenshots as image blocks, then the text.
_design_request() {
  local imgdir="$1" text_file="$2" system_file="$3"
  local f i=0
  echo '[]' > "$imgdir/blocks.json"
  for f in "$imgdir"/shot-*; do
    case "$f" in *.mime|*.b64) continue ;; esac
    [ -f "$f" ] || continue
    i=$((i + 1))
    # Image data goes through files: a large screenshot as a CLI argument exceeds ARG_MAX.
    base64 < "$f" | tr -d '\n' > "${f}.b64"
    jq -c --arg m "$(cat "${f}.mime")" --rawfile d "${f}.b64" --arg label "Screenshot ${i}:" \
      '. + [{type: "text", text: $label}, {type: "image", source: {type: "base64", media_type: $m, data: $d}}]' \
      "$imgdir/blocks.json" > "$imgdir/blocks.tmp" 2>/dev/null || cp "$imgdir/blocks.json" "$imgdir/blocks.tmp"
    mv "$imgdir/blocks.tmp" "$imgdir/blocks.json"
  done
  jq -n --arg model "$_DESIGN_MODEL" --slurpfile blocks "$imgdir/blocks.json" \
        --rawfile text "$text_file" --rawfile system "$system_file" \
    '{model: $model, max_tokens: 8000,
      thinking: {type: "adaptive"}, output_config: {effort: "medium"},
      system: $system,
      messages: [{role: "user", content: ($blocks[0] + [{type: "text", text: $text}])}]}'
}

# $1 = model JSON, $2 = screenshots seen, $3 = fingerprint. stdout: markdown
# comment, or nothing when the output is unusable (caller must then not post).
# PR text is attacker-controlled and this posts under a person's account, so
# every model string is length-capped, mentions are defused and links dropped.
_design_render() {
  local json="$1" shots="${2:-0}" fp="${3:-}"
  printf '%s' "$json" | jq -e '(.findings // null) | type == "array"' >/dev/null 2>&1 || return 0
  local basis
  if [ "$shots" -gt 0 ]; then
    basis="Based on the UI diff and ${shots} screenshots attached to this PR."
  else
    basis="No screenshots attached, so this is from the code only. Add screenshots of the changed screens to the PR description (or a comment) and push again for a visual check."
  fi
  printf '%s' "$json" | jq -r --arg marker "${_DESIGN_MARKER_PREFIX} fp=${fp} -->" --arg basis "$basis" '
    def clean(n): (. // "") | tostring
      | gsub("!?\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)")
      | gsub("https?://[^\\s)]+"; "[link removed]")
      | gsub("<[^>]*>"; "")
      | gsub("@(?<u>[A-Za-z0-9_-])"; "@​\(.u)")
      | gsub("—"; ", ")
      | if length > n then .[:n] + "..." else . end;
    def sevn: (try ((. // 0) | tonumber | floor) catch 0) | if . < 0 then 0 elif . > 4 then 4 else . end;
    def sev: ["Not a problem","Cosmetic","Minor","Major","Critical"][sevn];
    ([.findings[] | objects | select((.severity | sevn) >= 1)] | sort_by(-(.severity | sevn)) | .[:7]) as $f
    | ([.findings[] | objects | select((.severity | sevn) < 1)]) as $taste
    | [$marker,
       "## Design check (advisory, does not affect the score)",
       "",
       "**Who uses this:** \(.user | clean(300))  ",
       "**What they open it for:** \(.job | clean(300))",
       "",
       "_\($basis)_",
       "",
       (if ($f | length) == 0 then "No user-experience problems found in the changed screens.\n" else empty end),
       ($f | to_entries[] |
         "### \(.key + 1). \(.value.title | clean(160)) (\(.value.severity | sev))\n**Where:** \(.value.where | clean(200))  \n**What happens:** \(.value.what_happens | clean(900))  \n**Why it matters:** \(.value.why | clean(400))  \n**Possible fix (suggestion):** \(.value.fix | clean(600) | sub("^\\s*[Ss]uggestion:\\s*"; ""))\n"),
       (if ($taste | length) > 0 then "**Taste, not defects:** " + ([$taste[].title | clean(120)] | join("; ")) + "\n" else empty end),
       (if ((.cannot_check // []) | length) > 0 then "**Could not check:**\n" + ([.cannot_check[] | clean(400)] | .[:6] | map("- " + .) | join("\n")) + "\n" else empty end),
       (if ((.good // []) | length) > 0 then "**What works:**\n" + ([.good[] | clean(300)] | .[:5] | map("- " + .) | join("\n")) + "\n" else empty end),
       "<sub>Advisory only, never blocks merge. Reply on the PR if a finding is wrong.</sub>"
      ] | join("\n")' 2>/dev/null | head -c "$_DESIGN_MAX_COMMENT_CHARS"
}

# stdout: "<id> <fingerprint>" of our existing design comment, "none" if there
# is none, nothing if the lookup failed (caller must then not post, or it
# would create a duplicate).
_design_existing_comment() {
  local owner="$1" repo="$2" pr="$3" login="$4" raw
  raw=$($_DESIGN_TIMEOUT_CMD 30 gh api "repos/${owner}/${repo}/issues/${pr}/comments" --paginate 2>/dev/null) || return 0
  printf '%s' "$raw" | jq -rs --arg l "$login" --arg m "$_DESIGN_MARKER_PREFIX" '
    [.[][] | select(.user.login == $l and (.body | startswith($m)))] | last
    | if . == null then "none"
      else "\(.id) \((.body | capture("fp=(?<f>[0-9a-f]*)").f) // "")" end' 2>/dev/null
}

# Entry point. Always returns 0. $7 = "post" to publish, anything else prints.
run_design_check() {
  local owner="$1" repo="$2" pr="$3" author="$4" login="$5" diff_file="$6" mode="${7:-print}"
  local title="${8:-}" body="${9:-}" jira="${10:-}"
  [ "${DIFFHOUND_DESIGN:-1}" = "0" ] && return 0
  [ -s "$diff_file" ] || { echo "  Design check: no diff, skipped" >&2; return 0; }

  local ui_files
  ui_files=$(grep -E '^diff --git ' "$diff_file" | awk '{f=$4; sub(/^b\//,"",f); print f}' | _design_ui_files)
  if [ -z "$ui_files" ]; then
    echo "  Design check: no UI files changed, skipped" >&2
    return 0
  fi

  local work urls shots fp existing existing_id="" text_file req resp json md
  work=$(mktemp -d -t "pr-${pr}-design.XXXXXX")
  _design_ui_diff "$diff_file" "$ui_files" > "${work}/ui.diff"
  urls=$(_design_fetch_images "$owner" "$repo" "$pr" "$author" "$work")
  shots=$(printf '%s' "$urls" | grep -c . || true)
  fp=$(_design_fingerprint "${work}/ui.diff" "$urls")

  if [ "$mode" = "post" ]; then
    existing=$(_design_existing_comment "$owner" "$repo" "$pr" "$login")
    if [ -z "$existing" ]; then
      echo "  Design check: could not read existing comments, skipped" >&2
      rm -rf "$work"; return 0
    fi
    if [ "$existing" != "none" ]; then
      existing_id="${existing%% *}"
      if [ "${existing#* }" = "$fp" ] && [ "${DIFFHOUND_DESIGN_FORCE:-0}" != "1" ]; then
        echo "  Design check: screens unchanged since last check, skipped" >&2
        rm -rf "$work"; return 0
      fi
    fi
  fi

  text_file="${work}/text.txt"
  {
    printf 'PR TITLE: %s\n\nPR DESCRIPTION:\n%s\n\n' "$title" "$body"
    [ -n "$jira" ] && printf 'JIRA TICKET:\n%s\n\n' "$jira"
    printf 'SCREENSHOTS ATTACHED: %s\n\nCHANGED UI FILES:\n%s\n\nUI DIFF:\n' "$shots" "$ui_files"
    cat "${work}/ui.diff"
  } > "$text_file"

  req="${work}/req.json"
  _design_request "$work" "$text_file" "${DIFFHOUND_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/design-prompt.txt" > "$req"
  _design_curl_headers "${work}/h" "x-api-key: ${ANTHROPIC_API_KEY:-}" "anthropic-version: 2023-06-01" "content-type: application/json"
  resp=$($_DESIGN_TIMEOUT_CMD 180 curl -sf "${_ANTHROPIC_API_URL:-https://api.anthropic.com/v1/messages}" \
    -H @"${work}/h" -d @"$req" 2>/dev/null || echo "")
  declare -F _cost_record >/dev/null && printf '%s' "$resp" | DIFFHOUND_STAGE=design _cost_record "$_DESIGN_MODEL" design >/dev/null 2>&1
  json=$(printf '%s' "$resp" | jq -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>/dev/null | _design_extract_json)
  md=$(_design_render "$json" "$shots" "$fp")
  if [ -z "$md" ]; then
    echo "  Design check: model returned no usable result, nothing posted" >&2
    rm -rf "$work"; return 0
  fi

  printf '%s\n' "$md" > "${work}/comment.md"
  if [ "$mode" = "post" ]; then
    local ok=1
    if [ -n "$existing_id" ]; then
      $_DESIGN_TIMEOUT_CMD 30 gh api -X PATCH "repos/${owner}/${repo}/issues/comments/${existing_id}" -F "body=@${work}/comment.md" >/dev/null 2>&1 || ok=0
    else
      $_DESIGN_TIMEOUT_CMD 30 gh api -X POST "repos/${owner}/${repo}/issues/${pr}/comments" -F "body=@${work}/comment.md" >/dev/null 2>&1 || ok=0
    fi
    [ "$ok" = 1 ] && echo "  Design check: posted (${shots} screenshots)" >&2 || echo "  Design check: posting failed" >&2
  else
    cat "${work}/comment.md"
  fi
  rm -rf "$work"
  return 0
}
