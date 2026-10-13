#!/usr/bin/env python3
"""Checks that literal UI strings in App/ Swift files exist as keys in App/Resources/*.xcstrings.

Covers literals passed directly to common SwiftUI initializers and String(localized:).
Interpolations like "\\(x) free" match catalog keys with a format specifier ("%@ free", "%lld free").
Usage: lint_strings.py <repo root> [--list]
"""
import glob
import json
import os
import re
import sys

CALLS = r"(?:(?:Text|Button|Label|Toggle|Section|TextField|SecureField|Picker|Menu|Stepper|LabeledContent|Link|Window|CommandMenu|confirmationDialog|alert|navigationTitle|help)\(\s*|String\(localized:\s*)"
LITERAL = re.compile(CALLS + r"\"((?:[^\"\\]|\\.)*)\"")
SPEC = r"%(?:\d+\$)?(?:@|lld|llu|ld|lu|d|u|f|lf|\.\d+f)"


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def split_interpolations(literal):
    """Splits a Swift string literal body on \\( ... ) interpolations (nested parentheses allowed)."""
    parts, current, i = [], "", 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(literal) and depth:
                depth += {"(": 1, ")": -1}.get(literal[i], 0)
                i += 1
            parts.append(current)
            current = ""
        else:
            current += literal[i]
            i += 1
    parts.append(current)
    return parts


def key_pattern(literal):
    parts = split_interpolations(literal)
    if len(parts) == 1:
        return None
    return re.compile("^" + SPEC.join(re.escape(unescape(p)) for p in parts) + "$", re.S)


def main():
    root = sys.argv[1]
    keys = set()
    for path in glob.glob(os.path.join(root, "App/Resources/*.xcstrings")):
        with open(path, encoding="utf-8") as f:
            keys.update(json.load(f).get("strings", {}).keys())
    missing = []
    for path in sorted(glob.glob(os.path.join(root, "App/**/*.swift"), recursive=True)):
        with open(path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                if line.strip().startswith("//"):
                    continue
                for literal in LITERAL.findall(line):
                    pattern = key_pattern(literal)
                    if pattern is None:
                        ok = unescape(literal) in keys
                    else:
                        ok = any(pattern.match(k) for k in keys)
                    if not ok:
                        missing.append((os.path.relpath(path, root), lineno, literal))
    for path, lineno, literal in missing:
        print(f"{path}:{lineno}: string not in a catalog: \"{literal}\"")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
