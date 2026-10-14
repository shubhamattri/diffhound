"""Prepare and reconcile repository-backed finding decisions before voice rewriting."""

import json
import os
import re
import sys
from pathlib import Path

from repo_context import Repository, balanced_peer, clip

SEVERITIES = {"BLOCKING", "SHOULD-FIX", "NIT", "OPEN_QUESTION"}
STATUSES = ("supported", "corrected", "contradicted", "not_actionable", "unverified")


def read_json(text):
    match = re.search(r"^```(?:json)?\s*\n(.*?)^```", text, re.MULTILINE | re.DOTALL)
    return json.loads(match[1] if match else text)


def candidates(text, *, primary=False):
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
                if unanchored(match[0]).get("status_note"):
                    continue
                result.append(
                    {
                        "unverified": "No unambiguous source location and severity",
                        "body": match[0] + "\n" + body,
                        **unanchored(match[0]),
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
    if re.search(
        r"^#{1,6}\s+FINDINGS_START\s*\n\s*#{1,6}\s+FINDINGS_END\s*$", text, re.MULTILINE
    ):
        return []
    try:
        value = read_json(text)
    except json.JSONDecodeError:
        if primary:
            raise ValueError("unrecognized primary finding format") from None
        if re.search(
            r'^\s*(?:\{|\[\s*(?:\{|$)|```json\b|"findings"\s*:)', text, re.MULTILINE
        ):
            raise ValueError("unparseable candidate findings")
        return []  # Peer challenges and scorecards are context, not new findings.
    if isinstance(value, list):
        result = value
    elif isinstance(value, dict):
        result = value.get("findings")
    else:
        result = None
    if result is None and not primary:
        return []
    if not isinstance(result, list) or any(
        not isinstance(item, dict) for item in result
    ):
        raise ValueError(
            "invalid primary finding format" if primary else "invalid peer findings"
        )
    return result


SEVERITY_SLOT = re.compile(
    r"(BLOCKING|BLOCKER|SHOULD[-_ ]FIX|NIT|OPEN[-_ ]QUESTION)(?![\w-])", re.IGNORECASE
)
QUALIFIER = re.compile(r"\(?[A-Za-z_-]+\)?|\d+|")
FILE_LINE = re.compile(r"([\w./-]+\.[A-Za-z]\w*)(?::(\d+)\b)?")


def _severity_slot(rest):
    """Severity from the slot after the location; location qualifiers may come first, prose may not."""
    for segment in re.split(r"\s*[:—]\s*", rest.strip()):
        match = SEVERITY_SLOT.match(segment)
        if match:
            word = re.sub(r"[-_ ]", "-", match[1].upper())
            return {"BLOCKER": "BLOCKING", "OPEN-QUESTION": "OPEN_QUESTION"}.get(word, word)
        if not QUALIFIER.fullmatch(segment) or SEVERITY_SLOT.search(segment):
            return None
    return None


def unanchored(header):
    """Files, line and severity of a header the strict form rejects, for anchoring.

    A header with no severity in its slot stays unanchored: guessing one could lower a blocker.
    """
    text = header.split("FINDING:", 1)[-1].replace("*", "").replace("`", "")
    if re.fullmatch(r"\s*[\w./-]+(?::(?:\d+|general))?\s*(?::|\s—\s)\s*(?:FIXED|RESOLVED)\s*", text):
        return {"status_note": True}  # A thread status, not a claim about the code.
    matches = list(FILE_LINE.finditer(text))
    if not matches:
        return {}
    found = {"paths": list(dict.fromkeys(m[1] for m in matches))}
    severity = _severity_slot(text[matches[-1].end():])
    if not severity:
        return found
    found["severity"] = severity
    numbered = [(m[1], int(m[2])) for m in matches if m[2] and int(m[2]) > 0]
    if numbered:
        found["located"] = list(numbered[0])
    return found


def source_reference(ref, supplied):
    """Resolve supplied source; never repair both quote whitespace and location."""
    if (
        not isinstance(ref, dict)
        or set(ref) != {"path", "line", "text"}
        or type(ref["line"]) is not int
        or ref["line"] < 1
        or not isinstance(ref["path"], str)
        or not isinstance(ref["text"], str)
    ):
        raise ValueError("decision lacks exact supplied source evidence")
    if ref in supplied:
        return ref
    for candidate in supplied:
        if (
            candidate["path"] == ref["path"]
            and candidate["line"] == ref["line"]
            and candidate["text"].strip(" \t") == ref["text"].strip(" \t")
        ):
            return candidate
    matches = {
        candidate["line"]: candidate
        for candidate in supplied
        if candidate["path"] == ref["path"] and candidate["text"] == ref["text"]
    }
    if len(matches) != 1:
        raise ValueError("decision lacks exact supplied source evidence")
    return next(iter(matches.values()))


def reconcile(items, packets, response, unchecked=None, supplied=None):
    decisions = response.get("decisions", [])
    ids = [d.get("id") for d in decisions]
    if any(type(i) is not int for i in ids) or sorted(ids) != list(range(len(items))):
        raise ValueError("incomplete, duplicate or unknown finding decisions")
    decisions = sorted(decisions, key=lambda d: d["id"])
    counts = dict.fromkeys(STATUSES, 0)
    kept = []
    # Every packet in this batch was supplied together from the same Git head.
    if supplied is None:
        supplied = [ref for packet in packets for ref in packet["references"]]
    if unchecked is None:
        unchecked = []
    for item, packet, decision in zip(items, packets, decisions):
        status = decision.get("status", "").lower()
        if status not in STATUSES or not decision.get("reason"):
            raise ValueError("invalid finding decision")
        record = {
            "file": item["file"],
            "line": item["line"],
            "severity": item["severity"],
            "claim": item["body"],
            "reason": decision["reason"],
        }
        if status == "unverified":
            unchecked.append(record)
        evidence = decision.get("evidence", [])
        if status != "unverified":
            try:
                if not isinstance(evidence, list) or not evidence:
                    raise ValueError("decision lacks exact supplied source evidence")
                resolved = [source_reference(ref, supplied) for ref in evidence]
            except ValueError:
                # One unchecked claim must neither publish nor discard its neighbors.
                # Audit uncertainty also prevents this review from approving the PR.
                counts["unverified"] += 1
                counts["evidence_failures_withheld"] = (
                    counts.get("evidence_failures_withheld", 0) + 1
                )
                unchecked.append(dict(record, reason="its quoted code does not match the source"))
                continue
            repaired = sum(a["line"] != b["line"] for a, b in zip(resolved, evidence))
            if repaired:
                counts["citation_locations_corrected"] = (
                    counts.get("citation_locations_corrected", 0) + repaired
                )
            whitespace = sum(a["text"] != b["text"] for a, b in zip(resolved, evidence))
            if whitespace:
                counts["citation_whitespace_corrected"] = (
                    counts.get("citation_whitespace_corrected", 0) + whitespace
                )
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
            if severity not in ranks:
                raise ValueError("invalid verification severity")
            if ranks[severity] > ranks[item["severity"]]:
                # A disputed classification cannot become a published finding.
                counts[status] -= 1
                counts["unverified"] += 1
                counts["severity_escalations_withheld"] = (
                    counts.get("severity_escalations_withheld", 0) + 1
                )
                unchecked.append(dict(record, reason="the check rated it more severe than the reviewer did"))
                continue
            kept.append(
                {
                    "file": item["file"],
                    "line": item["line"],
                    "severity": severity,
                    "body": body,
                }
            )
    return kept, counts


def checker_instructions():
    instructions = Path(__file__).with_name("system-review-prompt.txt").read_text()
    voice_file = os.environ.get("DIFFHOUND_VERIFICATION_VOICE_FILE")
    if voice_file:
        instructions += (
            "\nStyle examples only; never borrow their facts or findings:\n"
            + clip(Path(voice_file).read_text(), 6000)
        )
    return instructions


def strip_header(body):
    return re.sub(r"^[ \t]*FINDING:[^\n]*\n?", "", body, flags=re.M)


def changed_lines(diff):
    """(path, line) pairs added by the diff, as PR-scope enforcement counts them."""
    changed, path, line = set(), "", 0
    for row in diff.splitlines():
        if row.startswith("diff --git"):
            path = ""
        elif row.startswith("+++ b/"):
            path = row[6:]
        elif row.startswith("@@ "):
            match = re.search(r"\+(\d+)", row)
            line = int(match[1]) - 1 if match else 0
        elif path and row.startswith("+") and not row.startswith("+++"):
            line += 1
            changed.add((path, line))
        elif path and row.startswith(" "):
            line += 1
    return changed


def prepare(repo, sha, directory, paths):
    root = Path(directory)
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    (root / "format-version").write_text("2")
    items, withheld = [], []
    texts = [Path(path).read_text() for path in paths]
    for i, text in enumerate(texts):
        (root / f"input-{i}.txt").write_text(text)
    repository = Repository(repo, sha)
    diff_file = os.environ.get("DIFFHOUND_DIFF_FILE")
    changed = changed_lines(Path(diff_file).read_text()) if diff_file and Path(diff_file).is_file() else set()
    for index, text in enumerate(texts):
        for item in candidates(text, primary=index == 0):
            if item.get("unverified") and item.get("severity"):
                located = item.get("located")
                found = (
                    tuple(located)
                    if located and repository.has_line(*located)
                    else repository.anchor(item["paths"], strip_header(item["body"]), changed)
                )
                if found:
                    item = {
                        "file": found[0],
                        "line": found[1],
                        "severity": item["severity"],
                        "body": "files: " + " + ".join(item["paths"]) + "\n" + item["body"],
                    }
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
    instructions = checker_instructions()
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


SECOND_LOOK = (
    "\nSecond look: each candidate below was UNVERIFIED before. The source you named in"
    " needs has been added to its evidence where the repository has it. Decide again; if it"
    " is still insufficient, answer UNVERIFIED with empty needs.\n"
)


def retry(repo, sha, directory):
    """One more look for UNVERIFIED claims, with the source the checker said it needed."""
    root, repository = Path(directory), None
    items, packets, origins = [], [], []
    texts = [p.read_text() for p in sorted(root.glob("input-*.txt"))]
    for path in sorted(root.glob("batch-*.json")):
        payload = json.loads(path.read_text())
        decisions = read_json(path.with_suffix(".response").read_text()).get("decisions", [])
        for decision in decisions:
            index, needs = decision.get("id"), decision.get("needs")
            if not isinstance(needs, list):
                continue
            needs = [n for n in needs if isinstance(n, str) and n.strip()][:6]
            if (
                str(decision.get("status", "")).upper() != "UNVERIFIED"
                or not needs
                or type(index) is not int
                or not 0 <= index < len(payload["items"])
            ):
                continue
            repository = repository or Repository(repo, sha)
            packet = repository.second_look(payload["packets"][index], needs)
            if not packet["second_look"]:
                continue  # Nothing new to show; asking again would only repeat the answer.
            items.append(payload["items"][index])
            packets.append(packet)
            origins.append([path.stem, index])
    instructions = checker_instructions() + SECOND_LOOK
    for offset in range(0, len(items), 8):
        name = root / f"retry-{offset // 8:03d}"
        batch = slice(offset, offset + 8)
        name.with_suffix(".json").write_text(
            json.dumps({"items": items[batch], "packets": packets[batch], "origins": origins[batch]})
        )
        findings = [
            {
                "id": i,
                "finding": item,
                "source": packet,
                "peer_assessments": peer_assessments(item, texts[1:]),
            }
            for i, (item, packet) in enumerate(zip(items[batch], packets[batch]))
        ]
        name.with_suffix(".prompt").write_text(
            instructions + "\n" + json.dumps(findings, ensure_ascii=False)
        )


def _decided(path):
    if path.with_suffix(".stop").read_text().strip() != "end_turn":
        raise ValueError("system review generation incomplete")
    return read_json(path.with_suffix(".response").read_text())


def _usable_retry(path):
    """A failed second look keeps the first decisions; it never stops the review."""
    try:
        payload, response = json.loads(path.read_text()), _decided(path)
        reconcile(payload["items"], payload["packets"], response, [])
        return payload, response
    except (ValueError, OSError, KeyError, TypeError, AttributeError) as error:
        print(
            f"Second look {path.stem} unusable ({type(error).__name__}); keeping first decisions",
            file=sys.stderr,
        )
        return None


def apply(directory):
    root, kept, totals, unchecked = Path(directory), [], {}, []
    retries = [r for r in map(_usable_retry, sorted(root.glob("retry-*.json"))) if r]
    replaced = {}
    for payload, _ in retries:
        for stem, index in payload["origins"]:
            replaced.setdefault(stem, set()).add(index)
    rounds = []
    for path in sorted(root.glob("batch-*.json")):
        payload, response = json.loads(path.read_text()), _decided(path)
        # Evidence stays checkable against the whole batch, including retried neighbours.
        supplied = [ref for packet in payload["packets"] for ref in packet["references"]]
        skip = replaced.get(path.stem, set())
        if skip:
            decisions = response.get("decisions", [])
            ids = [d.get("id") for d in decisions]
            if any(type(i) is not int for i in ids) or sorted(ids) != list(
                range(len(payload["items"]))
            ):
                raise ValueError("incomplete, duplicate or unknown finding decisions")
            keep = [i for i in range(len(payload["items"])) if i not in skip]
            by_id = {d["id"]: d for d in decisions}
            payload = {
                "items": [payload["items"][i] for i in keep],
                "packets": [payload["packets"][i] for i in keep],
            }
            response = {"decisions": [dict(by_id[i], id=n) for n, i in enumerate(keep)]}
        rounds.append((payload, response, supplied))
    rounds += [(payload, response, None) for payload, response in retries]
    for payload, response, supplied in rounds:
        findings, counts = reconcile(
            payload["items"], payload["packets"], response, unchecked, supplied
        )
        kept.extend(findings)
        for key, count in counts.items():
            totals[key] = totals.get(key, 0) + count
    if sum(totals.get(status, 0) for status in STATUSES) != int(
        (root / "count").read_text()
    ):
        raise ValueError("system review batch coverage mismatch")
    if retries:
        totals["second_look"] = sum(len(payload["origins"]) for payload, _ in retries)
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
    unchecked += [
        {
            "file": " + ".join(item.get("paths") or []) or None,
            "line": None,
            "severity": item.get("severity"),
            "claim": item.get("body", ""),
            "reason": "it names no line the check could find in the code",
        }
        for item in withheld
    ]
    (root / "audit.json").write_text(json.dumps(totals))
    (root / "findings.json").write_text(json.dumps(kept))
    (root / "unchecked.json").write_text(json.dumps(unchecked))


def _inert(text):
    """Reviewer text shown verbatim must not open HTML comments, mention people or break code spans."""
    return text.replace("<!--", "&lt;!--").replace("-->", "--&gt;").replace("@", "@\u200b").replace("`", "'")


def render_unchecked(directory, held, replies=0, limit=8):
    """Markdown listing the claims the check could not settle, so a person can."""
    rows = json.loads((Path(directory) / "unchecked.json").read_text())
    replies = int(replies or 0)
    if not rows and not replies:
        return ""
    count = f"{len(rows) + replies} reviewer claim(s) could not be checked against the code."
    lead = "Approval held: " + count if held == "held" else count[0].upper() + count[1:]
    lines = ["", "### Couldn't confirm, please check", lead + " Check each one and reply on the PR."]
    for row in rows[:limit]:
        where = row["file"] or "unlocated"
        if row["line"]:
            where += f":{row['line']}"
        claim = re.sub(r"^(?:FINDING|files):[^\n]*\n?", "", row["claim"], flags=re.M)
        claim = re.sub(r"^(?:(?:title|body|evidence|impact|suggestion|WHAT|EVIDENCE):\s*)+", "", claim, flags=re.M)
        claim = " ".join(claim.split())
        reason = clip(" ".join(row["reason"].split()), 200)
        lines.append(f"- `{_inert(where)}`: {_inert(clip(claim, 280))} _(not confirmed: {_inert(reason)})_")
    if len(rows) > limit:
        lines.append(f"- and {len(rows) - limit} more.")
    if replies:
        lines.append(f"- {replies} proposed thread repl{'y' if replies == 1 else 'ies'} also withheld, unchecked.")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    try:
        if sys.argv[1] == "prepare":
            prepare(*sys.argv[2:5], sys.argv[5:])
        elif sys.argv[1] == "retry":
            retry(*sys.argv[2:5])
        elif sys.argv[1] == "apply":
            apply(sys.argv[2])
        elif sys.argv[1] == "unchecked":
            sys.stdout.write(render_unchecked(*sys.argv[2:5]))
        elif sys.argv[1] == "peer":
            print(balanced_peer(*(Path(p).read_text() for p in sys.argv[2:6])))
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"System review stopped: {error}", file=sys.stderr)
        sys.exit(1)
