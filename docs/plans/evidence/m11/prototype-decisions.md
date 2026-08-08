# M11 P0 原型视觉决策

日期：2026-08-08。范围：M11 Reading Comfort 的界面原型探索，不进产品代码。
对照原型：[`p0-prototype.html`](p0-prototype.html)（Light / Dark / SI Classic 三主题）。

> 惯例同 M9/M10：原型里留的「待裁决」项，用户裁决后钉在此处，实现按此执行，不再各自发挥。

## 裁决（2026-08-08，用户确认）

| # | 待裁决项 | 选项 | 裁决 | 落到 |
|---|---|---|---|---|
| M11-D1 | 折叠占位符 chip 形态 | A 内联文本 / B 描边 pill / C 淡填充 | **B 描边 pill**（复用 M9-S5 chip token：1×5pt 描边、r4） | §3.2(3) / F2 |
| M11-D2 | 折叠柄交互与位置 | A 常驻折叠列 / B 悬停浮现 / C 行号内联 | **B 悬停浮现 chevron** | §3.10 / F2 |
| M11-D3 | 阅读高度档控件位置 | A 仅菜单 / B 顶部 chrome 分段 / C 底部状态栏 | **B 顶部 chrome 分段**（当前档高亮可见） | §3.7 / §3.8 / F4 |
| M11-D4 | Palette 浮层位置 | A 居中 / B 顶部下拉 / C 底部 | **A 居中浮层**（Spotlight 惯例） | §3.12 / §3.13 / C1 |
| M11-D5 | imports/cfgTest 归档 | Structure / Overview / 手动 only | **归 Structure**（看结构时收起噪声，与 declaration body 同档） | §3.7 / F4 |

## 各项落地说明

### M11-D1 · 折叠占位符 chip = 描边 pill（M9 token）

- chip 是 `NSTextAttachment`（长度恒 1、字符 `U+FFFC`、无法半选），视觉上呈现为 1×5pt 描边、r4 圆角的 pill，与既有 diff/scope/commit chip 同一族视觉语汇。
- **计数区固定宽度**（承载 `· N matches` / `· diff` / `· N occurrences`）：min-width 54px，只重绘不加宽。0 / 3 / 999 三态下 attachment 宽度与整行排版宽度恒定（F2 断言）。放不下截断为 `· 999`，**永不加宽**。
- 高度 ≤ 单行行高（否则行号尺、当前行背景、声明标记几何会漂）。F2 断言。
- 七种 kind 的占位内容按 §3.0 表；`memberCounts` 按 `mod, trait, impl, struct, enum, typeAlias, const, static, fn, method` 固定序、零计数省略。

### M11-D2 · 折叠柄 = 悬停浮现 chevron

- chevron 平时不占可见位，鼠标悬停某行 gutter margin 时浮现可点箭头；展开态/折叠态用 ▾/▸ 区分。
- **与 `needsRuler` 合同的关系**（§3.10）：`needsRuler = lineNumbers || 有 diff || 有可见折叠区` 仍是硬要求--行号关 + diff 空 + 有可见折叠区时 ruler 必须保留，以承载悬停区。即：B 的"轻"体现在**无常驻 chevron 字形**，而非"无 ruler"；ruler 存在性由 needsRuler 保证，悬停 chevron 以 overlay 形式落在该 margin 上。
- **不画柄条件**：`hiddenLineCount < 2` 的区间与无折叠区行均不出现 chevron。
- **⌥ 点击**递归同级折叠/展开。
- **可发现性取舍**（用户已知并接受）：悬停浮现的可发现性弱于常驻折叠列；以顶部 chrome 高度档分段（D3）与 Folding 菜单补足"此处可折叠/当前档"的提示。
- F2 spike 仍须先打通附件创建/更新/点击/AX 四件事，再定 hover 触发的几何。

### M11-D3 · 高度档控件 = 顶部 chrome 分段

- reader 顶部 titlebar（文件名行）右侧放 Full / Structure / Overview 三段分段控件，当前档高亮（inset bottom stroke）。
- 切档是重操作（清空所有 `(fileURL, contentID)` pair 的两个覆盖集合，§3.8）；放在一键可点处，**点选即触发**，不加二次确认（与菜单项行为一致）。
- **菜单项仍存在**：View ▸ Folding 五项（Toggle Fold / Full / Structure / Overview / Focus Current Scope）是 palette `>` 模式的采集源；分段控件与菜单/快捷键 `⌥⌘0/1/2` 三者同步同一状态。
- 自动折叠跳过 `hiddenLineCount < 2`（§3.0）。

### M11-D4 · Palette = 居中浮层（Spotlight）

- 屏幕居中浮层，macOS Spotlight 惯例；五模式同一输入框，前缀切换：（无）文件 / `>` 命令 / `@` 当前文件符号 / `#` 项目符号 / `:` 行号。
- 每模式最多 20 条，超出显示 `… 还有 N 条`。
- **采集时序**（§3.12）：每次打开即缓存原 first responder 并采集菜单树（不等输入 `>`）；执行前关闭 palette、还原 responder、重新验证，再 `sendAction`。
- active Reading Set 时 `@` / `:` 禁用并提示"Reading Set has no active file"；`⌘P` / `>` / `#` 仍可用（§3.13）。

### M11-D5 · imports/cfgTest 归 Structure

- Structure 档折叠：`.declaration` body + `.imports` + `.cfgTest`（与 declaration body 同档自动折叠）。
- Overview 档 = Structure + `.container` body，只留 `outlineDepth == 0` 的声明头。
- `.block` / `.comment` / `.attributes` 保持**手动 only**，不进高度档自动折叠。
- `cfgTest` 在所有下游按 container 对待（§3.0：交叠消解保留 `.cfgTest` 丢弃 `.container`，故兼容表含 `cfgTest ↔ mod`，作用域头与 Focus 都把它计入 container 一侧）。
- **Focus 是显式例外**（§3.9）：折叠一切 kind（含 block/comment/attributes），不受"manual-only"约束。

## 已定稿呈现（无需选，原型已渲染）

以下按计划 §3.15 / §3.20 / §3.12 / §3.7 既定，原型已实际渲染，列为既定项供实现对照：

- **常驻作用域头**（§3.15）：顶部钉住至多 2 层，kind/name 来自 `outlineFacets`；最小包含 facet + kind 兼容关联；无包围声明时整条不占位、不留空条。caret 在签名行或收尾 `}` 上仍能选中 scope（`facet.range` 含完整声明范围）。
- **Reading Set 出处头**（§3.20）：每段 role + symbol + `path:line` + badge（VERIFIED/INFERRED）+ provenance chip。provenance chip 文案：`project · <revision>` / `worktree · captured` / `dependency · captured`；caveat chip `name match only`（Inferred）；dependency 段用虚线 scope chip。
- **AT CAPTURE Inspector**（§3.20）：冻结态 Resolution Inspector，标题带 `AT CAPTURE` 虚线标签；availability/environment 明确标 `at capture`，**不显示 current readiness**；audit rows 用稳定 provenance（`project commit <revision>` / `worktree captured` / `dependency captured`）+ contentID 前缀 + capturedAt，**绝不显示 runtime UUID / SnapshotID**。frozen vs live mode 差异（AT CAPTURE 标题、live-only control）分别断言。
- **三动作 disabled 规则**（§3.20）：打开完整文件 / 扩大上下文 / 查看证据。dependency 段无"打开完整文件"（需 predicate 通过 + contentID 匹配才可用，否则隐藏/disabled）；文件不可读时 expand 禁用但"查看证据"始终可用（纯读 frozen payload）。live-only "Open former candidate" 在 frozen mode 若 payload 标记可用走 captured-source action + contentID gate，否则隐藏/disabled，不留失效 closure。
- **Folding 菜单五项文案**（§3.12）：Toggle Fold / Full / Structure / Overview / Focus Current Scope。不设 Fold All（= Overview 重复）与 Unfold All（= Full 重复）。
- **Focus 键位**（§3.9 / §4 P0 定稿项）：进入/退出 `⌥⌘F`；退出也可用 Escape（优先级见 §3.14：find bar 打开 > Focus 模式 > occurrence）。跨文件导航跟随、无包围 scope 退出并提示。

## P0 自拟项（未在计划中指定，需下游 Agent 知晓并可在实现时调整）

以下两项原型里有呈现但计划未指定具体值，是 P0 自拟的合理默认。下游 Agent 可保留或按实现约束调整：

- **Toggle Fold 快捷键**：原型标 `⌘⇧[`。计划 §3.12 只说"手动 toggle"未给键位。`⌥⌘F` 已被 Focus 占用、`⌥⌘0/1/2` 是高度档，Toggle Fold 需另选一个不冲突的键。`⌘⇧[` 是 Xcode "fold" 惯例，仅为建议；若与系统/既有快捷键冲突，下游 Agent 可改用其他未占用键位（如 `⌘⇧⌘[` 不合法，可考虑 `⌃⌘[` 等），只要不与 §3.7/§3.9/§3.14 已占用的冲突。
- **折叠 chip 计数区固定宽度值**：原型用 `min-width: 54px`（容纳 `· 999` 截断显示）。计划 §3.2(3) 只要求"固定宽度、只重绘不加宽、放不下截断"，未给具体像素值。实际值由 F2 spike 在真实 `ReaderTextView` 上按字号/字体测量后确定；54px 是 13pt 等宽字体下的估算，下游 Agent 以实测为准。

## 实现阶段待核对

- **D2 悬停浮现与 `needsRuler` 的交互**（需下游 Agent 在 F2 实现时确认）：悬停 chevron 依赖 ruler margin 承载悬停区；行号关 + diff 空 + 有可见折叠区时 `needsRuler` 仍须为 true（§3.10 合同）。若实现中发现"无 chevron 字形时 ruler 仍占宽"不可接受，需回到本决策修订 D2（改回 A 常驻折叠列）。此为 D2 已知风险，已在裁决说明中标注。

## 验证

- `p0-prototype.html`：五项裁决的变体对照 + 已定稿项（作用域头 / Reading Set / AT CAPTURE Inspector / 三动作 / Folding 菜单 / 高度档归档表 / Focus 键位）+ Light/Dark/SI Classic 三主题均已覆盖（顶部按钮切换）。
- 与 `m10/prototype-decisions.md` D6 一致：Reading Set 为 M11 目标形态（B 主区新 tab），本 P0 在此基础上定稿 header/动作/Inspector 文案。
- `Sources/`：P0 零差异（仅 `docs/plans/evidence/m11/` 下新增原型与本文档）。
- **截图状态**：P0 三主题 PNG 已产出：`p0-light.png`、`p0-dark.png`、`p0-si.png`，均为
  1265×5947 的同页完整截图；浏览器实测主题切换后全部 `.win` 分别应用 `t-light`、`t-dark`、
  `t-si`。F2 仍须补真实 AppKit 产品截图，不能以 HTML 原型图替代。

## 复用既有视觉 token

- 三主题色值（t-light / t-dark / t-si）复用 M10 `reading-set-prototype.html` 的 CSS 变量集。
- M9-S5 chip token（1×5pt 描边、r4）用于折叠占位符 pill。
- 三值 badge（Verified 绿实心 / Inferred 蓝实心 / Unresolved 中性描边）复用 M10 原型 01 既有规格。
