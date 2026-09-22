#!/usr/bin/env python3
"""Deterministic source fixtures; run from any directory to refresh the manifest."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent
operators = '''// Programming ligatures: != -> => <= >= !== === :: .. ...
fn compare(left: i32, right: i32) -> bool {
\tlet operators = "!= -> => <= >= !== === :: .. ...";
\t// 中文、emoji 👩🏽‍💻、combining é; Tab indentation and fallback fonts.
\tif left != right && left <= right { return true; }
\tlet range = 0..=10;
\tmatch left { 0 => false, _ => left >= right }
}
'''
(root / 'operators.rs').write_bytes(operators.encode())
(root / 'unicode-crlf.rs').write_bytes(operators.replace('\n', '\r\n').encode())
# Exactly 2,000 lines, fixed decimal indices and a 160-character string for wrapping.
regular = ''.join(f'let value_{i:04d} = left != right; // -> => !== === 中文 👩🏽‍💻 é {"x" * 160}\n' for i in range(2000))
(root / 'regular-2000.rs').write_bytes(regular.encode())
manifest = {}
for path in sorted(root.glob('*.rs')):
    data = path.read_bytes()
    manifest[path.name] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
                           'lines': len(data.splitlines()), 'maxLineBytes': max(map(len, data.splitlines())),
                           'utf16Units': len(data.decode().encode('utf-16-le')) // 2}
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
