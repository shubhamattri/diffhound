"""Exercise assembled review bodies at the publication boundary, without APIs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import review_state as state
import review_body as budget


class ReviewBody(unittest.TestCase):
    def shell(self, script, *args, env=None):
        return subprocess.run(["bash", "-c", 'source "$1/lib/github.sh"; source "$1/lib/publish.sh"; '
                               'source "$1/lib/lifecycle.sh"; shift; ' + script, "test", str(ROOT), *map(str, args)],
                              text=True, capture_output=True, env={**os.environ, **(env or {})})

    def test_large_capped_review_posts_complete_findings_once(self):
        # Claro #365: 18 findings remain, 14 move out of inline comments. A
        # ~5 KB generated summary was expanded beyond the 30 KB guard.
        concerns = [(f"Concern {i}: " + (f"Preserve scenario {i} when the dependency fails. " * 18)).strip()
                    for i in range(18)]
        lines = [f"COMMENT: src/handler{i}.py:10:{'BLOCKING' if i == 0 else 'SHOULD-FIX'} — {body}"
                 for i, body in enumerate(concerns)]
        plan = state.reconcile([], [], [], "me", "a" * 40, lines)
        generated = ("Review evidence and verified behavior. " * 140)[:5251]
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            for name, value in {"plan": json.dumps(plan), "comments": "\n".join(lines) + "\n",
                                "summary": generated, "replies": ""}.items():
                (tmp / name).write_text(value)
            result = self.shell('set -e; cd "$1"; dh_cap_inline_comments comments 3 overflow; '
                                'sed "s/^COMMENT: //" comments > selected; '
                                'dh_finalize_summary plan selected overflow replies summary o r 365; '
                                'dh_summary_leak_reason summary', tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "", "assembled review rejected: " + result.stdout)
            body = (tmp / "summary").read_text()
            for concern in concerns:
                self.assertEqual(body.count(concern), 1)
            recovered = state.load_history([{"user": "me", "state": "COMMENTED", "body": body}], "me")
            self.assertEqual([f["body"] for f in recovered["findings"]], concerns)
            result = self.shell('set -e; cd "$1"; _dh_body_with_marker "$(cat summary)" ' + 'a' * 40 + ' > marked; '
                                'test -s marked', tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            marked = (tmp / "marked").read_text()
            self.assertLessEqual(len(marked.encode()), 30000)
            (tmp / "review.json").write_text(json.dumps({"body": marked, "comments": [], "event": "COMMENT"}))
            result = self.shell('''set -e; cd "$1"
gh() {
  case "$*" in
    "api --paginate /repos/o/r/pulls/365/reviews?per_page=100") printf '[]' ;;
    "api --method POST -H Accept: application/vnd.github+json -H X-GitHub-Api-Version: 2022-11-28 /repos/o/r/pulls/365/reviews --input "*)
      cp "${@: -1}" sent.json; echo POST >> calls; printf '{"id":42}' ;;
    *) echo "Unexpected GitHub call" >&2; return 99 ;;
  esac
}
dh_publish_review o r 365 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa COMMENT review.json replies
test "$_DH_POSTED" = true
''', tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((tmp / "calls").read_text(), "POST\n")
            self.assertEqual(json.loads((tmp / "sent.json").read_text())["body"], marked)

    def test_builder_refuses_bodies_over_default_limit(self):
        plan = state.reconcile([], [], [], "me", "b" * 40,
                               ["COMMENT: example.py:1:SHOULD-FIX — " + "Known concern with supporting context. " * 5000])
        with self.assertRaisesRegex(ValueError, "byte"):
            state.complete_summary(plan, "Generated review evidence for this change. " * 20)

    def test_builder_reserves_markers_and_counts_utf8_bytes(self):
        plan = state.reconcile([], [], [], "me", "b" * 40, [])
        generated = "Verified evidence. " * 20 + "界" * 200
        assembled = generated + state.summary(plan)
        wrapped = budget.SUMMARY_MARKER + "\n" + budget.with_review_marker(assembled, plan["sha"])
        required = len(wrapped.encode())
        self.assertGreater(required, len(wrapped))
        with patch.dict(os.environ, {"DIFFHOUND_MAX_BODY_CHARS": str(required)}):
            self.assertEqual(state.complete_summary(plan, generated), assembled)
            budget.require_fits(wrapped)
        with patch.dict(os.environ, {"DIFFHOUND_MAX_BODY_CHARS": str(required - 1)}):
            with self.assertRaises(ValueError):
                state.complete_summary(plan, generated)
            with self.assertRaises(ValueError):
                budget.require_fits(wrapped)

    def test_default_budget_accepts_150000_utf8_bytes(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(budget.max_bytes(), 150000)
            budget.require_fits("x" * 74529)
            budget.require_fits("界" * 50000)
            with self.assertRaisesRegex(ValueError, "150003 bytes"):
                budget.require_fits("界" * 50001)

    def test_configured_budget_accepts_150000_and_refuses_next_byte(self):
        with patch.dict(os.environ, {"DIFFHOUND_MAX_BODY_CHARS": "150000"}):
            budget.require_fits("x" * 150000)
            with self.assertRaisesRegex(ValueError, "150001 bytes"):
                budget.require_fits("x" * 150001)

    def test_invalid_configuration_fails_closed(self):
        for value in ["", "0", "-1", "oops", "150001", "3.5"]:
            with self.subTest(value=value), patch.dict(os.environ, {"DIFFHOUND_MAX_BODY_CHARS": value}):
                with self.assertRaises(ValueError):
                    budget.require_fits("hello")

    def test_every_write_path_refuses_oversized_body(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            (tmp / "body").write_text("界" * 101)
            (tmp / "review.json").write_text(json.dumps({"body": "界" * 101, "comments": []}))
            (tmp / "replies").write_text("")
            calls = [
                '_dh_gh_post_json /repos/o/r/pulls/1/reviews review.json',
                'dh_publish_review o r 1 aaa COMMENT review.json replies',
                'dh_update_review_body o r 1 5 body',
                'dh_upsert_summary o r 1 me body',
            ]
            for call in calls:
                with self.subTest(call=call):
                    result = self.shell('cd "$1"; _gh_api_all() { printf "[]"; }; '
                                        'gh() { echo UNEXPECTED_WRITE; return 99; }; ' + call,
                                        tmp, env={"DIFFHOUND_MAX_BODY_CHARS": "300"})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("UNEXPECTED_WRITE", result.stdout)
                    self.assertIn("byte", result.stderr)

    def test_crlf_bytes_are_checked_before_review_update(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            (tmp / "body").write_bytes(b"x\r\n" * 15)
            result = self.shell('cd "$1"; gh() { touch unexpected-write; }; '
                                'dh_update_review_body o r 1 5 body', tmp,
                                env={"DIFFHOUND_MAX_BODY_CHARS": "30"})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((tmp / "unexpected-write").exists())

    def test_inline_rejection_preserves_complete_history_without_duplication(self):
        concern = ("Full concern with essential supporting evidence. " * 30).strip()
        plan = state.reconcile([], [], [], "me", "a" * 40,
                               ["COMMENT: src/auth.py:10:BLOCKING — " + concern])
        history = state.summary(plan)
        generated = "Verified review. " + "x" * (29000 - len(history.encode()) - 17)
        body = state.complete_summary(plan, generated)
        self.assertEqual(len(body.encode()), 29000)
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            (tmp / "review.json").write_text(json.dumps({"body": body, "event": "COMMENT", "comments": [
                {"path": "src/auth.py", "line": 11, "body": concern + "\n<!-- diffhound-id v1: test -->"}]}))
            (tmp / "replies").write_text("")
            result = self.shell('''cd "$1"
_gh_api_all() { printf '[]'; }
gh() {
  case "$*" in
    "api --method POST -H Accept: application/vnd.github+json -H X-GitHub-Api-Version: 2022-11-28 /repos/o/r/pulls/1/reviews --input "*)
      echo POST >> calls
      if jq -e '.comments | length == 0' "${@: -1}" >/dev/null; then
        cp "${@: -1}" sent.json; printf '{"id":42}'
      else return 1; fi ;;
    *) touch unexpected-call; return 99 ;;
  esac
}
dh_publish_review o r 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa COMMENT review.json replies
''', tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((tmp / "unexpected-call").exists())
            self.assertEqual((tmp / "calls").read_text(), "POST\nPOST\n")
            sent = json.loads((tmp / "sent.json").read_text())["body"]
            self.assertEqual(sent.count(concern), 1)
            self.assertEqual(state.load_history([{"user": "me", "state": "COMMENTED", "body": sent}], "me")["findings"],
                             plan["findings"])

    def test_inline_and_reply_fallbacks_cannot_bypass_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            review = {"body": "Review evidence. " * 30, "event": "COMMENT",
                      "comments": [{"path": "src/auth.py", "line": 10, "body": "Full concern. " * 80}]}
            (tmp / "review.json").write_text(json.dumps(review))
            for pending in [False, True]:
                with self.subTest(pending=pending):
                    (tmp / "replies").write_text("55:src/auth.py:10:" + "Reply evidence. " * 80 + "\n" if pending else "")
                    (tmp / "calls").write_text("")
                    result = self.shell('''cd "$1"
_gh_api_all() { printf '[]'; }
dh_review_threads() { printf '[]'; }
_dh_review_submitted() { return 1; }
gh() {
  case "$*" in
    "api --method POST -H Accept: application/vnd.github+json -H X-GitHub-Api-Version: 2022-11-28 /repos/o/r/pulls/1/reviews --input "*)
      cp "${@: -1}" sent.json; echo POST >> calls
      if [ "$PENDING" = 1 ]; then printf '{"id":42,"node_id":"node42"}'; else return 1; fi ;;
    "api --method DELETE /repos/o/r/pulls/1/reviews/42") echo DELETE >> calls ;;
    *) echo UNEXPECTED_WRITE; return 99 ;;
  esac
}
dh_publish_review o r 1 aaa COMMENT review.json replies
''', tmp, env={"DIFFHOUND_MAX_BODY_CHARS": "1000", "PENDING": str(int(pending))})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("UNEXPECTED_WRITE", result.stdout)
                    self.assertEqual((tmp / "calls").read_text(), "POST\nDELETE\n" if pending else "POST\n")
                    self.assertLessEqual(len(json.loads((tmp / "sent.json").read_text())["body"].encode()), 1000)


if __name__ == "__main__":
    unittest.main()
