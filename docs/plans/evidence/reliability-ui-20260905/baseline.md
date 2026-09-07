# Reliability & Reading UI 修复 — 实施基线（S0）

记录时间：2026-09-07。本文件为 S0 产物，只记录事实，不作为任何切片的通过证明。

## 环境与基线

- IMPLEMENTATION_BASE：`ac18460ff99197f70bed7641c29fd8b30c0cc257`（即规划基线，工作树无已跟踪文件修改，实施从该点直接开始）。
- 工作树差异（实施开始时）：仅未跟踪 `.claude-trace/`、`docs/plans/2026-09-05-reliability-and-reading-ui-plan.md`、`docs/reviews/`。按计划不删除、不覆盖、不顺手提交。
- OS：macOS 26.6.2（25G83），arm64。
- Swift：Apple Swift version 6.3.3（swiftlang-6.3.3.1.3）。
- 本轮验证 bundle 输出目录（V0 使用）：`.build/reliability-ui-validation`，bundle id `dev.cairn.Cairn.ReliabilityUIValidation`。不替换 `/Applications/Cairn.app`，不终止其原实例。

## S1 RED 复现（真实管道，独立可执行探针）

在 `/tmp/lsp-eof-probe` 用真实 `Pipe` + `NSFileHandle.readabilityHandler` 复现当前 `LSPClient.installHandlers()` 的 EOF 行为（探针代码与当前 LSP.swift:661-693 同构：EOF 时仅置位/返回，不注销 handler）：

- 现状模式（不注销）：服务端关闭写端后，2 秒内 EOF 回调 1,622,789 次，随后 2 秒又 3,296,134 次；handler 仍安装。这与审查报告中安装应用 175%–199% CPU、`sample` 定位 `installHandlers()` 回调链一致。
- 修复模式（EOF 回调内注销自身 handler）：EOF 回调仅 1 次，`readabilityHandler == nil`，无死锁，进程正常退出。

探针在本机直接验证了「回调内置 nil」在 macOS 26.6.2 上既不死锁也停止派发；RED 依据成立。

## Fixture 方针

- 按计划 S0：fixture A/B 均按需生成在临时目录（测试内 `temporaryProject` / `temporaryGitProject` / Exact 管道 fake 已存在，见 `Tests/CodeInsightAppModelTests/AppModelTests.swift:2708`、`Tests/CodeInsightExactTests/CodeInsightExactTests.swift` 的 Pipe fake server），不修改既有 `fixtures/`、`goldset/`。
- 各切片 RED 需要的具体 fixture（Rust 两次 commit + `target→renamed` + 前插注释 + Unicode、非源码资源等）在对应切片内以临时目录生成，不复用用户会话数据。
- 每轮 bundle/缓存隔离路径在 V0 记录；单元测试沿用 `CODEINSIGHT_INDEX_CACHE_ROOT` 环境变量隔离（AppModelTests 既有机制）。

## 复现判据索引（按切片）

| 切片 | 真实失败判据 | 状态 |
|---|---|---|
| S1 | EOF 后 handler 不再触发 + 未完成请求有限时间结束（探针 + 单元回归） | RED 已复现（本文件） |
| S2a | `target` 改名+前插注释后旧搜索跳到注释行（审查报告截图 06/07 已复现，当前源码含同一缺口） | 待测试固化 |
| S2b/S2c/S3… | 计划 §5 各切片验收项 | 逐片补充 |
