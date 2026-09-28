#!/usr/bin/env python3
"""Ground-truth check for "X.y is unguarded / may be undefined / can throw" claims.

Usage: guard_facts.py <repo> <path-relative-to-repo> <line>   (claim text on stdin)
Prints one verdict: NOCLAIM | TRUE | FALSE | UNVERIFIABLE (reason on stderr).

FALSE only when an early exit on the SAME identifier dominates the cited line:
a statement `if (!X ...) throw|return` (or `!X?.y`, `X == null`, as one term of
an `||` condition) at the top level of an enclosing function, before the line,
with X not reassigned in between. When X is a parameter of a non-exported
function, every call site in the file must pass a plain identifier that is
guarded the same way (monorepo #7693: `payload.productId` in reportFailureToSlack,
guarded by `if (!payload?.productId) throw` before the only call). No fuzzy
matching: a guard on another identifier, or one inside a branch, proves nothing.
"""
import os
import re
import sys

CLAIM_RE = re.compile(
    r"unguarded|not guarded|without (a |any )?(null|undefined|nullish|existence) (check|guard)"
    r"|no (null|undefined|nullish) (check|guard)|(may|might|could|can) (be )?(undefined|null|nullish)"
    r"|possibly (undefined|null)|(can|could|may|might|will) throw|throws? (a )?TypeError|TypeError"
    r"|cannot read propert|null (pointer )?dereference|undefined dereference",
    re.I,
)
THROW_RE = re.compile(r"throw|TypeError|cannot read propert|dereferenc|crash", re.I)
IDENT = r"[A-Za-z_$][A-Za-z0-9_$]*"
ACCESS_RE = re.compile(r"(?<![\w$.])(" + IDENT + r")(\?\.|\.)(" + IDENT + r")((?:/" + IDENT + r")*)")
NOT_FUNC = {"if", "for", "while", "switch", "catch", "with", "return", "typeof", "await"}
SKIP_ROOTS = {"this", "process", "console", "Math", "JSON", "Object", "Array", "Promise", "window", "document"}


def mask(src):
    """Blank comments and string/template contents (keeping newlines and ${} code)."""
    out, i, n = list(src), 0, len(src)
    stack = []  # "tpl", or an int: brace depth inside a ${ } of the enclosing template

    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "
    while i < n:
        c = src[i]
        if stack and stack[-1] == "tpl":
            if c == "\\":
                blank(i, i + 2); i += 2; continue
            if c == "`":
                stack.pop(); i += 1; continue
            if src.startswith("${", i):
                stack.append(0); blank(i, i + 2); i += 2; continue
            blank(i, i + 1); i += 1; continue
        if src.startswith("//", i):
            j = src.find("\n", i); j = n if j == -1 else j
            blank(i, j); i = j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2); j = n if j == -1 else j + 2
            blank(i, j); i = j; continue
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            blank(i + 1, j); i = j + 1; continue
        if c == "`":
            stack.append("tpl"); i += 1; continue
        if stack and isinstance(stack[-1], int):
            if c == "{":
                stack[-1] += 1
            elif c == "}":
                if stack[-1] == 0:
                    stack.pop(); out[i] = " "; i += 1; continue
                stack[-1] -= 1
        i += 1
    return "".join(out)


class Src:
    def __init__(self, text):
        self.m = mask(text)
        self.line_start = [0]
        for k, ch in enumerate(self.m):
            if ch == "\n":
                self.line_start.append(k + 1)
        self.match, st = {}, []
        for k, ch in enumerate(self.m):
            if ch in "{([":
                st.append(k)
            elif ch in "})]" and st:
                self.match[st.pop()] = k
        self.back = {v: k for k, v in self.match.items()}

    def line_of(self, pos):
        lo, hi = 0, len(self.line_start) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.line_start[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def pos_of_line(self, ln):
        return self.line_start[ln - 1] if 0 < ln <= len(self.line_start) else None

    def func_info(self, brace):
        """(name, params, exported) if the `{` at `brace` opens a function body, else None."""
        head = self.m[max(0, brace - 600):brace]
        arrow = re.search(r"=>\s*$", head)
        if arrow:
            before = head[:arrow.start()].rstrip()
            before = re.sub(r"\)\s*:\s*[^(){};=]*$", ")", before)
            if before.endswith(")"):
                close = brace - len(head) + len(before) - 1
                openp = self.back.get(close)
                if openp is None:
                    return None
                params = self.params(openp, close)
                pre = self.m[max(0, openp - 200):openp]
            else:
                pm = re.search(r"(" + IDENT + r")\s*$", before)
                if not pm:
                    return None
                params, pre = [pm.group(1)], before[:pm.start()]
            nm = re.search(r"(?:const|let|var)\s+(" + IDENT + r")\s*(?::[^=]*)?=\s*(?:async\s*)?$", pre)
            name = nm.group(1) if nm else None
            exported = bool(nm and re.search(r"export\s+(?:const|let|var)\s+" + re.escape(name) + r"\b", pre))
            return name, params, exported
        stripped = re.sub(r"\)\s*:\s*[^(){};=]*$", ")", head.rstrip())
        if not stripped.endswith(")"):
            return None
        close = brace - len(head) + len(stripped) - 1
        openp = self.back.get(close)
        if openp is None:
            return None
        pre = self.m[max(0, openp - 200):openp]
        nm = re.search(r"(?:(function\*?)\s*)?(" + IDENT + r")?\s*(?:<[^<>()]*>)?\s*$", pre)
        word = nm.group(2) if nm else None
        if not nm or (word in NOT_FUNC) or (not word and not nm.group(1)):
            return None
        exported = bool(re.search(r"export\s+(?:default\s+)?(?:async\s+)?function\*?\s*" + re.escape(word or "") + r"\s*$",
                                  pre[:nm.end()])) if word else False
        return word, self.params(openp, close), exported

    def raw_args(self, openp, close):
        inner, parts, depth, cur = self.m[openp + 1:close], [], 0, ""
        for ch in inner:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            if ch == "," and depth == 0:
                parts.append(cur); cur = ""
            else:
                cur += ch
        parts.append(cur)
        return parts

    def params(self, openp, close):
        inner, parts, depth, cur = self.m[openp + 1:close], [], 0, ""
        for ch in inner:
            if ch in "([{<":
                depth += 1
            elif ch in ")]}>":
                depth -= 1
            if ch == "," and depth == 0:
                parts.append(cur); cur = ""
            else:
                cur += ch
        parts.append(cur)
        out = []
        for p in parts:
            m = re.match(r"\s*(?:\.\.\.)?(" + IDENT + r")", p)
            out.append(m.group(1) if m else None)
        return out

    def enclosing_funcs(self, pos):
        """Function bodies containing pos, innermost first: (open, close, info)."""
        res = []
        for o, c in self.match.items():
            if self.m[o] == "{" and o < pos < c:
                info = self.func_info(o)
                if info:
                    res.append((o, c, info))
        return sorted(res, key=lambda t: -t[0])


def guard_terms(cond):
    parts, depth, cur, k = [], 0, "", 0
    while k < len(cond):
        ch = cond[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if depth == 0 and cond.startswith("||", k):
            parts.append(cur); cur = ""; k += 2; continue
        if depth == 0 and cond.startswith("&&", k):
            return []  # a conjunction does not exit whenever X is missing
        cur += ch; k += 1
    parts.append(cur)
    return [p.strip() for p in parts]


def term_guards(term, root, member):
    """Does `term` being true exactly when root (or root.member) is missing?"""
    r = re.escape(root)
    if member is None:
        pat = r"!\s*" + r + r"(?:(?:\?\.|\.)" + IDENT + r")*|" + r + r"\s*==\s*(?:null|undefined)"
    else:
        mm = re.escape(member)
        pat = r"!\s*" + r + r"(?:\?\.|\.)" + mm + r"|" + r + r"(?:\?\.|\.)" + mm + r"\s*==\s*(?:null|undefined)"
    return re.fullmatch(r"\(?\s*(?:" + pat + r")\s*\)?", term) is not None


def exits(src, pos):
    """pos is right after `if (...)`; True if the branch always throws/returns."""
    rest = src.m[pos:]
    s = len(rest) - len(rest.lstrip())
    p = pos + s
    if src.m[p:p + 1] == "{":
        end = src.match.get(p)
        if end is None:
            return None
        body = src.m[p + 1:end]
        flat, depth = "", 0
        for ch in body:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            elif depth == 0:
                flat += ch
        return end if re.search(r"(^|[;\s])(throw|return)\b", flat) else None
    m = re.match(r"(throw|return)\b[^;\n]*;?", src.m[p:])
    return p + m.end() if m else None


def dominated(src, root, member, target, depth=0):
    """True if a guard on root(.member) dominates source position `target`."""
    for o, c, (name, params, exported) in src.enclosing_funcs(target):
        body_depth_open = o
        # top-level statements of this body: scan `if (` whose innermost enclosing `{` is o
        for m in re.finditer(r"\bif\s*\(", src.m[o + 1:target]):
            ip = o + 1 + m.start()
            openp = o + 1 + m.end() - 1
            if innermost_brace(src, ip) != body_depth_open:
                continue
            close = src.match.get(openp)
            if close is None or close > target:
                continue
            terms = guard_terms(src.m[openp + 1:close])
            if not any(term_guards(t, root, member) for t in terms):
                continue
            end = exits(src, close + 1)
            if end is None or end > target:
                continue
            if re.search(r"(?<![\w$.])" + re.escape(root) + r"\s*=(?!=)", src.m[end:target]):
                continue
            return True
        declared = root in params or re.search(
            r"\b(?:const|let|var)\s+" + re.escape(root) + r"\b", src.m[o:target])
        if declared:
            if root in params and name and not exported and depth < 2:
                return callers_guarded(src, name, params.index(root), member, o, c, depth)
            return False
    return False


def innermost_brace(src, pos):
    best = None
    for o, c in src.match.items():
        if src.m[o] == "{" and o < pos < c and (best is None or o > best):
            best = o
    return best


def callers_guarded(src, fname, idx, member, fo, fc, depth):
    calls = [m for m in re.finditer(r"(?<![\w$.])" + re.escape(fname) + r"\s*\(", src.m)
             if not (fo - 400 < m.start() < fo)]
    calls = [m for m in calls if not re.search(r"function\s*\*?\s*$", src.m[max(0, m.start() - 30):m.start()])]
    if not calls:
        return False
    for m in calls:
        openp = m.end() - 1
        close = src.match.get(openp)
        if close is None:
            return False
        raw = src.raw_args(openp, close)
        if idx >= len(raw) or not re.fullmatch(r"\s*" + IDENT + r"\s*", raw[idx]):
            return False  # only a plain identifier argument can carry the guard
        if not dominated(src, raw[idx].strip(), member, m.start(), depth + 1):
            return False
    return True


def main():
    repo, rel, line = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
    text = sys.stdin.read()
    if not CLAIM_RE.search(text):
        print("NOCLAIM"); return
    accesses = []
    for m in ACCESS_RE.finditer(text):
        if m.group(1) in SKIP_ROOTS or re.fullmatch(r"\d+", m.group(1)):
            continue
        accesses.append((m.group(1), m.group(3)))
        for extra in filter(None, m.group(4).split("/")):
            accesses.append((m.group(1), extra))
    if not accesses:
        print("NOCLAIM"); return
    if os.environ.get("DIFFHOUND_TREE_UNVERIFIED") == "1":
        print("UNVERIFIABLE"); sys.stderr.write("tree is not the PR head\n"); return
    path = os.path.join(repo, rel)
    if not rel or not os.path.isfile(path) or not line.isdigit():
        print("UNVERIFIABLE"); sys.stderr.write("file/line not in head tree: %s:%s\n" % (rel, line)); return
    src = Src(open(path, encoding="utf-8", errors="replace").read())
    ln = int(line)
    lines = src.m.split("\n")
    throw_kind = bool(THROW_RE.search(text))
    roots = {}
    for root, member in accesses:
        roots.setdefault(root, set()).add(member)
    checked = False
    for root, members in roots.items():
        hit = None
        for cand in [ln] + [x for d in range(1, 6) for x in (ln - d, ln + d)]:
            if 0 < cand <= len(lines) and re.search(r"(?<![\w$.])" + re.escape(root) + r"\s*(\?\.|\.)", lines[cand - 1]):
                hit = cand; break
        if hit is None:
            continue
        pos = src.pos_of_line(hit) + re.search(r"(?<![\w$.])" + re.escape(root) + r"\s*(\?\.|\.)", lines[hit - 1]).start()
        checked = True
        needs = [None] if throw_kind else sorted(members)
        for member in needs:
            if not dominated(src, root, member, pos):
                print("TRUE"); sys.stderr.write("no dominating guard on %s%s before %s:%d\n"
                                                % (root, "." + member if member else "", rel, hit)); return
    if not checked:
        print("UNVERIFIABLE"); sys.stderr.write("claimed identifiers not near %s:%s\n" % (rel, line)); return
    print("FALSE"); sys.stderr.write("a guard on the same identifier dominates %s:%s\n" % (rel, line))


if __name__ == "__main__":
    main()
