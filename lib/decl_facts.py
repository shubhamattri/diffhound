#!/usr/bin/env python3
"""Ground-truth check for "declared twice" and "used without import" claims.

Usage: decl_facts.py <repo> <path-relative-to-repo>   (claim text on stdin)
Prints one verdict: NOCLAIM | TRUE | FALSE | UNVERIFIABLE (reason on stderr).

The model has written compile-error findings about code it never saw
(monorepo #7642: `requireEnabled` "declared twice", `PORTAL_INTAKE_KIND`
"declared three times", params `ss`/`ctx__` that exist in no commit). Those
are facts about ONE file, so they are checked against that file at the PR
head. FALSE only when the file proves the claim wrong; anything ambiguous is
UNVERIFIABLE so a real duplicate or a real missing import is never dropped.
"""
import os
import re
import sys

DUP_RE = re.compile(
    r"(declared|defined|redeclared)\s+(twice|two times|three times|\d+\s+times|multiple times|more than once|again)"
    r"|(declared|defined)\s+(\w+\s+){0,3}(twice|multiple times|three times)"
    r"|duplicate\s+(`[^`]*`\s+)?(const|let|var|declarations?|identifiers?)\b"
    r"|redeclar"
    r"|two consecutive\b.{0,80}\bdeclarations"
    r"|redundant\b.{0,80}\bparams?\b",
    re.I,
)
IMPORT_RE = re.compile(
    r"(without|with no|has no|no|missing)\s+(an?\s+|any\s+)?(visible\s+)?import"
    r"|not imported|never imported|isn'?t imported|import (is |statement is )?missing",
    re.I,
)
KEYWORDS = {
    "return", "const", "let", "var", "function", "class", "interface", "type", "enum", "import",
    "export", "from", "async", "await", "static", "new", "this", "true", "false", "null",
    "undefined", "if", "else", "for", "while", "def", "self", "default", "public", "private",
    # review-format words, never code symbols
    "FINDING", "COMMENT", "REPLY", "BLOCKING", "SHOULD", "FIX", "NIT", "OPEN_QUESTION", "WHAT",
    "EVIDENCE", "IMPACT", "OPTIONS", "DIFF_LINE", "REACHABLE_PATH", "REJECTED_ALTERNATIVE",
    "UNVERIFIABLE", "CLAIMS", "TODO",
}
DECL_KW = r"(?:const|let|var|function\*?|class|interface|type|enum|def|namespace)"
IDENT = r"[A-Za-z_$][A-Za-z0-9_$]*"


def code_like(tok):
    return ("_" in tok or re.search(r"[a-z][A-Z]", tok) or re.fullmatch(r"[A-Z][A-Z0-9_]{2,}", tok)
            or re.search(r"\d", tok))


def claimed_symbols(text):
    syms = []
    for snip in re.findall(r"`([^`]+)`", text):
        m = re.match(r"\s*" + DECL_KW + r"\s+(" + IDENT + ")", snip)
        if m:
            syms.append(m.group(1))
            continue
        m = re.fullmatch(r"\s*(?:[A-Za-z_$][\w$]*\.)*(" + IDENT + r")\s*(?:\(\s*\))?\s*", snip)
        if m:
            syms.append(m.group(1))
    for tok in re.findall(r"(?<![`\w.$/])" + IDENT + r"(?![\w$`])", re.sub(r"`[^`]*`", " ", text)):
        if code_like(tok):
            syms.append(tok)
    seen, out = set(), []
    for s in syms:
        if s not in seen and s not in KEYWORDS and not re.fullmatch(r"\d+", s):
            seen.add(s)
            out.append(s)
    return out


def subject_symbols(text, match):
    """Symbols the claim is ABOUT: those in the claim's sentence up to the claim phrase."""
    start = max(text.rfind(". ", 0, match.start()), text.rfind("\n", 0, match.start())) + 1
    head = claimed_symbols(text[start:match.end()])
    return head or claimed_symbols(text)


def sentence(text, match):
    start = max(text.rfind(". ", 0, match.start()), text.rfind("\n", 0, match.start())) + 1
    ends = [i for i in (text.find(". ", match.end()), text.find("\n", match.end())) if i != -1]
    return text[start:min(ends) if ends else len(text)]


def other_file_named(sent, rel):
    own = os.path.basename(rel)
    for f in re.findall(r"[\w./-]+\.(?:tsx?|jsx?|vue|py|go|rb|java|kt|cjs|mjs)\b", sent):
        if os.path.basename(f) != own:
            return True
    return False


def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    return re.sub(r"(?m)(^|[^:\"'])//.*$", r"\1", src)


def signatures(src):
    """Parameter-name lists of every function/method/arrow declaration."""
    sigs = []
    for m in re.finditer(r"\(", src):
        i, depth = m.end(), 1
        while i < len(src) and depth:
            depth += {"(": 1, ")": -1}.get(src[i], 0)
            i += 1
        if depth:
            continue
        after = src[i:i + 200]
        if not re.match(r"\s*(:\s*[^{;=]+?)?\s*(\{|=>)", after):
            continue
        before = src[max(0, m.start() - 80):m.start()]
        if re.search(r"\b(if|for|while|switch|catch|return)\s*$", before):
            continue
        body, parts, depth, cur = src[m.end():i - 1], [], 0, ""
        for ch in body:
            if ch in "([{<":
                depth += 1
            elif ch in ")]}>":
                depth -= 1
            if ch == "," and depth == 0:
                parts.append(cur)
                cur = ""
            else:
                cur += ch
        parts.append(cur)
        names = []
        for p in parts:
            pm = re.match(r"\s*(?:public|private|protected|readonly|\.\.\.)?\s*(" + IDENT + ")", p)
            if pm:
                names.append(pm.group(1))
        sigs.append(names)
    return sigs


def decl_count(src, sym):
    s = re.escape(sym)
    n = len(re.findall(r"\b" + DECL_KW + r"\s+" + s + r"\b", src))
    n += len(re.findall(r"(?m)^\s*(?:(?:public|private|protected|static|async|readonly|get|set|override|export)\s+)*"
                        + s + r"\s*(?:<[^>\n]*>)?\s*\(", src))
    n += len(re.findall(r"[\"']" + s + r"[\"']", src))
    n += sum(1 for imp in imports(src) if imp == sym)
    for names in signatures(src):
        n += names.count(sym)
    return n


def imports(src):
    names = []
    for m in re.finditer(r"\bimport\s+(?:type\s+)?([\s\S]*?)\s+from\s+['\"]", src):
        clause = m.group(1)
        for a in re.findall(r"\bas\s+(" + IDENT + ")", clause):
            names.append(a)
        inner = re.sub(r"\b" + IDENT + r"\s+as\s+", "", clause)
        names += re.findall(IDENT, inner.replace("type ", ""))
    names += re.findall(r"\b(?:const|let|var)\s+(" + IDENT + r")\s*=\s*require\(", src)
    for m in re.finditer(r"\b(?:const|let|var)\s*\{([^}]*)\}\s*=\s*require\(", src):
        names += re.findall(IDENT, re.sub(r"\w+\s*:\s*", "", m.group(1)))
    names += re.findall(r"(?m)^\s*from\s+[\w.]+\s+import\s+(.*)$", src)
    names += re.findall(r"(?m)^\s*import\s+(" + IDENT + ")", src)
    return names


def main():
    repo, rel = sys.argv[1], sys.argv[2]
    text = sys.stdin.read()
    dup, imp = DUP_RE.search(text), IMPORT_RE.search(text)
    if not dup and not imp:
        print("NOCLAIM")
        return
    if os.environ.get("DIFFHOUND_TREE_UNVERIFIED") == "1":
        print("UNVERIFIABLE"); sys.stderr.write("tree is not the PR head\n"); return
    path = os.path.join(repo, rel)
    if not rel or not os.path.isfile(path):
        print("UNVERIFIABLE"); sys.stderr.write("file not in head tree: %s\n" % rel); return
    m = dup or imp
    if other_file_named(sentence(text, m), rel):
        # "defined twice: here and in utils/x.ts" is a cross-file (DRY) claim.
        print("UNVERIFIABLE"); sys.stderr.write("claim names another file\n"); return
    src = strip_comments(open(path, encoding="utf-8", errors="replace").read())
    syms = subject_symbols(text, m)

    if dup:
        if re.search(r"\bparam", text, re.I):
            funcs = [s for s in syms if re.search(r"\b" + re.escape(s) + r"\s*(?:<[^>\n]*>)?\s*\(", src)]
            dup_params = [n for sig in signatures(src) for n in set(sig) if sig.count(n) > 1]
            if dup_params:
                print("TRUE"); sys.stderr.write("duplicate params exist: %s\n" % dup_params); return
            if funcs:
                print("FALSE"); sys.stderr.write("no signature in %s declares a param twice\n" % rel); return
        if not syms:
            names = re.findall(r"\b" + DECL_KW + r"\s+(" + IDENT + ")", src)
            dups = sorted({n for n in names if names.count(n) > 1})
            if dups:
                print("TRUE"); sys.stderr.write("names declared more than once: %s\n" % dups); return
            print("FALSE"); sys.stderr.write("no name is declared twice anywhere in %s\n" % rel); return
        counts = {s: decl_count(src, s) for s in syms}
        if any(c >= 2 for c in counts.values()):
            print("TRUE"); sys.stderr.write("declared more than once: %s\n" % counts); return
        print("FALSE"); sys.stderr.write("each named symbol is declared at most once in %s: %s\n" % (rel, counts)); return

    if not syms:
        print("UNVERIFIABLE"); sys.stderr.write("no symbol named in claim\n"); return
    have = set(imports(src))
    for s in syms:
        used = re.search(r"(?<![\w$.])" + re.escape(s) + r"(?![\w$])", src)
        declared = s in have or decl_count(src, s) > 0
        if used and not declared:
            print("TRUE"); sys.stderr.write("%s is used in %s with no import or declaration\n" % (s, rel)); return
    print("FALSE"); sys.stderr.write("every named symbol is imported, declared, or unused in %s\n" % rel)


if __name__ == "__main__":
    main()
