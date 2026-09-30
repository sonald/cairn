# 上下文窗口：类型直达、跟踪光标、跟踪所在函数（需求）

日期：2026-09-30
状态：需求已定稿（问答 Q1–Q22 与原型裁决 T1–T4 已全部确认）
实施计划：[2026-09-30-context-window-type-follow-plan.md](2026-09-30-context-window-type-follow-plan.md)
依赖：[快捷键集中定义表（K0）](2026-09-30-keybindings-requirements.md)
原型：[evidence/context-window-type-follow/lens-type-hop.html](evidence/context-window-type-follow/lens-type-hop.html)

## 1. 背景

Source Insight 的 Context Window 有三个容易被忽略的能力：

1. **类型直达**：选中 `struct S *psvar` 里的 `psvar`，窗口直接显示 `S` 的定义，而不是 `psvar` 的声明。
2. **跟踪光标下的符号**：键盘移动光标也会刷新窗口，不只鼠标点击。
3. **跟踪包含光标的函数／类**：窗口显示光标所在函数（或类）的定义，而不是光标下的符号。

Cairn 的上下文窗口（代码里叫 Lens，模型是 `ContextWindowModel`）目前三项都缺，见 §2。

## 2. 现状（2026-09-30 实测）

### 2.1 类型直达：缺

- `ContextWindowModel.present` 对局部绑定只落到 `BindingRecord.declarationRange`（`Sources/CodeInsightAppModel/ContextWindowModel.swift:589`）。窗口显示的是变量声明那一行。
- 精确层只接了 `definition / implementation / references / callHierarchy / hover`（`ExactCapabilities`，`Sources/CodeInsightExact/ExactProvider.swift:6`），没有 `textDocument/typeDefinition`。
- CLI 实测（`.build/debug/codeinsight resolve`）。探针：

  ```rust
  pub struct S { pub n: u32 }
  fn use_it(ps: &S) -> u32 {
      let local: Box<S> = Box::new(S { n: 1 });
      ps.n + local.n
  }
  ```

  | 位置 | 结果 | 期望 |
  |---|---|---|
  | `ps`（5:5） | `strong direct [lexicalBinding#0] -> 3:11`（形参名） | `S`（1:12） |
  | `local`（5:12） | `strong direct [lexicalBinding#1] -> 4:9`（let 名） | `S`（1:12） |
  | 类型位置上的 `S`（3:16） | `probable direct [nameOnly#0] -> 1:12` | 已能解析：第二跳可以复用 |
  | 字段访问 `ps.n` 的 `n`（5:8） | `probable direct [nameOnly#1] -> 1:20`（字段 facet） | 已能解析：字段可以作为第一跳 |

### 2.2 已有、可复用的基础

- Rust 抽取器已经给绑定记录了一个**类型名提示** `BindingRecord.targetHint`：类型注解（`annotatedTargetHint`，`RustScopeBuilder.swift:414`）、`self` 所在 impl 的类型名（`RustScopeBuilder.swift:255`）、构造表达式 `S::new()` / `S { .. }`（`constructedTargetHint`，`RustScopeBuilder.swift:430`）。它目前只用于方法调用的接收者解析（`Resolver.swift:552`），**只存名字，不存位置**，而且 `Box<S>` 取的是 `Box`（`supportedTypeName`，`RustScopeBuilder.swift:487`）。
- 精确层已经有“句法先出、精确原地升级”的管线（`startExactUpgrade / applyExact`）和内容漂移校验。
- `ReadingPlan.enclosingAssociatedFacets(at:in:)`（ReaderCore）已经能给出光标所在的嵌套大纲项，作用域标题栏就用它（`CodeInsightReaderUI.swift:1271`）。
- 命令面板的 `>` 命令列表直接读 `NSApp.mainMenu`（`PalettePanel.swift:1063`），菜单快捷键改了，面板自然跟着变。

### 2.3 跟踪光标：部分缺；所在函数：缺

- 单击会调用 `tokenClicked`（`MainWindowController.swift:4669` → `3780`）。键盘移动光标只触发 `onCaretChange`（`MainWindowController.swift:4687`），刷新作用域标题栏和大纲高亮，**不刷新上下文窗口**。
- 上下文窗口只有 `Mode.follow / .pinned`（`ContextWindowModel.swift:12`）。

## 3. 需求

编号用于计划和验收引用。

### R1 类型直达

- **R1.1** 单击或光标停在一个**值绑定**上（形参、局部变量、`self`/`this`、字段、带注解的全局），窗口默认显示它的**底层类型定义**。
- **R1.2** 类型来源，按优先级：
  1. 句法：绑定或字段写出的类型注解，剥掉包装后的头类型（R1.4）。
  2. 句法：`self` / `this` / Rust 的 `Self` / Python 的 `typing.Self` → 所在 `impl` 实现的类型或所在 class（Q6、Q11）。`impl Trait for S` 取 `S`。
  3. 句法：Rust 构造表达式 `let x = S::new()`、`let x = S { .. }`（沿用现有 `constructedTargetHint` 的识别范围），确定性降一档。
  4. 精确层：LSP `textDocument/typeDefinition`，覆盖没写类型的推断场景（`let x = foo();`）。
- **R1.3** 两跳的确定性取较低的一档，用现有的确定性石子显示。
- **R1.4** 头类型剥离表：

  | 语言 | 剥掉 | 例 |
  |---|---|---|
  | Rust | `&` `&mut` `*const` `*mut` `dyn` `impl`；`Box Rc Arc RefCell Cell Mutex RwLock Option Vec` 取第一个类型实参；路径取最后一段 | `&mut Box<S>` → `S`；`Option<Arc<a::S>>` → `S` |
  | Python | `Optional[T]`、`T \| None`、`list[T]` 等内建容器取元素；字符串注解去引号 | `Optional["S"]` → `S` |
  | TS | `T \| undefined \| null`、`T[]`、`Readonly<T>`、`Promise<T>` | `S[] \| undefined` → `S` |

  剥离表之外的泛型（如 `HashMap<K, V>`）取它自身；剥完剩下多个互不包装的名字（联合类型 `A | B`）就给出多个候选，走现有候选列表。
- **R1.5** 不跳的情况：
  - 原始类型（`u32`、`str`、`bool`、`int`、`string` 等）不跳，停在声明，徽章写明“原始类型，不跳”（Q3）。
  - 类型别名停在别名本身，不穿透（Q10）。
  - 泛型参数：只有一个约束时跳到这个约束，标签附上 `(T: Read)`；有多个约束或没有约束就停在声明，标签写“泛型 `T`”（Q7）。
  - 目标本身是类型、函数、模块，或者是导入绑定：沿用现有行为。
- **R1.6** 项目外的类型（标准库、第三方包）由精确层给出位置时，显示依赖源码，和现在 ⌘+单击 进依赖的行为一致（Q3）。
- **R1.7** 精确结果晚到时（Q4）：先显示变量声明，一跳标签写“`x` → 类型解析中…”并转圈；结果到了原地换成类型。用户在这期间手动切过声明/类型，就不再自动切换。精确层未就绪时，标签写“类型需要精确分析 · 未就绪”，不转圈。
- **R1.8** 没有“变量显示类型定义”的设置开关（Q8）。

### R2 两个概念分开（Q1）

- **R2.1** 模型区分**用户指向的符号**（`symbolCandidate`）和**窗口显示的内容**（`displayedCandidate`）。
- **R2.2** ⌘+单击、“查看引用/调用方/实现”、悬停文档、阅读集等一切“对符号做事”的入口只读 `symbolCandidate`。所以对 `ps` 做 ⌘+单击 仍然跳到 `ps` 的声明，“查看引用”列出 `ps` 的引用。
- **R2.3** 窗口正文、路径、徽章、双击打开读 `displayedCandidate`：看见什么就打开什么。

### R3 跳到类型定义（Q2、Q9）

- **R3.1** 新命令“跳到类型定义”，作用于光标（或点击位置）下的值绑定，目标同 R1。
- **R3.2** 入口：菜单“导航 → 跳到类型定义”，默认 ⌃⌘J；阅读器右键菜单；鼠标手势 ⌘⇧+单击。三者都登记在快捷键定义表里（K0），可以改键。
- **R3.3** 阅读轨迹里这一跳的原因记为新的“类型”（`NavigationCause.typeDefinition`），可以持久化。
- **R3.4** 目标不存在时（原始类型、泛型无约束、精确层未就绪），状态栏短暂提示原因，不跳转。

### R4 跟踪光标下的符号（Q5）

- **R4.1** 键盘移动光标后 150 ms 防抖，按单击同样的规则刷新窗口（句法层）。
- **R4.2** 精确请求：单击立即发；键盘移动时，光标在同一个名字上停留满 400 ms 才发。光标离开这个名字就取消未发出的请求，已发出的请求走现有批次取消。
- **R4.3** 光标落在空白、关键字、字面量、原始类型名上时，**保留上一次内容**，右上角显示淡色小标“光标不在符号上 · 保留上一次”（T4）。单击空白同样保留，这是 Source Insight 的做法。
- **R4.4** 同一个名字的区间内移动光标，不重新查询（现有 `locatedToken` 去重）。
- **R4.5** 分屏时跟随当前获得焦点的阅读器。

### R5 跟踪所在函数（Q12）

- **R5.1** 窗口可以切到“所在函数”模式：显示包含光标的最内层函数或方法；闭包不算。光标不在任何函数里时，退到最内层的类型（`impl`、struct、enum、trait、class、interface）；都没有时显示占位文字“光标不在任何函数或类型里”。
- **R5.2** 只显示文档注释加签名，截止到函数体的 `{` 或 `:`；下面再露出函数体第一行，渐隐处理，再加一行“⋯ 函数体 N 行 · 双击打开”（T3=A）。类型同理，写“⋯ 主体 N 行”，impl 额外写“M 个方法”。
- **R5.3** 纯句法，不需要索引就绪，也不发精确请求。同一个大纲项内移动光标不刷新。
- **R5.4** 候选的确定性是确定事实：不显示石子，徽章显示种类（“方法”“函数”“impl”……）。

### R6 模式控件与固定（T1=B、Q13）

- **R6.1** 头部左侧是两段控件 `符号 | 所在函数`，右边紧挨一个独立的图钉按钮。“跟踪什么”和“是否固定”是两个独立状态。
- **R6.2** 固定时头部变琥珀色（沿用现有样式），点击代码只更新关系面板；两种跟踪模式都能固定。
- **R6.3** `符号 / 所在函数` 的选择随会话恢复，每个窗口单独保存；固定状态不恢复，恢复后一律不固定。
- **R6.4** 命令“跟踪光标下的符号”“跟踪所在函数”“固定 / 取消固定”登记到快捷键定义表，默认不绑定按键。

### R7 一跳标签（T2=A）

- **R7.1** 类型直达时，头部的符号名位置显示 `ps: &S → S`：前半段是等宽字体的绑定写法（`self` 显示 `&self`，推断的显示变量名），后半段是衬线字体的类型名。
- **R7.2** 当前显示的一端加粗，另一端变淡、可以点击；点击就在声明和类型之间切换。这只影响本次显示，不改设置。
- **R7.3** 泛型约束附在类型名后，写成 `(T: Read)`。

### R8 CLI 与金标

- **R8.1** `codeinsight resolve --type-hop`：对值绑定的结果追加一行 `type -> path:line:col`（或 `type -> primitive u32`、`type -> generic T`），供 goldset 断言。
- **R8.2** `codeinsight exact-typedef <position> --project <dir>`：与 `exact-def` 对称。
- **R8.3** `codeinsight dump` 输出新增的类型引用字段。

## 4. 非目标

- 不做类型推断引擎；推断类型只靠精确层。
- 不做泛型实参推导（`Vec<T>` 里的 `T` 究竟是什么）。
- 不改现有 `targetHint` 的方法接收者语义（`Box<S>` 的方法解析仍取 `Box`）。能否统一，留作后续单独评估。
- TypeScript 的 `interface` / `type` 暂时不补进 `DeclarationKind`：这一轮只靠精确层落到它们；补进索引另开一项。
- VoiceOver 与语音相关验证不在范围内（AGENTS.md）。

## 5. 裁决记录

| # | 结论 |
|---|---|
| §7-1 | 单击变量默认显示类型定义 |
| §7-2 | 所在函数模式在函数外时退到所在的类型 |
| §7-3 | TS `interface` / `type` 另开一项，这一轮只靠精确层 |
| Q1 | 拆开 `symbolCandidate` 与 `displayedCandidate`（R2） |
| Q2 | 新增“跳到类型定义”：右键菜单、⌘⇧+单击，阅读轨迹原因记为“类型”（R3） |
| Q3 | 项目外的类型显示依赖源码；原始类型不跳（R1.5、R1.6） |
| Q4 | 精确结果晚到时先显示声明，标注“解析中”，到了原地换；用户手动切过就不换（R1.7） |
| Q5 | 键盘移动只触发句法层；停留 400 ms 才发精确请求（R4.2） |
| Q6 / Q11 | `self` `this` `Self` `typing.Self` 用句法落到所在类型（R1.2） |
| Q7 | 泛型参数只有一个约束时跳到约束（R1.5） |
| Q8 | 不加设置开关（R1.8） |
| Q9 | ⌃⌘J（R3.2） |
| Q10 | 类型别名停在别名（R1.5） |
| Q12 | 所在函数模式只显示签名加文档（R5.2） |
| Q13 | 记住跟踪模式，每个窗口单独保存；固定不恢复（R6.3） |
| Q14 | 我只写需求、原型、计划；实现交给其他 Agent |
| Q20 | 依赖 K0，新快捷键直接登记到定义表 |
| Q22 | 计划按阶段写成自包含的任务说明，顺序是 P0 → P1 → P2 → P3 → P4 |
| T1 | B：两段控件加独立图钉（R6.1） |
| T2 | A：头部内联一跳标签（R7） |
| T3 | A：函数体渐隐加“⋯ N 行”（R5.2） |
| T4 | 保留上一次内容（R4.3） |
| 默认 | 分屏跟随焦点阅读器；对比和历史视图行为一致；新增文字中英双语 |
