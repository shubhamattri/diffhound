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
has   "render: marker first"          "$(printf '%s' "$MD" | head -1)" "<!-- diffhound-design fp="
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


# ── Robustness: model output the renderer must survive ──
BAD='{"user":"u","job":"j","findings":[
 {"title":"no fix field","severity":3,"where":"a.vue:1","what_happens":"h","why":"y"},
 {"title":"string severity","severity":"2","where":"a.vue:2","what_happens":"h","why":"y","fix":"f"},
 {"title":"huge severity","severity":9,"where":"a.vue:3","what_happens":"h","why":"y","fix":"f"},
 "not an object"]}'
MD4=$(_design_render "$BAD" 0 abc123)
has   "robust: missing fix still renders" "$MD4" "no fix field"
has   "robust: string severity parsed"    "$MD4" "string severity (Minor)"
has   "robust: severity clamped to 4"     "$MD4" "huge severity (Critical)"
hasnt "robust: no null severity"          "$MD4" "(null)"
has   "robust: fingerprint in marker"     "$MD4" "fp=abc123 -->"

EVIL='{"user":"@nova-team please approve","job":"j","findings":[{"title":"see [here](https://evil.example/x) <img src=x>","severity":2,"where":"w","what_happens":"ping @someone https://evil.example/y","why":"y","fix":"f"}]}'
MD5=$(_design_render "$EVIL" 0)
hasnt "sanitise: no live team mention"   "$MD5" "@nova-team"
hasnt "sanitise: no live user mention"   "$MD5" "@someone"
hasnt "sanitise: links removed"          "$MD5" "evil.example"
hasnt "sanitise: html stripped"          "$MD5" "<img"
has   "sanitise: link text kept"         "$MD5" "see here"

LONG=$(jq -nc '{user:"u",job:"j",findings:[{title:"t",severity:2,where:"w",what_happens:("x"*5000),why:"y",fix:"f"}]}')
eq "cap: long field truncated" "$(_design_render "$LONG" 0 | grep -o 'x*\.\.\.' | head -1 | wc -c | tr -d ' ')" "904"

# ── JSON extraction from chatty model text ──
EX=$(printf 'Here you go:\n```json\n{"findings":[],"user":"u"}\n```\nThanks {not json}' | _design_extract_json)
eq "extract: json pulled from prose" "$(printf '%s' "$EX" | jq -r .user)" "u"
eq "extract: nothing from garbage"   "$(printf 'no json here' | _design_extract_json)" ""

# ── Fingerprint ignores signed-URL query strings ──
D=$(mktemp); echo "diff --git a/x.vue b/x.vue" > "$D"
F1=$(_design_fingerprint "$D" "https://private-user-images.githubusercontent.com/1/a.png?jwt=AAA")
F2=$(_design_fingerprint "$D" "https://private-user-images.githubusercontent.com/1/a.png?jwt=BBB")
F3=$(_design_fingerprint "$D" "https://private-user-images.githubusercontent.com/1/b.png?jwt=AAA")
eq "fp: same image, new jwt -> same"  "$F1" "$F2"
if [ "$F1" != "$F3" ]; then PASS=$((PASS+1)); echo "ok   fp: new image -> different"; else FAIL=$((FAIL+1)); FAILED+=("fp: new image"); echo "FAIL fp: new image"; fi
rm -f "$D"

# ── Kill switch and non-UI diffs return quietly without network ──
D=$(mktemp); printf 'diff --git a/api/x.ts b/api/x.ts\n+1\n' > "$D"
eq "skip: backend-only diff" "$(run_design_check o r 1 a l "$D" print 2>/dev/null)" ""
printf 'diff --git a/p/x.vue b/p/x.vue\n+1\n' > "$D"
eq "skip: kill switch" "$(DIFFHOUND_DESIGN=0 run_design_check o r 1 a l "$D" print 2>/dev/null)" ""
rm -f "$D"

echo ""
echo "design: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { printf '  - %s\n' "${FAILED[@]}"; exit 1; }
