# UI 重设计 · 第一阶段实施计划

日期：2026-09-27
状态：计划已定，待派发。
设计依据：[UI/UX 重设计方案](2026-09-27-ui-ux-redesign-design.md)。
代码基线：`f5e116d`。分支 `claude/ui-ux-redesign-f4d87e`。

## 1. 为什么分两阶段

只读架构优化（`codex/readonly-architecture`，S0–S6 已提交，S7 在主工作区未提交）与本次重设计同基线，并大改以下文件：

| 文件 | 只读架构改动 |
|---|---|
| `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift` | +1649 / −1060，排版改走度量 span 与重排成本策略 |
| `Sources/CodeInsightApp/MainWindowController.swift` | +117，另有未提交改动 |
| `Sources/CodeInsightApp/ReaderSettingsWindowController.swift` | +69，另有未提交改动 |
| `Sources/CodeInsightApp/ReadingSetView.swift` | +61 |
| `Sources/CodeInsightApp/CodeInsightApp.swift` | +23，另有未提交改动 |

**第一阶段只做与这些文件不重叠、或只在其未改动区域做极小改动的部分。** 阅读器字号层级、主窗口外框（时间轴、Seek、Lens、分层状态栏）、设置页、Reading Set、语言选择框留到第二阶段：届时先同步已合入只读架构的 main，再在新排版管线上实现，并与其性能门禁一起验收。

## 2. 范围

### 2.1 纳入

| 片 | 内容 | 可改文件 |
|---|---|---|
| S1 | 三主题调色板 | `ReaderSettings.swift`；新文件 `ReaderUI/ReaderThemePalette.swift`；`CodeInsightReaderUI.swift` **仅限第 51–71 行** Auto 分支 |
| S2 | 堆石与徽章组件 | 新文件（App 目标） |
| S3 | Relations 面板 + Resolution Inspector | `RelationWindowController.swift` |
| S4 | Reading Trail | `ReadingTrailView.swift` |
| S5 | 命令面板、项目查找、书签、提交选择器 | `PalettePanel.swift`、`SearchPanel.swift`、`BookmarkPanel.swift`、`CommitPickerPopover.swift`；`MainWindowController.swift` **仅限**在 `applyReaderSettings(_:)` 增加主题传播行、在面板构造处补参数 |
| S6 | 空状态 / 欢迎页 | `EmptyStateView.swift` |

所有片都可新增测试文件，并更新 `scripts/ci.sh` 的批次计数。

### 2.2 不纳入（第二阶段）

阅读器字号与声明层级（`functionNameDelta` 等）、标题栏重构、Seek 合并（D1 待定）、Lens、分层状态栏、历史快照阅读区着色、设置窗口、Reading Set、语言选择框、把书签 / 查找从独立窗口改为停靠面板。

## 3. 全局约定

1. **衬线字体用系统 New York**（`NSFontDescriptor.SystemDesign.serif`），不打包 Newsreader。设计稿里的 Newsreader 只是网页替身。
2. **颜色只从 `ReaderTheme` 取**，不在视图里写死十六进制。
3. **不新增数据**：设计稿里模型没有提供的信息（如提交是否已物化、历史会话列表），模型里没有就不显示，不编造。每片交付时列出「设计稿有、因无数据未做」的项。
4. **UI 断言必须证明可见**：`window != nil`、非隐藏、窗口坐标 frame 非零且在可见区内、未被遮挡；不接受只检查对象存在或文案的断言。新断言在改动前必须失败。
5. **排版观感交人工目视**：每片交付附三主题（Light / Dark / SI Classic）原生截图；无法截图时明确列为待人工目视项。
6. **完整测试摘要**：聚焦测试 + 全量 `CODEX_SANDBOX=1 bash scripts/ci.sh`，报告须含测试结束摘要，退出码不够。
7. Commit 用英文、简短。

## 4. 切片明细

### S1 三主题调色板

目标：Light → Granite、Dark → Basalt、SI Classic 采用设计方案 §3.1 的色值；Auto 跟随系统在 Granite / Basalt 之间切换。

- 更新 `ReaderTheme` 现有 RGB 表：阅读区背景、前景、行号、当前行、occurrence、chrome 系列、accent、verified / inferred / unresolved、warning、chip，以及语法色（`HighlightKind` 全部 case）。
  映射：verified → moss，inferred → slate，unresolved → rust，warning → amber，accent → moss（SI Classic 为 navy）。
- 新增 token：`amberMark`、`amberSoft`、`hist`、`histSoft`、`histReader`、`mossSoft`、`slateSoft`、`rustSoft`，NSColor 访问器放新文件 `ReaderThemePalette.swift`。
- **Auto 不再用系统 chrome 颜色**：`CodeInsightReaderUI.swift` 第 51–71 行的 `selection == .auto ? 系统色 : …` 改为统一走主题表。
- 测试：更新 `ReaderSettingsTests` 中固定色值的断言；新增对比度测试：每个主题下正文、次级文字、徽章文字对其底色 ≥ 4.5:1。

### S2 堆石与徽章组件

- `CertaintyStonesView`：输入 `Certainty`，画 0–4 块石头（设计方案 §3.4）。Unresolved 为虚线描边。尺寸 13 / 14 / 16 / 22pt。提供辅助功能标签（Exact / Strong / Probable / Possible / Unresolved）。
- 徽章：Verified、Inferred、Unresolved、Corrected、dispatch、dependency、captured、commit、limited 九种样式，一个类型统一绘制。
- 测试：五档石头的填充数量与辅助功能标签；徽章在三主题下取对应 token。

### S3 Relations 面板 + Resolution Inspector

参照画布「Reader」右栏与「Relations preset · Resolution Inspector」画板。

- 头部：眉标「Relations」、种类小色块、衬线根符号名、`path:line`。
- 四方向切换带计数。
- 行：两行式（名称 / `path:line`），左侧堆石，右侧 dispatch 徽章 + Verified / Inferred 徽章；测试调用者分组分隔线（已有 tests 分组时）；「Show N possible matches」折叠行带 Possible 石头。
- 底部：Freeze as Reading Set、Inspector（⌘I）、查询完整度一行。
- Inspector：衬线叙述句作标题；Source / Verification / Verification availability / Analysis environment 两列；Corrected candidates 用锈红浅底块；Full audit 为键值表。
- 保持 M8 裁决：不按 certainty 分组，行高稳定。
- 注意：`RelationNavigationTests` 也被只读架构修改，本片如需改它，只增不改原有断言。

### S4 Reading Trail

参照「Reading Trail」画板。

- 路径：苔绿实线串起主路径，分支用细曲线；每站用石头节点，当前站为琥珀点 + 「● CURRENT」；跨快照段用褐黄虚线与「snapshot boundary」标注。
- 每站：符号名（等宽粗体）、导航方式徽章、确定性徽章、`path:line · snapshot`。
- 详情栏：Snapshot、Navigated via、Explanation 卡（导航时证据 / 当前证据），证据变化时琥珀提示；Restore this node 为主按钮；Freeze Path as Reading Set。
- Project history：模型有数据才显示。

### S5 命令面板、项目查找、书签、提交选择器

- **主题传播**：四个面板新增 `apply(settings:)`；`MainWindowController.applyReaderSettings(_:)` 增加对应调用，构造处传入当前设置。除此之外不改 `MainWindowController`。
- 命令面板：前缀模式条（`>` `@` `#` `:`）、种类小色块、匹配字符高亮、底部快捷键提示；行号超出末尾提示用琥珀浅底。不做预览栏、不合并 ⌘T / ⌘P。
- 项目查找：查询框 + 大小写 / 正则切换、统计行、按文件分组（文件名粗体 + 目录 + 计数）、行号 + 片段、命中高亮、截断提示。
- 书签：过滤框、每条标题 / `path:line` / 快照徽章 / 状态徽章（Exact content 苔绿、Drifted 琥珀、File absent 锈红、Not evaluated 中性）、笔记区用衬线正文、Re-anchor 等既有操作保留。
- 提交选择器：Working Tree 行苔绿圆点、选中提交用褐黄浅底、哈希等宽、HEAD / tag 徽章、日期右对齐。

### S6 空状态 / 欢迎页

- 左侧：Cairn 标记、衬线大标语「Read code / without touching it.」（中文本地化同步）、说明句、Open Project…（⌘O）、拖放提示。
- 右侧：最近项目列表，含语言缩写块与路径；失败态与 Try Again 保留。
- 本地化：新增或修改的文案同步 `en` 与 `zh-Hans`，通过现有本地化检查。

## 5. 派发顺序

S1 → S2 → S3 → S4 → S5 → S6，串行派发到本工作树，每片验收通过并提交后再派下一片。S3–S6 依赖 S1 的 token 与 S2 的组件。

## 6. 验收

每片：

1. 聚焦测试与全量 CI 均有完整结束摘要。
2. 核对本片改动文件未超出 §2.1 列表（`git diff --stat`）。
3. 三主题原生截图，或明确列为人工目视项。
4. 列出「设计稿有、因无数据未做」的项。

阶段结束：与 `codex/readonly-architecture` 做一次试合并（不提交），确认无冲突或冲突可控，结果记入本文件。

## 7. 风险

| 风险 | 对策 |
|---|---|
| S1 改色影响只读架构的原生截图证据 | 只是视觉差异，不影响其正确性；第二阶段同步时重拍 |
| Auto 不再用系统色，用户可能更习惯系统外观 | 设计方案已定；交付后人工确认 |
| New York 与设计稿 Newsreader 观感不同 | 三主题截图交人工确认 |
| 只读架构 S7 在第一阶段期间继续改动上述文件 | 阶段结束做试合并；§2.1 的限定行若被其改动，改用新文件方案 |
