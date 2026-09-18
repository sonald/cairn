# 多窗口剩余 P2 修复与验证

> 最终状态更新（2026-09-18）：本文为历史记录；原剩余验收项已补齐，W01–W20 全部通过。以[最终验收记录](2026-09-18-multi-window-final-acceptance.md)为准。

日期：2026-09-17。对应 [完成度独立复验](2026-09-17-multi-window-completion-review.md) 的 R1–R4。

结论：**四项 P2 已修复；定向回归、完整 CI 与所述真实 UI 复验通过。** 本页不将此前 W01–W20 中未执行的其他交互升级为已通过。

## 1. 修复

| 问题 | 修改 | 验证 |
|---|---|---|
| R1 清缓存后 Exact 被维护状态拦截 | 将解除维护和重新分析放在同一个 defer 中，先 endMaintenance，再遍历窗口 restart；成功/失败共享这一顺序 | 真实应用级入口测试成功/失败两例；双窗 UI 清理后均恢复 ready |
| R2 Settings 不刷新新增信任 | 每次显示 Settings 都刷新列表；生产授权回调经窄的应用级方法，授权成功后刷新所有 coordinator 和共享列表 | 已存在 Settings 重开测试；实际应用级授权方法测试同时验证 Settings 与第二窗口 |
| R3 取消 A 后复用 B 仍用 A 的布局键 | `releaseProjectClaim()` 同时清空 frame autosave 名，下一次认领可采用新项目名 | 取消 A → 同窗加载 B，直接断言 B 的 frame autosave key；真实 UI 同流程正常 |
| R4 全局窗口下项目菜单错误启用 | Show Bookmarks、阅读高度、Preset、Relations、Context 前后项均要求有效项目目标 | 菜单校验回归；Settings 前台时真实菜单显示 disabled，字体全局操作仍可用 |

另外移除了 `prepareIsSuspended(...) || true` 的恒真断言，明确检查拒绝 prepare 不会解除挂起、resume/revoke 结束后挂起已解除。它证明这些状态转换，不代替完整的 provider 阻塞交错测试。

产品增量集中在 `CodeInsightApp.swift` 和 `MainWindowController.swift`；没有新增通用服务类型或依赖。为测试生产入口，少量现有方法由 private 调整为模块内部可见，状态属性保留 private(set)。

## 2. RED → GREEN

新增 5 个测试函数（其中缓存测试有成功/失败两个参数案例）：

- `appCacheClearResumesExactAfterSuccessOrFailure`
- `existingAppSettingsRefreshesSharedTrustOnEveryOpen`
- `appTrustGrantRefreshesExistingSettingsAndOtherWindows`
- `globalSettingsDisablesEveryTargetlessProjectMenu`
- `cancelledProjectWindowUsesNextProjectsFrameAutosave`

修复前已取得有效 RED：缓存清理后的重新准备终态失败、Settings 与其他 coordinator 未更新、无目标菜单错误启用、取消后旧布局键残留。缓存测试最初使用了缺失 snapshot 实现的索引桩，夹具失败不计为回归证据；改用现有真实 ProjectIndexService 和临时 Git 项目，初始状态通过后再记录有效 RED。

修复后，上述 5 个测试函数及修正后的挂起测试共 **6 个测试函数通过**。缓存测试通过实际应用级清理入口，而不是在测试里手动调整维护状态顺序。它使用禁用 provider 的可识别终态证明 prepare 被重新执行；真实 provider 恢复由下面的 UI 证据补足。

证据：[缓存/授权有效 RED](evidence/2026-09-17-multiwindow-p2-fixes/services-red.log)、[其他 RED 摘要](evidence/2026-09-17-multiwindow-p2-fixes/other-red-summary.txt)、[定向 GREEN](evidence/2026-09-17-multiwindow-p2-fixes/targeted-green.log)。

## 3. 完整 CI

执行 `CODEX_SANDBOX=1 CAIRN_LIBGIT2=brew bash scripts/ci.sh`，在正常 macOS 权限下完成，**退出码 0**。

- 主批次 **968 PASS**，书签隔离 **2 PASS**，面板隔离 **2 PASS**，合计 **972 PASS**。
- 架构引用检查、exact/diff/reading/projector/fold 应用自检、fixture 校验、release 构建均通过。
- 额外运行 `--self-test-multiwindow`，退出码 0，`passed:true`、`persistedSnapshots:2`；见 [自检日志](evidence/2026-09-17-multiwindow-p2-fixes/multiwindow-selftest.log)。
- fold-perf **254.120125ms ≤ 400ms**，内存增量 **17,858,584 bytes ≤ 80 MiB**，逻辑/渲染折叠计数和配置校验通过。没有放宽门限。
- `git diff --check` 通过。

证据：[完整 CI 日志](evidence/2026-09-17-multiwindow-p2-fixes/ci.log)、[主测试](evidence/2026-09-17-multiwindow-p2-fixes/main-tests.log)、[书签隔离](evidence/2026-09-17-multiwindow-p2-fixes/isolated-tests.log)、[面板隔离](evidence/2026-09-17-multiwindow-p2-fixes/panel-tests.log)、[性能结果](evidence/2026-09-17-multiwindow-p2-fixes/fold-perf.json)、[运行摘要](evidence/2026-09-17-multiwindow-p2-fixes/summary.json)。

## 4. 真实 UI 复验

使用定向 GREEN 后新构建的 debug 可执行文件，封装并 ad-hoc 签名为 `/tmp/cairn-p2-fixes-20260917/Cairn.app`，bundle ID 为 `dev.cairn.Cairn.p2fixes20260917`。启动设置 `CFFIXED_USER_HOME=/tmp/cairn-p2-fixes-20260917/home`，核对 session 与 index-cache 确实落在该临时目录。

1. 打开 alpha、beta 两个测试项目，均观察到 `Exact: ready · Safe (limited)`，Provider 为 rust-analyzer。
2. Settings → Exact → Clear Materialized Cache → Clear，提示 `Materialized cache cleared.`。
3. 回到 beta，再通过 Window 菜单切到 alpha，两窗均自动恢复 `Exact: ready · Safe (limited)`；不再停在 cache maintenance。
4. Settings 前台时 View 菜单的 Show Bookmarks、Full/Structure/Overview、Preset 均为 disabled；全局字号菜单仍可用。
5. 新建空白窗口，打开 cancel-a 后 Cancel，标题恢复 Cairn；再打开不同项目 project-b，正常显示文件树及 Exact ready。布局 key 归属由对应 NSWindow 行为测试直接断言。
6. 正常 ⌘Q 退出，检查该测试应用进程已不存在。

本轮未通过真实 UI 授予新的仓库执行权限；R2 的授权后即时刷新与 Settings 重开由使用隔离 registry 的应用级自动化测试验证。没有把自动化证据写成手工 UI 授权证据。

独立只读增量审查结论为 PASS，未发现本轮修复引入的新确定缺陷。
