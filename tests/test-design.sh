#!/usr/bin/env bash
# tests/test-design.sh — unit tests for lib/design.sh (UI detection, screenshot
# extraction, markdown rendering). No network, no model calls.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib/design.sh"

PASS=0; FAIL=0; FAILED=()
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — want: $3"; printf '%s\n' "$2" | sed 's/^/     /'; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — must NOT contain: $3"; else PASS=$((PASS+1)); echo "ok   $1"; fi; }
eq()   { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL $1 — want [$3] got [$2]"; fi; }

# ── UI file detection ──
UI=$(printf '%s\n' \
  services/portal/src/components/claro/ClaroRatingCoverage.vue \
  services/portal/src/components/claro/ClaroRatingCoverage.spec.js \
  services/api/src/queries/claroRatings.ts \
  dashboard/app/routes/voice.tsx \
  dashboard/tests/voice-session.test.mjs \
  services/portal/src/styles/main.scss \
  services/portal/src/components/Button.stories.js \
  services/portal/src/components/__tests__/Foo.spec.tsx \
  | _design_ui_files)
has   "ui: vue component"        "$UI" "ClaroRatingCoverage.vue"
has   "ui: tsx route"            "$UI" "dashboard/app/routes/voice.tsx"
has   "ui: stylesheet"           "$UI" "main.scss"
hasnt "ui: spec excluded"        "$UI" "ClaroRatingCoverage.spec.js"
hasnt "ui: backend ts excluded"  "$UI" "claroRatings.ts"
hasnt "ui: test dir excluded"    "$UI" "__tests__"
hasnt "ui: stories excluded"     "$UI" "stories"
eq    "ui: empty input -> empty" "$(printf '' | _design_ui_files)" ""

# ── Screenshot URL extraction from rendered body_html ──
HTML='<p>Before</p><p><a href="x"><img src="https://private-user-images.githubusercontent.com/1/abc.png?jwt=eyJ&amp;x=1" alt="before" style="max-width:100%;"></a></p>
<img alt="Open in Cursor" width="131" height="28" src="https://cursor.com/assets/images/open-in-cursor-dark.png">
<img src="https://github.com/user-attachments/assets/1111-2222" alt="after">
<img src="https://img.shields.io/badge/x-y.svg">
<img src="https://private-user-images.githubusercontent.com/1/abc.png?jwt=eyJ&amp;x=1">'
URLS=$(printf '%s' "$HTML" | _design_extract_image_urls)
has   "img: private signed url kept"   "$URLS" "https://private-user-images.githubusercontent.com/1/abc.png?jwt=eyJ&x=1"
has   "img: user-attachments kept"     "$URLS" "https://github.com/user-attachments/assets/1111-2222"
hasnt "img: badge host dropped"        "$URLS" "cursor.com"
hasnt "img: shields dropped"           "$URLS" "shields.io"
hasnt "img: html entity decoded"       "$URLS" "&amp;"
eq    "img: duplicates removed"        "$(printf '%s\n' "$URLS" | grep -c private-user-images)" "1"

# ── Rendering ──
JSON='{"user":"CX manager","job":"see which chats were rated badly","findings":[
 {"title":"17 bad ratings lead nowhere","severity":3,"where":"ClaroRatingCoverage.vue:22","what_happens":"The number is not clickable.","why":"Recognition over recall (the screen should hand you the next step).","fix":"Suggestion: Make the number open those chats."},
 {"title":"Colour","severity":0,"where":"x","what_happens":"y","why":"z","fix":"w"}],
 "cannot_check":["contrast"],"good":["Denominator shown beside every rate"]}'
MD=$(_design_render "$JSON" 0)
has   "render: marker first"          "$(printf '%s' "$MD" | head -1)" "<!-- diffhound-design -->"
has   "render: finding title"         "$MD" "17 bad ratings lead nowhere"
has   "render: severity label"        "$MD" "Major"
has   "render: where"                 "$MD" "ClaroRatingCoverage.vue:22"
has   "render: suggestion labelled"   "$MD" "Possible fix (suggestion):** Make the number"
hasnt "render: no doubled suggestion" "$MD" "Suggestion: Make"
has   "render: cannot-check as list"  "$MD" "- contrast"
has   "render: code-only notice"      "$MD" "No screenshots"
has   "render: cannot check"          "$MD" "contrast"
has   "render: good"                  "$MD" "Denominator shown"
hasnt "render: severity 0 not a finding" "$MD" "### 2."
has   "render: severity 0 as taste"   "$MD" "Colour"
MD2=$(_design_render "$JSON" 2)
has   "render: screenshot count"      "$MD2" "2 screenshots"
hasnt "render: no code-only notice"   "$MD2" "No screenshots"

# More than 7 findings are capped
MANY=$(jq -nc '{user:"u",job:"j",findings:[range(9)|{title:("F\(.)"),severity:2,where:"w",what_happens:"h",why:"y",fix:"f"}],cannot_check:[],good:[]}')
MD3=$(_design_render "$MANY" 1)
has   "cap: 7th shown"   "$MD3" "### 7."
hasnt "cap: 8th cut"     "$MD3" "### 8."

# Garbage model output renders nothing (caller must not post)
eq "render: invalid json -> empty" "$(_design_render 'not json' 0)" ""

echo ""
echo "design: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { printf '  - %s\n' "${FAILED[@]}"; exit 1; }
