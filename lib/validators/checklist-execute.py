#!/usr/bin/env python3
"""checklist-execute.py — drop "fails in isolation with ModuleNotFoundError"
findings when the claimed failing file's imports actually resolve.

Uses ast.parse to find import statements, then importlib.util.find_spec (with
the repo root on sys.path) to check if each import resolves. If all imports
that look local resolve, the finding is dropped.

Reads FINDING: blocks on stdin, writes kept blocks on stdout, drops to stderr.
DIFFHOUND_REPO must point to the PR's working tree.
"""

from __future__ import annotations

import ast
import importlib.util
import os
import re
import sys
from pathlib import Path

MODULE_NOT_FOUND_RE = re.compile(
    r"ModuleNotFoundError|fails? in isolation|can'?t run standalone",
    re.IGNORECASE,
)


def _repo() -> Path:
    root = os.environ.get("DIFFHOUND_REPO")
    if not root:
        raise SystemExit("DIFFHOUND_REPO must be set")
    return Path(root)


def _parse_block(lines: list[str]) -> dict:
    """Extract the bits we need from a FINDING: block."""
    if not lines:
        return {}
    header = lines[0]
    if not header.startswith("FINDING: "):
        return {}
    rest = header[len("FINDING: "):].strip()
    parts = rest.split(":", 2)
    if len(parts) < 3:
        return {}
    file_, line_no, severity = parts[0], parts[1], parts[2]
    what = ""
    for ln in lines[1:]:
        if ln.startswith("WHAT:"):
            what = ln[len("WHAT:"):].strip()
            break
    return {"file": file_, "line": line_no, "severity": severity, "what": what}


def _extract_import_roots(path: Path) -> list[str]:
    """Return top-level module names imported by `path`. Syntax-invalid files
    return an empty list (we can't verify, so don't drop)."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8", errors="replace"))
    except (SyntaxError, UnicodeDecodeError, OSError):
        return []
    roots: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            roots.extend(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level > 0:  # relative import — always resolves if file is in a package
                continue
            if node.module:
                roots.append(node.module.split(".")[0])
    return roots


def _imports_resolve(path: Path, repo: Path) -> bool:
    """True if every top-level import in `path` resolves under repo root or
    in the normal Python search path."""
    roots = _extract_import_roots(path)
    if not roots:
        return False  # Nothing to check — don't silently drop

    # Augment sys.path with repo root + file's directory + repo/api (common
    # Python layout in this codebase) so local modules resolve.
    extra_paths = [
        str(repo),
        str(path.parent),
        str(repo / "api"),
    ]
    original = sys.path[:]
    sys.path = [p for p in extra_paths if p not in sys.path] + sys.path
    try:
        for name in roots:
            try:
                spec = importlib.util.find_spec(name)
            except (ImportError, ValueError, ModuleNotFoundError):
                spec = None
            if spec is None:
                return False
    finally:
        sys.path = original
    return True


def main() -> None:
    repo = _repo()
    stdin = sys.stdin.read()
    if not stdin:
        return

    blocks = []
    current: list[str] = []
    for line in stdin.splitlines(keepends=True):
        if line.startswith("FINDING: "):
            if current:
                blocks.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        blocks.append(current)

    for blk in blocks:
        parsed = _parse_block([l.rstrip("\n") for l in blk])
        if not parsed:
            sys.stdout.write("".join(blk))
            continue
        if not MODULE_NOT_FOUND_RE.search(parsed.get("what", "")):
            sys.stdout.write("".join(blk))
            continue
        file_ = parsed["file"]
        candidate = repo / file_
        if candidate.is_file() and _imports_resolve(candidate, repo):
            sys.stderr.write(
                f"[checklist-execute] DROPPED (imports resolve): {blk[0].rstrip()}\n"
            )
            continue
        sys.stdout.write("".join(blk))


if __name__ == "__main__":
    main()
