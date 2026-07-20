# CodeInsight — 现代版 Source Insight 需求与设计（v3）

> 一个**只读**的 macOS 原生代码阅读器：把项目丢进去，秒级建立符号索引，
> 以 Source Insight 式的 Context Window、Call Tree 和独特排版美学，
> 帮你读懂陌生的复杂代码。首发支持 Rust / Python / TypeScript，支持在 git 历史中自由穿梭。
>
> v3 修订：吸收第二轮同行评审。核心变化——数据模型升级为 3+1 层（新增 AnalysisProfile）、
> 符号模型引入 Scope/Binding/SymbolSpace、调用解析拆为四个正交维度、
> 精确模式与 Safe/Trusted 信任边界正式化、WorktreeSnapshot 真正不可变化、
> 缓存生命周期设计，并清理全部内部矛盾。
> "CodeInsight" 仅为仓库代号，正式产品名待定（与 Revenera Code Insight 等撞名）。

---

## 0. 核心论点

> **一个非常快、永远能给结果、同时诚实表达不确定性的代码理解系统。**

产品壁垒**不是**"编译器级工具慢而重"——TypeScript 7 已是高性能原生实现，
rust-analyzer 也足够快。持久的差异化是这五件事的组合：

1. **打开即有结果**：零配置、不可编译的仓库也秒级可读可跳。
2. **历史快照原生可读**：任意 commit 虚拟切换，语义操作全程可用，绝不动工作区。
3. **对不可信仓库安全**：默认 Safe Reading Mode，绝不执行项目代码（§8.4）。
4. **只读交互做到极致**：Context Window、Call Tree、层次化排版，为阅读而非编辑设计。
5. **fuzzy 与 exact 共存于同一套置信度与证据系统**：精确结果带来源与覆盖度标注，
   模糊结果诚实说明依据，用户永远知道自己看到的是什么。

五条设计红线（历轮评审确立的"禁止近似"清单）：

1. **blob 内容缓存 ≠ 文件语义缓存**——内容索引跨 commit 复用；路径身份属于快照（§3.2）。
2. **语义不仅属于快照，还属于配置与环境**——同一 commit 在不同 feature/tsconfig/解释器下
   语义不同；关系解析绑定 snapshot + AnalysisProfile（§3.3）。
3. **按名字找到调用点 ≠ 知道谁调用了这个函数**——Call Tree 是**静态源码调用候选图**，
   每条边带 certainty/dispatch/provenance/completeness（§4）。
4. **TextKit 2 视口布局 ≠ 大文件天然低内存**——字符串本体、属性 run、坐标转换显式设计（§9）。
5. **commit 界面切换完成 ≠ 语义索引已就绪**——视觉切换与语义就绪分级；
   一切查询带 snapshot + profile + generation 防串（§6）。

---

## 1. 产品定位

### 1.1 一句话定位

**Code Reader，不是 Code Editor。** 为"理解代码"做极致优化，砍掉一切编辑功能。
macOS 原生应用（AppKit/Swift），无 Electron、无 Tauri、无 WebView。

### 1.2 与 IDE / VS Code + 插件的差异

| 维度 | IDE / VS Code | CodeInsight |
|------|--------------|-------------|
| 核心场景 | 写代码 | 读代码 |
| 陌生仓库冷启动 | 需要装依赖、配环境才有完整语义 | 零配置秒级可读，fuzzy 永远可用 |
| 不可信仓库 | 语言服务可能执行 build script/proc macro | Safe Mode 默认不执行任何项目代码 |
| 历史版本浏览 | checkout 切换、破坏工作区 | 虚拟快照 + 语义操作，不动工作区 |
| 结果可信度 | 精确或没有 | fuzzy/exact 统一置信度 + 证据体系 |
| UI | 通用编辑器布局 | 为阅读定制：Context Window、Relation Window、层次化排版 |

### 1.3 目标用户与首要语言

**首要支持语言：Rust、Python、TypeScript**（JS 见 F1.5 能力分级；C/C++、Go 后续扩展）。

- 接手陌生大型代码库（后端服务、基础设施工具、前端工程）的工程师
- 代码审计、安全审查者（**仓库本身可能不可信**——这是 Safe Mode 存在的理由）
- 阅读大型开源项目（tokio、Django、VS Code 量级）的学习者
- 重构前理清调用关系、排查 bug 反查引用的人

语言切换的深层含义（评审语）：本产品不是"路径感知的文本符号索引器"，
而是"**配置感知、环境感知、带不确定性的多语言语义阅读系统**"。
三门语言的显式 import 系统让直接调用的解析置信度远高于 C 世界；
难点转移到：Python 动态类型、Rust 宏与 feature/target 条件编译、TS 项目配置复杂度。

---

## 2. 需求梳理

优先级：P0 = MVP 必须有；P1 = 第一个正式版；P2 = 后续演进。

### 2.1 索引引擎

- **F1.1（P0）零配置导入**：选目录/git 仓库即开始索引，无需构建配置，无需网络。
- **F1.2（P0）秒级渐进索引**：性能口径见 §15；索引过程中 UI 全程可用。
- **F1.3（P0）符号模型**：见 §3.5——Symbol / DeclarationFacet / Scope / Binding / Occurrence
  五概念 + SymbolSpace（value/type/namespace/module/macro/…）。底层 kind 保留语言差异
  （Rust trait ≠ TS interface ≠ Python Protocol），UI 层可归并展示类别。
  装饰器应用、Rust attribute、impl 块作为 occurrence/relation/结构容器，不污染 Symbol 表。
- **F1.4（P0）内容寻址缓存**：ContentIndex 以内容 + 语言模式 + 提取器版本为键（§3.1）；
  项目配置变化只失效 ResolvedRelations，不重建 ContentIndex。
- **F1.5（P0）语言与能力分级**：
  - Rust / Python / TypeScript（含 TSX）：全功能目标。
  - **JavaScript：parsing/高亮/符号大纲随首发；definition/call 候选标 beta；exact 不承诺。**
- **F1.6（P0）候选式解析**：召回 + scope/binding/模块图约束 + 排序，输出永远是
  候选集 + certainty + dispatch + provenance + completeness + evidence（§4.2）。
- **F1.7（P1）精确增强（Exact Provider）**：见 §8。要点：TS7 原生 LSP 优先、
  按项目声明选择版本化工具、SCIP 作为离线事实源导入；**P1 仅支持当前 worktree**，
  历史 commit 的精确模式依赖后续的私有物化（§8.3）。
- **F1.8 依赖的四级参与**：
  - **依赖参与语义解析（P1 必需）**：crate graph、package typings、site-packages/stubs
    进入 Project Model，不必展示或全文索引。
  - 依赖源码可浏览：P2。
  - 依赖进入符号搜索：P2 可选。
  - 依赖进入全文搜索：默认关闭。
- **F1.9（P0）Safe / Trusted 双模式**：安全边界是正式产品功能，见 §8.4。

### 2.2 Context Window

- **F2.1（P0）联动**：hover 只给链接反馈 + 简短 tooltip；**单击**更新 Context Window；
  Cmd+单击/双击主窗口跳转。
- **F2.2（P0）渐进式回答**：Context Window 支持结果分级到达——
  先局部绑定（热路径），再 fuzzy 目标，精确结果就绪后原位升级并标注 provenance（§15）。
- **F2.3（P0）Follow / Pin**：Pinned 模式固定内容，误点不冲掉正在读的函数。
- **F2.4（P0）多候选**：候选切换条 + certainty/dispatch 标注。
- **F2.5（P0）递归预览**：内部可继续下钻，独立前进/后退历史。
- **F2.6（P0）局部作用域感知**：点击局部变量/参数命中词法作用域（§5）。
- **F2.7（P0）智能内容**：调用→定义；变量→绑定 + 类型；类型→定义；
  trait/interface 方法→签名 + 已知 impl 列表；import→目标模块。目标可能是
  依赖源码/生成代码/stub/内置符号——UI 按 DocumentID 类别如实展示"定义由宏生成"、
  "仅有 stub"、"位于依赖"（§3.6）。
- **F2.8（P0）长函数折叠**：默认署名 + **文档注释** + 函数体开头 + 相关行，其余折叠。
  （doc comment 展示为 P0；富文本渲染 doc 格式为 P1。）
- **F2.9（P0）查询可取消**：request token + generation；仅语义 token 变化时发起查询。

### 2.3 关系图谱 / Call Tree

- **F3.0（P0）定义**：Call Tree 是**静态源码调用候选图**，不是运行时完整调用图。
  首发**明确不当作普通调用**的机制（未来以独立 relation kind 加入）：
  Python `__call__`/property/descriptor/monkey patch/魔术方法；
  Rust `Deref`/运算符 desugar/宏展开内部调用；
  TS getter/decorator 触发/动态 import 执行/框架 DI 反射。
- **F3.1（P0）Forward / F3.2（P0）Reverse Call Tree**：逐层懒展开/上溯。
- **F3.3（P0）四维标注**：每条边 = certainty（Exact/Strong/Probable/Possible/Unresolved）
  × dispatch（direct/trait/interface/callback/dynamic/macroGenerated）
  × provenance（fuzzy/lsp/scip/languageProof）× completeness（complete/partial/truncated）。
  UI 主分组按 certainty（**Exact / Strong / Possible**——不用 "Confirmed"，
  启发式结果不冒充编译器事实），dispatch 作为边标签（如 `Exact · via trait Write`）。
- **F3.4（P0）调用者是执行区域**：caller 是 ExecutableRegion（函数/方法/闭包/模块体/
  类体/字段初始化器/装饰器应用/常量初始化器），不假设调用都在函数里（§4.1）。
- **F3.5（P0）环检测**：按当前展开路径 path-local，递归标 `↻`。
- **F3.6（P1）图视图**：局部有向图，导出 SVG/PNG/Mermaid。
- **F3.7（P1）引用列表**：走统一的 SnapshotSearchService（§12）候选召回 + tree-sitter 验证。
- **F3.8（P1）实现关系**：trait/interface → impls、方法 → overrides；与 Call Tree 同级重要。
- **F3.9（P2）类型关系**：包含/继承树。

### 2.4 Git 时间旅行

- **F4.1（P0）虚拟 checkout**：直接读 git 对象库，绝不动工作区。
- **F4.2（P0）三级就绪**：first paint（亚秒）→ cached semantic ready → full semantic ready，
  UI 显示分项覆盖状态（不压成单一百分比，§14）。
- **F4.3（P0）快照隔离**：QueryContext = snapshot + profile + generation，过期结果丢弃。
- **F4.4（P0）不可变快照**：WorktreeSnapshot 捕获时固化 dirty/untracked 内容（§6.2）。
- **F4.5（P0）忽略与排除**：CommitSnapshot 展示全部 tracked 文件（`.gitignore` 不适用于
  已跟踪文件）+ CodeInsight 排除规则；Worktree 的 untracked 按 `.gitignore` 过滤。
  依赖/产物目录（node_modules、target、venv、__pycache__、dist…）默认不索引。
  **lockfile 不作为普通源码索引，但必须进入 Project Model 用于确定依赖版本。**
- **F4.6（P0）边界情况**：symlink、submodule/gitlink、LFS pointer（识别提示，不假装是源文件）、
  shallow/partial clone、bare repo、重命名、大小写、Unicode 文件名、多 worktree、
  **SHA-1 与 SHA-256 对象格式仓库**。历史 commit 展示 raw blob（不做 filter）。
- **F4.7（P1）diff 阅读**：同文件跨 commit diff；函数级"A→B 改了什么"。
- **F4.8（P1）符号历史**：基于 SymbolLineageCandidate（候选 + certainty + 证据，§10.4）——
  lineage 不是事实，重命名/拆分/合并时如实展示不确定性。
- **F4.9（P2）Blame 集成**。

### 2.5 搜索与导航

- **F5.1（P0）符号模糊搜索**（`Cmd+T`）：名称归一化 + prefix/acronym/trigram 多路召回 +
  subsequence 打分（连续匹配、词边界、当前文件/目录、kind、最近访问加权）。
  例：`hndlconn → handle_connection`。
- **F5.2（P0）全文搜索**：统一走 **SnapshotSearchService**（§12）：快照感知、进程内、
  按 ContentID 去重扫描再投影到 occurrence。字面量搜索为原始字节实现；
  正则 M0 用 NSRegularExpression 做基线，PCRE2 为可压测的正式候选（不预先承诺 rg 级性能）。
- **F5.3（P1）结构化搜索**：tree-sitter S-expression query 起步，P2 提供 ast-grep 风格
  模式前端。不引入 ast-grep 依赖（无 C API、不快照感知），吸收其功能形态。
- **F5.4（P0）文件跳转**（`Cmd+P`）。
- **F5.5（P0）可重放跳转历史**：每项记录 snapshot descriptor + path + **contentID +
  byte offset + line/column 兜底 + 最近符号锚点**——临时快照被回收、文件改名后
  仍能定位到相同内容或相近符号。
- **F5.6（P0）当前文件符号大纲**。
- **F5.7（P1）书签与阅读笔记**：存 App 数据目录（书签所在快照因此长期保留，§10.3）。

### 2.6 UI / 视觉

- **F6.1（P0）层次化排版（克制版）**：函数定义名 +1pt、semibold、微字距、gutter 标记
  （放大幅度由 M0-B 原型定夺）；纯文本注释段落用人文字体，含 ASCII 图/表格的注释保持等宽；
  混合字体可整体关闭。
- **F6.2（P0）布局与面板预设**：`Reading / Relations / Compare / Focus`；Relations 不默认常开。
- **F6.3（P0）Profile 指示与切换**：当前 AnalysisProfile 可见可切
  （如 `Rust · workspace · default features` / `packages/app/tsconfig.json` / `.venv · Python 3.13`）。
- **F6.4（P0）主题**：SI Classic + 原创暗色，随系统切换。
- **F6.5（P0）只读铁律**。
- **F6.6（P1）多标签 / 分屏**。

### 2.7 非功能需求

- **N1 性能**：分级口径见 §15。
- **N2 原生**：AppKit/Swift 主进程；外部分析工具作为受控 helper 进程不违背原生原则。
- **N3 离线与安全**：默认完全本地、无网络、不执行项目代码（§8.4）。
- **N4 大文件**：5–10 万行单文件流畅（§9）。
- **N5 持久化与缓存生命周期**：§10.3。
- **N6 平台**：macOS 14+。

### 2.8 明确不做

编辑/保存/格式化；构建/运行/调试；Git 写操作；插件市场（早期）。

---

## 3. 数据模型（3+1 层）

```text
ContentIndex        内容本身的语法事实            键 = 内容 + 语言模式 + 提取器版本
SnapshotManifest    快照中的路径、内容与文件模式    每快照一份，不可变
AnalysisProfile     本次分析的项目配置/环境/目标/信任策略
ResolvedRelations   在 (snapshot × profile) 下的符号与调用关系
```

新增第四层的原因：同一 commit + 同一批文件，在不同配置下语义不同——
Rust 的 target/feature/cfg/edition、TS 的多 tsconfig/project references/moduleResolution/
package exports、Python 的解释器/venv/sys.path/namespace package/editable install。
**配置变化失效 ResolvedRelations，不触碰 ContentIndex。**

### 3.1 ContentIndex

```swift
struct ContentIndexKey: Hashable {
    let contentID: ContentID          // 见 §6.2：统一 ContentFingerprint
    let languageMode: LanguageMode    // ts/tsx、py 方言等
    let grammarVersion: UInt32
    let extractorVersion: UInt32
    // 注意：不含项目配置。只有改变语法解释/提取 query 的因素才进此键。
}

struct ContentIndex {
    let key: ContentIndexKey
    let scopes: [ScopeRecord]             // scope 拓扑（压缩存储）
    let bindings: [BindingRecord]         // 局部声明 + import binding
    let executableRegions: [ExecutableRegionRecord]
    let symbols: [DeclarationFacet]       // 见 §3.5
    let calls: [UnresolvedCall]
    let imports: [ImportBinding]          // 见 §7.4，不是裸字符串
    let exports: [ExportRecord]           // re-export、pub use、__init__ 转出
    let lineStarts: [UInt32]
}
```

**scope/binding 必须全量持久化**（紧凑格式），不能只在打开文件时构建——
否则 `from database import connect as open_db` 之后的 `open_db()`、
`import { send as transmit }` 之后的 `transmit()`，Reverse Call Tree 在项目级无法解析。
局部变量的完整引用位置不持久化，打开文件时再补充交互级索引。
**Scope Builder 每语言独立实现**（Python 的"函数内任意赋值即局部名"、
`global`/`nonlocal`，TS 的 var 提升/TDZ，Rust 的块级 + match 绑定——没有泛化算法）。

### 3.2 SnapshotManifest

```swift
struct FileOccurrence {
    let occurrenceID: FileOccurrenceID
    let pathID: PathID
    let contentID: ContentID          // 只指内容，不指索引状态
    let detectedLanguage: LanguageID?
    let sourceKind: SourceKind        // tracked / dirty / untracked / generated…
    let fileMode: FileMode            // regular / symlink / gitlink / lfsPointer
    let size: UInt64
}
```

manifest **不存 ContentIndexKey**——"文件树是什么"与"内容是否已索引、按什么模式索引"
解耦，通过独立映射 `(contentID, languageMode, extractorVersion) → ContentIndex` 查找。
由此：manifest 未索引完即可 first paint；同一内容可按不同语言模式尝试；
索引损坏重建不影响快照；git 文件树加载与 parser 生命周期彻底解耦。

### 3.3 AnalysisProfile / ProjectModel

```swift
struct AnalysisProfile {
    let id: AnalysisProfileID
    let projectUnitID: ProjectUnitID      // crate / tsconfig project / python package
    let language: LanguageID
    let projectRoot: PathID
    let configFingerprint: Digest         // Cargo.toml/tsconfig/pyproject 内容指纹
    let environmentFingerprint: Digest    // lockfile、venv、node_modules 布局指纹
    let toolchainVersion: String?         // 推断的 TS/Rust/Python 版本
    let target: TargetConfiguration?      // target triple / platform 条件
    let featureSet: FeatureSet?           // Rust features、TS exports conditions
    let dependencyEnvironment: DependencyEnvironment?
    let trustMode: TrustMode              // safe / trusted（§8.4）
}
```

- Project Model 由 Cargo.toml/workspace、tsconfig（含 references/extends）、
  pyproject/setup.cfg + **lockfile** 解析而来；lockfile 决定依赖版本（F4.5）。
- monorepo 中一个文件可属于多个 profile——数据模型支持多 profile，
  第一版默认自动选"最近配置文件的默认 profile"，UI 可切（F6.3）。

### 3.4 ResolvedRelations

```swift
struct RelationCacheKey {
    let snapshotID: SnapshotID
    let analysisProfileID: AnalysisProfileID
    let resolverVersion: UInt32
}
struct QueryContext {
    let snapshotID: SnapshotID
    let analysisProfileID: AnalysisProfileID
    let generation: UInt64
}
```

模块图、调用候选、倒排视图都按 (snapshot × profile) 缓存，短期、可随时重算（§10.3）。

### 3.5 符号模型（五概念）

不把一切塞进 Symbol：

```text
Symbol            用户认为可导航的实体（以 SymbolGroupID 聚合）
DeclarationFacet  该 Symbol 的一个声明/stub/实现/合并片段
Scope             名字可见范围
Binding           局部名字绑定到什么
Occurrence        定义/引用/调用/import/re-export 的源码位置
```

```swift
enum SymbolSpace { case value, type, namespace, module, macro, lifetime, label }

struct ScopeRecord   { let id: ScopeID; let parent: ScopeID?; let kind: ScopeKind; let range: ByteRange }
struct BindingRecord {
    let scopeID: ScopeID
    let localNameID: NameID
    let space: SymbolSpace
    let kind: BindingKind                 // param / let / import / assignment / pattern / global / nonlocal
    let declarationRange: ByteRange
    let targetHint: UnresolvedSymbolRef?
}
struct DeclarationFacet {
    let symbolGroupID: SymbolGroupID
    let space: SymbolSpace
    let kind: DeclarationKind             // 语言特有：rustTrait ≠ tsInterface ≠ pyProtocol
    let range: ByteRange
}
```

SymbolGroup 聚合：TS declaration merging、overload 签名组 + 实现、`.d.ts`↔实现、
`.pyi`↔`.py`、Rust trait 方法↔各 impl。Rust 的多 namespace 并存（同名 value/type/macro）、
TS 的 type/value/namespace 三面、Python 的名字绑定语义都由 SymbolSpace + Binding 表达。

### 3.6 DocumentID —— 目标不总是快照内文件

```swift
enum DocumentID {
    case snapshotFile(SnapshotID, PathID, ContentID)
    case externalPackage(PackageID, PathID)          // 依赖源码 / lib.d.ts / stubs
    case generated(AnalysisProfileID, GeneratedDocumentID)  // 宏展开、build 产物
    case builtin(LanguageID, StringID)               // 内置符号
}
```

Context Window 据此如实呈现："定义位于依赖源码"、"定义由宏生成"、
"只有 stub，无可见实现"、"生成源码当前不可用"。

---

## 4. 调用解析

### 4.1 调用点与执行区域

```swift
enum ExecutableRegionKind {
    case function, method, closure
    case moduleInitializer      // Python module body / TS top-level
    case classBody              // Python class body / TS static block
    case fieldInitializer, decoratorApplication, constantInitializer
}

struct UnresolvedCall {
    let regionID: ExecutableRegionID      // 不假设调用在函数里
    let nameID: NameID
    let range: ByteRange
    let syntacticKind: CallKind           // directCall / methodCall / qualifiedCall
                                          // / indirectCall / macroInvocation / decoratorApply
    let qualifierRange: ByteRange?
    let receiverRange: ByteRange?
    let argumentCount: UInt16?
}
```

### 4.2 候选 = 四个正交维度

```swift
struct ResolutionCandidate {
    let target: SymbolOccurrenceID        // target 文档为 DocumentID（§3.6）
    let certainty: Certainty              // exact / strong / probable / possible / unresolved
    let dispatch: DispatchKind            // direct / virtual / trait / interface / callback
                                          // / dynamic / macroGenerated
    let provenance: ResolutionProvenance  // fuzzyResolver / lsp / scip / languageProof
    let completeness: Completeness        // complete / partial / truncated / unknown
    let evidence: [ResolutionEvidence]
}
```

维度正交的意义：Rust trait 方法调用点可以 **Exact**（确定经由 `Write::write`）
同时 dispatch=trait（运行时多 impl）；TS callback 可因类型信息 Exact；
Python 无标注 `obj.close()` 是 possible · dynamic。UI 示例：
`Strong · direct`、`Exact · via trait Write`、`Possible · dynamic receiver`、
`Partial · generated by macro`。

**certainty 语义**：`Exact` 只来自精确 provider 或语言规则可证明唯一的绑定
（且需检查内层 scope shadowing、Python 的后续 rebinding——`run = fake_run` 之后的
`run()` 不能因顶部 import 就标高）；启发式最高只到 `Strong`，不冒充编译器事实。
`completeness=truncated` 用于预算耗尽的模块图/召回（§7.3），不伪装成"无结果"。

### 4.3 Call Tree 行为

- Reverse：posting 召回 → 定位 ExecutableRegion → 按 certainty 分组（Exact/Strong/Possible），
  dispatch 作边标签；trait/interface 方法先按"经由 trait X"聚合再展开到 impl。
- 懒加载；path-local 环检测；证据可展开。
- 排除机制清单见 F3.0——宁可少承诺，不静默混入。

---

## 5. Context Window 解析

### 5.1 两级索引（修订）

- **持久化**（全部文件）：scope 拓扑、局部声明、import binding、执行区域、符号、调用。
- **打开文件时补充**：完整局部引用索引（每个局部变量的所有读写位置）、交互级 tree。

### 5.2 解析顺序

```text
当前最内层词法作用域（含 shadowing 检查）
→ 外层区域参数与局部绑定（含赋值 rebinding）
→ self / this / 所在 impl / class 成员
→ 文件顶层绑定 + import binding（含 alias）
→ 模块图可达定义（profile 约束下，§7）
→ 全项目候选（降级 certainty）
```

### 5.3 声明 / stub / 实现

默认展示实现，保留切换：`.d.ts`↔实现、`.pyi`↔`.py`、trait 签名↔各 impl、
overload 组↔实现体。由 SymbolGroup 支撑（§3.5）。

### 5.4 渐进式回答

```text
~10ms   局部绑定命中（热路径，纯内存）
~40ms   fuzzy 项目级目标 + certainty 标注
之后    exact provider 结果到达 → 原位升级为 Exact，标 provenance
```

Follow/Pin、request token、语义 token 去抖同 F2.x。

---

## 6. Git 层与不可变源

### 6.1 源模型

```swift
enum GitObjectFormat { case sha1, sha256 }        // 不硬编码 SHA-1

struct SourceLocator {                            // 字节从哪取
    // repoID + git OID（含 objectFormat），或 App content-store key
}
typealias ContentFingerprint = Digest             // 统一 BLAKE3，对原始字节计算
// ContentID 采用统一 ContentFingerprint —— clean blob 与 dirty 文件相同字节必须去重；
// git OID 仅作 SourceLocator 与加速（已知 OID→fingerprint 映射可缓存）。

protocol SourceProvider {
    func open(_ source: SourceHandle) async throws -> SourceBuffer   // 流式/mmap，不强制整块 Data
}
```

### 6.2 WorktreeSnapshot 真正不可变

捕获时刻固化，之后不再按实时路径读：

```text
clean tracked 文件   记录 git blob locator（对象库天然不可变）
dirty / untracked   读取稳定字节 → 算 ContentFingerprint → 写入 App 私有 content store
                    → manifest 指向这份不可变副本
读取                 一律经 SourceHandle，绝不重读实时路径
```

杜绝"枚举时是内容 A、索引时文件已被外部编辑器改成 B、manifest 仍声称是 A"的竞态。
generation 防的是跨快照串线；不可变捕获防的是快照内部漂移——两者都要。

### 6.3 切换与就绪（同 F4.2/F4.3）

```text
1. 构建不可变 SnapshotHandle（libgit2 tree 遍历，百 ms 级）
2. first paint：文件树 + 打开文件切换                       ← 亚秒验收
3. cached semantic ready：ContentIndex 命中部分立即可查
4. full semantic ready：新内容后台索引，UI 显示分项覆盖状态
```

### 6.4 边界情况

见 F4.6。历史 commit 一律 raw blob；LFS pointer 识别并提示；
submodule/symlink 按 fileMode 呈现；SHA-256 仓库按 objectFormat 处理。

---

## 7. 候选模块图（per-profile）

模块图是**候选图**，按 AnalysisProfile 解析，结果带 certainty/completeness。

### 7.1 Rust —— 内置 resolver P0 范围（明确声明）

```text
支持：普通 Cargo workspace、默认 features、lib/bin crate roots、
     常规 mod/use/alias（crate/self/super、use as）、有限 glob/re-export、inline mod
不支持（标 unresolved/generated/profile-dependent）：
     #[path]、cfg 条件裁剪、OUT_DIR 生成内容、include!、build.rs/proc macro 执行、
     example/test crate roots（P1 补）、extern prelude 边缘、macro namespace 完整解析
```

### 7.2 TypeScript —— 版本化 resolver

真实解析涉及 moduleResolution 模式、package exports/imports 及条件、self-name import、
typesVersions、扩展名替换、ESM/CJS、project references、extends、rootDirs、
`.d.ts`↔运行时实现映射。且 **TS7（2026-07 发布）已移除 baseUrl/node10/classic**——
所以不是"实现一套最新规则"，而是：

```text
从仓库声明/lockfile 推断 TypeScript 版本
→ 选择对应版本的 resolver 语义
→ 无法确定时输出候选 + 证据
```

内置 fuzzy resolver P0 覆盖常见子集（相对路径、paths/baseUrl 按版本、exports 主条件、
index 约定、有限 barrel 跟随），其余交给 exact provider 或标 unresolved。

### 7.3 Python —— Import Candidate Graph

支持：regular/namespace package、src-layout、相对 import、多 source root、`.pyi`、
常见 `__init__` re-export。遇到 import hook、动态 sys.path、importlib、条件 import、
运行时生成模块 → 明确降级（unresolved/dynamic），不猜。

### 7.4 ImportBinding（不是裸字符串）

```swift
struct ImportBinding {
    let moduleSpecifier: StringID
    let importedName: NameID?      // from foo import bar 的 bar
    let localName: NameID?         // as 别名后的本地名（import foo.bar 绑定的是 foo！）
    let kind: ImportKind
    let flags: ImportFlags         // wildcard / reexport / typeOnly / conditional / dynamic
    let scopeID: ScopeID
    let range: ByteRange
}
```

### 7.5 遍历预算（取代"固定 8 层"）

固定深度会造成"7 层能跳 9 层不能跳"的不稳定。改为：
环检测 + memoized 传递闭包 + 强连通分量折叠 + **节点/边/时间预算**；
超预算返回 `completeness = truncated`——诚实表达不确定性在模块层的对应实现。

---

## 8. 精确增强与信任边界

### 8.1 ExactProvider 协议

```swift
protocol ExactProvider {
    var capabilities: ExactCapabilities { get }   // definition / references / implementations
                                                  // / typeHierarchy / callHierarchy / hover / generatedSource
    var supportedSnapshotKinds: SnapshotSupport { get }
    var requiresMaterialization: Bool { get }
    var requiresTrustedExecution: Bool { get }
    var toolVersion: String { get }
    func prepare(snapshot: SnapshotHandle, profile: AnalysisProfile) async throws -> ExactSession
}
```

按能力声明接入，不是单一"Exact"开关。外部工具跑在独立 helper 进程（XPC），
不违背原生原则——原生 UI ≠ 一切分析链接进主进程。

### 8.2 Provider 策略（2026-07 生态）

```text
TypeScript  TS7 项目 → 原生 TS7 LSP（Go 实现，helper 进程；7.1 API 稳定后再评估进程内集成）
            旧项目 → 按版本用 TS6 tsserver
Rust        rust-analyzer（注意其 build script 默认执行 → 受 Trust Mode 管控）
Python      Pyright / BasedPyright
SCIP        已有索引直接导入为离线事实源；scip-* 工具作批处理备选，非唯一路径
```

SCIP 主要给 symbol identity/occurrence/关系，不保证完整调用图——
Call Tree 仍需"SCIP 符号身份 × tree-sitter 调用表达式"结合。

### 8.3 历史快照的精确模式 = 物化

外部工具要看真实目录，libgit2 虚拟快照 ≠ 可分析工作区。策略：

```text
Fuzzy        worktree + 一切历史 commit 永远可用（虚拟读取）
Exact P1     仅当前 worktree
Exact 历史   后续版本：commit 物化到 App 私有缓存目录（绝不动用户工作区），
             按 (commit tree × profile × dependency fingerprint × tool version × config) 缓存复用
```

### 8.4 Safe / Trusted 双模式（正式产品功能）

审计用户打开的仓库可能不可信；rust-analyzer 默认会执行 build.rs，proc macro 在
编译期执行任意代码——"想要精确跳转"不能变成"悄悄运行了恶意构建脚本"。

```text
Safe Reading Mode（默认）
    不执行项目代码 / build.rs / proc macro；不加载项目语言服务插件；
    不自动安装依赖；不联网；fuzzy 索引始终全功能

Trusted Exact Mode（按仓库显式授权）
    启动外部精确 provider（独立 helper/XPC）；项目目录只读挂载；
    写入仅限 App 私有缓存；默认无网络；CPU/内存/时间限额
```

**Exact 不自动覆盖 fuzzy**：精确结果携带 provider/toolVersion/profile/生成时间/
coverage/trustMode；若精确索引来自过期物化或错误 profile，UI 显示 provenance 并允许切换。

---

## 9. 渲染层（TextKit 2）

### 9.1 坐标：字节为权威

`ByteRange` 是引擎权威坐标；UTF16Range 仅展示层转换。打开文件维护
newline offsets + UTF-8↔UTF-16 checkpoint，点击定位二分，不从头遍历。

### 9.2 大文件策略（依据 M0-B 探针实测修订，数据见 Prototypes/TextKitProbe/FINDINGS.md）

M0-B 实测（10 万行 / 3MB 合成 Rust）确认视口门控收益巨大（实际写属性 196 个
fragment 对全量 13 万，快 1.95s、省 191MB），但也发现 **lazy API ≠ lazy 成本**：
AppKit 仍对全部 10 万 fragment 做预验证，lazy 路径首屏 3.46s / 459MB。据此修订：

- 只有打开文件解码；只保留活跃标签页的 tree。
- 高亮/排版属性用 **TextKit 2 viewport 驱动的 rendering attributes**（机制中立表述——
  实测 NSTextContentStorage delegate 与不带范围判断的 renderingAttributesValidator
  都会退化为全文件工作），validator 内必须再做 viewport+buffer 范围门控。
  **验收指标是"实际写属性的 fragment 数"，不是"是否用了 lazy API"。**
- 高亮存储坐标一律 byte range，视口命中后才经 checkpoint 转 NSRange；
  不预先为全部 token 保存 UTF-16 range。
- 可变字号是 layout 属性而非纯颜色高亮：默认幅度（+1/+2pt）待人工滚动检查定；
  行高跳动明显则固定行高或退回 +1pt。
- **行距是一等排版参数**（2026-07-20 人工验收：系统默认行距偏紧）：主工程阅读区
  默认 lineHeightMultiple 待在 1.15/1.25/1.35 中人工扫值确定，且必须用户可调。
  巨档成本实测（10 万行）：1.3 倍行距 ≈ 首屏 +11%、内存 +25%，常规档可忽略——
  不构成放弃加大行距的理由。
- 不构造数十万 attribute run 的巨型 attributed string。
- **自定义 content provider / 分块 backing store 明确不进当前架构**（决策 c，
  2026-07-20）：接受原生 NSTextView 路径的实测上限，性能预算按文件规模分档（§15）；
  仅当真实用户数据表明分档预算不可接受时才重启该方向。

### 9.3 排版

同 F6.1。SI Classic + 暗色主题；M0-B 原型定放大幅度。

---

## 10. 存储、内存与缓存生命周期

### 10.1 紧凑格式

名字/路径/签名全部 intern（NameID/PathID/SigID）；range 用 UInt32 字节偏移；
按 ContentIndex SoA 连续存储；不存源码片段（按 SourceLocator 现读）。

### 10.2 倒排表：内容级 posting + manifest 求交

**不为每个 commit 重建 `name → [SymbolOccurrence]`**。维护全局内容级 posting：

```text
nameID → [(ContentIndexKey, localSymbolID)]   （delta 编码）
```

查询时与当前 manifest 的 ContentIndex 集合求交——时间旅行不复制倒排表。

### 10.3 缓存生命周期

```text
ContentIndex            长期缓存，按内容使用频率回收
SnapshotManifest        当前 + 最近历史 + 带书签/笔记的快照保留，其余回收
ResolvedRelations       短期缓存，可随时重算
ExactProvider 产物      按 snapshot × profile × toolVersion 管理
Source blob / 捕获内容   独立 LRU
```

另需：磁盘配额与项目级 LRU、schema 版本迁移、写入中断恢复（事务化）、
损坏检测与整层重建（重建 ContentIndex 不影响 manifest，§3.2 解耦的收益）。

### 10.4 符号 lineage（支撑 F4.8）

```swift
struct SymbolLineageCandidate {
    let from: SymbolOccurrenceID
    let to: SymbolOccurrenceID
    let confidence: Certainty
    let evidence: [LineageEvidence]   // qualified name / kind / container /
                                      // signature+body fingerprint / git rename / 位置相似度
}
```

lineage 是候选不是事实；signature/body fingerprint 在 M0-A 提取阶段就预留字段。

### 10.5 P0 持久化范围

```text
scopes / bindings / executableRegions / declarationFacets(symbols) /
calls / importBindings / exports / impl-implements 关系
```

普通标识符引用不全量持久化——引用列表走 SnapshotSearchService 召回 + 验证（F3.7）。

---

## 11. 索引流水线

```text
Enumerator → [bounded] → Source Capture/Loader → [bounded] → Parser Workers
→ [bounded] → Extractor（scope builder + facet + call + import）
→ Single Batched Store Writer（SQLite 单写者事务）→ Snapshot Publisher
```

- 背压、大文件按字节加权、可取消、UI 查询高 QoS / 后台索引低优先级、中断可恢复。
- worktree 捕获（§6.2）发生在 Enumerator/Loader 阶段：dirty 内容先固化再入队。
- tree-sitter：容错是核心价值；只读场景不做增量 edit sequence；
  全项目 tree 不常驻；打开文件的 tree 保留。
- 单进程为 M0/M1 实现选择；引擎暴露 `IndexServiceProtocol`，预留 XPC 演进
  （exact helper 从第一天就是独立进程）。

---

## 12. SnapshotSearchService（统一搜索服务）

全文搜索（F5.2）与引用召回（F3.7）共用一条管线：

```text
SnapshotManifest → 按 ContentID 去重 → SourceProvider 取字节
→ literal byte prefilter → literal / regex matcher
→ 命中投影到该内容的所有 FileOccurrence → generation 检查 → 流式发布
```

同一内容出现在十个路径只扫一次，投影十次。

如实认领工程量（不轻描淡写）：git pack/blob 解压、编码与无效 UTF-8、二进制判定、
超大文件策略、并发调度、结果流与取消、上下文行提取、regex 资源限制（每文件大小/
总结果数/超时预算）、字节→UI 坐标转换。

引擎分层：**字面量搜索 = 原始字节实现**（大多数代码搜索是标识符/字面量）；
正则 = NSRegularExpression 仅作 M0 基线（其 UTF-16 路径有解码/复制成本），
**PCRE2 是可压测的高性能正式候选**——不预先承诺 rg 级性能（rg 的速度还来自
literal extraction/mmap/SIMD/并行策略的总和）。若未来历史快照物化落地，
rg 可作对照基准或备用实现（它不能读虚拟 blob，但能读物化目录）。

---

## 13. 技术选型汇总与架构

| 组件 | 选择 | 说明 |
|------|------|------|
| UI | AppKit 为主，SwiftUI 轻量界面 | NSOutlineView / NSTextView / NSSplitView |
| 文本 | TextKit 2 只读 | §9 |
| 解析 | tree-sitter，直接 C interop 为正式路径 | 版本固定进 ContentIndexKey；CI 双测 wrapper 与 C API |
| Git | libgit2 | raw blob、SHA-1/SHA-256、纯读 |
| 存储 | SQLite + intern/posting 紧凑内存结构 | §10 |
| 并发 | Swift Concurrency + bounded channel | §11 |
| 搜索 | SnapshotSearchService（字节字面量 + NSRegularExpression→PCRE2） | §12 |
| 精确 | ExactProvider helpers：TS7 LSP / tsserver / rust-analyzer / Pyright / SCIP 导入 | §8，受 Trust Mode 管控 |
| 图渲染 | NSOutlineView 树主力；P1 自绘局部图 | |

```text
┌──────────────────────── AppKit UI ────────────────────────┐
│ Reader │ Context │ Relations │ Git │ Profile Selector     │
└───────────────────────────┬───────────────────────────────┘
                            │ QueryContext = snapshot + profile + generation
┌───────────────────────────▼───────────────────────────────┐
│ Query / Resolution Engine                                 │
│ ScopeGraph → Binding → ModuleGraph → Candidates           │
│ certainty + dispatch + provenance + completeness          │
└──────────────┬──────────────────┬─────────────────────────┘
               │                  │
┌──────────────▼───────────┐  ┌───▼───────────────────────┐
│ SnapshotManifest         │  │ AnalysisProfile / Project │
│ immutable path→content   │  │ config/env/target/trust   │
└──────────────┬───────────┘  └───┬───────────────────────┘
               │                  │
┌──────────────▼──────────────────▼─────────────────────────┐
│ ResolvedRelations + ExactProviderOverlay                  │
│ key = snapshot × profile × resolver/tool version          │
└──────────────────────────▲────────────────────────────────┘
                           │
┌──────────────────────────┴────────────────────────────────┐
│ ContentIndex Store                                        │
│ scopes / bindings / symbols / calls / imports / regions   │
└──────────────────────────▲────────────────────────────────┘
                           │
┌──────────────────────────┴────────────────────────────────┐
│ Immutable Source Store / Git Object Provider              │
│ worktree capture / commit blob / external / generated     │
└───────────────────────────────────────────────────────────┘
```

---

## 14. UI 布局

```
┌────────────────────────────────────────────────────────────────────┐
│ ⌘T 符号…   ⎇ main ▾ ● a3f21c ▾   Rust·workspace·default ▾    ⚙   │
├──────────┬───────────────────────────────────┬─────────────────────┤
│ 文件树    │                                   │ Relation Window     │
│──────────│         阅读区（只读）              │ ◂ Callers  Calls ▸  │
│ 符号大纲  │   （标签页 / 可分屏）               │ ▾ Exact (3)         │
│          │                                   │ ▸ Strong (2)        │
│          │                                   │ ▸ Possible (7)      │
├──────────┴───────────────────────────────────┴─────────────────────┤
│ Context ⚲Follow|Pin ‹2/3› src/net/socket.rs:1042  Strong·direct   │
│   pub async fn send_msg(&mut self, buf: &[u8]) -> io::Result<…> { │
└────────────────────────────────────────────────────────────────────┘
状态栏（按需出现）: Indexing 31 files… │ Imports resolved 72% │ Exact unavailable (Safe Mode)
```

- 覆盖状态**分项展示**（Files indexed / Imports resolved / Exact coverage /
  当前查询 complete·partial·truncated），不压成单一 `[semantic 87%]`。
- 顶栏含 Profile 切换器（F6.3）；commit 切换器一等公民。
- 面板预设 Reading / Relations / Compare / Focus；全键盘可操作。

---

## 15. 性能目标与测量口径

p50/p95 验收；记录环境（文件数/字节/行数/文件大小分布/冷热缓存/峰值 RSS/索引大小）。

**打开文件分四级 × 按规模分档**（决策 c，依据 M0-B 实测调整预算本身）：

```text
四级：first visible text → syntax visible（视口）→ document parsed（后台）→ semantic ready
```

| 档位 | 范围 | first visible | syntax visible | 稳定内存 |
|------|------|--------------|----------------|---------|
| 常规 | ≤1 万行（绝大多数源码文件） | **< 100ms**（核心卖点） | < 200ms | 文件字节的常数倍 |
| 大 | 1–5 万行 | < 500ms | < 1s | < 250MB |
| 巨 | 5–10 万行+ | < 2.5s（纯文本先行，parse/高亮转异步） | 异步补齐 | < 600MB |

说明：巨档预算来自 M0-B 实测——lazy 全同步路径 3.46s/459MB，其中 parse 737ms +
高亮索引 492ms 可移出首屏路径，纯文本首屏 ~2.2s 是原生 NSTextView 的现实下限；
接受之，不投入自定义 content provider（§9.2）。巨档文件占真实仓库比例极小
（tokio 717 文件最大者远小于此），预算劣化影响面有限；分档阈值按行数先行，
实现时可换算字节数。

**Context Window 分温度**：

```text
Hot   当前快照、索引与源码缓存命中          p95 < 50ms
Warm  索引命中、需读取/解压 blob            p95 < 150ms
Cold  等待后台索引或 exact provider         先返回局部/fuzzy，异步原位升级（§5.4）
```

**commit 切换**：first paint < 1s（p95）；cached/full semantic ready 分别记录。
**冷启动** < 500ms；**空载内存** < 100MB；内存分档测量（空载/未索引/中型/大型/
巨文件打开/索引器峰值）。

---

## 16. 里程碑

**M0 = 四个并行技术原型**；语义正确性用两类测试：
**人工语义 fixture（精确断言、持续回归）+ 大型真实仓库（性能与分布）**。

| 阶段 | 内容 | 验收 |
|------|------|------|
| **M0-A 索引与解析质量** | 引擎 module + CLI。**Fixture**：Rust（use alias/glob/cfg/trait dispatch/closure/inline mod/#[path]/feature/proc-macro 占位）、Python（import alias/rebind/global/nonlocal/class scope/closure/namespace pkg/typed·untyped receiver/decorator）、TS（type-value/declaration merging/overload/barrel/project refs/exports conditions/shadowing）。**仓库**：ripgrep + tokio + 一个 cfg/proc-macro 密集项目；Django + 一个类型标注充分项目；TS 或 VS Code 子项目 + React/TSX monorepo | fixture 全绿；gold set：Top-1/Top-5、Exact/Strong 精度、Possible 召回、无结果率、**错误标高率**；速度基线 |
| **M0-B 文本渲染** | 10 万行文件 + 混合字号/注释字体/高亮/滚动/复制/byte↔UTF-16（含 CJK/emoji） | 四级打开指标达标；排版幅度结论 |
| **M0-C Git 快照** | worktree 不可变捕获（dirty/untracked 固化）、commit 快照、相邻/远距切换、重命名、blob 复用、generation 防串 | 三级就绪计时；并发切换无串线；捕获后外部修改文件不影响快照 |
| **M0-D Exact + 信任边界 spike** | Rust/TS7/Python 各一个 worktree 跑通 helper 生命周期、profile 指纹、Safe Mode 验证不执行项目代码、历史物化最小闭环 | 外部工具与虚拟 Git 架构共存的可行性结论 |
| **M1 Reader Alpha** | 壳 + 阅读区 + 文件树 + 符号搜索 + Context Window（Follow/Pin、局部作用域、渐进回答）+ 跳转历史 | 用它读 tokio/Django 不想切回 IDE；冷启动/内存达标 |
| **M2 Relations Alpha** | 双向 Call Tree（四维标注、分组、证据）+ 实现关系 + 全文搜索 | 分组可信；懒展开流畅 |
| **M3 Product MVP** | Git 时间旅行完整（三级就绪 + 覆盖状态 UI + 跨版本历史）+ 面板预设 + 排版系统 | 任意 commit first paint < 1s；无串线 |
| **M4 正式版** | Exact Provider（P1 范围：worktree）+ Trusted Mode + diff 阅读 + 缓存生命周期完整 | 三语言按 gold set 达标者标正式，未达标者 beta |

---

## 17. 风险与对策

| 风险 | 对策 |
|------|------|
| Python 动态类型致调用图噪声 | 四维标注；无标注 receiver 诚实 possible·dynamic；类型标注/exact 升级 |
| Rust proc macro/生成代码不可见 | dispatch=macroGenerated + DocumentID.generated 如实展示；exact provider 覆盖；不自研宏展开 |
| TS 项目配置复杂度（exports/references/版本差异） | 版本化 resolver + P0 范围明确声明（§7.2）；解析不动标 unresolved；exact 补 |
| AnalysisProfile 判定错误（选错 tsconfig/feature） | Profile 可见可切（F6.3）；结果带 profile 标注；多 profile 数据模型 |
| 不可信仓库安全 | Safe Mode 默认 + Trusted 显式授权 + helper 沙箱限额（§8.4） |
| 三层+profile 模型实现复杂度 | M0-A CLI 先打通全模型；fixture 逐规则回归；分层可独立重建 |
| TextKit 2 大文件性能 | 已由 M0-B 探针量化（lazy 门控收益 + 全量预验证成本），按 §15 分档预算接受；validator 需 viewport 二次门控（§9.2） |
| 快照串线/内部漂移 | generation 全链路 + 不可变捕获（§6.2）；M0-C 并发测试 |
| 自研搜索性能不达标 | 字节字面量快路径 + PCRE2 候选压测 + 预算限额；不承诺 rg 级 |
| 缓存无限增长 | §10.3 生命周期 + 配额 + LRU |
| tree-sitter Swift 工具链兼容 | C interop 正式路径；版本进缓存键；CI 双测 |
| AppKit 开发效率 | 接受；SwiftUI 非核心界面；引擎 CLI 化测试 |

---

## 18. 决策与待定

**已决策**：

1. macOS 原生（AppKit），macOS 14+；主进程 + exact helper（XPC）架构。
2. 首发 Rust/Python/TypeScript；JS 能力分级（parsing/大纲首发，候选 beta，exact 不承诺）；
   C/C++、Go 后续。
3. 数据模型 3+1 层；关系缓存与查询绑定 snapshot × profile；配置变化不重建 ContentIndex。
4. Call Tree = 静态源码调用候选图；UI 用 Exact/Strong/Possible；启发式不冒充 Exact。
5. Safe Reading Mode 默认（不执行项目代码），Trusted Exact Mode 按仓库授权。
6. Exact P1 仅 worktree；历史 commit 精确模式待私有物化（后续版本）。
7. 搜索统一 SnapshotSearchService；字节字面量 + NSRegularExpression 基线 + PCRE2 候选；
   不引入 rg/ast-grep 依赖。
8. 首版直接分发 + 公证；App Store 留作后续选项。
9. lockfile 进入 Project Model；依赖参与语义解析（P1）与依赖可浏览（P2）分离。

**待定**：

1. 正式产品名（CodeInsight 撞名，仅作代号）。
2. 开源与否。
3. 各语言 beta→正式阈值数值（待 M0-A gold set；预期 Rust/TS 先达标，
   Python 方法解析长期依赖 exact 补强）。
4. TS7.1 稳定 API 发布后，TS 精确集成是否从 LSP helper 迁移为库集成。
5. 历史快照物化的磁盘配额与默认开关（待 M0-D 数据）。
