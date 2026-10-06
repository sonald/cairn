# 架构与源码入口

本文说明当前模块职责与长期不变量。它不要求为了符合图示再增加一层类型；改动应落在已有责任所在处，只有具体消费者需要时才引入新概念。

## 模块边界

| 模块 | 责任与入口 |
| --- | --- |
| CodeInsightCore | 内容/路径/快照身份、源码坐标、提取事实、解析候选和查询上下文。见 [ContentIndex](../Sources/CodeInsightCore/ContentIndex.swift)、[QueryContext](../Sources/CodeInsightCore/QueryContext.swift)。 |
| CodeInsightGit | Git 对象读取、工作区捕获与不可变快照。见 [GitSnapshot](../Sources/CodeInsightGit/GitSnapshot.swift)。 |
| TreeSitterKit、各语言 Extractor | 语法树访问和语言事实提取；抽取器输出纯模型，不操作 UI。 |
| CodeInsightEngine | 内容索引、SQLite 缓存、语言路由、候选解析、搜索与类型直达。见 [EngineSession](../Sources/CodeInsightEngine/EngineSession.swift)、[Resolver](../Sources/CodeInsightEngine/Resolver.swift)。 |
| CodeInsightExact | 子进程/LSP、provider、沙箱、信任与历史源码物化。见 [ExactProvider](../Sources/CodeInsightExact/ExactProvider.swift)、[Sandbox](../Sources/CodeInsightExact/Sandbox.swift)、[Materializer](../Sources/CodeInsightExact/Materializer.swift)。 |
| CodeInsightReaderCore | Reader 源文档、UTF-8/UTF-16 转换、投影、折叠、阅读规划、字体偏好和派生数据；不导入 AppKit/SwiftUI。 |
| CodeInsightAppModel | 项目与阅读状态、异步 Exact 协调、Context/Relations、轨迹、书签和会话保存；不导入 AppKit/SwiftUI。 |
| CodeInsightReaderUI | AppKit/TextKit 2 渲染、原生选择/复制、重排、坐标命中与装饰。 |
| CodeInsightApp | 应用/窗口生命周期、菜单、面板、设置和用户动作接线。 |
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

[KeyBindings](../Sources/CodeInsightAppModel/KeyBindings.swift) 是快捷键定义与用户覆盖的唯一来源。AppKit 接线消费有效绑定，设置页修改同一份模型，命令面板从菜单读取当前绑定；不要在工具栏另写一份默认键。

本地化资源归各 target 的 bundle。AppModel 的 `model.*` 文案由模型 bundle 读取；App 调用相应的 `modelText`/`modelTextFormat`，不能用自己的 `localized` 查另一个 bundle。身份、状态与样式取结构化字段，不从已翻译标签反推。资源数量和测试数量不作为架构合同。

## 项目搜索性能基线

2026-10-05，P0 与 P0.5 扫描提速已验收。2026-10-06 的区域索引、组合查询和原生交互实现及验证见下文。P0 中 Codex 罕见词首批为 154.12ms，采样显示主要开销是逐文件 URL 分类、逐字节比较和无命中文件的行号表。P0.5 不新增索引或缓存，改为普通路径直接取扩展名、仅为命中文件建行号表、分开大小写扫描，并按 CPU 数并行处理连续内容段。末尾 `.` / `..` 的特殊路径保留原 URL 规范化，分类属性测试与旧实现一致。

工作任务只返回范围；消费者仍按原内容及文件顺序汇总，保持重复内容去重和 5,000 条上限的截断位置。第一批命中立即发送，后续达到 16 个文件、200 条命中或距上次发送 50ms 时发送；计时器也能在等待下一文件时发送已有结果。取消会传播到所有工作任务，5 秒截止后标记未处理路径；该次 P0.5 没有修改索引格式或抽取器版本。后续 P1 的版本升级见下文。

正则共享不可变编译实例，依据 [Apple 的线程安全说明](https://developer.apple.com/documentation/foundation/nsregularexpression?language=objc)。匹配字符串在各工作任务中保持不变。使用进度回调以便无命中的长时间回溯也能停止；每 64 次无命中进度回调检查取消/超时，实际命中始终检查。一次采样确认逐次检查任务状态与时钟会导致性能退化，因此保留间隔检查及无命中回溯超时回归。

环境：MacBook Pro Mac15,6，Apple M3 Pro（11 核，5P+6E），36 GiB 内存；macOS 27.0（26A428），Xcode 27.0（27A266a），Swift 6.4。Release CLI、Homebrew libgit2。P0 测量时源码为 `ec55b9b016dc795c6c94d125a67c1d98f9ca1bf9` 加当时未提交的 P0 计时及错误根修复（现已提交），Rust extractorVersion=9；测量二进制 SHA-256 为 `7ba463cf937736ec709ca51e5c845286704b501b39c0ee255e4c83965d5793cd`。

原始基线先在 Codex 的 `codex-rs/core/tests/suite/unified_exec.rs` 崩溃：tree-sitter 返回 `ERROR` 根，其中的常量初始化器没有文件作用域，触发 `RustScopeBuilder.pushRegionIfNeeded` 的断言。两行复现见 `damagedRootPreservesConstantInitializerScope` 回归测试。修复只为异常根补建模块作用域；抽取器版本 8→9 会使已有 Rust 缓存重建。P0 数据均来自修复后的同一构建，不把崩溃运行算作成功样本。P0.5 基于 `a3dc2b4` 加本次未提交修改，使用相同机器、工具链和语料；二进制 SHA-256 为 `714f7da2f07e03f67275496abaa18e4b1bcddef0a391d069a18ef89ee0c248c5`。

语料均为干净工作区，仅索引 Rust，使用默认目录排除规则：

| 项目 | 本地路径 | 版本 | 文件 / 唯一内容 | 含语法错误的文件 |
| --- | --- | --- | --- | --- |
| tokio | `/Users/siancao/.cache/cairn-corpora/tokio-tokio-1.47.1` | `be8ee45b3fc2d107174e586141b1cb12c93e2ddf` | 717 / 717 | 0 |
| Codex | `/Users/siancao/work/readings/codex` | `315195492c80fdade38e917c18f9584efd599304` | 2,612 / 2,608 | 26 |

P0 每个项目使用两个新的隔离缓存目录，每个目录先冷索引一次，再用新进程热索引一次。冷仅指提取缓存为空，未清空操作系统文件缓存。热运行均确认 `extractedContents=0`，`reusedContents=uniqueContents`。进程耗时包含持久化写入完成，内部索引时间不包含该等待；RSS 为 `/usr/bin/time -l` 记录的进程峰值。

| 项目 / 缓存 | 内部索引 ms（两次） | 进程耗时 s（两次） | 峰值 RSS MiB（两次） | 退出后缓存总字节（两次） |
| --- | --- | --- | --- | --- |
| tokio / 冷 | 575、516 | 1.26、1.18 | 84.77、84.50 | 5,726,208、5,730,304 |
| tokio / 热 | 365、349 | 0.41、0.39 | 81.30、79.52 | 5,726,208、5,730,304 |
| Codex / 冷 | 4,082、3,813 | 9.47、9.31 | 510.61、512.12 | 36,569,088、36,995,072 |
| Codex / 热 | 2,671、2,683 | 2.85、2.86 | 414.92、422.33 | 36,503,552、36,929,536 |

缓存统计包含 SQLite 主文件及仍存在的 WAL/SHM；并发提取与 SQLite 布局会带来少量体积差异。P1 的首次建索引与缓存增幅应与相同语料、相同冷缓存持久化口径比较，不能把内部索引时间与进程耗时互换。

每个查询使用 `search --persist --repeat 3 --json`：索引一次后连搜三次，未剔除第一轮，大小写不敏感。首批指调用 `session.search` 到收到首个非空批次；结束指流结束并完成 CLI 批次合并，不包含索引、最终排序、JSON 编码和 stdout。以下均为三次中位数。

| 项目 | 查询 | P0 首批 / 结束 ms | P0.5 首批 / 结束 ms | 命中 / 文件 | 完整性 |
| --- | --- | --- | --- | --- | --- |
| tokio | `spawn` | 11.58 / 25.69 | **1.25 / 4.03** | 3,033 / 262 | complete |
| tokio | `IdleNotifiedSet` | 24.92 / 24.92 | **2.01 / 2.12** | 26 / 3 | complete |
| tokio | `fn\s+[a-z_]*spawn\w*`（`--regex`） | 15.90 / 34.96 | **6.44 / 16.84** | 190 / 58 | complete |
| Codex | `spawn` | 43.44 / 152.96 | **5.61 / 18.03** | 4,511 / 527 | truncated |
| Codex | `reconstruct_history_matches_live_compactions` | 154.12 / 154.14 | **9.17 / 9.74** | 1 / 1 | complete |
| Codex | `fn\s+[a-z_]*spawn\w*`（`--regex`） | 55.49 / 230.75 | **49.87 / 113.35** | 373 / 149 | complete |

P0.5 的六个最终 JSON（包含坐标、片段、完整性和截断路径）与 P0 逐项相同。Codex 罕见词首批样本为 10.007、9.121、9.171ms，均低于 100ms；六项查询的首批和结束中位数均优于 P0。P0.5 复用 P0 的隔离缓存，每次均确认没有重新抽取；未重新跑冷索引，P1 的索引预算仍以此前基线比较。

同样的 Codex 罕见词 `--repeat 3` 命令，本轮对照 P0 二进制峰值 RSS 为 443,498,496 字节（422.95 MiB），P0.5 为 443,269,120 字节（422.73 MiB）；未见明显增加。P0.5 六次进程峰值为 tokio 79.45–82.03 MiB、Codex 418.25–423.77 MiB。这是含索引准备的进程峰值，不是搜索独占内存；并行待汇总数据只持有已有源码数组和每内容至多 201 个范围，大一个数量级的语料仍需重新评估。

P0 的 Codex 罕见词首批原始样本为 154.120、154.396、153.577ms，均未达到 S8.1。`spawn` 在 `codex-rs/core/src/agent/control_tests.rs` 和 `codex-rs/core/src/tools/handlers/multi_agents_tests.rs` 达到每文件 200 条上限，结束时间不能称为完整结果时间。

局限：P0.5 只验证引擎/CLI，界面仍有 150ms 防抖。本次是引擎/CLI 证据，没有执行原生显示验收，不是端到端 100ms 的 PASS。Codex 的 TypeScript/Python 和非源码文件不在本次范围。少量样本用于检查点决策，不是 p95 或发布承诺；P1 的索引预算与 S8.2 实测结果见下文；原生显示耗时仍不等于 CLI 计时。

复现命令见[开发说明](development.md#性能复现)。P0 原始输出在指定工作树 `.build/query-p0/`，崩溃修复前输出在 `.build/query-p0-before-root-fix/`；P0.5 的最终测量、回归摘要和采样在 `.build/query-p05/`，不提交整套日志。P0.5 验证：Release 构建 PASS；Swift Testing 完整摘要为搜索集成 26 通过、Core 属性/扫描 5 通过，总共 31 通过、0 失败、0 跳过；CLI 集成检查 3 通过、0 失败、0 跳过。测试覆盖固定种子的新旧扫描/分类参照、1 与 4 个 worker 的逐条输出及截断、取消全部 worker、首批与定时发送、无命中正则回溯超时；这些均不是原生 UI 验收。


### 区域索引与组合查询（2026-10-06）

`ContentIndex.regions` 保存按源码顺序排列、不重叠的注释/字符串范围；`TreeSitterKit` 的共享节点分类同时供三语言抽取器与 Reader 使用。遍历复用原解析树和 tree cursor，识别整段区域后跳过其内部，不跳过宏、导入或导出分支；TS 模板表达式仍是代码。缓存以紧凑 `[lower, upper, kind]` 元组编码，codec 格式 4；Rust/Python/TypeScript extractorVersion 为 10/4/4。旧提取缓存重建，损坏、越界、重叠或无序范围不能进入搜索索引。

`ProjectSearchQuery` 是查询文本与条件控件共用的解析结构，错误携带 UTF-16 编辑范围；`ComposableSearch` 使用索引中的区域二分查询、作用域及声明名求值。单个词、短语及正则复用并行扫描，支持路径、区域与文件级排除；读取区域分类时按实际路径索引扫描，避免相同字节的 TS/TSX 错用同一语法。只有包含条件受数量上限约束，区域过滤发生在计数之前，OR 备选共享同一条件限额。排除在文件级遇首个有效命中即可停止；行距/函数级只保留行或函数内的存在信息，行距判断用有序行号二分。无法确认排除或组合判断超时的文件不发布结果。按行汇总时保留每个条件的真实字节范围，UI 直接画下划线，不重新解释正则。`SnapshotManifest` 保留文件树遍历得到的非源码和规则排除计数，未知值不伪造为零。

模型通过快照、profile、generation 拒绝旧请求；语法错误保留旧结果，快照变化时旧结果禁用导航。`same:fn` 使用完整函数声明范围；Python/TypeScript 的词法 body scope 不变，查询从 executable region 关联的声明取得函数头，TypeScript 无 facet 的嵌套函数区域也保留完整范围。结果名称仅带最近所属类型，不带整条模块链。`AppModel.projectSearch` 拥有查询与历史，会话 schema 5 保存最后查询及最近20条文本/开关状态；布局的可选 `bottomTab` 向后兼容。提示的学习状态在应用级保存，关闭提示只影响展示，不影响搜索语义。

以下 P1 对照使用相同 M3 Pro / 36 GiB、Xcode 27.0 / Swift 6.4、Codex `315195492c80fdade38e917c18f9584efd599304`、Release 与 `index --persist --json`。保留的 P0.5 二进制与区域版本各用两个独立空目录，进程退出后统计缓存全部文件；没有更换语料或重复挑最快值。

| 指标 | P0.5 对照两次 / 均值 | P1 两次 / 均值 | 增幅 / 上限 |
| --- | --- | --- | --- |
| 冷索引进程耗时 | 9.91、8.94s / 9.425s | 10.30、9.51s / 9.905s | **+5.1% / +10%：PASS** |
| 内部索引耗时 | 3,922、3,679ms / 3,800.5ms | 4,307、3,981ms / 4,144ms | +9.0%；不与进程口径混用 |
| 缓存字节 | 38,584,320、36,622,336 / 37,603,328 | 38,129,664、38,039,552 / 38,084,608 | **+1.3% / +15%：PASS** |

基础查询测量 CLI 基于 `bc65c76` 加本次未提交实现，SHA-256 `129d468923daec5f4b142018735888560f863e121f211aab4085c63413856be7`。随后补齐组合入口的独立发送计时，最终 CLI SHA-256 为 `8ee091240d59c385089584d1df2d31a8e2f699475709045d4917acf0a0ea9593`；组合查询表已用最终版本复测，JSON 与前次逐项相同。以下仍为索引就绪后三次中位数，不剔除首轮。基础查询的命中、位置、片段及截断字段与 P0 JSON 逐项一致；新增条件/符号/覆盖字段另有集成验证。

| 项目 / 基础查询 | 首批 ms | 结束 ms | 完整性 |
| --- | --- | --- | --- |
| tokio / `spawn` | 1.17 | 4.13 | complete |
| tokio / `IdleNotifiedSet` | 2.02 | 2.14 | complete |
| tokio / `fn\s+[a-z_]*spawn\w*`（正则） | 5.25 | 16.72 | complete |
| Codex / `spawn` | 6.14 | 18.36 | truncated，与 P0 相同 |
| Codex / `reconstruct_history_matches_live_compactions` | 9.30 | 9.88 | complete |
| Codex / `fn\s+[a-z_]*spawn\w*`（正则） | 55.99 | 112.25 | complete |

Codex 组合查询采用 `CancellationToken cancelled`；这些样本未达到任何截断上限，结束时是完整结果。

| 附加条件 | 首批 ms | 完成 ms | 结果行 |
| --- | --- | --- | --- |
| 无 | 3.96 | 65.48 | 682 |
| `path:codex-rs/` | 7.05 | 68.27 | 682 |
| `in:code` | 4.00 | 65.69 | 632 |
| `same:fn` | 4.15 | 66.86 | 281 |
| `near:5` | 4.09 | 65.41 | 95 |
| `same:fn in:code -path:tests/` | 6.59 | 57.49 | 240 |

tokio 的 `lock await` 组合复测同样每组执行三次；`lock` 在未加区域过滤时达到条件上限，因此仅 `complete` 行可用于完整结果时间判断。

| 附加条件 | 首批 ms | 结束 ms | 结果行 | 完整性 |
| --- | --- | --- | --- | --- |
| 无 | 0.342 | 16.073 | 5,031 | truncated |
| `path:tokio/` | 1.094 | 14.625 | 5,179 | truncated |
| `in:code` | 0.407 | 14.359 | 2,600 | complete |
| `same:fn` | 0.334 | 13.583 | 994 | truncated |
| `near:5` | 0.323 | 13.796 | 1,140 | truncated |
| `same:fn in:code -path:tests/` | 0.881 | 9.776 | 242 | complete |

引擎首批低于 100ms，完整的组合样本低于 1 秒；路径、区域、同一函数没有造成完成时间成倍增加。UI 另有 150ms 输入防抖，因此这些数字不能当作“键入到显示低于 100ms”的证据。三轮样本用于本次实现判断，不是 p95、原生输入到绘制时间或更大语料承诺。

本地复现与证据：`.build/query-p1/` 保存冷索引对照，`.build/query-final/` 保存12组查询的 JSON、每轮/中位数计时，`.build/query-final-delivery/` 保存最终组合批次实现的 tokio/Codex 各6组复测；`.build/query-native/` 使用独立 `dev.cairn.query-qa` 标识的打包应用和 tokio 副本。原生检查范围列在[产品限制表](product.md#当前限制与待核实事项)，操作、fixture 和截图清单保存在 `.build/query-native/README.md`；不把引擎、模型或进程内检查当作原生验收。


此前声称覆盖 185 项检查没有包含 `persistentDraftRoundTripMatchesDirectExtractionFieldForField`，该项仍断言旧格式而稳定失败；不能据此声明所有相关测试通过。2026-10-06 反馈修复已先复现排除上限、单条件计数、跨语言函数头、输入历史/过期状态、CLI 错误提示及 TS/TSX 区域身份错误，再执行对应回归。当前验证摘要和修复后的性能数据在下方记录。

旧版兼容存储边界另有1项通过（0失败、0跳过）：取 `bc65c76` 的原 `SessionCodec`/`SessionCheckpointStore`，读取本次真实 v5 数据报告 `unsupportedSchemaVersion(5)`，尝试写入旧格式后写回调为0、原文件逐字节不变；复现材料在 `.build/query-v4-compat/`。这不表示启动了完整旧版应用。

### 查询反馈修复验证（2026-10-06）

源码仍为 `bc65c76` 加未提交修改。最终 CLI SHA-256 `28a1a72e06539be733e9835f9a50f7af0361f2232c282b3f47b07969613d1302`；打包应用主程序 SHA-256 `2330c47c3d10a60414144dea5383734d5a5fa47d7f30539315e1ea1c2e7fcab4`。以下是本轮实际执行范围，不是全量 CI 结论：

- Engine 搜索、解析、快照索引/缓存 68 项通过；取消、首批和定时发送 4 项隔离执行通过（首批/定时各含普通、组合入口）。模型/会话 40 项、TypeScript 嵌套声明 2 项、共享区域一致性 1 项通过。合计 115 项相关测试通过，最终无失败或跳过。
- 首轮混合运行曾有 4 项计时测试在并行构建负载下产生 5 个失败 issue；无并行构建时分别重跑通过。未将这一首轮结果写为全通过。
- CLI 集成 6 项通过，包括查询错误可读提示、首项为负条件及选项误拼检查；1,016 项双语 key/占位符及本地 Markdown 链接检查通过。
- 原生打包应用使用独立标识 `dev.cairn.query-review` 和 `.build/query-review/native-fixture`：分段输入 `lock` → `lock a` → `lock aw` 后历史仍为空；回车、点击结果或关闭搜索后才增加完整条目，退出重开保持。语法错误时旧结果仍可点击，跳至原结果位置并只保存原查询。中文底部标签为“上下文”，结果符号显示 `Mutex::lock`，单短语 `"unwrap"` 显示4处匹配。刷新自动重搜保持2处结果，本轮未捕获短暂过期中间帧；快照变化禁用旧结果由模型回归覆盖，前轮原生观察不替代本轮帧证据。

同一 Codex `315195492c80fdade38e917c18f9584efd599304` 工作区、Release、索引就绪、`--repeat 3` 中位数，无并行构建；当前索引含2,612个Rust源文件。前四行受每文件命中上限影响，结束时间不代表完整结果耗时。

| 查询 | 首批 ms | 结束 ms | 匹配数 | 完整性 |
| --- | ---: | ---: | ---: | --- |
| `spawn` | 6.11 | 18.54 | 4,511 | truncated |
| `"spawn"` | 5.41 | 17.96 | 4,511 | truncated |
| `spawn path:codex-rs/` | 8.86 | 20.74 | 4,503 | truncated |
| `"spawn" path:codex-rs/` | 9.45 | 21.33 | 4,503 | truncated |
| `reconstruct_history_matches_live_compactions` | 11.94 | 12.49 | 1 | complete |
| `"reconstruct_history_matches_live_compactions"` | 10.40 | 10.91 | 1 | complete |
| `unwrap -test` | 6.04 | 9.12 | 571 | complete |

普通词/短语、带路径的普通词/短语的命中坐标逐项一致；普通词的坐标也与本轮修复前一致。`unwrap -test` 的213个结果文件另外由独立脚本读取，全部不含忽略大小写的 `test` 子串。上限回归另覆盖排除超过每文件200次、跨文件超过5,000次，以及无法确认排除时不得放行；密集排除只保留存在信息，TS/TSX同字节也不共用错误的区域索引。

原始命令、red/green日志、查询JSON及原生证据保存于 `.build/query-review/`。本轮修复未重新测量冷索引成本，前文的冷索引数字保留其原始测量范围。


### 刷新一致性与 CI 验证（2026-10-06）

查询重建保存 `(path, contentID, byteRange)`，跨批次寻找原命中；匹配不到时保留空选择，不把列表自动移到首项。搜索导航要求已知内容身份。刷新前分别保存阅读区的选中位置与滚动锚点，不能把 `firstVisibleByteOffset` 当成选中位置重放；同内容刷新使用已有 tab restore 路径，新内容仍走锚点回退。刷新失败或后续其他导航会清理待恢复状态。

并发扫描测试的同步 gate 会占用执行线程，因此这些测试及参数用例放在同一串行 suite；其余引擎测试仍和它们处于同一批。外围等待上限为10秒，gate保持30秒，首批测试的计时器为60秒，正则自身的10ms预算不变。故障注入分别禁用首批发送、把50ms计时器推迟到60秒，普通/组合入口对应断言都失败；恢复后5项通过。全局 `ReaderWorkCounters` 的测量用例使用现有 CI 独立进程机制，避免其他索引测试污染计数。

`CODEX_SANDBOX=1 bash scripts/ci.sh engine` 连续两轮各完成245项：同批244项（含全部并发扫描测试和重型索引测试）+独立计数测试1项，均0失败、0跳过。搜索模型25项和 AppKit 刷新回归1项通过；该回归修复前明确同时失败于模型选中位置、阅读器光标和视口断言。CLI 6项通过，另确认括号分组在索引前给出可读错误。

原生构建基于 `bc65c76` 加未提交改动，主程序 SHA-256 `2dd2ce02cd02d019fc54e2e7d6e1b230406288b20720707a2f58adac7c0f56bd`，CLI SHA-256 `c67d3afefd1d78bb226b9d39e205c6f376c9cb0b085e2591ad857aa1cd853d0b`。独立应用 `dev.cairn.query-refresh` 中搜索 `needle`：`config.rs:26` 在第一组，选择第二组的 `conn.rs:21` 后连续刷新两次，列表仍选21行，阅读区仍在21行，视口首部仍为13行。截图确认分组三角与路径文字分开，折叠/展开仍可用，默认区域可见约8条匹配，底部显示 `Rust`；`(a OR b)` 原生显示“暂不支持括号分组”。未进行逐帧动效计时。

证据及可复现fixture在 `.build/query-refresh-review/`：`before-refresh.png`、`after-refresh-1.png`、`after-refresh-2.png`、`grouping-error.png` 和 `checks/`。这是相关 CI 域与交互验证，不是 full 域或发布验证。代码未提交、未推送。
