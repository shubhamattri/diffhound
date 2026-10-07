"""Wait in one process so cancellation cannot orphan a lock-holding sleeper."""

import os
import signal
import sys
import time


def main():
    time.sleep(float(sys.argv[1]))
    for value in sys.argv[2:]:
        pid = int(value)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            print(f"Peer watchdog: process {pid} already exited", file=sys.stderr)


if __name__ == "__main__":
    main()
