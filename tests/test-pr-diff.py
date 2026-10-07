"""Exercise the production fetch block with real Git history and a fake gh API."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class PullRequestDiff(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.repo = self.folder / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.test")
        (self.repo / "original.txt").write_text("keep this content\n")
        (self.repo / "deleted.txt").write_text("remove this content\n")
        self.commit("common ancestor")
        self.git("checkout", "-qb", "feature")
        self.git("mv", "original.txt", "renamed.txt")
        (self.repo / "deleted.txt").unlink()
        (self.repo / "large.txt").write_text(
            "".join(f"line {n}\n" for n in range(20001))
        )
        self.head = self.commit("large PR")
        self.git("checkout", "-q", "main")
        (self.repo / "base-only.txt").write_text("not part of the PR\n")
        self.base = self.commit("base advances independently")
        self.bin = self.folder / "bin"
        self.bin.mkdir()
        self.output = self.folder / "review.diff"
        self.output.write_text("stale diff must not survive a failure")
        self.fake_gh(
            "echo 'HTTP 406: Sorry, the diff exceeded the maximum number of lines (20000)' >&2\nexit 1"
        )

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], text=True
        ).strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def fake_gh(self, body):
        gh = self.bin / "gh"
        gh.write_text("#!/bin/bash\n" + body + "\n")
        gh.chmod(0o755)

    def fetch(self, base=None, head=None, design_only=False):
        review = (ROOT / "lib/review.sh").read_text()
        start = review.index('spinner_start "Fetching diff..."')
        end = review.index('_filter_diff_by_config "$DIFF_FILE"', start)
        block = review[start:end]
        if design_only:
            start = review.index('if [ "$DESIGN_ONLY" = true ]; then')
            end = review.index("  _design_mode=print;", start)
            block = review[start:end] + "\nfi\n"
        script = (
            """set -uo pipefail
source "$1/lib/platform.sh"
if [ -f "$1/lib/pr-diff.sh" ]; then source "$1/lib/pr-diff.sh"; fi
PR_NUMBER=7
DESIGN_ONLY=true
REPO_PATH=$2
BASE_SHA=$3
HEAD_SHA=$4
DIFF_FILE=$5
spinner_start() { :; }
spinner_fail() { echo "$*" >&2; }
cd "$REPO_PATH"
"""
            + block
        )
        return subprocess.run(
            [
                "bash",
                "-c",
                script,
                "_",
                str(ROOT),
                str(self.repo),
                base or self.base,
                head or self.head,
                str(self.output),
            ],
            env={**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"},
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def assert_complete_diff(self):
        diff = self.output.read_text()
        self.assertIn("+line 20000\n", diff)
        self.assertEqual(
            sum(line.startswith("+line ") for line in diff.splitlines()), 20001
        )
        self.assertIn("rename from original.txt\nrename to renamed.txt", diff)
        self.assertIn("-remove this content", diff)
        self.assertNotIn("base-only.txt", diff)
        self.assertNotIn("HTTP 406", diff)

    def test_oversized_diff_uses_pinned_merge_base_without_truncation(self):
        (self.repo / "large.txt").write_text("uncommitted unrelated content")
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete_diff()

    def test_shallow_clone_fetches_missing_base_and_history(self):
        source = self.repo
        self.repo = self.folder / "shallow"
        subprocess.run(
            [
                "git",
                "clone",
                "-q",
                "--depth=1",
                "--branch=feature",
                source.as_uri(),
                str(self.repo),
            ],
            check=True,
        )
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository"), "true")
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete_diff()

    def test_normal_api_response_is_preserved(self):
        self.fake_gh("printf 'diff --git a/ok b/ok\\n+API patch\\n'")
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "diff --git a/ok b/ok\n+API patch\n")

    def test_design_only_uses_the_complete_diff_too(self):
        result = self.fetch(design_only=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete_diff()

    def test_invalid_metadata_fails_without_partial_diff(self):
        result = self.fetch(base="null")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists() and self.output.stat().st_size)

    def test_auth_server_and_timeout_failures_do_not_use_git(self):
        for code, error in [
            (1, "HTTP 403: forbidden"),
            (1, "HTTP 500"),
            (124, "timed out"),
        ]:
            with self.subTest(error=error):
                self.fake_gh(f"echo partial\necho '{error}' >&2\nexit {code}")
                result = self.fetch()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertFalse(self.output.exists() and self.output.stat().st_size)

    def test_missing_commit_fails_without_partial_diff(self):
        result = self.fetch(base="a" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists() and self.output.stat().st_size)

    def test_unrelated_histories_fail_without_partial_diff(self):
        self.git("checkout", "--orphan", "unrelated")
        unrelated = self.commit("unrelated root")
        result = self.fetch(base=unrelated)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists() and self.output.stat().st_size)


if __name__ == "__main__":
    unittest.main()
