# M2 Relations Alpha 实现计划（Planner: Fable 5, 2026-07-21）

本文件为 M2 执行的权威依据，切片 S1–S8 串行执行。通用约束沿用 M1：无头环境、
`swift build && swift test` 全绿、ci.sh 通过（AppKit 禁令：新增无 AppKit 逻辑一律进
CodeInsightAppModel / CodeInsightReaderCore / CodeInsightEngine）、Swift 6 严格并发
零 warning、不改 Prototypes/、每片不 commit。现有 86 测试 + 21 fixture + 双语料
gold set（nostrong=0）不得破坏。

**目标**（design §16 M2）：双向 Call Tree（四维标注、certainty 分组、证据）+
实现关系 + 全文搜索 + 符号大纲。验收基调："分组可信；懒展开流畅"。

## 决定 1：面板布局 —— 不引入预设机制，右栏可折叠

内层水平 NSSplitViewController 追加第三个 SplitViewItem（Relation Window，~300pt，
canCollapse=true，**默认折叠**，符合 F6.2）。菜单 Relations → Show/Hide（Cmd+Ctrl+R）；
触发 Show Callers/Calls 时自动展开。Reading/Relations/Compare/Focus 预设留 M3。

## 决定 2：RelationTreeModel（CodeInsightAppModel，无 AppKit）

```swift
public final class RelationTreeModel {   // @MainActor @Observable
    public enum Direction { case callers, calls, implementations }
    public final class Node { /* 引用类型（NSOutlineView item 恒等）；
        kind: root/group(Certainty 段)/edge/evidenceLine；title、subtitle(dispatch)、
        badge(↻)、target(path,byteOffset)、children:[Node]?（nil=未加载）*/ }
    public func setRoot(symbol:direction:)   // 换根，generation 递增
    public func expand(_ node: Node) async   // 懒展开，detached 查询
    public var onSelect: (Node) -> Void      // → Context 联动
}
```

- 分组头三段 Exact / Strong / Possible（probable 归 Possible 组，edge 副标签仍显示
  原始 certainty·dispatch，如 `Probable · direct`）。
- path-local 环检测：expand 沿 parent 链收集 (pathID, facetIndex)，重复标 ↻ 不可展开。
- 证据行 evidenceLine 为 edge 的末批子节点。
- expand 内 requestID + generation 双检，晚到丢弃（照抄 ContextWindowModel 模式）。
- 单测全打 model：分组、环、乱序丢弃、expand 幂等。

## 决定 3：正向 Calls 引擎 API

```swift
public struct OutgoingCall: Sendable {
    let callSite: SymbolOccurrenceID; let call: UnresolvedCall
    let calleeName: String; let candidates: [ResolutionCandidate]
}
public struct OutgoingCallsResult: Sendable {
    let calls: [OutgoingCall]; let completeness: Completeness
}
func outgoingCalls(from definition: SymbolOccurrenceID, context: QueryContext) throws
    -> OutgoingCallsResult
```

实现：facet.range **字节包含**收集 index.calls（闭包内调用计入外层 fn；落入嵌套命名
函数 facet 的排除——按最内层函数类 facet 归属过滤）；每条在 call.range.lowerBound 走
既有 Resolver.resolve 得四维候选。预算：每定义 512 条上限，超出 completeness=.truncated。
反向沿用既有 callers(of:)（名字级，M2 接受同名合并局限）。

## 决定 4：实现关系 —— 提取器有缺口，先补

已查证：RustDeclarations.implementedTypeName 对 `impl Foo for Bar` 丢弃 trait 名 Foo。
- Core：ContentIndex 增 `implRelations: [ImplRelation]`（implFacetIndex、traitNameID?、
  traitNameRange?、typeNameID；init 默认 []）。
- 提取器：impl_item 的 candidates.count==2 时 first 为 trait 名；**extractorVersion bump**。
- 引擎：ImplIndex（traitNameID→impls、typeNameID→impls）；API `implementations(ofTrait:)`
  （唯一定义 strong / 多义 possible 如实列出）、`overrides(ofTraitMethod:)`
  （trait 方法→各 impl 同名 method，dispatch=traitDispatch）。
- UI：Relation Window 第三方向（Callers/Calls/Implements 三段 segmented）。

## 决定 5：全文搜索预算与取消

Sources/CodeInsightEngine/SnapshotSearch.swift：

```swift
public protocol SnapshotContentSource: Sendable {   // M3 git 层未来实现方
    var manifest: SnapshotManifest { get }
    func bytes(for contentID: ContentID) -> [UInt8]?
}
// ContentSearchQuery{pattern,isRegex,caseSensitive}；SearchMatch{pathID,byteRange,
// line,column,lineText}；SearchBatch{matchesByPath,isFinal,completeness}
// search(...) -> AsyncThrowingStream<SearchBatch, Error>
```

按 ContentID 去重扫描 → 投影全部 FileOccurrence → 按文件分组分批产出。
**预算硬数字**：每文件命中 200；总命中 5000；regex 单内容 4MiB 上限（超限跳过计入
truncated）；总墙钟 5s 超时；取消 = Task cancel，每 content 检查 isCancelled。
字面量原始字节匹配（默认大小写不敏感可切）；regex 用 NSRegularExpression 基线；
无效 UTF-8：字面量照扫、regex 跳过如实计数。CLI 增 `search` 子命令。

## 决定 6：大纲面板 —— ReaderDocument 本地数据，不走引擎

索引期间即可用。OutlineFacet 扩展 kind（fn/method/struct/enum/trait/impl/mod/const/
static/typeAlias）、nameRange、depth；RustHighlighter 单遍 walk 顺带收齐（不二次 parse）。
OutlinePanelModel（无 AppKit）：facets 排序二分定位最内层，光标联动高亮。
布局：sidebar 垂直分割，文件树上、大纲下，常显。

## backlog 折入（S8）

折入：#2 ViewportGating 二分、#3 transition 接入生产路径、#4 Context 文档 LRU 缓存
（8 条，load 移出主 actor）、#5 contentID 装载时算一次、#6 历史双重条目、#7 索引期
文件树点击入历史、#10 搜索面板 path 字典缓存。
挂起：#1 K5 Pin 语义（等决策者手测；Relation 联动按"Pin 态不覆盖 Context"实现）、
#9 异步化（M3）、#11 AX 专项（M3）、#8 保留观察。

## 切片

### S1 — 引擎：正向调用 API
outgoingCalls + CLI `calls` 子命令 + 测试。无头验收：各类调用四维标注正确；闭包计入
外层；嵌套命名 fn 不串；512 截断标 truncated；tokio 实跑 JSON 稳定；全量回归绿。
人工：`tokio::spawn` 的调用清单与源码肉眼一致。

### S2 — 提取器 + 引擎：实现关系
ImplRelation 提取 + implementations/overrides API + CLI `impls` + 新 fixture
（impl-for、泛型 impl、无 trait impl、scoped trait、同名 trait 多定义）。
无头验收：trait→impls / method→overrides 与 certainty 断言；**既有 fixture 与
gold set 重跑 nostrong=0 保持，dump diff 逐条解释不许静默重录**；CLI impls Future。
人工：tokio Future impls / AsyncRead overrides 抽查合理。

### S3 — RelationTreeModel（无 AppKit）
决定 2 全实现 + 单测（分组切分含 probable 归组、a→b→a 环 fixture、懒加载幂等、
换根/换 session 晚到丢弃、证据行快照、fake session 交互序列）。

### S4 — Relation Window UI
第三 SplitViewItem + RelationWindowController（segmented 三方向 + NSOutlineView，
group 行 section 样式，edge 两行式：标题 + certainty·dispatch 副标签，↻ badge）。
入口：阅读区右键 Show Callers/Calls/Implementations（复用 token 定位）+ Relations
菜单（Cmd+Shift+H = Callers）作用于 Context 当前候选。联动：单击节点 → Context
explicitJump；双击/Enter → 主区 navigate 入历史。查询全部 Task.detached，展开中
spinner 行。首层 500 边上限超出 truncated 行。
无头验收：build/ci 绿；联动回调单测。人工：tokio spawn Callers 树分组可信、懒展开
流畅、深展开 ↻、联动、双击入历史；Future Implements；Cmd+Ctrl+R 折叠。

### S5 — SnapshotSearchService + SearchPanelModel
决定 5 全实现 + CLI search + SearchPanelModel（150ms debounce、新查询取消旧流、
按文件累积、truncated 暴露）。无头验收：ContentID 去重扫描计数断言；大小写折叠；
regex；四类预算路径；取消无泄漏；CLI 与 grep 抽样对齐；面板 model 单测。
人工：CLI 搜 tokio <2s 体感。

### S6 — 全文搜索面板 UI
SearchPanel（~720pt NSPanel，Cmd+Shift+F，Aa/.* toggle，按文件分组 NSOutlineView，
行号 + 命中行命中段加粗）。流式合帧 ≤30Hz；底部 "N matches in M files" + truncated
提示；Enter/双击跳转入历史；Esc 关。无头验收：build 绿 + model 集成序列。
人工：搜 block_on 流式出现、分组、跳转、快速改查询不闪烁、regex 可用。

### S7 — 符号大纲面板
决定 6 全实现。无头验收：大纲快照（嵌套 mod/impl/trait 深度与 kind）；二分定位
单测（边界/嵌套/头尾）；huge 档大纲不进首屏路径断言。人工：常规文件大纲即时、
滚动跟随高亮、点击跳转、10 万行异步补齐不卡首屏。

### S8 — backlog 折入 + 性能收尾
上表 7 项逐项修复带回归测试。性能：bench.sh 增 relation/search 场景；目标——
展开 p95 <100ms（tokio）；搜索首批 <300ms、全量 <2s（字面量）；大纲切文件 <16ms
（regular）；huge syntaxVisible 因 #2 二分显著低于 9.4s（新数字进 benchmarks.md）。
无头验收：三个 self-test 不回退；ViewportGating 二分单测；状态机接入全绿；历史
回归；全量绿。人工（= M2 总验收）：30 分钟 tokio 走查升级版（spawn Callers 下钻 +
Pin 联动、Future Implements、Cmd+Shift+F 排错、 大纲导航大文件），记录"分组是否
可信 / 哪步想切回 IDE"作 M3 输入。

依赖：S1→S3、S2→S3、S3→S4、S5→S6；S7 独立；S8 收尾。按编号串行派发。

## 风险预警

1. extractorVersion bump 涟漪（S2）：dump/fixture diff 逐条核对，gold set nostrong=0 硬门。
2. callers 高扇入（S4）：new/poll 级名字数百 call site——必须 detached + 首层 500 上限，
   严禁 MainActor 同步调 callers()。
3. NSOutlineView item 恒等：model 持有引用类型跨 reload 稳定；换代整树替换不原位变异。
4. 搜索流回压（S6）：批量合帧；SearchBatch Sendable 值；requestID 防乱序（照抄成熟模式）。
5. methodCall 边全落 Possible 组是**如实标注不是 bug**，不许抬 certainty；traitDispatch
   通路（S2）是正道。
6. AX 风险未修（#11 挂起）：新增两个 NSOutlineView，手测避免 AX 工具直接驱动滚动条。

## 待决策者批注

(a) K5 Pin 语义维持现状进 M2（Relation 联动按"Pin 态不覆盖 Context"实现），待手测定夺。
(b) S4 快捷键 Cmd+Shift+H（Callers）对齐 Xcode 习惯，如有偏好在 S4 前提出。
