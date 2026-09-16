# 恢复阅读现场：独立验收审查

> 本审查列出的事项已完成修复；最终结果见 [修复与原生验收](2026-09-16-reading-session-restore-fixes.md)。以下保留修复前的审查结论。

日期：2026-09-16。审查 HEAD：`71ed847`。依据：`docs/plans/2026-09-15-reading-session-restore-plan.md`。

## 结论

**Request changes：主体能力已实现，但尚不能认定完全符合预期。**

按项目快照、标签批量恢复、符号优先定位、Trail/History 数据结构、持久化 revision 与历史证据显示方向符合设计。下面仍有数据丢失风险、导航错误和验收证据缺口。

本次只读审查功能代码，并运行已有测试；未改实现、未操作用户真实会话或修改 Xcode 许可。下面的问题来自源码调用链，未逐项运行新增故障复现；不能将它们描述为本次已复现的运行故障。

## 1. [P1] 被取消的旧恢复任务可以结束新项目的恢复保护

位置：`Sources/CodeInsightAppModel/AppModel.swift:1401`、`:1474`；`Sources/CodeInsightAppModel/TabStripModel.swift:68`。

`sessionRestoreWriteSuspension` 和 `isRestoringBatch` 是共享状态，两个 defer 无条件解除它们。时序：

1. A 恢复正在 `await resolveSessionFile`（1513），后台同步文件读取/解析未结束。
2. 用户打开有现场的 B；控制器只 cancel A，不等待 A 退出，随后 B 开始恢复。
3. B 进入 batch 并等待自己的文件解析。
4. A 返回，generation/cancellation 检查拒绝发布，但 defer 仍结束 B 的 batch、解除 B 的写保护。
5. B 后续标签安装因 `isRestoringBatch == false` 返回 nil；最终可能写入缺失标签的快照。

**修正**：清理保护与 batch 时核对恢复归属；旧任务不得释放新任务状态。补两个恢复任务交错返回的门控测试，验证 B 标签完整且磁盘没有被部分状态覆盖。只有正文中的 generation guard 不够。

## 2. [P1] 合法历史版本导航被工作区文件检查拒绝

位置：`Sources/CodeInsightAppModel/AppModel.swift:3153`，尤其 `:3167`。

`canReplayTarget` 用工作区 `fileExists` 判断源码文件，但历史版本的读取来自 `documentSource`。保存 commit 中仍有 `a.rs`、工作区已经删除它时，Back/Forward 在切换到正确版本前就拒绝导航。非源码分支也使用当前 fileTree，不能证明目标版本可用。

**修正**：依据目标 revision 对应的内容来源验证目标。补“文件仅存在于目标 commit”的恢复后 Back/Forward 用例。

## 3. [P2] Back/Forward 仍在真正加载成功前提交游标

位置：`Sources/CodeInsightAppModel/AppModel.swift:3086`、`:3095`；`:4018`。

预检查通过后立即推进 history，实际 `replayOffset` 仍异步加载；加载失败直接返回，没有回滚或错误提示。

确定性的待复现场景：退出后将历史目标 `a.rs` 替换成同名目录，恢复后 Back。`fileExists` 对目录返回 true，游标先移动，文件读取失败，视口和 activeTrail 未动但 history 已被消耗。已有“文件不存在”测试无法覆盖这个分支。

**修正**：目标内容成功加载/定位、且当前请求仍有效后，再提交 history 与视口；失败保留整个导航状态并提示。不要仅再加一个存在性检查代替成功提交边界。

## 4. [P2] 同项目更改语言组合会丢失尚未保存的现场

位置：`Sources/CodeInsightApp/MainWindowController.swift:628`、`:667`。

显式修改语言组合会进入恢复流程，但先读取旧磁盘快照；flush 又因根目录相同而跳过。防抖期间的新标签、位置或轨迹可能被旧数据替换。

**修正**：确实需要重新打开时先保存，再读取；同项目仅聚焦窗口的分支仍可直接返回。增加语言更改发生在最后一次操作后 250ms 内的测试。

## 5. [P2] 读取权限/I/O 故障被错误当成内容损坏

位置：`Sources/CodeInsightAppModel/AppModel.swift:876`；legacy 加载也使用同类 catch。

`Data(contentsOf:)` 的读取错误与 JSON 解码错误进入同一个 catch。例如文件不可读但父目录可写，会把有效快照移至 `.corrupt`，随后允许 fresh open 和新快照写入。用户恢复权限后，原现场已退出正常恢复入口。

**修正**：区分读取与解码失败。暂时 I/O/权限失败保留原文件并阻止覆盖；只有内容已读出且确认不合法时才隔离。补权限故障恢复测试。

## 6. [P2] 未成功迁移的旧现场可以被误标为已迁移

位置：`Sources/CodeInsightAppModel/AppModel.swift:1002`。

`legacySessionRootPendingMigration == nil` 也允许 retire。旧项目离线或 schema 不支持导致加载失败后，打开另一个项目并保存，会把未迁移的旧文件改名为 `.migrated`。指针更新后没有再次自动导入的入口。

**修正**：只有对应旧项目成功迁移才 retire；明确清除现场的处理单独保留。补“旧项目离线→打开 B→旧项目重新可用”的迁移用例。

## 7. [P2] 损坏 history 游标可在净化前触发整数下溢

位置：`Sources/CodeInsightAppModel/SessionCodec.swift:471`。

201 条有效 records 配合 `cursor = Int.min` 时，`history.cursor - shift` 先下溢，再执行的 min/max 无法保护进程。损坏快照因此可能导致启动崩溃，而非降级恢复。

**修正**：先把原始 cursor 限制到合法范围，再做裁剪偏移。补一条异常 JSON 解码用例即可。

## 8. [P2] 两进程自测不能支持“真实 Quit 与 Reader 视口已恢复”的结论

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:8869`、`:8917`、`:8931`、`:11139`；`Sources/CodeInsightApp/MainWindowController.swift:849`。

- 进程 A 手动 checkpoint 后调用 exitSelfTest；该函数最终调用 `Darwin.exit`，未走 AppKit terminate/WillTerminate。因此证明的是落盘后跨进程恢复，没有验证正常 Quit 的最后位置捕获与保存。
- 重启后的 scroll/selection 检查读取 `model.tabStrip` 字段，没有测实际 Reader 可见行和 selection。
- `readerDisplaysActiveTab` 使用 `selfTestActiveTabFile`，其 getter 也是模型 activeTab，不能证明 Reader 已显示它。
- `trailActive` 只检查非 nil，节点/边只比数量，没有比对活动节点身份和兄弟分支端点。

**修正**：通过正常 terminate 退出；在最后 UI 操作后、防抖写入前退出以验证生命周期捕获。重启等待实际 Reader 呈现完成，检查可见源码行、选择位置、活动函数和 Trail 节点/边身份；执行一次恢复后的 Back/Forward。补实际关窗与 A→B→A 验收。修正原验收记录中过强的结论。

## 本次执行的验证

| 验证 | 结果 |
|---|---|
| 工作区与提交核对 | 开始审查时干净，HEAD 为 71ed847 |
| `swift test --no-parallel --filter 'SessionCodec\|SessionRestore\|TabStrip'` | **PASS：44 tests**，完整成功摘要、exit 0 |
| 3 个已有回放测试：恢复 revision/worktree、缺失文件、不可用 revision | **PASS：3 tests**，完整成功摘要、exit 0 |
| 上述新增边界场景 | **未运行专项复现**；源码证据已列出 |
| 本次真实 UI Quit/重启与关窗 | **未执行**；现有自测证据不足以替代 |
| 本次完整 CI | **未重跑**；用户报告仍有一项失败，不能记为全绿 |

测试日志：`/tmp/cairn-session-review-tests.log`、`/tmp/cairn-session-review-navigation-tests.log`。首次普通沙箱执行因 Clang 缓存权限失败；经工具审批后的同命令执行成功，未修改 Xcode 许可。

## 关于交付总结的两项环境说明

“930 通过 + 1 失败”只能说明总数为 931，不能说明 CI 成功。需要在功能提交之前的基线、相同环境和隔离条件下复现那一项，才能确认它与本功能无关；当前 HEAD 是干净工作区不足以证明这一点。本次未独立验证其根因，也未对 Xcode 用户级 defaults 修改作有效性背书。

建议先修复上述功能问题并加入对应回归，再补真实生命周期/Reader 验收；将“主体功能完成”和“完整验收通过”分开记录。
