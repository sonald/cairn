# S5a — pure projection and explicit materialization

Status: complete. Full text installation remains; local updates belong to S5b.

ReaderProjection owns validated source/fold segments, UTF-16 starts and existing
mapping/copy semantics in ReaderCore. Construction uses the existing immutable
byte map and performs no source decoding, including the unfolded case. DisplayMap
is a compatibility adapter. UI materialization is an explicit existing-class
helper; no separate stateless materializer type was needed. Only installation
requests the projected string, once. Decoded-byte counters measure source slices.

Five new tests plus the frozen oracle passed (six total): randomized Unicode
projections, both mapping directions, all display selection ranges, hidden/visible
copy, CRLF, EOF, surrogate boundaries and rejected identities/ranges. The 1 MiB
collapsed-body test built geometry with zero decoded bytes and materialized two
visible bytes. CI main expected count is 1,090.

Native Debug projection captures passed for Rust, Python, TypeScript and TSX.
Raw events and cold/overview PNGs are in `.build/readonly/s5a-native/`; the Rust
overview was visually inspected. Counters are retained in stage-s5a-results.json.
These are behavior captures, not Release timing or S7 repeated-budget evidence.

Regression logs are `.build/readonly/s5a-core.log` and
`.build/readonly/s5a-regression.log`. The completed ReaderCore batch passed
196 tests. A combined ReaderUI/mouse run exited before the final summary and
was not accepted; the isolated ReaderUI rerun passed 32 tests and the mouse
rerun passed one test, both with complete summaries. No new
selection restoration or partial text commit is included in this stage.
