"""Reject incomplete formatting before any review can be published."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("voice_output", ROOT / "lib/voice_output.py")
voice = importlib.util.module_from_spec(spec)
spec.loader.exec_module(voice)

COMPLETE = """### INLINE_COMMENTS_START
COMMENT: api/example.py:12:SHOULD-FIX — this loses the caller's update.
### INLINE_COMMENTS_END
### SUMMARY_START
the update needs to survive a retry.
### Should-Fix
- `api/example.py:12` — preserve the update.
## Scorecard
| Category | Score | Notes |
| Total | 93/100 | COMMENT |
## Verification & Test Checklist
- [ ] run the retry regression test
### SUMMARY_END
"""


class VoiceOutput(unittest.TestCase):
    def test_complete_review_and_clean_review(self):
        voice.validate(COMPLETE, "end_turn", True)
        clean = COMPLETE.replace(COMPLETE.splitlines()[1] + "\n", "")
        voice.validate(clean, "end_turn", False)
        voice.validate(clean[clean.index("### SUMMARY_START"):], "end_turn", False)

    def test_partial_and_complete_looking_token_exhaustion(self):
        for body in [COMPLETE.split("### INLINE_COMMENTS_END")[0], COMPLETE]:
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "max_tokens"):
                voice.validate(body, "max_tokens", True)

    def test_missing_duplicate_or_unordered_sections(self):
        for marker in ["INLINE_COMMENTS_START", "INLINE_COMMENTS_END", "SUMMARY_START", "SUMMARY_END"]:
            for body in [COMPLETE.replace("### " + marker, "missing"), COMPLETE + "### " + marker + "\n"]:
                with self.subTest(marker=marker), self.assertRaises(ValueError):
                    voice.validate(body, "end_turn", True)
        swapped = COMPLETE.replace("INLINE_COMMENTS_END", "TMP").replace("SUMMARY_START", "INLINE_COMMENTS_END").replace("TMP", "SUMMARY_START")
        with self.assertRaises(ValueError):
            voice.validate(swapped, "end_turn", True)

    def test_required_summary_fields_and_comments(self):
        for text in ["## Scorecard", "| Total | 93/100 | COMMENT |", "## Verification & Test Checklist", COMPLETE.splitlines()[1]]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                voice.validate(COMPLETE.replace(text, ""), "end_turn", True)

    def test_raw_metadata_and_malformed_comments_are_rejected(self):
        for body in [COMPLETE.replace("the update needs", "COMMENT: api/t\nthe update needs"), COMPLETE.replace(COMPLETE.splitlines()[1], "COMMENT: api/t")]:
            with self.assertRaises(ValueError):
                voice.validate(body, "end_turn", True)

    def test_missing_stop_reason_and_plain_prose_are_rejected(self):
        for stop in ["", "stop_sequence", "refusal"]:
            with self.subTest(stop=stop), self.assertRaises(ValueError):
                voice.validate(COMPLETE, stop, True)
        with self.assertRaises(ValueError):
            voice.validate("prose mentioning ### SUMMARY_START and ### SUMMARY_END", "end_turn", False)


if __name__ == "__main__":
    unittest.main()
