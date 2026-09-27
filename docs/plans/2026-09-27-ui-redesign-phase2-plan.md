# UI 重设计 · 第二阶段实施计划

日期：2026-09-27
状态：执行中（用户授权自主执行到底，见设计方案 §8 的 D1–D5 裁决）。
设计依据：[UI/UX 重设计方案](2026-09-27-ui-ux-redesign-design.md)；第一阶段见[第一阶段计划](2026-09-27-ui-redesign-phase1-plan.md)。
代码基线：本分支已 rebase 到 `main`（`e38e4fd`，含只读架构 S0–S8）。

## 1. 已裁决的输入

| 编号 | 裁决 |
|---|---|
| D1 | ⌘T 与 ⌘P 合并为一个 Seek 入口 |
| D2 | 散文注释用衬线斜体，默认开启 |
| D3 | 默认行高 1.3 |
| D4 | 函数名默认 +4.5pt |
| D5 | Lens 位于底部，横跨阅读区与 Relations（不含侧栏） |

## 2. 现状核查（rebase 后）

- **排版管线**：只读架构把字号变化视为「度量 span」，由 `metricSpans` 判定、走统一重排成本策略；字号仍集中在 `ReaderTextView.applyTypography`（`CodeInsightReaderUI.swift`）。`.functionName` 与 `.declarationTitle` 共用一个字号；`.comment` 在 `humanistComments` 时用系统无衬线字体。
- **设置持久化**：`ReaderSettings.save(to:)` 一次写入所有键，老用户本地已存 `functionNameDelta = 0`、`humanistComments = false`，只改默认值对他们无效，需要一次性迁移。
- **Seek**：`showSymbolSearch()` 已经是 `showPalette(prefill: "#", lockMode: true)`，命令面板本身支持 `>` `@` `#` `:` 四种前缀；合并的主要工作是去掉模式锁定、统一入口文案与快捷键展示。
- **布局**：`contentSplitController`（上下）= 上部（侧栏 | 阅读区 | Relations）+ Context；Context 目前横跨整窗，包括侧栏下方。D5 要求它只横跨阅读区与 Relations。
- **状态栏**：`indexLabel`、`truncatedLabel` 等仍用系统色（`.secondaryLabelColor`、`.systemOrange`）。

## 3. 切片

| 片 | 内容 | 主要文件 |
|---|---|---|
| P1 | 阅读器排版：函数名 +4.5pt（范围 0–8）、新增类型名增量（默认 +2，范围 0–6）、衬线斜体注释默认开启、一次性默认值迁移；更正 `docs/design.md` 行高为 1.3 | `ReaderSettings.swift`、`CodeInsightReaderUI.swift`（`applyTypography`、`metricSpans`） |
| P2 | 设置窗口：拆分函数名 / 类型名字号滑杆，放宽范围，衬线注释开关文案 | `ReaderSettingsWindowController.swift` |
| P3 | Seek：⌘T / ⌘P 进入同一面板且可切换前缀；面板顶部加前缀模式条；工具栏入口改为 Seek | `PalettePanel.swift`、`MainWindowController.swift` |
| P4 | Lens：版式（Follow / Pin、衬线符号名、候选条带堆石）；D5 布局调整 | `MainWindowController.swift`（`ContextWindowViewController`、分栏） |
| P5 | 状态栏：配色接主题、查询完整度用堆石、信任印章 | `MainWindowController.swift` |
| P6 | 历史快照：阅读历史 commit 时阅读区用 `histReader` 底色，提交入口用褐黄 | `MainWindowController.swift`、`CodeInsightReaderUI.swift` |
| P7 | Reading Set：卡片配色与标题排版 | `ReadingSetView.swift` |

## 4. 约定

沿用第一阶段 §3：颜色只从 `ReaderTheme` 取；衬线用系统 New York；不编造数据；UI 断言证明可见且逐条注入；每片全量 CI；commit 英文简短。新增：

- 每片完成后用 computer-use 在真实应用中截图自查（后台模式看不到自动隐藏的浮动面板时，改用离屏渲染）。
- 排版改动须通过 CI 的折叠性能门禁；若只读架构的工作量基线脚本对度量 span 有预算，一并复测。

## 5. 验收记录

（逐片补充）
