# Cairn 恢复阅读现场——实现与验收记录

> 2026-09-16 更新：本记录中的两进程证据范围已由独立审查修正；修复与最终验收以 [2026-09-16 修复记录](../reviews/2026-09-16-reading-session-restore-fixes.md) 为准。

日期：2026-09-15。设计方案：`docs/plans/2026-09-15-reading-session-restore-plan.md`。
实现切片提交：S1 `d93b146`、S2 `5e96e0b`、S3 `0b2d69c`、S4a `7ed2fa8`、S4b `3f340f4`、S5（本提交）。

## 1. 交付摘要

- **按项目保存**：每个项目一份快照 `sessions/<sha256(root)>.json`（SHA-256 基于标准化并解析符号链接的绝对根路径）；最后项目指针存于 RecentProjectsStore 同一 UserDefaults 命名空间（`Cairn.LastSessionProject`），仅在项目成功写入首份有效快照后更新；清空最近列表不影响指针与快照。
- **v1/v2 迁移**：无指针时启动读取旧 `session.json`，恢复并成功写入项目文件后将旧文件改名为 `session.json.migrated` 一次性备份；迁移失败不删旧文件、不标记完成；有 v3 数据后不再导入。
- **schema v3**：在 v2 基础上新增 `tabs[].isPreview/activationRank`、`navigationHistory`（records+cursor+forwardRecord）、`readingTrail`（节点按导航插入顺序、边含 cause 与冻结证据、活动节点）。未来版本（>3）读取时保留原文件并禁止覆盖；损坏数据隔离为 `.corrupt` 后可重新记录；项目目录离线时保留数据并提示。
- **标签语义**：恢复走 `TabStripModel` 批量安装（无 preview 替换/去重激活/LRU 淘汰副作用），相对 activation rank 重建淘汰顺序；至多一个 preview（Reading Set 不可为 preview）；v1/v2 默认固定标签、按保存顺序重建 LRU；保存的活动标签不可恢复时提示一次并激活首个可恢复标签。
- **位置回放**：共享 `replayOffset` 调整为 唯一符号 → 行列（内容变化时优先回到原函数声明；重载等歧义降级行列）；ContentID 一致仍用精确字节。恢复的选择/滚动锚点分别应用。
- **Trail/History**：批量恢复不重放导航事件（无重复节点、不截断 forward 分支）；跨进程不保存 SnapshotID，按持久化 revision 选择目标版本（工作区记录明确切回工作区；依赖文件不参与版本切换）；版本不可用时保留视口、cursor 与 activeTrail 并提示；历史证据在界面标注为“来自更早会话的冻结快照”，不提供依赖旧运行时 ID 的动作。
- **保存可靠性**：恢复期间（工作区安装完成→完整状态提交首个快照）抑制所有写入路径；250ms 防抖叠加 ~2s 脏状态上限；切项目先采集并 flush 旧项目；同项目重复打开直接聚焦；写失败状态栏提示并在下次成功后清除；Back/Forward 目标先验证后提交游标。
- **清除现场**：`File → Clear Reading Session…` 确认后关闭全部标签、重置导航状态、移除项目快照并写入空快照（防止退出写回旧状态），不删除源码、书签或全局设置。

## 2. 模型/控制器测试（swift-testing）

- `CodeInsightAppModelTests`：359 通过（含 SessionCodecTests、SessionRestoreTests、TabStripModelTests、SnapshotSwitchTests、RecentProjectsStoreTests、AppModelTests 的新增/调整用例）。
- `CodeInsightAppTests`：109 通过（按 CI 的既有隔离跳过 4 个窗口态用例后）。
- CI 主批次计数更新为 931（`scripts/ci.sh`）。

覆盖要点对应 §10 矩阵：

| 场景 | 证据（测试） |
|---|---|
| 恢复中退出/延迟加载不覆盖旧文件 | `midRestoreCheckpointWriteLeavesLastValidSnapshotIntact`、`syncSaveDuringBlockedRestoreIndexingKeepsDiskSnapshotIntact` |
| A→B→A 各自恢复 | `perProjectSnapshotsRestoreIndependentlyAcrossProjectSwitches`、`recentOpenWithSavedSnapshotRestoresTabsInsteadOfOpeningFresh` |
| v1/v2 迁移 | `legacyV1SessionMigratesToPerProjectStoreOnce`、`sessionCodecWritesV2LanguageArrayAndDecodesV1Singleton` |
| 离线/未来版本不删数据 | `sessionLoadProblemsAreClassifiedAndPreserveOrQuarantineData`、`futureVersionPerProjectSnapshotIsPreservedAndNotOverwritten` |
| preview 与第 11 个文件 | `restoredTabBatchReinstatesPreviewFlagsAndLRUEvictionOrder`、`sessionRestoreReinstatesPreviewFlagAndLRUEvictionOrder`、`sessionCodecRoundTripsPreviewFlagAndActivationRank` |
| A→B→Back→C 兄弟分支 | `sessionCheckpointPersistsAndRestoresNavigationHistoryAndTrail` |
| Back 中间退出后 Forward | 同上（导出/恢复 cursor 与 forwardRecord 并比对 canGoForward） |
| Back/Forward 目标不可用 | `failedReplayLeavesHistoryCursorAndActiveTrailUnchanged`（文件不可用）、`replayingAnUnavailableSavedRevisionKeepsTheCurrentView`（版本不可用） |
| 函数前插入代码 | `replayOffsetReturnsToTheOriginalFunctionWhenCodeMovedAboveIt`（含重载降级） |
| 损坏边/无效标签/超限 | `sessionCodecSanitizesInvalidTrailEdgesAndHistoryReferences`、`sessionCodecClampsHistoryCursorAndCapsTrailNodes` |
| 磁盘写失败可见/清除 | `sessionCheckpointWriteFailureSurfacesNoticeAndSuccessClearsIt`、`continuouslyRescheduledCheckpointCommitsWithinDirtyDeadline`（脏上限 ~2s 实测提交） |
| 清除现场 | `clearingTheCurrentProjectSessionDropsStateAndWritesEmptySnapshot` |
| 跨版本回放 | `restoredTrailNodeReplaysByItsSavedRevisionAndWorktreeRecordSwitchesBack` |
| 历史证据标注 | `trailDetailLabelsEvidenceRestoredFromAnEarlierSession` |

## 3. 原生两进程验收（真实 Quit→重启相同构建）

新增自测入口（隔离 `CAIRN_SESSION_SELFTEST_URL` 会话根与 `CAIRN_SESSION_SELFTEST_DEFAULTS` UserDefaults suite，不触碰用户数据）：

```sh
STATE=$(mktemp -d)
export CAIRN_SESSION_SELFTEST_URL="$STATE/session.json" \
       CAIRN_SESSION_SELFTEST_DEFAULTS="suite-$(basename $STATE)" \
       CAIRN_SESSION_SELFTEST_EXPECTATIONS="$STATE/expectations.json"
.build/debug/codeinsight-app --self-test-session <rust-project-root>      # 进程 A：真实打开→3 标签→语义导航 A→B→back→A→C→设置阅读位置→checkpoint
.build/debug/codeinsight-app --self-test-session-restart                 # 进程 B：正常启动路径（指针→按项目快照→restoreSession）
```

结果（连续两次独立运行，A/B 均 exit 0）：

- `tabOrder = [main.rs, other.rs, third.rs]`、活动标签与关闭前一致；
- `scrollAnchor/selectionAnchor` 与关闭前一致；
- Trail 2 条边（A→B 与 A→C 兄弟分支）、活动节点恢复；
- `historyCursor = 1`，`canGoBack/canGoForward` 与关闭前一致；
- Reader 显示恢复后的活动标签。

## 4. 故障注入与边界

- 进程 A 中途强杀未纳入本轮（两进程验收覆盖正常退出路径；S1 测试证明恢复中任何写入尝试都不会覆盖旧快照，故强杀至多回到最近一次成功 checkpoint）。
- 恢复期窗口关闭/退出：`applicationWillTerminate` 走同一受抑制的写入入口（S1 覆盖）。
- 主批次中 `readerVisualSettingControlsAreVisibleAndDoNotOverlap` 在本机（Xcode 27 升级后的环境）于干净 HEAD 上同样失败，属预存在的环境相关问题，与本功能无关；CI 若遇此失败请先在干净 HEAD 复核。

## 5. 尚未覆盖（首版明确不宣称）

- Reading Height、手动折叠（fold overrides）、Focus 的跨重启恢复（§11.1）。
- 完整拖选范围（仅恢复选择起点）与预览标签内部滚动/页码（§11.2）。
- 每项目独立面板比例/目录展开（沿用全局保存）。
- Relations/Context Pin/Compare 不恢复旧查询结果，按当前代码重新查询（设计如此）。
- Trail 证据仅保存显示快照：`VERIFIED` 不对今天的代码成立，需重新查询。
