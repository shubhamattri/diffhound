"""Constrain the wording pass to source-checked findings; prevent post-gate invention."""

import json
import re
import sys
from collections import Counter
from pathlib import Path

from voice_output import section

HEADER = re.compile(
    r"^COMMENT: (.+?):(\d+):(BLOCKING|SHOULD-FIX|NIT|OPEN_QUESTION) — ", re.MULTILINE
)


def constrain(body, findings):
    """Preserve vetted bodies verbatim and build summary claims from that same set.

    The model retains layout duties and advisory numeric scoring. Its thread
    replies are not source-checked candidates, so this boundary withholds them.
    """
    lines = body.splitlines()
    start, end = section(lines, "SUMMARY")
    inline = "\n".join(lines[:start])
    expected = Counter((f["file"], str(f["line"]), f["severity"]) for f in findings)
    if Counter(match.groups() for match in HEADER.finditer(inline)) != expected:
        raise ValueError("wording added, removed or moved source-checked findings")
    replies = re.findall(
        r"^REPLY: .*?(?=^COMMENT: |^REPLY: |^### INLINE_COMMENTS_END)",
        inline,
        re.MULTILINE | re.DOTALL,
    )
    comments = [
        f"COMMENT: {f['file']}:{f['line']}:{f['severity']} — {f['body']}"
        for f in findings
    ]
    output = [
        "### INLINE_COMMENTS_START",
        *comments,
        "### INLINE_COMMENTS_END",
        "",
        "### SUMMARY_START",
    ]
    output.append(
        "Source-backed findings below. Scores are advisory; source inspection does not establish test execution."
    )
    if replies:
        output.append(
            f"{len(replies)} proposed thread replies withheld: their claims were not source-checked."
        )
    for severity, heading in (
        ("BLOCKING", "Blockers (must fix before merge)"),
        ("SHOULD-FIX", "Should-Fix"),
        ("NIT", "Nits"),
        ("OPEN_QUESTION", "Open Questions"),
    ):
        group = [f for f in findings if f["severity"] == severity]
        if group:
            output += ["", "### " + heading]
            output += [
                f"- `{f['file']}:{f['line']}` — " + re.sub(r"\s+", " ", f["body"])
                for f in group
            ]
    output += ["", "## Scorecard", "| Category | Score | Notes |", "|---|---|---|"]
    summary = "\n".join(lines[start + 1 : end])
    score = summary.split("## Scorecard", 1)[1].split("\n## ", 1)[0]
    categories = set()
    for row in score.splitlines():
        cells = [cell.strip() for cell in row.strip().strip("|").split("|")]
        if len(cells) != 3 or not re.fullmatch(r"\*{0,2}\d+/\d+\*{0,2}", cells[1]):
            continue
        category = re.fullmatch(
            r"\*{0,2}(Security|Tests|Observability|Performance|Readability|Compatibility|Total)(?: \(\d+%?\))?\*{0,2}",
            cells[0],
            re.IGNORECASE,
        )
        if not category:
            continue
        # Preserve only numeric assessments, never unchecked explanations or verdict prose.
        verdict = (
            "REQUEST_CHANGES"
            if any(f["severity"] == "BLOCKING" for f in findings)
            else (
                "COMMENT"
                if any(f["severity"] == "SHOULD-FIX" for f in findings)
                else "APPROVE"
            )
        )
        label = category[1].capitalize()
        if label in categories:
            raise ValueError("duplicate scorecard category")
        categories.add(label)
        note = verdict if label == "Total" else "Advisory; see source-backed findings"
        if label == "Total":
            label = "**Total**"
        output.append(f"| {label} | {cells[1]} | {note} |")
    if categories != {
        "Security",
        "Tests",
        "Observability",
        "Performance",
        "Readability",
        "Compatibility",
        "Total",
    }:
        raise ValueError("incomplete scorecard categories")
    output += [
        "",
        "## Verification & Test Checklist",
        "- [ ] Run the affected automated tests; source inspection did not execute them.",
        "- [ ] Exercise the changed flow and relevant callers before release.",
        "### SUMMARY_END",
        "",
    ]
    return "\n".join(output)


if __name__ == "__main__":
    try:
        target = Path(sys.argv[1])
        original = target.read_text()
        result = constrain(original, json.loads(Path(sys.argv[2]).read_text()))
        Path(str(target) + ".raw").write_text(original)
        Path(str(target) + ".withheld-replies").write_text(
            str(len(re.findall(r"^REPLY:", original, re.MULTILINE)))
        )
        target.write_text(result)
    except (ValueError, OSError, IndexError, KeyError) as error:
        print(f"Verified wording rejected: {error}", file=sys.stderr)
        sys.exit(1)
