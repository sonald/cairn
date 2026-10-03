#!/usr/bin/env python3
"""Fail when the app target resolves a `model.*` key through its own
localized()/localizedFormat(): those keys live in CodeInsightAppModel's
bundle, so the app would show the raw key. Use modelText()/modelTextFormat()."""
import pathlib
import re
import sys

CALL = re.compile(r'(?<![A-Za-z_.])(localized|localizedFormat)\(')


def offending_calls(source: str):
    for match in CALL.finditer(source):
        depth, index = 1, match.end()
        while index < len(source) and depth:
            char = source[index]
            if char == '"':
                end = source.find('"', index + 1)
                if end == -1:
                    break
                index = end
            elif char == '(':
                depth += 1
            elif char == ')':
                depth -= 1
            index += 1
        if '"model.' in source[match.end():index]:
            yield source.count('\n', 0, match.start()) + 1


def main() -> int:
    samples = [
        'localized("model.typehop.noType")',
        'localized(\n    flag ? "model.typehop.resolving" : "model.x"\n)',
        'localizedFormat("model.typehop.accessibility", a, f(b))',
    ]
    for sample in samples:
        if not list(offending_calls(sample)):
            print(f"model key gate misses: {sample!r}", file=sys.stderr)
            return 1
    if list(offending_calls('modelText("model.typehop.noType")')):
        print("model key gate flags modelText()", file=sys.stderr)
        return 1
    hits = []
    for path in sorted(pathlib.Path("Sources/CodeInsightApp").glob("*.swift")):
        for line in offending_calls(path.read_text(encoding="utf-8")):
            hits.append(f"{path}:{line}")
    if hits:
        print("\n".join(hits))
        print("FAIL: App 层用 localized() 取 model.* 键会显示键名原文，改用 modelText()", file=sys.stderr)
        return 1
    print("PASS: App 层的 model.* 文案都经 modelText()")
    return 0


if __name__ == "__main__":
    sys.exit(main())
