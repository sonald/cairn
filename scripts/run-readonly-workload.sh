#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app_bin=""
suite="all"
manifest="$root/fixtures/readonly/manifest.json"
enforce_budgets=false
result_dir="$root/.build/readonly-workload"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-bin) app_bin="$2"; shift 2 ;;
        --suite) suite="$2"; shift 2 ;;
        --manifest) manifest="$2"; shift 2 ;;
        --enforce-budgets) enforce_budgets=true; shift ;;
        --out|--output-dir) result_dir="$2"; shift 2 ;;
        --help|-h) echo "usage: $0 --app-bin BIN [--suite identifiers|gutter|projection|reflow|lifetime|all] [--manifest JSON] [--out DIR] [--enforce-budgets]"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -x "$app_bin" ]] || { echo 'executable --app-bin required' >&2; exit 2; }
mkdir -p "$result_dir"
case "$suite" in identifiers|gutter|projection|reflow|lifetime|all) ;; *) echo 'invalid suite' >&2; exit 2 ;; esac
if [[ "$enforce_budgets" == true ]]; then
    echo '{"schemaVersion":1,"status":"fail","reason":"S0 has no calibrated timing/memory budgets; --enforce-budgets is unsupported"}' > "$result_dir/result.json"
    exit 1
fi
python3 - "$manifest" <<'PY'
import hashlib, json, pathlib, sys
manifest_path = pathlib.Path(sys.argv[1])
root = manifest_path.parent
manifest = json.loads(manifest_path.read_text())
assert manifest['schemaVersion'] == 1 and manifest['seed'] == 260926
for item in manifest['fixtures']:
    data = (root / item['path']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == item['sha256'], item['path']
    assert len(data) == item['byteCount'], item['path']
    assert data.count(b'\n') == item['newlineCount'], item['path']
    assert data.count(b'\n') + 1 == item['logicalLineCount'], item['path']
    assert max(map(len, data.split(b'\n'))) == item['longestLineBytes'], item['path']
print('readonly fixture manifest verified')
PY
code_sha="$(git -C "$root" rev-parse HEAD)"
swift --version > "$result_dir/toolchain.txt" 2>&1
python3 - "$root" "$result_dir/source-state.json" <<'PYSOURCE'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', '--modified', '--others', '--exclude-standard']).decode().split('\0')
files = {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sorted(set(paths)) if p and (root / p).is_file()}
sha = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD']).decode().strip()
pathlib.Path(sys.argv[2]).write_text(json.dumps(dict(head=sha, dirty=bool(files), modifiedAndUntrackedSHA256=files), indent=2) + '\n')
PYSOURCE
status=0
fixture_dir="$(cd "$(dirname "$manifest")" && pwd)"
while IFS= read -r fixture; do
    output="$result_dir/$fixture.json"
    rm -f "$output"
    python3 - "$output" "$app_bin" "$fixture_dir/$fixture" "$suite" "$code_sha" <<'PYRUN' || status=$?
import json, pathlib, subprocess, sys
output, binary, fixture, suite, sha = sys.argv[1:]
try:
    result = subprocess.run([binary, '--self-test-readonly', '--fixture', fixture, '--suite', suite,
                             '--output', output, '--code-sha', sha], timeout=120)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    path = pathlib.Path(output)
    partial = json.loads(path.read_text()) if path.exists() else {}
    partial.update(schemaVersion=1, status='fail', reason='Native workload exceeded 120 second deadline')
    path.write_text(json.dumps(partial, indent=2))
    sys.exit(1)
PYRUN
done < <(python3 -c 'import json,sys; print("\n".join(i["path"] for i in json.load(open(sys.argv[1]))["fixtures"]))' "$manifest")
python3 - "$result_dir" "$manifest" "$status" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
reports = []
for entry in manifest['fixtures']:
    path = root / (entry['path'] + '.json')
    value = json.loads(path.read_text()) if path.exists() else {'status': 'fail', 'reason': 'app output missing'}
    if value.get('status') == 'pass':
        if value.get('fixtureSHA256') != entry['sha256'] or not value.get('events'):
            value = {'status': 'fail', 'reason': 'invalid workload evidence'}
    reports.append({'fixture': entry['path'], 'result': value})
statuses = {report['result']['status'] for report in reports}
status = 'pass' if statuses == {'pass'} and sys.argv[3] == '0' else 'blocked' if statuses == {'blocked'} else 'fail'
result = dict(schemaVersion=1, status=status, reports=reports)
(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(f'readonly workload: {status}; {root / "result.json"}')
sys.exit(0 if status == 'pass' else 2 if status == 'blocked' else 1)
PY
