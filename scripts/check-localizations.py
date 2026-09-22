#!/usr/bin/env python3
"""Check shipped UI keys, format arguments and native plural resources."""
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(lld|ld|lu|llu|d|u|f|g|@|%)")


def arguments(text):
    result = {}
    next_index = 1
    for match in FORMAT.finditer(text):
        position, kind = match.groups()
        if kind == "%":
            continue
        index = int(position) if position else next_index
        assert index not in result or result[index] == kind, text
        result[index] = kind
        next_index += 1
    return result


def read_resources(directory):
    path = directory / "Localizable.strings"
    values = json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(path)]))
    # plutil accepts duplicate keys; reject them before they silently overwrite.
    keys = re.findall(r'^"((?:\\.|[^"\\])*)"\s*=', path.read_text(), re.M)
    assert len(keys) == len(set(keys)), f"Duplicate key in {path}"
    plurals_path = directory / "Localizable.stringsdict"
    plurals = plistlib.loads(plurals_path.read_bytes()) if plurals_path.exists() else {}
    assert not values.keys() & plurals.keys(), f"Duplicate plural in {directory}"
    for key, entry in plurals.items():
        fmt = entry["NSStringLocalizedFormatKey"]
        variables = re.findall(r"%(?:\d+\$)?#@(\w+)@", fmt)
        assert variables, (key, fmt)
        variants = []
        for variable in variables:
            rule = entry[variable]
            assert rule["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType", key
            assert rule["NSStringFormatValueTypeKey"] == "lld", key
            assert "other" in rule, key
            if directory.name == "en.lproj":
                assert "one" in rule, key
            variants.extend(v for k, v in rule.items() if not k.startswith("NSString"))
        assert all(arguments(v) == arguments(variants[0]) for v in variants), key
        values[key] = variants[0]
    return values


def main():
    assert arguments("%@ has %lld matches") == arguments("%2$lld 处匹配：%1$@")
    assert arguments("%lld") != arguments("%@")
    total = 0
    for target in ("CodeInsightApp", "CodeInsightAppModel", "CodeInsightReaderUI"):
        root = ROOT / "Sources" / target
        en = read_resources(root / "Resources/en.lproj")
        zh = read_resources(root / "Resources/zh-Hans.lproj")
        assert en.keys() == zh.keys(), f"Language keys differ: {target}"
        for key in en:
            assert en[key] and zh[key], f"Empty translation: {key}"
            assert arguments(en[key]) == arguments(zh[key]), f"Format mismatch: {key}"
        for source in root.glob("*.swift"):
            for key in re.findall(r'localized(?:Format)?\("([^"\\]+)"\s*[,)]', source.read_text()):
                assert key in en, f"Missing {key} in {source}"
        total += len(en)
        print(f"PASS: {target}: {len(en)} bilingual keys")
    print(f"PASS: {total} bilingual keys, placeholders and plural rules")


if __name__ == "__main__":
    main()
