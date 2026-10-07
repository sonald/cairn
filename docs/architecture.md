# 架构与源码入口

本文说明当前模块职责与长期不变量。它不要求为了符合图示再增加一层类型；改动应落在已有责任所在处，只有具体消费者需要时才引入新概念。

## 模块边界

| 模块 | 责任与入口 |
| --- | --- |
| CodeInsightCore | 内容/路径/快照身份、源码坐标、提取事实、解析候选和查询上下文。见 [ContentIndex](../Sources/CodeInsightCore/ContentIndex.swift)、[QueryContext](../Sources/CodeInsightCore/QueryContext.swift)。 |
| CodeInsightGit | Git 对象读取、工作区捕获与不可变快照。见 [GitSnapshot](../Sources/CodeInsightGit/GitSnapshot.swift)。 |
| TreeSitterKit、各语言 Extractor | 语法树访问和语言事实提取；抽取器输出纯模型，不操作 UI。 |
| CodeInsightEngine | 内容索引、SQLite 缓存、语言路由、候选解析、搜索与类型直达。见 [EngineSession](../Sources/CodeInsightEngine/EngineSession.swift)、[Resolver](../Sources/CodeInsightEngine/Resolver.swift)。 |
| CodeInsightExact | 子进程/LSP、provider、沙箱、信任与历史源码物化。见 [ExactProvider](../Sources/CodeInsightExact/ExactProvider.swift)、[Sandbox](../Sources/CodeInsightExact/Sandbox.swift)、[Materializer](../Sources/CodeInsightExact/Materializer.swift)。三种语言服务器共用 [LSPLanguageSession](../Sources/CodeInsightExact/LSPLanguageSession.swift)；语言差异（请求前等待与重试、诊断驱动的环境、能力推导、启动条件、`languageId`）是 `LSPLanguageSpec` 的策略点，可执行文件约束与启动配置留在各 provider。新增 LSP 行为改共享会话，不在 provider 里复制会话代码。 |
| CodeInsightReaderCore | Reader 源文档、UTF-8/UTF-16 转换、投影、折叠、阅读规划、字体偏好和派生数据；不导入 AppKit/SwiftUI。 |
| CodeInsightAppModel | 项目与阅读状态、异步 Exact 协调、Context/Relations、轨迹、书签和会话保存；不导入 AppKit/SwiftUI。 |
| CodeInsightReaderUI | AppKit/TextKit 2 渲染、原生选择/复制、重排、坐标命中与装饰。`ReaderTextView` 本体在 [CodeInsightReaderUI.swift](../Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift)；其五个区域（概览标尺、同名高亮、括号匹配、块尾注释、重排视口）共享私有状态，留在同一文件。折叠附件、标尺、点击视图与渲染属性协调器各自一个文件。 |
| CodeInsightApp | 应用/窗口生命周期、菜单、面板、设置和用户动作接线。`MainWindowController`、`ReaderViewController`、`ContextWindowViewController` 各占一个文件。`--self-test-*` 自测全部在 [SelfTest/](../Sources/CodeInsightApp/SelfTest/) 中按领域分文件，随正式二进制发布；`ci.sh static` 拒绝在 `CodeInsightApp.swift` 中定义 `run*SelfTest`。 |
| CodeInsightCLI | 使用相同引擎和 Exact 的命令行入口。 |

实际依赖以 [Package.swift](../Package.swift) 为准。UI 类型留在 UI target；核心和模型层不能靠 `NSView` 或显示字符串承载业务身份。

## 身份与源码事实

`ContentIndexKey` 包含内容身份、语言模式、grammar 版本和 extractor 版本。同一内容可跨路径/快照复用提取结果；解析出的路径目标必须仍属于查询快照，内容相同不等于语义环境相同。

`SnapshotManifest` 将路径与捕获内容关联；worktree 的 dirty/untracked 字节在捕获时固化。历史读取与搜索应使用快照内容，不能一边展示 commit、一边从实时磁盘解析。持久化缓存损坏或版本不匹配时重建，不把旧结构解码成新事实。

`AnalysisProfile` 记录语言、项目配置、环境指纹、features 与信任。`QueryContext` 使用 snapshot、profile、generation 拒绝过期结果；切项目、切快照、刷新、切分析配置后，旧请求不能发布到新上下文。信任变化还需停止/restart 相应 Exact 会话，不能仅凭内容缓存相同继续使用旧执行权限。

核心坐标使用 UTF-8 字节及半开区间，CLI 行/列为从 1 开始的 UTF-8 字节坐标。TextKit/LSP 所需坐标在边界转换。Unicode、CRLF、EOF、折叠隐藏区和占位符不能靠字符串长度近似；逆向转换不得把显示位置误当源位置。入口见 [Coordinates](../Sources/CodeInsightCore/Coordinates.swift)、[ByteUTF16Map](../Sources/CodeInsightReaderCore/ByteUTF16Map.swift)、[ReaderProjection](../Sources/CodeInsightReaderCore/ReaderProjection.swift)。

## 解析、验证与展示

提取事实区分 declaration facet、scope、binding、调用位置及执行区域。函数之外的类体/模块体也可能有调用；相同名字不证明是同一目标。当前解析策略与范围以 [Resolver](../Sources/CodeInsightEngine/Resolver.swift) 和语言抽取器为准，不复制早期编译器级 resolver 路线图。

解析候选的确定性、分派方式、来源、完整性独立。正向 provider 结果、不可用环境、未开始/进行中/空结果也是不同事实；取消和 stale 是控制流，不作为语义观察。

必须保留这些边界：

- provider 空结果只说明没有给出验证，不证明本地候选不存在。
- 两个目标只能在同一身份域中可比较时判相同/不同；不能仅凭原始 path/offset 不同判冲突。
- 可比较且不同的目标可修正主结果，但保留原候选证据。Safe/离线限制不否定 provider 已给出的正向目标。
- 捕获的导航说明不可随随后 Exact 升级改变；当前说明可以更新。阅读集与轨迹恢复不得重新查询后冒充原来的冻结证据。

[ContextWindowModel](../Sources/CodeInsightAppModel/ContextWindowModel.swift) 分开 `symbolCandidate` 与 `displayedCandidate`：语义动作取前者，正文/打开显示目标取后者。类型直达先解析绑定，再在绑定所在文件解析类型；跨文件字段/类属性的绑定下标不能在查询文件解释。Python `.memberBinding` 与本地 `.lexicalBinding` 的区别因此必须保留。

鼠标命中方法名才走方法解析；`receiverRange` 用于推断方法接收者，不能把接收者 token 变成方法 token。语法层类型剥离用于阅读预览，不应顺便改变原来的方法分派 `targetHint` 语义。

[ExactCoordinator](../Sources/CodeInsightAppModel/ExactCoordinator.swift) 处理语言会话、可用性、批次、内容校验与结果发布。Exact 定义、类型、hover 和关系能力各自协商；有 hover 不等于有 typeDefinition，provider ready 不等于结果完整。

## Reader 工作量与生命周期

源文档、折叠投影、阅读规划、标识符派生索引与 AppKit 几何是不同工作。优先复用已有事实，避免每次点击、滚动或改颜色重复做全文分析。

- [ReadingPlan](../Sources/CodeInsightReaderCore/ReadingPlan.swift) 提供作用域与阅读内容规划；渲染层消费计划，不能再次独立实现另一套“所在函数”规则。
- [ReaderDerivedDataStore](../Sources/CodeInsightReaderCore/ReaderDerivedDataStore.swift) 是应用拥有的有界共享缓存。视图拥有订阅，不拥有共享 worker；关闭一个视图只释放其订阅。任务取消、过期发布与视图消失都必须释放 token。
- 派生索引在后台构建；UI 只接收仍匹配 generation/内容的结果。共享计算不能由某个窗口的临时状态决定是否属于其他窗口。
- 颜色修改不应更换源码或重建投影；局部折叠用局部投影更新。声明形状、装饰与大纲等仍使用各自已有数据入口，不为每个主题增设通用层。
- [ReaderDocumentCost](../Sources/CodeInsightReaderCore/ReaderDocumentCost.swift) 在已有行表上计算源成本。高成本文档先选择有界视口路径，再考虑旧视口恢复；没有旧视口不代表可以同步全文布局。
- 概览竖条按显示行比例定位。2026-10-05 进程内测量（3,000 与 60,000 行、换行开关、折叠前后）：某行在 TextKit 估算文档高度中的位置与其行比例相差最多约 14%，同一行先后两次访问的位置也会变，因为未排版区域只有估算高度；行比例则稳定。显示行由 [ProjectedLines](../Sources/CodeInsightReaderCore/ProjectedLines.swift) 从行表和折叠段算出，不扫描文本。
- App 主动不扫描全文不等于 TextKit 保证不布局全文。长自然段落仍可能昂贵；源坐标、选区、复制和几何不能为性能被悄悄改变。

## 窗口、持久化与本地化

[AppModel](../Sources/CodeInsightAppModel/AppModel.swift) 管理项目阅读状态，[MainWindowController](../Sources/CodeInsightApp/MainWindowController.swift) 连接窗口与用户操作。实际项目路径归一后决定窗口归属，窗口关闭释放本项目资源。

[SessionCodec](../Sources/CodeInsightAppModel/SessionCodec.swift) 负责保存的数据格式，[SessionCheckpointStore](../Sources/CodeInsightAppModel/SessionCheckpointStore.swift) 负责路径、原子写入、旧文件迁移、损坏隔离与覆盖保护。项目键使用稳定 SHA-256，不用跨进程不稳定的 Swift `Hasher`。新格式或暂不可读的会话应保留；损坏隔离与 I/O 失败不能都当“空会话”处理。

面板布局：[PanelLayout](../Sources/CodeInsightAppModel/PanelLayout.swift) 是应用全局一份的纯值（UserDefaults `Cairn.panelLayout.v2`）：左右两区中面板的顺序、`hidden`、区域宽度、按面板的相对高度和分屏比例。每个面板恰好出现一次；解码丢弃未知面板、把缺失面板补回默认区末尾、逐字段回退坏数值，整体不是布局时用默认值。预设只改 `hidden`。[PanelViews](../Sources/CodeInsightApp/PanelViews.swift) 提供面板外壳（标题栏、`⋯` 菜单、拖动源）和区域视图（竖向 `NSSplitView`、放置目标）；`MainWindowController` 的外层 split 是左区 | 阅读组 | 右区，各面板控制器统一挂在窗口根控制器下。有效可见 = 布局可见 − 临时覆盖（无项目、非源码、阅读集、分屏放不下），上下文再按自动规则；覆盖由当前状态计算，不保存、恢复整份布局，覆盖期间不写回。只重建面板列表变化的区域，拖动开始只展开空区作落区。宽度、高度和分屏比例只在用户拖完分隔条时记录：外层、阅读组和区域内的 split 都是 `DividerTrackingSplitView`，它在 `mouseDown`（分隔条拖动在其中同步完成）返回后通知窗口。`NSSplitView` 在普通布局时也会带 divider index 发出调整通知，`NSApp.currentEvent` 在点击后也会一直停留在 mouse-up，二者都不能用来识别拖动。区域最小宽度是软约束（优先级 495，低于窗口保持尺寸），阅读区 320pt 是唯一硬最小值，窗口不因排版变大；右侧分隔条位置要减去自身厚度。

[KeyBindings](../Sources/CodeInsightAppModel/KeyBindings.swift) 是快捷键定义与用户覆盖的唯一来源。AppKit 接线消费有效绑定，设置页修改同一份模型，命令面板从菜单读取当前绑定；不要在工具栏另写一份默认键。

本地化资源归各 target 的 bundle。AppModel 的 `model.*` 文案由模型 bundle 读取；App 调用相应的 `modelText`/`modelTextFormat`，不能用自己的 `localized` 查另一个 bundle。身份、状态与样式取结构化字段，不从已翻译标签反推。资源数量和测试数量不作为架构合同。

## 项目搜索

工作任务只返回范围；消费者仍按原内容及文件顺序汇总，保持重复内容去重和 5,000 条上限的截断位置。第一批命中立即发送，后续达到 16 个文件、200 条命中或距上次发送 50ms 时发送；计时器也能在等待下一文件时发送已有结果。取消会传播到所有工作任务，5 秒截止后标记未处理路径。

正则共享不可变编译实例，依据 [Apple 的线程安全说明](https://developer.apple.com/documentation/foundation/nsregularexpression?language=objc)。匹配字符串在各工作任务中保持不变。使用进度回调以便无命中的长时间回溯也能停止；每 64 次无命中进度回调检查取消/超时，实际命中始终检查。一次采样确认逐次检查任务状态与时钟会导致性能退化，因此保留间隔检查及无命中回溯超时回归。

`ContentIndex.regions` 保存按源码顺序排列、不重叠的注释/字符串范围；`TreeSitterKit` 的共享节点分类同时供三语言抽取器与 Reader 使用。遍历复用原解析树和 tree cursor，识别整段区域后跳过其内部，不跳过宏、导入或导出分支；TS 模板表达式仍是代码。缓存以紧凑 `[lower, upper, kind]` 元组编码，codec 格式 4；Rust/Python/TypeScript extractorVersion 为 10/4/4。旧提取缓存重建，损坏、越界、重叠或无序范围不能进入搜索索引。

`ProjectSearchQuery` 是查询文本与条件控件共用的解析结构，错误携带 UTF-16 编辑范围；`ComposableSearch` 使用索引中的区域二分查询、作用域及声明名求值。单个词、短语及正则复用并行扫描，支持路径、区域与文件级排除；读取区域分类时按实际路径索引扫描，避免相同字节的 TS/TSX 错用同一语法。只有包含条件受数量上限约束，区域过滤发生在计数之前，OR 备选共享同一条件限额。排除在文件级遇首个有效命中即可停止；行距/函数级只保留行或函数内的存在信息，行距判断用有序行号二分。无法确认排除或组合判断超时的文件不发布结果。按行汇总时保留每个条件的真实字节范围，UI 直接画下划线，不重新解释正则。`SnapshotManifest` 保留文件树遍历得到的非源码和规则排除计数，未知值不伪造为零。

模型通过快照、profile、generation 拒绝旧请求；语法错误保留旧结果，快照变化时旧结果禁用导航。`same:fn` 使用完整函数声明范围；Python/TypeScript 的词法 body scope 不变，查询从 executable region 关联的声明取得函数头，TypeScript 无 facet 的嵌套函数区域也保留完整范围。结果名称仅带最近所属类型，不带整条模块链。`AppModel.projectSearch` 拥有查询与历史，会话 schema 5 保存最后查询及最近20条文本/开关状态。提示的学习状态在应用级保存，关闭提示只影响展示，不影响搜索语义。

查询重建保存 `(path, contentID, byteRange)`，跨批次寻找原命中；匹配不到时保留空选择，不把列表自动移到首项。搜索导航要求已知内容身份。刷新前分别保存阅读区的选中位置与滚动锚点，不能把 `firstVisibleByteOffset` 当成选中位置重放。新快照中同一文件、同一语言且 contentID 不变时，阅读区不重显示，只更新快照标识，视口、光标与已排版几何原样保留；回放落地后的 tab restore 若视口已在锚点行，不再按行重新对齐。回放开始只作废过期的导航任务（`AppModel` 私有 token），`navigationGeneration` 在回放落地时才递增，阅读区不会先按旧选择重新导航。新内容仍走锚点回退。刷新失败或后续其他导航会清理待恢复状态。

性能结论（详见[搜索性能证据](evidence/search-performance-2026-10.md)，含环境、二进制 SHA 与局限）：tokio 与 Codex 两个 Rust 语料上，基础词、短语、正则与组合查询的引擎首批均低于 100ms，Codex 罕见词首批从 154ms 降到约 10ms；这是引擎/CLI 计时，UI 另有 150ms 输入防抖，不等于键入到显示的时间。区域索引使冷索引进程耗时增加约 5%、缓存体积增加约 1%。当前缓存 codec 格式为 4，Rust/Python/TypeScript extractorVersion 为 10/4/4。
