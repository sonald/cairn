# M6 实现计划 v4：Exact 能力面扩展 + 引用消费（Planner: Opus，2026-07-27）

> **v4 与前三版的根本差别：每个设计决策背后都有实测证据**，来自
> `docs/plans/m6-spike-findings.md`（811 行，真实 rust-analyzer
> `0.0.0 (cac0779549 2026-07-18)` 的请求/响应 JSON）。
>
> v1–v3 三轮评审共 **18 条 P1 全部属实**，根因是我在规划阶段做了本该由实测决定的决策。
> 典型：v3 给 S5/S6 定了"huge fixture + 中位数 delta ≤ 10MB"的内存门，而那个 fixture
> 是 200 行 `needle` + 99799 空行、**零 Rust 代码**——纸上精确，守的是空气。
>
> v1–v3 存于 `docs/plans/m6-plan.md`（已冻结）；本文件是唯一可派发版本。

---

## §0 背景与基线

**产品**：Cairn，macOS 原生**只读**代码阅读器（AppKit + TextKit 2，SwiftPM，Swift 6
严格并发）。核心卖点：实时符号索引、Context Window、双向 Call Tree、git 时间旅行、
四维不确定性标注、entirely read-only。

**基线**（2026-07-27 实测）：`swift test` **286 全绿**；`ci.sh` 通过；**11 条 self-test
通道** exit 0；双语料 gold nostrong=0；canonical dump 零 diff；空载内存 ~20.5MB；
extractorVersion=6。

**核心判断**：M5 把启发式侧做到位了，但 **exact 侧仍只有 definition**
（`ExactCapabilities` 只有 `.definition`）。Relations 三方向至今全靠启发式——
"Exact (0)" 不是没找到，是我们没问过 RA。

**编排**：规划/派发词/验收/诊断/探针由 Opus 做；Codex（GPT-5.6 Sol, effort xhigh）
只接实现任务。每片不 commit，监工验收后提交。

---

## §1 Spike 实测结论（v4 的设计依据，全部有 JSON 证据）

| # | 问题 | 实测结论 | 对设计的约束 |
|---|---|---|---|
| Q1 | `fromRanges` 相对谁 | **incoming**：ranges 属于 `relation.from`（caller 文件）；**outgoing**：`to.uri` 是被调用者，但 ranges **仍在请求源文件**。同一 caller 多 callsite = **1 relation + N ranges** | 解析时就用**正确的 base URI** 把 range 物化成 `ExactLocation`；**不存 raw range** |
| Q2 | implementation 返回形态 | 本版 RA 返回 **`LocationLink[]`**；两个 impl 就返回两项 | parser 必须处理 `LocationLink[]`（现有 definition parser 只取数组第一项，且不认 LocationLink） |
| Q3 | 客户端能力必须声明吗 | **不必**。两种 initialize 下 RA 都 advertise `true` 且请求正常 | 仍**应当**声明（规范要求、未来 server 可能强制），但**不作为能力探测的前提** |
| Q4 | helper 重启后旧 item | **仍可用**，返回正确结果 | **不需要 session nonce**（v3 评审 #5 的担忧被实测推翻）；RA 用 `uri + selectionRange` 重定位 |
| Q5 | `data` 往返 | **PARTIAL：本版 RA 固定不发 `data`**（附 RA 源码 `data: None` 佐证） | `data` 存 `Data?` 备用，**不设"必须逐字节/语义往返"的验收**——无从测起 |
| Q6 | 真实引用密度 | **86–355 refs/kLoC**（5 个真实大文件）；合成 10 万行 fixture 单次 parse **372.880ms** | fixture 用**确定性合成**、密度取高位 **200 bindings + 350 refs/kLoC** |
| Q7 | 复用 extractor binding | 可行：`RustExtractor` 拆薄 parse wrapper + 接受现成 `Tree` 的 walk 入口；`ReaderCore` 已依赖 extractor，**无需改 Package.swift** | **陷阱**：`RustExtractor.traverse` 遇 item-position macro 会对 token-tree **再次 parse**（`:163-180`）——Reader 入口必须跳过 |

**被实测推翻的 v3 设计**：
- session nonce（Q4：不需要）
- `data` 语义往返验收（Q5：RA 不发 data，无从验）
- "在 RustHighlighter 里顺带实现绑定解析"（Q7：那是复写解析器；正确做法是复用 extractor 的 walk）

---

## §2 范围裁决

**做**：S0 技术债 → S1 协议扩展 → S2 implementations → S3 callHierarchy → S4 Relations 消费
→ S5 局部引用索引 → S6 Reference Styles → S7 收尾。

**明确不做**：
- **`references` 能力**：LSP references ≠ callers；本轮无消费者（S6 消费的是 S5 的
  **文件内**索引），YAGNI 删除。
- **session nonce / handle**（Q4 实测不需要）。
- **read/write access kind**：S6 只需 binding identity + range + local/param；
  `&mut` 当 write 语义不可靠。
- **member/const/type/fn 角色**：`BindingKind` 里没有这些，硬造需明确规则。
- **巨档绝对内存布尔门**：代码注释自证 `phys_footprint ... cannot gate S7 cost`
  （`CodeInsightApp.swift:1055`），只作 metric，绝对预算转 M7。
- TS/Python、书签、分支图、lineage、依赖全量浏览、Cmd+±、AX 专项、Relation 随光标跟踪。

---

## §3 切片明细

### S0 — 技术债清算 + M6 fixture 建设（前置片）

**目标**：把 M5 三笔债处理到"后续验收可信"，并**造出能真正压测 S5/S6 的 fixture**。

**内容**：

1. **M6 引用 fixture（本片最重要，Q6 已给出规格）**：
   确定性合成 10 万行 Rust，**不拼接真实源码**（避版权/版本漂移/重复 item）：
   - 1,000 个唯一函数 × 100 行
   - 每函数 2 params + 18 lets = **20 bindings**；**35 个 resolved local/param uses**
   - 其余为确定性注释 padding
   - 总计 **20,000 bindings / 35,000 references**（对应 200 bindings + 350 refs/kLoC，
     取真实语料高位）
   - **binding/reference 数写成硬断言**——避免第二次出现"10 万空行守空气"
   - 参考基线：单次 tree-sitter parse **372.880ms**（Q6 实测）
2. **修 `--self-test-pin` harness 竞态**：`waitUntil` 条件须含**视图可见状态**本身
   （`CodeInsightApp.swift:1444`）。**必须先构造稳定复现**（S7 的额外布局会掩盖竞态）；
   复现不了就如实报告，**不许靠"跑 30 次没红"当修好了**。
3. **批量连跑挂起**：backlog 已排除六个假设，**不要重复走**。建议加**退出路径埋点**
   （每条通道 finish 前打带时间戳标记），区分"没跑到 finish"与"finish 了但不退"。
   **无稳定复现不许改退出逻辑**。查不出就交付安全批量脚本（独立进程 + 超时守卫 + 聚合）。
4. **巨档内存正式转 metric-only**：删除任何基于 `phys_footprint` 的布尔门，
   三个数（baseline/after/delta）全列作 metric。更新 `m5-backlog.md`：绝对预算标 **M7 候选**，
   注明"需先解决可归因的测量方法学"。
5. **修正依赖类验收前置（三条缺一不可）**：
   - 依赖源码可得性**不由 Trusted 产生**——`Sandbox.swift:51` 对 Safe 与 Trusted
     **都**设 `CARGO_NET_OFFLINE=1`，取决于本地 `~/.cargo/registry` 与 rust-src。
     **写"需 Trusted"会诱导无用授权。**
   - **但 trust 确实影响覆盖**：Safe 显式设 `cargo.buildScripts.enable = false`
     （`RustAnalyzerProvider.swift:129`），**build script/proc-macro 参与的 crate 在
     Safe 下解析覆盖受限**。
   - 写成「**本地依赖齐全 × trust mode**」二维矩阵，四格各说明预期。

**验收**：fixture 的 binding/reference 数硬断言通过 + parse 耗时有数；pin 稳定性数字
（修前/修后各 ≥30 次）；批量连跑有根因+对照或安全脚本+诚实标注；巨档门已转 metric；
测试计划 diff。286 只增不减。

---

### S1 — Exact 能力面协议扩展（地基，无 UI）

**内容**：

1. `ExactCapabilities` 增 `.implementations`（`1 << 1`）、`.callHierarchy`（`1 << 2`）。
   **不加 `.references`**。
2. **协商能力的位置与时机（Q3 + v3 评审 #7 实测修正）**：
   `prepare()` 内 `try session.start()` **同步完成 initialize 才返回 session**
   （`RustAnalyzerProvider.swift:120-127`）——因此 **pre-init 状态对外不可观察**。
   **最小实现**：session 构造完成后持有**不可变的 `negotiatedCapabilities`**。
   **不做 pre-init/closed 状态机**（无消费者的并发状态），**不写对应测试**。
   Coordinator/UI 读 session 的协商能力，不读 provider 的静态能力。
3. **新增类型只有两个**：
   ```swift
   public struct ExactCallHierarchyItem: Sendable {
       public let name: String
       public let kind: Int
       public let uri: String
       public let range: ExactLocation      // 已物化
       public let selectionRange: ExactLocation
       public let data: Data?               // Q5：本版 RA 固定不发，保留备用
   }

   public struct ExactCallRelation: Sendable {
       /// incoming 时是 caller；outgoing 时是 callee
       public let item: ExactCallHierarchyItem
       /// 已物化文件身份的调用处（Q1：解析时就用正确 base URI 转换）
       public let callSites: [ExactLocation]
   }
   ```
   **不引入 `ExactRange`**（仓库无此类型，`ExactLocation` 够用）。
4. `ExactSession` 增方法：
   - `implementations(file:byteOffset:) throws -> [ExactLocation]?`
   - `prepareCallHierarchy(file:byteOffset:) throws -> [ExactCallHierarchyItem]?`
   - `incomingCalls(item:) throws -> [ExactCallRelation]?`
   - `outgoingCalls(item:) throws -> [ExactCallRelation]?`
   **返回 nil = 不支持/无结果，不抛错**。
5. **不提供统一 nil 的 protocol extension 默认实现**——会掩盖"声明了能力却忘了实现"。
   每个 provider 显式实现。

**验收**：
- **修前失败对照**：fake provider 协商出 `.callHierarchy` 后能拿到 relation，现状必失败。
- 能力子集矩阵：只协商 definition 时调 callHierarchy 返回 nil 不崩。
- **`negotiatedCapabilities` 是不可变量**的断言（不是状态机）。
- determinism 无涉，canonical dump / gold 照跑。286+ / ci / 11 通道 / 零 warning。

---

### S2 — rust-analyzer implementations 实装

**内容**：

1. 实现 `implementations(...)`，沿用既有超时/取消/诊断机制。
2. **响应解析必须覆盖四种形态（Q2 实测：本版 RA 返回 `LocationLink[]`）**：
   `Location` / `Location[]` / **`LocationLink[]`** / `null`。
   现有 definition parser 对数组**只取第一项**且不认 LocationLink
   （`RustAnalyzerProvider.swift:526`）——**必须全量解析，四种形态各有测试**。
   `LocationLink` 用 `targetSelectionRange` 作为跳转点。
3. **客户端能力照常声明**（Q3：本版 RA 不强制，但规范要求且未来 server 可能强制）：
   initialize 增 `textDocument.implementation`。**但能力探测读的是服务端
   `implementationProvider`，不依赖我们声明与否。**
4. 路径映射沿用既有约定，`exactLocationIsInDependency` 是唯一判据。

**验收**：
- **修前失败对照**：fake 返回 `LocationLink[]` 多项 → 断言全部解析出来（现状只取第一项，必失败）。
- 四种响应形态各一测试。
- **真实 RA 变体**：Codex 环境 sandbox 不可用会 skip，**它报的"全绿"对本片无意义**；
  必须诚实标 BLOCKED，**监工真机复核**。
- 286+ / ci / 11 通道 / determinism。

---

### S3 — callHierarchy 实装（两步协议）

**内容**：

1. 两步流程：`prepareCallHierarchy` → `incomingCalls`/`outgoingCalls`。
2. **`fromRanges` 的 base URI 必须按方向区分（Q1 实测，这是本片核心正确性）**：
   - **incoming**：用每条 `relation.from.uri` 解释其 `fromRanges`
   - **outgoing**：用**发起请求的源 item URI** 解释 `fromRanges`，
     **不是 `relation.to.uri`**——实测证明套错会**稳定跳错文件**
   解析时就转成 `ExactLocation` 存进 `callSites`，**不保留 raw range**。
3. **空 item 不是错误**：`prepareCallHierarchy` 返回空 = "此处不是可调用符号"，诚实降级。
4. 能力协商读 `callHierarchyProvider`；initialize 增 `textDocument.callHierarchy`。
5. **语义映射**：callers ← incomingCalls；calls ← outgoingCalls。**不是 references。**

**验收**：
- **方向正确性对照（本片最关键）**：构造跨文件调用 fixture（`a.rs` 的 `foo` 调用
  `b.rs` 的 `bar` **两次**）：
  - incoming：断言 callSites 落在 **`a.rs`**
  - outgoing：断言 callSites 落在 **`a.rs`**（不是 `b.rs`）
  **两个方向都断言，且必须能抓住"用错 base URI"的实现。**
- **多 callsite 聚合**：断言 1 条 relation 带 2 个 callSite（Q1 实测形态）。
- 多 prepare item 场景。
- `prepareCallHierarchy` 空时不崩、诚实降级。
- **不测 `data` 往返**（Q5：本版 RA 不发 data，无从验；只断言字段存在性不崩）。
- 286+ / ci / 11 通道 / determinism。

---

### S4 — Relations 消费 exact 结果（UI 片）

**内容**：

1. **展开身份枚举**（依赖中的 exact 节点没有引擎 `SymbolOccurrenceID`，
   `RelationTreeModel.swift:244` 现要求它才能展开）：
   - `.engine(SymbolOccurrenceID)`：既有启发式展开
   - `.exact(ExactCallHierarchyItem)`：exact 展开
   **Q4 实测：旧 item 跨 session 可用，因此不需要 session nonce。**
   但**二层请求仍统一经 `ExactCoordinator`**，由它守 generation / cancel / restart
   （沿用既有机制），并做 stale-generation 丢弃。
2. **多 callsite 的展示形态（v3 评审 #4 要求明确）**：
   **一个 caller 一行**，callSites 作为该行的可展开子项或"N 处调用"标注 +
   点击循环跳转。**理由**：与既有 Relations 的一符号一行语义一致，
   且避免同一 caller 因多次调用重复出现干扰去重与 cycle 判定。
3. **去重与 cycle**：
   - exact 与启发式同目标（file + range）只出现一次，**优先 exact**并标注"启发式也命中"
   - cycle identity 用 **file + selectionRange 标准化后**做 key；成环时诚实标注
     "已展开过"，不静默截断
4. **上限 500 + 诚实截断**（沿用 M5-S8 语汇 `Showing first N of M ...`，总数照报真实值）。
5. **不进 Overlay 长期缓存**：`ReuseKey`（`ExactCoordinator.swift:20`）**不含 worktree
   内容身份**，工作树改动后可能命中陈旧结果。call hierarchy 结果**只做请求级/会话级
   短缓存**。
6. **空态文案分级（按能力特性区分，v3 评审 #1 修正）**：
   - **callers/calls 三种**：(a) 服务端不支持；(b) 支持但此处不适用
     （`prepareCallHierarchy` 空）；(c) 支持且适用但无结果
   - **implementations 两种**：(a) 不支持；(c) 无结果
     （`textDocument/implementation` **无 prepare 步骤，不存在"不适用"态**）
   **不许用同一个 "Exact (0)" 糊过去。**

**验收**：
- **修前失败对照**：断言 exact 组有内容且**能展开到第二层**，现状必失败。
- **exact-only 节点展开**：构造无引擎符号的 exact 节点 → 展开成功。
- **stale-result 测试**：二层请求未完成时切 profile / 切 history / revoke trust →
  旧结果被丢弃、不显示陈旧数据、不崩。
- 去重 / cycle / 上限 / 截断文案各有断言。
- **五种空态文案各有断言**（callers 三 + implementations 二）。
- **几何/可见（放大窗口 1600×1000）**：exact 组可见、frame 在可视区内、与启发式组不重叠。
- 内存 20 连跑不回退；断言不触发布局物化。
- 286+ / ci / 11 通道 / determinism。

---

### S5 — 文件内局部引用索引（Q7 已给出完整改动面）

**内容**（严格按 Q7 的四点最小改动面）：

1. **`RustExtractor.swift`**：把 `extractWithDiagnostics(bytes:)` 拆成
   **薄 parse wrapper + 接受现成 `Tree` 的 walk 入口**；现有 API parse 后委托新入口，
   **CLI/indexer 行为不变**。
2. **`RustScopeBuilder.swift`**：在现有 scope/pattern walk 中给 local/param binding
   记录**使用 ranges**；用 binding 数组下标作 identity，产出
   `referencesByBinding: [[ByteRange]]`（与 `bindings` 同下标）——
   **不新增 `BindingReference` 实体**。
3. **`CodeInsightReaderCore.swift`**：`RustHighlighter` 在**现有一次 parse** 后，
   先做原有高亮 walk，再把**同一个 `Tree`** 交给 extractor 的 binding/reference walk；
   结果直接变成 Reader 需要的 lookup，**不把整份 Engine `ContentIndex` 挂在
   `ReaderDocument`**。
4. **必须跳过 macro fragment reparse（Q7 发现的陷阱，我原本没问到）**：
   `RustExtractor.traverse`（`:111-135`）遇 item-position macro 会调 `macroBody`，
   后者在 `:163-180` 对 token-tree **再次 `parser.parse`**。
   **Reader 的局部引用入口必须跳过这条路径**，并沿用既有 macro partial/unsupported
   标注；否则即使复用了 root `Tree` 也不能宣称 parse 零增量。
   **CLI/indexer 全量入口保持原宏行为不变。**
5. **首版范围**：只做 `local` 与 `param`（对应既有 `BindingKind.letBinding` / `.param`）。
   **不做 read/write access kind**；member/const/type/fn 推后。
6. **不改 `Package.swift`**（ReaderCore 已依赖 extractor）；**不改 ContentIndex /
   extractorVersion**（determinism 天然无涉）。

**验收（Q7 明确指出词法扫描会冒充语义，故测试必须能区分）**：

- **反冒充测试组（本片核心，缺一不可）**——现有 `identifierOccurrences`
  （`CodeInsightReaderCore.swift:170`）是词法同名扫描，**下列每一条它都会答错**：
  - **嵌套 shadowing**：内层 `let x` 遮蔽外层 `x`，断言引用各归其主
  - **同名 sibling scope**：两个函数各有 `x`，断言互不串
  - **声明前后**：声明前的同名 token **不属于**该 binding
  - **声明位置排除**：`declarationRange` 自身不计入引用
  - **param vs local 区分**
- **零额外 parse 证明**：断言构建局部索引**没有触发第二次 tree-sitter parse**
  （计数探针），**包括 macro 路径**。
- **索引构建阶段**：复杂度 **O(file/scope)**，报**构建耗时 / 内存增量 / token 总数**。
  用 S0 的 M6 fixture（20,000 bindings / 35,000 refs），参考 parse 基线 372.880ms。
- **屏幕消费阶段**：查询/转换必须 **O(viewport)**，报**实际转换 token 数**，
  与 viewport 同阶、不随总行数线性增长。
- 内存：metric-only（S0 已转），三个数全列。
- determinism：canonical dump 零 diff、gold 不动。
- 286+ / ci / 11 通道。

---

### S6 — SI Reference Styles（引用处按身份着装）

**内容**：

1. **spans 必须分仓（v3 评审 #6，防止回到全文件遍历）**：
   `applyTypography`（`CodeInsightReaderUI.swift:955`）遍历**全部** spans 写 backing
   attributed string。**reference spans 绝不进 `document.highlightSpans`**——
   单独一仓，**只交给 `RenderingAttributesCoordinator`**（M5-S7 的 viewport 门控先例）。
2. **首版只区分 local vs param**（对应 S5 首版能力），差异最小可辨（如 param 略淡）。
   **决策者目验后走机动小片微调，不预猜、不擅自加样式维度。**
   行高跳动明显即退回（M5-S6 教训）。
3. 总开关沿用 `syntaxFormatting`：关闭时抑制引用样式。
4. **诚实红线**：这是**语义**引用样式（基于 S5 绑定数据），与 M5-S7 的**词法**同名高亮
   **必须能区分**——不许让用户以为词法高亮也是语义的。

**验收**：
- **修前失败对照**：断言 local/param 引用处有对应样式，现状必失败。
- **写属性计数（核心指标）**：用 S0 的 M6 fixture（35,000 references），
  断言**实际应用的 attribute runs / styled fragments** 与 viewport 同阶、
  **不随文件总行数线性增长**——**报数字，不是报 span 总数**。
- **spans 分仓断言**：reference spans **不在** `document.highlightSpans` 里。
- **总开关 off（v3 评审 #6 修正范围）**：断言 **reference-specific attributes 消失
  （writes/fragments = 0）**。
  **不要求"所有声明与引用视觉差异消失"**——语法配色本来仍保留，那样断言会误伤。
- 声明样式（M5-S6）与引用样式各有断言，互不干扰。
- 286+ / ci / 11 通道 / determinism。

---

### S7 — 收尾

**内容**：bench 增 M6 节（implementations / callHierarchy 耗时、局部引用索引构建耗时
与内存、Reference Styles 的 attribute run 增量）；`benchmarks.md` 增节
（**只追加，不改 M0–M5 历史数字**）；11+ 条通道双语料全家福（S0 若解决批量连跑就自动化，
否则逐条单发并如实标注）；撰写 `docs/plans/m6-interactive-test-plan.md`
（**依赖类分组前置写成「本地依赖齐全 × trust mode」矩阵**）；backlog 结转。

**人工（M6 总验收弧线）**：打开 tokio → 三方向 exact Relations（含深层展开）→
引用样式目验 → 巨档滚动 → Trusted 前后对比（**验证 trust 影响的是 build-script crate
的覆盖度，不是依赖可得性**）。

---

## §4 派发顺序

```
S0 最先（还债 + 造 fixture，后续验收才可信）
S1 → S2 → S3（串行：三片都改 CodeInsightExact）
S3 → S4（S4 消费 callHierarchy）
S5 独立于 S1–S4（Reader/Extractor 层），可在 S0 后插空
S5 → S6（S6 消费 S5 索引，且都触 ReaderUI/ReaderCore）
S7 依赖全部
推荐：S0 S1 S2 S3 S4 S5 S6 S7
```

---

## §5 风险预警

1. **S2/S3 依赖真实 RA**：Codex 环境 `sandbox-exec` 不可用会一律 skip，
   **它报的"全绿"对这两片没有意义**。M5 里这个盲区让一条红测试潜伏了三个 commit。
   **监工必须真机复核每一条 RA 断言。**
2. **S3 的 base URI 方向是正确性核心**（Q1 实测）：outgoing 套错 URI 会**稳定跳错文件**，
   而且**功能看起来是work 的**（有结果、能点击），只是跳错地方——
   **必须有两个方向各自的断言**。
3. **S5 的 macro reparse 陷阱**（Q7 发现）：即使复用 root `Tree`，
   `macroBody` 仍会二次 parse。**"零额外 parse"的断言必须覆盖 macro 路径**。
4. **S5 的测试必须能区分语义与词法**：Reader 已有 `identifierOccurrences` 词法扫描，
   若测试只查"某变量的全部引用"，实现可直接复用它并谎称 semantic。
   **反冒充测试组是硬要求。**
5. **S6 分仓是性能红线**：reference spans 一旦进 `highlightSpans`，
   `applyTypography` 就会全文件遍历，35,000 个引用会让 attribute runs 爆炸。
6. **trust 与依赖的关系有两面**：可得性不由 Trusted 产生（两模式都离线）；
   但 build script/proc-macro 参与的 crate 覆盖度确实受 trust 影响。
   **任何单方面表述都是错的**（v2/v3 各错过一次）。

---

## §6 验收铁律（沿用 m5-plan §6 八条 + 本轮新增两条）

**沿用八条**：修前会失败硬交付、UI 断言表达可见/几何、断言不触发布局物化、
间歇缺陷连跑 ≥20 次、git 与非 git 双语料、诚实性红线、determinism 硬门、环境盲区互补。

9. **否定性/对比性事实断言的证据标准**。声称"没有依赖 / 能力不存在 / A 与 B 有差异"时，
   证据必须是**列了目录 + 看了全部相关分支**。**背景**：(a) 只看 `Cargo.toml` 没有
   `[dependencies]` 就断言 fixture 无依赖，漏了 `build.rs`；(b) 只确认"Safe 设了
   `CARGO_NET_OFFLINE`"就外推"Trusted 能拿依赖"，没看 Trusted 分支。
   **能直接观测就不要推断。**

10. **覆盖面要数，不是数量要数**。报"N 条通道全绿"前必须回答"**哪条通道走到了被测
    代码**"。**背景**：M5-S8 跑了 10 条通道报 PASS，但没有一条碰过搜索面板。
    **推论（v4 新增）**：fixture 也要问"它**能不能**触发被测路径"——
    v3 用零 Rust 代码的 `huge.txt` 守 S5/S6，是同一个病的另一种形态。

---

## §7 通用约束（照抄进每片派发词）

无头 `swift build && swift test` 全绿（基线 **286**，只增不减）；`ci.sh` 通过；
Swift 6 零 warning；不破坏既有 self-test 通道（进场 **11 条**，只增不减）/
双语料 gold(nostrong=0) / canonical dump 零 diff / design F2.3 单击 Pin 语义 /
**只读铁律** / 诚实性文案 tokens / 空载内存 <100MB 不放宽；UI 断言表达可见/几何且
不触发布局物化、内存与几何断言在 1600×1000 下连跑 ≥20 次；git 与非 git 双语料都验；
**禁 RECORD**；不改 `Prototypes/`；**通道逐条单发**（批量连跑有未查明挂起，除非 S0 解决）；
`--self-test-open` **必须喂真实存在的文件**（根目录**没有** README.md）；
**不要 `git checkout --` 未提交文件**；每片不 commit。

---

## 附：关键实现文件

- `Sources/CodeInsightExact/ExactProvider.swift`（S1 能力面，`:6-14`、`:133-135`、`:145-153`）
- `Sources/CodeInsightExact/RustAnalyzerProvider.swift`（S2/S3；`:120-127` prepare 同步、
  `:129` Safe 禁 build script、`:526` definition parser 只取第一项）
- `Sources/CodeInsightExact/LSP.swift`（`:91` JSONSerialization、`:237` 客户端能力声明）
- `Sources/CodeInsightAppModel/ExactCoordinator.swift`（S4；`:20` ReuseKey 缺内容身份、`:15` 依赖判据）
- `Sources/CodeInsightAppModel/RelationTreeModel.swift`（S4；`:244` 展开需引擎符号、`:528` callSite 消费）
- `Sources/CodeInsightRustExtractor/RustExtractor.swift`（S5；`:20-64` 拆 parse wrapper、
  **`:111-135` + `:163-180` macro 二次 parse 陷阱**）
- `Sources/CodeInsightRustExtractor/RustScopeBuilder.swift`（S5；`:40` 已有 scope/pattern 逻辑、`:194` 起声明识别）
- `Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift`（S5 seam `:313`；
  **`:170` identifierOccurrences 词法扫描——反冒充对象**）
- `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`（S6；`:955` applyTypography 全文件遍历——必须分仓绕开）
- `Sources/CodeInsightApp/CodeInsightApp.swift`（S0；`:1444` pin 竞态、`:1055` 内存门自证不可用、`:4870` 旧 huge fixture）
- `docs/plans/m6-spike-findings.md`（**本计划的实测依据**）
