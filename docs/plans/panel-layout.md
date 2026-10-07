# 面板布局：可拖动面板（需求与实施计划）

状态：待实现。2026-10-07 定稿需求；Fable 负责需求、原型与验收，Opus 5.5 (high) 负责实现。完成后把仍有效的结论归入 [product.md](../product.md) 与 [architecture.md](../architecture.md)，删除本文件。

原型：`~/work/ai/vibecoding/codeinsight-prototypes`（`swift run LayoutPrototype`，README 有结论和实拖发现的坑）。原型是一次性代码，只用来对照行为和手感，不要整段搬进产品。

## 1. 目标行为

### 面板与区域

- 面板：**文件、大纲、关系、上下文、搜索结果**五个，外加预留的 **文档**（本计划只建面板 ID，默认隐藏、默认在右侧最下；在"视图 → 面板"里不出现，内容和入口由后续"文档面板"任务接入）。阅读区（含分屏/比较）、阅读轨迹条、状态栏不是面板，不参与移动。
- 区域只有**左、右两侧**。同一侧的面板**上下堆叠**，各自可拖分隔条调高度。没有底部区域、没有标签页、没有浮动窗口。
- 每个面板有统一的标题栏：标题、`⋯` 菜单、`×` 关闭。`⋯` 菜单项：移到左侧 / 移到右侧 / 上移 / 下移 / 关闭（当前位置不可用的项置灰）。
- 一侧没有可见面板时该侧收起，阅读区占满；拖动进行中空侧显示 72pt 宽的"放到这里"落区，拖动结束后若仍为空再收起。

### 移动

- 拖面板标题栏可以放到任一侧的任意位置。拖动影像只有标题栏，贴着鼠标；目标侧显示一条强调色指示线，鼠标在某面板上半部分表示放到它前面，下半部分表示放到它后面，空白处表示放到末尾。
- `⋯` 菜单的四个移动命令和拖动改的是同一份布局，是键盘/自动化可达的等价路径。

### 显示与隐藏

- "视图 → 面板"子菜单列出全部面板，勾选表示可见。现有命令保留并指向同一开关：关系（`⌃⌘R`）、显示/隐藏搜索结果；新增文件、大纲、上下文、文档的切换命令（默认无快捷键，可在快捷键设置里绑定）。状态栏的 Context 按钮仍是上下文面板的开关。
- 上下文面板有三种状态，用 `hidden` 集合表达：**不在 `hidden` 里 = 跟随自动规则**（光标处有可显示内容时出现，没有时收起，即现在的 `updateContextVisibility`）；**在 `hidden` 里 = 用户已关闭**，不再自动出现，直到用户显式打开或切换预设。`×`、菜单取消勾选、状态栏按钮关闭都是"加入 `hidden`"；菜单勾选、按钮打开是"移出 `hidden`"并立即显示。菜单勾选状态反映有效可见性。现在的 `contextVisibilityOverride` 和 `Cairn.contextVisible` 由此替代。`⇧⌘F` 显示搜索结果面板并聚焦输入；搜索结果面板可见时阅读区画命中下划线；关闭它时提交查询历史。这些都是现有行为，只是载体从底部坞变成面板。
- 预设 `⌘1`–`⌘4` 退化为**显示组合**，不再改变放置和宽度。组合：阅读 = 文件、大纲，上下文跟随自动规则；关系 = 文件、大纲、关系，上下文自动；比较 = 文件 + 打开分屏，上下文自动；专注 = 全部隐藏，上下文也进入 `hidden`（保持现在"专注下不自动显示"的行为）。切换预设后仍然可以单独开关面板。
- "视图 → 恢复默认布局"把放置、宽度、高度、显示状态全部恢复为默认：左侧 文件、大纲；右侧 关系、上下文、搜索结果、（文档）；左 240pt、右 300pt；关系、搜索结果、文档隐藏，上下文跟随自动规则（与现在的"阅读"预设一致）。

### 临时覆盖（不写回布局）

- 阅读集打开时隐藏全部面板，离开后恢复到之前状态。
- 分屏打开且两侧都显示时放不下（两侧各 320pt 阅读区 + 侧区），暂时隐藏两侧区域，关闭分屏恢复。
- 非源码预览：大纲、关系、上下文、搜索结果、文档暂时隐藏，文件保留；回到源码恢复。
- 没有项目：全部面板隐藏。
- 这几条是叠在持久布局之上的临时覆盖，不得把覆盖期间的状态写进持久布局。

### 删除的行为

- 关系面板打开时自动折叠侧栏、关系面板宽度上限（`openRelationsPane`、`capRelationsPane`、`updateRelationsWidthAdaptation`、`sidebarTemporarilyCollapsedForRelations`）整个删除。
- 宽度规则：阅读区 320pt 是硬最小值（现有）；每侧的最小宽度 = 该侧可见面板最小宽度的最大值（关系 300、搜索结果 300、其余 180），但作为**软**约束实现（holding priority / 分隔条限制），不是 required constraint——现有注释（`MainWindowController.swift` 约 290 行）已说明硬最小值会让窗口自动变大而不是压缩面板。窗口放不下时侧区被压到更窄，仍然不允许为了排版自动放大窗口。
- 底部查询坞及其标签切换（`configureQueryDock`、`renderBottomTab`、`selectBottomTab`、`selectedBottomTab`、`bottomTab`）删除。
- 文件/大纲各自的折叠按钮和 `CodeInsightSidebarSplit.*` 默认值删除；两者变成两个独立面板后，用面板的关闭/显示代替。
- 按预设分别保存的 `Cairn.panelLayout.<preset>`、`Cairn.contextVisible` 不再读取、不迁移。首次启动新版本使用默认布局。

### 持久化

- 应用全局一份布局，不按项目、不按预设。建议 UserDefaults 键 `Cairn.panelLayout.v2`，JSON：
  ```json
  {"zones": {"left": ["files","outline"], "right": ["relations","context","search","docs"]},
   "hidden": ["search","docs","relations"],
   "zoneWidths": {"left": 240, "right": 300},
   "panelHeights": {"left": [0.55, 0.45], "right": [0.5, 0.25, 0.25, 0]},
   "readerSplitFraction": 0.5}
  ```
  解码时：未知面板 ID 丢弃，缺失的面板补到默认位置末尾，每个面板恰好出现一次，宽度/比例非有限值回默认。坏数据整体回默认，不崩溃。
- 分屏/比较不属于面板：是否打开分屏由 `model.referencePane` / `model.compare` 决定（现在也是），布局只保存分隔条比例 `readerSplitFraction`（替代旧的 `secondaryReaderFraction`；旧 `readerSplit` 标志不再需要）。关闭比较只关分屏，不改变面板可见性（替代现在"比较关闭后回到阅读预设"）。打开分屏放不下时，作为第四种临时覆盖暂时隐藏两侧区域（规则同阅读集/非源码，不写回），关闭分屏恢复；两侧隐藏后仍放不下才提示窗口太窄。
- 会话文件里的 `panelPreset` 字段保留（四个 rawValue 不变），含义是"最后选择的预设"，恢复会话时只用它决定显示组合，不再从它推导放置。

## 2. 现状与受影响代码

- 窗口由四层 `NSSplitViewController` 组成：`outer`（侧栏 | 工作区）→ `content`（上 | 底部查询坞）→ `upper`（阅读组 | 关系）→ `readerSplit`（主 | 参考）。见 [MainWindowController.swift:72](../../Sources/CodeInsightApp/MainWindowController.swift#L72) 起和 [:255](../../Sources/CodeInsightApp/MainWindowController.swift#L255) 起。
- 布局描述 [`PanelLayoutDescription`](../../Sources/CodeInsightAppModel/PanelPresetModel.swift) 是写死字段的结构（5 个折叠标志 + 4 个比例 + `bottomTab`），`PanelPresetModel.layout` 给出每个预设的完整布局。读写在 `currentPanelLayout` / `applyPanelLayout` / `savePanelLayout` / `restoredPanelLayout`（约 [:2545](../../Sources/CodeInsightApp/MainWindowController.swift#L2545)–2660）。
- 预设应用与表面切换：`applyPanelPreset`、`updateContentSurfaceIfNeeded`、`savedSourceSurfaceLayout`；阅读集强制专注布局在 `render()` 约 [:3097](../../Sources/CodeInsightApp/MainWindowController.swift#L3097)。
- 上下文自动显示：`updateContextVisibility`、`contextVisibilityOverride`、`toggleContext`（约 [:2106](../../Sources/CodeInsightApp/MainWindowController.swift#L2106)）。搜索：`showProjectSearch`、`toggleProjectSearchResults`、`refreshProjectSearchHits`（约 [:2018](../../Sources/CodeInsightApp/MainWindowController.swift#L2018)）。
- 侧栏 [SidebarViewController.swift](../../Sources/CodeInsightApp/SidebarViewController.swift)：一个控制器内含文件和大纲两段、自己的 `NSSplitView`、段头折叠按钮和 `setOutlineHidden`。
- 关系面板 [RelationWindowController.swift](../../Sources/CodeInsightApp/RelationWindowController.swift)、上下文 [ContextWindowViewController.swift](../../Sources/CodeInsightApp/ContextWindowViewController.swift)、搜索 [SearchPanel.swift](../../Sources/CodeInsightApp/SearchPanel.swift) 都是 `NSViewController`，可以直接装进面板。
- 菜单与命令：视图菜单在 [CodeInsightApp.swift:2164](../../Sources/CodeInsightApp/CodeInsightApp.swift#L2164) 起；命令 ID、默认键和本地化文案按 `viewPresetReading`、`relationsToggle`、`toggleProjectSearchResults` 的现有模式添加。
- 引用旧布局类型的测试：`Tests/CodeInsightAppTests/MainWindowControllerTests.swift`（`applyPanelPreset`、`Cairn.panelLayout.reading` 解码）、`RelationNavigationTests.swift`、`ReaderLigaturePropagationTests.swift`，以及 `CodeInsightAppModelTests` 里涉及 `panelPreset` 的会话测试。`Sources/CodeInsightApp/SelfTest/*` 里的 `contextVisible*` 是 self-test 自己的变量名，不是布局键。

## 3. 设计约束

- 新模型放在 `CodeInsightAppModel`：`PanelID`（`files`、`outline`、`relations`、`context`、`search`、`docs`）、`PanelZone`（`left`、`right`）、`PanelLayout`（上面的 JSON 结构）及其纯函数：`move(_:to:at:)`、`shift(_:by:)`、`setVisible`、`visible(in:)`、`standard`、解码校验。原型里的同名实现可作参照。`PanelLayoutDescription` 删除；`PanelPresetModel` 只剩 `visiblePanels: Set<PanelID>` 和 `opensReaderSplit`。
- 视图层放在 `CodeInsightApp`：一个面板外壳（标题栏 + 内容容器，作为拖动源）、一个区域视图（竖向 `NSSplitView`，作为放置目标）。主窗口的 outer split 变为 `[左区 | 阅读组 | 右区]`，`readerSplitController` 原样保留在中间。
- 五个现有控制器各装进一个面板外壳；文件和大纲拆成两个独立的 `NSViewController`。`SidebarViewController` 的数据逻辑（文件树、大纲模型、选择同步、项目状态占位）可以保留在一处，但两个面板必须各有自己的标题栏、各自可移动。
- 临时覆盖实现为"有效可见集 = 持久 `hidden` 之外再减去覆盖隐藏的面板"，覆盖存在期间 `savePanelLayout` 不写入；不要用保存/恢复整份布局的方式实现覆盖。
- 拖动用 `NSDraggingSession` + 自定义 pasteboard 类型（如 `dev.cairn.panel`），不用全局鼠标跟踪。原型实拖发现并修掉的四个坑，实现时直接带上：
  1. `NSSplitView` 是翻转坐标。落点索引和指示线必须在区域 split view 的坐标系里算（上半部→前面），否则指示线和鼠标对不上。
  2. 拖动影像只用标题栏并以标题栏的 frame 为拖动 frame；整面板影像又大又不贴手。
  3. 拖动开始时只显示空侧落区，不重建面板；重建会让高度在拖的过程中重排。只有面板列表真的变化的那一侧才重建。
  4. 设置右侧分隔条位置时减去 `dividerThickness`，否则每次操作右侧少 1pt。
- 区域内面板的最小高度沿用现在的值：上下文 120pt、搜索结果 240pt，其余 80pt；文档面板首次显示占所在侧 40% 高度。
- 布局保存时机与现在相同：分隔条拖动结束、面板移动/开关、窗口关闭；覆盖期间和阅读集期间不保存。
- 多窗口：每个项目窗口读写同一份全局布局；某窗口改动后其他已开窗口不必实时同步，下次打开窗口时读取即可。
- 分支与提交：在 `feat/panel-layout` 分支上做，不直接改 `main`；每个实施步骤一个或几个提交，提交信息用英文、几句话说清做了什么；验收前 rebase 到最新 `main`（线性历史，不用 merge）。

## 4. 实施顺序

每步结束都要能 `swift build` 并通过该步的测试。

1. **模型**：`PanelLayout` 及纯函数、解码校验；`PanelPresetModel` 改为显示组合。属性测试见 §5。
2. **面板外壳与区域视图**：标题栏、`⋯` 菜单、`×`、拖动源、放置目标、指示线、空侧落区。先用占位内容在主窗口里跑通拖动和菜单移动。
3. **接入现有面板**：关系、上下文、搜索装入外壳；删除底部查询坞；上下文自动显示、搜索显示/聚焦/下划线/提交历史改写到新的可见集上。
4. **拆侧栏**：文件、大纲成为两个面板；删除段头折叠按钮和 `CodeInsightSidebarSplit.*`。
5. **菜单、命令、状态栏**："视图 → 面板"子菜单、新命令 ID 与中英文文案、预设改显示组合、"恢复默认布局"、状态栏 Context 按钮。
6. **删除旧逻辑**：关系折叠侧栏与宽度上限、旧布局键、`PanelLayoutDescription`；更新引用它们的测试和 self-test（`SelfTest/SessionSelfTest.swift`、`LanguageSelfTest.swift`、`SelfTestLaunch.swift` 里用 `CodeInsightSidebarSplit` 作 autosave 名的地方一并处理）；`docs/architecture.md` 第 83 行附近"布局的可选 `bottomTab` 向后兼容"删除。
7. **文档**：`product.md` 第 30 行"文件和大纲可分别收起…Context 按钮控制底部预览"、预设相关描述、"搜索区域首次展开约为 360pt…"一段中关于停靠区的部分、分屏一节"放不下先收起侧栏"改为新规则；`architecture.md` 加一段布局模型与覆盖规则。

## 5. 验证

按 [AGENTS.md](../../AGENTS.md) 的表选择：

| 机制 | 验证 |
| --- | --- |
| `PanelLayout` 的 move/shift/setVisible/解码 | 属性测试：随机操作序列后每个面板恰好出现一次、`hidden` 只含已知 ID、宽度比例有限；坏 JSON（未知 ID、缺面板、NaN、空区域）回默认。固定种子。 |
| 布局持久化、预设→显示组合、临时覆盖不写回 | 少量集成测试（改写 `MainWindowControllerTests` 里现有的布局保存/预设用例）：移动面板后重建窗口控制器读回同一布局；进入非源码预览/阅读集期间保存不改变持久布局；预设只改可见集。 |
| 拖动、菜单移动、指示线、空侧落区、`×`、视图菜单勾选、恢复默认、状态栏按钮 | 打包应用端到端。 |

端到端流程（打包 `Cairn.app`，用一个 Python 或 Rust 项目）：

1. 默认布局与现在的"阅读"预设等价：左侧文件/大纲，右侧为空收起。
2. `⌃⌘R` 打开关系面板出现在右侧；`⋯ → 移到左侧` 落到左侧末尾；拖其标题栏到文件上半部，落到左侧第一位，指示线位置与鼠标一致。
3. 把左侧全部面板移到右侧，左侧收起、阅读区占满；拖动开始时左侧出现"放到这里"，放入后左侧重新展开。
4. 调整两侧宽度和面板高度，重开应用后保持；`⌘1`–`⌘4` 只改变可见面板，不改放置。
5. 光标停在符号上，上下文面板自动出现在它被放置的位置；`×` 关闭后不再自动出现；状态栏 Context 按钮重新打开。
6. `⇧⌘F` 显示搜索结果面板并聚焦，结果下划线出现；关闭面板后下划线消失。
7. 打开阅读集全部面板隐藏，关闭后恢复；打开非源码文件只剩文件面板，回到源码恢复。
8. "恢复默认布局"回到第 1 步状态。
9. 深色与浅色主题下标题栏、指示线、落区可见。

自动化边界：`视图 → 面板` 勾选和预设可以用 computer-use 的 `app_menu` 在后台执行；面板 `⋯` 菜单和拖动需要接管屏幕（本会话已有先例）或人工操作。做不到的流程标 BLOCKED，不用模型测试充当 PASS。记录构建、输入、步骤、截图。

## 6. 验收标准

- §1 的每一条行为在打包应用中按 §5 的流程实测，结果逐条记为 PASS / FAIL / BLOCKED。
- §1"删除的行为"列出的代码和默认值在源码中不再存在。
- 相关测试（`swift test --filter PanelLayout`、`MainWindowController`、`RelationNavigation`、`SessionCodec`、`SessionRestore`）通过；`bash scripts/ci.sh static` 通过（本地化双语键、模块边界）。
- `product.md`、`architecture.md` 描述的是实现后的行为，不含底部坞、关系折叠侧栏和按预设保存布局的说法。
