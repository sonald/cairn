## 日常使用：少量、相关、够用即止

未来默认 `--samples 3 --max-pairs 3`，允许 `--samples 1`。日常开发只选择与改动直接相关的场景，用少量样本检查行为和工作量；通过后停止，不自动扩大矩阵或重复运行。30组属于**明确请求时**才运行的发布级选项（显式传 `--samples 30 --max-pairs 30` 或经说明的补样上限），不是早期提交前置条件。只有非supplemental且samples≥30，`standaloneAcceptanceEligible`才可能为true；该字段也不替代功能/环境验收。

本轮按用户要求停止，实际AC完整配对Rust/长行各29，其余各30；不再补齐。已执行旧driver的快照与哈希保留在各artifact的protocol目录，以下历史协议按当时执行配置理解，不能用未来默认改写历史。

# Matched native readonly measurement (s7-v2)

This is an optional overlay on the existing readonly native workload, not product
behavior. Use separate clean worktrees at exact baseline/candidate commits. The
installer rejects staged, unstaged and untracked inputs. It changes only the
Reader observation hook and the existing self-test entry point.

For each worktree:

1. Preserve its original Release executable.
2. `python3 scripts/readonly-matched/install_harness.py install --root ROOT --expected-sha SHA --receipt RECEIPT`
3. Build `codeinsight-app` in Release with the same Swift/SDK/libgit2 configuration.
4. `python3 scripts/readonly-matched/install_harness.py seal --root ROOT --receipt RECEIPT --binary BINARY`
5. Preserve the sealed executable, sibling resource bundles, receipt and build log.
6. `python3 scripts/readonly-matched/install_harness.py restore --root ROOT --receipt RECEIPT`

Run the installer from this checkout against the separate ROOT. Receipts/backups
belong in an ignored `.build` directory. Restore refuses to overwrite unexpected
edits. Sealing binds the binary/resource hashes to the controlled source overlay;
the app reports an embedded source SHA, not only a command-line label.

`run_matched.py --help` lists the binary/receipt/manifest/output arguments. Use
`--scenario all --samples 30 --max-pairs 45` for the fixed sequence. It alternates
AB/BA pairs, includes all six frozen inputs, retains raw exceptions/timeouts and
reports per-metric n/p50/nearest-rank-p95/max. Do not overlap builds or other native
benchmarks, or interact with measurement windows. These are fresh-process cold
samples; OS file/font caches are not flushed.

The measured window uses an explicit Aqua appearance and starts with the light
Reader theme; this changes no system/user preference and avoids automatic day/night
appearance changes invalidating a long collection. Appearance is recorded.

The sequence is cold display, identifier warm-up/hot interaction, scrolling,
fold/unfold, color, font, then combined color/font/wrap. A recorded setup outside
measurement clears occurrences and installs the same downstream caret before
projection/reflow. Correct full-selection preservation is tested separately.

The first native draw marker is a drawBackground callback, not compositor delivery.
Operation-only, operation plus synchronous drawing, and stable viewport latency
are separate. Both versions pump native turns and require matching content,
settings, fragment font attributes, selection, actual draw and no pending reflow.
Stable viewport geometry must repeat; elapsed time alone is never sufficient.
Cold display expects the initial zero-length caret at offset zero; a transient
pre-layout native selection is recorded separately and is not treated as intent.
Both receive the same 100ms post-readiness memory observation, excluded from
latency. Physical-footprint samples and their peak remain raw evidence.

One independent source-byte/row-offset target spans uninterrupted reflow updates.
Every readiness observation measures its actual laid-out row and legal-clamped
error. LAST production diagnostics cannot establish readiness. Only the same
known >8,000-line or >64 KiB source-paragraph policy can make exact anchor latency
NOT_RUN; content/draw/geometry convergence must still pass. Other missing or
misplaced targets remain failures. Empty/short-fold fixtures explicitly report
inapplicable folding instead of measuring a no-op.

Operation/draw and supported stable metrics each require 30 valid observations.
Deterministic stable failure is retained as FAIL after the other metrics reach
30; it does not trigger futile additional pairs or become a pass. Collection
completion is separate from validity. Cold p95 regressions require written review;
a capture alone is not release approval. Native host/whole-workflow acceptance,
source correctness, CI and lifecycle proofs remain separate.

### Explicit cold caret setup (r3)

The cold measured closure now sets caret `[0, 0]` with downstream affinity immediately after `reader.display`. Both standalone readers were observed returning an initial EOF caret; S0 later normalized it during native reflow while S6 retained it. Treating an assumed zero caret as intent made the earlier harness incomparable. The explicit setup models the host's initial caret action, is charged to cold operation time, and is recorded as `coldProtocolSetup`. Other phases continue to record actual post-operation selection. Preserve r1/r2 artifacts as protocol-development failures; do not merge them into r3 statistics.

### r5 power-qualified primary cohort

The original r5 collector recorded Battery Power at 21:10:37 +0800, then the power history first recorded AC at 21:34:36, during the candidate process in long-line pair007. The original thirty pairs remain intact as mixed-power evidence. Do not describe them as thirty fixed-AC pairs.

The primary inclusion rule was proposed before pair018 and approved afterward, independent of measured latency: retain common original pairs008–029 only after validating subsequent power history, and collect eight new complete pairs in a separate directory using the same sealed binaries and unchanged app protocol. Preserve original000–007 separately, including the crossed-power pair007. `ac-inclusion-rule.json` records the proposal/approval and journal boundary.

The collector's supplementary mode is explicit:

```text
--supplemental --samples 8 --pair-start 30 --require-ac-power
```

This is a short supplemental collection, never standalone thirty-sample acceptance. Each process receives read-only `pmset -g batt` snapshots before/after; if any endpoint is not AC, neither side of that pair enters AC statistics and both raw outputs remain. A non-AC preflight blocks launching another native process, retaining prior output. Qualified pair counts, not favorable timings, determine any additional collection. Final power-history review also checks for an intermediate transition; start/end AC alone is not proof that power never changed inside a long process.

The running original r5 process uses its already-loaded collector code, saved under its artifact `protocol/` directory before adding these options. `addon.swift`, `readiness.swift`, `install_harness.py`, the fixture bytes and both sealed binaries are unchanged. The new driver records its separate short-run scope and process power observations. No original raw sample is deleted or relabelled.
