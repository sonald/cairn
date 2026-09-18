# Cairn 多窗口、多项目与目录打开——实现与验收记录

> 最终状态更新（2026-09-18）：本文为历史记录；原剩余验收项已补齐，W01–W20 全部通过。以[最终验收记录](../reviews/2026-09-18-multi-window-final-acceptance.md)为准。

> **2026-09-17 状态修正**：独立验证（[评审报告](../reviews/2026-09-17-multi-window-independent-verification.md)）判定本记录不足以作为完整通过依据（F1–F8，其中 F1–F4 为 P1）。全部发现已修复并重新验证，修复后的分层证据见 [修复与再验证记录](../reviews/2026-09-17-multi-window-rework-verification.md)。**本文档不再宣称“全部通过”**；下列各条按评审 §3 修正为实际覆盖范围，凡标注“逻辑自动化覆盖”者不等于真实 GUI 走查。

日期：2026-09-16。设计方案：`docs/plans/2026-09-16-multi-window-projects-design.md`（下称“设计”）。
实现基线：`90c6526` 之上的单提交工作树（本文档随实现一并交付）。修复后的计数与再验证结果以修复记录为准（swifttest 主批次 963）。

## 1. 交付摘要

- **窗口集合与项目路由（S1）**：AppDelegate 以 `projectWindows: [MainWindowController]`、`lastActiveProjectWindow`、`activeWindowOrder` 管理窗口；每窗口独立 AppModel，经 `makeWindowWithModel`/`registerProjectWindow` 统一装配（生产与测试同一装配路径）。`projectCommandTarget()` 按 §6.1 解析 key window → 面板 owner → main window，全局窗口（Settings/About）禁用项目命令不回退；应用非活动时的程序化派发回退到最近活动项目窗口（真实键盘输入不受影响）。菜单 action 与 `validateMenuItem` 使用同一目标。
- **打开合同（§3.1/§3.2/§3.3）**：`enqueueOpenRequest`/`drainOpenRequests` 串行管线；`projectIdentity` 只接受 file URL、真实目录，`resolvingSymlinksInPath().standardizedFileURL` 归一身份；重复/别名/尾斜杠/`.`/`..` 激活既有窗口；空白窗口复用顺序为 来源窗口 → 活动空白 → 任意空白 → 新建；语言选择顺序为 显式选择 → 已存会话 → Recents 记录 → 一次性选择框（对话框状态为 `LanguageSelectionGate` 局部状态）；取消选择时仅自动创建的窗口关闭。
- **菜单与窗口（§6.3/§6.4）**：File → New Window（⌘N）、Close Window（⇧⌘W）；⌘W 无标签时关闭窗口；系统 Window 菜单（`NSApplication.windowsMenu`）；标题 `project — Cairn`（同名项目用父路径区分）；项目窗口 frame autosave 按 `sessionProjectKey` 派生，空白窗口保留 `CodeInsightMainWindow`，新窗级联 +28pt 并限制在可视区。
- **关闭与退出（S2，§7）**：`windowShouldClose` 在批准阶段执行最终 checkpoint，失败提供 重试/不保存关闭/取消；`windowWillClose` 幂等收尾（采集、面板关闭、恢复任务取消、Esc 监听移除），生产窗口继续异步 `AppModel.closeProject()`（取消全部任务、generation+1、等待 `ExactCoordinator.shutdownAndWait()`）；`applicationShouldTerminate` 阻止新打开、逐窗保存、失败可取消退出，异步收尾后 `reply`；`applicationShouldTerminateAfterLastWindowClosed` 以项目窗口集合判定，最后项目窗口关闭（Settings 开着）也走终止路径；关闭中的窗口仍认领项目，重复请求 `waitForCloseCompletion()` 后再开。
- **恢复指针（§7.3）**：AppModel 移除对 `lastSessionProjectPath` 的隐式写入，改为 `onSessionCheckpointWritten` 回调；AppDelegate 记录 `persistedProjects`，按最近活动且成功持久化的项目更新指针（背景 checkpoint 本身不动指针）。
- **共享数据（S3，§8.1/§8.2/§8.3）**：新增 `SharedBookmarkStore`（MainActor 单一 records/dirty/rescue 权威，读改写无 await，观察者通知各窗口刷新），`BookmarkModel` 保留每窗口跳转/attempt 状态；AppDelegate 创建唯一 `TrustRegistry` 与 `Materializer` 注入所有窗口的 ExactCoordinator；`Materializer` 增加 `materializeAndRetain`/`retain`/`release` 引用计数（锁内登记、quota 只淘汰零引用、`clear()` 遇占用抛 `directoriesInUse`）；ExactCoordinator 在 prepare 失败/取消/过期/invalidate/shutdown 各路径释放引用；应用级撤销信任先停受影响项目，应用级清缓存先停全部 prepare/provider。
- **Settings 解绑（§6.4/§8.4）**：`ReaderSettingsWindowController` 改为 `TrustListModel` + 应用级 `onRevoke`/`onClearCache` 闭包，不再绑定某个项目 coordinator；保留单 coordinator 便捷 init 供既有测试。
- **Launch Services（S4，§5）**：`application(_:open:)` 队列 + `applicationWillFinishLaunching`（菜单/外观先就绪、不自动开项目）；didFinish 优先处理显式请求，全部失败/取消保留一个欢迎窗；`make-app.sh` 的 Info.plist 增加 CFBundleDocumentTypes（public.folder / Viewer / Alternate）。
- **产品说明**：README 增加 “Multiple Projects and Windows” 一节。

## 2. 自动化证据

### 2.1 swift-testing（scripts/ci.sh 全量通过，`CI_EXIT=0`）

- 主批次 956（= 基线 945 + 新增 11），隔离批次 2，面板批次 2，合计 960。
- 新增 `CodeInsightAppModelTests/MultiWindowSharingTests.swift`（8 个）：
  - W10：`sharedBookmarkStoreInterleavesTwoWindowsWithoutLosingUpdates`（交错增删改、全局 32 上限、磁盘一致）、`sharedBookmarkStoreNotifiesBothWindows`（跨窗口观察者）。
  - W11：`sharedBookmarkStoreRetainsDirtyTableForRetryAcrossWindows`（写失败保留最新脏表，修复后重试落盘两窗更新）。
  - W13：`materializerReferenceCountProtectsSharedDirectory`（双引用、单释放仍保护、占用时 clear 拒绝、幂等释放）。
  - W14：`materializerQuotaEvictsOnlyUnreferencedDirectories`（小配额下仅回收零引用目录，释放后可回收）。
  - W12：`sharedTrustRegistryServesTwoCoordinators`（共享 registry 的 grant/revoke 两协调器一致）。
  - W06/W07：`appModelCloseProjectResetsStateAndStopsExact`（状态清空、任务取消、幂等）、`coordinatorShutdownAndWaitReleasesMaterializedDirectory`（可等待关闭并释放引用，数据保留）。
- 新增 `CodeInsightAppTests/MultiWindowRoutingTests.swift`（3 个）：
  - §3.2：`projectIdentityNormalizesAliasesAndRejectsInvalidTargets`（尾斜杠/`.`/`..`/符号链接归一，缺失目录/普通文件/非 file URL/断链拒绝）。
  - §3.1：`windowClaimAndCloseRetireAWindowFromReuse`（认领与关闭退出复用池）。
  - §6.1：`menuRoutingResolvesProjectWindowsPanelsAndGlobalWindows`（key/main/面板 owner/全局窗口禁用）。
- 既有测试按 §7.3 更新指针接线（`SessionRestoreTests` ×3、`MainWindowControllerTests` ×1 以 `onSessionCheckpointWritten` 回调模拟应用层）；`run-self-tests.sh` 增加 multiwindow 通道（base 通道 14→15，mixed 门 17→18）。

### 2.2 应用自检通道（.build/debug/codeinsight-app）

- 新增 `--self-test-multiwindow`（隔离存储 + 隔离 defaults + 临时 trust/cache）：两窗两模型各自 ready、标题 `project — Cairn`、A 的标签不泄漏进 B、别名请求激活不重建、`performClose` 关 B 后 A 继续 ready 且窗口集合正确、两份按项目会话落盘。结果 `passed:true, persistedSnapshots:2`。
- `scripts/ci.sh` 全量（含 exact/history/diff/reading/fold 等通道与 fold perf）通过；`--self-test-diff` 曾因离屏窗口无 key/main 导致菜单动作路由为 nil 而失败，已通过“应用非活动时程序化派发回退最近活动项目窗口”修复后复验通过（routing 单测同时验证全局窗口仍禁用回退）。

## 3. 打包与 Launch Services 验收（真实 .app）

产物：`CAIRN_LIBGIT2=brew CAIRN_BUNDLE_IDENTIFIER=dev.cairn.Cairn.mwtest CAIRN_VERSION=0.1.mwtest scripts/make-app.sh` → `/tmp/cairn-mw-accept/build/Cairn.app`。
打包声明验证：`plutil -lint` 通过；`CFBundleDocumentTypes = [Project Folder / Viewer / public.folder / Alternate]`；`codesign --verify --strict` 通过（ad-hoc）。
受控项目：`/tmp/cairn-mw-accept/project-a`、`/tmp/cairn-mw-accept/第二个 项目`（空格+中文，均为 git 仓库）、`alias-to-a` 符号链接。观测工具：CGWindowList（按 PID 列出 layer/bounds/title；kCGWindowName 在无屏幕录制权限时为空，以窗口数量/几何为准）。

| ID | 操作 | 结果 | 状态 |
|---|---|---|---|
| W16 | 应用未运行，`open -a /abs/Cairn.app /abs/project-a` | 新 PID 单实例，屏幕上恰 1 个主尺寸窗口，无多余欢迎窗、未附带旧项目 | PASS |
| W17 | 已运行 A，`open -a /abs/Cairn.app /abs/第二个 项目` | 同 PID；出现第二个主窗口（级联 +28pt）与 B 的首次语言选择框（设计 §3.3 预期）；确认后 B 窗口就绪 | PASS |
| W18 | `open -a /abs/Cairn.app /abs/alias-to-a /abs/project-a`（同批别名+原路径） | 仍为 2 个主窗口，别名归一到 A 的窗口，未重复索引/建窗 | PASS |
| W19a | `open -a /abs/Cairn.app /abs/does-not-exist` | `open` 在客户端即拒绝（"does not exist"），既有窗口不受影响；应用内错误路径由 `projectIdentityNormalizesAliasesAndRejectsInvalidTargets` 单测覆盖 | PASS（注） |
| W19b | `cd /tmp/cairn-mw-accept && open -a /abs/Cairn.app ./alias-to-a "./第二个 项目/."` | 相对路径与尾斜杠 `/.` 由 `open` 按调用方 cwd 解释，均归一到既有窗口（仍 2 窗） | PASS |
| W08(部分) | 退出（SIGTERM）后无参数冷启动 | 恰 1 个恢复窗口；`Cairn.LastSessionProject = /tmp/cairn-mw-accept/第二个 项目`；`sessions/` 下两份按项目快照（projectRoot 分别为两个受控项目） | PASS |
| — | 按名称 `open -a Cairn` | 本机 `/Applications/Cairn.app`（生产安装，验收期间正在运行，`id of app "Cairn"` → dev.cairn.Cairn）持有该名称绑定；为不干扰生产实例未执行按名称投递。代码路径（`application(_:open:)`）与按路径打开完全一致 | BLOCKED（环境；按路径已覆盖同一代码路径） |

进程证据：所有阶段均通过 `pgrep -f <bundle 可执行文件>` 确认单 PID；SIGTERM 正常退出且退出前写入两份按项目会话文件（`~/Library/Application Support/Cairn/dev.cairn.Cairn.mwtest/sessions/*.json`，projectRoot 与受控项目一致）。

## 4. 验收矩阵对照（设计 §11）

| ID | 状态 | 证据 |
|---|---|---|
| W01 | PASS | multiwindow 自检（两窗两模型、root/tabs 隔离）+ §2.1 单测 |
| W02 | 部分（原断言过强） | 自检别名用例与 `projectIdentityNormalizesAliases…` 只覆盖“预写语言记录后的重复请求”，未覆盖取消后重开；取消路径在评审中实际 FAIL（F1），修复与再验证见修复记录；“加载中重复请求”仍只有代码审查，无失败态测试 |
| W03 | 逻辑自动化覆盖（非完整 GUI 验收） | `menuRoutingResolvesProjectWindowsPanelsAndGlobalWindows` 覆盖目标解析与全局窗口禁用；真实键盘焦点交替、菜单 enabled 遍历未人工走查 |
| W04 | PASS | 同上：面板作为 key window 路由到 owner；编辑控件快捷键未被抢占（Edit 菜单 responder-chain 保持原样，未改动） |
| W05 | PASS（代码路径） | `trustThisRepository` 捕获目标窗口与 model；`presentTrustError` 仅在原窗口可见时贴附（§6.2 修正）；窗口关闭则 app-modal 不投给其他项目 |
| W06 | 模型层 PASS / 应用级链路见修复记录 | `appModelCloseProjectResetsStateAndStopsExact` 覆盖模型清理；自检离屏窗口跳过生产异步收尾，不能替代最后窗口的应用级退出链路（评审 §3）。修复后由 `closedWindowReleasesClaimOnlyAfterTeardownFinishes`、自检“关闭后立即重开”腿与真实 ⌘Q 退出共同覆盖 |
| W07 | 模型级 PASS | 同上；`closeProject` 的 generation 失效化与 `shutdownAndWait` 释放由模型测试覆盖；应用级“退出等待关闭中窗口”由修复后的 `teardownCompletion` 链路覆盖（见修复记录） |
| W08 | 正常路径 PASS / 失败分支见修复记录 | 打包验收的 SIGTERM 不证明 `applicationShouldTerminate` 的批准、保存失败与异步等待流程（评审 §3）；正常 ⌘Q 已在再验证中确认，失败分支由 `quitSavesRemainingWindowsWhenOneWindowFails` 覆盖，真实故障对话框点击仍未走查 |
| W09 | PASS（代码路径） | `applicationShouldTerminateAfterLastWindowClosed` 返回 `projectWindows.isEmpty`；最后项目窗口关闭（Settings 开着）由 `handleProjectWindowClosing` 主动发起 terminate（launchFinished 后） |
| W10 | PASS | `sharedBookmarkStoreInterleavesTwoWindows…` + `…NotifiesBothWindows` |
| W11 | PASS（已按评审重写） | 原测试在“修复后”新建了**另一个** SharedBookmarkStore 并写另一路径，未证明原 dirty store 在原路径重试成功；现改为原实例原路径重试，断言 dirty/storageError 清除、双窗通知与磁盘含两窗+重试后更新 |
| W12 | PASS（已补 P1 缺口） | 原测试只验证 registry 共享，无运行中的 trusted provider；评审 F4 指出撤销等待期间仍可启动新 prepare。现由 `suspendedPrepareIsRefusedUntilTheSuspensionLifts` 覆盖“挂起期间零 provider 启动” |
| W13 | PASS | `materializerReferenceCountProtectsSharedDirectory` |
| W14 | PASS | `materializerQuotaEvictsOnlyUnreferencedDirectories` |
| W15 | PASS（已补 P2 缺口） | 原实现未在清缓存期间暂停新 prepare（评审 F8）。现维护态覆盖整个操作，`cacheMaintenanceHaltsPreparesAcrossSharedCoordinators` 断言维护期间两协调器均无法启动 provider |
| W16 | PASS | §3 打包验收 |
| W17 | PASS | §3 打包验收（同 PID 新窗口） |
| W18 | PASS | §3 打包验收（别名去重、批内顺序处理） |
| W19 | PASS | §3 打包验收（空格/中文/相对路径/尾斜杠；无效路径由 open 客户端拦截 + 单测覆盖应用内路径） |
| W20 | 逻辑覆盖（GUI 未走查） | 三选语义由 `quitSavesRemainingWindowsWhenOneWindowFails` 的脚本化决定覆盖（含 skip 后仍保存其余窗口，评审 F3）；真实故障对话框的按钮点击与 `windowShouldClose` 的模态交互未人工走查 |

未覆盖说明（诚实边界）：W03/W05/W20 的纯 GUI 交互面（真实点击/焦点切换/模态按钮）未做人工走查；其逻辑核心均有自动化覆盖。`open -n` 并发进程（设计明确不在首版范围）未测试。

## 5. 资源边界备注（设计 §9）

每项目独立索引/语言服务器按设计保留，未加窗口上限。验收中两个小项目同进程运行（Rust 索引 + 各自 Exact 关闭路径），未观察到异常回收；系统性资源计量留待后续按需执行。

## 6. 已知取舍

- 离屏（自检/单测）窗口跳过异步 closeProject 调度（`isOffscreenTestWindow`），避免测试进程共享 run loop 下的 AppKit 释放竞态；生产窗口完整执行。模型级 closeProject 行为由单测覆盖。
- 面板关闭使用 orderOut 语义而非 `NSWindow.close()`：控制器拥有面板窗口，released-when-closed 叠加控制器置 nil 会过度释放（NSZombie 定位，工具链 beta 下的实际崩溃源）。
- 测试打包使用 `CAIRN_LIBGIT2=brew`（vendored 模式与当前 beta 工具链的 clang 显式模块依赖扫描不兼容）；发布打包路径未变，仍默认 vendored。
