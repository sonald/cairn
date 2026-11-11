# Go 语言支持实施计划（临时，完成后删除）

本计划供并行实现方使用；完成后有效结论归入 [product.md](../product.md)、[architecture.md](../architecture.md)，本文件删除。可行性与实测数据见 [go-feasibility-2026-11](../evidence/go-feasibility-2026-11/README.md)；仓库规则见 [AGENTS.md](../../AGENTS.md)、测试策略见 [testing.md](../testing.md)。

## 0. 已裁决（不要再改）

1. `vendor` 在默认跳过目录里（已实现）；生成的 `.go` 文件不特殊处理。
2. `_test.go` 与构建标签变体（`foo_linux.go`）都是项目源码；句法层给多候选，不按平台过滤。
3. Safe 模式下 cgo 保持开启（不设 `CGO_ENABLED=0`）。
4. 分析单元标记：`go.mod` 与 `go.work`，沿用现有"最浅覆盖标记 / 否则最深标记祖先"规则。句法层解析 import 时按每个文件最近的 `go.mod` 取模块路径。
5. 语言服务器环境 `GOTOOLCHAIN=local`；`go.mod` 要求更新的 Go 时显示 go 的原话（`go.mod requires go >= X (running go Y; GOTOOLCHAIN=local)`）。
6. "下载依赖"：有 `go.sum` 且没有 `vendor/` 时在应用内运行。做法是把 `go.mod`/`go.sum` 复制到仓库外的临时目录，运行 `go mod download -modfile=<副本>/go.mod`；`go.work` 单元按 `use` 列出的每个模块分别以 `GOWORK=off` 运行。不得改动仓库里任何文件。

实测约束（证据第一、四节）：gopls 进程必须设 `GOCACHE`、`GOPLSCACHE` 到私有缓存目录（否则引用静默为空）；**不要设 `GOFLAGS`**（`-mod=readonly` 会让带 `vendor/` 的仓库失败）；`GOPROXY=off`。

## 1. 地基（已在 `cd75eaa` 完成）

- `LanguageID.go = 4`；`LanguageMode.classify` 认 `.go`（含 `_test.go`）；**`LanguageMode.supported` 还没有 `.go`**，所以应用目前不会探测到 Go。
- `DeclarationKind`：`goFunction`、`goMethod`、`goStruct`、`goInterface`、`goType`（其他 `type T …`，含别名）、`goConst`、`goVar`、`goField`；`shape`、大纲种类、`kindWeight`、`typeKinds` 已映射。
- `goConfigIdentity`（`Sources/CodeInsightCore/QueryContext.swift`）：配置为 `go.work`（有时）否则 `go.mod`；环境为 `go.sum` + `go.work.sum`。
- `contentRegionKind` 的 Go 分支；`Sources/CTreeSitterGo`（v0.25.0，ABI 15）；`CodeInsightGoExtractor` 骨架与 `GoExtractorTests`；`Package.swift` 已让 Engine、ReaderCore、相关测试依赖 `CodeInsightGoExtractor`，ReaderCore 依赖 `CTreeSitterGo`。**并行阶段谁都不改 `Package.swift`**；确实需要时在报告里说明，由我合并。
- 其余所有按语言分支的地方，Go 暂时与 `.javascript` 走同一"未支持"路径（`git show cd75eaa` 可见全部位置）。各块把自己文件里的这些路径换成真实行为。

## 2. 提取器约定（各块共享）

`GoExtractor` 产出的 `ContentIndex`：

| 记录 | Go 内容 |
| --- | --- |
| `symbols` | 包级 `func` → `goFunction`；带接收者的 `func` → `goMethod`（`parentFacetIndex = nil`）；`type` 声明：struct → `goStruct`，interface → `goInterface`，其余 → `goType`；struct 字段（含嵌入字段，名取类型名）→ `goField`，父为 struct；interface 的方法 → `goMethod`，父为该 interface；包级 `const`/`var`（含分组块里的每个名字）→ `goConst`/`goVar`。函数体内的局部声明不进 `symbols`。 |
| `space` | 类型声明 `.type`；其余 `.value` |
| `visibility` | 名字首字母为 Unicode 大写 → `.public`，否则 `.private`；`_` 视为 `.private` |
| `implRelations` | 每个带接收者的方法一条：`implFacetIndex` = 该方法 facet 自身，`traitNameID = nil`，`typeNameID` = 接收者基类型名（去掉 `*` 与类型参数，`(c *Command)` → `Command`） |
| `supertypes` | interface 中嵌入的 interface、struct 中嵌入的类型（名取最后一段） |
| `imports` | 每个 import spec 一条：`moduleSpecifier` = 导入路径字符串（不含引号）；`localName` = 显式别名，否则路径最后一段（`gopkg.in/yaml.v3` 这种按 go 的默认包名规则尽量推断，推断不了用最后一段）；`kind = .module`；`.` 导入加 `.wildcard`，`_` 导入用 `.sideEffect` |
| `calls` | `f(x)` → `.directCall`；`x.f(y)` → `.methodCall`，`receiverRange` 为 `x` 的范围；`pkg.F(x)` 在 `pkg` 是导入名时 → `.qualifiedCall`，`qualifierRange` 为 `pkg` 的范围 |
| `scopes`/`bindings` | 文件 → `.module`；`func`/方法/函数字面量 → `.function`；块 → `.block`。参数、接收者 → `.param`；`:=`、`var` → `.letBinding`；导入名 → `.importBinding`。能从 `T{…}`、`&T{…}`、`new(T)`、`var x T`、参数类型读出类型时填 `targetHint`/`typeRef`（做法照 Rust/Python 抽取器） |
| `regions` | `contentRegions(in:language: .go)` |

`identifierRanges(named:in:mode:)` 返回所有 `identifier`、`type_identifier`、`field_identifier`、`package_identifier` 中名字匹配的范围。递归遍历要用显式栈或 `depthFirst()`（深嵌套表达式曾让抽取器栈溢出，见 `docs/evidence/js-grammar-and-nesting-2026-10.md`）。

## 3. 并行切片与文件归属

每块在自己的 git worktree / 分支上工作，**只改归属的文件**。都从 `cd75eaa` 之后的提交开始。

### X：提取器与句法层（Engine、CLI）

归属：`Sources/CodeInsightGoExtractor/**`、`Tests/GoExtractorTests/**`、`Sources/CodeInsightEngine/**`、`Tests/CodeInsightEngineTests/**`、`Sources/CodeInsightCLI/**`、`goldset/**`、`scripts/run-gold-gates.sh`、`Sources/CodeInsightCore/**`（只在确需时）、`Tests/CodeInsightCoreTests/**`。

1. 实现 `GoExtractor`（§2）。参照 `Sources/CodeInsightPythonExtractor/PythonExtractor.swift`、`Sources/CodeInsightTypeScriptExtractor/`、`Sources/CodeInsightRustExtractor/`。Go 节点名见 `Sources/CTreeSitterGo/src/node-types.json`。
2. 把 `Tests/CodeInsightEngineTests/ContentIndexDraftCodecTests.swift` 的 `case .go: preconditionFailure` 换成 `GoExtractor()`。
3. Engine 里所有 Go 暂按未支持处理的位置（`grep -n '\.go\b' Sources/CodeInsightEngine`）：
   - `ProjectIndexer.languageExtractor` → `GoExtractor()`；`analysisProfile(root:language:projectRoot:)`。
   - `ProfileDetector`：`isMarker` 认 `go.mod`、`go.work`；`detect` 产出 Go profile（`goConfigIdentity`；`projectUnitName`：有 `go.work` 为 `go.work`，否则 `go.mod` 里 `module` 指令的路径，都没有用项目根名）。
   - `ModuleMap`：Go 的"目录即包"。同一目录（且同一 `package` 名；`_test` 外部测试包算另一个包）的文件属于一个包；包路径 = 最近 `go.mod` 的 module 路径 + 相对目录。`targetFile(for:from:)` 现在只返回一个文件：为 Go 新增"导入 → 包内文件集合"的查询，`Resolver.importCandidate` 的 Go 分支在整个包的文件里找 `importedName`（`pkg.F` 的 `F`）。`modulePath(of:)` 返回包路径分段。导入路径不在本单元任何模块内（标准库、第三方）→ 未解析（`.unresolved`，交给 Exact）。
   - `Resolver`：同包文件互相可见、无需 import——`globalCandidates`/直接调用时同包候选优先（`.strong` 仅当同包唯一）；`pkg.F` 走导入的包；`x.M()` 在 `x` 的绑定能给出类型时用 `byTypeName` 找接收者为该类型的 `goMethod`（`implFacetIndex` 就是方法本身，见 §2），否则按方法名回退（同 Python/TypeScript）。注意现有 `== .python`/`== .typescript` 比较编译器不会提示，逐个检查 `grep -n 'language == \.' Sources/CodeInsightEngine`。
   - `ComposableSearch` 里写死的 `[LanguageID.rust, .python, .typescript]` 与函数头所属显示（Go 方法显示 `Type.Method`）；`ProjectSymbols` 给方法带出接收者类型名（新字段或复用 `implTraitName` 之外的字段，自行决定并在报告中说明）；`EngineSession` 中其余按种类的集合。
4. CLI：`--language go` 解析（`Sources/CodeInsightCLI/CodeInsightCLI.swift` 中 `"python", "py"` 那处），其余 Go 未支持分支按 Python/TypeScript 的样子补齐。
5. Gold set：在 `~/.cache/cairn-corpora/cobra`（`adbc8813901bba65827259daa8e22ff94ec1f30e`）上建一份小的 `goldset/cobra-go.gold`（格式看已有 `.gold` 与 `scripts/run-gold-gates.sh`），覆盖跨文件调用、同包无 import 可见、`pkg.F`、方法调用、接口；在 run-gold-gates 里加 Go 选项（参照 TypeScript 的 `--typescript-corpus`）。
6. 测试：`GoExtractorTests` 用小 fixture 覆盖 §2 每一行；Engine 集成测试覆盖同包跨文件定义、导入包内定义、方法按接收者类型解析、`_test.go` 与平台变体给多候选、`vendor/` 不进索引。按 AGENTS.md：不为每个方法写单元测试；新增的每条测试要能说明它防的风险。
7. 验证：`bash scripts/ci.sh engine core`；gold 门 `bash scripts/run-gold-gates.sh --go-corpus …`（你新增的选项）。

### Y：精确层（gopls）

归属：`Sources/CodeInsightExact/**`、`Tests/CodeInsightExactTests/**`。

1. 新增 `GoplsProvider`（参照 `PyrightProvider.swift`、`TypeScriptLanguageServerProvider.swift`）：`findExecutable(projectURL:environment:)` 找 `gopls`（PATH 与 `~/go/bin`，即 `$GOPATH/bin`；不得在项目内）；`toolVersion` 记录 `gopls version` 的版本与它的构建 Go 版本，以及 `go version`（在沙箱里运行）；`prepare(...)` 启动 `gopls serve`。
2. `LSPLanguageSpec.gopls`：`requestFlow: .direct`；`switchReadiness: nil`（实测切换后第一个请求即新答案）；能力推导含 `definition`、`references`、`callHierarchy`、`hover`、`implementations`、`typeDefinition`；`languageID` 为 `"go"`；`acceptsPath` 只认 `.go`。`onDiagnostic`：诊断含 `module lookup disabled by GOPROXY=off` 时把环境标为 `.dependenciesUnavailableOffline`（看 rust-analyzer/pyright 现在怎么做）。
3. 沙箱环境（`Sandbox.swift` 或 provider，自行判断哪里最合适）：`GOCACHE=<cache>/go-build`、`GOPLSCACHE=<cache>/gopls`、`GOTOOLCHAIN=local`、`GOPROXY=off`，并移除继承来的 `GOFLAGS`。不设 `CGO_ENABLED`。
4. 大仓库：gopls 在工作区加载期间挂起请求，标准库样本 13.4 s。确认 `requestTimeout` 与就绪状态在这种情况下不会误报失败；需要时用 `$/progress` "Setting up workspace" 的 begin/end 作为就绪信号（看 `LSPLanguageSession` 已有的 progress 处理）。
5. `ExactProvider.swift`：Go 的指纹用 `goConfigIdentity`（两个 init）；`requireSupportedFingerprint` 接受 `.go`。
6. `DependencySetup`：Go 分支（§0 第 6 条）。`runsInApp = go.sum 存在 && 单元里没有 vendor/`；命令文本显示 `go mod download`；`fetch()` 对 Go 用仓库外副本，`GOWORK=off`、`GOTOOLCHAIN=local`，网络允许；失败抛出 go 最后一行 stderr；取消即终止进程。`DependencyBorrowing` 对 Go 不借用（已是 `break`）。
7. 测试：参照现有 rust-analyzer/pyright 的真实服务器测试与假服务器测试。至少：真实 gopls 在小 fixture 上的定义/引用/实现（gopls 不在时跳过并说明）；缺依赖诊断 → 标注；热切换（`switchSnapshot`）后答案更新；`DependencySetup` 的 Go 分支在 `go.sum` 不完整的临时仓库上运行后仓库文件不变（需联网，标记为可跳过）。
8. 验证：`bash scripts/ci.sh exact`。

### Z：阅读器语法（ReaderCore）

归属：`Sources/CodeInsightReaderCore/**`（除 `DiffCore.swift`）、`Tests/CodeInsightReaderCoreTests/**`、`Sources/CodeInsightReaderUI/**`（只在确需时）。

1. 新增 `GoReaderSyntax.swift`（参照 `PythonReaderSyntax.swift`、`TypeScriptReaderSyntax.swift`）：基于 tree-sitter-go 的高亮（关键字、内建类型与函数、类型名、函数/方法名、字段、字符串含 raw string、rune、数字、注释、包名）、语法折叠（函数体、块、复合字面量、`import`/`const`/`var`/`type` 分组、多行注释）、括号匹配与块尾注解需要的信息。
2. 接入：`CodeInsightReaderCore.swift` 里的 Go 分支（看 `.python` 的对应处）、`IdentifierIndex`（Go 关键字表，Go 不再走"无标识符分析"）、`SymbolDoc`（Go 文档注释：声明前紧邻的 `//` 行或 `/* */`，参照 Python/TS 的句法 hover 文档）、`BlockEndAnnotations`、`TextFormatSyntax`/`TextFormatFolding`（项目未分析 Go 时 `.go` 预览也用语法树着色，与 `.rs/.py/.ts` 一致；`CodeLanguageSyntax.swift` 的词法着色保留给其他用途或删除 Go 条目，看哪种不留死代码）、Markdown 代码块 `go`/`golang` 用语法树。
3. 不要改 `DiffCore.swift`（依赖提取器，由集成阶段做）。大纲来自提取器，也在集成阶段接。
4. 测试：照现有 Python/TypeScript 阅读器测试的粒度（不要逐个高亮类别写断言）；`ReadonlyIdentifierOracle.swift` 里给 Go 一套关键字表，让已有的属性测试覆盖 Go。
5. 验证：`bash scripts/ci.sh reader`。

## 4. 集成阶段（我来做）

合并 X、Y、Z 后：`DiffCore` 与大纲接提取器；AppModel（`ExactCoordinator` 创建 provider、`validateExactLanguage`、`validateProfile`、`allowsWarmSwitch` 让 `.go` 像 `.rust` 一样容忍环境指纹变化、hover 拆分、文档面板）；App（侧栏颜色、语言名、项目符号面板所属）；`LanguageMode.supported` 加 `.go`；`GitSnapshot` 的语言探测；自测通道；`docs/` 与中英文 README；最后在打包应用上原生验收（cobra）。

## 5. 所有实现方共同遵守

- 构建工具链：`bash scripts/check-toolchain.sh` 必须 PASS（Xcode 27.1 / Swift 6.4）。需要 `brew install libgit2`（本机已有）。
- 运行 `swift test` 时挂内存看门狗：`swiftpm-testing-helper` 常驻超过 8 GB 就 `kill -9`（轮询 `ps -o rss`；macOS 的 `ulimit -v` 不可靠）。只要有向上走目录的循环，终止条件用 `pathComponents.count > 1`。
- Swift Testing（`@Test`、`#expect`），函数名描述行为。报告测试时写"Test run with N tests … passed/failed"的原文摘要；退出码 0 但没有摘要行不算通过。
- 修 bug 的回归测试：撤回修复确认它会失败，逐条报告哪些测试变红、哪些仍绿。
- 提交：英文、简短（`feat(go): …`、`test(go): …`），只提交到自己的分支，不 push，不改 `main`，不删本计划文件。
- 不做原生 GUI 验收（集成阶段做）。不要运行 `scripts/ci.sh full`。
- 不要在 `/private/tmp` 下的工作树里跑 Exact 测试（路径校验会假失败）。
- 遇到计划与代码不符或计划有错：按代码事实做最小合理决定，在报告里列出。
