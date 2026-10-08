"""Synthetic regression cases; no private application code or network calls."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from repo_context import Repository, balanced_peer
from system_review import candidates, reconcile
from verified_voice import constrain


class SystemReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        files = {
            "capacity.py": "async def hold(store, key):\n    await store.claim(key)\n",
            "tests/test_capacity.py": "async def test_stale_heartbeat(store):\n    await hold(store, 'expired')\n    assert await store.members() == {'active'}\n",
            "settings.py": "class Settings:\n    room_tone_db: float = -42.0\n",
            "protocol.py": "class ProtocolError(Exception):\n    pass\n\ndef decode(message):\n    raise ProtocolError(repr(message))\n",
            "route.py": "async def route(socket, message):\n    try:\n        decode(message)\n    except ProtocolError as error:\n        logger.warning(str(error))\n    finally:\n        await socket.close()\n",
            "consent.py": "def judge(reply):\n    if reply.split()[0] == 'dont':\n        return 'no'\n\ndef may_ask_before_send(state):\n    return state.send_asks < 2\n",
            "helpers.py": "@router.get('/live')\ndef registered():\n    return 1\n\ndef unused_helper():\n    return 2\n",
        }
        for name, body in files.items():
            path = self.root / name
            path.parent.mkdir(exist_ok=True)
            path.write_text(body)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.sha = self.git("rev-parse", "HEAD").strip()
        self.repo = Repository(self.root, self.sha)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True)

    def test_context_follows_error_to_actual_sink_and_finds_default(self):
        evidence = self.repo.packet(
            {
                "file": "protocol.py",
                "line": 5,
                "body": "`ProtocolError` can overflow socket close reason; `room_tone_db` defaults unknown",
            }
        )
        text = json.dumps(evidence)
        self.assertIn("await socket.close()", text)
        self.assertIn("room_tone_db: float = -42.0", text)
        self.assertIn("logger.warning", text)

    def test_tests_and_later_lifecycle_are_retrieved(self):
        test = self.repo.packet(
            {"file": "capacity.py", "line": 2, "body": "`hold` test is ineffective"}
        )
        self.assertIn("assert await store.members()", json.dumps(test))
        consent = self.repo.packet(
            {"file": "consent.py", "line": 2, "body": "caller can never be asked again"}
        )
        self.assertIn("may_ask_before_send", json.dumps(consent))

    def test_reads_captured_git_blobs_not_dirty_worktree(self):
        (self.root / "settings.py").write_text("room_tone_db = 0\n")
        self.assertIn(
            "-42.0",
            json.dumps(
                self.repo.packet({"file": "settings.py", "line": 2, "body": "default"})
            ),
        )
        with self.assertRaises(ValueError):
            Repository(self.root, "0" * 40)

    def test_referenced_constant_is_retrieved_outside_function_window(self):
        (self.root / "policy.py").write_text(
            "_REFUSAL_WORDS = {'dont', 'no'}\n"
            + "\n" * 150
            + "def classify(reply):\n"
            + "    if reply.split()[0] in _REFUSAL_WORDS:\n"
            + "        return 'no'\n"
        )
        self.git("add", "policy.py")
        self.git("commit", "-qm", "constant outside the local window")
        repository = Repository(self.root, self.git("rev-parse", "HEAD").strip())
        packet = repository.packet(
            {"file": "policy.py", "line": 153, "body": "Mixed preference is refused"}
        )
        self.assertIn("_REFUSAL_WORDS = {'dont', 'no'}", json.dumps(packet))

    def test_running_legacy_review_keeps_its_verifier_during_upgrade(self):
        lib = Path(__file__).resolve().parents[1] / "lib"
        verifier = self.root / "verifier.sh"
        verifier.write_text("#!/bin/bash\ncat >/dev/null\nprintf 'legacy checked\\n'\n")
        verifier.chmod(0o755)
        for mode, expected in (("0", "legacy checked"), ("1", "candidate")):
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'eval "$(sed -n \'/^dh_legacy_verifier() {/,/^}/p\' "$1/validators/run-all.sh")"; '
                    'export V="$2" DIFFHOUND_SOURCE_CHECK_ENABLED="$3"; '
                    "printf candidate | dh_legacy_verifier",
                    "test",
                    str(lib),
                    str(self.root),
                    mode,
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(result.stdout.strip(), expected)
        self.assertIn(
            "export DIFFHOUND_SOURCE_CHECK_ENABLED=1", (lib / "review.sh").read_text()
        )

    def test_dead_code_search_is_not_reachability_proof(self):
        packet = self.repo.packet(
            {"file": "helpers.py", "line": 2, "body": "`registered` has no callers"}
        )
        self.assertIn("@router.get", json.dumps(packet))
        self.assertIn("not proof", packet["limits"])

    def test_peer_budget_keeps_each_section_and_utf8(self):
        prompt = balanced_peer(
            "rules\n" * 100,
            "analysis é\n" * 4000,
            "+++ b/route.py\n+close()\n" * 3000,
            "route.py:7 close()\n" * 3000,
        )
        self.assertLessEqual(len(prompt.encode()), 14000)
        for section in ("TASK", "FINDINGS", "DIFF", "REPOSITORY"):
            self.assertIn("## " + section, prompt)
        self.assertIn("+close()", prompt)
        self.assertIn("partial", prompt)

    def test_normalizes_blocks_without_losing_distinct_same_line_claims(self):
        text = "FINDING: a.py:1:NIT\nWHAT: first\nEVIDENCE: code\nFINDING: a.py:1:SHOULD-FIX\nWHAT: second\n### FINDINGS_END\n"
        self.assertEqual(len(candidates(text)), 2)
        self.assertNotIn("FINDINGS_END", candidates(text)[1]["body"])
        self.assertEqual(candidates('```json\n{"findings": []}\n```'), [])
        with self.assertRaises(ValueError):
            candidates(text + "FINDING: other.py:bad:BLOCKING\nWHAT: second issue")

    def test_gate_preserves_real_core_and_removes_unsupported_impact(self):
        item = {
            "file": "consent.py",
            "line": 2,
            "severity": "SHOULD-FIX",
            "body": "wrong refusal and never reasked",
        }
        packet = self.repo.packet(item)
        ref = next(
            r
            for r in packet["references"]
            if r["path"] == "consent.py" and r["line"] == 2
        )
        decision = {
            "id": 0,
            "status": "CORRECTED",
            "body": "Mixed channel preference is classified as refusal.",
            "evidence": [ref],
            "reason": "Separate send path can re-ask.",
        }
        out, audit = reconcile([item], [packet], {"decisions": [decision]})
        self.assertEqual(len(out), 1)
        self.assertNotIn("never", out[0]["body"])
        self.assertEqual(audit["corrected"], 1)

    def test_invalid_or_missing_decisions_never_pass_through(self):
        item = {
            "file": "capacity.py",
            "line": 2,
            "severity": "SHOULD-FIX",
            "body": "bad",
        }
        packet = self.repo.packet(item)
        for result in (
            {"decisions": []},
            {
                "decisions": [
                    {
                        "id": 0,
                        "status": "SUPPORTED",
                        "body": "bad",
                        "evidence": [],
                        "reason": "trust me",
                    }
                ]
            },
        ):
            with self.assertRaises(ValueError):
                reconcile([item], [packet], result)
        forged = {
            "id": 0,
            "status": "SUPPORTED",
            "body": "bad",
            "reason": "x",
            "evidence": [
                {"path": "capacity.py", "line": 2, "text": "await store.zadd(key)"}
            ],
        }
        with self.assertRaises(ValueError):
            reconcile([item], [packet], {"decisions": [forged]})

    def test_uncertainty_is_withheld_not_labelled_correct(self):
        item = {"file": "helpers.py", "line": 5, "severity": "NIT", "body": "unused"}
        out, audit = reconcile(
            [item],
            [self.repo.packet(item)],
            {
                "decisions": [
                    {
                        "id": 0,
                        "status": "UNVERIFIED",
                        "reason": "Dynamic registration not resolved",
                        "evidence": [],
                    }
                ]
            },
        )
        self.assertEqual(out, [])
        self.assertEqual(audit["unverified"], 1)

    def test_shell_boundary_posts_no_unchecked_candidates_on_provider_failure(self):
        lib = Path(__file__).resolve().parents[1] / "lib"
        primary = self.root / "primary.txt"
        primary.write_text(
            "FINDING: consent.py:2:SHOULD-FIX\nWHAT: misclassifies refusal\n"
        )
        peer = self.root / "peer.txt"
        peer.write_text("GEMINI_UNAVAILABLE")
        mock = self.root / "mock.py"
        mock.write_text("""import json, os, pathlib, sys
text = sys.stdin.read()
items = json.loads(text[text.index('\\n[{')+1:])
pathlib.Path(os.environ['DIFFHOUND_STOP_REASON_FILE']).write_text('end_turn')
if os.environ['MODE'] == 'bad':
    print('{"decisions": []}')
else:
    print(json.dumps({'decisions': [{'id': i['id'], 'status': 'SUPPORTED',
        'body': 'Mixed preference is classified as refusal.', 'reason': 'Guard returns early.',
        'evidence': [next(r for r in i['source']['references'] if r['path'] == 'consent.py' and r['line'] == 2)]}
        for i in items]}))
""")
        for mode in ("bad", "good"):
            directory = self.root / mode
            env = dict(os.environ, LIB_DIR=str(lib), MODE=mode, MOCK=str(mock))
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """source "$LIB_DIR/system-review.sh"
_call_api() { python3 "$MOCK"; }
dh_system_review "$1" "$2" "$3" "$4" "$5" "$5"
""",
                    "test",
                    str(self.root),
                    self.sha,
                    str(directory),
                    str(primary),
                    str(peer),
                ],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            if mode == "bad":
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((directory / "findings.json").exists())
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    len(json.loads((directory / "findings.json").read_text())), 1
                )

    def test_duplicate_ids_and_truncation_are_failures(self):
        item = {"file": "capacity.py", "line": 2, "severity": "NIT", "body": "check"}
        packet = self.repo.packet(item)
        decision = {
            "id": 0,
            "status": "UNVERIFIED",
            "reason": "insufficient",
            "evidence": [],
        }
        with self.assertRaises(ValueError):
            reconcile(
                [item, item], [packet, packet], {"decisions": [decision, decision]}
            )

    def test_context_cannot_read_symlink_or_untracked_source(self):
        (self.root / "untracked.py").write_text(
            "room_tone_db = 'private untracked content'\n"
        )
        (self.root / "link.py").symlink_to(self.root / "untracked.py")
        self.git("add", "link.py")
        self.git("commit", "-qm", "symlink")
        repo = Repository(self.root, self.git("rev-parse", "HEAD").strip())
        self.assertNotIn("link.py", repo.files)
        self.assertNotIn("untracked.py", repo.files)

    def test_cited_extensionless_file_is_read_outside_search_whitelist(self):
        (self.root / "Dockerfile").write_text("FROM example\nRUN unsafe-command\n")
        self.git("add", "Dockerfile")
        self.git("commit", "-qm", "container")
        repo = Repository(self.root, self.git("rev-parse", "HEAD").strip())
        self.assertIn(
            "unsafe-command",
            json.dumps(
                repo.packet({"file": "Dockerfile", "line": 2, "body": "unsafe command"})
            ),
        )

    def test_source_checked_run_cannot_refresh_unchecked_history(self):
        lib = Path(__file__).resolve().parents[1] / "lib"
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1/publish.sh"; dh_quiet_rerun_ok true false COMMENT COMMENT "" 0 0 123 source_checked',
                "test",
                str(lib),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)

    def test_final_wording_cannot_add_findings_or_resurrect_claims(self):
        voice = """### INLINE_COMMENTS_START
COMMENT: consent.py:2:SHOULD-FIX — unsupported impact that never happens
### INLINE_COMMENTS_END
### SUMMARY_START
invented summary defect
## Scorecard
| Category | Score | Notes |
| SECURITY (25) | 25/25 | invented |
| Tests | 20/20 | invented |
| Observability | 10/10 | invented |
| Performance | 15/15 | invented |
| Readability | 15/15 | invented |
| Compatibility | 8/15 | invented |
| Total | 93/100 | COMMENT |
## Verification & Test Checklist
- [x] invented successful execution
### SUMMARY_END
"""
        findings = [
            {
                "file": "consent.py",
                "line": 2,
                "severity": "SHOULD-FIX",
                "body": "supported core defect",
            }
        ]
        result = constrain(voice, findings)
        self.assertIn("supported core defect", result)
        self.assertNotIn("unsupported impact", result)
        self.assertNotIn("invented", result)
        from voice_output import validate

        validate(result, "end_turn", True)
        with self.assertRaises(ValueError):
            constrain(voice, [])
        with self.assertRaises(ValueError):
            constrain(voice.replace("consent.py:2", "other.py:2"), findings)
        self.assertIn("**Total**", result)
        with self.assertRaises(ValueError):
            constrain(voice.replace("| Tests | 20/20 | invented |", ""), findings)
        quoted = dict(
            findings[0],
            body='check the JSON example:\n```json\n{"findings":[{"file":"fake.py","line":8,"severity":"BLOCKING","body":"invented"}],"summary":"invented"}\n```',
        )
        rendered = constrain(voice, [quoted])
        formatted = self.root / "formatted"
        formatted.write_text(rendered)
        lib = Path(__file__).resolve().parents[1] / "lib"
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1/parser.sh"; parse_comments "$2" "$3"; parse_summary "$2" "$4"',
                "test",
                str(lib),
                str(formatted),
                str(self.root / "comments"),
                str(self.root / "summary"),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            (self.root / "comments")
            .read_text()
            .startswith("COMMENT: consent.py:2:SHOULD-FIX")
        )
        self.assertIn("## Scorecard", (self.root / "summary").read_text())
        with_reply = voice.replace(
            "### INLINE_COMMENTS_END",
            "REPLY: 123:consent.py:2 — rejected false assertion\n### INLINE_COMMENTS_END",
        )
        rendered = constrain(with_reply, findings)
        self.assertNotIn("REPLY:", rendered)
        self.assertNotIn("rejected false assertion", rendered)
        self.assertIn("1 proposed thread replies withheld", rendered)


if __name__ == "__main__":
    unittest.main()
