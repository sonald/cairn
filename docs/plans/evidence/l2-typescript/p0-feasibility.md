# L2 TypeScript P0 feasibility evidence

> Date: 2026-08-12 (Asia/Shanghai)
> Scope: P0a grammar/ABI/link, P0b Exact/trust/lifecycle rerun, P0c corpus anchors.
> No production code/tests/fixtures/gold were changed by this evidence.
> Roadmap note: P0 originally allowed evidence/probe only; the `0637a7e`
> process-guard stop-condition fix is a user-authorized, independently
> committed change.
> Overall P0: **GO** for plan gate; `.typescript` remains unsupported until F7b.

## P0a: GO

### Source freeze

Official repo: `https://github.com/tree-sitter/tree-sitter-typescript`

Release/tag:
- `v0.23.2`
- `git ls-remote https://github.com/tree-sitter/tree-sitter-typescript.git refs/tags/v0.23.2`
- tag ref: `f975a621f4e7f532fe322e13c4f79495e0a7b2e7`

Shallow fetch in temp dir proved the tag ref is a lightweight/commit ref:
```text
git clone --quiet --depth 1 --branch v0.23.2 https://github.com/tree-sitter/tree-sitter-typescript.git repo; clone_exit=0
git cat-file -t v0.23.2; commit
git rev-parse 'v0.23.2^{commit}'; f975a621f4e7f532fe322e13c4f79495e0a7b2e7
git cat-file -t "$(git rev-parse 'v0.23.2^{commit}')"; commit
git show -s --format='%H%n%s%n%aI' HEAD
f975a621f4e7f532fe322e13c4f79495e0a7b2e7
0.23.2
2024-11-10T21:32:53-05:00
```

Archive:
- URL: `https://github.com/tree-sitter/tree-sitter-typescript/releases/download/v0.23.2/tree-sitter-typescript.tar.xz`
- Size: `1031994` bytes
- SHA-256: `2d324af0616a692cc6fcaea35442a816decb2ef0d05242953cb1feb15a5dc72d`
- MIT license in `LICENSE`

Worker note: my first transcribed hash was wrong and is not included here as fact.
A parent-driven re-download independently recomputed the release archive hash and
preserved the correct parent-independent value above.

### Parser ABI, entries, field lookup

Current runtime is vendored tree-sitter v0.25.8:
- `TREE_SITTER_LANGUAGE_VERSION 15`
- `TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION 13`
- enforced in `Sources/CTreeSitter/src/parser.c:2004-2007`

TypeScript grammar `v0.23.2`:
- entry: `tree_sitter_typescript()`
- ABI: 14
- symbol_count: `376`
- external_token_count: `10`
- field_count: `40`

TSX grammar `v0.23.2`:
- entry: `tree_sitter_tsx()`
- ABI: 14
- symbol_count: `393`
- external_token_count: `10`
- field_count: `43`

Node-types field list: both grammars expose the runtime fields used by the
planned extractor/Reader slice: `name`, `body`, `parameters`, `parameter`,
`return_type`, `source`, `declaration`, `value`, `left`, `right`, `object`,
`type`, etc. TSX additionally exposes `attribute` and `open_tag` for JSX.

Field lookup during P0a probe:
```text
TS function_declaration name_kind=identifier body_kind=statement_block
```

### Compile/link probe

Dual grammar one-target link was tested against the current runtime in throwaway
temp dirs only.

Command shape:
```sh
cc -I<runtime api include> -I<release common> -I<TS src headers> -I<TSX src headers> \
  <release>/typescript/src/parser.c \
  <release>/typescript/src/scanner.c \
  <release>/tsx/src/parser.c \
  <release>/tsx/src/scanner.c \
  <repo>/Sources/CTreeSitter/src/lib.c probe.c
```

Result: `cc_exit=0`.

Parse:
```text
TS lang=<p> tsx lang=<p> version_ts=14 version_tsx=14
TS root=program error=0 no_error=1 PASS
TSX root=program error=0 no_error=1 PASS
TS_on_TSX root=program error=1 no_error=0 PASS
```

The SwiftPM throwaway probe using current TreeSitterKit source and both vendor
grammars also built and ran with exit 0, producing same ABI and parse results.

Minimal vendor allow-list, 14 exact paths from the release archive:
```text
LICENSE
common/scanner.h
typescript/src/parser.c
typescript/src/scanner.c
typescript/src/node-types.json
typescript/src/tree_sitter/parser.h
typescript/src/tree_sitter/alloc.h
typescript/src/tree_sitter/array.h
tsx/src/parser.c
tsx/src/scanner.c
tsx/src/node-types.json
tsx/src/tree_sitter/parser.h
tsx/src/tree_sitter/alloc.h
tsx/src/tree_sitter/array.h
```



## P0b: GO (rerun on `0637a7e`)

Commit: `0637a7ee7bfb71bca7a4bdeb3ba08b474f5dda71`.
Chain: `Sandbox -> LSPClient -> CProcessGuard`.

### Toolchain

```text
node: v26.7.0
typescript-language-server: 3.3.0
typescript: 5.0.2 (from package.json)
/opt/homebrew/bin/node
/opt/homebrew/bin/typescript-language-server
/opt/homebrew/lib/node_modules/typescript/bin/tsserver.js
```

`$/typescriptVersion` source = `user-setting`.
Capabilities advertised: definition/references/implementation/callHierarchy.

### Basic TS fixture

TS fixture: definition PASS; references returned declaration + import/use:

```text
file:///private/tmp/p0b-fixture/src/definition.ts 0:16..22 declaration
file:///private/tmp/p0b-fixture/src/main.ts 0:9..15 import
file:///private/tmp/p0b-fixture/src/main.ts 1:12..18 use
```

### Basic TSX byte-coordinate evidence (`/private/tmp/basic-tsx-component`)

New fixture:
```text
definition.tsx
export function Badge(){return <span>ok</span>}

main.tsx
import { Badge } from './definition'; export const view = <Badge />;

tsconfig.json: module esnext / moduleResolution bundler / jsx react-jsx
```

- `main.tsx` import identifier `Badge` (`0:9..0:14`) definition resolves to
  `definition.tsx` `0:16..0:21` (`export function Badge`).
- references with includeDeclaration=true = 3: decl + import + JSX use
  (`main.tsx` `0:57..0:62`).
- JSX use query `definition` result `[]`; recorded as observed boundary.
- basic TSX definition+references gate PASSes at import/declaration coordinates.
- close `forceKill=false reap=true`.

The previous wrong `main.tsx 1:17` label fixture description is removed.

### first / warm / cancel / timeout

```text
first_ms=255.765 (one run; another measured 253.335)
warm_ms=1.120 (one run; 0.991 in another)
timeout_expected_error=timeout("textDocument/definition")
```

Real TLS cancel transcript `/private/tmp/p0b-evidence/cancel-real.txt`:
```text
attempt=1 elapsedMs=1.44195556640625 wait=success cancelResult=cancelled("workspace/symbol") late=no
new_request_after_cancel workspace/symbol succeeded (returned symbol v0_0)
closed forceKill=false reap=true
```

That is the real-server cancel evidence for `workspace/symbol`; no late
response was observed. The shared `ExactRequestBatch` focused test remains the
deterministic cross-provider regression.

### Restart

```text
ROOT_PID=29378
restart root=29383
restart_count=1
SECOND_ROOT_PID=29389
second_crash_unavailable=connectionClosed
```

### ABRT / KILL PID sets

ABRT rows:
```text
29009 28976 28975 /private/tmp/p0b-codeinsight/.build/debug/p0b-driver ... hold-query
29013 29009 29013 ...
29014 29009 29014 /opt/homebrew/bin/node ... --stdio
29015 29014 29014 tsserver.js --serverMode partialSemantic --disableAutomaticTypingAcquisition ...
29016 29014 29014 tsserver.js ...
after: no rows
```

KILL rows:
```text
29039 28976 28975 ...
29043 29039 29043 ...
29044 29039 29044 /opt/homebrew/bin/node ... --stdio
29045 29044 29044 tsserver.js --serverMode ...
29046 29044 29044 tsserver.js ...
after: no rows
```

### force arm

Real TLS forced transcript `/private/tmp/p0b-evidence/forced-tls.txt`:
```text
ROOT_PID=34519
before: 34519 /opt/homebrew/bin/node ... --stdio
        34532 34519 34519 tsserver.js --serverMode partialSemantic ...
        34533 34519 34519 tsserver.js ...
close grace=0.1 forceKill=false reap=true
after:  34532  1 34519 (immediately reparented)
        34533  1 34519 (immediately reparented)
```

The wrapper ignored TERM, so the immediate close was `forceKill=false` (not
called a force path). The same guard-owned group (`34519`) then reaped the
captured set to zero within 2s. The existing `closeForceKills...` test
separately proves `didForceKill=true`; plan only requires bounded zero, so
lifecycle gate PASSes with the honest window.

Direct root SIGKILL in other probe arms only came from the restart arm.

### Security gaps

Adversarial marker tree (hashes equal before/after):
```text
bin/bun bin/node bin/npm bin/npx bin/pnpm
bin/tsserver bin/typescript-language-server bin/yarn
fake-plugin.js fake.helper
node_modules/typescript/lib/tsserver.js package.json
```

Safe argv: `--useInferredProjectPerProjectRoot --disableAutomaticTypingAcquisition`
and **no** `--globalPlugins`. Control argv:
`--globalPlugins fake --pluginProbeLocations .../fake-plugin.js`.

```text
marker_hit=
marker_exists=false marker_bytes=0
sandbox_write status=0 project_created=false cache_created=true
```

Network deny `(deny network*)`; local listener denied.

### PATH empty focused test

`executablePathScanIncludesStandardAbsoluteDirectoriesOnEmptyPath` PASSED
in rerun; confirms `/opt/homebrew/bin` and `/usr/local/bin` for empty PATH.

### LaunchServices real probe

Temp bundle `/private/tmp/p0b-ls-probe.Cdg4w4/P0bLS.app`,
bundle `dev.p0b.LaunchServicesProbe`, argv0 bundle executable path, env
`P0B_LS_LAUNCH=1`, exit 0 via `/usr/bin/open --env P0B_LS_LAUNCH=1 -W`.

PATH contained `/opt/homebrew/bin` and `/usr/local/bin`. Production
`executableSearchDirectories` seam diffed clean (0 lines; seam hash
`abbf47c30bc2cc8610f2ad9e236379ae1caf64970c18657a55e0071229336e3c`). Actual
canonical tools: node v26.7.0, typescript-language-server 3.3.0, tsserver
executable. TypeScript package.json reports 5.0.2.

LaunchServices final bundle discovery remains F1/C3/V0 scope; this is P0
toolchain discovery feasibility only.

### Historical Materializer identity

`Materializer` wrote 72 files under materialized `HEAD~1` root.
Workspace/materialized def/refs for `ChatPanel`/`ChatMessages` URIs switch
between `.../materialized-root/431e5c5e.../p0c-identity-probe` and
`/Users/siancao/work/ai/morphic`; no location/content drift.

`components/search-results-image.tsx` file identity:
```text
materialized HEAD~1: sha 38559bcfd2ef3d3cb88ab27f136128d01097ab5cffef47a24f5983152b4937dc, equals git show HEAD~1, has no onError hunk
worktree:            sha dda847cfcf2040884b94471a283261488860fee02b247ab073a9b2a84fde8e5a, has the onError hunk
```

Full morphic tree including ignored/untracked entries was hashed before/after
the P0 runs; the tree contents (including `components/search-results-image.tsx`
worktree sha above) were equal. Full tree hash value is not re-invented here;
the equality is the recorded fact.

## P0c: corpus and semantic boundary (GO)

Real corpus `morphic` same as plan:

```text
HEAD: f31fe4a9ce2d355c3a44203fcb6add9296cc9b61
HEAD~1: 431e5c5e179b1b01946c6a5559ac43df459619db
2 .ts + 51 .tsx
package.json  1305cb4500d734708db8af6b829b44177f3e8da3d15cc618d7f9cd1be3baca88
tsconfig.json 54202f1d6d35ba51c3daea32bf67e8da24568ec0cb0c341fa0b5ed2ceb174f2d
bun.lockb     1af8613ebe88f16629b43e9c233ca5c8ba121299c9ce94549520354ee71c206f
```

Exact anchors:
- `selectedIndex` decl `34:9`; refs `[34:9,53:19,55:11]`; setSelectedIndex `[34:24,68:29]`.
- `ChatPanel` refs 3, `ChatMessages` refs 3.
- `Card` alias resolved to `components/ui/card.tsx`; actual large server ref set, no count.
- `taskManager` def `5:22`, incoming `app/action 48:31`, outgoing console/lib.dom.
- `researcher` def `18:22`, incoming `app_81`, outgoing listed set incl. SearchResultsImageSection.
- `SearchResultsImageSection` 28:13, incoming `researcher 101:15`, outgoing `DialogHeader`.
- `querySuggestor impl=[] prepCall=<null>` observed boundary, not provider absence claim.

`@/*` fuzzy remains a frozen implementation boundary (no TS fuzzy implementation exists yet);
Exact `Card` resolved and aliases are comparison anchors, not a product claim.

TSX outline/fold/local refs stay F5 candidate expectations only.

## Overall GO

P0a grammar fixed. P0b TS/TSX exact definition/refs, lifecycle, PID, security,
Discovery, LaunchServices temp feasibility all PASS as stated. P0c exact
anchors frozen. No plan stop condition triggered. F1 may begin.
