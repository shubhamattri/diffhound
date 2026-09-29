"""A second process waits; closing the first process's descriptor releases it."""
import importlib.util
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("run_locked", ROOT / "lib/run_locked.py")
locks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(locks)


class ReviewLock(unittest.TestCase):
    def test_repo_slug_and_local_checkout_share_the_lock(self):
        with tempfile.TemporaryDirectory() as folder:
            subprocess.run(["git", "init", "-q", folder], check=True)
            subprocess.run(["git", "-C", folder, "remote", "add", "origin", "git@github.com:Owner/Repo.git"], check=True)
            with patch.dict(os.environ, {"REVIEW_REPO_PATH": folder, "GH_HOST": "github.com"}):
                self.assertEqual(locks.repository_identity(["7"]), locks.repository_identity(["7", "--repo", "owner/repo"]))
                self.assertEqual(locks.repository_identity(["7", "--repo=Owner/Repo"]), "github.com/owner/repo")

    def test_serializes_and_releases_without_stale_lock_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            fd = locks.acquire("o/r/7", Path(folder))
            code = "import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); import run_locked; print('ready',flush=True); run_locked.acquire('o/r/7',Path(sys.argv[2])); print('locked',flush=True)"
            process = subprocess.Popen([sys.executable, "-c", code, str(ROOT / "lib"), folder], stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(process.stdout.readline().strip(), "ready")
                self.assertEqual(select.select([process.stdout], [], [], 0.1)[0], [])
                os.close(fd)
                fd = None
                output, _ = process.communicate(timeout=3)
                self.assertEqual(output.strip(), "locked")
                self.assertEqual(process.returncode, 0)
            finally:
                if fd is not None:
                    os.close(fd)
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    unittest.main()
