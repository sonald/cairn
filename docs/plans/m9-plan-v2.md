# M9 实现计划 v2.4：Rust 阅读体验与 UI 打磨（2026-08-05，三轮评审修订版）

> **一句话目标**：围绕真实使用中暴露的六个痛点——符号选中不可见、outline 高亮来回跳、
> 侧边栏高度失衡、三区配色不协调、Relations 排版难懂、RA 就绪/空结果策略遗留——把日常
> Rust 阅读体验从"能用"打磨到"顺手、好看、可信"。
>
> **版本沿革**：v1（2026-07-31）从未执行。v2（2026-08-05 上午）以用户反馈重排优先级。
> v2.1 按同日评审修订：基线更新到 `e0160e7`；S4 从"重新测量未知异常"改为
> "先裁决 readiness / null 策略再取证"（N1 已查明）；S1 仲裁收敛到控制器层、
> 删除定时 pin；S5 明确只删旧 certainty 空组、保留状态行合同；S2 先试原生
> selection、删除不存在的跨行验收；S3 / S6 降为"原生方案优先，证据后加码"。
> v2.2 按同日 web 原型评审补订：S2 阶段二自定义样式定为 **Variant B**（主题强调色描边环 +
> 淡填充，`docs/plans/evidence/m9v2-s2-prototypes/`），原生优先两阶段不变；S5 行排版定为
> **两行行式**（path:line 作对齐次级行，`m9v2-s5-prototypes/`）；S6 经用户裁决**扩回三主题
> 三区配色统一**，覆盖 v2.1 的 SI-only 范围（`m9v2-s6-prototypes/`）。
> v2.3 按同日二轮评审修订：S4 拆为 **S4a（readiness 信号取证）→ S4b（分流实现）**，
> readiness 取证先于 `null` 快返，`LSP.swift` 纳入范围；S5 允许 Node 增加**最少量标量
> 展示字段**（禁止 View 解析展示字符串）；S1 事件定为 `didLiveScroll`、仲裁收敛在共享
> 导航入口；S5 行高与 S6 颜色桥的验收措辞对齐实现；两份原型的决策文字与计划同步。
> v2.4 按同日三轮评审修订：S4b 补**取消 / 锁 / 超时合同**（readiness 等待不持有
> `operationLock`、可被取消/退出/超时唤醒、取消后不进 RA、fake LSP 计数断言）；
> 明确**降级 C 只是 mitigation**——无可靠信号时 S4b 与成功合同 6 记 FAIL / 顺延，
> M9 总验收不得 PASS（除非用户另行接受降级目标），C 参数由 S4a 样本决定；
> S4a 探针声明为**可丢弃**；S0 允许在既有 self-test seam 加无行为变化的 telemetry hook。
> v1 的失败态恢复、Profile 入口、完整 AX、搜索收口仍顺延下一里程碑。

---

## §0 事实基线

- `HEAD = e0160e7`（doc: update doc），相对 `origin/main` ahead 5。M8 验收之后新增两个
  提交：`0bcdf17` 把测试 corpora 移到 `~/.cache/cairn-corpora` 并加 loud-fail 守卫；
  `e0160e7` 更新文档（含 M8 验收 §4.1 的 N1 根因诊断）。
- **N1（warm 反常）已查明，不再是未知异常**（`docs/plans/m8-acceptance.md` §4.1，
  2026-08-05）：不存在"warm 比 cold 慢"，是**固定重试睡眠（1s、2s）随机落在哪一相**。
  根因链：rust-analyzer 在快照就绪前对首个请求返回 `null` → 四处 parse 把 `null`
  转成 `nil` → `request()` 把任何 `nil` 一律当"没就绪"盲睡重试。顺带查出两条独立缺陷：
  光标停在**必然为空**的位置也要等满 1s+2s；结果行的 `textDocument/definition`
  踩同一梯子，Context 可能空到 6.5s。M8 报告已给出修法排序：**B（区分 `null` 与
  未就绪，只有 `-32801 content-modified` 算未就绪）最该先做**，A（服务端就绪信号）、
  C（小步退避）视证据跟进。还有一条反面教训：单纯缩短睡眠会让 cold 三次快速重试
  全拿 `null`，**一条 exact 结果都不剩**——就绪等待不能删，只能换机制。
- **当前实现没有任何独立的结构化 readiness 状态**：`request()` 循环只能用请求结果
  反推（`null → 睡眠重试`，非空 → 就绪，`RustAnalyzerProvider.swift:487` 起）；
  `$/progress` 未处理；`experimental/serverStatus` 等 status 通知只被拼进
  `serverDiagnostics` 诊断文本（`LSP.swift:424` 起），从未结构化消费。
  rust-analyzer 的 `experimental/serverStatus` 需要**显式 client capability**
  才会下发，提供 `health` / `quiescent` 字段，官方将其定位为状态通知——
  **能否充当 readiness barrier 必须用当前 RA 版本实测，不能假定**
  （见 rust-analyzer LSP extensions 文档）。这决定了 S4 必须先取证再实现：
  在拿到可靠的就绪信号之前实施"`null` 立即返回"，会把已实测的 cold `null`
  （就绪前的假空）当成合法空结果。
- **现有 `request()` 的并发合同必须被新等待继承**：当前实现刻意把重试等待放在
  `operationLock` 之外（`RustAnalyzerProvider.swift:504`、`:560`），并保留
  锁前、锁后、发送前**三层取消门**；batch / session 取消、进程退出、
  `requestTimeout` 都能终止等待。任何新增的 readiness wait 若在持锁状态下
  睡眠、或绕过取消门，都会退化已有的响应性与可取消性。
- corpus 基础设施已就位：`scripts/provision-corpora.sh`（tokio-1.47.1 + ripgrep-14.1.1，
  含 `--check` 预检）与 `scripts/run-gold-gates.sh`（带 corpus preflight 的 gold gate）。
- **用户 2026-08-05 截图与 HEAD 代码存在矛盾**：截图中 Relations 显示
  `POSSIBLE / EXACT (2) / STRONG / PROBABLE` 分组头（含两个空组），但 `d385db5`
  已改为行内 badge。要么用户在跑旧二进制，要么分组头有残留路径。S0 必须先核实。
- 用户报告的真实痛点（tokio 真机阅读场景）：
  1. 点击符号后没有可见的"当前选中"指示，不知道现在选了什么符号；
  2. 文件树（FILES）与 OUTLINE 的高度分配不合理；
  3. outline 高亮当前符号经常来回跳跃；
  4. FILES / OUTLINE / 代码阅读区配色不协调、不好看；
  5. Relations 区域排版与可理解性差。
- 代码级现状（已核对源码）：
  - Reader 只读可选（`isEditable=false`、`isSelectable=true`），拥有**原生 AppKit
    文本选择能力**。点击后有两层高亮：同名 occurrence 背景色 + 当前行背景。
    没有"这一个才是你点的"主选中标识。`identifierOccurrences`
    （`CodeInsightReaderCore.swift:281`）产出的是**单个词法 identifier**，
    不存在跨行 occurrence。`Prototypes/` 中的选型只比较过四种自定义样式，
    **从未把 AppKit 原生 selection 放进对照组**。
  - outline / Relations 驱动的导航目前**只 `reveal`、不 `activate`**：程序化
    `navigate`（`MainWindowController.swift:3291`）滚动 Reader 后，最终和用户滚动
    走的是**同一个 `onReadingPositionChange`**（100ms viewport 防抖，`:3354`），
    消费端无法分辨来源。点击走 `onSelectionChange`，无防抖。
    `OutlinePanelModel.highlight` 是纯 offset→facet 二分映射；`highlightOutline`
    每次 `selectRowIndexes + scrollRowToVisible`。
  - 侧边栏是 `SidebarViewController` 内垂直 `NSSplitView`，首次 `viewDidLayout`
    （`:2176`）固定 `setPosition(height * 0.65)`。**首次 layout 早于 tree / outline
    数据到达**，彼时无法按内容行数计算比例。divider 可拖但不持久化，未设
    `autosaveName`。
  - 配色是两套体系：Reader 四主题（Auto / Light / Dark / SI Classic）硬编码在
    `ReaderSettings.swift`；侧边栏用 `NSVisualEffectView(.sidebar)`、Relations 用
    `.windowBackground` + 系统色。Auto / Light / Dark 与系统材质本身是协调的；
    割裂主要来自 **SI Classic**：暖纸色 Reader 配冷灰系统侧栏。无 Asset Catalog。
  - Relations 模型（`Sources/CodeInsightAppModel/RelationTreeModel.swift:833` 起）
    **只在 possible 非空时建组**，同时**有意保留** `No verified…`、
    `Verified incomplete…`、offline、truncated 等状态行——实现与
    `Tests/CodeInsightAppModelTests/RelationTreeModelTests.swift:658` 起的测试都把
    这些区别当作合同。行排版：`RelationCellView` 水平 stack
    `[spinner | (title+subtitle 竖排) | badge]`，符号名 12pt 与 `path:line` 10pt
    同行混排，`.edge` 行高 38pt。
- M8 真实遗留（N 表）：N1 已查明待修；N2（183s 挂起）建立不了因果、后续 5 次正常；
  N3（`real-references` 间歇）同一二进制 1 失败后 3/3 通过；N4（tokio 规模未进门禁）。
- 既有验收基础设施：`--self-test-*` 12 个 CLI 入口、`run-self-tests.sh` / `ci.sh` /
  `stress-test.sh` / `run-gold-gates.sh`、offscreen geometry 断言。
- 文件规模警戒：`MainWindowController.swift` 3704 行、`CodeInsightApp.swift` 7128 行；
  本轮沿现有 seam 最小改动，不拆文件。

---

## §1 成功合同

M9 v2 完成时，用户在 tokio 这样的真实 Rust workspace 中应能：

1. 点击任意符号，立刻看到一个**包裹当前符号的选中效果**（主选中），与同名
   occurrence 的次级高亮、当前行背景三层清晰可辨；换主题不失效。
2. 正常滚动阅读一个 500+ 行文件时，outline 高亮**平滑单调地跟随**，不来回抖动；
   点击与程序化导航的意图立即生效，且用户接管滚动后跟随立即恢复。
3. 打开项目后 FILES / OUTLINE 高度可用，手动拖动后的位置在重启与切项目后仍被记住。
4. 在 Light / Dark / SI Classic 三主题下，侧边栏、Reader、Context、Relations
   **看起来属于同一个应用**；SI Classic 不再出现暖纸 Reader 配冷灰侧栏的断层。
5. 打开 Relations，不看文档也能回答"哪些行是验证过的、哪些是推断的、每行是什么
   符号、在哪个文件"；coverage / offline / truncated 等诚实状态行仍在。
6. 光标停在没有调用层级的位置时**不再盲等 3 秒**；cold 场景 Exact 结果不因就绪
   误判而静默丢失；`-32801` 仍可恢复。四方向真实结果有落点级证据与重复样本。
   **本项以 S4a 找到可靠就绪信号为前提**：若实测无可靠信号，降级 C 只是延迟
   缓解、无法区分合法空与 cold 假空，本项如实记 FAIL / 顺延，不以 C 冒充完成。

---

## §2 范围

### 本轮做

- Reader 主选中效果：先真机验证原生 selection，证据不足再启用自定义绘制。
- outline 跟随：控制器层来源仲裁 + 锚定带迟滞 + 滚动礼貌。
- 侧边栏 divider 原生持久化；默认高度只在证据支持时再加内容感知。
- readiness 信号取证（S4a）→ ready / preparing 分流实现（S4b），随后四方向真值取证。
- Relations 行排版收口；只删旧 certainty 空组（若存在），状态行合同不动。
- 三区（侧栏 / Relations / Context）配色统一到 `ReaderTheme` surface：三主题各一组，
  替换系统材质依赖（用户 2026-08-05 原型裁决，扩自 v2.1 的 SI-only）。

### 明确不做（顺延或裁掉）

- v1 的失败态恢复、Profile 单一入口、完整键盘/AX 合同、搜索收口 → 下一里程碑。
  本轮新改 UI 只要求不倒退现有 AX。
- TypeScript / Python、新关系类型、breadcrumb、图视图、书签、Rename。
- 应用级主题系统 / Asset Catalog 迁移 / 第五套主题 / 动画框架。
  （S6 只在现有四主题内把三区 surface 并入 `ReaderTheme`，不是新主题系统。）
- 拆分 MainWindowController / CodeInsightApp 的重构。
- 未经证据支持的：内容感知侧栏比例、自定义 TextKit 选中绘制、
  "手动滚 outline 暂停跟随"之类恢复条件未定义的新机制。

---

## §3 设计裁决

1. **主选中先用平台已有的东西**：Reader 是原生可选择文本，`selectedRange` 高亮
   就是现成的"包裹"。裁决：S2 第一步在真机上把**原生 selection** 与既有
   occurrence / 当前行高亮叠加取证（三主题截图）；只有人工确认原生效果达不到
   "包裹"视觉，才启用自定义绘制（描边 + 填充），且色值进 `ReaderTheme`——
   若进入自定义，样式已由 2026-08-05 原型定为 **Variant B（主题强调色描边环 + 淡填充）**：
   以色相把"我点的这一个"（蓝）与其余同名 occurrence（琥珀 `occurrenceRGB`）分开，
   accent Light `#175CD3` / Dark `#84ADFF` / SI `#163A5F`、淡填充 12–20% alpha
   （原型 `docs/plans/evidence/m9v2-s2-prototypes/`）。
   occurrence 是单个词法 identifier，无跨行情形，不为其设计。
2. **跟随仲裁只放控制器层，模型保持纯函数**：`OutlinePanelModel.highlight`
   维持确定性的 offset→facet 映射，不加迟滞状态。标记**收敛在共享导航入口**：
   所有程序化导航都经由同一入口置"显式导航进行中"标记；该标记在**首次真实
   用户滚动完成事件**解除——事件定为 `NSScrollView.didLiveScrollNotification`
   （AppKit 头文件明确：legacy mouse 滚动可能没有 willStart/didEnd 配对，
   `didLiveScroll` 才表示用户事件实际改变了 viewport），或经真机验证的等价事件。
   不用定时 pin，不做距离稀释，避免"点击后滚动 outline 仍冻结"。
   滚动跟随的锚定带与迟滞同样放在控制器消费端。`scrollRowToVisible` 只在
   目标行不可见时调用。仲裁用真实 App self-test 覆盖；**不为了可测性把 UI
   仲裁下沉成新的 AppModel 类型**。
3. **侧栏先用原生持久化**：`NSSplitView.autosaveName` 是平台内建方案，先上它；
   固定 65/35 默认值保留。只有 S0 取证证明固定默认在真实项目上仍不可用，
   才加"数据首次到达后的一次性内容感知调整"（并须解决 viewDidLayout 早于数据
   到达的时序）。
4. **三区配色统一进主题，但不做主题系统**：把侧栏 / Relations / Context 的
   surface / selection / header / divider 色并入现有 `ReaderTheme`（三主题各一组），
   替换对 `.sidebar` / `.windowBackground` 系统材质的依赖；Auto 跟随系统时退回系统色。
   （用户 2026-08-05 原型裁决：扩自 v2.1 的"仅 SI Classic"，三主题都统一——SI 断层最重、
   Light / Dark 一并收敛到同温度 chrome。）色值只进 `ReaderSettings.swift`，view 层无裸 RGB。
5. **Relations 删噪不删诚实，展示数据结构化不解析**：`No verified…`、
   `Verified incomplete…`、offline、truncated 等状态行是 M8 合同（实现与测试
   双重锁定），**必须保留**。可删的只有旧 certainty 空分组头——且仅当 S0 证明
   HEAD 上确实存在。已选的两行行式需要 dispatch chip 与修饰信息分开呈现，
   而模型只暴露拼接后的 `subtitle`（`RelationTreeModel.swift:1076` 起）——
   裁决：**禁止在 View 解析展示字符串**；允许 Node 增加**最少量的标量展示
   字段**（如结构化 dispatch、修饰短语列表；call-site 计数从 `LoadedEdge.callSites`
   派生，不重复存储），现有 `subtitle` 及其 AX 合同原样保留，**不新增类型**。
   `Verified` 只来自 rust-analyzer，`Inferred` 只表示源码结构推断，语义不动。
6. **readiness 取证必须先于 `null` 快返**：就绪等待不能删（cold 三连 `null`
   丢光 Exact 是实测教训），只能换机制。但当前实现**没有独立的 readiness
   信号**（见 §0），直接实施"`null` 立即返回"会把就绪前的假空当合法空。
   裁决：S4 拆两步——**S4a 先用当前 RA 实测** `experimental/serverStatus`
   （`health` / `quiescent`）、`$/progress` 或其他最小信号能否充当 readiness
   barrier；**确认可靠后 S4b 才分流**：`ready + null` 立即返回空、`preparing`
   等待就绪、`-32801 content-modified` 重试。若实测没有任何可靠信号：
   退而实施 C（小步退避）**仅作为延迟缓解**——C 仍无法区分合法空与 cold 假空，
   本质还是盲重试，**不实施 `null` 快返**，且 S4b 与成功合同 6 记 FAIL / 顺延，
   M9 总验收不得因此 PASS（除非用户另行接受降级目标）。C 的重试次数与总等待
   预算由 S4a 的时序样本推导，不预设固定起点。新等待继承现有取消 / 锁 / 超时
   合同（见 §0），在现有 `LSP.swift` / `RustAnalyzerProvider.swift` seam 内做，
   复用既有 batch / condition，**不建新的 readiness 子系统或协调器类型**。
7. **视觉改动先取证**：先用 HEAD 新构建取证（截图 + geometry + 跟随日志），再动手；
   用户旧截图只用于定位问题域。
8. **跳跃类 bug 用可回放日志验收**：录制必须包含**事件类型、时间戳与滚动轨迹**，
   使回放可复现；验收标准是高亮序列无短窗翻转，翻转次数与"改前"日志可量化对比。

---

## §4 实现切片

### S0：重建取证基线与二进制一致性核对

**目标**：确认用户所见与 HEAD 一致；为每个痛点留下"改前"证据。

**工作**：

- `bash scripts/provision-corpora.sh --check` 预检 corpus；从 HEAD 重新构建。
- 核对 Relations 实际呈现（分组头 vs 行 badge）；给出截图/HEAD 矛盾的结论，
  并确认五个痛点在 HEAD 构建上各自"成立 / 不成立 / 变形"。
- 在 tokio 真机场景取证：900×600 与 1600×1000 × Light / Dark / SI Classic 的
  Reader + 侧边栏 + Relations + Context 截图。
- 录制 outline 跳跃复现（**S1 的对照样本**）：对 `tokio/src/fs/dir_builder.rs`
  匀速滚动与点击，日志逐条记录**事件类型（滚动/点击/导航）、时间戳、滚动位置、
  触发的回调、`highlightOutline` 的 offset 与选中行**——保证可回放复现。
  现有代码没有输出这些信息的日志入口：允许在**既有 App self-test seam**
  增加一个**无行为变化的 telemetry hook**（默认关闭，仅环境变量 /
  `--self-test-*` 开启时记录；不新增 logger 类型）。
- 记录侧边栏固定 65/35 默认值在浅树/深 outline、深树/浅 outline 两种项目下
  是否真实不可用（S3 是否加码内容感知以此为准）。
- 记录三主题下侧栏 / Relations 与 Reader 的真实基准值与失配程度（供 S6 上色参考；
  S6 已定覆盖三主题，此处只为取真实 reader 值与"改前"对照）。

**验收**：

- [ ] `docs/plans/evidence/m9v2-s0/` 取证目录：截图、可回放跟随日志、
  二进制与 corpus 版本说明。
- [ ] 明确回答：截图/HEAD 矛盾原因；五个痛点各自的 HEAD 现状；
  S3 是否需要内容感知；三主题真实 reader 基准值（供 S6 上色）。
- [ ] 除上述 telemetry hook 外不改产品代码；hook 默认关闭、无行为变化
  （关闭时零日志、零副作用），不新增 logger 类型。

**依赖**：无。**预计范围**：S。

### S1：Outline 跟随稳定化

**目标**：滚动时高亮平滑单调，显式意图立即生效，用户接管滚动后跟随立即恢复。

**工作**：

- 控制器层建立来源仲裁（`OutlinePanelModel` 不动，不新增 AppModel 类型）：
  - 程序化导航（outline 点击、Relations 跳转、search 打开等）**收敛到共享导航
    入口**，在该入口置"显式导航进行中"标记，并直接设定 outline 高亮；
  - 标记存续期间，`onReadingPositionChange` 的滚动跟随不覆盖高亮；
  - **首次真实用户滚动完成事件**解除标记，跟随立即恢复。事件定为
    `NSScrollView.didLiveScrollNotification`（`willStartLiveScroll` 会漏掉
    没有 start/end 配对的 legacy mouse 滚动；`didLiveScroll` 表示用户事件
    实际改变了 viewport），或经真机验证的等价事件。无定时器，无距离稀释。
- Reader 点击走 `onSelectionChange` 立即高亮（现状保留），只补"点击后短防抖窗内
  的 viewport 信号不回跳"这一处仲裁。
- 滚动跟随加锚定带 + 迟滞（控制器消费端）：取视口顶部向下一个带（如 1/4 屏），
  新 facet 在带内持续超过现有 100ms 防抖窗才切换。
- `highlightOutline` 仅在目标行不在可见范围时才 `scrollRowToVisible`。
- 不引入"用户手动滚 outline 时暂停自动滚动"机制（恢复条件未定义，裁掉）。

**验收**：

- [ ] 用 S0 的可回放日志重放：高亮序列无 500ms 内 A→B→A 翻转；
  翻转次数与改前日志量化对比（归零或接近零）。
- [ ] outline 点击 / Relations 跳转后高亮立即正确；程序化滚动结束前不被
  viewport 信号覆盖；用户一滚动，跟随立即接管（无 3 秒冻结窗口）。
- [ ] outline 目标行已可见时不滚动；不可见时恰好滚动一次。
- [ ] 仲裁逻辑有**真实 App self-test**覆盖（含 `didLiveScroll` 解除路径）；
  `OutlinePanelModel.highlight` 保持纯函数，已有测试零改动；
  未为可测性新增 AppModel 类型。

**依赖**：S0 的对照日志。**预计范围**：M，2–3 个文件。

**可能触及**：

- `Sources/CodeInsightApp/MainWindowController.swift`
- `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`（识别用户滚动事件）
- `Sources/CodeInsightApp/CodeInsightApp.swift`（App self-test）

### S2：符号主选中效果（原生优先，两阶段）

**目标**：点击后一眼看出"我选的是这一个"，与同名 occurrence、当前行三层可辨。

**工作**：

- **阶段一（原生候选）**：点击 / outline / Relations 导航时把该 occurrence 设为
  `selectedRange`，利用 AppKit 原生 selection 高亮作为主选中；调整
  occurrence / currentLine 色确保三层可辨；三主题真机截图给人工裁决。
  之前 `Prototypes/` 的四种自定义样式没有原生对照组，本阶段补上这个对照。
- **阶段二（仅证据不足时）**：若人工确认原生 selection 达不到已认可的"包裹"
  视觉（如需要圆角描边），才在 `drawBackground` 增加自定义绘制——样式用
  2026-08-05 原型定的 **Variant B**：主题强调色（Light `#175CD3` / Dark `#84ADFF` /
  SI `#163A5F`）圆角描边环 + 12–20% alpha 淡填充，与琥珀 occurrence 以色相分开；
  色值进 `ReaderTheme`。无跨行情形（occurrence 是单个词法 identifier），不做分段绘制。
- **共享导航路径**：outline / Relations 目前只 `reveal` 不 `activate`——收敛为
  同一条导航路径：定位 + 设主选中 + 触发 occurrence 高亮，三个入口
  （Reader 点击、outline、Relations）行为一致。
- Escape / 点击空白清除主选中；AX 复用既有 value/label 通道暴露当前符号名。

**验收**：

- [ ] 阶段一三主题截图 + 人工结论单列；若进入阶段二，附"原生不足"的对比证据。
- [ ] Reader 点击、outline 点击、Relations 跳转三个入口都产生主选中且行为一致；
  Escape 清除。
- [ ] 滚动 / resize 后无残影；与 occurrence、当前行三层在三主题下可辨。
- [ ] `Tests/CodeInsightReaderUITests` 断言主选中 range 状态与清除路径；
  **AppKit 层**对 outline / Relations 导航入口的 activate 行为有真实
  `NSWindow` 集成检查（不以模型测试代替）。

**依赖**：S0；与 S1 共享导航路径改动，S1 先行。**预计范围**：M，3–4 个文件。

**可能触及**：

- `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`
- `Sources/CodeInsightApp/MainWindowController.swift`（共享导航路径）
- `Sources/CodeInsightReaderCore/ReaderSettings.swift`（仅阶段二需新色值时）
- `Tests/CodeInsightReaderUITests/ReaderTextViewTests.swift`

### S3：侧边栏 divider 持久化（原生方案）

**目标**：手动调整被记住；默认高度是否加码以 S0 证据为准。

**工作**：

- 给侧栏 `NSSplitView` 设**唯一** `autosaveName`（平台内建持久化），保留固定 65/35
  初始默认；校对两 pane minimum 高度（标题 + 至少 3 行）。
  self-test 使用专用 `autosaveName` 并在测试前后清理 UserDefaults，避免污染
  真实 divider 设置。
- **仅当** S0 证明固定默认在真实项目上不可用：加"树/outline 数据首次到达后的
  一次性内容感知调整"（解决 viewDidLayout 早于数据的时序），且用户已有
  autosave 值时不介入。

**验收**：

- [ ] 拖动 divider → 重启 → 位置恢复；切项目不丢。
- [ ] 既有 `selfTestSidebarGeometry` / `selfTestDividerSurvivesPlaceholderRefresh`
  继续通过，补持久化断言；self-test 使用专用 `autosaveName` 并在前后清理
  UserDefaults，不污染真实 divider 设置。
- [ ] 900×600 下两 pane 都不塌缩到不可用。
- [ ] 若加了内容感知：浅树/深 outline 与深树/浅 outline 的默认分割截图；
  若没加：S0 证据中记录"固定默认足够"的结论。

**依赖**：S0。**预计范围**：S，1–2 个文件。

**可能触及**：

- `Sources/CodeInsightApp/MainWindowController.swift`
- `Sources/CodeInsightApp/CodeInsightApp.swift`（sidebar geometry self-test）

### S4a：readiness 信号取证

**目标**：用当前 rust-analyzer 实测：是否存在可靠的就绪信号可充当 readiness
barrier。**在此之前不实施任何 `null` 快返。**

**工作**：

- 在 initialize 时声明 `experimental/serverStatus` client capability，结构化
  接收该通知（当前 `LSP.swift:424` 只把 status 拼进 `serverDiagnostics` 文本），
  记录 `health` / `quiescent` 的到达时序；同时记录 `$/progress`
  （workDoneProgress）的可用性。
- 对照实测：cold 启动后，`quiescent`（或 progress 完成）时刻 vs
  首个 `prepareCallHierarchy` 从 `null` 变为非空的时刻——信号可靠的判据是
  **信号到达后请求不再返回假空**（多次独立 cold 样本，含 `exact_fixture`
  与 tokio 两种规模）。
- 只做取证与**可丢弃的 instrumentation**（capability 声明 + 结构化接收 +
  时序记录），不改 `request()` 重试策略；产出一份简短结论：可靠信号是什么、
  时序余量多大、或"没有可靠信号"。**探针代码不预设永久保留**——只有被 S4b
  选为 barrier 的信号才进入产品代码；若信号不可靠，instrumentation 与对应
  测试一并移除，仅保留 `docs/plans/evidence/m9v2-s4a/` 取证文档。

**验收**：

- [ ] 取证结论落盘（`docs/plans/evidence/m9v2-s4a/`）：每个候选信号的原始时序
  样本（≥5 次独立 cold）、判定结果；若走降级 C，附带由样本推导的重试次数与
  总等待预算（不预设固定起点）。
- [ ] 若信号被 S4b 选中：`serverStatus` / progress 通知已被结构化接收且有测试；
  `serverDiagnostics` 原有行为不变。若信号不可靠：探针代码与测试**不进入
  最终产品**，仅取证文档保留。
- [ ] 明确裁决 S4b 走哪条路：`quiescent` barrier / progress barrier /
  **无可靠信号 → 降级 C（mitigation only，S4b 与成功合同 6 记 FAIL / 顺延）**。

**依赖**：无（可与 S1–S3 并行）。**预计范围**：S–M。

**可能触及**：

- `Sources/CodeInsightExact/LSP.swift`（capability 声明与 serverStatus 结构化接收；
  **仅被 S4b 选中时保留**，否则可丢弃）
- `Sources/CodeInsightExact/RustAnalyzerProvider.swift`（仅暴露取证所需时序）
- `Tests/CodeInsightExactTests/`（探针测试同上可丢弃规则）

### S4b：ready / preparing 分流与四方向真值门

**目标**：按 S4a 证实的信号分流，修 N1 根因；再用重复样本证明四方向真实能力可信。
**无可靠信号时本切片与成功合同 6 记 FAIL / 顺延**（降级 C 只是 mitigation）。

**工作**：

- **分流实现**（**仅当** S4a 证实信号可靠）：`ready` 状态下 `null` = 合法的
  "这里没有"，立即返回空；`preparing` 状态下等待就绪信号（替代盲睡）；
  `-32801 content-modified` 保持重试。在现有 `request()` seam 内实现，
  复用既有 batch / condition，**不建新的 readiness 子系统或协调器类型**。
  **取消 / 锁 / 超时合同**（继承现有实现，见 §0）：
  - readiness 等待**不持有 `operationLock`**（与现有重试睡眠同层，`:504`、`:560`）；
  - 等待期间 batch / session 取消、进程退出、`requestTimeout` 能唤醒等待；
  - 取消后不再进入 rust-analyzer（保留锁前、锁后、发送前三层取消门）；
  - fake LSP 测试直接断言**请求数与等待数**，不依赖耗时。
  若 S4a 结论是"无可靠信号"：可退而实施 C（小步退避，参数由 S4a 样本推导），
  **不实施 `null` 快返**；C 只是延迟缓解、无法区分合法空与 cold 假空，
  **S4b 与成功合同 6 记 FAIL / 顺延**，M9 总验收不得因此 PASS
  （除非用户另行接受降级目标）。
- **重复取证**：`bash scripts/provision-corpora.sh --check` 预检后，
  在 `exact_fixture` 上独立进程重复真实 provider，四方向输出实际落点，
  References 不再只留 `textDocumentReferencesReached=true`；连续 10 个独立样本。
  `real-references` / `real-implementations` 复现则定位共同消费点根因修一次，
  未复现则不改产品代码、保留原始频率。
- tokio `lock` 按 M8 同 corpus / offset 记录 5 组 cold / warm 首行与全结果；
  用 `scripts/run-gold-gates.sh` 跑 gold gate 确认策略改动无回归。

**验收**：

- [ ] **S4b 总体裁决**：S4a 有可靠信号 → 本切片 PASS；无可靠信号 → 本切片
  **FAIL / 顺延**（降级 C 仅 mitigation，不得记 PASS）。
- [ ] **合法空结果不盲等**（**仅**走分流时）：ready 后光标停在无调用层级/定义的位置，
  结果在无重试睡眠的时间尺度内返回（对照 N1 记录的 1s+2s）。
- [ ] **cold Exact 不静默丢失**：cold 场景四方向仍产出预期落点
  （incoming `relation_root`/`main`、outgoing `answer`、implementation
  `ExactFixtureBackend`、reference `main.rs` 落点），无"快速失败拿零结果"回归。
- [ ] **`-32801` 仍可恢复**：content-modified 后重试路径有测试覆盖。
- [ ] **取消 / 锁 / 超时合同**（走分流时）：readiness 等待不持有 `operationLock`；
  batch / session 取消、进程退出、`requestTimeout` 能唤醒等待；取消后不再进入 RA；
  fake LSP 断言请求数与等待数（不依赖耗时）。
- [ ] 不受限真机 10/10 通过；失败保留 JSON、stderr、RA 版本与耗时。
- [ ] tokio 5/5 首个可操作行 ≤ 1s；全结果原始值全部报告；结果行 Context 延迟
  （N1 顺带查出的 6.5s 问题）一并测量报告。
- [ ] `run-gold-gates.sh` 双 corpus 通过；`sandbox-exec` 不可用记 **BLOCKED**。

**依赖**：S4a 的取证裁决。**预计范围**：M。

**可能触及**：

- `Sources/CodeInsightExact/RustAnalyzerProvider.swift`（`request()` 重试条件
  与四处 `null` parse）
- `Sources/CodeInsightExact/LSP.swift`（就绪状态消费）
- `Sources/CodeInsightApp/CodeInsightApp.swift`（复用 `runExactSelfTest` 与
  relation timing 入口）
- `Tests/CodeInsightExactTests/`（含 fake LSP 请求数 / 等待数断言；取消 / 锁 /
  超时合同）

### S5：Relations 排版与可理解性

**目标**：不查文档能读懂每一行；删噪、对齐、层级清楚；**状态行合同零改动**。

**工作**（以 S0 对 HEAD 的取证结论为准）：

- 空组处理的边界：**只删旧 certainty 空分组头，且仅当 S0 证明 HEAD 上存在**。
  `No verified…`、`Verified incomplete…`、offline、truncated 等状态行是 M8 合同
  （`RelationTreeModel.swift:833` 起的实现与 `RelationTreeModelTests.swift:658`
  起的测试双重锁定），**必须保留**。
- 模型侧最小增量（§3.5 裁决）：两行行式需要 dispatch chip 与修饰信息
  （`3 call sites`、`name match only` 等）分开呈现，而 Node 目前只有拼接后的
  `subtitle`（`RelationTreeModel.swift:1076` 起）。给 Node 增加**最少量标量
  展示字段**（结构化 dispatch、修饰短语列表）；call-site 计数等数值**从现有
  `LoadedEdge.callSites` 派生**，不重复存储同一计数。拼接逻辑与现有
  `subtitle` / AX 合同原样保留，不新增类型；**禁止在 View 解析 `subtitle`
  字符串**。
- `RelationCellView` 拆层（2026-08-05 原型定为**两行行式**，`m9v2-s5-prototypes/`）：
  符号名为主行；`path:line`（等宽、统一截断方向）+ dispatch chip + 修饰信息作
  对齐的**次级行**；badge 做成右上对齐的药丸；行高**同 kind 稳定**（原型
  edge 44pt、折叠/证据行更矮），消除现状 edge 内部 title/subtitle 挤压。
  （单行列式作宽窗密集档备选，本轮不实现。）
- 折叠行（`Show N possible matches`）的缩进、字号与计数与正常行区分明确。
- badge 保持 `Verified` / `Inferred`；tooltip / AX value 不倒退。

**验收**：

- [ ] tokio 真实四方向结果截图（三主题）：行层级、对齐清楚；**同 kind 行高
  稳定、相邻两行 edge 内容不重叠**；人工结论单列。
- [ ] 状态行（coverage / offline / truncated / unsupported）全部原样保留；
  `RelationTreeModelTests` 与 `RelationNavigationTests` **既有断言零改动**全绿
  （新增展示字段只允许增量断言；若 S0 证明确需删 HEAD 上真实存在的空组，
  相应测试变更单独说明）。
- [ ] View 层不解析 `subtitle` 等展示字符串（chip / 修饰信息全部来自
  结构化字段）。
- [ ] 长路径截断后完整值可由 tooltip / AX 读取。
- [ ] Relations geometry self-test（不重叠、segment 可见）继续通过。

**依赖**：S0、S4b（用真实数据打磨）。**预计范围**：M，2–3 个文件。

**可能触及**：

- `Sources/CodeInsightApp/RelationWindowController.swift`
- `Sources/CodeInsightAppModel/RelationTreeModel.swift`（Node 标量展示字段；
  空组渲染仅 S0 证明存在时）
- `Tests/CodeInsightAppModelTests/RelationTreeModelTests.swift`（增量断言）

### S6：三主题三区配色统一

**目标**：Light / Dark / SI Classic 三主题下侧栏 / Reader / Relations / Context
属于同一个应用；不建应用级主题系统。

**工作**：

- 在 `ReaderTheme` 为三主题各增一组 surface 色，`SidebarViewController` /
  `RelationWindowController` / Context 面板改从 theme 取色，替换 `.sidebar` /
  `.windowBackground` 系统材质；Auto 跟随系统时退回系统色。原型定的起点值：

  | 主题 | chrome（侧栏/Rel 背景） | chrome2（header） | divider | sel（选中行） | accent（主选中/链接） |
  |---|---|---|---|---|---|
  | Light | `#F4F5F7` | `#ECEEF1` | `#E1E4EA` | `#E7F0FF` | `#175CD3` |
  | Dark | `#252528` | `#2C2C30` | `#34363B` | `#2C3644` | `#84ADFF` |
  | SI Classic | `#EEE7D6` | `#E7DEC9` | `#DAD0B9` | `#E7DAB9`（暖金） | `#163A5F`（navy） |

  content / fg / occurrence / currentLine / 语法色沿用现有 `ReaderTheme` 值不变；
  SI 选中行走暖金、navy 只留给 S2 主选中描边这一个锐强调
  （原型 `docs/plans/evidence/m9v2-s6-prototypes/`）。
- 选中色与 S2 的主选中、occurrence 色同表管理，同主题内不打架。
- **Auto 的系统语义色在既有 AppKit 颜色桥统一处理**
  （`CodeInsightReaderUI.swift:5` 起的 `NSColor(name:nil)` 动态桥），
  三区控制器只消费桥出来的 `NSColor`，不各自重复 RGB → NSColor 转换。

**验收**：

- [ ] Light / Dark / SI Classic 三主题整窗截图（两尺寸）：无冷暖/明暗断层，
  SI Classic 暖纸色延伸到侧栏与 Relations，人工结论单列。
- [ ] 主题切换后侧栏、Relations、Context 同代更新，无旧色闪回。
- [ ] view 层无新增裸 RGB（色值只在 `ReaderSettings.swift`）。

**依赖**：S0（取证 reader 值与失配程度）、S2 / S3 / S5（布局与选中定型后上色）。
**预计范围**：S–M，4 个文件。

**可能触及**：

- `Sources/CodeInsightReaderCore/ReaderSettings.swift`
- `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`（既有 AppKit 颜色桥）
- `Sources/CodeInsightApp/MainWindowController.swift`
- `Sources/CodeInsightApp/RelationWindowController.swift`

### S7：M9 v2 总验收

**自动化门禁**：

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache" \
swift test --disable-sandbox

bash scripts/provision-corpora.sh --check
CODEX_SANDBOX=1 bash scripts/ci.sh
CODEX_SANDBOX=1 bash scripts/run-self-tests.sh <git-repo> <non-git-dir> <open-file>
CODEX_SANDBOX=1 bash scripts/stress-test.sh --runs 5 --load 8 --timeout 180
bash scripts/run-gold-gates.sh
```

**真实体验验收**（tokio 真机）：

- 完整走一遍 §1 成功合同 1–5 与 6 中 cold Exact / `-32801` / 四方向样本部分：
  主选中、outline 平滑跟随（回放脚本对比 S0 日志）、divider 持久化、主题协调、
  Relations 可读。
- **成功合同 6 的"空结果不盲等"**：仅当 S4a 找到可靠信号且 S4b 分流落地时记 PASS；
  若 S4a 无可靠信号、S4b 降级 C，本项记 **FAIL / 顺延**，M9 总验收不得因此 PASS
  （除非用户另行接受降级目标）。
- S4a 的 readiness 取证结论、S4b 的分流实现证据（或 FAIL / 顺延记录）、
  四方向重复样本与 M8 对照数字齐全。
- 900×600 与 1600×1000 × 三主题关键状态截图归档。

**边界审计**：

- [ ] canonical dump 零 diff；`goldset/` 零 diff；`RECORD` 未设置。
- [ ] `Tests/RustExtractorTests/Fixtures/`、`Prototypes/`、`.zcache/` 未改。
- [ ] real provider 受限项单列 **BLOCKED**，不并入通过率。
- [ ] 交付 `docs/plans/m9-acceptance.md`：逐项 PASS / FAIL / BLOCKED、
  环境与原始 artifact；主观视觉项单列人工结论。

**依赖**：S0–S6。**预计范围**：S；只新增验收报告，发现缺陷退回对应切片。

---

## §5 顺序与检查点

| 顺序 | 切片 | 原因 |
|---|---|---|
| 1 | S0 | 先核实二进制一致性、留可回放的"改前"证据；S3/S5/S6 的加码与范围都以此裁决 |
| 2 | S1 | outline 跳跃是最高频干扰；建立控制器层仲裁，供 S2 的共享导航路径复用 |
| 3 | S2 | 主选中先原生后自定义；依赖 S1 的导航路径收敛 |
| 4 | S3 | 原生 autosave，小而独立 |
| 5 | S4a | readiness 信号先取证；可与 S1–S3 并行 |
| 6 | S4b | 按取证结论分流实现，修 N1 根因；必须先于 S5 |
| 7 | S5 | 用真实四方向数据打磨排版 |
| 8 | S6 | 布局与选中定型后做三主题三区配色统一 |
| 9 | S7 | 总验收 |

### Checkpoint A：S0–S2

- [ ] 取证目录齐全、二进制矛盾有结论；outline 回放零翻转；主选中三主题可见，
  原生/自定义的裁决有截图证据。
- [ ] 全量 Swift tests 通过；受限项如实 BLOCKED。

### Checkpoint B：S3–S5

- [ ] divider 持久化；S4a 取证结论落盘；S4b 有可靠信号时分流落地且合法空结果
  不盲等、cold Exact 无丢失；**无可靠信号时 S4b 与成功合同 6 记 FAIL / 顺延**
  （降级 C 仅 mitigation）；
  Relations 排版收口且状态行合同零改动。

### Checkpoint C：S6–S7

- [ ] 三主题三区配色统一完成；全门禁（含 corpus preflight 与
  gold gates）、真实体验、边界审计交账，验收报告落盘。

---

## §6 风险与对策

| 风险 | 对策 |
|---|---|
| 用户所见来自旧构建，痛点在 HEAD 上已部分失效 | S0 先核实；各切片验收以 HEAD 新构建取证为准 |
| readiness 信号（serverStatus / progress）实测不可靠 | S4a 先取证再实现；无可靠信号则 S4b 与成功合同 6 记 FAIL / 顺延，降级 C 仅 mitigation、M9 总验收不得 PASS（除非用户另行接受降级目标）；C 参数由 S4a 样本推导 |
| readiness 等待破坏现有取消 / 锁合同 | S4b 硬门：等待不持有 `operationLock`；batch / session 取消、进程退出、`requestTimeout` 可唤醒；fake LSP 断言请求数与等待数 |
| 分流后仍把真实未就绪误判为合法空，cold 静默丢结果 | 验收硬门：cold 四方向落点必须齐全；`-32801` 恢复路径有测试；gold gates 双 corpus 通过 |
| 显式导航标记因事件识别不准而泄漏（不解除/早解除） | 解除事件用 `didLiveScroll`（覆盖 legacy mouse）；真实 App self-test 覆盖解除路径；回放日志包含事件来源可事后审计 |
| 原生 selection 视觉不达标导致 S2 返工 | 两阶段本身就是对策：阶段一只动 selection 与配色，代价小；进入阶段二须附对比证据 |
| "排版打磨"误删状态行、破坏 M8 合同 | `RelationTreeModelTests` / `RelationNavigationTests` 既有断言零改动全绿为硬门；模型改动仅限增量展示字段与 S0 证明的空组 |
| 三区上色蔓延成主题系统 | 只把 surface / selection / header / divider 并入 `ReaderTheme`，模型与交互零改动；三主题整窗截图对照，Auto 仍跟随系统 |
| 迟滞/仲裁调参变成玄学 | S0 录制含事件、时间戳、滚动轨迹的可回放日志；翻转次数量化对比 |
| 大控制器诱发顺手重构 | 单切片超过 5 个文件先拆片；本轮不拆 MainWindowController |

**v2.4 无待确认项。** 默认按 S0 → S7 执行；每片开始前只读取该片关联代码与验收合同。
