# S7 requirement-to-evidence matrix

Status: **development evidence at the user-adjusted testing scope; not full release approval**. This matrix records inspected evidence and its limits. It does not run tests, native UI, or performance jobs. Further measurement is stopped at the user’s request; final accounting uses only existing raw data; S8 has a separate completed investigation and a decision to defer adoption.

`PASS` below applies only to the stated scope. `PARTIAL` means some required scenario or evidence is absent. `PENDING` means work/results are still outstanding. `NOT_RUN` is not PASS and is not necessarily an environmental block. A passing model test, AX getter, bitmap, and real operator action prove different things.

## Evidence anchors

| Evidence | Confirmed result and boundary |
| --- | --- |
| [S0](stage-s0.md), [S1](stage-s1.md), [S2](stage-s2.md), [S3](stage-s3.md), [S4](stage-s4.md), [S5a](stage-s5a.md), [S5b](stage-s5b.md), [S6](stage-s6.md) | Completed implementation-stage checks, frozen references, actual work counters and native captures. Their single-run timings do not establish S7 statistical performance. |
| `.build/readonly/s7-ci-scheduling.log` | Full CI PASS: **1,138 tests** = 1,131 main + 2 bookmark + 2 panel + 1 isolated native mouse + 1 process font + 1 distributed font route; **795 bilingual keys**; architecture gates and exact/diff/reading/projector/fold native self-tests. Existing fold workload PASS has `budgetsEnforced=false`. CI's Exact self-test identifies its fake provider; it does not prove an external LSP session. |
| [Host records](stage-s7-hosts.json), `.build/readonly/s7-hosts/`, [retained PNGs](native-surfaces/) | **17 captures** cover main, secondary, Context, Settings, Reading Set, plain text and frozen-card before/after window recreation. JSON records positive actual draw-count deltas, nonblank sampled pixels, independent source/display hash equality, selection and private-pasteboard bytes. The two frozen-card captures have `windowVisible=false`: these are actual offscreen AppKit draws, not an onscreen operator or process-restart claim. |
| [Operator record](stage-s7-operator.json), [narrative](stage-s7.md) | Real native CUA/menu/keyboard workflow PASS: open → Find → definition/caller jump → focus → historical revision → freeze → normal quit → **new process** → worktree drift and frozen/historical identity checks. Historical commit `9aef36e5f62f499c948d6488444b6aaa86ac4b8a`; generated fixture HEAD `b279ae1fe5053c836681487ad28c3d60c3ea567b`. Two frozen caller excerpts retained their content IDs, byte ranges, revision and +1/+2 source despite worktree +101/+202; historical helper remained +10 while worktree became +999. The operator record reports real rust-analyzer ready in Safe mode, separately from the CI fake provider. |
| `.build/readonly/s7-session-scheduling.log` | Separate packaged-app two-process PASS: normal termination, actual Reader viewport/caret, trail identity and Back/Forward; artifacts `/tmp/cairn-session-acceptance.AZs4BQ`. This complements the actual frozen-tab operator restart. |
| S7 matched measurements | **Collected at user-adjusted scope: Rust/long-line 29 AC pairs each; other fixtures 30 each. Further sampling stopped.** The frozen repaired candidate `a99f10b` passes all six smoke inputs with matched configurations/outcomes. R4 remains complete historical evidence; r5 battery/transition samples stay outside the fixed-AC population. S0 Python font-only/combined reflow still fails fresh anchor validation. Superseded S6/r3 partial samples are excluded; no baseline stable samples are manufactured. |

## R01–R14

| Requirement | Status | Evidence and precise remaining boundary |
| --- | --- | --- |
| R01 — source snapshot identity | PASS, functional/native | S5 projection/copy tests and all six host surfaces preserve independently expected bytes/hashes. The actual historical/frozen operator restart verifies revision/content/byte-range identity against a deliberately drifted worktree. |
| R02 — byte/UTF-16/glyph/pixel coordinates | PASS, tested functional/native scope | Frozen projection oracle, Unicode/emoji/combining/CRLF/EOF tests, actual TextKit geometry, complete selection restoration and native Shift extension. Native mouse drag-selection is exercised. VoiceOver navigation is separately unverified under X01. |
| R03 — prepared identifier reuse | PASS, work-count/functionality; performance reported at actual n | S1 whole-position oracle comparison and shared-build/native interaction tests; hot queries have zero scan/build increments. S7 cold/hot/peak-memory results use the actual retained n; no universal performance claim is made. |
| R04 — same name versus same binding | PASS, functional | Identifier oracle preserves lexical matching; existing Rust/Python/TS local-reference/shadowing tests independently check binding boundaries. Native parameter/reference styling and occurrence tests remain in full CI. |
| R05 — prepared gutter data | PASS, work-count/native | S2 real draw/hover and 50k-line captures have zero stable-scroll preparation/global visits; first visual row, same-line fold priority, diff/bookmark/hidden-match cases are checked. S2 disabled-environment Release recheck passed all six fixtures under X04. |
| R06 — static fold relations | PASS, functional/work-count | S3 generated/equal/crossing/invalid interval comparisons; actual focus/sibling/ancestor UI paths; repeated queries do not rebuild topology. Exceptional compatibility input retains its explicitly reported O(F²) ceiling. |
| R07 — static call ownership | PASS, functional/work-count | Generated ownership oracle, closures/default parameters/methods/top-level cases, 0/512/513 limits, store/profile isolation, and repeated real Engine queries with zero region scans/rebuilds. Operator caller navigation proves host integration; Resolver evidence remains context-dependent. |
| R08 — dependency-based invalidation | PASS for tested paths; detailed boundaries below | S4 native settings matrix, font-then-color, mixed settings, validator replay, late providers, automatic appearance raster and syntax geometry reuse. Reading Set paint bypass/zero measurement checks passed in S6. Real same-name process font replacement is now proven under V06. Live process-language switching is not a product feature; V08 states its precise scope. |
| R09 — projection versus materialization/local updates | PASS, functional/work-count | S5a zero-decode plan construction; S5b small folds, multi-patch parity, bounded placeholder lookup, complete selection, preflight/barriers, explicit fallback. Sparse source materialization is measured; a giant single paragraph still has native paragraph/layout cost. |
| R10 — async result ownership | PASS, tested lifecycle scope | A→B→A/subscription/analysis identities, one-subscriber cancellation, old-syntax teardown, stale preflight rejection, Settings queued reopen/close and Context late observation tests. Analysis-only refresh is distinguished from content replacement. |
| R11 — full reading state through reflow | PASS within explicit high-cost limits | Existing native reflow cases plus the new L04/L09 integrated tests pass. Real detached syntax arrives while reading in the middle/end; two simultaneously visible 500/790pt windows share one identifier build and retain independent measured anchors and selections after font-environment refresh. High-cost precision remains explicitly limited. |
| R12 — bounded cache/task lifetime | PASS for cache/subscription and tested object ownership; extended resource observation deferred | Budgets/eviction/oversized active entries are tested. A weak-reference test proves Reader and ReaderDocument release even while an idle derived result remains cached; terminal tasks/observers are tested. This is stronger than an LRU count, but not proof that every native provider/process allocation returns to baseline across an extended same-process version-switch cycle. Keep cache bytes, retained objects and physical footprint distinct. |
| R13 — surfaces, compatibility and safety | PARTIAL | Six actual native surfaces, real historical/frozen workflow, non-source preview, language dispatch, Safe mode and bilingual checks passed. X01 VoiceOver operation remains outstanding; X04 disabled-runtime checks have now passed. |
| R14 — verifiable functional/work measurement | PARTIAL | Full completed test summaries and actual-site work counters exist; native artifacts include source identity and draw/copy evidence. The final report records actual 29/30-pair results and high-cost limits; the original full-release sampling gate is not claimed under the user-adjusted scope. |

## Projection P01–P12

| Cases | Status | What was actually proved |
| --- | --- | --- |
| P01 | PASS — pure model + work counter | Unfolded/empty source plans construct without full source decoding. |
| P02–P03 | PASS — differential model | Deterministic legal projections, visible/hidden/EOF mappings and all valid boundaries match the frozen old DisplayMap; invalid surrogate boundaries are rejected. Native glyph correctness has separate Reader tests. |
| P04 | PASS — source export + native clipboard | Placeholder/cross-placeholder copy uses original source-range concatenation. Native private pasteboards, hidden multi-selection, width changes and operator copy paths are covered. Default NSTextView's layout-inserted LF was correctly rejected as a source-byte oracle. An OS drag-to-another-application export was not separately exercised; it is **not an added X01 requirement**. |
| P05 | PASS — construction/materialization scope | Sparse collapsed-source test materializes only its two visible source bytes; no source-size projection String reserve remains. Whole-process peak memory is reported separately in the retained performance samples. |
| P06 | PASS — model and native rejection | Invalid identity/range/UTF boundary/unknown fold cases reject before partial mutation; native invalid-document tests preserve existing display. |
| P07 | PASS — native/counters | A middle small fold becomes one local replacement rather than a whole-source replacement; representative collapse events decode zero source bytes and update one placeholder/paragraph. |
| P08 | PASS — model and native | Multiple old-coordinate patches apply backwards and match full materialization, fonts and paragraph attributes. |
| P09 | PASS — actual Reader preflight seam | A prepared A intent cannot overwrite an actual B display or newer same-content analysis. Stale target rejection is distinct from recoverable current-target fallback. |
| P10 | PASS — native selection/keyboard/copy | All ranges, affinity, hidden endpoints, normalized shared placeholders, EOF and half-open fold-start endpoints are restored. Reverse single selection uses a bounded native command/public delegate; multi-range next-Shift behavior matches native reference. Primary symbol style follows its new display position. |
| P11 | PASS — tested joins/attributes | Unicode, emoji, combining marks, CRLF, tabs, cross-range styling and paragraph joins match the full-install reference. A giant paragraph may still require paragraph-sized work; no unconditional local native-layout speedup is claimed. |
| P12 | PASS — native failure/rollback | Forced/current-target fallback and disabled local replacement retain text/selection; invalid targets keep old content. Storage observers verify mapping/copy/validator suppression during partial, full, display and syntax commits. |

## Invalidation V01–V09

| Cases | Status | Evidence / boundary |
| --- | --- | --- |
| V01–V02 | PASS — native counters | Idempotent apply and stable scroll do no extra projection/character work; pure colors perform paint writes but no replacement/application full layout. Paint work has its own nonzero counter, not a fabricated zero. |
| V03–V04 | PASS — native matrix | Fonts/sizes/ligatures preserve characters; combined font/color/wrap uses the intended transaction. Existing source selection, attachment identity and copy regression passes. |
| V05 | PASS — native + differential | Same-content syntax with same canonical folds reuses projection; reordered arrays do not rebuild; changed fold bodies trigger a valid update/fallback. |
| V06 | PASS — actual process replacement + isolated distributed route | The historical missing distributed subscription is repaired. Actual process-scope A→B registration keeps the same PostScript name while Reader font URL/hmtx/advance change (6.5→11.7pt), with source, selection, native draw and copy preserved. A separate fresh-process test verifies distributed routing; it is not a real session/persistent installation claim. [Evidence](stage-s7-font-registration.json). |
| V07 | PASS — actual TextKit callback | Invalidated attributes are resubmitted even with cached range computations; plain text receives the current base foreground. |
| V08 | PASS for appearance and same-language summary updates; language-switch boundary explicit | Automatic light/dark raster/provider tests pass. `readonlyIntegratedLocalizedFoldSummaryUpdatesGeometryWithoutCharacters` changes a same-body summary: native chip width grows 132→244pt, source/projection stay unchanged, and the new provider draws with its localized AX label. The test host resolves English; the actual acceptance app uses Chinese. No live language-switch feature exists (Bundle localization is selected at process launch), and no runtime English↔Chinese same-summary geometry comparison is claimed. |
| V09 | PASS — native geometry | Gutter/line-number changes participate in effective width/wrap behavior; first-row and reflow tests use real TextKit rows. |

## Layout L01–L09

| Cases | Status | Evidence / boundary |
| --- | --- | --- |
| L01 | PASS — native anchor/selection | Width→font→width before queue drain, font/ligature/wrap round trips and actual row/source anchor checks passed. |
| L02 | PASS — native input and lifecycle | Actual wheel movement cancels old restoration; layout-originated bounds changes do not. Replacement documents, font environment and closing stop stale work. |
| L03 | PASS — native geometry | Soft-wrap continuations, first-row markers, EOF, empty rows and Unicode geometry checks passed. |
| L04 | PASS — new native integrated test | `readonlyIntegratedDeferredSyntaxKeepsMiddleAndEndSourceAnchors` first navigates a plain Reader to middle/end positions, then receives real detached DocumentLoader syntax. Source/selection/affinity/copy remain unchanged; independent row drift is <=2pt and actual drawing advances. The CLI syntax scenario alone was not used for this claim. |
| L05 | PASS — injected native branch; naturally absent case NOT_RUN where unavailable | Missing-old-viewport branch was directly exercised under optimized and legacy policy: zero versus one full extent enumeration as specified. The natural CLI case is NOT_RUN when TextKit creates a viewport; it is not relabeled as absence. |
| L06 | PASS — cost/limited-state behavior; precision LIMITED | Very long single-line input is classified before expensive caret capture; horizontal state and source selection remain. The reported roughly 14.5s/1.35GB S6 run is a real remaining cost, not a successful precision/latency budget. |
| L07 | PASS — actual unmounted→mounted surface | Genuine zero-size/unmounted surface preserves the pending transition and later reachable native extent; an invalid zeroed-attached-clip simulation was replaced rather than accepted. |
| L08 | PASS — Reading Set native tests | Outer card anchor and selection survive typography/wrap; pure colors change actual foreground without scheduling card layout or increasing measurement count. Closing cancels pending card layout and late scroll publication. |
| L09 | PASS — new native integrated test | `readonlyIntegratedTwoWindowFontEnvironmentKeepsIndependentAnchorsAndSelections` uses simultaneous 500/790pt windows, different font sizes/source positions and one shared store. Font-environment refresh keeps both independently measured anchors <=2pt and each selection/affinity/copy/source unchanged; the store retains one build and two subscribers. |

## Compatibility X01–X04 and rollback scope

| Cases | Status | Evidence / boundary |
| --- | --- | --- |
| X01 | PARTIAL — VoiceOver NOT_RUN | Actual native mouse drag-selection, word/keyboard selection, Shift direction, copy and TextKit 2 checks passed. AX roles/labels/getters and CUA accessibility inspection are present; **neither is actual VoiceOver navigation/speech/focus testing**. OS drag-export to another app is also unobserved, but the plan's X01 asks for mouse drag-selection, not that extra workflow. |
| X02 | PASS — actual workflow + regressions | Relation jumps, historical/worktree boundary, stale content, bookmarks, frozen Reading Set and normal process/session restore are covered by tests plus the real operator sequence. |
| X03 | PASS in recorded scope | Actual Safe-mode operator session, native non-source previews and Settings propagation plus 795-key localization checks. The CI fake Exact provider is not counted as real-provider evidence. Runtime locale attachment details remain the V08 boundary. |
| X04 | PASS | S1/S2 targeted disabled-policy tests plus fresh Release environment-flag runs on all six fixtures each passed; [retained records](stage-s7-rollback.json). S5/S6 explicit native Release flag runs passed. |

| Flag | Existing evidence | Remaining minimal runtime check |
| --- | --- | --- |
| `CAIRN_READONLY_IDENTIFIER_CACHE=0` | `readonlyIdentifierCacheRollbackKeepsResultsAndReleasesEachBuild`: functional asynchronous store test with two independent builds and zero remaining entries | PASS six fresh Release fixture processes; [records](stage-s7-rollback.json). It disables cache/coalescing, not prepared worker queries. |
| `CAIRN_READONLY_DECORATION_CACHE=0` | `readonlyGutterCacheRollbackPreservesMarkersAndCountsItsWork`: actual draw test, markers retained, preparation/global visits increase | PASS six fresh Release fixture processes; [records](stage-s7-rollback.json). Do not enforce optimized zero-work expectations on this deliberate fallback. |
| `CAIRN_READONLY_LOCAL_REPLACEMENT=0` | PASS `.build/readonly/s5b-fallback/`: eligible supplementary Python fixture SHA `88fa28e66459fe8482b0e66f304f1c5520e43d9d02560ad5afad133d68fffe42`; fold/unfold/overview/full each perform one full replacement | Do not confuse this with the default short Python fixture's ineligible folds. |
| `CAIRN_READONLY_REFLOW=0` | PASS six Release fixture captures in `.build/readonly/s6-fallback/`; injected missing-viewport optimized/legacy native test also passes | Matched measurements are reported at actual n; fallback correctness is not a speed claim. |

## Deferred checks under the user-adjusted scope

The user requested restrained testing for an early-stage project. Do not launch
more samples, repeat full CI, or build the prepared twenty-switch resource overlay
to close this document's remaining cells. Revisit them when a relevant change,
observed regression or release decision justifies the work.

- **VoiceOver:** actual navigation/speech/focus remains NOT_RUN, with OS-setting
  authorization pending. AX inspection is not a substitute.
- **Extended resources:** the prepared same-process twenty-switch observer was
  never built/run and is not evidence. Existing cache/cancellation/weak-reference
  checks prove their narrower scope; process peaks do not establish leak freedom.
- **Performance:** preserve all collected data, actual per-fixture n and supply
  conditions. Any incomplete final pair is retained outside paired statistics.
  The original 30-sample rule is not silently marked satisfied if n is smaller.
- **Locale:** live language switching is unsupported; English test-host summary
  geometry and Chinese operator workflow remain separate evidence.

S8/R15 is outside R01–R14 and the A/B release gate. Its corrected native probe has now been executed: [S8 decision](stage-s8.md). Adoption is deferred because 9/11 valid source-position geometries differ; no product integration or performance gain is claimed.

## Additional integrated native checks

`.build/readonly/s7-integrated-reflow.log` has a complete **3-test PASS** summary
(0.961s after build) for L04, L09 and summary geometry under V08. The targeted
English label was `Collapsed, hides 4 lines`; chip width changed 132→244pt.
A separate nonpersistent test-process experiment requested `zh-Hans`; Foundation's
preferred language changed, but the test host's bundle still resolved English.
That experiment (`s7-locale-zh.log`) is **not Chinese localization proof**, and the
unused override was removed. The existing Chinese packaged-app operator evidence
and bilingual resource checks remain separate. No system language was changed.

## Font registration review

The missing distributed CoreText subscription predates this work (`git blame`:
`3cd489f5`, 2026-09-22); it is a historical integration gap, not a new S4 regression.
`CTFontManager.h` explicitly routes process registrations through the local center
and session/persistent registrations through the distributed center. The minimal
S7 repair uses the existing handler for both. Real process-scope replacement and isolated distributed routing now pass;
measurement collection was paused outside any active native sample for these checks. The matched readonly CLI
exits through `runReadonlyWorkloadSelfTest` before any AppDelegate construction,
so its sealed S6 measurements do not exercise this host-only observer change.

An intermediate CI failed `wrapToggleClampsLegallyAtDocumentEdges` once; its
original numeric failure was not reconstructed. Full-context tracing identified
a test helper returning before native scroll completion. Correct sequencing then
exposed a separate reproducible viewport-query side effect. The helper now waits
for completion, the getter is pure, and explicit restore owns required layout.
Six targeted and all 233 ReaderCore tests passed before full CI.
[Evidence](stage-s7-scroll-query.json) retains failures and traces.

The later scheduling repair adds three regressions for worker start before
MainActor yields, already-cancelled subscription, and a dropped Reader's unpublished
token. Complete final CI is **1,138/1,138 PASS**, with native self-tests and
architecture gates: [verified record](stage-s7-ci.json). Final packaged session
restoration and six cache-disabled native fixtures also pass. Actual sample counts are retained in the performance report; VoiceOver and
extended resource checks are explicitly deferred under the user-adjusted scope.
