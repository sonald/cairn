# M7 实现计划：全局 References / 影响面导航闭环（Planner: Opus，2026-07-28，v4）

> **版本沿革**：v1 由我起草，把 M7 定成"修点击缺陷 + 视觉配置化"——**格局判断错了**，
> 那是两件维护性工作不是里程碑。v2 采纳另一位 agent 的主线（References ≠ Callers）。
> **v4 按复审的 3 个 P1 + 1 个 P2 修订**（消费者清单未穷尽、G0 门无通过标准、
> 截断时仍称"真实总数"、S5A 不可独立派发），每条均实地核查属实。
> **v3 按评审的 4 个 P1 + 2 个 P2 重写，每条我都实地核查过，全部属实**——
> 其中 P1-1 是我自己犯的老毛病：把 `realProvider: passed` 外推成"真实 RA 路径全绿"，
> 而那条变体**根本没跑 implementations / incoming / outgoing / Relations**
> （核查见 §1.2）。这正是我写进铁律⑩要防的事：报绿前先问"哪条通道走到了被测代码"。

---


## §0 背景与基线

**产品**：Cairn，macOS 原生**只读**代码阅读器（AppKit + TextKit 2，SwiftPM，
Swift 6 严格并发）。核心卖点：实时符号索引、Context Window、双向 Call Tree、
git 时间旅行、四维不确定性标注、entirely read-only。

**基线**（2026-07-28 实测，HEAD `cec7319`）：`swift test` **323 全绿**；`ci.sh` 通过；
`run-self-tests.sh` **12 PASS / 0 FAIL / 0 HANG**；双语料 gold nostrong=0；
canonical dump 零 diff；extractorVersion=6。

**真实 rust-analyzer 覆盖的准确表述（v3 修正，评审 P1-1）**：
- **已 PASS**：definition / Context 升级路径、offline coverage 标注
  （`realProvider: passed` + `realOfflineCoverage: passed`）
- **NOT RUN**：**M6 Relations 真机总弧线尚无已归档执行证据**——
  `runRealExactVariant`（`CodeInsightApp.swift:2966`）只做「点击 token → 等 Context
  从 Fuzzy 升级到 Exact definition → 检查 Fuzzy 仍保留」，
  **完全没有执行 implementations / incomingCalls / outgoingCalls / Relation Window /
  exact-only 深层展开**（监工核查确认）。
- `m6-interactive-test-plan.md` 是**测试规格**，不是填过 PASS/FAIL/BLOCKED 的**执行报告**。

**我在 v2 里把 `realProvider: passed` 外推成"真实 RA 路径全绿"，是错的**——
这正是铁律⑩要防的："报绿前先问哪条通道走到了被测代码"。

**编排**：规划/派发词/验收/诊断/探针由 Opus 做；Codex（GPT-5.6 Sol, effort xhigh）
只接实现任务。每片不 commit，监工验收后提交。

---

## §1 本轮定位：References 是当前最明显的用户闭环缺口

**现状**：`RelationTreeModel.Direction` 只有 `callers / calls / implementations`
（`RelationTreeModel.swift:11-13`）。用户**无法反查**"这个类型 / 常量 / 函数值
在哪些地方被用到"——而这是重构前最常做的事，design §核心卖点里也写了。

**Calls 树覆盖不了**：类型引用、构造器、模式匹配、函数值传递、import alias、
借用/解引用。rust-analyzer 的 Find All References 覆盖这些场景，我们没有。

**M7 主线**：
> 用户选中符号后，能够在当前工作区或历史快照中查看**全部使用位置**，
> 区分 Exact / Fuzzy / partial / truncated，并完成跨文件跳转与返回。

**明确不做**（会把一个可验收里程碑拆成多个半成品）：TypeScript、Python、书签、
branch graph、lineage、Rename、read/write 分类、custom TextKit、大规模 UI 重构。

### §1.1 对合并来源的状态核实（五条已过时）

那份规划是在 M6-S7 跑到一半时看的，以下判断**现已不成立**：

| 它的判断 | 实测事实 |
|---|---|
| M6-S7 **IN PROGRESS** | **已完成** `565fc70` |
| `benchmarks.md` 止于 M5 | **M6 节在 `:272`** |
| `m6-interactive-test-plan.md` 不存在 | **已存在** |
| 真实 RA **BLOCKED** | **部分成立**：definition/coverage 已 PASS，但 **Relations 总弧线 NOT RUN**（见 §0） |
| 工作树有两处"并发草稿改动" | 那是 S7 验收时的工作树，**已提交** |

**G0 的处置（v3 修正）**：它的四条"M6 收口"事项（bench、交互计划、backlog 清理、
12 通道/CI/gold/canonical）**确已完成**（`565fc70` + `cec7319`），这部分删除。
**但第五条"真机真实 RA 验证 implementations/incoming/outgoing/深层展开"没做**——
**保留为 §3 的 G0 最小前置门**。

---

## §2 现状核查结论（实地读代码）

| 项 | 核查结果 | 证据 |
|---|---|---|
| **点击定位缺陷** | `call.range` 是**整个 `call_expression` 节点**，`Resolver` 用它做命中判定 → 行内任何位置都命中同一 call，`nameID` 是被调函数名 | `RustCalls.swift:24/:43`、`Resolver.swift:196`、附录 A 探针 |
| **Context 早退叠加** | `locatedToken.range.contains(offset)` 认为"还是同一 token"直接返回旧结果 | `ContextWindowModel.swift:255` |
| **canonical dump 依赖 call.range** | `:63` **用它排序**、`:65` 打印它 | `CanonicalDump.swift` |
| **gold set 依赖 call.range** | `:193` `offset: call.range.lowerBound` 作**查询点**、`:296` 取 range | `GoldSet.swift` |
| **UnresolvedCall 现有字段** | 已有 `qualifierRange` / `receiverRange` **两个辅助 range 的先例** | `Calls.swift:10-18` |
| **局部引用索引（S2 复用）** | M6-S5 已交付 `ReaderDocument.localBindings` + `referencesByBinding`（同下标）+ `localReferences(intersectingBytes:buffer:)` viewport 查询 | `CodeInsightReaderCore.swift:133-134`、`:235` |
| **SnapshotSearchService（S3 复用）** | 已有 `search(_:context:) -> AsyncThrowingStream<SearchBatch, Error>`，含批次、取消、snapshot 校验、completeness/truncated | `SnapshotSearch.swift:96` |
| **Exact 面（S4 扩展点）** | M6 已建 `negotiatedCapabilities` 协商机制 + `.implementations` / `.callHierarchy`；**`.references` 按 YAGNI 未加** | `ExactProvider.swift` |
| 视觉硬编码常量 | param alpha `0.72`（ReaderUI:292）、当前行 alpha `0.7`（:976）、声明分级 `.semibold`（:1070/:1079）；`ReaderSettings` 现 7 字段无一覆盖 | ReaderUI、`ReaderSettings.swift:15-31` |

### §2.1 一处技术分歧的裁决：新增 `nameRange`，不收窄 `range`

合并来源主张"把 `UnresolvedCall.range` **收窄**为 callee/macro 名称 token，
只有发现真实消费者需要完整表达式时才加第二个 range"。

**这个 YAGNI 提醒方向对，但前提不成立——完整表达式的消费者已经存在**：

- `CanonicalDump.swift:63` **用 `call.range` 排序**，`:65` 打印它
- `GoldSet.swift:193` 用 `range.lowerBound` 作 **resolve 查询点**

**收窄会导致**：dump 逐行变化 + **双语料 gold 条目全部偏移**。
而 gold 重录是本项目明令禁止的（禁 RECORD）。

**裁决：新增 `nameRange`，`range` 语义不变。**
`UnresolvedCall` 已有 `qualifierRange` / `receiverRange` 两个辅助 range 的先例，
这不是凭空加抽象。代价是 ContentIndex 结构变了 → **仍需 bump `extractorVersion`**，
但 **canonical dump 版式可保持不变**（新字段不进 dump）→ 既有 dump 零 diff、
gold 条目不用重录。

### §2.2 计数文案合同（复审 P1-3，全计划统一）

**问题**：`SnapshotSearchService` 在**原始候选阶段**就限制每文件 200 / 总计 5000
（`SnapshotSearch.swift:73-78`），而 `SearchBatch`（`:50-56`）只有
`completeness` / `truncatedPathIDs`，**没有未截断的 universe total**。

**因此 truncated 的 Fuzzy 结果根本不知道真实总数是多少，声称它就是造假。**

**四态合同（S3 / S5A / 红线全部按此）**：

| 状态 | 文案 | 含义 |
|---|---|---|
| complete | `M references` | service 未截断、UI 未 cap，M 是真实总数 |
| display cap only | `Showing first N of M references` | service 未截断（M 可信），UI 只显示 N |
| **service truncated** | **`N verified references · partial`** | **服务端已截断，不知道真实总数，绝不声称 M** |
| Exact + Fuzzy 合并 | **各自保留自己的 completeness** | 不许用一方的状态覆盖另一方 |

**这是诚实性红线**：把 truncated 的 N 说成"真实总数"是明确的造假，
与 M5-S8 建立的 completeness 语汇冲突。

---

---

## §3 切片明细

### G0 — M6 Relations 真机执行门（最小前置，评审 P1-1）

**目标**：把"M6 Relations 在真实 rust-analyzer 下到底行不行"这个问题**落成归档证据**，
而不是继续用 `realProvider: passed` 外推。

**为什么必须做**：M6 的 exact Relations（implementations / incoming / outgoing /
exact-only 深层展开）**只被 fake provider 覆盖过**。`runRealExactVariant`
（`CodeInsightApp.swift:2966`）不碰这些路径。M7 的 S4（Exact References）要建在
这套机制上——**地基没验过就往上盖，出问题无法归因**。

**内容**：按 `m6-interactive-test-plan.md` 的 G1–G6 **实际执行一遍**，产出
`docs/plans/m6-interactive-test-report.md`，**逐项填 PASS / FAIL / BLOCKED**。

**红线**：
- **real provider skip 一律记 BLOCKED，不记 PASS**（铁律⑧）
- 跑不了的如实标 `NOT RUN` + 原因，**不许留空、不许推测**
- 发现 FAIL 就**停下来报告**，不要顺手修（那是独立片）

**验收分两级（复审 P1-2：v3 只要求"有报告"，那样即使关键项全 BLOCKED 也算过，
与"地基没验过不往上盖"自相矛盾）**：

| 级别 | 标准 | 后果 |
|---|---|---|
| **证据采集完成** | 每项都有 PASS / FAIL / BLOCKED / NOT RUN 结论 + 原因 | G0 这片可以收工 |
| **G0 PASS** | **M6 的 G1–G3 与 G6.1 的真实 RA 核心路径全部 PASS** | **S4 Exact References 才可派发** |
| **G0 FAIL / BLOCKED** | 关键项未过 | **S4 不得派发**；但 S0A/S0B/S1/S2/S3 可继续 |

**这样设计的理由**：真机暂时阻塞（sandbox 不可用、依赖缺失）不该冻结所有 Fuzzy 工作，
但 **BLOCKED 也绝不能悄悄穿过 Exact gate**——S4 是建在 M6 exact 机制上的，
那套机制只被 fake provider 覆盖过。

**这片主要由监工在真机做**（Codex 环境 sandbox 可用性不稳定），
可派 Codex 的部分：把 G1–G6 里能自动化的断言补进 `--self-test-exact` 的真实 RA 变体。

---

### S0A — 导航正确性：nameRange 与全部消费者分类（评审 P1-2）

**目标**：点哪个词就查哪个词。**入口身份不可信，引用列表就是空中楼阁。**

**内容**：
1. `UnresolvedCall` 增 `nameRange: ByteRange`；`RustCalls.swift` 填充
   （`call_expression` 用 callee 最终 identifier 的 range；`macro_invocation` 用
   `finalName(in: macro)` 的 range）。
2. `extractorVersion` 6→7；`ContentIndexDraftCodec` 新字段编解码 + 校验
   （该文件已有 targetHint 的先例）。
3. **全部 `call.range` 消费者（语义/展示/传播）必须逐个分类**
   （评审 P1-2 + 复审 P1-1；v2 只提了 Resolver、v3 漏了下表后六行）。
   **注意这是 `call.range` 的全部消费者，不只是 `.lowerBound`**：

   | 位置 | 当前用途 | 分类 | 改不改 |
   |---|---|---|---|
   | `Resolver.swift:196` | 点击命中判定 | **语义查询** | 改用 `nameRange` |
   | `EngineSession.swift:230` | callers 解析查询点 | **语义查询** | 改用 `nameRange` |
   | `EngineSession.swift:324` | outgoing 解析查询点 | **语义查询** | 改用 `nameRange` |
   | `EngineSession.swift:287-293` | 归属判定（facet 包含关系） | **展示/归属** | **不改** |
   | `EngineSession.swift:302-303` | 排序键 | **展示/归属** | **不改** |
   | `GoldSet.swift:193` | 报告位置 **兼** resolve 查询点 | **两者都是** | **拆开**，见下 |
   | `GoldSet.swift:296` | 报告位置 | **展示** | 不改 |
   | `FixtureHarness.swift:108` | 测试查询点 | **语义查询** | 改用 `nameRange` |
   | `RelationTreeModel.swift:1067` | callsite 落点 | **需核实**（展示还是导航目标） | 按核实结果定 |
   | `CanonicalDump.swift:63/65` | 排序 + 打印 | **展示** | **绝不改** |
   | `ContextWindowModel.swift:365` | **callsite 导航落点** | **语义/导航** | **改用 `nameRange`** |
   | `CodeInsightCLI.swift:341` | CLI 查询 offset | **语义查询** | 改用 `nameRange` |
   | `CodeInsightCLI.swift:344` | CLI 输出 byteRange | **展示** | 不改（保持表达式） |
   | `CodeInsightCLI.swift:446` | CLI 展示位置 | **展示** | 不改，**但报告里要写明选择理由** |
   | `CodeInsightEngineTests.swift:418-419` | **排序合同断言** | **展示/排序** | 不改（改了说明排序语义被动） |
   | `ProjectIndexer.swift:592-601` | **draft remap 逐字段重建** | **传播** | **必须加 `nameRange`**，漏了会静默丢字段 |

   **`ContextWindowModel.swift:365` 是第二个关键点**：它是 callsite 的**导航落点**。
   不改的话，"点击入口修好了，但跳过去仍落在 qualifier/receiver"。

   **`ProjectIndexer.swift:592` 不是 lowerBound 消费者，但同样致命**：
   它逐字段重建 `UnresolvedCall`，**新字段不加进去就会在 remap 后丢失**——
   跨文件/持久化后 nameRange 变空，且**不会有编译错误**。

   **`GoldSet.swift:193` 是关键陷阱**：它把同一个 `source` 同时当"报告位置"和
   "resolve 查询点"。要保持 gold 条目零改动，必须**拆成两个值**——
   用 `range.lowerBound` 生成既有报告位置，用 `nameRange.lowerBound` 调 Resolver。
   **不许让一个变量承担两种语义。**

   **对 `Config::set(...)` 和 `receiver.method()`，表达式下界分别是 qualifier 和
   receiver，不是方法名**——语义查询点若不改，这些调用会解析成 `Config` / receiver
   而不是 `set` / `method`。

4. `Resolver.swift:205` 的"取最短匹配"语义**要复核**（nameRange 之间不再互相包含）。
5. **限定符/接收者是否可点——需先采样，不许纸上定**：
   点 `Config::set(...)` 的 `Config` 该显示什么？`qualifierRange` / `receiverRange`
   已存在。**先跑探针**看 `Config` 在 `index.symbols` / `index.imports` 里有没有对应
   条目：**有则跳转，没有则诚实返回"此处无可跳转符号"，不许硬编造**。
6. `ContextWindowModel.swift:255` 早退：range 变窄后语义自然正确，**但要复核**
   是否还有别的早退路径。

**注意（评审 P2-1）**：worktree Exact overlay 的 stale-cache 问题**已拆到 S0B**——
它触及 `ExactCoordinator` 而非 ContentIndex/Resolver，与本片是两个独立问题，
混在一起会让 RED 未复现、schema 变化和验收归属搅在一块。

**验收**：
- **修前失败对照（硬交付）**：`Config::set(...)` 点 `Config` → 断言**不再**返回 `set`；
  同一行点第二个符号 → 断言 Context **确实更新**。两条都要，贴红/绿。
- `call.nameRange` 文本 == 函数名；`call.range` 仍覆盖整个表达式（**两条都断言**）。
- **determinism 硬门**：既有 canonical dump **逐字节零 diff**、双语料 gold
  nostrong=0 **且条目一字不改**、**禁 RECORD**。出现 diff 说明 nameRange 泄漏进 dump
  或误改了 range 语义，**回退**。
- draft 缓存失效：bump 后首跑 `extracted>0`、二跑 `extracted==0`；持久化 round-trip。
- 回归：点函数名本身仍正确解析（既有主路径不能坏）。
- 323 只增不减 / ci / 12 通道 / Swift 6 零 warning。

**顺带观察（不单独占片）**：决策者报告的"同名高亮延迟约 1 秒"。
S0 修完后**先看是否自愈**——`activate` 是同步调用（`CodeInsightReaderUI.swift:358`），
理论上应立即，根因未明。**自愈就如实报告，不改渲染热路径；未自愈则加时间戳探针定位，
没有稳定复现和明确根因不许改。**

**人工**：决策者复验原报告的三个现象。

---

### S0B — Exact overlay stale-cache 复现探针（独立小片，评审 P2-1）

**目标**：验证"工作树改动后是否会命中陈旧 overlay"。**先复现，再决定改不改。**

**背景**：`ExactOverlay.ReuseKey`（`ExactCoordinator.swift:20`）=
versionIdentity × configFingerprint × featureSelection × toolVersion，
**不含 worktree 内容身份**。理论上改了文件再查可能命中旧结果。

**内容**：写复现测试（改文件 → 不改 commit/profile → 查同一位置）。

**红线（这片的全部意义）**：
- **只在 RED 能稳定复现后**才做最小失效修复
- **复现不了就如实报告"未能复现 + 已尝试的手段"**，不许猜一个修法
- 与 S0A 分开验收，不共用 commit

---

### S1 — References 合同与证据 spike（丢弃型，先采样再冻结）

**目标**：用真实 rust-analyzer 固定 References 的语义边界，**再冻结 UI、cap 和性能预算**。

**M6 的教训**：计划写了四版被评审 18 条 P1 推翻，转折点是做了个丢弃型 spike。
**这片就是 M7 的 spike，产出是答案文档不是产品代码。**

**要问清的**（每条附真实请求/响应证据）：
1. **declaration 是否包含**（`includeDeclaration` 语义）
2. **覆盖面**：local / param / function / **type** / **constructor** / **pattern** /
   **import alias** —— **必须证明"References ≠ Callers"**
3. shadowing、同名 sibling scope 是否正确区分
4. comment / string 是否被排除
5. dependency location（依赖源码里的引用）
6. worktree 与历史 commit 两种快照
7. **规模数据**：结果总量、首批延迟、总延迟、**常见短名称的密度**
   （现有搜索有候选总量与超时上限，短名可能在语义验证前耗尽 cap——**先得数据**）

#### 第二组：Fuzzy 实现路径（评审 P1-4，v2 漏了这半边，而它才是风险最高的）

**为什么必须问**：S3 的主要未知**不在 LSP，而在本地 Fuzzy 验证**。监工核查：

- `SnapshotSearchService`（`SnapshotSearch.swift:73-78`）在**语义验证之前**就有
  `matchesPerFile = 200` / `totalMatches = 5000` 的硬上限
- `ContentIndex`**不保存 Tree，也不保存完整 identifier occurrences**
- `Resolver` 的 identifier fallback（`:209-216`）**只看 `isIdentifierByte`，
  完全不认 comment / string**

所以"文本候选 → Tree-sitter/Resolver 验证"这条路**隐含了一条新的 on-demand parse 路径**。

**要用丢弃型 Fuzzy prototype + 反冒充语料答清**：
8. **每个 unique content 是否只 parse 一次**（还是每个候选都 parse 一遍）
9. **comment / string 排除是否真实生效**（现有 fallback 不认，得新做——做了有效吗）
10. **raw cap 是否先吞掉了有效引用**：常见短名在 200/5000 上限下，
    语义验证前就被截断的比例是多少
11. **截断时显示什么**：是"已验证 N 条"，还是错误地宣称"真实总数 N"
    （这两者混淆就是诚实性事故）
12. 端到端延迟：候选发现 + 验证的首批/总耗时

**红线**：答不出就写"未能测得 + 原因 + 建议办法"，**绝不许编**。
优先绕过 sandbox 直连裸 RA（M6 spike findings §0 有做法）。

**验收**：`docs/plans/m7-spike-findings.md` 完成，**Exact 与 Fuzzy 两组 findings 都有**；
探针全部还原；产品代码零 diff。

**S3 只有在 Fuzzy 组结果支持时才可派发**——若 prototype 显示 cap 会吞掉有效引用，
S3 的设计要先改（例如提高 cap、或改成两阶段查询），**不能带着已知缺陷往下做**。

---

### S2 — Local References 消费闭环（复用 M6-S5，不加持久化实体）

**目标**：先形成**真实消费者**，再谈 Exact/Fuzzy 扩展。

**复用**：M6-S5 已交付 `ReaderDocument.localBindings` + `referencesByBinding`（同下标）
+ `localReferences(intersectingBytes:buffer:)`（`CodeInsightReaderCore.swift:133-134`、`:235`）。
**不新增持久化实体、不写进 ContentIndex。**

**派发前必须裁决三件事（评审 P1-3，v2 直接跳到"导航历史和几何断言"，
没说结果出现在哪、binding identity 怎么传——实现者会被迫现场发明
`ReferenceTarget` / 新 panel / 跨层回调）**：

监工核查到的接缝现状：
- `ReaderDocument.localBinding(at:)`（`CodeInsightReaderCore.swift:194`）返回
  **document-local binding index**
- `RelationWindowController.setRoot(symbol:direction:)`（`RelationWindowController.swift:293`）
  **只接受 `SymbolOccurrenceID`**
- `ContextWindowModel.Candidate` **不保留 lexical-binding evidence**；
  现有把 local index 伪装成 `.declarationFacet` 的做法**不能直接交给 RelationTree**

**三个待裁决问题**：
1. **References 是否在 Relation Window 增第四个方向**（`Direction` 加 `.references`），
   还是另起结果面？
2. **ReaderDocument 的 binding index 如何送进现有结果面**？
3. **local 与 global references 是否真的必须统一成一种 target 类型**？

**红线**：**只有第 3 点答案为"必须"时**，才允许新增一个**严格两分支**的最小 target
类型（`.engine(SymbolOccurrenceID)` / `.localBinding(documentIndex)`，
沿用 M6-S4 的 `ExpansionIdentity` 先例）。
**答案是"不必须"就不要造这个类型**——local 先走自己的通路。

**内容**：当前文件内 local/param 的全部引用；declaration policy（按 S1 结论）；
点击 → 跳转 → 返回；shadowing 不串线。

**验收**：
- **反冒充测试组**（沿用 M6-S5 的做法，词法扫描必然答错的五类场景）
- 跳转/返回的导航历史正确
- 几何/可见断言（放大窗口 1600×1000）
- 323 只增不减 / ci / 12 通道 / determinism

---

### S3 — Fuzzy Project References（复用 SnapshotSearchService）

**目标**：Safe 模式 / offline / 历史快照下**仍能给出诚实的 Fuzzy 结果**。

**复用**：`SnapshotSearchService.search(_:context:)`（`SnapshotSearch.swift:96`）
已有批次流、取消、snapshot 校验、completeness/truncated。
**不建 `ReferenceStore` / `ReferenceGraph` / 新数据库表。**

**内容**：文本候选发现 → Tree-sitter/Resolver 身份验证 → 流式批次 + 取消 +
generation guard → 诚实标记 heuristic / partial / truncated。
**引用不写进 ContentIndex。**

**验收**：
- **"引用但不是调用"的样本**（S1 spike 会给出具体类型）
- **comment / string 不得伪装成引用**
- **同名但不同 binding 的引用不得混合**
- **计数文案合同（复审 P1-3，全计划统一，见 §2.2）**——truncated 时**不得声称真实总数**
- Safe / offline / 历史快照三种场景各验
- generation 切换时旧结果被丢弃（stale-result 测试）

---

### S4 — Exact References 提升（消费者完成后才加）

**内容**：`.references` capability（M6 已建协商机制）；
`ExactSession.references(file:byteOffset:includeDeclaration:) -> [ExactLocation]?`
——**直接用 `[ExactLocation]`，不加 `ExactReferences` 包装类型**（LSP 3.17 定义
`Location[] | null`，沿用 M6 的 YAGNI 裁决）；
Exact/Fuzzy 合并去重（**同位置 Exact 胜出，但保留"heuristic also matched"标注**）；
profile / session / snapshot / trust 切换时拒绝旧结果。

**验收**：修前失败对照；去重不隐藏 Fuzzy 来源；四种切换的 stale-result；
**真实 RA 必须真机验**（Codex 环境 skip 一律记 BLOCKED，不记 PASS）。

---

### S5A — References UX、规模与 AX

**依赖**：S1 的**计数合同**（§2.2）与 S2 的**结果面裁决**。这两者未定不得派发本片。

**内容**：大结果取消；键盘选择；跨文件导航；基本 AX；数量语义按 §2.2。

**验收（复审 P2：v3 只有一行内容、没有具体验收，不可独立派发）**：
- **取消**：取消后**旧 batch 不发布**（stale-result 断言，沿用 M6-S4 的做法）
- **键盘选择与打开**：走**真实 `NSOutlineView`**，不是模型层模拟
- **AX**：结果行有 label/value；**选中变化时 AX 通知正确**
- **三种文案各有断言**：complete / display-cap / service-truncated（§2.2 四态里的前三态）
- **几何/可见（放大窗口 1600×1000）**：结果面在可视区内、行几何非零、
  与既有面板不重叠；**断言只读 frame，不触发强制布局**（铁律③）
- **导航历史**：跨文件跳转后能返回原位置
- 内存放大窗口连跑 ≥20 次不回退

---

### S5B — Reader 视觉设置（独立，可提前，评审 P2-2）

**v2 说"两者都动 `ReaderSettings` 分开会撞文件"——这个理由不成立**：
References 的结果数量、取消、键盘、导航、AX **属于 Relation model/window，
根本不碰 `ReaderSettings`**。两片独立验收。

**内容**（决策者 2026-07-28 提出）：
1. **先盘点全部硬编码视觉常量**（"不只做 param alpha 一个开关"）。
   **但盘点 ≠ 每个常量都新增设置字段（评审 P2-2）**——
   只把**有明确用户控制需求**的项放进设置，其余留在代码里。盘点清单与取舍理由都要列。
   已知：param alpha `0.72`（ReaderUI:292）、当前行 alpha `0.7`（:976）、
   声明分级 `.semibold`（:1070/:1079）。**盘点清单要列进报告。**
2. 收进 `ReaderSettings`（现 7 字段），**每个数值型新字段都要有 clamp 范围**
   （Bool / enum 不需要 clamp）。
3. Settings 的 Reading 页加控件；`UserDefaults` 持久化 round-trip。
4. **红线：新设置项默认值必须等于当前硬编码值**——配置化是把常量搬家，
   **不是趁机调观感**。观感调整走决策者目验后的机动小片。
5. **不加 StyleProfile / 主题 schema / 插件体系。**

---

### S6 — 总验收

**完整用户弧线**：
> 选中符号 → 查看引用 → 跨文件核查 → 切历史 commit → 重新查询 → 返回原位置

bench 增 M7 节（**只追加**）；`m7-interactive-test-plan.md`；12 通道全家福；
真实 RA × Safe/Trusted × 依赖可得性矩阵；backlog 结转。

---

## §4 派发顺序

```
G0  最先（M6 Relations 真机执行门——地基没验过不往上盖）
S0A 导航正确性（References 的前置条件）
S0B Exact stale-cache 探针（独立小片，与 S0A 分开验收）
S1  spike 在 S0A 之后（要在正确的入口身份上问语义），Exact + Fuzzy 两组
S1 → S2 → S3 → S4（严格串行：消费者先行，Exact 最后提升）
    ※ S3 只有在 S1 的 Fuzzy 组结果支持时才可派发
S5A References UX，在 S4 之后（要等结果面稳定）
S5B Reader 视觉设置，独立，可任意提前
S6  依赖全部
推荐：G0 S0A S0B S1 S2 S3 S4 S5A S5B S6
```

---

## §5 风险预警

1. **S0A 是本轮唯一动 ContentIndex 结构的片**：新增字段不进 dump，
   但 extractorVersion 必须 bump。**canonical dump 零 diff 是硬门**。
2. **S0A 的 gold 影响需实跑确认**：`GoldSet:193` 的查询点**必须拆开**
   （报告位置用 `range.lowerBound`、resolve 用 `nameRange.lowerBound`），
   **拆开后 gold 条目理论上零改动——但必须实跑双语料确认，不能推理了事**。
3. **S1 spike 的规模数据决定 S3 的可行性**：常见短名称可能在语义验证前耗尽候选 cap。
   **先得数据再冻结预算**，不预造 LSP streaming。
4. **S3 最容易退化成"Callers 的别名"**：验收必须有**"引用但不是调用"的样本**，
   否则做出来的是重复功能。
5. **S4 的 Exact/Fuzzy 去重不能隐藏来源**：同位置 Exact 胜出，
   但**必须保留"heuristic also matched"**，否则用户不知道两条证据链都命中了。
6. **S5B 的配置化不是调观感**：默认值等于当前硬编码值，否则会把"搬家"和"改设计"
   混在一起，出问题无法归因。
7. **G0 可能查出 M6 的真问题**：exact Relations 只被 fake provider 覆盖过。
   若真机 G1–G6 发现 FAIL，**停下来报告，不要顺手修**——那是独立片，
   而且会影响 S4 的设计前提。
8. **S1 的 Fuzzy 组可能否决 S3 的现有设计**：若 prototype 显示
   `matchesPerFile=200` / `totalMatches=5000` 在语义验证前就吞掉有效引用，
   S3 要先改设计（提 cap？两阶段查询？），**不能带着已知缺陷往下做**。

---

## §6 验收铁律（沿用 m6-plan-v4 §6 十条）

1. "修前会失败"是硬性交付物
2. UI 断言必须表达可见/几何正确
3. 断言不得触发 AppKit 布局物化
4. 间歇缺陷连跑 ≥20 次
5. git 与非 git 双语料都验
6. 诚实性红线（启发式不冒充 exact、nil 字段不显示、覆盖缺口如实标）
7. determinism 硬门（gold nostrong=0、dump 零 diff、禁 RECORD）
8. **环境盲区互补**：Codex 环境 `sandbox-exec` 可用性不稳定，
   真实 RA 断言**它报的"全绿"可能来自 skip**，监工必须真机复核。
   **real provider skip 一律记 BLOCKED，不记 PASS。**
9. 否定性/对比性事实断言的证据标准：列了目录 + 看了全部相关分支才能下结论
10. 覆盖面要数，不是数量要数；**fixture 也要问"它能不能触发被测路径"**

### §6.1 本轮专属红线（来自合并来源，全部采纳）

- 同名但不同 binding 的引用**不得混合**
- comment / string **不得伪装成引用**
- **必须包含至少一种"引用但不是调用"的样本**
- Exact/Fuzzy 去重后 Exact 优先，**但不能隐藏 Fuzzy 来源**
- 切 profile / commit / trust / generation 后，**旧结果不得发布**
- Safe 模式没有 Exact 时**仍能给出诚实的 Fuzzy 结果**
- **计数文案按 §2.2 的四态合同**；truncated 时**不得声称真实总数**
- **不增加 `ReferenceStore` / `ReferenceGraph` / 新数据库表 / 通用语言框架**

---

## §7 通用约束（照抄进每片派发词）

无头 `swift build && swift test` 全绿（基线 **323**，只增不减）；`ci.sh` 通过；
Swift 6 零 warning；**12 通道用 `scripts/run-self-tests.sh` 跑**（不写 `for` 循环）；
双语料 gold nostrong=0；canonical dump 零 diff；**禁 RECORD**；
design F2.3 单击 Pin 语义；**只读铁律**；诚实性文案 tokens 零改动；
空载内存 <100MB（由 `--self-test` / `--self-test-reading` 独立进程守）；
`--self-test-open` **必须喂真实存在的文件**（根目录**没有** README.md）；
不改 `Prototypes/`；**不要 `git checkout --` 未提交文件**；每片不 commit。

---

## §8 备选路线（若目标变化）

- **公开 beta 优先**：M7 应改为"发布与安全硬化"（正式签名、公证、stapling、
  Gatekeeper、真实 RA 生命周期），References 延后
- **语言覆盖优先**：只选 TypeScript 或 Python **之一**做完整 vertical slice，
  References 延后
- **书签与历史锚点**：有产品价值，但应独立成里程碑，不能顺带塞入

---

## 附录 A：点击定位缺陷的实测证据（监工 2026-07-28 探针）

对 `fn f() { Config::set(ConfigKey::Backend, 1); }` 调 `session.tokenRange`：

```
click=Config     offset=13  text=[Config::set(ConfigKey::Backend, 1)]
click=set        offset=21  text=[Config::set(ConfigKey::Backend, 1)]
click=ConfigKey  offset=25  text=[Config::set(ConfigKey::Backend, 1)]
```

三个不同点击位置**全部返回整个调用表达式**。

---

## 附：关键实现文件

- `Sources/CodeInsightCore/Calls.swift`（`:10-18` UnresolvedCall，S0 加 nameRange）
- `Sources/CodeInsightRustExtractor/RustCalls.swift`（`:24` macro、`:43` call_expression）
- `Sources/CodeInsightRustExtractor/RustExtractorInfo.swift`（extractorVersion 6→7）
- `Sources/CodeInsightEngine/Resolver.swift`（`:196` 命中判定、`:205` 最短匹配）
- `Sources/CodeInsightEngine/CanonicalDump.swift`（`:63/:65` **只读，绝不让 nameRange 进 dump**）
- `Sources/CodeInsightEngine/GoldSet.swift`（`:193/:296` 用 call.range 作查询点——S0 复核点）
- `Sources/CodeInsightEngine/SnapshotSearch.swift`（`:96` search，S3 复用）
- `Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift`（`:133-134` 局部索引、`:235` viewport 查询，S2 复用）
- `Sources/CodeInsightExact/ExactProvider.swift`（S4 加 `.references`）
- `Sources/CodeInsightAppModel/ContextWindowModel.swift`（`:255` 早退）
- `Sources/CodeInsightAppModel/ExactCoordinator.swift`（`:20` ReuseKey 缺内容身份，S0 stale-cache 测试）
- `Sources/CodeInsightReaderCore/ReaderSettings.swift`（`:15-31` S5 收纳处）
- `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`（`:292/:976/:1070/:1079` 硬编码常量）
