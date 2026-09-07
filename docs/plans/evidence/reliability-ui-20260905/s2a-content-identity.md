# S2a — 拦截内容不匹配的语义导航：逐片记录

## RED（2026-09-07，当前源码）

新增 5 个 AppModel 级回归测试先于实现运行，按审查复现（`target` 改名 + 前插 8 行注释）构造陈旧索引场景，失败点与审查一致：

- `semanticNavigationVerifiesContentIdentityBeforeCommitting`：陈旧跳转被放行（opened+1）、写入 history（+1）、延伸 Trail（+1）、无任何提示。
- `semanticNavigationChecksDisplayedDocumentWithoutRereading`：已显示文档与索引不一致时跳转仍被放行。
- `semanticNavigationRejectsDeletedInvalidUTF8AndOutOfRangeTargets`：越界 offset、非法 UTF-8、目标删除三类全部放行且无反馈。
- `semanticValidationCannotPublishAfterNewerNavigationOrProjectSwitch`：新导航/切项目后旧验证（此时为直接放行）仍发布旧目标。

## 实现

- `SourceDestination` 增加 `expectedContentID`（D1 允许的既有实体最小扩展；消费者为共享导航入口）。
- `AppModel.navigate` 拆出 `commitNavigation`；带 offset 且带身份的请求先验证后提交：
  - 快路径：目标是当前显示文档时直接比对 `activeDocument.contentID` 与 offset 有效性（无 I/O）。
  - 慢路径：后台读目标内容（worktree 读盘、commit 走 `documentSource`）哈希比对，按 workspace generation + `navigationGeneration` 双守卫发布；新导航/切项目使旧验证任务失效（`semanticValidationTask` 可取消）。
  - 拒绝时：不移动视口、不写 history/Trail、不污染当前 tab，设置 `staleIndexNotice = "File changed since indexing"`（状态栏渲染）；成功提交时清除。
- `semanticDestinationMatches`（nonisolated static）：与 Reader 相同的身份计算（sha256 原始字节）+ UTF-8 有效性 + offset 可解析。
- 索引位置生产者全部供身份、当前文档生产者保持 nil（D1：由 producer 声明，不按 cause 猜测）：
  - 搜索面板（`SearchPanelModel.Group.contentID` ← manifest）与 Palette 项目符号模式（`AppModel.indexedContentID(forPath:)`）。
  - Relations/Context 候选统一经 `MainWindowController.open(path:)` 附 `indexedContentID`；依赖路径（Exact）留 nil，由 S2b 补。
  - 大纲/行号/文档符号模式（activeDocument 来源）不附身份，不受索引陈旧影响。
- 历史回放、严格书签维持既有前置验证，经 nil 身份直通。

## GREEN

- 新增 5 测试全绿（RED 时 15 个 issue）。
- `AppModelTests|SearchPanelModelTests|SnapshotSwitchTests|SessionRestoreTests|ExactCoordinatorTests`：319 通过。
- UI 批（RelationUX/Palette/MainWindowController/ReaderContextMenu/NonSourcePreview，含隔离跳过）：76 通过 + 隔离 2 通过。三个既有 Trail UI 断言补 `await pumpRunLoop()`：验证任务使 commit 晚一个 main-actor 跳，observation 驱动的 render 需在该跳之后断言（产品路径不变：真实 App 的 Reader 即由 observation→render 驱动）。
- 完整主套件：**860 通过**（= 规划基线 849 + S1 新增 6 + S2a 新增 5），`scripts/ci.sh` 计数同步 849→860。
- 注意：过滤运行若把两个隔离 BookmarkPanel 测试混入批次，会在 `recentProjectStores…` 处静默截断（复现于干净基线，属既有隔离契约，须按 ci.sh 方式 `--skip` 后单独跑）。

## 验收对照（计划 §5 S2a）

1. 不匹配/删除/越界/非法 UTF-8 不再错误导航并给出状态栏反馈；失败不增加 history/Trail、不污染当前 tab。✅（单测覆盖）
2. 当前文档大纲/查找正常（nil 身份不受影响，Unicode 测试覆盖）；commit 路径经 documentSource 同一验证（慢路径单测 + 860 全量既有 commit 流程测试）。中文/emoji 字节坐标正确。✅
3. 快速 A→B→C、切项目旧验证不发布；索引位置 producer（搜索、⌘T 项目符号、Relations、Context）均供身份。✅（依赖路径 producer 属 S2b）

## 已知边界

- `File changed since indexing` 提示暂无 `Refresh Index` 操作（S2c 落地 D2 时补）。
- Palette 行在快照切换后未重建的极窄窗口内，身份取自新清单（面板每次 show 重建行，实际窗口极小）。
