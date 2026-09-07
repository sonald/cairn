# S2c — Refresh Index 的真实恢复路径：逐片记录

## RED（2026-09-07）

6 个新回归（`SnapshotSwitchTests.swift`，真实 Git fixture + `ProjectIndexService`/`ControlledSnapshotIndexService`），先以桩 `refreshIndex` 运行：

- `refreshIndexRepublishesDriftedWorktreeAndClearsStaleState`：刷新后 `#renamed` 仍无命中、`#target` 仍命中、manifest 身份仍旧、stale 提示不清（RED 4 issue）。
- `refreshIndexPreservesTabsTrailHistoryAndBookmarks` / `refreshIndexFailureRestoresThePreviousIndexAndAllowsRetry` / `refreshInProgressSuppressesSessionCheckpoints` / `refreshIndexWorksForPlainNonGitDirectories` / `refreshYieldsToAProjectSwitchMidFlight`：桩下全部失败（120s fuse 或直接断言失败）。

## 实现（D2）

`AppModel.swift`：

1. `switchSnapshot` 抽出共享发布链 `snapshotLoadTask(revision:generation:root:languages:onFailure:onSuccess:)`（capture → publishFirstPaint → prepare → cachedReady → complete → fullReady，各级 generation/root/languages 守卫不变）。
2. `refreshIndex(leaving:)`：同一 destination（worktree 或当前 commit）的新捕获代际，绝不走 `openProject`（其会 reset tabs/Trail/history）。单语言项目走 `index()` 链（非 Git 目录同样可刷新）+ 重建文件树 + 保留选中文件；多语言走共享快照链。位置恢复经既有 `pendingReplay`/replayOffset fallback（content→line→anchor），刷新不写 history、不重复 Trail。
3. 失败恢复：刷新前捕获 sessions/phase/coverage/fileTree/snapshotID/documentSource/ready 会话/stale 提示；失败时整体恢复并发布 `.ready`（新代际上下文），设置 `indexRefreshNotice`（重试即再次 Refresh Index）。重复触发取消旧请求（单 `snapshotTask` 字段，不叠加）；openProject/switchSnapshot 接管工作区时 `endIndexRefresh()` 交还所有权。
4. 刷新中 `scheduleSessionCheckpoint` 抑制（不保存半安装会话）；成功后由下一次 checkpoint 正常落盘。

UI（`MainWindowController.swift` / `CodeInsightApp.swift`）：File 菜单 `Refresh Index`（⌘R，同一动作）+ 状态栏在 stale/刷新失败时显示 `Refresh Index` 按钮（刷新中显示 "Refreshing index…" 并禁用）。菜单 validation 走 `canRefreshIndex`（仅 ready 项目）。

## GREEN

- 6 新测试全绿（RED 时 15 issue / 3 个 120s fuse）。
- `SnapshotSwitchTests|SessionRestoreTests|AppModelTests|ExactCoordinatorTests`：329 通过（含既有快照切换/取消/代际失效链不倒退）。
- UI 批（Relation/MainWindowController/NonSource/Palette，隔离跳过）：70 通过。
- `scripts/ci.sh` 计数 864→870。

## 验收对照（计划 §5 S2c）

1. 刷新后 `#target` 不再命中、`#renamed` 定位正确（manifest 身份 = 漂移后字节）、stale 提示清除、新身份导航恢复。✅
2. tabs/Trail 分支/history/书签/选中文件不丢、不重复历史。✅（位置恢复链经既有 replay fallback；原位置恢复在 G0 前半检查的真实 bundle 复测中再验）
3. 刷新失败恢复旧索引可重试；刷新中切项目由 generation 守卫让位、不发布到新工作区；半安装会话不 checkpoint；非 Git 单语言目录可刷新。✅

## G0 前半检查状态

S1–S2 单测级全绿；真实 bundle 的 `target→renamed` 复现-修复对比（外部改名→重开→stale→旧搜索拒绝→Refresh Index→新符号定位）留待 V0 步骤 3 执行——单元测试通过但若原生实测仍有错误跳转则本切片不算 PASS。
