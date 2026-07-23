# M4-Fix 修复计划（Planner: Fable 5, 2026-07-23，基于 HEAD 1239b70）

M4 正式版 30 分钟人工交互验收 = FAIL（20 PASS / 8 FAIL / 6 BLOCKED）。本计划映射
8 个 FAIL 到 6 个修复片。BLOCKED 多为测试工具限制（Computer Use 发不了 Cmd+点击）
与缓存/离线环境条件，非产品缺陷，不修（G2.3 已旁证 exact 落点 author.rs:8:10 正确）。

Planner=Fable 5 规划（证据已实地核查两份 .ips + oatmeal 源码 + 相关 Swift 源码），
Codex 逐片实现（effort xhigh，提示词走文件），Opus 监工验收，末尾 Fable 终审。

## 证据基础（已核查，非假设）

- **C1** `EXC_BREAKPOINT/SIGTRAP`：`Array._checkSubscript`（Index out of range）←
  `TrustSettingsView.body` 行闭包 @ ReaderSettingsWindowController.swift:148 ←
  SwiftUI ForEach ← NSHostingView layout。报告
  `~/Library/Logs/DiagnosticReports/codeinsight-app-2026-07-23-111522.ips`。
- **C2** `+[NSApplication _crashOnException:]`：`-[NSConcreteTextStorage addAttributes:
  range:]` 越界 ← `ReaderTextView.apply(settings:)` ← ReaderSettingsView `.onChange`。
  报告 `…-2026-07-23-111008.ips`。
- **F4**：oatmeal `src/domain/models/backend.rs:73` `pub trait Backend` 是纯签名
  trait（无默认方法体）→ Calls 无 call site → 空树，解释"看似缺 External 组"。

---

## FIX-1 · C1 Revoke 崩溃（P0）

**根因（证实）**：`ReaderSettingsWindowController.swift:147-148`
`List(coordinator.trustedRepositories.indices, id: \.self){ index in let r =
coordinator.trustedRepositories[index] }`——以 indices 为数据源 + 行内回查活数组。
Revoke → `ExactCoordinator.refreshTrust()` 把数组从 1 清成 [] → 同一 layout pass
SwiftUI 仍以旧 index（id=0）重估行 → `trustedRepositories[0]` 越界 → SIGTRAP。
"没回 Safe / RA 孤儿"是下游：崩溃打断了 `AppModel.revokeRepositoryTrust`
(AppModel.swift:414-423) 里 revoke 之后的 `prepareExact(generation:)`（回 Safe 重建
逻辑本身正确）。

**策略**：
1. 根因：`trustedRepositories` 由 tuple 数组升级为
   `struct TrustedRepository: Identifiable, Equatable, Sendable { var id: String {path};
   let path; let grantedAt }`（放 CodeInsightExact，TrustRegistry 返回）；List 改
   `List(coordinator.trustedRepositories)`，行闭包用 element 值，**禁行内回查数组**。
2. `applicationWillTerminate` 增同步 `exactCoordinator.shutdown()`（补正常退出清理，
   目前仅靠 deinit 时序）。
3. grep `\.indices, id:` 审同类模式（当前仅此一处）。

**文件**：ReaderSettingsWindowController.swift、CodeInsightExact/TrustRegistry.swift、
CodeInsightAppModel/ExactCoordinator.swift、CodeInsightApp/CodeInsightApp.swift、
Tests/CodeInsightAppModelTests/ExactCoordinatorTests.swift。

**验收（无头）**：
- 单测：grant→revoke 断言数组原子更新、revoke 后 prepare 收 `.safe`、旧 session
  `close()` 被调、trust.json=={}。
- **新 self-test `--self-test-exact` 的 trust-revoke 变体**（ci.sh 已跑该通道）：
  fixture 仓 + fake provider + 临时 trust.json → grant → 起 trusted session →
  **构造真实 ReaderSettingsWindowController、showWindow、泵 runloop 让 NSHostingView
  完成含 1 行列表的 layout** → 调用与 UI 同一 `model.revokeRepositoryTrust(root)` →
  继续泵 runloop。断言：进程存活（修前必 SIGTRAP，以退出码判死）、
  trustedRepositories 空、trust.json=={}、fake provider 记录到二次 prepare 且
  trustMode==.safe、旧 session closed、状态文案不含 "Trusted"。

---

## FIX-2 · C2 主题/设置切换崩溃（P0）

**根因（证实）**：`MainWindowController.swift:1478` 在 `ReaderViewController.display(nil)`
分支直接 `textView.view.string = ""`，绕过 ReaderTextView 的不变量（storage 内容 ==
displayedDocument 字节）——storage 清空而 displayedDocument/byteUTF16Map 仍旧。之后
任何 `apply(settings:)`(CodeInsightReaderUI.swift:224-257) 用旧文档 highlightSpans 经
`applyTypography`(:379-408) 对空 storage `addAttributes(range:)` → NSException →
`_crashOnException` 杀进程。与 SI Classic 无关（任何 settings 变更都炸）；Compare 退出
时 secondaryReader `display(nil)` 埋雷，G8.3 切主题时命中。

**策略**：
1. 根因：新增 `ReaderTextView.clear()` 原子清 storage/displayedDocument/byteUTF16Map/
   diffMarkers/validator；display(nil) 分支(:1474-1481) 与错误分支(:1509-1513) 改走
   `clear()`（顺带修"报错仍显示旧内容"不一致）；App 层禁绝 `view.string` 直写。
2. 保险丝（**标注为纵深，不替代根因修**）：apply/updateSyntax 入口校
   `document.byteUTF16Map.utf16Count == backingTextStorage.length`，不一致 debug
   assertionFailure + release 跳 typography；applyTypography 内每个 nsRange 对
   storage.length clamp。

**文件**：CodeInsightReaderUI/CodeInsightReaderUI.swift、MainWindowController.swift、
Package.swift + 新 `Tests/CodeInsightReaderUITests/`（新 target，允许 AppKit——ci.sh
禁令清单不含 ReaderUI）、CodeInsightApp.swift（-self-test-diff 增步骤）。

**验收（无头）**：
- 新 target CodeInsightReaderUITests（NSTextView 离屏无窗口服务器可跑）：display→clear→
  apply 不抛且 length==0；display→apply 各主题（含 .siClassic、humanistComments 开）
  range 全 ≤ length；保险丝：人造不一致→apply 不抛。
- **`--self-test-diff` 增步骤**（真实 MainWindowController 复刻验收路径）：openProject→
  openFile→Compare 选 HEAD~1→`applyPanelPreset(.reading)`+`clearCompare()`→
  `applyReaderSettings(theme:.siClassic)`→泵 runloop+layoutIfNeeded。断言进程存活、
  主 reader 字节不变、secondary 已清。**ci.sh 追加 `--self-test-diff .`**（本仓即合法
  git 仓；CI +几秒，值得）。

---

## FIX-3 · F1+F2 首屏信任态 + 覆盖诚实化（P1）

**根因**：F1 `ExactCoordinator` 无可观察 trustMode（只在私有 Active struct）；
`renderExactStatus`(MainWindowController.swift:576-611) `.ready` 只显 "Exact: ready"。
F2 `.partial`（Safe base，RustAnalyzerProvider.swift:65）不上屏，
`.dependenciesUnavailableOffline` 由 session 从 RA 诊断动态算(:156-170)，coordinator 仅在
prepare 完成与每次 publish 快照 coverage → 首屏 RA 未吐 offline 日志故为 partial，UI 又只
特判 offline → 渲染成绿 "ready"。

**策略**：
1. coordinator 增 `public private(set) var trustMode: TrustMode?`，prepare 拿到 registry
   查询即置（早于 session ready），invalidate 清 nil；MainWindowController.observe() 观察。
2. 文案：`.ready` → "Exact: ready · Safe (partial)" / "· Trusted"；offline 保持橙
   "deps unavailable (offline) · Safe"；tooltip 写全归因。
3. coverage 事件驱动刷新：LSPClient 增诊断回调（window/logMessage + stderr 排水，锁外
   回调）→ session onCoverageChange → coordinator 订阅 hop MainActor 更新 observable。
   风险高则降级为 ready 后 +1s/+3s/+10s 有界重读，首选事件驱动。

**文件**：ExactCoordinator.swift、CodeInsightExact/LSP.swift、RustAnalyzerProvider.swift、
MainWindowController.swift、Tests（AppModel/Exact）。

**验收**：单测 trustMode 立即可读/清空、fake session 翻 diagnosticText → coordinator
coverage 无查询自动变 offline、revoke→re-prepare 回 .safe；`--self-test-exact` 各变体在
**任何 click 之前** `selfTestExactStatusText` 含 "Safe"/"Trusted"，RA-real conditional
离线 fixture 最终含 "deps unavailable (offline)"。

---

## FIX-4 · F3 历史 exact 物化归因（P1）

**根因**：`ExactCoordinator.publish()`(:423-440) 有 materializedRoot 与
key.versionIdentity(=commit hex)，但只把 session.attribution 原样塞进 overlay，来源丢失；
`ExactAttribution` 无 snapshot 来源字段（provider 不该知道物化）。徽标
`exactBadge`(ContextWindowModel.swift:548-557) 只能显 "Exact·direct · rust-analyzer ·
Safe"，违背 S7 验收"归因显示物化来源"。

**策略**（coordinator 层旁挂，不动 Core/ExactAttribution 本体）：
1. `ExactOverlay.Entry` 增 `origin: ExactOrigin`，
   `enum ExactOrigin { case worktree; case materialized(commitOID: String) }`；publish 从
   `materializedRoot != nil ? .materialized(versionIdentity) : .worktree` 填。
2. `ContextWindowModel.Candidate` 增 exactOrigin，badge 物化时追加 "· @<short7>
   (materialized)"；RelationTree "Exact·lsp" 徽标物化加 " · hist"（可选）。

**文件**：ExactCoordinator.swift、ContextWindowModel.swift、CodeInsightApp.swift
（historical-fake 变体断言）、Tests（AppModel）。

**验收**：单测 CommitSnapshot 路径 entry `origin==.materialized`，worktree 路径
`.worktree`，badge 含 short SHA + "materialized"；`--self-test-exact` historical-fake
变体(CodeInsightApp.swift:900-1001) 增断言 provenance 含 commitOID 前 7 位 +
"materialized"（保留 providerRootIsMaterialized/uiPathIsRepoRelative）。overlay 复用键不变。

---

## FIX-5 · F4 Calls External 组恒显 + 选中驱动换根（P1）

**根因**：分组代码存在且模型层测试绿（RelationTreeModel.swift:346-355，
`relationTreeShowsExternalCallsAsUnresolved` 绿）——又一次"模型绿≠集成对"。真实两因：
(a) External/Unresolved 组只在非空时追加(:347 `if !external.isEmpty`)，纯签名 trait 根
edges 为空 → 看似缺组，与 "Exact (0)" 诚实展示不对称；(b) 无路径把树内选中变新根——
单击仅联动底部 Context（AppModel.swift:334-345，符合 F2.3）；双击/Enter 只 navigate；
方向段控 `directionChanged`(RelationWindowController.swift:208-211) 永远用 currentSymbol
（旧根）。选 get_completion 再点 Calls 查的仍是 Backend。

**策略**：
1. `.calls` 方向 **恒显** External/Unresolved 组，空时 "External / Unresolved (0)"（对齐
   Exact (0)：教会"查过、为零"）。
2. 换根（**保持 F2.3 单击=联动底部不变**）：方向段控作用于选中 edge 符号
   （`selectedRelationSymbol ?? currentSymbol`）；双击/Enter navigate 同时
   `setRoot(symbol: node.symbol, direction:)`——"钻进去根跟随"；node.symbol 为 nil
   （词法/unresolved）时只 navigate 不换根。

**文件**：RelationTreeModel.swift、RelationWindowController.swift、Tests（Relation）、
CodeInsightApp.swift（集成断言）。

**验收**：单测 纯签名 trait 根→组存在 "(0)"；impl 含 self.x.post()/tokio::spawn 外部
调用→组非空 subtitle "Unresolved"；`--self-test-exact` fake-overlay 变体增两步：真实
outline 存在 "EXTERNAL / UNRESOLVED (0)" 组头；选中带 symbol 的 edge 行
（selectRowIndexes+selectSelection）→ directionChanged → `model.root?.title` 变为该符号
且 generation 递增；双击断言 navigate + 换根同时。

---

## FIX-6 · 孤儿 rust-analyzer 崩溃兜底（增强，独立片，排最后）

现状：LSPClient 正常 close 有 shutdown→terminate→SIGKILL+reap + deinit 兜底，但**进程级
崩溃/abort 时什么都不跑**，靠内核关管道让 RA 读 EOF 自杀——RA 在 trusted 重活中对 EOF
反应可能滞后 → PPID=1 孤儿（验收 G9.2 属实）。

**分层（按性价比）**：
1. 必做（并入 FIX-1）：修崩溃本身消除本次孤儿来源 + `applicationWillTerminate` shutdown。
2. 本片 FIX-6：进程内**崩溃信号 bracket**——全局 child-PID 注册表（固定长度原子数组，
   async-signal-safe），装 SIGTRAP/SIGABRT/SIGSEGV/SIGBUS/SIGILL handler + atexit：遍历
   `kill(pid,SIGKILL)` 后恢复默认 handler 重新 raise（保留崩溃报告）。handler 内只用
   async-signal-safe 调用。
3. 暂缓（backlog）：posix_spawn + POSIX_SPAWN_SETPGROUP 进程组化（覆盖 cargo/proc-macro
   孙进程，需弃 Foundation Process 重写 spawn）；kqueue 看护进程。

**验收**：注册表并发单测；辅助进程测试（spawn fake 长命子进程后 abort → 断言 fake 子
`kill(pid,0)==ESRCH`）；LSPClient 正常 close 不受影响（既有 LSP 测试绿）。

---

## 派发顺序与并行

| 片 | 依赖 | 并行 |
|---|---|---|
| FIX-1 (C1) | 无 | ‖ FIX-2 |
| FIX-2 (C2) | 无 | ‖ FIX-1 |
| FIX-3 (F1/F2) | FIX-1（同文件 ExactCoordinator） | ‖ FIX-5 |
| FIX-4 (F3) | FIX-3（同文件） | ‖ FIX-5 |
| FIX-5 (F4) | 无 | ‖ FIX-3/4/6 |
| FIX-6 (孤儿) | FIX-1 | ‖ FIX-3/4/5 |

保守串行序：1→2→3→4→5→6。监工逐片验收，不并行合并以便审查。

## 每片通用约束（照抄进 Codex 派发指令）

- 无头 `swift build && swift test` 全绿（既有 **208** 测试 + 新增，不删改既有断言语义）。
- `scripts/ci.sh` 通过：引擎/model 目标 **禁 AppKit/SwiftUI import**（FIX-3 的 LSPClient
  回调、FIX-4 的 ExactOrigin 都落在已禁 AppKit 的 target，不得引 UI 类型）；结尾
  `--self-test-exact .`（FIX-2 另加 `--self-test-diff .`）。
- Swift 6 严格并发零 warning（新回调注意 @Sendable/actor hop；LSPClient @unchecked
  Sendable，回调触发点在锁外）。
- **不破坏**：双语料 gold set（nostrong=0）、canonical dump 零 diff（禁 RECORD 重录）、
  8 条 self-test 通道（-/-open/-project/-switch/-diff/-pin/-history/-exact）。
- 不改 Prototypes/；每片不 commit；UI 行为改动必须带"驱动真实 MainWindowController/
  ReaderSettingsWindowController/NSOutlineView 的离屏断言"（M3 铁律：模型层绿不算完成）。

## Backlog 移交（本轮不修，记录）

posix_spawn 进程组化 / kqueue 看护；`methodNameOnly` 把外部方法调用吸收成 Possible 的
语义复审；设置窗口缓存导致 stale settings 展示的可能。
