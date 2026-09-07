# S2b — Context 与 Exact 不混合不同内容：逐片记录

## RED（2026-09-07）

4 个新回归（`ExactCoordinatorTests.swift`，复用 `ContextExactGate` 延迟回复 + `ProjectIndexer` 真实索引），失败点即内容混合：

- `contextExactUpgradeSuspendsWhenTargetContentDriftsBehindTheIndex`：provider 往返期间目标文件在磁盘漂移，回复仍把候选升级为 `.exact` / 徽标含 "Exact"，无陈旧上报。
- `contextExactInsertRequiresMatchingTargetBytes`：Exact 指向 fuzzy 列表之外的漂移目标，仍以「索引行号 + 磁盘新字节 excerpt」的混合形态插入候选（RED 时 count 1→2）。
- `contextExactUpgradeSuspendsWhenSourceFileDrifts`：仅查询源文件漂移时升级照样发生。
- `contextFuzzyCandidatesDoNotMixExcerptsFromDriftedBytes`：索引后目标漂移的首次查找，excerpt 混入磁盘新字节。

## 实现（`ContextWindowModel.swift` + `AppModel.swift` 接线）

1. `document(path:contentID:)`：加载后核对 `loaded.contentID == contentID`，不匹配不返回也不缓存——任何身份请求都不再拿到另一身份的字节。
2. `applyExact` 增加源/目标新鲜核对 `indexContentIsCurrent`：绕开 excerpt 缓存重读（worktree 读盘、commit 走 snapshot——按构造恒一致；依赖路径由其加载文档自洽，不经此路径）。profile/snapshot/generation 一致不再被视为字节相同。await 之后重查 requestID/generation/snapshot/profile/stage。
3. 失配时：保留既有 fuzzy 候选（索引一致），不升级、不插入、不伪标 Exact；经 `onStaleIndexContent` 上报，AppModel 置 `staleIndexNotice`（复用 S2a 的 `File changed since indexing` 状态栏面；observation 追踪该属性）。
4. provider 字节来源核实：didOpen 使用 `snapshot.readBytes`（RustAnalyzerProvider:1043），Exact 偏移与 manifest 身份同源，漂移只可能发生在快照 vs 磁盘——正是上述核对覆盖的差异。

## GREEN

- 4 新测试全绿；既有 `contextExactUpgradeKeepsEveryFuzzyCandidateAndSelectsExact`、`pythonContextExactBadgeOmitsCargoFeatureDetail`（含 Pin 升级、materialized origin、Safe 限制徽标）不倒退。
- `ExactCoordinatorTests|AppModelTests|SnapshotSwitchTests|SessionRestoreTests`：323 通过。
- `RelationNavigationTests|MainWindowControllerTests|NonSourcePreviewTests`（含隔离跳过）：59 通过。
- `scripts/ci.sh` 计数 860→864。

## 验收对照（计划 §5 S2b）

- 目标变（升级/插入两路径）、源变、延迟升级不串线；不伪标 Verified/Exact。✅
- 版本切换/provider 重启：既有 generation/snapshot/profile 守卫测试维持（全量 323+59 通过）。✅
- Pin 不被后台旧回复覆盖：既有 requestID + pinned 仅原地升级选中项测试维持。✅
- Safe/离线/candidate/verified/conflict 语义不降级：既有徽标/限制断言维持。✅
- 依赖（dependency）路径身份：materialized 依赖内容不可变且候选自洽，未列 S2b RED；如后续实测需要再补。

## 已知边界

- 陈旧上报当前经 `staleIndexNotice` 单值呈现（与 S2a 同面）；`Refresh Index` 操作在 S2c 落地。
- Relations 面板的 Exact 合并不在本切片文件清单内（其行为受 S2a 导航验证约束），如 G0 前半检查发现实测串线再单列。
