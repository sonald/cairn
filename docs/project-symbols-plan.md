# 项目符号浏览计划（未实现）

> 状态：需求与决定已确认（2026-10-11，D1–D7 全部按推荐值），待实施。**以下能力均未实现**，不得写入 README 或 [产品说明](product.md) 作为现有功能。
> 原型：[project-symbols-prototype.html](project-symbols-prototype.html)（浏览器打开，可切三主题；数据是示意，不是真实索引）。
> 完成后把仍有效的行为归入 `product.md`，删除本文件和原型。

## 要解决的问题

现在找符号的入口都要先知道名字：`⌘P` 的 `#` 和 `@` 在查询为空时不列任何结果，大纲只看当前文件，搜索结果按文本命中组织。接手陌生仓库时用户常常连关键词都没有，只能顺着文件树一个个点开。Source Insight 的 Project Symbol List 和 Symbol Categories 解决的就是这个场景：不输入名字，按种类或模块把整个项目的声明摊开来看。

本计划新增一个"项目符号"面板：空查询列出当前快照里全部已索引的声明，可以按种类或按模块组织，可以按种类、可见性、范围过滤，选中即预览。它不做语义归属、类型层次或 Agent 角色视图。

## 范围

| 编号 | 内容 | 一句话 | 主要复用 |
| --- | --- | --- | --- |
| B1 | 数据来源 | 引擎已索引的 `DeclarationFacet`，跨全部分析单元和语言 | `EngineSession.contentIndexes`、`SnapshotView` 活动文件 |
| B2 | 组织方式 | 按种类 / 按模块两种树 | `DeclarationShape`、`ModuleMap`、`parentFacetIndex` |
| B3 | 过滤 | 文字、种类、仅公开、范围 | `SymbolSearchIndex` 的匹配与评分 |
| B4 | 交互与导航 | 预览、打开、右键关系命令、定位当前符号 | 搜索结果面板与大纲的既有导航路径 |
| B5 | 状态 | 索引中、过期、多单元合并、选中恢复 | `SymbolSearchPanelModel`、搜索结果的过期规则 |
| B6 | 面板接入与持久化 | 新 `PanelID`、菜单、快捷键、应用级偏好 | `PanelLayout`、`PanelViews`、`KeyBindings` |
| B7 | 可见性事实 | 抽取器记录声明处的可见性修饰 | 三个抽取器、`ContentIndexDraftCodec` |
| B8 | TypeScript 新种类 | interface、type alias、enum 成为 facet（D1 已采纳） | `TypeScriptExtractor`、`DeclarationKind` |

明确不做：

- **Agent 角色视图**（按工具定义、Prompt、主循环等组织）：AI 相关功能按 2026-10-05 的决定统一暂缓；本面板的树结构应能容纳将来的叠加层，但不预留接口。
- **类型层次、跨 commit 符号映射、`__all__` 解析、语义归属**：本面板只展示句法事实。
- **用户自定义分类**（SI 的自定义 Symbol Categories）：没有真实需求前不做。
- **替代 `⌘P` 的 `#`**：快速打开保持不变，面板不是它的另一个皮肤。

## 共同约束

1. **只展示引擎已有的事实**。面板不重新解析文件，不启动 Exact 请求；每一行对应一个 `DeclarationFacet`，点击的落点是它的 `nameRange`。
2. **同名不等于同一目标**。跨文件聚合只按名称并在界面上标明"按名称合并"（见 B2.4），不能暗示语义归属。
3. **诚实标注可见性**。界面文案是"声明处的修饰"（`pub`、`export`、`_` 前缀），不是"外部可访问"。Rust 公开项位于私有模块、Python 的 `__all__` 都不纳入判断。
4. **大项目不退化**。空查询要列出几万个声明；树节点只在展开时物化子项，组标题带计数；不像搜索那样设 2,000 条上限。
5. **与搜索面板同一套过期规则**。首帧缓存会话到完整会话静默替换；快照变化才标过期并禁止跳转；重建后按 `(path, contentID, nameRange)` 恢复选中。
6. **键位进入集中表**，文案同时加 `en.lproj` 和 `zh-Hans.lproj`，AppKit 只进 `CodeInsightApp`。

---

## B1 数据来源

- **B1.1** 数据是当前快照里每个分析单元 session 的 `contentIndexes` 中的 `symbols`，按 `SnapshotView` 的活动文件过滤，所以同一语言的多个单元不会重复列出同一文件；被项目排除规则剪掉的路径不出现。
- **B1.2** 每行携带：名称、`DeclarationKind`、所属（`parentFacetIndex` 链）、文件路径、行号、可见性（B7）、语言与单元。impl 块行另带 `ImplRelation` 的 trait 名。
- **B1.3** 列出的种类按 `DeclarationShape` 归成九个组：函数、方法、结构体/类、枚举、trait/接口、类型别名、impl、模块、常量/静态；字段不成组，只作为类型行的子项（D5）。"方法"的定义是父 facet 为类型、impl 或 trait 的函数（Rust `rustMethod`，Python/TypeScript 父为 class 的函数）。
- **B1.4** 当前不是 facet 的东西不出现：Rust 枚举变体、宏，Python 模块级变量，TypeScript 的 interface/type alias/enum 在 P1 完成前。大纲能看到而项目符号没有的条目，需要在面板的 `?` 说明里列出，避免被当成 bug。
- **B1.5** 枚举全部 facet 在后台进行，结果是不可变数组，主线程只做树的物化与过滤。目标：5 万个 facet 的首次构建在 Apple Silicon 上低于 300ms（实施时只取少量样本确认方向，不做反复 p95）。

## B2 组织方式

面板顶部有"种类 | 模块"分段控件；两种方式共用同一份数据与过滤。

**B2.1 按种类**

- 第一层是 B1.3 的九个组，每组标题带计数，默认全部折叠，只有一个组时自动展开。
- 组内按路径、再按位置排序；有过滤文字时按匹配评分排序，同分再按路径和位置。不使用 `⌘P` 的 `kindWeight`，这里没有"更可能想要的种类"。
- 行显示：种类图标、名称（匹配部分加粗）、所属（灰色，如 `Log::`、`Benchmark.`）、右侧灰色相对路径与行号，宽度不够先截路径。
- 多语言项目在名称前加语言缩写标记（`rs`、`py`、`ts`），单语言不显示。
- 方法在"方法"组里平铺，所属显示在名称前（`Log::append`）；展开类型行或 impl 行时它们再次出现为子行（B2.3、B2.4），两处指向同一个 facet。
- 字段不单独成组（D5）：只在"类型"组内某个结构体/类展开后，以子行列出；种类过滤里取消"字段"则不再列出。

**B2.2 按模块**

- 第一层是分析单元，标题为"语言 · 单元根"（如 `Rust · crates/server`、`Python · tools`），只有一个单元时省略这一层。
- Rust：每个 crate 根文件（`main.rs`、`lib.rs`，以及 `src/bin/*.rs`）是一个 crate 节点；`mod foo;` 通过 `ModuleMap` 的父子关系展开成子模块，内联 `mod foo { }` 通过 `parentFacetIndex` 链展开。任何根都到达不了的文件（`examples/`、`tests/`、`benches/`、没被 `mod` 引用的文件）归入"未挂载的文件"节点，按相对路径列出。`ModuleMap` 需要新增公开的"文件 → 模块路径"查询。
- Python：模块路径就是单元根下的目录路径（与 `ModuleMap` 一样去掉 `src/` 前缀），`__init__.py` 代表包本身，不判断 `__init__.py` 是否存在。
- TypeScript：目录树加文件节点，`index.ts` 不折叠成目录。
- 模块节点下先列该模块直接声明的符号（按位置），再列子模块；同样遵守 B2.1 的行显示。

**B2.3 成员挂靠**

- Python/TypeScript 方法与字段的父 facet 是同文件的 class，直接挂在类行下。
- Rust 方法的父 facet 是 impl 块，不是 struct。两种方式都按 impl 块展示：按种类时 impl 行标题写 `impl Log` 或 `impl Engine for BitCask`，方法挂在 impl 行下；按模块时 impl 行出现在它所在的模块。
- **B2.4** 按种类的"类型"组里，结构体/类/枚举行可以展开，展开后依次列出：自身字段、同文件的同名 impl 块及其方法，以及（仅当这个名字在本分析单元里只有一个类型声明时）其他文件的同名 impl 块。跨文件的 impl 行带"按名称合并"的灰色标记和各自的文件路径，提示这是名称匹配而不是语义归属。名字不唯一时（例如 `raft::log::Log` 和 `storage::bitcask::Log`，或 `cfg` 分支各有一个 `struct Config`）每个类型行只列自身字段和同文件 impl，其余 impl 只出现在 impl 组和模块树里（D7）。

## B3 过滤

- **B3.1 文字**：面板顶部的过滤框，与 `#` 用同一套匹配规则（`SymbolSearchIndex.candidates`：前缀、缩写、子序列），输入停顿约 150ms 执行。`candidates` 的 `cap` 默认 2,000，作用于召回的不同名字；面板调用传 `.max`，不沿用这个上限。有文字时树仍按当前组织方式显示，不匹配的叶子隐藏，容器节点只要有匹配的子项就保留并自动展开；容器自身不匹配时灰显。
- **B3.2 种类**：过滤按钮弹出九个组加"字段"共十个勾选项，默认全选；取消勾选的种类在两种组织方式下都隐藏。"方法"与"函数"分开勾选。
- **B3.3 仅公开**：一个开关，开启后只保留可见性为"公开"的声明，以及为了显示它们而必须保留的容器（灰显）。可见性"不适用"的叶子（trait 内的方法签名、trait impl 里的方法）视为通过；"不适用"的容器（impl 块）自身不算通过，只在有通过的子项时保留并灰显，所以 `impl Key`（`Key` 私有、方法全私有）不会留下。不提供三档单选，受限（`pub(crate)`、`protected`）与私有一样被隐藏。
- **B3.4 范围**：整个项目 / 当前目录。当前目录取焦点阅读区文件所在目录，含子目录；没有打开文件时该选项置灰。"当前文件"不提供，那是大纲的职责。
- **B3.5** 组标题与面板底部的计数都反映过滤后的数量，底部写成"显示 37 / 4,912 个符号 · 213 个文件 · Rust、Python"；没有过滤时省略"显示 N /"。
- **B3.6** 过滤文字与过滤框的 `×` 一起清除；种类、仅公开、范围的状态按应用级记忆（见 B6.4）。

## B4 交互与导航

- **B4.1** 单击或方向键选中一行：在预览标签中打开并闪烁声明名，焦点留在列表，Context 按符号模式显示它（与搜索结果一致）。回车或双击：保留打开并把焦点交给阅读区。
- **B4.2** `←`/`→` 折叠/展开当前节点，`⌥` 加点击展开三角递归展开。过滤框里按 `↓` 进入列表；列表里按 `Esc` 先清空过滤文字，再次 `Esc` 把焦点还给阅读区，面板保留。
- **B4.3** 右键菜单复用现有命令：打开、在右侧打开、查看调用者、查看被调用者、查看引用、查看实现（按种类决定可用项，与阅读区右键一致）、高亮此名称、在文件树中显示、复制限定名（`raft::log::Log::append`，分隔符取 `qualifiedNameSeparator`）。
- **B4.4** "定位当前符号"按钮（工具栏靠右的准星图标，命令可绑定快捷键）：取 Context 当前指向的符号，没有时取光标所在的声明；在当前组织方式下展开到该行并选中。如果它被当前过滤隐藏，显示一行提示"当前符号被过滤隐藏"，不自动改过滤。面板不自动跟随光标，那会和大纲打架。
- **B4.5** 分屏时所有打开动作作用于焦点一侧；"在右侧打开"始终在右侧。

## B5 状态

- **B5.1** 项目状态为索引中时显示"正在索引…"占位；首帧缓存会话到达后立即列出，完整会话到达时静默替换（同快照），展开与选中不丢。
- **B5.2** 快照变化（切换 commit、Refresh Index、保存排除规则）后旧树标为过期：顶部出现"列表来自上一快照，正在重建…"，行不可导航。新数据到达后替换，按 `(path, contentID, nameRange)` 恢复选中，匹配不到则清选；展开状态按节点键（组 id、模块路径、类型名 + 文件）尽量恢复。
- **B5.3** 多单元、多语言按 `[(EngineSession, QueryContext)]` 合并，与 `SymbolSearchPanelModel` 现有做法一致；某个 session 的快照不匹配时整次结果作废。
- **B5.4** 项目没有受支持源码时不会出现这个面板的内容（无项目时整体隐藏）；非源码预览期间面板保持，但"当前目录"范围按焦点一侧最近的源码文件计算。

## B6 面板接入与持久化

- **B6.1** `PanelID` 新增 `symbols`，标题"项目符号"。默认放在左侧区、大纲之后、隐藏；`PanelLayout.standard` 的 `heights` 补 `symbols: 0`。旧布局解码时缺失面板会自动补回默认区末尾，不需要迁移。
- **B6.2** 最小宽度 180pt（与文件、大纲同级）；在 180pt 下行显示退化为图标 + 名称，路径与所属省略；工具栏第二行允许换行，过滤、仅公开、范围三个控件只显示短标签。
- **B6.3** "视图 → 面板 → 项目符号"开关，默认快捷键 `⌃⌘S`（显示面板并聚焦过滤框；面板已显示且过滤框有焦点时再按一次隐藏面板）。实施时须通过 `KeyBindingTable.validate`。预设 `⌘1`–`⌘4` 不显示它，与搜索结果、文档相同。
- **B6.4** 组织方式、种类勾选、仅公开、范围四项是应用级偏好（UserDefaults，与面板布局同级），不进阅读会话；过滤文字、展开状态、选中不持久化。
- **B6.5** 图标与颜色复用 `SidebarViewController` 的 `symbolName(for:)` / `symbolColor(for:)`：加一个 `DeclarationKind → OutlineKind` 的映射（interface 复用 trait 图标），不复制一份按形状的分支。
- **B6.6** 可见性在行首用一个 9pt 的小记号表示：实心圆 = 公开，半圆 = 受限，空心圆 = 私有，不适用不画；辅助功能文本写全称。

## B7 可见性事实

`DeclarationFacet` 新增 `visibility: DeclarationVisibility?`（`public` / `restricted` / `private`，`nil` = 不适用），初始化参数默认 `nil`。缓存 codec 格式 4 → 5，旧缓存重建；Rust/Python/TypeScript 的 `extractorVersion` 各升一位。

| 语言 | 公开 | 受限 | 私有 | 不适用 |
| --- | --- | --- | --- | --- |
| Rust | `pub` | `pub(crate)`、`pub(super)`、`pub(in …)` | 无修饰（含 `mod tests` 这类私有模块本身） | impl 块；trait 内的方法签名与默认方法；`impl Trait for T` 里的方法 |
| TypeScript | 顶层声明被 `export`（含 `export default` 与后置 `export { x }`，用现有 `ExportRecord` 判断）；类成员无修饰或 `public` | 类成员 `protected` | 顶层未导出；类成员 `private` 或 `#name`；嵌套函数 | — |
| Python | 名字不以 `_` 开头，或是 `__x__` 形式 | — | 以 `_` 开头且不是 `__x__`；嵌套函数 | — |

固有 impl（`impl Log { }`）里的方法按自身修饰判断。Rust 字段按修饰判断；Python/TypeScript 字段目前不是 facet。

## B8 TypeScript 新种类（D1 已采纳）

若采纳：`DeclarationKind` 新增 `typescriptInterface = 15`、`typescriptTypeAlias = 16`、`typescriptEnum = 17`，形状分别映射到 `.trait`、`.typeAlias`、`.enum`；抽取器在 `interface_declaration`、`type_alias_declaration`、`enum_declaration` 处产出 facet（名称节点为 `type_identifier` / `identifier`），作用域与执行区域不变。它们随 B7 一起升 `extractorVersion`，不额外多一次缓存重建。接口里的方法签名不产出 facet，保持与现在 `abstract_method_signature` 的处理一致。

---

## 已决定（2026-10-11，全部采用推荐值）

| # | 问题 | 决定 | 理由 |
| --- | --- | --- | --- |
| D1 | 是否随本功能补 TypeScript 的 interface / type alias / enum facet（B8） | **是** | 大纲里看得到、项目符号里找不到会被当成 bug；本次已经要升 extractorVersion 和缓存格式，增量成本低 |
| D2 | Rust 方法挂在哪里 | **挂在 impl 块下；类型行展开时按名称合并同名 impl 并标明** | `parentFacetIndex` 指向 impl，跨文件 impl 只能按名称聚合，必须标明不是语义归属 |
| D3 | 可见性过滤的形式 | **一个"仅公开"开关** | 三门语言的可见性不在同一个轴上，三档单选会给 Python 和 TypeScript 一个永远为空的档 |
| D4 | 默认快捷键与位置 | **`⌃⌘S`，左侧区大纲之后，默认隐藏** | `⌃⌘S` 未被占用；大纲按文件跟随光标，两者相邻但不混在一起 |
| D5 | 字段是否单独成组 | **不单独成组，仅在类型展开后出现**；种类过滤里仍可取消勾选 | Rust 结构体字段数量大，摊平会淹没其他组 |
| D6 | 是否同时加 CLI `codeinsight symbols` | **可选，放在 P2 末尾** | 给集成测试一个稳定边界，与 `search` 一样支持 `--json`；不是面板上线的前提 |
| D7 | 跨文件 impl 何时合并到类型行 | **同文件 impl 总是挂；跨文件 impl 只在该名字在单元内唯一时合并并打标** | 真实 crate 里 `Config`、`Error`、`State` 常重名，无条件按名称合并会让每个类型行挂上别人的 impl |

## 实施计划

四个切片，依赖关系：P1 → P2 → P3；P4 贯穿。每个切片完成后把已实现的行为写进 [product.md](product.md)，从本文删除对应的 B 节；全部完成后删除本文和原型。

### P1 抽取器事实：B7 + B8

1. `CodeInsightCore`：`DeclarationVisibility` 枚举与 `DeclarationFacet.visibility`；D1 采纳时同时加三个 `DeclarationKind` case 与 `DeclarationShape` 映射。`kindWeight` 给新种类补权重（interface 18、typeAlias 14、enum 18，与 Rust 同类一致）。
2. `RustDeclarations.enter` 读 `visibility_modifier` 子节点（`RustImports.swift` 已有识别写法）；trait 容器内与 trait impl 内的函数记 `nil`。
3. `TypeScriptExtractor`：顶层声明的可见性在收齐 `ExportRecord` 后回填（后置 `export { x }` 在声明之后）；类成员读 `accessibility_modifier` 与 `private_property_identifier`。D1 采纳时在 `collectDeclarations` 对应分支产出 facet。
4. `PythonExtractor`：按名字规则赋值；嵌套函数记 `private`。
5. `ContentIndexDraftCodec` 格式 5，三个 `extractorVersion` 升位；`CanonicalDump` 输出可见性，goldset 相应更新。
6. **验证**：三语言 fixture 各加少量用例（`pub(crate)`、后置 export、`#private`、`__x__`、trait 方法为 nil）作为 `CanonicalDump` 的 golden；codec 往返的现有测试覆盖新字段；旧格式缓存被重建而不是误解码。

### P2 引擎枚举与模块路径：B1 + B2 的数据侧

1. `EngineSession` 新增一个只读枚举接口：遍历活动文件的全部 facet，产出 B1.2 所述的行（含 `SymbolOccurrenceID`，供 Context 与关系命令复用）。`contentIndexes` 以内容为键，字节相同的文件共享一份索引，所以必须像 `definitionOccurrences` 那样按 `occurrences(of:)` 展开成每个文件一行。不做评分，不设上限。
2. `ModuleMap` 新增公开的 `modulePath(of: PathID) -> [NameID]?`（Rust 沿 `parentModules` 上溯到 crate 根；到不了根返回 `nil`），以及 crate 根集合。Python/TypeScript 的路径规则在同一处实现，供面板与"复制限定名"共用。
3. 可选（D6）：CLI `symbols` 子命令，`--kind`、`--public`、`--path`、`--json`，复用同一枚举接口。
4. **验证**：一个集成测试在 `fixtures/` 的多单元项目上检查：每个文件恰好出现在一个单元下、未挂载文件进入兜底节点、计数与 `CanonicalDump` 一致；模块路径对 `mod.rs`、`foo.rs`、内联 `mod` 三种写法各一例。

### P3 面板：B2–B6

1. `CodeInsightAppModel` 新增 `ProjectSymbolsPanelModel`：持有不可变行数组、组织方式、过滤状态、树的物化与过滤结果、过期与选中恢复；不导入 AppKit。过滤文字复用 `SymbolSearchIndex`，组织方式切换不重新枚举。
2. `PanelID.symbols`、`PanelLayout.standard`、`视图 → 面板` 菜单项、`⌃⌘S`（`KeyBindings` 默认表 + `CommandID`）、`panel.symbols.*` 文案。
3. `CodeInsightApp` 新增一个面板控制器（`NSOutlineView`，懒物化子项），工具栏为过滤框、种类/模块分段、过滤按钮（弹出种类勾选、仅公开、范围）、定位按钮；底部计数行；右键菜单接到 `MainWindowController` 现有命令。
4. 单击/方向键走搜索结果面板的"预览并闪烁、焦点留在列表"路径；回车/双击走"保留打开"路径；Context 按符号模式接收 `SymbolOccurrenceID`。
5. 过期与恢复按 B5；偏好按 B6.4 写 UserDefaults。
6. **验证**：
   - 模型层属性测试：任意过滤组合下，容器节点保留当且仅当存在匹配后代；计数等于可见叶子数；选中恢复只在 contentID 一致时成功。
   - 集成测试：首帧缓存会话 → 完整会话的静默替换保留展开与选中；切换 commit 后旧行禁导航、新树恢复选中。
   - 原生应用（打包后）：在 toydb 或 tokio 上走一遍——`⌃⌘S` 打开并聚焦、空查询列出全部、种类/模块切换、输入过滤、仅公开、当前目录、单击预览与 Context 跟随、回车打开、右键查看调用者、定位当前符号、切换 commit 后的过期与恢复、180pt 窄面板、三主题截图。结果分 PASS / FAIL / BLOCKED 记录。

### P4 文档

1. 把已实现的行为写进 `product.md` 的"Reader 与导航"（面板一段）与"当前限制"（B1.4 的不出现项、可见性是句法修饰、Python 不读 `__all__`）。
2. `architecture.md` 的面板布局段落补一句新面板；"身份与源码事实"补可见性字段与 codec 格式 5。
3. `?` 说明文案列出 B1.4 的差异，避免反复被报成 bug。
