#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1/Contents" ]]; then
    echo "usage: bash scripts/run-session-acceptance.sh <Cairn.app>" >&2
    exit 2
fi
app="$(cd "$1" && pwd -P)"
state="$(mktemp -d /tmp/cairn-session-acceptance.XXXXXX)"
python3 - "$state" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]) / 'project'
p.mkdir()
(p / 'main.rs').write_text('fn alpha() { beta(); gamma(); }\nfn main() { alpha(); }\n')
(p / 'other.rs').write_text('pub fn beta() { println!("beta"); }\n')
(p / 'third.rs').write_text('pub fn gamma() {\n' + ''.join(
    f'    // reading checkpoint {i:03d}\n' for i in range(180)
) + '    println!("gamma");\n}\n')
PY

run_phase() {
    local phase="$1"
    shift
    /usr/bin/open -n -W "$app" \
        --stdout "$state/$phase.stdout" --stderr "$state/$phase.stderr" \
        --env "CAIRN_SESSION_SELFTEST_URL=$state/session.json" \
        --env "CAIRN_SESSION_SELFTEST_DEFAULTS=dev.cairn.session.$(basename "$state")" \
        --env "CAIRN_SESSION_SELFTEST_EXPECTATIONS=$state/expectations.json" \
        --env "CODEINSIGHT_INDEX_CACHE_ROOT=$state/index-cache" \
        --args "$@"
}
run_phase save --self-test-session "$state/project"
run_phase restore --self-test-session-restart
python3 - "$state" <<'PY'
from pathlib import Path
import json, sys
p = Path(sys.argv[1])
def events(name):
    return [json.loads(line) for line in (p / name).read_text().splitlines()
            if line.startswith('{')]
saved = events('save.stdout')
restored = events('restore.stdout')
assert any(e.get('channel') == 'session' and e.get('passed') for e in saved), saved
assert any(e.get('willTerminate') for e in saved), 'normal WillTerminate was not reached'
result = next(e for e in restored if e.get('channel') == 'session-restart')
assert result['passed'] and all(result['checks'].values()), result
print('PASS: normal termination, actual Reader viewport/caret, trail identity, Back/Forward')
print(f'artifacts: {p}')
PY
