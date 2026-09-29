# Shared by the review pipeline, publication recovery, and fallback sweep.
def dh_submitted:
  .state as $state | ["COMMENTED", "APPROVED", "CHANGES_REQUESTED", "DISMISSED"] | index($state) != null;
def dh_author($login):
  (.user | if type == "object" then .login else . end) == $login;
def dh_review($login):
  dh_author($login) and dh_submitted and
  ((.body // "") | test("<!-- diffhound-review v1 |SCORECARD_JSON|\\| Category \\| Score"));
def dh_sha:
  ((.body // "") | [capture("<!-- diffhound-review v1 sha=(?<s>[0-9a-f]+) -->").s][0]) // .commit_id;
def dh_covers($login; $sha): dh_review($login) and dh_sha == $sha;
