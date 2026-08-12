# L2 TypeScript implementation acceptance

> Started: 2026-08-12 (Asia/Shanghai)
> Source plan: `docs/plans/l2-typescript-plan.md` (untracked user input)
> Status: F0 recorded; P0 rerun evidence appended below; P0a GO, P0b GO, P0c GO; Overall P0 GO for plan gate. `.typescript` product support remains unsupported until F7b.

## F0 live baseline

### A. L2_BASE and worktree/index/untracked

Actual checkout is `2ace2ebf4ed78b1ae1bc1fa64b6d6917620c6b0d`. The plan draft's
"草拟时实施基线" SHA is the same `2ace2ebf4ed78b1ae1bc1fa64b6d6917620c6b0d`.

```text
git rev-parse HEAD
2ace2ebf4ed78b1ae1bc1fa64b6d6917620c6b0d

git status --short --branch
## main...origin/main [ahead 5]
?? docs/plans/l2-typescript-plan.md

git status --porcelain=v1 --untracked-files=all
?? docs/plans/l2-typescript-plan.md
```

Index and tracked worktree were clean. No file was staged. The only untracked file is the source
plan provided by the user. Protected paths below remained unchanged.

### B. Toolchain and RECORD

```text
RECORD: unset
swift: swift-driver version 1.148.6 Apple Swift version 6.3.3
node: v26.7.0
npm: 11.19.0
typescript-language-server: 3.3.0
typescript: 5.0.2
pyright: 1.1.411
python: 3.14.6
```

Canonical provider paths observed:

```text
typescript-language-server -> /opt/homebrew/bin/typescript-language-server
tsserver -> /opt/homebrew/lib/node_modules/typescript/bin/tsserver
```

### C. Full CI

Command used for the recorded run:

```sh
CODEX_SANDBOX=1 bash scripts/ci.sh
```

Result: shell exit `0` with one recorded test issue, not a new stable production regression.

Swifty test list inventory: 639 test entries via `swift test list` (with the repository-local
CLang/Swift module cache overrides that `scripts/ci.sh` sets).

The exit-0 test run included one recorded issue:

```text
✘ Test rulerEdgeLineDoesNotBleedAboveTheScrollView() recorded an issue
  at ReaderRulerBleedTests.swift:56:21:
  CGWindowListCreateImage(...) -> nil
```

That test was added in `17c0c7e` and requires a real Mac window capture; in this non-GUI
host/`swift test` context it fails at the `CGWindowListCreateImage` capture boundary before it can
measure pixels. The two comment-fold focused tests below pass directly, so the L1/L2 "Fold ID 5"
issue has not returned.

Self-test channels inside `scripts/ci.sh` all emitted `SELF_TEST_FINISH ... exit=0`:

```text
exact: SELF_TEST_FINISH ... channel=exact exit=0
diff:  SELF_TEST_FINISH ... channel=diff exit=0
reading: SELF_TEST_FINISH ... channel=reading exit=0
projector: SELF_TEST_FINISH ... channel=projector exit=0
fold: SELF_TEST_FINISH ... channel=fold exit=0
```

Release fold perf:

```text
candidateCount=8400
logicalFoldCount=4400
renderedFoldCount=200
foldLatencyMs=379.267
deltaBytes=5980160
status=pass
```

### D. Protected blob/tree freeze

With `git rev-parse HEAD:<path>`:

| Scope | Blob or tree |
|---|---|
| `Sources/CodeInsightEngine/CanonicalDump.swift` | `20ddd6f08d326d7e15074a7fb684680e7a8477bf` |
| `Prototypes/` | `27ff155fede12ff663030e1dd0cf52e6f8458887` |
| `goldset/tokio.gold` | `debbe499edd3bf6c3c75a37c2e59aa6e8e0f3db4` |
| `goldset/ripgrep.gold` | `b67ce3150035f29ce4aa3162bd15de65c9a5d159` |
| `goldset/mcp-python-sdk.gold` | `8acc33fa09ad2a16571c96b8e2f4c25c942a4edb` |
| `goldset/fixtures/` | `c3ecb4ec45e3c7ab2c6733b5fd72b16bbbf70c47` |
| `Tests/RustExtractorTests/Fixtures/` | `82f1d4251fb71da9ec20a904e6427c0c39451e6a` |
| `Tests/CodeInsightExactTests/Fixtures/` | `57d053cf1845fe174c1f894be74e1ac484a80cf8` |
| `docs/plans/evidence/m11/` | `4b1b7c00dddc18077c16d4b2cd555704f5f059e4` |
| `Sources/CTreeSitter/` | `14a506fa4b2a3712efb34cdbc42ccd4d10a8e033` |
| `Sources/CTreeSitterRust/` | `61f5fb9e9a0ffcdca398eae02b338592f7e45b94` |
| `Sources/CTreeSitterPython/` | `ae3bce11867d148decbaacecdb963325fa0b30ca` |
| `Package.resolved` | `a24e48a32ea8f7c994a712f1265ba1b3104a374e` |

`goldset/fixtures/` and the fixture/tree paths were still within the same tree hashes after all
checks.

### E. Gold and corpus counts

Gold gate command:

```sh
CODEX_SANDBOX=1 bash scripts/run-gold-gates.sh \
  --python-corpus /Users/siancao/work/ai/mcp/mcp-python-sdk \
  --python-revision f55831ee798cd4d7bafab4d50d6dba46e6fce387
```

Result: all gold gates passed.

```text
tokio gold: total=17, def top1=8/8, nostrong=0, unexpected failures=0
ripgrep gold: total=16, def top1=5/6, nostrong=0, unexpected failures=0
mcp-python-sdk gold: total=6, def top1=3/3, nostrong=0, unexpected failures=0
```

Frozen corpora:

```text
tokio: be8ee45, 720 .rs files
ripgrep: 4649aa9, 98 .rs files
python: f55831ee798cd4d7bafab4d50d6dba46e6fce387, clean, 204 tracked .py
```

### F. 14 legacy channels plus Python/F0 self-test status

`run-self-tests.sh` ran the full legacy 14 channels plus the Python 15th channel three times.
All three `run-self-tests.sh` artifacts are under `.build/self-test-run-*`; only this evidence
file is under `docs/plans/evidence/l2-typescript/`.

1. `self-test-run-20260812-193248-61516`: default `CODEINSIGHT_SELF_TEST_TIMEOUT_SECONDS=90`,
   with `CODEX_SANDBOX=1`. It produced `pass=14 fail=0 hang=1` because the Python channel was
   `HANG_BEFORE_FINISH python` and hit the 90 s watchdog before it could emit
   `SELF_TEST_FINISH`.
2. `self-test-run-20260812-193544-62325`: `CODEINSIGHT_SELF_TEST_TIMEOUT_SECONDS=240`,
   with `CODEX_SANDBOX=1`. It produced `pass=14 fail=1 hang=0`. Python emitted
   `SELF_TEST_FINISH ... channel=python exit=1` with the outer-sandbox error
   `sandbox-exec: sandbox_apply: Operation not permitted`.
3. `self-test-run-20260812-193908-62958`: `CODEINSIGHT_SELF_TEST_TIMEOUT_SECONDS=240`,
   with a fresh `CODEINSIGHT_INDEX_CACHE_ROOT` and the same fixed Python corpus, outside the
   Codex outer sandbox. It produced `pass=15 fail=0 hang=0`; Python emitted
   `SELF_TEST_FINISH ... channel=python exit=0` in about 4.04 s.

I did not prove the host run reused the same cache root as the sandbox runs. Each run created a
fresh cache root under `/private/tmp/...`; I can only say "fresh cache" for each, not "same
cache".

The successful 15-channel artifact is at `.build/self-test-run-20260812-193908-62958`.

### G. Focused comment-fold tests

Both comment/fold navigation tests pass with repository-local module caches:

```text
swift test --filter manualFoldsArbitrateInBothDirectionsAndLevelSwitchClearsEveryPair
✔ Test manualFoldsArbitrateInBothDirectionsAndLevelSwitchClearsEveryPair() passed

swift test --filter navigationUnfoldsManualAndBaselineAncestorsWithoutCrossingDirections
✔ Test navigationUnfoldsManualAndBaselineAncestorsWithoutCrossingDirections() passed
```

F0 conclusion: **PASS** for the requested baseline, with the two known/controlled notes:
`rulerEdgeLineDoesNotBleedAboveTheScrollView` fails at `CGWindowListCreateImage` unavailability in this
host, and the outer Codex sandbox blocks real nested provider sandboxing (`sandbox-exec`);
the host 15-channel Python path passed. No production files changed.

## P0 rerun

### Gate

- P0a: GO (unchanged).
- P0b: GO after lifecycle fix `0637a7e`.
- P0c: GO with semantic anchors frozen on `morphic`.
- Overall P0: GO for the plan gate; App still `.typescript` unsupported until F7b.

P0b TSX exact gate uses the basic TSX Badge fixture under
`/private/tmp/basic-tsx-component`: import identifier at `main.tsx 0:9..0:14`
resolves to `definition.tsx 0:16..0:21`, declaration refs
`includeDeclaration=true` return 3 (decl/import/JSX use).

### Main test result

Full `CodeInsightExactTests` focused lifecycle suite: 6/6 passed on the
current lifecycle fix tree. Path-discovery focused test
`executablePathScanIncludesStandardAbsoluteDirectoriesOnEmptyPath` PASSED in
the real rerun.

The full `CodeInsightExactTests` suite result 74/74 is recorded from this
round's main acceptance command, which exited 0.

### Focused lifecycle group A (6/6)

1. `closeForceKillsAndReapsUnresponsiveProcess`
2. `childProcessRegistryRegistersAndUnregistersConcurrently`
3. `crashGuardKillsRegisteredGrandchildAndReraisesAbort`
4. `terminationGuardKillsRegisteredGrandchildAndPreservesDefaultSignal`
5. `reaperKillsRegisteredGrandchildAfterParentSIGKILL`
6. `ciProcessGuardUnregisterKillsOwnedGroupLeaderAndGrandchild`

### Focused discovery/cancel/restart/guard group B (6/6)

1. `executablePathScanIncludesStandardAbsoluteDirectoriesOnEmptyPath`
2. `rustAnalyzerCancelledBatchNeverEntersProviderAfterOperationQueue`
3. `pyrightSessionRestartsOnceThenExhaustsAndIsUnavailable`
4. `closeForceKillsAndReapsUnresponsiveProcess`
5. `crashGuardKillsRegisteredGrandchildAndReraisesAbort`
6. `reaperKillsRegisteredGrandchildAfterParentSIGKILL`

Both groups were observed as 6/6 PASS in this round's captured log.

The shared production `ExactRequestBatch` test asserts cancelled old-batch
requests never enter the provider after the operation-queue gate; old response
count stays frozen at 1 and a new current request totals 2 (source
expectations), and is kept as the deterministic cross-provider regression.

Real TLS cancel transcript `/private/tmp/p0b-evidence/cancel-real.txt`:
`cancelResult=cancelled("workspace/symbol") late=no`, after 1.44 ms; new
`workspace/symbol` request succeeded; close `forceKill=false reap=true`.

### Lifecycle

Captured PID/PPID/PGID rows summarized:
```text
ABRT 29009 29013 29014 29015 29016
KILL 29039 29043 29044 29045 29046
after=empty
```

`forceKill=false` arm: `28984 28985 28986` before close, after empty; the
existing `closeForceKillsAndReapsUnresponsiveProcess` test covers the
production `forceKill=true` path. The restart feasibility session was
`29378 -> restart 29383 -> 29389`, `restart_count=1`,
`second_crash_unavailable=connectionClosed`.

Real TLS forced transcript `/private/tmp/p0b-evidence/forced-tls.txt`: root
`34519` + children
`34532/34533` same PGID `34519`; close `grace=0.1 forceKill=false`, children
immediately reparented then captured set zero within 2s via group guard. Not
called a forced path; `closeForceKillsAndReapsUnresponsiveProcess` separately
proves `didForceKill=true`.

### Security / project / cache

Adv marker tree (fake `node/npm/npx/bun/yarn/pnpm/tls/tsserver/plugin/helper`)
full-tree hash before == after. `marker_exists=false marker_bytes=0`.
Safe argv includes `--disableAutomaticTypingAcquisition` and does not include
`--globalPlugins`. Plugin control argv includes
`--globalPlugins fake --pluginProbeLocations .../fake-plugin.js`, proving
plugin/ATA options are forwarded in the argv; the marker itself was not
written (fake plugin API is not compatible).

`sandbox_write status=0 project_created=false cache_created=true`.
Network denied to local listener: yes, with sandbox `(deny network*)`.

Historical Materializer probe wrote 72 files for `HEAD~1`, and def/refs from
the materialized root returned URIs under
`.../materialized-root/431e5c5e.../p0c-identity-probe` and worktree root
switched to `/Users/siancao/work/ai/morphic`; no location/content drift.

### P0 discovery scope

PATH empty focused real PASS plus current normal-process canonical toolchain
paths are recorded for **P0 toolchain discovery feasibility** only.
LaunchServices real probe (temp bundle `dev.p0b.LaunchServicesProbe`) exited 0
via `/usr/bin/open --env P0B_LS_LAUNCH=1 -W`; inside the bundle argv0 was the
bundle executable path, PATH contained `/opt/homebrew/bin` and
`/usr/local/bin`, and the production `executableSearchDirectories` seam
diffed clean (0 lines changed; content hash
`abbf47c30bc2cc8610f2ad9e236379ae1caf64970c18657a55e0071229336e3c`).
Canonical tools: node `v26.7.0`, typescript-language-server `3.3.0`, tsserver
executable (TypeScript package version 5.0.2). This covers P0 toolchain
discovery feasibility;
final bundle discovery remains C3/V0.

### Do not infer product support

No production TS extractor / provider / Reader / `.typescript` cutover exists
yet. P0 GO only opens F1.
