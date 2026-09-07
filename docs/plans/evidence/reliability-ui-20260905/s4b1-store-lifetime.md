# S4b-1 — 项目与快照存储寿命：逐片记录

## RED（2026-09-07）

两个新回归（`AppModelTests.swift`，真实 Git fixture + 真实 `ProjectIndexService`）。移除边界调用的对照运行（/tmp/s4b1-red.log）确认 5 处断言失败：

- `projectBoundaryReplacesTheServiceStoreButKeepsOldSessionsUsable`：打开 B 后 A 的内容仍被服务 store 保留。
- `multiLanguageProjectBoundaryAlsoReplacesTheServiceStore`：多语言边界同样不清。

## 实现

- `ProjectIndexStore` 增加公开诊断面 `retainedContentIDs()` / `retainedContentByteCount()`（消费者：S4b 回归与 S4a 矩阵复测）。
- `ProjectIndexService.beginProjectScope(root:)`：进入不同项目（root 标准化路径变化）时替换为全新 store；同一项目（含 commit 切换、Refresh Index、重开）不替换，保持跨修订 blob 复用（M0-C 合同）。接线到 `index(root:language:)` 与两个 `captureSnapshot` 入口；`store` 由 let 变 var 并全部经锁读写。
- 已发布的 EngineSession/Compare/pending replay 持各自 store 引用，替换不失效（测试断言旧会话 `searchSymbols` 仍可用）。
- 旧项目任务释放：AppModel 代际守卫（S3a）取消旧任务；旧 store 对象随旧任务/会话引用消亡。

## GREEN

- 2 新测试全绿（RED 对照 5 失败）。
- `AppModelTests|SnapshotSwitchTests|SessionRestoreTests|ExactCoordinatorTests|SnapshotIndexerTests|CodeInsightGitTests|CodeInsightEngineTests`：478 通过（含 commit 切换内容复用、刷新、会话恢复不倒退）。
- UI 批：60 通过。`scripts/ci.sh` 875→877。

## 冻结阈值对照（s4a-measurement.md）

- 项目切换后旧项目内容离开服务 store ✅（两测试）。
- 固定 A/B×20 扁平：store 级 contentID 去重保持 ✅（S4a 场景 B）。
- 当前会话/Compare/pending replay 引用有效 ✅（旧会话可用断言）。
- **同项目演化内容保留为已报告的开放风险**（S4a 场景 C 线性；按计划先收缩到项目边界，不强行删除 interned IDs/共享状态）。
