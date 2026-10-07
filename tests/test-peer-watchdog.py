"""Peer completion must release inherited pipes and PR locks immediately."""

import fcntl
import logging
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class PeerWatchdog(unittest.TestCase):
    def assert_releases_lock_and_stdout(self, script, expected_exit):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "review.lock"
            fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            process = subprocess.Popen(
                ["bash", "-c", script, "test", str(ROOT / "lib")],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                pass_fds=(fd,),
                start_new_session=True,
            )
            os.close(fd)
            try:
                process.communicate(timeout=2)
                self.assertEqual(process.returncode, expected_exit)
                with path.open("w") as next_review:
                    fcntl.flock(next_review, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                # The broken implementation leaves sleep in this isolated group.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    logging.getLogger(__name__).debug(
                        "Watchdog test process group already exited"
                    )
                process.communicate(timeout=2)

    def test_peer_completion_releases_inherited_lock_and_stdout(self):
        source = (ROOT / "lib/review.sh").read_text()
        start = source.index("  # Allow two bounded model attempts")
        end_line = "  wait $_WATCHDOG_PID 2>/dev/null || true"
        end = source.index(end_line, start) + len(end_line)
        # Exercise the production launch/wait/cancel sequence with quick peers.
        script = "LIB_DIR=$1; _PEER_TIMEOUT=5\nsleep 0.1 & CODEX_PID=$!\nsleep 0.1 & GEMINI_PID=$!\n"
        self.assert_releases_lock_and_stdout(script + source[start:end], 0)

    def test_review_failure_cancels_the_watchdog_before_exiting(self):
        source = (ROOT / "lib/review.sh").read_text()
        cleanup = source[
            source.index("cleanup() {") : source.index("trap cleanup EXIT")
        ]
        script = 'LIB_DIR=$1; REPO_OWNER=""; dh_abandon_pending() { :; };\n' + cleanup
        script += '\npython3 "$LIB_DIR/peer_watchdog.py" 5 99999999 &\n_WATCHDOG_PID=$!\ntrap cleanup EXIT\nexit 1\n'
        self.assert_releases_lock_and_stdout(script, 1)

    def test_expired_watchdog_terminates_live_peer_after_an_exited_peer(self):
        exited = subprocess.Popen([sys.executable, "-c", "pass"])
        exited.wait(timeout=2)
        peer = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "lib/peer_watchdog.py"),
                    "0.05",
                    str(exited.pid),
                    str(peer.pid),
                ],
                capture_output=True,
                timeout=2,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(peer.wait(timeout=2), -signal.SIGTERM)
        finally:
            if peer.poll() is None:
                peer.kill()
            peer.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
