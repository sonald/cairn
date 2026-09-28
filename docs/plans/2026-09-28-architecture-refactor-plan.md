# 面向后续阅读功能的架构重构方案

日期：2026-09-28
状态：**§0.3 已按推荐裁决（2026-09-28）：R1a 纳入；Reading Set 省略表示暂缓；会话持久化只提取职责。R0 进行中。**
性质：**纯重构。** 本轮不新增任何产品功能、索引数据或界面入口；除 §0.2 标明的一处缺陷修复外，所有改动
必须保持可观察行为不变。
复核基线：`508cf09`（包含同行评审所用的 `6a54ef1`）。
输入：本会话的架构分析；同行评审《架构调整》；
[只读架构详细设计](2026-09-26-readonly-design.md) 与 [实施计划](2026-09-26-readonly-implementation-plan.md)；
[L3 混合语言计划](l3-mixed-language-plan.md)。

---

## §0 结论先行

### §0.1 为什么现在做

后续可能做的功能——Agent 项目识别与领域 outline、语义高亮、语义焦点、原地展开、生成注释——本轮都**不做**。
它们只用来回答一个问题：**如果明天开始做这些功能，现有代码的哪些地方会逼着我们在协调对象里继续堆特例？**
本方案只处理这些地方，并且只做行为不变的结构调整，让以后的功能主要是「新增自己的规则」，而不是
「改动所有旧功能的协调代码」。

### §0.2 本轮唯一的可观察行为变化

`ContextWindowModel.applyExact` 的竞态（F2）：Exact 校验期间用户切换候选，校验结束后选择会被旧值覆盖。
这是缺陷修复，不是新功能；R1a 给出明确契约与红测。若用户认为本轮应严格零行为变化，可把 R1a 移出，
只保留其余 R1 项。

### §0.3 需要用户裁决

| # | 问题 | 推荐 |
|---|---|---|
| Q1 | R1a（F2 竞态修复）是否纳入本轮 | **纳入**：它是已确认缺陷，且 R3 重构同一段代码时无法绕开 |
| Q2 | R8「Reading Set 省略标记显式化」涉及 `SessionCodec` 持久化格式，是否纳入 | **暂缓**：待原地展开功能立项时与 R6 的投影契约一起设计；本轮只记录问题 |
| Q3 | R7 会话持久化：只提取职责（同线程、同步语义不变），还是同时移出主线程 | **只提取职责**：移出主线程会改变写入时序，缺少卡顿实测证据 |

---

## §1 未来功能 → 当前障碍

| 后续功能 | 会撞上的现有结构 | 本轮对应重构 |
|---|---|---|
| Agent 领域 outline | 侧栏 outline 与 `OutlineFacet`、单文件、字节范围包含关系硬绑定 | **R6** 侧栏 outline 数据源解耦 |
| Agent 领域 outline、语义搜索 | 声明「是函数/类型/容器」的语义在 5 处各自 switch 重算，新增语言或种类要逐处修改 | **R2** 声明分类词汇收敛 |
| 自动解释、证据展示 | Context 候选把 dispatch 折进本地化 `label`，原始 evidence 在展示前被丢弃 | **R3** 候选保留结构化事实 |
| 语义焦点（「只看这个 Tool」） | Full/Structure/Overview/Focus 的折叠决策写在 AppKit 渲染器的私有静态函数里 | **R4** 阅读规划提取到 ReaderCore |
| 语义高亮 | 样式合成是固定元组 `HighlightKind? + occurrence + isParameterReference?`，每加一种强调就加一个布尔位 | **R5** 装饰合成改为有序层 |
| 高频交互、异步领域分析 | 内容校验触发整套语法分析；大文件语法任务不可取消；有效性检查在同一函数里复制 5 遍；一处锁外读 | **R1** 缺陷与重复工作；**R3** 有效性检查收拢 |
| 任何新增 AppModel 状态 | `AppModel`（4,324 行）同时承担会话持久化、迁移、损坏隔离 | **R7** 会话持久化职责提取 |
| 原地展开、生成注释 | 源身份与展示实例身份未分离；Reading Set 用文本内 `…` 行表示省略 | **不在本轮**，见 §5 与附录 |

---

## §2 事实基线（均已对照 `508cf09` 源码核实）

### §2.1 已确认的缺陷与重复工作

| ID | 事实 | 位置 |
|---|---|---|
| F1 | `indexContentIsCurrent` 只为比较 `contentID`，却执行完整 `DocumentLoader.load`（行表、UTF-16 映射、高亮、fold、outline、局部绑定）；一次 Exact 升级调用两次 | `ContextWindowModel.swift:871–894`、`:578–585` |
| F2 | `applyExact` 在两次 `await` 后只检查 `case .candidates = stage`，随后用 await **前**捕获的 `current`/`selected` 重写 `stage`；`select`/`selectNext`/`selectPrevious` 不改变 `requestID` | `ContextWindowModel.swift:557–640`、`:294–317` |
| F3 | 混合语言准备路径 `let store = store` 在锁外读取；`beginSnapshotScope` 在锁内替换它；单语言路径 `:178`、`:222` 都在锁内读取 | `AppModel.swift:267` |
| F4 | `loadSyntax(for:completion:)` 内部 `Task.detached`、不返回句柄；只用于 >10,000 行的 large/huge 档，正是最需要取消的场景 | `CodeInsightReaderCore.swift:976–993`、`MainWindowController.swift:7758` |

### §2.2 结构性坏味道

| ID | 事实 | 位置 |
|---|---|---|
| S1 | 声明分类在 5 处各自重算：Palette 的两个 `init`（分别从 `OutlineKind`、`DeclarationKind`）、Diff 的「是否函数」与名字分隔符、CLI 的函数过滤；搜索权重另有一份逐 case 表 | `PalettePanel.swift:47/61`、`DiffCore.swift:67/398`、`CodeInsightCLI.swift:413`、`EngineSession.swift:634` |
| S2 | Context 候选的 `label` 与 `provenanceBadge` 是由 certainty 和 dispatch 拼成的本地化字符串；`Candidate` 不保存 `dispatch` 与 `evidence` | `ContextWindowModel.swift:16–30`、`:462–476` |
| S3 | 同一组有效性条件（requestID、`.ready`、generation、snapshotID、profile ID）在 `ContextWindowModel` 中复制 5 遍 | `ContextWindowModel.swift:564–568`、`:586–590`、`:632–636` 等 |
| S4 | 折叠/焦点决策是 `ReaderTextView` 的私有静态纯函数：`logicalFoldIDs`、`baselineFoldIDs`、`focusTarget`、`enclosingAssociatedFacets`、`facetContainsCaret`、`focusFoldIDs`、`maximalFoldIDs`、`setFold` | `CodeInsightReaderUI.swift:1431–1553` |
| S5 | 样式合成元组 `StyledRange = (range, HighlightKind?, occurrence: Bool, isParameterReference: Bool?)` | `CodeInsightReaderUI.swift:165–167` |
| S6 | `SidebarViewController`（约 1,040 行）位于 8,581 行的 `MainWindowController.swift` 内；outline 数据源直接操作 `OutlineFacet`、以 `range.lowerBound` 作为折叠状态键、以 `nameRange` 作为跳转目标 | `MainWindowController.swift:3965–5003`、`:4440–4560` |
| S7 | 会话持久化（检查点调度、路径、加载、旧版迁移、损坏隔离、写入、清除、快照构建）约 700 行位于 `AppModel` | `AppModel.swift:736–1465` |
| S8 | 小项：`RustHighlighterError` 被 Python/TS 高亮复用；`FileTreeModel` 的 `language(s)` 参数被 `_ = language` 忽略 | `PythonReaderSyntax.swift:30`、`AppModel.swift:368/387/397` |

### §2.3 已由只读计划处理、本轮不重复

- 同行第 6 点的「颜色 vs 布局」失效契约：只读计划 S4 已实现（纯颜色不重建投影、不恢复视口），见 `evidence/readonly/stage-s4.md`。
- 同行提到的 `identifierOccurrences` 全文扫描：已由 S1 的 `IdentifierIndex` 取代，CI 禁止交互路径调用（`scripts/ci.sh:107`）。
- 同行第 3 点的投影模型：`ReaderProjection` 已存在（`.source`/`.folded` 段）。S8 已证明把自然段拆成多个 `NSTextParagraph` 会改变几何（11 个采样点 9 个不同）。

---

## §3 原则与不变量

1. **先锁行为，再移动代码。** 每个重构切片先补「特征测试」固定当前输出（若已有测试覆盖则引用），再改结构。
   需要比较新旧实现时，旧实现以测试专用 oracle 形式保留在测试 target 中（沿用只读计划 S0.3 的做法），
   切片完成后删除。
2. **可观察行为不变**：Reader 文本、高亮 run、折叠集合、outline 行与折叠状态、Context 候选的顺序与文案、
   会话文件字节、四个 Gold、`CanonicalDump`、fold 自测与 fold 性能门禁全部不变。
3. **不新增索引数据、界面入口、持久化字段**；不修改 `ContentIndex`、`ContentIndexKey`、`SessionCodec` 格式、
   `ProjectState`、`QueryContext`。
4. **不做机械拆分**：不把大类切成若干 `extension` 文件而状态仍互相访问。唯一的纯搬移（R6a）是为了让侧栏
   成为独立单元，其后必须有 R6b 的数据源解耦。
5. 新增类型必须有**当前**的生产消费者（通常是被替换的旧代码），在各切片中列明。
6. 每片红→绿（或特征测试绿→重构后仍绿）、单独提交；更新 `scripts/ci.sh` 的 `expected_main_test_count`；
   只接受有完整 Swift Testing 摘要的结果。

---

## §4 R0：基线与特征测试盘点

产物：`docs/plans/evidence/arch-refactor/r0-baseline.md`。只读，不改 production。

| 任务 | 内容 |
|---|---|
| R0.1 | 记录 HEAD、工具链、`expected_main_test_count`（当前 1171）。若当前代码树已有完整 CI 记录则引用，否则跑一次 `CODEX_SANDBOX=1 bash scripts/ci.sh` |
| R0.2 | 为 R2–R7 每个切片列出**已有**覆盖其行为的测试名；缺口处列出需新增的特征测试（见各切片） |
| R0.3 | 记录 fold 性能门禁、`--self-test-fold`、`--self-test-reading` 的基线输出，供 R4/R5 前后对比 |

---

## §5 实施切片

### R1 — 已确认缺陷与重复工作

#### R1a　`applyExact` 跨 await 的选择一致性（F2，需 Q1 批准）

**文件**：`Sources/CodeInsightAppModel/ContextWindowModel.swift`、`Tests/CodeInsightAppModelTests/ExactCoordinatorTests.swift`

**契约**（写入代码注释）：
1. 候选身份是 `(path, targetByteOffset)`，不是下标。
2. 请求开始后用户显式改变过选择：Exact 结果只**就地升级**匹配的候选，不重排、不改选择；需要插入新候选时插在
   首位，选择下标 +1，保持选中同一候选。
3. 用户未改变选择：保持现有行为（follow 模式升级项提到首位并选中）。
4. pinned 模式：只在 await **之后**的选中项就是目标时升级。

**实现**：私有 `selectionEpoch: UInt64`，三个选择入口递增；`applyExact` 进入时捕获；每个 await 后用
`case let .candidates(latest, latestSelected) = stage` 重新绑定并按身份查找。

**红测**：
- `contextExactUpgradeKeepsUserSelectionChangedDuringVerification`
- `contextExactPinnedUpgradeUsesSelectionAfterVerification`
- `contextExactInsertKeepsUserSelectionChangedDuringVerification`
- 回归：现有三个 drift 测试（`ExactCoordinatorTests.swift:2020–2140` 附近）。

测试通过 R1b 的 `contentIdentity` 注入点挂起校验，在挂起期间调用 `selectNext()`。

#### R1b　内容身份校验不做语法分析（F1）

**实现**：新增 `typealias ContentIdentityReader = @Sendable (URL) async -> ContentID?`，默认实现：有
`contentSource` 用它读字节，否则 `Data(contentsOf:options:.mappedIfSafe)`，返回 `ContentID.sha256(of:)`——
与 `DocumentLoader.load` 的身份计算一致（`CodeInsightReaderCore.swift:872`）。`indexContentIsCurrent` 改用它，
保留「依赖路径 / 无 pathID 时返回 true」的语义。现有 `loader` 注入（如 `AppModelTests.swift:2339`）仍只控制
excerpt 文档加载。

**测试**：`contextExactVerificationDoesNotBuildReaderDocuments`（计数 `loader`，断言 Exact 升级期间不构建阅读文档）；
三个 drift 测试保持通过，证明身份判定语义不变。原计划用 DEBUG `RustExtractor.parseObserver` 计数，但它是
`@TaskLocal`，不会进入校验所用的 `Task.detached`，因此改为观察 `loader` 调用。

**已知差异**：旧实现遇到非 UTF-8 字节时 `DocumentLoader.load` 抛错，校验判为「已变化」，并通过
`onStaleIndexContent` 报告一个实际上并未变化的文件；新实现只比较哈希，字节与索引一致即判为未变化。索引器不检查
UTF-8（`ProjectIndexer`/`ProjectIndexStore` 中没有编码校验），所以这条路径理论上可达。新行为消除的是一次误报；
需要构建阅读文档的插入分支仍会因加载失败而不插入候选。未为此单独加测试。

#### R1c　混合准备路径在锁内读取 store（F3）

`AppModel.swift:267` 改为 `let store = lock.withLock { self.store }`，与 `:178`、`:222` 对称。一行修复，不新增只
重复实现的测试；运行 `SnapshotSwitchTests` 与 mixed 相关 AppModel 测试一次。可选运行一次
`swift test --sanitize=thread --filter Mixed`，未运行记 NOT_RUN。

#### R1d　可取消的异步语法加载（F4）

**文件**：`Sources/TreeSitterKit/TreeSitterKit.swift`、`Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift`、
`Sources/CodeInsightApp/MainWindowController.swift`、`Tests/CodeInsightReaderCoreTests/ReaderCoreTests.swift`

**实现**：
1. `loadSyntax(for:completion:)` 返回 `@discardableResult Task<Void, Never>`；在解析前、解析后、回调前检查
   `Task.isCancelled`，取消时不调用 completion。现有 11 处 completion 形式调用方（生产 6、测试 5）编译不受影响；
   同步重载 `loadSyntax(for:) throws` 不变。
2. `Parser` 增加 `parse(_:shouldCancel:)`，基于 v0.25.8 的 `ts_parser_parse_with_options` 与
   `progress_callback`（`api.h:101`）协作取消；解析之后、局部引用之前与之后各检查一次。只有异步
   `loadSyntax(for:completion:)`（large/huge 档）传入取消条件，regular 档同步路径不变。
   **实施偏离**：原计划的「遍历中每 4,096 个节点检查一次」未做——Python/TS 遍历器是递归实现，把取消条件穿进
   递归会扩大改动面；解析是可以中途停止的主要成本，遍历只在阶段边界停止。
3. `ReaderViewController` 保存句柄，在新加载、关闭、切换文件时取消；现有 `loadGeneration`/`displayedLanguageMode`
   发布栅栏**保留**（取消是省计算，栅栏是防误发布，二者不互相替代）。

**测试**（实际）：`cancellableParseMatchesPlainParseWhenNotCancelled`、`cancellableParseHaltsAtTheFirstCancelledPoll`
（TreeSitterKit）；`cancellableSyntaxPassMatchesTheDefaultPassAndStopsWhenCancelled`、`cancelledAsyncSyntaxLoadNeverCompletes`
（ReaderCore）。原计划的「解析次数为 0」断言因 `parseObserver` 是 `@TaskLocal`、不进入 detached 任务而改为以上
可确定的断言；「中途取消」由轮询计数确定性证明，不依赖计时。fold 自测与 fold 性能门禁由 R1 检查点的完整 CI 覆盖。

**为后续功能准备的**：异步领域分析与高频语义交互需要「停止无用计算」与「不发布旧结果」两种能力各自存在。

---

### R2 — 声明分类词汇收敛（S1）

**目标**：「这个声明属于哪一族（函数 / 类型 / trait / 容器 / 值）、名字用什么分隔符」只在一处定义。

**实现**：
- 在 `Sources/CodeInsightCore/ContentIndex.swift` 旁新增 `DeclarationFamily`（`function/type/trait/container/value`），
  以及 `DeclarationKind.family`、`DeclarationKind.isCallable`、`DeclarationKind.qualifiedNameSeparator`（由
  `LanguageID` 推出，Rust 为 `::`，其余为 `.`）。
- `OutlineKind`（ReaderCore）增加 `family`，映射放在 ReaderCore（它依赖 Core）。
- 替换使用点：`PalettePanel` 两个 `init` 改为基于 `family` 查表；`DiffCore.isFunction` 与 `displayName`。
  CLI `:413` **不改**（R0 盘点：CLI 无测试覆盖，且 `calls` 只索引 Rust）。`Resolver.swift:77` 的 `[.rustMethod, .rustFn]` 是 Rust 方法名兜底路径的候选过滤，属于解析策略而非
  分类，**不改**。`EngineSession.kindWeight` **保留逐 case 权重**（权重是搜索排序策略，不是分类；Python/TS 与 Rust 函数同为 24 是
  巧合而非规则），只加注释说明为何不用 family。
- 顺带 S8：`RustHighlighterError` 更名为 `ReaderSyntaxError`；`FileTreeModel` 删除被忽略的 `language`/`languages`
  参数重载，只保留 `init(root:)` 与 `init(root:snapshotPaths:)`。
- **实施调整**：Palette 的两字母标签比「族」更细（st/en/ty/cl 同属 type 族），因此共享词汇落为
  `DeclarationShape`（function/struct/enum/class/typeAlias/trait/impl/module/value），族由 `shape.family` 推出；
  `DeclarationKind.shape/language/qualifiedNameSeparator` 与 `OutlineKind.shape` 为唯一映射。两处改名/删参
  没有保留兼容别名：它们只有本仓库内的调用方，全部已同步，保留别名只会是无人使用的代码。

**测试**：`declarationFamilyCoversEveryKind`（穷举 `DeclarationKind`/`OutlineKind`，对照旧 switch 的 oracle）；
Palette 行标签与 Diff 显示名的现有测试保持通过。

**为后续功能准备的**：新增语言、新增声明种类或领域分组时，只改一张映射表。

---

### R3 — Context 候选保留结构化事实，并收拢有效性检查（S2、S3）

**实现**：
1. `Candidate` 增加 `dispatch: DispatchKind?` 与 `evidence: [ResolutionEvidence]`（Exact 升级候选沿用其来源）。
2. `label`、`provenanceBadge` 改为由一个私有 `CandidatePresentation` 函数从结构化字段生成；保留两个字段的存储
   与文本，确保 UI 与测试看到的字符串逐字不变。
3. 新增私有 `func isStillCurrent(request:session:context:) -> Bool`，替换 5 处重复条件；各分支需要的 `stage` 重新
   绑定留在调用点（R1a 已示范）。
4. 不引入跨模型的通用「请求上下文」类型；若 `RelationTreeModel` 出现同样的重复，另立切片。

**测试**：`contextCandidateLabelsMatchPreviousPresentation`（对多个 certainty × dispatch 组合，断言标签与重构前 oracle
逐字相等）；Context/Exact 现有测试全绿。

**为后续功能准备的**：解释与证据展示直接消费 dispatch/evidence，不需要反解析本地化字符串。

---

### R4 — 阅读规划提取到 ReaderCore（S4）

**实现**：
- 新增 `Sources/CodeInsightReaderCore/ReadingPlan.swift`（package API），搬入 S4 列出的 8 个纯函数，接口仍以
  `ReaderDocument`、`FoldRegion`、`OutlineFacet`、`FoldOverrides` 为输入输出。`ReadingHeightLevel`（现为 ReaderUI 的
  `package enum`，`CodeInsightReaderUI.swift:474`）与 `FoldOverrides`（现为 `ReaderTextView` 内的 `private struct`，
  `:495`）一并下移到 ReaderCore 并改为 `package`；二者都不依赖 AppKit。
- `ReaderTextView` 改为委托调用；TextKit、字体、命中测试、视口保持原位。
- 不增加新的阅读模式或语义焦点入口。

**测试**：
- 新增 ReaderCore 纯测试：对 Rust/Python/TS fixture 与 `fixtures/fold_perf.rs`，三档阅读高度 × 若干焦点位置 ×
  覆盖规则，断言 fold 集合与重构前 oracle 相等。
- 现有 ReaderUI 折叠/焦点测试、`--self-test-fold`、`run-fold-perf.sh` 输出与 R0.3 基线一致。

**为后续功能准备的**：语义焦点只需提供一组源范围给 `ReadingPlan`，不改渲染器。

---

### R5 — 装饰合成改为有序层（S5）

**实现**：
- 在 ReaderUI 内把 `StyledRange` 元组改为 `DecorationLayer` 列表：每层给出 `(id, priority, 源范围集合, 非布局样式)`；
  合成器按优先级生成 run。
- 本轮只有三层：语法（`HighlightKind`）、occurrence 背景、参数引用透明度，**合成结果必须与现有实现逐 run 相同**。
- 契约写入注释：层只允许颜色、背景、下划线等不影响布局的样式；字号/字重类变化必须走 S4 已有的 typography 事务。
- 保留 `rangeCalculationCount`/`rangeCacheHitCount` 等计数语义与 128 范围 / 8,192 run 缓存上限。

**测试**：
- `decorationComposerMatchesLegacyRuns`：旧合成逻辑作为测试 oracle，对 Rust/Python/TS fixture 的多个视口、
  有/无 occurrence、有/无参数引用组合，逐 run 比较范围与属性。
- 只读计划 S4 的 16 格矩阵、validator 回放、纯颜色不触发全文计算的测试全部保持通过。

**为后续功能准备的**：语义高亮、搜索命中、解释引用区间都成为新增一层，而不是新增布尔位与分支。

---

### R6 — 侧栏 outline 数据源解耦（S6）

#### R6a　纯搬移

`SidebarViewController` 从 `MainWindowController.swift` 搬到 `Sources/CodeInsightApp/SidebarViewController.swift`，
零行为改动；验证：编译 + 侧栏相关 App 测试（含 CI 单独批次的
`productPolishOutlineUsesNativeHierarchyAndPreservesCollapsedBranches`）。

#### R6b　outline 行模型与 `OutlineFacet` 解耦

**实现**：
- `OutlinePanelModel` 输出语言中立的行模型：`OutlineNode(key, title, detail, family, navigationOffset, range)`；
  父子关系仍由现有包含算法计算。`key` 等于现在用作折叠状态键的 `range.lowerBound`，保证折叠状态保存逻辑不变；
  `navigationOffset` 等于现在的 `nameRange.lowerBound`。
- 符号 outline 成为这个行模型的**唯一生产者**（`[OutlineFacet] → [OutlineNode]` 的适配函数）；侧栏数据源、cell 渲染、
  跟随高亮只依赖 `OutlineNode`。
- `onOpenOutline` 保持 `(UInt32) -> Void` 不变：它与阅读器 scope header 的 `onOpenScope` 共用同一闭包
  （`MainWindowController.swift:456–460`）。跨文件跳转目标等 Agent outline 立项、出现真实消费者时再加，
  本轮不加无消费者的字段。
- 不新增分段控件、不新增第二个生产者。

**测试**：`OutlinePanelModelTests` 现有用例改为断言 `OutlineNode`；新增 `outlineNodesMatchFacetOrderAndHierarchy`；
侧栏原生测试与一张原生截图（证明 outline 内容可见，非占位），与 R0 基线截图对比。

**为后续功能准备的**：侧栏不再认识 `OutlineFacet`；Agent 领域 outline 只需新增一个 `OutlineNode` 生产者，
并在那时为节点加上跨文件跳转目标。

---

### R7 — 会话持久化职责提取（S7，按 Q3 推荐只提取职责）

**实现**：
- 新增 `Sources/CodeInsightAppModel/SessionCheckpointStore.swift`（`@MainActor final class`），搬入：会话文件路径计算、
  加载与旧版加载、损坏隔离、检查点写入、旧版退役、清除。写入保护状态 `sessionOverwriteBlockedKeys` 与
  `sessionRestoreWriteSuspension`（`AppModel.swift:615`）随职责一起移入；`sessionSaveNotice`/`sessionLoadNotice`
  仍是 `AppModel` 的公开可观察属性（`:529/:532`），由 store 返回结果后在 AppModel 中更新，UI 绑定不变。
  防抖状态 `sessionCheckpointDirtyAt` 与调度留在 AppModel。
- `makeSessionSnapshot` 与 `restoreSession`（依赖 tab、导航、Reading Trail 等 AppModel 状态）**留在 AppModel**；
  store 只接收不可变 `SessionCodec` 快照。
- **线程与时序不变**：仍在主线程同步写入；`scheduleSessionCheckpoint` 的防抖与 `cancelPendingSessionCheckpoint`
  语义不变。

**测试**：`SessionCodecTests`、`SessionRestoreTests`、`SessionOpenBoundaryTests` 全绿；新增 store 级单元测试覆盖
「新版本不可覆盖」「恢复未完成不可写」「损坏文件隔离」三条保护规则（若 R0.2 盘点发现已有，则引用不新增）。
写出的会话文件字节与重构前一致（固定输入比较）。

**为后续功能准备的**：以后需要移出主线程时，只改 store 内部；AppModel 不再增长持久化逻辑。

---

## §6 明确不做

- 不新增 `ContentIndex` 字段（decorator、调用参数、字符串、循环）、不做领域识别层、不做 Agent 视图、语义高亮、
  语义焦点、原地展开、生成注释。设计思路保留在附录，供未来功能立项使用。
- 不做 TreeSitterKit Query API（当前无消费者）。
- 不统一 Engine 与 Reader 的解析（两次解析服务于不同缓存身份；先消除上层多余调用）。
- 不引入 `LanguageAdapter`/registry；extractor 工厂在 `ProjectIndexer:525` 与 `DiffCore:386` 各有一份，两个模块互不依赖，
  为此新增共享 target 不划算。
- 不重做 `ContextWindowModel` 的 8 文档缓存（未测到问题）。
- 不拆分 `CodeInsightApp.swift` 中的 self-test 代码。
- 不改 Reading Set 省略表示（Q2 推荐暂缓）。
- 不把会话写入移出主线程（Q3 推荐暂缓）。
- VoiceOver 与语音相关测试不在验收范围（AGENTS.md）。

---

## §7 验收与证据

| 切片 | 必要证据 |
|---|---|
| R1 | 每项红→绿；F2 交错场景测试；完整 CI 一次并记录总数 |
| R2 | 分类穷举 oracle 测试；Palette/Diff 现有测试 |
| R3 | 标签逐字相等测试；Context/Exact 全绿 |
| R4 | fold 集合 oracle 测试；fold 自测与性能门禁输出与 R0.3 一致 |
| R5 | 逐 run oracle 测试；S4 矩阵测试全绿 |
| R6 | outline 行模型测试；侧栏原生测试；原生截图对比 |
| R7 | 会话相关测试全绿；会话文件字节一致 |
| 收尾 | 完整 CI 一次；`evidence/arch-refactor/acceptance.md` 列出每片提交、测试总数、未运行项（NOT_RUN） |

通用规则：相关检查通过后，没有新代码变化不重复跑完整 CI；性能只取少量代表性样本，不做 p95 研究。

---

## §8 风险与停止条件

| 风险 | 缓解 / 停止条件 |
|---|---|
| 重构中无意改变行为 | 每片先有特征测试或 oracle；任一 oracle 比较不等即停，不以「更合理」为由接受差异 |
| R5 合成器性能退化 | 对比 R0.3 的 fold 性能门禁与计数器；退化即回退该片 |
| R6b 改变侧栏折叠状态或跟随行为 | `key` 与现有状态键完全相同；侧栏原生测试不过即停 |
| R7 改变写入时序 | 本轮禁止改线程与防抖；会话文件字节比较不等即停 |
| 切片范围膨胀 | 每片限定在列出的文件；发现需改其它模块时停下来单独评估 |

---

## §9 建议提交顺序

```text
R0 基线与特征测试盘点
 │
 ├─ R1a（Q1）  R1b  R1c  R1d           缺陷与重复工作，互不依赖
 │
 ├─ R2 声明分类收敛
 ├─ R3 Context 结构化事实 + 有效性检查   依赖 R1a/R1b（同一文件）
 ├─ R4 阅读规划提取
 ├─ R5 装饰合成                         与 R4 同改 ReaderUI 文件，按顺序集成
 ├─ R6a 侧栏搬移 → R6b 数据源解耦        R6b 可用 R2 的 family
 └─ R7 会话持久化职责提取
 │
收尾：完整 CI + 交付记录
```

---

## 附录：后续功能的接入点（本轮不实施）

记录分析阶段的设计结论，供功能立项时直接使用。

1. **Agent 领域 outline**：分两层。
   - 语言事实：decorator/attribute、调用参数（一层展开）、字符串字面量、循环，追加进 `ContentIndex`，
     随 `extractorVersion` 缓存；`CanonicalDump` 追加段、既有段逐字不变。
   - 框架知识：声明式静态表，在索引之后匹配，不重新解析、不使索引缓存失效。
   - 输出领域对象（跨多个源位置、带证据与确定性、区分 defined/registered/exposed/unknown），**不扩展**
     `DeclarationKind` 或 `OutlineKind`；通过 R6b 的 `OutlineNode` 接入侧栏。
2. **语义高亮**：作为 R5 的一个新装饰层；可选接入 LSP `semanticTokens`（Exact 目前未请求）。
3. **语义焦点**：向 R4 的 `ReadingPlan` 提供源范围集合。
4. **原地展开与生成注释**：扩展 `ReaderProjection.Segment`，增加带展示实例 ID 的 `excerpt` 与 `generated` 段；
   先定导航、复制、选择三条契约；不得依赖 S8 已否决的段落拆分方案；届时一并处理 Reading Set 的文本内 `…` 省略标记
   （`ReadingSet.swift:393/462`、`ReadingSetView.swift:481`；源码中恰为 `…` 的行会被误判为省略行）。
5. **会话写入移出主线程**：触发条件为实测主线程写入 > 16 ms 或用户报告卡顿；在 R7 的 store 内部改为串行写入器，
   禁止每次写入一个独立 detached task。
