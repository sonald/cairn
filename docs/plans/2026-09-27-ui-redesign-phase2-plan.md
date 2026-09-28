# UI 重设计 · 第二阶段实施计划

日期：2026-09-27
状态：P1–P7 已实现并提交；锁屏期间被阻塞的检查已在解锁后补做（见 §5.4）。
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

## 5. 验收记录（2026-09-28）

### 5.1 提交与测试

| 片 | 提交 | 新增或更新的测试 |
|---|---|---|
| P1 排版 | `d7f1e5b` | 默认值一次性迁移；大文件保持等宽注释；更新类型名字号、衬线注释等 7 处既有断言 |
| P2 设置 | `6791117` | 主区域出现函数名 / 类型名 Stepper，按箭头以 0.5 递增；开关数量 |
| P3 Seek | `9fcd1fb` | ⌘T 打开同一个未锁定的面板；前缀图例高亮当前模式并随前缀切换 |
| P4a Lens | `228d863` | 衬线符号名、可见的堆石、主题徽章、固定时琥珀底 |
| P4b 布局 | `6ce5527` | Lens 左边界不越过侧栏、右边铺满；面板宽度恢复测试改按新层级定位 |
| P5 状态栏 | `7d5399f` | Exact 状态主题色与堆石、截断提示与分隔线随主题 |
| P6 历史 | `1dac1c3` | 真实 git 提交上切到历史 commit 再切回，阅读区与提交按钮着色往返 |
| P7 Reading Set | `10e2668` | 衬线标题、卡片与页面层次、角色标签与徽章同色 |
| 修正 | `45573c1` | Lens 标题取声明名而不是来源标签 |

- 每条新测试都逐条注入验证（改坏对应实现、确认变红后恢复）。
- 全量 CI：P1（1157）、P2+P3（1159）全部通过。P4 起屏幕锁定；最终一轮（`45573c1`）主批次 1158 条全部报告完成，除 §5.4 的 3 条外全部通过，隔离、面板、鼠标、字体批次与折叠性能门禁均通过。

### 5.2 实施中发现的问题

| 问题 | 处理 |
|---|---|
| 衬线注释默认开启后，M6 夹具（10 万行、7.9 万行注释）字体 run 从 <5000 涨到 16 万，触及 design.md §9.2 红线 | 衬线注释沿用只读架构的成本策略：`requiresViewportOnlyLayout`（>8000 行或超长行）的文档保持等宽注释；run 数回到 2001 |
| 老用户本地已存旧默认值（`save` 一次写入全部键） | `reader.defaultsRevision` 一次性迁移：仅当存储值仍等于旧默认值时升级 |
| 对 SwiftUI Stepper 做无障碍 `increment` 后，下一条设置窗口测试所在进程静默退出，主批次只报告 988 条 | 测试改为按 Stepper 自带的箭头按钮；同样验证 0.5 步进 |
| `readonlyIntegratedDeferredSyntax…` 在并行模式下锚点漂移 10.9pt | 仅在测试并行交错、另一条测试刷新全局字体环境时出现；CI 串行运行不受影响，记为既有的测试隔离问题 |
| 在 /private/tmp 下的快照工作树跑 CI，Exact 测试批量报 `invalidPath` | 环境问题；CI 只在正常工作树位置运行 |
| Lens 标题误用了 `Candidate.label`（来源标签） | 离屏渲染自查时发现，改为读取摘录声明的名字，取不到则不显示 |

### 5.3 离屏渲染自查

用临时测试把整窗（打开 knuth-rs 的 `actor.rs`）在三个主题下渲染成 PNG 查看：函数名放大加粗、类型名大 2pt、prose 注释衬线斜体、定义行自然增高；Lens 位于阅读区下方、侧栏全高；状态栏堆石与 Exact 状态色正确。路径栏在离屏图里呈黑底，判断为离屏渲染拍不到其材质，需真实应用确认。探针测试未提交。

### 5.4 锁屏期间被阻塞的检查

- `ligaturePendingRestoreYieldsToUserScroll`、`readonlyResizeUserScrollResizeUsesTheUsersNewPosition`、`wrapToggleClampsLegallyAtDocumentEdges`：依赖向窗口投递真实滚轮事件，锁屏时事件送不到窗口而失败；阅读器模块自 P3（这三条通过）以来无改动。解锁后需重跑。
- computer-use 真实应用目视：锁屏时截图不可用。解锁后需确认路径栏、Lens、状态栏与历史着色。

**解锁后补做（2026-09-28）：**

- 三条滚轮测试在解锁后重跑全部通过（`ligaturePendingRestoreYieldsToUserScroll` 1.0s、`readonlyResizeUserScrollResizeUsesTheUsersNewPosition` 0.3s、`wrapToggleClampsLegallyAtDocumentEdges` 2.7s），证实失败源于锁屏。
- 真实应用（`45573c1` 打包）computer-use 截图：路径栏为正常窗口底色，离屏图里的黑底确为渲染伪影；工具栏入口为「跳转 ⌘P」；Lens 位于阅读区与 Relations 下方、侧栏全高；状态栏显示堆石与琥珀色 Exact 状态；Python 注释为衬线斜体，`class` 名放大。
- 经用户授权切到全屏控制后补看（深色主题）：
  - 点击 `ColorfulLogger`：Lens 顶栏显示衬线符号名、`path:line`、4 块苔绿石头与「精确·直接」苔绿浅底徽章；阅读区选中符号为苔绿描边环。
  - 点「固定」：Lens 顶栏与「固定」分段变琥珀色；切回「跟随」恢复。
  - 提交选择器：工作区行苔绿勾选、分支徽章苔绿浅底；切到 `1bed65d` 后该行为褐黄浅底，提交按钮变褐黄色，阅读区底色变为偏暖的 `histReader`；切回工作区后恢复。
