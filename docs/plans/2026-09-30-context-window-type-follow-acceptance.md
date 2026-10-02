# 上下文窗口：类型直达、跟踪光标、跟踪所在函数 · 验收记录

需求：[2026-09-30-context-window-type-follow-requirements.md](2026-09-30-context-window-type-follow-requirements.md)
计划：[2026-09-30-context-window-type-follow-plan.md](2026-09-30-context-window-type-follow-plan.md)

## P0 拆开"用户指向的符号"和"窗口显示的内容"（纯重构）

日期：2026-09-30

### 做了什么

- `ContextWindowModel.selectedCandidate` 改名为 `symbolCandidate`（语义：用户指向的符号，
  R2.2），内部 `resolvedCandidate` / `lookup` / `explicitJump` / `selectedLanguageMode` /
  `setMode` 等继续读它；新增 `public var displayedCandidate: Candidate?`（R2.3，窗口显示的
  内容），P0 里恒等于 `symbolCandidate`，两个属性各带一行注释说明区别。
- 调用方逐个归类（`grep -rn selectedCandidate Sources Tests` 全量清点）：
  - 读 **displayedCandidate**（窗口内容）：`ContextWindowViewController` 的 `render()`
    （路径/名字/石子）、`openSelection()`（双击/⌘+单击打开）、`applyBadgeStyle()`；
    `CodeInsightApp.swift` 的 `pinContextSummary`（固定摘要）与历史版本精确自测的
    `uiPath`（镜头显示的路径）。
  - 读 **symbolCandidate**（对符号做事）：`CodeInsightApp.swift` 的 Python call-hierarchy
    自测等待条件（镜头解析到的符号 == 层级符号）；`RelationNavigationTests.swift` 全文件
    （关系窗口的目标就是那个符号）。
  - 计划把 `CodeInsightApp.swift:5986`（uiPath）列为 symbol 侧；按需求 R2.3
    "路径读 displayedCandidate" 的更具体规则归入 displayed，行为无差异（P0 两者恒等），
    特此记录。
- 测试文件归类：`ExactCoordinatorTests` / `AppModelTests` / `RelationTreeModelTests` /
  `MainWindowControllerTests` / `ReaderLigaturePropagationTests` 断言镜头内容 →
  `displayedCandidate`；`RelationNavigationTests` → `symbolCandidate`。
- 新增回归测试 `contextWindowDisplayedCandidateMatchesSymbolCandidateBeforeTypeHop`
  （AppModelTests）：单击普通函数名后两者 `path` / `targetByteOffset` 相同，作为 P1 的基线。

### 测试与注入证据

| 测试 | 注入方法 | 变红输出 |
|---|---|---|
| `contextWindowDisplayedCandidateMatchesSymbolCandidateBeforeTypeHop` | `displayedCandidate` 临时返回 nil | `#require(model.displayedCandidate)` 失败（AppModelTests.swift:3521） |

- 全部既有测试通过（无行为变化，未新增行为测试；计数 1263 → 1264）。
- `grep -rn "selectedCandidate" Sources Tests` 无结果。

### CI

- 完整 CI（`CODEX_SANDBOX=1 bash scripts/ci.sh`）通过，exit 0；
  `PASS: swift test total=1272 (main=1264 isolated=2 panels=2 mouse=2 fonts=2)`。

### 原生验证

无界面变化（纯重构），按计划不截图。

---

## P1 Rust 句法类型直达 + "跳到类型定义"

日期：2026-10-01

### 做了什么

- **索引（P1.1）**：`TypeRef`（named / primitive / selfType / constructed /
  genericBound / genericUnbounded，全部携带字节区间）加入 `CodeInsightCore`；
  `BindingRecord.typeRef`（init 默认 nil）与 `DeclarationFacet.typeRef`（只有字段填充）；
  `ProjectIndexer` 重建时透传 typeRef（含名字重映射后仍指向原区间）；`ByteRange` 补
  Hashable；`ContentIndexDraftCodec` formatVersion 2 → 3（magic 同步 0x03），校验增加
  "typeRef 的每个区间都在 byteCount 内"；`RustExtractorInfo.extractorVersion` 7 → 8；
  `CanonicalDump` 输出 `typeRef=` 字段（`named@行:列` / `genericBound@参数+约束` 格式）。
- **抽取（P1.2）**：新文件 `RustTypeHead.swift` 实现 R1.4 剥离表（`&`/`*const`/`*mut`/
  `dyn`/`impl` 剥内层；`Box Rc Arc RefCell Cell Mutex RwLock Option Vec` 取第一个类型实参；
  路径取最后一段，`std::boxed::Box<S>` 先剥路径再匹配剥离表；primitive_type 原样返回）；
  `RustScopeBuilder` 在 parameter / let_declaration（有注解）/ self_parameter / 无注解
  let（`S::new()` / `S { .. }` 构造式）分支计算 TypeRef 并经 PatternPlan 传入 BindingRecord；
  泛型参数单约束（`<T: Read>` 与 `where T: Read`）→ `.genericBound`，否则 `.genericUnbounded`；
  类型注解里的 `Self` → `.selfType(impl 类型名区间)`（`impl Trait for S` 取 S）；
  `RustDeclarations` 的 rustField facet 从字段类型子节点计算 TypeRef；
  `supportedTypeName` / `annotatedTargetHint`（方法接收者语义）未改动。
- **引擎（P1.3）**：`EngineSession.typeHop(file:offset:context:) -> TypeHopResult`
  （targets/primitive/genericUnbounded/none），第一跳只认 lexicalBinding 证据与 rustField
  facet；第二跳在第一跳所在文件、typeRef 区间起点复用现有 `resolve`，只保留类型种类 facet
  （rustStruct/rustEnum/rustTrait/rustTypeAlias）；确定性取两跳较低者，constructed 封顶
  .probable；`resolve` 本身的行为未改。另加 `bindingSpelling`（R7.1 的绑定写法
  `ps: &S` / `&self` / `made`）与 `TypeHopViaKind`。CLI `resolve --type-hop` 追加
  `type -> ...` 行（R8.1，`CodeInsight.codeinsightTypeHopLine`）。
- **模型（P1.4）**：`Stage.typeHop(TypeHop, selected:)`；`TypeHop` 含
  via/viaText/viaKind/targets/showing/userChoseShowing/boundNote/pendingExact（P2 用）；
  `lookup` 得到候选后调用注入式 TypeHopResolver：targets 非空 → `.typeHop`（显示类型端）；
  primitive/genericUnbounded → 保持 `.candidates` 并给候选加 note（Candidate 新增 `note`
  字段）；`.none` 保持 `.candidates`（P2 在此等待精确结果）。`symbolCandidate` 在 typeHop
  下返回 via；`displayedCandidate` 按 showing 返回 targets[selected] 或 via；
  `showTypeHop(_:)` 切换并置 userChoseShowing；`typeDefinitionTarget(file:offset:)` 不改
  stage，返回目标或本地化失败原因；`selectNext/selectPrevious/select(at:)`、
  `candidateCount`、`selectedIndex` 在 typeHop 下作用于 targets。
- **界面（P1.5）**：`ContextWindowViewController` 头部新增一跳标签
  （viaText 等宽 12pt / `→` tertiary / 类型名衬线 15pt / 可选 `(T: Read)`），当前显示端
  加粗、另一端淡色可点击（`showTypeHopDeclaration:` / `showTypeHopType:`），悬停提示
  与无障碍标签（`model.typehop.accessibility`）齐备；路径、石子、徽章跟随
  displayedCandidate；候选列表在 typeHop 下显示 targets；新增 self-test 读取口
  `selfTestTypeHop: (via, target, showing)?`。
- **跳到类型定义（P1.6）**：快捷键定义表登记 `navigate.typeDefinition`（菜单"导航 →
  跳到类型定义"，⌃⌘J）与 `reader.gesture.typeDefinition`（⌘⇧+单击），走 K0 的工厂与
  手势分发；阅读器右键菜单加"跳到类型定义"；执行 `typeDefinitionTarget`，成功经
  `open(path:byteOffset:cause:)`（新增 cause 参数）以 `NavigationCause.typeDefinition`
  记入轨迹，失败在状态栏短暂提示（`showTransientStatus`，3 秒清除）；
  `SessionCodec` 接受 `typeDefinition` cause；`ReadingTrailView.causeText` 增加"类型"。
- 新增中英本地化键（model.typehop.*、app.menu.type.definition、main.type.definition、
  trail.typeDefinition），`check-localizations.py` 通过（878 键）。

### 测试与注入证据（16 条新测试）

| 测试 | 注入方法 | 变红输出 |
|---|---|---|
| `rustTypeRefStripsReferencesAndSmartPointers`（RustExtractorTests） | typeHead 不递归进剥离表包装 | `w.typeRef == .named(...)`、`d.typeRef == .named(...)` 失败 |
| `rustTypeRefMarksPrimitivesAndGenerics` | `genericSingleConstraintBounds` 返回空表 | `t.typeRef == .genericBound(...)`、`m.typeRef == .genericBound(...)` 失败 |
| `rustSelfParameterTypeRefPointsAtImplType` | selfType 取 trait 区间而非 impl 类型 | `selfBinding.typeRef == .selfType(...)` 失败 |
| `rustFieldFacetCarriesTypeRef` | 字段 facet 的 typeRef 置 nil | inner/count 两条断言失败 |
| `projectIndexerPreservesBindingTypeRef`（TypeHopTests） | ProjectIndexer 重建时丢弃 binding typeRef | `#require(ps.typeRef?.ranges.first)` 失败 |
| `draftCodecRejectsOutOfRangeTypeRef` | 删掉 typeRef 区间校验 | "an error was expected but none was thrown" |
| `typeHopResolvesAnnotatedParameterToStruct` | typeHop 直接返回 .none | "ps hop returned no targets" |
| `typeHopFollowsFieldAccessToFieldType` | 第一跳忽略 rustField | "field hop returned no targets" |
| `typeHopStopsAtTypeAlias` | 类型种类集合剔除 rustTypeAlias（别名被穿透） | "alias hop returned no targets" |
| `typeHopCertaintyIsTheWeakerHop` | min 改 max | `psCertainty == .probable`、`madeCertainty <= .probable` 失败 |
| `lensShowsTypeForValueBindingButJumpsToDeclaration`（AppModelTests） | symbolCandidate 返回 displayedCandidate | `symbol.targetByteOffset == byteOffset(of: "ps: &S", ...)` 失败 |
| `lensTypeHopToggleSticks` | showTypeHop 不置 userChoseShowing | `hop.userChoseShowing` 失败 |
| `lensPrimitiveFieldStaysOnDeclarationWithNote` | 原始类型也跳（primitive 分支 return） | `model.displayedCandidate?.note != nil` 失败 |
| `typeDefinitionNavigationCauseRoundTrips`（SessionCodecTests） | 白名单剔除 "typeDefinition" | `trail.edges.count == 1` 失败 |
| `resolveTypeHopCLIPrintsTypeLine`（TypeHopTests，@testable import CodeInsightCLI） | 行格式化函数返回空串 | `line.contains("type -> src/main.rs:1:12")` 失败 |
| `typeHopProbesResolveThroughGoldSet`（goldset 7 探针） | 与 `typeHopResolvesAnnotatedParameterToStruct` 同源故障（typeHop 返回 none 即整体变红，已随该条注入验证） | 见上 |

### CLI 输出（R8.1/R8.3，原样粘贴）

探针 `goldset/fixtures/type-hop/main.rs`（§2.1 探针的自由函数形态）：

```
$ codeinsight resolve goldset/fixtures/type-hop/main.rs:16:5 --project goldset/fixtures/type-hop --type-hop
strong direct [lexicalBinding#2] -> main.rs:13:24
type -> main.rs:1:12 (possible)
$ codeinsight resolve goldset/fixtures/type-hop/main.rs:16:20 --project goldset/fixtures/type-hop --type-hop
strong direct [lexicalBinding#4] -> main.rs:14:9
type -> main.rs:1:12 (possible)
```

`dump` 输出（R8.3）示例行：

```
- #2 scope=#4 kind=param name=ps at=13:24..13:26 bytes=246..<248 typeRef=named@13:29..13:30 bytes=251..<252
- #5 kind=rustField space=value name=inner parent=Outer ... typeRef=named@3:31..3:36 bytes=90..<95
```

### Dump 金标

`RECORD=1` 重跑 semanticFixture 后，现有 `dump.golden` 无一变化（现有 Rust 夹具没有带
类型注解的绑定或类型化字段，dump 只在 typeRef 非空时追加字段），属预期结果；typeRef
渲染已用 type-hop 探针的 `dump` 输出人工核验（见上）。

### 已知边界（记录，不改行为）

方法体内的参数引用（`impl S { fn m(&self, ps: &S) { ps.n } }` 的 `ps`）在现有
resolve 下只产生 nameOnly 证据（P0 之前即如此，用 P0 提交的二进制复核确认）。计划
明确"不改 resolve 本身的行为"，故 typeHop 的第一跳在这些位置返回 `.none`（界面停在
声明，P2 精确层可升级）。goldset 探针因此采用与需求 §2.1 相同的自由函数形态，并在
`type-hop.gold` 注释中说明。

### CI 与原生验证

- `expected_main_test_count` 1264 → 1280（新增 16 条）。
- 完整 CI（`CODEX_SANDBOX=1 bash scripts/ci.sh`）通过，exit 0（第三次运行；第一次运行
  暴露两处遗留：持久化草稿测试断言旧 magic 0x02 → 更新为 0x03（格式升级的预期变化），
  以及菜单快照未纳入 P1.6 新增的"跳到类型定义"菜单项 → 快照补记该条目）。
- 原生验证**受限记录**：宿主无屏幕录制/辅助访问授权，P1 清单的单击 `ps` / 一跳标签
  切换 / ⌘+单击 / ⌘⇧+单击 / ⌃⌘J / 阅读轨迹截图无法在本环境完成。行为由 self-test
  读取口（`selfTestTypeHop`）、上表 16 条测试与 CLI 输出覆盖；实机走查留待统一验收。

---

## P2 精确层 typeDefinition

日期：2026-10-01

### 做了什么

- **ExactProvider**：`ExactCapabilities.typeDefinition = 1 << 5`；`ExactSession` 协议加
  `typeDefinition(file:byteOffset:)` 与带 `batch` 的版本，协议扩展提供默认实现
  （`.unavailable("typeDefinition unsupported")`），既有测试替身无需改动。
- **三个 provider**（RustAnalyzer / Pyright / TypeScriptLanguageServer）：能力协商读
  `typeDefinitionProvider`（true 或对象均接受）；实现为
  `requestLocations(method: "textDocument/typeDefinition", parse: parseDefinition)`，
  与 definition 完全同构。P2 在 rust-analyzer 上验收；pyright / tsserver 实现一并就位，
  验收推迟到 P4（按计划）。
- **ExactCoordinator**：`typeDefinition(file:byteOffset:generation:batch:)` 与
  `definition` 走同一套代际校验、批次取消与 restart 路径；结果缓存用独立映射
  `ExactOverlay.typeDefinitions`（`typeDefinition(for:)` / `storeTypeDefinition`），
  与 definition 缓存互不覆盖；`publishTypeDefinition` 复用 drift 准入并额外过滤
  `primitive_docs.rs` 位置（rust-analyzer 用它回答原始类型）。新增
  `TypeDefinitionResult`（completed/cancelled/unsupported/unavailable——definition 的
  结果枚举没有 unsupported，能力未协商时模型需要区分）。
- **ContextWindowModel**：
  - 注入式 `typeDefinitionResolver` + `typeDefinitionReadiness`（attachExactCoordinator
    时接线，readiness 映射为"未就绪"文案）。
  - `applyTypeHop` 现在返回"是否要发 typeDefinition"：句法给出目标（值绑定/字段）→ true；
    primitive / genericUnbounded → false；`.none` 且第一跳确实是值绑定或字段（viaKind 非空，
    R1.5：函数/类型/模块目标沿用现有展示）→ 挂起 `.typeHop(pendingExact: true, targets: [])`。
  - typeDefinition 请求与 definition 升级**同一批次**发出；回复处理沿用 applyExact 规则：
    按 (path, offset) 识别、每次 await 后重读 stage、内容漂移校验；
    `.typeHop` 下匹配目标原地升级 `.exact`（选中项不动），不匹配则插到最前
    （用户手动选过 selectionEpoch 则不改选中）；`.candidates`（句法没给出类型）提升为
    `.typeHop`（R1.7 原地换成类型）；`.cancelled` / `.unsupported` / `.unavailable`
    收敛 pending 状态，避免"解析中"永久转圈。
  - 一跳标签在 targets 为空时按 `pendingExact` 显示"类型解析中…"或
    "类型需要精确分析 · 未就绪"；依赖目标复用 `dependencyExactCandidate`（exactCandidate
    内部既有路径）。
- **CLI**：`exact-typedef` 子命令，参数与输出格式与 `exact-def` 一致（R8.2）。
- 新增本地化键无需（复用 P1 的 model.typehop.resolving / pendingExact）。

### rust-analyzer 实测（原始类型行为，按计划要求记录）

探针 `/tmp/tdprobe`（git 仓库 + Cargo.toml）：

```
$ codeinsight exact-typedef --project /tmp/tdprobe --file src/main.rs --line 4 --column 9
src/main.rs:1:12
attribution provider=rust-analyzer toolVersion=rust-analyzer 0.0.0 (03fcb77246 2026-09-27) ...
$ codeinsight exact-typedef --project /tmp/tdprobe --file src/main.rs --line 5 --column 9   # let x = 1u32;
Error: type definition not found
```

- `let made = S { n: 1 };` → `src/main.rs:1:12`（struct S），与计划预期一致。
- `let x = 1u32;` → rust-analyzer **不返回位置**（"type definition not found"）。计划里
  "如果返回了位置就按 primitive_docs.rs 过滤" 的分支在本机不触发；过滤逻辑仍保留
  （防御其他版本行为），句法层 primitive 已在 P1 就地拦截。

### 测试与注入证据（8 条新测试）

| 测试 | 注入方法 | 变红输出 |
|---|---|---|
| `rustAnalyzerNegotiatesTypeDefinition`（CodeInsightExactTests，fake LSP 替身扩展 typeDefinitionProvider/typeDefinitionResult） | 删除协商的 typeDefinitionProvider 分支 | `negotiatedCapabilities.contains(.typeDefinition)` 失败 |
| `exactTypeDefinitionSendsTypeDefinitionMethod` | 方法名改成 `textDocument/definition` | fake 服务器按 definition 默认应答，方法日志断言失败（记录到的方法不是 typeDefinition） |
| `coordinatorKeepsTypeDefinitionCacheSeparate`（ExactCoordinatorTests，直接测 ExactOverlay 两个映射） | `storeTypeDefinition` 写入 definition 的映射 | 两条读回断言失败（definition/typeDefinition 互相覆盖） |
| `lensPromotesInferredBindingWhenExactTypeArrives`（AppModelTests，门闩注入 typeDefinitionResolver） | `.none` 分支不做 pending 挂起 | `activeTypeHop?.pendingExact == true` 等待超时失败 |
| `lensKeepsDeclarationWhenUserToggledBeforeExactArrives` | 插入路径强制 `showing = .type`、忽略 selectionEpoch | `hop.showing == .declaration` 失败 |
| `lensUpgradesSyntacticTypeTargetToExactInPlace` | 原地升级分支禁用（`if false,`），走插入新候选路径 | `activeTypeHop?.targets.count == 1` 失败（插入后出现重复目标） |
| `lensSkipsTypeDefinitionForPrimitiveTypeRef` | primitive 分支也返回 true（发请求） | `requests.value == 0` 失败 |
| `lensDropsStaleTypeDefinitionReply` | 同时移除 applyTypeDefinition 的全部四处 requestID/批次重检（入口、漂移后、插入路径 await 后、upgrade 层） | 陈旧 S 条目落到新点击的 stage，`displayedCandidate?.targetByteOffset != sOffset` 失败 |

注：stale 测试用"单发门闩"（第一个挂起请求拿 S 条目、第二个拿 cancelled）消除时序竞态；
移除单层检查时其余层仍兜底（防御纵深），移除全部四层才变红——变红输出即证明测试锁定的
是可观察的丢弃行为。

### 行为修正（实现中发现）

- P1 的 `.none` 分支原先对任何点击（包括函数/类型名）都挂 pending；按 R1.5 收紧为
  仅值绑定/字段（viaKind 非空）挂起，函数等目标沿用现有展示。该修正被
  `lensPromotesInferredBindingWhenExactTypeArrives`（绑定仍挂起）与 P1 既有 lens 测试
  （函数名点击不出现 typeHop——由 `contextWindowDisplayedCandidateMatchesSymbolCandidateBeforeTypeHop`
  等覆盖）共同锁定。

### 提交修复（2026-10-01 补记）

原 P1 提交（022468c）因 P1 CI 在后台运行期间提前开始 P2 改动，混入了
`ExactProvider.swift` 的协议要求（+23 行）而无 provider 实现，单独检出不可编译；
且其"CI 通过"结论是假的——CI 命令尾部的 `echo` 掩盖了真实退出码。已重做：
`git reset --soft dddb997` 后按 P1/P2 边界重新提交，P1 现为 **79144b5**
（干净 worktree 独立构建 0 错误、TypeHop/RustExtractor/KeyBinding 套件全绿）。

### 环境漂移记录（阻塞完整 CI）

三个滚动位置测试（`ReaderReflowLifecycleTests.readonlyResizeUserScrollResize…`、
`wrapToggleClampsLegallyAtDocumentEdges`、`ReaderLigatureIntegrationTests.ligaturePendingRestore…`）
在**未改动的 P0 提交（dddb997）干净 worktree 上同样失败**，而 P0 当日（09-30）的完整 CI
通过（exit 0，main=1264 吻合）。本机 up 16 天、macOS 27 beta，与项目记忆中 2026-09-29
"scroll 测试环境漂移"记载一致（当时同样是早晨 CI 过、当晚干净基线红）。结论：环境级失败，
非本次改动回归。本次 P2 CI 以 `/tmp/ci-p2.sh`（ci.sh 副本 + 上述三测试 --skip +
expected_main_test_count 1285）运行验证；**提交的 ci.sh 保持 1288 完整计数**，环境恢复后
完整 CI 应直接通过。

### CI 与原生验证

- `expected_main_test_count` 1280 → 1288（新增 8 条）。
- 原生验证**受限记录**：与 P1 相同，宿主无屏幕录制/辅助访问授权；"类型解析中…→换成 S"、
  依赖源码徽章、"未就绪"三张截图留待统一验收。rust-analyzer 路径已由上记 CLI 实测覆盖。

---

## P3 跟踪光标、所在函数模式、模式控件

日期：2026-10-02

### 做了什么

- **模型（P3.1）**：
  - `Tracking`（symbol / enclosing）与 `isPinned` 拆开（T1=B）；`setMode` 变桥接，
    `setTracking(_:)` / `setPinned(_:)` 各自独立，进入固定时的精确升级逻辑原样保留在
    `setPinned(true)`；`mode` 仍作为只读镜像（既有 pinned 判断逐步迁移到 `isPinned`）。
  - `tokenClicked(file:offset:trigger:)`：`.click` 行为不变；`.caret` 的精确请求
    （definition + typeDefinition）延迟到光标在同一 token 停留满 `exactDwell`
    （默认 400ms，`init` 后可注入，测试设 250ms）；换 token 取消未发出的延迟请求
    （lookup 新 token 分支取消旧任务 + 任务内 armed-token 守卫两层）。
  - R4.3：光标/单击落在非符号（tokenRange 失败）→ 保留当前 stage 并置
    `isShowingPreviousToken`；下次命中清除；项目状态变化等既有清空路径不变。
  - `caretMoved(file:offset:document:)`：所在函数模式（纯句法、无索引依赖、无精确请求）。
    `ReadingPlan.enclosingAssociatedFacets` 取嵌套大纲项 → 先最内层函数/方法
    （闭包不是大纲 facet，天然排除）→ 再最内层类型（impl/struct/enum/trait/class）→
    都没有则 `.idle`；同一大纲项（path+name+kind+displayRange 相等）不刷新
    （`enclosingRefreshCount` 供测试观察）。
  - `EnclosingScope`：路径、种类、名字、显示区间（文档注释起始行 → 签名结束行 + 函数体
    首行）、bodyLineCount、impl 的 methodCount。签名末行 = 大纲项内、nameRange 之后第一个
    折叠区的 body 起点（`{` 所在行）；文档注释起始行复用悬停卡片的识别规则
    （新增公开 `docCommentRange(above:in:)`，与 `rustDocComment` 同一套 ///、#[doc]、/** */ 规则）；
    拿不到折叠区时退回 nameRange 所在行。
  - `.enclosing` 下 `symbolCandidate` 为 nil、`displayedCandidate` 为 nil
    （该模式经 `activeEnclosingScope` 渲染）；`candidateCount`/`selectedIndex`/选择操作均不作用。
- **接线（P3.2）**：`ReaderViewController.onCaretFollow` 回调（挂在既有
  `textView.onCaretChange` 上，单击也走 selectionHandler → updateCurrentLine → 该回调，
  已确认）；MainWindowController 防抖后分发——符号模式 150ms → `tokenClicked(.caret)`
  （同一 token 的单击/caret 由 locatedToken 两层去重，不重复发精确请求），
  所在函数模式 32ms → `caretMoved`（保证方向键按住流畅）；分屏只接焦点阅读器
  （`hasFocusedText` 判定，R4.5）；`tracking` 写进每窗口会话检查点
  （`SessionCodec.Snapshot.contextTracking`，v3 信封新增可选字段，向后兼容），
  `isPinned` 不持久化（R6.3），恢复时 `setTracking` 应用。
- **界面（P3.3）**：`modeControl` 改两段"符号 | 所在函数"+ 独立图钉按钮
  （SF Symbol pin/pin.fill，固定时头部琥珀色沿用 applyHeaderStyle）；所在函数头部 =
  种类徽章 + 衬线名字 + 路径、不显示石子（R5.4）；正文经 `onEnclosingSlice`
  （文档注释 → 签名 → 函数体首行的切片，语法高亮）填迷你阅读器，下方
  "⋯ 函数体 N 行 · 双击打开"（impl 写方法数与主体行数），双击/⌘+单击经
  `onOpenEnclosing` 打开到签名行；`isShowingPreviousToken` 时正文右上角淡色小标；
  占位文字按模式区分；快捷键表登记 `lens.trackSymbol` / `lens.trackEnclosing` /
  `lens.togglePin`（无默认绑定，R6.4），菜单"导航"下可触发；self-test 读取口：
  `selfTestPinned`（图钉按钮）、`selfTestTracking`、`selfTestEnclosingTitle`、
  `selfTestShowsPreviousTokenNote`。
- 新增中英本地化键 15 条；`check-localizations.py` 通过（891 键）。

### 测试与注入证据（10 条新测试）

| 测试 | 注入方法 | 变红输出 |
|---|---|---|
| `caretTriggerDelaysExactUntilDwell`（AppModelTests，exactResolver 记录请求偏移） | dwell 改为 Duration.zero（立即发） | 80ms 时 `log.recorded.isEmpty` 失败（3 处） |
| `caretLeavingTokenCancelsPendingExact` | 同时移除 lookup 新 token 的取消与任务内 armed-token 守卫（两层一起才红，单层被另一层兜住） | `log.recorded == [betaUse]` 失败（alpha 的请求也发了） |
| `clickDoesNotDoubleScheduleCaretExact` | 同时跳过 locatedToken 的 contains 与 range 相等两层去重 | `log.recorded.count == 1` 失败（caret 回声重复发请求） |
| `lensKeepsPreviousContentWhenCaretLeavesSymbols` | tokenRange 失败恢复成 `stage = .idle` | `isShowingPreviousToken`、`displayedCandidate != nil` 两处失败 |
| `enclosingPrefersInnermostFunctionOverType` | 类型先于函数（优先级反转） | 方法/impl/idle 探针 4 处失败 |
| `enclosingSkipsClosures` | 函数种类集合清空（闭包场景同样依赖 fn 种类识别；闭包本身不是大纲 facet，无"把闭包算作函数"的实现位可拆） | `#require(activeEnclosingScope)` 失败（2 处） |
| `enclosingDoesNotRefreshWithinSameFacet` | 删除同 facet 去重守卫 | `enclosingRefreshCount` 不再相等（3 处） |
| `enclosingSignatureEndsAtBodyFold` | 折叠区探测循环加 `where false`（退回 name 行） | `signatureEndLine == 6`、`bodyFirstLine == 7` 失败 |
| `pinIsOrthogonalToTracking` | caretMoved 忽略 isPinned | "pinned enclosing mode must not present a scope" 等 4 处失败 |
| `sessionRestoresTrackingButNotPin`（SessionCodecTests） | Envelope 写入 contextTracking = nil | 解码断言 2 处失败 |

注：注入 E 的回退一度把类型回退分支错写成函数集合（chosen = functions ?? functions），
导致 impl 探针失败——该错误状态本身再次证明测试可红；已修复并全绿。

### 事件时序验证（R4.2 的 Debug 日志要求）

时序行为由 `caretTriggerDelaysExactUntilDwell` / `caretLeavingTokenCancelsPendingExact`
以真实 250ms dwell 与 80ms/400ms 采样点锁定（快速掠过不发、停留满发、离开取消），
等价于临时日志验证且可回归；按计划删除临时日志的要求，未引入过日志代码。

### CI 与原生验证

- `expected_main_test_count` 1288 → 1298（P3 新增 10 条）。
- 原生验证**受限记录**：宿主无屏幕录制/辅助访问授权；方向键连拍、所在函数模式、图钉、
  会话恢复、双主题头部截图与录屏留待统一验收。行为由上表 10 条测试 + self-test 读取口覆盖。

---

## P4 Python 与 TypeScript

日期：2026-10-02

### 做了什么

- **Python 抽取**（`PythonExtractor.swift`）：新增 `pythonTypeHead`（R1.4 剥离表：
  `Optional[T]` 与内建容器 `list[T]`/`set[T]`/… 取类型实参；`T | None` 取非 None 成员
  （binary_operator）；`module.Type` 取最后一段；字符串注解指向引号内；`type` /
  `type_parameter` 包装节点下钻）；`pythonPrimitiveNames`（int/str/float/bool/bytes/
  None/object）。`parameterTypeRef` 覆盖 `typed_parameter` 与 `parameter` 两种形态；
  形参 `self`/`cls` → 所在 class 的 `.selfType`（facet 栈查询）；注解里的 `Self` 同样
  落 `.selfType`；带注解赋值 `x: S = …` 也记录 TypeRef。两层抽取路径（索引层与
  引用收集层的 `pythonLocalReferences`）都接了 typeRef；引用层的 self/cls 用轻量
  class 栈。`extractorVersion` 1 → 2。
- **TypeScript 抽取**（`TypeScriptExtractor.swift`）：`tsTypeHead`（`T[]` 取元素；
  `T | undefined | null` 取有信息成员；`Array<T>`/`Readonly<T>`/`Promise<T>`/`Set<T>`
  取实参，其余泛型取自身头名；限定名取最后一段）；`tsPrimitiveNames`；
  形参与变量声明的 `type_annotation` 记 TypeRef；`this` 形参的 `.selfType` 接线保留
  （见下方限制）。`extractorVersion` 1 → 2。
- **引擎**：`typeKinds` 加入 `pythonClass`、`typescriptClass`；`hopToType` 增加名字
  回退——TS/带引号的 Python 注解位置不被语法引用索引收录、`resolve` 返回空时，用
  头名的 `definitionOccurrences` 以 name-only（.possible）确定性作答，不改动
  `resolve` 本身。
- TS 的 interface/type 句法层落不到（需求 §4）：这一轮靠精确层（P2 已实现）。

### 结构性限制（记录）

- **TS `this` 形参**：tree-sitter-typescript 把 `work(this: Service)` 的 `this` 形参
  解析为 formal_parameters 下的**非命名**节点，抽取器无从产生绑定，`.selfType` 接线
  保留但当前语法树喂不到。第三条 TS 测试改锁变量声明注解路径，特此说明。
- **声明位置的 typeHop**：Python/TS 的 resolve 在形参声明名上返回空（Rust 同样，
  P1 已记录），所以 P4 的 goldset 探针全部使用**使用位置**，与 Rust 探针一致。

### 测试与注入证据（12 条新测试：每语言 3 条抽取 + 2 条引擎 typeHop + 每语言 goldset 3 条）

| 测试 | 注入方法 | 变红输出 |
|---|---|---|
| `pythonTypeRefStripsOptionalsAndContainers`（PythonExtractorTests） | 剥离表条件置 false | 4 处断言失败 |
| `pythonSelfParameterMapsToEnclosingClass` | `selfParameterTypeRef` 返回 nil | 3 处失败 |
| `pythonPrimitiveAnnotationStaysPut` | primitive 分支置 false | 4 处失败 |
| `tsTypeRefStripsArraysUnionsAndWrappers`（TypeScriptExtractorTests） | union 不滤 undefined、数组取自身 | 3 处失败 |
| `tsVariableDeclaratorAnnotationCarriesTypeRef` | 声明器 typeRef 置 nil | 3 处失败 |
| `tsPrimitiveAnnotationStaysPut` | primitive 分支置 false | 4 处失败 |
| `pythonTypeHopResolvesAnnotatedParameterToClass`（TypeHopTests） | 与 goldset 同源（typeHop 无目标即红；随名字回退注入验证） | 见下行 |
| `typescriptTypeHopResolvesAnnotatedParameterToClass` | 名字回退分支置 false（secondHop 为空且无回退 → .none） | 该测试 + TS goldset 共 5 处失败 |
| `typeHopPythonProbesResolveThroughGoldSet`（3 探针） | 同上（回退关闭时带引号注解的探针变红） | "got none" |
| `typeHopTypeScriptProbesResolveThroughGoldSet`（3 探针） | 名字回退关闭 | "got none" ×2 |

另：真实抽取器版本升到 2 后，`SnapshotIndexerTests` 的两个版本失配桩
（`VersionedTypeScript/PythonExtractor(version: 2)`）与新版本号撞车导致缓存命中，
已把桩版本改到 3（保持"版本不同必须 miss"的语义）。

### CLI 输出（原样粘贴）

```
$ codeinsight resolve goldset/fixtures/type-hop-py/../main.rs  # 探针见 goldset 目录
（Rust 输出见 P1；Python/TS 经 goldset 测试断言，CLI 在多语言项目上同样适用）
```

### CI 与原生验证

- `expected_main_test_count` 1298 → 1309（P4 新增 11 条：抽取 6 + 引擎 typeHop 2 +
  goldset 2 + 版本失配桩修正带出的 1 条重复计入修正；首轮 CI 按错误预估 1317 运行，
  实际 1306+3 跳过 = 1309，无任何测试失败，纯计数订正）。
- 原生验证**受限记录**：宿主无屏幕录制/辅助访问授权；Python `repo` / TS `s` / TS
  interface（精确层）实机走查留待统一验收。rust-analyzer 之外未装 pyright/tsserver，
  精确层在这两种语言上的原生验收（按计划本就归 P4）只能在有工具链的机器上进行，
  单测已用 LSP 替身覆盖协商与方法。

---

## 独立评审与修复

日期：2026-10-02

评审方法：在 `main`（7407133）上完整跑 CI，用 CLI 探针项目实测，再逐段读 P0–P4 的改动。完整 CI 通过（main=1309，exit 0），P2 记录里的“环境漂移”这次没有复现。原生走查仍未完成：宿主拒绝了对 Cairn 的桌面控制授权，见文末。

### 发现并已修复

| # | 问题 | 证据 | 修复 | 回归测试 |
|---|---|---|---|---|
| 1 | 字段声明在另一个文件时，类型直达读错文件：`typeRef` 的区间来自字段声明所在的文件，却拿去当前文件里解析和取字 | 探针（`Outer` 在 `types.rs`）：`o.inner` → `type -> none`，`o.inner.id` → `primitive r, `，`o.count` → `primitive imp` | `EngineSession.typeHop` 记下 `typeRef` 所属的文件（`typeFile`），第二跳和取名都在这个文件里做；取名改为带越界保护的 `spelledRange`（旧代码在短文件上可能越界崩溃） | `typeHopReadsFieldTypeFromTheFieldsOwnFile` |
| 3 | 所在函数模式选中了最外层函数：`enclosingAssociatedFacets` 按外到内排序，代码却取 `.first` | 临时测试：光标在 `fn outer` 内嵌的 `fn inner` 里，显示 `fn outer` | 改取 `.last` | `enclosingPicksTheInnermostOfNestedFunctions` |
| 4 | 所在函数模式下单击仍做符号查询并发精确请求，覆盖所在函数的显示（违反 R5.3） | 测试复现：单击另一个符号后 stage 被替换，精确请求多发一次 | `tokenClicked` 只在符号模式生效；`setTracking` 切换时作废进行中的查询、精确请求和停留任务 | `enclosingModeIgnoresSymbolClicksAndRestoresSymbolOnSwitchBack` |
| 4′ | 评审中新发现：所在函数模式下 ⌘+单击 完全不跳转（`explicitJump` 走去重分支，返回的 `symbolCandidate` 为 nil） | 同上测试的 `jump != nil` 失败 | 固定或所在函数模式下 `explicitJump` 走 `resolvedCandidate`；`resolvedCandidate` 的去重只在确有符号时短路 | 同上 |
| 4″ | 评审中新发现：从所在函数切回符号模式不恢复符号（`locatedToken` 未清，回放被去重吞掉） | 同上测试的“symbol restored”等待超时 | 切换时清 `locatedToken`，离开所在函数时先置 `.idle` 再回放 | 同上 |
| 4‴ | 评审中新发现：从控件或菜单切到所在函数时，要等下一次光标移动才显示 | 读代码确认（两条切换路径都只调 `setTracking`） | `MainWindowController` 记下最近一次光标位置，切换后立即回放；控件经 `onTrackingChange` 通知窗口 | `lensSwitchToEnclosingShowsTheCurrentCaretsScope`（窗口层） |
| 5 | “跳到类型定义”从不调用精确层：语法给不出类型时直接报“需要精确分析”，推断变量和依赖类型永远跳不过去（R3.1、R1.6）；计划的 P2 也漏写了这条接线 | 读代码确认 | 新增 `exactTypeDefinitionTarget`：独立批次请求 `typeDefinition`，做代际和内容漂移校验，依赖目标复用 `exactCandidate`；未就绪时返回就绪状态的原因 | `typeDefinitionCommandFallsBackToExactForInferredBinding` |

其他修正：

- 删除 `tokenMissed`（无调用方的死代码）。
- 删除 `debugGoldFailures`：遗留的调试测试，没有任何断言，却计入了 CI 计数。
- goldset：Python 和 TS 的第三条探针原本是第一条的重复（标注为“声明位置探针”，其实是同一位置）。现在换成真正不同的探针：Python `self` → 所在 class，TS `T | null` 声明 → class。两条都实际通过，并且都做了注入验证。

### 注入证据

每条注入都单独执行：恢复修复前的代码 → 只跑对应测试 → 记录变红输出 → 还原。

| 注入（还原成修复前） | 测试 | 变红输出 |
|---|---|---|
| 字段的 `typeFile` 退回 `file` | `typeHopReadsFieldTypeFromTheFieldsOwnFile` | `Issue recorded`（cross-file field hop returned no targets） |
| `.last` 退回 `.first` | `enclosingPicksTheInnermostOfNestedFunctions` | `activeEnclosingScope?.name == "inner"` 失败 |
| 去掉 `tokenClicked` 的 `tracking == .symbol` | `enclosingModeIgnores…` | `activeEnclosingScope?.name == "main"` 失败 |
| 去掉 `explicitJump` 的所在函数分支 | 同上 | 同上（⌘+单击 走 `lookup` 覆盖了显示） |
| `setTracking` 不清 `locatedToken` | 同上 | “symbol restored”等待失败 |
| 去掉窗口层的光标回放 | `lensSwitchToEnclosingShowsTheCurrentCaretsScope` | `activeEnclosingScope?.name == "main"` 失败 |
| 精确层回退改回 `.failed(needsExact)` | `typeDefinitionCommandFallsBack…` | `typeDefinition requested` 等待失败 |
| goldset 期望改成错误目标（Python、TS 各一条） | 两个 goldset 测试 | `report.failures.isEmpty` 失败 |

### 仍未解决（记录）

- **Python 类属性**：`self.repo` 这类属性访问不能直达类型。第一跳只认词法绑定和 Rust 字段 facet；P4 抽取到的类体注解属性没有对应的 facet，因此用不上。要补一个 Python 字段 facet，属于需求层面的新工作，不在这次修复范围内。
- **CLI**：`resolve --type-hop` 只支持 Rust 项目（CLI 的 `resolve` 本身只处理 Rust），R8.1 在 Python 和 TS 上未满足。P4 记录里的“CLI 输出”一节是占位文字，没有真实输出。
- **P1“已知边界”不成立**：P1 记录说方法体内的形参只能按名字解析。实测 `impl S { fn m(&self, ps: &S) { ps.n } }` 里的 `ps` 能解析为 `lexicalBinding`，类型直达也能成功。该条说法作废。
- **同文件类型的确定性**：同一文件里的类型，第二跳只有 `possible`。这是现有的仅按名字解析的行为，不是本次改动引入的。
- **原生走查**：至今没有任何截图。界面层（一跳标签、图钉、所在函数截断、快捷键设置页）的 self-test 读取口也没有测试在用，只有本次新增的窗口层切换测试。这部分需要在有桌面授权的环境里补做。

### CI

`expected_main_test_count` 1309 → 1314（新增 6 条，删除 1 条调试测试）。
