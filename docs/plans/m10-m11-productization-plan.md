# M10/M11 产品化收口修改计划 v1

日期：2026-08-29

计划基线：`17610774e985c80aae59bbd526ef1111280b6c6d`

状态：**待批准；本文件只制定计划，不授权修改生产代码或提交**

上面的 SHA 只记录计划制定时的事实基线。实施前的 `PLAN_BASE` 必须是包含已批准计划的实际提交，
不能继续沿用该 SHA，也不能用未提交工作树冒充实施基线。

## §0 结论先行

本轮不再增加阅读能力，而是让既有能力能被首次用户走通、被普通用户看懂，并诚实表达边界：

1. 修复首次打开项目时语言选择器被压缩、无法可靠操作的 P0 阻断；
2. 明示 Reading Trail 是**当前会话**的导航轨迹，增强空态和分支入口的可发现性；
3. 明示 Reading Set 是从 Trail 或 Relations **冻结出来的证据快照**，统一英文文案；
4. 没有文件时禁用 Reading Height，避免可见但无作用的控件；
5. 在现有中英文 README 中写清一条可复现的 Explainable Reading 工作流；
6. 用新 bundle id 做真实 AppKit 首次启动、分叉、冻结、折叠和重启验收。

本轮**不持久化 Reading Trail**。现有 Trail 浮层已经写明 `THIS SESSION`，Reading Set 已承担跨重启冻结；
把 Trail DAG 和 explanation store 塞进 `SessionCodec` 会扩大持久化边界，却没有已验证的用户需求。

## §1 当前事实基线

### §1.1 已有能力可复用

- `ReadingTrail`、`ResolutionExplanationStore`、`ReadingTrailView` 已支持 cause breadcrumb、分叉、
  frozen/current explanation、恢复节点和从路径创建 Reading Set。
- `ReadingSetExcerpt`、`FrozenInspectorDisplay`、`TabContent.readingSet` 已支持冻结源码、证据、来源、
  Open / Expand / View Evidence、50 段上限、skipped reason 和跨重启恢复。
- `ReadingHeightLevel`、折叠 reducer、Focus、查找、diff、occurrence 和复制合同已经闭合；本轮不改折叠模型。
- M13 明确不允许在 Reading Set 上创建书签；本轮不反向扩大 M13 范围。
- 当前针对 Trail、Reading Set 和 ReaderUI 的定向命令：
  `swift test --disable-sandbox --filter 'ReadingSetViewTests|RelationNavigationTests|ReaderUITests'`
  已在计划制定前得到 **92 / 92 PASS**。

### §1.2 本次产品审计发现

| ID | 现象 | 影响 | 优先级 |
|---|---|---|---|
| P0-1 | `Choose Languages` 的三个 checkbox 在真实 `NSAlert` 中被压成极小控件 | 首次用户无法可靠打开项目，后续 M10/M11 全部不可达 | P0 |
| P1-1 | 顶部 Trail 空态只说导航会出现，`⑂` 入口只能靠 tooltip 理解 | 用户不知道从哪里产生 Trail，也不知道它只活在当前会话 | P1 |
| P1-2 | Relations 的 `Reading Set` 按钮没有表达“冻结结果”；Trail 按钮写成 `Open` | 用户容易把它理解成可编辑、可整理的一般清单 | P1 |
| P1-3 | Reading Set 标题/状态为英文，段数和三项操作为中文 | 产品语言不一致，且 M10/M11 原合同未完成中文本地化 | P1 |
| P2-1 | 空项目/空文件时 Reading Height 仍显示为可操作状态 | 暗示一个当前不存在的操作对象 | P2 |
| P2-2 | README 只笼统写 folding/navigation history，未解释 Trail → Reading Set → restart | 能力存在但用户无法从产品资料发现 | P2 |

### §1.3 根调用链

```text
File ▸ Open Project…
  → CodeInsightApplicationDelegate.chooseLanguagesProject
  → NSAlert.accessoryView(NSStackView + 3 checkboxes)
  → MainWindowController.openProject(root:languages:)

semantic navigation
  → AppModel.navigate / ReadingTrail.record
  → MainWindowController.renderTrail
  → ReadingTrailView
      ├─ Restore this node
      └─ Open as Reading Set

Relations published rows
  → RelationWindowController Reading Set button
  → MainWindowController / AppModel freeze excerpts
  → TabContent.readingSet
  → ReadingSetView

file reader state
  → ReaderViewController.display(file | readingSet | empty)
  → readingHeightControl visibility/enabled state
```

## §2 成功合同

### §2.1 首次进入

1. 使用从未运行过的新 bundle id 打开 Cairn，选择项目后，Rust / Python / TypeScript 三项都完整可见；
2. checkbox 可用鼠标和键盘选择，1–3 项时 Open enabled，0 项时 disabled；
3. 选中 Rust 后能进入真实项目并看到文件树；不能用预写 session、UserDefaults 或 self-test 注入绕过此流。

### §2.2 Trail

1. 空态直接说明：Trail 来自 Relations 等显式语义导航，并且只属于当前会话；
2. 入口不用只有内部含义的 `⑂` 字符，线性路径和分叉路径都能看懂如何打开详情；
3. 既有 cause、分叉 DAG、snapshot boundary、frozen/current explanation 和 Restore 行为零变化；
4. 退出重启后 Trail 可以为空，但界面不得让用户误以为发生了数据丢失。

### §2.3 Reading Set

1. Relations 入口表达“冻结当前结果”，Trail 入口表达“冻结当前路径”；
2. tab 仍叫 Reading Set，仍按现有 producer/path 顺序、50 段 cap、无 dedup 合同工作；
3. 所有产品文案统一为英文；本轮不引入 localization framework；
4. Open File / Expand Context / View Evidence 的 availability、source drift 和 frozen evidence 行为零变化；
5. Reading Set 跨重启恢复；不获得书签、折叠、⌘F、Focus、重排、删除单卡或共享能力。

### §2.4 Folding / Reading Height

1. 没有 active file 时 Reading Height disabled；文件加载完成后 enabled；Reading Set 中继续隐藏；
2. Full / Structure / Overview、Toggle Fold、Focus、隐藏命中、自动展开和复制合同零变化；
3. 菜单、快捷键和 AX 名称零倒退。

### §2.5 质量边界

- 不新增 production `struct` / `class` / `enum` / `protocol`；
- 不修改 `CodeInsightCore`、`CodeInsightAppModel`、`CodeInsightReaderCore`、`CodeInsightReaderUI`；
- 不修改 `SessionCodec`、`ReadingTrail`、`ReadingSetExcerpt`、`TabContent`、Bookmark 模型；
- 不新增依赖、持久化文件、UserDefaults key、feature flag 或 registry；
- 不修改语料、goldset、fixture、canonical dump 或项目文件内容。

## §3 范围

### §3.1 允许修改

- `Sources/CodeInsightApp/CodeInsightApp.swift`
- `Sources/CodeInsightApp/ReadingTrailView.swift`
- `Sources/CodeInsightApp/ReadingSetView.swift`
- `Sources/CodeInsightApp/RelationWindowController.swift`
- `Sources/CodeInsightApp/MainWindowController.swift`
- 对应的既有 `CodeInsightAppTests`；优先扩展已有测试文件，不新建测试 target
- `README.md`、`README.zh-CN.md`
- 本计划及最终 acceptance/evidence 文档

### §3.2 明确不做

- Trail 持久化、跨启动 DAG、跨设备 Trail；
- Reading Set 的 tags、文件夹、重排、去重、单卡删除、协作、分享、导入导出；
- Reading Set 上的 bookmark、notes、fold、Focus、⌘F；
- 修改 50 段 cap 或 Relations 的 producer 顺序；
- 全量中文本地化、`.xcstrings` 引入或语言偏好设置；
- 新 onboarding window、view controller、state model 或 coordinator；
- 拆分 `CodeInsightApp.swift` / `MainWindowController.swift`；
- M10/M11 语义模型、Exact provider、索引、snapshot replay 或 M13 持久化改造。

## §4 产品与实现裁决

### §4.1 语言选择器只修原生布局

继续使用当前 `NSAlert + NSStackView + NSButton(checkboxWithTitle:)`。在把 stack 赋给
`alert.accessoryView` 前，使用 AppKit 的 intrinsic/fitting size 给 accessory 明确尺寸；不新建自定义窗口或 controller。

现有 `mixedLanguageCheckboxes` 与 `mixedLanguageOpenButton` 继续作为唯一选择状态，不增加 view model。

### §4.2 Trail 保持 session-only

- 顶部空态改为：`Navigate from Relations to build a trail · this session only`；
- 详情按钮使用可读文字：无分叉时 `Trail Details`，有分叉时 `Branches · N`；
- tooltip 与 AX 继续包含 `⌥⌘T` 和 `Show Reading Trail branches`；
- popover 内既有 `THIS SESSION`、`AT NAVIGATION`、`CURRENT` 保持不变。

不触碰 `SessionCodec`。若未来真实访谈或使用数据证明用户需要跨重启续接 DAG，再单独设计持久化合同。

### §4.3 Reading Set 定位为 frozen evidence set

- Relations 按钮：`Freeze Results`；
- Relations tooltip：`Freeze up to 50 published locations as a Reading Set`；
- Relations AX label：`Freeze Results as Reading Set`；
- Trail 按钮：`Freeze Path as Reading Set`；
- subtitle：`N excerpts · frozen at capture`；
- card actions：`Open File` / `Expand Context` / `View Evidence`；
- empty state：`No excerpts could be frozen. Review the skipped reasons above.`。

只改 copy 和既有控件状态，不改 excerpt capture、source gate、cap、tab 生命周期或 codec。

### §4.4 Reading Height 只在有文件时可操作

复用 `ReaderViewController` 已有的 file / readingSet / empty 显示分支：

- empty：控件可见但 disabled，保留发现性；
- file ready：enabled；
- Reading Set：沿用现状 hidden；
- loading/failed：disabled，不能保留上一个文件的可操作假象。

不增加新的 reader state enum；直接由已有 display 分支设置 `isEnabled`。

## §5 实施切片

### S1：修复首次语言选择器

**目标：** 新 bundle id 的首次项目打开不再被 accessory layout 阻断。

**改动：**

- 在 `chooseLanguagesProject` 内给现有 stack 安装确定的 fitting size；
- 扩展 `CodeInsightApp.swift` 的既有 AppKit self-test，检查三个 label 可见、frame 非零且互不重叠，
  以及 Open 的 0/1/3 项 gate；
- 不抽新类型，不新增 UserDefaults。

**验收：**

- [ ] Rust / Python / TypeScript 三项视觉完整，最小窗口下不裁切；
- [ ] AX 顺序与视觉顺序一致；
- [ ] 0 项 disabled，1–3 项 enabled；
- [ ] 新隔离 bundle 真实完成 `Open Project → choose Rust → files visible`。

**验证：**

- [ ] `swift build --disable-sandbox --product codeinsight-app`
- [ ] `.build/debug/codeinsight-app --self-test`
- [ ] 签名 AppKit 包截图与 AX dump

**依赖：** 无。

**预计范围：** S，1 个 production 文件，扩展既有自检。

**保存点：** `fix: make first-run language selection usable`

### S2：收口 Trail 的可发现性和 session 边界

**目标：** 不读计划也能知道 Trail 从哪里来、如何打开、何时消失。

**改动：**

- 只调整 `ReadingTrailView` 的空态和详情按钮文案；
- 更新 `RelationNavigationTests` 的 title / AX / branch-count 断言；
- 保留所有导航数据和恢复调用链。

**验收：**

- [ ] 空 Trail、线性 Trail、1 个分叉、多个分叉四种状态文案正确；
- [ ] `⌥⌘T`、鼠标和 AX action 都能打开同一 popover；
- [ ] `spawn → A → Back → B → Restore A` 不丢 B 分支；
- [ ] `git diff` 证明 `SessionCodec` / `AppModel` 零变化。

**验证：**

- [ ] `swift test --disable-sandbox --filter RelationNavigationTests`
- [ ] 900×600 最小窗口和 1280×820 默认窗口真实截图

**依赖：** S1，确保真实入口可达。

**预计范围：** S，1 个 production 文件 + 1 个既有测试文件。

**保存点：** `fix: clarify session-scoped reading trails`

### S3：统一 Reading Set 的冻结语义和语言

**目标：** 用户能区分“冻结结果/路径”与一般可编辑清单。

**改动：**

- 更新 Relations、Trail、Reading Set 三处既有按钮/状态/空态 copy；
- 更新 `ReadingSetViewTests`、`RelationNavigationTests` 的精确文案和 AX 断言；
- 不修改冻结、cap、skipped、Open/Expand/Evidence 行为。

**验收：**

- [ ] Relations 入口明确是冻结最多 50 个已发布 location；
- [ ] Trail 入口明确只冻结当前 root→node path；
- [ ] Reading Set 页面不存在中英混排；
- [ ] 全部来源不可读时仍打开诚实空集合并显示 skipped reasons；
- [ ] bookmark 继续显示 `Reading Sets cannot be bookmarked.`。

**验证：**

- [ ] `swift test --disable-sandbox --filter 'ReadingSetViewTests|RelationNavigationTests|ReadingSetTests'`
- [ ] Light / Dark / SI Classic 同一五段 Reading Set 截图与 AX dump

**依赖：** S2，先固定 Trail 上的动作名称。

**预计范围：** M，3 个 production 文件 + 2 个既有测试文件。

**保存点：** `fix: present reading sets as frozen evidence`

### S4：禁用无对象的 Reading Height

**目标：** 控件状态与 active content 一致，不暗示空操作。

**改动：**

- 在已有 empty / loading / failed / file-ready 分支设置 `readingHeightControl.isEnabled`；
- Reading Set 继续走既有 hidden 分支；
- 扩展 `MainWindowControllerTests` 或现有 self-test 状态，不增加状态模型。

**验收：**

- [ ] 无项目、索引中、打开失败时 disabled；
- [ ] 文件 first paint 后 enabled；
- [ ] Reading Set active 时 hidden，切回 file 后 enabled；
- [ ] segment、Folding 菜单和快捷键仍共用既有 reducer。

**验证：**

- [ ] `swift test --disable-sandbox --filter 'MainWindowControllerTests|ReaderUITests'`
- [ ] 空态 → 文件 → Reading Set → 文件真实回放

**依赖：** S1。可与 S2 并行实现，但提交独立。

**预计范围：** S，1 个 production 文件 + 1 个既有测试文件。

**保存点：** `fix: disable reading height without an active file`

### C1：产品入口检查点

- [ ] S1–S4 每片各自测试通过并有独立提交；
- [ ] 没有新增 production 类型、持久化、依赖或状态源；
- [ ] `SessionCodec`、AppModel、ReaderCore、ReaderUI、Bookmark 模块零 diff；
- [ ] 主窗口最小尺寸无裁切、重叠或不可达按钮；
- [ ] 用户确认 copy 和 session-only / frozen 定位后再进入文档与总验收。

### S5：补齐现有 README 的任务说明

**目标：** 用户不读内部计划也能走完 Explainable Reading 主路径。

**改动：**

- 在 `README.md` 与 `README.zh-CN.md` 的 Features 后增加同构短节；
- 只描述四步：打开项目 → 从 Relations 语义导航 → 在 Trail 分叉/恢复 → Freeze 为 Reading Set；
- 明示 Trail session-only、Reading Set 可恢复、Folding 只作用于文件 Reader；
- 列出现有 `⌘I`、`⌥⌘T`、`⌥⌘0/1/2`、`⌥⌘F`，不新增快捷键表系统。

**验收：**

- [ ] 中英文事实、快捷键和边界逐项一致；
- [ ] README 不承诺 Trail persistence、Reading Set curation 或 bookmark；
- [ ] 不新增独立用户手册或文档生成工具。

**验证：**

- [ ] `git diff --check -- README.md README.zh-CN.md`
- [ ] 人工逐项对照运行时菜单标题和快捷键

**依赖：** C1，文档只写已验证的最终 copy。

**预计范围：** S，2 个文档文件。

**保存点：** `docs: explain the frozen reading workflow`

### V0：真实产品总验收

使用唯一新 bundle id 和输出目录；预检 Application Support 目标不存在，避免读取或覆盖正式 Cairn 会话。

**自动门禁：**

- [ ] `swift test --disable-sandbox`
- [ ] `CODEX_SANDBOX=1 bash scripts/ci.sh`
- [ ] `bash scripts/run-self-tests.sh ...` 全通道明确 exit 0
- [ ] fold release runner 继续满足现有 400 ms / 80 MiB 门槛
- [ ] Tokio/ripgrep gold gate 无新增 unexpected failure

**真实 AppKit 任务：**

1. **First run**：新 bundle → Open Project → 三语言选择器 → Rust → 文件树出现；
2. **Explain**：symbol → Show Calls/Callers → 选择 relation → Inspector 能说明 source / verification；
3. **Branch**：A → B → Back A → C → Trail Details/Branches → Restore B，C 仍存在；
4. **Freeze path**：在 Trail 选择 relation edge → Freeze Path as Reading Set → provenance/evidence 正确；
5. **Freeze results**：Relations → Freeze Results → 50 段 cap 与 skipped summary 诚实；
6. **File reading**：切回文件 → Structure → Overview → Focus → 隐藏命中导航只展开最小祖先链；
7. **Restart boundary**：退出重启 → Reading Set 恢复；Trail 为空且明确 `this session only`；
8. **Accessibility**：键盘、focus order、AX label/value、disabled/hidden 状态与视觉一致。

**视觉证据：**

- [ ] first-run language picker 1 张；
- [ ] Trail 线性 / 分叉 / detail 共 3 张；
- [ ] Reading Set 来自 Trail / Relations 共 2 张；
- [ ] Light / Dark / SI Classic 各 1 张，保持相同内容和窗口尺寸；
- [ ] restart 后 Reading Set 恢复与 session-only Trail 空态 1 张。

**零写审计：**

- [ ] 记录 `PLAN_BASE...HEAD`、index、worktree、untracked 四个域；
- [ ] 变更只落在 §3.1 allow-list；
- [ ] `goldset/`、`fixtures/`、`Prototypes/`、语料仓、用户项目和正式 Application Support 零变化；
- [ ] `RECORD` 未设置；真实验收 bundle/output/session 目录隔离；
- [ ] `git diff --check` 与新文件 `git diff --no-index --check` 无 whitespace/conflict marker 问题。

**交付物：**

- `docs/plans/evidence/m10-m11-productization/m10-m11-productization-acceptance.md`
- 按任务编号命名的真实截图与必要 AX 文本
- 每项明确 `PASS / FAIL / SKIP / BLOCKED`，不能以自动测试替代未完成的产品任务

## §6 依赖顺序

```text
S1 first-run blocker
 ├─→ S2 Trail copy/discoverability ─→ S3 Reading Set copy/positioning ─┐
 └─→ S4 Reading Height state ──────────────────────────────────────────┤
                                                                       ↓
                                                                      C1
                                                                       ↓
                                                                      S5
                                                                       ↓
                                                                      V0
```

S2 与 S4 可并行实现；S3 必须等 S2 固定 Trail action copy；S5 只记录 C1 后的真实界面。

## §7 风险与停止条件

| 风险 | 影响 | 对策 / 停止条件 |
|---|---|---|
| `NSAlert` accessory 在不同系统字号/语言下再次收缩 | 首次进入仍不可用 | 用 fitting size + 最小尺寸/大字号真实检查；失败则停在 S1，不进入后续切片 |
| Trail 文案变长挤压 breadcrumb | 900×600 下路径不可读 | 保留 breadcrumb 压缩策略，按钮固定 hugging；最小窗口失败则缩短 copy，不改布局模型 |
| `Freeze Results` 被理解为保存全部 500/1000 项 | cap 预期错误 | tooltip 明写 up to 50，Reading Set subtitle 保留 skipped summary |
| 统一英文被误解为已完成本地化 | 范围膨胀 | README 明示当前 product copy 为英文；本轮不加 localization infrastructure |
| 为了禁用 Reading Height 引入第二份 active-content 状态 | 双真值 | 只在已有 display 分支设置控件状态；若需要新 enum/store，停止 S4 并重新评审 |
| 实现顺手触碰 SessionCodec / Bookmark / folding core | 回归面扩大 | protected-path gate 直接 FAIL，不以“顺便修”接受 |

## §8 批准前检查

- [ ] 用户批准 Trail 继续 session-only；
- [ ] 用户批准 Reading Set 定位为 frozen evidence set，而不是可整理清单；
- [ ] 用户批准本轮统一为英文 copy，不启动中文本地化；
- [ ] 用户批准 Relations / Trail 两个 CTA：`Freeze Results` / `Freeze Path as Reading Set`；
- [ ] 确认实施时每个 S 切片验证后独立提交，V0 再做最终评审；
- [ ] 已批准的计划先形成独立文档提交，并把该提交记录为新的 `PLAN_BASE`；
- [ ] 未获批准前，不修改生产代码、不建立分支、不提交本计划。
