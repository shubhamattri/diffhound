#!/usr/bin/env python3
"""
extract-context.py — Ericsson-style enclosing function extraction for PR reviews.

Usage:
  python3 extract-context.py <repo_path> <diff_file>

Extracts the smallest enclosing function/class/method that contains each changed
hunk, rather than dumping the first N lines of each file. Reduces context tokens
by 60-70% vs head -100 with higher signal density.

Requires (optional — falls back gracefully if not installed):
  pip3 install tree-sitter tree-sitter-typescript tree-sitter-javascript tree-sitter-python
"""
import sys
import re
from pathlib import Path

# Try to import tree-sitter. Fall back to line-window extraction if unavailable.
try:
    from tree_sitter import Language, Parser
    HAS_TREE_SITTER = True
    _TS_PARSERS = {}

    def _get_parser(ext: str):
        if ext in _TS_PARSERS:
            return _TS_PARSERS[ext]
        try:
            if ext in ('.ts', '.tsx'):
                import tree_sitter_typescript as ts_lang
                lang = ts_lang.language_typescript()
            elif ext in ('.js', '.jsx'):
                import tree_sitter_javascript as ts_lang
                lang = ts_lang.language()
            elif ext == '.py':
                import tree_sitter_python as ts_lang
                lang = ts_lang.language()
            else:
                return None
            parser = Parser(Language(lang))
            _TS_PARSERS[ext] = parser
            return parser
        except Exception:
            return None

except ImportError:
    HAS_TREE_SITTER = False

    def _get_parser(ext: str):
        return None


# AST node types that represent enclosing "function-like" scopes
_FUNCTION_TYPES = {
    # TypeScript / JavaScript
    'function_declaration', 'function_expression', 'arrow_function',
    'method_definition', 'generator_function_declaration',
    'generator_function', 'export_statement', 'class_declaration',
    'lexical_declaration',  # for const fn = () => {}
    # Python
    'function_def', 'async_function_def', 'class_def',
}

MAX_FUNCTION_BYTES = 3500  # cap per extracted block to avoid flooding context
FALLBACK_CONTEXT_LINES = 35  # ± lines around hunk for non-tree-sitter path


def parse_diff_hunks(diff_text: str) -> dict:
    """
    Parse unified diff into {filepath: [(new_start, new_end), ...]} mapping.
    Only captures hunks that add/change lines (new_len > 0).
    """
    result: dict = {}
    current_file = None

    for line in diff_text.splitlines():
        if line.startswith('+++ b/'):
            current_file = line[6:].rstrip()
            result.setdefault(current_file, [])
        elif line.startswith('@@ ') and current_file is not None:
            # @@ -old_start[,old_len] +new_start[,new_len] @@
            m = re.search(r'\+(\d+)(?:,(\d+))?', line)
            if m:
                new_start = int(m.group(1))
                new_len = int(m.group(2)) if m.group(2) is not None else 1
                if new_len > 0:
                    result[current_file].append((new_start, new_start + new_len - 1))

    return result


def find_enclosing_node(root_node, start_line: int, end_line: int):
    """
    Walk the AST to find the smallest node that:
      1. Fully contains [start_line, end_line] (0-indexed internally)
      2. Is a function/class/method type

    Returns the node or None.
    """
    # tree-sitter uses 0-indexed lines
    s, e = start_line - 1, end_line - 1
    best = None

    def walk(node):
        nonlocal best
        ns, ne = node.start_point[0], node.end_point[0]
        if ns <= s and ne >= e:
            if node.type in _FUNCTION_TYPES:
                # Prefer the smallest (most specific) enclosing function
                if best is None or (ne - ns) < (best.end_point[0] - best.start_point[0]):
                    best = node
            for child in node.children:
                walk(child)

    walk(root_node)
    return best


def extract_with_tree_sitter(source: str, ext: str, line_ranges: list, filepath: str) -> list:
    """Return list of (label, code_block) tuples using tree-sitter AST."""
    parser = _get_parser(ext)
    if parser is None:
        return []

    try:
        tree = parser.parse(bytes(source, 'utf-8'))
    except Exception:
        return []

    lines = source.splitlines()
    output = []
    seen_ranges: set = set()  # avoid duplicating same function for multiple hunks

    for start, end in line_ranges:
        node = find_enclosing_node(tree.root_node, start, end)
        if node is None:
            # Changed line is at module level — show a small window
            ctx_s = max(0, start - FALLBACK_CONTEXT_LINES)
            ctx_e = min(len(lines), end + FALLBACK_CONTEXT_LINES)
            key = (ctx_s, ctx_e)
            if key not in seen_ranges:
                seen_ranges.add(key)
                snippet = '\n'.join(lines[ctx_s:ctx_e])
                output.append((
                    f"{filepath} (lines {ctx_s + 1}-{ctx_e}, module-level context)",
                    snippet[:MAX_FUNCTION_BYTES],
                    ext[1:] if ext else 'text',
                ))
            continue

        fn_s = node.start_point[0]
        fn_e = node.end_point[0]
        key = (fn_s, fn_e)
        if key in seen_ranges:
            continue
        seen_ranges.add(key)

        func_text = '\n'.join(lines[fn_s: fn_e + 1])
        output.append((
            f"{filepath} (lines {fn_s + 1}-{fn_e + 1})",
            func_text[:MAX_FUNCTION_BYTES],
            ext[1:] if ext else 'text',
        ))

    return output


def extract_fallback(source: str, line_ranges: list, filepath: str, ext: str) -> list:
    """± FALLBACK_CONTEXT_LINES window around each changed hunk."""
    lines = source.splitlines()
    output = []
    seen_ranges: set = set()

    for start, end in line_ranges[:4]:  # cap at 4 hunks for large diffs
        ctx_s = max(0, start - FALLBACK_CONTEXT_LINES)
        ctx_e = min(len(lines), end + FALLBACK_CONTEXT_LINES)
        key = (ctx_s, ctx_e)
        if key in seen_ranges:
            continue
        seen_ranges.add(key)
        snippet = '\n'.join(lines[ctx_s:ctx_e])
        output.append((
            f"{filepath} (lines {ctx_s + 1}-{ctx_e}, ±{FALLBACK_CONTEXT_LINES} window)",
            snippet[:MAX_FUNCTION_BYTES],
            ext[1:] if ext else 'text',
        ))

    return output


def extract_function_context(repo_path: str, diff_file: str) -> None:
    diff_text = Path(diff_file).read_text(errors='replace')
    hunks = parse_diff_hunks(diff_text)

    print("## 1. ENCLOSING FUNCTION CONTEXT (precise — not full file header)")
    print(f"# extraction: {'tree-sitter AST' if HAS_TREE_SITTER else 'line-window fallback'}")
    print()

    for filepath, line_ranges in hunks.items():
        if not line_ranges:
            continue

        full_path = Path(repo_path) / filepath
        if not full_path.exists():
            continue

        ext = full_path.suffix.lower()
        supported_exts = {'.ts', '.tsx', '.js', '.jsx', '.py', '.vue', '.go', '.sql'}
        if ext not in supported_exts:
            continue

        try:
            source = full_path.read_text(errors='replace')
        except OSError:
            continue

        total_lines = len(source.splitlines())

        # Prefer tree-sitter; fall back to line window
        blocks = []
        if HAS_TREE_SITTER and ext in ('.ts', '.tsx', '.js', '.jsx', '.py'):
            blocks = extract_with_tree_sitter(source, ext, line_ranges, filepath)

        if not blocks:
            blocks = extract_fallback(source, line_ranges, filepath, ext)

        for label, code, lang in blocks:
            print(f"### {label} ({total_lines} lines total in file)")
            print(f"```{lang}")
            print(code)
            print("```")
            print()


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <repo_path> <diff_file>", file=sys.stderr)
        sys.exit(1)

    extract_function_context(sys.argv[1], sys.argv[2])
