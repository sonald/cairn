# L3 mixed-language implementation acceptance

> Started: 2026-08-15 (Asia/Shanghai)
> Source plan: `docs/plans/l3-mixed-language-plan.md`
> Current status: C3 PASS; product cutover remains closed until F7.

## F0 live baseline

### A. Baseline identity and repository state

The approved plan and P0 evidence were committed as `9cbca29`. The live implementation baseline
was then stabilized by `bfcc8a0c4798d9cd6e2492bd9601fba739503b95` before any L3 production
slice began.

```text
HEAD:     bfcc8a0c4798d9cd6e2492bd9601fba739503b95
branch:   main
upstream: origin/main
ahead:    23
behind:   0
worktree: clean
index:    clean
untracked: none
RECORD:   unset
```

Repository secret scan result: clean. The scan excluded `.git/` and `.build/` and checked the
tracked source/docs surface for AWS access-key IDs, GitHub classic tokens, and private-key
headers.

### B. Toolchain and fixed external corpora

```text
macOS:                      26.6.1 (25G76)
Xcode:                      26.6 (17F113)
Swift:                      6.3.3
rust-analyzer:              0.0.0 (b54a82b321 2026-08-02)
Pyright:                    1.1.411
typescript-language-server: 3.3.0
Node:                       v26.7.0
npm:                        11.19.0
```

The real provider corpora remained clean before and after the gates:

```text
Python:     /Users/siancao/work/ai/mcp/mcp-python-sdk
revision:   f55831ee798cd4d7bafab4d50d6dba46e6fce387
status:     clean

TypeScript: /Users/siancao/work/ai/morphic
revision:   f31fe4a9ce2d355c3a44203fcb6add9296cc9b61
status:     clean
```

### C. Required CI and product gate

Sandbox-equivalent CI command:

```sh
CODEX_SANDBOX=1 bash scripts/ci.sh
```

Result: shell exit `0`. The complete Swift Testing run reported:

```text
Test run with 724 tests in 3 suites passed after 70.043 seconds.
```

The CI self-tests for Exact, Diff, Reading, Projector, and Fold all emitted
`SELF_TEST_FINISH ... exit=0`. Release fold performance also passed:

```text
candidateCount=8400
logicalFoldCount=4400
renderedFoldCount=200
foldLatencyMs=352.595
deltaBytes=5881832
status=pass
```

Host product command:

```sh
bash scripts/run-product-gates.sh \
  /Users/siancao/work/ai/mcp/mcp-python-sdk \
  /Users/siancao/work/ai/morphic
```

Result: shell exit `0`. The host CI passed, followed by the complete product matrix:

```text
PASS base
PASS project-git
PASS project-non-git
PASS tabs
PASS search
PASS reading
PASS projector
PASS fold
PASS diff
PASS pin
PASS history
PASS exact
PASS switch
PASS open
PASS python
PASS typescript
summary: pass=16 fail=0 hang=0
```

Artifacts: `.build/self-test-run-20260815-113058-31205`.

The Exact summary contains `realProvider=passed` and `realOfflineCoverage=passed`; no provider
skip was accepted. The Reading summary passed with `regularFootprintMB=44.079`, 201 verified
reference rows, honest partial coverage, geometry, navigation-history, and styling checks all
true.

### D. F0 prerequisite stabilization record

The first host product run exposed an existing deterministic gate defect rather than an L3
production regression:

```text
artifact: .build/self-test-run-20260815-105151-17460
summary:  pass=15 fail=1 hang=0
failure:  reading regularFootprintMB=100.126, all other reading checks true
```

The reading fixture had indexed its later 18,001-candidate reference-scale workload before
recording the regular-reader footprint. Commit `bfcc8a0` stages that workload only after the
regular measurement, reopens the same project, and waits for `.fullReady` before running the
unchanged reference checks. The 100 MiB budget was not changed. Independent focused replay and
the two complete gates above all passed.

### E. Frozen Gold totals

All four suites completed with no unexpected failures and no strong-resolution violations:

| Gold suite | Total | Definition Top-1 | Definition Top-5 | Unresolved | Known failures | Unexpected |
|---|---:|---:|---:|---:|---:|---:|
| tokio | 17 | 8/8 | 3/3 | 2/2 | 0 | 0 |
| ripgrep | 16 | 5/6 | 2/3 | 2/2 | 3 | 0 |
| mcp-python-sdk | 6 | 3/3 | 0/0 | 1/1 | 0 | 0 |
| morphic-typescript | 10 | 6/6 | 0/0 | 2/2 | 0 | 0 |

### F. Protected blob and tree freeze

The following `git rev-parse HEAD:<path>` identities are the F0 protection baseline:

| Scope | Blob or tree |
|---|---|
| `Sources/CodeInsightEngine/CanonicalDump.swift` | `20ddd6f08d326d7e15074a7fb684680e7a8477bf` |
| `Prototypes/` | `27ff155fede12ff663030e1dd0cf52e6f8458887` |
| `goldset/tokio.gold` | `debbe499edd3bf6c3c75a37c2e59aa6e8e0f3db4` |
| `goldset/ripgrep.gold` | `b67ce3150035f29ce4aa3162bd15de65c9a5d159` |
| `goldset/mcp-python-sdk.gold` | `8acc33fa09ad2a16571c96b8e2f4c25c942a4edb` |
| `goldset/morphic-typescript.gold` | `0b7c210f12d7184bcf06fa100da01281c1f64ef1` |
| `Tests/Fixtures/` | `0bf01b2d933cc801e6ad3a49df24c4e0ce9fce57` |
| `Tests/CodeInsightExactTests/Fixtures/` | `57d053cf1845fe174c1f894be74e1ac484a80cf8` |
| `Tests/RustExtractorTests/Fixtures/` | `82f1d4251fb71da9ec20a904e6427c0c39451e6a` |
| `Tests/PythonExtractorTests/Fixtures/` | `40c228b4a99d8ea2e3290dcb5898498aa4e3f186` |
| `Tests/TypeScriptExtractorTests/Fixtures/` | `c1683a05d57c249dce684eb087f72d2687cc1d50` |
| `Sources/CTreeSitter/` | `14a506fa4b2a3712efb34cdbc42ccd4d10a8e033` |
| `Sources/CTreeSitterRust/` | `61f5fb9e9a0ffcdca398eae02b338592f7e45b94` |
| `Sources/CTreeSitterPython/` | `ae3bce11867d148decbaacecdb963325fa0b30ca` |
| `Sources/CTreeSitterTypeScript/` | `dedc56757c32a44bf3bd30d8e26f18a3a70c363c` |
| `docs/plans/evidence/m11/` | `4b1b7c00dddc18077c16d4b2cd555704f5f059e4` |
| `docs/plans/evidence/l1-python/` | `cfb9e242d583961e86b44133f664d618bda1ab90` |
| `docs/plans/evidence/l2-typescript/` | `5034cd030d9b2a4f204d71dfc7d67dd631883517` |
| `Package.resolved` | `a24e48a32ea8f7c994a712f1265ba1b3104a374e` |
| `Package.swift` | `913b1de039b81d67c32b3f54cb627d4abbadc546` |

F0 verdict: **PASS**. L3 production remains rejected until the later cutover slice.

## C2 App/query/Reader/persistence checkpoint

The implementation through F5b is recorded by these stage commits:

```text
53a54f9 feat: publish mixed workspace sessions atomically
ed4453d feat: fence active session consumers by profile
57300e4 feat: search all workspace sessions
915ee38 feat: persist mixed language selections
15099ad feat: search symbols across workspace sessions
03de769 fix: route mixed reader state by file mode
d7c0072 feat: restore mixed workspace sessions
```

The four checkpoint targets were run serially from a clean worktree with repository-local
SwiftPM and Clang module caches. Every command exited `0`:

| Target | Result |
|---|---:|
| `CodeInsightAppModelTests` | 270 passed |
| `CodeInsightReaderCoreTests` | 113 passed |
| `CodeInsightReaderUITests` | 14 passed |
| `CodeInsightAppTests` | 75 passed |

Total: **472 passed, 0 failed**.

Focused deterministic tests cover workspace content and symbol search forwarding, cross-language
Reader/Context/Relation/Compare routing, snapshot/profile/generation stale completion rejection,
SessionCodec v1 compatibility, v2 canonical language arrays, mixed checkpoint/restore, Open Recent,
Retry, supported-suffix dependencies, and extensionless dependency rejection.

The production diff from C1 commit `af3d106` through C2 does not touch CodeInsightCore,
CodeInsightEngine, CodeInsightReaderCore, or CodeInsightReaderUI. An added-entity scan found no
mixed/session router, registry, aggregate, DTO, or new Core/Engine/Reader semantic abstraction.

C2 verdict: **PASS**. Mixed Exact and the product entry remain rejected until C3/F7.

## C3 Exact checkpoint

Nested profile fingerprints and provider switching are recorded by these stage commits:

```text
e2091cf feat: read exact profiles from nested roots
d587d8c feat: switch exact providers across mixed profiles
```

The complete Exact and AppModel targets were run against the committed implementation. Both
commands exited `0`:

| Target | Result |
|---|---:|
| `CodeInsightExactTests` | 91 passed |
| `CodeInsightAppModelTests --no-parallel` | 275 passed |

The five focused F6b tests also passed together. They cover nested worktree and commit provider
roots, workspace-relative result mapping, active-profile boundary rejection, preservation of a
true external dependency, invalid-prefix atomicity, Rust -> Python -> TypeScript -> Rust session
closure, one-warm prepare serialization, same-profile reuse, and foreign-language relation
rejection. The legacy root-profile path was separately characterized after fixing `.` prefix
normalization.

### Real provider repeat

The existing P0 probe was rebuilt from the current repository and run against the disposable,
clean clone below:

```text
repository: /private/tmp/codeinsight-l3-p0.tKX4qX/llm-tools
revision:   457b66e72da1967c2432131a7ff8adc4341eb337
index hash: 5bc1b2d621663fa2e74715e925013c285f80add410654339c24749487867065d
```

Live provider versions had advanced since P0 and were therefore re-recorded rather than assumed:

```text
rust-analyzer:              0.0.0 (f938641be5 2026-08-10)
Pyright:                    1.1.412
Python interpreter:         3.14.7
typescript-language-server: 3.3.0
TypeScript:                 5.0.2
Node:                       v26.7.0
```

Safe mode completed the fixed one-at-a-time sequence with exit `0`:

| Profile | Definition | References | Ready + query elapsed |
|---|---:|---:|---:|
| Rust `crates/qrcode2txt` | 1 | 2 | 4.084 s |
| Python `.` | 1 | 2 | 0.489 s |
| TypeScript `tools/model-files-web` | 1 | 8 | 1.570 s |
| Rust again | 1 | 2 | 2.473 s |

Trusted mode repeated the same sequence with exit `0`: 3.092 s, 0.437 s, 0.545 s, and
4.021 s. Every switch remained below the existing 30 second boundary. The provider capability
sets remained language-specific; no generic lifecycle or provider pool was introduced.

After both runs the clone remained at the same revision with empty status, worktree and index
diff exit `0`, and the same index hash. A host process scan found zero remaining rust-analyzer,
pyright-langserver, typescript-language-server, `tsserver.js`, or `cli.mjs` processes. The Exact
target's host sandbox tests also passed project-write denial, network denial, Trusted Rust
`target/` allowance, batch cancellation, forced close, and child-process reaping.

The production source diff adds only scalar root/prefix state and private path helpers to the
existing single `ExactCoordinator`. It adds no provider pool, registry, protocol, DTO, or public
semantic type, and does not refactor the three concrete provider implementations.

C3 verdict: **PASS**. The product entry remains rejected until the final F7 cutover.
