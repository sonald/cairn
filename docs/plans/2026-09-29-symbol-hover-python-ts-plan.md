# 符号悬浮文档：Python 与 TypeScript 计划

日期：2026-09-29。前置计划：`2026-09-29-symbol-hover-docs-plan.md`（Q16：Rust 打磨完后再开其他语言）。
本计划把已落地的悬浮文档底座开放给 Python 与 TypeScript：卡片 UI、悬浮状态机、缓存、
说明行规则、Esc/滚动关闭等全部复用，不动行为。

## 现状（哪些是现成的）

- `SymbolDoc` 模型、`SymbolHoverModel` 状态机、`SymbolDocCard` UI、`hoverIdentifierRange`
  标识符判定：语言无关，零改动。
- `ExactCapabilities.hover` 位已定义；`ExactSession.hover` 协议扩展默认返回 `nil`；
  `ExactCoordinator.hover` 已就绪并按协商能力分派。
- `LSPClient.initialize` 已声明 `hover: { contentFormat: [...] }`，对 pyright /
  typescript-language-server 同样生效（它们当前忽略它，因为没人发 hover 请求）。
- `CodeSnippetHighlighter` 已支持 python / typescript 代码块高亮，卡片签名区直接可用。
- `DependencySourceProbe` 是 Rust 专属（`rustPathRoot` 找 `::` 路径根）；Python/TS 文档上
  路径根必为 `nil`，探测自然短路，无需改动。
- 需要动的只有四处：语法层提取（ReaderCore）、两个非 Rust provider 的 hover（Exact）、
  hover Markdown 的语言感知拆分（AppModel）、UI 语言门控（App）。

## 决策

| # | 决策 |
|---|---|
| P1 | 开放 `.rust`、`.python`、`.typescript` 三种语言；`.javascript` 继续不开（无 Exact provider，避免半支持状态），留作后续 |
| P2 | Python 语法层：签名 = 装饰器之后到头部 `:`（括号/方括号深度为 0）为止，跳过 `@` 装饰器行；文档 = 函数/类体第一条语句的三引号 docstring（PEP 257：跳过空白后必须紧跟 `"""`/`'''`，支持 `\` 转义，按公共缩进取整去缩进）；类体不内联 |
| P3 | TS 语法层：签名 = 声明起点到 `{` / `;`（沿用 Rust 扫描器骨架，字符串定界符加 `'` 与反引号，结尾裁掉悬挂的 `=>` / `=`）；`class`/`interface`/`enum` 沿用短体内联规则；文档 = 声明上方的 `/** */` JSDoc 块（复用现有块解析），中间允许夹 `@decorator` 行 |
| P4 | JSDoc `{@link Target}` 与 `{@link Target Label}` 转成 `cairn-symbol:` 链接（跳过代码围栏）；Python docstring 不做链接改写 |
| P5 | `symbolDoc(fromHoverMarkdown:)` 按语言分派：Rust 维持"两个 fence = 模块路径 + 签名"；Python/TS 取首个 fence 为签名（fence 信息串即 signatureLanguage，缺省用语言名），其余去掉前导 `---` 后为正文；无 fence 时整段为正文 |
| P6 | Python/TS 的精确层说明行规则与 Rust 完全一致（有内容不加注；空结果列出 limitation；pyright 常驻的 `dependenciesUnavailableOffline` 只在空结果时显示） |
| P7 | CLI `exact-hover` 增加 `--language rust\|python\|typescript`（默认 rust），按 ExactCoordinator 的 provider 发现规则起对应 server，用于排查真实返回 |
| P8 | 验收比例：单元测试覆盖提取与拆分；原生验收各语言至少"项目内符号、外部依赖符号、降级态"三张截图；性能样本沿用既有结论不重测 |

## 工作项

### W1 语法层（ReaderCore，`SymbolDoc.swift`）

`syntacticSymbolDoc` 的非 Rust 分支拆成语言分派：

- **Python**（`pythonSymbolDoc`）：
  - 签名：从 range 下界起跳过整行 `@` 装饰器行（facet range 含 decorated_definition
    wrapper），再扫描到深度 0 的 `:` 为止；字符串定界 `"` 与 `'`（含三引号形态）；
    结尾去掉 `:` 后裁空白；多行签名沿用 `dedentContinuationLines`。
  - 文档：头部 `:` 之后跳过空白字符（含换行），必须是 `"""` 或 `'''` 开头才算
    docstring；扫描到未转义的闭合三引号；内容按公共缩进取整、去首尾空行。
  - `signatureLanguage = "python"`。
- **TypeScript**（`typescriptSymbolDoc`，`.typescript`，含 tsx variant）：
  - 签名：复用 Rust 的字节扫描骨架，参数化终止符与字符串定界符：终止 `;` 与 `{`；
    字符串 `"`、`'`、`` ` ``；保留 `<>` 深度跟踪（泛型）；结尾裁掉悬挂 `=>` / `=`；
    `class`/`interface`/`enum` 且体 ≤12 行时内联。
  - 文档：向上收集紧邻 `/** */` 块（复用 `docBlock`），中间允许夹 `@` 开头的装饰器行；
    普通单行注释、`//` 不算文档。
  - `{@link}` 转链接（P4）。
- **JavaScript**：维持现状（首行签名），悬浮门控不开放。

测试（`SymbolDocTests` 增补）：Python 装饰器跳过、多行签名去缩进、带注解默认值、
docstring 各种引号/转义/缩进、非首语句字符串不算、类与方法；TS JSDoc 块、装饰器夹层、
箭头函数悬挂 `=>`、泛型 `{` 不误断、interface 短体内联、`{@link}` 转换与围栏跳过。

### W2 精确层（Exact）

- `PyrightProvider.supportedCapabilities` 与
  `TypeScriptLanguageServerProvider.supportedCapabilities` 增加 `.hover`。
- 两个 `negotiatedCapabilities(from:)` 解析 `hoverProvider`（Bool 或对象）。
- 两个 session 实现 `hover(file:byteOffset:batch:)`：走现有 `requestLocations` 管线
  （didOpen、崩溃重启、batch 取消），`parse` 用 `exactHoverMarkdown`，返回
  `ExactHoverQueryResult`；未协商到 `.hover` 返回 `nil`（协议默认即此，保持显式 guard
  与 rust-analyzer 一致）。
- 协调器、能力协商客户端侧声明均已就绪，无改动。

测试（`CodeInsightExactTests`）：pyright 协商 `hoverProvider` 并返回
`MarkupContent`；未声明 provider 时 hover 返回 `nil`；typescript-language-server
同样两条；更新两个 provider 的能力集合断言。

### W3 拆分与合并（AppModel）

- `symbolDoc(fromHoverMarkdown:)` → `symbolDoc(fromHoverMarkdown:language:)`：
  - Rust：现逻辑不变（测试保护）。
  - Python/TS：首个前导 fence = 签名（信息串为空时用语言名）；其余去前导 `---`
    为正文；不做 intra-doc 链接改写。
- `SymbolHoverModel.present/merge` 把 `token.document` 的语言传下去（document 缺失时
  按 Rust 处理，与现有降级一致）。

测试（`SymbolHoverModelTests`）：pyright 形态（```python 签名 + 正文）、tsserver 形态
（无信息串 fence + 正文）、无 fence 纯文本、Rust 回归不变。

### W4 门控与 CLI（App / CLI）

- `MainWindowController.hoverToken(for:)`：`.rust` → `.rust`/`.python`/`.typescript`，
  注释同步改掉"Rust only"。
- 菜单"显示符号文档"与 ⌥+点击经同一门控，自动生效；设置开关全局，不动。
- CLI `exact-hover` 加 `--language`（P7）：python 走 `PyrightProvider.findExecutable`，
  typescript 走 node + typescript-language-server + tsserver 的发现链（与
  `ExactCoordinator` 默认工厂相同）；profile 用对应语言的 `ExactProfileKey`。

### W5 文档与验收

- 本计划 + 验收记录（`2026-09-29-symbol-hover-python-ts-acceptance.md`）。
- `scripts/ci.sh` 期望条数同步。
- 原生验收（P8）：临时 Python 项目（一个有 docstring 的模块 + 依赖 site-packages
  符号）与 TS 项目（JSDoc + node_modules 依赖符号），真实鼠标悬浮截图：项目内符号
  精确层、外部依赖符号、降级态（server 冷启动期间）、`{@link}` 跳转、Esc/滚动关闭
  抽查。

## 风险与对策

- **真实服务器返回形态与假设不符**（fence 结构、`---` 分隔）：实现 W2 后先用 CLI
  `exact-hover --language` 对真实项目采样，再定 W3 拆分细节；拆不出时整段降级为正文，
  不失败。
- **pyright 对无 docstring 符号返回纯签名**：拆分后正文为空、签名非空，卡片只显示
  签名——与 Rust"没有文档注释"的表现一致。
- **TSX 文件**：`LanguageMode.language == .typescript` 覆盖 tsx variant，门控天然放行；
  provider 请求路径按现有 definition 管线处理。

### 真实采样结论（2026-09-29，本机 pyright / typescript-language-server）

- **pyright**：单一 ` ```python ` fence 是签名，且带声明种类前缀——`(function) def f()`、
  `(method) def open()`、`(variable) path: Module(..)`；类没有前缀（`class Repository()`）。
  fence 后有 `---` 分隔行，正文是 docstring 的 Markdown 渲染（`Args:` 段保留、内联代码
  转反引号）。→ W3 拆分时对 python 剥离 `(小写单词) ` 前缀。
- **typescript-language-server**：单一 ` ```typescript ` fence 是签名，无前缀、无 `---`
  分隔行；JSDoc 标签已渲染为强调体（`*@param*` `id` — …）。无文档的符号 hover 返回
  null（"hover empty"），与降级层组合的表现同 Rust。
- 两者的正文前导 `---` 剥离逻辑通用（pyright 有、tsserver 无，剥不到也无害）。

## 验收

- 单元测试全绿（看完整摘要），CI batch 计数同步。
- 原生验收截图（两语言各至少三张：项目内、依赖、降级）。
- Rust 行为零回归：现有 hover 测试与原验收抽查项不重跑全量，靠单测与 CI。

### 进度（2026-09-29）

W1–W4 已落地，逐片提交：

- W1 `3f63c89`：`syntacticSymbolDoc` 按语言分派；声明头扫描器参数化
  （`HeaderScanConfiguration`），Rust 行为由既有测试保护不变。Python：跳过装饰器行、
  头部 `:` 终止、PEP 257 docstring（`inspect.cleandoc` 式去缩进、`\` 转义还原）。
  TS：JSDoc（装饰器可夹层）、悬挂 `=>`/`=` 裁剪、短聚合体内联、`{@link}` 转
  `cairn-symbol:` 链接。
- W2 `da482bb`：两个 provider 协商并实现 `textDocument/hover`。
- W3：`symbolDoc(fromHoverMarkdown:language:)` 按 P5 分派，pyright 前缀剥离。
- W4：门控放开 rust/python/typescript（JavaScript 不开）；`symbolName(fromDocLink:)`
  额外剥 `.`/`#` 段；CLI `exact-hover --language`。
- 说明：`swift test --filter CodeInsightAppModelTests` 在并行模式下会挂在
  `ProjectIndexer.completeSnapshot` 的信号量上（既有问题，干净树同样可复现并行挂起）；
  CI 的 `--no-parallel` 批次 26.5 秒跑完 400 条全绿。
