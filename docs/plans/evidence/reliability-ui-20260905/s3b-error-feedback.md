# S3b — 可恢复的错误反馈（G0）：逐片记录

## RED 依据

审查报告已实测：打开失败落为无原因的 `.failed`（AppModel catch 丢弃 error），空态只有 "Couldn't open this folder." + "Try Again"。本切片引入 `projectFailureReason` / `failureSummary` / 空态原因行 API 时同步落测试——新 API 不存在于改造前，等价 RED（无法在旧代码上编译断言）。

## 实现

`AppModel.swift`：

- `projectFailureReason: String?`：`failWorkspace`/`failIndexing` 从底层 error 生成；`snapshotLoadTask` 的 `onFailure` 携带 `Error?`（打开/切换/刷新三处接线）；新打开（`beginWorkspaceOpen`）、firstPaint、`finishIndexing`、刷新成功时清除。
- `failureSummary(_:)`（nonisolated static）：`LocalizedError.errorDescription` 优先，≤280 字符 + 省略号封顶——provider stderr 之类无限文本不进 UI；原 error 不被替换。
- 刷新失败通知追加括号内短原因（仍非破坏、可重试）。

`EmptyStateView.swift` / `MainWindowController.swift`：

- 失败空态新增可选中（可复制）的原因行（13pt、≤460pt 宽、AX label "Open failure reason"），与 "Try Again" 并列的 "Open Another Folder…" 次按钮；默认空态不出现。`showEmptyState` 增加 `failureReason` 参数；observation 追踪该属性。

## GREEN

- `openAndSwitchFailuresSurfaceTheirUnderlyingReasons`：不存在路径（真实服务）、拒绝读取（CocoaError 注入）、无效 Git revision（ready 仓库上 switchToCommit 40×"0"）三类均有非空原因；重开成功后清除；超长 stderr 封顶 ≤281 且带省略号。✅
- `emptyStateFailureShowsReasonAndRecoveryActions`：失败空态含 "Try Again" + "Open Another Folder…"、原因可见/可选中/AX 可读、默认空态无原因与次按钮。✅
- `AppModelTests|SnapshotSwitchTests|SessionRestoreTests`：333 通过；UI 批（MainWindowController/Relation/NonSource）：60 通过。
- `scripts/ci.sh` 计数 873→875。

## 验收对照（计划 §5 S3b）

- 三类失败（不存在路径、拒绝读取、无效 revision）原因可见。✅
- Retry/选择其他目录可用（两个按钮 + 各自动作接线断言）。✅
- 超长错误有界（≤281），空态最小窗口不撑窗（标签宽度约束 ≤460pt + wrapping）；AX 标签含原因。✅（几何留 V0 步骤 9 复核）
- 刷新失败用非破坏状态栏提示，不覆盖可读主区（S2c 已有，本片补原因）。✅
- 未建全局错误分类平台（单一 summary 函数 + 既有 Error）。✅

## G0 状态

S1–S3 单测级全部通过。按计划 G0 定义，完整通过需当前 bundle 的真实复现对比（V0 步骤 1–5）；单测通过但原生实测仍失败则 G0 不算 PASS。
