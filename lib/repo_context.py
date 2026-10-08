"""Bounded source evidence from immutable Git blobs, never generated execution claims."""

import argparse
import ast
import json
import re
import subprocess
from pathlib import Path

SOURCE = {
    ".py",
    ".ts",
    ".tsx",
    ".js",
    ".jsx",
    ".mjs",
    ".cjs",
    ".vue",
    ".go",
    ".rs",
    ".java",
    ".rb",
    ".sh",
    ".bash",
    ".sql",
    ".graphql",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
}
EXCLUDED = {"node_modules", "dist", "build", "vendor", "fixtures", ".venv"}
TOKEN = re.compile(r"\b[A-Za-z_][A-Za-z_0-9]{3,}\b")
LIMITS = "Bounded textual search, not proof of reachability or absence. Dynamic registration, reflection, external callers and other repositories may be unobserved. Source was read; tests were NOT executed."


def clip(text, budget):
    return text.encode()[: max(0, budget)].decode("utf-8", errors="ignore")


def balanced_peer(task, findings, diff, context, budget=14000):
    """Reserve independent budgets so a long analysis cannot hide the actual code."""
    pieces = [
        (
            "Coverage: partial, bounded excerpts; peer completion is not finding verification.\n"
            "No tools. Assess only introduced defects; no minimum finding count. Return new issues as\n"
            "FINDING: path:line:SHOULD-FIX (or BLOCKING/NIT) followed by WHAT: and EVIDENCE: lines.\n"
            "Explain refutations separately; insufficient context means UNVERIFIED.\n"
        )
    ]
    for name, value, share in (
        ("TASK", task, 0.15),
        ("FINDINGS", findings, 0.25),
        ("DIFF", diff, 0.30),
        ("REPOSITORY", context, 0.25),
    ):
        pieces.append(f"\n## {name}\n" + clip(value, int(budget * share)))
    return clip("".join(pieces), budget)


class Repository:
    """Index at most 32 MiB of tracked source; ignore symlinks and untracked secrets."""

    def __init__(self, root, sha):
        self.root, self.sha = Path(root), sha
        if (
            not re.fullmatch(r"[0-9a-f]{40}", sha)
            or self.git("rev-parse", "HEAD").decode().strip() != sha
        ):
            raise ValueError("repository does not match captured head")
        entries, size = [], 0
        self.tracked = {}
        self.omitted = 0
        for row in self.git("ls-tree", "-rlz", sha).split(b"\0"):
            if not row:
                continue
            metadata, rawpath = row.split(b"\t", 1)
            mode, kind, oid, length = metadata.split()
            path = rawpath.decode("utf-8", errors="strict")
            if kind != b"blob" or mode not in (b"100644", b"100755"):
                continue
            self.tracked[path] = (oid.decode(), int(length))
            if (
                Path(path).suffix not in SOURCE
                or EXCLUDED.intersection(Path(path).parts)
                or Path(path).name in {"package-lock.json", "pnpm-lock.yaml"}
            ):
                continue
            length = int(length)
            if (
                length > 500000
                or size + length > 32 * 1024 * 1024
                or len(entries) >= 6000
            ):
                self.omitted += 1
                continue
            entries.append((path, oid))
            size += length
        request = b"\n".join(oid for _, oid in entries) + b"\n" if entries else b""
        raw = self.git("cat-file", "--batch", data=request)
        self.files = {}
        self.hits = {}
        position = 0
        for path, _ in entries:
            end = raw.index(b"\n", position)
            length = int(raw[position:end].split()[-1])
            source = raw[end + 1 : end + 1 + length].decode("utf-8", errors="replace")
            position = end + length + 2
            self.files[path] = source.splitlines()

    def git(self, *args, data=None):
        result = subprocess.run(
            ["git", "-C", str(self.root), *args],
            input=data,
            capture_output=True,
            timeout=30,
            check=False,
        )
        if result.returncode:
            raise ValueError("cannot read captured repository")
        return result.stdout

    def occurrences(self, symbol):
        if symbol not in self.hits:
            pattern = re.compile(r"\b" + re.escape(symbol) + r"\b")
            self.hits[symbol] = [
                (p, i + 1)
                for p, lines in self.files.items()
                for i, text in enumerate(lines)
                if pattern.search(text)
            ]
        return self.hits[symbol]

    def window(self, path, line):
        # Search-index omissions must not prevent checking the actual cited text file.
        if (
            path not in self.files
            and path in self.tracked
            and self.tracked[path][1] <= 500000
        ):
            data = self.git("cat-file", "blob", self.tracked[path][0])
            if b"\0" not in data:
                self.files[path] = data.decode("utf-8", errors="replace").splitlines()
                self.hits.clear()
        lines = self.files.get(path, [])
        start, end = max(0, line - 31), min(len(lines), line + 30)
        if path.endswith(".py"):
            try:
                tree = ast.parse("\n".join(lines))
            except SyntaxError:
                tree = (
                    None  # The line window still exposes syntax; no invented AST facts.
                )
            scopes = (
                [
                    n
                    for n in ast.walk(tree)
                    if isinstance(
                        n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
                    )
                    and n.lineno <= line <= n.end_lineno
                ]
                if tree
                else []
            )
            if scopes:
                node = min(scopes, key=lambda n: n.end_lineno - n.lineno)
                if node.end_lineno - node.lineno <= 100:
                    start = max(0, node.lineno - 3)
                    end = min(len(lines), node.end_lineno + 8)
        indices = sorted(
            range(start, end), key=lambda i: (abs(i + 1 - line) > 4, abs(i + 1 - line))
        )
        return [{"path": path, "line": i + 1, "text": lines[i]} for i in indices]

    def packet(self, finding, budget=10000):
        path, line = finding["file"], int(finding["line"])
        cited = self.window(path, line)
        words = TOKEN.findall(finding.get("body", ""))
        explicit = re.findall(r"`([A-Za-z_][A-Za-z_0-9]*)`", finding.get("body", ""))
        explicit += [w for w in words if "_" in w or any(c.isupper() for c in w[1:])]
        source_text = "\n".join(r["text"] for r in cited)
        constants = [
            w for w in TOKEN.findall(source_text) if w.startswith("_") or w.isupper()
        ]
        calls = re.findall(
            r"\b(?:def|class|function)\s+(\w+)|\b(\w{4,})\s*\(",
            source_text,
        )
        symbols = list(
            dict.fromkeys(
                explicit + constants + [next(p for p in pair if p) for pair in calls]
            )
        )[:24]
        related = []
        for symbol in symbols:
            hits = [
                (p, n)
                for p, n in self.occurrences(symbol)
                if p != path or abs(n - line) > 30
            ]
            roles = {}
            for p, number in hits:
                source = self.files[p][number - 1]
                role = (
                    "test"
                    if "test" in p
                    else (
                        "definition"
                        if re.search(
                            r"\b(def|class|function|const)\s+"
                            + re.escape(symbol)
                            + r"\b",
                            source,
                        )
                        else "caller"
                    )
                )
                roles.setdefault(role, (p, number))
            # One of each role: many test references must not crowd out production callers.
            for role in ("definition", "caller", "test"):
                if role in roles:
                    p, number = roles[role]
                    related.append(self.window(p, number))
        references, seen = [], set()
        # Reserve half the space for callers/tests/settings instead of one large function.
        for groups, allowance in (
            ([cited], budget * 2 // 5),
            (related, budget * 3 // 5),
        ):
            group_used = 0
            for group in groups:
                # Share context among symbols/files rather than exhausting it on the first caller.
                window_used = 0
                for ref in group:
                    key = (ref["path"], ref["line"])
                    length = len(json.dumps(ref, ensure_ascii=False).encode())
                    if (
                        key not in seen
                        and group_used + length <= allowance
                        and window_used + length
                        <= max(2400, allowance // max(1, len(groups)))
                    ):
                        references.append(ref)
                        seen.add(key)
                        group_used += length
                        window_used += length
        references.sort(key=lambda ref: (ref["path"], ref["line"]))
        return {
            "sha": self.sha,
            "limits": LIMITS,
            "indexed_files": len(self.files),
            "omitted_files": self.omitted,
            "symbols": symbols,
            "references": references,
        }


def diff_context(repo, diff):
    packets, path = [], ""
    for row in diff.splitlines():
        if row.startswith("+++ b/"):
            path = row[6:]
        match = re.match(r"@@ .*\+(\d+)", row)
        if match and path and len(packets) < 12:
            packets.append(
                repo.packet({"file": path, "line": int(match[1]), "body": ""}, 2000)
            )
    return {
        "limits": LIMITS + " At most 12 hunk contexts included.",
        "packets": packets,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("sha")
    parser.add_argument("diff")
    args = parser.parse_args()
    print(
        json.dumps(
            diff_context(Repository(args.repo, args.sha), Path(args.diff).read_text()),
            ensure_ascii=False,
        )
    )
