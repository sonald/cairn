# M1 Reader Alpha 实现计划（Planner: Fable 5, 2026-07-20）

本文件是 M1 执行的权威依据。执行者按切片（S1–S7）实现，每片验收以"无头验收"为准，
"人工清单"由决策者执行。通用约束见文末。

**目标**（design §16）：AppKit 壳 + 阅读区 + 文件树 + 符号模糊搜索 + Context Window
（Follow/Pin、局部作用域、渐进回答）+ 跳转历史。验收："用它读 tokio 不想切回 IDE"；
冷启动 < 500ms、空载 < 100MB；打开文件按 §15 分档。

**不做**：Call Tree/Relations、全文搜索（M2）；git 时间旅行（M3）；exact provider（M4）；
多标签/分屏；符号大纲面板（M2）。

## 决定 1：App 形态 —— SwiftPM executable target，不引入 Xcode project

主包 Package.swift 增加 `.executableTarget(name: "CodeInsightApp")`，程序化
`NSApplication` 启动（`setActivationPolicy(.regular)` + 程序化主菜单）。理由：
M1 只需本机调试；执行者无头环境下 SwiftPM 单一 `swift build && swift test` 保住
ci.sh；TextKitProbe 已证明该路径可承载完整 AppKit 窗口。签名/bundle 留 M4。

## 决定 2：App 架构

### 模块划分（新增 4 个 target）

```text
CodeInsightAppModel    (无 AppKit)  AppModel 状态机、FileTreeModel、ContextWindowModel、
                                    NavigationHistory、SymbolSearchPanelModel、IndexService
CodeInsightReaderCore  (无 AppKit)  ByteUTF16Map、RustHighlighter(span 索引)、ReaderDocument、
                                    分档 Tier、视口门控纯逻辑、excerpt/折叠计算
CodeInsightReaderUI    (AppKit)     NSTextView + TextKit 2 栈、rendering attributes validator、
                                    主题/字体/行距
CodeInsightApp         (AppKit,exe) AppDelegate、窗口/SplitView 控制器、菜单、快捷键、面板 view
```

依赖：`App → {AppModel, ReaderUI}`；`ReaderUI → ReaderCore`；`AppModel → Engine/Core`；
`ReaderCore → TreeSitterKit + CTreeSitterRust + CodeInsightCore`。
**ci.sh AppKit 禁令扩展覆盖 CodeInsightAppModel 与 CodeInsightReaderCore**——
一切可单测逻辑放这两个无 AppKit module。

### 窗口层次

```text
AppDelegate → MainWindowController
  └── 外层 NSSplitViewController（垂直）
      ├── 内层 NSSplitViewController（水平）：SidebarViewController（NSOutlineView 文件树）
      │                                     + ReaderViewController（阅读区）
      └── ContextWindowViewController（底部面板：header 条 + mini reader）
  工具栏：项目名 + 索引状态项；浮层：SymbolSearchPanel（NSPanel，Cmd+T）
```

### 引擎生命周期与 actor 边界

- `AppModel`：`@MainActor @Observable`，`ProjectState = empty / indexing / ready(session, context) / failed`。
- `EngineSession` 是 Sendable：后台构建、整体交 MainActor。
- `IndexService` 协议化（测试注入）。**`ProjectIndexer.index` 内部阻塞（信号量），
  必须 `Task.detached`（.userInitiated）调用，严禁放协作线程池。**
- resolve 纯内存毫秒级，可 MainActor 直接调；callers/搜索走 detached。
- 单窗口单项目；重开项目 = 整体替换 + generation 递增防串。

### 打开项目流程（F1.2 索引中 UI 可用）

阅读区完全不依赖引擎（打开文件时 ReaderCore 自行 parse + 高亮）。引擎只服务
跨文件语义。流程：选目录 → t+0ms 文件树可见（FS 枚举，skip 清单复用引擎 public 常量）
→ 后台索引，工具栏 "Indexing N files…" → 期间阅读全功能，Cmd+T/Context 显示占位
→ ~700ms session 就绪，功能激活。

## 决定 3：阅读区产品化

`ByteUTF16Map` 连同单测**原样抬升**进 ReaderCore；`ProbeSession`/`LazyRenderingProvider`
按 FINDINGS 结论**重写**。探针目录保留作对照。

| 探针结论 | 产品化落点 |
|---|---|
| viewport 门控 + validator 二次范围判断 | `RenderingAttributesCoordinator`：validator 内按 viewportBounds ± 2 屏与 fragment frame 相交才写属性；**暴露"实际写属性 fragment 数"计数器**并进自测断言 |
| byte↔UTF-16 checkpoint | ByteUTF16Map 抬升；高亮只存 byte range，视口命中才转 NSRange |
| 行距 1.25 定案 | `ReaderTheme.lineHeightMultiple = 1.25` 常量 |
| 函数名 +1pt | `ReaderTheme.functionNameDelta = 1`，semibold + 微字距，layout 属性；注释人文字体 M1 默认关 |
| 巨档纯文本先行 | FileTier 分档见下 |

`FileTier`：regular ≤1 万行（同步全属性，与 large 共用 validator 渲染栈）；
large 1–5 万行 / huge >5 万行：纯文本 + 段落样式先上屏，parse + 高亮 detached 后
invalidate 视口。`ReaderDocument`（Sendable 值）：bytes/LineTable/ByteUTF16Map/
[HighlightSpan]/outline facets（同次提取顺带产出）。tree-sitter Tree 不跨 actor；
M1 提取时一次算完不长期持有 tree。`RustHighlighter` 放 ReaderCore（展示层组件，
Extractor 不出配色 span）。

## 决定 4：符号模糊搜索（F5.1）

引擎新增 `SymbolSearchIndex`（session 构造后惰性建一次）：
entriesSortedByNormalized（prefix 二分）+ acronymBuckets（词边界首字母）+
trigramPostings（兜底）。查询：归一化 → 三路召回并集（上限 2000）→ subsequence
打分（连续匹配/词边界/密度/长度惩罚）→ 上下文加权（kind、当前文件、同目录、
最近访问 SearchBoost）→ Top-K 经 NamePosting/definitionOccurrences 展开为 occurrence 行。
API：`EngineSession.searchSymbols(query:limit:boost:context:) -> [SymbolSearchHit]`
（含匹配区间供 UI 加粗）。CLI 加 `symsearch` 子命令（无头验收 + 排序回归载体）。
UI：Cmd+T 居中 NSPanel（~560pt），NSTextField 即时过滤（debounce 30ms）+
NSTableView ≤50 行（kind 图标 + 名字匹配段加粗 + 路径:行号），↑↓/Enter/Esc。
选择/过滤逻辑在 `SymbolSearchPanelModel`（无 AppKit）。

## 决定 5：Context Window

底部固定面板（~180pt 可拖）：header（Follow|Pin、‹2/5› 候选切换 Cmd+Alt+←/→、
路径:行号、certainty·dispatch 标签）+ mini reader（复用 ReaderUI，regular 档规格）。

- 交互（F2.1）：hover 零查询（M1 连 tooltip 不做，Cmd-hover 仅变光标）；单击更新
  Context；Cmd+单击主区跳转。点击链：characterIndex → ByteUTF16Map → byte offset
  → `ContextWindowModel.tokenClicked(file:offset:)`。
- 去抖（F2.9）：引擎暴露 `tokenRange(file:offset:)`（包装 Resolver.locatedName 定位段），
  同 token 不重发。
- 取消：requestID 递增，apply 前比对；Pin 态忽略更新但 Cmd+click 仍跳。
- 渐进回答：M1 单次 resolve 已在热路径内，但 model 接口按 stage 设计
  （.localHit/.fuzzyCandidates/未来 .exactUpgrade），UI 管线从第一天支持晚到与原位升级。
  indexing 态显示占位，就绪后 pending 自动补查。
- 局部作用域（F2.6）：binding 类候选渲染"声明行 excerpt + binding kind"，不假跳全局。
- excerpt（F2.8 简化）：doc comment 吸附 + 签名行 + 函数体前 24 行 + "… n more lines"。
  Context 内 Cmd+单击 → 主区跳转；递归下钻独立历史留 M2。
- unresolved import 候选如实显示 "external crate — not resolved (M1)"。

## 决定 6：跳转历史（M1 单快照简化）

```swift
struct JumpRecord: Sendable {
    let path: String            // 相对路径字符串（不是 PathID——ID 是 session 作用域）
    let contentID: ContentID?   // 记录但 M1 不参与重放
    let byteOffset: UInt32
    let line: UInt32, column: UInt32   // 兜底
    let symbolAnchor: String?   // 记录但 M1 不参与重放
    let snapshotID: SnapshotID
}
```

`NavigationHistory`（@MainActor，数组+光标，浏览器语义）：push 截断前进栈、相邻去重、
上限 200；B/F 不自 push；push 的是离开前位置。重放：path+byteOffset → 越界退
line/column → 再退文件头。仅内存态。push 时机：Cmd+单击跳转、Cmd+T 打开、文件树打开、
Context 内跳转。快捷键 `Cmd+Ctrl+←/→` 主、`Cmd+[ / ]` 备（Go 菜单）。
打开文件管线统一收敛 `navigate(to:)` 单入口。

## 决定 7：性能预算落点

- 冷启动 <500ms：启动只做 NSApplication/菜单/空三面板；不碰 tree-sitter、不建
  Interner、不读磁盘、不恢复项目。
- 空载 <100MB：空态唯一风险是启动预热，别做。
- 测量通道（执行者无头验收唯一通道）：`codeinsight-app --self-test`（离屏跑到首窗口
  可见，JSON 输出 coldStartMS/idleFootprintMB，按预算 exit 0/1）；
  `--self-test-open <file>`（四级打开计时）；`--self-test-project <dir>`（文件树可见/
  索引就绪时间线）。TASK_VM_INFO.phys_footprint 从探针抬升。
- tokio 打开时序：t<50ms 文件树可见；文件随时可开（regular <100ms）；t≈700ms 语义激活。

## 切片（S1–S7 串行）

### S1 — App 壳与模块脚手架
4 个新 target、空窗口三面板、self-test 通道。涉及：Package.swift、AppModel 状态机、
四个空 VC、菜单骨架、ci.sh 扩展。无头验收：build 出 codeinsight-app；AppModel 状态机
单测（含非法转移拒绝）；`--self-test` exit 0（coldStart<500ms、idle<100MB）；ci.sh 全绿。
人工：三面板空态窗口、菜单骨架、Cmd+Q。

### S2 — 打开项目、文件树、引擎生命周期
NSOpenPanel → 文件树立即可见 → 后台索引 → ready。涉及：ProjectState 全实现、
FileTreeModel、IndexService、ProjectIndexer skip 清单提 public 常量（唯一引擎侧改动）、
SidebarViewController、状态项。无头验收：FileTreeModel 枚举单测（排序/skip/只含 .rs）；
fake IndexService 测时序与旧 session 丢弃（open A 后 open B，A 到达被忽略）；真实
IndexService 对 fixture 建 session 断言 stats。人工：Cmd+O 开 tokio，文件树 1s 内可见，
"Indexing 717 files…" 出现后消失，期间无卡顿。

### S3 — 阅读区产品化
涉及：ReaderCore{ByteUTF16Map 抬升+原测、RustHighlighter、ReaderDocument、FileTier、
ViewportGating、DocumentLoader}、ReaderUI{ReaderTextView、RenderingAttributesCoordinator、
ReaderTheme}、ReaderViewController 接线。要点：1.25 行距、+1pt 函数名、byte 权威、
validator 二次门控 + 计数器、large/huge 纯文本先行、暗色随系统。无头验收：
ByteUTF16Map 原测；Highlighter span 快照；FileTier 单测；ViewportGating 纯逻辑单测；
离屏 smoke：10 万行 first visible <2.5s 且实际写属性 fragment 数 <500；
`--self-test-open` 常规档 <100ms。人工：tokio 常规文件瞬开/高亮/排版/行距；10 万行
先纯文本后补高亮滚动不 hitch；复制无样式污染；暗色正确。

### S4 — 符号模糊搜索
涉及：SymbolSearchIndex、searchSymbols、CLI symsearch、SymbolSearchPanelModel、
SymbolSearchPanel。无头验收：三路召回/subsequence 排序（hndlconn 型）/加权/确定性
单测；`symsearch spawn --path <tokio>` Top-K 含 tokio::spawn；PanelModel 单测。
人工：Cmd+T `jhndl` → JoinHandle 前排；Enter 跳转；Esc 关；快速输入不闪烁。

### S5 — Context Window
涉及：ContextWindowModel、Excerpt、引擎 tokenRange API、ContextWindowViewController、
ReaderViewController 点击分流。无头验收：model 单测（去抖/乱序丢弃/Pin/候选循环/
indexing 补查）；Excerpt 单测；tokenRange 单测；集成：fixture 跨文件调用点候选
certainty·dispatch 标签断言。人工：单击引用 <50ms 出 excerpt 带标签；局部变量显示
声明与 kind；Pin 生效；‹›切换；Cmd+单击跳转同步；hover 零查询。

### S6 — 跳转历史
涉及：NavigationHistory、navigate(to:) 单入口收敛、Go 菜单快捷键、当前阅读位置提供。
无头验收：浏览器语义/去重/上限/兜底重放/B-F 不自 push 单测；AppModel 集成序列断言。
人工：A→B→C 后退两次回 A 原视口，前进恢复，菜单灰显正确。

### S7 — 性能验收与收尾
self-test 家族补全、bench.sh app 场景、修预算回归。无头验收：三 self-test 全 exit 0
（冷启动/空载/常规档 100ms/10 万行 2.5s/tokio 就绪 <2s）；ci.sh 全绿；全套测试通过。
人工（= M1 总验收）：读 tokio 30 分钟走查（spawn 入手、Context 逐层、历史往返、
最大文件滚底），记录"哪一步想切回 IDE"作为 M2 输入。

## 通用约束（每片适用）

`swift build` 全绿；现有 44 测试 + 16 fixture 不破坏；ci.sh 通过（含扩展禁令）；
Swift 6 严格并发零 warning；不改 Prototypes/；不 commit（由 orchestrator 验收后提交）。

## 执行者三条风险预警（来自 M0 实测）

1. `ProjectIndexer.index` 是阻塞调用，只能 Task.detached，放协作池会饿死并发。
2. rendering validator 会被 AppKit 全文件预验证调用——门控必须在 validator 体内，
   验收看"实际写属性 fragment 数"计数器（M0-B 用 2 秒和 191MB 换来的教训）。
3. 跨 actor 的 parse 产物必须 Sendable 值类型；tree-sitter Tree 不跨线程共享。
