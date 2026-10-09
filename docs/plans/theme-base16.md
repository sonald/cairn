# 开放主题（base16）：需求与实施计划

状态：待实现。2026-10-09 定稿；Fable 负责需求、原型与验收，实现交给其他 Agent。完成后把仍有效的结论归入 [product.md](../product.md) 与 [architecture.md](../architecture.md)，删除本文件和 [theme-base16/](theme-base16/) 原型目录。

原型：[theme-base16/](theme-base16/)（`swift mapping-proto.swift base16/*.yaml`）。它验证了 §3 的映射规则对 16 套方案都满足现有内置主题的对比度要求；映射函数和检查循环可以照搬进产品代码与测试，其余只作参照。

调研结论（2026-10-09）：Ghostty 与 Otty 的主题都是终端 16 色，没有语义角色，不接；base16 的 16 色自带灰阶梯度与语义约定，社区方案约 300 套且全部 MIT，作为唯一导入格式。

## 1. 目标行为

### 主题选择

- 主题由 id 标识。内置四个保持现有 id 与文案：`Auto`、`Light`、`Dark`、`SI Classic`。base16 主题 id 为 `base16:<文件名去掉 .yaml>`，显示名取文件里的 `name`，不翻译。
- `Auto` 变为一对：设置里选 Auto 后出现"浅色主题"和"深色主题"两个选择器（默认 Light / Dark），跟随系统外观切换。浅色槽只列 variant 为 light 的主题，深色槽只列 dark；存储的槽位 id 未知或 variant 不符时回到该槽默认值。固定选某个主题时不受系统外观影响。
- 主题列表分三组：内置、随应用打包的 base16、用户目录里的 base16。用户目录是 `~/Library/Application Support/<bundleIdentifier>/Themes/`（与 AppModel 的应用支持目录一致），设置页提供"打开主题文件夹"按钮（目录不存在时先创建再打开）；目录在应用启动和每次打开设置窗口时重新扫描，不做文件监视。
- 随应用打包 10 套：nord、dracula、catppuccin-latte、catppuccin-frappe、catppuccin-macchiato、catppuccin-mocha、solarized-light、solarized-dark、gruvbox-dark-medium、gruvbox-light-medium。
- 存储键 `reader.theme` 继续存 id 字符串；读取时对照目录校验，未知 id（文件已删除）回到 Auto，下次保存写回 Auto，设置选择器因此不会出现列表外的值。新增 `reader.theme.light`、`reader.theme.dark`（Auto 的一对）和 `reader.theme.quietSyntax`（见下）。

### 文件格式

- 直接接受 tinted-theming/schemes 的 base16 YAML 原文，不转换、不加 YAML 依赖。解析只支持原型里那套扁平子集：`key: "value"` 顶层键（`system`、`name`、`author`、`variant`）、`palette:` 块下缩进的 `baseXX: "#rrggbb"`，值可带引号、行尾可有 `# 注释`。
- `base00`–`base0F` 缺一个就拒绝整份文件；`variant` 缺省时按 `base00` 亮度判定（`relativeLuminance < 0.5` 为 dark）。`system` 不是 `base16` 的文件忽略。坏文件只跳过并记一条日志，不报错也不崩溃。

### 映射与"安静"开关

- 16 色按 §3 的表确定性映射到 Cairn 现有的全部语义角色；三个内置主题不经映射，保持现有手调值。
- `reader.theme.quietSyntax`（默认 true）只影响 base16 主题的语法着色：安静时函数名、属性、参数、局部绑定与正文同色，类型用蓝色；关闭后按 base16 约定完整上色。设置页在主题选择器下方放一个开关，文案"导入主题使用安静的语法着色"。
- 语义文字角色（verified / inferred / unresolved / warning / hist、行号、chrome 次要文字）按 §3 的规则向方案中对比度最强的文字色调色，直到达到内置主题承诺的对比度。这会改变浅色方案的部分色相（见 §3 证据）；取舍是状态文字可读优先于色相保真。用户可以在验收时推翻这一条，届时把阈值降到 3:1 即可。

### 外观

- 主题的 `variant` 决定 AppKit 外观：dark → `.darkAqua`，light → `.aqua`，Auto → nil 跟随系统。文档面板的反色样式、系统控件和设置窗口的 SwiftUI chrome 都只跟随外观，不跟随调色板；SI Classic 今天已是这种行为，是已知限制。

### 非目标

不接 Ghostty / Otty / iTerm2 / VS Code 格式；不做主题编辑器与逐角色覆写文件；不做文件监视；不分发第三方字体；不改 Dash 面板的反色做法。

## 2. 现状与受影响代码

- 主题枚举 `ReaderSettings.Theme`（`auto/light/dark/siClassic`，`CaseIterable`，rawValue 即存储值）在 [ReaderSettings.swift:49](../../Sources/CodeInsightReaderCore/ReaderSettings.swift)；读写在同文件约 207 与 303 行。
- 全部颜色在同文件 341 行起的 `ReaderTheme`：约 45 个 `xxxRGB(isDark:)` / `xxxAlpha(isDark:)` 函数逐个 `switch resolvedSelection(isDark:)`，共约 60 个角色（14 种 `HighlightKind`、3 种 diff、6 个高亮槽位的填充与概览标记、4 个查询条件色、约 25 个 chrome 与语义色、5 个 alpha）。
- UI 侧 [ReaderTheme+Colors.swift](../../Sources/CodeInsightReaderUI/ReaderTheme+Colors.swift) 与 [ReaderThemePalette.swift](../../Sources/CodeInsightReaderUI/ReaderThemePalette.swift) 用 `NSColor(name:)` 动态色包装这些函数，按外观深浅取值；`ReaderTheme(settings:)` 有 47 处调用，变更检测靠 `ReaderTheme` 的 `Equatable`（`CodeInsightReaderUI.swift` 1494、2751 行，`ReaderViewController.swift` 1583 行等）。没有以主题枚举做 key 的缓存。
- 外观切换重复四处：[CairnAppearance.swift](../../Sources/CodeInsightApp/CairnAppearance.swift)（已有 `cairnAppearance(for:)`）、`PalettePanel.swift:180`、`MainWindowController.swift:2618`、`CodeInsightApp.swift:1687`。文档面板已经用 `cairnAppearance(for:)`，深色判断取自 `effectiveAppearance`，只改调用参数。
- 枚举 case 的其他使用：设置选择器 `ReaderSettingsWindowController.swift:363`（`allCases`）；`SessionSelfTest.swift:1396`、`PerfSelfTest.swift` 411/556/598/716/1402、`LanguageSelfTest.swift` 469/769、`SelfTestLaunch.swift:560`；测试 `ReaderSettingsTests.swift` 114/128、`ReaderTextViewTests.swift` 247/327/493、`ReadingSetLigatureTests.swift:102`、`RelationNavigationTests.swift` 141/1480、`MainWindowControllerTests.swift:1251`。
- 主题之外只有 7 处系统语义色（`MainWindowController.swift:330`、`ReadingSetView.swift:726`、`SearchPanel.swift` 1007–1197）和设置窗/欢迎页约 23 处 SwiftUI `Color`，维持现状。
- `CodeInsightReaderCore` target 目前没有 `resources:` 声明（Package.swift 214 行）。`make-app.sh` 118 行只把 `CodeInsightApp`、`CodeInsightAppModel`、`CodeInsightReaderUI` 三个资源 bundle 拷进 `Cairn.app`，新加资源的 target 必须加进这个列表，否则打包应用里 `Bundle.module` 会崩。
- 文案：`settings.theme.*` 在两份 `Localizable.strings` 449–453 行；产品描述 `product.md:154`、`README.md:16`、`README.zh-CN.md:16` 都写着 "Light/Dark/SI Classic"。

## 3. 设计约束

### 数据形状（`CodeInsightReaderCore`，无 AppKit）

- `ReaderSettings.Theme` 改为 `struct Theme: Hashable, Sendable { let id: String }`，静态值 `.auto/.light/.dark/.siClassic` 使用现有 rawValue 字符串，`static let builtIns`；`Theme(rawValue:)`/`rawValue` 保留为 id 的别名，让存储与自测代码少改。`ReaderSettings` 新增 `autoLightTheme: Theme`、`autoDarkTheme: Theme`、`quietSyntax: Bool`。
- `ThemePalette: Equatable, Sendable`：每个现有角色一个字段（`UInt32` 或 `Double` alpha），外加 `variant`。三个内置主题各一个静态字面量，数值从现有 `switch` 原样搬出。
- `Base16Scheme`：`name`、`variant`、`base: [UInt32]`（16 个）、`load(contentsOf:)` 扁平解析；`ThemePalette(scheme:quiet:)` 实现下表。
- `ThemeCatalog`：进程内注册表（内置预装，锁保护，`register(_:)` / `palette(for id:)` / `entries`），`ReaderTheme.init(settings:)` 通过它把 id 解析成 `lightPalette`/`darkPalette`（固定主题两者相同）。`ReaderTheme` 的全部 `xxxRGB(isDark:)` 签名不变，内部改为 `palette(isDark:).xxx`，UI target 与 47 处调用不动；`Equatable` 因而包含调色板。
- 资源：`Sources/CodeInsightReaderCore/Themes/` 放 10 个 yaml 与 tinted-theming 的 LICENSE，Package.swift 加 `resources: [.copy("Themes")]`，`make-app.sh` 的 bundle 列表加 `CodeInsightReaderCore`；打包后在 `Cairn.app` 里确认十套主题出现在设置列表。

### 16 色 → 角色映射

`bg = base00`，`fg = base05`，`chrome = base01`，`strong` = base05/06/07 中对 bg 对比度最大者，`soft` = dark 0.16 / light 0.14，`blend(c, over: b, a)` 为 sRGB 线性插值。`tone(c, on: b, min:)`：c 对 b 的对比度不足 min 时，把 c 向 `strong` 二分混合到刚好达标。

| 角色 | 来源 |
| --- | --- |
| background / foreground | base00 / base05 |
| lineNumber | tone(blend(fg, bg, 0.55), on bg, 3.0) |
| currentLine | blend(fg, bg, dark 0.06 / light 0.05) |
| chrome / chromeHeader / chipBackground | base01 / base02 / base02 |
| chromeDivider | blend(fg, chrome, 0.18) |
| chromeSelection | blend(base0D, chrome, soft + 0.06) |
| chromeSecondary / chipForeground | tone(fg, on chrome, 4.5，向纯黑或纯白) / fg |
| chromeTertiary | tone(blend(fg, chrome, 0.7), on chrome, 3.0) |
| accent | base0D |
| verified + mossSoft | c = tone(base0B, on chrome, 4.5)；soft = blend(c, bg, soft)；c = tone(c, on soft, 4.5) |
| inferred + slateSoft | 同上，base0D |
| unresolved(+Border) + rustSoft | 同上，base08 |
| warning + amberSoft | 同上，base0A；warningBorder / amberMark = base09 |
| hist + histSoft / histReader | 同上，base09（base0F 在 Nord 是蓝、Rosé Pine 是灰，不稳定）；histReader = blend(base09, bg, 0.05) |
| occurrence / overviewOccurrence | blend(base0A, bg, soft + 0.06) / base0A |
| 高亮槽位 1–6 填充 / 概览标记 | 来源依次 base0C、0E、0B、08、0D、09，某来源与前面重复时改用 base0F；填充 = blend(来源, bg, dark 0.40 / light 0.30)，标记 = 来源 |
| 查询条件 0–3 | base0D、0E、0C、09 |
| diff added / removed / changed | base0B / base08 / base0A |
| 5 个 alpha | 按 variant 取现有 Dark 或 Light 主题的值 |
| comment | base03 对 bg ≥ 3.0 则用之，否则 blend(fg, bg, 0.6)；再 tone 到 3.0 |
| keyword / string / number / macro、attribute | base0E / 0B / 09 / 0E，各 tone 到 3.0 |
| 安静：functionName / typeName、declarationTitle、enumMember / 其余 | base06 / base0D / fg |
| 完整：functionName、functionCall / property、parameter / typeName 三者 / localBinding、declarationEmphasis | base0D / base08 / base0A / fg |

证据（原型 `output.txt`，16 套 × 安静/完整全部满足现有 13 组对比度）：深色方案几乎不调色（Mocha、Macchiato 零调整，Dracula 2 个角色微调）；浅色方案调得多——Catppuccin Latte 15 处（warning `#DF8E1D` → `#715E56`），Solarized Light 15 处，Gruvbox Light 5 处，Solarized Dark 11 处（它的正文色对自家 chrome 只有 4.4:1，所以向 base07 调）。高亮槽位最近一对的 RGB 距离在 12–34 之间，与内置 Light 的 teal/blue 槽位（约 15）相当；Nord 的 0C/0D、Catppuccin 的 08/09 天然相近，是方案本身的限制。

### 其他

- `cairnAppearance(for:)` 改为接收解析后的 `variant`（Auto 为 nil），三处重复 switch 改为调用它。
- 设置窗口：主题 Picker 按三组列出目录条目；Auto 时显示两个子 Picker；下方是安静开关与"打开主题文件夹"按钮。打开设置窗口时重新扫描用户目录并注册到目录。
- 应用启动（`CodeInsightApp` 读设置之前）加载打包与用户主题到 `ThemeCatalog`。
- 本地化：新文案中英文都要有，`bash scripts/ci.sh static` 会检查。
- 不加依赖；不改 `ReaderTheme` 的公开读取接口；不改 `NSColor(name:)` 动态色机制。
- 分支：在本 worktree 分支 `worktree-theme-base16` 上提交，英文简短提交信息；验收前 rebase 到最新 `main`。

## 4. 实施顺序

每步结束都要能 `swift build` 并通过该步测试。

1. **纯搬运**：先在改动前用一个临时测试把现有三主题的全部角色 × `isDark` 两值写成 golden JSON，提交到 `Tests/CodeInsightReaderCoreTests/Fixtures/theme-golden.json`（测试用 `#filePath` 相对定位，与 `TypeHopTests` 同样做法，不需要 test target 资源声明）；再引入 `ThemePalette` 与 `ThemeCatalog`，`ReaderTheme` 改为查表，`Theme` 改为 id 结构体，修 §2 列出的全部 case 使用点。验收标准：解码后逐角色数值一致（不比文件字节，键序无关），`swift test --filter "ReaderSettings|ReaderTextView|Ligature|RelationNavigation|MainWindowController|PanelTheme|Welcome"` 通过。
2. **base16 解析与映射**：`Base16Scheme.load`、`ThemePalette(scheme:quiet:)`、资源目录与 Package.swift；把原型的检查循环变成测试（见 §5）。
3. **设置与持久化**：`autoLightTheme`/`autoDarkTheme`/`quietSyntax` 键与默认值；`ReaderTheme` 对 Auto 取对；设置窗口的 Picker 分组、子 Picker、开关、打开文件夹；启动与开设置时扫描用户目录；中英文文案。
4. **外观合一**：`cairnAppearance(for:)` 改签名，删三处重复；确认两个深色主题互切时所有 `apply(settings:)` 入口重绘。
5. **文档**：`product.md:154` 一段改写为现行行为（内置三套、base16 打包十套、用户目录、Auto 配对、安静开关、外观限制）；`README.md:16`、`README.zh-CN.md:16` 同步；`architecture.md` 的主题一句补 `ThemeCatalog` 与映射位置；LICENSE 与来源说明只留在 `Themes/` 目录。

## 5. 验证

| 机制 | 验证 |
| --- | --- |
| 内置主题不变 | 步骤 1 的 golden JSON 断言（临时，步骤 1 通过后可删，`PanelThemeTests` / `WelcomeThemeTests` 快照继续保护常用角色） |
| base16 解析 | 原文样本（含行尾注释的 catppuccin、无注释的 nord）、缺 `variant` 的亮度推断、缺一个 base 的拒绝、`system` 不是 base16 的忽略、乱码文件不崩溃 |
| 映射对比度 | 扩展 `readerThemePaletteMeetsRequiredContrastRatios`：遍历目录里内置 + 打包十套 × 安静/完整，沿用现有 13 组阈值；八个语法角色（comment、keyword、string、number、functionName、typeName、property、macro）对 bg ≥ 3.0；高亮槽位对 bg ≥ 1.15 |
| 持久化 | `ReaderSettingsTests`：未知 id 回退 Auto；Auto 对的读写，槽位 id 未知或 variant 不符时回默认；`quietSyntax` 默认值 |
| 目录扫描 | 临时目录放一好一坏两个文件：好的进目录、坏的跳过 |
| 设置 UI、外观、重绘、Dash 面板 | 打包应用端到端，不写单元测试 |

端到端流程（打包 `Cairn.app`，rlm-minimal + 一个 Rust 项目）：

1. 设置 → 主题选 Nord：阅读区、侧栏、状态栏、搜索面板、上下文、书签、阅读集、Dash 面板（深色反色）全部换色；再选 Dracula：同一外观下全部重绘，没有残留 Nord 色。
2. 选 Catppuccin Latte：窗口变为浅色外观；语法安静（函数名与正文同色、类型蓝）；关掉安静开关后函数名、属性按 base16 上色；重新打开恢复。
3. Auto + 浅色 Latte / 深色 Mocha：切换系统外观，两边跟随。
4. 把 `tokyo-night-dark.yaml` 放进用户目录，重新打开设置：出现在"用户"组并可选；放一个只有 8 个 base 的坏文件：不出现、不崩溃。
5. 退出重开：主题、Auto 对、安静开关保持；删除用户目录里当前选中的文件后重开：回到 Auto。
6. SI Classic、Light、Dark 三套与基线截图逐一比对无差异；基线在步骤 1 开始前用 `main` 的打包应用对同一文件、同一窗口尺寸截取。

自动化边界：按本仓库记录，后台点击不能成为阅读区光标、设置窗口交互需要接管屏幕；做不到的流程标 BLOCKED，不用模型测试补成 PASS。

## 6. 验收标准

- §1 每条行为按 §5 流程实测，逐条 PASS / FAIL / BLOCKED。
- 步骤 1 的 golden 逐角色一致；`swift test --filter "ReaderSettings|ReaderTextView|Ligature|RelationNavigation|MainWindowController|PanelTheme|Welcome|Theme"`、`bash scripts/ci.sh app`、`bash scripts/ci.sh static` 通过。
- `product.md`、`architecture.md`、两份 README 描述实现后的行为；本文件与原型目录删除。
