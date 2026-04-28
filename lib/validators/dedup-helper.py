#!/usr/bin/env python3
"""dedup-helper.py — drop current-round findings whose logical identity matches
a prior-round finding. Prevents the same logical issue from being re-posted
across review rounds when the LLM rephrases the WHAT line or the underlying
code line shifts beyond the ±5-line window of the posting-time dedup at
``lib/review.sh:4372``.

Identity key: ``(file_basename, primary_symbol, normalized_what[:80])``

- ``file_basename``: line-shift-tolerant (no line number).
- ``primary_symbol``: the first backtick-quoted identifier in WHAT — protects
  against false-drop when two distinct findings share similar wording but
  reference different variables (e.g. ``userId`` vs ``accountId``).
- ``normalized_what``: lowercased, whitespace-collapsed, validator annotations
  stripped, first 80 chars. Tolerant of severity mutations (no severity in key)
  and tolerant of trailing rephrase (only first 80 chars).

Input (stdin): current-round FINDING: blocks.
Env (required for any drop): ``DIFFHOUND_PRIOR_FINDINGS`` — path to prior
FINDING: blocks. If unset/empty/missing, this validator is a no-op pass-through
(first review, no prior to dedup against).
Env (optional): ``DIFFHOUND_DEDUP_DISABLE=1`` opts out entirely.

Output (stdout): kept findings, in input order, with their original block_raw
preserved (including any annotations from upstream validators in the pipeline).
Drop messages on stderr, format ``[dedup-helper] DROPPED ...`` matching
``security-helper.sh`` and ``citation-discipline.sh`` conventions.

Why a separate validator and not extending ``round-diff.py``: round-diff is
invoked separately to compute the CHANGES_SINCE_LAST_REVIEW trailer; its
existing fixtures encode "keep + count" semantics. Dedup-on-drop is a different
concern that belongs in the run-all pipeline so it can be opted out cleanly
(``DIFFHOUND_DEDUP_DISABLE=1``) without affecting the trailer accounting.
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
        stripped = ANNOTATION_RE.sub("", self.what)
        norm = re.sub(r"\s+", " ", stripped.lower()).strip()
        return norm[:80]

    @property
    def identity_key(self) -> tuple[str, str, str]:
        return (self.file_basename, self.primary_symbol, self.normalized_what)

    @property
    def display(self) -> str:
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

    if os.environ.get("DIFFHOUND_DEDUP_DISABLE") == "1":
        sys.stdout.write(current_text)
        return

    prior_path = os.environ.get("DIFFHOUND_PRIOR_FINDINGS")
    if not prior_path or not Path(prior_path).is_file():
        sys.stdout.write(current_text)
        return

    try:
        prior_text = Path(prior_path).read_text(encoding="utf-8")
    except OSError:
        sys.stdout.write(current_text)
        return

    prior_keys = {f.identity_key for f in _parse_blocks(prior_text)}
    if not prior_keys:
        sys.stdout.write(current_text)
        return

    current = _parse_blocks(current_text)

    # Walk the original text linearly to preserve any non-FINDING content
    # (header lines, separators) verbatim. Drop only the matched FINDING
    # blocks. We re-stream by detecting block starts; everything between two
    # FINDING: starts (or before the first / after the last) is ambient and
    # passes through.
    dropped_blocks: set[int] = set()
    for idx, f in enumerate(current):
        if f.identity_key in prior_keys:
            dropped_blocks.add(idx)
            print(
                f"[dedup-helper] DROPPED (logical match in prior round): {f.display}",
                file=sys.stderr,
            )

    if not dropped_blocks:
        sys.stdout.write(current_text)
        return

    # Reconstruct output by streaming kept blocks' raw text.
    out_chunks: list[str] = []
    block_idx = -1
    in_block = False
    current_chunk: list[str] = []

    def _flush_chunk():
        nonlocal current_chunk, block_idx
        if not current_chunk:
            return
        if block_idx >= 0 and block_idx in dropped_blocks:
            current_chunk = []
            return
        out_chunks.append("".join(current_chunk))
        current_chunk = []

    # Capture pre-first-FINDING preamble too (rare, but harmless).
    for line in current_text.splitlines(keepends=True):
        if line.startswith("FINDING: "):
            _flush_chunk()
            block_idx += 1
            in_block = True
            current_chunk = [line]
        else:
            current_chunk.append(line)
    _flush_chunk()

    sys.stdout.write("".join(out_chunks))


if __name__ == "__main__":
    main()
