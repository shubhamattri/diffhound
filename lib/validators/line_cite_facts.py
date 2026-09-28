#!/usr/bin/env python3
"""line_cite_facts.py — the engine behind line-cite-verify-check.sh.

Reads FINDING: blocks on stdin, writes kept (possibly re-anchored) blocks on
stdout, one audit line per action on stderr. DIFFHOUND_REPO is the PR head tree.

A finding is dropped only when the repository proves its claim false:
  1. ABSENT: none of the code identifiers the claim is about (backticked in
     WHAT or EVIDENCE) exists anywhere: not in the cited file's code (comments
     do not count) and not in any other file of the repo. (#7145:
     `computeEarnedPremium`.)
  2. FAR FROM A STATED LINE: the prose itself says the thing is "at line N",
     the identifiers are nowhere near N, and their nearest real occurrence is
     more than FAR lines away, i.e. a different place. (#7145: `.forUpdate()`
     "at line 276", only occurrence at 873.)
Otherwise a finding whose line number is merely off (nearest occurrence within
FAR lines) is re-anchored to that occurrence, not dropped (#7642 run 36443530901 dropped 28 of 50 real
findings with the old ±5-line rule).

Not claim identifiers: file/path fragments (`integration`, `claro`,
`actionEntitlements` of actionEntitlements.integration.spec.ts), tokens from
OPTIONS / REJECTED_ALTERNATIVE / IMPACT (proposals and consequences), spans
broken by ``` fences, and identifiers the finding says are missing.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

WINDOW = 12   # an occurrence this close to the cited line: the cite is fine
FAR = 50      # nearest occurrence farther than this: a different place, not a slightly-off line
MIN_LEN = 5
CODE_EXT = (".ts", ".tsx", ".js", ".jsx", ".py", ".vue", ".cjs", ".mjs")
CLAIM_FIELDS = ("WHAT", "EVIDENCE")
SKIP = set("""forEach map filter reduce find findOne findIndex some every includes indexOf slice
splice push pop shift unshift sort reverse join split trim toLowerCase toUpperCase charAt
charCodeAt substring substr replace replaceAll match test exec valueOf toString hasOwnProperty
then catch finally resolve reject all race allSettled any next prev done value key name type id
err error true false null undefined this self new util utils src test tests spec specs exports
module require import export default async await return throw try class function const let var
interface enum extends implements Record Promise Array Object Function Map Set WeakMap WeakSet
Date Number Boolean String Symbol RegExp Error TypeError RangeError SyntaxError JSON Math Buffer
Partial Required Readonly Pick Omit Exclude Extract NonNullable ReturnType Parameters
InstanceType ThisType Awaited string number boolean void unknown never object symbol bigint""".split())
# The finding says the identifier is NOT there: absence is its claim, not a contradiction.
ABSENCE_RE = re.compile(
    r"deleted|removed|dropped|never (called|invoked|used|appears|references|set|awaited)|no longer|"
    r"was renamed|has been (deleted|removed|renamed|dropped)|not in the (file|module|source)|not present|"
    r"missing|nowhere|does(n'?t| not) (exist|set|define|configure|include|have|call|use|handle|check|pass|await|cover)|"
    r"is(n'?t| not) (defined|set|configured|called|used|handled|checked|awaited|covered|tested|passed|mocked|imported)|"
    r"is undefined|cannot find|can'?t find|zero results|returns zero|\black(s|ing)?\b|\bhas no\b|\bwithout\b|"
    r"\bno `|\bnever\b|\babsent\b|\bomit", re.I)
PATH_RE = re.compile(r"[\w@.\-/]*[\w-]\.(?:tsx?|jsx?|cjs|mjs|py|vue|json|ya?ml|sql|md|graphql)\b")
LINE_RE = re.compile(r"\blines? (\d+)(?:\s*[-–]\s*(\d+))?", re.I)


def strip_comments(src: str, path: str) -> str:
    if path.endswith(".py"):
        return re.sub(r"(?m)#.*$", "", src)
    src = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    return re.sub(r"(?m)(^|[^:\"'\\])//.*$", r"\1", src)


def read(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


class Finding:
    def __init__(self, lines: list[str]):
        self.lines = lines
        head = lines[0][len("FINDING: "):].strip()
        parts = head.rsplit(":", 2)
        self.path, self.line = (parts[0], parts[1]) if len(parts) == 3 else ("", "")
        self.fields: dict[str, list[str]] = {}
        cur = None
        for ln in lines[1:]:
            m = re.match(r"^([A-Z_]+):\s?(.*)$", ln)
            if m:
                cur = m.group(1)
                self.fields.setdefault(cur, []).append(m.group(2))
            elif cur:
                self.fields[cur].append(ln)
        self.text = "\n".join(lines)

    def field(self, name: str) -> str:
        return "\n".join(self.fields.get(name, []))


def backtick_spans(text: str) -> list[str]:
    spans = []
    for ln in text.splitlines():
        if ln.strip().startswith("```"):
            continue  # fence markers break backtick pairing
        ln = ln.replace("```", "")
        spans += re.findall(r"`([^`\n]+)`", ln)
    return spans


def path_tokens(f: Finding) -> set[str]:
    toks = set()
    for p in PATH_RE.findall(f.text) + [f.path]:
        toks.update(t for t in re.split(r"[/.\-@]", p) if t)
    return toks


def claim_ids(f: Finding) -> list[str]:
    text = "\n".join(f.field(n) for n in CLAIM_FIELDS)
    ptoks = path_tokens(f)
    out: list[str] = []
    for span in backtick_spans(text):
        if "/" in span or PATH_RE.fullmatch(span.strip()):
            continue  # a path, not code
        for tok in re.findall(r"[A-Za-z_][A-Za-z0-9_]+", span):
            if len(tok) < MIN_LEN or tok in SKIP or tok in ptoks or tok in out:
                continue
            out.append(tok)
    return out


def missing_claimed(f: Finding, ident: str) -> bool:
    """The finding says `ident` ITSELF is missing: an absence phrase right
    before it ("without `X`", "no `X`", "lacks a `X`") or right after it ("`X`
    is never called", "`X` was removed"). "`afterAll` ... without try/finally"
    is not a claim that afterAll is missing."""
    text = "\n".join(f.field(n) for n in CLAIM_FIELDS)
    for m in re.finditer(r"`[^`\n]*\b%s\b[^`\n]*`" % re.escape(ident), text):
        before = text[max(0, m.start() - 25):m.start()]
        after = text[m.end():m.end() + 45]
        if re.search(r"\b(without|no|lacks?|lacking|missing|omits?|omitted|never|absent)\b(\s+(a|an|the|any))?\s*$", before, re.I):
            return True
        if re.match(r"\s*(\([^)]*\)\s*)?(is|are|was|were|has been|gets?)?\s*(" + ABSENCE_RE.pattern + ")", after, re.I):
            return True
    return False


_repo_cache: dict[str, bool] = {}


def in_other_repo_files(repo: str, ident: str, exclude: str) -> bool:
    key = ident + "\0" + exclude
    if key in _repo_cache:
        return _repo_cache[key]
    found = False
    try:
        if os.path.isdir(os.path.join(repo, ".git")) or os.path.isfile(os.path.join(repo, ".git")):
            r = subprocess.run(["git", "-C", repo, "grep", "--untracked", "-l", "-F", "-e", ident, "--", ".", ":(exclude)" + exclude],
                               capture_output=True, text=True, timeout=60)
            found = bool(r.stdout.strip())
        else:
            r = subprocess.run(["grep", "-rlF", "--exclude-dir=node_modules", "--exclude-dir=.git", "-e", ident, repo],
                               capture_output=True, text=True, timeout=60)
            ex = os.path.normpath(os.path.join(repo, exclude))
            found = any(os.path.normpath(p) != ex for p in r.stdout.splitlines() if p)
    except (OSError, subprocess.TimeoutExpired):
        found = True  # cannot tell: never drop on an unanswered question
    _repo_cache[key] = found
    return found


def occurrences(code_lines: list[str], ident: str) -> list[int]:
    return [i + 1 for i, ln in enumerate(code_lines) if ident in ln]


def judge(f: Finding, repo: str) -> tuple[str, str, int | None]:
    """-> (action, reason, new_line). action: keep | drop | reanchor."""
    if not f.path or not f.line.isdigit() or not f.path.endswith(CODE_EXT):
        return "keep", "", None
    src = read(os.path.join(repo, f.path))
    if src is None:
        return "keep", "", None
    code = strip_comments(src, f.path).splitlines()
    cited = int(f.line)
    ids = [i for i in claim_ids(f) if not missing_claimed(f, i)]
    if not ids:
        return "keep", "", None

    absent = [i for i in ids if not occurrences(code, i) and not in_other_repo_files(repo, i, f.path)]
    if absent and len(absent) == len(ids):
        # Nothing the claim is about exists. One absent token among real ones is
        # usually a placeholder (`logger.error(message, contextObject)`), not proof.
        return "drop", "exists nowhere in the repo: " + " ".join(absent), None

    in_file = {i: occurrences(code, i) for i in ids}
    in_file = {i: o for i, o in in_file.items() if o}
    if not in_file:
        return "keep", "", None  # all claim ids live in other files the finding is about
    near = lambda n: any(abs(o - n) <= WINDOW for occ in in_file.values() for o in occ)
    if near(cited):
        return "keep", "", None
    # Re-anchor to a use, not to an import line that merely names the identifier.
    import_line = re.compile(r"^\s*(import\b|export\s+\{[^}]*\}\s+from\b|from\s+\S+\s+import\b|(const|let|var)\s+.*=\s*require\()")
    uses = [o for occ in in_file.values() for o in occ if not import_line.match(code[o - 1])]
    cands = sorted(set(uses or [o for occ in in_file.values() for o in occ]))
    # The place the finding is about: the line with the most distinct claim
    # identifiers within 3 lines (afterAll + dropSchema + destroy), then nearest.
    density = lambda n: sum(1 for occ in in_file.values() if any(abs(o - n) <= 3 for o in occ))
    nearest = min(cands, key=lambda o: abs(o - cited))
    best = max(cands, key=lambda o: (density(o), -abs(o - cited)))
    stated = [int(a) for m in LINE_RE.finditer(f.field("WHAT")) for a in m.groups() if a]
    if stated and not any(near(n) for n in stated) and abs(nearest - cited) > FAR \
            and all(abs(nearest - n) > FAR for n in stated):
        return "drop", "says line %s, identifiers only at line %d" % (
            ",".join(map(str, stated)), nearest), None
    if abs(best - cited) > FAR:
        return "keep", "", None  # the place it is about is elsewhere: not an off-by-a-few line
    return "reanchor", "re-anchored from %d to %d" % (cited, best), best


def emit(f: Finding, repo: str) -> str:
    action, reason, new = judge(f, repo)
    head = f.lines[0][len("FINDING: "):].strip()
    if action == "drop":
        sys.stderr.write("[line-cite-verify-check] DROPPED (%s): %s\n" % (reason, head))
        return ""
    lines = list(f.lines)
    if action == "reanchor":
        sev = head.rsplit(":", 1)[1]
        lines[0] = "FINDING: %s:%d:%s" % (f.path, new, sev)
        for i, ln in enumerate(lines):
            if ln.startswith("WHAT:"):
                lines[i] = ln + " [line-cite: %s]" % reason
                break
        sys.stderr.write("[line-cite-verify-check] %s: %s\n" % (reason.upper(), head))
    return "\n".join(lines) + "\n"


def main() -> None:
    repo = os.environ.get("DIFFHOUND_REPO", "")
    out, cur, pre = [], None, []
    for ln in sys.stdin.read().splitlines():
        if ln.startswith("FINDING: "):
            if cur is not None:
                out.append(emit(Finding(cur), repo))
            cur = [ln]
        elif cur is None:
            pre.append(ln)
        else:
            cur.append(ln)
    if cur is not None:
        out.append(emit(Finding(cur), repo))
    sys.stdout.write(("\n".join(pre) + "\n" if pre else "") + "".join(out))


if __name__ == "__main__":
    main()
