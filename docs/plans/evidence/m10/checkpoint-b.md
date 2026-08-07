# M10 Checkpoint B 验收证据（进行中）

日期：2026-08-07。范围：E1b / E1b0 / E1c / E1d / N2。

## E1b：definition case-specific

- `ExactDefinitionQueryResult` 明分 `completed([ExactTarget])`、`cancelled`、`unavailable`；`.completed([])` 不再与失败混同。
- rust-analyzer definition array 保留全部目标；Coordinator 为每个目标附 attribution/origin；stale generation 直接丢弃。
- `rustAnalyzerPreservesEveryDefinitionTarget`、Coordinator cancelled/unavailable/restart 用例与 Context 多候选升级用例 PASS。

## E1b0：ExactAnalysisEnvironment

`ExactCoverage` 已删除；`ExactAttribution.environment` 是 attribution 内唯一 trust source。Session observer、Coordinator、Relations、Context、CLI、status bar 与 fake provider 均直接传递 `ExactAnalysisEnvironment`，limitation 输出按 `rawValue` 排序。

### 迁移清单

| 位置/断言 | 旧 | 新 | 原因 |
|---|---|---|---|
| Relations 空结果状态 | `Verified incomplete: partial coverage` | `Analysis limited: build scripts disabled; proc macros disabled` | Safe 限制不是结果否定，且不再压成单一 coverage 等级 |
| Relations offline 状态 | `Verified unavailable: deps unavailable (offline)` | `Analysis limited: dependencies unavailable offline` | offline 是分析环境限制，不否定 provider 已返回的正向目标 |
| Exact status bar / tooltip | `coverage` + `full/partial/offline` | trust + 排序后的具体 limitations | Trusted+offline 与 Safe+offline 可同时如实表达 |
| Context provenance badge | `coverage: partial` | `limitations: build scripts disabled; proc macros disabled` | 显示实际限制，不显示派生等级 |
| CLI attribution | `coverage=<rawValue>` | `limitations=<sorted raw values>` | 保留稳定机器可读输出，同时去掉双真值 |
| `exactCoordinatorRefreshesCoverageWithoutAQuery` | observer 发布 `ExactCoverage` | `exactCoordinatorRefreshesEnvironmentWithoutAQuery` 发布完整 environment | trust 与 limitations 原子更新 |
| `relationTreeExactZeroCopyDistinguishesCoverage` | full/partial/offline 三等级 | 无限制 / Safe 两限制 / offline limitation | 测正交 limitation，而非旧枚举 |
| rust-analyzer diagnostic 测试 | coverage 降级 | 在原 environment 上加入 offline limitation | 保留原 trust 与既有限制 |

### 门禁结果

- Trusted+offline：`explicitOfflineDependencyFailureAddsLimitation` 断言 `.trusted` 与 `dependenciesUnavailableOffline` 同时存在。
- Safe+offline：同一测试断言 `.safe`、build scripts、proc macros、offline 三个事实同时存在。
- 用户文案：`relationTreeExactZeroCopyDistinguishesLimitations` 覆盖无限制、Safe、offline 三种状态；App self-test 同步相同合同。
- `swift test --disable-sandbox`：418/418 PASS。
- `CODEX_SANDBOX=1 bash scripts/run-self-tests.sh ...`：12/12 PASS；exact 通道包含三种 limitation 空结果文案。真实 rust-analyzer 仍受宿主 `sandbox-exec: sandbox_apply: Operation not permitted` 限制，按 BLOCKED 记载，不以 fake 结果替代。

## 尚待本 Checkpoint 完成

- [ ] E1c call-site reconciliation 与 conflict 修复。
- [ ] E1d 完整 trace 投影与 `alsoHeuristic` 删除。
- [ ] N2 Trail DAG、Explanation Store 与 worktree best-effort replay。
