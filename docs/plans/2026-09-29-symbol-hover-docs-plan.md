# 符号悬浮文档（Hover Docs）计划

日期：2026-09-29。决策来源：与用户的 grilling 会话 Q1–Q21，全部按推荐裁决。

## 目标

阅读时鼠标停在符号上，弹出类似 VSCode 的富格式文档卡片：定义位置 + 签名 + Markdown 文档正文。
首发只对 Rust 开启；数据模型、降级提取、卡片 UI 与语言无关。

## 决策摘要

| # | 决策 |
|---|---|
| Q1 | 卡片内容：定义位置（一行小字）→ 签名代码块 → Markdown 正文。不含引用计数 |
| Q2 | 外部符号只读本地已有源码（registry / rust-src），不联网；拿不到时明确提示 |
| Q3/Q14 | 悬浮 500ms 触发；⌥+点击；菜单项"显示符号文档"（⌃⇧Space，实现时核对冲突），作用于光标符号 |
| Q4/Q11 | 卡片可交互：滚动、选中复制、链接跳转。自绘无边框子窗口（非 NSPopover），符号→卡片路径上有宽容区；Esc / 滚动 / 切文件关闭。钉住面板留作后续 |
| Q5/Q16 | 首发只开 Rust；其他语言等 Rust 打磨完再开 |
| Q6/Q7 | 两层数据：先弹语法级降级卡片，rust-analyzer `textDocument/hover` 返回后原地替换。降级层是 ReaderCore 新增的按需提取函数，输出与精确层同形（签名 + Markdown），不进索引 |
| Q8 | "hover 零查询"改为"停留满延迟才查询"：移走即取消在飞请求；按（修订 + 符号范围）缓存；跟踪路径不做全文档工作、不读文件 |
| Q9 | 共用 `SymbolDoc` 模型与渲染器；本次只做卡片，Context 面板（F2.8）以后接入 |
| Q10 | 只在标识符上触发（含声明名本身）；关键字、字面量、注释、字符串不触发。判定用 highlight span，零查询 |
| Q12 | 能映射到符号的链接应用内跳转；外部 URL 交浏览器（用户主动点击），悬浮时显示完整 URL |
| Q13 | 结果不完整时底部说明行，复用 `ExactAnalysisLimitation` |
| Q15 | 最大 560×400pt，超出卡片内滚动；签名等宽 + 语法高亮；正文系统字体小一号；跟随三套阅读器主题 |
| Q17 | 所有 `ReaderTextView` 视图生效；无精确会话的修订只显示降级结果并注明原因 |
| Q18 | 延迟固定 500ms；设置里一个"悬浮显示文档"总开关（默认开），键盘触发不受影响 |
| Q20/Q21 | 先写 plan、做底层，同时出可交互 HTML 原型；**UI 层等原型确认后再做**（唯一的中途停顿点） |

## 现状（摸底结论）

- 阅读器 `ClickTextView`（TextKit 2 `NSTextView`）只有折叠栏做鼠标跟踪；点击经 `clickHandler` → `onTokenClick`。
- LSP 未声明、未实现 hover；`ExactSession` 只有 definition / implementation / references / call hierarchy。
- 索引不存文档注释，签名只存哈希；`excerpt()`（ReaderCore/Excerpt.swift）只给原始行。
- `MarkdownPreviewRenderer` 可复用（`AttributedString(markdown:)` + 代码块 tree-sitter 高亮），宿主视图是 TextKit 1、固定 780 宽，卡片需要自己的小视图。
- 旧规则：`m1-plan.md` F2.1 与 `m1-interactive-test-plan.md` T4.8 "hover 零查询"——本计划改写它们。

## 数据模型

`CodeInsightReaderCore/SymbolDoc.swift`（无 AppKit 依赖）：

```swift
public struct SymbolDoc: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case syntactic, exact }
    public enum Note: Equatable, Sendable {
        case exactPending                 // 语法级结果 · 精确分析未就绪
        case exactUnavailable(String)     // 精确分析不可用：原因
        case limited(Set<ExactAnalysisLimitation>) // 在 Exact 层映射成字符串再传入
        case dependencySourceMissing      // 依赖源码不在本地缓存
    }
    public var location: String?          // "crate::mod::Type" 或 "path:line"
    public var signature: String?         // 代码块内容
    public var signatureLanguage: String? // "rust"
    public var markdown: String           // 正文
    public var source: Source
    public var notes: [Note]
}
```

## 工作项

### W1 降级提取（ReaderCore）

`symbolDoc(forDeclarationAt:in:)`：给定声明 range，
- 签名：声明起点到 body `{` / `;` / `=`（取先到者）之前，裁剪尾部空白；多行保留缩进归一化。
- 文档：向上收集紧邻的 `///`、`/** */`、`#[doc = "..."]` 行，允许中间夹 `#[attr]` 行；去掉前缀和统一缩进；`//!` 只在悬浮 `mod` / 文件顶部时收集；普通 `//` 不算文档。
- Rust intra-doc 链接 ``[`Foo`]`` 保留为 Markdown 链接文本，交给 UI 层解析。
- 与 `excerpt()` 分开写，不改它的行为。

测试：`///` 多行、`/** */`、`//!`、属性夹在中间、空行打断、无文档、多行签名、`where` 子句。

### W2 精确层（Exact）

- `ExactCapabilities.hover`；`LSPClient.initialize` 声明 `hover: { contentFormat: ["markdown", "plaintext"] }`。
- `ExactSession.hover(file:byteOffset:batch:) -> ExactHoverResult?`，协议扩展提供默认实现返回 `nil`（Pyright / TS / 测试替身零改动）。
- `RustAnalyzerSession` 实现：走现有 `requestLocations` 管线（didOpen、崩溃重启、batch 取消）；解析 `MarkupContent` / `MarkedString` / 数组三种形态。
- rust-analyzer hover Markdown 结构：首个 ```` ```rust ```` 块常是模块路径，第二个是签名，`---` 之后是正文。拆成 `location` / `signature` / `markdown`；拆不出时整段作为 `markdown`。
- `ExactCoordinator.hover(file:byteOffset:generation:batch:)`，与 `definition` 同样处理 prepare 等待、generation、依赖路径映射；结果附带当前 `analysisEnvironment.limitations`。

测试：解析三种 hover 形态、拆分签名、空结果；假 session 验证 coordinator 转发与 generation 失配丢弃。

### W3 悬浮状态机（AppModel，无 AppKit）

`SymbolHoverModel`：
- 输入：`pointerMoved(offset:tokenRange:)`、`pointerExited`、`scrolled`、`fileChanged`、`escape`、`pointerEnteredCard/ExitedCard`、`explicitRequest(offset:)`。
- 状态：`idle → dwelling(token) → showing(token, doc)`；同 token 内移动不重置计时；换 token 重新计时并取消在飞 batch。
- 延迟 500ms 由注入的时钟驱动，测试可控。
- 显示时先给降级结果，精确结果到达且 token 仍是当前 token 时替换。
- 缓存键：`(contentID, tokenRange)`；LRU 64 条。
- 总开关关闭时忽略指针事件，但接受 `explicitRequest`。

测试：延迟、同 token 不重置、换 token 取消、离开关闭、宽容区（卡片进入前短暂离开不关）、Esc、滚动关闭、缓存命中不再查询、开关关闭仍响应显式请求。

### 进度（2026-09-29）

W1–W3 与 W5 已落地，UI 层（W4）等原型裁决：

- W1 `Sources/CodeInsightReaderCore/SymbolDoc.swift`：`SymbolDoc` 与 `syntacticSymbolDoc(forDeclarationAt:in:location:)`。非 Rust 语言暂时只给首行签名（按 Q16，其他语言不开放悬浮）。
- W2 `ExactSession.hover`（协议扩展默认返回 `nil`）、`exactHoverMarkdown`、`RustAnalyzerSession.hover`、`ExactCoordinator.hover`。
- W3 `Sources/CodeInsightAppModel/SymbolHoverModel.swift`，挂在 `AppModel.symbolHover` 上。数据源来自 `ContextWindowModel.hoverFallback` / `exactHover`：降级层复用单击时的本地解析，但不改动 Context 面板的状态。
- 说明行规则：精确层有内容时不加说明行；精确层返回空时，列出当前生效的 limitation；外部符号两层都没有结果，且 `dependenciesUnavailableOffline` 生效时，显示"依赖源码不在本地缓存"。
- 切换符号：已有卡片时，移到新符号只需停留 250ms，同时旧卡片进入 250ms 宽容期。

W4 也已落地，原生验收见 `2026-09-29-symbol-hover-docs-acceptance.md`。实现中新增的规则：

- **依赖源码探测（`DependencySourceProbe`）**：降级层为空时，在发起精确请求之前运行。它读 `Cargo.toml` 和 registry/vendor 目录，判断依赖源码是否在本地；不在就立即提示，不用等冷启动的 rust-analyzer。
- **只缓存最终结果**：精确层返回了内容，或明确不支持 hover。超时显示"精确分析未就绪"，下次悬浮重新请求。
- **快速路径不处理 impl**：`impl X` 里的 `X` 交给引擎解析到类型定义。语法级结果会去掉 rustdoc 的隐藏行。
- **Esc 优先关闭卡片**：主窗口的 Esc 监听器先关卡片（包括卡片自己是 key window 的时候）。卡片接受首次点击；阅读区的鼠标跟踪在应用激活时就生效。
- **新增 CLI `codeinsight exact-hover`**：打印 rust-analyzer 返回的原始 hover Markdown，用于排查。

### 原型裁决（2026-09-29，`evidence/hover-docs-prototypes/hover-card.html`）

- H1 签名区：**A 底色条**（chrome 色托底，上下细分隔线）。
- H2 卡片外壳：**B 半透明材质**（`NSVisualEffectView`）。
- H3 弹出方向：**上方优先**，空间不够时翻到下方。

### W4 UI 层（**原型确认后**）

- `ClickTextView` 增加 `.mouseMoved` tracking area 与 `hoverHandler`；指针处 span 类型过滤（Q10），只把 offset/tokenRange 交给模型，不做其他工作。
- `SymbolDocPanel`：无边框 `NSPanel` 子窗口，`NSVisualEffectView` 材质 + 圆角；内容为 TextKit 1 `NSTextView`，复用 `MarkdownPreviewRenderer`（加参数覆盖宽度与 inset）。
- 链接：intra-doc / 符号链接 → 应用内跳转；http(s) → `NSWorkspace.open`；悬浮显示 URL。
- ⌥+点击与菜单项；设置开关；本地化字符串（中英）。

### W5 文档与规则更新

- 改写 `m1-plan.md` F2.1 与 `m1-interactive-test-plan.md` T4.8 为新规则。
- `design.md` F2.8 注明共享 `SymbolDoc`。

## 验收

- 单元测试：W1–W3 全部新增用例通过（看完整测试摘要，不只看退出码）；CI batch 计数同步更新。
- 原生验收（打包应用截图，证明卡片真的可见）：项目内符号、外部依赖符号、降级态、Safe 模式受限提示。
- 性能：几次悬浮扫过长文件的样本，确认跟踪路径无退化（不做 p95 大规模测量）。
- 暂不覆盖 Python / TypeScript。
