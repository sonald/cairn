# M9 S4b real-provider evidence (2026-08-06)

## Verdict

**PASS.** S4a selected `experimental/serverStatus.quiescent`; the product now
waits for it outside `operationLock`, treats `ready + null` as a legal empty
result, and only retries `-32801 content-modified`. It retains the existing
batch/session gates at the lock boundary and before LSP send.

The fake-LSP checks cover quiescent waiting, legal ready-null return,
content-modified recovery without lock retention, and cancellation before an
RA request. The targeted tests pass. No new coordinator or readiness type was
introduced: the existing `LSPClient` condition owns the one boolean barrier.

## exact_fixture: ten independent real runs

Command (each in a fresh process):

```sh
CODEX_SANDBOX=1 .build/debug/codeinsight-app --self-test-exact .
```

All ten runs recorded `"realProvider":"passed"` and
`SELF_TEST_FINISH … channel=exact exit=0`. Each exercised real
rust-analyzer `12c3381f0b` with these four concrete results:

| direction | observed real result |
|---|---|
| implementations | `ExactFixtureBackend` in `src/lib.rs` |
| incoming calls | `relation_root` in `src/lib.rs`, `main` in `src/main.rs` |
| outgoing calls | `answer` in `src/lib.rs` |
| references | `textDocument/references` reached; declaration excluded by the real path |

The ten process starts (epoch seconds) were: 1785979843.849080,
1785979852.463907, 1785979860.931197, 1785979868.989355,
1785979877.148920, 1785979885.473445, 1785979893.782925,
1785979902.073358, 1785979910.302261, and 1785979918.356198.
No failure JSON or stderr was produced. The additional Context timing runs
also passed after adding observation-only fields.

## Tokio: five independent real runs

Corpus: tokio `be8ee45`, `tokio/src/sync/mutex.rs`, byte offset `15449`
(`Mutex::lock`); Rust analyzer ran Trusted with the already provisioned local
corpus. `indexHot=true` means the source index was ready before timing; each
run starts a new RA process. Context is measured from a fresh reader click
before the two relation actions, so it is not polluted by the relation
resolver cache.

| run | Context first / Exact (ms) | cold first / all (ms) | warm first / all (ms) |
|---:|---:|---:|---:|
| 1 | 327.343 / 4458.200 | 147.346 / 1650.795 | 323.648 / 323.651 |
| 2 | 259.470 / 3765.262 | 126.916 / 1784.886 | 336.884 / 336.886 |
| 3 | 266.591 / 3909.865 | 126.571 / 1645.180 | 360.585 / 360.587 |
| 4 | 259.277 / 3886.902 | 128.482 / 2028.484 | 327.713 / 327.716 |
| 5 | 258.404 / 3847.417 | 139.251 / 1988.674 | 329.523 / 329.525 |

All five have `passed=true`, a visible/selectable `blocking_lock` heuristic
row, 215 candidates, and `contextExactVisible=true`. Cold first actionable is
126.571–147.346ms, so all five meet the <=1s contract. Full results are
1.645–2.028s; Context's Exact upgrade is 3.765–4.458s. This preserves the
honest distinction: Relations becomes actionable early while Context Exact
can remain pending for several seconds.

Raw output is intentionally temporary (`/private/tmp/m9-s4b-exact/` and
`/private/tmp/m9-s4b-tokio-fresh-context-{1..5}.log`); there were no failure
artifacts to retain in the repository.
