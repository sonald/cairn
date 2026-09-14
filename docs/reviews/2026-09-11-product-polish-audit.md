# Cairn 产品精致度审计与整改方案

日期：2026-09-11。本文件保留当日审计及获批方案，源码位置与现场观察均属于当日基线。当前整改及验收结果见 [验收报告](2026-09-11-product-polish-acceptance.md)。辅助功能专项范围按用户 2026-09-14 的调整处理。

## 结论

Cairn 的主要缺口是：各项功能已经能工作，但没有把它们收敛成一套稳定、协调、适合长时间读代码的界面。固定尺寸、系统默认控件边距、手写文字排版、面板最小宽度等规则相互叠加；再加上有限的代码分类和 Outline 信息，形成了现在的 MVP 感。

这次应该作为一次完整的产品质量整改，而不是逐张截图调几个 margin。先修几何和交互，再统一界面密度与层级，随后补充代码信息。保留 AppKit、TextKit、Tree-sitter 与现有阅读模型，无需更换框架或建立新的设计系统平台。

## 证据与边界

- 用户提供的六张截图是直接证据，已原样保存为 `ref-01` 至 `ref-06`。
- 本次通过 CUA 操作正在运行的 Cairn，检查主阅读窗口、Cmd+P 多条/单条/无结果、Files/Outline、关系栏两向拖动、actor.rs、文件内查找、Reader 设置，保存截图及部分 AX 状态。
- 源码基线：`695a2d9f21f2a46871b5b44c27907605b82cd907`。开始时只有无关的 `.claude-trace/` 未跟踪目录；本次不修改产品源代码。
- 运行中的 bundle 未证明与这个 SHA 完全一致。因此，下文分别标明“现场观察”“当前源码”和“待验证推断”，不把它们拼成同一版本的完整验收。
- 未重新构建、运行 CI 或全量测试。暗色、另一块屏幕、窗口重启恢复、VoiceOver 完整流程、Compare/Reading Set/Bookmarks/错误恢复不在本次实机覆盖范围内，列入后续验收。
- 已关闭检查时打开的设置和查找，恢复 harness.rs；右栏宽度恢复原 AX 位置 952，然后恢复原先隐藏状态。

## 逐步检查

| 步骤 | 用户动作 / 页面 | 健康度 | 观察与证据 |
|---|---|---|---|
| 1 | 在项目中阅读文件 | 需整改 | 内容可读，但空的底部 Context 长期占据空间，工具条、Trail、Tabs、阅读高度入口争夺层级。见 01。 |
| 2 | Cmd+P，展示多个候选 | 不合格 | 窄、提示被截断、左右视觉留白不统一；用户图 1 的定位问题由源码中的屏幕 center 调用支持。见 02、ref-01。 |
| 3 | 输入 harn，只剩一个候选 | 不合格 | 唯一行紧贴圆角下缘，文字受裁切/压迫，仍显示滚动条。见 03、ref-02。 |
| 4 | 继续输入，变成无结果 | 不合格 | No files found 也落在同样狭窄的区域，仍有滚动条。见 04。 |
| 5 | 浏览 Files / Outline | 需整改 | Files 有目录展开和选中；文件类型区别弱。Outline 是不可展开的声明列表，缺少 Cursor 截图中的字段、变体及类型摘要。见 01、09、ref-03。 |
| 6 | 打开 Relations，向左右拖动 | 部分通过 | 当前现场能拖：AX 位置 952 → 892 → 1022，截图布局同步变化。不能复现“完全不能拖”；宽度硬上限与内部布局阈值冲突，AX 仍报告 disabled。见 06、07、08、ref-06。 |
| 7 | 打开 actor.rs 阅读 | 需整改 | 行号到代码间留白大，调用点/字段/attribute 的区分弱；注释使用比例字体。见 09、ref-04、ref-05。 |
| 8 | Cmd+F，查找 ActorContext | 基本通过，仍需打磨 | 输入获得焦点，显示 1 / 9，正文有匹配反馈，Esc 后查找栏关闭。查找输入偏短，整条横栏的空间分配与其余控件不同。见 10、11。 |
| 9 | 打开 Reader 设置 | 需整改 | 高级排版参数先于行号/折行，首屏看不到后者；label 较长、嵌套留白重，无就地预览。当前 AX 把四个参数标题合并成一条文本，未暴露四个独立 slider，需专项检查。见 12。 |

### 1. 阅读窗口

![当前阅读窗口](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/01-live-reader.png)

### 2—4. Palette 的三个实际状态

![多条候选](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/02-palette-many.png)

![唯一候选](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/03-palette-single.png)

![无结果](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/04-palette-empty.png)

### 5—7. 侧栏、代码区与 Relations

![Relations 打开时](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/06-relations-before.png)

![向左拖后](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/07-relations-after-drag.png)

![向右拖后](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/08-relations-second-drag.png)

![actor.rs 阅读与侧栏](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/09-actor-reader.png)

### 8. 文件内查找

![查找入口](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/10-find.png)

![查找结果](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/11-find-result.png)

### 9. 设置

![Reader 设置](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/12-settings.png)

## 六张用户截图背后的具体问题

### A. Cmd+P：定位、尺寸与状态布局都有问题

**当前源码确定：** [调用方](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/MainWindowController.swift:1451) 已传入所属窗口，但 [Palette.show](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/PalettePanel.swift:115) 直接调用 `panel.center()`；[每次安装结果](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/PalettePanel.swift:535) 又重新 center。宽度在构造和结果更新时均固定为 380pt。输入控件实际可用宽度约 306pt，容不下完整模式提示。

**现场确认：** 多条、单条、无结果三种状态的布局都不理想。单条不是单纯“留白不好看”，而是整行的容纳和裁切没有处理好。

**待验证的根因细节：** 代码把 `rows.count × 26 + 4` 直接作为整个滚动区域的高度，却没有明确 table style/contentInsets；单元格另有 padding，空 shortcut 也保留了间距，滚动条再占一层空间。需要读实际 rowRect、clip bounds、effective style、insets 后确认每份留白的来源，不能武断地归因于某一个系统默认值。

整改规则：

- 相对所属窗口的可见内容区水平居中，顶部固定在内容区上方约 15% 处；结果减少只让底边上收，输入行不跳动。窗口移动、resize、切换屏幕后重新定位并保持在可见范围内。
- 宽度以约 600pt 为常态，按窗口可用宽度扩展，建议首版 `min(可用宽度−48, clamp(可用宽度×0.5, 560, 760))`。这些是方案起点，不是已验收数值。
- 输入提示缩短为当前模式对应的“打开文件…”等内容；模式切换说明放在轻量辅助行。输入文本与候选文本左对齐；容器水平居中，输入与图标的视觉中心/基线一致。不要为了居中把长输入文字居中排版。
- 搜索头约 44pt，候选行约 30pt，外层只保留一份 8pt 左右留白，文字内边距约 12pt。文件名主文本、路径次文本、快捷键按需出现；长路径截断并可获知完整路径。
- 0 / 1 / 多条的高度由完整行和明确的内边距决定，单条至少完整显示一行；无结果使用独立的空态内容。只有实际溢出才有可滚动内容；系统常显滚动条模式也不能挤压正文或破坏边距。
- 选择高亮距离左右边缘相同，保留上下呼吸空间。查询过滤不改变候选行的基本排版。

仓库已有可复用的所属窗口定位写法，例如 [SearchPanel.show](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/SearchPanel.swift:62)。先直接统一行为，不需要额外建一个通用弹窗框架。

### B. Sidebar：信息结构不足，换图标只能解决一部分

Cursor 的参考图值得借鉴的是：稳定的缩进与图标列、真实可展开层级、字段与类型之间的主次关系、克制的选中背景。颜色只是其中一部分。参考图为深色、Cairn 为浅色且缩放不同，不能拿截图像素直接判断字号优劣。

当前 [文件图标](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/MainWindowController.swift:3999) 只有 doc/folder；[标题区](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/MainWindowController.swift:3826) 是 30pt 高、全大写、accent 色加背景分割线。界面强调了容器，却没有给文件和符号足够辨识度。

[Outline 数据源](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/MainWindowController.swift:3667) 将 facets 都挂在根节点并设为不可展开，depth 只用于视觉缩进。现有 [OutlinePanelModel](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightAppModel/OutlinePanelModel.swift:9) 已计算 parentIndices，可直接复用。当前 [OutlineFacet](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift:91) 则尚缺字段、枚举成员及类型摘要，不能把这些承诺成一个纯 UI 改动。

整改规则：

- Files 和 Outline 共用明确的字号、行高、缩进、图标槽与选中样式。首版 UI 字号 12–13pt、行高 22pt、缩进 12–14pt、图标 14–16pt；用实际渲染校准。
- 标题缩到约 24pt，弱化蓝色和背景，让内容成为主体。提供清晰的折叠入口和键盘操作。
- 复用已有文件分类，给源文件、配置、文档等少量常见类别稳定图标；不先做可安装图标主题系统。
- 用现有 parentIndices 建真正树形 Outline，保留展开状态，选中符号与阅读位置一致，提供合理的滚动显露行为。
- 另一个明确任务补字段、枚举变体、参数/返回类型摘要；直接扩展现有解析结果中必要的数据，保持类型文字为次要信息。不能仅靠颜色区分符号种类。
- 用户调整 Files/Outline 分配后应保留。当前 [首次 layout 的 65/35 初始化](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/MainWindowController.swift:3550) 有覆盖 autosave 的风险，需用真实控制器重建确认。

### C. Reader：先消除重复留白，再统一排版

图 4 和本次 actor.rs 都显示了过大的行号到正文间距。

高可信度原因是 [updateRulerThickness](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift:2405)：创建了独立 ruler 后，又令 `textContainerInset.width = 12 + ruler.ruleThickness`。普通 Rust 文件可产生约 53pt 的 ruler，再加约 65pt 的文本 inset，和现象吻合。

但最终修复需要确认 `NSScrollView.contentInsets` 决定的 ruler/content 布局模式，不能盲删一项。验收应直接测“gutter 右边缘到无缩进行首 glyph 的距离”，而不是再从当前 inset 反推一个正确值。

整改规则：

- gutter 只占一份宽度，包含实际启用的行号、标记、折叠、书签/diff 槽；其右侧到正文首字约 8–12pt。
- 行号右对齐，宽度依实际字体和最大位数测量。字号随正文合理变化，避免正文放大后行号仍固定为 10pt。
- 默认正文等宽 13pt、行高约 1.3 可作为起点。字体变化应重算布局、点击位置和 gutter，不做整块画面的等比放大。
- 保留 Source Insight 式声明强调能力，但默认更克制。当前声明名会加字号/字重/字距，应用于所有调用点将严重干扰阅读。
- 本次设置显示 humanist comments 已开启，所以图 4 的比例字体注释不能归咎于默认设置；当前源码默认其实是关闭。先给用户一个协调的推荐预设，保留原来的偏好选项。
- 当前行、选择、搜索命中、符号引用和导航落点应各有清晰且不冲突的表达；折叠前后、长行水平滚动、diff/书签共存都要查实际位置。

### D. 高亮：缺的是代码角色，不只是颜色

当前 [HighlightKind](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift:7) 只有 9 类，[主题](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightReaderCore/ReaderSettings.swift:254) 实际归成 6 组语法色。[Rust 遍历](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift:536) 主要覆盖关键字、注释、字面量、类型标识符和声明名。调用、字段、宏、attribute 等缺少独立表达。

补齐有明确阅读价值的角色：函数/方法调用、属性/字段、宏与 attribute、参数/局部绑定、枚举成员。参数/局部绑定优先复用已有 `localBindings` / `referencesByBinding`；其余按现有 Tree-sitter 数据能够可靠识别的范围实现。不确定的引用保持中性，不能把词法猜测伪装为完整语义解析。

角色数不等于颜色数。采用有限的协调色组，配合少量字重，避免“每一种节点一个颜色”。语法角色和声明排版也应区分：不要把调用名复用为现有 `.functionName`，因为 [这个分支](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift:2930) 还会放大和加粗。

VS Code 的官方分类把 property、parameter、enumMember、method、macro 等区分开，这可以作为命名参考；其语义高亮叠加在语法高亮之上。不能仅凭 Cursor 的截图认定每一处颜色来自哪层，也不需要为了这轮整改新接一条 LSP 高亮管线。[官方语义高亮说明](https://code.visualstudio.com/api/language-extensions/semantic-highlight-guide)

### E. 分栏：可拖范围、发现方式和恢复应有统一规则

**现场结果：** 当前运行 app 的右侧外层分隔线可以向左右拖动，AX 位置为 952 → 892 → 1022；恢复时 setValue 也能将其回到 952。因此图 6 的“完全不能拖”本次未复现，不能写成确定根因。AX 的 disabled 标记与可操作事实不一致，是需要专项核查的无障碍风险。

**当前源码确定：**

- 已用原生 NSSplitViewController；[Relations 限制为 300–560pt](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/MainWindowController.swift:197)，窄窗还会进一步收紧，可能让最小值与最大值重合。
- [内部 Inspector 并排布局](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/RelationWindowController.swift:895) 要求 604pt、恢复要求 628pt，超过外层 560pt 的硬上限。嵌入右栏正常情况下到不了并排模式。
- 内部叫 contentSplit 的对象实际是 [NSStackView.fillEqually](/Users/siancao/work/ai/vibecoding/codeinsight/Sources/CodeInsightApp/RelationWindowController.swift:783)，不能拖动内部比例；它与用户图 6 的外层边界不是同一处。
- 外层会话主要保存 preset，未见用户拖动尺寸的对应持久化；不能用 Files/Outline 的 autosave 证明全部分栏都会恢复。

整改规则：

- 保留原生 split view；先测实际命中区域和 resize 光标，不能把细线的视觉宽度等同于有效命中宽度。如果确实不足，再用原生 delegate/分隔条能力提供约 6–8pt 的有效命中带及正确光标，避免自建手势框架。
- 将“默认宽度”和“硬性可拖上限”分开。右栏默认约 320–380pt，最大值由窗口余量及 Reader 最小可读宽度决定；宽屏允许超过 628pt，或明确取消该并排模式，两种产品规则必须一致。
- 窄窗优先使用可理解的折叠方式，不能显示一条看似可拖、实际 min=max 的线而不提供反馈。
- 关闭/重开右栏、切文件、缩放窗口、退出重启后保留用户调整。复用原生 autosave 或已有会话布局数据，不新增布局管理器。
- 用户图 6 的复现需要记录当时窗口大小、布局 preset、当前 min/max、鼠标命中点及 bundle 版本。

## 扩展检查：为什么整体仍像 MVP

| 范围 | 问题 / 证据级别 | 整改 |
|---|---|---|
| 整体信息层级 | 现场：空 Context 占据明显高度，Trail 空提示常驻，右栏无数据时仍大片留空 | 初次没有上下文时用轻量入口；有结果或用户明确打开时展开。保留用户主动选择的面板状态和功能可发现性。 |
| 顶部与 tabs | 截图：多个控件都有强边框/胶囊背景，Tabs、Full/Structure/Overview、Trail 的强调程度接近 | 工具条、阅读导航、辅助状态各有主次；统一高度/分割线。保证文件名和当前文件最容易识别。 |
| 路径与当前位置 | 当前有 scope 提示，但目录、文件、符号信息没有形成稳定导航行 | 复用当前文件/outline 数据给轻量可点击面包屑，长路径合理压缩；控制数量与 tabs 不互相挤压。 |
| 长名称 / 多 tabs | 未做实机极端覆盖 | 验收长路径、同名文件、多标签溢出、关闭最后一个标签、预览转固定；不凭小样例断言产品完成。 |
| 设置 | 现场：高级 opacity/weight 参数占首屏，常用开关靠后，首屏内容需要滚动 | 首屏放主题、字号、行高、折行、行号；高级排版折叠收纳，给同一段代码预览及恢复默认入口。复用现有设置字段。 |
| 文案 | Palette 同时出现英文提示与中文“…还有 N 条”；设置使用 declaration emphasis 等内部词 | 至少当前语言内统一；建立常用名词对照，避免中英随机混用。完整本地化支持按产品范围单列，不用临时散落翻译。 |
| 无数据 / 等待 / 限制 | 本次初始 Exact 为 ready，后变成 deps unavailable (offline)；细小状态文字较难解释能力边界 | 区分“没有结果”“仍在分析”“依赖不可用”。状态可点开解释和下一步；保留 Safe/能力限制真实含义。 |
| 无障碍 | 现场 AX 分隔条 disabled 但能拖；设置四个视觉 slider 没有作为独立 slider 出现 | 用 VoiceOver/键盘实测并核对控件 label/value/可操作状态。当前截图不构成无障碍合规证明。 |
| 配色和对比度 | 标题 accent 过多；次要图标和状态视觉偏弱，尚未量测 | light/dark 分别检查真实文字/背景组合、非激活选中、提高对比度设置；颜色之外保留文字、图标和焦点表达。 |

推荐整体方向：**紧凑、安静、信息充分的原生代码阅读器。** 借鉴 Cursor 的内容密度、对齐和层级；保留 Cairn 的声明阅读、关系跟随、快照边界。Blame、CodeLens、minimap 等不属于完成这轮精致度整改的前提，不自动扩充范围。

## 实施顺序与完成条件

### 第一批：消除最明显的几何和交互缺陷

范围：PalettePanel、Reader gutter、主窗口 split 约束。修 owner 定位、响应式宽度、单条/空态、滚动条/inset、正文起点和分栏限制；先验证原生鼠标命中，仅在存在问题时调整。

完成条件：用真实打包 app 重走步骤 2–4、6–7；多/单/零候选不裁切、不跳输入行；正文没有双重 gutter；两向拖动有效、窄窗行为可解释。先补测量再修，保护现有点击/折叠/书签坐标。

### 第二批：统一主窗口与侧栏

范围：Files/Outline、tabs/header、Trail/Context 空态、面板宽度恢复。只抽取确有多个消费者的少量尺寸/颜色常量，放在已有主题/对应 UI 层；不建立可配置 token 引擎。

完成条件：同一文件在 900 / 1280 / 1600pt 窗口下无裁切或重叠；Files/Outline 真正可展开、位置可恢复；辅助区不无故挤占阅读区；当前文件/符号/选中项关系明确。

### 第三批：补足阅读信息

范围：现有 Tree-sitter 高亮分类、主题映射、Outline 必要字段/枚举变体/类型摘要。

完成条件：用一段真实代表代码并列看声明、调用、字段、参数、宏、attribute、字符串/注释；light/dark 都清楚、协调。Rust 先完成主要问题，同时检查 Python/TypeScript 的共享渲染不退化；随后按各语言现有能力补齐，不把三门语言一概宣称相同支持。

### 第四批：完成周边工作流和整体验收

范围：设置的信息层级和 AX、查找/搜索/书签/Reading Set/Compare 的同类布局问题、空态/等待/失败文案。核心顺序是“打开项目 → 找文件 → 读代码 → 跳符号 → 看关系 → 返回 → 恢复布局”。

完成条件：端到端工作流、当前 bundle 的实际截图和键盘/AX 操作都通过。每批都有独立可验收结果，不等全部改完才看界面。正式实施时按各批独立变更；本次仅提出方案，未创建提交。

## 验收方式也必须改

现在有一部分测试在保护实现参数，而没有保护用户结果。例如 [PaletteTests:302](/Users/siancao/work/ai/vibecoding/codeinsight/Tests/CodeInsightAppTests/PaletteTests.swift:302) 直接要求宽度 380、高度 258；gutter 的几何测试从相同的 ruler/inset 假设计算两边；侧栏恢复测试构造裸 NSSplitView，未重建真实 SidebarViewController。这些检查即便通过，也不能证明这次截图中的问题不存在。

沿用现有测试、自测入口和原生 UI 验收，不另起框架：

| 验收对象 | 真正要保护的结果 |
|---|---|
| Palette 定位 | 所属窗口中居中、屏幕可见；结果变化后输入头位置稳定；owner 不在主屏也正确。 |
| Palette 0/1/多条 | 完整候选/空态可见，长名称路径无重叠，左右一致，真实溢出才滚动。 |
| Reader gutter | 直接测首 glyph 与 gutter 边缘，覆盖字号、行号开关、折叠/书签/diff 和系统滚动条模式。 |
| 拖动与恢复 | 实际鼠标两向拖；放手后不弹回；切文件、toggle、resize、真实控制器重建及应用重启后位置正确。 |
| 高亮与 Outline | 一个小而有代表性的语法样例验证角色；原生 Reader 截图验证视觉；层级/展开/导航结果可操作。 |
| 键盘与 AX | Cmd+P/F、上下键/Return/Esc、焦点回归；面板/树/slider 的 label、value 和状态准确。 |
| 视觉矩阵 | light/dark × 900/1280/1600pt，另抽查大字号、长路径、系统常显滚动条。固定数据和缩放看前后对照。 |
| 已有能力 | 跑受影响的现有坐标、导航、搜索、折叠、快照和产品 gates；仅在出现新失败/风险时扩大范围。 |

不能以“测试全绿”“窗口能打开”“控件在 AX 中存在”替代视觉及实际交互验收。精致度的退出条件是这些具体场景中的内容、对齐、拖动、键盘和恢复全部成立。

## 参考截图与后续交接

六张用户截图：[弹窗位置](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/ref-01-palette-position.png)、[唯一候选](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/ref-02-palette-single.png)、[Cursor 侧栏](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/ref-03-cursor-sidebar.png)、[Cairn 代码](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/ref-04-cairn-reader.png)、[Cursor 代码](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/ref-05-cursor-reader.png)、[分隔线](/Users/siancao/work/ai/vibecoding/codeinsight/docs/reviews/evidence/2026-09-11-product-polish/ref-06-divider.png)。

本次现场截图保存在同一 evidence 目录。AX 数字是辅助操作证据，不应与截图像素混用。当前还没有修改后的设计稿或成品截图；上述尺寸是可评审的起点，必须在真实 AppKit 页面完成视觉校准。
