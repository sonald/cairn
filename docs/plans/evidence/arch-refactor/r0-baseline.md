# R0 — 基线与特征测试盘点

计划：[面向后续阅读功能的架构重构方案](../../2026-09-28-architecture-refactor-plan.md)
日期：2026-09-28
结论：**R0 完成，可以开始 R1。**

## R0.1 基线

| 项 | 值 |
|---|---|
| HEAD | `508cf09`（分支 `claude/cairn-innovation-architecture-2d6bf5`） |
| 工具链 | Apple Swift 6.4（swiftlang-6.4.0.34.1），Xcode 27.0（27A266a），macOS 27.0（26A428），arm64 |
| libgit2 | `CAIRN_LIBGIT2=brew` |
| CI 主批次计数 | `expected_main_test_count=1171`；合计 1178（主 1171 + 书签 2 + 面板 2 + 鼠标 1 + 字体 2） |

**完整 CI 引用而不重跑**：UI 重设计阶段 4 在 `418b737` 跑过完整 CI，主批次 1171 条全部报告完成，合计 1178 条，
折叠性能门禁 pass（[phase 4 计划](../../2026-09-28-ui-redesign-phase4-plan.md) 第 64 行）。
`git diff --stat 418b737 HEAD -- Sources Tests scripts Package.swift Package.resolved fixtures goldset` 为空：
之后的 `8f0b079`、`f3d932a`、`508cf09` 只改动 `docs/` 与 `site/`。按 AGENTS.md，没有代码变化不重复跑完整 CI。

## R0.2 特征测试盘点

「已有」列为现有测试中覆盖该切片可观察行为的用例；「缺口」为重构前必须先补的特征测试或 oracle。

| 切片 | 已有 | 缺口（在对应切片开头先补） |
|---|---|---|
| R1a/R1b | `ExactCoordinatorTests`：`contextExactUpgradeSuspendsWhenTargetContentDriftsBehindTheIndex`、`contextExactInsertRequiresMatchingTargetBytes`、`contextExactUpgradeSuspendsWhenSourceFileDrifts` | 三个选择交错红测；校验阶段解析计数为 0 |
| R1c | `SnapshotSwitchTests`、mixed 相关 `AppModelTests` | 无（一行对称修复） |
| R1d | `ReaderCoreTests` 中 4 处 `loadSyntax(for:completion:)` 用例 | 取消前/取消中两条 |
| R2 | `PaletteTests.paletteSymbolRowsCarryVisibleKindTagsColoredByFamily`（部分 KindTag）；`DiffCoreTests` 的 TS/Python 点分隔与 Rust `::`（`:341`）命名 | **穷举** `DeclarationKind`/`OutlineKind` → 旧 Palette 标签/family、旧 `isFunction` 的 oracle 测试 |
| R3 | `ExactCoordinatorTests:2269`、`RelationTreeModelTests:3033`（仅 Exact 依赖标签 `External · in dependency`）；`AppModelTests:2879`（仅 `contains("strong")`） | **fuzzy 标签 `certainty·dispatch` 格式未被固定**：先补 certainty × dispatch 组合的逐字标签特征测试 |
| R4 | `ReaderUITests`：`readingHeightLevelsUseTheSpecifiedKindsAndSkipSmallRegions`、`manualFoldsArbitrateInBothDirectionsAndLevelSwitchClearsEveryPair`、`navigationUnfoldsManualAndBaselineAncestorsWithoutCrossingDirections`、`focusSelectsTheSmallestFacetAtItsHeaderAndClosingBrace`、`focusIsIndependentAndEscapeRestoresHeightAndOverridesExactly`、`focusTreatsCfgTestAsAContainerAndNoScopeDoesNotFold`、`focusFollowsExplicitCrossFileNavigationButNotLiveScroll`、`focusUsesTheExplicitLandingPointAfterDeferredSyntaxLoads`、`foldReducerRendersOnlyMaximalRegionsAndScopesOverridesByFileAndContent`、`optionFoldHandleRecursivelyTogglesSiblingRegions`；已有测试 oracle `ReadonlyStructuralOracle.swift` | ReaderCore 层纯函数 oracle（三档高度 × 焦点位置 × 覆盖规则，含 `fold_perf.rs`） |
| R5 | `ReaderUITests`：`occurrenceHighlightsPreserveDifferentSyntaxForegroundColors`、`semanticLocalAndParamReferencesUseDistinctViewportStyles`、`defaultVisualSettingsRenderRestrainedDeclarationsAndParameterRoles`、`m6ReferenceDensityStylesOnlyViewportFragments`、`clickingIdentifiersReplacesOccurrencesAndTracksOneCurrentLine`；`ReaderInvalidationTests` 8 条（含 `readonlyInvalidationNativeSettingsMatrixNeverReplacesCharacters`、`readonlyInvalidationPlainTextAndValidatorRepublishCachedColors`） | 旧合成逻辑作为 oracle 的逐 run 等价测试 |
| R6 | `OutlinePanelModelTests.outlinePanelSortsLocatesInnermostAndOpensRows`（1 条）；`MainWindowControllerTests.productPolishOutlineUsesNativeHierarchyAndPreservesCollapsedBranches`（CI 独立批次） | 模型层补：跟随高亮落到可见祖先、跨文件切换后折叠状态恢复 |
| R7 | `SessionRestoreTests`：`sessionLoadProblemsAreClassifiedAndPreserveOrQuarantineData`、`midRestoreCheckpointWriteLeavesLastValidSnapshotIntact`、`sessionCheckpointWriteFailureSurfacesNoticeAndSuccessClearsIt`、`continuouslyRescheduledCheckpointCommitsWithinDirtyDeadline`、`legacyV1SessionMigratesToPerProjectStoreOnce`、`clearingTheCurrentProjectSessionDropsStateAndWritesEmptySnapshot`、`sessionOfflineLegacySurvivesOtherProjectAndMigratesOnReturn`、`sessionUnreadableLegacyCannotBeShadowedByFreshCheckpoint`（含 future schema）；`SessionCodecTests.sessionCodecRoundTripsCanonicalLanguageArrayWithSortedKeys` | 计划中的三条保护规则（新版本不可覆盖、恢复未完成不可写、损坏隔离）**均已有覆盖，不新增**；补一条固定输入的会话文件逐字节特征测试 |

盘点带来的计划调整：R2 不改 CLI `:413`（无测试覆盖，`calls` 只索引 Rust），已写回计划。

## R0.3 自测与性能基线

输出保存在 `.build/arch-refactor/`（不提交），关键结果摘录如下。

| 检查 | 命令 | 结果 |
|---|---|---|
| fold 自测 | `.build/debug/codeinsight-app --self-test-fold` | `passed:true`，15 项布尔检查全部为 true |
| reading 自测 | `CODEINSIGHT_INDEX_CACHE_ROOT=<临时目录> .build/debug/codeinsight-app --self-test-reading` | `passed:true`；`styledFragmentCount=29`、`referenceStyledFragmentCount=90`、`referenceAttributeRunCount=175`、`referenceScannedCount=105`、`visibleLineCount=30` |
| projector 自测 | `.build/debug/codeinsight-app --self-test-projector` | `passed:true`，10 项检查全部为 true |
| fold 性能门禁 | `provision-corpora.sh --verify-fold-fixture` → `swift build -c release --product codeinsight-app`（83 s）→ `run-fold-perf.sh`（与 `scripts/ci.sh:173–181` 相同参数） | `status: pass`，`budgetStatus: pass`；`acceptedFoldCount=8400`、`candidateCount=8400`、`logicalFoldCount=4400`、`renderedFoldCount=200`；`resolutionMs=28.2`、`foldLatencyMs=49.8`、`peakPhysBytes=116,704,192`、`deltaBytes=21,151,768`；单次样本 |

fold 性能门禁的输出里 `budgetsEnforced: false`：脚本在本机记录预算状态，但不据此让门禁失败。此处如实记录，本轮不修改该行为。
产物目录为 `.build/m11-fold-perf`。

R4、R5 完成后用同样的命令对比：

- 布尔检查必须全部保持为 true。
- reading 自测中与样式相关的计数（`styledFragmentCount`、`referenceStyledFragmentCount`、`referenceAttributeRunCount`、
  `referenceScannedCount`）必须相等。
- fold 性能门禁的四个 `observed` 计数必须相等，`status` 保持 pass。
- 耗时和内存类字段只作参考，不作为等价判据；明显退化（例如 `foldLatencyMs` 翻倍）时再补样本判断。
