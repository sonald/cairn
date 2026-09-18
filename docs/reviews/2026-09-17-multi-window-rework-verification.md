# 多窗口功能——评审修复与再验证记录

> 最终状态更新（2026-09-18）：本文为历史记录；原剩余验收项已补齐，W01–W20 全部通过。以[最终验收记录](2026-09-18-multi-window-final-acceptance.md)为准。

日期：2026-09-17。对象：`90c6526` 之上的工作树（本记录随修复一并交付）。
上游评审：[2026-09-17 多窗口功能独立验证](2026-09-17-multi-window-independent-verification.md)（结论 FAIL，F1–F8）。
本文回答评审 §4 的重新验收要求：每条发现给出修复点、可失败的行为验证、以及**分层**证据（代码审查 / 模型测试 / AppKit 交互 / Launch Services / 进程退出），不以其中一层替代其他层。

## 1. 逐项处置

### F1（P1）取消语言选择后再次打开不加载

**修复**：打开管线在取消分支调用 `destination.releaseProjectClaim()`（`MainWindowController.releaseProjectClaim`，要求未在关闭中）后再决定是否关闭自动创建的窗口；重复请求因此能重新认领并加载，而不是激活一个永远不会加载的僵尸认领。

**行为验证**：
- 模型/控制器层：`CodeInsightAppTests.cancelledFirstOpenReleasesClaimAndRepeatRequestLoads`——取消后断言 `isUnclaimedForReuse`、`projectURL == nil`；随后再次请求断言项目进入 ready 且窗口数仍为 1。该测试在修复前失败（曾实际复现：取消后重复命令无任何变化）。
- AppKit 交互层（真实 UI，CUA + AX）：`open -a <app> /tmp/cairn-mw-accept/cancel-project` → Choose Languages → Cancel → 窗口标题回到 `Cairn`、显示欢迎页、工具栏 `Project = Cairn`（旧缺陷会停留在 `cancel-project — Cairn`）；重复同一命令 → 选择框再次出现；Open → 标题变为 `cancel-project — Cairn`、文件树加载 `src/`、`Cargo.toml`。
- 自检层：`--self-test-multiwindow` 增加“取消后重开”腿（取消 → 集合收敛回既有窗口 → 重复请求加载 C 项目）。

### F2（P1）关闭窗口立即移出集合，退出不等待其清理

**修复**：`windowWillClose` 走统一的 `beginTeardown`：控制器在**异步收尾完成前**保留在 `projectWindows` 中并保持项目认领（`isClosing` 让路由与退出判定跳过它）；收尾由控制器自己的 `teardownTask` 完成，完成后回调 `onProjectWindowClosed` 才从集合移除并释放认领。`applicationShouldTerminate` 对**全部**窗口（含正在关闭的）`await teardownCompletion()` 后才回复终止。退出判定改为 `projectWindows.allSatisfy(\.isClosing)`。

**行为验证**：
- `closedWindowReleasesClaimOnlyAfterTeardownFinishes`——`performClose` 后立即断言 `isClosing == true` 且 `projectURL != nil`（修复前认领已丢），等待集合归零后断言 `projectURL == nil`。
- 自检腿：关闭 B 后**立即**重新请求 B，断言最终恰有一个 B 窗口、与旧会话写入者串行（修复前 `waitForCloseCompletion` 分支不可达，因为控制器已被移除）。
- 进程层：修复后正常 ⌘Q 退出，应用与子进程退出，两份按项目会话文件写出（§3.3）。

### F3（P1）一个窗口保存失败时继续退出会跳过其他窗口的最终保存

**修复**：`finalizeQuitSaves(prompt:)` 按窗口处理失败——`retry` 重跑该窗口、`skipWindow` 只把该窗口加入跳过集并**继续保存其余窗口**、`cancelQuit` 中止退出且不销毁任何窗口；已在关闭中的窗口不重复询问（其批准阶段已完成）。对话框返回的三种决定由应用层映射，测试可注入脚本化决定。

**行为验证**：`quitSavesRemainingWindowsWhenOneWindowFails`——A 的会话文件路径被目录占位（写入必失败），脚本化决定为 `skipWindow`；断言 B 的最终快照落到磁盘且内容含 B 的项目根、A 的占位目录未被改写、然后 `cancelQuit` 返回 false 且两窗都未进入关闭态。修复前该测试失败（B 无最终保存）。

### F4（P1）撤销信任等待期间仍可启动新的 trusted prepare

**修复**：`ExactCoordinator.revokeTrust` 第一步就把该仓库加入 `suspendedPrepares`（`defer` 解除），并同时挂起该项目的 prepare：`prepareSupported` 在入口检查 `suspendedPrepares`（命中即 `invalidate` + `readiness = .off("trust revoking")` 且**不启动任何 provider**）。`AppModel.revokeRepositoryTrust` 改为在撤销完成后按**当前** generation 重建 Safe（feature/commit 切换在等待期间被拒绝，故必须由这次调用重启），不再因 generation 变化而跳过。

**行为验证**：`suspendedPrepareIsRefusedUntilTheSuspensionLifts`——挂起期间调用 prepare 断言 `readiness == .off("trust revoking")` 且 `state.prepareCount == 0`（无 provider 启动）；解除后同一 generation 流程可正常 ready；`revokeTrust` 结束后断言挂起已清除（`prepareIsSuspended == false`）。

### F5（P2）显式 Open Python / TypeScript 丢失语言选择

**修复**：`openProjectIdentity` 把显式语言分支提到语言解析顺序最前：有 `context.languages` 时直接 `openProject(root:languages:)`，不再经过会话/Recents/picker。

**行为验证**：
- `explicitLanguageChoiceBeatsRecentsAndProbeOnFirstOpen`——Recents 预写 rust、picker 被替换为会报错的桩（若被调用即失败），显式 `.python` 请求后断言 `projectLanguages == [.python]` 且 `lastOpenedProjectLanguage == .python`。
- AppKit 交互层（真实 UI）：File → Open Python Project… → 面板进入 `cairn-f5-python-project`（含 `Cargo.toml`、`src/lib.rs` 与 `main.py`，探测会预选 Rust）→ Open。观察：**未出现 Choose Languages 对话框**（修复前必现），欢迎窗口直接变为 `cairn-f5-python-project — Cairn`；工具栏 Profile 显示 `Python · cairn-f5-python-…`；正常退出后该项目的会话快照记录 `languages: [1]`（`LanguageID.python = 1`）。UI 与落盘两层一致指向 Python。

### F6（P2）项目窗口未切换独立 frame autosave 名称

**修复**：`adoptProjectFrameAutosave` 允许从空白窗口默认名 `CodeInsightMainWindow` 切换到项目名，仅当当前名已是别的项目名时保持不变。

**验证层级**：代码路径 + 既有的窗口认领测试（`windowClaimAndCloseRetireAWindowFromReuse` 覆盖认领与关闭）；跨屏几何未做人工复现，与评审同层级（评审亦未做）。缺口如实标注。

### F7（P2）物化失败遗留引用，之后无法清空缓存

**修复**：`materializeAndRetain` 在 `enforceQuota` 抛错时回滚刚登记的引用（`releaseLocked`），使调用者未拿到 URL 的失败路径不再留下永久引用。

**行为验证**：`materializerQuotaFailureRollsBackTheNewReference`——旧缓存目录权限置 000 使其在配额扫描中抛 EACCES，随后 `materializeAndRetain` 抛错；断言 `retainedDirectoryCount == 0`，恢复权限后 `clear()` 成功（修复前该测试失败：留存引用导致 `clear()` 抛 `directoriesInUse`）。

**顺带修复的既有缺陷**：配额扫描用目录枚举 URL 与 `current` 直接比较，而枚举 URL 带尾斜杠，导致“保留当前目录”失效、刚写入的目录可能被自我淘汰（修复前的探针复现）。现改为规范化键比较。

### F8（P2）全局清缓存期间没有暂停新 prepare

**修复**：`Materializer` 增加维护态（`beginMaintenance`/`endMaintenance`/`isUnderMaintenance`），`ExactCoordinator.prepareSupported` 在维护期间拒绝新 prepare（`readiness = .off("cache maintenance")`）。应用级清缓存用 `defer` 让维护态覆盖整个操作（停止 → 删除 → 失败或成功都统一解除），因此等待 B 期间 A 或新窗口都无法启动新分析。

**行为验证**：`cacheMaintenanceHaltsPreparesAcrossSharedCoordinators`——两个共享同一 materializer 的协调器，维护期间 prepare 均被拒绝且 `state.prepareCount == 0`；解除后同一协调器可正常 ready。

## 2. 测试与 CI

新增/修改测试：

| 测试 | 覆盖 |
|---|---|
| `CodeInsightAppTests/MultiWindowLifecycleTests.swift`（新，4 个） | F1 取消后重开、F5 显式语言优先、F2 关闭后认领保留、F3 退出按窗口保存 |
| `CodeInsightAppModelTests/MultiWindowSharingTests.swift`（+3 个，W11 重写） | F4 prepare 挂起、F7 引用回滚、F8 维护态；W11 改为**原 dirty store 在原路径重试成功**并断言 dirty/error 清除与双窗通知 |
| `Tests/CodeInsightAppTests/...`（既有） | 无回归 |

CI（`scripts/ci.sh`，主批次计数 956 → 963）：

- swifttest：主批次 **963 PASS**，隔离批次 2 PASS，面板批次 2 PASS，合计 967。
- 应用自检通道：`--self-test-multiwindow`（含 F1/F2 新腿）PASS；exact/history/diff/reading 等通道在改动后逐一复验通过。
- 最终完整 `scripts/ci.sh`（冻结树）：swifttest 967 **PASS**（主 963 / 隔离 2 / 面板 2）、ReaderUI 引用禁令 PASS、core 目标无 AppKit/SwiftUI PASS、SwiftUI 稳定 identity 禁令 PASS、自检通道（exact/diff/reading/projector/fold）PASS、corpora 校验 PASS、release 构建 PASS。
- **fold-perf 门：FAIL（环境受阻，非代码回归）**。当日机器负载 13–20（Chrome 多进程各占 ~100% CPU，为用户活动应用，未干预），`foldLatencyMs` 实测 506–688ms（末次 528ms），超过 400ms 门限；**同一负载下用纯净 `90c6526` 代码构建的 release 二进制在同一门限下同样失败（528ms）**；而昨日同代码在负载正常时通过（258–266ms）。本次修复未改动 reader/folding 代码（`git diff -- CodeInsightReaderUI CodeInsightReaderCore` 为空），fold-perf 亦不经过 AppDelegate/窗口路径。判定为环境阻塞；**需在机器空闲时重跑该门限以完成 CI 全绿**，在此之前不宣称 CI 完整通过。

## 3. 打包 `.app` 再验证（Launch Services + 进程层）

产物：`CAIRN_LIBGIT2=brew CAIRN_BUNDLE_IDENTIFIER=dev.cairn.Cairn.mwtest CAIRN_VERSION=0.2.mwtest scripts/make-app.sh`（修复后重新打包；`plutil -lint` 与 `codesign --verify --strict` 通过）。

| 场景 | 操作 | 结果 | 层 |
|---|---|---|---|
| W16 冷启动 | `open -a /abs/Cairn.app /abs/project-a` | 新 PID；一个主窗口 + 首次语言选择框（设计 §3.3 预期）；确认后项目加载 | Launch Services |
| W17 热启动 | `open -a /abs/Cairn.app "/abs/第二个 项目"` | 同 PID；第二个主窗口（级联 +28pt）+ 其首次选择框 | Launch Services |
| W18 别名去重 | 同批 `alias-to-a` + `project-a` | 仍恰 2 个主窗口 | Launch Services |
| W19 相对/尾斜杠 | `cd /tmp/cairn-mw-accept && open -a <abs> ./alias-to-a "./第二个 项目/."` | 仍恰 2 个主窗口，归一到既有窗口 | Launch Services |
| 正常 ⌘Q 退出 | CUA 发送 ⌘Q | 应用与子进程退出；`sessions/` 下两份按项目快照（`projectRoot` 正确，`languages` 与各项目选择一致） | 进程退出 + 持久化 |
| F1 真实 UI | 见 §1 F1 | 取消 → 认领释放；重开 → 正常加载 | AppKit 交互 |
| F5 真实 UI | 见 §1 F5 | 无选择框；Profile=Python；快照 `languages=[1]` | AppKit 交互 + 持久化 |
| 按名称 `open -a Cairn` | 未向本机生产安装投递测试目录 | SKIP（同评审：名称解析由生产安装占用；按绝对包路径覆盖同一 `application(_:open:)` 代码路径） | — |

## 4. 仍未覆盖 / 未重验的边界（诚实清单）

- **fold-perf 门**：本记录初次验收时未通过；随后独立诊断已确认独立无头 agent-browser 实例的负载影响，结束该实例后原门限连续三次 PASS（256/261/297ms）。详见 [根因与处理记录](2026-09-17-fold-perf-root-cause.md)。§2 的“用户活动应用”归属判断由该记录纠正；此项已单独重验完成，不代表重新跑过整个 CI。
- **W03/W04/W05/W20 的完整 GUI 走查**：本次补了 F1/F5 两条真实交互路径与路由单测/面板 owner 测试；真实键盘焦点遍历、信任确认后切换窗口、保存失败对话框的按钮点击仍未人工走查（与评审一致，不宣称通过）。
- **W08 的失败分支**：正常 ⌘Q 已验证；`applicationShouldTerminate` 的失败对话框分支由 `finalizeQuitSaves` 的单测覆盖（脚本化决定），未做真实故障对话框点击。
- **F6 跨屏几何**：未人工复现（同评审层级）。
- `open -n` 多进程并发（设计明确不在首版范围）未测试。

## 5. 原验收记录的修正说明

[2026-09-16 验收记录](../plans/2026-09-16-multi-window-projects-acceptance.md) 已按评审 §3 修正表述：明确 W02/W06/W07 的自检与模型证据不构成应用级退出链路证明，W08 的 SIGTERM 不证明 `applicationShouldTerminate` 的批准/失败/等待流程，W11/W12/W15 按各自实际覆盖范围重述，W03/W04/W20 标注为逻辑自动化覆盖而非完整真实 GUI 验收。该记录不再宣称“全部通过”，并指向本记录作为修复后的再验证依据。
