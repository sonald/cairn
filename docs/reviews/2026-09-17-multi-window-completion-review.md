# 多窗口功能完成度：独立复验

> 最终状态更新（2026-09-18）：本文为历史记录；原剩余验收项已补齐，W01–W20 全部通过。以[最终验收记录](2026-09-18-multi-window-final-acceptance.md)为准。

日期：2026-09-17。范围：当前 `90c6526` 之上的工作树，包含 F1–F8 修复。结论：**尚未全部完成，FAIL。完整 CI 通过，但仍有 4 个 P2 缺陷和若干验收覆盖缺口。**

后续更新：本页保留修复前验证结果。R1–R4 已随后修复，定向回归、972 项测试及完整 CI 通过，详见 [P2 修复与验证](2026-09-17-multi-window-p2-fixes.md)。未执行的其他 W01–W20 交互仍保留其原有覆盖边界。

本轮未修改产品代码。两个独立只读审查分别复核窗口生命周期与共享服务；主验证者执行完整 CI、补充 multiwindow 自检，并操作独立 release 测试包。

## 1. 剩余缺陷

### R1 · P2：清缓存后重启被自身维护状态拦截

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:11083–11100`。

`clearMaterializedCacheAppLevel` 用 defer 解除维护，但成功和失败分支都先调用 `restartExactAnalysis()`；同步进入 `prepareSupported` 后被仍为 true 的 `isUnderMaintenance` 拒绝。函数返回后才解除维护，没有再次重启。

**本轮真实 UI 已复现：**

1. alpha 和“第二个 项目”均显示 `Exact: ready · Safe (limited)`，Provider 为 rust-analyzer。
2. Settings → Exact → Clear Materialized Cache → Clear。
3. 设置提示 `Materialized cache cleared.`。
4. 回到项目，状态变为 `Exact: off (Safe)`，AX Help 为 `cache maintenance`。
5. 展开目录并打开 lib.rs，文件可读，但 Exact 仍未恢复。

临时用户目录已验证生效：session、index-cache 均位于 `/tmp/cairn-full-independent-20260917/home/Library/Application Support`；未清理生产用户缓存。

现有 F8 测试先手动解除维护再 prepare，没有走到生产入口的错误顺序。应先解除维护，再恢复分析；成功和失败路径都需要覆盖。

### R2 · P2：Settings 不刷新后来授予的信任

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:11023–11040,11124–11130`。

信任列表仅在 Settings 首次创建或撤销时刷新。若先打开/关闭 Settings，再对项目执行 Trust This Repository，授权成功只更新目标模型；重开同一个 Settings 控制器继续展示旧列表，无法从该列表撤销新授权。

证据：当前源码调用链确认；本轮未进行真实 UI 授权操作。应在授权成功后刷新共享列表，并在显示 Settings 时刷新。F4 的“禁止撤销期间 prepare”不解决列表刷新问题。

### R3 · P2：取消 A 后在同一欢迎窗打开 B，沿用 A 的布局存储键

位置：`Sources/CodeInsightApp/MainWindowController.swift:790–809`。

打开 A 时先设置项目 frame autosave 名称。取消后 `releaseProjectClaim()` 只清 projectURL，未重置 autosave 名；随后同窗打开 B 时，`adoptProjectFrameAutosave` 只接受空名或 `CodeInsightMainWindow`，因此拒绝切换已经属于 A 的名字。

影响：B 的窗口位置/尺寸写入 A 的 key。F1 的同目录取消重开测试不会发现跨目录复用问题。证据：代码路径确认；本轮未进行跨屏几何操作。应让释放认领和重新认领时的布局归属一致。

### R4 · P2：Settings 下项目菜单启用但点击无效

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:11430–11448`。

Show Bookmarks 和 Full/Structure/Overview 无条件返回 enabled；Settings 为 key window 时目标解析返回 nil，动作实际无目标。

**本轮真实 UI 已复现：** Settings 前台时 View 菜单的 Show Bookmarks、Full、Structure、Overview 可选，而 Toggle Bookmark 等正确禁用；点击 Show Bookmarks 后仍是 Settings，没有打开书签面板。应使菜单启用判断与目标解析一致。

## 2. 完整 CI 结果

本轮执行：

```bash
CODEX_SANDBOX=1 CAIRN_LIBGIT2=brew bash scripts/ci.sh
```

在正常 macOS 权限下运行，避免上一轮 NSScreen 和 sandbox-exec 的外层沙箱限制。终端最终退出码 **0**。

| 检查 | 本轮结果 |
|---|---|
| Swift Testing 主批次 | 963 PASS |
| 书签隔离批次 | 2 PASS |
| 面板隔离批次 | 2 PASS |
| 总计 | **967 PASS** |
| ReaderUI 引用、core imports、SwiftUI identity 检查 | PASS |
| CI 中 exact/diff/reading/projector/fold 自检 | PASS |
| corpora/fixture 校验、release 构建 | PASS |
| fold-perf | **PASS：259.735209ms，内存增量 19,972,144 bytes** |
| 额外 `--self-test-multiwindow` | PASS，退出码 0，`persistedSnapshots:2` |

证据：[CI 完整日志](evidence/2026-09-17-multiwindow-completion/ci.log)、[主测试日志](evidence/2026-09-17-multiwindow-completion/main-tests.log)、[书签隔离日志](evidence/2026-09-17-multiwindow-completion/isolated-tests.log)、[面板隔离日志](evidence/2026-09-17-multiwindow-completion/panel-tests.log)、[性能结果](evidence/2026-09-17-multiwindow-completion/fold-perf.json)、[multiwindow 自检](evidence/2026-09-17-multiwindow-completion/multiwindow-selftest.log)。

## 3. 真实应用补测

测试包 `/tmp/cairn-full-independent-20260917/Cairn.app`，bundle ID `dev.cairn.Cairn.fullverify20260917`。它使用本轮 CI release 对应的二进制，复用 bundle 资源并 ad-hoc 重签。复制前全文件哈希与 release 相同；重签后全文件哈希因签名而变化，机器码 `__text` 节哈希仍一致，见 [产物记录](evidence/2026-09-17-multiwindow-completion/artifact.json)。这不是生产安装替换或公证发布验收。

启动时指定 `CFFIXED_USER_HOME=/tmp/cairn-full-independent-20260917/home`，并检查实际 session/index-cache 创建位置，确认测试存储隔离有效。测试结束时通过正常 UI 退出并检查进程不存在。

| 场景 | 观察 | 判断 |
|---|---|---|
| 冷启动 alpha、热启动中文空格项目 | 各自语言选择、文件树和 Exact ready | PASS |
| 两项目同时打开 | Window 菜单分别列出，文件来源与项目标题一致 | PASS（已操作路径） |
| 清空缓存 | 清理成功后 Exact 停在 cache maintenance，打开文件仍未恢复 | FAIL，R1 |
| 保存失败时取消关闭 | 将测试 session 原文件备份，原位置放目录；点击关闭出现错误框，Cancel 后窗口和 lib.rs 保留 | PASS |
| 保存失败时取消退出 | Cancel 关闭后可切到 extra.rs；⌘Q 报错，Cancel Quit 后 extra.rs 与窗口保留 | PASS |
| 故障恢复 | 备份 SHA256 未变，删除空占位目录并恢复原文件；随后正常退出成功 | PASS |
| 退出/恢复 | B 活跃后切 A，⌘N 新空白窗，再正常 ⌘Q；无参数重启恢复 A | PASS（本轮序列） |
| 全局 Settings 下菜单 | Show Bookmarks 等启用，点击无效 | FAIL，R4 |
| 最后项目关闭、Settings 仍开着 | 切回唯一 alpha，⇧⌘W 后进程退出 | PASS |

保存失败测试只移动/恢复本轮临时 session；未修改源项目文件或生产数据。正常退出后的 session 快照保存在证据目录。

审查曾推测“新空白窗导致恢复错误项目”，本轮实际恢复 A，未复现该推测，因此**不列入缺陷**。不能用静态推演覆盖相反的运行证据。

## 4. W01–W20 完成度对照

以下“部分”表示有通过的证据，但尚未覆盖设计要求的全部路径；不是额外发现产品错误，也不是 PASS。

| ID | 本轮及现有证据 | 完成度 |
|---|---|---|
| W01 双项目独立状态 | multiwindow 自检 + 双窗 UI；未逐项人工遍历全部 history/compare 状态 | 基础通过，完整交互部分 |
| W02 重复、别名、加载中请求 | 路由测试与含取消/立即重开腿的自检通过 | 自动化通过；批量交错 UI 部分 |
| W03 切窗命令与菜单 enabled | 路由测试通过；全局窗口菜单存在 R4 | FAIL |
| W04 项目工具面板与输入 | 路由测试通过；未本轮逐一遍历所有文本编辑快捷键 | 部分 |
| W05 确认框后换窗/关窗 | 捕获原目标的源码路径；未真实授权确认后跨窗操作 | 部分 |
| W06 关一窗不影响另一窗 | 自检/生命周期测试通过；本轮补正常退出与最后窗进程检查 | 部分，未逐一量测双窗 provider 回收 |
| W07 准备/恢复中关闭 | 生命周期/等待测试通过；未固定全部迟到回调交错 | 部分 |
| W08 两项目保存与恢复 | 自检、会话文件、正常 ⌘Q 后无参启动恢复 A | 本轮正常路径 PASS；失败回退部分 |
| W09 Settings 开着关最后项目 | 真实窗口关闭及进程退出 | PASS |
| W10 共享书签 | 交错写入、全局上限、观察者测试通过 | 自动化 PASS；双窗备注完整 UI 部分 |
| W11 dirty 书签重试 | 修订测试使用原 store/原路径，检查 dirty/error 与通知 | 自动化 PASS |
| W12 信任/prepare 交错 | registry 共享与挂起测试通过；Settings 列表有 R2；真实交错证明不足 | FAIL / 覆盖未完成 |
| W13 共享缓存引用 | 双引用、关闭释放、占用时拒绝 clear 测试通过 | 自动化 PASS |
| W14 配额与失败引用回滚 | 小配额与权限失败测试通过 | 自动化 PASS |
| W15 多项目清缓存并恢复 | 维护暂停测试通过；生产重启顺序 R1 真实失败 | FAIL |
| W16 冷启动目录 | 隔离 `.app` 绝对路径打开通过；按名称投递未做 | 部分 |
| W17 热启动第二项目 | 真实 UI 打开中文目录第二窗 | 已测路径 PASS |
| W18 多目录/重复/错误混合 | 自检覆盖部分；本轮未完整复跑一批含无效项请求 | 部分 |
| W19 路径形式与非法输入 | identity 测试通过；本轮中文空格路径通过 | 自动化通过，完整系统入口部分 |
| W20 保存失败与取消 | 本轮真实关闭/退出错误框均点 Cancel，窗口可继续操作且备份未变；skip/retry 有单测 | 取消路径 PASS；全部按钮 UI 部分 |

另外，项目 frame autosave 的跨取消归属存在 R3，不应把 F6 标为全面完成。

## 5. 验收测试中的缺口

`Tests/CodeInsightAppModelTests/MultiWindowSharingTests.swift:444`：

```swift
#expect(!coordinator.prepareIsSuspended(for: fixture.root) || true)
```

这是恒真断言，不能证明撤销结束后挂起已解除。该测试主要通过手动 suspend/resume 检查入口，尚未把真实 revoke 与阻塞 provider 的交错跑通。应移除 `|| true`，并验证生产异步调用顺序；单纯增加测试数量不能补上此缺口。

本轮未向 `/Applications` 的生产 Cairn 安装投递测试目录或替换应用，因此 `open -a Cairn` 的名称解析仍未作为已验证项。使用绝对包路径成功不能代替这一条。

## 6. 判定

F1/F2/F3/F5 的主修复路径、共享书签 dirty 重试及 F7 引用回滚均有当前通过证据；此前 fold-perf 环境阻塞也已消除。**完整 CI 通过与“全部产品功能完成”仍是两回事。**

修正 R1–R4，并补齐表中需要真实交互/异步交错的关键项后，才能把多窗口功能标为完整验收。尤其需要直接测试应用级清缓存入口与 Settings 信任刷新，避免再次只测内部 helper 的正确顺序。
