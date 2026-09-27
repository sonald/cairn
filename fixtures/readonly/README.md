# Readonly workload inputs

Regenerate the six default inputs and hashes with `python3 scripts/generate-readonly-fixtures.py`.
The fixed seed is 260926. Inputs cover Rust, Python, TypeScript, TSX, 9,002 source lines and a >1 MiB single line; all include Unicode.

Run a built native executable:

```sh
scripts/run-readonly-workload.sh --app-bin .build/debug/codeinsight-app \
  --suite all --manifest fixtures/readonly/manifest.json --out .build/readonly-workload
```

Each fixture process has a 120 second deadline. A missing WindowServer session is blocked;
a timeout is a failure. `pass` means valid baseline capture, not that later optimization
workload gates or timing budgets passed. `--enforce-budgets` fails explicitly until budgets
are calibrated. Each event retains before/after/delta counters and actual background draw
counts. PNGs capture the cold and Overview windows. Synchronous operation-and-draw duration
is not stable-layout latency. Only the selected suite runs, with cold-display setup for every suite.

Generate optional scale inputs outside the checked-in fixture set:

```sh
python3 scripts/generate-readonly-fixtures.py --scales --out .build/readonly-scales
```

This creates a separate manifest including 10k/30k/50k/100k line inputs. Pass that manifest
explicitly to the runner. Scale inputs are not in the default run.

Refresh and multiple windows exercise Reader entry points, not the application's file
watcher/session coordinator. VoiceOver, drag, full application routing, peak memory,
first paint and stable-layout latency require separate acceptance.
