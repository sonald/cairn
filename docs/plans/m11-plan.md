# M11 实现计划 v15：Reading Comfort（折叠、统一入口与阅读器基本功）

> **v15 收敛修订。** perf observer 明确为 `@Sendable`，由 harness 注入并写入其私有、锁保护的单一
> collector；在 detached completion 后以同锁建立 happens-before 才读取 JSON，普通路径为 nil。无公开类型、
> global registry、第二消解或数据竞争。
>
> **v11 收敛修订。** Reading Set 只接受可冻结 source + 可 materialize 的 location seed，
> dependency/worktree/commit provenance 分开；active Reading Set 不触 file anchors；perf observer 只包
> 生产消解调用；V0 从干净 checkout 可执行。无 registry/factory/stable identity/第二 store。
>
> **v10 依据 v9 独立评审修订。** M11D 改为最终 v1 tagged tab union：Reading Set 的冻结 source、
> contentID/revision provenance、冻结展示证据和 active entry 跨重启恢复；入口严格为
> Relations 与 Trail，tokio `spawn` 固定五段为硬验收（§3.16/§3.20/R3/M11D）。fold fixture 统一
> Overview 数量，并把候选消解 `resolutionMs` 写入 perf JSON/runner gate；V0 补 repo-local cache 的
> 可执行命令矩阵、精确 deny-list 与 provision 常量审计。无 registry/factory/stable identity/第二 store。
>
> **v9 依据第八轮评审修订。** 主要变更：**不再把已确认的 M11D 写成待确认 gate**；补齐
> `TabContent` 的最小 seam、Reading Set 连续 excerpt 流、切片、依赖与 V0 验收（§2/§3.20/§4/§5）；
> fold 性能协议改成明确的 `control|fold` 两进程模式、合法 JSON、后台 25ms 采样与固定窗口
> （§3.2(4)）；固定语料把候选/接受/渲染数、kind/depth 分布和 preset 写进 manifest 并在计时前
> 断言（§3.2(4)/F0）；session 改为一个全局 target revision 与 tab anchor provenance（§3.16）；
> V0 改审计记录的 M11 base...HEAD、index/worktree/untracked，并把产品变更 allow-list 与受保护
> deny-list 分开（§4）。同时清除旧 projector、tie、scope/session 风险文案，补 R0→C1 依赖及
> Palette 空查询的既有真值源、唯一 `memberCounts` 顺序。
>
> 历史摘要只供追溯；现行合同以各节最新文本为准，§3.16/§3.20 已由 v13 完整取代旧会话/Reading Set
> 叙述。本版逐节对 v9 做存在性对比，无静默删节。

> **v8 历史修订摘要。** 它补了 fold seam、并列冲突、导航覆盖项、`rg` 门禁、性能与会话的
> 初版合同；范围裁决以本版 §2/§3.20 为唯一现行文本。
> **Fold seam 补初始化**：`package` designated init + 保留原签名 `public` convenience，projector
> 只从 `document.foldRegions` 读、参数改 `renderedFoldIDs`（§3.1，评审 P1）；
> **并列改"真重复去重 / 矛盾整组拒绝"**，去 ordinal（§3.0，评审 P1）；
> **导航展开转移表**守卫 forced 两集合不交叠（§3.8，评审 P1）；
> **rg 门禁处理退出码**（`set -e` 下 1=PASS/0=FAIL/≥2=工具错，§3.1，评审 P1）；
> **性能 runner 改指 `codeinsight-app`** + 具名 perf 入口 + JSON 输出 + 窗口内持续采样（§3.2(4)，
> 评审 P1）；**F0 预算先量真实 N**（O(n²) 与 10⁵ 互相排斥，§3.0/F0，评审 P1）；
> **coherent checkpoint 诚实对待 inactive tabs**（保留旧 contentID provenance + 降级，§3.16，
> 评审 P1）；Palette 查词合同（§3.13）、`memberCounts` 固定展示序（§3.0）、V0 受保护产物审计
> （§0/§4），三组 P2。
>
> 上一轮（v7）已并保留：`package highlightWithFolds` + `foldRegions` 传输 seam、覆盖项状态方程、
> ⌘F 文档代际守卫、coherent checkpoint、可执行性能门禁、ruler 可见性、Focus 例外、F0 提取预算。
>
> **修订纪律（v5 新增，延续）**：v3 丢了 Focus 语义、v4 丢了折叠状态作用域，两次都是重构时
> 静默丢节。此后每版必须**逐节对上一版做存在性对比**，删节要在本表写明理由，不得静默消失。
> 本轮逐节对 v8 做了存在性对比，无静默删节。
>
> 历史：v5 新增渲染集归一、折叠状态作用域、附件运行机制与宽度不变量、锚点隐藏恢复、排序+贪心、
> `cfgTest` container 兼容、Focus scope、会话两锚点、`rg` 门禁改双匹配。v4 占位符改
> `NSTextAttachment`、单遍 projector、`FoldKind` 去 `Comparable`、header/body 边界表、会话两
> 锚点、`replayOffset` 标量校验。v3 修正坐标迁移面（4→21 处）、optional 换算、`FileTreeModel`、
> `FallbackKind`、R0→F6 依赖、TextKit 2 换行前提实测推翻。
> v2 删除 `CommandRegistry`、⌘F 逻辑命中改 `ByteRange`、复制始终返回源码、折叠数据不按行数裁剪。

## §0 事实基线（HEAD = `2569e70`；带 ✅ 者为本轮/上轮**实测**，非推断）

- **git**：M11 产品实现起点为 `2569e70486e93cc3e547201de1c80657d98f0adf`；
  `origin/main...HEAD` = behind 0 / **ahead 4**。计划已提交，P0 原型证据在首个切片提交中纳入。
- `swift-tools-version: 6.0`（`Package.swift:1`）→ Swift 6 语言模式。
- ✅ **`enum K: UInt8, Comparable` 编不过**（`evidence/m11/swift6-enum-comparable-probe.*`）：
  `error: type 'K' does not conform to protocol 'Comparable'`。无 raw value 的 enum 才自动合成。
  → v3 的 `FoldKind: UInt8, Sendable, Comparable` 是编译错误。
- ✅ **纯字符串占位符可被半选**（`evidence/m11/placeholder-selection-probe.*`）：
  `{ … 42 lines }` 长 14，`setSelectedRange(15,3)` 原样落在 `{15, 3}`。
  **`NSTextAttachment` 长度恒为 1**，字符为 `U+FFFC`，无法半选。
  → v3 "占位符是整体 run，不允许半选" 是声明而非行为。
- ✅ **裸 `NSTextAttachment` 拿不到 view provider，且 `bounds` 不生效**
  （`evidence/m11/attachment-*probe.*`）：`textAttachmentViewProviders.count == 0`；
  整行排版宽度在 `bounds` 取 20 / 200 时都是 **34.3pt**（= 只有 "ABCD" 的宽度），
  改为 `image` 宽 200 后变 **233.3pt**。
  → 两条推论：**(a)** 必须显式选定运行机制（注册 provider / 私有 attachment 子类 / image·cell），
  裸 attachment 什么都不画；**(b) 宽度确实参与断行，"UTF-16 长度不变" ≠ "布局不变"**——
  v4 §3.2 "映射对计数免疫" 只对**映射**成立，对**布局**不成立。
- ✅ **TextKit 2 换行**（`evidence/m11/textkit2-wrap-probe.*`）：3 个段落在 wrap 开关两种状态下
  **都只有 3 个 `NSTextLayoutFragment`**；开 wrap 后长段落是 1 个 layout fragment 内含
  **14 个 `NSTextLineFragment`**。→ "换行使一个源码行产生多个 layout fragment"不成立。
- **Reader 渲染**：TextKit 2（`CodeInsightReaderUI.swift:450`），`isEditable = false`（`:1235`），
  `isSelectable = true`（`:1236`），`isHorizontallyResizable = true`（`:1241`）。
- **坐标换算点共 22 处**（本轮 grep 全量，v4 写"21 处"但列了 22 个行号，口径更正）：
  `165`、`466`、`512`、`534`、`548`、`575`、`597`、`639`、`653`、`669`、`689`、`792`、`832`、
  `848`、`860`、`870`、`890`、`912`、`925`、`953`、`1046`、`1260`。
  其中 **8 处直接访问 `document.byteUTF16Map`**（v4 写"6 处"但列了 8 个，口径更正）：
  `165`/`512`/`534`/`575`/`597`/`639`/`953`/`1260`——**删掉 `ReaderTextView` 的存储属性
  覆盖不到它们**。
- **另有 3 处 `ByteUTF16Map` 类型引用**：`157`（`RenderingAttributesCoordinator.map`）、
  `430`（`ReaderTextView.byteUTF16Map`）、`1272`（`applyTypography(map:)` 形参）。
  → 门禁必须同时匹配 **`ByteUTF16Map|byteUTF16Map`**，只匹配小写会漏掉 `157` 与 `1272`。
- **`SnapshotSearch.asciiFold`（`:613`）与 `literalRanges`（`:488`）都是 `private static`**，
  **不能直接复用**；要复用须先提取为 Core 的 package 级函数。
- **两个方向不能混谈**：`enumerateVisibleLayoutFragments`（`:1024`）、validator
  `style(fragment:in:)`（`:205`）是 **display → source**；`occurrenceNSRanges`（`:948`）、
  `applyTypography`（`:1270`）、`reveal`/`restore` 是 **source → display**。
- **`ByteUTF16Map` 用 optional 表达失败**：`byteOffset(forUTF16:) -> Int?`、
  `nsRange(byteLowerBound:upperBound:) -> NSRange?`、`utf16Offset(forByte:) -> Int?`。
  → **`utf16Offset(forByte:)` 是现成的"字节是否落在合法标量边界且在范围内"判据。**
- **保险丝**：`documentMatchesStorage`（`:1259`）只比长度，**发现不了等长错映射**。
- **复制走原生响应链**：Edit 菜单 Cut/Copy/Paste/Select All `target = nil`
  （`CodeInsightApp.swift:5740`–`:5760`）。
- **结构数据**：`ReaderDocument.outlineFacets`（`CodeInsightReaderCore.swift:132`）带
  `kind`/`name`/`range`/`nameRange`/`depth`，由 highlighter 的**同一次 walk** 产出（`:489`）。
  **`facet.range` 是完整声明范围**（含 header），不是内部 body。
- **Gutter**：`ReaderRulerView`（`:1350`）自绘，列宽 `:990`–`:1009`；无可点击区域。
- **无换行**：`widthTracksTextView = false` + 无限 `containerSize`（`:1247`）。
- **Escape 已被占用**：`escapeHandler`（`:486`）在 `occurrenceCount > 0` 时消费。
- **菜单栏**：`makeMainMenu()`（`CodeInsightApp.swift:5658`）；已有 `validateMenuItem(_:)`
  （`:5629`）；Open Recent 由 delegate 填充（`:5704`）；Back/Forward 有隐藏备用项（`:5803`）。
- **文件内查找不存在**；**⌘T 只搜符号**（`SymbolSearchPanelModel.swift:57`）；无跳转到行号。
- **可复用的搜索语义**：`SnapshotSearch.asciiFold`（`:613`）= `A-Z → a-z`，**其余字节原样比较**
  ——这是本项目已有的、有定义的大小写不敏感语义。
- **可复用的异步模式**：`SearchPanelModel` 用 `requestID` 去抖 + **模型持有的 `searchTask`
  （`Task`，`:47`/`:132`/`:163`）**，它消费 Engine 返回的 stream；**模型本身不创建 `detached`
  worker**——detached 由 Engine 的 stream 内部持有（与 §3.14 一致）。R0 为此复用 `requestID`
  去抖 + 模型持有并取消 worker 的既有形状。
- **`FileTreeModel`**（`AppModel.swift:169`）已驱动 sidebar（`MainWindowController.swift:2484`），
  **不依赖索引完成**；`session.manifest` 依赖 `.ready`。
- **Tab**：`TabStripModel.Tab` 只有 `fileURL` + `scrollByteOffset` + `selectionByteOffset`
  （`TabStripModel.swift:6`），**无 id**，**两个位置**，且 inactive tab 只有裸 offset。
- **导航落点的既有捕获/恢复对**：
  - `JumpRecord`（`NavigationHistory.swift:567`）：`path`/`contentID`/`byteOffset`/`line`/
    `column`/`symbolAnchor`/`snapshotID`/`revision`。**只能表达一个位置。**
  - 捕获 `currentJumpRecord()`（`MainWindowController.swift:2132`）——**只覆盖 active tab**。
  - 恢复 `replayOffset`（`AppModel.swift:1083`）：第一档
    `if Int(record.byteOffset) <= document.bytes.count` **不比较 `contentID`、不校验标量边界**，
    且**只返回 offset**，调用方无从知道走了哪一档。
  - **producer 审计**：`MainWindowController.swift:2149` 产 `contentID: nil, line: 0`；
    `AppModel.swift:982` 产 `contentID: nil, line: 1`。
- **`SnapshotID.rawValue: UUID`**（`Manifest.swift:3`）→ 不可跨启动持久化；可持久化的是 `revision`。
- **验收基础设施**：12 条 self-test 通道（`scripts/run-self-tests.sh:101`–`:112`）、`ci.sh`、
  `stress-test.sh`、`run-gold-gates.sh`、`provision-corpora.sh`。
  **本轮新增 2 条通道，全都具名（评审 P2-5）**：`--self-test-projector`（F1：恒等投影回归 +
  `ByteUTF16Map|byteUTF16Map` 门禁）、`--self-test-fold`（F2：折叠附件 / 状态作用域 / 锚点）。
  二者 src 端都在 `run-self-tests.sh` 注册，V0 的 "12+2" 指既有 12 条 + 这 2 条，
  **没有第三条未命名通道**。
- **文件规模**：`CodeInsightApp` 7258、`MainWindowController` 4085、`CodeInsightReaderUI` 1438。
  本轮不拆大文件。

---

## §1 成功合同

1. **折叠只改变可见性，不改变事实**：折叠区里的搜索命中、diff hunk、当前符号 occurrence 如实
   暴露；导航落点在折叠区内自动展开最小链；**复制永远得到源码**。
2. 折叠柄、阅读高度档、Focus 三种入口都能不离开键盘完成。
3. 占位符承载看不见的信息：规模、内容构成、藏了什么要紧的。
4. **命令没有第二真值源**：palette 命令模式直接遍历运行时 `NSMenu` 树。
5. ⌘F 的逻辑命中数永远等于真实命中数；Escape 优先级明确。
6. 会话恢复不伪造精度：降级路径可见且**调用方知道自己走了哪一档**。
7. **Reading Set 是冻结、可恢复的非文件 tab**：固定 trace 的五段及 provenance/evidence 跨重启
   不漂移；与文件 tab 一样受 tab 生命周期管理。

---

## §2 范围

**M11A 折叠**：F0 提取、F1 坐标 seam、F2 gutter 与占位符、F3 复制与选择、F4 高度档、F5 Focus、
F6 诚实合同。**M11B**：C1 Palette。**M11C**：R0 ⌘F、R1 作用域头、R2 Copy path:line、
R3 会话恢复、R4 Settings + ⌘± + 换行。**M11D Reading Set**：`TabContent` 非文件文档原语、
连续 excerpt 阅读流及 Relations/Trail 入口（§3.20）。**P0 原型**、**V0 总验收**。

**范围裁决（已定，不设 gate）**：M10 计划 `§2（m10-plan.md:109）` 与 D6
（`evidence/m10/semantics.md:81`，用户于 2026-08-06 确认）把 **Reading Set 与 `TabContent`
归入 M11**。本计划以此为范围合同：**M11D 是完整、必做的实现切片**；不得静默移至 M12。
若未来要变更，须先有新的用户裁决并同时修改本范围、§3.20、§4、§5、§6 和 V0；在该裁决出现前
不得开始宣称 M11 完成。其余切片可先推进，但 V0 依赖 M11D。

**明确不做（其余）**：Symbol Lineage → M12+；书签 F5.7；
按相关性折叠；Minimap；Rust Lens 专项；TS/Python 语言面；中文本地化；不拆大文件；
不建 `CommandRegistry`（§3.12）；⌘F 不做正则/全词（§3.14）；
**不新增公开 registry / factory / 第三套结构模型**——本轮只加一个 projector（§3.1）、一份
私有 session shape（§3.16），以及 D6 所必需的一个 `TabContent` seam、`ReadingSetExcerpt` 与其嵌套
`FrozenInspectorDisplay`（两入口复用所必需的唯一 codec/display seam，§3.20）。除 `Tab.fileURL: URL → URL?` 的**有意 source-breaking optionalization**外，不新增 public
类型或 API surface；它的包内与发布消费者迁移审计是 M11D 验收。§3.0/§3.1 确需新增 `FoldID`、`FoldKind`、`FoldRegion`、
`FoldSummary`、`DisplayPosition`、`SourcePosition`、`DisplayMap`；§3.20 仅新增 `TabContent`、
`ReadingSetExcerpt` 与嵌套 `FrozenInspectorDisplay`。跨 target 所需者一律 `package`（不写 `public`）；仅 ReaderUI 内部使用的
`DisplayMap` 与两个 Position 词汇用 `internal`。projector 与 session shape 保持文件内私有，
没有任何新 public type。

---

## §3 设计裁决

### §3.0 折叠类型模型：边界、去重、身份

```swift
// 跨 target（Core ⇄ ReaderUI）所需类型用 package，不写 public（§2）。
package struct FoldID: Hashable, Sendable { package let rawValue: UInt32 }

// 不写 Comparable：Swift 6 实测不为 raw-value enum 合成（§0）。
// 优先级即 rawValue，比较处私下用 rawValue。
package enum FoldKind: UInt8, Sendable {
    case cfgTest = 0, container = 1, declaration = 2, block = 3,
         comment = 4, imports = 5, attributes = 6
}

package struct FoldRegion: Sendable, Equatable {
    package let id: FoldID
    package let kind: FoldKind
    package let headerRange: ByteRange   // 永远可见
    package let bodyRange: ByteRange     // 可被隐藏，与 headerRange 不相交
    package let outlineDepth: Int
    package let summary: FoldSummary
}

package struct FoldSummary: Sendable, Equatable {
    package let hiddenLineCount: Int
    package let memberCounts: [OutlineKind: Int]
    package let itemCount: Int?
    package let leadingText: String?
}
```

**`memberCounts` 的展示顺序固定（评审 P2）**：`[OutlineKind: Int]` 的 `Dictionary` 遍历顺序
不稳定，`7 fn · 2 const` 可能跨进程变序。renderer 必须按现有 `OutlineKind` 的唯一顺序
`mod, trait, impl, struct, enum, typeAlias, const, static, fn, method` 格式化，**零计数省略**；
不按字典迭代，也不另建摘要类型。**测试**：以不同插入顺序构造内容相同的字典，断言占位文案
逐字节一致。

**header / body 精确边界（评审 ② 上半，v3 缺失）**：

| kind | headerRange | bodyRange |
|---|---|---|
| `declaration` / `container` / `cfgTest` | 声明起点 → 开 `{`（**含** `{`） | 开 `{` 之后 → 闭 `}` 之前（**不含**两个花括号） |
| `block`（花括号型） | 关键字起点 → 开 `{`（含） | 同上 |
| `block`（match arm） | arm 模式起点 → `=>`（含） | `=>` 之后 → arm 结尾（不含尾逗号） |
| `imports` | 第一条 `use` 语法节点的完整 extent | 首节点结尾之后 → 最后一条节点结尾 |
| `comment` | 第一条注释语法节点的完整 extent | 首节点结尾之后 → 注释运行结尾 |
| `attributes` | 第一条 `#[...]` 语法节点的完整 extent | 首节点结尾之后 → 属性运行结尾 |

折叠后闭合花括号保持可见（`fn f() {⟦…⟧}`）；`imports`/`comment`/`attributes` 折叠后保留首项。

**边界按语法节点切，不按物理行（评审 P2-1）**：`use` 语句、`#[...]` 属性、块注释都**可以跨多行**，
按"第一行"切会把一条语句劈开。精确规则：这三类的候选是一串**相邻同类节点**；
`headerRange` = **第一个节点的完整 extent**（可跨行），`bodyRange` = 第一个节点结尾之后
→ 最后一个节点结尾。`block` 的 closure **没有关键字起点**，`headerRange` 从参数列表
`|…|` 的起点到开 `{`（含）；无花括号的表达式体 closure **不产出 `FoldRegion`**。

**单个跨行节点：禁止空 body（评审 ③）**：三类候选**可能只有单个节点**（一个跨多行块注释、
一条跨行 `use`、一个多行 `#[...]`）。此时首节点即末节点，`bodyRange` 为**空区间**——既
隐藏不了内容也不会出现折叠柄，与 F0 点名的"跨多行验收"冲突。裁决：
**`bodyRange` 为空 → 该候选不产出 `FoldRegion`**（F0 断言），跨行块注释内部折叠不进本轮
范围（不为此单独发明"折叠注释内部"语义）。只有**两个及以上**同类相邻节点才产出 folding
（`bodyRange` 至少覆盖若干完整行）。由此"单条 use 折叠成 1 条"是不存在的语义，`imports`
合并折叠只作用于 ≥2 条 runs。

**交叠消解：排序 + 贪心接受，不做 pairwise（评审 ⑥）**

v4 的"两两比较丢弃败者"是**顺序相关**的：三个互相链式交叠的区间，按不同检查顺序会得到不同
的 survivor 集合；而"同 fixture 跑两次"发现不了——extractor 的产出顺序是固定的。改为：

1. **先按 winner tuple 全序排序**候选：
   `(kind.rawValue ↑, hiddenLineCount ↓, headerRange.lowerBound ↑, headerRange.upperBound ↑,
   bodyRange.lowerBound ↑, bodyRange.upperBound ↑, outlineDepth ↑)`。
   语义：kind 优先级高者先被考虑；同 kind 时体量大者先。
   **全序补齐（评审 ②）**：仅 `(kind, hiddenLineCount, bodyRange)` 不是全序——同 kind 且
   body 相同者 `hiddenLineCount` 必然相同，但 **`headerRange`、`outlineDepth`、`summary`
   仍可不同**，排序键完全相等时留下谁仍取决于 extractor 输入顺序。故把两个 header 界、
   `bodyRange` 双边与 `outlineDepth` 都纳入比较键，并**逐字段稳定**（见第 3 步断言），
   之后先按完整几何键分组：全字段相同者去重，几何相同但摘要不同者整组拒绝（见下）；
   不靠输入顺序或 `assertionFailure` 决定结果。
2. **贪心接受**：依次取候选，若它与**已接受集合**保持 laminar（与每个已接受区间要么不相交、
   要么严格嵌套），则接受；否则丢弃。结果只由 winner tuple 决定，与 extractor 产出顺序无关。
   - 同范围完全相同者天然由第 1 步定序、第 2 步淘汰（后者与前者既不相离也非严格嵌套）。
   - **完全并列的唯一处理（评审 ③，区分"重复"与"矛盾"）**。几何键（kind/body/header/depth）
     相同并不自动等于"同一候选"——**摘要不同就是矛盾事实**。分两档：
     **(a) 全字段相同（几何 + summary 全等）= 真重复**：确定性去重，只留一个（它们本就不可分）。
     **(b) 几何相同但 `summary` 不同 = 矛盾**：extractor 对同一区间给了互相矛盾的事实。此时
     **整组拒绝**：该区域**不产出 FoldRegion**（不显示任何折叠，也就不会展示错误摘要），记一条
     诊断日志。**不做 ordinal 择优**——ordinal 只解决确定性，不解决真实性，会稳定地展示错误
     摘要。**YAGNI**：不需要 ordinal 机制；全字段去重靠相等性即可，矛盾靠整组拒绝。
     **不依赖 `assertionFailure` 做控制流**（release 中它不是控制流）；矛盾时 release 也执行
     "整组拒绝"。
   - 已知冲突：`cfgTest`/`container`（`#[cfg(test)] mod tests`）、`declaration`/`block`
     （整个函数体就是一个 `match`）、同 kind 部分交叠。
3. **排列测试（评审 ⑥）**：对候选列表做若干次确定性重排（固定种子的置换），
   断言接受结果**逐字段相同**。这才能抓住顺序相关性，`两次跑同一 fixture` 抓不住。
4. **laminar 校验**：接受完成后线性复验，DEBUG 下违反即 `assertionFailure`。
5. **最后排序分配身份**：按 `(bodyRange.lowerBound ↑, bodyRange.upperBound ↓, kind.rawValue ↑)`
   全序排序，`FoldID.rawValue` = 下标。**分配必须在消解之后**，否则丢弃会留下 ID 空洞
   并使身份不稳定。同 `contentID` 必得同一组 ID。

**`cfgTest` 的下游语义（评审 ⑤）**：去重会保留 `.cfgTest` 丢弃 `.container`，
因此 **`cfgTest` 在所有下游一律按 container 对待**——§3.15 的 kind 兼容表含
`cfgTest ↔ mod`，§3.9 的 Focus scope 选取把 `cfgTest` 计入 container。
否则 tests module 的作用域头与 Focus 都会失效。

**体积过滤不在数据层**：`FoldRegion` 无条件产出（R1 要用）。
但**两处展示/自动策略都要过滤 `hiddenLineCount < 2`**（评审 P2-4）：
F2 不画折叠柄，**且高度档/Focus 的自动折叠跳过它们**——否则会出现"自动折叠了却没有柄"
的一行占位符。

**七种 kind 的占位内容**：

| kind | 占位符主体 |
|---|---|
| `declaration` | `leadingText`（有则优先）+ `hiddenLineCount` lines |
| `container` | `memberCounts` 摘要（`7 fn · 2 const`）+ `hiddenLineCount` lines |
| `imports` | `itemCount` imports |
| `comment` | `leadingText` + `hiddenLineCount` lines |
| `attributes` | `itemCount` attributes |
| `cfgTest` | `tests` + fn 数 + `hiddenLineCount` lines |
| `block` | match 时 `itemCount` arms，否则 `hiddenLineCount` lines |

### §3.1 单遍 projector 是唯一 seam（评审 ①）

**路线**：显示投影（body 换成占位附件），非 `NSTextContentStorage` 代理替换 paragraph。
`ReaderDocument` 的**既有字段与语义完全不变**（`bytes`/`contentID`/`highlightSpans` 仍是
渲染的真值源）；折叠加**唯一一个新承载字段** `foldRegions`（见下）。

#### Fold 数据的传输 seam（评审 P1，v6 未定义）

`FoldRegion` 来自 Core 的**同一次 walk**，却要交到 ReaderUI；而 `highlight(bytes:)`
是 `public`（`CodeInsightReaderCore.swift:424`），返回固定元组、**不能**在其签名里暴露
`package FoldRegion`；`DocumentLoader`（`:719`）当前也不承载 folds。**唯一 owner 与路径**：

- **owner**：highlighter 的 walk（产出 `outlineFacets` 的同一次）。
- **路径**：Core 新增一个 **`package` 可见的 walk 入口**，返回既有元组 **+ `folds: [FoldRegion]`**，
  例如 `package func highlightWithFolds(bytes:)`。`public func highlight(bytes:)` 改为调用它并
  丢弃 `folds`（**公开签名不变**）。二者**同一次 parse**，不二次解析。
- **承载 + 初始化（评审 P1，v7 缺）**：`ReaderDocument` 是 `public final class`、有
  `public init`（`CodeInsightReaderCore.swift:126`），新增 `package let foldRegions` 后每个
  designated initializer 都必须初始化它，但 **`public init` 不能接收 `package` 类型参数**。
  裁决：**新增 `package` designated init**（参数含 `foldRegions`），并**保留原签名 `public`
  convenience init**（`foldRegions: []` 走默认空路径）——公开调用方签名完全不变，`package`
  路径由 Core 内部（DocumentLoader）使用。F0 断言：旧 `public init` 仍可调用且 `foldRegions`
  为空；`package` init 能装配 folds。
- **覆盖两条加载路径**：`DocumentLoader.load`（`:708`）与 `loadSyntax`（`:745`）都走
  `highlightWithFolds`，经 `package` init 把 `folds` 装进 `ReaderDocument`。**同步与异步语法
  加载都覆盖**，F0 各一断言，避免一条路径旁路结构数据。
- **ReaderUI 消费（消除双真值，评审 P1）**：projector 的**折叠** `FoldRegion` **只**来自
  `document.foldRegions`；其另一个参数是 `renderedFoldIDs`（**渲染集，只含 FoldID，不含定义**，
  由 §3.8 状态方程给出）。**projector 绝不接收 `folds: [FoldRegion]` 作为第二输入**——那会与
  `document.foldRegions` 形成两个真值。签名形如 `project(document, renderedFoldIDs, theme)`。

**根治手段：storage 与 map 由同一遍 segment walk 同时产出。**
v3 分两步构建，长度保险丝只能发现长度差、**发现不了等长错映射**。改为一个文件内可见的 projector：

```
project(document, renderedFoldIDs, theme) -> (attributed: NSAttributedString, map: DisplayMap)
```

沿源字节顺序走 segment（可见段 / 折叠段交替），一次同时 append 文本与累积映射条目，
末尾原子安装。两个产物**由构造保证一致**，而不是靠事后校验。长度保险丝保留为纵深防御。

**边界纪律（评审 ①）**：**不从 Core 删除 `ByteUTF16Map`**（Engine/Core 仍需要它）。
改为 `DisplayMap` 私有持有它，并加**门禁**：`rg` 断言 `Sources/CodeInsightReaderUI/` 内
**除 `DisplayMap` 实现文件这一个例外文件外**，对 **`ByteUTF16Map|byteUTF16Map`**（区分大小写
两种都匹配，见 §0）的引用**零处**。门禁必须同时匹配大写类型引用与小写符号引用——
只匹配 `byteUTF16Map` 会漏掉 §0 列出的 `157`（`RenderingAttributesCoordinator.map`）与
`1272`（`applyTypography(map:)`）这两处**大写类型引用**，它们不在 `document.` 路径上，
删存储属性覆盖不到。§0 已清点是 **8 处**经 `document.` 的直接访问 + **3 处 `ByteUTF16Map`
类型引用**；F1 迁移完成后 ReaderUI 内**恰好只剩 `DisplayMap` 实现文件一处**（其私有
backing）与 `ByteUTF16Map` 有关，故门禁许可名单精确到该单文件。

**P0：门禁必须是可执行命令，不是描述（评审 P0）。** 实现文件具名为 `DisplayMap.swift`，
门禁命令（`ci.sh` / `run-gold-gates.sh` 各加一条，`--self-test-projector` 亦跑）：

```sh
# 必须显式区分退出码（评审 P1）：`ci.sh`/`run-gold-gates.sh` 都 `set -euo pipefail`，
# 裸 `rg` 零命中返回 1 会直接终止脚本，把 PASS 判成失败。不能用 `! rg`（会把 rg 的
# 基础设施错误 2 也当成功）。正确形状：
if out=$(rg -n 'ByteUTF16Map|byteUTF16Map' Sources/CodeInsightReaderUI/ \
            --glob '!Sources/CodeInsightReaderUI/DisplayMap.swift' 2>&1); then
  echo "$out"; echo "FAIL: 发现禁用 ByteUTF16Map 引用"; exit 1   # rc=0 → 命中 → FAIL
else
  rc=$?
  if [[ $rc -eq 1 ]]; then echo "PASS: 零命中";                  # rc=1 → 干净 → PASS
  else echo "FAIL: rg 基础设施错误 rc=$rc"; exit 1; fi           # rc≥2 → 工具错 → FAIL
fi
```

F1 完成判据：`CodeInsightReaderUI.swift` 里该模式**零命中**（§0 列的 22 处换算点中的
`document.` 直接访问与全部裸 `byteUTF16Map` 属性引用、加上 3 处 `ByteUTF16Map` 大写类型
引用，一并消失），`DisplayMap.swift` 是唯一允许持有 `ByteUTF16Map` 的文件。门禁收窄到
`DisplayMap.swift` 这一个 glob 例外，不写第二个。

**换算失败用 optional 表达**：越界、负 display offset、UTF-8 标量中间、UTF-16 surrogate 中间
都无语义，且持久化数据是信任边界，不能靠隐含 precondition：

```swift
// 两个 Position 是 DisplayMap 的返回值词汇，只在 ReaderUI 内使用，无跨 target 需要（评审 P2-4）。
internal enum DisplayPosition: Equatable, Sendable { case visible(Int); case hidden(FoldID) }
internal enum SourcePosition: Equatable, Sendable { case source(UInt32); case placeholder(FoldID) }

// ReaderUI 内部使用（internal），不进入公开面（§2）。
internal struct DisplayMap: Sendable {
    internal func displayPosition(ofByte: UInt32) -> DisplayPosition?
    /// O(log f + k)，f = 活动折叠数，k = 结果段数
    internal func project(byteRange: ByteRange) -> (visible: [NSRange], folds: [FoldID])?
    internal func sourcePosition(ofDisplay: Int) -> SourcePosition?
    /// 含被折叠部分，供复制使用（§3.3）
    internal func sourceRanges(forDisplay: NSRange) -> [ByteRange]?
    /// 仅可见源码段，供 viewport gating（§3.1）；与 sourceRanges 相反，跳过折叠 body
    internal func visibleSourceRanges(forDisplay: NSRange) -> [ByteRange]?
    internal var projectedUTF16Length: Int
}
```

**两类反向查询必须分开（评审 ④）**：`sourceRanges(forDisplay:)` **明确会展开隐藏源码**
（`folds` 填满整段），只适合复制取原文。若 `RenderingAttributesCoordinator` 复用它做
viewport gating，一个占位符位置就会把**整个巨型隐藏 body 的 spans / references 扫回来**，
折叠后的滚动性能不会改善。因此**新增 internal 的 `visibleSourceRanges(forDisplay:)`**——
只返回与 display 段可对应的**可见源码段**，占位附件位置返回空；它才是 viewport gating
与 counting 的入口。F2 断言：同一折叠，折叠后经 `visibleSourceRanges` 扫描的
`referenceScannedCount` **只随可见源码增长**，且随 `hiddenLineCount` 增大而**不增**（对比
`sourceRanges` 会随增大）——证明巨型隐藏 body 的引用不再被回扫。

**可测命题**：可见字节 b → `sourcePosition(displayPosition(b)) == .source(b)`；隐藏字节 b →
`.hidden(f)` 且 b ∈ f 的 `bodyRange`；占位附件位置 d → `.placeholder(f)`；
区间 r → `project(r).visible` 互不重叠且升序，其字节原像 ∪ `folds` 覆盖字节 ⊇ r；
**`visibleSourceRanges` 不含任何折叠 body 的字节、在占位位置返回空**（与 `sourceRanges`
对照断言，评审 ④）；
**非法输入返回 nil**（越界 / 标量中间 / surrogate 中间各一条断言）。

**恒等投影回归门禁**：无折叠时 22 处调用点对语料的结果与今天的 `ByteUTF16Map` **逐字节相同**。

### §3.2 折叠状态：逻辑集、渲染集、作用域与占位附件

本节由一个 **private fold-state reducer** 承载，不新增公开实体。

#### (1) 逻辑集 → 渲染集归一（评审 ①，v4 缺失）

高度档会**同时**激活嵌套区间：`Structure` 同时激活外层 `cfgTest` 与其内部的 `declaration`；
`Overview` 同时激活 `container` 与其内部 `declaration`。**projector 不能直接遍历逻辑集** ——
嵌套区间会产出套在隐藏文本里的附件。

**规则**：

- **`renderedFoldIDs = maximal(logicalFoldIDs)`**：即逻辑集中的极大元（不被逻辑集中任何其他区间包含者）。projector 只为渲染集
  产出附件与隐藏段。
- **内部逻辑状态保留**：外层展开后，内部区间**仍按其 baseline/override 处于折叠态**，
  立即以新的渲染集重新投影。展开外层不等于展开内部。
- **占位符摘要按逻辑集算**（`memberCounts` / `hiddenLineCount` 反映外层真实隐藏内容），
  不因内部也被折叠而重复计数。

#### (2) 折叠状态作用域（评审 ①，v3 有、被我在 v4 静默删除）

- **高度档是全局的**（跨文件保持）。
- **手动覆盖项按 `(fileURL, contentID)` 键值对隔离存于内存** —— 只按 `FoldID` 存会在切文件时
  碰撞，因为 `FoldID` 是文件内下标。
- **按 pair 隔离、新旧 pair 不互清（评审 P2-2）**：覆盖项以 `(fileURL, contentID) → 覆盖集合`
  分开存。**`contentID` 变化 ≠ 清空该 `fileURL` 的覆盖项**——那样切回旧 `contentID` 就命中
  不了缓存恢复，自相矛盾。正确语义：**新 pair** 从空覆盖项开始、按当前高度档重新推导；
  **旧 pair 保留原覆盖集合**，切回同一 `contentID` 时命中缓存恢复。恢复只按新旧
  pair 精确查找，不做任何"跨内容重放折叠区"（与拒绝发明 `StableSymbolID` 同一原则）。
  F2 断言：切走再切回旧 `contentID` 时覆盖集合原样归来；中途 `contentID` 变化不污染旧 pair。
- **不写磁盘。**

#### (3) 占位符 = `NSTextAttachment`（v3 纯文本方案作废）

实测（§0）：纯字符串占位符可被半选，且 v3 假设的"占位符必然终结于行尾、右侧有自由空间"
在 `if { … } else`、inline closure 等场景不成立。改用 **`NSTextAttachment`**：
长度恒为 1、字符 `U+FFFC`、**无法半选**（由长度保证，不是靠声明）；
每折叠对 display 长度贡献恒为 1，位置任意，不依赖后面有没有源码。

**运行机制必须显式选定（评审 ②）**：实测裸 attachment
`textAttachmentViewProviders.count == 0` 且 `bounds` 完全不生效。因此：

- **F2 的第一步是一个 spike**，在真实 `ReaderTextView` 上打通并证明四件事：
  provider（或私有 attachment 子类 / image·cell）的**创建**、计数变化时的**更新**、
  **点击展开**、**AX label 可读**。四条各一断言。spike 未通过前不写 chip 视觉。
- **hit testing 归属要裁决**：provider 若返回视图会截获鼠标。二选一并断言：
  provider 自己执行展开；或 provider 让出 hit testing 交回 `NSTextView`，由既有
  `clickHandler` 路径处理。

**宽度不变量（评审 ②，v4 的错误承诺）**：实测宽度参与断行（image 宽 200 → 整行
34.3pt 变 233.3pt）。**"UTF-16 长度不变" 只保证映射不变，不保证布局不变。** 裁决：

- chip **预留固定宽度区**放动态计数（`· N matches` / `· diff` / `· N occurrences`），
  计数变化时**只重绘不改宽**；放不下就截断计数，**永不加宽**。
- 由此 §3.11 的计数变化既不重建 `DisplayMap`，也不触发重新断行。F2 断言：
  同一折叠在 0 / 3 / 999 matches 三种状态下 **attachment 宽度与整行排版宽度不变**。
- **高度 ≤ 单行行高**，否则行号尺、当前行背景、声明标记的几何会漂。F2 断言。

#### (4) 折叠集合变更走单一 private 原子入口

```
1. 以 source 空间捕获 selection 与 viewport anchor
2. 由 reducer 算出新的渲染集（本节 (1)）
3. 调 §3.1 的 projector 重新产出 (attributed, map)，原子安装
4. 按 §3.3 的锚点策略还原 selection 与 viewport
```

**性能门禁（可执行，固定工作量）**：projector 每次在主线程重建整份 attributed string，且新旧
storage 会短暂并存。本轮保留这条简单路径，但以**同一份确定性 fixture**同时约束 F0 提取与 F2
首次折叠；不拿现有 corpora 最大文件或 debug self-test 代替。

**fixture 合同**：新增 `scripts/provision-corpora.sh --gen-fold-fixture <rs> --manifest <json>`。
固定种子 `m11-fold-perf-v1` 产出 `fixtures/fold_perf.rs`（恰好 50,000 个换行、至少 2 MiB）与
`fixtures/fold_perf.manifest.json`。生成器的结构不是任意填充，必须得到下列已验证工作量：

| 项目 | 固定值 |
|---|---:|
| `candidateCount` / `acceptedFoldCount` | 8,400 / 8,400 |
| kind 分布 | `container` 200、`imports` 200、`declaration` 4,000、`block` 4,000；其余 0 |
| depth 分布 | depth 0: 200（container）；depth 1: 4,200（200 imports + 4,000 declarations）；depth 2: 4,000（block） |
| Structure logical / rendered | 4,200 / 4,200 |
| Overview logical / rendered | 4,400 / 200 |
| perf preset | `Overview`；control 为同一文档、无 rendered folds |

manifest 必含 `schemaVersion: 1`、fixture SHA-256、字节数、行数和上表字段。生成后与每次计时前
都由 fixture verifier 校验 manifest、SHA 和所有计数；任一不符即 FAIL，禁止把空折叠文件当性能
样本。F0 对同一 fixture 的**候选消解**（只从排序/去重/laminar 贪心开始，到分配 FoldID 结束；
不含 parse、summary 提取、DocumentLoader 或 TextKit）在 release 下 **≤ 500 ms**；8,400 候选超过
该门禁才把 O(n²) 替换为次平方结构，之前不预建区间树。

```sh
# 生成、验证、release 运行：codeinsight-app 含 ReaderUI/TextKit；CLI codeinsight 不含。
bash scripts/provision-corpora.sh --gen-fold-fixture fixtures/fold_perf.rs \
  --manifest fixtures/fold_perf.manifest.json
swift build -c release --disable-sandbox --product codeinsight-app
bash scripts/run-fold-perf.sh --app-bin .build/release/codeinsight-app \
  --fixture fixtures/fold_perf.rs --manifest fixtures/fold_perf.manifest.json
```

**app/runner 协议**：`codeinsight-app` 增加唯一入口
`--fold-perf-mode control|fold --fold-perf-fixture <path> --fold-perf-out <json>`。runner 起两个全新
进程，分别传 `control` 和 `fold`，各自写临时 JSON；生产 highlighter 的候选消解函数是**唯一实现**，
perf mode 仅以可选 **`@Sendable` observer closure** 在该次真实调用前后用 `ContinuousClock` 记录
`resolutionMs`、candidate/accepted counts；它由 perf harness 显式注入 `DocumentLoader` 的 package 路径，再
显式捕获并传过 50k-newline 的 `loadSyntax` `Task.detached` 到生产 `highlightWithFolds`/candidate resolver。
closure 形状只收三个 Sendable 标量（ms、candidate、accepted），不新增 public type。harness 唯一拥有一个
**private、lock-protected `PerfResolutionCollector`**：observer 在 resolver 计时停止后以一次短临界区写完整 sample，
因此锁不在被测 resolution 区间内；detached 的 `@Sendable` completion 已返回后，harness 在同一锁下 snapshot
collector，unlock→lock 建立 happens-before，**只此时**组装 app JSON。completion 前无 JSON read，未收到恰好一份
sample 或字段非法即 FAIL。nil 时是原有生产路径；不依赖隐式 task context（detached 不继承）、global registry、
二次实现或消解副本。渲染层从真实 reducer/projector 记录 logical/rendered counts。
这些 observed 值不得从 manifest 回显；不二次 parse、不保留 raw candidates、不运行消解副本。
control/fold 都从实际 document load 取得该观察值。perf mode **bypass 正常 session restore 与用户
Application Support**，两进程只加载该 fixture，并将生产 `ReaderSettings` 固定为 `fontSize=13`、
`wrapLines=false`、`lineNumbers=true`、theme SI Classic，窗口 1440×900pt。它**不新增 font-family
设置**：安装后从实际 text storage/layout 读回 `resolvedFontName`/`resolvedFontSizePt`、从 clip view
读回 `viewportPt`、从 text container/scroll geometry 读回 `wrapLines`，并从生效 settings/theme 读回
`lineNumbers`/`theme`。perf harness 布局后必须让 clip view 实测为 **1200×760pt**（否则 app FAIL）；app JSON
只报这些 observed-effective `perfConfig` 字段；runner 断言 13pt、1200×760pt、`wrapLines=false`、
`lineNumbers=true`、SI Classic，且两个 mode 的 resolved fontName、fontSize 与 viewport 一致，否则 FAIL，
绝不回显请求常量。runner 在两份 app JSON 都通过
schema/fixture 校验后合成最终 JSON 并判定退出码。control 打开同一 fixture 并完成初始布局、不触发折叠；fold
走同样打开路径后切到 `Overview` 并等待一次 layout stable。二者不复用进程、cache 或输出文件。

采样在 app 的**非主线程** `DispatchSourceTimer` 上每 **25 ms** 调 `task_info`；窗口从文档安装前
开始，到主线程报告 layout stable 后的两个 run-loop turn 结束。若 10 s 内未 stable，app 输出
`status: "timeout"` 并失败。timer 因此在 projector 阻塞主线程时仍持续采样；`peakPhysBytes` 是
窗口全部样本的最大值，而非稳定后的单点。fold latency 是从发出 preset 变更到该 stable 回调的
主线程墙钟，单位 ms。

每个 app 输出的合法 JSON 形状为：

```json
{"schemaVersion":1,"mode":"fold","fixtureSHA256":"…","samplePeriodMs":25,
 "perfConfig":{"wrapLines":false,"resolvedFontName":"<actual-text-storage-font>","resolvedFontSizePt":13,"windowPt":[1440,900],"viewportPt":[1200,760],"lineNumbers":true,"theme":"SI Classic"},
 "observed":{"candidateCount":8400,"acceptedFoldCount":8400,"logicalFoldCount":4400,"renderedFoldCount":200},
 "status":"ok","resolutionMs":123,"peakPhysBytes":456,"foldLatencyMs":321}
```

runner 合成：

```json
{"schemaVersion":1,"control":{"resolutionMs":123,"observed":{"candidateCount":8400,"acceptedFoldCount":8400,"logicalFoldCount":0,"renderedFoldCount":0},"peakPhysBytes":456},
 "fold":{"resolutionMs":124,"observed":{"candidateCount":8400,"acceptedFoldCount":8400,"logicalFoldCount":4400,"renderedFoldCount":200},"peakPhysBytes":789,"foldLatencyMs":321},"deltaBytes":333,"status":"pass"}
```

仅当两个 app 都 `status == "ok"`、fixture SHA 相等、两者 observed `candidateCount == 8400` 且
`acceptedFoldCount == 8400`、control `logical/rendered == 0/0`、fold `logical/rendered == 4400/200`、
`perfConfig.wrapLines == false`、`resolvedFontSizePt == 13`、`lineNumbers == true`、`theme == "SI Classic"`、
`windowPt == [1440,900]`、`viewportPt == [1200,760]` 且 control/fold 的 `resolvedFontName`/size/window/viewport
一致、两者 `resolutionMs ≤ 500`、
`foldLatencyMs ≤ 400`，且
`deltaBytes = max(0, fold.peakPhysBytes - control.peakPhysBytes) ≤ 80 * 1_048_576` 时退出 0；否则
退出非 0 并保留 JSON。它是首次折叠的粗粒度进程守卫，不声称把 `phys_footprint` 精确归因于
TextKit。`ci.sh` 与 `run-gold-gates.sh` 各自先验证/生成 M11 fixture、执行
`swift build -c release --disable-sandbox --product codeinsight-app`，再调用 runner，故可独立运行；
不把它混进 debug self-test。

### §3.3 锚点被隐藏时的恢复策略（评审 ③）

"折叠后回到同一源码位置"在锚点刚好落进被折叠的 body 时**不可能**：`DisplayMap` 只会返回
`.hidden(FoldID)`，NSTextView 无法选中隐藏字节。裁决：

| 锚点情形 | selection | viewport |
|---|---|---|
| 折叠后仍可见 | 精确还原到同一源字节 | 精确还原 |
| 折叠后被隐藏 | 落到该 fold 的**占位附件**上（`.hidden(f)` → f 的附件位置） | 对齐到 f 的 **header 行** |

被隐藏时**为 selection 与 viewport 各保留一份独立的 latent anchor**（评审 ⑥）：两者本就是
**独立位置**——用户可以把 viewport 滚离 caret，甚至分别落入**不同 fold**。若只存一份
latent，展开时必然丢失其中一个位置。因此原子入口（§3.2(4) 步骤 1）在 source 空间分别捕获
两个位置，**各关联其所在 fold 的 `FoldID`**；展开某个 fold 时只消费绑定它的 latent，另一个
latent 保留，直到其 own fold 展开后再还原（scroll anchor 还原 viewport、selection anchor 还原
caret）。**无关导航、文档代际变化或显式替换 selection/viewport** 才同时作废两份 latent；再次
折叠变更本身不作废尚未命中的另一份。F2 断言两种情形各一条、
"展开后各 latent 锚点各自生效"、以及"selection 与 viewport 分别落入两个不同 fold 时**依次展开
各自还原**"（评审 ② 点名场景）。

### §3.4 折叠下的复制与选择（§1 合同项）

原生复制路径会序列化占位附件字符 `U+FFFC` —— 粘贴出来是垃圾且丢失隐藏源码。
**裁决：复制永远产出源码。** 覆写 `ClickTextView.writeSelection(to:type:)`（并覆写 `copy(_:)`
兜底），把 display 选区经 `sourceRanges(forDisplay:)` 映射回源字节，从 `document.bytes` 取原文
拼接。跨折叠选择时该折叠区完整源码计入结果。

**验收**：全折叠 `selectAll` + 复制 == 完整源码；跨单个折叠的部分选区 == 对应源字节原文；
**剪贴板中不得出现 `U+FFFC`**。

### §3.5 保险丝

`documentMatchesStorage`（`:1259`）改为
`displayMap.projectedUTF16Length == backingTextStorage.length`，
作为 §3.1 单遍 projector 的**纵深防御**（根治是构造，不是校验）。无折叠时行为与今天一致。
**F1 之前不得动 gutter 或占位符。**

### §3.6 折叠 / 展开的属性来源

不保留整份已排版 attributed string 副本（巨档会翻倍文本内存）。projector 走可见段时用
`document.bytes` 子串 + 落在该段的 `highlightSpans` 调 `applyTypography` 的区间版本。

### §3.7 阅读高度档只认大纲深度

大纲深度（mod → impl → fn）对读者有意义；括号嵌套深度是噪音。**不给数字滑块**——
"深度 3" 在 100 行和 3000 行文件之间不可比，分档可比：

| 档位 | 折叠什么 | 快捷键 |
|---|---|---|
| **Full**（默认） | 无 | `⌥⌘0` |
| **Structure** | `.declaration` body + `.imports` + `.cfgTest` | `⌥⌘1` |
| **Overview** | 上一档 + `.container` body，只剩 `outlineDepth == 0` 的声明头 | `⌥⌘2` |

自动折叠**跳过 `hiddenLineCount < 2`**（§3.0）。`.block`/`.comment`/`.attributes` 只走手动。
（imports / cfgTest 归档由 P0 定稿。）

### §3.8 高度档与手动折叠的仲裁（评审 ④，补状态方程）

**覆盖项必须有方向，不能是裸 `FoldID` 集合。** 一个 `FoldID` 在覆盖集合里，无法判断它代表
"强制折叠"还是"强制展开"——Full 档下手动折叠一个 block、与 Overview 档下手动展开一个 fn，
行为相反，同一个 reducer 无法无歧义实现。**裁决**：

- **覆盖项分两个方向集合**：`forcedFolded: Set<FoldID>` 与 `forcedUnfolded: Set<FoldID>`。
- `baseline` 由当前高度档（§3.7）推出；精确状态方程及投影输入见本节后的
  `logicalFoldIDs` / `renderedFoldIDs` 定义。
- **手动 toggle（对 FoldID `f`）**：若 `f ∈ baseline` → 用户展开它 → 加入 `forcedUnfolded`
  （rendered 里去掉它）；若 `f ∉ baseline` → 用户折叠它 → 加入 `forcedFolded`。再按一次从
  对应集合移除，回到 baseline 决定。同一 `f` 不会同时出现在两个集合。
- **导航自动展开（§3.11 第 1 条）的转移（评审 P1，必须守卫不交叠不变量）**：落点在折叠区内 →
  展开最小祖先链。对祖先链里每个 `FoldID f`，**先移除相反方向，再按 baseline 决定**，
  使 `f` 永不同时出现在两个集合：

  | f 的当前状态 | 转移 |
  |---|---|
  | `f ∈ forcedFolded`（baseline 不含 f，但被手动折叠） | **只移除 `forcedFolded`**。baseline 不含 f → 移除后既不在两个集合、baseline 也不折它 → 展开。**不必加 forcedUnfolded** |
  | `f ∈ baseline`，且 `f ∉ forcedFolded` | **加入 `forcedUnfolded`**（否则重投影又折回） |
  | `f ∉ baseline`，且 `f ∉ forcedFolded` | **无操作**（baseline 不折它，本就展开） |

  关键：若只按 v7 的"加入 forcedUnfolded"，Full 下手动折叠的 `f` 会**同时**落在两个集合，
  `logicalFoldIDs = (baseline∖forcedUnfolded)∪forcedFolded` 仍含它 → 导航无法展开手动折叠区。
  **先删 `forcedFolded` 是展开的充分条件**。转移后断言两集合不相交。
- **状态方程**：`logicalFoldIDs = (baseline(currentHeightLevel) ∖ forcedUnfolded) ∪ forcedFolded`；
  **`renderedFoldIDs = maximal(logicalFoldIDs)`**。projector 只接收后者；前者只用于状态/摘要，绝不把
  未归一集合误叫 rendered。
- **切换高度档清空所有 `(fileURL, contentID)` pair 的两个覆盖集合**（`forcedFolded` 与
  `forcedUnfolded`），不只清 active pair——否则切回旧文件仍带上一档的手工裁决，且"切到 Full
  还有东西折着"无法向用户解释。**此裁决固定。**
- **双向测试**：Full 下手动折叠 block → rendered 含它；Overview 下手动展开 fn → rendered 不含
  它；**导航进"手动折叠区"（f∈forcedFolded）→ 移除 forcedFolded 后展开，且不再进 forcedUnfolded**
  （评审 P1 点名场景）；导航进"baseline 折叠区"→ 加入 forcedUnfolded 保持展开；切档 → 两集合
  清空所有 pair；任意操作后两集合不相交、`renderedFoldIDs == maximal(logicalFoldIDs)` 断言。

### §3.9 Focus 当前作用域：完整语义（评审 ④，v3 丢失）

v3 只写了跟随策略，没定义 Focus 折叠什么，无法实现也无法验收。补全：

- **焦点 scope 从 `outlineFacet.range` 选，不从 `FoldRegion.bodyRange` 选（评审 ⑤）**：
  `facet.range` 是**完整声明范围**（含 header 与闭合花括号），因此 caret 停在函数签名行或
  收尾的 `}` 上时仍能选中该 scope；用 `bodyRange` 会在这两处落空。
  取**包含 caret 的最小 facet**，kind 为 `fn`/`method` 优先，否则取最小的
  `struct`/`enum`/`trait`/`impl`/`mod`（**`cfgTest` 计入 container 一侧**，见 §3.0）。
  再按 §3.15 的关联规则映射到对应 `FoldRegion`。
- **折叠什么（评审 P2：与"manual-only"的关系）**：焦点 facet 的范围保持完全可见；其**全部祖先
  的 header 链**保持可见；其余所有可折叠区间按**渲染集的极大元**折叠（§3.2(1)，避免占位符套
  占位符）。**Focus 是显式例外，折叠一切 kind**——包括 §3.7 说"只走手动"的
  `.block`/`.comment`/`.attributes`。二者不冲突：§3.7 的"manual-only"约束**高度档**（Structure/
  Overview）的自动折叠与默认折叠，不约束 Focus 这个用户显式开启的"只留当前 scope"模式——
  Focus 的语义就是"把焦点外的都藏起来"，若排除三类，焦点外的 block/comment 会漏出来，违背
  Focus 本意。§3.9 的 Focus 测试**必须含一个 `.block`、一个 `.comment`、一个 `.attributes`
  区间**，锁定它们被折叠。自动折叠跳过 `hiddenLineCount < 2`。
- **无包围 scope**（文件顶层、import 区、注释区）：**Focus 不做任何折叠**并给一次性提示，
  **不退化成"全折叠"**。
- **与高度档/覆盖项仲裁**：Focus 是**独立模式**，不与高度档叠加。进入时记住当前高度档与
  覆盖项，退出时原样还原。
- **退出**：再按 `⌥⌘F` / Escape（优先级见 §3.14）/ 关闭文件。
- **跨文件导航**：Focus 模式**跟随到新文件**，在新落点重新计算焦点；新文件无包围 scope 时
  **退出 Focus 模式**并提示，而不是留在一个什么都没折的"假 Focus"里。
- **跟随仲裁**：复用 M9-S1 显式意图 —— 只有显式导航重设焦点；`didLiveScroll` 解除**跟随**
  但**不退出模式**。

### §3.10 占位符视觉与 AX

复用 M9-S5 chip token（1×5pt 描边、r4），三主题取色集中在 `ReaderSettings.swift`。
附件的 accessibility label 读得出"已折叠，隐藏 143 行，含 7 个函数"以及 §3.11 的暴露项。
交互：点击附件或折叠柄展开；`⌥` 点击折叠柄对同级递归；单击 header 行不触发折叠。

**折叠柄参与 ruler 可见性与宽度（评审 P2）**：现有 `needsRuler = lineNumbers || !diffMarkers.isEmpty`
（`CodeInsightReaderUI.swift:733`）——**行号关 + diff 空时整个 ruler 被移除**，折叠柄无处可点。
改为 `needsRuler = lineNumbers || 有 diff || 有可见折叠区`，且折叠列计入 `rulerThickness`
的宽度计算（`:990`–`:1009`，`rulerThickness` 现只因行号/声明列取值）。**回归测试**：
`lineNumbers = false`、`diff 为空`、**存在可见折叠区** → ruler 仍显示且折叠柄可点击；三个条件
都空才移除 ruler。

### §3.11 折叠诚实合同（红线）

1. **导航自动展开**：落点在折叠区内 → 展开包含落点的祖先链（非全展开），gutter 短暂标记。
2. **搜索命中暴露**：命中在折叠区内 → 附件绘制 `· N matches`，且**计入总数**。
3. **diff 暴露**：折叠区内含 diff hunk → 附件绘制 `· diff`，gutter diff 列绘制合并标记。
4. **当前符号暴露**：折叠区内含当前选中符号 occurrence → 附件绘制计数。

四条**各自独立测试**（M10 教训：套件变红只证明其中某一条）。

### §3.12 Palette 命令模式遍历 `NSMenu`（不建 `CommandRegistry`）

`CommandRegistry` 表达不了 `action`/`target`/`representedObject`、delegate 填充的 Open Recent、
`allowsKeyEquivalentWhenHidden` 备用项、已存在的 `validateMenuItem(_:)`；
`@MainActor () -> Bool` 存进 `Sendable` 类型在 Swift 6 下编不过；且无 palette-only 命令。

**采集与执行的时序（评审 ⑦）**：v3 只解决了"执行目标"，没解决"验证发生在错误的 responder 上"
——palette 一旦成为 first responder，`menu.update()` 与 `isEnabled` 就是针对搜索框算的，
命令可能被错误隐藏。裁决：

1. **palette 每次打开时就缓存原 first responder 并采集菜单树**——**不是等用户输入 `>` 才采集**
   （评审 P2-4）：用户可能先用 ⌘P 进文件模式、再改输入 `>`，那时 responder 早已转走。
   采集 = 逐级 `menu.update()`，收集叶节点，跳过分隔符、`isHidden == true`、
   **`action == nil`**。
2. 展示 `menuPath.joined(" ▸ ")` 与快捷键。
3. 执行时**先关闭 palette、还原原 first responder，再重新验证一次**，通过后
   `NSApp.sendAction(action, to: target, from: item)`。
4. Cut/Paste 等编辑命令排除出只读阅读器的 `>` 列表。

四条各一条断言。**单一真值源由构造保证**，不需要双向门禁。

**推论**：折叠命令必须是真实菜单项。View ▸ Folding 只收
**Toggle Fold / Full / Structure / Overview / Focus Current Scope** 五项
（`Fold All` 与 `Overview`、`Unfold All` 与 `Full` 语义重复，不设）。

**诚实说明**：macOS 14+ Help 菜单本身可搜菜单项（⇧⌘/）。Palette 的增量价值在于
文件/符号/行号合并成一个输入框与全键盘流。

### §3.13 Palette 模式与键位

| 前缀 | 模式 | 数据源 |
|---|---|---|
| （无） | 文件名 | **`FileTreeModel`**（`AppModel.swift:169`），不依赖索引完成 |
| `>` | 命令 | 运行时 `NSMenu`（§3.12） |
| `@` | 当前文件符号 | `document.outlineFacets`，即时 |
| `#` | 项目符号 | 复用 `SymbolSearchPanelModel` |
| `:` | 行号 | `document.lineTable` |

键位：`⌘P`（文件）、`⇧⌘P`（`>`）、**`⌘T` 保留预填 `#`**、`⌘L` 预填 `:`。
`SymbolSearchPanelModel` 不删不重写。

active Reading Set 时，文件 `⌘P`、命令 `>` 与项目符号 `#` 仍可用；只有依赖当前 file document 的 `@`
与 `:` 禁用并提示“Reading Set has no active file”，绝不回读上一个 `selectedFile`。C1 与 M11D 各有此
分派断言。

**查询合同（评审 P2，为每种模式定最小确定性语义，不新增公开类型）**：

- **匹配**：文件 / 命令 / 当前符号三种本地模式统一为**大小写不敏感的子串匹配**
  （复用 `asciiFold` 语义，§0）；`#` 项目符号复用 `SymbolSearchPanelModel` 既有语义。
- **排名 + 稳定 tie-break**：前缀命中 > 子串命中；同组内按固定序稳定排序——文件按
  `(路径深度 ↑, 路径全串 lexicographic ↑)`；命令按 `(父菜单深度 ↑, title lexicographic ↑)`；
  符号按 `(kind 序, name lexicographic ↑, range 起点 ↑)`，其中 kind 序固定为
  `mod, trait, impl, struct, enum, typeAlias, const, static, fn, method`。tie-break 全部确定，跨进程一致。
- **结果上限**：每模式最多返回 **20 条**，超出截断并显示 `… 还有 N 条`。
- **同名文件消歧**：多个同名文件时，条目显示**消歧用的父目录路径**（最短唯一前缀），
  选中后跳到完整路径。
- **空查询**：文件模式只显示当前 `TabStripModel.tabs` 的 **file** case（按 tab 顺序），随后追加
  `FileTreeModel` 中未出现过的文件，按 `(路径深度, 路径)` 固定排序；Reading Set 过滤且按标准化 URL
  去重。这是已有真值，不引入 recent-file 或“常用”持久化。命令模式显示全部 enabled 叶命令；符号 /
  行号模式空查询显示空列表并提示。
  **不静默无结果**。
- **非法 `:line`**：非数字、`0` 或负数 → 不跳转 + 提示；正数越界
  （`> lineTable.lineStarts.count`）→ 钳到末行并提示，不静默。
- **查询变化后的 selection**：每次查询变化重置到结果首条；若当前选中仍在结果中则不重置。
- **测试**：每种模式各一条 + 同名文件消歧 + 空查询 + 非法/越界行号 + 排名稳定各一条。

### §3.14 ⌘F：逻辑命中用 `ByteRange`

**最小匹配合同（评审 P2-2）**：

- 字面子串，**不做正则、不做全词**。
- 大小写不敏感沿用既有 `SnapshotSearch.asciiFold` **语义**（`:613`）：`A-Z → a-z`，
  **非 ASCII 字节原样比较**。这是本项目已有的、有定义的语义，不自造 Unicode 折叠。
  另有大小写敏感开关。
- **不重叠、leftmost-first**。
- 匹配**不跨行**；查询含换行 → 零结果并提示，不静默。
- **导航循环**：到尾回到首条并提示 `wrapped`。

**复用方式要先做提取（评审 P2-2）**：`asciiFold`（`:613`）与 `literalRanges`（`:488`）
当前都是 `SnapshotSearch` 的 **`private static`，不能直接调用**。R0 的第一步是把既有
literal scan **提取为 Core 的 package 级函数**，`SnapshotSearch` 与 ⌘F 共用同一份实现——
而不是在 ReaderCore 里抄一遍（抄一遍就有两套大小写语义，正是要避免的）。

**扫锚点的取消与完整合同要先闭环（评审 ⑤）**：`SearchPanelModel` **本身并不创建 detached
worker**——是 Engine 的 stream 持有 detached task 并在 termination 时取消；而新建的
`Task.detached` **不会继承父任务取消**，单做一个"外层取消"接不上底下的扫描，任务会堆积。
且既有 `literalRanges` 在取消/超时下**直接返回无完成标志的部分数组**，会破坏真实命中数合同。
裁决（R0 实现秩序上先于一切查询功能）：
**(a)** 模型持有并**逐个取消**它派生的 detached worker handle，输入去抖即取消上一个；
**(b)** 扫描遇取消**抛 `CancellationError`**，不返回截断中间结果，调用方据此结论是
"无结果（未完成）"而不是"零命中"；
**(c)** 文件内查找**不设 wall-clock 截断**——只有**完整结果**才能发布计数与列表，杜绝"扫到一半
当全量"的假命中数。三者各一断言。

**发布必须绑定文档代际（评审 ⑤，取消合同不够）**：取消旧 worker 只防"输入去抖"，不防
**旧文件 / 旧 snapshot 的 `[ByteRange]` 在新文档里发布**——worker 在切换文件或 snapshot 后完成
时，会把旧范围的计数/列表贴到新文档。**请求与发布必须绑定同一代际 key**：

```
generation = (fileURL, contentID, query, caseSensitive)
```

只有 `generation == 当前代际` 才允许发布计数与列表；任一字段变化即作废旧代际。**失效时机**：
切文件、切 snapshot、关闭 find bar（关闭即清空命中并作废代际，见下）。**测试**：延迟扫描期间
(a) 切文件、(b) 切 snapshot、(c) 关闭 find bar，各自断言旧结果不发布、计数不污染新文档。

**与折叠的接线**：

- **逻辑命中集合是 `[ByteRange]`**，是计数与导航的唯一真值。隐藏命中没有 display range，
  丢弃会让总数撒谎，全映射到占位符会产生重复 range。
- 渲染时派生可见 `[NSRange]`（经 `project(byteRange:)`）+ 每 fold 命中计数（喂 §3.11 第 2 条）。
  **计数显示始终用逻辑集合大小**（`3 / 17`）。
- 跳到折叠区内的命中时自动展开最小链。

**Escape 优先级**：find bar 打开 → 关 find bar；否则 Focus 模式中 → 退出 Focus（§3.9）；
否则 occurrence 存在 → 清 occurrence；否则不消费。专测锁定。
**关闭 find bar**：清除 find 命中并**恢复**打开前存在的符号 occurrence；之前没有则不留高亮。

### §3.15 常驻作用域头：最小包含 facet + kind 兼容（评审 ⑤ / P2-1）

`.container` 把 impl/trait/mod/struct/enum 塌成一类，作用域头说不出 "impl Foo"。
**kind 与 name 来自既有 `outlineFacets`**（已含 `kind`/`name`/`range`/`depth`）。

**关联规则（评审 P2-1）**：`facet.range` 是**完整声明范围**，`FoldRegion.bodyRange` 是**内部
body**，两者**不相等**，不能按相等关联。规则为：对每个 `FoldRegion`，取
**`range` 最小且包含该 `bodyRange`、且 kind 兼容**的 facet
（`declaration`↔`fn`/`method`；`container` **及 `cfgTest`**↔`struct`/`enum`/`trait`/`impl`/`mod`）。
**`cfgTest ↔ mod` 必须在表内**（评审 ⑤）：交叠消解会保留 `.cfgTest` 丢弃 `.container`，
漏掉这条会让 `#[cfg(test)] mod tests` 的作用域头整个失效。
无匹配 facet 时该层不进作用域头（例如 `block`/`comment`）。
**不解析 header 文本，不新增第三套结构模型。**

顶部钉住至多 2 层，超出省略中间层；无包围声明时整条不占位、不留空条。

### §3.16 会话恢复：tagged tab union、冻结 Reading Set 与文件锚点

M11 首次引入私有 `schemaVersion = 1` session codec（HEAD 没有旧 tab/session schema，因此不做
迁移）。最终形状是**tagged tab union**，tab 数组顺序就是生命周期顺序；`activeTabOrdinal` 指向保存时
数组中的 entry ordinal，恢复时保留 old-ordinal→new-index 映射，故缺失 file entry 不会让 active
tab 错位，也能精确恢复 active Reading Set。没有 runtime UUID、`SnapshotID`、`StableSymbolID`、
registry 或第二证据 store。

```
schemaVersion: 1
projectRoot: String
revision: String?            // 唯一全局 target；不存 runtime SnapshotID
activeTabOrdinal: Int?
panelPreset: String
tabs: [
  { kind: "file", path, anchorContentID?,
    scrollAnchor: { byteOffset, line, column, symbolAnchor? }?,
    selectionAnchor: { byteOffset, line, column, symbolAnchor? }? },
  { kind: "readingSet", title, excerpts: [FrozenReadingSetExcerpt], scrollOffset: Double? }
]
```

`makeInspectorDisplay` 是唯一 package helper：live Inspector、Relations freeze 和语义导航 Trail freeze 都调它，
故稳定内容只有一份定义。现有 live `auditRows` 的 `("Snapshot", snapshot.uuidString.prefix(8))` 删除，改为
稳定 provenance rows：`Source` = `project commit <revision>` / `worktree captured` / `dependency captured`，
`Content` = `contentID` 的固定前缀；无 revision 明说 captured，绝不显示 runtime UUID。M10 Inspector 测试把
Snapshot UUID 断言迁移到这两行。`FrozenReadingSetExcerpt` 是 session codec 的私有 Codable DTO，不是 store：它逐字段保存 `role`、`path`、
`line`/`column`、`byteRange`、**冻结 `sourceText`**、`contentID`、`revision?`、`capturedAt`、source kind
(`projectCommit` / `worktreeCaptured` / `dependencyCaptured`) 与嵌套 `FrozenInspectorDisplay`。后者是两入口
复用所必需的**唯一** package/private codec/display seam，保存 renderer 已得到的稳定值：node title、badge
small-enum、why、source body、verification title/body、correction body、明确带 **AT CAPTURE** 标签的
availability/environment、稳定 audit `(label,value)` rows、AX value、capturedAt 与 provenance。audit rows 使用
session DTO 的 private keyed codec（或 private nested `AuditRow` DTO），保持既有稳定顺序；Swift tuple 不作为
Codable 域模型。live-only controls
不编码 closure：former-candidate 的显示资格是一个布尔值，frozen mode 的行为另见 §3.20。它**禁止** raw
`NarrativeClause`（其 `sourceEvidence` 含 `ResolutionEvidence`）、raw `ResolutionEvidence`、
`MaterializedResolutionExplanation`、`ResolutionExplanationID`、`SnapshotID` UUID、`PathID`、`NameID`，以及
任何 live context/store ID。package 内 `ReadingSetExcerpt` 持有同一 payload；badge、摘要和 Inspector 都从
这一次 freeze 派生，session 只编码它，不形成双真相。每个 Reading Set 最多 50 段、每段冻结文本最多
16 KiB；入口超过上限时按其固定排序取前 50 并显示“50 / N 段已冻结”，不另造缓存。

- **恢复顺序**：先安装全局 `revision` / snapshot，再按保存次序恢复 tagged entries；file entry 按
  §3.17 解析两个 anchors，readingSet 从冻结 payload 渲染并恢复其 numeric `scrollOffset`；最后用 old-ordinal 映射激活 entry，
  无效时取第一个成功 entry。Reading Set 不走 file anchor/replayOffset，但会话确实恢复其 tab 与 payload。
- **捕获时机**：**file tab** 失活时分别捕获 `scrollAnchor` 与 `selectionAnchor`；**readingSet tab** 失活时保存其现有
  `NSScrollView` 的 numeric `scrollOffset`。后者不复用 file byte anchor，也不持久化文本 selection；
  退出时不遍历失活 file tab 补锚点（文档可能已卸载）。
- **active file tab 写盘时要单独构造两个锚点（评审 ④）**：`currentJumpRecord()` **只给滚动位置**，
  selection 锚点须另行从 active document + `Tab.selectionByteOffset` 构造。
  v4 只说"用 `currentJumpRecord()`"，会静默丢掉 active tab 的选中位置。
- **保存位置与版本失败策略**：Application Support 下单个 JSON（不进 UserDefaults）。未知版本、
  解码失败或缺失 `projectRoot` 整份忽略、删除并一次性提示；普通 Codable 不做 lossy 单 payload
  恢复。运行时源不可读不是 JSON 损坏：仍展示已解码的冻结段，只禁用相应动作。
- **写入时机（评审 ⑦）**：open、activate、scroll、tab 失活、转入后台可**去抖**原子 checkpoint。
  **close 与 LRU eviction 是破坏性 topology mutation**：先取消 pending debounce，再以**last-installed**
  revision 与既有 anchor provenance 同步原子写 topology-only coherent checkpoint，成功后才返回，故立即 kill
  不会复活已删 tab；切 snapshot 进行中的任何 checkpoint 也只可写 last-installed revision 的 topology/anchors，
  绝不把 pending revision 写入。**退出路径同样不能走延迟去抖**——
  `applicationWillTerminate` 是进程退出前的**同步收尾点**，
  此时才启动延迟任务，进程可能**先于任务执行就结束**，丢最后状态。退出路径的固定顺序：
  **(a)** 若 active 是 file tab 才捕获两个锚点；若 active 是 Reading Set，保存其 numeric scrollOffset
  并同步写已有冻结 payload/已捕获 file anchors，
  **(b)** 取消 pending debounce，**(c)** 同步原子写入（`Data.write(to:options: .atomic)` 或等价
  原子替换，避免写一半）。普通失活/切换事件则继续去抖，不被退出路径复用。
- **切 snapshot 的保存必须是 generation-keyed coherent checkpoint，且必须诚实对待 inactive
  tabs（评审 ⑥ / P1）**：snapshot 切换是**异步**过程，且 `TabStripModel` **只持有
  `activeDocument`**（`TabStripModel.swift:16`），**inactive tabs 没有 ReaderDocument**，无法在
  新 revision 下重算锚点。coherent 的含义是：一次原子写入记录**一个**已安装完成的全局 target
  `revision`，以及每个 anchor 的真实 provenance；它不声称所有 tab anchor 都来自 target revision。
  裁决：**(a)** active **file** tab 才在安装完成回调、按新文档重算两个 anchor 后写入其
  `anchorContentID = document.contentID`。**(b)** inactive tab 保留原 `anchorContentID`，不加载
  所有文档、不丢弃 anchor；恢复到 target revision 后若 contentID 不匹配，两个 anchor 各自按
  §3.17 降级（`.line` / `.symbol` / `.fileHead`），绝不假冒精确。实现时把
  `anchorContentID` 传为 §3.17 输入记录的 `contentID`；磁盘中没有 per-tab revision。readingSet
  payload 不随 snapshot 改写，仍保留 capture provenance；active Reading Set 时安装完成只更新全局
  revision，绝不尝试重算不存在的 active anchors。
  **(c)** 每次保存带**运行时 generation**（= 安装完成的 snapshot 代际），**恢复任务按运行时
  generation 匹配**，代际不符的自动恢复任务立即取消（旧 task 不得在用户已手动打开另一快照/项目
  后继续落点）。**运行时 generation 与磁盘 schema 的 `schemaVersion` 是两回事**，不混为一谈。
  **(d)** 失败合同：**missing `projectRoot`** → 该份不恢复、丢弃并提示；**missing
  `revision`** → 恢复 tabs 但不重设 snapshot（整体降级）；**切换中途退出** → **保留上一份
  coherent 文件**，不覆盖为半新的（写入仅当安装完成；安装未完成则沿用旧文件）。
  **测试**：延迟切换 snapshot 后立即退出（不得写混合记录，保留旧 coherent 文件）；切换进行中
  启动恢复、随后用户手动打开另一项目（旧恢复任务取消、不污染新项目）；inactive file tab 恢复时按
  旧 contentID 走 §3.17 降级而非假冒新 revision；active Reading Set 的 snapshot 切换/退出不触
  file anchor 重算，重启后仍为 active entry；frozen display DTO（含 `capturedAt`）round-trip 后每个
  可见 Inspector 字段仍一致且可打开。
- **测试隔离**：XCTest、`--self-test-tabs` 与 `--self-test-reading` 必须通过 package/private init seam
  或 self-test env 注入 private temporary session URL；禁止读写用户真实 Application Support。每例结束
  删除该 temp session 并断言不存在；该 seam 不进入 public API。
- **磁盘 trust boundary**：解码后、恢复前校验 tab 数 ≤ 既有 maximumCount、readingSet excerpts ≤50、每段
  `sourceText` ≤16 KiB、title/path ≤4 KiB、每个 frozen display 的全部字符串合计 ≤16 KiB 且 audit rows ≤32；项目文件 `path` 必须为相对路径且拒绝绝对路径与
  `..` 逃逸。任何 dependency 绝对路径在 restore、open、expand 前都必须通过既有 dependency predicate：
  file entry 未通过则整份 session 按既定策略失败；已恢复 frozen excerpt 未通过只禁用动作，绝不把任意
  绝对路径当 dependency。任一其余非法记录也按本节既定
  单 JSON 失败策略整份丢弃并提示，不做 lossy 恢复。R3 加 inactive close/LRU eviction 后模拟崩溃恢复，及
  超限/路径逃逸 JSON 全份失败断言。
- **`path` 语义要沿用既有约定（评审 P2-3）**：现有导航允许 **dependency 的绝对路径**进入 tab
  （`JumpRecord.path` 亦如此），而 schema 只写 `path` 没说相对/绝对。恢复校验**复用
  `JumpRecord` 约定**：项目内文件存**项目内相对路径**、dependency 文件存**绝对路径**，
  恢复时都先通过既有 dependency predicate；R3 分别对项目文件和 dependency 文件各做一条恢复断言，
  而非只测项目内路径。
**落点解析复用 §3.17 修正后的阶梯**（复用逻辑，不复用记录形状）。

### §3.17 `replayOffset` 修正：保号档 + 标量边界校验 + fallback kind（评审 ⑦→⑤）

直接把"contentID 不一致就降级"套上去会**回归 M10**：§0 审计出两个 producer 产
`contentID: nil`（`line: 0` / `line: 1`），它们今天依赖第一档保住字节偏移。
同时 v3 的前两档**不校验字节合法性**，与 §3.1 "持久化数据是信任边界" 自相矛盾。修正后：

| 档 | 条件 | 结果 | `FallbackKind` |
|---|---|---|---|
| 1 | `contentID != nil` 且 `== document.contentID` **且 `utf16Offset(forByte:) != nil`** | 精确字节偏移 | `.exact` |
| 2 | **`contentID == nil`** 且 **`utf16Offset(forByte:) != nil`** | 字节偏移（保持今天行为） | `.byteUnverified` |
| 3 | 以上不成立，行列可解析 | `line`/`column` 落点 | `.line` |
| 4 | 行列越界，`symbolAnchor` **唯一命中** | 该符号声明处 | `.symbol` |
| 5 | 其余 | 文件头 | `.fileHead` |

`utf16Offset(forByte:)`（§0）同时覆盖"在范围内"与"落在合法标量边界"，两档共用，
**失败继续向下降级**而不是硬用。

三条硬要求：

1. **返回 `(offset, FallbackKind)`**，调用方据此给准确提示（`.byteUnverified` 不谎称"精确恢复"）。
2. **`symbolAnchor` 仅唯一命中可用**；同名多个跳到第 5 档，不赌。
3. **审计全部 producer**：两处 `contentID: nil` 逐个判断能否补上；补不上的走第 2 档并写进迁移清单。

R3 必须重跑 M10 的 replay 断言；锁定旧弱行为的断言按迁移清单更正并写明理由。
worktree 沿用 M10 §3.14 的 best-effort 语义与 `replayed against current worktree` 措辞。

### §3.18 R4 换行：先复现再决定（前提已被实测推翻）

"换行使一个源码行占多个 layout fragment、行号尺会重影"是 TextKit 1 的心智模型，
**实测不成立**（§0 探针）。改为：

1. R4 **第一步是在真实 `ReaderTextView` 上写复现测试**，测量开 wrap 后行号尺、当前行背景、
   声明标记、diff 列的实际表现，**再决定是否有 gutter 工作**。不预设结论。
2. **设置项本体（评审 P2-3，v4 漏写）**：`wrapLines: Bool` 是 `ReaderSettings` 的 **package 存储**，
   默认 `false`；既有 public init 签名不加参数、源兼容且默认 false，public `init(defaults:)` 在模块内恢复
   此值，App/ReaderUI 同 package 才可修改。它进 `save(to:)`/读取路径做 UserDefaults round-trip，Settings
   Reader 页加 toggle；不得把 property 或 init 参数扩大为 public API。R4 加旧 public init 调用源兼容断言。
3. wrap 开关的完整几何（评审 P2-3）：开启时 `widthTracksTextView = true`、
   `containerSize.width` 跟随 clip view、**`isHorizontallyResizable = false`**（当前 `true`，
   `:1241`）、**关闭水平滚动条**、document view 随窗口缩放；关闭时**逐项反向恢复**。
   两个方向各一条断言。
4. 待确认（非已知缺陷）：fragment 高度覆盖全部视觉行后，`drawCurrentLineBackground`（`:1066`）
   会填满整块——判断是期望行为还是要收窄。

### §3.19 Settings 缓存拆除 → ⌘±

`showSettings`（`:5493`）缓存的 controller 捕获创建时的 `readerSettings`，是 backlog 的
"⌘± 字号"阻塞点。裁决：不再捕获快照值，每次 `showWindow` 前注入当前 settings；
**窗口已打开时，⌘± 引起的变化直接重建/更新既有 hosting root**（评审 P2-3：
不新增 observable settings module）。`⌘+` / `⌘-` 是真实 `NSMenuItem` 的 key equivalent（分别
`+` / `-` 加 command modifier），每次将既有 `ReaderSettings.fontSize` 按 **1pt** 加/减，并由既有
`fontSizeRange = 10...24` 钳制；到边界时对应菜单项 disabled。菜单项因而自动可被 §3.12 的 Palette
`>` 模式采集，不另造命令通道。每次成功变化都 `ReaderSettings.save(to:)`，立即 `applyReaderSettings`
到文件 Reader、Reading Set 的只读文本视图和已打开 Settings window；后者仍只接收新 settings 值。
验收：10/24 边界禁用与钳制、连续 ±1pt、UserDefaults 重启 round-trip、打开的 Settings window 同步，及
Reading Set 字号即时变化各一条；不新增 observable settings module。

### §3.20 M11D Reading Set：冻结、可恢复的非文件 tab（D6）

Reading Set 是 D6 已确认的 M11 目标：`File Tab | Reading Set Tab` 并列，后者是满宽连续 excerpt
流。`TabContent` 是 `TabStripModel.Tab` 的 package 真值，file accessor 改为**可选**：

```swift
package enum TabContent: Sendable { case file(URL); case readingSet(title: String, excerpts: [ReadingSetExcerpt]) }
// Tab.fileURL: URL?；只有 .file 返回 URL，绝不为 Reading Set 伪造 URL。
```

`ReadingSetExcerpt` 是唯一新增的 package 值 payload；其冻结/持久化字段与 §3.16 的私有 codec
一一对应（source text、location、contentID/revision provenance、**normalized frozen Inspector display**）。
它没有 id、registry、StableSymbolID、缓存或第二证据 store；badge 从同一次 freeze 派生。现有
`public Tab.fileURL: URL` 必须有意 source-breaking 改为 `public URL?`，这是唯一既有 public accessor
的 optionalization，**不新增 public 类型/API surface**。先执行包内与发布消费者审计：
`rg -n 'Tab\.fileURL|\.fileURL' Sources Tests Package.swift`，将所有命中归类迁移并在 evidence 列为
“本包内”或“外部 consumer”；若外部 consumer 非零，未完成其迁移/兼容决策即 FAIL。所有现有
`Tab.fileURL` 消费者必须迁移为 `guard case .file`/可选处理：`TabStripModel` 的 open/activate/
`setActiveDocument`，`AppModel` 的 tab 切换与 `selectedFile`，`MainWindowController` 的 tab strip、
sidebar 同步、reader/compare/menu/restore 选择，以及 `--self-test-tabs` 的 file 断言。active Reading Set
时 `activeDocument = nil`、`selectedFile = nil`；file-only menu、⌘F、Focus、fold 与 open restore 不得
回退使用上一个 selectedFile；Palette 仅 `@`/`:` 禁用，`⌘P`/`>`/`#` 仍依 §3.13 可用。

此 repo 的 `Package.swift` products 不导出 `CodeInsightAppModel`，因此没有可由本仓库枚举的发布
consumer；实现前后在 evidence 执行 `swift package dump-package | jq -r '[.products[] |
select(.targets[] == "CodeInsightAppModel")] | length == 0' | rg -x 'true'`，该命令必须成功，再以 `rg`
清单证明所有仓库内 source/test consumer
已迁移。若未来出现该 product 或登记的下游 consumer，optionalization 必须以其 source-breaking 发布决策
处理，不能把这个检查当兼容性承诺。

`openReadingSet` **总是新开 tab**，与 file tab 共用既有 maximumCount/LRU、activate、键盘切换、关闭
规则；LRU 淘汰和关闭后选中的 next tab 仍按 content 分派，因而 file anchors 不受 Reading Set 影响。
它由专用只读 `NSScrollView` 渲染，文件 tab 继续走 `ReaderTextView`；选择/复制按现有只读文本语义
返回冻结可见 excerpt 文本，不进入文件源码复制路径。Reading Set 在失活、切回和重启时用现有 Tab
的最小 `readingSetScrollOffset` 数值字段恢复同一 excerpt/scroll；不复用 file byte anchor，也不保存
文本 selection。

**两个可实现入口（不是 Inspector）与唯一 capture seam**：Relations 的 `Open as Reading Set` 取当前已
发布的 location rows（root 仅在它确有 materializable evidence 时纳入），按现有 UI 顺序，排除
group/evidence/loading/error rows；在**当前 live row + RelationQueryContext**上同步生成该段
`FrozenInspectorDisplay`。Trail 不在用户稍后点菜单时追 live store：每一次带 explanation 的语义导航，
在仍有 live row/context、correctedTitles/readiness 的当下，将同一 display freeze 写入
`NavigationExplanation` 并值携带至 `TrailEdge` 的 observed-at-navigation payload；Trail C 取选中 node 的
root→node 边，按 path 顺序只使用 edge 的 frozen display，绝不以 `currentExplanationID` 重查当前 explanation。
`NavigationExplanation`/`TrailEdge` 保留既有 public init；仅加 package 存储与 package capture initializer
承载 `FrozenInspectorDisplay`，不让该 type 进入 public API、也不造 registry/factory。
root 没有 incoming edge，故通常不入 Trail 集合。固定 tokio `spawn` fixture 明确是 **session root + 五个有
evidence 的目标节点**，最终顺序严格为 definition、Verified caller、name-only Inferred caller、trait contract、
test 的五段，而不是 root 再加五段。

Relations source/evidence 都来自当前已安装 snapshot；Trail source/evidence 都来自 edge destination 的记录
snapshot/revision。为使 worktree 不漂移，新增最小 package 读取 seam：将现有
`EngineSession.sourceBytes(at:)` 提升为 package，并提供按 manifest path 查 `(contentID, bytes)` 的 package
helper（返回 tuple，不建 registry/type）。Relations/current-worktree 与仍为 current snapshot 的 Trail worktree
**只**从 `EngineSession.storeState.sourceBytesByContent` 的 captured bytes 取，绝不读磁盘；旧 worktree 已非
current 且无 retained bytes 则 skip。commit 只有 `snapshot.readBytes(path:)` 读指定 revision 后 contentID 匹配
才可 freeze；dependency 才读通过既有 dependency predicate 的绝对路径。FrozenInspectorDisplay 随同保存
expected revision/source-kind/contentID，source freeze 必核同一个 observed evidence。每个 seed 仅在同代际
source + frozen display 均成功时成为 excerpt；无 evidence、无法读记录 revision 或冻结失败
不伪造 Verified、不换当前工作树、不造空 excerpt，只在集合顶部报告 `skipped N` 及原因。**不新增跨记录
dedup**：保留 producer 顺序与身份，避免不同 observed evidence 被合并。

**excerpt 范围（所有来源同一 helper）**：以 seed target line 找最小 enclosing `outlineFacet.range`；若有则
取该 range 的完整整行 source，初始上限 **80 行或 8 KiB**。无 facet 时取 target line 为中心、前后各 20 行
的整行窗口。若超过初始上限，在 UTF-8 与整行边界围绕 target line 对称裁剪，首/尾各显示省略标记；绝不
切进多字节标量。**唯一单行例外**：target line 自身超过上限时，取包含 target byte 的 UTF-8 scalar-safe
line slice，标 `partial-line`；slice 与省略 UI 的持久化计算总量不得超过当前 8 KiB/16 KiB cap，`byteRange`
只代表真实 source bytes、绝不包含省略标记。Expand 对普通段每次各向外增加 40 行；对 partial-line 只在该
行按同一 scalar-safe 规则向两侧扩展，最大 **200 行或 16 KiB**，target byte 始终在内。初始/expanded 的
range、frozen text 与 partial-line flag 都进入 payload；重启/复制仍返回冻结 text（含明确省略表现），不再读
当前文件。fixture、目标在首/末行、超长 facet、多字节边界与超长单行的 capture/expand/restart/copy 各一断言。

**动作与漂移合同**：每段显示 role、`path:line`、badge、caveat/scope chip 和 provenance chip：
`projectCommit` 只在读取该 revision 后 contentID 匹配才显示 commit；`worktreeCaptured` 显示
`worktree · captured`；`dependencyCaptured` 用绝对路径、contentID 与 `dependency · captured`，绝不把项目
全局 revision 当 dependency commit。**查看证据**纯读 frozen payload，绝不重新读取/校验 source，故文件不可读、
hash mismatch 或重启后仍可用。**打开完整文件**仅 projectCommit 通过既有 snapshot transition/replay 安装 captured
revision、contentID 匹配后才开 file tab；失败绝不切到当前版本。worktree/dependency 的 open 需重读并
contentID 匹配：worktree 只用仍 current 的 EngineSession captured bytes，dependency 才读受 predicate 限制的
绝对路径。**Expand** 同样校验来源：projectCommit 重读 captured revision，worktree 取仍 current 的 captured
bytes，dependency 重读 captured path；仅 contentID 匹配才按同一 helper 生成并持久化更大的 frozen range/text，
绝不改取当前不同版本的内容；mismatch 只禁用 open/expand。

**frozen Inspector mode**：MainWindowController 的 View Evidence 展开既有 relation pane，并调用
RelationWindowController 的最小 frozen-display entry；它复用 `ResolutionInspectorView`，但不设
`inspectedNode`、不伪造 `Node`/`RelationQueryContext`，也不查询 provider。controller 增加明确 mode：
`render()`/reload 在 `model.root == nil` 时仅隐藏 **live** mode，不得隐藏或 replace frozen mode；关闭
frozen Inspector 或随后点 live row 才回到 live mode。live-only “Open former candidate” 在 frozen mode 若
payload 标记可用则走 excerpt 的 captured-source action + contentID gate，否则隐藏/disabled，且各一断言；
不得留下失效 closure。Inspector 只由每段 **查看证据** 打开，不是集合入口，capture-time availability/
environment 明确不冒充 current readiness。

**验收**：D6 固定五段 fixture 在 Light/Dark/SI Classic 三主题验证全宽连续流、每段出处头、三动作、
选择/复制、键盘、AX、空态；Relations 与 Trail 各自产出规则、skipped reason、producer 顺序、固定五段
及 payload 均有断言。冻结前后 Inspector 的**稳定内容字段**（title、badge、why/source、verification、
correction、AT CAPTURE availability/environment、stable provenance/audit、AX）逐项一致；AT CAPTURE title
与 live-only control 是明确 mode 差异，分别断言，不能再声称所有可见字段相同。重启后 View Evidence 打开 frozen Inspector；
session JSON 不编码 UUID 字段或 `SnapshotID`/`PathID`/`NameID`/会话 ID（不把任意冻结源码文本误判为 ID），
capture-time 状态不显示为 current readiness。另断言：导航后修改磁盘时，current installed worktree 仍从
captured bytes 产出原 excerpt；旧 worktree snapshot 不可解析则 skip。覆盖 `Reading Set → File → Reading Set` 回到同一 excerpt/scroll、
退出重启恢复 active Reading Set 与 scroll、frozen Inspector 在 relation refresh/root nil 后仍可用。复用既有
`--self-test-tabs`（tab 生命周期/恢复）与 `--self-test-reading`（只读文本/AX），不新增未命名通道。

---

## §4 实现切片

每片验收：`swift test` 全绿 + 该片点名断言 + 不破坏既有断言。

### P0：三主题 HTML 原型与裁决（最先，不依赖代码）
折叠占位符 chip（含动态计数区）、折叠柄、高度档控件位置、palette 布局、常驻作用域头。
产出 `evidence/m11/prototype-decisions.md` + 三主题截图。
**§3.7 的 imports/cfgTest 归档、Folding 菜单文案、Focus 键位，以及基于 M10 D6 原型的 Reading Set
header、AT CAPTURE Inspector 文案、三动作（含 disabled）状态在此定稿。**

### F0：`FoldRegion` 提取
七种 kind 的 header/body 边界（§3.0 表，**按语法节点切**）、排序+贪心 laminar 消解、
确定性身份、**传输 seam**。
验收：逐种边界断言（含 `use`/`#[...]`/块注释**单个跨多行节点 → 不产出**与**多个相邻节点
合并**、无花括号 closure 不产出）；
**传输 seam（评审 P1）**：新增 `package highlightWithFolds`，`public highlight` 调它丢弃
`folds`（公开签名不变）；`ReaderDocument.foldRegions` 由 `DocumentLoader.load` 与
`loadSyntax` **两条加载路径**都装配，各一断言（同步/异步都不旁路）；
**候选列表置换测试**（若干确定性重排后接受结果**逐字段相同，含 tie-breaker 的
header/body 最深比较键**）——这才抓得住顺序相关性，"同 fixture 跑两次"抓不住；
**空 body 候选被拒**断言；`cfgTest/container`、`declaration/block`、同 kind 部分交叠
三组各一条胜者断言；laminar 断言；`FoldID` 在排序消解之后分配、无空洞；
**并列处理**：全字段相同 → 去重；几何同但 summary 异 → 整组拒绝（不产出，不靠 ordinal /
assert）各一条断言；
**解析次数不变**（复用 `RustExtractor.parseObserver`）；
**F0 提取性能门禁（固定 workload）**：贪心最坏 O(n²)，但本轮只接受 §3.2(4) manifest 所锁定的
8,400 候选、8,400 接受项；计时前先验 manifest 的 SHA、candidate/accepted/kind/depth 分布，不能用
空或稀疏文件替换。该固定 workload 下，release 消解 **≤ 500 ms**。若真实产品样本越过 10,000
候选或此门禁失败，下一次计划修订必须选次平方结构；不预先加区间树。F2 的首次折叠预算不覆盖
加载阶段的 region 消解成本，故两项分别门禁；由 §3.2(4) 生产消解调用周围的 observer 写入 app JSON
的 `resolutionMs`，runner 对 control/fold 两值各自判 ≤500ms，不能只留 prose 预算。新增并发/非旁路
断言：`loadSyntax` 的 detached 路径收到一次 `@Sendable` sample，collector completion 后读取到同一完整值；
nil observer 不写 collector 且正常加载；注入两个 sample 或 completion 前读取均 FAIL。断言 observer 在
计时结束后才写 collector，确保锁不污染 `resolutionMs`。

### F1：单遍 projector + `DisplayMap` seam（22 处迁移）
§3.1 全部：projector 同时产出 `(attributed, map)`；22 处改走 `DisplayMap`；
`rg` 门禁（ReaderUI 内**除 `DisplayMap` 实现文件这一个例外**外，对 `ByteUTF16Map|byteUTF16Map`
**零引用**）；往返命题与 optional 失败语义逐条断言（含 `visibleSourceRanges` 不含折叠 body、
在占位位置为空，评审 ④）；**恒等投影回归门禁**；保险丝按 §3.5 改写。
**新通道 `--self-test-projector` 承载以上门禁回归**（§0/§V0 具名）。
**本片零可见 UI 变化**，是本轮工作量最大的一片，不与 F2 合并。

### F2：折叠附件 + gutter 折叠柄 + 原子入口
**第一步是 spike**（§3.2(3)）：在真实 `ReaderTextView` 上打通并证明附件机制的
**创建 / 更新 / 点击 / AX** 四件事，并裁决 hit testing 归属。**spike 未过不写 chip 视觉。**
随后：渲染集归一（§3.2(1)）、状态作用域（§3.2(2)）、可点击折叠列、
`hiddenLineCount < 2` 不画柄、原子入口（§3.2(4)）。
验收：新通道 `--self-test-fold`；三主题截图；AX 断言；
**同一折叠在 0 / 3 / 999 matches 三态下 attachment 宽度与整行排版宽度不变**断言；
**附件高度 ≤ 单行行高**断言；
**锚点可见 / 被隐藏两种情形的还原**各一条；
**selection 与 viewport 两份 latent 各自生效** + **两者落入两个不同 fold、依次展开各自还原**
（§3.3，评审 ② 点名场景）；
**切回旧 `contentID` 覆盖集合原样归来、`contentID` 变化不污染旧 pair**（§3.2(2)，评审 P2-2）；
**折叠后 `visibleSourceRanges` 扫描的引用计数只随可见源码增长、随 `hiddenLineCount` 不增**
（§3.1，评审 ④）；
**嵌套折叠只渲染极大元、展开外层后内层仍折**断言；
**`lineNumbers = false`、`diff` 为空、存在可见折叠区 → ruler 仍显示且折叠柄可点击**回归断言
（评审 P2，`needsRuler` 参与折叠判断）；
**巨档首次折叠延迟 ≤ 400 ms 与折叠峰值 RSS 增量 ≤ 80 MB**固定语料硬阈值（§3.2(4)，
`run-fold-perf.sh` release 下执行、独立进程采样，PASS/FAIL 命令见 §3.2(4)）。

### F3：折叠下的复制与选择
§3.4 全部，含**剪贴板不含 `U+FFFC`** 断言。独立成片（§1 合同项且失败静默）。

### F4：阅读高度档
`⌥⌘0/1/2` + P0 控件 + View ▸ Folding 五项菜单。仲裁按 §3.8，自动折叠过滤按 §3.0。

### F5：Focus 当前作用域
§3.9 全部：**焦点 scope 从 `outlineFacet.range` 选**（caret 停在签名行或收尾 `}` 上仍能选中）、
`cfgTest` 计入 container、无 scope 不折、独立模式与还原、退出、跨文件跟随/退出、跟随仲裁。
每条各一断言，含"caret 在 header 行"与"caret 在闭合花括号"两条。
**Focus 测试必须含一个 `.block`、一个 `.comment`、一个 `.attributes` 区间，断言它们被折叠**
（评审 P2：Focus 是"manual-only"的显式例外，见 §3.9）。
**只留 private helper，不提前抽公共 seam。**

### R0：⌘F 文件内查找
**第一步是把 `asciiFold` 与 `literalRanges` 从 `SnapshotSearch` 提取为 Core 的 package 级函数**
（§3.14；两者现为 `private static`，不提取就只能抄一遍，等于两套大小写语义）。
随后 §3.14 全部，含去抖、任务取消、扫描循环内 `Task.checkCancellation()`、
**取消与完整合同闭环**（模型持有并逐个取消 worker、扫描抛 `CancellationError`、
不设 wall-clock 截断、只有完整结果才发布，评审 ⑤）三者各一断言、
**文档代际发布守卫**（`(fileURL, contentID, query, caseSensitive)` 绑定；延迟扫描期间
切文件 / 切 snapshot / 关闭 find bar 各断言旧结果不发布，评审 ⑤）。
**必须早于 F6。**

### F6：折叠诚实合同
§3.11 四条逐条实现、逐条独立断言。依赖 F2（附件绘制）与 R0（真实命中）。

### C1：Palette 五模式
§3.12 / §3.13。**palette 每次打开即缓存原 responder 并采集菜单**（不是等输入 `>` 才采集）、
执行前还原 responder 并重新验证、跳过 `action == nil`、
排除编辑命令，四条断言；文件模式用 `FileTreeModel`；Open Recent 与隐藏备用项各一条；
**查询合同（评审 P2）**逐条断言：每种模式匹配/排名/稳定 tie-break、结果上限 20、同名文件消歧、
空查询、非法与越界 `:line`、查询变化后 selection 重置/保留。

### R1：常驻作用域头
§3.15：最小包含 facet + kind 兼容关联；无匹配 facet 的层不进；无包围声明不留空条。

### R2：Copy path:line / Reveal in Finder
右键菜单 + 菜单项。格式与 Inspector / Trail 现用一致。

### R3：会话恢复 + `replayOffset` 修正
**依赖 M11D 的 final tagged session schema**（不得先做 file-only v1 再二次迁移）。§3.16 + §3.17：
两锚点分别捕获与恢复、**失活时**捕获、**active file tab 的 selection 锚点单独构造**、
`activeTabOrdinal` 映射、readingSet frozen payload、open/activate/scroll 去抖 checkpoint、close/LRU 的
last-installed topology 同步 checkpoint 与**退出路径同步原子写入、取消 debounce**、恢复顺序、未知版本整份忽略、
trust-boundary 上限/路径逃逸整份失败、
**前置文件缺失时 active tab 不错位**断言、
**切 snapshot 的 coherent checkpoint**（只在安装完成的三元组写盘、失败不写、代际不符的
恢复任务取消、延迟切换后立即退出不写混合记录、切换中启动恢复后手动开另一项目不污染，
评审 ⑥）各一断言；
**`path` 语义：项目文件用项目内相对路径、dependency 文件用绝对路径，各一条恢复断言**
（评审 P2-3）；
五档阶梯逐档断言、标量边界校验断言、`FallbackKind` 措辞断言、`symbolAnchor` 唯一命中断言、
producer 审计结论、**重跑 M10 replay 断言**并出迁移清单。

### R4：Settings 缓存 + ⌘± + 换行
§3.18 + §3.19。**第一步是复现测试，不预设 gutter 有缺陷**；含 `ReaderSettings.wrapLines`
默认值与 UserDefaults round-trip、Settings toggle、水平滚动条与 document view 的双向恢复，以及真实
NSMenu `⌘+`/`⌘-` 的 1pt/10...24 边界、文件/Reading Set/Settings window 即时同步。

### M11D：Reading Set + `TabContent`
§3.20 全部，**先于 R3；R3 依赖其 final schema**，且需既有 M10 Relations/Trail records。先以 D6 `spawn` 固定五段
fixture 完成 `TabContent.file` / `.readingSet` 分派、truth-preserving optional `fileURL` 与所有现有
消费者迁移；再完成 Relations live capture、NavigationExplanation/TrailEdge observed-at-navigation capture、
frozen relation-pane mode、同代际 excerpt helper、全宽连续流和三项动作；最后由 R3 写入/恢复同一 v1
tagged union。三主题、键盘、AX、选择/复制、逐段不可读和空态均为验收；复用
`--self-test-tabs` / `--self-test-reading`。断言 Reading Set 不进入 file anchors/⌘F/Focus/fold，active 时
`⌘P`/`>`/`#` 仍可用而 `@`/`:` 禁用提示，
但**必须**随 tab 生命周期和 session 恢复；不得以虚构 URL、registry、StableSymbolID 或第二 store
替代 §3.20。

### V0：总验收
先设 repo-local cache 并确认 `RECORD` 未设置；命令矩阵是唯一可执行总验收，不用笼统“跑全绿”代替：

```sh
set -euo pipefail
M11_BASE="2569e70486e93cc3e547201de1c80657d98f0adf"
git rev-parse --verify "$M11_BASE^{commit}" >/dev/null
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
[[ -z "${RECORD:-}" ]]
bash scripts/provision-corpora.sh --check
bash scripts/provision-corpora.sh --gen-fold-fixture fixtures/fold_perf.rs \
  --manifest fixtures/fold_perf.manifest.json
swift build --disable-sandbox
swift test --disable-sandbox
selftest_git_repo="$PWD"
selftest_non_git_dir="$(mktemp -d /private/tmp/codeinsight-m11-selftest.XXXXXX)"
selftest_open_file="$PWD/Tests/RustExtractorTests/Fixtures/inline_mod/main.rs"
trap 'rm -rf "$selftest_non_git_dir"' EXIT
cp "$selftest_open_file" "$selftest_non_git_dir/main.rs"
test -d "$selftest_git_repo/.git" && test -f "$selftest_non_git_dir/main.rs" && test -f "$selftest_open_file"
CODEX_SANDBOX=1 bash scripts/run-self-tests.sh "$selftest_git_repo" "$selftest_non_git_dir" "$selftest_open_file"
CODEX_SANDBOX=1 bash scripts/stress-test.sh --runs 5 --load 8 --timeout 180
swift build -c release --disable-sandbox --product codeinsight-app
bash scripts/run-fold-perf.sh --app-bin .build/release/codeinsight-app \
  --fixture fixtures/fold_perf.rs --manifest fixtures/fold_perf.manifest.json
CODEX_SANDBOX=1 bash scripts/ci.sh
bash scripts/run-gold-gates.sh
```

`run-self-tests.sh` 的三个实参由矩阵中的当前 CodeInsight git repo、`mktemp` 后复制了具名 Rust fixture
的 non-git directory 与 `Tests/RustExtractorTests/Fixtures/inline_mod/main.rs` 提供，并在 evidence 记录绝对路径与每一条（含 `--self-test-tabs`/`--self-test-reading`、新增具名
projector/fold）的 JSON 结果；stress 固定 `--runs 5 --load 8 --timeout 180`，记录实际命令与 PASS。
以上全绿后再做 CUA 任务式验收。**证据分级**：fixture/self-test PASS 仅证明确定性 UI、冻结与编排，
绝不冒充真实 rust-analyzer。CUA 必须用新构建 app 与 provisioned Tokio，分别实际走
Relations → Reading Set 和 Trail → Reading Set；成功才记录 real-provider PASS。若宿主 sandbox 阻止 RA，
记录精确 provider/sandbox 错误与 BLOCKED，并与 fixture PASS 分列；不得用 fake/provider-less 结果填
real-provider PASS。

**变更与受保护产物审计（评审 P1）**：M11 开始实现前把 base commit
`2569e70486e93cc3e547201de1c80657d98f0adf` 记录为 `M11_BASE`；若实现从不同提交开始，先在
计划顶部和验收记录中更新该值，再写任何产品代码。不能只查 worktree：分片提交后普通 `git diff`
会漏掉 M11 修改。V0 必须逐项证明：

- `RECORD` 未设置（`[[ -z "${RECORD:-}" ]]`）后才跑会接触 fixture 的测试；并运行
  `git diff --check "$M11_BASE...HEAD"`、`git diff --check --cached`、`git diff --check`。
- **完整变更域**：审计 `git diff --name-status "$M11_BASE...HEAD"`、`git diff --cached
  --name-status`、`git diff --name-status` 与 `git ls-files --others --exclude-standard` 的并集。
  产品实现允许只落在本计划点名的 `Sources/CodeInsightCore/`、`Sources/CodeInsightEngine/`、
  `Sources/CodeInsightReaderCore/`、`Sources/CodeInsightReaderUI/`、`Sources/CodeInsightAppModel/`、
  `Sources/CodeInsightApp/`、对应 `Tests/`、`scripts/`、
  `fixtures/fold_perf.rs`、`fixtures/fold_perf.manifest.json`、`docs/plans/m11-plan.md` 和
  `docs/plans/evidence/m11/`；每项仍须能映射到 F/C/R/M11D 切片，不能以宽泛目录掩盖无关清理。
- **protected deny-list** 独立于上述产品 allow-list：
  `Sources/CodeInsightEngine/CanonicalDump.swift`、`goldset/**`、`docs/goldset-baseline.md`、
  `Prototypes/**`、`docs/plans/evidence/m10/**` 对 `M11_BASE...HEAD`、index、worktree 均必须零差异。
  `fixtures/fold_perf.rs` 与其 M11 manifest 是特意授权的新 fixture，不属于 deny-list。允许修改
  `scripts/provision-corpora.sh` 以生成/验证 M11 fixture，但审计其既有 `TOKIO_TAG`、`TOKIO_DIR`、
  `TOKIO_REPO`、`RIPGREP_TAG`、`RIPGREP_DIR`、`RIPGREP_REPO` 常量逐字节未变；任一既有基准确需
  变更必须另有用户授权和迁移记录。
- **deny-list 也检查 untracked**：不能只用 diff。V0 将 `git ls-files --others --exclude-standard` 的输出
  与 `^Sources/CodeInsightEngine/CanonicalDump\.swift$|^goldset/|^docs/goldset-baseline\.md$|^Prototypes/|^docs/plans/evidence/m10/`
  取交集；任一命中即 FAIL，并将该命令和空输出写入 evidence：

  ```sh
  if denied_untracked=$(git ls-files --others --exclude-standard | rg \
      '^(Sources/CodeInsightEngine/CanonicalDump\.swift|goldset/|docs/goldset-baseline\.md|Prototypes/|docs/plans/evidence/m10/)'); then
    echo "$denied_untracked"; echo 'FAIL: protected untracked path'; exit 1
  else
    rc=$?; [[ $rc -eq 1 ]] || { echo "FAIL: untracked deny audit rc=$rc"; exit 1; }
  fi
  ```
- **provision 常量审计命令**（写入 evidence，任一差异 FAIL）：

  ```sh
  : "${M11_BASE:=2569e70486e93cc3e547201de1c80657d98f0adf}"
  git rev-parse --verify "$M11_BASE^{commit}" >/dev/null
  for name in TOKIO_TAG TOKIO_DIR TOKIO_REPO RIPGREP_TAG RIPGREP_DIR RIPGREP_REPO; do
    base=$(git show "$M11_BASE:scripts/provision-corpora.sh" | rg "^readonly ${name}=")
    head=$(rg "^readonly ${name}=" scripts/provision-corpora.sh)
    [[ "$base" == "$head" ]] || { echo "FAIL: provision constant changed: $name"; exit 1; }
  done
  ```
- 审计输出（base SHA、四个路径列表、deny-list 检查、未跟踪文件列表）写入 M11 evidence；不满足即
  FAIL。这样既不会误杀正常产品实现，也不会漏掉已提交或未跟踪的变更。

| 任务 | 判据 |
|---|---|
| Overview 档扫 tokio `join_set.rs` 找到 `abort_all` 并展开 | 零错误导航；占位符信息足以定位 |
| ⌘F 搜出现在折叠区内的标识符 | 总数与可见数不一致时界面明说；跳转自动展开 |
| **全折叠后 ⌘A ⌘C 粘贴到外部** | 完整源码，无 `U+FFFC` |
| ⌘P 打开文件、`:449` 跳行、`>` 执行折叠命令 | 三模式各一次，全程不碰鼠标 |
| Focus 后滚动，再跳到无包围 scope 的文件顶部 | 内容不跳；滚动解除跟随不退出模式；无 scope 时明确退出并提示 |
| 关闭重开恢复会话 | `.exact` / `.line` 两条文件路径各验一次；scroll/selection 回来，active Reading Set 与冻结 payload 也回来 |
| Relations / Trail 打开 Reading Set | 各自按 §3.20 source/order 取数；tokio `spawn` fixture 严格五段、出处头、三项动作、三主题、选择/复制、键盘/AX、逐段不可读与空态均通过 |
| provisioned Tokio 的真实 Relations / Trail → Reading Set | 新构建 app 的 CUA 两路径各一次；记录 real-provider PASS，或精确 RA/sandbox 错误的 BLOCKED；不得以 fixture 代替 |

---

## §5 顺序与检查点

```
P0 ─┬─ F0 ─┬─ F1 ─ F2 ─ F3 ─ F4 ─ F5 ─ F6 ─┐
    │       └─ R1 ─────────────────────────────┤
    └─ M11D ─┬─ R3 ────────────────────────────┤
R4 ──────────┘                                 │
R0 ───────────┬─ F6 ───────────────────────────┤
F4 ───────────┴─ C1 ───────────────────────────┤
R2 ────────────────────────────────────────────┤
                                                V0
```

- **F 链严格串行**：F1 的 projector 与 22 处迁移不完成，不许动 F2（§3.5）。
- **F3 紧跟 F2**：附件一落地复制就在吐 `U+FFFC`，不允许推后。
- **R0 早于 F6**：F6 第 2 条断言依赖真实查找存在。
- **C1 同时依赖 F4 与 R0**：F4 让 Folding 菜单项存在；R0 先把 `asciiFold` 提为唯一的 Core
  语义实现，C1 才能复用而非复制匹配规则。
- **M11D 依赖 P0 与既有 M10 Relations/Trail**：P0 先定 excerpt/head、AT CAPTURE Inspector 与动作状态文案；M11D 先于 R3，令 v1
  session 一次完成 tagged union；所有分支均汇入 V0。
- **R4 排在最前的独立位**：settings 缓存是既有地雷，先拆再叠功能。

**Checkpoint A**：P0 / F0 / F1 / R4 —— 结构数据、单遍 projector 与坐标迁移、地雷拆除，零可见回归。
**Checkpoint B**：F2 / F3 / F4 / F5 / R0 —— 折叠可用且复制诚实，三主题截图与 AX 齐备。
**Checkpoint C**：F6 / C1 / R1 / R2 / M11D / R3 / V0 —— 诚实合同、统一入口、Reading Set 先定 schema、会话恢复、
Reading Set 与总验收。

---

## §6 风险与对策

| 风险 | 对策 |
|---|---|
| **复制静默丢源码 / 吐 `U+FFFC`** | §3.4 定为 §1 合同项；F3 独立成片紧跟 F2；V0 含粘贴到外部 |
| **storage 与 map 等长错映射**（长度保险丝抓不到） | §3.1 单遍 projector 同时产出两者，由构造保证；保险丝降为纵深防御 |
| 22 处换算遗漏，表现为"偶尔高亮/点击错位" | `rg` 门禁（ReaderUI 零直接引用）+ 逐处点名 + 恒等投影回归门禁 |
| 占位符被半选 / 行尾假设不成立 | §3.2 改 `NSTextAttachment`，长度恒 1，实测证据在 `evidence/m11/` |
| 附件高度撑高行，几何漂移 | F2 断言附件高度 ≤ 单行行高 |
| 折叠区部分交叠导致映射非法 | §3.0 排序 + 贪心 laminar 接受 + 三组冲突胜者规则 + laminar 断言 |
| **交叠消解顺序相关**（三区间链式交叠时 survivor 取决于检查次序） | §3.0 winner tuple 定序 + 贪心；**候选置换测试**（"跑两次"抓不住） |
| **嵌套折叠产出套在隐藏文本里的附件** | §3.2(1) 渲染集 = 逻辑集极大元；内部状态保留，展开外层不展开内层 |
| **折叠状态跨文件碰撞**（`FoldID` 是文件内下标） | §3.2(2) 覆盖项按 `(fileURL, contentID)` 隔离 |
| **`contentID` 变化清空与切回恢复自相矛盾** | §3.2(2) 按 pair 隔离、新旧 pair 不互清 |
| **单节点跨行结构得到空 body、折不了** | §3.0 空 body 候选不产出；`imports` 合并折叠只作用于 ≥2 条 runs |
| **winner tuple 同几何但摘要矛盾** | §3.0 全字段同才去重；几何同而 summary 异整组拒绝，不靠 ordinal 或 assert 控制流 |
| **finder 扫 `[ByteRange]` 取消/截断产生假零命中** | §3.14 模型持有并取消 worker；扫描抛 `CancellationError`；不设 wall-clock 截断 |
| **附件机制落空**（裸 attachment 无 provider、`bounds` 不生效，实测） | §3.2(3) F2 第一步是 spike，证明创建/更新/点击/AX 后才写视觉 |
| **计数变化改变 chip 宽度→重新断行** | §3.2(3) 固定宽度计数区，只重绘不加宽；三态宽度不变断言 |
| **锚点落在刚被隐藏的区间** | §3.3 可见精确/隐藏落到附件；selection/viewport **各自独立 latent 锚点**各绑 FoldID |
| **selection 与 viewport 分落不同 fold 时丢一个位置** | §3.3 两份 latent 分别还原；F2 有"分属两 fold 依次展开"断言 |
| **viewport gating 误用复制映射把隐藏 body 扫回来** | §3.1 新增 `visibleSourceRanges`；F2 断言引用计数只随可见源码增长 |
| **退出走去抖写，进程先结束丢最后状态** | §3.16 退出路径同步原子写入 + 取消 pending debounce；普通事件才去抖 |
| **巨档折叠主线程重建整份 storage** | §3.2(4) 本轮保留简单方案，但加固定语料硬阈值：首次折叠延迟 ≤ 400 ms、峰值 RSS 增量 ≤ 80 MB |
| **`cfgTest` 去重后失去 container 语义** | §3.0 下游一律按 container 对待；§3.15 兼容表含 `cfgTest ↔ mod` |
| **⌘F 抄一份大小写语义** | §3.14 先把 `asciiFold`/`literalRanges` 提取为 Core package 级函数再共用 |
| **缺失 file entry 令 active tab 错位** | §3.16 保存 activeTabOrdinal 并以 old-ordinal→new-index 映射恢复 |
| **`replayOffset` 修正回归 M10** | §3.17 第 2 档保号；两档补标量校验；R3 重跑 M10 断言并出迁移清单 |
| 会话恢复丢失 scroll/selection 之分或补不出锚点 | §3.16 两独立锚点 + **失活时**捕获 + 恢复顺序固定 |
| **Reading Set 被再次静默移出 M11（违反 D6）** | §2/§3.20/§4/§5 将 M11D 作为必做切片；V0 未验其连续流与入口即 FAIL |
| **Fold 数据无传输 seam（highlight 是 public、DocumentLoader 无承载）** | §3.1 `package highlightWithFolds` + `ReaderDocument.foldRegions`，覆盖 `load`/`loadSyntax` |
| **并列摘要矛盾时展示错误摘要**（ordinal 只解决确定性不解决真实性） | §3.0 全字段同才去重；几何同 summary 异 → 整组拒绝，不靠 ordinal/assert |
| **覆盖项无方向或未归一直接投影** | §3.8 `logicalFoldIDs=(baseline∖forcedUnfolded)∪forcedFolded` 后 `renderedFoldIDs=maximal(logicalFoldIDs)`；切档清所有 pair + 双向测试 |
| **⌘F 旧代际结果贴到新文档** | §3.14 发布绑定 `(fileURL, contentID, query, caseSensitive)`，切文件/快照/关闭作废 |
| **切 snapshot 写盘产生"新 revision+旧 anchors"混合记录** | §3.16 generation-keyed coherent checkpoint：只写安装完成的（revision,document,anchors），失败不写，旧恢复任务取消 |
| **性能门禁测成空工作或漏峰值** | §3.2(4) manifest 锁 8,400 候选/接受项与 preset；`control|fold` 新进程、后台 25ms 全窗口采样、合法 JSON 判定 |
| **detached load 丢 observer 或并发读到半份 sample** | §3.2(4) `@Sendable` closure 显式穿透 `loadSyntax`；perf harness 私有同步 collector，completion 后同锁读取，缺失/重复/早读 FAIL |
| **行号关+diff 空时折叠柄无处可点** | §3.10 `needsRuler` 参与折叠判断 + 折叠列计入宽度 + 回归测试 |
| **Focus 与 "manual-only" 冲突，三类漏折叠** | §3.9 Focus 是显式例外折叠一切 kind；F5 测试含 block/comment/attribute |
| **F0 贪心 O(n²) 超出可接受规模** | §3.2(4)/F0 用同一 fixture 固定 8,400 候选并设 release ≤500ms；真实样本超 10,000 或门禁失败才升级次平方 |
| **F5 语义不全导致无法验收** | §3.9 六条语义全定义，F5 每条各一断言 |
| **Reading Set 被伪装成文件、重启漂移或丢 lifecycle** | §3.16/§3.20 的 tagged union + optional fileURL + frozen source/evidence/contentID；Reading Set 进 session 但不走 file anchors |
| **Trail 迟开集合改写导航当时证据** | §3.20 在语义导航时值携带 frozen display；Trail 只读 edge observed-at-navigation，不查 current store |
| **relation reload 抹掉重启后的证据视图** | §3.20 frozen mode 与 live mode 分离；root nil/reload 不隐藏 frozen Inspector，关闭/点 live row 才切回 |
| **异常 session 复活已关闭 tab 或路径逃逸** | §3.16 topology checkpoint + codec 上限/相对路径/dependency 校验；非法整份失败 |
| **Fold seam 加 package 字段但 public init 编不过** | §3.1 `package` designated init + 保留原签名 `public` convenience（foldRegions 默认空） |
| **projector 双真值**（document.foldRegions 与 folds 参数并存） | §3.1 projector 参数改 `renderedFoldIDs`，定义只从 `document.foldRegions` 读 |
| **导航展开手动折叠区时两集合交叠** | §3.8 转移表：先删 `forcedFolded`，baseline 含才加 `forcedUnfolded` |
| **rg 门禁零命中触发 set -e 误杀 CI** | §3.1 显式处理退出码：0=FAIL/1=PASS/≥2=工具错，不用 `! rg` |
| **性能 runner 指错 target**（CLI 无 ReaderUI） | §3.2(4) 改 `codeinsight-app`；具名 `--fold-perf-fixture` 入口 + JSON 输出 |
| **"稳定后取峰值"不是峰值采样** | §3.2(4) 窗口内固定周期持续采样取最大；`delta = foldPeak − controlPeak` |
| **inactive tab anchor 被误称为新 snapshot 精确位置** | §3.16 仅一个全局 target revision；tab 保存 `anchorContentID` provenance，失配按 §3.17 降级 |
| **Palette 各模式无查询合同** | §3.13 匹配/排名/稳定 tie-break/上限/消歧/空查询/非法行号/selection 行为 |
| **memberCounts Dictionary 顺序不稳定** | §3.0 renderer 用固定 `OutlineKind` 序；不同插入序断言文案一致 |
| **V0 漏掉已提交、index 或未跟踪修改，或改写基准** | §4 记录 M11 base，审计 base...HEAD + index/worktree/untracked；产品允许路径与 protected deny-list 分开 |
| palette 在搜索框 responder 上验证命令 | §3.12 采集在转移 responder 之前，执行前还原并重新验证 |
| 在错误的 TextKit 前提上做 R4 | §3.18 前提已被实测推翻；R4 第一步是复现测试 |
| ⌘F 大小写语义自造 / 巨档逐键卡顿 | §3.14 提取 `asciiFold` 复用；复用 `requestID` 去抖，模型持有并逐个取消其 detached worker handle |
| 自动折叠产生没有柄的一行占位符 | §3.0 高度档/Focus 的自动折叠同样过滤 `hiddenLineCount < 2` |
| 切片过多导致"某片红了但报全绿" | F3 / F5 / F6 独立成片；每片点名断言；沿用 M10 逐条取证纪律 |
