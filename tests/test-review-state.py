"""Finding lifecycle across ephemeral runners; no network/model calls."""
import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
spec = importlib.util.spec_from_file_location("review_state", ROOT / "lib/review_state.py")
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class Lifecycle(unittest.TestCase):
    def finding(self, body="Reject expired tokens", path="src/auth.ts", line=10, severity="SHOULD-FIX"):
        return f"COMMENT: {path}:{line}:{severity} — {body}"

    def run_round(self, lines, previous=None, threads=(), comments=None):
        reviews = [] if previous is None else [{
            "id": 1, "user": "me", "state": "COMMENTED", "submitted_at": "2026-09-29",
            "body": state.marker(previous),
        }]
        return state.reconcile(reviews, comments or [], None if threads is None else list(threads), "me", "bbb", lines)

    def test_same_defect_moves_line_without_new_comment(self):
        first = self.run_round([self.finding()])
        second = self.run_round([self.finding(line=50)], first)
        self.assertEqual(second["comments"], [])
        self.assertEqual(second["duplicates"], 1)
        self.assertEqual(second["findings"][0]["line"], 50)
        self.assertEqual(second["findings"][0]["status"], "OPEN")

    def test_same_line_new_blocker_is_not_a_fixed_old_nit(self):
        first = self.run_round([self.finding("Typo in message", severity="NIT")])
        blocker = self.finding("Authentication always returns true", severity="BLOCKING")
        second = self.run_round([blocker], first)
        self.assertEqual(second["comments"], [blocker])
        self.assertEqual(len(second["findings"]), 2)

    def test_full_path_and_full_body_are_identity(self):
        body = "x" * 90
        result = self.run_round([self.finding(body + " A"), self.finding(body + " B"),
                                 self.finding(body + " A", path="test/auth.ts")])
        self.assertEqual(len(result["comments"]), 3)

    def test_severity_escalation_posts_again(self):
        first = self.run_round([self.finding(severity="NIT")])
        second = self.run_round([self.finding(severity="BLOCKING")], first)
        self.assertEqual(second["comments"], [self.finding(severity="BLOCKING")])
        self.assertEqual(second["findings"][0]["change"], "ESCALATED")

    def test_missing_from_incremental_review_does_not_resolve(self):
        first = self.run_round([self.finding()])
        second = self.run_round([], first)
        self.assertEqual(second["findings"][0]["status"], "OPEN")

    def test_resolved_thread_and_recurrence(self):
        first = self.run_round([self.finding()])
        comment = {"id": 55, "user": "me", "path": "src/auth.ts", "line": 10,
                   "body": "Reject expired tokens\n<!-- diffhound-id v1: abc -->"}
        threads = [{"db_id": 55, "is_resolved": True}]
        resolved = self.run_round([], first, threads, [comment])
        self.assertEqual(resolved["findings"][0]["status"], "RESOLVED")
        reopened = self.run_round([self.finding(line=30)], resolved, threads, [comment])
        self.assertEqual(reopened["comments"], [self.finding(line=30)])
        self.assertEqual(reopened["findings"][0]["change"], "REOPENED")
        # A still-resolved OLD thread must not reopen the same concern every push.
        again = self.run_round([self.finding(line=30)], reopened, threads, [comment])
        self.assertEqual(again["comments"], [])

    def test_pending_other_author_and_unmarked_history_are_ignored(self):
        first = self.run_round([self.finding()])
        for user, review_status, body in [("other", "COMMENTED", state.marker(first)),
                                          ("me", "PENDING", state.marker(first)),
                                          ("me", "COMMENTED", "manual review")]:
            with self.subTest(user=user, status=review_status):
                review = {"user": user, "state": review_status, "body": body}
                result = state.reconcile([review], [], [], "me", "ccc", [self.finding()])
                self.assertEqual(result["comments"], [self.finding()])

    def test_history_corruption_stops_instead_of_forgetting(self):
        review = {"user": "me", "state": "COMMENTED", "body": "<!-- diffhound-state v1: invalid -->"}
        with self.assertRaises(ValueError):
            state.reconcile([review], [], [], "me", "ccc", [])

    def test_unknown_thread_status_does_not_suppress(self):
        first = self.run_round([self.finding()])
        second = self.run_round([self.finding()], first, None)
        self.assertEqual(second["comments"], [self.finding()])

    def test_cap_overflow_is_remembered_before_inline_selection(self):
        first = self.run_round([self.finding(str(i), line=i + 1) for i in range(30)], threads=[])
        second = self.run_round([self.finding("29", line=99)], first, threads=[])
        self.assertEqual(second["comments"], [])
        self.assertEqual(len(second["findings"]), 30)

    def test_interactive_deselection_is_not_recorded_as_published(self):
        plan = self.run_round([self.finding(), self.finding("Second concern", line=20)])
        committed = state.finalize(plan, [self.finding()])
        self.assertEqual([f["body"] for f in committed["findings"]], ["Reject expired tokens"])
        again = self.run_round([self.finding("Second concern", line=20)], committed)
        self.assertEqual(again["comments"], [self.finding("Second concern", line=20)])

    def test_semantic_rewording_survives_future_rounds_and_resolution(self):
        first = self.run_round([self.finding()])
        reworded = self.finding("Do not accept expired tokens")
        second = self.run_round([reworded], first)
        prior = state.semantic_prior(second, "me")
        state.merge_aliases(second, prior, [reworded], [(1, 1)])
        third = self.run_round([reworded], second)
        self.assertEqual(third["comments"], [])
        comment = {"id": 55, "user": "me", "path": "src/auth.ts", "line": 10,
                   "body": "Reject expired tokens\n<!-- diffhound-id v1: abc -->"}
        resolved = self.run_round([], third, [{"db_id": 55, "is_resolved": True}], [comment])
        reopened = self.run_round([reworded], resolved, [{"db_id": 55, "is_resolved": True}], [comment])
        committed = state.finalize(reopened, [reworded])
        self.assertEqual(committed["findings"][0]["status"], "OPEN")
        self.assertEqual(committed["findings"][0]["change"], "REOPENED")

    def test_case_sensitive_code_is_not_normalized_into_same_defect(self):
        result = self.run_round([self.finding("Check `Token`"), self.finding("Check `token`")])
        self.assertEqual(len(result["comments"]), 2)

    def test_unit_separator_preserves_body_leading_dashes_and_resolution(self):
        for prefix in ["- ", "— ", "– ", "   - "]:
            with self.subTest(prefix=prefix):
                body = prefix + "Reject expired tokens"
                line = "COMMENT: src/auth.ts:10:SHOULD-FIX\x1f" + body
                first = self.run_round([line])
                self.assertEqual(first["findings"][0]["body"], body.strip())
                comment = {"id": 55, "user": "me", "path": "src/auth.ts", "line": 10,
                           "body": body + "\n<!-- diffhound-id v1: abc -->"}
                threads = [{"db_id": 55, "is_resolved": True}]
                resolved = self.run_round([], first, threads, [comment])
                self.assertEqual(len(resolved["findings"]), 1)
                self.assertEqual(resolved["findings"][0]["status"], "RESOLVED")
                reopened = self.run_round([line], resolved, threads, [comment])
                self.assertEqual(reopened["comments"], [line])

    def test_resolved_findings_never_enter_semantic_suppression(self):
        first = self.run_round([self.finding()])
        first["findings"][0]["status"] = "RESOLVED"
        second = self.run_round([self.finding("Another issue")], first)
        self.assertEqual(state.semantic_prior(second, "me"), [])

    def test_stored_history_cannot_make_empty_model_work_publishable(self):
        plan = self.run_round([self.finding("a long known concern " * 30)])
        for generated in ["", "APPROVE", state.marker(plan)]:
            with self.assertRaises(ValueError):
                state.complete_summary(plan, generated)

    def test_oversized_history_is_not_silently_truncated(self):
        plan = self.run_round([self.finding("concern " * 20000)])
        with self.assertRaises(ValueError):
            state.complete_summary(plan, "Review evidence " * 30)

    def test_human_unresolve_reopens_blocker_without_model_rediscovery(self):
        first = self.run_round([self.finding(severity="BLOCKING")])
        comment = {"id": 55, "user": "me", "path": "src/auth.ts", "line": 10,
                   "body": "Reject expired tokens\n<!-- diffhound-id v1: abc -->"}
        resolved = self.run_round([], first, [{"db_id": 55, "is_resolved": True}], [comment])
        reopened = self.run_round([], resolved, [{"db_id": 55, "is_resolved": False}], [comment])
        committed = state.finalize(reopened, [])
        self.assertEqual(committed["findings"][0]["status"], "OPEN")
        self.assertEqual(committed["findings"][0]["severity"], "BLOCKING")
        self.assertEqual(committed["findings"][0]["change"], "REOPENED")


if __name__ == "__main__":
    unittest.main()
