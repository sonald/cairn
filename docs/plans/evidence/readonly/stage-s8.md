# S8 — independent chunked-content decision

Status: **prototype investigation complete; adoption deferred**.

The measured long-paragraph cost in S6 selects S8a. There is no additional concrete
cross-file reading requirement for S8b/c, so no speculative composition or logical
skeleton framework was built.

The standalone [prototype](../../../../Prototypes/ReadonlyChunkedContent/FINDINGS.md)
uses public TextKit 2 APIs and retains original source bytes. Release compilation
and enumeration boundary checks passed. Initial native execution exposed missing
paragraph ranges and a constrained text-view extent in the probe; these were
diagnosed and corrected before making a decision. Original failure artifacts are
retained, not counted as performance results.

The corrected ordinary/chunked Unicode comparison has matching source hashes,
exact native cross-chunk clipboard bytes, AX getter text/count and EOF selection.
All 11 sampled native caret rectangles are valid and visible. **Nine differ in
geometry**: for example UTF-16 position 8194 moves from `(521.32, 2360)` to
`(5, 2380)`, and EOF moves from y=4020 to y=4040. Splitting a natural paragraph
into separate `NSTextParagraph` elements changes this input's visual layout.

This concrete scheme fails the semantic adoption gate, so no 30-sample performance
comparison or product integration follows. No conclusion is made that all public
content-provider designs are impossible. Actual VoiceOver and manual drag/Shift
checks on the rejected prototype remain NOT_RUN; they cannot make the observed
geometry failure acceptable. The current Reader remains the product implementation.

[Compact evidence](../../../../Prototypes/ReadonlyChunkedContent/evidence.json)
records source/probe/raw-result hashes, environment, exact commands and failed
positions. Raw corrected results are `.build/readonly/s8-unicode-repaired/native-sizing/`;
the initial crash remains `.build/readonly/s8-unicode/`.
