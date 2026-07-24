# M5 实现计划：Rust 深化 + UIUX 精修（Planner: Fable 5, 2026-07-24）

> 本文件为独立评审文档，尽量自包含。基于 HEAD `bca314a` 实地核查代码产出，非凭
> backlog 想当然。切片 S1–S9 单工作树串行派发。
>
> **给评审者的阅读提示**：第 §0 交代项目背景与本轮定位（§0.5 是 Source Insight
> 视觉签名对照——本轮 UX 半边的选题依据）；§1 是实地核查结论（含发现
> 的一个真实潜在 bug 与两处省事结论）；§2 范围裁决；§3 切片明细（每片带"无头可证
> / 人工目视"分界）；§4 派发顺序与冲突；§5 风险；§6 是本项目反复踩坑后固化的**验收
> 铁律**——评审时请重点看每片验收是否符合这些铁律，它们不是形式主义，每一条背后都
> 有一次真实事故。

---

## §0 背景与本轮定位

**产品**：Cairn（代号 CodeInsight），macOS 原生**只读**代码阅读器（AppKit + TextKit 2，
SwiftPM，Swift 6 严格并发）。灵感源自 Source Insight，核心卖点：超快实时符号索引、
底部 Context Window（随光标显示定义）、双向 Call Tree、快速 git commit 切换且切换后
仍可做跳转/引用/Context 语义操作、四维不确定性标注（"永远给结果，同时诚实表达不确定
性"）、entirely read-only。

**已完成**：M0（四原型）→ M1 Reader → M2 Relations → M3 Git 时间旅行 → M4 正式版
（Rust-only：Exact Provider via rust-analyzer、Safe/Trusted 双模式、跨 commit diff、
SQLite 索引持久化、vendored 静态关网络 libgit2 + 发布工程）→ backlog 清理轮 →
UI 产品级打磨 6 片（品牌+空态、顶栏、Profile 指示器、状态栏、视觉语言、App 图标）。

**基线数字**（评审可据此校准）：`swift test` **233 全绿**；`ci.sh` 通过；8 条 self-test
集成通道 exit 0（`--self-test` / `-open` / `-project`（git+非 git 双语料）/ `-switch` /
`-history` / `-pin` / `-exact` / `-diff`）；双语料 gold set（ripgrep 14.1.1 + tokio
1.47.1）nostrong=0；canonical dump 逐字节零 diff；空载内存 0/20 次超 100MB 预算
（~19.4MB）；放大窗口内容撑满；侧栏 65/35；extractorVersion=5。

**决策者定的方向（原话转述）**：「继续打磨 UIUX，以及对 Rust 的支持，再复制到其他
语言。」即：**先把单语言(Rust)体验 + 整体 UX 打磨到可发布产品级，之后再把语言面复制
到 TS/Python；明确不并行铺三语言**。理由：design §16/§18 首发承诺三语言，但现状引擎
实为 Rust-only（`ProjectIndexer` 硬编码 `.rs`、`ModuleMap` 只认 main.rs/lib.rs/mod.rs），
补全 TS/Python 整语言面 ≈ 再来一个 M0–M4 的量级（各语言自己的 tree-sitter 提取器 +
模块解析 + exact provider + gold set 达标）。先做 Rust + UX，降低风险、先有可发布物。

**编排分工**：Planner=Fable 5 规划；Codex（GPT-5.6 Sol，effort xhigh）实现；
Opus 监工逐片验收 + 末尾终审。每片不 commit，由监工验收后提交。

**最小充分集判断（Fable）**：本轮"Rust 达到可发布产品级"的最小充分集 =
**S1+S2（AnalysisProfile 真实化与可切，多语言接缝地基）+ S3（receiver 类型建模，
Calls 树从"名字匹配"升到"类型证明"）+ S4（依赖落点展示，打通 exact 跳依赖的死路）+
S5（多标签，F6.6 P1 的最后一块阅读工作流缺口）** 为功能半边；**S6+S7（Source
Insight 视觉签名补全：声明排版分级 + 阅读区行号/当前行/同名高亮，见 §0.5）为 UX
半边的主体**——它们直接对应决策者「打磨 UIUX」方向与"现代版 Source Insight"的产品
定位，本轮不再视作可裁剪缓冲；仅 S8（SearchPanel 整治）保留缓冲属性可裁剪；
历史 exact **无需专门切片**（见 §1，M4-S7 已交付全链路）。

### §0.5 Source Insight 视觉签名对照（本轮定位校准）

产品是"现代版 Source Insight"（design.md v3 标题即此），但截至上一轮，UI 打磨集中在
品牌/空态/顶栏/状态栏等"壳"层，**SI 真正的视觉辨识度反而没对表**。SI 的视觉核心是
一件事：**把代码渲染成"文档"而不是"字符流"**——声明像标题一样从正文里浮出来，引用
处按身份着装，扫一眼就能看清文件结构（SI4 手册：Syntax Formatting = Declaration
Styles "Declare…" + Reference Styles "Ref to…" + Highlight References，样式含字号/
粗细/斜体分级，非仅配色）。逐项对照现状：

| SI 视觉签名 | Cairn 现状（实地核查，证据见 §1 A 轨） | 归属 |
|---|---|---|
| **Declaration Styles**：函数/结构/类/宏等**所有**声明名按类别放大加粗，如文档标题 | 仅函数定义名 +1pt semibold；struct/enum/trait/mod/const/typeAlias 声明名与普通文本无任何区分（八分之一个 SI） | **S6** |
| 注释散文用比例字体、代码保持等宽；混合字体可整体关闭（F6.1 原文承诺） | `humanistComments` 已有但默认关且无 ASCII 图表保护（开了会毁图）；无总开关 | **S6** |
| 行号槽 + 声明处 gutter 标记（F6.1 原文承诺过"gutter 标记"，至今未做） | 主阅读区**无行号槽**；仅 Compare 有 7px diff 色条 ruler | **S7** |
| 当前行高亮（SI4 显示选项） | 无；跳转只有 findIndicator 闪烁一次 | **S7** |
| Highlight References：点选符号 → 全文引用高亮 | 无；点击只驱动底部 Context | **S7**（词法同名版，诚实不冒充语义，见切片红线） |
| Symbol Window（文件符号列表常驻） | 已有：侧栏 Outline 窗格 | 已达成 |
| Context Window / Relation Window 三窗联动 | 已有，产品核心卖点 | 已达成 |
| SI Classic 配色 | 已有 siClassic 主题 | 已达成 |
| **Reference Styles**（引用处按 local/param/member/const 分样式，SI 排版的另一半） | 无；且依赖 design §5.1"打开文件时补充完整局部引用索引"这块尚未建的基础设施 | 推后 M6（§2） |
| 书签（F5.7 P1）、Relation Window 随光标自动跟踪 | 无 | 推后 M6（§2） |

结论：SI 的"骨架"（三窗联动、Context/Relations、Classic 主题）已经齐了，缺的是
"皮肤"——排版分级只做了函数名一类，阅读区裸奔（无行号/无当前行/无引用高亮）。这
正是"看着像 demo 还是像产品"的分界线，也是本轮 UX 半边（S6/S7）的选题依据。

---

## §1 现状核查结论（实地读代码）

### A 轨 UIUX

| 候选项 | 核查结果 | 证据 |
|---|---|---|
| F6.1 ASCII 图/表格注释保护 | **未做**。`applyTypography` 对 `.comment` span 无条件换 `NSFont.systemFont`（humanist 开时）；无图表检测。缓解：`humanistComments` 默认 **false** | `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift:443-448`；`ReaderSettings.swift:36` |
| 多标签 F6.6 | **未做**。MainWindowController 无 tab 结构，单 `displayedDocument` | 全文件 grep 零命中 |
| SearchPanel 5000 命中 | 模型层 34ms 节流 + 全量 `reloadData`，无显示上限、无诚实截断行 | `SearchPanel.swift:10,386` |
| Profile 指示器（C3 产物） | 纯指示器：标题 = `语言 · 根目录名 · Safe/Trusted`，菜单只有 Trust 动作 + 一行"Profiles are detected from project configuration"解释文案，**不能切** | `MainWindowController.swift:1006-1082` |
| AX 专项 / huge syntaxVisible | 均未做（backlog 原样） | — |
| **SI 视觉签名缺口（本轮补查，§0.5 的证据）** | 样式分级仅函数名：`applyTypography` 只特判 `.functionName`（+1pt semibold + kern）与可选 `.comment`，其余 token 只有颜色；`HighlightKind` 仅 6 类（keyword/comment/string/number/functionName/typeName），无"声明 vs 引用"之分；主阅读区无行号槽（仅 Compare 装 `DiffGutterRulerView`）、无当前行高亮、无同名/引用高亮 | `CodeInsightReaderUI.swift:416-453`（typography）、`:296-298,505`（diff ruler）；`CodeInsightReaderCore.swift:6-13`（HighlightKind）；`MainWindowController.swift:2433`（ruler 安装判空处） |
| **其它粗糙处（Fable 剪代码发现）** | exact 落点在依赖源码时 Context **静默丢弃升级**（`exactCandidate(at:)` 要求 pathID 在项目 session 内，依赖绝对路径返回 nil），Relations 侧却已有 "External · in dependency" 标签——**两侧不一致，跳依赖是死路** | `ContextWindowModel.swift:510-525` vs `RelationTreeModel.swift:462` |

### B 轨 Rust 引擎

| 候选项 | 核查结果 |
|---|---|
| **AnalysisProfile 真实化** | 确系 placeholder：`AnalysisProfile.placeholder` 每次索引生成**随机 UUID** id、root 恒 `"."`（`ProjectIndexer.swift:169,261`）；引擎完全不读 Cargo.toml；design §3.3 的 configFingerprint/featureSet/target 等字段全部缺席。唯一读 Cargo.toml/lock 的是 `ExactProfileKey`（纯 sha256 指纹，不解析）。**已确认的真实潜在 bug**：`ExactOverlay.ReuseKey` = versionIdentity × configFingerprint × toolVersion——**将来 feature 可切后，同一 Cargo.toml 下切 feature 会错误命中旧 exact 缓存**（键不含 feature 选择）。利好：CanonicalDump 不含 profile、goldset 用 session 自身 profile id、SQLite IndexCache 键不含 profile（按 design 本就不该含）——真实化**不触 determinism 面**。 |
| **历史 exact 剩余缺口** | **全链路已通**：`AppModel.swift:712` 以 currentRevision 调 `exactCoordinator.prepare` → CommitSnapshot → `Materializer.materialize`（staging + `.complete` marker + 2GB LRU 配额）→ RA 指向物化根 → `mapped()` 剥前缀映射回仓库相对路径 → Context/Relations 显 `@commit (materialized)` / `· hist` 徽标。真正缺口：(a) **exact 能力面 = definition-only**（`ExactCapabilities` 只有 `.definition`，worktree 与历史同缺 references/implementations/callHierarchy）；(b) 物化目录键不含 toolVersion（仅 overlay 键含，无正确性影响，源码目录与工具无关）。**结论：不设"历史 exact"切片**。 |
| **receiver 类型建模** | 原料齐备但未接线：`receiverRange` 已被 RustCalls 提取（`field_expression` 首子节点）；`BindingRecord.targetHint` 字段/编解码/校验都在但 **RustScopeBuilder 恒填 nil**（`RustScopeBuilder.swift:74`）；`implRelations` + `EngineSession.byTypeName` 索引已存在。Resolver 的 methodCall 路径目前纯名字匹配（`possible · dynamic` + `.methodNameOnly`）。**决定性利好**：CanonicalDump 的 bindings 行不打印 targetHint → 填充它不破 canonical dump 零 diff 硬门。 |
| **依赖可浏览 / F2.7** | lockfile 只进了 exact 指纹，未进任何浏览模型。exact 依赖落点：Relations 有标签，Context 丢弃（见 A 轨）。全量依赖树浏览是 design P2，本轮只做 F2.7 落点展示 + 只读打开。 |
| **RA 孙进程进程组化** | 现有 `CProcessGuard`（atexit + crash signal handler SIGKILL 注册的**直接子进程**，即 sandbox-exec）已覆盖主要路径；残余窗口仅剩"宿主被 SIGKILL / 直接子死后孙进程（cargo/proc-macro srv）残留"，需弃 Foundation Process 改 posix_spawn + setpgid/killpg，触及 LSPClient 主干。**收益窄、风险宽，推后**。 |

基线复核：`@Test` 计 **233**；ci.sh 含引擎禁 AppKit/SwiftUI、SwiftUI 身份禁令 regex
自检、`--self-test-exact .`、`--self-test-diff .`；extractorVersion 当前 **5**。

---

## §2 范围裁决

**本轮做（按派发顺序）**：S1 Profile 引擎真实化 → S2 Profile 切换器 + exact 缓存键 →
S3 receiver 类型建模 → S4 依赖落点展示 → S5 多标签 → S6 SI 式层次化排版完成版
（声明分级 + F6.1 注释保护 + 总开关）→ S7 阅读区阅读性基础设施（行号槽/当前行/
同名高亮）→ S8 SearchPanel 极限整治 → S9 收尾。S6 起任意时点若决策者目视反馈到达，
优先插入"观感微调"机动小片（预算半片，内容以反馈为准，不预猜）。

**推后（含理由）**：
- **exact references/implementations/callHierarchy**：**下一轮的首选主体**（比 TS/Python
  铺面前更值得做，是"最好的 Rust 阅读器"的下一级），本轮不塞——它会再改 ExactProvider
  协议 + RelationTreeModel + 通道，与 S2/S4 撞文件且体量是整片级。
- **SI Reference Styles（"Ref to…" 引用样式：引用处按 local/param/member/const 分
  样式）**：SI 排版签名的另一半，但需要 design §5.1"打开文件时补充完整局部引用索引"
  这块尚未建的基础设施 + 显示端逐 token 符号查找（SI 手册自己都注明会拖慢显示、需
  缓存），整片量级。挂 **M6 候选**——与 exact references 是天然一对（同一份引用数据
  两个消费面），届时一起做性价比最高。
- **F5.7 书签、Relation Window 随光标自动跟踪**：SI 的行为签名但非视觉签名，且书签
  牵动快照保留策略（design §10.3）。挂 M6 候选。
- **RA 进程组化**：残余风险窗口窄，触 exact 主干，收益/风险比不划算。
- AX 值变更防御专项、huge syntaxVisible 属性重排：无头不可证 + 探针级投入，性能预算
  目前分档达标。
- 分支图、F4.8 lineage、依赖全量浏览/搜索（P2）、sandbox-exec 迁移、Cmd+± 字号
  （有 settingsWindowController 缓存地雷，动前必须先拆缓存——backlog 已存档）。
- **TS/Python 整语言面：明确不在本轮**。

---

## §3 切片明细

### S1 — AnalysisProfile 引擎真实化（地基，无 UI）

**目标**：把 placeholder 换成真实、确定性、多语言可扩展的 profile 模型；建立"profile
失效 ResolvedRelations、不动 ContentIndex"的引擎级语义。

**内容**：
1. `CodeInsightCore/QueryContext.swift`：按 design §3.3 扩展 `AnalysisProfile`——新增
   `projectUnitName: String`（Rust=package/workspace 名；将来 TS=tsconfig 路径、
   Python=venv 标识，字段语言中立）、`configFingerprint: String`、
   `environmentFingerprint: String`、`featureSelection`（枚举
   `defaultFeatures / allFeatures / noDefaultFeatures`，附加 feature 名列表留字段）、
   `edition: String?`。`AnalysisProfileID` 改为**由 (language, unit, configFingerprint,
   environmentFingerprint, featureSelection) 确定性派生**（SHA256 → UUID 字节），不再
   随机。保留 `placeholder` 兼容测试但产品路径不再用。**在代码注释里写明：ID 派生规则
   是未来 TS/Python 复制的跨语言契约。**
2. 新 `CodeInsightEngine/ProfileDetector.swift`：从 store 已捕获的 `Cargo.toml` 字节做
   **最小 TOML 子集解析**（package.name、workspace.members、\[features\] 键名、edition；
   不引三方库）；解析失败或无 Cargo.toml → 诚实回退 profile（unit=目录名、指纹为空），
   **绝不阻塞索引**。
3. `ProjectIndexer` 两处 `placeholder` 换真实 profile；`EngineSession` 增
   `reprofiled(featureSelection:) -> EngineSession`：共享 store/manifest/moduleMap，仅换
   profile（新 SnapshotView），零重提取。
4. 旧 QueryContext 带旧 profileID 的查询经既有 `profileMismatch` 拒绝——这就是
   "ResolvedRelations 随 profile 失效"的引擎表达（本项目 ResolvedRelations 是即时计算，
   不存缓存层，失效语义 = context 拒绝 + 在途结果丢弃）。

**验收（无头，全自动）**：
- **修前失败对照**：新测试"同一目录索引两次 → AnalysisProfileID 相等"在现状（随机
  UUID）**必然失败**，改后过——真 bug 检测器，非防回归摆设。TOML 子集解析 fixture 组
  （workspace/features/edition/畸形文件→回退）。
- reprofile 测试：索引→reprofiled→断言 `extractedCount == 0`、ContentIndex 字典**对象
  同一**（identity）、profileID 不同、旧 context 抛 `profileMismatch`。
- **determinism 硬门**：全部既有 fixture canonical dump 逐字节零 diff（profile 不进 dump，
  靠既有断言证明）；双语料 gold set nostrong=0 不动；禁 RECORD。
- git 与非 git 双语料：新增非 git 目录 + Cargo.toml 的检测单测；`--self-test-project`
  双语料通道重跑不回退。
- 233 基线 + ci.sh + Swift 6 零 warning + 引擎禁 AppKit。

**人工**：无（纯引擎片）。

### S2 — Profile 切换器 UI + exact 联动 + 缓存键正确性

**目标**：C3 指示器变成真能切（feature 预设三档），exact 随 profile 重建且缓存键不串。

**内容**：
1. `AppModel`：暴露当前 profile 与可切 feature 预设；切换流程 = generation 递增 →
   `session.reprofiled` → Context/Relations 在途丢弃 → `exactCoordinator` 以新 feature
   选择重 prepare。workspace 多成员本轮**只展示 unit，不切 unit**（诚实标注，切 unit
   留后续）。
2. `CodeInsightExact`：RA initializationOptions 增 `cargo.features` /
   `cargo.noDefaultFeatures` / `cargo.allFeatures` 映射；**`ExactOverlay.ReuseKey` 与
   `ExactProfileKey` 加入 featureSelection**（修复 §1 已确认的缓存键隐患）；
   `ExactAttribution` 带 feature 选择供徽标显示。
3. `MainWindowController` profile 菜单：真实 profile 详情（unit · features · edition ·
   trust）+ 三档可选带勾选态 + 原 Trust 动作；标题随选择更新。
4. 物化目录键：commitOID × configFingerprint 维持不变（源码目录与 feature 无关，注释
   说明）。

**验收（无头）**：
- **修前失败对照（缓存键）**：fake provider 计数测试——存入 feature=default 的 overlay
  条目后以 allFeatures 查询，断言 **miss 并再次调 provider**。此测试在现状键结构下
  **会失败**（错误命中），是本片核心 bug 检测器。**先写测试后改键。**
- 集成通道（扩展 `--self-test-exact`，真实 MainWindowController）：驱动菜单动作切换预设
  → 断言 (a) profile 按钮**在放大窗口内可见且 frame 含于 toolbar 可视区**、标题串含新
  预设字样（可见+几何，非存在性）；(b) fake provider 收到含预期 feature 的新 prepare；
  (c) 切换期间 fuzzy Context 照常出结果；(d) 旧 generation 结果被丢弃。
- 断言只读 `isHidden`/既有 frame 快照，不调用强制布局 API（见 §6 铁律③）；空载内存通道
  放大窗口 **连跑 ≥20 次** 0 fail、<100MB 不放宽。
- 8 条通道 + 双语料 + determinism 硬门 + 233+。

**人工**：真机 rust-analyzer 下切 feature 预设，观察 exact 落点/coverage 徽标变化与切换
观感（不闪不跳）；Trust 流程回归。

### S3 — receiver 类型建模（extractor + resolver）

**目标**：`x.foo()` 从"全项目同名方法 possible"升到"receiver 类型已证的 impl 方法
strong"，Calls 树可感知降噪。

**内容**：
1. `RustScopeBuilder`：填 `targetHint`——`let x: T`、参数 `x: T`/`&T`/`&mut T`（注解证明，
   hintKind=.unqualified）、`let x = T::new(..)` / `T { .. }`（构造推断，hintKind=.member
   区分）；impl 作用域内 `self` → 所在 impl 的 self 类型。
2. `Resolver` methodCall 路径：有 `receiverRange` → 复用词法绑定机制找 receiver 绑定 →
   targetHint 类型名 → `byTypeName` impl 关系 → 候选限于该类型 impl（含 trait impl，
   dispatch 相应标 trait）：注解/self 证明 → **strong**、构造推断 → probable，新证据 case
   `.receiverType(nameID:)`；无 hint / trait object / 泛型 → 维持现状 possible（**诚实
   红线：启发式封顶 strong 不变，不冒充 exact**）。**shadowing/重绑定检查沿用词法绑定的
   位置过滤**。
3. `RustExtractorInfo.extractorVersion` 5→6（SQLite draft 缓存随之正确失效，加一次性
   重提取断言）。
4. RelationTree："name match only" 注记在 receiver 证明边上消失，边随 certainty 升组。

**验收（无头）**：
- **修前失败对照**：新 resolver 测试断言注解 receiver 方法调用产出 strong + `.receiverType`
  证据——现状**必失败**（恒 possible + methodNameOnly）。fixture 组：注解 receiver /
  self 方法 / 构造推断 / receiver 被 shadow / trait object 保持 possible / 同名多 impl。
- **determinism 硬门（本片最严）**：既有全部 canonical dump fixture **逐字节零 diff**
  （targetHint 不进 dump 版式，靠既有 expect.txt 原文对照证明，禁 RECORD）；既有 gold
  set 条目**一字不改**、nostrong=0 双语料保持（新推断只在注解/self/构造场景触发，双语料
  nostrong 锚点全是无标注 receiver，不受影响——验收时明确复核这 6 个锚点）；新行为以
  **新增** fixture/gold 条目覆盖（追加不算重录）。
- 集成通道：固定 fixture 仓上右键 Calls → 断言真实 NSOutlineView 中已知边**修前在
  Possible 组、修后在 Strong 组**（两个方向都断言），且 trait-object 边仍在 Possible。
- draft 缓存失效断言：版本 bump 后首跑 `extracted>0`、二跑 `extracted==0`。
- bench 护栏：tokio 语料索引耗时相对 benchmarks.md 基线不超容差。
- 233+ / ci / 8 通道 / 双语料。

**人工**：tokio 抽查若干 `x.foo()` 的 Calls/Context 准确度观感。

### S4 — 依赖落点展示（F2.7 "位于依赖"）

**目标**：exact 落点在依赖源码时不再静默丢弃；Context 诚实展示"位于依赖"卡片并可只读
打开。

**内容**：
1. `ContextWindowModel`：exact 目标为项目外绝对路径时，产出新候选卡：
   "External · in dependency" + crate 名（从 cargo registry / 物化路径推导，推不出就显示
   路径）+ 从该文件字节读取的摘录（异步、只读）+ 完整 exact 徽标；Pin 语义不变
   （Pin 时仅标注就地升级的既有规则沿用）。
2. 跳转：Cmd+单击/双击可在阅读区只读打开依赖文件（`loadReaderDocument(at:)` 已支持绝对
   路径；文件树不联动、大纲按打开文件单独构建或诚实置空）；导航历史带绝对路径回放护栏。
3. Relations 的 "External · in dependency" 边单击联动 Context 用同一卡片路径，两侧一致。
4. 诚实性文案 tokens 清单增补 "in dependency" 系。

**验收（无头）**：
- **修前失败对照**：先写测试断言现状"fake provider 返回项目外绝对路径 → Context 无卡片/
  升级被丢弃"（现状过），改后翻转为"卡片出现且摘录字节 == fixture 文件内容"。
- 集成通道（扩展 `--self-test-exact`）：fake provider 指向 fixture 假 registry 目录 →
  断言真实 Context 视图卡片**可见（frame 在底部面板可视区内）**、文案含 "in dependency"、
  跳转后阅读区字节 == 依赖文件字节且 `isEditable == false`（**只读铁律**）。
- 内存/几何：放大窗口连跑 ≥20 次预算不回退；断言不触发布局物化。
- 8 通道 / 双语料 / determinism（UI+AppModel 片，引擎不动）/ 233+。

**人工**：真机 RA 跳 serde/std 源码观感；"位于依赖"文案与徽标是否清楚。

### S5 — 多标签（F6.6 P1）

**目标**：阅读工作流补齐标签页；内存纪律恪守 design §9.2"只保留活跃标签页的 tree"。

**内容**：
1. `CodeInsightAppModel` 新 `TabStripModel`：有序 tabs（fileURL + 滚动/选择锚点）、
   active 索引；重复打开聚焦既有 tab；上限（建议 10）+ LRU；**只有 active tab 持有
   ReaderDocument**，切换经既有 DocumentLoader 异步重载并恢复滚动位置（常规档 <100ms，
   成本可接受）。
2. `MainWindowController`：阅读区上方轻量自绘 tab strip（不用 NSTabView/窗口原生 tab），
   C5 视觉语言与三主题联动；≤1 tab 时隐藏（作为待决策者反馈项标注）。
3. 交互：文件树单击仍在当前 tab 打开（**F2.3 单击语义不动**）；右键 "Open in New Tab"
   + Cmd+Shift+Return 新开；Cmd+W 关 tab、Cmd+Shift+\[/\] 切换（避开 Cmd+T 符号搜索）。
4. 快照切换：active tab 沿用既有 replay；非活跃 tab 仅存路径，激活时按当前快照懒加载，
   文件不存在 → tab 内诚实占位。

**验收（无头，新通道 `--self-test-tabs`，驱动真实 MainWindowController）**：
- **几何/可见（放大窗口）**：≥2 tabs 时 strip 可见、frame 含于窗口内容区、与阅读区不
  重叠，且 strip 高度 + 阅读区高度撑满既有空间（**防"存在但塌陷/不撑满"事故**——对照
  §6 铁律②逐条表达为几何等式断言）；1 tab 时 strip 隐藏且阅读区恢复全高。
- 行为：开 A → 新 tab 开 B → 断言 tabs==2、active==B、阅读区字节==B；切回 A → 字节==A
  且滚动偏移恢复为记录值；关 B → 阅读区仍显 A。
- **内存纪律（修前失败对照）**：模型层 weak 探针断言切走后非活跃 tab 的 ReaderDocument
  释放（若实现保留强引用该断言必失败）；空载与双 tab 场景放大窗口 **连跑 ≥20 次** 内存
  预算不回退；断言只读模型状态与既有 frame，不强制布局。
- 既有 8 条通道全部重跑（本片是 MainWindowController 大改，回归面最大）；F2.3/Pin/
  history 通道必须绿；双语料；determinism 门不涉及但照跑。
- 233+ / ci / 零 warning。

**人工**：tab 切换是否闪烁、滚动恢复手感、三主题下 strip 观感、10+ tab 行为、与 Compare
分屏共存观感。

### S6 — SI 式层次化排版完成版（Declaration Styles 补全 + F6.1 注释保护 + 总开关）

**目标**：把 SI Syntax Formatting 的"声明样式"半边从 1/8（仅函数名）补到全量——所有
声明名按类别分级浮出正文，文件读起来像带标题的文档（§0.5 第一行签名）；同时交付
F6.1 承诺的注释 ASCII 保护与混合字体总开关。**全部改动在 Reader 层
（HighlightSpan/ReaderCore/ReaderUI），不触 ContentIndex，determinism 无涉。**

**内容**：
1. **声明分级（SI "Declare…" styles 的对应物）**：highlight walk（`CodeInsightReaderCore`
   已在同一棵 tree-sitter 树上做大纲提取，声明名节点现成）为声明名产出新
   `HighlightKind.declarationName(kind)`（或等价扩展），`applyTypography` 分两级应用：
   - **一级（结构标题）**：fn/method/struct/enum/trait/typeAlias 声明名 → 与现函数名
     同规格（`fontSize + functionNameDelta`、semibold、kern 0.15）；
   - **二级（克制强调）**：mod/const/static 声明名 → semibold 不放大。
   分级幅度先按此克制版实现，**决策者目验后用机动小片微调，不预猜**（M0-B 结论
   沿用：行高跳动明显即退回）。调用点/引用处一律不动（Reference Styles 明确推后
   M6，见 §2——本片只做"声明"半边，不做半吊子引用样式）。
2. **F6.1 注释 ASCII 图/表格保护**：`CodeInsightReaderCore` 增纯函数分类器
   （box-drawing 字符、`+--+`/`|` 表格线、连续 ≥3 划线符、多行列对齐启发式；**保守
   策略：疑似图表即保持等宽**）；highlight 管线为 comment span 附 prose/figure 标记；
   `applyTypography` 仅对 prose 换人文字体。humanist 默认**维持 off**（保护到位后
   是否默认开，留决策者定）。
3. **Syntax Formatting 总开关**（F6.1 原文"混合字体可整体关闭"，对应 SI 的
   "Use only color formatting"/Mono Font View）：`ReaderSettings` 增一个 bool（默认
   开），关闭时抑制**全部**字号/字重/字距/字体族变化，只留配色；Settings 窗口
   Reading 页加勾选项。

**验收（无头）**：
- **修前失败对照**：attributed-string 层测试"struct/trait 声明名为 semibold"现状
  **必失败**（现在只有颜色）；"humanist 开时图表注释保持 monospaced"现状必失败
  （无条件 systemFont）。两者都在纯 NSAttributedString 上做，无窗口无布局（内存安全，
  铁律③天然满足）。
- 分类器 fixture 单测（ASCII 图/表格/纯散文/CJK 散文/混合）；声明分级 fixture
  （各 OutlineKind 一例 + 嵌套 impl 内 method + 调用点同名 identifier **不得**被误升级）。
- 总开关测试：off 时全文遍历断言单一 font family + 单一 pointSize + 零 kern。
- determinism 无涉（HighlightSpan 是 Reader 层，不进 ContentIndex/dump），但 canonical
  dump / gold set 照跑作回归。233+ / ci / 零 warning。
- 巨档护栏：10 万行档 `syntaxVisible` 路径 span 数增长在既有分档预算内（声明数远小于
  token 数，预期无感，但要有数字）。

**人工**：tokio/ripgrep 目验"文件像文档"效果与行高稳定性（放大幅度分级是观感决策，
反馈走机动小片）；SI Classic 主题下与 SI 原版观感对照；开 humanist 看含图注释；
总开关 off 的"素面"模式可用。

### S7 — 阅读区阅读性基础设施（行号槽 + 当前行高亮 + 同名高亮）

**目标**：补齐 SI 阅读区三件裸奔缺口（§0.5）：行号槽含声明 gutter 标记（F6.1 原文
承诺）、当前行高亮、点选符号全文同名高亮。**本片直接动 viewport 渲染热路径，是
内存/性能回归高危片**（见 §5 风险 7）。

**内容**：
1. **行号槽**：主阅读区 NSScrollView 装自绘 `NSRulerView`（TextKit 2 下无
   NSLayoutManager 可依赖，必须自绘——`DiffGutterRulerView` 已趟通 viewport fragment
   枚举路径，复用其经验）；只绘 viewport 内 fragment 对应行号；tabular figures 等宽
   数字；三主题弱化灰阶配色（行号不与代码争夺注意力）；**声明处 gutter 标记**：
   outline facet 所在行绘 kind 刻度点（与 S6 的声明分级同源数据）。Compare 模式下
   与 diff 色条合并绘制（同一 ruler 内并列，宽度相加），`--self-test-diff` 不得回退。
   可开关（默认开，`ReaderSettings` 增 bool）。
2. **当前行高亮**：光标/最近跳转行 subtle 整行背景（背景绘制层，不进 attributed
   string）；三主题各配色；与 findIndicator 闪烁不冲突（闪烁是瞬时反馈，当前行是
   持续锚点）。
3. **同名高亮（SI "Highlight References" 的词法版）**：单击 identifier → 全文同名
   token 背景高亮，经既有 `RenderingAttributesCoordinator` viewport 门控写属性；
   Esc / 点击空白清除。**诚实红线：这是词法同名匹配，不是语义引用**——UI 不用
   "references" 字样（叫 occurrences 或不出文案），不与 Context/Relations 的语义
   结果混淆；语义版留给 M6 的 Reference Styles + exact references 一对。

**验收（无头，新集成通道 `--self-test-reading`，驱动真实 MainWindowController，
放大窗口）**：
- **修前失败对照**：现状断言主阅读区 `hasVerticalRuler == false`（过）→ 改后翻转为
  ruler 存在、宽度 > 0、行号文本与已知行一致。
- **几何等式（铁律②）**：ruler frame 在窗口内容区内、阅读区宽 == 容器宽 − ruler 宽
  （撑满、不重叠）；关闭行号开关后阅读区恢复全宽。
- **viewport 门控（design §9.2 铁律：验收"实际写属性的 fragment 数"，不是"是否用了
  lazy API"）**：巨档（10 万行）打开 + 同名高亮激活后，实际写属性 fragment 数与
  viewport 尺寸同阶、不随文件总行数线性增长（复用 M0-B 计数探针）。
- 行为：点击 fixture 已知 identifier → 模型层同名集合计数 == 预期；换点另一符号 →
  旧高亮清除；当前行高亮存在于点击行且不在其它行（属性/绘制状态只读断言，不强制
  布局，铁律③）。
- **内存**：常规档 + 巨档、放大窗口**连跑 ≥20 次**预算不回退（本片是 M5 内存风险
  最高片，20 次是底线不是上限）。
- `--self-test-diff` 通道必须绿（gutter 共存）；其余全部既有通道 + 双语料 +
  determinism 照跑；233+ / ci / 零 warning。

**人工**：巨档滚动帧率手感（行号绘制在滚动热路径上，**帧率手感如实标人工，不冒充
自动化守住**）；三主题下行号/当前行/同名高亮配色观感；声明 gutter 标记密度是否
干扰；同名高亮与 diff/查找闪烁同屏时的视觉层级。

### S8 — SearchPanel 极限渲染整治（小-中片）

**内容**：模型层显示上限（建议 2000）+ 诚实截断行 "Showing first 2000 of N matches
(truncated)"（沿用 completeness 语汇）；总数照报；身份保持选中语义（backlog 清理轮
成果）不回退；view 层确认每节流 tick 单次 `reloadData`。

**验收（无头）**：模型测试 5000+ 命中 → 行数 ≤ cap+1 且截断行文案正确（**修前失败**：
现状 rows==5000）；面板集成断言用 dataSource 行数 + 截断行存在于数据层，不强制表格布局；
**帧率手感如实标人工，不冒充自动化守住**。**人工**：大仓搜单字母滚动手感；cap 数值与
文案是否可接受（待反馈微调项）。

### S9 — 收尾：bench + 回归全家福 + M5 交互测试计划

**内容**：bench.sh 增 profile 切换延迟/receiver 解析开销/巨档行号+同名高亮滚动路径
对照；benchmarks.md 增节；stress-switch 回归；10 条通道（8+tabs+reading）双语料
全家福连跑；撰写 `docs/plans/m5-interactive-test-plan.md`（含 S2/S4/S5/S6/S7 的人工
锚点与已知限制白名单——同名高亮"词法非语义"要作为已知限制明示）；backlog 结转
（进程组化/AX/huge syntaxVisible/exact references/SI Reference Styles/书签/Relation
随光标显式挂 M6 候选）。

**验收（无头）**：ci + 全量测试 + fixture + gold set + canonical dump + 10 通道 exit 0，
空载内存放大窗口 20 连跑。**人工（M5 总验收 30 分钟弧线）**：Safe 开 tokio → 切 feature
预设看 exact 变化 → `x.foo()` 看 Strong 组 → 跳 serde 依赖源码 → 多标签来回读 →
目验声明分级"文件像文档"+ 行号/当前行/同名高亮（SI Classic 主题对照 SI 原版观感）→
humanist 开关含图注释 → 大搜索截断 → 撤销授权回 Safe。

---

## §4 派发顺序、依赖与冲突

```
S1 → S2（严格串行：S2 依赖 S1 的 reprofiled/字段；两片同触 Core/Engine/Exact）
S2 → S4 → S5 → S7（严格串行：四片都改 MainWindowController.swift + CodeInsightApp.swift
   自测宿主；S7 另触 ReaderUI 渲染管线）
S3 在 S1 之后任意时点（触 Extractor/Resolver/RelationTreeModel，与 S2 的 Exact/UI 面基本
   不交，但单工作树下仍建议串行插在 S2 与 S4 之间）
S6 与引擎/主窗口片无文件交集（ReaderCore/ReaderUI），可在 S1 之后任意插空；但 S6 与 S7
   同触 CodeInsightReaderUI.swift（applyTypography vs 渲染门控/背景绘制），两片之间必须
   串行且建议 S6 在前（S7 的 gutter 声明标记复用 S6 同源的声明数据）
S8 与谁都不撞（SearchPanel*），缓冲插空
S9 依赖全部
推荐单工作树顺序：S1 S2 S3 S4 S5 S6 S7 S8 S9
```

---

## §5 风险预警

1. **S1 TOML 解析自研**：只做声明式子集，任何歧义按"解析失败→回退 profile"处理，宁可
   显示 fallback 也不猜——回退路径必须有 fixture。
2. **S2 缓存键翻新**：ReuseKey 加字段后，"修前会失败"的错误命中测试是本片验收锚点，
   先写测试后改键。
3. **S3 是唯一动 ContentIndex 语义的片**：canonical dump 零 diff 靠"dump 版式不含
   targetHint"这一事实性护栏成立，实现中若有人改 dump 版式即违规；gold set 六个 nostrong
   锚点逐一复核。
4. **S5 回归面最大**：C4/C5 两次"存在性断言全绿但布局坏了"的事故都发生在主窗口结构改
   动，本片的几何等式断言（撑满/不重叠/隐藏恢复）是主防线，8 条旧通道全家福不可省。
5. **RelationTree provider 路径约定耦合**（backlog 防线留档）：S4 触碰绝对路径判定逻辑
   （`hasPrefix("/")` 降组分支），必须同步复查 `RelationTreeModel.swift:326-351` 的注释约定。
6. **oatmeal/tokio 等真实语料的人工锚点**沿用 m4-interactive-test-plan 的既有锚点体系，
   S9 更新。
7. **S7 直接改 viewport 渲染热路径**：design §9.2 的教训原文——"NSTextContentStorage
   delegate 与不带范围判断的 renderingAttributesValidator 都会退化为全文件工作"，同名
   高亮与行号绘制都必须 viewport 门控，**验收指标是"实际写属性的 fragment 数"，不是
   "是否用了 lazy API"**；TextKit 2 下 NSRulerView 无 NSLayoutManager 兜底，必须自绘
   （`DiffGutterRulerView` 是唯一先例，其 viewport 枚举方式是本片起点）。内存 20 连跑
   在本片是底线不是形式。
8. **S6 放大幅度分级是观感决策，不是工程决策**：先按克制版两级实现（一级 = 现函数名
   规格、二级 = semibold 不放大），决策者目验后走机动小片微调；行高跳动明显即退回
   （M0-B 既有结论），**不预猜第三级、不擅自加 italic**（SI 用 italic 标 member，但
   那属于推后的 Reference Styles 半边）。

---

## §6 验收铁律（本项目反复踩坑固化，评审请据此审每片验收）

> 这些不是形式主义，每条背后有一次真实事故。评审时若发现某片验收未体现相关铁律，应
> 判其验收不充分。

1. **"修前会失败"对照是硬性交付物**：凡声称某断言守住了某行为，必须能演示"回退该修改
   → 断言确实失败 → 还原 → 通过"。做不到就如实降级为人工项。**背景**：M4-Fix 的 FIX-1
   曾交付一个无头 self-test 通道全绿、但把被修代码改回旧写法后仍 5/5 通过的**假安全网**
   （离屏 SwiftUI layout 时序与真实窗口服务器不同，无头根本触发不了那个崩溃）。此后每片
   强制对照。

2. **UI 断言必须表达"可见/几何正确"，不能只查"存在"**。存在性断言（对象非 nil、能读出
   字符串、item 在 `toolbar.items` 里）在离屏视图层级里**必然通过**，与用户能否看见无关。
   **背景三连**：(a) UI-C1 空态视图被 `addSubview` 进 NSScrollView 被文本视图遮住，
   `emptyStateExists=true` 全绿但用户看到**纯白**；(b) UI-C4 状态栏用的 NSStackView 没设
   alignment/distribution，内容缩在左上角 846×500 而窗口 1600×1000，几何断言只查"在窗口
   内、面积非零"照样绿；(c) UI-C5 改 sidebar material 换根视图改变布局顺序，FILES 面板
   塌成 71px。修法：断言窗口坐标系 frame 面积非零 + 与容器的**几何等式**（撑满 = 宽等于
   容器宽、高等于容器高减兄弟占位；不重叠；隐藏后恢复），且**必须在放大窗口(如 1600×1000)
   下测**——默认尺寸下 fitting size 恰好接近窗口，看不出问题。

3. **断言本身不得触发 AppKit 布局物化导致内存回归**。**背景**：UI-C2 新增的可见性断言为
   判断"看得见"去访问 `NSToolbarItem.view` 做 bounds/坐标转换，主动物化工具栏布局，导致
   空载内存间歇 129MB（>100MB 预算）。改用 `NSToolbar.visibleItems` 等只读查询。

4. **间歇缺陷不能用"一次通过"证伪**，内存/几何类断言**连跑 ≥20 次**。**背景**：内存尖峰
   触发率随环境波动很大（同一版本实测过 0/30、2/15、13/20）；曾用"30 次全不触发概率约
   十万分之二"的错误推理把运气当成证据。低频缺陷需受控二分 + 每档足量采样 + 一个已知能
   归零的对照档作锚点。

5. **git 与非 git 两种语料都验**。**背景**：UI-C2 新增的分支名断言无条件要求有分支名，
   把"打开非 git 目录"（tar 解压的语料、下载的源码包——Cairn 作为只读阅读器的核心场景）
   判成失败。Codex 只用有 git 的本仓库自测漏掉，orchestrator 用 tokio（无 .git）才撞出。

6. **诚实性是产品红线，宁可少显示不可显示假的**：(a) 启发式**绝不冒充 exact**，
   Strong 是启发式封顶；(b) 恒 nil 的字段（如 `importsResolved`）**一律不显示**，不造假
   进度；(c) 单 profile / 单项时不伪装成可切换的假控件；(d) 覆盖缺口如实标 partial /
   offline / truncated。这些文案 token 被 self-test 用 `contains` 断言，**改视觉容器时
   字符串一个字都不许动**。

7. **determinism 硬门**：双语料 gold set nostrong=0、canonical dump 逐字节零 diff——
   **禁止 RECORD 重录**。新行为用**新增** fixture/gold 条目覆盖（追加不算重录）。

8. **环境盲区互补**：Codex 执行环境无真实窗口服务器 + `sandbox-exec` 不可用（真实 RA
   变体永远 skip），故它测不到 AppKit 布局物化、真实 exact 时序、多语料等；orchestrator
   在真机复跑补齐。反过来 Codex 擅长读代码定位根因。**分工**：Codex 读码提假设 + 无头
   实现，orchestrator 真机复现/验收；**复现不了就如实报告、给可执行的二分方案，不盲改、
   不拿"跑不出来"当已修**。

---

## §7 通用约束（照抄进每片派发词）

无头 `swift build && swift test` 全绿（基线 **233**，既有测试只增不减、不改语义）；
`ci.sh` 通过（引擎/model target 禁 import AppKit/SwiftUI、SwiftUI 身份静态禁令 regex +
自检、`--self-test-exact .` 与 `--self-test-diff .`）；Swift 6 严格并发零 warning；
不破坏既有 self-test 通道（进场 8 条，S5/S7 增 tabs/reading 后只增不减）/ 双语料
gold set(nostrong=0) / canonical dump 零 diff /
design F2.3 单击 Pin 语义 / 只读铁律 / 诚实性文案 tokens / 空载内存 <100MB 预算不放宽；
UI 断言必须表达可见/几何正确且不触发布局物化、内存与几何断言在放大窗口下连跑 ≥20 次；
git 与非 git 双语料都验；禁 RECORD 重录；不改 `Prototypes/`；每片不 commit（监工验收后
提交）。

---

## 附：关键实现文件（评审可据此抽查）

- `Sources/CodeInsightCore/QueryContext.swift`（S1 profile 模型与确定性 ID，跨语言接缝）
- `Sources/CodeInsightEngine/ProjectIndexer.swift`（S1 placeholder 替换 + reprofile 接线，S3 extractorVersion 联动）
- `Sources/CodeInsightEngine/ProfileDetector.swift`（S1 新增，最小 TOML 子集解析）
- `Sources/CodeInsightAppModel/ExactCoordinator.swift`（S2 缓存键/feature 联动核心）
- `Sources/CodeInsightEngine/Resolver.swift`（S3 receiver 类型解析主战场）
- `Sources/CodeInsightRustExtractor/RustScopeBuilder.swift`（S3 targetHint 填充）
- `Sources/CodeInsightAppModel/ContextWindowModel.swift`（S4 依赖落点卡片）
- `Sources/CodeInsightAppModel/`（S5 新 TabStripModel）
- `Sources/CodeInsightApp/MainWindowController.swift`（S2/S4/S5/S7 串行冲突中心，几何断言宿主；`:2433` 现有 ruler 安装判空处是 S7 gutter 共存的接缝）
- `Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift`（S6 声明名 HighlightKind 扩展 + 注释分类器；`:6-13` 现有 6 类枚举）
- `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`（S6 `applyTypography:416-453` 分级；S7 渲染门控/当前行背景/行号 ruler——`DiffGutterRulerView:505` 是自绘先例）
- `Sources/CodeInsightReaderCore/ReaderSettings.swift`（S6 总开关、S7 行号开关；主题色 token 增行号/当前行/同名高亮三组）
- `Sources/CodeInsightAppModel/SearchPanelModel.swift`（S8 截断）
