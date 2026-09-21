- # 阅读器软换行（Soft Wrap）设计 · v2

  日期：2026-09-19  
  状态：评审后修订，待实施与验收。  
  代码基线：`sonald/cairn@7666dcb0079e5dfab88342c5dac826307332f542`。这是上一轮评审核对的默认分支提交，提交日期为 2026-09-18。本文的源码事实均以该提交为准。[^BASE]

  本方案将软换行完善为常用的全局阅读控制：用户可以快速切换，正在阅读的文字和选区得到保留，行号与标记落在正确的视觉行，各阅读面按明确的规则完成重排。

  文档沿用原方案的 G1–G5、D1–D5 编号。§5.1 记录原文中已由用户确认的四项交互裁决；其余新增算法、内部接口和性能预算是本次修订提出的实施约定。文中的示意接口尚未实现，测试结果和性能数值均待 macOS 环境验收填写。

  前置成果：m11 R4 已落地基础 wrap 能力，原方案记录其提交为 `04cbe52`，验收材料位于 `docs/plans/evidence/m11/m11-acceptance.md`。[^ORIGINAL]

  ## 1. 现状盘点

  ### 1.1 可复用的实现

  | 范围          | 基线实现与证据                                               |
  | ------------- | ------------------------------------------------------------ |
  | 设置模型      | `ReaderSettings.wrapLines` 为 package 属性，默认 `false`；持久化 key 为 `reader.wrapLines`，缺少 key 时恢复为 `false`。[^SETTINGS] |
  | Settings 入口 | Reader 页已有 `Wrap lines` Toggle；Settings 外部值可同步到表单状态，预览使用 `ReaderTextView`。[^SETTINGS_UI] |
  | 全局传播      | `AppDelegate.commitReaderSettings(_:)` 保存设置，广播至项目窗口，并更新已打开的 Settings 窗口。[^APP] |
  | 基础换行      | `ReaderTextView.configureWrapping(in:)` 配置滚动条、水平伸缩、宽度跟踪、容器大小和 autoresizing。[^READER] |
  | 主阅读器渲染  | `ReaderTextView` 显式使用 TextKit 2，并通过 `DisplayMap` 映射源字节与显示文本；字体、折叠附件与 rendering attributes 已有独立处理路径。[^READER] |
  | 多阅读器传播  | `MainWindowController.applyReaderSettings(_:)` 向主 Reader、对比 Reader、Context 等控制器传递设置。具体渲染状态仍需逐个阅读面验收。[^WINDOW] |
  | 基础测试      | R4 已有逻辑行装饰唯一性测试，以及换行属性和窗口缩放可逆性测试。[^TESTS] |

  ### 1.2 实施时必须面对的现有行为

  `ReaderTextView.apply(settings:)` 在替换 text storage 之前已经调用 `configureGutter`；后者会调用 `configureWrapping`，并触发布局。视口快照必须在这条链路开始之前捕获。[^READER]

  现有 `followAnchorByteOffset()` 选择接近视口高度 25% 处的 layout fragment，返回该 fragment 起点对应的源位置。现有 `restore(scrollByteOffset:selectionByteOffset:)` 则将目标源逻辑行定位到顶部，并把传入的 selection 恢复为长度为零的插入点。这两个函数不足以表达本设计要求的字符位置、屏幕偏移和完整选区。[^READER]

  `drawRuler` 使用整个 layout fragment 的矩形。点状标记和折叠箭头使用其中心，diff 条覆盖整个 fragment 高度；行号绘制矩形也使用整个 fragment 高度。折叠 click 经 `foldRegion(at:in:)`，hover 经独立的 `updateFoldHover(at:in:)`，后者目前只检查 x 是否位于折叠列。[^READER]

  `drawPrimarySelection` 只调用一次 `firstRect(forCharacterRange:actualRange:)`，并只绘制一个矩形。Apple 规定跨行范围的这次调用只返回第一行的矩形，因此跨视觉行的当前查找命中需要单独修复。[^READER][^FIRST_RECT]

  Reading Set 使用独立的 `NSTextView`、行号标签和手工宽高布局。宽度按最长源行估计，高度按源行数量估计；卡片更新只收到 `ReaderTheme`，其中没有 wrap 状态。[^READING_SET][^SETTINGS]

  普通文本与 Markdown 共用 `displayPreviewText`。该入口目前统一创建可换行的文本视图；已打开预览的设置更新路径主要更新颜色。[^WINDOW]

  ## 2. 缺口分析

  ### G1 可发现性与全局状态

  增加 View 菜单和快捷键，并确保 Settings 成为活动窗口时，全局命令仍然可用。菜单、Settings、当前阅读面和之后创建的阅读面都要使用同一个设置值。

  ### G2 首视觉行几何与跨行装饰

  折行后，一个源逻辑行可以占据多个视觉行。gutter 的点状标记、行号、diff 条及折叠交互需要明确使用首视觉行；当前查找命中的强调框需要覆盖其全部可见视觉片段。

  原方案对 `NSString.draw(in:)` 自动垂直居中的假设不作为实现依据。文字位置由本方案明确计算，再通过实际绘制验收。逻辑行与 TextKit fragment 也应通过源位置映射关联，不能将“一行恰好一个 fragment”的现有测试现象推广成所有渲染情况的前提。

  ### G3 重排时的阅读状态

  需要保留可见字符、字符相对视口的位置、完整选区及必要的水平位置。连续切换、字号调整、窗口缩放、分栏宽度变化和异步布局回调必须遵从同一套恢复规则。

  ### G4 悬挂缩进的布局生命周期

  缩进值受实际文本宽度、字体和 Tab 度量影响。宽度变化后需要重新计算 25% 上限；段落样式必须在所有投影构建入口生效，并独立于 `syntaxFormatting`。

  ### G5 Reading Set 与预览重排

  Reading Set 需要完整的设置传递、实际排版高度、布局驱动的行号和外层滚动恢复。普通文本需要覆盖创建与实时更新两条路径；Markdown 需要明确采用其文档预览规则。

  ## 3. 目标、范围与基础约定

  ### 3.1 用户可见目标

  | 目标            | 可观察结果                                                   |
  | --------------- | ------------------------------------------------------------ |
  | 快速切换        | View → `Wrap Lines`、`⌥Z`、Settings Toggle 同步              |
  | gutter 定位正确 | 首视觉行出现行号和标记，续行区域没有折叠柄命中               |
  | 阅读位置稳定    | 相同可见字符在重排后保持相近的视口位置，完整选区与复制结果得到保留 |
  | 续行缩进        | 代码续行按源行前导空白缩进，满足 24 列与当前有效宽度 25% 的双重限制 |
  | 阅读面一致      | 主 Reader、辅助 Reader、Reading Set 与普通文本按下表响应全局设置 |
  | 交互完整        | 查找命中跨视觉行时，强调框覆盖全部可见命中片段               |

  ### 3.2 阅读面策略

  | 阅读面                                                       | wrap 策略            | 悬挂缩进               | 视口恢复责任                                                 |
  | ------------------------------------------------------------ | -------------------- | ---------------------- | ------------------------------------------------------------ |
  | 主 Reader、对比 Reader、Context miniReader、其他使用 `ReaderTextView` 的代码阅读面 | 全局 `wrapLines`     | 按 D4                  | 每个 `ReaderTextView` 自己的局部视口                         |
  | Settings 代码预览                                            | 全局 `wrapLines`     | 按 D4                  | 预览实例；初次展示从开头开始                                 |
  | Reading Set 代码卡片                                         | 全局 `wrapLines`     | 按 D4 的代码段落规则   | 卡片选区与横向状态由卡片保存，纵向状态由外层 Reading Set 保存 |
  | 普通文本预览，如 `.txt`、`.log`                              | 全局 `wrapLines`     | 使用普通文本段落样式   | 预览控制器                                                   |
  | Markdown 渲染预览                                            | 按文档预览布局换行   | 使用 Markdown 段落样式 | 预览自身                                                     |
  | HTML、PDF、图片预览                                          | 各自渲染器的布局策略 | 不适用                 | 各自渲染器                                                   |

  本表对 Reading Set 悬挂缩进、普通文本段落样式和 Markdown 的描述，是本版补充的实施策略，详见 §5.2。

  ### 3.3 本次范围边界

  按固定列数换行、列指示线、按语言或按文件记忆 wrap、续行箭头、点击行号选择整行继续列入 backlog。当前行背景按源逻辑行覆盖其全部视觉行。[^ORIGINAL]

  软换行只改变排版。源字节、源行号、搜索范围、复制文本及源位置映射以原内容为准；实现不得通过插入换行或空格制造视觉效果。

  ### 3.4 位置与坐标约定

  | 名称           | 含义与使用范围                                               |
  | -------------- | ------------------------------------------------------------ |
  | 源位置         | `ReaderDocument.bytes` 中的 UTF-8 byte offset；跨排版变化识别同一内容 |
  | 显示位置       | 当前 `DisplayMap` 对应字符串中的 UTF-16 offset／`NSRange`；TextKit 和 AppKit 选区使用 |
  | 逻辑行         | 源内容中的行，由现有 line table 识别                         |
  | 视觉行         | TextKit 在给定宽度下排出的行                                 |
  | layout 坐标    | `layoutFragmentFrame` 所在坐标系                             |
  | text view 坐标 | 加入文本容器在 `NSTextView` 内的实际原点后的坐标             |
  | ruler 坐标     | 用 `ruler.convert(..., from: textView)` 得到的坐标           |
  | 视口偏移       | 锚点矩形在同一坐标系中相对可见区域顶部的距离，单位为 point   |

  `NSTextLineFragment.characterRange` 的索引基准属于其 source attributed string；封装转换时必须结合所属 fragment／element 的位置。不得直接把局部 offset 当全文 UTF-16 offset。转换须覆盖中文、emoji、组合字符和折叠占位符。[^LINE_FRAGMENT]

  所有像素验收先统一到同一 view 坐标系，再按 `backingScaleFactor` 换算。文中 `pt` 指逻辑点，物理像素误差另行注明。

  ## 4. 方案设计

  ### D1 入口与状态（App 层）

  #### D1.1 设置链路

  View 菜单在现有阅读／折叠控制附近增加 `Wrap Lines`。快捷键为 `keyEquivalent = "z"`、modifier mask `.option`。菜单 action 复制当前 `readerSettings`，翻转 `wrapLines`，再调用 `commitReaderSettings(_:)`。

  菜单的勾选与可用性直接读取应用级设置。Settings 或欢迎窗口成为 key window 时，命令仍可使用。菜单验证不依赖活动项目是否提供 `projectCommandTarget()`。

  继续以现有 `ReaderSettings` 和 `reader.wrapLines` 保存状态。`commitReaderSettings` 负责持久化、广播和 Settings 更新，视图只持有渲染所需的当前快照。[^APP][^SETTINGS]

  #### D1.2 创建时与实时更新

  窗口或阅读面创建时先收到当前设置，再展示正文。已挂载的阅读面通过 `apply(settings:)` 响应变化；尚未挂载或宽度为零的实例保存最新设置，在首次获得有效几何时完成布局。

  Settings 中的 `suppliedSettings → @State settings` 同步要保留，并检查相同值写回不会再次发起布局。设置值相同的 `apply` 应为幂等操作。[^SETTINGS_UI]

  ### D2 首视觉行几何、gutter 与当前命中（ReaderUI 层）

  #### D2.1 统一几何查询

  新增内部 helper，建议名为 `firstVisualRowRectInTextView(of:)`。其结果明确位于 text view 坐标系。

  计算步骤为：取得目标视觉行的 `typographicBounds`，转换到所属 layout fragment 的全局位置，再加上 `textView.textContainerOrigin`。`textContainerOrigin` 已包含容器 inset 等因素；不得再额外叠加一次 `textContainerInset`。当前 `fragmentRectInTextView` 使用 inset 的实现应一起审查，形成单一转换入口。[^READER][^LINE_FRAGMENT][^CONTAINER_ORIGIN]

  首视觉行的身份通过源逻辑行与显示 range 确定。普通一行对应一个 fragment 的情况可直接取其首个 `textLineFragment`；折叠投影、空段落或多 fragment 情况必须核对映射。对于尚未完成布局的 fragment，返回“几何不可用”，等待布局完成后刷新。

  建议内部记录至少包含：源逻辑行号、首视觉行显示范围、首视觉行在 text view 中的矩形、当前布局 revision。滚动时转换至 ruler 坐标，避免长期缓存会随滚动失效的 ruler 矩形。

  #### D2.2 绘制规则

  | 装饰                         | 绘制规则                                                     |
  | ---------------------------- | ------------------------------------------------------------ |
  | 行号                         | 只在首视觉行绘制一次；用行号字体的实际测量高度计算 y，使文字在该行矩形中垂直居中，横向右对齐 |
  | 声明点、书签点、导航着陆标记 | 中心位于首视觉行垂直中心                                     |
  | 折叠箭头                     | 绘制在首视觉行对应的折叠列区域                               |
  | diff 条                      | 限于首视觉行的高度，可保留既有列内留白                       |
  | 当前行背景                   | 覆盖当前源逻辑行对应的全部可见视觉行                         |
  | occurrence 背景              | 使用源范围投影后的 TextKit rendering attributes；补充折行回归测试 |

  行号文字位置由测量结果和绘制原点显式确定。区分 `rowRect`、`labelRect` 和实际 glyph／baseline 位置：行号字号小于正文字号时，`labelRect.minY` 不必等于 `rowRect.minY`。

  当首视觉行已经滚出视口、只有续行可见时，首行专属装饰随其滚出；续行仍参与当前行背景绘制。装饰可见性按装饰本身的矩形与视口求交，不能仅依据整个 fragment 与视口相交。

  #### D2.3 折叠 hover 与 click

  把首视觉行几何用于两条交互路径：`updateFoldHover(at:in:)` 和 `foldRegion(at:in:)`／`clickFoldHandle`。

  命中区域是折叠列的 x 区间与首视觉行的 y 区间。为避免相邻行共享边界，按半开区间判断 y。鼠标位于某逻辑行的续行 gutter 时，不产生该行折叠柄 hover，也不执行该行折叠。

  可将现有单个 `foldGutterHovered: Bool` 改为当前 hovered `FoldID?`，使 hover 身份与实际命中的首行一致。鼠标离开、滚动、宽度变化和重新投影后重新计算或清空 hover。Option-click 的既有递归折叠语义继续通过命中后的 fold action 执行。[^READER]

  #### D2.4 当前查找命中跨视觉行绘制

  新增内部查询 `visibleRects(forDisplayRange:)`，返回 text view 坐标中的所有可见命中片段。`drawPrimarySelection` 为每个片段分别绘制现有样式的背景和描边。

  首选 TextKit 2 的文本 segment 枚举，限制到命中范围与可见区域对应的范围；该 API 能表达同一视觉行中不连续的视觉片段。若使用 `firstRect` 兼容实现，必须读取 `actualRange`，逐段推进到剩余范围，统一屏幕坐标转换，并处理无进展、无效范围及空矩形。[^TEXT_SEGMENTS][^FIRST_RECT]

  具体要求：几何查询不可强制布局整个主 Reader 文档；每个返回片段都按 viewport／dirty rect 裁剪；零长度光标不画命中框；反向文字产生的矩形先规范化；当前命中索引与源匹配范围沿用查找模型。

  ### D3 重排时保持视口与选区（ReaderUI 层）

  #### D3.1 状态模型

  为当前阅读面新增短生命周期的 `ReaderViewportState`。该状态归 `ReaderTextView` 实例所有，供同一内容的重排使用。

  | 字段                    | 作用                                                         |
  | ----------------------- | ------------------------------------------------------------ |
  | 内容身份                | 文件／阅读面身份与 `ContentID`，防止旧状态作用于新文档       |
  | 投影身份                | 当前投影 revision，或等价的内容身份与有效折叠集合版本；用于判断显示 ranges 能否直接恢复 |
  | 锚点                    | `.source(byteOffset)`、`.fold(FoldID)` 或空文档／末尾位置，识别具体内容 |
  | 显示边界信息            | 当前 UTF-16 位置及必要的 affinity，明确软换行边界属于哪一侧  |
  | `offsetFromViewportTop` | 锚点所在视觉行参考点相对视口顶部的距离                       |
  | `selectedRanges`        | 完整显示选区数组，并保存当前选择 affinity；恢复后 Shift 扩展选区方向需验收 |
  | 交互选择状态            | 当前 primary selection／find selection 身份及原生 selection 绘制方式所需状态 |
  | 水平位置                | 当前合法 x 及暂存的非换行 x                                  |
  | generation              | 布局请求序号和用户交互序号，防止过期恢复                     |

  上述是字段职责约定，实现可以组合成少量内部值类型。仅记录“行号＋一个 byte offset”不满足本节契约。

  #### D3.2 捕获锚点

  在发生布局修改之前，读取已经稳定的可见布局。优先选取视口高度约 25% 处的可见视觉行，再从该视觉行的可见横向区域内选一个实际字符位置。宽度已横向滚动时，要在当前可见文字中取点。

  记录该字符的源 byte offset，以及其所在视觉行参考点相对 viewport 顶部的偏移。记录单位应统一为 text view 坐标中的 point。软换行边界使用确定的 affinity；组合字符按 TextKit 返回的合法字符边界定位。

  如果可见对象是折叠 chip，保存 FoldID 和它的位置，恢复到同一占位符。纯重排不应为了寻找 anchor 展开该折叠。空文档、末尾额外行以及没有可见 glyph 的空白行使用合法插入位置作为锚点。

  首次显示或零尺寸视图无法获取有效几何时，只保存设置和已有 selection；等首次完成有效布局后建立稳定锚点，首次展示仍从文档开头开始。

  #### D3.3 保持同一个字符及屏幕偏移

  完成新的布局后，定位同一锚点在新布局中的视觉行参考点，并计算：

  ```text
  newScrollY = newAnchorY - savedOffsetFromViewportTop
  ```

  将滚动位置约束在 `NSClipView` 的合法范围内，随后反映滚动条状态。文档开头、结尾或内容短于视口时允许边界限制，但必须记录 clamp 原因。

  旧 `restore(scrollByteOffset:selectionByteOffset:)` 的“目标源行置顶”语义继续服务现有导航／快照路径。重排使用本节的独立入口，不调用会置顶、展开折叠或显示查找指示器的导航方法。[^READER]

  对于超长逻辑行，恢复的是内部可见字符。由于开启／关闭 wrap 后该字符可能从第十个视觉行移动到单行中的中间位置，源逻辑行行首不能替代这个字符。

  #### D3.4 完整选区与事件副作用

  同一投影内容下，保存和恢复 `selectedRanges` 的全部范围及 affinity。恢复前核对投影身份和范围合法性。颜色或布局改变可以重建 storage 对象，但相同字符串的显示选区仍应指向相同内容。

  如果内容、折叠投影或导航目标已经变化，取消旧重排恢复，交给对应操作的状态恢复逻辑；不得把旧的显示范围直接应用于新投影。

  目前 `selectionHandler` 会更新当前行，并可能清除 primary selection、恢复原生 selection 样式和刷新 occurrence。新增恢复事务需要抑制中间的选择／滚动回调，把最后一致的状态发布一次。[^READER]

  恢复 selection 不抢走 Settings、查找输入框或其他窗口的 first responder；不新增导航历史，不伪造用户滚动。恢复后的 `onCaretChange`、`onViewportChange`、outline follow 等通知按最终状态合并处理。

  #### D3.5 连续切换与水平位置

  一串仅由 wrap、字号或宽度变化引起的重排，应继续使用同一个稳定文本锚点。不要在每次重排后重新选取新的 25% 位置：当长逻辑行从多行变成一行时，这会逐步丢失行内位置。

  用户主动滚动、单击、扩展选区、执行查找导航、切换文件／快照或改变折叠状态后，结束这串重排，依据新的阅读位置建立锚点。

  水平位置按以下规则处理：

  | 变化                        | 行为                                                         |
  | --------------------------- | ------------------------------------------------------------ |
  | wrap off → on               | 保存当前非换行 x，滚动到换行模式的合法起点；起点包含 clip inset，不能假设为 0 |
  | wrap on → off               | 同一阅读状态下优先恢复缓存 x；若锚点仍不可见，以最小水平滚动使锚点可见 |
  | wrap off 下的字号／宽度变化 | 优先维持合法的原 x，必要时最小调整以保留锚点可见性           |
  | 新的用户导航或阅读位置      | 使旧非换行 x 缓存失效                                        |

  垂直锚点保持与水平可见性分别计算。纯重排期间完整 selection 可以位于视口外，系统不应为了显示远处选区而覆盖阅读锚点。

  #### D3.6 统一执行顺序

  ```text
  识别变化并合并请求
  → 捕获或复用旧稳定视口状态
  → 进入布局更新保护，记录 generation
  → 更新主题、gutter、滚动条和文本容器几何
  → 取得本轮有效文本宽度
  → 按需要更新字体、段落属性与显示投影
  → 恢复完整 selection 和相关显示状态
  → 完成目标范围与 viewport 布局
  → 恢复 anchor 的相对位置与水平位置
  → 再核对一次几何和 generation
  → 刷新装饰，发布最终状态
  ```

  捕获必须发生在 `configureGutter`／`configureWrapping` 之前。相同内容下仅宽度改变时，只更新必要的段落属性和布局；不把每次窗口拖动都实现为全量 `DisplayMap` 重建。

  TextKit 可能在布局中再次调整文档高度。允许在下一次正常主线程布局完成回调中有限次校正，建议最多 3 次；每次校验内容身份、布局 generation 和用户交互序号。超限输出诊断并结束本轮校正，禁止递归布局或无限 dispatch。三次上限属于本版工程参数。

  设置生效期间新到的设置取最新值，旧回调失效。用户主动滚动或导航优先于尚未完成的恢复。窗口关闭和文档替换立即使旧 generation 失效。

  #### D3.7 覆盖的布局变化

  wrap、基础字号、函数／类型字号增量、行高、字体粗细、Syntax formatting、比例字体注释、行号／gutter 宽度，以及窗口／分栏宽度变化均进入几何更新判断。可用一个内部 layout signature 比较实际输入；纯颜色与透明度变化走重绘路径。

  窗口和分栏变化通过已有 AppKit view 的尺寸生命周期接入。对 `ClickTextView` 增加窄的尺寸变化回调，在有效宽度实际改变之前保存旧稳定状态，修改后调度一次更新；已有 viewport 回调用于收尾。只有事后的 `boundsDidChange` 通知不足以捕获原位置。

  同一轮 `tile`、frame 与 bounds 通知合并处理；相同有效宽度不重复更新。设置更新与尺寸回调重入时由同一个实例级保护和 generation 协调。

  ### D4 悬挂缩进与段落布局（ReaderUI 层）

  #### D4.1 独立的段落步骤

  新增 `applyParagraphLayout` 或等价内部步骤。主 Reader 的投影构建顺序为：

  ```text
  DisplayMap 与 projected string
  → 基础字体和基础段落样式
  → applyTypography（按 syntaxFormatting 应用语法字体）
  → 安装折叠附件
  → applyParagraphLayout（按 wrap、宽度与前导空白处理）
  → 发布投影与 storage
  ```

  `applyParagraphLayout` 显式接收布局配置，包括 wrap、有意义的有限文本宽度、基础代码字体度量及 Tab 排版信息。`ReaderTheme` 继续表达样式；宽度属于当前视图布局输入。

  当前 `applyTypography` 的入口带有 `guard theme.syntaxFormatting`，因此新步骤必须位于该 guard 之外。`display`、`updateSyntax`、设置更新、折叠投影重建和任何其他 `project` 调用都使用相同段落规则。[^READER]

  #### D4.2 有效文本宽度

  以完成 gutter 与滚动条布局后的文本容器为准取得宽度。对当前普通矩形代码容器，行内可排版宽度为容器宽度减去左右 `lineFragmentPadding`。容器宽度已经反映 text view 的 inset 和所在阅读列实际可用宽度；此处不得再扣一遍 gutter 或 inset。

  为避免属性设置瞬间和稳定布局后的尺寸不同，配置时使用目标宽度，布局后再校验实际宽度。如果发生有效变化，再合并到 D3 的有限校正流程。

  W 必须为有限正数。视图尚未挂载、宽度为零或使用非换行无限容器时，不用其值计算 25% clamp；保存待布局状态，首次有效尺寸到达后执行。

  #### D4.3 缩进公式

  定义：

  ```text
  prefixAdvance = 当前逻辑行前导空格和 Tab 的实际排版宽度
  spaceAdvance  = 当前基础代码字体的一个空格 advance
  W             = 当前有效文本宽度
  
  headIndent = min(prefixAdvance, 24 × spaceAdvance, 0.25 × W)
  ```

  wrap on 时，对代码段落设置 `firstLineHeadIndent = 0`，`headIndent` 使用上述结果。第一行的实际缩进来自源文本中的空格／Tab；续行增加的是段落排版属性。没有前导空白的行，`headIndent = 0`。只有空白的行采用零悬挂缩进。

  wrap off 时恢复该阅读面的基础段落缩进。代码 Reader 的基础首行和续行缩进为零，源文本自身的前导空白照常显示。[^READER]

  Apple 将 `headIndent` 定义为文本容器前缘到非首行起点的 point 距离，因此宽度变化后必须重算比例上限。[^HEAD_INDENT]

  例如基础空格宽度为 8pt、源前缀为 20 个空格：W=800pt 时续行缩进为 160pt；W=320pt 时缩进为 80pt。这是说明公式的示例值，并非系统字体测量结果。

  #### D4.4 Tab 度量

  本版使用当前基础段落样式的实际 `tabStops` 与 `defaultTabInterval`。原方案没有裁决 4 列或 8 列 Tab，因此不在本次新增一个全局 Tab 列宽偏好。Apple 的 `defaultTabInterval` 使用 point，并与显式 tab stops 共同决定后续 tab 位置。[^TAB_INTERVAL]

  纯空格前缀可按空格 advance 累加。含 Tab 的前缀通过可复用的单行 TextKit 测量上下文取得前缀实际 advance；测量使用同一基础代码字体和 Tab 段落配置、无限制行宽、零额外首行／续行缩进，并在前缀后放置测量用的非空白字符定位终点。测量内容只存在于独立测量上下文，不进入阅读器源文本。

  测量器复用 TextKit 对象，按字体、Tab 配置和前缀缓存结果，不为每一行创建 NSView。字体和 Tab 配置改变时缓存失效。长纯空格前缀可在已经确定达到 clamp 后停止计算；含 Tab 时必须依据相同的排版配置计算。

  由此保证开关 wrap 不会因为两套 Tab 解释方式而改变首行缩进。单测使用明确 tab stops 验证混合前缀，再用实际视觉行位置作独立校验。

  #### D4.5 段落样式的保留与失效

  从该阅读面的基础 paragraph style 复制出新样式，保留 `lineHeightMultiple`、行距、Tab 等已有值，只改本功能负责的缩进字段。样式安装到 attributed string 后按不可变对象对待；宽度改变时创建并替换新的样式值。

  按显示段落写属性，再经 `DisplayMap` 找到其对应的源行前导空白。折叠投影中隐藏的源行不单独写入；包含 fold chip 的显示段落按对应源 header 行取得缩进。禁止把源 byte range 直接当 attributed string range。

  有效宽度变化时，复用已计算的源行前缀宽度，重新计算受影响段落的 `headIndent`。只有值实际变化的段落才更新属性，并在一次 editing batch 中提交。完整初次投影可遍历显示段落；窗口拖动无需重新解析语法或重建源行表。

  懒布局不等于段落值可以永久过期。初版需保证当前显示投影中的段落属性都符合本轮宽度；是否进一步做段落级增量索引，根据 §7 的性能数据决定。

  #### D4.6 组合场景

  深缩进、比例字体注释、放大声明名、关闭 Syntax formatting、连续宽度变化、CRLF、空行和折叠附件都应测试。

  fold chip 可能因为前面的文字变长而移动到续行。布局与点击仍使用它实际的 attachment 几何；gutter 折叠柄使用源 header 的首视觉行，两者通过同一 FoldID 关联。不得把“chip 始终处于首视觉行”作为前提。

  ### D5 Reading Set 与普通文本预览（App 层）

  #### D5.1 明确设置传递

  `ReadingSetView` 保存最新 `ReaderSettings`，或保存由其导出的显式 `ExcerptLayoutConfiguration`。已有卡片更新与新卡片 `display` 都收到相同的 wrap、字号、行高和代码段落配置。

  卡片的 `apply` 不再只接受 `ReaderTheme`。可采用 `apply(settings:)`，或显式传入 `theme` 与 `layout` 两个值。与宽度相关的值在卡片完成局部几何后确定。[^READING_SET]

  设置变化只更新布局和视觉属性；Reading Set 的 frozen source、provenance 与操作可用性按现有摘录模型处理。布局更新不重新抓取源文件。

  #### D5.2 卡片的文本与行号模型

  卡片继续使用独立的只读文本视图。为共用 D2 的视觉行几何，初始化时显式使用 TextKit 2，仿照主 Reader 已有的 TextKit 2 初始化方式；通过 `textLayoutManager` 取得布局。首次验收应检查该 manager 实际存在。[^READER][^TEXTKIT]

  新增一个轻量 gutter view，替代把全部行号拼成一个多行 `NSTextField`。显示摘录时建立本地 UTF-16 行范围到源行标签的映射，沿用 `excerpt.firstLine` 和现有省略行规则：`…` 占位行无行号，也不递增已采用的源行编号计数。此规则来自当前实现；本次不推断摘录模型未提供的被省略行数。[^READING_SET]

  gutter 按每个本地逻辑行的首视觉行几何绘制源行标签。续行没有重复标签。空行和末尾换行都应保留对应显示行；行号列宽按当前需要的标签和字体度量计算。

  #### D5.3 宽度、实际高度与约束

  卡片保存一个可复用的 `codeScrollHeightConstraint`。后续通过修改其 constant 更新高度，避免每次 `display` 或布局时新增固定高度约束。

  每次布局遵循以下顺序：

  ```text
  取得卡片外层实际宽度
  → 配置 wrap 对应的滚动条与文本伸缩属性
  → tile，取得代码滚动区域的实际可用宽度
  → 扣除卡片内部 gutter 和留白，确定 codeView／text container 宽度
  → 应用字体、行高与 D4 代码段落样式
  → 完成该摘录的文本布局
  → 读取所有摘录视觉行的实际最大底边，计入末尾行与文本 inset
  → 更新 codeView／codeDocument 高度及滚动区域高度约束
  → 外层 stack 布局完成后恢复 Reading Set anchor
  ```

  wrap on 时，`codeView` 宽度来自卡片可用宽度。wrap off 时，文本容器允许长行布局，文档宽度采用真实文本使用宽度与视口宽度的最大值，以支持横向滚动。

  高度包含实际文本使用高度、上下留白，以及当前 scroller style 下实际占用的横向滚动条高度。必须从已配置的滚动视图几何得到这些值，不把 legacy scroller 与 overlay scroller 假定为相同占用。

  当前的“源行数 × 字体高度”和“最长行字符串测量宽度”不再作为最终尺寸依据。TextKit 布局结果才决定正文的可见边界。[^READING_SET]

  卡片需要获知整个摘录高度，因此可能布局完整摘录；该成本按真实摘录总长度和卡片数量计入性能测试。主 Reader 的 viewport 策略不自动为卡片提供相同的成本保证。

  #### D5.4 防止重复重排

  卡片缓存布局签名，至少包括摘录内容身份、有效宽度、wrap、字体、行高、gutter 宽度及段落配置。签名相同直接复用结果；宽度／属性变化的请求按主线程一轮更新合并。

  单张卡片的高度变化使外层 stack 更新；外层布局通知只在有效宽度变化时触发新的文本排版。仅高度变化不能再次无条件触发同一排版，避免“排版—高度约束—layout—排版”循环。

  窗口连续缩放时，一代宽度请求只对每张受影响卡片测量一次；代次更新使旧的高度恢复回调失效。零宽度卡片先保存配置，进入有效布局后完成测量。

  #### D5.5 Reading Set 的外层视口状态

  布局前由 `ReadingSetView` 保存整体状态：当前卡片身份、该卡片内的本地 UTF-16 字符锚点、该视觉位置相对外层 viewport 顶部的偏移。卡片身份可以使用当前 Reading Set generation、卡片索引以及摘录内容摘要；状态只在同一个冻结集合内使用。

  重排后先定位卡片的新 frame，再定位卡片内同一文本位置，组合为外层 document view 中的 y，按 D3 公式恢复。这样，前面卡片高度增加时，正在阅读的后面卡片仍能留在原来的视口位置。

  视口锚点位于卡片 header、操作区或卡片间空隙时，记录卡片身份及区域内偏移。每张存在非空选区的卡片保存完整 selection；横向滚动缓存归卡片自己所有。

  现有 `restoreScrollOffset(_:)` 的像素偏移可用于原有首次恢复路径；wrap／字号／宽度重排使用上述卡片锚点。集合内容替换、用户滚动或关闭 Reading Set 时，使未完成的重排恢复失效。[^READING_SET]

  #### D5.6 普通文本与 Markdown 预览

  把预览种类建模为内部的明确值，如 `plainText` 与 `markdown`，由已有扩展名判断路径传入。显示标题与布局策略分别保存，避免靠展示用字符串判断逻辑。

  创建普通文本预览时按当前 `wrapLines` 配置容器宽度、水平伸缩、autoresizing 与滚动条。已打开预览的 `apply(settings:)` 通过同一配置函数即时更新，并采用本地 UTF-16 锚点与完整 selection 恢复。

  Markdown 使用自身文档段落样式和按视口布局的规则。共享 `displayPreviewText` 时显式传入 wrap policy，避免一次全局切换改变 Markdown 的段落缩进或文本宽度策略。当前两个预览确实共用该函数，相关实时更新触点位于 Reader controller 的 settings apply 路径。[^WINDOW]

  普通文本的字体策略不由本次 wrap 改造扩展；使用其当前实际字体测量布局。创建后更新与关闭再打开应得到相同的 wrap 状态。

  #### D5.7 多阅读面更新的一致性

  应用广播同一 settings 值，但各阅读面使用自己的尺寸、锚点和 generation。主 Reader 的恢复不得驱动另一列同步滚动；对比导航继续由现有明确的导航行为决定。

  隐藏但仍存活的阅读面保存最新配置。它再次可见时，先按当前宽度完成布局，再执行仍有效的局部恢复。Settings 预览和后台窗口更新不得改变活动窗口焦点。

  ### D6 内部责任与代码组织

  D6 是本次新增的实施分工说明，用于承接 D1–D5；不新增用户设置。

  | 责任                                     | 所有者                           | 建议实现位置                                |
  | ---------------------------------------- | -------------------------------- | ------------------------------------------- |
  | 全局设置、菜单、持久化与广播             | AppDelegate                      | `CodeInsightApp.swift`                      |
  | 原阅读器生命周期与更新事务               | `ReaderTextView`                 | `CodeInsightReaderUI.swift`                 |
  | 视觉行／命中范围几何转换                 | ReaderUI 内部 helper             | 可拆出 `ReaderLayoutGeometry.swift`         |
  | 短生命周期锚点、selection 快照与恢复辅助 | ReaderUI 内部值类型／helper      | 可拆出 `ReaderViewportState.swift`          |
  | 前缀度量、段落样式生成和配置             | ReaderUI 内部 helper             | 可拆出 `ReaderParagraphLayout.swift`        |
  | Reading Set 卡片尺寸与外层锚点           | 卡片和 `ReadingSetView` 各自负责 | `ReadingSetView.swift`                      |
  | 普通文本预览创建／实时更新               | Reader controller                | `MainWindowController.swift` 内现有预览路径 |
  | Settings 表单与预览同步                  | Settings 控制器及 preview view   | `ReaderSettingsWindowController.swift`      |

  新增文件名为建议。需要 AppKit 的几何、字体和布局状态放在 ReaderUI 或 App 层；ReaderCore 只保留既有设置与内容模型。共享 helper 接收显式文本范围、字体／布局参数和 view 引用，不持有全局窗口或另建一套设置状态。

  ## 5. 裁决与本版实施约定

  ### 5.1 原方案中已由用户确认的交互裁决

  | 编号 | 裁决                                                   |
  | ---- | ------------------------------------------------------ |
  | C1   | 快捷键为 `⌥Z`                                          |
  | C2   | 普通文本预览遵从全局 wrap；默认 `false` 时允许横向滚动 |
  | C3   | 悬挂缩进上限为 24 列，且不超过容器有效文本宽度的 25%   |
  | C4   | 折叠柄 hover 和 click 命中区为首视觉行                 |

  依据：用户提供的原设计文档 §5。[^ORIGINAL]

  ### 5.2 本版补充的实施约定

  | 编号 | 约定                                                         | 对应章节 |
  | ---- | ------------------------------------------------------------ | -------- |
  | E1   | Wrap 命令属于应用级设置，在 Settings 成为活动窗口时仍可用    | D1       |
  | E2   | 重排保留具体字符与视口偏移；完整选区、选择状态和必要的水平位置一并保存 | D3       |
  | E3   | 连续纯重排复用稳定锚点；用户交互及内容变化使旧恢复失效       | D3       |
  | E4   | 查找当前命中按多个可见文本片段绘制                           | D2       |
  | E5   | 缩进独立于 Syntax formatting，宽度变化后重算；Tab 沿用实际段落排版配置 | D4       |
  | E6   | Reading Set 采用实际文本布局确定宽高，并提供外层卡片锚点     | D5       |
  | E7   | 悬挂缩进用于代码 Reader 与代码摘录；普通文本和 Markdown 使用各自段落规则 | §3.2、D5 |
  | E8   | Markdown 按文档预览规则换行；普通文本响应全局开关            | D5       |
  | E9   | 性能通过显式测试模式测量重排／绘制完成；本文初始预算按 §7.4 执行 | §7.4     |

  E1–E9 是本次修订提出的方案，不记作原有用户裁决或已完成实现。

  ## 6. 实施切片与依赖

  ### 6.1 切片安排

  | 切片       | 内容                                                         | 完成条件                                                     |
  | ---------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
  | S0（准备） | 固定代码／fixture 基线；确定坐标转换测试；建立 wrap 性能入口和指标；验证尺寸变化回调时机 | 测试程序能区分 off/on，能输出真实配置、布局与绘制指标；旧行为基线有可复查数据 |
  | S1（P0）   | D1 菜单与快捷键；D3 主 Reader 的视口、选区、generation 及尺寸变化处理 | 连续切换、非空选区、长逻辑行内部锚点和多窗口同步通过         |
  | S2a（P0）  | D2 首视觉行 gutter、hover/click、跨视觉行当前命中绘制        | 几何、实际绘制、命中范围和 continuation-only 场景通过        |
  | S2b（P0）  | D5 Reading Set 设置传递、动态宽高、行号与外层锚点；普通文本预览实时切换 | 多卡片重排、完整选区、末行可见、纯文本／Markdown 策略通过    |
  | S3（P1）   | D4 悬挂缩进、Tab 度量、宽度失效及全部投影入口；接入代码摘录  | 公式、Syntax formatting off、深缩进、折叠 chip 和缩放性能通过 |

  S0 先固定共享测量规则。S1 与 S2a 在内部几何接口明确后可并行；S2b 的视口恢复与行号最终集成依赖 S1／S2a 的契约。S3 依赖宽度更新和段落生命周期入口；Reading Set 可先完成基础换行，再由 S3 接入悬挂缩进。

  每片分别附测试和性能证据。先完成底层恢复与几何，再将菜单入口作为可交付能力验收，避免只有入口而阅读位置明显漂移的中间版本进入发布。

  ### 6.2 主要改动清单

  | 文件                                                         | 计划改动                                                     |
  | ------------------------------------------------------------ | ------------------------------------------------------------ |
  | `Sources/CodeInsightApp/CodeInsightApp.swift`                | 菜单 action／validation；self-test 入口及性能配置            |
  | `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`      | 设置变更分类、布局事务、首视觉行绘制与命中、查找强调框、投影段落步骤 |
  | ReaderUI 内部新文件                                          | 按 D6 拆出几何、视口状态与段落布局辅助逻辑                   |
  | `Sources/CodeInsightApp/ReadingSetView.swift`                | 显式布局设置、TextKit 2 代码视图、gutter、动态高度约束、外层锚点、重排合并 |
  | `Sources/CodeInsightApp/MainWindowController.swift`          | 普通文本／Markdown 预览策略与实时 apply；局部重排完成通知    |
  | `Sources/CodeInsightApp/ReaderSettingsWindowController.swift` | 设置双向同步和预览生命周期验证，必要的幂等处理               |
  | `Tests/CodeInsightReaderCoreTests/ReaderUITests.swift`       | 新几何、selection、anchor、段落与状态回归测试                |
  | App 现有 self-test 与测试辅助代码                            | 菜单、Reading Set、预览、多窗口及性能场景                    |

  实施时依据符号定位，并在提交中记录实际变更范围；本文不依赖会随改动漂移的源码行号。

  ### 6.3 每片验收记录

  建议写入 `docs/plans/evidence/reader-wrap-v2/`。每片记录：代码 SHA、测试命令与结果、fixture 哈希、macOS／SDK／机器信息、实际几何或性能 JSON、关键截图及遗留项。

  S0 的基线记录与候选实现记录分开命名。未运行项目标记 `not-run`，不填充估计的通过结果。

  ## 7. 测试与验收门禁

  ### 7.1 测试层次与观测值

  测试分为四层：可预测的几何／缩进计算、真实 TextKit 离屏布局、带窗口的交互与绘制、固定环境的性能验收。离屏布局通过不能代替实际点击、焦点或绘制检查。

  新增测试观测值从实际执行路径采集：

  | 观测值                                                       | 用途                                     |
  | ------------------------------------------------------------ | ---------------------------------------- |
  | 本轮实际绘制的 `rowRect`、`labelDrawPoint`、glyph baseline、marker rect | 验证绘制消费了正确坐标；每轮绘制清空旧值 |
  | fold hover／click 查询返回的 FoldID 与 hit rect              | 验证首行与续行边界                       |
  | 当前命中的实际绘制片段矩形及显示范围                         | 验证跨视觉行覆盖                         |
  | anchor 内容身份、偏移误差、clamp 原因、恢复次数              | 验证位置稳定及有限校正                   |
  | 完整 selection ranges、affinity 与复制文本                   | 验证范围和文本语义                       |
  | 有效 W、每段 headIndent、Tab 配置签名                        | 验证宽度失效和缩进约束                   |
  | 卡片 layout signature、测量次数、实际文本底边、高度约束数量  | 验证尺寸和重排收敛                       |
  | 请求／提交 generation 与过期回调计数                         | 验证快速切换和用户导航优先级             |

  预期值应来自独立的 fixture 定义、实际 TextKit 字符几何或截图。不得用同一个 helper 同时生成期望值与“实际值”，再以两者相等作为绘制正确的全部证据。

  ### 7.2 功能验收矩阵

  以下编号是新增测试用例的标识，不表示仓库中已经存在对应测试函数。

  #### A. 全局设置与生命周期

  | ID   | 场景                                            | 断言                                              |
  | ---- | ----------------------------------------------- | ------------------------------------------------- |
  | W01  | Settings 打开，用菜单切换，再用 Toggle 切换回来 | 菜单勾选、表单、预览和两个项目窗口一致            |
  | W02  | Settings／欢迎窗口为 key window                 | `⌥Z` 可执行；没有项目 target 也不错误禁用         |
  | W03  | 保存、重建设置实例、重新创建窗口／卡片          | key round-trip 一致；缺 key 时为 false            |
  | W04  | 隐藏 Reader、零尺寸 preview，之后显示           | 先应用最新设置，再按有效宽度布局                  |
  | W05  | 快速切换设置并关闭窗口或切换文档                | 旧 generation 不修改新文档，不访问已释放视图      |
  | W06  | 相同设置连续 apply                              | 没有多余全量投影与重排，无菜单／Settings 回写循环 |

  #### B. 视口、选区与导航

  | ID   | 场景                                               | 断言                                                         |
  | ---- | -------------------------------------------------- | ------------------------------------------------------------ |
  | W10  | 文档中部 off/on 连续往返 20 次                     | 同一个字符锚点持续有效，逐次位置误差和最终累计误差均在预算内 |
  | W11  | 非空选区、多范围选择、反向选择后切换               | ranges 与复制文本一致，Shift 扩展方向符合原选择              |
  | W12  | 阅读折成至少 20 个视觉行的逻辑行中部               | anchor 是原来的行内字符，切换后不会退化成行首                |
  | W13  | 水平滚动到长行中段后开启并关闭 wrap                | 按 D3.5 恢复合法 x，锚点保持可见                             |
  | W14  | 选择文本位于视口之外，用户已滚动到别处             | 重排跟随阅读锚点，不把视口拉回远处选区                       |
  | W15  | 字号、行高、声明字号、字体粗细、注释字体、行号切换 | 所有几何变化均保留 anchor 与 selection                       |
  | W16  | 窗口／分栏连续缩放，期间用户滚动或查找导航         | 请求合并；用户交互使旧恢复失效，不发生回拉                   |
  | W17  | 文档开头、结尾、短文档、空文档                     | clamp 合法且有原因；不把普通漂移伪装成边界限制               |
  | W18  | 中文、emoji、组合字符、CRLF、折叠 chip 锚点        | byte／UTF-16／显示位置往返正确；折叠状态和复制内容符合原模型 |
  | W19  | 查找框或 Settings 持有 first responder             | 重排后焦点不变；outline follow／history 只接收最终合理事件   |

  非边界场景的初始位置误差预算为 **2 个物理像素**，按实际 backing scale 转为 point。恢复次数上限为 3；超限失败并输出诊断。测试需同时检查单次误差与 20 次往返后的累计误差。

  #### C. gutter、文本装饰与可访问性

  | ID   | 场景                                            | 断言                                                         |
  | ---- | ----------------------------------------------- | ------------------------------------------------------------ |
  | W20  | 一行代码折为多个视觉行，启用全部 gutter 标记    | 行号和标记仅在首视觉行出现；diff 条限于首行高度              |
  | W21  | 首视觉行滚出，仅续行在视口内                    | 无首行专属装饰重画到续行，续行仍有正确当前行背景             |
  | W22  | 折叠列首行、续行、边界点 hover/click            | 返回正确 FoldID；续行无 hover／click；Option-click 原语义有效 |
  | W23  | 单次查找命中跨两行、三行或部分移出视口          | 每个可见命中片段均被描边，矩形没有错误拼成整块               |
  | W24  | 光标、普通 occurrence、不同字号、中文及双向文字 | 原生选择与自定义框均合法，零长度范围无伪造命中框             |
  | W25  | 1×／2× backing scale、不同字号与行高            | 文字 baseline 和标记位置按真实绘制验收，不依赖整块 rect 的隐式居中 |
  | W26  | 键盘与辅助功能读取菜单和文本选择                | Wrap 菜单 title／快捷键／state 正确，正文与 selection 仍可访问 |

  #### D. 悬挂缩进、Reading Set 与预览

  | ID   | 场景                                                      | 断言                                                   |
  | ---- | --------------------------------------------------------- | ------------------------------------------------------ |
  | W30  | 0、4、24、超过 24 列的空格缩进                            | 实际续行 x 满足公式；第一行前导空白正常显示            |
  | W31  | 明确 tab stops 下的 Tab／空格混合前缀                     | 前缀度量与实际首行排版一致，续行 clamp 正确            |
  | W32  | W 从 800pt 缩到 320pt 再恢复                              | 每次稳定布局后都满足当前 W 的 25% 上限                 |
  | W33  | Syntax formatting off、比例注释、放大声明字体             | 悬挂缩进独立生效，行高和其余段落样式保留               |
  | W34  | updateSyntax、fold/unfold、Focus／reading height 重新投影 | 段落样式未丢失；深缩进 chip 在续行时绘制和点击正确     |
  | W35  | Reading Set 多卡片变宽／变窄，最后一行带尾换行            | 高度按实际布局更新；末行可见，无卡片重叠或约束冲突     |
  | W36  | 正在阅读第三张卡片，前两张卡片因 wrap 变高                | 原卡片和卡片内字符维持视口偏移，完整 selection 保留    |
  | W37  | 卡片有省略行、较大源行号、空行                            | 按现有源行标签规则绘制；续行不重复，gutter 宽度足够    |
  | W38  | legacy／overlay scroller 与连续多次设置更新               | 高度包括实际占用；每卡片只有一个活动高度约束，布局收敛 |
  | W39  | 普通文本已打开后切换，再关闭重开                          | 两条路径 wrap 状态一致，横向滚动和 selection 正常      |
  | W40  | 同时打开普通文本与 Markdown                               | 普通文本跟随开关；Markdown 段落样式和预览规则正确      |

  ### 7.3 既有回归与真实窗口验收

  保留并运行 R4 已有的两条基础测试：

  ```text
  wrapProbeKeepsLogicalLineDecorationsUniqueInRealReaderTextView
  wrapSettingReversesEveryTextKitAndScrollerProperty
  ```

  它们继续验证逻辑行装饰唯一性及关键属性可逆性。涉及旧时序的尺寸断言如果需要适配，必须同时给出稳定布局后的正确尺寸断言和实际字符几何，不能仅删除失败项。[^TESTS]

  执行原方案指定的仓库门禁：

  ```sh
  swift test --disable-sandbox
  scripts/ci.sh
  scripts/run-gold-gates.sh
  ```

  扩展现有 `--self-test-reading`，覆盖菜单 AX、设置 round-trip、现有／新建阅读面、焦点和多窗口同步。上述执行入口来自原方案，实际结果随实现提交记录。[^ORIGINAL]

  真实窗口验收至少覆盖：Tokio 等代码仓库中的长行、Context、对比两列、Reading Set、普通文本和 Settings 预览。每组保留 off/on 对照，包含窄宽度、字号变化和首行已滚出的状态。折叠命中与用户打断恢复需要交互记录，不能只用静态截图代替。

  ### 7.4 性能入口与预算

  #### 7.4.1 单独测量 wrap 工作

  基线 `runFoldPerformance` 把 `settings.wrapLines` 固定为 false，并在有效性检查中要求 `!wrapLines`。输出中的 `perfConfig.wrapLines` 是观测值。其 `resolutionMs` 来自折叠解析 observer，不能表示 wrap 的重排与绘制延迟。[^APP]

  S0 增加显式 wrap 性能模式，建议新增 `--self-test-wrap`；也可扩展现有 runner，但必须按下列契约区分场景。以下参数是拟新增接口：

  ```text
  <cairn-executable> --self-test-wrap
      --fixture <path>
      --wrap <on|off>
      --scenario <initial|toggle|resize|reading-set>
      --output <path>
  ```

  runner 需报告 requested wrap 和实际 width tracking／scroller 状态，不得只把请求参数原样写回作为成功证据。保留 fold 性能场景原有的配置校验，并为 wrap 场景增加独立校验。

  #### 7.4.2 计时边界与输出

  | 指标                                  | 起止与含义                                                   |
  | ------------------------------------- | ------------------------------------------------------------ |
  | `toggleFirstFrameMs`                  | 从实际设置动作开始，到新设置下文字与装饰完成首次可见绘制；不包含首次文件读取和语法加载 |
  | `toggleSettledMs`                     | 从实际设置动作开始，到新宽度、selection、anchor 及装饰均满足本轮 generation 的稳定条件 |
  | `resizeStepMs`                        | 从一个合并后的有效宽度请求开始，到对应稳定布局和绘制完成     |
  | `longestMainThreadStallMs`            | 性能场景期间主线程连续阻塞的观测时长                         |
  | `peakPhysBytes`                       | 与现有 runner 一致的物理内存占用峰值；保留采样周期和原始数据，不能标成 RSS |
  | `reflowCount`／`paragraphUpdateCount` | 实际排版提交与更新段落数量，诊断重复工作                     |
  | `cardMeasureCount`                    | Reading Set 每卡片、每宽度代次实际测量次数                   |
  | `anchorErrorPt`／`restorePassCount`   | 同时验证性能过程没有牺牲位置正确性                           |

  布局完成必须由真实布局和绘制回调确认。不能在 `layoutViewport()` 返回时直接宣布首帧已经画完，也不能依赖固定 sleep 作为稳定条件。

  每份 JSON 记录：schema version、代码 SHA、fixture SHA-256、场景、请求及有效 wrap、字体实际名称与大小、有效 viewport 宽高、line height、gutter、fold 状态、scroller style、OS／SDK／机器、backing scale、每次样本和汇总统计。发生超时、配置不符、恢复超限或裁剪时输出明确失败状态。

  #### 7.4.3 Fixture 与对照方法

  | Fixture        | 固定特征                                                     | 测量目的                          |
  | -------------- | ------------------------------------------------------------ | --------------------------------- |
  | F1 普通大文件  | 约 3MiB；大量短行加一定比例长行；记录实际字节数、逻辑行数和最大行长度 | 常规切换与缩放                    |
  | F2 超长逻辑行  | 文件中部包含至少一条 512KiB 逻辑行，前后有正常上下文         | 行内 anchor、paragraph 级布局成本 |
  | F3 无空白长串  | 至少 1MiB 连续字符串，单独报告                               | 极端断行、内存和阻塞              |
  | F4 组合文本    | Tab、深缩进、中文、emoji、CRLF、注释与 fold chip             | 正确性与复杂排版                  |
  | F5 Reading Set | 固定 30 张卡片，每张 20 个逻辑行，其中包含两条约 2KiB 长行；另有省略行测试卡片 | 卡片完整布局及外层恢复            |

  以上是新增 fixture 的生成规格，落地后提交生成脚本／文件和实际哈希。使用固定种子，记录真实大小；F5 的省略行语义按当前摘录模型生成。

  在固定机器、OS、Release 构建和同一视口下，每种配置至少预热 5 次，再采集 30 次有效样本；切换双向分别统计 p50、p95、max。resize 使用固定的宽度序列和请求节奏，记录被合并的请求数量。

  对主 Reader，把同一测量程序的观测代码应用于基线，比较 base 与 candidate 在相同 off/on 配置下的结果。Reading Set 基线不支持 wrap on，该场景标记为 `unsupported`，按候选实现的绝对预算和 off/on 增量报告，不能填入虚构基线。

  #### 7.4.4 本版初始预算

  以下数值是本次提出的工程验收预算，尚无实测通过结论。S0 固定机器后将其写入验收配置；调整须附原始样本、原因和新的审阅记录。

  | 指标                              | 初始预算                                                     |
  | --------------------------------- | ------------------------------------------------------------ |
  | F1 普通文件 `toggleSettledMs`     | p95 ≤ 250ms；同时不超过 `max(baseP95 × 1.5, baseP95 + 15ms)` |
  | F1 合并后 `resizeStepMs`          | p95 ≤ 33ms；连续主线程阻塞 max ≤ 100ms                       |
  | F2／F3 极端文本 `toggleSettledMs` | p95 ≤ 1500ms，单独报告，不并入普通文件均值                   |
  | F5 Reading Set `toggleSettledMs`  | p95 ≤ 250ms；所有卡片最终高度及外层 anchor 正确              |
  | 同配置内存增量                    | candidate 峰值 ≤ `max(basePeak × 1.3, basePeak + 32MiB)`；无对应基线时单独记录 off/on 增量 |
  | 连续往返操作                      | 100 次后无持续增长的 constraint／observer／缓存条目；释放阅读面后的占用在同环境观测中可回落 |
  | 每轮收敛                          | 普通 Reader 恢复最多 3 次；卡片每个有效布局签名只提交一次完整测量 |

  如果基线本身超过绝对预算，要先记录现有成本并区分本次增量；该场景仍是明确的待解决性能项，不以“基线也慢”标记为通过。不得通过改变 fixture、视口或关闭装饰来绕过失败。

  ## 8. 风险与处理

  | 风险                                    | 处理与验证                                                   |
  | --------------------------------------- | ------------------------------------------------------------ |
  | 坐标遗漏或重复叠加 inset                | 单一转换 helper；测试有 gutter／无 gutter、横向滚动、不同 scale，独立核对实际字符位置 |
  | 把 TextKit 局部 range 当全文 offset     | 封装 fragment／element 到全文转换；UTF-8／UTF-16 与占位符 round-trip 测试 |
  | 重排被 selection／viewport 回调打断     | 实例级事务保护，generation 使过期任务失效，最终状态只发布一次 |
  | 连续切换重新选择锚点造成漂移            | 同一纯重排序列复用稳定字符锚点；显式用户交互重建状态         |
  | 容器宽度在 gutter／scroller tile 后变化 | 读取实际有效宽度，合并一次后续校正；防止重复扣宽度           |
  | 深缩进或 Tab 在不同状态下错位           | 同一段落 Tab 配置、缓存实际前缀度量、宽度变化后重算 clamp    |
  | 段落样式覆盖行高或在某条投影路径丢失    | 从基础样式复制，集中投影步骤；遍历所有 `project` 调用点验收  |
  | Reading Set 高度循环、卡片裁剪          | 单个高度约束、布局签名和测量次数；末行、尾换行与两种 scroller style 测试 |
  | 首行滚出后的 gutter 命中残留            | 按首行矩形判断可见性；滚动与重排后清理 hover                 |
  | 跨行命中绘制只画首段                    | 查询全部可见 segment，测试部分移出视口及长命中范围           |
  | fold chip 移至续行                      | 使用 attachment 实际几何，FoldID 关联保持一致，源 header 的 gutter 独立定位 |
  | 极端单行破坏性能预算                    | 单列 fixture 与指标；明确失败，不将 paragraph 布局成本假定为恒定 |
  | 隐藏阅读面或窗口关闭后回调继续执行      | weak 生命周期引用、内容身份和 generation 检查；关闭与重开压力测试 |

  ### 8.1 技术验证点

  S0／各实施切片必须验证目标部署版本上的以下行为：TextKit 2 的局部位置转换、绘制回调的计时点、反向选择恢复、尺寸变化前捕获旧几何，以及包含 attachment 的可见行边界。本文规定行为和测试，具体 SDK API 的调用组合以目标 macOS 实测为准。

  如果某条恢复路径暂时无法取得有效几何，应保留合法 selection 和最新设置，等待正常布局生命周期恢复，并输出原因。不得以强制跳转到文件顶部作为通用 fallback。

  ## 9. 评审意见对照与完成定义

  ### 9.1 修订对照

  | 上轮评审问题                                     | 本文落实位置         |
  | ------------------------------------------------ | -------------------- |
  | 全局菜单不应受项目 target 限制                   | D1.1、W02            |
  | 行号垂直居中假设缺少依据；坐标转换遗漏 inset     | D2.1–D2.2、W20／W25  |
  | hover 与 click 是不同路径                        | D2.3、W22            |
  | 当前查找命中只画一个 firstRect                   | D2.4、W23            |
  | follow anchor 与 restore 语义不匹配，选区被折叠  | D3.1–D3.4、W10–W14   |
  | 捕获时机晚于 configureWrapping                   | D3.6–D3.7            |
  | 宽度 25% clamp 不会自动更新                      | D4.2–D4.5、W32       |
  | Syntax formatting 开关会误伤缩进；Tab 未定义     | D4.1／D4.4、W31／W33 |
  | Reading Set 丢失 wrap 状态，宽高仍依赖不换行模型 | D5.1–D5.4、W35／W38  |
  | Reading Set 缺少外层阅读锚点                     | D5.5、W36            |
  | 普通文本与 Markdown 共用预览入口，实时更新缺失   | D5.6、W39–W40        |
  | 性能入口固定 wrap off，resolutionMs 不测排版     | §7.4                 |
  | 属性断言不能证明实际绘制和阅读稳定               | §7.1–§7.3            |

  ### 9.2 完成定义

  当 S1、S2a、S2b、S3 的实现与各自门禁通过，既有仓库门禁全绿，真实窗口与性能证据归档，且已知失败项得到明确处理后，将状态改为“实施完成”。

  提交说明应列出实际支持的阅读面、对应测试编号、数据与截图位置。当前这份文档的状态为“待实施与验收”。

  ## 10. 依据与参考

  源码引用固定到同一提交。Apple 文档用于确认 API 语义；本方案新增的产品行为、内部类型、切片和性能预算见 §5.2，不属于外部资料中的既有结论。

  [^ORIGINAL]: 用户提供的 `2026-09-19-reader-wrap-design.md`，2026-09-19 版。本文据其目标、G1–G5／D1–D5 结构、§5 四项裁决及原有验收要求修订。
  [^BASE]: [Cairn 基线提交 `7666dcb0079e5dfab88342c5dac826307332f542`](https://github.com/sonald/cairn/commit/7666dcb0079e5dfab88342c5dac826307332f542)。
  [^SETTINGS]: [ReaderSettings.swift](https://github.com/sonald/cairn/blob/7666dcb0079e5dfab88342c5dac826307332f542/Sources/CodeInsightReaderCore/ReaderSettings.swift)，`ReaderSettings`、`ReaderTheme`。
  [^SETTINGS_UI]: [ReaderSettingsWindowController.swift](https://github.com/sonald/cairn/blob/7666dcb0079e5dfab88342c5dac826307332f542/Sources/CodeInsightApp/ReaderSettingsWindowController.swift)，Reader 设置表单与预览生命周期。
  [^READER]: [CodeInsightReaderUI.swift](https://github.com/sonald/cairn/blob/7666dcb0079e5dfab88342c5dac826307332f542/Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift)，`ReaderTextView` 初始化、`apply(settings:)`、`restore`、`followAnchorByteOffset`、`drawRuler`、`drawPrimarySelection`、`configureWrapping`、`project`、`applyTypography`。
  [^APP]: [CodeInsightApp.swift](https://github.com/sonald/cairn/blob/7666dcb0079e5dfab88342c5dac826307332f542/Sources/CodeInsightApp/CodeInsightApp.swift)，`commitReaderSettings`、菜单验证与 `runFoldPerformance`。
  [^WINDOW]: [MainWindowController.swift](https://github.com/sonald/cairn/blob/7666dcb0079e5dfab88342c5dac826307332f542/Sources/CodeInsightApp/MainWindowController.swift)，设置传播、Reader controller、普通文本／Markdown 预览。
  [^READING_SET]: [ReadingSetView.swift](https://github.com/sonald/cairn/blob/7666dcb0079e5dfab88342c5dac826307332f542/Sources/CodeInsightApp/ReadingSetView.swift)，`ReadingSetView` 与 `ReadingSetExcerptView`。
  [^TESTS]: [ReaderUITests.swift](https://github.com/sonald/cairn/blob/7666dcb0079e5dfab88342c5dac826307332f542/Tests/CodeInsightReaderCoreTests/ReaderUITests.swift)，两条既有 wrap 测试。
  [^LINE_FRAGMENT]: Apple，[NSTextLineFragment.typographicBounds](https://developer.apple.com/documentation/appkit/nstextlinefragment/typographicbounds)，及该页对 `characterRange`／`attributedString` 的定义。视觉行矩形的原点相对于所属 layout fragment 的行片段组。
  [^CONTAINER_ORIGIN]: Apple，[NSTextView.textContainerOrigin](https://developer.apple.com/documentation/appkit/nstextview/textcontainerorigin)。该原点根据 view bounds、container inset 和 used rect 计算。
  [^FIRST_RECT]: Apple，[firstRect(forCharacterRange:actualRange:)](https://developer.apple.com/documentation/appkit/nstextinputclient/firstrect%28forcharacterrange%3Aactualrange%3A%29)。跨行范围只返回第一行矩形；返回坐标为屏幕坐标，`actualRange` 用于继续查询。
  [^TEXT_SEGMENTS]: Apple，[NSTextLayoutManager.textSelections](https://developer.apple.com/documentation/appkit/nstextlayoutmanager/textselections) 同页列出的 `enumerateTextSegments(in:type:options:using:)`，以及 [AppKit 文本范围几何示例说明](https://developer.apple.com/documentation/appkit/nswritingtoolscoordinator/delegate-swift.protocol/writingtoolscoordinator%28_%3Arequestsunderlinepathsfor%3Ain%3Acompletion%3A%29)。
  [^HEAD_INDENT]: Apple，[NSParagraphStyle.headIndent](https://developer.apple.com/documentation/appkit/nsparagraphstyle/headindent)。非首行起点相对文本容器前缘的距离，单位为 point。
  [^TAB_INTERVAL]: Apple，[NSMutableParagraphStyle.defaultTabInterval](https://developer.apple.com/documentation/appkit/nsmutableparagraphstyle/defaulttabinterval)。默认 Tab 间距使用 point，与 `tabStops` 共同生效。
  [^TEXTKIT]: Apple，[TextKit](https://developer.apple.com/documentation/appkit/textkit)。`NSTextView` 中现代与旧布局引擎的访问入口分别为 `textLayoutManager` 与 `layoutManager`。
