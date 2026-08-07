# M10 Checkpoint B 验收证据

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

## E1c：call-site reconciliation

- definition 验证按 `SourceLocation` 分组；同一 call site 的多个 candidate 只发一次请求。
- `compare` 只在同 semantic identity 或 canonical location 完全相同时给 `.same`；只有两边都归一为明确且不同的 `SymbolOccurrenceID` 才给 `.different`；其余均为 `.notComparable`。
- `.completed([])` 为中性 not-corroborated；非空结果逐 candidate 生成 corroborated / corrected / inconclusive，provider 目标逐 identity 去重显示。
- 每次 reconciliation 写入 `RelationQueryContext`；provider 主行持全部 reconciliation refs，corrected 行保留原目标位置并进入单一 `Show corrected candidates (N)` disclosure。
- Possible 与 corrected 最多两个同层 disclosure；批量验证重建组时复用 Node/group 身份，展开与 viewport 验证可继续。

门禁：

- `relationTargetComparisonIsConservative`：same / different / notComparable 三分 PASS。
- `relationTreeReconcilesOneDefinitionPerCallSiteWithThreeWayRoles`：A=same、B=different、C=notComparable；一次请求、一个 provider 主行、一个 corrected、C 继续 Inferred，主行 refs 完整。
- `relationTreeEmptyDefinitionIsNeutralForEveryCandidate`：空结果不生成 conflict/corrected，所有 candidate 继续 Inferred。
- `relationTreeShowsEveryDistinctProviderTargetForAConflict`：重复 provider location 去重；全部不匹配目标仍完整显示，candidate 折入 corrected。
- AppKit `relationCorrectedCandidatesUseTheirOwnWarningDisclosure`：warning 色 corrected disclosure 显 `Show corrected candidates` + 独立计数，不冒充 Possible。
- viewport 迁移：验证后的 Verified 行离开 Possible 组，因此旧测试“Possible 永远保持 64 行”改为“首批后剩 32 行，滚动剩余组后请求总数 64”；节点身份、批量上限与展开状态未弱化。
- `swift test --disable-sandbox`：423/423 PASS。
- `CODEX_SANDBOX=1 bash scripts/run-self-tests.sh ...`：12/12 PASS。

## E1d：完整 trace 投影与旧状态保留

- 每个 Relations expansion 建立一个 `RelationQueryContext`；Engine/Exact 并发到达分别更新 `pending / completed / failed`，Exact-first 发布时不会把尚未到达的 candidate 误判成空结果。
- `mergeExact` 现在完整投影三态：fuzzy-only 保留 `candidateOnly` 与 Inferred，exact-only 保留 `verificationOnly` 与 Verified，重合行持 `corroborated(candidate, verification)`。
- relation query 结果直接携带完整 `ExactAttribution`，因此 verification trace 不再从 environment 反推或伪造 provider 信息；RA call hierarchy 的查询穷尽性明确记录为 `.bestEffort`。
- callers/calls/implementations/references 的候选观察均携带原 certainty、dispatch、provenance、completeness、evidence；未解析 call 与文本 reference 使用已有 `UnresolvedSymbolRef`，未增加并行 endpoint 类型。
- `LoadedEdge.alsoHeuristic` 已删除；原 `heuristic also matched` UI/AX 文案只从 `.corroborated` 派生。

门禁：

- `relationTreeReferenceMergeKeepsAllThreeEvidenceCases`：三态 trace、升级前 observation、查询级 completed facts 全部断言 PASS。
- `relationTreeFreezesExactFirstRowOrderWhenHeuristicArrives`：Exact-first 时 candidate=`pending`、exact=`completed`、行=`verificationOnly`；Engine 到达后原位升级为 `corroborated`，fuzzy-only 保持 `candidateOnly`。
- `rg alsoHeuristic Sources Tests`：零命中；既有 UI/AX 文案断言继续 PASS。
- RelationTree 定向测试：52/52 PASS；`swift test --disable-sandbox`：423/423 PASS。
- `CODEX_SANDBOX=1 bash scripts/run-self-tests.sh ...`：12/12 PASS，artifact `.build/self-test-run-20260807-105533-48304`。

## N2：Trail DAG、Explanation Store 与 worktree replay

- `NavigationHistory` 的单一存储改为 `NavigationRecord(jump, trailNodeID)`，兼容读视图仍投影为原 `JumpRecord`；Back/Forward 按 `trailNodeID` 恢复具体访问节点，同位置的不同访问路径不再混同。
- `ReadingTrail` 只记录 `NavigationPolicy.recordInTrail` 的显式语义导航；Back 后新跳转保留旧边并从恢复节点生成新分支。节点直接持 `JumpRecord.snapshotID`，跨 snapshot 路径自然分段，不引入伪稳定 symbol ID。
- `TrailEdge` 固定保存导航时物化快照与 `currentExplanationID`；`ResolutionExplanationStore` 只存 `MaterializedResolutionExplanation`。Exact 原位更新复用行上的同一 ID，路径快照不变、当前解释可更新。
- Relations 行首次导航时先物化 live context/ref；换根、snapshot/profile 切换仅保留 Trail 引用的解释，未引用解释清理；新项目全清。Store 内没有 live `RelationQueryContextID` / `ReconciliationRef`。
- 旧 worktree snapshot 无法精确重建时，在当前 worktree 上按 `JumpRecord` 弱锚点重放；AppModel 发布并在状态栏显示 `replayed against current worktree`。若 snapshot ID 仍存活并匹配，则不显示该提示。
- 未增加磁盘持久化、非文件 tab 或 Reading Set 产品实体。

门禁：

- `readingTrailBranchesFromRestoredHistoryIdentity`：A→B、Back 到 A、A→C 形成保留双边的 DAG；history record 恢复 A 的节点身份。
- `trailExplanationSnapshotStaysFixedWhileStoreAdvances`：edge 快照保持 Possible，Store 同 ID 更新到 Strong。
- `relationRootResetRetainsTrailMaterializationsWithoutLiveReferences`：旧 query context 清除后 candidate-only 与内联 reconciliation 的 conflict 均可从 Store 读取。
- `oldWorktreeReplayUsesCurrentWorktreeAndSaysSo`：重捕获 worktree 得到新 snapshot ID，弱锚点恢复位置、Trail 身份，并发布明确提示。
- AppKit `relationReferenceDoubleClickDoesNotNavigateTwiceAndHistoryReturns`：真实 Relations 单击把物化 explanation ID 同时写入 NavigationRequest、Trail edge 与 Store；双击去重和 Back 行为不变。
- AppModel/Snapshot/RelationUX 定向回归：178/178 PASS；`swift test --disable-sandbox`：427/427 PASS。
- `CODEX_SANDBOX=1 bash scripts/run-self-tests.sh ...`：12/12 PASS，artifact `.build/self-test-run-20260807-111207-90422`。

### 2026-08-07 Trail UI 纠错闭环

此前本 Checkpoint 只验了 Trail 模型和 replay，却将 N2 记为 PASS；这不满足原型决策 D4/D5 的“常驻顶部条 +
浮层 DAG”，该旧结论作废。纠正实现没有新增第二状态源：`ReadingTrailView` 直接投影 AppModel 的
`ReadingTrail` / `ResolutionExplanationStore`，恢复继续调用既有 replay 管线。

- 顶部 32pt 路径条在无项目时也可见；active path 的边显示 cause，`⑂` 显分支数并由 `⌥⌘T` / View 菜单唤起。
- 浮层左侧为 git-log 式 DAG，复用 Relations 的 Verified / Inferred / Unresolved 与 snapshot chip；右侧显示
  `NAVIGATED VIA`、`AT NAVIGATION`、`CURRENT` 和 `Restore this node`。
- `semanticTrailKeepsBranchesVisibleAndRestorable` 固化 A→B、Back、A→C、选择 B、恢复 B 且边数不变；
  `semanticTrailShowsSnapshotBoundaryAndNavigationCause` 固化 snapshot boundary、commit chip 与 search cause。
- `relationReferenceDoubleClickDoesNotNavigateTwiceAndHistoryReturns` 追加常驻条几何 / AX、浮层内容与 Inspector
  可发现入口检查；模型测试同时锁定 edge cause 与 `.historyReplay` 恢复不增边。
- 三主题证据：`semantic-trail-light.png`、`semantic-trail-dark.png`、`semantic-trail-si-classic.png`；真实 tokio
  证据：`semantic-trail-live-tokio.png`。
- 最终：435/435 tests PASS；独立 self-test 12/12 PASS（`.build/self-test-run-20260807-144721-57949`）；
  stress 5/5、0 failure / hang / error（`.build/stress-test-20260807-143314-41932`）。

## 尚待本 Checkpoint 完成

- [x] E1c call-site reconciliation 与 conflict 修复。
- [x] E1d 完整 trace 投影与 `alsoHeuristic` 删除。
- [x] N2 Trail DAG、Explanation Store 与 worktree best-effort replay。
