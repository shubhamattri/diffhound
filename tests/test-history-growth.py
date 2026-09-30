"""Review history must survive many rounds without copying the whole PR each time."""
import hashlib
import base64
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import re
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import review_state as state

EVIDENCE = "Verified the changed paths and failure cases for this review. " * 10


def concern(number):
    evidence = " ".join(hashlib.sha256(f"{number}:{i}".encode()).hexdigest() for i in range(8))
    return f"COMMENT: src/file{number}.py:10:SHOULD-FIX — Preserve failure scenario {number}. Evidence: {evidence}"


def review(number, body):
    return {"id": number, "user": "me", "state": "COMMENTED", "submitted_at": f"{number:08d}", "body": body}


class HistoryGrowth(unittest.TestCase):
    def test_legacy_reader_fails_instead_of_ignoring_new_state(self):
        plan = state.reconcile([], [], [], "me", "a" * 40, [concern(0)])
        body = state.complete_summary(plan, EVIDENCE)
        # v0.7.60 matches only v1, then uses strict base64 decoding. It must
        # fail at that boundary rather than reuse an older successful review.
        legacy = re.search(r"<!-- diffhound-state v1: (.*?) -->", body, re.S)
        self.assertIsNotNone(legacy)
        with self.assertRaises(ValueError):
            base64.b64decode(legacy[1], validate=True)
        self.assertEqual(len(state.load_history([review(1, body)], "me")["findings"]), 1)

    def test_one_hundred_rounds_keep_every_concern_without_body_growth(self):
        reviews = []
        for turn in range(1, 101):
            lines = [concern(i) for i in range((turn - 1) * 5, turn * 5)]
            plan = state.reconcile(reviews, [], [], "me", f"{turn:040x}", lines)
            state.finalize(plan, lines)
            body = state.complete_summary(plan, EVIDENCE)
            self.assertLess(len(body.encode()), 12000)
            for line in lines:
                self.assertIn(state.parse(line)["body"], body)
            if turn > 1:
                self.assertNotIn(state.parse(concern(0))["body"], body)
                self.assertIn(f"#pullrequestreview-{turn - 1}", body)
            reviews.append(review(turn, body))
        recovered = state.load_history(list(reversed(reviews)), "me")
        self.assertEqual(len(recovered["findings"]), 500)
        self.assertEqual([f["body"] for f in recovered["findings"]],
                         [state.parse(concern(i))["body"] for i in range(500)])
        again = state.reconcile(reviews, [], [], "me", "f" * 40, [concern(0), concern(499)])
        self.assertEqual(again["comments"], [])

    def test_legacy_snapshot_remains_available_after_migration(self):
        old = state.reconcile([], [], [], "me", "a" * 40, [concern(i) for i in range(30)])
        reviews = [review(1, state.marker(old))]
        plan = state.reconcile(reviews, [], [], "me", "b" * 40, [concern(30)])
        body = state.complete_summary(plan, EVIDENCE)
        self.assertLess(len(body.encode()), 6000)
        reviews.append(review(2, body))
        self.assertEqual(len(state.load_history(reviews, "me")["findings"]), 31)

    def test_quiet_refresh_preserves_visible_history_and_next_round(self):
        reviews = []
        for turn in range(1, 4):
            plan = state.reconcile(reviews, [], [], "me", f"{turn:040x}", [concern(turn)])
            reviews.append(review(turn, state.complete_summary(plan, EVIDENCE)))
        original_ids = [f["id"] for f in state.load_history(reviews, "me")["findings"]]
        for turn in range(4, 10):
            plan = state.reconcile(reviews, [], [], "me", f"{turn:040x}", [])
            state.finalize(plan, [])
            marked = state.complete_summary(plan, EVIDENCE) + "\n<!-- diffhound-review v1 sha=aaa -->\n"
            reviews[-1]["body"] = state.refresh_summary(plan, marked, 3)
            self.assertIn(state.parse(concern(3))["body"], reviews[-1]["body"])
            self.assertNotIn("#pullrequestreview-3", reviews[-1]["body"])
            self.assertEqual([f["id"] for f in state.load_history(reviews, "me")["findings"]], original_ids)
        plan = state.reconcile(reviews, [], [], "me", "f" * 40, [concern(4)])
        reviews.append(review(4, state.complete_summary(plan, EVIDENCE)))
        self.assertEqual(len(state.load_history(reviews, "me")["findings"]), 4)

    def test_quiet_refresh_of_legacy_snapshot_keeps_its_findings(self):
        first = state.reconcile([], [], [], "me", "a" * 40, [concern(0)])
        reviews = [review(1, state.marker(first))]
        plan = state.reconcile(reviews, [], [], "me", "b" * 40, [])
        reviews[0]["body"] = state.refresh_summary(plan, state.complete_summary(plan, EVIDENCE), 1)
        self.assertIn(state.parse(concern(0))["body"], reviews[0]["body"])
        self.assertEqual(len(state.load_history(reviews, "me")["findings"]), 1)

    def test_missing_foreign_pending_or_cyclic_parent_fails_closed(self):
        first = state.reconcile([], [], [], "me", "a" * 40, [concern(0)])
        parent = review(1, state.complete_summary(first, EVIDENCE))
        second = state.reconcile([parent], [], [], "me", "b" * 40, [concern(1)])
        child = review(2, state.complete_summary(second, EVIDENCE))
        for older in [[], [dict(parent, user="someone-else")], [dict(parent, state="PENDING")]]:
            with self.subTest(older=len(older)), self.assertRaisesRegex(ValueError, "Missing parent"):
                state.load_history(older + [child], "me")
        _, payload = state.decode_history(parent["body"])
        payload["parent"] = 2
        with self.assertRaisesRegex(ValueError, "cyclic"):
            state.load_history([review(1, state.encode_history(payload)), child], "me")

    def test_resolution_reopen_and_alias_changes_survive_deltas(self):
        initial = "COMMENT: src/auth.py:10:SHOULD-FIX — Reject expired tokens"
        alias = "COMMENT: src/auth.py:30:SHOULD-FIX — Check the token expiry"
        first = state.reconcile([], [], [], "me", "a" * 40, [initial])
        reviews = [review(1, state.complete_summary(first, EVIDENCE))]
        second = state.reconcile(reviews, [], [], "me", "b" * 40, [alias])
        state.merge_aliases(second, state.semantic_prior(second, "me"), [alias], [(1, 1)])
        state.finalize(second, [])
        reviews.append(review(2, state.complete_summary(second, EVIDENCE)))
        comment = {"id": 55, "user": "me", "path": "src/auth.py", "line": 10,
                   "body": "Reject expired tokens\n<!-- diffhound-id v1: abc -->"}
        threads = [{"db_id": 55, "is_resolved": True}]
        resolved = state.reconcile(reviews, [comment], threads, "me", "c" * 40, [])
        reviews.append(review(3, state.complete_summary(resolved, EVIDENCE)))
        self.assertEqual(state.load_history(reviews, "me")["findings"][0]["status"], "RESOLVED")
        reopened = state.reconcile(reviews, [comment], threads, "me", "d" * 40, [alias])
        self.assertEqual(reopened["comments"], [alias])
        state.finalize(reopened, [alias])
        reviews.append(review(4, state.complete_summary(reopened, EVIDENCE)))
        again = state.reconcile(reviews, [comment], threads, "me", "e" * 40, [alias])
        self.assertEqual(again["comments"], [])

    def test_failed_refresh_can_fall_back_to_a_new_review_with_same_history(self):
        first = state.reconcile([], [], [], "me", "a" * 40, [concern(0)])
        reviews = [review(1, state.complete_summary(first, EVIDENCE))]
        quiet = state.reconcile(reviews, [], [], "me", "b" * 40, [])
        normal = state.complete_summary(quiet, EVIDENCE)
        state.refresh_summary(quiet, normal, 1)
        reviews.append(review(2, normal))
        self.assertEqual(len(state.load_history(reviews, "me")["findings"]), 1)

    def test_actual_refresh_helper_puts_a_recoverable_body(self):
        first = state.reconcile([], [], [], "me", "a" * 40, [concern(0)])
        reviews = [review(1, state.complete_summary(first, EVIDENCE))]
        plan = state.reconcile(reviews, [], [], "me", "b" * 40, [])
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            (tmp / "plan").write_text(json.dumps(plan))
            (tmp / "body").write_text(state.complete_summary(plan, EVIDENCE))
            root = Path(__file__).resolve().parents[1]
            result = subprocess.run(["bash", "-c", '''source "$1/lib/publish.sh"
source "$1/lib/lifecycle.sh"
cd "$2"
gh() {
  case "$*" in
    "api --method PUT -H Accept: application/vnd.github+json /repos/o/r/pulls/365/reviews/1 --input "*)
      cp "${@: -1}" sent.json ;;
    *) echo 'Unexpected API call' >&2; return 99 ;;
  esac
}
dh_refresh_review o r 365 1 body plan
''', "test", str(root), str(tmp)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            sent = json.loads((tmp / "sent.json").read_text())["body"]
            self.assertIn(state.parse(concern(0))["body"], sent)
            recovered = state.load_history([review(1, sent)], "me")
            self.assertEqual([f["id"] for f in recovered["findings"]], [state.parse(concern(0))["id"]])

    def test_quiet_refresh_retains_escalated_and_reopened_same_id(self):
        initial = "COMMENT: src/auth.py:10:NIT — Reject expired tokens"
        blocker = initial.replace(":NIT", ":BLOCKING")
        first = state.reconcile([], [], [], "me", "a" * 40, [initial])
        reviews = [review(1, state.complete_summary(first, EVIDENCE))]
        second = state.reconcile(reviews, [], [], "me", "b" * 40, [blocker])
        reviews.append(review(2, state.complete_summary(second, EVIDENCE)))
        quiet = state.reconcile(reviews, [], [], "me", "c" * 40, [])
        reviews[-1]["body"] = state.refresh_summary(quiet, state.complete_summary(quiet, EVIDENCE), 2)
        self.assertIn("- **BLOCKING** `src/auth.py:10` — Reject expired tokens", reviews[-1]["body"])
        comment = {"id": 55, "user": "me", "path": "src/auth.py", "line": 10,
                   "body": "Reject expired tokens\n<!-- diffhound-id v1: abc -->"}
        threads = [{"db_id": 55, "is_resolved": True}]
        resolved = state.reconcile(reviews, [comment], threads, "me", "d" * 40, [])
        reviews.append(review(3, state.complete_summary(resolved, EVIDENCE)))
        reopened = state.reconcile(reviews, [comment], threads, "me", "e" * 40, [blocker])
        reviews.append(review(4, state.complete_summary(reopened, EVIDENCE)))
        quiet = state.reconcile(reviews, [comment], threads, "me", "f" * 40, [])
        body = state.refresh_summary(quiet, state.complete_summary(quiet, EVIDENCE), 4)
        self.assertIn("- **BLOCKING** `src/auth.py:10` — Reject expired tokens", body)

    def test_merging_previously_stored_identity_does_not_resurrect_it(self):
        a = "COMMENT: src/auth.py:10:NIT — Check token expiry"
        b = "COMMENT: src/auth.py:20:SHOULD-FIX — Reject expired tokens"
        first = state.reconcile([], [], [], "me", "a" * 40, [a, b])
        reviews = [review(1, state.complete_summary(first, EVIDENCE))]
        escalated = a.replace(":NIT", ":SHOULD-FIX")
        merged = state.reconcile(reviews, [], [], "me", "b" * 40, [escalated])
        state.merge_aliases(merged, state.semantic_prior(merged, "me"), [escalated], [(1, 2)])
        state.finalize(merged, [])
        reviews.append(review(2, state.complete_summary(merged, EVIDENCE)))
        recovered = state.load_history(reviews, "me")
        self.assertEqual([f["id"] for f in recovered["findings"]], [state.parse(b)["id"]])
        quiet = state.reconcile(reviews, [], [], "me", "c" * 40, [])
        reviews[-1]["body"] = state.refresh_summary(quiet, state.complete_summary(quiet, EVIDENCE), 2)
        self.assertEqual(len(state.load_history(reviews, "me")["findings"]), 1)
        comments = [{"id": i, "user": "me", "path": "src/auth.py", "line": 10,
                     "body": text + "\n<!-- diffhound-id v1: abc -->"}
                    for i, text in [(55, "Check token expiry"), (56, "Reject expired tokens")]]
        resolved = state.reconcile(reviews, comments, [{"db_id": i, "is_resolved": True} for i in [55, 56]],
                                   "me", "d" * 40, [])
        self.assertEqual([f["status"] for f in resolved["findings"]], ["RESOLVED"])


if __name__ == "__main__":
    unittest.main()
