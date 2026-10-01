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
