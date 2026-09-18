# 多窗口功能独立验证

日期：2026-09-17。对象：`90c6526` 之上的未提交工作树。

结论：**FAIL，需修正后重新验收。** 基本多项目窗口可运行，但取消打开、关闭生命周期和保存失败分支不满足设计；信任撤销还有未阻止新 prepare 的交错风险。原验收记录不能作为完整通过依据。

本次没有修复或提交产品代码，只增加本报告和证据文件。独立源码审查分别覆盖窗口生命周期、共享存储与 Exact；主验证者重新构建、运行测试并操作隔离 `.app`。

## 1. 发现

### F1 · P1：取消语言选择后，再次打开该项目不会加载

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:10596,10621–10627`；`MainWindowController.swift:796`。

打开管线先 `claimProject(identity)`，取消时却要求 `isUnclaimedForReuse` 才关闭；该条件要求 `projectURL == nil`，因此不可能成立。再次请求命中已认领窗口后只激活并返回。

**已通过真实 UI 复现：**

1. 测试应用已有 alpha 窗口。
2. `open -a /tmp/cairn-mw-independent-20260917/Cairn.app /tmp/cairn-mw-independent-20260917/cancel-project`。
3. Choose Languages 中点击 Cancel。
4. 窗口仍显示 `cancel-project — Cairn`，内容是欢迎页，工具栏 Project 值为 Cairn。
5. 再次执行相同命令，AX 树没有变化，未显示语言框或文件树。

应在取消时解除此次项目认领，并按合同关闭自动创建的窗口、保留原有空白窗口。

### F2 · P1：关闭窗口立即从集合移除，退出不等待其清理

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:10178–10195`；`MainWindowController.swift:2049–2064`。

`windowWillClose` 同步通知 AppDelegate；AppDelegate 立即移除控制器，最后项目窗口关闭时发起 terminate。之后控制器才创建 `closeProject()` Task。退出路径捕获的 `projectWindows` 已为空，可以直接答复终止，没有等待刚关闭窗口的 prepare/provider 收尾。

同一问题使 `openProjectIdentity` 中 `existing.isClosing → waitForCloseCompletion` 分支无法找到正常关窗中的控制器。关闭 A 后立刻重开 A，可在旧 A 清理结束前创建新模型。

证据：确定性调用顺序审查。未通过故障调度运行证明子进程实际遗留，因此不将“遗漏等待”扩大成“已观察到孤儿进程”。正常 Quit 的成功退出不覆盖此分支。应保留关闭中控制器及完成任务，收尾完成后再释放项目认领；退出同时等待这些任务。

### F3 · P1：一个窗口保存失败时，继续退出跳过其他窗口最终保存

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:779–808`。

逐窗保存遇到第一个错误就中断；选择 Quit Without Saving 又退出整个保存循环。排列在失败窗口之后的窗口没有最终 checkpoint，随后 `closeProject()` 会清空模型并取消自动保存。WillTerminate 无法重新采集已经丢弃的 reader/model 状态。

触发：A 保存失败，B 有未完成最终采集的阅读变化，退出时对 A 选择继续退出。影响不仅限于用户批准不保存的 A。

证据：代码分支确认，未进行真实保存故障对话框测试。应按窗口处理失败；跳过 A 后仍保存 B，取消退出则保留所有窗口。

### F4 · P1：撤销信任等待期间仍可启动新的 trusted prepare

位置：`Sources/CodeInsightAppModel/ExactCoordinator.swift:702–725`；`AppModel.swift:1898–1905,1918–1942`。

撤销只使已有工作失效，随后等待 close，再修改 registry；等待期间没有禁止 prepare。切换 feature/commit 可推进 generation，新 prepare 读取尚未撤销的 trusted 记录。registry 更新后仅刷新列表；generation 已变化又会跳过 AppModel 的 Safe 重建，旧权限 prepare 因而没有被这次撤销再次失效化。

证据：源码交错分析，**未通过可控调度测试复现**。现有 W12 测试没有活跃/准备中的 provider，不能排除此路径。应从撤销开始暂停受影响项目的 prepare，停止旧工作并完成 registry 更新后再放行。

### F5 · P2：显式 Open Python / TypeScript 丢失语言选择

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:10612–10629`。

`context.languages` 只在已有窗口或有效 snapshot 分支使用。无 session 时，有 Recents 就使用旧语言；首次打开则使用 picker 结果。

**已通过真实 UI 复现：** File → Open Python Project… → 选择无 session 的 cancel-project，出现 Choose Languages，Rust=1、Python=0。点击 Open 后窗口显示 `Provider: rust-analyzer` 和 `Exact: ready · Safe (limited)`。

应在无 snapshot 的分支优先使用显式 languages，不能由 Recents 或探测结果覆盖。

### F6 · P2：项目窗口未切换到独立 frame autosave 名称

位置：`Sources/CodeInsightApp/MainWindowController.swift:780–790`，初始化处 `:411–415`。

新窗口先设 `CodeInsightMainWindow`，`adoptProjectFrameAutosave` 又要求当前名字为空才切换，因此经打开管线认领的项目窗口继续共用空白窗口名字。启动恢复路径可以另行设置项目名字，不能证明新开的窗口也正确。

证据：代码条件确认，未做跨屏几何复现。应允许从空白默认名切换到项目名。

### F7 · P2：物化失败遗留引用，之后无法清空缓存

位置：`Sources/CodeInsightExact/Materializer.swift:70–71,117–118`。

代码先 `retainLocked`，再调用可能抛错的 `enforceQuota`。扫描旧缓存或淘汰失败时，调用者没拿到返回 URL，无法释放新增引用。

**隔离确定性复现通过：** 将旧缓存目录权限设为 000；新物化完成后 quota 扫描抛 EACCES；恢复权限后 `retainedDirectoryCount` 仍为 1，`clear()` 仍抛 `directoriesInUse`。

复现程序保留当前 Materializer 实现，以小型桩替代项目 Snapshot/错误类型；这是资源管理单元级复现，不是完整 app 测试。见 [源文件](evidence/2026-09-17-multiwindow/materializer-failure-probe.swift) 与 [实际输出](evidence/2026-09-17-multiwindow/materializer-failure.log)。应在仍持锁的 quota 成功路径登记引用，或在错误时撤销新增引用。

### F8 · P2：全局清缓存期间没有暂停新 prepare

位置：`Sources/CodeInsightApp/CodeInsightApp.swift:10928–10945`。

操作先快照当前 coordinators，再逐个等待停止。等待 B 期间，已停止的 A 或新窗口可以启动分析。新历史分析持有引用后，clear 会以 directoriesInUse 失败；worktree 分析则可能根本没有停止。

证据：源码交错分析，未做并发运行复现。引用保护仍可防止直接误删，不应将此问题描述为已发生数据损坏。应增加覆盖已有与新窗口的应用级维护状态，清理成功或失败后统一解除。

## 2. 独立执行记录

### 构建与产物

- 命令：`CODEX_SANDBOX=1 CAIRN_LIBGIT2=brew bash scripts/ci.sh`。
- 当前工作树 debug 构建完成；有已有编译警告。
- UI 测试包：`/tmp/cairn-mw-independent-20260917/Cairn.app`。
- 使用刚构建的 debug executable，复用已有 bundle 的资源/Frameworks 布局，修改隔离 bundle ID 后 ad-hoc 重签；不是 release 打包脚本的完整重跑。
- bundle ID：`dev.cairn.Cairn.independent20260917`。`plutil -lint`、`codesign --verify --strict` 成功。
- 构建产物与测试包可执行文件 SHA256 相同，见 [artifact.json](evidence/2026-09-17-multiwindow/artifact.json)。
- 测试项目与书签/session 均使用本次独立路径；未修改生产 Cairn 的偏好或数据。全局 Exact 仍使用产品默认缓存/信任入口，本次没有授予信任、撤销信任或清空用户缓存。

### 测试状态

| 检查 | 结果 | 边界 |
|---|---|---|
| 当前工作树 debug 构建 | PASS | 本次新编译产物用于 UI 验证 |
| CI 主批次 956 项 | 初跑 955 通过、1 失败 | 唯一失败为 `projectSearchPanelFitsVisibleOwnerAndLeavesAnUnclippedEmptyState` 的 `NSScreen.main`；部分真实 sandbox/provider 测试内部报告 SKIP，不能等同已执行 |
| 单项正常权限复验 | PASS，1 项，退出码 0 | `NSScreen.main` 失败在正常权限下消失，不能据初跑错误断言产品回归 |
| 多窗口定向复跑 | PASS，11 项，退出码 0 | 3 个 routing + 8 个 sharing；覆盖缺口见下文 |
| `scripts/ci.sh` 整体 | INCOMPLETE，原运行退出码 1 | 主批次失败后脚本停止，剩余 4 个隔离测试及后续自检/release/perf 门未执行；没有宣称全量 960 或完整 CI 通过 |
| `git diff --check` | PASS | 不代表功能正确 |

见 [汇总](evidence/2026-09-17-multiwindow/test-summary.txt)、[主批次完整日志](evidence/2026-09-17-multiwindow/ci-main.log)、[定向日志](evidence/2026-09-17-multiwindow/focused-tests.log)、[正常权限单项复验](evidence/2026-09-17-multiwindow/screen-retry.log)。定向命令首次因模块缓存路径越过沙箱失败，在显式使用项目内缓存后成功；首次失败不计入测试通过数量。

已有 `pythonHugeDocumentHighlightProbe` 导致 ReaderCore 批次耗时约 341 秒，采样显示仍在折叠候选计算；它最终完成，不是死锁。未为这次多窗口验证修改或优化该测试。

独立执行 `--self-test-multiwindow`：退出码 0，`passed:true`，`persistedSnapshots:2`。见 [日志](evidence/2026-09-17-multiwindow/multiwindow-selftest.log)。该测试预写语言记录、跳过真实选择框，并且离屏关闭跳过生产异步清理，故不能否定 F1/F2/F5。

### 真实 UI 与系统入口

通过 CUA 读取真实 AX 树并点击操作，使用 `open -a <测试包绝对路径> <目录>` 发送请求。沙箱内 open 首次返回 Launch Services -10827；通过批准的正常权限调用成功，不将此环境限制算产品故障。

| 场景 | 本次观察 | 判断 |
|---|---|---|
| 热启动打开第二个项目 | Window 菜单同时列出 alpha 与“第二个 项目”；两窗均 ready | PASS（基础双窗） |
| 中文、空格路径 | “第二个 项目”正确加载 | PASS |
| 阅读状态隔离 | A 已打开 lib.rs；首次 B 显示 No file open；返回 A 仍显示 `pub fn alpha()` | PASS（已测路径） |
| 切回 A 后 ⌘F | A 的 Find in file 出现、取得焦点，原文件不变 | PASS（一个路由场景） |
| 项目书签面板 | ⌥⌘B 显示 Bookmarks，过滤输入获得焦点 | PASS（面板打开）；未覆盖全部面板快捷键 |
| 取消首次打开再重开 | 标题认领目录但停留欢迎页，再次命令无变化 | FAIL，F1 |
| Open Python Project | Rust 默认选中，最终运行 rust-analyzer | FAIL，F5 |
| 正常 ⌘Q | 应用及本次 rust-analyzer 子进程退出，A/B 会话文件存在 | PASS（正常退出） |
| 冷启动显式打开 A | 恢复 A 的 lib.rs，Window 菜单仅 A | PASS（已存会话路径） |
| 保存失败、取消退出、继续退出 | 本次没有 UI 故障注入；代码存在 F3 | 未完成，不能 PASS |
| 按名称 `open -a Cairn` | 未向本机生产安装投递测试目录 | SKIP；按绝对包路径不替代名称解析验收 |
| release 打包、vendored libgit2 | 本次 UI 使用新 debug 测试包 | SKIP |

正常退出后的项目会话内容见 [sessions.json](evidence/2026-09-17-multiwindow/sessions.json)。这些只证明本次正常路径，不能证明失败分支及全部 Reader 锚点恢复。

## 3. 原验收证据需要修正的表述

- W02 自检只覆盖预写语言记录后的重复请求，没有覆盖取消后重开；本次实际 FAIL。
- W03/W04 的目标解析测试不是完整真实键盘、焦点、文本编辑验收。本次补了部分正常路径，仍不能宣称全部通过。
- W06/W07 的 offscreen self-test 明确跳过异步 `closeProject`，模型测试不能代替最后窗口的应用级退出链路。
- W08 使用 SIGTERM 退出不证明 `applicationShouldTerminate` 的批准、保存失败和异步等待流程；本次补了正常 ⌘Q，但失败路径仍需测。
- W11 测试“修复后”新建另一个 SharedBookmarkStore，并写另一个路径，而不是让原 dirty store 在原路径重试成功；没有证明 dirty/error 清除和双窗通知。
- W12 仅验证 registry 共享，没有运行中的 trusted provider，不能证明撤销信任安全。
- W15 的“PASS（代码路径）”缺少暂停新 prepare，实际代码也不满足设计。
- W20 的 GUI 故障分支未走查，不能仅因有三选按钮就给 PASS。

## 4. 重新验收要求

优先处理 F1–F4，再处理 F5–F8。添加能失败的行为验证：取消后重开、关闭后立刻重开及最后窗等待、A 保存失败但 B 正常保存、revoke/prepare 交错、物化 quota 失败回滚引用。

之后复跑完整 CI 和打包 `.app` 场景。沿用独立证据分层：代码审查、模型测试、AppKit 交互、Launch Services、进程退出分别标注；不得以其中一层替代其他层。未经再次验证，不修改原验收记录为“全部通过”。
