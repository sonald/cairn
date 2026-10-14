# 架构与源码入口

本文说明当前模块职责与长期不变量。它不要求为了符合图示再增加一层类型；改动应落在已有责任所在处，只有具体消费者需要时才引入新概念。

## 模块边界

| 模块 | 责任与入口 |
| --- | --- |
| CodeInsightCore | 内容/路径/快照身份、源码坐标、提取事实、解析候选和查询上下文。见 [ContentIndex](../Sources/CodeInsightCore/ContentIndex.swift)、[QueryContext](../Sources/CodeInsightCore/QueryContext.swift)。 |
| CodeInsightGit | Git 对象读取、工作区捕获与不可变快照。见 [GitSnapshot](../Sources/CodeInsightGit/GitSnapshot.swift)。 |
| TreeSitterKit、各语言 Extractor | 语法树访问和语言事实提取；抽取器输出纯模型，不操作 UI。 |
| CodeInsightEngine | 内容索引、SQLite 缓存、语言路由、候选解析、搜索与类型直达。见 [EngineSession](../Sources/CodeInsightEngine/EngineSession.swift)、[Resolver](../Sources/CodeInsightEngine/Resolver.swift)。每门语言的分析单元根与 profile 由 [ProfileDetector](../Sources/CodeInsightEngine/ProfileDetector.swift) 从 marker 文件推出。 |
| CodeInsightExact | 子进程/LSP、provider、沙箱与信任。见 [ExactProvider](../Sources/CodeInsightExact/ExactProvider.swift)、[Sandbox](../Sources/CodeInsightExact/Sandbox.swift)；历史 commit 的检出目录是 CodeInsightGit 的 [CheckoutRoot](../Sources/CodeInsightGit/CheckoutRoot.swift)。三种语言服务器共用 [LSPLanguageSession](../Sources/CodeInsightExact/LSPLanguageSession.swift)；语言差异（请求前等待与重试、诊断驱动的环境、能力推导、启动条件、`languageId`）是 `LSPLanguageSpec` 的策略点，可执行文件约束与启动配置留在各 provider。新增 LSP 行为改共享会话，不在 provider 里复制会话代码。 |
| CodeInsightReaderCore | Reader 源文档、UTF-8/UTF-16 转换、投影、折叠、阅读规划、字体偏好和派生数据；不导入 AppKit/SwiftUI。 |
| CodeInsightAppModel | 项目与阅读状态、异步 Exact 协调、Context/Relations、轨迹、书签和会话保存；不导入 AppKit/SwiftUI。 |
| CodeInsightReaderUI | AppKit/TextKit 2 渲染、原生选择/复制、重排、坐标命中与装饰。`ReaderTextView` 本体在 [CodeInsightReaderUI.swift](../Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift)；其五个区域（概览标尺、同名高亮、括号匹配、块尾注释、重排视口）共享私有状态，留在同一文件。折叠附件、标尺、点击视图与渲染属性协调器各自一个文件。 |
| CodeInsightApp | 应用/窗口生命周期、菜单、面板、设置和用户动作接线。`MainWindowController`、`ReaderViewController`、`ContextWindowViewController` 各占一个文件。`--self-test-*` 自测全部在 [SelfTest/](../Sources/CodeInsightApp/SelfTest/) 中按领域分文件，随正式二进制发布；`ci.sh static` 拒绝在 `CodeInsightApp.swift` 中定义 `run*SelfTest`。 |
| CodeInsightCLI | 使用相同引擎和 Exact 的命令行入口。 |

实际依赖以 [Package.swift](../Package.swift) 为准。UI 类型留在 UI target；核心和模型层不能靠 `NSView` 或显示字符串承载业务身份。

## 身份与源码事实

`ContentIndexKey` 包含内容身份、语言模式、grammar 版本和 extractor 版本。同一内容可跨路径/快照复用提取结果；解析出的路径目标必须仍属于查询快照，内容相同不等于语义环境相同。

语言集合是快照的输出：`Snapshot.languages` 由捕获路径按后缀计算（符号链接与 gitlink 不计），只有工作区捕获会写入 `AppModel.projectLanguages`，commit 沿用当前集合。其余分类（session 路由、manifest 的 `detectedLanguage`、首帧覆盖计数）都按当前集合进行，所以 commit 中多出的语言是非源码预览，而不是没有 session 的源码。`ProjectIndexer.prepareSnapshots` 每个快照只读一遍文件、建一份 manifest，每门语言一个 `PreparedSnapshot`（提取单位），其中每个分析单元一个 session，共享同一 store 和同一次提取。单元划分见 [product.md](product.md)“项目、快照与窗口”：有 marker 目录包含该语言全部源码时取最浅的那个，否则每个源码归入最深的 marker 祖先或项目根。`SnapshotView` 按最深单元归属过滤活动文件，所以同一语言内每个文件恰好属于一个单元，各单元合起来就是全部源码；manifest 仍是整个快照，但项目文本搜索只扫 session 自己的活动文件（`SnapshotContentSource.searchIncludes`），所以多单元不会把同一命中列两次。Exact 的 profile 前缀等于所在单元根。`AnalysisProfileID` 不含单元路径，同一语言两个单元身份相同时整门语言回退为一个项目根单元。

`DeclarationFacet.visibility`（`public`/`restricted`/`private`，`nil` 为不适用）记录声明处的句法修饰，由三个抽取器写入、codec 格式 5 编码，不判断外部可达性。`EngineSession.projectSymbols` 按 `SnapshotView` 活动文件把以内容为键的索引展开成每文件一行，附 `ModuleMap.modulePath`/`crateRoot`；项目符号面板（`ProjectSymbolsPanelModel`，CLI `symbols`）只读这份列表，不重新解析、不发 Exact 请求，多 session 结果中任一个抛错即整次作废。

`SnapshotManifest` 将路径与捕获内容关联；worktree 的 dirty/untracked 字节在捕获时固化，读不出来的文件被跳过并以 `unreadablePathCount` 计数（未知为 nil，不伪造为零）。历史读取与搜索应使用快照内容，不能一边展示 commit、一边从实时磁盘解析。持久化缓存损坏或版本不匹配时重建，不把旧结构解码成新事实。

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

[ContextWindowModel](../Sources/CodeInsightAppModel/ContextWindowModel.swift) 分开 `symbolCandidate` 与 `displayedCandidate`：语义动作取前者，正文/打开显示目标取后者。工作区先发布缓存会话、再发布完整会话（同一快照、同一 profile 的新会话对象）；部分索引期间没有答案的点击被记住，完整会话到来时在跟随、符号模式下重查一次，快照、profile、generation 变化或离开就绪状态时清掉记录，不能让首帧期间的点击永久丢失。类型直达先解析绑定，再在绑定所在文件解析类型；跨文件字段/类属性的绑定下标不能在查询文件解释。Python `.memberBinding` 与本地 `.lexicalBinding` 的区别因此必须保留。`explicitJump`（`⌘` 单击）在本地无候选、首个候选是导入绑定（导入行或同文件的使用点）、或是被点的绑定本身时，用自己的 `ExactRequestBatch` 请求 definition（不取消 Context 的升级，做同样的 generation 与内容漂移检查），精确层未就绪时直接返回本地结果；无本地候选的点击照常发起 Context 升级，`applyExact` 在该请求的 `.idle` 阶段把结果作为唯一候选。

鼠标命中方法名才走方法解析；`receiverRange` 用于推断方法接收者，不能把接收者 token 变成方法 token。语法层类型剥离用于阅读预览，不应顺便改变原来的方法分派 `targetHint` 语义。

[ExactCoordinator](../Sources/CodeInsightAppModel/ExactCoordinator.swift) 处理语言会话、可用性、批次、内容校验与结果发布。Exact 定义、类型、hover 和关系能力各自协商；有 hover 不等于有 typeDefinition，provider ready 不等于结果完整。

## 精确分析会话与历史检出

阅读区、索引、搜索和比较只读 Git 对象快照；检出目录只给语言服务器看。行为承诺见 [product.md](product.md)“只读与分析信任”，测量依据见[热切换证据](evidence/warm-lsp-switch-2026-10/README.md)。

**检出目录。** [CheckoutRoot](../Sources/CodeInsightGit/CheckoutRoot.swift) 在应用目录里 `git_repository_init`，把 `objects/info/alternates` 指向用户仓库的 `git_repository_commondir`（兼容用户自己的 worktree），不用 `git worktree add`（会写用户的 `.git/worktrees/`）或 `git_clone`。仓库配置 `core.autocrlf=false`、`core.symlinks=false`，`.git/info/attributes` 写 `* -text -eol -filter -ident`，优先于 tree 中的 `.gitattributes`。`checkout` 以当前 HEAD 为基线 `FORCE` 检出并 detach，之后按 tree 删除符号链接与 gitlink，只留普通文件。借用链接（见下）在检出前先删掉不再需要、指向别处或与 tracked 路径冲突的，检出后再补建，所以检出不会经链接写进工作区。目录存活期间持有 `.git/cairn.lock` 的 flock，另一进程（如打包自测）的启动清理不会误删。[CheckoutStore](../Sources/CodeInsightGit/CheckoutRoot.swift) 是应用共享的父目录，每个窗口的协调器以本进程内的 UUID 拥有一份；协调器关闭时等会话退出后再删目录；启动时删除无人持锁的目录；整体清除在有活动目录时拒绝，进行中挂起所有协调器的新 prepare。

**两个会话槽。** [ExactCoordinator](../Sources/CodeInsightAppModel/ExactCoordinator.swift) 每窗口一份，按服务器读的根保留两个槽：工作区与检出目录。`prepare` 取走目标槽的会话，另一个槽保持待命，除非它服务的项目、语言、单元、特性选择或信任模式与这次不同（此时关闭）。待命槽每 30 秒检查一次，待命超过 `standbyIdleLimit`（600 s）或服务器物理内存占用（`proc_pid_rusage` 的 `ri_phys_footprint`，含被压缩的页；常驻集 RSS 会因压缩骤降而漏判）超过 `standbyMemoryLimit`（2 GiB）即关闭；阈值是常量，不是设置项。信任撤销、关窗、清除检出目录关闭两个槽，`slotEpoch` 让此时仍在进行的 prepare 关闭它拿走的会话而不是放回去。

**热切换还是重启（复用条件）。** 槽里的会话只有在根、单元前缀与单元名、槽类型、Python 解释器都相同，且 `ReuseKey.allowsWarmSwitch` 成立时才热切换：语言、`featureSelection`、`trustMode` 相同，`environmentFingerprint` 相同（Rust 例外：它是 `Cargo.lock` 的哈希，rust-analyzer 会像 `Cargo.toml` 一样在 Fetching 门后重载；Python 是 `uv.lock`，TypeScript 是 `bun.lockb`，变化即重启）。`configFingerprint` 不比较，由服务器自己重载。`toolVersion` 实际不参与：候选键用槽内 provider 自己的版本构造，所以升级后的服务器只在冷启动时生效。切换后若“是否借用工作区依赖”变了也重启，因为 provider 在启动时决定这项标注。成功后整份 `Active`（profile、缓存键、归因、快照、依赖根）替换，不只换 commit ID；结果缓存仍按 commit 的 `ReuseKey.versionIdentity` 区分。

**切换顺序与就绪确认。** [LSPLanguageSession](../Sources/CodeInsightExact/LSPLanguageSession.swift) 的 `switchSnapshot` 持操作锁完成：暂停新请求、取消在途请求、`didClose` 全部已开文档、由调用方检出并重算借用链接、更新快照引用、按 [ExactFileChange](../Sources/CodeInsightExact/ExactProvider.swift) 的差异发送 `workspace/didChangeWatchedFiles`（新增 1、修改 2、删除 3；变成符号链接或 gitlink 的路径算删除），再等服务器确认。确认规则是 `LSPSwitchReadiness`，来自 S0 实测：rust-analyzer 在 1 s 内等 `$/progress` `rustAnalyzer/Fetching` begin，等到了再等其后的 `serverStatus quiescent=true`（最多 120 s），1 s 内没有 Fetching 就视为就绪（沙箱内只改 `.rs` 不触发重载，首个答案已正确）；Fetching begin 会清掉 `LSPClient` 粘滞的 quiescent 状态；不能用 quiescent 的 false→true 翻转，清单切换时服务器不发 false。Pyright 没有进度通知：源码变化直接就绪，配置变化时在 5 s 内等 `window/logMessage` “Reloading configuration file”。tsserver 在 1 s 内看到 “Initializing JS/TS language features” begin 就等它的 end。等待期间到达的请求阻塞到切换结束并读新快照；`-32801 content modified` 重试保留。确认失败时会话不回到就绪，协调器关闭它并冷启动。

**通知必须完整。** 沙箱拒绝 `mach-lookup com.apple.FSEvents`，rust-analyzer 在沙箱内没有自己的文件监视，Cairn 的 `didChangeWatchedFiles` 是唯一的变化来源，这也让切换不会触发整工作区重扫。差异在两个整项目快照之间计算；协调器自己用默认 `ProjectPathRules` 建快照，不应用用户排除规则，所以被用户排除的 tracked 文件照样在 commit 快照里、照样通知。工作区快照仍跳过内置目录（`target`、`build`、`dist` 等），重新激活工作区槽时这些目录里 tracked 文件的改动不会通知，是已知缺口。

**依赖借用与路径分类。** [DependencyBorrowing](../Sources/CodeInsightExact/DependencyBorrowing.swift) 给出检出目录内的链接集合（TypeScript 是项目根与每个 tracked `package.json` 旁、工作区里存在的 `node_modules`；Python 是该 commit 自己配置的相对 `venvPath`；Rust 不借用）和 Pyright 的解释器（工作区单元根的 `.venv`/`venv`，工作区与 commit 两种模式都用）。服务器可能返回检出目录下的链接路径，也可能返回工作区的真实路径：位置落在检出目录或工作区下、且快照里有这个文件时才映射成项目相对路径，否则保留绝对路径作为依赖文件，从磁盘读取，不进 `snapshot.readBytes`。`ContextWindowModel.projectPath` 对项目根下的绝对路径用同一规则：会话索引里有该文件才相对化。`ExactCoordinator.isDependencyFile` 认出工作区下的依赖根；`AppModel.isDependencyFile` 再加上会话恢复时以绝对路径打开的文件，因为恢复可能早于 Exact 准备完成。依赖目标的语言用 `dependencyFileLanguageMode`，它在项目语言分类之外接受 `.d.ts`（TypeScript）与 `.pyi`（Python）；`LanguageMode.classify` 本身不变，它决定项目语言探测与索引。离线标注由 provider 在启动时决定：借用了工作区依赖就是“依赖来自当前工作区”，否则 Pyright 没有解释器、TypeScript 单元根没有 `node_modules` 时是“离线依赖不可用”。

**沙箱。** [Sandbox](../Sources/CodeInsightExact/Sandbox.swift) 禁网，只放行分析缓存目录写入（Trusted 的 Rust 另加项目 `target`）；检出目录、借用的真实目录、用户源码与 `.git` 不可写。长驻会话不设 `ulimit -t`：S0 实测 codex 加载已用约 52 s CPU，累计上限只够切一两次。保留 `ulimit -v`（512 GiB；VSZ 恒在 467 GiB 左右）、单次请求超时与崩溃重启。

**窗口隔离。** 一个项目只有一个窗口（再次打开激活现有窗口），每个窗口有自己的协调器、两个会话槽和检出目录；信任登记与 `CheckoutStore` 是应用共享资源。

## Reader 工作量与生命周期

源文档、折叠投影、阅读规划、标识符派生索引与 AppKit 几何是不同工作。优先复用已有事实，避免每次点击、滚动或改颜色重复做全文分析。

- [ReadingPlan](../Sources/CodeInsightReaderCore/ReadingPlan.swift) 提供作用域与阅读内容规划；渲染层消费计划，不能再次独立实现另一套“所在函数”规则。
- [ReaderDerivedDataStore](../Sources/CodeInsightReaderCore/ReaderDerivedDataStore.swift) 是应用拥有的有界共享缓存。视图拥有订阅，不拥有共享 worker；关闭一个视图只释放其订阅。任务取消、过期发布与视图消失都必须释放 token。
- 派生索引在后台构建；UI 只接收仍匹配 generation/内容的结果。共享计算不能由某个窗口的临时状态决定是否属于其他窗口。
- 颜色修改不应更换源码或重建投影；局部折叠用局部投影更新。声明形状、装饰与大纲等仍使用各自已有数据入口，不为每个主题增设通用层。
- 主题颜色全部来自 [ThemePalette](../Sources/CodeInsightReaderCore/ThemePalette.swift)：内置三套是手调字面量，base16 方案由 [Base16Scheme](../Sources/CodeInsightReaderCore/Base16Scheme.swift) 解析并在同一文件映射到全部角色。[ThemeCatalog](../Sources/CodeInsightReaderCore/ThemeCatalog.swift) 是进程内注册表：内置与随附 `Themes/` 在首次使用时载入，用户主题文件夹由 App 在启动和打开设置时重新扫描。`ReaderTheme` 按主题 id（Auto 按配对）解析出浅/深两份调色板，读取接口不变，`Equatable` 含调色板，所以切换同一明暗的两个主题也会触发重绘；窗口外观只取解析后的明暗（`cairnAppearance(for:)`）。
- [ReaderDocumentCost](../Sources/CodeInsightReaderCore/ReaderDocumentCost.swift) 在已有行表上计算源成本。高成本文档先选择有界视口路径，再考虑旧视口恢复；没有旧视口不代表可以同步全文布局。
- 概览竖条按显示行比例定位。2026-10-05 进程内测量（3,000 与 60,000 行、换行开关、折叠前后）：某行在 TextKit 估算文档高度中的位置与其行比例相差最多约 14%，同一行先后两次访问的位置也会变，因为未排版区域只有估算高度；行比例则稳定。显示行由 [ProjectedLines](../Sources/CodeInsightReaderCore/ProjectedLines.swift) 从行表和折叠段算出，不扫描文本。
- App 主动不扫描全文不等于 TextKit 保证不布局全文。长自然段落仍可能昂贵；源坐标、选区、复制和几何不能为性能被悄悄改变。

## 窗口、持久化与本地化

[AppModel](../Sources/CodeInsightAppModel/AppModel.swift) 管理项目阅读状态，[MainWindowController](../Sources/CodeInsightApp/MainWindowController.swift) 连接窗口与用户操作。实际项目路径归一后决定窗口归属，窗口关闭释放本项目资源。

[SessionCodec](../Sources/CodeInsightAppModel/SessionCodec.swift) 负责保存的数据格式，[SessionCheckpointStore](../Sources/CodeInsightAppModel/SessionCheckpointStore.swift) 负责路径、原子写入、旧文件迁移、损坏隔离与覆盖保护。项目键使用稳定 SHA-256，不用跨进程不稳定的 Swift `Hasher`。新格式或暂不可读的会话应保留；损坏隔离与 I/O 失败不能都当“空会话”处理。

面板布局：[PanelLayout](../Sources/CodeInsightAppModel/PanelLayout.swift) 是应用全局一份的纯值（UserDefaults `Cairn.panelLayout.v2`）：左、右、底三区中面板的顺序、`hidden`、区域尺寸（侧区宽度、底部区高度，存储键仍为 `zoneWidths`）、按面板沿所在区堆叠方向的相对尺寸（`heights`）和分屏比例。每个面板恰好出现一次；解码丢弃未知面板、把缺失面板按默认显示状态补回默认区末尾（新面板如 `symbols` 默认隐藏，升级不会突然出现）、逐字段回退坏数值，整体不是布局时用默认值。预设只改 `hidden`。[PanelViews](../Sources/CodeInsightApp/PanelViews.swift) 提供面板外壳（标题栏、`⋯` 菜单、拖动源）和区域视图（`NSSplitView`，侧区竖向、底部区横向，同时是放置目标；沿堆叠方向的最小值与跨方向的软最小值在底部区互换）；`MainWindowController` 的外层 split 是左区 | 中栏 | 右区，中栏是竖向 split：阅读组在上、底部区在下，各面板控制器统一挂在窗口根控制器下。有效可见 = 布局可见 − 临时覆盖（无项目、非源码、阅读集、分屏放不下），上下文再按自动规则；覆盖由当前状态计算，不保存、恢复整份布局，覆盖期间不写回。只重建面板列表变化的区域，拖动开始只展开空区作落区。宽度、高度和分屏比例只在用户拖完分隔条时记录（唯一例外：文档面板第一次显式显示时记录一次所在区的高度，不记录宽度）：外层、中栏、阅读组和区域内的 split 都是 `DividerTrackingSplitView`，它在 `mouseDown`（分隔条拖动在其中同步完成）返回后通知窗口。`NSSplitView` 在普通布局时也会带 divider index 发出调整通知，`NSApp.currentEvent` 在点击后也会一直停留在 mouse-up，二者都不能用来识别拖动。区域最小尺寸是软约束（优先级 495，低于窗口保持尺寸），阅读区 320pt 宽、200pt 高是仅有的硬最小值，窗口不因排版变大；右侧和底部分隔条位置要减去自身厚度。`applyZoneWidths` 在存储宽度放不下（窗口宽 − 320 − 分隔条）时先按比例缩两侧区再设分隔条位置，与 `NSSplitView` 实时缩放的结果一致；否则逐个 `setPosition` 会先把左区压到最小值。

文档面板：[DocumentationSource](../Sources/CodeInsightAppModel/DocumentationSource.swift) 是文档来源协议（可用性、搜索、精确命中判断），目前唯一实现 `DashDocumentationSource` 用不落盘缓存的 ephemeral URLSession 访问 Dash 本机 API：每次查询读 `status.json` 取端口，`/health`（1 秒超时），`/docsets/list`（identifier 每台机器随机，只在本次运行内按端口缓存，搜索为空时刷新一次再搜），`/search`，结果按当前文件语言对应的 Dash platform 稳定排序并标出 `matchesLanguage`。查询词由 App 层的 `DashIntegration.query` 构造（Rust 取定义路径末段，其他语言取源码中的一层接收者），“在 Dash 中查看”与面板共用。安装与运行状态由 App 层注入，AppModel 不导入 AppKit；整个应用共用一个来源实例。精确命中与自动加载规则是纯函数。[DocumentationPanelModel](../Sources/CodeInsightAppModel/DocumentationPanelModel.swift) 每个窗口一份，状态为空闲、不可用、搜索中、待选、显示中，新查询取消旧任务并用代次号丢弃迟到结果；不可用原因是枚举，文案在 App 层。[DocumentationPanelController](../Sources/CodeInsightApp/DocumentationPanelController.swift) 只在有页面要显示时创建 WKWebView（非持久数据存储，页面脚本关闭）。内容规则 `cairn-docs-dash-v1` 先查已编译的再编译，首次加载前必须就绪；`WKContentRuleListStore` 会跨启动保留编译结果，规则一改就要升版本号。深色主题用用户脚本注入反色 CSS（根滚动条不受 html 的 filter 影响，单独给深色），用户脚本在页面脚本关闭时仍运行；深色时 WKWebView 不画自身背景（KVC `drawsBackground`），未绘制的瓦片露出面板背景。头部的后退与副标题来自 WKWebView 的 KVO（`canGoBack`、`title`、`url`），因为同页只换锚点时 WebKit 不回调 `didFinish`。

[KeyBindings](../Sources/CodeInsightAppModel/KeyBindings.swift) 是快捷键定义与用户覆盖的唯一来源。AppKit 接线消费有效绑定，设置页修改同一份模型，命令面板从菜单读取当前绑定；不要在工具栏另写一份默认键。

本地化资源归各 target 的 bundle。AppModel 的 `model.*` 文案由模型 bundle 读取；App 调用相应的 `modelText`/`modelTextFormat`，不能用自己的 `localized` 查另一个 bundle。身份、状态与样式取结构化字段，不从已翻译标签反推。资源数量和测试数量不作为架构合同。

## 项目搜索

工作任务只返回范围；消费者仍按原内容及文件顺序汇总，保持重复内容去重和 5,000 条上限的截断位置。第一批命中立即发送，后续达到 16 个文件、200 条命中或距上次发送 50ms 时发送；计时器也能在等待下一文件时发送已有结果。取消会传播到所有工作任务，5 秒截止后标记未处理路径。

正则共享不可变编译实例，依据 [Apple 的线程安全说明](https://developer.apple.com/documentation/foundation/nsregularexpression?language=objc)。匹配字符串在各工作任务中保持不变。使用进度回调以便无命中的长时间回溯也能停止；每 64 次无命中进度回调检查取消/超时，实际命中始终检查。一次采样确认逐次检查任务状态与时钟会导致性能退化，因此保留间隔检查及无命中回溯超时回归。

`ContentIndex.regions` 保存按源码顺序排列、不重叠的注释/字符串范围；`TreeSitterKit` 的共享节点分类同时供三语言抽取器与 Reader 使用。遍历复用原解析树和 tree cursor，识别整段区域后跳过其内部，不跳过宏、导入或导出分支；TS 模板表达式仍是代码。缓存以紧凑 `[lower, upper, kind]` 元组编码，codec 格式 5；Rust/Python/TypeScript extractorVersion 为 11/5/5。旧提取缓存重建，损坏、越界、重叠或无序范围不能进入搜索索引。

`ProjectSearchQuery` 是查询文本与条件控件共用的解析结构，错误携带 UTF-16 编辑范围；`ComposableSearch` 使用索引中的区域二分查询、作用域及声明名求值。单个词、短语及正则复用并行扫描，支持路径、区域与文件级排除；读取区域分类时按实际路径索引扫描，避免相同字节的 TS/TSX 错用同一语法。只有包含条件受数量上限约束，区域过滤发生在计数之前，OR 备选共享同一条件限额。排除在文件级遇首个有效命中即可停止；行距/函数级只保留行或函数内的存在信息，行距判断用有序行号二分。无法确认排除或组合判断超时的文件不发布结果。按行汇总时保留每个条件的真实字节范围，UI 直接画下划线，不重新解释正则。`SnapshotManifest` 保留文件树遍历得到的非源码、规则排除和无法读取计数，未知值不伪造为零。

模型通过快照、profile、generation 拒绝旧请求；语法错误保留旧结果，快照变化时旧结果禁用导航。`same:fn` 使用完整函数声明范围；Python/TypeScript 的词法 body scope 不变，查询从 executable region 关联的声明取得函数头，TypeScript 无 facet 的嵌套函数区域也保留完整范围。结果名称仅带最近所属类型，不带整条模块链。`AppModel.projectSearch` 拥有查询与历史，会话 schema 5 保存最后查询及最近20条文本/开关状态。提示的学习状态在应用级保存，关闭提示只影响展示，不影响搜索语义。

查询重建保存 `(path, contentID, byteRange)`，跨批次寻找原命中；匹配不到时保留空选择，不把列表自动移到首项。搜索导航要求已知内容身份。刷新前分别保存阅读区的选中位置与滚动锚点，不能把 `firstVisibleByteOffset` 当成选中位置重放。新快照中同一文件、同一语言且 contentID 不变时，阅读区不重显示，只更新快照标识，视口、光标与已排版几何原样保留；回放落地后的 tab restore 若视口已在锚点行，不再按行重新对齐。回放开始只作废过期的导航任务（`AppModel` 私有 token），`navigationGeneration` 在回放落地时才递增，阅读区不会先按旧选择重新导航。新内容仍走锚点回退。刷新失败或后续其他导航会清理待恢复状态。

性能结论（详见[搜索性能证据](evidence/search-performance-2026-10.md)，含环境、二进制 SHA 与局限）：tokio 与 Codex 两个 Rust 语料上，基础词、短语、正则与组合查询的引擎首批均低于 100ms，Codex 罕见词首批从 154ms 降到约 10ms；这是引擎/CLI 计时，UI 另有 150ms 输入防抖，不等于键入到显示的时间。区域索引使冷索引进程耗时增加约 5%、缓存体积增加约 1%。上述测量时 codec 格式为 4、extractorVersion 为 10/4/4；格式 5 只增加每个声明一个可见性字节。
