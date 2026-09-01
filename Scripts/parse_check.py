#!/usr/bin/env python3
"""Parse every Swift file and report syntax errors.

For editing this project where Xcode is not - a Linux container, CI without
a Mac. `swift build` cannot help there: SwiftData, SwiftUI and Core Data do
not exist off Apple platforms, and swift.org is not always reachable anyway.
A grammar, however, is portable, and tree-sitter ships one.

    pip install tree_sitter tree_sitter_language_pack
    python3 Scripts/parse_check.py Sous SousKit/Sources SousKit/Tests

**Know its ceiling.** It knows Swift's grammar, not its types. It catches the
mistake an edit without a build is most likely to make - an unbalanced
construct, a malformed expression, a trailing closure the grammar does not
allow there - and it catches nothing about whether a method exists, a type
matches, or a ViewBuilder accepts what it was handed. Green here is not a
build; it only means the next failure will be an interesting one.

**It has a baseline.** Sixteen files fail to parse on a clean checkout, all
of them for the grammar's reasons rather than the code's: SwiftData's @Model
macro with its `#Index` and a handful of regex literals. So the number to
watch is the *difference* against the commit you started from, not zero:

    git worktree add /tmp/base <commit>
    (cd /tmp/base && python3 Scripts/parse_check.py Sous SousKit/Sources) > /tmp/base.txt
"""
import sys, pathlib
from tree_sitter_language_pack import get_parser

parser = get_parser('swift')

def errors(path):
    src = path.read_bytes()
    tree = parser.parse(src)
    found = []
    stack = [tree.root_node]
    while stack:
        n = stack.pop()
        if n.type == 'ERROR' or n.is_missing:
            line = n.start_point[0] + 1
            snippet = src.split(b'\n')[n.start_point[0]][:100].decode('utf8', 'replace').strip()
            found.append((line, 'MISSING' if n.is_missing else 'ERROR', snippet))
        else:
            stack.extend(n.children)
    return sorted(found)

roots = sys.argv[1:] or ['.']
bad = 0
files = []
for r in roots:
    p = pathlib.Path(r)
    files.extend(sorted(p.rglob('*.swift')) if p.is_dir() else [p])
for f in files:
    if '/build/' in str(f) or '/.build/' in str(f):
        continue
    errs = errors(f)
    if errs:
        bad += 1
        print(f"\n{f}")
        for line, kind, snippet in errs[:6]:
            print(f"   {kind} at line {line}: {snippet}")
print(f"\n{len(files)} files, {bad} with parse errors")
