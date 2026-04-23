#!/usr/bin/env python3
"""round-diff.py — append `### CHANGES_SINCE_LAST_REVIEW` accounting block.

Identity key is (file_basename, primary_symbol, normalized_what_80) — NO line
number, NO severity, so unrelated line shifts and severity mutations from
upstream validators (e.g. todo-deferral's BLOCKING → SHOULD-FIX) don't
create false churn.

Input (stdin): current-round FINDING: blocks.
Optional env DIFFHOUND_PRIOR_FINDINGS: path to prior-round FINDING: blocks.
Output (stdout): current blocks unchanged + CHANGES_SINCE_LAST_REVIEW trailer.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import NamedTuple

SYMBOL_RE = re.compile(r"`([_a-zA-Z][_a-zA-Z0-9]*)`")
ANNOTATION_RE = re.compile(r"\[[a-z-]+: [^\]]+\]")


class Finding(NamedTuple):
    file: str
    line: str
    severity: str
    what: str
    block_raw: str

    @property
    def file_basename(self) -> str:
        return Path(self.file).name

    @property
    def primary_symbol(self) -> str:
        m = SYMBOL_RE.search(self.what)
        return m.group(1) if m else ""

    @property
    def normalized_what(self) -> str:
        # Strip validator annotations so key survives re-runs through the pipeline
        stripped = ANNOTATION_RE.sub("", self.what)
        # Lowercase + collapse whitespace
        norm = re.sub(r"\s+", " ", stripped.lower()).strip()
        # First 80 chars of the substantive content
        return norm[:80]

    @property
    def identity_key(self) -> tuple[str, str, str]:
        return (self.file_basename, self.primary_symbol, self.normalized_what)

    @property
    def display(self) -> str:
        # Strip annotations for display; the WHAT text already contains the
        # symbol in backticks, so don't duplicate it.
        clean_what = ANNOTATION_RE.sub("", self.what).strip()
        return f"{self.file_basename} {clean_what}".strip()


def _parse_blocks(text: str) -> list[Finding]:
    findings: list[Finding] = []
    current: list[str] = []

    def _flush():
        if not current:
            return
        header = current[0]
        if not header.startswith("FINDING: "):
            return
        rest = header[len("FINDING: "):].strip()
        parts = rest.split(":", 2)
        if len(parts) < 3:
            return
        file_, line_no, sev = parts[0], parts[1], parts[2]
        what = ""
        for ln in current[1:]:
            if ln.startswith("WHAT:"):
                what = ln[len("WHAT:"):].strip()
                break
        findings.append(
            Finding(
                file=file_,
                line=line_no,
                severity=sev,
                what=what,
                block_raw="".join(current),
            )
        )

    for line in text.splitlines(keepends=True):
        if line.startswith("FINDING: "):
            _flush()
            current = [line]
        else:
            current.append(line)
    _flush()
    return findings


def main() -> None:
    current_text = sys.stdin.read()
    current = _parse_blocks(current_text)

    prior_path = os.environ.get("DIFFHOUND_PRIOR_FINDINGS")
    prior: list[Finding] = []
    if prior_path and Path(prior_path).is_file():
        prior = _parse_blocks(Path(prior_path).read_text(encoding="utf-8"))

    current_keys = {f.identity_key for f in current}
    prior_keys = {f.identity_key for f in prior}

    new = [f for f in current if f.identity_key not in prior_keys]
    resolved = [f for f in prior if f.identity_key not in current_keys]
    unchanged_count = len(current) - len(new)

    # Emit current findings unchanged
    sys.stdout.write(current_text)
    if not current_text.endswith("\n") and current_text:
        sys.stdout.write("\n")

    sys.stdout.write("### CHANGES_SINCE_LAST_REVIEW\n")
    sys.stdout.write(
        f"+{len(new)} new, -{len(resolved)} resolved, ={unchanged_count} unchanged\n"
    )
    if resolved:
        sys.stdout.write("RESOLVED:\n")
        for f in resolved:
            sys.stdout.write(f"- {f.display}\n")


if __name__ == "__main__":
    main()
