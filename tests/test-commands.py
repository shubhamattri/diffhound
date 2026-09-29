"""Command behavior with strict, stateful GitHub and model fakes."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("commands", ROOT / "lib/commands.py")
commands = importlib.util.module_from_spec(spec)
spec.loader.exec_module(commands)


class Commands(unittest.TestCase):
    def setUp(self):
        self.body = "Human context\n\nDo not remove this."
        self.head = "aaa"
        self.writes = []
        self.model_calls = []
        self.answer = {"body": "This PR rejects expired tokens in `src/auth.ts`."}

    def gh(self, endpoint, method="GET", payload=None):
        if method != "GET":
            self.writes.append((endpoint, method, payload))
            if endpoint == "/repos/o/r/pulls/7":
                self.body = payload["body"]
            return {"id": 99}
        if endpoint == "/repos/o/r/pulls/7":
            return {"title": "Validate tokens", "body": self.body, "head": {"sha": self.head}}
        if endpoint == "/repos/o/r/labels":
            return [{"name": "security"}, {"name": "bug"}]
        if endpoint == "/repos/o/r/issues/7/comments":
            return [{"id": 8, "user": {"login": "me"}, "body": "<!-- diffhound-command ask request=22 -->\nold"}]
        if endpoint == "/user":
            return {"login": "me"}
        raise AssertionError(f"Unexpected API endpoint: {endpoint}")

    def model(self, system, context):
        self.model_calls.append((system, context))
        return self.answer

    def run_command(self, command, apply=False, **kwargs):
        return commands.run(command, "o/r", 7, "diff --git a/auth.ts b/auth.ts\n+rejectExpired()",
                            self.gh, self.model, apply=apply, **kwargs)

    def test_draft_does_not_write_and_makes_one_model_call(self):
        result = self.run_command("describe")
        self.assertEqual(self.writes, [])
        self.assertFalse(result["applied"])
        self.assertEqual(len(self.model_calls), 1)
        self.assertIn("rejectExpired", self.model_calls[0][1])

    def test_description_preserves_human_context_and_replaces_its_region(self):
        self.run_command("describe", apply=True)
        self.answer = {"body": "Updated description"}
        self.run_command("describe", apply=True)
        self.assertIn("Human context\n\nDo not remove this.", self.body)
        self.assertEqual(self.body.count("<!-- diffhound-describe start -->"), 1)
        self.assertIn("Updated description", self.body)
        self.assertNotIn("This PR rejects", self.body)

    def test_changelog_separate_from_description(self):
        self.run_command("describe", apply=True)
        self.answer = {"body": "### Fixed\n- Reject expired tokens."}
        self.run_command("changelog", apply=True)
        self.assertIn("<!-- diffhound-describe start -->", self.body)
        self.assertIn("<!-- diffhound-changelog start -->", self.body)

    def test_labels_are_existing_only_additive(self):
        self.answer = {"labels": ["security", "security"]}
        self.run_command("labels", apply=True)
        self.assertEqual(self.writes, [("/repos/o/r/issues/7/labels", "POST", {"labels": ["security"]})])

    def test_invented_label_cannot_mutate(self):
        self.answer = {"labels": ["security", "nonexistent"]}
        with self.assertRaises(ValueError):
            self.run_command("labels", apply=True)
        self.assertEqual(self.writes, [])

    def test_empty_or_malformed_output_cannot_write(self):
        for answer in [{"body": ""}, {"body": 42}, {"body": "<!-- diffhound-describe end -->"}]:
            self.answer = answer
            with self.assertRaises(ValueError):
                self.run_command("describe", apply=True)
        self.assertEqual(self.writes, [])

    def test_head_change_refuses_write(self):
        def changing_model(system, context):
            self.head = "bbb"
            return self.answer
        with self.assertRaises(ValueError):
            commands.run("describe", "o/r", 7, "diff", self.gh, changing_model, apply=True)
        self.assertEqual(self.writes, [])

    def test_ask_retry_updates_same_answer(self):
        self.run_command("ask", apply=True, question="Why this change?", request_id="22")
        self.assertEqual(self.writes[0][:2], ("/repos/o/r/issues/comments/8", "PATCH"))
        self.assertIn("Why this change?", self.model_calls[0][1])

    def test_missing_question_and_truncated_context_do_not_call_model(self):
        with self.assertRaises(ValueError):
            self.run_command("ask")
        with self.assertRaises(ValueError):
            commands.run("describe", "o/r", 7, "x" * 200001, self.gh, self.model)
        self.assertEqual(self.model_calls, [])

    def test_event_requires_explicit_human_command_and_write_permission(self):
        event = {"action": "created", "issue": {"number": 7, "pull_request": {}},
                 "repository": {"full_name": "o/r"},
                 "comment": {"id": 22, "body": "/ask Why?", "user": {"login": "dev", "type": "User"}}}
        def permission(endpoint, *args):
            self.assertEqual(endpoint, "/repos/o/r/collaborators/dev/permission")
            return {"permission": "write"}
        self.assertEqual(commands.event_command(event, permission), ("ask", "o/r", 7, "Why?", "22"))
        with self.assertRaises(ValueError):
            commands.event_command(event, lambda *args: {"permission": "read"})
        for body in ["please /ask Why?", "<!-- diffhound-command ask -->\n/ask Why?", "/unrecognized"]:
            event["comment"]["body"] = body
            self.assertIsNone(commands.event_command(event, permission))
        event["comment"].update(body="/ask Why?", user={"login": "bot", "type": "Bot"})
        self.assertIsNone(commands.event_command(event, permission))


if __name__ == "__main__":
    unittest.main()
