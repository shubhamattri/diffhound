"""Synthetic peer gate tests: no private review contents or provider calls."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
from peer_output import validate

PROSE = (
    "The supplied change keeps the checked value and preserves the existing caller contract. "
    * 2
)


class PeerOutputTests(unittest.TestCase):
    def test_complete_markdown_preserves_exact_answer(self):
        for ending in (
            "*No additional issue was found (see `example_flag`).*",
            "**No additional issues found (within supplied context)**",
            "_No additional issues found._",
            "__No additional issues found.__",
            "***No additional issues found.***",
            "The caller uses `checkedValue()`",
            "```typescript\nreturn checkedValue;\n```",
            "~~~typescript\nreturn checkedValue;\n~~~",
            "````text\n``` is an example delimiter\n````",
        ):
            with self.subTest(ending=ending):
                answer = PROSE + "\n" + ending
                output, reason = validate(answer)
                self.assertEqual(output, answer + "\n")
                self.assertTrue(reason.startswith("complete_"))

    def test_unclosed_fences_cannot_hide_behind_punctuation(self):
        for ending in (
            "```typescript\nconst value = compute()",
            "```typescript\nconst value = compute()\n~~~",
            "````typescript\nconst value = compute()\n```",
            "```typescript\nconst value = compute()\n```typescript",
        ):
            with self.subTest(ending=ending):
                self.assertEqual(
                    validate(PROSE + "\n" + ending), ("", "unclosed_fence")
                )

    def test_incomplete_json_rejected_with_or_without_closed_wrapper(self):
        text = '{"description": "' + PROSE + '", "items": ["ended string"'
        for answer in (text, "```json\n" + text + "\n```"):
            self.assertEqual(validate(answer), ("", "invalid_json"))

    def test_complete_json_and_wrapper_remain_supported(self):
        text = json.dumps({"description": PROSE, "findings": []})
        for answer in (text, "```json\n" + text + "\n```"):
            self.assertEqual(validate(answer), (text + "\n", "complete_json"))

    def test_brackets_in_json_strings_do_not_bypass_json_validation(self):
        description = (
            "The caller reads values[0] before checking the supplied values. " + PROSE
        )
        for value in ([{"description": description}], [description], [[description]]):
            text = json.dumps(value)
            self.assertEqual(validate(text), (text + "\n", "complete_json"))
            self.assertEqual(validate(text[:-1]), ("", "invalid_json"))

    def test_leading_markdown_is_not_mistaken_for_a_json_array(self):
        for prefix in (
            "[P2] Keep the checked value.\n",
            "[Reference](https://example.invalid/docs).\n",
            "[1] Keep the checked value.\n",
            "[123](https://example.invalid/changes/123)\n",
        ):
            answer = prefix + PROSE
            self.assertEqual(
                validate(answer), (answer.rstrip() + "\n", "complete_text")
            )
        text = json.dumps([{"description": PROSE}])
        self.assertEqual(validate(text), (text + "\n", "complete_json"))
        self.assertEqual(validate("```json\n" + PROSE + "\n```"), ("", "invalid_json"))

    def test_cutoffs_and_unpaired_trailing_markup_are_rejected(self):
        for ending in (
            "because the caller",
            "an incomplete reply*",
            "finished.*",
            "finished.**",
            "finished.`",
            "**finished.*",
            "`finished.``",
        ):
            self.assertEqual(validate(PROSE + "\n" + ending), ("", "unfinished_text"))

    def test_byte_floor_and_noise_only_output(self):
        self.assertEqual(validate("a" * 98 + "."), ("", "too_short"))
        self.assertEqual(validate("a" * 99 + "."), ("a" * 99 + ".\n", "complete_text"))
        self.assertEqual(
            validate("tokens used 10000\nmcp startup: none"), ("", "too_short")
        )

    def test_shell_rejection_retains_private_raw_and_safe_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            file, archive = Path(tmp) / "answer", Path(tmp) / "private"
            answer = PROSE + " SYNTHETIC_PRIVATE_REVIEW still unfinished"
            file.write_text(answer)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1/lib/peer-validate.sh"; _validate_peer_output "$2" GEMINI "$3"',
                    "test",
                    str(ROOT),
                    str(file),
                    str(archive),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(file.read_text(), "GEMINI_UNAVAILABLE\n")
            self.assertEqual((archive / "GEMINI-raw.txt").read_text(), answer)
            metadata = json.loads((archive / "GEMINI-validation.json").read_text())
            self.assertEqual(
                metadata,
                {
                    "status": "unavailable",
                    "reason": "unfinished_text",
                    "input_bytes": len(answer.encode()),
                    "output_bytes": 0,
                },
            )
            self.assertEqual(archive.stat().st_mode & 0o777, 0o700)
            for path in archive.iterdir():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(
                "SYNTHETIC_PRIVATE_REVIEW",
                result.stdout + result.stderr + json.dumps(metadata),
            )

    def test_archive_disabled_and_unavailable_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "answer"
            file.write_text("GEMINI_UNAVAILABLE\n")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1/lib/peer-validate.sh"; _validate_peer_output "$2" GEMINI',
                    "test",
                    str(ROOT),
                    str(file),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(result.stdout + result.stderr, "")
            self.assertEqual(file.read_text(), "GEMINI_UNAVAILABLE\n")
            self.assertEqual(
                sorted(p.name for p in Path(tmp).iterdir()),
                ["answer", "answer.validation.json"],
            )
            self.assertEqual(
                json.loads(Path(str(file) + ".validation.json").read_text())["reason"],
                "unavailable",
            )

    def test_python_failure_fails_closed_without_stale_usable_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "answer"
            file.write_text(PROSE + ".")
            diagnostic = Path(str(file) + ".validation.json")
            diagnostic.write_text('{"status":"usable","reason":"complete_text"}')
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1/lib/peer-validate.sh"; python3() { return 1; }; _validate_peer_output "$2" GEMINI',
                    "test",
                    str(ROOT),
                    str(file),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(file.read_text(), "GEMINI_UNAVAILABLE\n")
            self.assertIn("validation failed", result.stderr)
            self.assertEqual(
                json.loads(diagnostic.read_text()),
                {"status": "unavailable", "reason": "validator_failure"},
            )


if __name__ == "__main__":
    unittest.main()
