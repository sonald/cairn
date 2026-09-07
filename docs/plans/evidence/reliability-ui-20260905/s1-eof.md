# S1 — LSP EOF 忙循环：逐片记录

## RED（当前源码，2026-09-07）

新增回归测试先于实现运行，3 项关键断言失败：

- `lspClientStopsStdoutMonitoringAtEOFWhileClientStaysAlive`：stdout EOF 后 `readabilityHandler` 仍安装（空转根源）。
- `lspClientStopsStderrMonitoringAtEOFWithoutClosingTransport`：stderr EOF 后监听仍安装。
- `lspClientEndsPendingRequestWhenProcessClosesStdoutButStaysAlive`：进程存活、stdout 关闭时，未完成请求等到进程退出（10.0s，`.processExited`）而不是在 EOF 立即结束。

独立管道探针（见 baseline.md）：现状模式 EOF 后 2 秒 1,622,789 次回调；与安装应用 175%–199% CPU 的采样结论一致。

## 实现

`Sources/CodeInsightExact/LSP.swift`：

1. `installHandlers()`：stdout/stderr 各自 EOF 时先注销自身 `readabilityHandler` 再置位/唤醒；weak self 已释放路径同样注销。已收到的消息与 stderr 诊断保留；stderr EOF 不关闭整个 transport。
2. `request()`/`waitForQuiescence()` 等待条件加入 `!reachedEOF`：stdout EOF 立即结束未完成请求（`connectionClosed`），不再等进程退出或超时。
3. 管道 init 增加可选 `errorReadHandle`（internal），供测试独立关闭 stderr 复现（计划 S0 规定的夹具能力）。

回调内不做任何等待同一 transport 的同步 shutdown/close；显式 close、进程退出、EOF、deinit 的清理保持幂等（`releaseHandles` 与 EOF 注销重复置 nil 无害）。

## GREEN

`swift test --disable-sandbox --no-parallel --filter 'CodeInsightExactTests'`：98/98 PASS（26.5s），其中：

- 进程存活 + stdout 关闭的未完成请求 0.082s 结束（修前 10.0s）。
- stdout-only、stderr-only、进程退出、close 竞态、deinit 清理 6 个新回归全绿；既有测试（含两次 provider 重启耗尽、批量取消不发布迟到结果）不倒退。

## 验收对照（计划 §5 S1）

1. EOF 后 handler 不再触发（两个流均验证）；未完成请求有限时间结束；正常新进程仍可使用（重启耗尽既有测试 + 进程型新测试）；weak self 释放不留监听（deinit 测试）。✅（单测级）
2. stdout-only、stderr-only、进程退出、close 竞态覆盖；旧响应不发布到新会话由既有 `typeScriptBatchCancel…`/restart 测试覆盖。✅
3. 当前 bundle 空闲 CPU 采样 3×10 秒：**推迟到 V0**（需要真实 bundle + provider 断开的原生流程，属计划 §6 V0 步骤 2；机制层证据由探针与回调计数差异给出）。不以此为 PASS 依据。

## 回退

本片可独立回退；回退后 EOF 空转缺陷重新出现（上述 3 项断言即回退判据）。
