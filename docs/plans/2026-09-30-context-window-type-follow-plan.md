# 上下文窗口：类型直达、跟踪光标、跟踪所在函数（实施计划）

日期：2026-09-30
需求：[2026-09-30-context-window-type-follow-requirements.md](2026-09-30-context-window-type-follow-requirements.md)（下文 `R*` 指需求编号）
原型：[evidence/context-window-type-follow/lens-type-hop.html](evidence/context-window-type-follow/lens-type-hop.html)
前置：[快捷键 K0](2026-09-30-keybindings-plan.md) 必须先合入

每个阶段是一份自包含的任务说明，可以单独交给一个实现 Agent。按顺序做：**K0 → P0 → P1 → P2 → P3 → P4**。后一阶段依赖前一阶段已合入 main。

## 0. 所有阶段通用的规则

- **读这些再动手**：`AGENTS.md`、需求文档、原型页面（用浏览器打开，右侧场景按钮能直接演示每条行为）。
- **分支与提交**：每阶段一个分支，例如 `feat/lens-type-hop-p1`。提交信息用英文，简洁，沿用历史风格（`feat(lens): ...`、`fix(exact): ...`）；证据细节写进验收记录，不写进提交信息。同步 main 用 rebase，不用 merge。
- **架构约束**：`CodeInsightCore`、`CodeInsightEngine`、`CodeInsightAppModel`、`CodeInsightReaderCore`、各语言抽取器、`CodeInsightExact` 里禁止 `import AppKit` / `import SwiftUI`，CI 会检查。
- **Swift 版本**：CI 用 Swift 6.1，本机可能是 6.4。本机编译通过不代表 CI 通过。反复踩过的坑：隐式 `CGFloat` 转换、`@MainActor` 隔离、长表达式类型检查超时。拿不准时拆表达式、写明类型。
- **测试**：Swift Testing（`@Test`、`#expect`），名字描述行为。每条新测试都要**单独注入**：把被测逻辑改坏，确认这一条测试变红，再改回来；在验收记录里逐条写下注入方法和变红的输出。只看到“套件变红”不算。
- **CI 计数**：新增或删除测试后，更新 `scripts/ci.sh` 里的 `expected_main_test_count`（当前 1247）。
- **跑 CI**：在仓库工作树里跑 `CODEX_SANDBOX=1 bash scripts/ci.sh`，不要在 `/tmp` 的工作树副本里跑（Exact 测试会报 `invalidPath` 假失败）。只接受带完整测试摘要的结果，退出码本身不算数。
- **原生验收**：界面改动要在打包好的应用里实测并截图：`CAIRN_LIBGIT2=brew bash scripts/make-app.sh`，然后 `open .build/distribution/Cairn.app`。截图必须证明内容**可见**，不能只断言元素存在。截图放 `docs/plans/evidence/context-window-type-follow/<阶段>/`。
- **验收记录**：每阶段在 `docs/plans/2026-09-30-context-window-type-follow-acceptance.md` 追加一节，写明：做了什么、每条测试的注入证据、CLI 输出、截图、跳过了什么以及原因。
- **遇到计划没覆盖的分叉**：停下来问，不要自己拍板。

---

## P0 拆开“用户指向的符号”和“窗口显示的内容”（纯重构）

**覆盖**：R2。**前置**：无（可以和 K0 并行，但合入顺序在 K0 之后）。**行为变化**：无。

### 背景

`ContextWindowModel.selectedCandidate` 现在身兼两职：窗口显示什么，以及导航、关系、悬停作用于哪个符号。`resolvedCandidate` 和 `lookup` 在同一个名字上直接返回 `selectedCandidate`（`ContextWindowModel.swift:453`、`505`、`509`）。P1 让窗口显示类型之后，如果不先拆开，⌘+单击 `ps` 会跳到 `S`。

### 改动

1. `Sources/CodeInsightAppModel/ContextWindowModel.swift`
   - 把 `selectedCandidate` 改名为 `symbolCandidate`（语义：用户指向的符号）。
   - 新增 `public var displayedCandidate: Candidate?`。P0 里它恒等于 `symbolCandidate`，P1 起两者会不同。
   - `resolvedCandidate(file:offset:)`、`lookup(_:)`、`explicitJump(file:offset:)`、`selectedLanguageMode` 继续读或返回 `symbolCandidate`。
2. 调用方逐个归类（用 `grep -rn "selectedCandidate" Sources Tests` 列全）：
   - 读 **`displayedCandidate`**：`ContextWindowViewController` 的渲染和 `openSelection`（`MainWindowController.swift:7088` 起），`MainWindowController.swift:1853` 的“是否有内容”判断，`CodeInsightApp.swift:6859`（self-test 摘要）。
   - 读 **`symbolCandidate`**：`MainWindowController.swift:3772`、`3814`（⌘+单击、关系），`CodeInsightApp.swift:5986`、`7134`、`7192`、`7225–7230`、`8484`（自测里的跳转、关系、层级）。
   - 拿不准的调用方就问自己：它是在“对符号做事”，还是在“显示窗口内容”？前者用 `symbolCandidate`。
3. 在 `ContextWindowModel` 的两个属性上写一行注释说明区别。

### 测试

- 不新增行为测试（没有行为变化）。全部现有测试必须通过。
- 在 `AppModelTests.swift` 增加一条 `contextWindowDisplayedCandidateMatchesSymbolCandidateBeforeTypeHop`：单击一个普通函数名后，两者 `path`/`targetByteOffset` 相同。它在 P1 里作为回归基线。注入：让 `displayedCandidate` 返回 nil → 这条变红。

### 完成定义

- `grep -rn "selectedCandidate" Sources Tests` 无结果。
- `CODEX_SANDBOX=1 bash scripts/ci.sh` 完整通过（计数 +1）。
- 不需要原生截图（无界面变化），验收记录里写明这一点。

---

## P1 Rust 句法类型直达 + “跳到类型定义”

**覆盖**：R1.1–R1.5（Rust 部分）、R1.8、R2.3、R3、R7、R8.1、R8.3。**前置**：K0、P0。

### P1.1 索引：类型引用

1. `Sources/CodeInsightCore/ScopeModel.swift`：新增

   ```swift
   /// Where a binding's or field's type is spelled, already reduced to its
   /// head name (wrappers stripped at extraction time).
   public enum TypeRef: Codable, Hashable, Sendable {
       case named(ByteRange)                       // `S` in `ps: &Box<S>`
       case primitive(ByteRange)                   // `u32`
       case selfType(ByteRange)                    // the impl's / class's type name
       case constructed(ByteRange)                 // `S` in `S::new()` / `S { .. }`
       case genericBound(parameter: ByteRange, bound: ByteRange)
       case genericUnbounded(parameter: ByteRange)
   }
   ```

   给 `BindingRecord` 加 `public let typeRef: TypeRef?`，`init` 参数默认 `nil`，这样现有调用点不用改。
2. `Sources/CodeInsightCore/ContentIndex.swift`：`DeclarationFacet` 同样加 `typeRef: TypeRef? = nil`，只有字段（`rustField`）会填。
3. `Sources/CodeInsightEngine/ProjectIndexer.swift:815`：重建 `BindingRecord` 和 `DeclarationFacet` 时**必须带上 `typeRef`**（它只含字节区间，不需要重映射名字）。漏掉这一步，索引里的数据会悄悄丢失。
4. `Sources/CodeInsightEngine/ContentIndexDraftCodec.swift`：`formatVersion` 2 → 3；校验逻辑（第 82 行附近）增加“`typeRef` 里的每个区间都在 `byteCount` 内”。
5. `Sources/CodeInsightRustExtractor/RustExtractorInfo.swift`：`extractorVersion` 7 → 8。
6. `Sources/CodeInsightEngine/CanonicalDump.swift` 和 CLI `dump`：输出 `typeRef`（R8.3）。受影响的 dump 金标一并更新，并在验收记录里说明是预期变化。

### P1.2 Rust 抽取

`Sources/CodeInsightRustExtractor/RustScopeBuilder.swift`：

- 新增 `typeHead(in type: Node) -> Node?`，按需求 R1.4 的 Rust 剥离表实现：
  - `reference_type`、`pointer_type`：取内部类型。
  - `dynamic_type`、`abstract_type`（`dyn T` / `impl T`）：取 trait 名。
  - `generic_type`：外层名字在剥离表（`Box Rc Arc RefCell Cell Mutex RwLock Option Vec`）里，就递归进第一个类型实参；否则取外层名字本身。
  - `scoped_type_identifier`：取最后一段。
  - `primitive_type`：返回节点，由调用方标为 `.primitive`。
- **不要改** `supportedTypeName` 和 `annotatedTargetHint`，那是方法接收者解析在用的语义（需求 §4）。
- 在 `registerPatterns` 的这些分支里算出 `TypeRef`，经 `PatternPlan` 传到 `BindingRecord(typeRef:)`：
  - `parameter`、`let_declaration`（有 `:` 注解）→ `.named` / `.primitive`。
  - `self_parameter` → `.selfType(impl 类型名的区间)`。需要在 scope 记录里把 `implTypeNameID` 旁边再存一个区间；`impl Trait for S` 取 `S`。
  - 无注解的 `let_declaration`，初始化是 `S::new()` / `S { .. }` → `.constructed`（识别范围同 `constructedTargetHint`）。
  - 头类型是当前作用域的泛型参数名：只有一个约束（`<T: Read>` 或 `where T: Read`）→ `.genericBound`；否则 → `.genericUnbounded`。
  - 只对简单绑定模式记录（与 `targetHint` 相同，`isSimpleBindingPattern`）；解构模式记 `nil`。
- `Sources/CodeInsightRustExtractor/RustDeclarations.swift:77/161`：`rustField` facet 从 `field_declaration` 的 `type` 子节点算 `TypeRef`。
- 类型注解里的 `Self`（`other: &Self`、`-> Self`）按 `.selfType` 处理。

### P1.3 引擎：第二跳查询

`Sources/CodeInsightEngine/EngineSession.swift` 新增一个公开方法（名字可调整，语义不变）：

```swift
public enum TypeHopResult: Sendable {
    case targets([ResolutionCandidate], certainty: Certainty)
    case primitive(name: String)
    case genericUnbounded(name: String)
    case none                         // nothing spelled; Exact may still answer (P2)
}
public func typeHop(file: PathID, offset: UInt32, context: QueryContext) throws -> TypeHopResult
```

- 先按现有 `resolve` 得到第一跳。只处理两种第一跳：`lexicalBinding` 证据的绑定，以及 `rustField` facet。其余返回 `.none`。
- 读第一跳的 `typeRef`：
  - `.named` / `.selfType` / `.constructed` / `.genericBound(bound:)`：在**第一跳所在文件**、该区间起点调用现有 `resolve`，只保留落在类型种类 facet 上的结果（`rustStruct`、`rustEnum`、`rustTrait`、`rustTypeAlias`；P4 再加 `pythonClass`、`typescriptClass`）。
  - `.primitive` → `.primitive(name:)`；`.genericUnbounded` → `.genericUnbounded(name:)`。
- 确定性取两跳较低者；`.constructed` 再封顶到 `.probable`。
- 不改 `resolve` 本身的行为。

CLI（`Sources/CodeInsightCLI/CodeInsightCLI.swift:736` 的 `Resolve`）：加 `--type-hop`，结果后追加 `type -> path:line:col` / `type -> primitive u32` / `type -> generic T` / `type -> none`（R8.1）。

### P1.4 模型

`Sources/CodeInsightAppModel/ContextWindowModel.swift`：

- `Stage` 增加

  ```swift
  case typeHop(TypeHop, selected: Int)
  public struct TypeHop: Sendable {
      public enum Showing: Sendable { case type, declaration }
      public let via: Candidate            // the binding; always symbolCandidate
      public let viaText: String           // `ps: &S`, `&self`, `made`
      public let viaKind: String           // localized: 形参 / 局部变量 / 接收者 / 字段
      public var targets: [Candidate]      // empty while Exact is pending (P2)
      public var showing: Showing
      public var userChoseShowing: Bool    // set once the user toggles; blocks auto-switch
      public var boundNote: String?        // `T: Read`
  }
  ```

- `lookup` 得到候选后：如果第一个候选是值绑定或字段，就调用 `session.typeHop`：
  - `.targets(非空)` → `stage = .typeHop(showing: .type)`。
  - `.primitive` / `.genericUnbounded` → 保持 `.candidates`，给候选加一个说明（例如 `Candidate.note`，供徽章显示“字段 · u32 是原始类型，不跳”“泛型 T”）。
  - `.none` → 保持 `.candidates`（P2 会在这里等精确结果）。
- `symbolCandidate` 在 `.typeHop` 下返回 `via`；`displayedCandidate` 按 `showing` 返回 `targets[selected]` 或 `via`。
- 新增 `public func showTypeHop(_ showing: TypeHop.Showing)`：切换显示端并置 `userChoseShowing = true`。
- 新增 `public func typeDefinitionTarget(file:offset:) async -> TypeTargetResult`：不改变 `stage`，供“跳到类型定义”命令使用。返回目标候选，或者带原因的失败（原始类型 / 泛型无约束 / 没有类型 / 需要精确分析）。
- `selectNext / selectPrevious / select(at:)` 在 `.typeHop` 下作用于 `targets`。

### P1.5 界面：一跳标签（R7）

`ContextWindowViewController`（`MainWindowController.swift:7088` 起）：

- 在 `symbolLabel` 的位置放一个一跳标签视图：`viaText`（等宽 12pt，`chromeSecondaryColor`），`→`（`chromeTertiaryColor`），类型名（沿用 `cairnSerifFont(ofSize: 15, weight: .medium)`），可选的 `(T: Read)`（等宽 12pt、淡色）。
- 当前显示的一端用前景色加粗，另一端淡色；两端都可以点击（`NSButton` 无边框样式，或者带点击手势的标签），点击调用 `model.showTypeHop(...)`。悬停提示：“形参 · 点击查看声明”“点击查看类型定义”。
- 路径、石子、徽章跟随 `displayedCandidate`。
- 无障碍：一跳标签整体的 accessibilityLabel 写“ps，形参，类型 S”。
- 增加 self-test 读取口（仿照 `selfTestLensStyle`）：`selfTestTypeHop: (via: String, target: String?, showing: String)?`。
- 新增本地化字符串（中英）：一跳相关的所有文字、徽章说明。`python3 scripts/check-localizations.py` 必须通过。

### P1.6 跳到类型定义（R3）

- 快捷键定义表（K0）登记：命令 `navigate.typeDefinition`（菜单“导航 → 跳到类型定义”，默认 ⌃⌘J），鼠标手势 `reader.gesture.typeDefinition`（默认 ⌘⇧+单击）。
- 阅读器点击分发（`MainWindowController.swift:4659` 的 `textView.onClick`）：现在只认 `[]`、`[.command]`、`[.option]`。改为从 K0 的手势表查修饰键组合对应的动作，新增“跳到类型定义”一支。
- 阅读器右键菜单（`MainWindowController.swift:4697` 起）加“跳到类型定义”。
- 执行时调用 `typeDefinitionTarget`：成功就 `open(path:byteOffset:)`，原因记为新的 `NavigationCause.typeDefinition`；失败就在状态栏短暂提示原因。
- `Sources/CodeInsightAppModel/NavigationHistory.swift:527`：新增 `.typeDefinition`，`persistenceKey` 为 `"typeDefinition"`，同步 `SessionCodec` 接受的原因集合（见该处注释）；`ReadingTrailView` 的 `causeText` 增加“类型”。

### 测试（P1）

| 测试 | 放在 | 断言 | 注入 |
|---|---|---|---|
| `rustTypeRefStripsReferencesAndSmartPointers` | `RustExtractorTests` | `&S`、`&mut Box<S>`、`Option<Arc<a::S>>` 的 `typeRef` 都指向 `S` 的区间 | 让 `typeHead` 不递归进 `Box` |
| `rustTypeRefMarksPrimitivesAndGenerics` | 同上 | `u32` → `.primitive`；`<T: Read>` → `.genericBound`；`<T: A + B>` → `.genericUnbounded` | 删掉单约束分支 |
| `rustSelfParameterTypeRefPointsAtImplType` | 同上 | `impl Tr for S { fn f(&self) }` 的 `self` → `.selfType(S)` | 取 trait 名而不是 `S` |
| `rustFieldFacetCarriesTypeRef` | 同上 | `pub inner: Inner` 的字段 facet 带 `.named(Inner)` | 不给字段 facet 赋值 |
| `projectIndexerPreservesBindingTypeRef` | `CodeInsightEngineTests` | 经过 `ProjectIndexer` 名字重映射后 `typeRef` 仍在 | 在 `ProjectIndexer.swift:815` 处漏传 `typeRef` |
| `draftCodecRejectsOutOfRangeTypeRef` | 同上 | 越界区间的草稿被拒绝 | 去掉新校验 |
| `typeHopResolvesAnnotatedParameterToStruct` | 同上 | 需求 §2.1 探针里的 `ps`、`local` → `S` | `typeHop` 直接返回 `.none` |
| `typeHopFollowsFieldAccessToFieldType` | 同上 | `self.inner` 的 `inner` → `Inner` | 不处理字段第一跳 |
| `typeHopStopsAtTypeAlias` | 同上 | `h: Handle` → `Handle` 的别名 facet，不是 `Inner` | 穿透别名 |
| `typeHopCertaintyIsTheWeakerHop` | 同上 | 结果确定性等于两跳中较低者；`.constructed` ≤ `.probable` | 取较高者 |
| `lensShowsTypeForValueBindingButJumpsToDeclaration` | `AppModelTests` | 单击 `ps` 后 `displayedCandidate` 是 `S`，`symbolCandidate` 和 `explicitJump` 是 `ps` 的声明 | 让 `symbolCandidate` 返回 `displayedCandidate` |
| `lensTypeHopToggleSticks` | 同上 | `showTypeHop(.declaration)` 后显示声明，`userChoseShowing == true` | 切换时不置标志 |
| `lensPrimitiveFieldStaysOnDeclarationWithNote` | 同上 | `n: u32` 保持 `.candidates` 并带“原始类型”说明 | 对原始类型也跳 |
| `typeDefinitionNavigationCauseRoundTrips` | `SessionCodecTests` | `.typeDefinition` 编码后能解码 | 删掉解码分支 |
| `resolveTypeHopCLIPrintsTypeLine` | CLI 或 Engine 测试 | `--type-hop` 输出含 `type -> src/main.rs:1:12` | 不打印这一行 |

此外，把需求 §2.1 的探针写成 goldset 断言（`goldset/` 里现有格式），覆盖 `ps`、`local`、`self`、`n`、`inner`、`h`、`r: T`（单约束）。

### 验收（P1）

- CLI：在需求 §2.1 的探针项目上，`swift run codeinsight resolve src/main.rs:5:5 --project <探针> --type-hop` 输出 `type -> src/main.rs:1:12`；`5:12` 同样。输出原样贴进验收记录。
- 原生（截图，Light 主题，另加一张 SI Classic）：
  1. 单击 `ps`：头部显示 `ps: &S → S`，正文是 `S` 的定义。
  2. 点 `ps: &S`：正文换成声明行，`ps: &S` 加粗、`S` 变淡。
  3. ⌘+单击 `ps` → 跳到形参；⌘⇧+单击 → 跳到 `S`；⌃⌘J 同样跳到 `S`；阅读轨迹里这一跳的原因显示“类型”。
  4. 单击 `self.n` 的 `n`：停在字段声明，徽章写原始类型说明。
- 完整 CI 通过。

---

## P2 精确层 `typeDefinition`

**覆盖**：R1.2 第 4 条、R1.6、R1.7、R8.2。**前置**：P1。

### 改动

1. `Sources/CodeInsightExact/ExactProvider.swift`
   - `ExactCapabilities.typeDefinition = 1 << 5`。
   - `ExactSession` 协议加 `typeDefinition(file:byteOffset:)` 和带 `batch` 的版本，返回 `ExactDefinitionQueryResult`。协议扩展里给默认实现，返回 `.unavailable("typeDefinition unsupported")`，这样测试替身不用全改。
2. 三个 provider（`RustAnalyzerProvider.swift`、`PyrightProvider.swift`、`TypeScriptLanguageServerProvider.swift`）：
   - 能力协商：服务器声明了 `typeDefinitionProvider`（`true` 或对象）就加入 `.typeDefinition`（仿照第 410 行附近 `definitionProvider` 的写法）。
   - 实现：`requestLocations(method: "textDocument/typeDefinition", parse: parseDefinition)`，写法照抄 `definition`。
   - P2 只需在 rust-analyzer 上验收；pyright 和 tsserver 的实现在 P2 一并写上，验收放到 P4。
3. `Sources/CodeInsightAppModel/ExactCoordinator.swift`：`typeDefinition(file:byteOffset:generation:batch:)`，与 `definition`（第 76 行起）走同一套代际校验和批次；结果缓存用**独立的**映射，不能和 `definition` 的缓存混用。
4. `ContextWindowModel`
   - 仿照 `attachExactCoordinator` 注入 `typeDefinitionResolver`。
   - 第一个候选是值绑定或字段时，和现有 `definition` 升级**同一批次**发出 `typeDefinition`。例外：`typeRef` 是 `.primitive` 或 `.genericUnbounded` 时不发。
   - 结果处理，规则同 `applyExact`：按 `(path, targetByteOffset)` 识别候选，每次 `await` 之后都重新读 `stage`，并做内容漂移校验。
     - 已经是 `.typeHop`：匹配的 target 原地升级为 `.exact` basis；没匹配上就把精确目标插到最前，但用户手动选过（`selectionEpoch` 变了）就不改选中项。
     - 仍是 `.candidates`（句法没给出类型）：提升为 `.typeHop`。`showing` 取 `.type`，除非 `userChoseShowing`。这就是 R1.7 的“原地换成类型”。
   - 句法没有类型、精确请求在路上时，`.typeHop` 的 `targets` 为空，界面显示“类型解析中…”；精确层未就绪时显示“类型需要精确分析 · 未就绪”。建议用 `TypeHop.pendingExact: Bool` 加上 coordinator 的 readiness 来区分这两种状态。
   - 依赖代码里的目标复用 `dependencyExactCandidate`。
   - **原始类型过滤**：推断出的原始类型，rust-analyzer 可能返回 `core` 里 `primitive_docs.rs` 这类位置，也可能什么都不返回。实施时先用 `exact-typedef` 实测 `let x = 1u32;`，把实际返回写进验收记录；如果返回了位置，就按“路径落在 toolchain 的 `primitive_docs.rs`”过滤掉，并停在声明上。
5. CLI：`ExactTypeDef` 子命令，参数和输出格式与 `ExactDef`（`CodeInsightCLI.swift:39`）一致（R8.2）。

### 测试（P2）

| 测试 | 放在 | 断言 | 注入 |
|---|---|---|---|
| `rustAnalyzerNegotiatesTypeDefinition` | `CodeInsightExactTests` | 带 `typeDefinitionProvider` 的初始化响应 → 能力含 `.typeDefinition` | 去掉协商分支 |
| `exactTypeDefinitionSendsTypeDefinitionMethod` | 同上（用现有的 LSP 替身） | 请求方法名是 `textDocument/typeDefinition` | 改成 `definition` |
| `coordinatorKeepsTypeDefinitionCacheSeparate` | `ExactCoordinatorTests` | 同一位置的 `definition` 和 `typeDefinition` 缓存互不覆盖 | 共用一张表 |
| `lensPromotesInferredBindingWhenExactTypeArrives` | `AppModelTests` | `let made = make_s();`：先是 `.typeHop` 且 `targets` 为空，精确回复后 `displayedCandidate` 为 `S` | 不做提升 |
| `lensKeepsDeclarationWhenUserToggledBeforeExactArrives` | 同上 | 回复前调用 `showTypeHop(.declaration)`，回复后仍显示声明 | 忽略 `userChoseShowing` |
| `lensUpgradesSyntacticTypeTargetToExactInPlace` | 同上 | `ps` 的 `S` 候选升级为 `.exact`，选中项不变 | 插入新候选而不是原地升级 |
| `lensSkipsTypeDefinitionForPrimitiveTypeRef` | 同上 | `n: u32` 不发 `typeDefinition` | 去掉跳过条件 |
| `lensDropsStaleTypeDefinitionReply` | 同上 | 回复到达前已经换了 token，回复被丢弃 | 去掉 `requestID` 检查 |

### 验收（P2）

- CLI：`swift run codeinsight exact-typedef src/main.rs:<made 的位置> --project <探针>` 输出指向 `S`。探针需要补一行 `let made = make_s();`。
- 原生：
  1. rust-analyzer 就绪后单击 `made`：先截到“类型解析中…”，再截到换成 `S` 之后。
  2. 单击一个类型来自依赖 crate 的变量：显示依赖源码，徽章为“外部”。
  3. 在“准备中”时单击 `made`：显示“类型需要精确分析 · 未就绪”。
- 本机 rust-analyzer 不可用时：在验收记录里写明跳过了哪些原生步骤及原因，单测照常必须通过。

---

## P3 跟踪光标、所在函数模式、模式控件

**覆盖**：R4、R5、R6。**前置**：P1（P2 可并行，但 R4.2 的 400 ms 精确门槛要等 P2 才有精确请求可以限流）。

### P3.1 模型

`ContextWindowModel`：

- 把 `Mode` 拆成两个独立状态（T1=B）：

  ```swift
  public enum Tracking: String, Codable, Sendable { case symbol, enclosing }
  public private(set) var tracking: Tracking = .symbol
  public private(set) var isPinned = false
  ```

  现有 `mode == .pinned` 的判断全部改成 `isPinned`；`setMode` 拆成 `setTracking(_:)` 和 `setPinned(_:)`。进入固定时的精确升级逻辑（`setMode` 里 `enteringPin` 那段）原样保留在 `setPinned(true)` 里。
- 触发来源：`tokenClicked(file:offset:)` 增加参数 `trigger: Trigger`（`.click` / `.caret`）。
  - `.click`：行为同现在，精确请求立即发。
  - `.caret`：句法查询照常；精确请求（`definition` + `typeDefinition`）延迟到光标在同一 token 上停留满 `exactDwell`（默认 400 ms）才发。`exactDwell` 做成 `init` 可注入，测试里设为 0 或很小的值。token 变了就取消还没发出的延迟请求。
- 光标不在符号上（`tokenRange` 失败）时，`.click` 和 `.caret` 都**保留**当前 `stage`，并置 `public private(set) var isShowingPreviousToken = true`；下一次命中符号时清掉（R4.3）。项目状态变化、换根目录这类现有的清空路径不受影响。
- 所在函数：`public func caretMoved(file: String, offset: UInt32, document: ReaderDocument)`：
  - `tracking == .enclosing` 且未固定时，用 `ReadingPlan.enclosingAssociatedFacets(at:in:)` 取嵌套大纲项。先选最内层的函数或方法（排除闭包）；没有就选最内层的类型（impl / struct / enum / trait / class / interface）；都没有 → `stage = .idle`。
  - 与上一次是同一个大纲项（按 `range` 判断）就不刷新。
  - 产出 `Stage.enclosing(EnclosingScope)`，包含：路径、种类、名字、要显示的行区间（文档注释起始行 → 签名结束行，再加函数体第一行）、函数体总行数、impl 的方法数。
  - **签名在哪一行结束**：取该大纲项范围内、起点在 `nameRange` 之后的第一个折叠区（`document.foldRegions`），它的起点所在行就是签名的最后一行。Python 的 `:` 同理，函数体从下一行开始。**文档注释从哪一行开始**：复用悬停卡片句法路径里提取文档注释的逻辑（`syntacticSymbolDoc(forDeclarationAt:in:location:)` 附近）。拿不到折叠区时，退回到只显示 `nameRange` 所在的那一行。
  - 不需要索引就绪，不发任何精确请求。
- 在 `.enclosing` 下，`symbolCandidate` 为 nil（没有“指向的符号”），`displayedCandidate` 是这个声明。

### P3.2 接线

`MainWindowController`：

- `textView.onCaretChange`（第 4687 行）：150 ms 防抖后调用 `contextWindow.tokenClicked(..., trigger: .caret)`；所在函数模式下，改调 `contextWindow.caretMoved(...)`（所在函数模式只需要轻量防抖，16–50 ms 即可，保证方向键按住不放时不卡）。
- 先确认单击是否也会触发 `onCaretChange`（`CodeInsightReaderUI.swift:3627` 的 `updateCurrentLine`）。如果会，就要去重：单击路径已经调用了 `tokenClicked(.click)`，同一偏移的 `.caret` 不能再排一次延迟的精确请求。写一条测试锁住这一点。
- 分屏：只接当前第一响应者所在的阅读器（R4.5）。`secondaryReaderController` 也要接同样的回调，按焦点决定由谁生效。
- 会话恢复：`tracking` 写进每个窗口的会话检查点（`AppModel.scheduleSessionCheckpoint` / `SessionCodec`）；`isPinned` 不写（R6.3）。

### P3.3 界面

`ContextWindowViewController`：

- `modeControl` 改为两段 `符号 | 所在函数`，右边加一个独立的图钉按钮（SF Symbol `pin` / `pin.fill`，22pt 高，与两段控件等高）。固定时头部琥珀色，沿用 `applyHeaderStyle`。
- 所在函数模式的头部：一个种类徽章（“方法”“函数”“impl”“结构体”……），加衬线字体的名字，加路径；不显示石子（R5.4）。
- 正文：用 `EnclosingScope` 给出的行区间填迷你阅读器；最后一行（函数体第一行）加渐隐遮罩；下面一行小字“⋯ 函数体 N 行 · 双击打开”（impl 写“⋯ M 个方法 · 主体 N 行”）。双击或 ⌘+单击 打开到签名行。
- `isShowingPreviousToken` 为真时，正文右上角显示淡色小标“光标不在符号上 · 保留上一次”。
- 占位文字按模式区分（原型里有两种）。
- 快捷键定义表登记三条命令：`lens.trackSymbol`、`lens.trackEnclosing`、`lens.togglePin`，默认不绑定按键（R6.4）。
- 更新 self-test 读取口：`selfTestPinned` 改读图钉按钮；新增 `selfTestTracking`、`selfTestEnclosingTitle`、`selfTestShowsPreviousTokenNote`。

### 测试（P3）

| 测试 | 放在 | 断言 | 注入 |
|---|---|---|---|
| `caretTriggerDelaysExactUntilDwell` | `AppModelTests` | `.caret` 触发后在 `exactDwell` 之前没有精确请求，之后有 | 去掉延迟 |
| `caretLeavingTokenCancelsPendingExact` | 同上 | 停留不满就换 token → 旧 token 的精确请求从未发出 | 不取消延迟任务 |
| `clickDoesNotDoubleScheduleCaretExact` | `MainWindowControllerTests` | 单击之后同一偏移的 caret 回调不再排精确请求 | 去掉去重 |
| `lensKeepsPreviousContentWhenCaretLeavesSymbols` | `AppModelTests` | 光标移到空白后 `stage` 不变，`isShowingPreviousToken == true` | 恢复成 `stage = .idle` |
| `enclosingPrefersInnermostFunctionOverType` | 同上 | 方法体内 → 方法；impl 内、方法外 → impl；顶层空白 → `.idle` | 颠倒优先级 |
| `enclosingSkipsClosures` | 同上 | 闭包体内 → 外层函数 | 把闭包也算作函数 |
| `enclosingDoesNotRefreshWithinSameFacet` | 同上 | 同一方法内移动不产生新的 stage 写入 | 去掉去重 |
| `enclosingSignatureEndsAtBodyFold` | `CodeInsightReaderCoreTests` 或 AppModel | 多行 `where` 子句的签名全部包含在内，函数体从 `{` 之后开始 | 只取 `nameRange` 那一行 |
| `pinIsOrthogonalToTracking` | 同上 | 两种模式都能固定；固定后 `caretMoved` 和 `tokenClicked` 都不改变 stage | 固定时仍然处理所在函数的更新 |
| `sessionRestoresTrackingButNotPin` | `SessionRestoreTests` | 恢复后 `tracking` 保留，`isPinned == false` | 把 pin 也持久化 |

### 验收（P3）

- 原生（截图加一段录屏或连拍截图）：
  1. 在 `use_it` 里用方向键逐行移动：窗口跟着变；走过空白时保留上一次内容，并出现小标。
  2. 切到“所在函数”：窗口显示 `use_it` 的文档和签名，加渐隐和“⋯ 函数体 N 行”；移到 impl 里、方法外 → 显示 `impl S`。
  3. 图钉：固定后移动光标，窗口不变，头部琥珀色。
  4. 重启应用恢复会话：`所在函数` 被保留，图钉未按下。
  5. 在 Light 和 Dark 主题各截一张头部。
- 事件时序：在 Debug 构建里临时打日志，确认方向键快速掠过 `made` 时**没有**精确请求；停留时 400 ms 后发出。把日志片段贴进验收记录，然后删掉临时日志。

---

## P4 Python 与 TypeScript

**覆盖**：R1（Python、TS 部分）、P2 在 pyright / tsserver 上的验收。**前置**：P1、P2（P3 不是必需的）。

### 改动

- `TypeRef` 抽取：
  - Python（`Sources/CodeInsightPythonExtractor/PythonExtractor.swift:207`、`677` 两处 `BindingRecord`）：形参注解、带注解赋值 `x: S = …`、类体里的注解属性；`self`（方法第一个形参）和 `cls` → `.selfType(所在 class 名)`；`typing.Self` → `.selfType`。剥离表见需求 R1.4；字符串注解去引号后再定位区间（区间指向引号内的名字）。
  - TypeScript（`Sources/CodeInsightTypeScriptExtractor/TypeScriptExtractor.swift:255`，以及阅读器侧的 `Sources/CodeInsightReaderCore/TypeScriptReaderSyntax.swift:481`）：变量、形参、类属性的 `type_annotation`；`this` → `.selfType(所在 class)`。
  - 原始类型表：Python `int str float bool bytes None object`；TS `string number boolean any unknown void never object bigint symbol undefined null`。
  - 两个抽取器的 `extractorVersion` 各加 1。
- 引擎 `typeHop` 的类型种类集合加上 `pythonClass`、`typescriptClass`。
- TS 的 `interface` / `type`：句法层落不到（需求 §4），只靠 P2 的精确层；验收时确认 tsserver 能给出这两类的位置。

### 测试（P4）

每种语言至少三条抽取测试：剥离表、`self`/`this`、原始类型。再各加一条 `typeHop` 引擎测试；加 goldset 断言：每种语言 3 条，覆盖形参、属性、`self`/`this`。每条都要单独注入。

### 验收（P4）

- CLI：各语言探针的 `resolve --type-hop` 和 `exact-typedef` 输出贴进验收记录。
- 原生：Python 的 `def f(repo: Optional["Repository"])` 中单击 `repo` → `Repository`；TS 的 `const s: Snapshot[] | undefined` 中单击 `s` → `Snapshot`；TS 的 interface 类型变量等精确层给出位置。

---

## 附：需求 → 阶段对照

| 需求 | 阶段 |
|---|---|
| R1.1–R1.5（Rust） | P1 |
| R1.2 第 4 条、R1.6、R1.7 | P2 |
| R1（Python、TS） | P4 |
| R1.8 | P1（不实现开关即满足） |
| R2 | P0 |
| R3 | P1（依赖 K0） |
| R4 | P3 |
| R5 | P3 |
| R6 | P3 |
| R7 | P1 |
| R8.1、R8.3 | P1 |
| R8.2 | P2 |
