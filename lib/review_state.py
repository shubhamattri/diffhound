#!/usr/bin/env python3
"""GitHub-backed finding history. Missing findings are never evidence of a fix.

Full path + full rendered concern identify exact repeats, independently of line
number and severity. Human thread resolution permits a later recurrence to be
reported again. This module does not infer fixes from edits or model silence.
"""
import base64
import hashlib
import json
import re
import sys
import zlib
from pathlib import Path
from review_body import require_summary_fits

MARKER = re.compile(r"<!-- diffhound-state v1: (.*?) -->", re.S)
SUBMITTED = {"COMMENTED", "APPROVED", "CHANGES_REQUESTED", "DISMISSED"}
RANK = {"NIT": 0, "SHOULD-FIX": 1, "BLOCKING": 2}
COMMENT = re.compile(r"^COMMENT: (.+?):~?(\d+):(BLOCKING|SHOULD-FIX|NIT)\s*[—–-]\s*(.*)$")


def clean(body):
    """Remove transport metadata, preserving case and the entire concern."""
    return re.sub(r"\s+", " ", re.sub(r"<!-- diffhound-[\s\S]*?-->", "", body)).strip()


def identity(path, body):
    return hashlib.sha256((path + "\n" + clean(body)).encode()).hexdigest()[:24]


def parse(line):
    match = COMMENT.match(line)
    if not match:
        return None
    path, number, severity, body = match.groups()
    return {"id": identity(path, body), "path": path, "line": int(number),
            "severity": severity, "body": clean(body)}


def marker(plan):
    """Only committed history goes in the marker; local planning data stays local."""
    history = {key: plan[key] for key in ("sha", "findings", "resolved_threads")}
    encoded = base64.b64encode(zlib.compress(json.dumps(history, separators=(",", ":")).encode())).decode()
    return f"<!-- diffhound-state v1: {encoded} -->"


def load_history(reviews, login):
    for review in sorted(reviews, key=lambda r: r.get("submitted_at") or "", reverse=True):
        if review.get("user") != login or review.get("state") not in SUBMITTED:
            continue
        match = MARKER.search(review.get("body") or "")
        if not match:
            continue
        try:
            decoder = zlib.decompressobj()
            raw = decoder.decompress(base64.b64decode(match[1], validate=True), 1_000_000)
            if not decoder.eof:
                raise ValueError("history exceeds limit")
            history = json.loads(raw)
            for finding in history["findings"]:
                if (finding["severity"] not in RANK or finding["status"] not in {"OPEN", "RESOLVED"}
                        or not isinstance(finding["line"], int) or not finding["id"]):
                    raise ValueError("invalid finding")
                for key in ("path", "body"):
                    if not isinstance(finding[key], str):
                        raise ValueError("invalid finding")
            return history
        except (ValueError, KeyError, TypeError, zlib.error) as error:
            raise ValueError("Cannot read previous Diffhound finding state; refusing to forget it") from error
    return {"findings": [], "resolved_threads": []}


def reconcile(reviews, comments, threads, login, sha, lines):
    history = load_history(reviews, login)
    findings = {f["id"]: dict(f, change="UNCHANGED") for f in history["findings"]}
    aliases = {alias: f["id"] for f in findings.values() for alias in f.get("aliases", [])}
    resolved = {t["db_id"] for t in threads or [] if t.get("is_resolved") is True}
    newly_resolved = resolved - set(history.get("resolved_threads", []))
    newly_open = {t["db_id"] for t in threads or [] if t.get("is_resolved") is False} & set(history.get("resolved_threads", []))
    linked = {}
    for comment in comments:
        body = comment.get("body") or ""
        if (comment.get("user") != login or comment.get("in_reply_to_id") is not None
                or not comment.get("path") or "<!-- diffhound-id v1:" not in body):
            continue
        key = identity(comment["path"], body)
        key = aliases.get(key, key)
        # Legacy inline comments seed the ledger once. Manual comments don't.
        findings.setdefault(key, {"id": key, "path": comment["path"], "line": comment.get("line") or 1,
                                   "body": clean(body), "severity": "SHOULD-FIX", "status": "OPEN",
                                   "change": "UNCHANGED"})
        linked.setdefault(key, []).append(comment["id"])
    for key, ids in linked.items():
        if set(ids) & newly_resolved and set(ids) <= resolved:
            findings[key].update(status="RESOLVED", change="RESOLVED")
        elif set(ids) & newly_open:
            findings[key].update(status="OPEN", change="REOPENED")
    before = {key: dict(f) for key, f in findings.items()}
    output, repeats = [], []
    for line in lines:
        current = parse(line)
        if current is None:
            output.append(line)
            continue
        current["id"] = aliases.get(current["id"], current["id"])
        prior = findings.get(current["id"])
        if prior and prior["status"] == "OPEN" and RANK[current["severity"]] <= RANK[prior["severity"]] and threads is not None:
            prior.update(line=current["line"])
            repeats.append(line)
            continue
        change = "NEW" if prior is None else "REOPENED" if prior["status"] == "RESOLVED" else "ESCALATED"
        findings[current["id"]] = dict(current, status="OPEN", change=change,
                                        aliases=prior.get("aliases", []) if prior else [])
        output.append(line)
    return {"sha": sha, "findings": list(findings.values()),
            "resolved_threads": sorted(resolved) if threads is not None else history.get("resolved_threads", []),
            "comments": output, "duplicates": len(repeats), "repeats": repeats, "before": before,
            "threads_known": threads is not None}


def semantic_prior(plan, login):
    if not plan["threads_known"]:
        return []
    return [dict(f, id=i + 1, ledger_id=f["id"], user=login, is_resolved=False)
            for i, f in enumerate(plan["before"].values()) if f["status"] == "OPEN"]


def merge_aliases(plan, prior, lines, matches):
    """Remember judge-confirmed rewordings, including body-only prior findings."""
    by_id = {f["id"]: f for f in plan["findings"]}
    for number, prior_id in matches:
        current = parse(lines[number - 1])
        old = next(p for p in prior if p["id"] == prior_id)
        if current["path"] != old["path"] or RANK[current["severity"]] > RANK[old["severity"]]:
            raise ValueError("Invalid semantic match")
        target = by_id[old["ledger_id"]]
        if current["id"] != target["id"]:
            by_id.pop(current["id"], None)
            target["aliases"] = sorted(set(target.get("aliases", []) + [current["id"]]))
        target["line"] = current["line"]
    plan["findings"] = list(by_id.values())
    plan["duplicates"] += len(matches)
    return plan


def finalize(plan, lines):
    """Record only findings actually selected for publication, including overflow."""
    aliases = {alias: f["id"] for f in plan["findings"] for alias in f.get("aliases", [])}
    selected = {aliases.get(f["id"], f["id"]): f for line in lines if (f := parse(line)) is not None}
    committed = []
    for finding in plan["findings"]:
        key = finding["id"]
        if finding["change"] in {"NEW", "REOPENED", "ESCALATED"} and key not in selected:
            if key in plan["before"]:
                committed.append(plan["before"][key])
            continue
        committed.append(finding)
    known = {f["id"] for f in committed}
    committed.extend(dict(f, status="OPEN", change="NEW") for key, f in selected.items() if key not in known)
    plan["findings"] = committed
    return plan


def finding_line(finding):
    """Render the complete visible concern used by history and fallback checks."""
    return f"- **{finding['severity']}** `{finding['path']}:{finding['line']}` — {finding['body']}"


def inline_fallback(review):
    """Append only inline concerns missing from the complete visible history."""
    body = review["body"]
    history = load_history([{"user": "local", "state": "COMMENTED", "body": body}], "local")
    visible = {identity(f["path"], f["body"]) for f in history["findings"]
               if f["status"] == "OPEN" and finding_line(f) in body}
    missing = [c for c in review.get("comments", []) if identity(c["path"], c["body"]) not in visible]
    if not missing:
        return ""
    lines = ["\n**Findings** (could not be attached to diff lines)\n"]
    for comment in missing:
        lines.append(f"- `{comment['path']}:{comment['line']}` {clean(comment['body'])}")
    return "\n".join(lines) + "\n"


def summary(plan):
    """Persistent visible inventory includes findings posted only in the body."""
    opened = [f for f in plan["findings"] if f["status"] == "OPEN"]
    fixed = len(plan["findings"]) - len(opened)
    lines = [f"\n### Finding history\n\n{len(opened)} open · {fixed} resolved in GitHub threads.",
             "Absence from an incremental review does not mark a finding fixed."]
    for finding in sorted(opened, key=lambda f: -RANK[f["severity"]]):
        lines.append(finding_line(finding))
    return "\n".join(lines) + "\n\n" + marker(plan) + "\n"


def complete_summary(plan, generated):
    # History must not make a failed/empty model response pass the existing
    # minimum-content gate. Validate generated work before adding stored work.
    if len(re.sub(r"\s+", "", clean(generated))) < 200:
        raise ValueError("Generated review summary is empty or too short; history is not a review")
    body = generated + summary(plan)
    require_summary_fits(body, plan["sha"])
    return body


def main():
    command, *args = sys.argv[1:]
    if command == "plan":
        reviews, comments, threads, login, sha, source, dest = args
        plan = reconcile(json.loads(Path(reviews).read_text()), json.loads(Path(comments).read_text()),
                         json.loads(Path(threads).read_text()), login, sha, Path(source).read_text().split("\n")[:-1])
        Path(dest).write_text(json.dumps(plan))
        Path(source).write_text("".join(line + "\n" for line in plan["comments"]))
        print(plan["duplicates"])
    elif command == "finish":
        plan_file, selected, overflow, summary_file = args
        # Selected file has its COMMENT prefix removed by the interactive UI.
        lines = ["COMMENT: " + line for line in Path(selected).read_text().split("\n") if line]
        lines += Path(overflow).read_text().split("\n")
        plan = finalize(json.loads(Path(plan_file).read_text()), lines)
        body = complete_summary(plan, Path(summary_file).read_text())
        Path(summary_file).write_text(body)
        Path(plan_file).write_text(json.dumps(plan))
    elif command == "prior":
        plan_file, login = args
        print(json.dumps(semantic_prior(json.loads(Path(plan_file).read_text()), login)))
    elif command == "inline-fallback":
        sys.stdout.write(inline_fallback(json.loads(Path(args[0]).read_text())))
    elif command == "aliases":
        plan_file, prior_file, source, matches_file = args
        matches = [tuple(map(int, row.split())) for row in Path(matches_file).read_text().splitlines()]
        plan = merge_aliases(json.loads(Path(plan_file).read_text()), json.loads(Path(prior_file).read_text()),
                             Path(source).read_text().split("\n"), matches)
        Path(plan_file).write_text(json.dumps(plan))
    else:
        raise ValueError(f"Unknown state command: {command}")


if __name__ == "__main__":
    main()
