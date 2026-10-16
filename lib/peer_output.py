"""Conservative completeness checks for peer text, without judging its findings."""

import json
import re
import sys
from pathlib import Path


NOISE = re.compile(
    r"^(mcp startup:|OpenAI Codex v|workdir:|model:|provider:|approval:|"
    r"sandbox:|reasoning effort:|tokens used|--------$|Reading prompt from stdin)"
)
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
INLINE_END = re.compile(
    r"(?<![\w*_`])(\*{1,3}|_{1,3}|`+)(?![*_`])(\S(?:.*?\S)?)(?<![*_`])\1$"
)
JSON_ARRAY = re.compile(r'^\[\s*(?:[{"\[\]\d-]|true\b|false\b|null\b)')
MARKDOWN_PREFIX = re.compile(r'^\[[^\[\]{}"\n]+\](?:\([^)\n]*\))?\s+\S')


def fence_spans(lines):
    """Require matching fences; a closing fence only closes its own opening."""
    opening = None
    spans = []
    for index, line in enumerate(lines):
        match = FENCE.fullmatch(line)
        if not match:
            continue
        marker, suffix = match.groups()
        if opening is None:
            opening = (index, marker)
        elif (
            marker[0] == opening[1][0]
            and len(marker) >= len(opening[1])
            and not suffix.strip()
        ):
            spans.append((opening[0], index))
            opening = None
    return spans, opening is not None


def validate(text):
    lines = "\n".join(line for line in text.splitlines() if not NOISE.match(line))
    lines = lines.strip().splitlines()
    spans, unclosed = fence_spans(lines)
    if unclosed:
        return "", "unclosed_fence"
    # Strip only a single fence wrapping the entire response. A terminal code
    # example belongs to the answer and must retain both of its delimiters.
    wrapper = spans == [(0, len(lines) - 1)]
    normalized = "\n".join(lines[1:-1] if wrapper else lines).strip()
    if len(normalized.encode()) < 100:
        return "", "too_short"
    json_wrapper = wrapper and lines[0].lstrip("`~ ").strip().lower() == "json"
    json_array = JSON_ARRAY.match(normalized) and not MARKDOWN_PREFIX.match(normalized)
    if json_wrapper or normalized.startswith("{") or json_array:
        try:
            json.loads(normalized)
        except json.JSONDecodeError:
            return "", "invalid_json"
        return normalized + "\n", "complete_json"
    if spans and spans[-1][1] == len(lines) - 1 and not wrapper:
        return normalized + "\n", "complete_code_block"
    # Inspect punctuation inside paired terminal emphasis/inline code. Never
    # merely allow '*' or '`': those can also be unfinished delimiters.
    ending = normalized.splitlines()[-1]
    while match := INLINE_END.search(ending):
        ending = ending[: match.start()] + match[2]
    if ending[-1:] not in ']".!?)}':
        return "", "unfinished_text"
    return normalized + "\n", "complete_text"


def main():
    path, name = Path(sys.argv[1]), sys.argv[2]
    raw = path.read_bytes()
    if not raw:
        output, reason = "", "empty"
    elif raw.strip() == f"{name}_UNAVAILABLE".encode():
        output, reason = "", "unavailable"
    else:
        try:
            output, reason = validate(raw.decode("utf-8"))
        except UnicodeDecodeError:
            output, reason = "", "invalid_utf8"
    metadata = {
        "status": "usable" if output else "unavailable",
        "reason": reason,
        "input_bytes": len(raw),
        "output_bytes": len(output.encode()),
    }
    diagnostic = Path(str(path) + ".validation.json")
    diagnostic.touch(mode=0o600, exist_ok=True)
    diagnostic.chmod(0o600)
    diagnostic.write_text(json.dumps(metadata) + "\n")
    path.write_text(output or f"{name}_UNAVAILABLE\n")
    if not output and reason != "unavailable":
        detail = {"empty": "no output at all", "too_short": "output too short"}
        print(
            f"  warning: {name} {detail.get(reason, 'output incomplete')} "
            f"({reason}, {len(raw)}B) -- discarding",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
