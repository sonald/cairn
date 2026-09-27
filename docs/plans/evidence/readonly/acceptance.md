# Readonly implementation acceptance

Status: **S0–S8 development work complete at the user-adjusted testing scope; final stage commits being recorded**.
This is not a release approval. No remote push or distribution has been performed.

| Stage | Commit | Evidence |
| --- | --- | --- |
| S0 | `4fdabe3` | [Baseline and oracles](stage-s0.md) |
| S1 | `cec8838` | [Prepared identifiers](stage-s1.md) |
| S2 | `7757527` | [Prepared gutter data](stage-s2.md) |
| S3 | `fd6401e` | [Fold and call ownership](stage-s3.md) |
| S4 | `26e0f7b` | [Paint and typography](stage-s4.md) |
| S5a | `0cec95d` | [Pure projection](stage-s5a.md) |
| S5b | `92a46af` | [Local projection commits](stage-s5b.md) |
| S6 | `2c1bd48` | [Reflow and lifecycle](stage-s6.md) |
| S7 | pending | [Integrated evidence](stage-s7.md), [requirement matrix](stage-s7-requirements.md) |
| S8 | commit pending | [Completed prototype decision](stage-s8.md); adoption deferred |

Current frozen measurement candidate: `a99f10b2ec09c27c2610f3a651a638c070075470`
(r5), based on S6 plus the S7 font-notification, viewport-query and subscription
scheduling repairs. Baseline: `4fdabe38eb364f9e9d7aa6507aa445fb636ad485`.
Controlled observation overlays, source/binary/resource hashes and raw samples
remain separate from product code. Superseded r3 partial data and complete r4
cold-tail results are retained separately. No measurement generations are mixed.
R5 uses the qualified AC subset: Rust/long-line each 29 pairs, the other four
fixtures each 30. Further sampling was stopped at the user’s request; see the
exact population rule in [S7](stage-s7.md).

Completed integrated checks: 1,138 tests, 795 bilingual keys, architecture/native
self-tests, six native reading surfaces, actual historical/frozen navigation and
normal process restart, and all four rollback branches. The additional reflow/summary scenarios passed in the full CI. Actual VoiceOver
operation and extended same-process resource observation remain NOT_RUN. The user
requested restrained early-stage testing; these are deferred release checks, not
claimed passes or reasons to expand this delivery’s test campaign. The S8 investigation
is complete with adoption deferred because geometry differs. Full details and precise limits belong
to the linked records rather than inferred PASS labels here.

Known limits: exceptional overlapping fold topology retains a counted quadratic
fallback; large source paragraphs retain native TextKit shaping/backing costs;
high-cost reflow explicitly limits source/pixel precision. Timing budgets have not
been calibrated. Earlier diagnostic single samples are not S7 performance results.
