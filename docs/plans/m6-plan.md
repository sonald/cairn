# M6 实现计划：Exact 能力面扩展 + 引用消费（Planner: Opus，2026-07-27）

> **状态：v3 已冻结，等待 spike 结论后出 v4。不要按本文件派发实现。**
>
> 三轮评审共 **18 条 P1 全部核查属实**。v1 是方向错（references≠callers）、
> v2 是设计不闭合（能力生命周期、展开身份）、v3 是**验收假绿 + 协议契约不完整**。
> 越往后越深，说明**问题不在文档打磨不够，而在我于规划阶段做了本该由实测决定的决策**。
>
> 最典型：v3 给 S5/S6 定了"huge fixture + 中位数 delta ≤ 10MB"的内存门，
> 但那个 fixture 是 200 行 `needle` + 99799 个空行、**零 Rust 代码**
> （`CodeInsightApp.swift:4870`）——S5/S6 完全不运行也能通过。**纸上精确，守的是空气。**
>
> 而 `fromRanges` 坐标系、RA 的实际响应形态、helper 重启后 item 的命运、
> 真实 Rust 文件的引用密度——**这些只能问真实 rust-analyzer，不能靠读我们自己的代码想**。
>
> **因此改为：先做丢弃型 spike（见 `docs/plans/m6-spike.md`），拿真实数据后一次性出 v4。**
>
> 本文件保留 §1 的**已确证事实**（三轮评审 + 我实地核查的代码证据，不会因 spike 改变）
> 与 §8 的修订史；§3 的切片设计**待 spike 后重写**。

---


## §0 背景与本轮定位

**产品**：Cairn（代号 CodeInsight），macOS 原生**只读**代码阅读器（AppKit + TextKit 2，
SwiftPM，Swift 6 严格并发）。核心卖点：超快实时符号索引、底部 Context Window、
双向 Call Tree、快速 git commit 切换且切换后仍可做语义操作、四维不确定性标注
（"永远给结果，同时诚实表达不确定性"）、entirely read-only。

**已完成**：M0 四原型 → M1 Reader → M2 Relations → M3 Git 时间旅行 → M4 正式版 →
UI 打磨 6 片 → **M5 九片** → M5-Fix。

**基线数字**（2026-07-27 实测）：`swift test` **286 全绿**（本机装了 rust-analyzer 且
sandbox 可用的环境下首次全绿）；`ci.sh` 通过；**11 条 self-test 通道** exit 0；
双语料 gold set nostrong=0；canonical dump 逐字节零 diff；空载内存 ~20.5MB；
extractorVersion=6。

**编排分工**：**规划、派发词、验收、诊断、探针全部由 Opus 自己做，零 Fable**；
Codex（GPT-5.6 Sol，effort xhigh）只接实现任务。每片不 commit，监工验收后提交。

### §0.1 本轮的核心判断

M5 把**启发式**这一侧做到位了，但 **exact 侧仍只有 definition**：
`ExactCapabilities` 只有 `.definition`（`ExactProvider.swift:13`），`ExactSession`
只有 `definition(file:byteOffset:)`（:150）。**Relations 的 callers/calls/
implementations 三方向至今全靠启发式**——"Exact (0)" 不是没找到，是我们没问过 RA。

补齐 exact 能力面是"最好的 Rust 阅读器"的下一级，也是 Reference Styles 的数据前提。

---

## §1 现状核查结论（实地读代码，v3 已按二轮评审逐条复核）

| 项 | 核查结果 | 证据 |
|---|---|---|
| Exact 能力面 | definition-only。`capabilities` 挂在 **provider**（prepare 之前就要给出） | `ExactProvider.swift:6-14`、`:133-135`、`:145-153` |
| Relations 展开 | `expansionTask` **要求 `node.symbol`（引擎 `SymbolOccurrenceID`）**才能展开；依赖中的 exact 节点通常没有它 | `RelationTreeModel.swift:244-247` |
| Overlay 缓存键 | `ReuseKey` = versionIdentity × configFingerprint × featureSelection × toolVersion，**不含 worktree 内容身份/environment** | `ExactCoordinator.swift:20-31` |
| 局部绑定数据 | `BindingRecord` 只有 `declarationRange`，**没有使用边、没有 read/write access kind**；`BindingKind` 也不含 member/const/type/fn 这些角色 | `ScopeModel.swift:74-80` |
| 排版写入路径 | `applyTypography` **遍历全部 spans** 写 backing attributed string，不是 viewport 门控 | `CodeInsightReaderUI.swift:955-975` |
| **Safe vs Trusted** | **两种模式都设 `CARGO_NET_OFFLINE=1`**（环境变量在 trustMode 分支之外）。Trusted 只额外允许写 `target/`（从而允许 build script/proc-macro）。**Trusted 不开网** | `Sandbox.swift:51`、`:122-128` |
| M5 遗留缺口 A | `--self-test-pin` harness 竞态，S7 巧合掩盖，根因仍在 | `m5-backlog.md`、`CodeInsightApp.swift:1444` |
| M5 遗留缺口 B | 通道批量连跑间歇挂起，六个假设已排除，**根因未明** | `m5-backlog.md` 第一节 |
| M5 遗留缺口 C | 巨档 footprint 超 100MB 预算（TextKit 2 基线，S6 之前已存在）。**v3 实测**：baseline 254.2MB → after 226.3MB（净变化为负，被缓存回收主导，不可归因） | `m5-backlog.md`、本机实测 |
| **LSP 帧解析** | `LSP.swift:91` 用 `JSONSerialization` 解析，**原始 JSON 字节已丢失**——无法保证 `data` 逐字节往返 | `LSP.swift:86-96` |
| **readiness 语义** | `start()` 完成 initialize 后 **readiness 仍是 `.preparing`**；只有第一次 definition 成功才 `markReady()` | `RustAnalyzerProvider.swift:284-290`、`:334-336` |
| **Safe 的分析影响** | Safe 除禁网外，**显式禁用 build scripts**（`cargo.buildScripts.enable = false`）——因此 trust mode **确实影响** build script/proc-macro 参与的 crate 的解析覆盖 | `RustAnalyzerProvider.swift:129-137` |
| **extractor 数据通路** | `RustScopeBuilder` 结果只经 `ContentIndex` 输出；Reader 侧由 `RustHighlighter` **独立解析**（源码明确禁止为大文件重复解析） | `RustExtractor.swift:35-42`、`CodeInsightReaderCore.swift:313` |
| **macro 子树** | extractor 对 `macro_invocation` 有深度限制（`macroDepth < 3`）与条件展开——macro 内引用属 partial/unsupported | `RustExtractor.swift:111` |
| `BindingKind` 取值 | param / letBinding / importBinding / assignment / patternBinding / globalDecl / nonlocalDecl——**无 member/const/type/fn** | `ScopeModel.swift:48-56` |
| **huge fixture 内容** | `huge.txt` = 200 行 `needle` + 99799 个空行，**零 Rust 代码**——任何"用它守 S5/S6"的门都是假绿 | `CodeInsightApp.swift:4870` |
| **内存门自证不可用** | 代码注释已明写 `phys_footprint` 被 TextKit 缓存回收主导、**cannot gate S7 cost** | `CodeInsightApp.swift:1055` |
| **LSP 客户端能力** | initialize 只声明 `textDocument.definition`，**未声明 implementation / callHierarchy** | `LSP.swift:237` |
| **definition parser** | 数组形态**只取第一项**；未处理 `LocationLink[]` | `RustAnalyzerProvider.swift:526` |
| **prepare 是同步的** | `prepare()` 内 `try session.start()` 完成 initialize 才返回 session——**pre-init 状态对外不可观察** | `RustAnalyzerProvider.swift:120-127` |
| **绑定解析已有实现** | `RustScopeBuilder` 有完整 scope enter/exit + pattern + 声明逻辑；Resolver 处理 shadowing 与声明顺序 | `RustScopeBuilder.swift:40`、`Resolver.swift:391` |
| **ReaderCore 已依赖 extractor** | `Package.swift` 中 `CodeInsightReaderCore` 已 depend on `CodeInsightRustExtractor`——复用 binding 规则无需新增依赖 | `Package.swift:151` |
| **词法扫描会冒充语义** | Reader 已有 `identifierOccurrences`（词法同名）；若 S5 测试只查"某变量的全部引用"，实现可直接复用它并谎称 semantic | `CodeInsightReaderCore.swift:170` |

---

## §2 范围裁决

**本轮做**：S0 技术债 → S1–S4 Exact 能力面 → S5 局部引用索引 → S6 Reference Styles → S7 收尾。

**明确不做（v2 新增裁决）**：

- **`references` 能力本轮不实装**。评审 #1 指出：LSP `textDocument/references` 返回
  **所有引用位置**，语义上不等于 callers；而 Relations 的三方向应分别来自
  `callHierarchy/incomingCalls`（callers）、`outgoingCalls`（calls）、
  `textDocument/implementation`（implementations）。本轮 references **没有消费者**
  （S6 的 Reference Styles 消费的是 S5 的**文件内局部**索引，不是跨文件 LSP references），
  按 YAGNI 删除。**若将来做"全局引用列表"功能再加。**
- **不新增 `ExactReferences` 包装类型**（v2 评审 #8）。`[ExactLocation]` 已够用。
  **新增类型只有两个**：`ExactCallHierarchyItem`（LSP 强制的 opaque `data` 载体）
  与 `ExactCallRelation`（item + **fromRanges**，v3 评审 #1 指出 fromRanges 才是
  实际调用点，丢了它 Relations 的 callSite 导航就废了）。
- **不做 read/write access kind**（v3 评审 #8）。S6 只需要 binding identity + range +
  local/param；且把 `&mut` 直接当 write 语义不可靠。有明确产品需求时再加。
- **不设巨档绝对内存布尔门**（v3 评审 #6）。绝对值不可归因（实测净变化为负），
  只守增量中位数，规程写死在 S0。
- TS/Python 整语言面、F5.7 书签、分支图、F4.8 lineage、依赖全量浏览、Cmd+± 字号、
  AX 专项、Relation Window 随光标跟踪：全部推后。

---

## §3 切片明细

### S0 — 技术债清算（前置片，无新功能）

**目标**：把 M5 遗留的三笔债处理到"后续验收可信"。

**内容**：

1. **修 `--self-test-pin` harness 竞态**：`waitUntil` 条件须包含**视图可见状态**本身，
   而非只等模型层 `pinContextSummary != nil`（`CodeInsightApp.swift:1444`）。
   **必须先构造稳定复现**（S7 的额外布局会掩盖竞态）；复现不了就如实报告，
   **不许靠"跑 30 次没红"当修好了**。
2. **批量连跑挂起**：backlog 已排除六个假设，**不要重复走**。建议给 self-test 宿主加
   **退出路径埋点**（每条通道 finish 前打带时间戳的标记），挂起时可区分"没跑到 finish"
   与"finish 了但进程不退"。**红线：没有稳定复现不许改退出逻辑**。查不出就交付
   "安全批量脚本"（每条独立进程 + 超时守卫 + 结果聚合），让 S7 全家福能自动化。
3. **巨档内存：裁决已定 = 正式推后绝对预算，本轮只守增量（评审 #6）**。
   **不再二选一**。M5 已证明 `phys_footprint` 净变化被 TextKit 缓存回收主导
   （本机实测 baseline 254.2MB → after 226.3MB，**净变化为负**），
   **绝对值不可归因，因此不设布尔安全门**。

   **本轮唯一的内存门（S5/S6 共用，写死如下）**：

   | 项 | 规定 |
   |---|---|
   | fixture | `--self-test-reading` 的既有 10 万行 huge fixture（200 个 `needle`），**不换** |
   | 窗口状态 | 放大窗口 1600×1000，borderless（避免 titled 窗口的 WindowServer cache 干扰，UI-C2 教训） |
   | 预热 | 打开文件后 `pumpRunLoop()` 一次再开始采样 |
   | 采样 | **连续 20 次独立进程**，每次记 `baselineFootprintMB` / `afterFootprintMB` / `delta` |
   | 统计量 | 取 **20 次 delta 的中位数** |
   | **阈值** | **中位数 delta ≤ +10MB**（相对同一次运行内的 baseline，不是跨版本绝对值） |
   | 失败条件 | 中位数 delta > +10MB，或 20 次中有 ≥3 次 delta > +20MB |
   | 绝对值 | **只作为 metric 输出**（baseline/after/delta 三个数全列），**不判定 pass/fail** |

   **S0 交付物**：把上表实现成可复用的采样脚本或 self-test 输出格式，S5/S6 直接用。
   同时更新 `m5-backlog.md`：把"巨档绝对 footprint"正式标为**M7 候选**，
   注明"需先解决可归因的测量方法学，再谈预算"。
4. **修正交互测试计划的依赖类前置条件（v2 评审 #7 + v3 评审 #4，两次都有修正）**：

   `m5-interactive-test-plan.md` 的 G2 组现在**没有**前置说明。历次表述都不准确，
   **v3 的准确表述如下（三条缺一不可）**：

   - **依赖源码是否存在，不由 Trusted 授权产生**。`Sandbox.swift:51` 对 Safe 与
     Trusted **都**设 `CARGO_NET_OFFLINE=1`——**两种模式都离线**。可得性取决于本地
     `~/.cargo/registry` 缓存与 rust-src 组件是否齐全。
     **写"需 Trusted"会诱导用户做无用授权。**
   - **但 trust mode 确实影响分析覆盖**（v2 说"只影响 target 写入"是矫枉过正）：
     `RustAnalyzerProvider.swift:129` 显示 Safe 显式设 `cargo.buildScripts.enable = false`。
     **依赖 build script / proc-macro 的 crate，其 RA 解析与语义覆盖在 Safe 下会受限。**
   - 因此 G 组前置写成「**本地依赖齐全 × trust mode**」二维矩阵，
     四格各自说明预期结果（含"依赖齐全但 Safe 下 build-script crate 覆盖受限"这一格）。

**验收**：pin 稳定性数字（修前/修后各 ≥30 次）；批量连跑要么有根因+复现对照，
要么有可用安全批量脚本 + 如实标注根因未明；巨档裁决落到 backlog；测试计划 diff。
286 基线只增不减。

**人工**：无。

---

### S1 — Exact 能力面协议扩展（地基，无 UI）

**目标**：让协议能表达 implementations / callHierarchy，**并把能力放到正确的生命周期位置**。

**内容**：

1. **能力位置修正（评审 #2，v1 设计与协议不相容）**：LSP 的 ServerCapabilities 只能在
   `initialize` 响应后获得，而 `ExactProvider.capabilities`（`ExactProvider.swift:134`）
   在 `prepare()` **之前**就要给出。因此：
   - `ExactProvider.capabilities` 保持原义 = **"这个 provider 类型可能支持什么"**（静态上限）。
   - **新增 `ExactSession.negotiatedCapabilities`** = **"本次会话服务端实际支持什么"**
     （协商结果）。Coordinator / UI **一律读 session 的协商能力**，不读 provider 的静态能力。
   - **发布时机（v3 修正，评审 #2）**：**`initialize` 响应成功即发布协商能力，
     与语义查询 readiness 解耦**。v2 写的"session 未 ready 时为空"是错的——
     核查 `RustAnalyzerProvider.swift:284-290` 与 `:334-336`：`start()` 完成
     initialize 后 **readiness 仍是 `.preparing`**，要等第一次 definition 成功才
     `markReady()`。若把能力绑到 ready，会在整个 preparing 期间谎报"无能力"。
     **只有两种情况能力为空**：(a) initialize 尚未完成；(b) session 已失效/关闭。
2. `ExactCapabilities` 增 `.implementations`（`1 << 1`）、`.callHierarchy`（`1 << 2`）。
   **不加 `.references`**（§2 已裁决）。
3. `ExactSession` 增方法（**v3 修正返回类型，评审 #1**）：
   - `implementations(file:byteOffset:) throws -> [ExactLocation]?`
   - `prepareCallHierarchy(file:byteOffset:) throws -> [ExactCallHierarchyItem]?`
   - `incomingCalls(item:) throws -> [ExactCallRelation]?`
   - `outgoingCalls(item:) throws -> [ExactCallRelation]?`

   **`ExactCallRelation` = `item` + `fromRanges`**。v2 把 incoming/outgoing 压成
   `[ExactCallHierarchyItem]` 是错的：LSP 返回的是 `{from/to: item, fromRanges: Range[]}`，
   **`fromRanges` 才是实际调用点**。而 Relations 现有实现依赖 `callSite` 做导航与归因
   （`RelationTreeModel.swift:528` 一带），丢掉 fromRanges 会让"跳到调用处"失效。

   **返回 nil = 不支持/无结果，不抛错**（能力缺失是常态）。
4. **新增两个类型**：
   - `ExactCallHierarchyItem`：name / kind / uri / range / selectionRange / `data`
   - `ExactCallRelation`：`item` + `fromRanges: [ExactRange]`

   **`data` 的类型与往返语义（v3 修正，评审 #1）**：v2 要求"逐字节原样回传"
   **不可实现**——`LSP.swift:91` 用 `JSONSerialization` 解析，**原始 JSON 字节已丢失**。
   LSP 规范也只要求**语义值**保留。因此：
   - `data` 存为 **`Data?`（重新序列化的 JSON）或等价的 Sendable JSON value**
   - **测试语义往返**（回传后服务端能正确定位），**不测原始字节一致**
5. **不提供"统一返回 nil"的 protocol extension 默认实现（评审 #8）**——那会掩盖
   "声明了能力却忘了实现"。**每个 provider 显式实现**；fake provider 也显式返回 nil。

**验收**：
- **修前失败对照**：断言 fake provider 协商出 `.callHierarchy` 后能拿到 item，
  现状**必失败**（协议无此方法）。
- **能力生命周期测试（v3 重写）**：
  - initialize 完成但 readiness 仍 `.preparing` 时 → 断言**协商能力已发布、非空**
    （防止 v2 那种"绑 ready 导致整个 preparing 期谎报无能力"）
  - initialize 未完成 / session 已关闭 → 断言能力为空
  - provider 静态声明 `.callHierarchy` 但服务端未声明 → 断言协商结果**不含**它
- 能力子集矩阵：只协商 definition 时调 callHierarchy **返回 nil 不崩**。
- determinism 无涉，但 canonical dump / gold 照跑。286+ / ci / 11 通道 / 零 warning。

**人工**：无。

---

### S2 — rust-analyzer implementations 实装

**目标**：`textDocument/implementation` 走通，Relations 的 implementations 方向有 exact 来源。

**内容**：

1. `RustAnalyzerProvider` 实现 `implementations(...)`，沿用既有超时/取消/诊断机制。
2. **能力协商**：从 `initialize` 响应读 `implementationProvider`，
   只在服务端真支持时才把 `.implementations` 放进 `negotiatedCapabilities`。
3. 路径映射沿用既有约定（项目/物化根内相对、根外绝对），
   **`exactLocationIsInDependency` 是唯一判据**（M5-S4 建立），改路径约定必须复查其全部调用点。
4. coverage 标注沿用 M5 的诚实规则。

**验收**：
- **修前失败对照**：fake provider 返回已知 impl 集 → 断言结果与归因完整。
- **真实 RA 变体**：**Codex 环境 `sandbox-exec` 不可用会一律 skip，它报的"全绿"对本片
  无意义**（§6 铁律⑧）。必须诚实标 BLOCKED，**监工真机复核每一条 RA 断言**。
- 依赖落点：impl 落在依赖源码时走 M5-S4 的"位于依赖"路径。
- 286+ / ci / 11 通道 / determinism 三项。

**人工**：真机对 tokio 抽查 trait 方法 implementations 的准确度与耗时。

---

### S3 — callHierarchy 实装（两步协议）

**目标**：`prepareCallHierarchy` + `incomingCalls`/`outgoingCalls` 走通。

**内容**：

1. **两步流程**：先 `textDocument/prepareCallHierarchy` 拿 item 列表，
   再以 item 查 `callHierarchy/incomingCalls` / `outgoingCalls`。
   **`data` 按语义值保存与回传**（不是逐字节——`LSP.swift:91` 已用 `JSONSerialization`
   解析，原始字节不存在）。
   **返回值必须保留 `fromRanges`**（实际调用点），封装为 `ExactCallRelation`。
2. **空 item 不是错误**：`prepareCallHierarchy` 返回空 = "此处不是可调用符号"，
   诚实降级，不崩不报错。
3. 能力协商：读 `callHierarchyProvider`。
4. **语义映射（评审 #1，v1 错了）**：
   - **callers ← `incomingCalls`**
   - **calls ← `outgoingCalls`**
   - **不是 `references`**——references 返回所有引用位置，不等于调用者。

**验收**：
- fake + 真实 RA 变体；`prepareCallHierarchy` 空时不崩、诚实降级（各有断言）。
- **`data` 语义往返测试**：回传后服务端能正确定位（**不测原始字节一致**，见 S1）。
- **`fromRanges` 覆盖（v3 新增，评审 #1）**：
  - 多个 prepare item（同一位置解析出多个候选）
  - **同一 caller 有多个 callsite** → 断言 fromRanges 数量与位置都对
- 能力探测测试：mock 只支持 definition 的 server → 断言不声明 callHierarchy。
- 286+ / ci / 11 通道 / determinism。

**人工**：深层 call hierarchy 的耗时观感。

---

### S4 — Relations 消费 exact 结果（UI 片，本轮最复杂）

**目标**：Relations 三方向真正有 exact 内容，且**能继续展开**、与启发式结果并置可辨。

**内容**：

1. **exact-only 节点的展开身份 + 会话代际约束（v2 评审 #3 + v3 评审 #3）**：
   现状 `expansionTask`（`RelationTreeModel.swift:244`）要求 `node.symbol`
   （引擎 `SymbolOccurrenceID`）才能展开，而**依赖中的 exact 节点通常没有引擎符号**。
   若不处理，exact 节点**只能显示第一层**。

   **展开身份改为枚举**：
   - `.engine(SymbolOccurrenceID)`：走既有启发式展开
   - `.exact(ExactCallHierarchyItem)`：走 exact 展开（用 `data` 继续查 incoming/outgoing）

   **会话代际约束（v3 新增，这是 v2 的严重疏漏）**：`ExactCallHierarchyItem` **属于
   生成它的那个 RA session**，不能在 feature/profile/history/trust 切换或 helper 重启后
   交给新 session 使用。现有模糊展开已经同时校验 generation + requestID + session
   identity（`RelationTreeModel.swift:244`），exact 展开**必须同等对待**：
   - **所有二层请求统一经 `ExactCoordinator`**，由它守 generation / session identity /
     cancel / restart（`ExactCoordinator.swift:350` 一带已有这套机制）
   - **服务端原始 URI/range/data 用于回传**；**映射后的路径只用于显示、导航、去重**
     （两者不可混用——回传映射后的路径会让服务端找不到）
   - session 失效后持有的 item **一律作废**，UI 诚实提示需重新展开
2. **去重与 cycle identity**：
   - exact 与启发式结果**去重**：同一目标（file + range）只出现一次，**优先展示 exact**
     并标注"启发式也命中"（不丢信息）。
   - **cycle 检测**：递归调用会形成环，必须有 identity 判定（建议 file+selectionRange
     标准化后做 key）并在 UI 上诚实标注"已展开过"，不是静默截断。
3. **结果上限与诚实截断**：单层结果上限（建议 500），超出时**诚实截断行**
   （沿用 M5-S8 的 completeness 语汇：`Showing first N of M ...`），
   **总数照报真实值**。
4. **缓存策略（评审 #3）**：**不要把大结果集塞进长期 Overlay cache**——
   现有 `ReuseKey`（`ExactCoordinator.swift:20`）**不含 worktree 内容身份**，
   工作树改动后可能命中陈旧结果。本轮 call hierarchy 结果**只做请求级/会话级短缓存**，
   不进 Overlay；**若要进 Overlay，必须先给 ReuseKey 补内容身份**（那是独立议题，本轮不做）。
5. **诚实红线：空态文案分级（v3 修正适用范围，评审 #1）**：
   - **callers/calls（call hierarchy）三种情况文案各不相同**：
     (a) 服务端不支持该能力；(b) 支持但此处不适用（`prepareCallHierarchy` 返回空，
     即"此处不是可调用符号"）；(c) 支持且适用但无结果。
   - **implementations 只有两种**：(a) 不支持；(c) 无结果。
     `textDocument/implementation` **没有 prepare 步骤，不存在"此处不适用"这一态**——
     v2 对三方向一律要求三种文案是错的。
   **不许用同一个 "Exact (0)" 糊过去。**

**验收**：
- **修前失败对照**：集成通道断言 exact 组有内容且**能展开到第二层**，现状必失败。
- **exact-only 节点展开断言**（本片核心）：构造一个无引擎符号的 exact 节点 → 展开成功。
- **去重/cycle/上限各有断言**；截断文案含真实总数。
- **stale-result 测试（v3 新增，评审 #3）**：二层请求**未完成时**切 profile / 切 history /
  revoke trust → 断言旧 session 的结果**被丢弃**，UI 不显示陈旧数据、不崩。
- **三种空态文案各有断言**（诚实红线）。
- **几何/可见（§6 铁律②，放大窗口 1600×1000）**：exact 组可见、frame 在面板可视区内、
  与启发式组不重叠。
- 内存放大窗口连跑 ≥20 次不回退；断言不触发布局物化（铁律③）。
- 286+ / ci / 11 通道 / determinism。

**人工**：真机三方向 exact 组观感；exact 与启发式并置是否清楚；深层展开手感。

---

### S5 — 文件内局部引用索引（design §5.1）

**目标**：为 S6 提供**文件内**逐 token 的绑定身份数据。

**内容**：

1. **数据通路必须先定 seam（v3 新增，评审 #5——v2 这里根本不可落地）**：
   核查结果：`RustScopeBuilder` 的结果**只经 `ContentIndex` 输出**
   （`RustExtractor.swift:35-42`），而 Reader 侧由 `RustHighlighter` **独立解析**
   （`CodeInsightReaderCore.swift:313`，源码明确禁止为大文件重复解析）。
   v2 既要求"在 RustScopeBuilder 生成使用边"又要求"不进 ContentIndex"——
   **这两条同时成立就必然导致第二次全文解析**，违反既有禁令。

   **本轮选定的 seam：复用 Reader 侧 `RustHighlighter` 的那一次解析**。
   理由：S6 是 Reader 层的显示功能，数据消费者在 Reader；
   而 `RustHighlighter` 本来就要为高亮遍历整棵树，**在同一次遍历里顺带收集局部绑定
   与引用位置，零额外解析**。
   - **不动 `RustScopeBuilder` / `ContentIndex` / extractorVersion**
     （因此 determinism 完全无涉，canonical dump 必然零 diff）
   - 产物是 Reader 层的按需数据结构，随 `ReaderDocument` 生命周期

2. **首版能力范围（v3 收窄，评审 #8）**：
   - **只做 `local` 与 `param` 两类**（对应既有 `BindingKind.letBinding` / `.param`，
     `ScopeModel.swift:48-56`）。member/const/type/fn **明确推后**——
     `BindingKind` 里根本没有这些角色，硬造需要明确解析规则。
   - **不做 read/write access kind（v3 删除，评审 #8）**：S6 只需要
     **binding identity + range + local/param**，不消费读写区分；
     且 v2 把 `&mut` 直接定义为 write **语义不可靠**。
     **有明确产品功能需要区分读写时再加。**

3. **macro 内引用如实标 partial/unsupported（v3 新增，评审 #5）**：
   extractor 对 `macro_invocation` 有深度限制与条件展开（`RustExtractor.swift:111`）。
   macro 展开内的引用**本轮不保证覆盖**，UI 侧不得暗示"已覆盖全部引用"。

**验收（v2 的两条互斥已拆开，评审 #4）**：

- **索引构建阶段**：承认复杂度 **O(file/scope)**——完整索引本来就要扫相关作用域。
  **报告：构建耗时、内存增量、token 总数**。巨档必须有数字。
  **不要求 O(viewport)**（viewport 铁律约束的是渲染属性写入，不是语义索引构建）。
- **屏幕消费阶段**：查询/转换为显示数据必须 **O(viewport)**，
  **报告实际转换的 token 数**，与 viewport 同阶、不随文件总行数线性增长。
- **零额外解析证明**：断言构建局部索引**没有触发第二次 tree-sitter parse**
  （计数探针或等价证据）。
- **修前失败对照**：断言能查到已知 local/param 的全部引用位置，现状必失败。
- 内存：**按 S0 第 3 条写死的规程执行**（huge fixture / borderless 1600×1000 /
  20 次 / 中位数 delta ≤ +10MB）。
- determinism：canonical dump 零 diff、gold 不动（本片不碰 extractor，若出现 diff
  说明走错了 seam，回退）。
- 286+ / ci / 11 通道。

**人工**：巨档打开手感（是否有可感知的额外延迟）。

---

### S6 — SI Reference Styles（引用处按身份着装）

**目标**：补齐 SI Syntax Formatting 的另一半，与 M5-S6 的声明分级合成完整 SI 排版签名。

**内容**：

1. **写入路径必须改造（评审 #5，这是本片的前置工程）**：
   `applyTypography`（`CodeInsightReaderUI.swift:955`）现在**遍历全部 spans** 写
   backing attributed string。给每个引用生成 span 后，即使 S5 的查询被 viewport 门控，
   **S6 仍会退化成全文件 attribute runs**，违反 design §9.2。
   **要求**：引用样式走 **viewport 门控的 rendering attributes 路径**
   （M5-S7 的 `RenderingAttributesCoordinator` 是现成先例），
   **不要**把引用样式塞进 `applyTypography` 的全文件遍历。
2. **样式分级克制版**（沿用 M5-S6 教训）：首版只区分 **local vs param**
   （对应 S5 首版能力——S5 已明确不做 member/const/type/fn，也不做 read/write），
   差异做到最小可辨（如 param 略淡）。
   **决策者目验后走机动小片微调，不预猜、不擅自加样式维度。**
   行高跳动明显即退回。
3. 总开关沿用 M5-S6 的 `syntaxFormatting`：关闭时同样抑制引用样式，只留配色。
   **注意 v3 评审 #7 指出的验收漏洞**：旧断言只查 font/size/kern，
   而引用样式走的是**新的 rendering attributes 路径**——即使它仍在写颜色，
   旧断言也会通过。**必须直接断言 reference-style 的写入数为零**（见验收）。
4. **诚实红线**：这是**语义**引用样式（基于 S5 绑定数据），与 M5-S7 的**词法**同名高亮
   **必须能区分**——不许让用户以为词法高亮也是语义的。

**验收**：
- **修前失败对照**：断言 local 引用处有对应样式，现状必失败。
- **写属性计数（评审 #5，本片核心指标）**：巨档打开 + 引用样式激活后，
  **实际应用的 attribute runs / styled fragments 数**与 viewport 同阶、
  **不随文件总行数线性增长**——**报数字，不是报 span 总数**。
- **声明 vs 引用不混淆**：声明处仍是 M5-S6 分级，引用处是新样式，各有断言。
- **总开关 off（v3 强化，评审 #7）**：除既有的"全文单一 font family + 单一 pointSize +
  零 kern"外，**必须新增**：从 rendering coordinator（或可见 fragment）断言
  **reference-style 的 writes / fragments 计数为 0**，
  并断言**声明样式与引用样式的差异消失**。只查 font/size/kern 会漏掉新路径。
- 286+ / ci / 11 通道 / determinism（Reader 层）。

**人工**：目验引用着装观感与**行高稳定性**；SI Classic 主题对照；与 M5-S6 声明分级的协调。

---

### S7 — 收尾

**内容**：bench 增 M6 节（implementations / callHierarchy 各自耗时、局部引用索引构建
耗时与内存、Reference Styles 的 attribute run 增量）；`benchmarks.md` 增节
（**只追加，不改 M0–M5 历史数字**）；11+ 条通道双语料全家福（**S0 若解决批量连跑就
自动化，否则逐条单发并如实标注**）；撰写 `docs/plans/m6-interactive-test-plan.md`
（**依赖类分组前置写成「本地依赖齐全 × trust mode」矩阵，不写"需 Trusted"**）；
backlog 结转。

**验收**：ci + 全量测试 + fixture + gold + canonical dump + 全部通道 exit 0，
空载内存放大窗口 20 连跑。**人工（M6 总验收弧线）**：打开 tokio → 三方向 exact
Relations（含深层展开）→ 引用样式目验 → 巨档滚动 → Trusted 授权前后对比
（**验证 trust 只影响 build script/target 写入，不影响依赖可得性**）。

---

## §4 派发顺序、依赖与冲突

```
S0 最先（还债，后续验收才可信）
S1 → S2 → S3（严格串行：三片都改 CodeInsightExact 协议与 provider）
S3 → S4（S4 消费 callHierarchy 的 item/data，必须在 S3 之后）
S5 独立于 S1–S4（Reader/Core 层 vs Exact 层），可在 S0 之后任意插空
S5 → S6（S6 消费 S5 索引；且 S6 要改 ReaderUI 写入路径，必须串行）
S7 依赖全部
推荐单工作树顺序：S0 S1 S2 S3 S4 S5 S6 S7
```

---

## §5 风险预警

1. **S1 协议扩展影响所有 provider**：`ExactSession` 是 public 协议。**不提供统一 nil
   默认实现**（评审 #8），因此每个实现方都要显式补齐——这是有意的，防止"声明了能力
   却忘了实现"。
2. **S2/S3 依赖真实 rust-analyzer**：Codex 环境 `sandbox-exec` 不可用会一律 skip，
   **它报的"全绿"对这两片没有意义**。M5 里这个盲区让一条红测试潜伏了三个 commit。
   **监工必须真机复核每一条 RA 断言。**
3. **S4 是本轮最复杂片**：exact-only 节点展开身份、去重、cycle、上限、三种空态文案、
   缓存策略——任一漏掉都会产生"只能看第一层"或"陈旧结果"这类隐性缺陷。
   **几何等式断言是 C4/C5 式塌陷的主防线。**
4. **S5 的复杂度承诺必须分层表述**（评审 #4）：索引构建 O(file/scope) 是合理的，
   **不要为了凑 viewport 铁律而谎报**；真正要守 O(viewport) 的是屏幕消费阶段。
5. **S6 必须先改写入路径**（评审 #5）：不改造就直接加引用 span，会让全文件 attribute
   runs 爆炸。**验收指标是实际应用的 attribute runs，不是 span 总数。**
6. **S0 的批量连跑挂起可能查不出根因**：六个假设已排除。**查不出就如实交付
   workaround，不许编根因**（M5 里编过一次，被自己的验证实验证伪，已提交更正 `fcb9ee7`）。
7. **trust mode 与依赖的关系有两面，别再走极端**（v2 评审 #7 + v3 评审 #4）：
   - **可得性**：Safe 与 Trusted **都禁网**，依赖源码有无取决于本地 cache 与 rust-src，
     **"授权 Trusted 就能拿到依赖"是错的**，会诱导无用授权。要让依赖类验收可跑，
     正确做法是**本地把依赖拉全**（`cargo fetch` / 装 rust-src）。
   - **覆盖度**：但 Safe **显式禁用 build scripts**（`RustAnalyzerProvider.swift:129`），
     所以**依赖 build script / proc-macro 的 crate 在 Safe 下解析覆盖会受限**。
     v2 说"trust 只影响 target 写入、不影响依赖分析"**是矫枉过正**。
8. **S5 的 seam 选错会触发第二次全文解析**（评审 #5）：`RustScopeBuilder` 结果只经
   `ContentIndex` 输出，Reader 侧由 `RustHighlighter` 独立解析且**源码明确禁止为大文件
   重复解析**（`CodeInsightReaderCore.swift:313`）。本轮已选定"复用 Reader 侧那一次解析"，
   **验收要有"没有第二次 parse"的证据**，不能只看功能对不对。
9. **exact item 跨 session 使用会产生陈旧结果**（评审 #3）：`ExactCallHierarchyItem`
   绑定生成它的 session，profile/history/trust 切换或 helper 重启后必须作废。
   **stale-result 测试是本轮 S4 的必查项。**

---

## §6 验收铁律（沿用 m5-plan §6 八条，本轮新增两条）

**沿用 m5-plan §6 全部八条**（"修前会失败"硬交付、UI 断言必须表达可见/几何、
断言不得触发布局物化、间歇缺陷连跑 ≥20 次、git 与非 git 双语料、诚实性红线、
determinism 硬门、环境盲区互补）。**新增**：

9. **否定性/对比性事实断言的证据标准**。声称"某项目没有依赖 / 某能力不存在 /
   A 与 B 有差异"时，证据必须是**列了目录 + 看了全部相关分支**，不能是"我看了一个文件"。
   **背景两例**：(a) 监工只看 `Cargo.toml` 没有 `[dependencies]` 就断言 fixture 无依赖，
   漏了同目录 `build.rs`（带进 `cc` 工具链依赖），错误前提写进派发词让 Codex 白改一轮；
   (b) 监工只确认"Safe 设了 `CARGO_NET_OFFLINE`"就外推"Trusted 能拿到依赖"，
   **没看 Trusted 分支**——实际两种模式都禁网，该结论写进 memory 与 v1 计划，
   被评审当场推翻。**能直接观测就不要推断。**

10. **覆盖面要数，不是数量要数**。报"N 条通道全绿"前必须回答"**哪条通道走到了被测
    代码**"。**背景**：M5-S8 监工跑了 10 条通道报 PASS，但没有一条碰过搜索面板——
    被测功能零覆盖，直到人工验收才暴露。**新功能片必须有覆盖该功能的通道，没有就先建。**

---

## §7 通用约束（照抄进每片派发词）

无头 `swift build && swift test` 全绿（基线 **286**，既有测试只增不减、不改语义）；
`ci.sh` 通过；Swift 6 严格并发零 warning；不破坏既有 self-test 通道（进场 **11 条**，
只增不减）/ 双语料 gold set(nostrong=0) / canonical dump 零 diff / design F2.3 单击
Pin 语义 / **只读铁律** / 诚实性文案 tokens / 空载内存 <100MB 预算不放宽；
UI 断言必须表达可见/几何正确且不触发布局物化、内存与几何断言在放大窗口(1600×1000)下
连跑 ≥20 次；git 与非 git 双语料都验；**禁 RECORD 重录**；不改 `Prototypes/`；
**通道逐条单发**（批量连跑有未查明的间歇挂起，除非 S0 解决）；
`--self-test-open` **必须喂真实存在的文件**（本仓库根目录**没有** README.md）；
**不要 `git checkout --` 未提交文件**（用 `git stash` 或 `git archive`）；
每片不 commit（监工验收后提交）。

---

## §8 修订明细（两轮评审处置）

### v2 → v3（二轮评审：6 P1 + 2 P2，全部核查属实并采纳）

| # | 评审意见 | 核查证据 | 处置 |
|---|---|---|---|
| 1 [P1] | call hierarchy 丢失 `fromRanges`；`data` 逐字节往返不可保证 | `RelationTreeModel.swift:528` 依赖 callSite；`LSP.swift:91` 用 `JSONSerialization`，原始字节已丢 | **已修**。新增 `ExactCallRelation` = item + fromRanges；`data` 改为语义值往返（`Data?`/JSON value），**测语义不测字节**；验收补"多 prepare item / 同一 caller 多 callsite"；空态三分**只适用 call hierarchy**，implementation 只有两种 |
| 2 [P1] | negotiatedCapabilities 绑错 readiness | `RustAnalyzerProvider.swift:284-290` initialize 后仍 `.preparing`；`:334-336` 首次 definition 才 `markReady()` | **已修**。改为 **initialize 成功即发布能力**，与语义查询 readiness 解耦；只有 initialize 未完成 / session 失效时为空 |
| 3 [P1] | exact node 缺会话/代际约束 | `RelationTreeModel.swift:244` 模糊展开已校验 generation+requestID+session；`ExactCoordinator.swift:350` 管代际与重启 | **已修**。二层请求统一经 Coordinator 守 generation/session/cancel/restart；原始 URI/range/data 用于回传、映射路径只用于显示；**新增 stale-result 测试** |
| 4 [P1] | trust 结论矫枉过正 | `RustAnalyzerProvider.swift:129` Safe 显式 `buildScripts.enable = false` | **已修**。三条并列：依赖可得性不由 Trusted 产生 / 两模式都离线 / **但 build script·proc-macro 参与的 crate 覆盖确实受 trust 影响** |
| 5 [P1] | S5 无可落地通路，且会二次全文解析 | `RustExtractor.swift:35-42` 只经 ContentIndex；`CodeInsightReaderCore.swift:313` 禁大文件重复解析；`:111` macro 深度限制 | **已修**。**选定 seam = 复用 Reader 侧 `RustHighlighter` 那一次解析**，不动 extractor/ContentIndex；macro 内引用明标 partial；验收加"零额外解析"证据 |
| 6 [P1] | 巨档内存仍是"二选一" | 本机实测 baseline 254.2MB → after 226.3MB（净变化为负） | **已修**。**裁决已定：绝对值只作 metric 不判定**；写死唯一内存门规程（fixture/borderless 1600×1000/20 次/中位数 delta ≤ +10MB/失败条件），绝对预算正式转 M7 |
| 7 [P2] | 总开关验收未覆盖新渲染路径 | 引用样式走 rendering attributes，旧断言只查 font/size/kern | **已修**。总开关 off 必须断言 **reference-style writes/fragments = 0** 且声明与引用差异消失 |
| 8 [P2] | read/write access kind 无消费者 | S6 只需 binding identity + range + local/param；`&mut` 当 write 不可靠 | **已修**。**本轮删除 access kind** |

### v1 → v2（一轮评审：7 P1 + 1 P2）

| # | 评审意见 | 处置 |
|---|---|---|
| 1 [P1] | references ≠ callers | callers←incomingCalls、calls←outgoingCalls、implementations←implementation；**references 删除**（无消费者） |
| 2 [P1] | capability 生命周期不相容 | provider.capabilities = 静态上限；新增 `ExactSession.negotiatedCapabilities`（v3 又修了发布时机） |
| 3 [P1] | S4 未定义 exact-only 展开/去重/cycle/上限/缓存 | 展开身份枚举 `.engine`/`.exact`；去重/cycle/500 上限+诚实截断；结果不进 Overlay |
| 4 [P1] | S5 两条验收互斥 | 拆成"索引构建 O(file/scope)"与"屏幕消费 O(viewport)" |
| 5 [P1] | S6 写属性路径仍是全文件 | 引用样式走 viewport 门控的 rendering attributes，不塞进 `applyTypography` |
| 6 [P1] | S0 没清第三笔债 | 补入 S0（v3 进一步定死为具体规程） |
| 7 [P1] | "G2 必须 Trusted" 错误 | 改为「本地依赖齐全 × trust mode」矩阵（v3 又补了覆盖度那一面） |
| 8 [P2] | 删面向假想语言的实体 | 不新增 `ExactReferences`；不提供统一 nil 默认实现 |

---

## 附：关键实现文件

- `Sources/CodeInsightExact/ExactProvider.swift`（S1 能力面，`:6-14` 能力集、`:133-135` provider 静态能力、`:145-153` 会话协议）
- `Sources/CodeInsightExact/RustAnalyzerProvider.swift`（S2/S3 LSP 实装 + 能力协商）
- `Sources/CodeInsightAppModel/ExactCoordinator.swift`（S4 暴露与缓存，`:20` ReuseKey 缺内容身份、`:15` 依赖判据）
- `Sources/CodeInsightAppModel/RelationTreeModel.swift`（S4 三方向消费，`:244` expansionTask 的符号身份约束）
- `Sources/CodeInsightCore/ScopeModel.swift`（S5 只读参考：`:48-56` BindingKind 取值、`:74` BindingRecord 结构）
- `Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift`（**S5 的 seam：`:313` RustHighlighter 那一次解析**；S6 引用样式 HighlightKind 扩展）
- `Sources/CodeInsightExact/LSP.swift`（`:91` JSONSerialization——`data` 只能语义往返的原因）
- `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`（S6 `:955` applyTypography 全文件遍历——必须绕开；M5-S7 的 RenderingAttributesCoordinator 是 viewport 门控先例）
- `Sources/CodeInsightApp/CodeInsightApp.swift`（S0 pin 竞态 `:1444`、通道宿主）
- `Sources/CodeInsightExact/Sandbox.swift`（`:51` 两模式都禁网、`:122-128` Trusted 只多允许 target 写入）
- `docs/plans/m5-interactive-test-plan.md`（S0 修正依赖类前置矩阵）
