# 多窗口、多项目与目录打开：最终验收

日期：2026-09-18。范围：[设计 W01–W20](../plans/2026-09-16-multi-window-projects-design.md)。状态：**全部 20 项已闭环，最终 CI、打包和按名称启动核对通过；可以按任务完成提交。**

本次以生产启动入口、实际 `.app`、真实 AppKit 交互及受控 provider 交错补齐此前缺口；中间评审和失败日志保留为历史，不再作为当前状态。

## 1. 补验中发现并修复的问题

### 首窗口绕过共享服务装配

真实两窗交错保存书签时，第二窗口覆盖了第一窗口的磁盘记录。根因是 main 的普通启动分支注入了独立 AppModel，后续窗口才使用 AppDelegate 的共享书签、信任和缓存实例。

普通启动与 multiwindow 自检现在统一经 `AppDelegate.production`，首窗和后窗均由 `makeWindowModel` 装配；保留其他自检的显式 fake provider/隔离注入。

`productionFirstAndLaterWindowsShareBookmarksTrustAndCache` 修复前有 5 条失败断言，修复后通过：两窗及磁盘均有两条记录、共享同一 registry、共享缓存维护状态。真实 UI 再次确认 alpha-final 与 beta-final 同时落盘，删除 beta 后 alpha 记录与备注仍存在。

### 已关闭窗口的迟到确认仍改写数据

真实 NSAlert 待处理时关闭父窗口，再投递迟到确认，原会话文件被改写；回归在 `savedA == afterCloseA` 失败。会话清理和书签删除的完成回调现在拒绝 `isClosing` 的控制器。

同样为信任确认的回调、异步任务入口和迟到错误增加关闭状态保护。信任旧路径在本次特定调度下已通过，不伪称它取得 RED；该项是明确生命周期策略和回归覆盖。

## 2. 受控异步验证

以下测试调用真实 AppModel/ExactCoordinator/AppDelegate，provider 使用可阻塞的测试实现，以固定交错顺序；不把 fake provider 描述为真实语言服务器运行。

| 测试 | 证明 |
|---|---|
| `revocationBlocksNewProvidersAndRestartsCurrentGenerationSafely` | 真实 revoke 进行中阻塞旧 provider.close；切换 feature/generation 不启动新 provider；解除阻塞后旧 trusted session 已关，新 Safe session 服务当前 generation，旧 generation 请求被拒绝 |
| `shutdownWaitsForLatePrepareToCloseAndReleaseItsDirectory` | prepare 尚未完成时 shutdown 不提前结束；迟到 session.close 仍被等待，物化引用在实际关闭后释放 |
| `sharedCacheClearWaitsForBothProvidersAndAllowsRestartAfterMaintenance` | 双 coordinator 引用按 2→1→0 释放，维护中拒绝 prepare，clear 后解除维护并恢复 ready/引用2 |
| `closingWindowWithPendingClearSessionSheetPreservesBothSessions` | 真实 sheet 的会话清理/书签删除两例；A 已关的迟到确认不改写 A/B 会话、不删除书签、不复活窗口 |
| `closedWindowIgnoresLateTrustSheetConfirmation` | 真实 AppDelegate action 和 sheet；父窗关闭后迟到确认不写信任记录 |

门控有超时失败保护，检查的是阻塞期间和解除后的状态，而不是依靠 sleep 猜测顺序。共享服务装配的回归另覆盖生产 main 使用的同一工厂，避免只手工拼出正确对象图。

## 3. 真实入口与 UI 证据

为了测试真正的 `open -a Cairn`，先备份原安装和完整偏好，将脚本生成的验收包临时放入 `/Applications/Cairn.app`。有效测试使用原 bundle ID 和独立 `CFFIXED_USER_HOME`，核对 session/index-cache 实际落入临时目录。测试后已按原可执行文件 SHA256 和偏好 plist 内容恢复。

- 冷启动 `open -a Cairn <alpha>` 命中 `/Applications/Cairn.app/Contents/MacOS/codeinsight-app`；热启动第二项目保持同一应用主 PID **58619**。另一个同名进程为该主进程的 guard 子进程，不误计成第二应用实例。
- 一次投递 `./alias-alpha`、`./第二个 项目/.`、普通文件 `./plain.txt`、`./alpha`：普通文件有明确错误提示，其余请求继续处理；Window 菜单恰为 alpha 和第二项目两窗，没有别名重复窗口。
- 双窗口分别打开自己的 lib.rs；第二窗切 extra.rs 后 `⌘[` 返回自己的 lib.rs，`⌘F` 查 beta 为 1/1；项目搜索中用 `⌘A` 替换 helper 为 beta，得到对应项目的结果。
- 第二窗 Show Calls 以 beta 为根，helper 为 Verified 子项；关闭其标签不关闭首窗文件。跨窗切换时重新确认实际激活窗口，避免自动化工具沿用旧输入目标。
- 书签备注使用实际输入焦点与 `⌘A` 替换；两窗记录及备注共同落盘。面板按项目过滤，删除 beta 不删除 alpha。
- 在明确激活的 alpha 发起会话清理确认后激活第二项目，再返回原确认框确认：落盘 alpha tabs=0、第二项目 tabs=1。
- 注入临时 session 路径写失败：Cancel Close 保留文件与窗口；恢复目标后 Retry Save 成功关闭。alpha 的 provider **58632** 退出，第二项目 provider **59328** 仍存活且 UI ready。
- 全局清缓存停止了两个旧 provider，随后为两个项目重新启动 **62065 / 62066**，UI 恢复 ready，Reader 状态保留。
- 注入 alpha 最终保存失败：Cancel Quit 后第二项目 extra.rs 仍可读；Quit Without Saving 完成退出，第二项目 extra.rs 快照仍保存，alpha 原备份 SHA256 未变。恢复测试故障后无参数启动，恢复第二项目的 extra.rs。
- Settings 开着时关闭最后项目，应用真正退出；原安装和原偏好已恢复一致。

测试项目、缓存、书签和 session 都是临时夹具；未授予生产项目新权限，也没有清理用户缓存。截图/AX 操作确认 UI，文件内容与进程 PID 单独证明落盘和回收，不以窗口标题代替模型隔离。

## 4. W01–W20 结论

本表以设计规定的行为和证据层级为边界，不声称对所有可能 OS 调度或输入做穷举。

| ID | 结论 | 对应证据 |
|---|---|---|
| W01 | PASS | 独立模型自检；两窗文件、标签、导航、关系状态分别操作；生产共享服务回归 |
| W02 | PASS | 项目认领先于异步加载的路由测试；取消重开/关闭立即重开自检；最终包别名与重复批量请求去重 |
| W03 | PASS | 实际跨窗查找、后退、Show Calls、关闭标签；菜单目标与 enabled 回归 |
| W04 | PASS | 项目搜索 helper→beta 的全选输入；书签备注正常编辑及面板 owner 路由测试 |
| W05 | PASS | 原窗口确认经跨窗切换后只作用原窗口；关闭父窗的真实 sheet 迟到清理/删除/信任回归 |
| W06 | PASS | alpha 关闭后仅对应 provider 退出，第二窗 provider 与阅读继续；保存文件检查 |
| W07 | PASS | 迟到 prepare/session 的双门控等待与引用释放；窗口关闭/恢复写入抑制回归 |
| W08 | PASS | 两项目会话独立保存；正常退出及跳过失败保存后无参数启动恢复正确项目/文件 |
| W09 | PASS | Settings 存在时关闭最后项目，进程退出 |
| W10 | PASS | 生产首/后窗口共享装配回归；真实双窗备注交错落盘与删除隔离 |
| W11 | PASS | 原 dirty store、原路径故障恢复重试测试，检查全部记录与通知 |
| W12 | PASS | 真实 revoke 与阻塞 provider.close、feature/generation 切换的受控交错；共享 registry 与列表更新回归 |
| W13 | PASS | 双引用保护测试及双 provider 关闭顺序下的引用计数 |
| W14 | PASS | 小配额只淘汰零引用；quota 失败回滚；迟到/取消 prepare 引用释放 |
| W15 | PASS | 双 provider 门控维护测试 + 真实全局入口停止/重启两个 provider，UI ready |
| W16 | PASS | 安装位置按名称冷启动，实际可执行路径与单项目窗口核对 |
| W17 | PASS | 按名称热启动第二目录，主 PID 不变 |
| W18 | PASS | 同批多目录、别名、无效文件混合，报错不阻断其余请求、窗口数正确 |
| W19 | PASS | 中文/空格/相对路径/尾斜杠/符号链接的实际命令；非法 URL/断链等 identity 测试 |
| W20 | PASS | 真实 Cancel Close、Cancel Quit、Retry Save、Quit Without Saving；旧文件保护及其他窗口保存检查 |

## 5. 最终构建与复原记录

最终冻结版本执行 `CODEX_SANDBOX=1 CAIRN_LIBGIT2=brew bash scripts/ci.sh`，终端退出码 **0**：

- Swift Testing：主批次 **974**、书签隔离 **2**、面板隔离 **2**，合计 **978 PASS**。
- 架构引用检查、exact/diff/reading/projector/fold 自检、fixture 校验、release 构建通过。
- fold-perf **253.860959ms ≤ 400ms**，内存增量 **22,528,048 bytes ≤ 80 MiB**，原门限、fixture 和折叠计数保持不变。
- 单独运行最终 `--self-test-multiwindow`：退出码 0，`passed:true`、`persistedSnapshots:2`。
- 最终源码、测试和脚本哈希与冻结清单一致；`git diff --check` 通过。

`scripts/make-app.sh` 生成最终 **0.7.acceptance** 包，plist 和严格签名验证通过。该最终包也临时安装到 `/Applications/Cairn.app`，实际执行按名称冷启动和热启动；冷启动主 PID **86966**，窗口菜单显示 alpha 与第二项目两个窗口，随后正常退出。

最终产物位于 `/tmp/cairn-final-acceptance-20260918/delivery/Cairn.app` 与同目录 `Cairn.zip`。这是本机 ad-hoc、Homebrew libgit2 打包路径的验收；原设计排除的多进程并发和全部窗口重启恢复不属于本任务，发行公证也不作为本功能提交条件。

测试后原应用字节和测试前偏好内容再次校验恢复一致，测试进程已退出。此前失败/部分覆盖记录为历史，本页替代其中的剩余验收清单，不再保留设计范围内的待验项。

主要证据：[最终汇总与产物哈希](evidence/2026-09-18-multiwindow-final/summary.json)、[完整 CI](evidence/2026-09-18-multiwindow-final/ci.log)、[性能结果](evidence/2026-09-18-multiwindow-final/fold-perf.json)、[打包记录](evidence/2026-09-18-multiwindow-final/delivery-build.log)、[多窗口自检](evidence/2026-09-18-multiwindow-final/multiwindow-final.log)、[最终复原](evidence/2026-09-18-multiwindow-final/final-restoration.json)。

证据目录：`docs/reviews/evidence/2026-09-18-multiwindow-final/`。其中保存生产装配 RED/GREEN、受控并发、迟到确认 RED/GREEN、按名称进程记录、双窗书签、确认归属、provider 回收/重启、退出快照、安装/偏好复原以及最终 CI 日志。原用户偏好备份不加入仓库。
