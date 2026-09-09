# Cairn 稳定性、内容一致性与阅读 UI 修复计划

日期：2026-09-05。状态：**计划完成，尚未实施；本次不修改业务代码、不提交。**

规划源码基线：`ac18460ff99197f70bed7641c29fd8b30c0cc257`。
依据：[本轮审查报告](../reviews/2026-09-05-product-architecture-review.md)及其真实截图、CPU 采样、复现步骤。
另纳入随后 UI 专项评审的六项意见：主区被挤压、无用面板占空间、来源信息过重、强调元素过多、辅助文字偏小、操作概念不直观。

实施开始时另记 `IMPLEMENTATION_BASE` 的完整 SHA、工作树差异、操作系统、工具版本和实际 bundle 路径；不能把本规划 SHA 或历史测试数当成最终验收证明。
现有 `.claude-trace/` 与 `docs/reviews/` 均为未跟踪内容，不删除、不覆盖、不顺手提交。

## 1. 本轮要达到的结果

1. 语言服务退出、断开或关闭输出后，Cairn 不再空转；查询能正常结束。
2. 用户看到的源码与应用使用的语义位置一致；过期结果不能静默跳到错误位置。
3. 项目与历史内容的内存寿命有边界；不让非源码预览内容无条件积累在语义存储中。
4. 关系命令围绕用户正在操作的内容工作，Context Pin 不劫持全局命令目标。
5. Reader 是视觉主区：辅助面板按任务出现，窗口尺寸不被长文本撑开，关键路径和命令可读。
6. 首次打开、失败恢复、阅读证据保存的文案准确；已批准的产品边界不被暗中扩大。

这是修复与收敛，不是重写。保留 AppKit、Engine/Exact/Git/Reader 分层、现有主题与原生控件。

### 1.1 证据等级和处理原则

| 问题 | 当前证据 | 本计划处理 |
|---|---|---|
| LSP EOF 空转 | 已安装应用 175%–199% CPU；采样定位两个 FileHandle 回调；当前源码有同一缺口 | S1 先在当前源码隔离实例建立 RED，再修 |
| Worktree 旧索引跳新文件 | 当前构建真实复现 `target` 改名后跳到注释行 | S2a–S2c 强制修复 |
| 无界内存存储、全文件捕获 | 调用链确认；大型仓库代价未量化 | S4a–S4c 先测再改，不凭风险直接重写 Snapshot |
| 两套打开流程、错误原因丢失 | 源码确认 | S3a/S3b，用行为回归约束收敛 |
| Relations 命令依赖 Context | 大纲/选区入口禁用已观察；Pin 错目标未实测 | S5 分别建立可重复验证 |
| Exact 文案撑宽窗口 | 截图 900×652 → 1244×652；唯一约束根因尚未锁定 | S6 先测 NSWindow frame、约束和文本变化 |
| 面板比例、文字和层级 | 本轮真实截图及专项设计评审 | S7/S8 以明确布局合同验证 |
| Reading Set 随 tab 生命周期 | M11 明确裁决，当前代码符合 | S10 说明边界，不改成独立资料库 |

不能复现的分支标为 `BLOCKED（未复现）`，不能将推测写成已修复。

## 2. 先固定的行为与设计决策

以下为本计划提出的实现合同；修改时若发现与已批准的更具体合同冲突，先记录冲突及最小修订，不擅自改变语义。

### D1：保留 live Worktree 阅读，禁止混用字节身份

- 保留 M14 的现有行为：Worktree 打开/重新打开文件读取磁盘，commit Reader 读取选定快照。
- 所有来自索引的 byte offset，在应用到 Reader/Context/Relations 前必须和目标内容身份配对验证。
- 已显示的旧文档与旧索引一致时可以继续阅读。没有检测到磁盘变化时，不承诺实时同步；本轮不增加文件监听器或轮询。
- 检测到文档与索引不一致：仍可选择/复制/查找当前文本，并使用当前文档的大纲与折叠；旧索引语义操作暂停，显示 `File changed since indexing` 和可见的 `Refresh Index` 操作。
- 全项目搜索属于索引视图，保留其原始位置与来源；激活结果前验证目标，失败时不移动视口、不写入 history/Trail。不能仅在当前 Reader 上放一个提示而继续允许陈旧搜索跳转。
- 当前文档大纲、文件内查找产生的位置来自当前文档，不能因全项目索引旧而一并禁用。位置身份由实际 producer 提供，不能只靠 `NavigationCause.search` 猜测来源。
- 优先使用已有 `ReaderDocument.contentID`、manifest、`JumpRecord.contentID` 和捕获来源。若跨入口确实缺身份，可在既有 `SourceDestination` 增加 `expectedContentID`，消费者为共享导航入口；索引位置不得以 nil 绕过验证。不新增另一套导航实体。
- Context、Exact 结果也必须验证查询源和目标身份；只匹配 snapshot/profile/generation 不足以证明磁盘字节一致。

### D2：刷新索引不是重新打开项目

新增的 `Refresh Index` 是同一 Worktree 的新捕获代际，复用既有快照切换/发布链。
保留 tabs、选中的文件、Reading Set、书签、已有 Trail 分支和用户布局；对文件位置按已有 content/anchor/line fallback 恢复，并明确降级。
刷新成功只发布一个新代际，不重复添加导航历史。失败保留可读文档与旧索引状态，继续禁止不一致的语义操作，提供重试。
不能直接调用会 reset tabs/Trail 的 `openProject` 来完成刷新。

### D3：Context Pin 仅冻结预览

Reader 获得焦点时，全局 Show Callers/Calls/Implementations 使用其当前选区/光标对应目标。
菜单和快捷键复用既有右键“文件 + offset → resolve → relation root”路径。
Relations 自身方向切换仍围绕当前关系根；Context 内显式操作仍围绕该预览。必须区分当前操作面，不统一猜成“最近一次候选”。
菜单展开导致 first responder 改变时使用打开菜单前的有效操作面；不能悄悄 fallback 到被 Pin 的旧候选。

### D4：保留既有产品边界

- Trail 保持 session-only；Reading Set 保持冻结源码/证据及 tab 生命周期；书签仍按 M13 严格内容锚点处理。
- 不增加 Reading Set 数据库、文件夹、标签、永久收藏、跨版本符号映射、同步或导出功能。
- M14 文件发现规则优先于较早总设计：固定跳过目录之外的常规非 symlink 文件可见。本轮不擅自改成 `.gitignore` 过滤；S11 统一文档，并保留此取舍的记录。
- 不新增语言、provider、依赖、renderer registry、插件框架、通用 cache manager 或 UI 状态机框架。
- 不因文件很长就拆出新的类型。已有类移文件可以以后单独做，不与本轮行为修复混合提交。

## 3. UI 目标合同

使用当前截图作为改前基线。布局单位为 AppKit **pt**，截图像素仅用于同一 backing scale 的对比。
以下宽度是本轮 proposed 验收值，不冒充历史产品已有承诺；G2 在当前字体与三主题下验证可用性。

### 3.1 面板如何出现

| 场景 | 主区域 | 辅助区域与恢复规则 |
|---|---|---|
| 尚未打开项目 | 品牌、Open Project、最近项目 | 隐藏无操作对象的 Outline/Context/Reading Height/空 Trail 行；保留正常菜单 |
| 源码阅读 | Reader + 按用户选择显示的文件树/大纲 | Context 尚无结果时不保留大块空白；首个明确预览请求可展开；Pin 内容可保留 |
| Markdown/HTML/文本/图片/PDF | 文件树 + 内容预览 | 隐藏 Outline、Context、Relations、Inspector 和源码控件；不清掉用户的源码布局偏好或 Pin 内容 |
| 关系探索 | Reader + Relations | 宽度不足时临时收起 sidebar，不能压缩代码到不可读；退出后恢复用户原来选择 |
| Inspector 打开 | Reader + 证据解释 | 右侧宽度不足以放结果和解释时，Inspector 在既有右区域替换结果列表；Close/Back 恢复列表选中和滚动位置 |
| Compare | 双 Reader | 保留现有 Compare 语义；不强行套单 Reader 的 480pt 下限；两侧各至少 320pt，必要时暂收起 sidebar/Context |
| Reading Set | 既有独立阅读布局 | 沿用 frozen 内容、来源与行为，S7 不修改其保存模型 |

单 Reader 默认字体下有效宽度目标 ≥480pt；独立 Relations/Inspector 区域 ≥300pt。
仅当右侧内部宽度能够同时满足 list ≥280pt、Inspector ≥300pt 和分隔间距时，允许它们并排。
900pt 窗口下优先展示 Reader + 一块右侧辅助区域；不通过自动增大窗口满足约束。

布局选择由已有 preset、当前内容、Inspector 可见性与窗口宽度导出。可以保存一份必要的私有临时尺寸/折叠值用于恢复，不新建持久化 schema 或布局实体。
不要在每次 render 时重新设置 splitter 位置；只在内容/布局模式或宽度阈值实际变化时调整。跨阈值不得振荡。
用户主动选 Focus、Compare、拖动分隔条的意图优先；临时收起不能被写回为新的默认 preset。

### 3.2 信息层级、字号和色彩

- 第一层：源码选区/当前显式导航目标。第二层：文件、函数、路径、关系结果。第三层：来源、环境、快捷键。
- 保留用户 Reader 字号和主题设置，不擅自统一改成新的字体方案。
- 新调整的解释正文优先 13pt；关键路径/关系辅助文字至少 12pt；11pt 仅用于短的时间/快捷键等次要标注。不再用缩小字号解决溢出。
- Context 常驻：目标路径与行号、候选计数、简短 Verified/Inferred 状态、确有必要的限制标识。
- 完整 provider/toolVersion/trust/limitations/commit/features 移入**已有** tooltip 或 Inspector；AX 可获取完整信息。Context 候选不一定具备现有 relation explanation，不能为展示详情伪造 Inspector 证据。
- 不通过改 `provenanceBadge` 数据内容破坏语义判断；UI 短标签从已有 certainty/provenance/attribution 得出，保留完整诊断信息。
- 蓝色优先用于选中与主要动作；绿色仅作小型验证标记；黄色保留给已有查找/显式跳转反馈。不能隐藏 Unresolved/Conflict/Partial 等重要区别。
- 路径截断应有完整 tooltip；重点信息不用颜色单独编码。小字号对比度按 4.5:1，非文本控件关键边界按 3:1 作为验收目标。
- 收敛顶部胶囊/按钮层级，保留原生 toolbar；在 900pt 宽和长项目名下 Symbols 必须可见，项目名/版本说明先压缩，Settings 可进入 overflow。

### 3.3 文案

保持英文产品界面，不新增本地化系统。拟采用：

| 位置 | 目标文案或说明 |
|---|---|
| Worktree 内容不一致 | `File changed since indexing` / `Refresh Index` |
| Trail 空态 | `Follow symbols to build a trail · this session only` |
| Trail 证据标题 | `Evidence at navigation` / `Current evidence`，去掉 `explanation store` |
| Structure / Overview | 保留既有名称与快捷键；tooltip 明确实际隐藏/保留内容，按既有 reducer 行为撰写，不只改名 |
| 冻结结果入口 | 保留 `Freeze Results`，tooltip 说明保存当前已发布源码与证据快照 |
| Reading Set 说明 | 可随本次保留的标签恢复；关闭或自动淘汰后不再保留，不宣称永久收藏 |
| 打开失败 | 简短具体原因 + 对应 Retry/Open Another Folder；详细错误可读、可复制 |

## 4. 顺序、依赖与提交边界

每个编号是独立可 review 的切片；S2/S3/S4/S7 明确拆成子切片，不能合成一次大提交。
本计划不指定代理或模型，也不启动并行实现。多数切片共享 AppModel/MainWindowController，默认顺序实施。

| 切片 | 内容 | 依赖 | 规模 |
|---|---|---|---|
| S0 | 冻结复现、测试隔离与基线 | 无 | 证据/fixture |
| S1 | EOF 与 transport 生命周期 | S0 | 2–3 文件 |
| S2a | 共享语义导航的内容身份验证 | S1 | 3–5 文件 |
| S2b | Context/Exact 的来源一致性 | S2a | 3–5 文件 |
| S2c | 无损 Refresh Index | S2a/S2b | 3–5 文件 |
| S3a | 收敛打开/取消/发布流程 | S2c | 3–5 文件 |
| S3b | 打开与刷新失败反馈 | S3a | 3–5 文件 |
| S4a | 内存与首屏测量，冻结预算 | S3a | 证据 + 小型测试 |
| S4b | 项目/快照存储寿命、非源码隔离 | S4a/G1 | 分成两个 3–5 文件提交 |
| S4c | 必要时调整捕获策略 | S4b 后仍超预算 | 受 G1 条件约束 |
| S5 | 关系命令目标与键盘/Pin | S2b/S3a | 3–5 文件 |
| S6 | Context/toolbar 长文本与稳定几何 | S5 | 3–4 文件 |
| S7a | 非源码/空态面板退场与恢复 | S6 | 3–4 文件 |
| S7b | Reader 优先的窄窗口/Inspector 布局 | S7a | 3–5 文件 |
| S8 | 字号、色彩、强调层级收敛 | S7b/G2 | 分 App chrome / Reader token 两步 |
| S9 | 首次导入语言预选 | S3b | 2–4 文件 |
| S10a | Markdown 列表语义呈现 | S7a | 2 文件 |
| S10b | 阅读概念与保存边界文案 | S8/S9 | 3–5 文件 |
| S11 | 文档与正式回归门禁 | 上述切片 | 分 docs / gates 两步 |
| V0 | 当前构建原生完整验收 | S11 | 无业务改动 |

主线检查点：**G0（S1–S3）正确性 → G1（S4）资源寿命 → G2（S6–S10）阅读体验 → V0 总验收**。

## 5. 实施切片详细合同

### S0 — 冻结基线与隔离复现

**工作**：记录现有报告、采样、截图和 git 状态；生成临时 fixture，不修改既有 Gold/corpus。先复现再修。

- fixture A：小 Rust 仓库、两次 commit、函数 A/B、Unicode、可改名/前插注释的源码、README 内链、Markdown 列表、图片/PDF/未知二进制。
- fixture B：Python/TS/TSX 及混合 Git workspace；普通非 Git 单语言目录；缺失/无权限路径；按需生成不同大小的非源码资源。
- provider 夹具复用现有 Pipe/LSP fake session，能够独立关闭 stdout、stderr，以及“关闭输出但进程仍活着”。

**隔离**：每轮唯一 bundle id/output/cache/fixture 目录；只允许写本轮测试数据。预检真正使用的 UserDefaults、App Support、session、bookmarks、index cache 路径，不能仅以换 bundle id 假定全部已隔离。
不杀 `/Applications/Cairn.app` 的原实例，不覆盖安装包、不提升 Trust、不访问网络安装依赖。

**验收**：基线可重放；每个已复现问题有真实失败判据；保存 NSWindow frame/控件 frame/AX/截图与实际源码 SHA。无效截图不计 PASS。

### S1 — 终止 EOF 忙循环

**文件**：`Sources/CodeInsightExact/LSP.swift`、`Tests/CodeInsightExactTests/CodeInsightExactTests.swift`；仅在 termination 通知不能正确发布时扩展 `ExactCoordinator.swift` 及其既有测试，另作提交。

**RED**：关闭输出端后保持 LSPClient/应用存活，证明 EOF handler 未卸载或回调继续发生；不能用立即 deinit 隐藏问题。

**实现**：stdout/stderr 各自 EOF 时注销各自监听，保留已收到的消息/诊断；stdout EOF 结束未完成请求，stderr EOF 不误判整个 transport 已关闭。显式 close、进程退出、取消与回调并发时清理幂等。
不要在 readability 回调内执行会等待同一 transport 回调的同步 shutdown/close。

**验收**：

1. EOF 后 handler 不再触发；未完成请求有限时间结束，正常新进程仍可使用；weak self 已释放的路径也不留监听。
2. stdout-only、stderr-only、进程退出、close 竞态均覆盖；旧响应不发布到新会话。
3. 当前 bundle 空闲采样 3×10 秒：修前 EOF 空转可见，修后不再出现该栈；自身 CPU 中位数目标 <3%（100%=一个核心），并与同机打开前基线比较。异常必须解释，不能只截瞬时 0%。

**验证**：Exact 既有测试 + 一个真实 EOF 回归；真实 provider 断开后继续操作 Reader。提交建议：`fix: stop LSP stream monitoring at EOF`。

### S2a — 拦截内容不匹配的语义导航

**文件**：`AppModel.swift`、`NavigationHistory.swift`、`MainWindowController.swift`、`Tests/CodeInsightAppModelTests/AppModelTests.swift`、`Tests/CodeInsightAppTests/RelationNavigationTests.swift`。

**RED**：复用 `target→renamed + 8 行注释` 场景；同时覆盖当前文件、未打开目标、inactive tab 和搜索→Relations→跳转入口。

**实现**：先追踪所有导航调用者，在共同入口验证目标内容身份后才提交视口/history/Trail 变化。优先沿已有请求传内容身份，不在每个按钮补散落 guard。
文件读取/哈希不得放在每次 hover、滚动或 menu validation；复用已加载文档和快照哈希，必要 I/O 在动作执行的后台阶段完成，再按请求代际发布。

**验收**：

1. 不匹配、目标删除、越界、非法 UTF-8 均不错误导航，给出有效反馈；失败不增加 history/Trail、不污染当前 tab。
2. 当前文档的大纲/查找仍正常；无变化文件和 commit 搜索正常；中文/emoji 字节坐标正确。
3. 快速 A→B→C、切项目、切 profile 时旧验证任务不能恢复旧目标；所有索引位置 producer 都有内容身份，无 nil 放行。

### S2b — Context 与 Exact 不混合不同内容

**文件**：`ContextWindowModel.swift`、`ExactCoordinator.swift`、必要的 `AppModel.swift`；既有 `AppModelTests.swift`/`ExactCoordinatorTests.swift`/`RelationNavigationTests.swift` 中选择相关测试文件，每次提交控制在 3–5 个文件。

**RED**：Context 索引指向旧目标而磁盘目标改变；Exact 延迟返回期间改变源/目标；Engine 捕获后、Exact 再捕获前改文件。

**实现**：查询与展示沿用同一源/目标内容身份。Context 加载后核对请求 contentID。Exact 当前会另做 snapshot/profile 准备，不能因 profile 一致就当成源码相同：核对其 source identity 与当前 Engine/Reader，必要时复用已有捕获输入。
失配时保留已知一致的 fuzzy 或冻结证据，停止错误升级并显示 stale；不伪标为 Verified。
不要为了规避此问题把所有 Worktree 都改成 Trusted 或历史物化模式。

**验收**：源变、目标变、provider 重启、版本切换和延迟升级不串线；Pin 不被后台旧回复覆盖；Safe/离线及既有 candidate/verified/conflict 语义不降级。

### S2c — Refresh Index 的真实恢复路径

**文件**：`AppModel.swift`、`MainWindowController.swift`、`CodeInsightApp.swift`、`SnapshotSwitchTests.swift`、`SessionRestoreTests.swift`（测试均在现有目录）。

**工作**：实现 D2，在状态提示和菜单提供同一个 Refresh Index 动作，刷新中可读、可取消；重复触发取消旧请求，不叠加多个捕获任务。

**验收**：

1. 前述 RED 场景刷新后 `#target` 不再命中，`#renamed` 定位正确；Context/Relations 恢复，stale 提示清除。
2. tabs、Reading Set、书签、Trail 分支、布局不丢；原位置按既有 fallback 恢复；不增加重复历史。
3. 刷新失败、刷新中切项目/版本、应用退出重开，不保存半安装会话；普通非 Git 单语言目录同样可刷新。

**G0 前半检查**：在当前 bundle 真实复现与修复对比；单元测试通过但错误跳转仍存在则 FAIL。

### S3a — 收敛项目打开与代际清理

**文件**：`AppModel.swift`、`MainWindowController.swift`、`AppModelTests.swift`、`SnapshotSwitchTests.swift`，必要时 `SessionRestoreTests.swift`。

**工作**：Git 单语言和多语言进入同一取消/初始化/分阶段发布链；语言列表是输入。保留现有对外入口作为薄转发，不引入新的 coordinator 类型。
普通非 Git 单语言 fallback 保持可用；不得将任何捕获错误都吞成“不是 Git 仓库”，权限/损坏等失败需正确传递。

**验收**：1/2/3 语言、普通目录、切版本、切配置的生命周期一致；加载 A 中打开 B 时只有 B 发布；bookmark generation、Exact 关闭、Compare、pending replay、Trail/tabs 的 reset 范围与 D2 区分明确。
此切片只做结构收敛，不混入 UI 风格修改。

### S3b — 可恢复的错误反馈

**文件**：`AppModel.swift`、`MainWindowController.swift`、`EmptyStateView.swift`、对应 `AppModelTests.swift`/`MainWindowControllerTests.swift`。

**工作**：保留底层 error，在既有状态上呈现简短原因和操作；首开失败用空态，刷新失败用非破坏提示，不覆盖仍可阅读的主区。
所需原因直接由既有 Error 提供，不建全局错误分类平台；避免在 UI 拼接无限长度 stderr。

**验收**：至少验证不存在路径、拒绝读取、无效 Git revision 三类；Retry/选择其他目录可用；超长错误在最小窗口可读且不撑窗，AX 能读完整必要原因。

**G0**：S1–S3 当前构建 PASS 后再做资源与视觉收敛；不能带着一致性错误修改大量布局代码。

### S4a — 资源测量与预算 G1

**文件**：新增本轮 evidence；需要回归入口时扩展 `SnapshotIndexerTests.swift` 或现有 app self-test，不建性能测试框架。

**测量矩阵**：相同源码 + 0/64/256 MiB 非源码；同一文件在 10 个 commit 有不同内容；A/B 项目来回 20 次；关闭 Compare、tabs 和待处理任务后再次观察。
测试大文件只在临时目录按需生成，禁止在仓库提交大二进制或压测用户已有会话。

记录目录发布、首个可见文件、cached/full semantic ready、捕获字节数、store retained bytes、RSS/physical footprint 与 CPU；区分捕获临时峰值、共享数组 COW 和仍被会话持有的内容。计时不包含编译。
冷热场景分别重复不少于 5 次；宣称 p95 达标的项目不少于 20 次，记录环境和分布，不拿一次成功算 p95。

**验收目标**：
1. 继承 `docs/design.md §15` 的文件分档和 commit first-paint p95<1s 目标；已批准的历史例外单列，不悄悄放宽。
2. 纯非源码资源不增加语义 store retained bytes；关闭项目后，旧项目 store 生命周期可验证结束。
3. 同一固定 A/B 集合反复打开，后半段 retained bytes 不随轮次线性增长；RSS 与分配器保留内存分开报告。先冻结可复现实测阈值，再实施，不能修完挑有利阈值。

### S4b — 最小资源寿命修复（两个提交）

**S4b-1 项目与快照寿命**：`ProjectIndexStore.swift`、`AppModel.swift`、`EngineSession.swift`（确有需要时）、`SnapshotIndexerTests.swift`、`AppModelTests.swift`。
ProjectIndexService 不无限保留跨项目所有内容；明确 project boundary 后的 store 替换与旧任务释放。当前会话、Compare、pending replay 的引用仍须有效。
同项目回收按实际活动内容键处理，不能清空仍在使用的 interned IDs 或改变既有 snapshot；读取旧历史时可按既有缓存/捕获重新恢复。若 pruning 会破坏 IDs/共享状态，先缩小回收到项目边界并如实报告同项目风险未关闭，再补设计，不能强行删除。

**S4b-2 非源码不进入语义 store**：`ProjectIndexer.swift`、`ProjectIndexStore.swift`、`GitSnapshot.swift`（仅必要部分）、`SnapshotIndexerTests.swift`、`GitSnapshotTests.swift`。
在 bytes 写入语义 store 前筛选实际消费者；保留语义源码和真实需要的配置，预览使用快照/Reader 的内容来源。逐一检查 `capturedProjectSource`、Reading Set、Bookmark、ProfileDetector、Materializer 和 CLI 的调用，不能因为扩展名非源码就误删配置或物化所需内容。
文件树成员、Snapshot 原始 bytes 与 M14 历史预览不因此消失；本切片不悄悄缩减快照合同。

**验收**：S4a 全矩阵复测；语义统计/内容哈希/配置/历史 raw blob 行为保持；已打开的历史、Compare、Reading Set 在回收后仍可读。

### S4c — 捕获策略的条件切片

**触发条件**：S4b 后，全文件 eager 捕获仍使 G1 的首屏或峰值预算不达标。触发则此风险不能标 PASS；不触发则不做该接口改造。

当前 `Snapshot.listFiles()` 要求每项已有 SHA-256 ContentID，`CommitSnapshot` 会读取所有 blob 计算它。不能用 Git OID 冒充 ContentID，也不能一边承诺不可变 Worktree，一边延迟读已变化磁盘。

触发后先提交一份小型接口差异与消费者清单，覆盖：GitSnapshot、ProjectIndexer 两个入口、AppModel 首屏/书签、Exact 的 ProfileSnapshot、Materializer、CLI snapshot 与现有测试。按以下优先顺序选择最小可行方案：

1. 在不改 Snapshot 内容合同的前提下，先发布现有文件树并延后不阻塞阅读的捕获工作；仍需说明何时获得语义一致的 bytes。
2. 若峰值仍超标，分离**同一 Snapshot** 的目录元信息读取和内容读取，让 commit 可按已解析 blob OID 取 bytes；必须显式处理 ContentID 获取时机及所有消费者，不能只在 Reader 局部实现假 lazy。
3. Worktree 需要冻结的内容若改为磁盘 backing，写入仅限 App 私有测试/缓存目录，捕获须检测变化；定义文件/项目预算、取消、清理和超限反馈。禁止静默截断、随机漏文件或不受限落盘。

不新增 renderer/泛型缓存层。若确需新增方法/私有元信息，只能附着既有 Snapshot，列出其真实消费者；先通过合同评审，再分“接口与 fixture → Git 实现 → App/Engine 调用”三个切片实施。

**G1 结论**只能是：预算达标；或列明仍不达标、剩余设计与阻塞原因。不得把完成 S4b 等同于整个性能风险已消除。

### S5 — 当前操作面驱动关系命令

**文件**：`MainWindowController.swift`、`CodeInsightApp.swift`、`ReaderContextMenuTests.swift`、`RelationNavigationTests.swift`，必要时 `ContextWindowModel.swift`。

**RED**：大纲定位后 `⌘⇧H` 不可用；选中调用点仍不可用；Pin A 后 Reader 去 B 再执行命令验证目标，不先假定其结果。

**实现**：落实 D3；复用已有 resolver 与目标路径。菜单 validation 只做廉价可用性检查，执行阶段异步 resolve 并再次验证内容与 generation；不在菜单展开时启动 Exact 或做磁盘 I/O。

**验收**：Reader 鼠标/键盘/大纲入口一致；Pin A 查询 B 时 Context 仍为 A、Relations 根为 B；不支持 surface/空白位置正确禁用或给明确反馈；Relations 内切方向和 Context 内操作不倒退。

### S6 — 来源说明和 toolbar 不撑窗

**文件**：`MainWindowController.swift`、`MainWindowControllerTests.swift`、`RelationNavigationTests.swift`；必要时既有 `ReaderContextMenuTests.swift`。

**RED**：900pt 固定窗口依次发布短 fuzzy 与超长 Exact 文本，记录 frame/路径可见区/约束；鼠标和键盘都不调整窗口。先确定导致扩窗的约束，不能仅凭审查推断降低任意优先级。

**实现**：落实 §3.2 短来源标签、完整 tooltip/AX；设置必要的压缩/截断策略；顶部项目/版本/分析 profile 先压缩，Symbols 保持可见。

**验收**：

1. 900/1000/1280/1440pt 四宽度，结果升级前后 NSWindow frame 不变（仅允许读取/取整误差，不放宽产品几何）；无约束冲突。
2. 路径至少能识别文件名和行号；完整来源可通过既有详情路径读取；Verified/Inferred/Unresolved/Conflict 表达不丢。
3. 长项目名、长分支名、三 provider、三主题均不挤掉 Symbols，不出现内容越界或来源文字整条染色。

### S7a — 非源码与空态的面板退场

**文件**：`MainWindowController.swift`、`EmptyStateView.swift`、`NonSourcePreviewTests.swift`、`MainWindowControllerTests.swift`。

**实现**：按 §3.1 隐藏不适用区域，借用已有布局应用入口和最少私有恢复值。不清空 Pin 或用户源文件布局，不修改 SessionCodec。

**验收**：source→Markdown→HTML→PDF→source；Pin 后往返；Reading/Relations/Compare/Focus 各 preset 往返。内容/滚动/选中可恢复，无陈旧源码控件和隐藏但可聚焦的 AX 控件；初始空窗口主按钮与最近项目完整可见。

### S7b — Reader 优先与 Inspector 收敛

**文件**：`MainWindowController.swift`、`RelationWindowController.swift`、必要的 `PanelPresetModel.swift`，以及 `MainWindowControllerTests.swift`/`RelationNavigationTests.swift`。

**实现**：落实 §3.1 宽度合同。用现有 `listPane`、`inspectorView` 和 onClose 在窄右区切换，不引入新窗口或 inspector navigation store。
临时收起 sidebar、恢复尺寸不得覆盖用户选定 preset；Inspector 切换前后保留关系根、选中行与滚动位置。

**验收**：窄窗 Reader≥480pt、独立右区≥300pt；Inspector 文本无逐词窄列；宽度来回跨阈值不振荡、不重建查询；Compare 双列和 Focus 不被自动布局破坏。鼠标/键盘打开、关闭 Inspector 均回到同一关系结果。

### S8 — 视觉层级、字号和色彩

**文件**：先只改 `MainWindowController.swift`、`RelationWindowController.swift` 及对应 app 测试；若确需调整共享主题 token，再单独修改 `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift` 与相关 ReaderUI 测试。

**工作**：依据 §3.2 清理重复胶囊和强背景、增大关键辅助文字、降低非交互分隔与元信息权重。保留 SI Classic 风格、用户 Reader 字号、源码语法色和已有导航高亮生命周期。
对比同一真实内容的 Light/Dark/SI Classic 改前改后截图；不以空 fixture 大片白区作为“简洁”的证明。

**验收**：当前文件/函数/路径先于 provenance 可读；重要状态不靠颜色区分；字符和控件对比度达目标；所有视觉变化能对应本轮问题，不新增装饰性区域。
纯样式值不逐项写实现镜像测试；复用几何/AX 验证，保留必要的人工视觉判断。

**G2**：Reader/Relations/Inspector/非源码四种场景在目标宽度稳定可读后，才统一界面截图和文档，不靠“大屏截图正常”放行最小窗口。

### S9 — 首次导入语言预选

**文件**：`CodeInsightApp.swift`、必要的 `RecentProjectsStore.swift`，以及 `MainWindowControllerTests.swift`/`RecentProjectsStoreTests.swift`。

**实现顺序**：路径已在 Recents 中且有有效记录，使用真实保存的语言；新路径基于既有 LanguageMode 与固定跳过规则进行可取消、只读的文件名探测，预选确实出现的语言。不能把 `languages(for:)` 的默认 Rust fallback 误当成用户曾作选择。
探测不读取全部文件内容、不启动 provider、不加载项目脚本；0 语言时保留清楚的手选入口，不默默打开错误模式。
若用户在探测完成前手动改选，不覆盖其选择；混合非 Git 目录仍遵守当前支持边界并明确提示，不偷偷扩大支持。

**验收**：Rust/Python/TSX/混合仓库预选准确；JS/JSX 不误选 TS；老项目偏好有效；0 项 Open 禁用、1–3 项可用，纯键盘可完成。探测取消、巨大目录或无权限子目录有明确终态，不能让弹窗假死。

### S10a — Markdown 列表恢复结构

**文件**：`MainWindowController.swift`、`NonSourcePreviewTests.swift`。

**工作**：复用 Foundation Markdown presentationIntent，在现有渲染函数保留无序/有序列表标记、嵌套层级、段落间距；代码块仍等宽，不新增 Markdown 引擎。

**验收**：序号/项目符号和嵌套可辨；列表内强调、链接、代码块不损坏；窄窗口换行与选择复制可用；内部链接安全策略、HTML CSP 和只读性零倒退。不将本轮扩成完整 CommonMark 渲染器重写。

### S10b — 概念与保存边界文案

**文件**：`ReadingTrailView.swift`、`ReadingSetView.swift`、`RelationWindowController.swift`、相关既有 app 测试；Reading Height tooltip 位于 MainWindowController 时另作小提交。

**工作**：落实 §3.3。按真实 reducer 解释 Full/Structure/Overview；Trail 明确来源与会话性；冻结按钮说明保存的是已发布证据；去掉 explanation store 等内部术语。
Reading Set 文案明确“保留 tab 可重启恢复、关闭/淘汰不永久保留”；不修改最大 10 tabs、50 excerpts 或 LRU 规则。

**验收**：界面与 tooltip/AX 同义；session-only 与 frozen 的边界准确；按钮文字不会因变长再次溢出，核心动作无需读 README 才能辨认。

### S11 — 文档和回归门禁

**docs 提交**：`docs/design.md`、`README.md`、`README.zh-CN.md`、本计划、最终验收记录。
同步 Worktree 内容/刷新合同、M14 局部 WebKit、文件发现规则、语言预选、Reading Set 生命周期；将支持/延期/历史验收分开。旧报告保持其当时事实，不修改历史 FAIL 伪装原本通过。

**gates 提交**：`scripts/ci.sh`、`scripts/run-product-gates.sh`；仅在正式产品自测确有新增断言时扩展 `CodeInsightApp.swift`，不顺手搬动整个自测程序。
保留既有隔离的两条 BookmarkPanel 测试及成功摘要验证；当前 849+2 是基线，按真实新增测试数更新，不能绕过计数。
不随意改既有 17 通道合同；能在相关通道增加断言就不新建通道。将 M14 非源码真实入口验收纳入最终明确执行清单，避免只证明编译或模型测试。

**验收**：一条失败注入确认 EOF/内容不一致的关键回归会使门禁失败；中英文 README 同构；最终缺口明示，不把 ad-hoc bundle 写成已公证发布。

## 6. 验证命令与最终原生验收

以下为实施时使用的命令，**制定本计划时不运行编译、测试或压测**。

```bash
# 每片只运行与变化有关的测试；模式先用 swift test list 核对可发现的测试名。
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift test --disable-sandbox --no-parallel --filter 'CodeInsightExactTests'
swift test --disable-sandbox --no-parallel --filter 'AppModelTests|SnapshotSwitchTests|SessionRestoreTests|ExactCoordinatorTests'
swift test --disable-sandbox --no-parallel --filter 'RelationNavigationTests|ReaderContextMenuTests|MainWindowControllerTests|NonSourcePreviewTests'
swift test --disable-sandbox --no-parallel --filter 'CodeInsightGitTests|SnapshotIndexerTests|SnapshotSearchTests'

# 所有相关检查完成后，最后运行一次完整门禁。
CODEX_SANDBOX=1 bash scripts/ci.sh
bash scripts/run-product-gates.sh "$PYTHON_CORPUS" "$TYPESCRIPT_CORPUS" "$MIXED_CORPUS"

# 唯一输出与 bundle id；只覆盖该轮自有目录，不替换 /Applications/Cairn.app。
CODEX_SANDBOX=1 bash scripts/make-app.sh \
  --output .build/reliability-ui-validation \
  --bundle-id dev.cairn.Cairn.ReliabilityUIValidation
```

`PYTHON_CORPUS` 等必须先解析为已有冻结 corpus，不能把占位变量原样当作执行完成。
过滤器匹配到 0 个测试、exit 0 但没有最终成功摘要、日志停在 started 都不是 PASS。不得并发启动多个占同一 .build 的 SwiftPM 任务。
局部错误应定位后重跑有关部分；通过后不要无理由重复全套构建。

### V0：真实 AppKit 流程

1. **首次打开**：新隔离数据目录，Open Project → 原生 picker → 语言预选 → 文件树 → 可读源码；鼠标和纯键盘各一遍。
2. **CPU 生命周期**：启动/断开 provider 后 Reader 仍可用，EOF 稳定期不空转；只终止本轮明确标识的测试子进程。
3. **内容一致性**：外部改名/前插行 → 重新打开 → stale 提示 → 旧搜索激活被拒绝 → Refresh Index → 新符号正确定位。补目标文件未打开、删除、Unicode、三语言与 mixed。
4. **关系与 Pin**：Reader 定位 B，Pin A，分别通过鼠标菜单和快捷键查询 B；关系正确且 Pin 不变。Inspector 开关与窄宽窗口往返保留选中。
5. **版本与 Compare**：Worktree ↔ commit，比较两个版本；磁盘 HEAD/index/内容不发生应用写入，UI 显示所选版本及降级提示。
6. **预览往返**：源码 → README 内链 → HTML/图片/PDF/文本 → Back/Forward → 源码；控件与布局恢复，禁止外链/本地资源策略仍有效。
7. **阅读证据**：真实 Relations 导航形成 A→B→Back→C，Trail 显示兄弟分支与版本边界；Restore；分别 Freeze Results/Freeze Path；正常 Quit 后重启，Reading Set 恢复、Trail 为空。只操作隔离测试数据，不用预写 session 替代真实入口。
8. **书签与笔记**：隔离数据中创建/打开、drift 拒绝、显式 re-anchor、重启；不改变 M13 原有严格锚点语义。
9. **视觉/AX**：900×600、1000×700、1280×820、1440×900 的内容尺寸；Light/Dark/SI Classic；长名称、长 provider/错误；键盘焦点、tooltip、AX 名称与完整内容、对比度检查。
10. **资源**：S4a 的同机同数据复测；区分新资源首次读取、缓存命中、关闭后回收与切版本峰值，保存原始结果。

每步记录 PASS/FAIL/SKIP/BLOCKED、SHA、bundle、OS、触发方式和证据文件。截图须检查真实内容且未裁切，不能用非空像素代替流程完成。
真实 UI、持久化动作、provider 或系统访问若被工具权限阻止，记录准确限制；不以单元测试、修改用户会话或间接调用绕过。单独的模型/代码检查可以继续，但不冒充该原生步骤 PASS。

零写验证按时间段做：fixture 的受控外部修改是复现步骤，修改后重新取指纹，再比较应用操作前后；不能将主动造出的 drift 误算成应用写入。检查 HEAD、index、status、tracked/untracked 内容；正式 App Support 前后指纹不变。

## 7. 提交、回退与完成判据

- 每片 RED → 最小实现 → GREEN → 代码/实际行为 review → 一个原子提交；本次计划制定不执行提交。
- 提交先处理行为，再做结构，最后样式/文档，避免一片同时改变 resolver、内容来源与视觉。
- 不降低安全限制、几何容差或既有测试数来换取通过；不删除仍在使用的 snapshot/source 内容。
- S1 可独立回退；S2a–S2c 在应用层构成依赖组，回退后必须明确旧一致性缺陷重新存在，不能只撤回 guard 保留表面提示。
- S3 收敛与 S4 资源变更分开，回退资源优化不应撤掉一致性保护。
- S6–S10 样式/文案独立提交，可回退视觉而保留功能修复。临时布局不更改 session schema，减少恢复风险。
- 有明确触发的深层性能切片 S4c 未完成、V0 任一关键真实步骤 BLOCKED/FAIL 时，只能报告部分完成，不能写“所有问题已解决”。

最终验收记录放在 `docs/plans/evidence/reliability-ui-20260905/acceptance.md`，该目录只保存本轮小型日志、测量结果与必要截图，不提交大 fixture 或生成 bundle。

最终交付：当前源码与 review、逐片验证结果、最终 acceptance 文档、同内容改前改后截图、CPU 与内存原始测量、已确认延期项。**不新增不必要的类型或概念；每个新增字段/方法都必须有本计划内的具体消费者与行为。**
