# S3 — fold topology and call ownership

Status: complete. Static relationships now belong to their immutable document/session.

## Fold behavior

ReaderDocument owns a FoldTopology with ID/source-line lookup, parent/children,
preorder subtree ranges and facet associations. Recursive siblings, ancestor
expansion, maximal visible folds, focus and scope-header association consume it.
Gutter summaries and attachment construction share its ID/header queries instead
of maintaining another permanent dictionary.

Normalized laminar folds use sorting plus a stack. Equal/crossing ranges and
nonmonotone custom depths use explicit, one-time compatibility relationships that
preserve the frozen depth/input-order semantics. Their O(F²) time/space ceiling is
reported by compatibilityReason/compatibilityRecordVisits; it is not presented as
a normal-tree bound. Duplicate IDs, empty bodies and invalid source boundaries are
rejected with a reason. Reader display/syntax checks reject before changing state,
retaining the old document instead of trapping in Dictionary(uniqueKeysWithValues:).

Facet association uses a balanced source interval index and subtree upper bounds,
not a fold-by-facet full scan. Input-order ties and the existing class-association
behavior are preserved. Focus target selection still examines outline facets;
this stage does not claim all focus work is constant time.

## Engine behavior

Each EngineSession owns CallOwnershipIndex values keyed by its ContentIndexKey.
A source sweep with a small priority heap chooses the smallest containing executable
region, then larger region ID and original input order. The complete call range
must also fit the chosen facet. Calls are grouped in source/original-index order;
Calls/Callers no longer scan all regions per query. Region lookup preserves the old
first occurrence for duplicate IDs. Resolver results remain per current context.

The 512 limit and truncated decision use the complete matching count. No persistent
extraction format changed and no intern IDs are cached across stores. There is no
unused per-call owner array: the actual consumer needs only grouped call indices
and the region-ID map. Build cost is O(R log R + C log C + C log R), with the call
sort omitted for source-ordered input; query work still includes resolution/output.

## Evidence

- 14 new index tests plus the frozen call oracle passed (9 ReaderCore + 6 Engine).
- 69 related regression tests passed across six targets, with complete summaries.
- All 5 prepared-gutter tests passed after topology integration.
- Release build, localization (795 keys), and `git diff --check` passed.
- Native Release captures passed for Rust/Python/TypeScript/TSX and the 50,000-line
  fixture. All used the normal topology path, with zero compatibility visits.
- The large fixture has 10,000 folds and 10,000 outline facets; association visited
  188,243 interval-query nodes instead of a 100,000,000-pair full scan. This is a
  measured work count, not a claimed wall-clock speed ratio.
- Single fold/unfold and Full/Overview operations had zero topology-build deltas.
  Generated interval tests also compare old parent/sibling/maximal semantics;
  Unicode rejection checks and a native invalid-document test verify safe retention.
- Engine tests cover generated overlaps, default arguments/closures/methods/top-level
  calls, 0/512/513 calls, distinct stores/profiles and old sessions. Repeated actual
  Calls/Callers queries show zero region scans and zero ownership rebuilds.

Artifacts are under `.build/readonly/s3-release/` and `.build/readonly/s3-50000/`;
`stage-s3-results.json` retains compact hashes and work counts. Initial preparation
counters now include document construction, before displaying the Reader. The runner
retains its existing extra syntax load, so construction counts are per actual object,
not advertised as one global build for every identical source instance.

Added 14 tests. CI main count is 1,077; the existing 2/2/1 isolation batches remain.
The original S0 native gaps and S7 dedicated timing requirements still apply.
