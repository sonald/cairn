#!/usr/bin/env python3
"""Install two controlled harness edits on a clean tree; seal exact build artifacts."""
import argparse, hashlib, json, shutil, subprocess, time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=['install', 'seal', 'restore'])
parser.add_argument('--root', required=True, type=Path)
parser.add_argument('--receipt', required=True, type=Path)
parser.add_argument('--expected-sha')
parser.add_argument('--binary', type=Path)
args = parser.parse_args()
root = args.root.resolve()
base = Path(__file__).resolve().parent
sha256 = lambda data: hashlib.sha256(data).hexdigest()
def git(*arguments):
    return subprocess.check_output(['git', *arguments], cwd=root).decode()
def assert_controlled_tree(receipt):
    assert receipt['root'] == str(root) and git('rev-parse', 'HEAD').strip() == receipt['sourceSHA']
    paths = {item['path'] for item in receipt['files']}
    changed = set(filter(None, git('diff', '--name-only', 'HEAD').splitlines()))
    assert changed == paths, f'Unrecorded/staged build inputs changed: {changed ^ paths}'
    assert not git('ls-files', '--others', '--exclude-standard'), 'Untracked build inputs are forbidden'
    for item in receipt['files']:
        assert sha256((root / item['path']).read_bytes()) == item['patchedSHA256'], item['path']
def bundles(binary):
    return {str(file.relative_to(binary.parent)): sha256(file.read_bytes())
            for bundle in sorted(binary.parent.glob('*.bundle'))
            for file in sorted(bundle.rglob('*')) if file.is_file()}

if args.action in ('restore', 'seal'):
    receipt = json.loads(args.receipt.read_text())
    assert_controlled_tree(receipt)
    if args.action == 'seal':
        assert args.binary and args.binary.is_file(), '--binary must be the just-built Release executable'
        binary = args.binary.resolve()
        assert binary.stat().st_mtime >= receipt['preparedAtUnix'], 'Binary predates harness installation'
        resources = bundles(binary)
        assert resources, 'SwiftPM Release resource bundles must accompany the executable'
        receipt['sealedBuild'] = dict(binarySHA256=sha256(binary.read_bytes()),
            binaryPath=str(binary), resourceHashes=resources, sealedAtUnix=time.time())
        args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
        print('Sealed executable/resources against unchanged controlled source inputs')
    else:
        for item in receipt['files']:
            assert sha256(Path(item['backup']).read_bytes()) == item['originalSHA256'], 'Backup integrity mismatch'
        for item in receipt['files']:
            shutil.copy2(item['backup'], root / item['path'])
        print('Restored exact source originals; sealed build artifacts retained')
else:
    head = git('rev-parse', 'HEAD').strip()
    assert args.expected_sha and head == args.expected_sha, 'Require exact expected source SHA'
    assert not git('status', '--porcelain', '--untracked-files=all'), 'Install only in an entirely clean isolated worktree'
    assert not args.receipt.exists(), 'Receipt exists; preserve it and use a new path'
    # Self-tests moved into SelfTest/; keep older baselines installable.
    workload = next(p for p in ['Sources/CodeInsightApp/SelfTest/ReadonlyWorkloadSelfTest.swift', 'Sources/CodeInsightApp/ReadonlyWorkloadSelfTest.swift'] if (root / p).exists())
    paths = [workload, 'Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift']
    originals = {path: (root / path).read_bytes() for path in paths}
    app = originals[paths[0]].decode()
    if 'import CoreText\n' not in app: app = app.replace('import AppKit\n', 'import AppKit\nimport CoreText\n', 1)
    ui = originals[paths[1]].decode()
    # Fix the measured surface appearance without changing any user preferences.
    marker = '        settings.fontSize = 13'
    assert app.count(marker) == 1
    app = app.replace(marker, marker + '\n        if arguments.contains("--matched-perf") { settings.theme = .light }', 1)
    marker = '        window.makeKeyAndOrderFront(nil)'
    assert app.count(marker) == 1
    app = app.replace(marker, '        if arguments.contains("--matched-perf") { window.appearance = NSAppearance(named: .aqua) }\n' + marker, 1)
    assert 'MATCHED_PERFORMANCE_ADDON' not in app and 'matchedPerformanceGeometry' not in ui
    addon = (base / 'addon.swift').read_text()
    ready = 'reader.identifierPreparationState == .ready' if 'identifierPreparationState' in app else 'true'
    addon = addon.replace('__IDENTIFIER_READY__', ready).replace('__MEASURED_SOURCE_SHA__', head)
    marker = '        var events: [[String: Any]] = []'
    assert app.count(marker) == 1
    app = app.replace(marker, addon + '\n' + marker, 1)
    marker = '    public func clear() {'
    assert ui.count(marker) == 1
    ui = ui.replace(marker, (base / 'readiness.swift').read_text() + '\n' + marker, 1)
    marker = '            self.backgroundDrawCount += 1'
    assert ui.count(marker) == 1
    ui = ui.replace(marker, marker + '\n            if self.matchedFirstDrawInstant == nil { self.matchedFirstDrawInstant = ContinuousClock.now }', 1)
    patched = {paths[0]: app.encode(), paths[1]: ui.encode()}
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    backup_dir = args.receipt.parent / (args.receipt.stem + '-originals')
    backup_dir.mkdir(exist_ok=False)
    receipt = dict(schemaVersion=2, root=str(root), sourceSHA=head, sourceTreeSHA=git('rev-parse','HEAD^{tree}').strip(),
        sourceWasClean=True, preparedAtUnix=time.time(), protocol='s7-v2',
        installerSHA256=sha256(Path(__file__).read_bytes()), addonSHA256=sha256((base/'addon.swift').read_bytes()),
        readinessSHA256=sha256((base/'readiness.swift').read_bytes()), identifierReadinessExpression=ready, files=[])
    for i, path in enumerate(paths):
        backup = backup_dir / f'{i}.swift'
        backup.write_bytes(originals[path])
        receipt['files'].append(dict(path=path, backup=str(backup), originalSHA256=sha256(originals[path]), patchedSHA256=sha256(patched[path])))
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    for path in paths: (root/path).write_bytes(patched[path])
    print('Installed harness; build Release, seal --binary, archive executable/resources/receipt, restore')
