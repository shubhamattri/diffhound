"""One UTF-8 byte budget for assembled reviews and their GitHub transports."""
import json
import os
from pathlib import Path
import re
import sys

DEFAULT_MAX_BYTES = 30000
MAX_CONFIGURED_BYTES = 60000
SUMMARY_MARKER = "<!-- diffhound-summary v1 -->"
REVIEW_MARKER = re.compile(r"<!-- diffhound-review v1 sha=[0-9a-f]+ -->")


def max_bytes():
    """Keep the legacy environment name; the limit has always counted bytes."""
    value = os.environ.get("DIFFHOUND_MAX_BODY_CHARS", str(DEFAULT_MAX_BYTES))
    if not value.isascii() or not value.isdigit() or not 1 <= int(value) <= MAX_CONFIGURED_BYTES:
        raise ValueError(f"DIFFHOUND_MAX_BODY_CHARS must be 1..{MAX_CONFIGURED_BYTES} UTF-8 bytes")
    return int(value)


def require_fits(body):
    """Refuse an unrepresentable payload without trimming findings or state."""
    if not isinstance(body, str):
        raise ValueError("Review body must be text")
    size, limit = len(body.encode("utf-8")), max_bytes()
    if size > limit:
        raise ValueError(f"review body is {size} bytes (Diffhound limit {limit} bytes)")


def with_review_marker(body, sha):
    """Replace only review metadata, preserving the complete visible body."""
    return REVIEW_MARKER.sub("", body) + f"\n\n<!-- diffhound-review v1 sha={sha} -->\n"


def require_summary_fits(body, sha):
    """Reserve the exact review marker and the larger sticky-comment envelope."""
    require_fits(SUMMARY_MARKER + "\n" + with_review_marker(body, sha))


def main():
    command, *args = sys.argv[1:]
    if command == "mark":
        sys.stdout.write(with_review_marker(sys.stdin.buffer.read().decode("utf-8"), args[0]))
    elif command == "check":
        require_fits(Path(args[0]).read_bytes().decode("utf-8"))
    elif command == "check-json":
        require_fits(json.loads(Path(args[0]).read_text())["body"])
    elif command == "summary-marker":
        print(SUMMARY_MARKER)
    else:
        raise ValueError("Unknown review-body command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(f"Diffhound body budget: {error}", file=sys.stderr)
        sys.exit(1)
