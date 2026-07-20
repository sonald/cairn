# Rust gold set baseline

Measured on 2026-07-20 with `codeinsight goldset` against the unmodified ripgrep 14.1.1 and Tokio 1.47.1 source trees. Gold positions are 1-based UTF-8 byte coordinates, and expected targets come from manual source tracing rather than current engine output.

| Metric | ripgrep 14.1.1 | Tokio 1.47.1 |
|---|---:|---:|
| Assertions | 16 | 17 |
| `def` Top-1 accuracy | 5/6 (83.3%) | 8/8 (100.0%) |
| `def5` Top-5 recall | 2/3 (66.7%) | 3/3 (100.0%) |
| `nostrong` violations (wrongly high certainty) | 0/3 (0.0%) | 0/3 (0.0%) |
| `unresolved` conforming | 2/2 (100.0%) | 2/2 (100.0%) |
| No-result assertions | 3/16 (18.8%) | 2/17 (11.8%) |
| `KNOWN-FAIL` | 3 | 0 |
| Unexpected failures | 0 | 0 |

The no-result count includes expected unresolved macro calls: two in each corpus. ripgrep has one additional no-result binding failure.

## KNOWN-FAIL backlog

- `crates/core/main.rs:87:54`: the `search` call ranks the non-callable `mod search` binding before `fn search`.
- `crates/core/main.rs:112:10`: `WalkBuilder::build` is below the first five path-ranked same-name method candidates.
- `crates/core/main.rs:150:8`: the tail-expression use of local `matched` returns no resolution candidate.

## Commands

```console
swift run -c release codeinsight goldset goldset/ripgrep.gold --corpus /path/to/ripgrep-14.1.1
swift run -c release codeinsight goldset goldset/tokio.gold --corpus /path/to/tokio-tokio-1.47.1
```
