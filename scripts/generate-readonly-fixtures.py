#!/usr/bin/env python3
"""Deterministic S0 inputs; no runtime randomness or external dependencies."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parent.parent / 'fixtures' / 'readonly')
parser.add_argument('--scales', action='store_true', help='include 10k/30k/50k/100k line inputs; use --out .build/readonly-scales')
args = parser.parse_args()
root = args.out
root.mkdir(parents=True, exist_ok=True)
seed = 260926
sources = {
    'workload.rs': ''.join(f'// seed {seed}, 中文 e\u0301 😀\nfn function_{i}(value: i32) -> i32 {{\n    let repeated = value + {i};\n    repeated + repeated\n}}\n' for i in range(200)),
    'workload.py': ''.join(f'# seed {seed}, 中文 e\u0301 😀\ndef function_{i}(value):\n    repeated = value + {i}\n    return repeated + repeated\n\n' for i in range(200)),
    'workload.ts': ''.join(f'// seed {seed}, 中文 e\u0301 😀\nfunction function_{i}(value: number): number {{\n    const repeated = value + {i};\n    return repeated + repeated;\n}}\n' for i in range(200)),
    'workload.tsx': ''.join(f'// seed {seed}, 中文 😀\nexport function Component{i}() {{\n    const repeated = {i};\n    return <span>{{repeated}}</span>;\n}}\n' for i in range(200)),
    'large.rs': ''.join(f'// line {i}: repeated 中文 😀\n' for i in range(9001)) + 'fn tail(value: i32) -> i32 { value }\n',
    'long-line.rs': '// ' + 'repeated 中文 😀 ' * 50000 + '\nfn tail() {}\n',
}
if args.scales:
    for count in (10000, 30000, 50000, 100000):
        sources[f'scale-{count}.rs'] = ''.join(f'let value_{i} = {i};\n' for i in range(count))
entries = []
for name, source in sources.items():
    data = source.encode()
    (root / name).write_bytes(data)
    entries.append(dict(path=name, sha256=hashlib.sha256(data).hexdigest(), byteCount=len(data), newlineCount=data.count(b'\n'), logicalLineCount=data.count(b'\n') + 1, longestLineBytes=max(map(len, data.split(b'\n'))), language='python' if name.endswith('.py') else 'typescript' if name.endswith(('.ts', '.tsx')) else 'rust', variant='tsx' if name.endswith('.tsx') else None))
(root / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1, seed=seed, generator='scripts/generate-readonly-fixtures.py', fixtures=entries), indent=2) + '\n')
