# 文档面板（Dash 来源）：需求与实施计划

状态：待实现。2026-10-08 定稿；Fable 负责需求、原型与验收，Opus 5.5 (high) 负责实现。完成后把仍有效的结论归入 [product.md](../product.md) 与 [architecture.md](../architecture.md)，删除本文件。

原型：`~/work/ai/vibecoding/codeinsight-prototypes`（`swift run DashRenderPrototype`，README"结论"一节）。它验证了渲染方案、深色主题做法和 Dash API 的行为，是一次性代码；内容规则 JSON、反色 CSS 和 API 调用顺序可以照搬，其余只作参照。

## 1. 目标行为

### 面板

- 面板 ID `docs`（"文档"）已在布局模型里预留：默认右侧最下、默认隐藏。本计划给它内容，并把它加进"视图 → 面板"（命令 `view.panel.docs`，默认无快捷键）。
- 第一次"在文档面板中显示"时面板自动变为可见（从布局的 `hidden` 移出并保存），之后显示状态随布局保存；用户 `×` 关闭后不再自动出现，下一次显式动作再打开。最小宽度 300pt、最小高度 240pt；首次显示占所在侧 40% 高度。
- 面板内容不跨重启保存：重启后显示空状态"在阅读区选中一个符号，用右键菜单、悬浮卡片或 ⌃⌘D 在这里查看文档"。

### 触发（显式，不跟随光标）

三个入口共用一个动作 `showInDocsPanel(identifier, document, offset)`：

- 阅读区右键菜单："在文档面板中显示"，放在"在 Dash 中查看"旁边；光标下没有标识符时置灰。
- 悬浮卡片：在现有"↗ 在 Dash 中查看"旁再加一条"在文档面板中显示"链接。
- 关系菜单："在文档面板中显示"，默认 `⌃⌘D`（命令 `relations.showInDocsPanel`），作用于光标处的标识符。取词走 `hoverRequestAtSelection()` 再从文档字节切出标识符（① 的 `dashLink` 就是这样取的），**不要**经过 `hoverToken(for:)`——它对 JavaScript 返回 nil，会把语言门槛带回来。

不设语言门槛：任何语言、包括没有语言服务器的文件，只要光标下有标识符就可用。未安装 Dash（`dash-plugin://` 无处理程序）时三个入口都不出现，与 ①"在 Dash 中查看"一致；已安装但未运行或 API 未开启时入口出现，面板用状态文字说明。

### 查询与命中

- 查询词沿用 ① 的 `DashIntegration.query`：rust-analyzer 精确结果带路径时发 `std::sync::Mutex::lock`，否则发标识符。右键和 ⌃⌘D 在悬浮卡片正显示该符号时复用卡片的精确结果，否则只有标识符。
- 每次查询：读 `~/Library/Application Support/Dash/.dash_api_server/status.json` 的端口 → `GET /health`（1 秒超时）→ `GET /docsets/list` 取全部 identifier → `GET /search?query=&docset_identifiers=<全部>&search_snippets=false&max_results=20`。identifier 是每台机器随机的，不能缓存到磁盘；一次应用运行内可以缓存 `/docsets/list`，搜索返回空时刷新一次再搜。
- `/search` 没有结果时返回 `[{}]`：先丢掉空字典再处理，否则会多出一条假候选。
- **精确命中**：把查询词按 `::` 或 `.` 拆成段；把解码后的 `load_url` 按 `/ . # _ - :` 切成 token。一个结果是精确命中，当且仅当 `name` 等于最后一段，且其余每一段都作为整个 token 出现在 URL 里（Sphinx 的片段是 `//apple_ref/<Type>/<限定名>`，rustdoc 的限定名拆在路径 `std/sync/struct.Mutex.html` 和片段 `Method/lock` 里；用整 token 匹配是为了让 `io` 不命中 `asyncio`）。
- **自动加载规则**：精确命中只有一个 → 直接加载；多个精确命中且查询词有两段以上 → 加载 Dash 顺序里的第一个（`std::sync::Mutex::lock` 在 std/poison/nonpoison 都命中时取 std）；多个精确命中但查询词只是裸标识符（如 `acquire` 同时命中 threading.Lock.acquire 和 asyncio.Lock.acquire）→ 不自动加载，等用户选；没有精确命中 → 不自动加载。候选下拉在结果多于一个时总是显示全部结果（`name · type · docset`），只有一个结果时直接加载。
- 新查询取消进行中的查询；用代次号丢弃迟到结果。

### 渲染

- 受限 `WKWebView`：`websiteDataStore = .nonPersistent()`，`allowsContentJavaScript = false`，`javaScriptCanOpenWindowsAutomatically = false`。
- 一份 `WKContentRuleList`（标识符带版本后缀，如 `cairn-docs-dash-v1`，规则变了就升版本，因为 store 会持久化编译结果；先 `lookUpContentRuleList` 再编译）：屏蔽全部 → `ignore-previous-rules` 放行 `^http://127\.0\.0\.1[:/]` → 屏蔽所有 `script` 资源 → `css-display-none` 隐藏导航：`div.related, div.sphinxsidebar, div.footer, div.mobile-nav, nav.sidebar, .sidebar-resizer, rustdoc-search, .sub, #top-link, .theme-selection`。首次加载必须等规则就绪。
- 直接 `load(URLRequest(url: load_url))`，带片段，由 WebKit 原生滚到锚点；不用 `loadHTMLString`，不自己拼 URL（`load_url` 里的 docset 令牌每个 docset 不同）。
- 导航策略：目标主机是 `127.0.0.1` 的链接允许在面板内跳转，面板头部有"后退"（`goBack`，按 `canGoBack` 启用）；其他 http/https 链接取消并交给系统浏览器（与悬浮卡片一致）。同页只换锚点时 WebKit 不回调 `didFinish`，状态更新不能依赖它。
- 头部：当前符号（候选 name + type）、来源"Dash · <docset 名>"、"↗ 在 Dash 中打开"（用 ① 的 URL）、后退按钮、候选下拉（候选多于一个时显示，切换即加载）。面板内跳转后头部副标题显示网页标题（KVO `WKWebView.title`，无需 JS）。
- 主题：WebView 固定 `appearance = .aqua`，让页面按自带浅色样式渲染；Cairn 主题为深色时，用 `WKUserScript`（`atDocumentEnd`，仅主框架）插入一个 `<style>`，内容是 Dash 自己的反色 CSS（原型 README 和源码里有全文：`html { filter: invert() hue-rotate(180deg) … }`，图片/视频反转回来）。用户脚本在页面脚本关闭时仍会运行（原型已验证）。切换主题时重新加载当前页面。
- 不可用状态只显示文字，不放 WebView、不自动启动 Dash、不改 Dash 偏好：
  - 未安装（`dash-plugin://` 无处理程序）：入口已隐藏，正常情况下到不了这里；面板若仍可见（如上次会话留下的）显示"未安装 Dash"；
  - 已安装未运行（`NSRunningApplication` 里没有 `com.kapeli.dashdoc` / `com.kapeli.dash-setapp`）："Dash 未运行"；
  - 运行中但 `/health` 不通："Dash 的 API 服务未开启，在 Dash → Settings → Integration 打开"；
  - 搜索无结果："Dash 里没有 <查询词>"；
  - Dash 试用期已过：`load_url` 或 `/search` 返回 403 且正文含 "API access blocked due to Dash trial expiration" → "Dash 试用期已过，API 不可用"；
  - 其他加载失败：错误说明。

### 离线规则

`product.md` 第 9–11 行的"禁止网络"补一句：本机 Dash 服务（127.0.0.1 上的 Dash API 与它的文档服务器）不算外网，Safe 与 Trusted 模式都可用；文档面板只连 loopback，页面脚本关闭，页面引用的外部资源被规则拦截。

### 非目标

不跟随光标、不做多来源合并与来源设置界面、不做文档内搜索、不缓存页面、不做 TypeScript lib 文档（TS docset 是 Handbook）。

## 2. 现状与受影响代码

- 布局模型 [PanelLayout.swift](../../Sources/CodeInsightAppModel/PanelLayout.swift)：`PanelID.docs` 已存在，默认在 `standard` 的右侧末尾且 `hidden`，高度 0。面板外壳与最小尺寸在 [PanelViews.swift](../../Sources/CodeInsightApp/PanelViews.swift)（`minimumWidth` 第 35 行、`panelTitle` 第 351 行，`panel.docs` 文案已存在）。
- 面板内容挂接：[MainWindowController.swift](../../Sources/CodeInsightApp/MainWindowController.swift) 约 1946–1958 行的 `contents` 数组把各控制器视图装进 `PanelChromeView`；`docs` 目前不在其中，所以不渲染。
- 视图菜单"面板"子菜单：[CodeInsightApp.swift](../../Sources/CodeInsightApp/CodeInsightApp.swift) 约 2198–2212 行，按 `(PanelID, CommandID)` 列表生成；命令定义在 [KeyBindings.swift](../../Sources/CodeInsightAppModel/KeyBindings.swift)（`viewPanelFiles` 第 179 行、`relations.showSymbolDocumentation` 第 203 行的模式）。
- ① 已有：[DashIntegration.swift](../../Sources/CodeInsightApp/DashIntegration.swift)（`isInstalled`、`url(query:)`、`query(identifier:doc:language:)`）、右键菜单项 `openInDash` 和 MWC 的 `dashQuery`、悬浮卡片 `SymbolDocCard.show(..., externalLink:)` 与 `openSymbolDocLink` 的 `dash-plugin` 分支。
- 现有受控 WKWebView（HTML 预览）在 `ReaderViewController.displayPreviewHTML` 约 2845 行，用 CSP 禁网；文档面板用内容规则而不是 CSP，因为页面要从 Dash 本机服务器加载 CSS。
- 主题枚举 `ReaderSettings.Theme`（light / dark / siClassic），窗口外观在 `applyReaderSettings` 里设置。
- 打包 Info.plist 由 `scripts/make-app.sh` 生成，没有 ATS 配置；原型以裸可执行文件访问 `http://127.0.0.1` 没有遇到 ATS 拦截。若打包后 URLSession 或 WebView 报 ATS 错误，在 make-app.sh 的 plist 里加 `NSAppTransportSecurity/NSAllowsLocalNetworking`，不要用其他方式绕过。

## 3. 设计约束

- `CodeInsightAppModel`（无 AppKit）：
  - `DocumentationSource` 协议：`name`、`availability() async -> DocumentationAvailability`、`search(_ query: String) async throws -> [DocumentationCandidate]`。候选：`name`、`kind`、`docset`、`loadURL`、`sourceName`；`isExactMatch(for query)` 是纯函数，放在源实现里。
  - `DashDocumentationSource`：URLSession 实现上面的协议；端口读取、健康检查、docset 列表缓存、搜索、精确匹配。
  - `DocumentationPanelModel`：状态机 `idle / unavailable(reason) / searching(query) / candidates([…]) / showing(candidate, candidates)`，持有当前代次；新查询取消旧任务；对外是 `@Observable` 状态 + `show(query:)`、`select(candidate)`。用注入的 stub 源测试。
- `CodeInsightApp`：
  - `DocumentationPanelController: NSViewController`：头部、候选下拉、后退、状态文字、WKWebView、内容规则、深色用户脚本、导航代理。观察模型状态渲染；主题变化时重载。
  - MWC：把 `.docs` 加进 `contents`；`showInDocsPanel(...)` 构造查询词、`setPanelVisible(.docs, true)`、调用模型；视图菜单"文档"项与 `⌃⌘D` 命令；右键菜单项与卡片链接（卡片用自定义 scheme，例如 `cairn-docs:`，在 `openSymbolDocLink` 里分发；`SymbolDocCard.show` 的 `externalLink` 改为链接数组）。
- 复用 `DashIntegration.query` 取查询词；`DashIntegration.url` 给"在 Dash 中打开"。不要再写第二份 Dash URL 拼接。
- 不加新依赖；JSON 用 `JSONSerialization` 或 `Codable` 即可。
- 分支与提交：`feat/docs-panel`，不直接改 `main`；每步一个或几个英文简短提交；验收前 rebase 到最新 `main`，不用 merge。
- 本地化：新文案中英文都要有，`bash scripts/ci.sh static` 会检查。

## 4. 实施顺序

每步结束都要能 `swift build` 并通过该步测试。

1. **模型与来源**：`DocumentationSource`、`DocumentationCandidate`、`DashDocumentationSource`（含精确匹配纯函数）、`DocumentationPanelModel`。测试见 §5。
2. **面板控制器**：WebView + 内容规则 + 状态文字 + 头部；接进 MWC 的 `contents`（此时还没有入口，可用临时命令或测试驱动）。
3. **入口**：视图菜单"文档"、关系菜单"在文档面板中显示" `⌃⌘D`、右键菜单项、悬浮卡片链接、中英文文案；首次显示时面板自动可见并给 40% 高度。
4. **链接与主题**：面板内 loopback 跳转与后退、外部链接交浏览器、网页标题副标题、深色主题注入与主题切换重载。
5. **文档**：`product.md` 悬浮文档一节下新增"文档面板"小节，离线规则补充，限制表加一行待验收；`architecture.md` 加一段来源协议与面板模型；原型 README 不动。

## 5. 验证

| 机制 | 验证 |
| --- | --- |
| 精确匹配与自动加载规则 | 纯函数测试，用原型记录的真实 `load_url` 样本：`threading` 在 21 个结果里唯一精确命中 Module → 直接加载；`threading.Thread.start` → `#//apple_ref/Method/threading.Thread.start`；`std::sync::Mutex::lock` 在 std/poison/nonpoison 三个 `lock` 都命中时取第一个；`acquire` 同时命中 threading 与 asyncio 的 `Lock.acquire` → 不自动加载；`io` 不命中 `asyncio` 的 URL；`[{}]` 被丢弃。 |
| 面板模型 | stub 源：不可用三态、无结果、单候选直接加载、多候选等待选择、精确命中直接加载、新查询取消旧查询且迟到结果被丢弃。 |
| Dash 源的 HTTP 层 | 不写网络 mock；一条集成测试在本机 Dash 可用时跑真实 `/health` + `/search`，不可用时标 SKIP 并说明原因，不伪造 PASS。 |
| 面板可见性与布局 | 复用 `PanelLayoutTests` 的方式：首次显示把 `docs` 移出 `hidden` 并写入高度；`×` 后再次显式动作重新可见。 |
| WebView、规则、主题、链接、菜单 | 打包应用端到端，不写单元测试。 |

端到端流程（打包 `Cairn.app`，Dash 8.1.1 运行且 API 开启，rlm-minimal + 一个 Rust 项目）：

1. 右键 `threading` → "在文档面板中显示"：面板首次出现在右侧最下，直接加载 threading 模块页（唯一精确命中），导航栏隐藏，样式完整。
2. 悬浮 `Thread.start`（或任一方法）→ 卡片链接 → 面板滚到该方法锚点；头部显示符号、docset、"在 Dash 中打开"。
3. Rust 文件里 `⌃⌘D` 作用于 `lock`：卡片显示时发限定名，精确命中 std 的 `lock`。
4. 右键 `acquire`（`threading.Lock().acquire()` 一类）：不自动加载，候选下拉列出 threading 与 asyncio 的两个 `acquire`，选一项后加载。
5. 点页面内 `_thread` 链接：面板内跳转，后退可用；点 `Lib/threading.py` 这类外部链接：系统浏览器打开，面板不变。
6. 深色主题：页面反色可读（Sphinx 与 rustdoc 都看）；切回浅色后恢复。
7. 关闭 Dash API（Settings → Integration）：面板显示"API 服务未开启"；退出 Dash：显示"Dash 未运行"；都不会自动启动 Dash。
8. 面板 `×` 关闭后再右键显示：重新出现。重启应用：面板位置/显示保持，内容为空状态。

自动化边界：右键菜单、悬浮卡片和真实点击需要接管屏幕；多显示器下屏幕控制不可靠，验收时让用户亲手操作、用后台窗口截图核对。做不到的流程标 BLOCKED。

## 6. 验收标准

- §1 每条行为按 §5 流程实测，逐条 PASS / FAIL / BLOCKED。
- 面板在 Safe 模式下可用；除 127.0.0.1 外不发起任何网络请求（规则构造保证，并在验收时用 `nettop` 或 `lsof -i` 抽查一次）。
- `swift test --filter "Documentation|Dash|PanelLayout"`、`bash scripts/ci.sh app`、`bash scripts/ci.sh static` 通过。
- `product.md`、`architecture.md` 描述实现后的行为；离线规则已补充例外。
