# L3 mixed-language P0 feasibility evidence

> Date: 2026-08-15 (Asia/Shanghai)
> Baseline: `5af5d8253d3099214e91f56ae40b1758d5fbabfe`
> Result: **GO for F0; production mixed-language support is not implemented.**
> Scope: fixed-corpus, shared snapshot/store/cache, three real Exact providers,
> schema migration model, and native chooser feasibility. All throwaway probe
> source, clones, caches, and provider writes stayed outside the repository.

## 1. Host and safety boundary

```text
branch: main
HEAD: 5af5d8253d3099214e91f56ae40b1758d5fbabfe
RECORD: unset
Swift: Apple Swift 6.3.3
Xcode: 26.6 (17F113)
macOS: 26.6.1 (25G76)
```

The CodeInsight worktree/index were clean before the P0 probes except for the
untracked L3 plan. After P0 they contain only this plan and this evidence file.
No production source, test, fixture, gold, dependency, package manifest, cache
schema, or protected evidence was changed.

The fixed corpus was cloned into a private temporary directory. Both the Safe
clone and the separate Trusted clone finished with:

```text
HEAD: 457b66e72da1967c2432131a7ff8adc4341eb337
git status --porcelain=v1 --ignored --untracked-files=all: empty
git ls-files -s SHA-256:
5bc1b2d621663fa2e74715e925013c285f80add410654339c24749487867065d
```

## 2. P0a: fixed corpus and unit roots — GO

Repository: `https://github.com/sonald/llm-tools.git`

Current fixed revision:

```text
457b66e72da1967c2432131a7ff8adc4341eb337
tracked .rs: 11
tracked .py: 8
tracked .ts: 22
tracked .tsx: 4
tracked .d.ts: 1 (unsupported and excluded)
tracked .js: 0
```

The three selected-language roots are unique under the approved
one-profile-per-language rule:

| Language | Marker | Selected root |
|---|---|---|
| Rust | `crates/qrcode2txt/Cargo.toml` | `crates/qrcode2txt` |
| Python | `pyproject.toml` | `.` |
| TypeScript | `tools/model-files-web/tsconfig.json` | `tools/model-files-web` |

The root-selection probe uses component arrays, not string-prefix matching. A
negative fixture with two independent Python roots returned `ambiguous`, and
`tools/py2` was not treated as a descendant of `tools/py`. This supports a
small private root-selection function; it does not justify a workspace graph,
registry, or profile router.

Configuration identities at the fixed revision:

| File | SHA-256 |
|---|---|
| `pyproject.toml` | `0c48694c3cc9668d7e062a03e98ab41d53a5b68a7500bd977da826e5f01273e6` |
| `uv.lock` | `562ebad06578ceca1bbcd1888942fcb8bf001340dbd63ce6c4d5737c144dbe4c` |
| `crates/qrcode2txt/Cargo.toml` | `e0079b229039a8a02b440878c4235f6ac05a0c5e6db71b6cf61fcf28eee947a2` |
| `tools/model-files-web/tsconfig.json` | `770b4140bbb581e2dfd9ea9946ffc9c75a1d86ba7d2db5f77c83e37cbdf9d808` |
| `tools/model-files-web/package.json` | `798565f0dc3bcb30375457bd8e003d7c30b14679f0e79bc6a1c50ddd0d63eb6c` |
| `tools/model-files-web/package-lock.json` | `8373619bda0840fb24893976201504404cd0fde71f61621057b529dfc1719d31` |

Historical revision `6cc5b52f9f1bef28b27133155bbb858b2891c829` is reachable by first-parent
walk. Its supported-language counts are `11/9/0/0`; TypeScript therefore has
an honest empty historical profile. The frozen Compare file
`crates/qrcode2txt/tests/qrcode_monkey_fixtures.rs` is 45 lines there and 62
lines at the current revision, with 17 added lines.

## 3. P0b: shared snapshot, store, and cache — GO

### Shared identity and mode isolation

A throwaway Swift executable used only current public Core/Git/Engine APIs.
One `SameBytesSnapshot` exposed identical bytes at `same.rs`, `same.py`,
`same.ts`, and `same.tsx`. Three sequential language prepares into one
`ProjectIndexStore` proved:

```text
same-bytes snapshot=1 store=1 modes=4
```

All sessions retained the same `SnapshotID` and the same interner/store
identity. The four distinct keys were:

```text
rust / nil
python / nil
typescript / nil
typescript / tsx
```

No `ContentIndexKey`, cache schema, or codec change is needed.

### Capture and read cost

The fixed commit tree contains 146 blobs totaling 6,225,189 bytes. A single
union `CommitSnapshot` capture/read and three equivalent captures measured:

```text
capture pass=1  files=146 bytes=6225189 elapsed=0.045328667s
capture pass=2  files=146 bytes=6225189 elapsed=0.023264375s
capture pass=3  files=146 bytes=6225189 elapsed=0.020116250s
once=0.045328667s; three total=0.088709292s
```

Current `prepareSnapshot` reads before it classifies by language. Three
language prepares therefore read the 146-file union three times: 438 reads and
18,675,567 bytes. This is recorded as the present implementation cost, not
hidden as 45 source reads. The measured cost is far below the existing 30
second boundary, so P0 does **not** authorize a speculative pipeline or
filter-before-read refactor. Revisit only if a later real gate crosses the
budget.

### Cold/hot cache matrix

Cold mixed, mixed-to-singleton, and mixed hot:

| Run | Extracted | Reused | Total |
|---|---:|---:|---:|
| mixed cold | 45 | 0 | 0.1611 s |
| mixed → Rust singleton | 0 | 11 | 0.0260 s |
| mixed hot | 0 | 45 | 0.0637 s |

Fresh singleton-first cache:

| Run | Extracted | Reused | Total |
|---|---:|---:|---:|
| Rust singleton cold | 11 | 0 | 0.0418 s |
| singleton → mixed | 34 | 11 | 0.1295 s |

Cold mixed phase timings:

| Language | cached/first-paint prepare | full extraction | Files |
|---|---:|---:|---:|
| Rust | 9.8 ms | 26.2 ms | 11 |
| Python | 10.6 ms | 17.0 ms | 8 |
| TypeScript/TSX | 7.2 ms | 46.6 ms | 26 |

A fresh `/usr/bin/time -l` run measured 45,629,440 bytes maximum RSS and
33,554,936 bytes peak memory footprint. The cold mixed full sequence was
0.1498 seconds; hot mixed was 0.0640 seconds. All are well within the existing
30 second product wait boundary.

## 4. P0c: nested Exact providers and warm budget — GO

### Toolchain

| Provider | Version |
|---|---|
| rust-analyzer | `0.0.0 (b54a82b321 2026-08-02)` |
| Pyright | `1.1.411` |
| Python interpreter identity | Python `3.14.6` |
| typescript-language-server | `3.3.0` |
| TypeScript | `5.0.2` |
| Node | `v26.7.0` |

No package manager, build script, dependency install, venv creation, or
project Node/Python executable was run.

### Safe real-provider sequence

The probe used the exact nested roots and frozen symbols from the plan. It
created one provider/session at a time and closed it before constructing the
next:

| Sequence | Symbol | Definition | References | Negotiated maximum | Ready |
|---|---|---:|---:|---|---:|
| Rust | `Report::from_results` | 1 | 2 | definition, implementation, call hierarchy, references | 2.034 s |
| Python | `LogitsAnalyzer.get_top_tokens` | 1 | 2 | definition, call hierarchy, references | 0.390 s |
| TypeScript | `inspectTokenizerStructure` | 1 | 8 | definition, implementation, call hierarchy, references | 0.525 s |
| Rust again | `Report::from_results` | 1 | 2 | same as Rust | 2.013 s |

The longest switch was 2.034 seconds. This supports the approved single warm
provider design; a provider pool or LRU has no measured job.

The first TypeScript attempt used a cache below the `/tmp` alias and exposed a
throwaway harness path-identity issue (`/tmp` versus `/private/tmp`). Repeating
with the system physical temporary directory and the same deny-network
sandbox passed. Production files were not changed, and the final sequence used
that non-aliased cache path.

### Trusted and sandbox semantics

A second disposable clone repeated Rust → Python → TypeScript → Rust with
`TrustMode.trusted`; the same definition/reference targets passed in
2.174/0.385/0.527/2.155 seconds. Its tracked/index/status/ignored state remained
identical to the Safe clone. Rust did not need to create `target/` on this
corpus. Python and TypeScript retain their existing Safe launch sandbox even
when the analysis attribution records Trusted; L3 does not add a project write
path for them.

Host-level sandbox tests were rerun outside the outer tool sandbox so they did
not silently skip:

```text
project write: denied, status=1
network to local listener: denied, status=1
Trusted Rust target: allowed
Trusted network: denied
CARGO_NET_OFFLINE: 1
```

Focused cancellation/lifecycle tests passed:

- TypeScript batch cancellation drops the late result and accepts a new request;
- Pyright batch cancellation accepts a new request;
- rust-analyzer cancelled queued batch never publishes the stale request;
- forced close reaps an unresponsive LSP process.

After the real provider sequence, a host `ps` scan found no rust-analyzer,
pyright-langserver, typescript-language-server, `tsserver.js`, or `cli.mjs`
descendant.

## 5. P0d: session migration and native chooser — GO

The current v1 codec regression
`sessionCodecPersistsLanguageAndMigratesMissingLanguageToRust` passed live.
A throwaway migration probe then applied the proposed v2 boundary:

```text
v1 accepted: missing language plus Rust/Python/TypeScript singleton = 4
v2 accepted: 3 singleton + 3 two-language + 1 three-language set = 7
rejected: v1+languages, empty, duplicate, unsorted, JavaScript, unknown,
          and v2+language = 7
dependency tabs: 3 uniquely classified; 2 unsupported/extensionless skipped
mixed profile title: pass
```

This confirms that schema v2 can be implemented by extending the existing
private `Envelope`; no tab/excerpt language field or new session DTO is needed.

A throwaway AppKit executable constructed a native `NSAlert` with one
`NSStackView`, two labels, three `NSButton` checkboxes, and the existing
Open/Cancel buttons. It proved:

```text
AXGroup / AXStaticText / AXCheckBox / AXButton roles
checkbox labels and boolean values present
0 or 1 selected => Open disabled
2 or 3 selected => Open enabled
Cancel => zero open callback/state mutation
```

Unattached offscreen AppKit controls initially reported `AXUnknown`; explicitly
setting their native roles made the contract deterministic. That is a small
implementation detail inside the existing chooser function, not a reason for
an accessibility wrapper or chooser controller type.

## 6. Decision and next gate

P0 is **GO** under the approved boundaries:

- Git workspaces only;
- one profile per selected language;
- one shared snapshot/store and four existing mode keys;
- one warm Exact provider;
- no cross-language fuzzy/Exact relations;
- explicit 2...3-language chooser;
- schema v2 project-level language array only;
- no new public type, protocol, registry, router, provider pool, or dependency.

The measured duplicate reads are accepted at this corpus size; the first lazy
solution that works is to leave them alone. The next authorized stage is F0:
refresh the live baseline, full product gates, test inventory, and protected
hashes. F1 production work must still start with red tests and must not make the
Mixed entry visible before the planned cutover.
