#!/usr/bin/env bash
# lib/design.sh — design check for PRs that change screens.
#
# Runs only when the diff touches UI files. Reviews the user experience (not the
# code) from the UI diff plus any screenshots the author attached, and upserts
# ONE advisory PR comment marked <!-- diffhound-design -->. It never changes the
# code-review score or verdict, and any failure here is logged and swallowed so
# the main review is never blocked by it. Kill switch: DIFFHOUND_DESIGN=0.

_DESIGN_MARKER="<!-- diffhound-design -->"
_DESIGN_MAX_IMAGES=5
_DESIGN_MAX_IMAGE_BYTES=5000000
_DESIGN_MAX_DIFF_BYTES=80000
_DESIGN_MODEL="${DIFFHOUND_DESIGN_MODEL:-claude-opus-5}"

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

# Downloads screenshots from the PR description and the author's own comments.
# Uses body_html because private-repo uploads are only reachable through the
# short-lived signed URLs GitHub puts there. stdout: number of images saved.
_design_fetch_images() {
  local owner="$1" repo="$2" pr="$3" author="$4" outdir="$5"
  local html urls n=0 url f mime size
  html=$( {
    gh api "repos/${owner}/${repo}/pulls/${pr}" -H 'Accept: application/vnd.github.full+json' --jq '.body_html // ""'
    gh api "repos/${owner}/${repo}/issues/${pr}/comments" --paginate -H 'Accept: application/vnd.github.full+json' \
      | jq -r --arg a "$author" '.[] | select(.user.login == $a) | .body_html // ""'
  } 2>/dev/null || true)
  urls=$(printf '%s' "$html" | _design_extract_image_urls)
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    [ "$n" -ge "$_DESIGN_MAX_IMAGES" ] && break
    f="${outdir}/shot-$((n + 1))"
    if ! $_TIMEOUT_CMD 60 curl -sfL -o "$f" "$url" 2>/dev/null; then
      $_TIMEOUT_CMD 60 curl -sfL -H "Authorization: token $(gh auth token 2>/dev/null)" -o "$f" "$url" 2>/dev/null || { rm -f "$f"; continue; }
    fi
    mime=$(file --mime-type -b "$f" 2>/dev/null || echo "")
    size=$(wc -c < "$f" | tr -d ' ')
    case "$mime" in image/png|image/jpeg|image/gif|image/webp) ;; *) rm -f "$f"; continue ;; esac
    [ "$size" -gt "$_DESIGN_MAX_IMAGE_BYTES" ] && { rm -f "$f"; continue; }
    printf '%s' "$mime" > "${f}.mime"
    n=$((n + 1))
  done <<< "$urls"
  echo "$n"
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
    # Image data goes through files: a 5MB screenshot as a CLI argument exceeds ARG_MAX.
    base64 < "$f" | tr -d '\n' > "${f}.b64"
    jq -c --arg m "$(cat "${f}.mime")" --rawfile d "${f}.b64" --arg label "Screenshot ${i}:" \
      '. + [{type: "text", text: $label}, {type: "image", source: {type: "base64", media_type: $m, data: $d}}]' \
      "$imgdir/blocks.json" > "$imgdir/blocks.tmp" 2>/dev/null || echo '[]' > "$imgdir/blocks.tmp"
    mv "$imgdir/blocks.tmp" "$imgdir/blocks.json"
  done
  jq -n --arg model "$_DESIGN_MODEL" --slurpfile blocks "$imgdir/blocks.json" \
        --rawfile text "$text_file" --rawfile system "$system_file" \
    '{model: $model, max_tokens: 8000,
      thinking: {type: "adaptive"}, output_config: {effort: "medium"},
      system: $system,
      messages: [{role: "user", content: ($blocks[0] + [{type: "text", text: $text}])}]}'
}

# $1 = model JSON, $2 = screenshots seen. stdout: markdown comment, or nothing
# when the model output is unusable (caller must then not post).
_design_render() {
  local json="$1" shots="${2:-0}"
  printf '%s' "$json" | jq -e '.findings | type == "array"' >/dev/null 2>&1 || return 0
  local basis
  if [ "$shots" -gt 0 ]; then
    basis="Based on the UI diff and ${shots} screenshots attached to this PR."
  else
    basis="No screenshots attached, so this is from the code only. Add screenshots of the changed screens to the PR description (or a comment) and re-run for a visual check."
  fi
  printf '%s' "$json" | jq -r --arg marker "$_DESIGN_MARKER" --arg basis "$basis" '
    def sev: ["Not a problem","Cosmetic","Minor","Major","Critical"][. // 0];
    ([.findings[] | select((.severity // 0) >= 1)] | sort_by(-(.severity // 0)) | .[:7]) as $f
    | ([.findings[] | select((.severity // 0) < 1)]) as $taste
    | [$marker,
       "## Design check (advisory, does not affect the score)",
       "",
       "**Who uses this:** \(.user // "unclear")  ",
       "**What they open it for:** \(.job // "unclear")",
       "",
       "_\($basis)_",
       "",
       (if ($f | length) == 0 then "No user-experience problems found in the changed screens." else empty end),
       ($f | to_entries[] |
         "### \(.key + 1). \(.value.title) (\(.value.severity | sev))\n**Where:** \(.value.where)  \n**What happens:** \(.value.what_happens)  \n**Why it matters:** \(.value.why)  \n**Possible fix (suggestion):** \(.value.fix)\n"),
       (if ($taste | length) > 0 then "**Taste, not defects:** " + ([$taste[].title] | join("; ")) + "\n" else empty end),
       (if ((.cannot_check // []) | length) > 0 then "**Could not check:** " + ((.cannot_check) | join("; ")) + "\n" else empty end),
       (if ((.good // []) | length) > 0 then "**What works:** " + ((.good) | join("; ")) + "\n" else empty end),
       "<sub>Reply on this PR if a finding is wrong; it is advisory and never blocks merge.</sub>"
      ] | join("\n")'
}

# Creates or updates the single design comment. Issue comments do not trigger
# the diffhound workflow, so updating it cannot re-enter the review.
_design_upsert_comment() {
  local owner="$1" repo="$2" pr="$3" login="$4" body_file="$5" existing
  existing=$(gh api "repos/${owner}/${repo}/issues/${pr}/comments" --paginate 2>/dev/null \
    | jq -r --arg l "$login" --arg m "$_DESIGN_MARKER" \
    '.[] | select(.user.login == $l and (.body | startswith($m))) | .id' 2>/dev/null | tail -1)
  if [ -n "$existing" ]; then
    gh api -X PATCH "repos/${owner}/${repo}/issues/comments/${existing}" -F "body=@${body_file}" >/dev/null
  else
    gh api -X POST "repos/${owner}/${repo}/issues/${pr}/comments" -F "body=@${body_file}" >/dev/null
  fi
}

# Entry point. Always returns 0. $7 = "post" to publish, anything else prints.
run_design_check() {
  local owner="$1" repo="$2" pr="$3" author="$4" login="$5" diff_file="$6" mode="${7:-print}"
  local title="${8:-}" body="${9:-}" jira="${10:-}"
  [ "${DIFFHOUND_DESIGN:-1}" = "0" ] && return 0

  local ui_files
  ui_files=$(grep -E '^diff --git ' "$diff_file" | awk '{f=$4; sub(/^b\//,"",f); print f}' | _design_ui_files)
  if [ -z "$ui_files" ]; then
    echo "  Design check: no UI files changed, skipped" >&2
    return 0
  fi

  local work shots text_file req resp json md
  work=$(mktemp -d -t "pr-${pr}-design.XXXXXX")
  shots=$(_design_fetch_images "$owner" "$repo" "$pr" "$author" "$work")
  text_file="${work}/text.txt"
  {
    printf 'PR TITLE: %s\n\nPR DESCRIPTION:\n%s\n\n' "$title" "$body"
    [ -n "$jira" ] && printf 'JIRA TICKET:\n%s\n\n' "$jira"
    printf 'SCREENSHOTS ATTACHED: %s\n\nCHANGED UI FILES:\n%s\n\nUI DIFF:\n' "$shots" "$ui_files"
    _design_ui_diff "$diff_file" "$ui_files"
  } > "$text_file"

  req="${work}/req.json"
  _design_request "$work" "$text_file" "${DIFFHOUND_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/design-prompt.txt" > "$req"
  resp=$($_TIMEOUT_CMD 300 curl -sf "${_ANTHROPIC_API_URL:-https://api.anthropic.com/v1/messages}" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" -d @"$req" 2>/dev/null || echo "")
  declare -F _cost_record >/dev/null && printf '%s' "$resp" | DIFFHOUND_STAGE=design _cost_record "$_DESIGN_MODEL" design
  json=$(printf '%s' "$resp" | jq -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>/dev/null \
    | sed -n '/^[[:space:]]*{/,$p' | sed '/^```/d')
  md=$(_design_render "$json" "$shots")
  if [ -z "$md" ]; then
    echo "  Design check: model returned no usable result, nothing posted" >&2
    rm -rf "$work"; return 0
  fi

  printf '%s\n' "$md" > "${work}/comment.md"
  if [ "$mode" = "post" ]; then
    if _design_upsert_comment "$owner" "$repo" "$pr" "$login" "${work}/comment.md"; then
      echo "  Design check: posted (${shots} screenshots)" >&2
    else
      echo "  Design check: posting failed" >&2
    fi
  else
    cat "${work}/comment.md"
  fi
  rm -rf "$work"
  return 0
}
