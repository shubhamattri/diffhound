"""Validate the complete voice response before extracting publishable text."""

import re
import sys
from pathlib import Path

COMMENT = re.compile(
    r"^COMMENT: \S+:\d+:(?:BLOCKING|SHOULD-FIX|NIT|OPEN_QUESTION) — \S"
)
REPLY = re.compile(r"^REPLY: \d+:\S+:\d+ — \S")
INTERNAL = re.compile(
    r"^(?:### (?:INLINE_COMMENTS|SUMMARY|FINDINGS|SCORECARD)_(?:START|END)|(?:COMMENT|REPLY|FINDING|WHAT|EVIDENCE|IMPACT):)",
    re.MULTILINE,
)


def section(lines, name):
    """Return the one ordered, closed section; reject duplicate delimiters."""
    positions = []
    for suffix in ("START", "END"):
        matches = [
            i for i, line in enumerate(lines) if line.strip() == f"### {name}_{suffix}"
        ]
        if len(matches) != 1:
            raise ValueError(f"expected exactly one {name}_{suffix}")
        positions.append(matches[0])
    if positions[0] >= positions[1]:
        raise ValueError(f"unordered {name} section")
    return positions


def normalize_summary_headings(body):
    """Canonicalize the two required H3 headings inside a closed summary only."""
    lines = body.splitlines(keepends=True)
    start, end = section(lines, "SUMMARY")
    for index in range(start + 1, end):
        lines[index] = re.sub(
            r"^### (Scorecard|Verification & Test Checklist)(?=[ \t\r\n]*$)",
            r"## \1",
            lines[index],
        )
    return "".join(lines)


def validate(body, stop, findings_expected):
    """Require finished generation, complete sections and a readable scorecard."""
    if stop != "end_turn":
        raise ValueError(
            f"voice generation did not finish: {stop or 'missing stop reason'}"
        )
    body = normalize_summary_headings(body)
    lines = body.splitlines()
    start, end = section(lines, "SUMMARY")
    summary = "\n".join(lines[start + 1 : end])
    if not summary.strip() or INTERNAL.search(summary):
        raise ValueError("summary is empty or contains internal review metadata")
    if not re.search(r"^## Scorecard\s*$", summary, re.MULTILINE):
        raise ValueError("summary is missing its scorecard")
    if not re.search(
        r"^\|[^\n]*Total[^\n]*\|[^\n]*\d+/100[^\n]*\|[^\n]*(?:APPROVE|COMMENT|REQUEST_CHANGES)[^\n]*\|\s*$",
        summary,
        re.MULTILINE,
    ):
        raise ValueError("scorecard is missing its total or verdict")
    if not re.search(r"^## Verification & Test Checklist\s*$", summary, re.MULTILINE):
        raise ValueError("summary is missing its verification checklist")
    if not re.search(r"^- \[[ xX]\] \S", summary, re.MULTILINE):
        raise ValueError("verification checklist is empty")
    has_inline = any(line.strip().startswith("### INLINE_COMMENTS_") for line in lines)
    if findings_expected or has_inline:
        inline_start, inline_end = section(lines, "INLINE_COMMENTS")
        if inline_end >= start:
            raise ValueError("inline comments overlap the summary")
        inline = lines[inline_start + 1 : inline_end]
        comments = [line for line in inline if COMMENT.match(line)]
        if findings_expected and not comments:
            raise ValueError("voice output dropped all expected findings")
        for line in inline:
            if line.startswith(("COMMENT:", "REPLY:")) and not (
                COMMENT.match(line) or REPLY.match(line)
            ):
                raise ValueError("voice output contains an incomplete comment or reply")
        outside = (
            lines[:inline_start] + lines[inline_end + 1 : start] + lines[end + 1 :]
        )
    else:
        outside = lines[:start] + lines[end + 1 :]
    if any(line.strip() for line in outside):
        raise ValueError("voice output contains text outside its complete sections")
    return body


if __name__ == "__main__":
    try:
        normalized = validate(
            Path(sys.argv[1]).read_text(),
            Path(sys.argv[2]).read_text().strip(),
            sys.argv[3] == "true",
        )
        if len(sys.argv) > 4:
            Path(sys.argv[4]).write_text(normalized)
    except (ValueError, OSError) as error:
        print(f"Diffhound voice output: {error}", file=sys.stderr)
        sys.exit(1)
