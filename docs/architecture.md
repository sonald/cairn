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

2026-10-05，可组合查询 P0：**停止于性能检查点，P1–P4 尚未实施**。Codex 的罕见单词查询首批结果三次均超过 100ms。采样显示时间主要花在扫描实现上，并非缺少索引：每次搜索前按文件构造 `URL` 做语言分类（约 40ms）、单线程逐字节比较（约 90ms）、无命中文件也建行号表（约 18ms）。因此先提速扫描，不做三元组索引（细节见 [query-plan.md](query-plan.md) P0.5）。

环境：MacBook Pro Mac15,6，Apple M3 Pro（11 核，5P+6E），36 GiB 内存；macOS 27.0（26A428），Xcode 27.0（27A266a），Swift 6.4。Release CLI、Homebrew libgit2。源码为 `ec55b9b016dc795c6c94d125a67c1d98f9ca1bf9` 加本工作树未提交的 P0 计时及错误根修复，Rust extractorVersion=9；测量二进制 SHA-256 为 `7ba463cf937736ec709ca51e5c845286704b501b39c0ee255e4c83965d5793cd`。

原始基线先在 Codex 的 `codex-rs/core/tests/suite/unified_exec.rs` 崩溃：tree-sitter 返回 `ERROR` 根，其中的常量初始化器没有文件作用域，触发 `RustScopeBuilder.pushRegionIfNeeded` 的断言。两行复现见 `damagedRootPreservesConstantInitializerScope` 回归测试。修复只为异常根补建模块作用域；抽取器版本 8→9 会使已有 Rust 缓存重建。以下所有数据均来自修复后的同一构建，不把崩溃运行算作成功样本。

语料均为干净工作区，仅索引 Rust，使用默认目录排除规则：

| 项目 | 本地路径 | 版本 | 文件 / 唯一内容 | 含语法错误的文件 |
| --- | --- | --- | --- | --- |
| tokio | `/Users/siancao/.cache/cairn-corpora/tokio-tokio-1.47.1` | `be8ee45b3fc2d107174e586141b1cb12c93e2ddf` | 717 / 717 | 0 |
| Codex | `/Users/siancao/work/readings/codex` | `315195492c80fdade38e917c18f9584efd599304` | 2,612 / 2,608 | 26 |

每个项目使用两个新的隔离缓存目录，每个目录先冷索引一次，再用新进程热索引一次。冷仅指提取缓存为空，未清空操作系统文件缓存。热运行均确认 `extractedContents=0`，`reusedContents=uniqueContents`。进程耗时包含持久化写入完成，内部索引时间不包含该等待；RSS 为 `/usr/bin/time -l` 记录的进程峰值。

| 项目 / 缓存 | 内部索引 ms（两次） | 进程耗时 s（两次） | 峰值 RSS MiB（两次） | 退出后缓存总字节（两次） |
| --- | --- | --- | --- | --- |
| tokio / 冷 | 575、516 | 1.26、1.18 | 84.77、84.50 | 5,726,208、5,730,304 |
| tokio / 热 | 365、349 | 0.41、0.39 | 81.30、79.52 | 5,726,208、5,730,304 |
| Codex / 冷 | 4,082、3,813 | 9.47、9.31 | 510.61、512.12 | 36,569,088、36,995,072 |
| Codex / 热 | 2,671、2,683 | 2.85、2.86 | 414.92、422.33 | 36,503,552、36,929,536 |

缓存统计包含 SQLite 主文件及仍存在的 WAL/SHM；并发提取与 SQLite 布局会带来少量体积差异。P1 的首次建索引与缓存增幅应与相同语料、相同冷缓存持久化口径比较，不能把内部索引时间与进程耗时互换。

每个查询使用 `search --persist --repeat 3 --json`：索引一次后连搜三次，未剔除第一轮，大小写不敏感。首批指调用 `session.search` 到收到首个非空批次；结束指流结束并完成 CLI 批次合并，不包含索引、最终排序、JSON 编码和 stdout。以下均为三次中位数。

| 项目 | 查询 | 首批 ms | 结束 ms | 命中 / 文件 | 完整性 |
| --- | --- | --- | --- | --- | --- |
| tokio | `spawn` | 11.58 | 25.69 | 3,033 / 262 | complete |
| tokio | `IdleNotifiedSet` | 24.92 | 24.92 | 26 / 3 | complete |
| tokio | `fn\s+[a-z_]*spawn\w*`（`--regex`） | 15.90 | 34.96 | 190 / 58 | complete |
| Codex | `spawn` | 43.44 | 152.96 | 4,511 / 527 | truncated |
| Codex | `reconstruct_history_matches_live_compactions` | **154.12** | 154.14 | 1 / 1 | complete |
| Codex | `fn\s+[a-z_]*spawn\w*`（`--regex`） | 55.49 | 230.75 | 373 / 149 | complete |

Codex 罕见词首批原始样本为 154.120、154.396、153.577ms，均未达到 S8.1。`spawn` 在 `codex-rs/core/src/agent/control_tests.rs` 和 `codex-rs/core/src/tools/handlers/multi_agents_tests.rs` 达到每文件 200 条上限，结束时间不能称为完整结果时间。

局限：当前引擎攒够 16 个命中文件或 200 条命中才发送中间批次，罕见词首批可能等到扫描结束；界面另有 150ms 防抖。本次是引擎/CLI 证据，没有执行原生显示验收，不是端到端 100ms 的 PASS。Codex 的 TypeScript/Python 和非源码文件不在本次范围。少量样本用于检查点决策，不是 p95 或发布承诺；P1 的 +10%/+15% 预算与 S8.2 组合查询尚未验证。

复现命令见[开发说明](development.md#性能复现)。本地原始输出在指定工作树 `.build/query-p0/`；修复前输出在 `.build/query-p0-before-root-fix/`，不提交整套日志。验证：Release 构建 PASS；Rust 抽取器 Swift Testing 完整摘要为 35 通过、0 失败、0 跳过；CLI 集成检查 3 通过、0 失败、0 跳过。回归用例修复前已复现 SIGTRAP。
