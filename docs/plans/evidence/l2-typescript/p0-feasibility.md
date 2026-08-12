# L2 TypeScript P0 feasibility evidence

> Date: 2026-08-12 (Asia/Shanghai)
> Scope: P0a grammar/ABI/link, bounded P0b Exact probe, P0c static anchors.
> No production code/tests/fixtures/gold were changed by this evidence.
> Overall P0: **NO-GO/BLOCKED** for production start; `.typescript` remains unsupported.

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

## P0c static anchors only

Real corpus candidate path from plan:
```text
/Users/siancao/work/ai/morphic
origin: https://github.com/miurla/morphic
HEAD: f31fe4a9ce2d355c3a44203fcb6add9296cc9b61
HEAD~1: 431e5c5e179b1b01946c6a5559ac43df459619db
classifier-supported tracked: 2 .ts + 51 .tsx
deferred .d.ts: 0
excluded .js: 1
config files: package.json, tsconfig.json, bun.lockb
```

Parent-recomputed config hashes:
- `tsconfig.json`: `54202f1d6d35ba51c3daea32bf67e8da24568ec0cb0c341fa0b5ed2ceb174f2d`
- `package.json`: `1305cb4500d734708db8af6b829b44177f3e8da3d15cc618d7f9cd1be3baca88`
- `bun.lockb`: `1af8613ebe88f16629b43e9c233ca5c8ba121299c9ce94549520354ee71c206f`

Static anchors:
- `components/search-results-image.tsx` selectedIndex at lines `35/54/69`
- `components/chat.tsx` relative import `./chat-panel` at line `3`
- `components/search-results-image.tsx` alias `Card` at line `4` targets `components/ui/card.tsx`
- `lib/agents/index.tsx` re-export via `export *` at line `1`
- `app/action.tsx` import of that re-export at line `12`
- `HEAD~1..HEAD` TSX hunk in `components/search-results-image.tsx` adds `onError`
  lines `78-80` and `112-115`

The following remain candidates/unvalidated, not results:
TSX outline/fold/local ref, alias Exact navigation, same-file/local binding,
relative import, `@/*` fuzzy unresolved + Exact resolved contrast, re-export
semantic navigation, Exact symbol behavior.

No outline/fold/Exact candidate results are recorded as GO.
P0c: static anchors frozen; semantic/fold/Exact gates INCOMPLETE after P0b stop.

## P0b: NO-GO/BLOCKED

- P0b is **NO-GO/BLOCKED** for production implementation.
- App validator remains `.typescript` unsupported.
- After this evidence no provider remnants were observed. Original repo/corpus
  working trees were clean.

### Driver constraints

Because production `Sandbox` was module-internal, the temp copy patched only access
level on `Sources/CodeInsightExact/Sandbox.swift`: public struct, public static
limit constants, public executable/arguments/environment/workingDirectoryURL
properties, and public init. Body unchanged.

The temp driver used current production Sandbox + LSPClient + CProcessGuard and
did not direct-launch node.

### Toolchain and LSP

External fixed toolchain:
```text
/opt/homebrew/bin/node
/opt/homebrew/lib/node_modules/typescript-language-server/lib/cli.mjs --stdio
```

Initialize advertised at least:
```text
definitionProvider=1
referencesProvider=1
implementationProvider=1
callHierarchyProvider=1
```

The sufficient L2 minimum `definition + references` was attempted. The probe
driver used wrong zero-based coordinates for the fixture: definition at
`line 0 char 8` landed on a space and references at `line 1 char 8` landed on a
blank line, so no semantic definition/references PASS is recorded.

### PID tree and lifecycle stop

Successful cache was under real `TMPDIR`:
```text
/private/var/folders/9k/7j3z072513z5hkf_xgcxzdzm0000gn/T/p0b-cache.96K16d
```

mkdir control under `/var/folders` passed:
```text
control1 status=0
control1 exists=true
```

Probe PID tree before close:
```text
PID 85194 sandbox-exec -> /opt/homebrew/bin/node ... typescript-language-server/lib/cli.mjs --stdio
PID 85196 PPID=85194 PGID=85194 /opt/homebrew/Cellar/node/26.7.0/bin/node ... tsserver.js --serverMode partialSemantic ...
PID 85197 PPID=85194 PGID=85194 /opt/homebrew/Cellar/node/26.7.0/bin/node ... tsserver.js --serverMode ...
PID 85198 PPID=85197 PGID=85194 /opt/homebrew/Cellar/node/26.7.0/bin/node ... typingsInstaller.js ...
```

After `client.close(grace: 2)`:
- direct PID 85194 was gone.
- residual tsserver PID 85197 remained, reparented to PPID 1, PGID 85194.
- PID 85198 was observed as an existing typings installer at that snapshot; after
  forced cleanup it was gone with 85197.

Manual cleanup:
```sh
kill -9 85197 85198 || true
```

Then a `ps` match on `85194|85196|85197|85198|typescript-language-server|tsserver`
showed no rows.

Not completed after the stop condition and not invented here:
ATA/plugin execution, deny-network proof, project-write proof,
historical-snapshot identity, cancel/restart/crash recovery, zero residual descent,
TSX didOpen, real corpus Exact navigation, no-semantic-pass.

## Overall conclusion

- P0a: **GO**
- P0b: **NO-GO/BLOCKED**
- P0c: static anchors frozen; semantic/fold/Exact gates **INCOMPLETE** after P0b stop
- Overall P0: **NO-GO/BLOCKED**
- L2 production implementation: not started; `.typescript` remains unsupported.
