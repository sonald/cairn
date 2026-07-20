# Exact Provider + Trust Boundary Spike

Date: 2026-07-20  
Host: macOS, Apple Silicon  
Tools: rust-analyzer `0.0.0 (ffcdbbd906 2026-07-13)`, typescript-language-server `3.3.0`, Pyright `1.1.411`

## Result

The stdio LSP lifecycle works for Rust, TypeScript, and Python, including three cross-file definition requests per process and graceful `shutdown`/`exit`. The Safe Mode configuration tested here prevented rust-analyzer from executing `build.rs` and from creating `target/`, while default rust-analyzer did both. A historical Rust commit can be copied into a private cache and analyzed independently without changing the source repository.

This supports a **limited Safe Exact mode for source-only Rust navigation**, but the rust-analyzer settings are configuration, not a security boundary. The product still needs OS-enforced read-only repository access, cache-only writes, no network, and process limits.

## Provider runs

Representative warm-host results (one run each; tiny fixtures):

| Provider | Initialize | Definition requests | Expected result |
|---|---:|---:|---|
| rust-analyzer | 8.3 ms | 2138.4 / 0.2 / 0.1 ms | `src/lib.rs:3:8` |
| typescript-language-server | 69.5 ms | 293.6 / 1.3 / 0.9 ms | `src/definition.ts:1:17` |
| Pyright | 106.0 ms | 176.3 / 4.4 / 0.3 ms | `definition.py:1:5` |

`initialize` returning does not mean the workspace is ready. rust-analyzer initially returned empty definitions and once returned JSON-RPC error `-32801 content modified` while loading. The probe retries only those two transient cases within a 30-second request budget; wrong locations and other errors fail immediately.

The installed TypeScript path is typescript-language-server backed by the machine's TypeScript (`tsc 5.0.2`), not the proposed native TS7 LSP. This run proves the generic LSP/helper path and tsserver-backed definition behavior only; it does **not** validate TS7-specific APIs or behavior.

## Safe Mode experiment

Fixture `build.rs` writes `BUILD_SCRIPT_RAN` in the project root. Before each arm, both the marker and `target/` are absent.

Safe initialization options:

```json
{
  "cargo": {"buildScripts": {"enable": false}},
  "procMacro": {"enable": false},
  "checkOnSave": false
}
```

Observed result:

| Arm | Definition correct | `BUILD_SCRIPT_RAN` | `target/` | Initialize / first definition |
|---|---|---|---|---:|
| Safe options | yes | absent | absent | 7.8 / 2322.9 ms |
| Default options | yes | present | present | 10.6 / 2520.9 ms |

The environmental XCTest `testSafeModeRequiresRustAnalyzer` repeats the assertions and skips when `/opt/homebrew/bin/rust-analyzer` is unavailable.

Conclusion for design §8.4: the options are effective on the tested rust-analyzer build for this tiny Cargo project, so Safe Mode can offer partial source navigation. They cannot justify the sentence “does not execute project code” by themselves: option names or behavior can drift, other subprocesses may still exist, and a compromised helper ignores configuration. Treat the options as defense in depth inside an OS sandbox, not as the trust boundary.

## Profile fingerprints

The probe computes SHA-256 over the configuration filename and bytes:

- Rust: `Cargo.toml`
- TypeScript: `tsconfig.json`
- Python: `pyproject.toml`

It computes `environmentFingerprint` over an existing language lockfile; no lockfile is represented by the empty string. Every provider command appends a byte to its configuration, asserts that `configFingerprint` changes, restores the original bytes, and asserts that the original fingerprint returns. The three fixtures had no lockfiles, so all environment fingerprints were empty.

## Historical materialization

The Rust fixture has two commits. HEAD places `answer` at line 3; HEAD~1 places it at line 1. Materialization uses `git archive` followed by `/usr/bin/tar`, so it neither checks out nor adds worktree metadata to the source repository.

Representative run:

```text
cache root/
  materialized/
    bf06ac830f654699ba9a845f4545a8e96777f5bd/
      33657bbbeb7b2c0cbe5f002814be7d53f9a4363844cd1da97e16df93b01ea2fe/
        Cargo.toml
        build.rs
        src/lib.rs
        src/main.rs
```

- First materialization: 135.3 ms.
- Second request for the same commit + config fingerprint: existing-directory hit, 0.0 ms, no archive/copy.
- Historical rust-analyzer definition: line 1, column 8.
- HEAD rust-analyzer definition: line 3, column 8.

The sandbox cannot write `~/Library/Caches`, so the probe maps the same layout under the process temporary directory: `.../T/CodeInsight/ExactProbe/Caches`. The App should substitute its real Application Support/Cache container URL without changing the key layout.

## LSP implementation notes

- `Content-Length` counts UTF-8 bytes, not Swift characters. The decoder retains partial headers/bodies and emits multiple coalesced frames.
- stdout is reserved for JSON-RPC; stderr must be drained independently or a noisy server can block.
- Servers can send requests to the client. The minimal client answers them rather than leaving the server waiting.
- `initialized` and `didOpen` are necessary but not a readiness barrier; progress notifications or bounded retry are required.
- Normal close is `shutdown` request → response → `exit` notification → wait. The fallback sends SIGTERM, then SIGKILL. The test uses an intentionally unresponsive process and asserts it is reaped.

## Recommended changes to design §8

1. Replace provider-wide `requiresTrustedExecution` with trust-dependent session preparation, minimally `prepare(snapshot:profile:trustMode:)`. rust-analyzer can provide useful definitions in Safe mode but has lower coverage without build scripts/proc macros; a single Boolean cannot express that.
2. Require `ExactSession` results to carry the cache/provenance identity already promised in prose: snapshot/tree identity, provider + tool version, config fingerprint, environment/dependency fingerprint, trust mode, generation time, and coverage/completeness.
3. Specify lifecycle/cancellation on `ExactSession`: readiness/progress, per-request timeout, graceful close, and forced termination. `prepare` alone does not define resource ownership.
4. Keep materialization outside the provider. The host should resolve an immutable cache directory keyed at least by commit/tree + config fingerprint + environment fingerprint + tool version, then pass that resolved snapshot to the helper.
5. Describe Safe rust-analyzer results as partial exact evidence. Missing macro/build-script-generated symbols are coverage gaps, not “not found”.

No reusable provider hierarchy, XPC layer, cache eviction policy, or TS7 adapter was added; those need product integration or the actual TS7 tool before they have a concrete job.
