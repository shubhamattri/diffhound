"""Exercise sweep deadlines without GitHub, providers, or real PRs."""

import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


class SweepBudgetTests(unittest.TestCase):
    def run_sweep(self, mode, cycle, review):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "repos.txt").write_text("example/repo\n")
            prs = [
                {
                    "number": n,
                    "headRefOid": str(n) * 40,
                    "updatedAt": "2020-01-01T00:00:00Z",
                    "isDraft": False,
                    "title": "fixture",
                    "author": {"is_bot": False},
                }
                for n in ((1,) if mode == "hung" else (1, 2))
            ]
            (root / "prs.json").write_text(json.dumps(prs))
            gh = root / "gh"
            gh.write_text(
                '#!/bin/bash\nif [ "$1" = pr ]; then cat "$DIFFHOUND_SWEEP_HOME/prs.json"; elif [ "$MODE" = metadata_fail ]; then exit 1; else echo "[]"; fi\n'
            )
            gh.chmod(0o755)
            reviewer = root / "reviewer"
            reviewer.write_text("""#!/bin/bash
echo "$1" >> "$DIFFHOUND_SWEEP_HOME/calls"
if [ "$MODE" = slow ]; then sleep 3.2; else sleep 10; fi
touch "$DIFFHOUND_SWEEP_HOME/finished-$1"
""")
            reviewer.chmod(0o755)
            env = dict(
                os.environ,
                PATH=str(root) + os.pathsep + os.environ["PATH"],
                DIFFHOUND_SWEEP_HOME=str(root),
                DIFFHOUND_BIN=str(reviewer),
                DIFFHOUND_SWEEP_CYCLE_BUDGET_SECONDS=str(cycle),
                DIFFHOUND_SWEEP_REVIEW_TIMEOUT_SECONDS=str(review),
                DIFFHOUND_SWEEP_GRACE_MIN="0",
                REVIEW_LOGIN="fixture",
                MODE=mode,
            )
            start = time.monotonic()
            result = subprocess.run(
                [
                    "bash",
                    str(Path(__file__).resolve().parents[1] / "bin/diffhound-sweep"),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            calls = (
                (root / "calls").read_text().splitlines()
                if (root / "calls").exists()
                else []
            )
            return (
                result,
                calls,
                [p.name for p in root.glob("finished-*")],
                time.monotonic() - start,
                [p.read_text().strip() for p in (root / "state").glob("*.attempts")],
            )

    def test_finished_review_is_not_interrupted_but_next_review_waits(self):
        result, calls, finished, elapsed, attempts = self.run_sweep("slow", 3, 10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["1"])
        self.assertEqual(finished, ["finished-1"])
        self.assertLess(elapsed, 10)
        self.assertEqual(attempts, ["1"])

    def test_invocation_timeout_returns_failure(self):
        result, calls, finished, elapsed, attempts = self.run_sweep("hung", 10, 1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["1"])
        self.assertEqual(finished, [])
        self.assertIn("diffhound exit=124", result.stderr)
        self.assertLess(elapsed, 6)
        self.assertEqual(attempts, ["1"])

    def test_missing_review_metadata_never_starts_or_charges_an_attempt(self):
        result, calls, finished, _, attempts = self.run_sweep("metadata_fail", 10, 1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(finished, [])
        self.assertEqual(attempts, [])
        self.assertIn("review metadata unavailable", result.stderr)


if __name__ == "__main__":
    unittest.main()
