# Cairn 恢复阅读现场设计方案

状态：已实现（2026-09-15）。验收记录：`2026-09-15-reading-session-restore-acceptance.md`。

日期：2026-09-15。代码基线：`d8ac506`。

## 1. 目标与结论

用户关闭 Cairn、关闭项目窗口或切到另一个项目后，再次打开该项目，能够接着上次阅读：标签顺序不变，当前文件回到原来的函数和阅读位置，阅读轨迹的分支仍在，前进/后退继续有效。

实现方向是扩展现有 SessionCodec、AppModel 和 Reader 状态采集链路。复用现有 JSON 原子写入、位置锚点、导航回放与项目 generation 检查，不另建会话服务、数据库、事件日志或通用状态框架。

这不是从零实现：现有代码已经支持最后一个项目的标签和位置恢复。主要增量是**按项目保存、保存完整导航状态，以及可靠的保存/恢复生命周期**。

## 2. 现状：已有能力与缺口

以下为当前源码检查结果；风险项尚未通过本次运行复现。历史验收记录不能代替本功能验收。

| 范围 | 当前行为 | 本次处理 |
|---|---|---|
| 自动重启恢复 | `CodeInsightApp.launch` 加载一个 session，并调用控制器恢复 | 保留自动打开最后项目；增加按项目读取 |
| 存储 | `AppModel.defaultSessionURL` 指向 Application Support/Cairn/<bundle>/session.json | 改为每个项目一份快照，保留最后项目指针 |
| 源码标签 | 已存文件路径、ContentID、scroll/selection 两个 Anchor | 复用，补预览标签语义与淘汰顺序 |
| 当前函数/位置 | Anchor 已有 byteOffset、line、column、symbolAnchor；恢复复用 `replayOffset` | 保持选择位置和视口分别恢复，明确降级反馈 |
| Reading Set | 已保存标题、冻结片段、证据、跳过原因、滚动位置 | 保持现有 50 片段上限和标签生命周期 |
| Reading Trail | 节点、边、当前节点存在内存；界面写明 this session only | 保存分支结构、当前节点、当时证据的可读快照 |
| Back/Forward | `NavigationHistory` 有 records、cursor、私有 forwardRecord，最多 200 条 | 三者一起保存，不能仅保存 records |
| 面板与偏好 | session 有 panelPreset；尺寸、窗口和部分侧栏状态另有持久化 | 沿用现有机制，避免复制完整布局系统 |
| 手动打开项目 | 控制器直接 openProject，模型清空 tabs/history/Trail | 统一先保存旧项目、再加载目标项目快照 |
| 退出/关窗 | WillTerminate 同步保存；最后窗口关闭会触发退出 | 保留；关闭时显式 flush，避免依赖间接调用顺序 |
| 自动保存 | 250ms 防抖，并检查 generation/languages | 增加恢复期间写入抑制及有界持续保存 |
| 读取失败 | 损坏、版本不支持、目录不存在均删除 session | 分类处理，离线和新版本数据必须保留 |
| 写入失败 | 多处 try?，用户无反馈 | 非阻塞提示，保留旧数据，下次触发重试 |

### 2.1 源码定位

- `Sources/CodeInsightAppModel/SessionCodec.swift:4`：Snapshot、FileTab、Anchor、v1/v2 编解码及校验。
- `Sources/CodeInsightAppModel/AppModel.swift:686`：默认路径；697 自动保存；723 加载；760 写入；782 快照采集。
- `Sources/CodeInsightAppModel/AppModel.swift:836`：beginWorkspaceOpen 清空项目状态；928 restoreSession；1151 resolveSessionFile。
- `Sources/CodeInsightAppModel/AppModel.swift:3480`：当前回放顺序是精确字节 → 无 ContentID 时未验证字节 → 行列 → 唯一同名符号 → 文件头；它尚不满足“代码前移后优先回到原函数”的目标。
- `Sources/CodeInsightAppModel/NavigationHistory.swift:594`：JumpRecord；695 ReadingTrail；755 NavigationHistory。
- `Sources/CodeInsightAppModel/AppModel.swift:2624`：Restore Trail；3327 附近的 replay 依赖进程内 snapshotDestinations。
- `Sources/CodeInsightApp/MainWindowController.swift:603`：项目打开入口；657 恢复；3215 采集位置；3253 同步 checkpoint。
- `Sources/CodeInsightApp/MainWindowController.swift:414`：Reader 滚动、选中、文档变化回调。
- `Sources/CodeInsightApp/CodeInsightApp.swift:546`：退出保存；9337 启动恢复；9449 最后窗口关闭即退出。
- `Tests/CodeInsightAppModelTests/SessionRestoreTests.swift`、`SessionCodecTests.swift`：已有版本、语言、位置、缺失文件及旧恢复取消测试。

### 2.2 必须更新的旧约定

`docs/plans/2026-09-05-reliability-and-reading-ui-plan.md` §3 与 M10/M11 方案规定 Trail 为 session-only。本需求明确提出跨次恢复阅读轨迹，因此本方案提议替代这一边界。实现后更新当前产品说明和空态文案；历史计划和验收记录保留其当时结论。

Reading Set 仍是冻结的源码/证据集合；Trail 仍是走过的导航路径。两者不合并，也不把 Trail 自动转换为 Reading Set。

## 3. 用户体验与恢复范围

### 3.1 必须满足的主流程

1. 用户在项目 A 打开若干标签，沿函数 A→B，后退到 A，再跳到 C，形成兄弟分支。
2. 当前停留在 C 函数内部，关闭应用或打开项目 B。
3. 从 Open Project、最近项目或拖入目录重新打开 A。
4. 按原顺序显示标签，选中 C 所在标签，回到该函数内部；Trail 保留 A→B 与 A→C，当前节点仍是 C。
5. Back/Forward 的可用性与关闭前相同；点击旧 Trail 节点可以回放，并在源码变化时提示定位降级。

正常恢复不弹确认框；状态栏只在加载中显示“正在恢复阅读现场…”。部分失败时显示一次汇总，例如“已恢复 4 个标签；1 个文件不可用，2 处位置已调整”。可查看文件和原因，不逐项弹窗。

### 3.2 状态清单

| 状态 | 首版契约 |
|---|---|
| 项目与语言组合 | 按项目恢复；显式 Choose Languages 优先于保存值，不能被恢复覆盖 |
| 版本 | 恢复已保存的完整 commit SHA；工作区则读取当前工作区，不承诺保存旧的未提交源码 |
| 标签 | 保存内容、顺序、活动标签、preview 标记、相对 LRU 顺序；沿用最多 10 个标签 |
| 源码视口 | 保存顶部源码锚点，恢复到对应行；不承诺窗口/字体改变后像素完全一致 |
| 当前函数 | 从当前文档及位置锚点重建 Outline/scope；不保存可能过时的函数对象 |
| 选择位置 | 首版保留现有 caret/selection 起点，不宣称恢复完整拖选范围 |
| 阅读轨迹 | 分支、节点、导航原因、活动节点、历史证据显示；限额见 §8 |
| 前进/后退 | 完整恢复 records、cursor、forwardRecord，以及与 Trail 节点的关联 |
| Reading Set | 保持冻结内容及滚动；关闭或被淘汰后从下一份快照移除 |
| 面板 preset、字体和主题 | 复用原有保存；字体/主题仍是全局偏好 |
| 目录树、面板宽度 | 沿用现有保存策略，不承诺首版所有布局按项目隔离 |
| Reading Height、手动折叠、Focus | 作为后续独立增强，不包含在首版“完全恢复”的声明中 |
| Context Pin、Relations/Inspector、Compare | 首版不恢复旧查询结果；根据当前代码重新查询，不恢复运行任务 |
| Markdown/PDF 等预览 | 恢复标签；预览内部滚动/页码首版不承诺，沿用现有能力 |

上述首版覆盖用户明确列出的函数、标签和轨迹。若产品使用“完整现场”措辞，必须等 §11 增强项完成，不能把范围外状态包装成已恢复。

不增加命名会话、多个存档槽、云同步或无限历史。提供一个“清除本项目阅读现场”动作即可：清除恢复数据与内存导航状态、关闭当前标签并写入空快照，防止退出时旧状态重新写回；不删除源码、书签或全局设置。动作需在界面说明会关闭标签及丢弃标签内 Reading Set。

## 4. 保存位置与项目身份

### 4.1 每个项目一个文件

```text
Application Support/Cairn/<现有 bundle 命名空间>/
  session.json                  # 旧 v1/v2 文件，仅迁移使用
  sessions/
    <project-key>.json          # 该项目最新一次有效阅读现场
```

project-key 使用规范化绝对项目根路径的稳定 SHA-256，复用项目已有哈希能力；禁止 Swift Hasher/hashValue，因为它跨进程不稳定。路径先 standardize、解析符号链接；不自行转小写。快照仍保存 root，读取时校验 root 与请求项目匹配，不只相信文件名。

Git worktree 的不同根目录视为不同项目；非 Git 目录同样支持。移动/改名后的项目首版视为新项目，不增加仓库身份匹配或全盘扫描。外置卷暂时离线时保留旧文件，提示项目不可用。

最后项目路径以现有 UserDefaults/RecentProjectsStore 同一命名空间中的一个字段保存，不建立新的项目索引数据库。最近项目列表仅用于入口，清空最近列表不自动删除现场。指针仅在目标项目成功打开并完成首份有效保存后更新；没有指针则展示欢迎页。

### 4.2 旧格式迁移

1. 没有新版最后项目指针时，尝试读旧 session.json。
2. 继续支持 v1 单语言和 v2 多语言数据；新增字段缺失时采用明确默认值。
3. 完成恢复，并成功原子写入项目文件后，再更新最后项目指针。
4. 旧文件改名保留为一次性迁移备份；迁移失败不能删除旧文件，也不能标记已完成。
5. 防止有新版数据后每次启动重新导入旧文件；清除现场后也不能复活迁移备份。

新版 schemaVersion 为 3。未知未来版本保留原文件并禁用本次对它的覆盖；界面提示版本不兼容，用户可显式清除后重新记录。回退旧版只能读迁移备份，不能宣称 v3 可无损降级。

## 5. 数据模型：扩展既有快照

以下是字段契约示意，不是要求新增对应的业务类。磁盘 DTO 放在 SessionCodec 内；运行时仍由 TabStripModel、ReadingTrail、NavigationHistory 持有状态。

```text
Snapshot v3
  原有 root / languages / revision / tabs / activeTabOrdinal / panelPreset
  FileTab: 增加 isPreview、activationRank
  ReadingSetTab: 增加 activationRank
  navigationHistory?
    records[]: jump + trailNodeID?
    cursor
    forwardRecord?
  readingTrail?
    nodes[]: id + jump
    edges[]: from + to + cause + frozenInspectorDisplay? + readingSetRole?
    activeNodeID?
```

### 5.1 标签

仅保存 LRU 的相对排名，不保存运行时 activationClock。恢复时一次安装顺序及活动项，避免逐个 open 产生 preview 替换、去重、激活排序或自动淘汰等副作用。最多一个 preview；Reading Set 不可为 preview。

旧 v1/v2 没有 preview/LRU 信息，默认全部固定标签，LRU 按保存顺序重建。活动项缺失时延续现有“第一个可恢复标签”规则，并解释原活动文件不可用。

### 5.2 JumpRecord 的可持久化身份

保存 path、ContentID、byteOffset、line、column、symbolAnchor、revision。commit 用完整 SHA；nil revision 明确代表工作区。依赖文件继续遵守现有 dependency path 允许规则。

**不能直接跨进程保存并使用 SnapshotID。** 现在 replay 通过 snapshotDestinations 查进程内 SnapshotID，重启后映射不存在，会导致旧节点无法回放。磁盘 jump 不保存该运行时 ID，恢复后由当前运行重新绑定。

跨版本回放必须按持久化的 revision 选择目标：revision 相同则使用当前来源；不同则走已有 switchSnapshot，成功后绑定本次 SnapshotID，再解析位置。工作区记录要明确切回工作区，不能因为 snapshotID 为 nil 就落到正在阅读的历史 commit。依赖来源不参与项目 commit 跳转。

不在启动时重建所有历史版本索引。仅恢复当前版本；用户点击历史节点时再加载对应版本。

### 5.3 Trail 证据

保留 UUID 节点 ID、边的原顺序和导航原因。历史证据复用 `ReadingSetExcerpt.FrozenInspectorDisplay` 的现有可读结构与编码方式：在导航边创建时固定“当时”的显示快照。若边当时没有说明，允许无证据，不从未来的 currentExplanation 补造历史事实。

不持久化 currentExplanationID、provider 请求、interned symbol/path ID 或整个 ResolutionExplanationStore。恢复边的 currentExplanationID 为空，界面显示“上次导航时的证据”；当前证据需通过新查询获得。只有显示快照的数据不得继续提供依赖旧运行时 ID 的“打开候选”等动作。

Freeze Path 继续走已有流程：能够取得并验证内容才冻结，失败按现有 skippedReasons 报告。恢复历史证据不意味着保存了该时刻所有源码，也不意味着 VERIFIED 对今天的代码仍成立。

### 5.4 History

增加 package 级批量恢复/导出入口，包含私有 forwardRecord。cursor 合法范围是 0...records.count，不能误限制为小于 count。forwardRecord 在历史尾端的意义按现有模型保留。

恢复不调用 push、recordNavigation 或模拟用户点击，避免产生重复节点、截断 forward 分支。Trail 节点引用被裁剪后，history 中该引用置空，但 jump 本身仍可导航。

## 6. 生命周期与写入一致性

### 6.1 正常保存

复用已有 250ms 防抖。触发点包括滚动/光标变化、标签打开关闭和固定、活动标签切换、语义导航成功、Back/Forward/Trail Restore 成功、Reading Set 更新、panelPreset 变化。

持续滚动可能让纯防抖无限推迟。增加一个最长约 2 秒的脏状态等待上限，确保连续操作也能周期保存；只需已有 checkpoint task 加一个最早脏时间，不建立后台调度框架。2 秒为设计目标，需测量主线程繁忙时的实际间隔，不能宣称硬实时保证。

切项目、窗口关闭、正常退出前，先从可见 Reader 采集最后位置，再取消防抖并同步原子写入。应用失去焦点继续使用已有保存触发。系统强杀无法依赖退出回调，只保证恢复最近成功写入的快照。

### 6.2 切换项目

统一在主窗口“用户打开项目”边界处理，覆盖 Open、Recent、拖目录、Choose Languages 与 Retry：

```text
采集 A 当前 UI → flush A → 取消 A 的恢复/保存任务
→ 查找 B 的快照 → 调用现有项目打开/恢复流程
→ B 完整发布 → 安装 B 状态 → 保存 B → 更新最后项目指针
```

底层 openProject 保持“打开一个干净 workspace”的职责；restoreSession 内部调用它时不能再次触发外层保存/查找逻辑。不要给底层所有 openProject 调用隐式套上恢复，避免刷新和版本切换递归恢复。

同一项目已处于正常阅读中，再选择同一路径直接聚焦窗口，不清空和恢复。用户显式更改语言组合则先保存现场，用新语言打开，并仅恢复可支持标签；反馈跳过项。Refresh Index 保持原有窄范围生命周期。

### 6.3 恢复期间禁止覆盖旧现场

在 AppModel 的 checkpoint 写入共同入口增加恢复保护，涵盖异步防抖和同步退出保存，不能只在 View 回调里拦截。

恢复开始取消旧 checkpoint 并标记所属 generation；恢复中 UI 可以渲染、但不能把空/部分标签写回。恢复完成须满足：目标来源就绪、标签安装、活动项确定、history/Trail 安装，以及活动内容达到可展示终态。源码要求文档和位置已应用；Reading Set/预览要求对应内容已呈现；无标签或全部文件缺失要求明确空态；单项加载失败要求可见的错误占位。不能要求所有内容都具有源码 ReaderDocument。之后解除保护并提交第一份完整快照。

取消/失败时释放当前任务资源；若 workspace 未完整恢复，保持该代快照写入禁用，直到用户成功打开新的完整状态。不能简单在 defer 中无条件启用保存。

A 恢复期间用户选择 B：A 任务取消，所有 await 后验证 generation/root/languages。A 的 completion 不得清除 B 的保护或把 A 保存到 B。保存目标路径和快照 root 必须来自同一次采集，不从异步执行时的可变 projectRoot 拼接。

恢复中退出保留磁盘原始快照，不把半恢复状态提交。恢复中若允许用户主动导航，应取消剩余自动定位，并在模型拓扑完整之后采纳用户位置；首版更简单的选择是暂时禁用项目内导航，仍允许选择另一个项目与退出。

### 6.4 I/O 失败

沿用 Data.write(.atomic)。写失败保留上次有效文件，状态栏提示“阅读现场尚未保存：…”，下次变化或生命周期事件重试；成功后清除提示。不要无限定时重试。

正常退出前保存失败不无期限阻止退出，不承诺本次状态已保存。自动保存期间就应显示错误，使用户有机会处理磁盘/权限问题。

读取错误分类：文件不存在＝首次打开；目录离线＝保留并提示；JSON 损坏＝保留一份 .corrupt 备份后允许重新记录；未来版本＝保留且禁止覆盖；可恢复条目失效＝仅跳过对应条目。无权限或暂时 I/O 失败不应误判为损坏并删除。

## 7. 定位与内容变化

复用 `AppModel.replayOffset`，不新增另一套相似度搜索。规则如下：

1. ContentID 一致且偏移有效：使用精确 byteOffset。
2. 内容变化、可识别原符号：按现有 symbolAnchor 匹配规则恢复。
3. 符号无法可靠匹配：回退保存的行列，并限制到合法文本边界。
4. 文件不可用：跳过标签或让 Trail 节点保留“不可用”状态，不能静默打开别的文件冒充原目标。

这是对现有 fallback 顺序的明确调整：现在合法旧行列会先于符号命中，函数上方插入代码后可能回到别的函数。S3 应在共享 replayOffset 中修正，覆盖 Session Restore 与普通导航回放两类调用和 `AppModelTests.swift` 中已有 fallback 测试；严格书签验证路径不随之放宽。

源码未变时恢复函数内部原偏移；源码变化后唯一符号匹配先回到声明处，并提示“已按函数重新定位”。现有锚点只保存符号名，无法保证函数内部相对位置或跨改名追踪；首版不声称有这一能力。无 ContentID 的旧数据只允许标为未验证/近似位置，不能显示精确恢复。行列也不可用且符号不匹配时回退文件头并提示，沿用现有 fileHead 结果。

旧 symbolAnchor 的歧义能力以当前实现为准；发现重载等多匹配时应降级行列，而不是猜一个函数。按字节处理 UTF-8 边界，不将 Swift 字符索引当 byteOffset。

先加载并验证文档，再应用选择位置，最后应用滚动位置，防止 selection 自动滚动盖掉视口。文档异步更新时以 tab/文件身份及恢复 generation 校验；用户接管后不得再次延迟滚回旧位置。非活动标签的已解析锚点在激活时通过现有 pendingTabRestore 应用。

保存 commit 已失效：当前活动现场可按已有行为回退工作区并汇总提示。点击 Trail 中不可用的历史版本时保留当前视口，提供明确的“在当前工作区打开”动作，不自动把旧版本证据解释为工作区证据。

失败回放还必须保持 history cursor 和 activeTrail 不变。现有 goBack/goForward 会先修改 history 再 replay，因此 S4 需要改为验证和加载成功后提交游标，或在失败时回滚；跨 generation 的取消不能回滚新项目的状态。

## 8. 校验、限额与裁剪

沿用现有路径、ContentID、数值和字符串校验，并为新增字段建立边界：

- tabs ≤ 10，Reading Set excerpts ≤ 50，history records ≤ 200。
- Trail 首版最多 500 个节点；运行时与磁盘使用相同保留策略，避免重启才突然大量丢失。
- Trail ID 唯一，边两端存在，无自环、无环，每节点最多一个父节点，活动节点存在；允许裁剪产生多个根。保留当前实际树/分支模型，不扩为任意图编辑器。
- 有限数、合法枚举、锚点非负且行列合法；path 不得通过 `..` 或符号链接越过允许根，依赖路径单独验证。
- 先检查文件大小再整体解码。建议初始总上限 32 MiB、单条冻结说明 64 KiB；这是待真实 Reading Set 样本验证的工程限额，不能直接截断 sourceText 破坏冻结内容。

Trail 的顺序沿导航插入顺序保存，不能排序随机 UUID 当时间。达到限额时优先保留活动节点及其祖先链，再保留最近导航节点；祖先链本身超限则保留靠近当前端的 500 个节点，最早保留项成为截断根。过滤悬空边与 history 引用，显示“较早轨迹已省略”。用现有边序和导出的有序节点确定顺序；若运行时无法可靠表达插入顺序，只增加 ReadingTrail 私有有序 ID 数组。

总文件过大时先裁剪较早 Trail 证据，再裁剪较早非活动路径；不得静默丢弃当前标签或 Reading Set 冻结源码。仍超限则本次保存失败并提示，旧有效文件保留。实施前测试 10 个 Reading Set 标签的典型体积，必要时调整一次固定上限。

校验分层：信封/root/version 不可信则不恢复整份；一个标签或一块 navigation 数据不合法时，可跳过该标签或整块 navigation，保留其余安全标签。不要因一个无效边让全部标签消失。历史数据校验仍不得放宽文件访问边界。

## 9. 实施切片与文件范围

| 切片 | 内容与主要文件 | 完成标准 |
|---|---|---|
| S1 保存可靠性 | AppModel、MainWindowController、CodeInsightApp、SessionRestoreTests | 恢复中退出/延迟加载不覆盖旧文件；切项目先 flush；写失败可见 |
| S2 按项目与迁移 | AppModel、RecentProjectsStore、SessionCodec、SessionCodecTests/RestoreTests | A→B→A 各自恢复；v1/v2 迁移；离线/未来版本不删数据 |
| S3 标签语义与位置 | TabStripModel、SessionCodec、AppModel.replayOffset、MainWindowController、既有模型/App 测试 | preview、LRU、活动项和位置恢复；共享回放优先唯一符号，代码变化有降级反馈 |
| S4 Trail/History | NavigationHistory、SessionCodec、AppModel、ReadingTrailView、ReadingSet 既有编码辅助 | 分支及 cursor/forwardRecord 正确；跨版本回放不依赖旧 SnapshotID；证据标为历史 |
| S5 原生验收与文案 | 既有 App 测试/自测入口、产品说明、验收记录 | 两进程真实恢复、关窗/退出/项目切换、失败矩阵完成 |

依赖：S1→S2→S3→S4→S5。每个切片独立提交、对应一组有意义的验收；不把所有状态一起重构。S4 复杂时按“图与历史存储”和“证据及跨版本回放”拆为两个提交。

新增类型仅限 SessionCodec 私有 DTO、确有必要的批量恢复参数；不引入 SessionManager、WorkspaceStateStore 协议、事件总线或新的磁盘依赖。若 AppModel 文件过长需要拆文件，仅搬移 session 相关扩展，不借机改其他模块。

## 10. 验收矩阵

| 场景 | 必须观察到的结果 | 层级 |
|---|---|---|
| 正常退出后重启 | 相同 tab 顺序/活动项；相同函数与可见行；Trail 分支、Back/Forward 一致 | 原生，两进程 |
| 关闭最后窗口 | 与正常退出同一现场；没有被空窗口状态覆盖 | 原生 |
| A→B→A | 两项目独立；A 离开前最后滚动也保存 | 模型＋原生 |
| preview 与第 11 个文件 | 恢复后仍遵守 preview 替换和原 LRU 淘汰顺序 | 模型＋控制器 |
| A→B→Back→C | 重启后兄弟分支保留；点击 B/C 正确；无额外恢复节点 | 模型＋原生 |
| 停在 Back 中间时退出 | 重启后的 Forward 返回真正离开的位置 | 模型＋原生 |
| Back/Forward 的目标版本不可用 | 视口、history cursor、activeTrail 都不变；明确反馈失败 | 导航故障注入 |
| 多语言与历史 commit | Rust/Python/TS 标签恢复；节点按对应 SHA 回放；工作区节点切回工作区 | 集成 |
| 函数前插入代码 | 精确位置或符号降级符合规则，selection 与 scroll 都验证 | 模型＋Reader |
| 改名、删除、重载、Unicode | 无错误偏移和错误函数声明；降级/跳过可解释 | 定位测试 |
| 多标签慢速恢复中退出 | 磁盘仍是原完整快照，重启继续恢复 | 故障注入＋两进程 |
| A 恢复中打开 B | 只有 B 发布；A 后到结果不能写入 B | 并发故障注入 |
| 磁盘只读/写失败 | 旧文件保留、错误可见、后续成功触发清除错误 | 注入存储路径权限/错误 |
| 目录暂时离线/未来 schema | 原文件不删不覆盖，恢复入口有明确反馈 | 模型 |
| v1/v2 升级 | 原有 tabs/Reading Set 不丢；新增导航为空；不会重复迁移 | Codec＋集成 |
| 损坏边/无效标签/超限文件 | 有界处理；其他合法标签仍可恢复；路径访问不越界 | Codec |
| 强制终止 | 恢复最近一次成功 checkpoint；连续操作保存间隔有实测记录 | 隔离子进程 |
| 旧证据 | 历史显示与当时保存一致；不显示为当前查询已验证 | 原生 |

测试直接扩充已有 SessionCodecTests、SessionRestoreTests、TabStripModelTests 与相应导航/控制器测试。不增加只验证赋值行为的大量镜像单元测试。

实现后的最小验证命令示例：

```sh
swift test --no-parallel --filter 'SessionCodec|SessionRestore|TabStrip'
bash scripts/ci.sh
```

过滤实际名称以本库 Swift Testing 输出为准，必须出现非零测试数和成功结束。新增导航/原生测试按实际 suite 单独执行，再跑规定 CI。若新增测试影响 scripts/ci.sh 的固定数量，同步核对并更新，不能把数量检查绕掉。

原生验收从实际 Open Project 入口构造阅读轨迹，正常 Quit，再启动相同构建。注入 JSON 可用于解码测试，不能代替完整用户流程证据。用隔离的 UserDefaults、session 根、bookmarks 与索引目录，不删除或改写用户真实现场；强杀只针对本轮测试进程。

本次设计验证：源码链路检查。未运行测试或原生恢复操作，不声明以上矩阵已 PASS。

## 11. 后续增强：在需要更完整现场时增加

### 11.1 阅读高度、折叠与 Focus

新增文件级可序列化显示字段，而不是序列化整个 ReaderTextView。保存 ReadingHeightLevel、用户手动 fold override 对应的源码范围/符号与 ContentID、Focus 的目标锚点，以及退出 Focus 后应恢复的原阅读高度和 overrides。

加载顺序：文档与 fold tree → 阅读高度 → 手动 override → Focus → selection → scroll。ContentID 不同时不复用旧 FoldID；首版增强可直接放弃该文件旧折叠并提示，无需模糊匹配所有折叠节点。Focus 目标无法确定则退出 Focus，恢复基础阅读高度，不能隐藏错误的代码。

需要覆盖“切标签再重启”与“Focus 后退出 Focus”两条路径，不能只证明启动时看起来一致。

### 11.2 预览位置与布局

按已经存在的预览组件保存少量必要数据：文本/Markdown 的稳定位置、PDF 页码及页内偏移。路径和资源访问仍走原有安全规则，不恢复外部页面或运行脚本。

只有用户需要每项目独立面板比例/目录展开时，再给现有保存键加 project-key；窗口尺寸、主题和字体继续沿用全局设置，不复制一套布局快照。

### 11.3 Relations、Context Pin、Compare

需要恢复时仅保存“查询意图”：根符号的路径/锚点、关系类型、Pin 目标、对比 SHA。重新计算结果；选择项失效则取消选择并解释。provider 状态、正在执行的请求、旧结果树不入磁盘。本轮核心现场恢复不依赖这一增强。

## 12. 交付标准

首版交付应能证明：**退出、关窗、切项目都能保存；每个项目独立恢复函数位置、标签和导航路径；恢复失败不损坏上次有效数据；历史内容变化有清楚的降级行为。**

交付报告分别列明模型测试、原生两进程验收、故障注入结果，并再次列出折叠/Focus、完整选择范围与预览位置等尚未覆盖项。
