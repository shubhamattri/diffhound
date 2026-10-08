"""Prepare and reconcile repository-backed finding decisions before voice rewriting."""

import json
import os
import re
import sys
from pathlib import Path

from repo_context import Repository, balanced_peer, clip

SEVERITIES = {"BLOCKING", "SHOULD-FIX", "NIT", "OPEN_QUESTION"}


def read_json(text):
    match = re.search(r"^```(?:json)?\s*\n(.*?)^```", text, re.MULTILINE | re.DOTALL)
    return json.loads(match[1] if match else text)


def candidates(text):
    """Accept both primary formats; embedded evidence JSON cannot shadow FINDING blocks."""
    matches = list(re.finditer(r"^[ \t]*FINDING:[^\n]*", text, re.MULTILINE))
    if matches:
        result = []
        for i, match in enumerate(matches):
            body = text[
                match.end() : matches[i + 1].start()
                if i + 1 < len(matches)
                else len(text)
            ]
            body = re.split(
                r"^#{1,6}\s+[\w-]+_(?:START|END)", body, maxsplit=1, flags=re.MULTILINE
            )[0].strip()
            header = re.fullmatch(
                r"[ \t]*FINDING:\s+([^\s:]+):(\d+)(?::|\s+—\s+)([A-Z_-]+)\s*",
                match[0],
            )
            if not header or header[3] not in SEVERITIES or int(header[2]) < 1:
                result.append(
                    {
                        "unverified": "No unambiguous source location and severity",
                        "body": match[0] + "\n" + body,
                    }
                )
                continue
            result.append(
                {
                    "file": header[1],
                    "line": int(header[2]),
                    "severity": header[3],
                    "body": body,
                }
            )
        return result
    try:
        value = read_json(text)
    except json.JSONDecodeError:
        if re.search(r"FINDING:|\"findings\"", text):
            raise ValueError("unparseable candidate findings")
        return []  # Peer challenges and scorecards are context, not new findings.
    return value if isinstance(value, list) else value.get("findings", [])


def reconcile(items, packets, response):
    decisions = response.get("decisions", [])
    ids = [d.get("id") for d in decisions]
    if any(type(i) is not int for i in ids) or sorted(ids) != list(range(len(items))):
        raise ValueError("incomplete, duplicate or unknown finding decisions")
    decisions = sorted(decisions, key=lambda d: d["id"])
    counts = {
        k: 0
        for k in (
            "supported",
            "corrected",
            "contradicted",
            "not_actionable",
            "unverified",
        )
    }
    kept = []
    # Every packet in this batch was supplied together from the same Git head.
    supplied = [ref for packet in packets for ref in packet["references"]]
    for item, packet, decision in zip(items, packets, decisions):
        status = decision.get("status", "").lower()
        if status not in counts or not decision.get("reason"):
            raise ValueError("invalid finding decision")
        evidence = decision.get("evidence", [])
        if status != "unverified" and (
            not evidence or any(ref not in supplied for ref in evidence)
        ):
            raise ValueError("decision lacks exact supplied source evidence")
        counts[status] += 1
        if status in {"supported", "corrected"}:
            body = decision.get("body", "").strip()
            if not body or re.search(
                r"^(?:COMMENT:|REPLY:|FINDING:|### )", body, re.MULTILINE
            ):
                raise ValueError("invalid corrected finding body")
            if any(ord(c) < 32 and c not in "\n\t" for c in body):
                raise ValueError("finding body contains transport control characters")
            if not any(
                ref["path"] == item["file"] and ref["line"] == item["line"]
                for ref in packet["references"]
            ):
                raise ValueError("finding location is not in captured source")
            severity = decision.get("severity", item["severity"])
            ranks = {"OPEN_QUESTION": 0, "NIT": 1, "SHOULD-FIX": 2, "BLOCKING": 3}
            if severity not in ranks or ranks[severity] > ranks[item["severity"]]:
                raise ValueError("verification cannot escalate severity")
            kept.append(
                {
                    "file": item["file"],
                    "line": item["line"],
                    "severity": severity,
                    "body": body,
                }
            )
    return kept, counts


def prepare(repo, sha, directory, paths):
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    (root / "format-version").write_text("2")
    items, withheld = [], []
    texts = [Path(path).read_text() for path in paths]
    for i, text in enumerate(texts):
        (root / f"input-{i}.txt").write_text(text)
    repository = Repository(repo, sha)
    for text in texts:
        for item in candidates(text):
            if (
                item.get("unverified")
                or not isinstance(item.get("file"), str)
                or not item.get("file")
                or item.get("severity") not in SEVERITIES
                or type(item.get("line")) is not int
                or item["line"] < 1
            ):
                withheld.append(item)
                continue
            item = {
                "file": item["file"],
                "line": item["line"],
                "severity": item["severity"],
                "body": "\n".join(
                    f"{k}: {item[k]}"
                    for k in (
                        "title",
                        "body",
                        "evidence",
                        "impact",
                        "reachable_path",
                        "rejected_alternative",
                        "suggestion",
                        "options",
                        "diff_line",
                        "claims",
                    )
                    if item.get(k)
                ),
            }
            if item not in items:
                items.append(item)
    instructions = Path(__file__).with_name("system-review-prompt.txt").read_text()
    voice_file = os.environ.get("DIFFHOUND_VERIFICATION_VOICE_FILE")
    if voice_file:
        instructions += (
            "\nStyle examples only; never borrow their facts or findings:\n"
            + clip(Path(voice_file).read_text(), 6000)
        )
    for offset in range(0, len(items), 8):
        batch = items[offset : offset + 8]
        packets = [repository.packet(item) for item in batch]
        payload = {"items": batch, "packets": packets}
        name = root / f"batch-{offset // 8:03d}"
        name.with_suffix(".json").write_text(json.dumps(payload))
        findings = [
            {
                "id": i,
                "finding": item,
                "source": packet,
                "peer_assessments": peer_assessments(item, texts[1:]),
            }
            for i, (item, packet) in enumerate(zip(batch, packets))
        ]
        name.with_suffix(".prompt").write_text(
            instructions + "\n" + json.dumps(findings, ensure_ascii=False)
        )
    (root / "withheld.json").write_text(json.dumps(withheld))
    (root / "count").write_text(str(len(items)))


def peer_assessments(item, texts):
    """Keep refutations as challenges even when the peer emits no new FINDING blocks."""
    excerpts = []
    for text in texts:
        lines = text.splitlines()
        selected = set()
        for i, line in enumerate(lines):
            if Path(item["file"]).name in line:
                selected.update(range(max(0, i - 2), min(len(lines), i + 4)))
        excerpts.append(clip("\n".join(lines[i] for i in sorted(selected)), 4000))
    return excerpts


def apply(directory):
    root, kept, totals = Path(directory), [], {}
    for path in sorted(root.glob("batch-*.json")):
        payload = json.loads(path.read_text())
        if path.with_suffix(".stop").read_text().strip() != "end_turn":
            raise ValueError("system review generation incomplete")
        findings, counts = reconcile(
            payload["items"],
            payload["packets"],
            read_json(path.with_suffix(".response").read_text()),
        )
        kept.extend(findings)
        for key, count in counts.items():
            totals[key] = totals.get(key, 0) + count
    if sum(totals.values()) != int((root / "count").read_text()):
        raise ValueError("system review batch coverage mismatch")
    version = root / "format-version"
    if version.exists():
        if version.read_text().strip() != "2":
            raise ValueError("unknown system review archive format")
        withheld = json.loads((root / "withheld.json").read_text())
    else:
        # Pre-upgrade prepare had no withheld-candidate path or version file.
        # All its candidate IDs were already checked against count above.
        withheld = []
    totals["unverified"] = totals.get("unverified", 0) + len(withheld)
    (root / "audit.json").write_text(json.dumps(totals))
    (root / "findings.json").write_text(json.dumps(kept))


if __name__ == "__main__":
    try:
        if sys.argv[1] == "prepare":
            prepare(*sys.argv[2:5], sys.argv[5:])
        elif sys.argv[1] == "apply":
            apply(sys.argv[2])
        elif sys.argv[1] == "peer":
            print(balanced_peer(*(Path(p).read_text() for p in sys.argv[2:6])))
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"System review stopped: {error}", file=sys.stderr)
        sys.exit(1)
