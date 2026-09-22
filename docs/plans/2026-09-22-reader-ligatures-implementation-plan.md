# Cairn 编程连字支持：实施计划

日期：2026-09-22  
版本：1.0，评审稿  
代码基线：`sonald/cairn@d1f68eee3300df8525ce914b2fb37760c82c65a3`  
状态：功能实现已落地，发布验收进行中；实际通过项、性能结果与阻塞见[验收记录](2026-09-22-reader-ligatures-acceptance.md)。

配套文档：[需求说明](2026-09-22-reader-ligatures-requirements.md) · [技术设计](2026-09-22-reader-ligatures-design.md)

## 1. 执行原则与任务依赖

先用真实字体、真实 Reader 验证成形与交互，再逐步接入设置、字体解析和重排。每个阶段形成可独立审查的提交，完成对应测试后推进。

```text
P0 原生成形与交互验证
          ↓
P1 配置与持久化
          ↓
P2 字体解析与角色派生
          ↓
P3 主 Reader 排版与重排接入
          ↓
P4 设置 UI、全局传播与 Reading Set
          ↓
P5 完整回归、性能和发布记录
```

P0 的 fixtures、P1 的纯值测试和 P2 的解析器测试可以由不同开发者并行准备。P3 依赖已冻结的 feature 策略；P4 的显示实现依赖 P2 / P3 的接口。合并前按上图完成阶段门槛。

### 1.1 从现有成果开始

以下为基线已有能力：ReaderViewportState、ReaderViewportGeometry、多矩形范围几何、wrap 幂等 apply、Reading Set 的 TextKit 2 实际测量和 ReaderParagraphLayout。任务列表以接入和回归为主。[^reader][^viewport][^readingset][^paragraph]

基线的 CI 对 AppKit 测试采用多个串行批次，并校验测试完成数量。新增测试必须同步处理计数与隔离规则，不能只根据进程返回 0 判断测试通过。[^ci]

## 2. P0：原生成形与交互验证

目标：证明选定字体在 Cairn 当前文本系统中能够开启、关闭、恢复默认连接形态，并确认部分选择、复制和高亮的可接受行为。

### T00 核对实施基线和环境

- [x] 记录实际开发分支 HEAD、macOS、硬件、Xcode / Swift、deployment target 和构建模式。
- [x] 与本文固定基线比较 ReaderUI、ReaderSettings、ReadingSet 和 CI 的变更。
- [x] 核对 app 层设置提交、已有 wrap 自测和性能脚本的参数入口。
- [x] 在未改代码时运行现有 CI，保存完整日志和测试计数。

输出：`docs/plans/evidence/reader-ligatures/environment.md`、基线测试日志及源码差异记录。本文的基线事实仍可用于定位，发生变化的实现决策需注明新提交。

### T01 建立字体与源码 fixtures

拟新增 `fixtures/ligatures/`，包含：操作符样例、混合 Unicode 源码、语法样式样例、部分查找样例、折叠样例，以及用于 Reading Set 的多个短摘录。

性能复用既有 wrap 的大文件和长行样例，并增加一个约 2,000 行、可重复生成的常规 fixture。记录生成器参数、字节数、行数、最大源行长度和 SHA-256；中文与 CRLF 样例保持字节可复现。

- [x] 从官方来源选定一套编程字体；Fira Code 作为首个候选。[^firacode]
- [x] 记录所用字体文件的来源、版本、PostScript name 与 SHA-256。
- [x] 测试环境按固定路径提供字体，并验证实际解析到了目标 face。
- [x] 字体测试资源由测试环境提供；文档包与产品首版不附带字体二进制。
- [x] 增加第二套字体或字体变体作交叉验证，并保留系统字体回退用例。

输出：源码 fixtures、生成脚本、fixture manifest、字体环境清单。字体文件存在不等于验证通过。

### T02 成形与真实 Reader 双层探针

新增独立探针或拟新增 `Sources/CodeInsightApp/LigatureSelfTest.swift`。对同一字体和文本比较三态请求，并设置 `.ligature` 单独控制的对照组。

第一层用 Core Text 记录实际 font、glyph ID、位置、advance 和必要的截图，确定 D03 feature 请求表。第二层把相同配置应用到实际 Reader 的展示文本中，验证语法属性、rendering attributes、折叠与原生选择的组合。探针中的临时注入不是最终配置入口。

- [x] 固定 `!= -> => <= >= !== === :: .. ...` 样例，记录哪些序列有实际连接形态。
- [x] 分别验证 `.ligature`、`calt` 等请求的效果以及 Default 的恢复。
- [x] 对相同字形数量但形态改变的情况给出正确判定。
- [ ] 对 `!=` 中的 `=` 和 `!==` 中的子范围执行鼠标、键盘、查找与复制测试。
- [x] 验证函数名放大与现有 `.kern` 的组合，冻结自然字距规则。
- [x] 核对最低部署系统与当前支持系统上的 API 可用性；未覆盖环境明确记入待验。

**P0 门槛：** 至少一套固定版本字体有清晰的 On / Off / Default 实际结果；源码范围与复制正确；feature 桥接写法能够在目标 SDK 编译。未满足时，保留探针数据并修正策略，暂不把该字体列为支持。

对应：A02、A05 的先行验证；设计 D03、D04、D07。

## 3. P1：配置与持久化

### T03 增加纯值模型

文件：`Sources/CodeInsightReaderCore/ReaderSettings.swift`，按需要新增 `ReaderFontConfiguration.swift`。

- [x] 增加 `CodeFontSelection` 和 `CodeLigatureMode`。
- [x] 为 ReaderSettings 增加字段与默认值，保持已有调用方可使用原有默认初始化。
- [x] 增加用于排版比较的纯值键。
- [x] 将新字段传入 ReaderTheme，确保当前 `themeChanged` 检查能观察新设置。
- [x] 确认 Core targets 无 AppKit / SwiftUI 导入。

### T04 完成保存、读取与迁移

- [x] 实现需求 R10 和设计 D02 中的 key 规则。
- [x] 同时更新 `save(to:)` 中的 validated 设置重构造。[^settings]
- [x] 缺 key、非法模式、非法字体 kind、空字符串按规则回退。
- [x] 有效但未安装的字体名保持原请求，留给解析器回退。
- [x] 测试使用隔离的 UserDefaults suite，不修改开发者真实偏好。

### T05 配置测试

拟新增 `Tests/CodeInsightReaderCoreTests/ReaderLigatureSettingsTests.swift`。

覆盖：默认、三态逐一 round trip、指定字体 round trip、恢复系统默认后清理旧名字、未知枚举、缺失 key、配置相等比较，以及 ReaderTheme / 排版键随新字段变化。

**P1 门槛：** A01 通过；新增纯值测试完整执行；旧设置构造和已有配置测试通过。此阶段可以没有可见 UI。

## 4. P2：字体解析和角色派生

### T06 实现 ReaderFontResolver

文件：拟新增 `Sources/CodeInsightReaderUI/ReaderFontResolver.swift`。

- [x] 按 D04 提供 request → resolved font 的入口。
- [x] 实现系统默认、指定字体、同族字重派生和回退诊断。
- [x] 构造结果时保留实际 variation／字体变体信息。
- [x] 将 `.font`、连字 attribute、feature 请求和字距规则作为统一结果提供。
- [x] 通过构造参数注入或应用级持有解析器，缓存中只保存字体相关对象。

### T07 实现已冻结的 feature 策略

- [x] 使用 P0 验证的 descriptor / attribute 组合。
- [x] 在字号、字重派生后合并特性。
- [x] 每次从基准 descriptor 创建新结果，规范化重复 feature 请求。
- [x] 验证 `On → Off → Default → On` 不残留旧覆盖。
- [x] humanist 注释使用独立字体与成形策略。
- [x] “未验证”与“字体缺失”使用不同诊断状态。

### T08 缓存与环境失效

- [x] 建立规范化请求键和 `ResolvedFontKey`。
- [x] 增加有界缓存、缓存命中计数和环境版本。
- [x] 在相同配置下模拟字体环境变化，验证重新解析。
- [x] 在频繁改变字号与字重的压力用例中确认缓存容量受限。
- [x] 性能日志保存可读配置，避免用进程散列值当稳定证据。

### T09 解析器测试

拟新增 `Tests/CodeInsightReaderUITests/ReaderFontResolverTests.swift`。

固定字体的精确成形测试要求字体环境满足 manifest。普通单元测试可通过可注入字体查询或替身验证缺失字体和缺失字重，避免依赖开发者本机字体清单。

**P2 门槛：** A02、A03、A13 的解析部分通过；每个字体角色的实际字体和特性可检查；字体缺失在专用验收任务中报失败或阻塞，不计为通过。

## 5. P3：主 Reader 排版与重排接入

### T10 统一样式入口

文件：`Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`。

- [x] `baseAttributes` 使用最终正文字体和连字策略。
- [x] `applyTypography` 使用同族派生角色，应用明确的字距规则。
- [x] `syntaxFormatting` 开／关时清理旧属性，字体和连字独立生效。
- [x] 新建 projection、语法更新和实时字体更新使用相同样式计算规则。
- [x] 按角色保留行号、chip、路径等 UI 字体。

### T11 增加纯排版属性更新分支

- [x] 在 `apply(settings:)` 中比较排版键、几何变化与字体环境版本。
- [x] 在任何可能触发布局的操作前捕获现有阅读状态。
- [x] 相同内容和折叠投影时，使用 editing transaction 批量更新拥有的字体属性。
- [x] 保留原显示字符串、DisplayMap、附件与源范围；清理旧 feature 和 kern 覆盖。
- [x] 区分 projection install、属性更新和布局计数。
- [x] 对字体与 wrap 同时变化做一次合并更新。

当前 `apply(settings:)` 的 theme 分支会构建 projection；本任务为字体变化建立更明确的路径，复用已有 wrap 幂等分支。[^reader]

### T12 保留阅读状态并控制延迟恢复

- [x] 复用 `captureViewportStateForReflow` 和现有恢复／矫正机制。
- [x] 选区恢复独立于大文件是否执行同步视口恢复。
- [x] 保留当前命中、当前行、水平位置、折叠与 focus 状态。
- [x] 字体新布局尚未生效时，避免使用旧 fragment 几何。
- [x] 连续切换字体、字号与 wrap 保持同一稳定锚点。
- [x] 人工滚动、点击、文件切换和视图销毁取消过期恢复。
- [x] 覆盖非空选区、反向扩选、多范围状态（现有原生接口允许时）与后续 Shift 行为。

### T13 几何和段落回归

文件：`ReaderViewportState.swift`、`ReaderParagraphLayout.swift`。

- [x] 检查 `characterRect` 的 UTF-16 单步查询在 emoji / 组合序列上的行为。
- [x] `visibleRects` 覆盖部分连字、跨行范围和混合字体。
- [x] 调整几何边界时保留搜索与复制的原始范围。
- [x] 悬挂缩进使用最终字体，缓存对字体或 feature 变化失效。
- [x] 保持 CI 对 ByteUTF16Map 使用位置的限制。[^ci]

拟新增 `Tests/CodeInsightReaderUITests/ReaderLigatureIntegrationTests.swift`。

**P3 门槛：** A04—A09、A12、A14 在主 Reader 通过；纯字体切换的投影安装增量为 0；相同有效配置的主动更新增量为 0。大文件必须单独记录恢复策略和观测结果。

## 6. P4：Settings、全局传播与 Reading Set

### T14 Settings 控件与预览

文件：`Sources/CodeInsightApp/ReaderSettingsWindowController.swift`。

- [x] 实现 Code Font 选择器与三态 Programming Ligatures 控件。
- [x] 预览包含操作符、函数名强调、字符串与注释。
- [x] 显示缺失字体回退、实际字体和未验证状态。
- [x] 保留应用级设置到表单状态的同步；重复写回不造成反馈循环。
- [ ] 加入辅助功能标签和键盘操作验收。（AX 控件自动化通过，真实 Settings 键盘操作待解锁。）

### T15 核对应用级传播

定位 `CodeInsightApp.swift` 的设置提交与 `MainWindowController.swift` 的应用路径，逐个覆盖主 Reader、对比 Reader、Context、Settings 预览、新建窗口与新建阅读面。

- [x] 已打开与之后创建的代码面使用同一配置。
- [x] 实际字体环境变化能刷新现有代码面。
- [x] 普通文本和渲染文档仍遵循需求范围表的字体策略。
- [x] 发布用场景表列出每个代码面的创建入口和更新入口。

### T16 Reading Set 字体和测量

文件：`Sources/CodeInsightApp/ReadingSetView.swift`。

- [x] 把数值数组签名替换为包含 `ResolvedFontKey` 的具名布局键。
- [x] `apply` 和 `measure` 共用最终字体，清理 `measure` 中的系统正文字体重写。
- [x] 字体不同、字号相同，以及只改变连字模式，都能重新测量。
- [x] 有效配置相同重复 apply 不重新测量。
- [x] 在 editing transaction 内提交需要修改的正文属性与段落样式。
- [x] 更新已有高度约束和真实布局行号，保留卡片选区和横向偏移。
- [x] 卡片批量更新后通过现有 Reading Set 外层锚点恢复。
- [x] 测量失败或零尺寸时不提交可误用的有效缓存签名。

当前测量已基于 TextKit 2；本任务集中在字体输入、缓存键和更新传播。[^readingset]

### T17 App 层测试

拟新增 `Tests/CodeInsightAppTests/ReaderLigatureSettingsUITests.swift` 和 `ReadingSetLigatureTests.swift`。测试名称为计划名称，提交时按仓库已有测试风格组织。

**P4 门槛：** A10、A11、A13 的 UI 部分通过；其他支持面复跑 A03、A05、A06；已打开 Reading Set 能在同字号字体切换后准确更新。

## 7. P5：完整验收、性能与发布

### T18 完善自测与性能记录

将 P0 的探针整理为专用自测入口，拟定命令名 `--self-test-ligatures`。新增入口应记录请求配置和实际渲染配置，支持选定字体、fixture、模式和结果文件。

以下是计划中的调用形式，只有在对应入口实现后才执行：

```bash
# FONT_PS 来自 P0 的真实字体清单。
.build/release/codeinsight-app --self-test-ligatures \
  --font-postscript "$FONT_PS" \
  --mode enabled \
  --fixture fixtures/ligatures/operators.rs \
  --json-out .build/ligatures-enabled.json
```

结果字段至少包含：

| 类别 | 字段 |
| --- | --- |
| 环境 | commit、macOS、硬件、Swift / SDK、release/debug、backingScaleFactor |
| 输入 | fixture SHA-256、源行数、字节数、最大行长、宽度、wrap、字号、字重 |
| 字体 | 请求字体、实际字体、字体版本与 SHA-256、mode、有效 feature、回退状态 |
| 正确性 | source / display 是否一致、复制内容匹配、选区范围、实际成形检查 |
| 性能 | 字体解析、属性写入、首个正确帧、稳定时刻、主线程阻塞、峰值内存 |
| 计数 | projection install、属性更新、测量、缓存命中、恢复／丢弃次数 |
| 结论 | passed / failed / blocked / skipped，原因，是否使用大文件降级 |

缺少测试字体时输出 blocked；一般 CI 可显式跳过非必需字体任务，但发布验收的必需字体组合不能因此判为 passed。

### T19 执行测试与更新 CI

开发环境按仓库现有 README 配置依赖。以下是已存在的构建／测试工具使用方式；针对具体测试 target 的 filter 结果必须检查实际运行数量。

```bash
git rev-parse HEAD
swift build
swift test --no-parallel --filter CodeInsightReaderCoreTests
swift test --no-parallel --filter CodeInsightReaderUITests
# 完整回归保留仓库对 AppKit 测试的独立批次。
bash scripts/ci.sh
```

- [x] 在新增测试完成后更新 `scripts/ci.sh` 的期望测试计数。
- [x] 保留已有 AppKit 隔离批次；必要时为字体注册／原生窗口用例增加独立进程。
- [x] 检查测试完成摘要和成功数量，不只检查退出码。
- [ ] 运行既有 fold、projector、wrap 及产品质量门槛，参数按当前脚本契约执行。（已执行；产品门禁停在 Tabs 内存失败，后续阶段未运行。）
- [ ] 测量默认配置相对原基线，以及同字体 On 相对 Off 的回归。
- [x] 冷缓存与预热结果分开；预热后至少 30 次，报告 p50 / p95 与样本数。
- [x] 原生截图配合实际字体／feature 检查，避免“设置已保存但没有生效”的假通过。

### T20 发布文档与恢复路径

- [x] 填写 A01—A15 结果，每项链接到日志、截图或测试用例。
- [x] 填写目标字体及系统版本兼容记录。
- [x] 更新用户说明：选择字体、三态含义、字体缺失回退、恢复默认。
- [x] 填写大文件恢复限制与其他已知兼容性情况。
- [x] 记录最终 feature 请求表、缓存策略和性能预算。
- [ ] 通过后将文档状态更新为“已实施”，并引用实际实现提交。

**P5 门槛：** 所有必需 A 项和已冻结性能预算通过；完整 CI 有成功摘要；没有被字体缺失或环境跳过掩盖的必需用例。

## 8. 建议的提交划分

| 提交 | 内容 | 审查重点 |
| --- | --- | --- |
| C0 | 探针、fixtures、环境与基线证据 | 是否真的观察到目标字体效果 |
| C1 | 配置字段、迁移和纯值测试 | 默认兼容、save 重构造和相等判断 |
| C2 | 字体解析器、角色派生、feature 与缓存 | Default 清理、回退、缓存边界 |
| C3 | 主 Reader 属性更新与重排测试 | 投影复用、完整选区、大文件保护 |
| C4 | Settings、全局传播和 Reading Set | 同字号不同字体的测量失效 |
| C5 | 全量回归、性能门槛和发布文档 | 证据完整、无假通过 |

每个提交将新增接口的测试与实现一同提交。独立的机械文件拆分应与行为变化分开审查，避免把本功能扩大为大范围 Reader 重构。

## 9. 需求、设计与任务追踪

| 需求 | 主要设计 | 任务 | 验收 |
| --- | --- | --- | --- |
| R01 字体选择 | D02、D04、D09 | T03、T06、T14 | A01、A11 |
| R02 连字模式 | D03 | T02、T07、T14 | A02 |
| R03 传播与幂等 | D06、D09 | T11、T15 | A11、A14 |
| R04 派生一致 | D04、D05 | T06、T07、T10 | A03 |
| R05 源范围 | D01、D05、D07 | T01、T11、T13 | A04、A12 |
| R06 选择与复制 | D06、D07 | T02、T12、T13 | A05、A07 |
| R07 高亮几何 | D05、D07 | T02、T13 | A05、A06 |
| R08 阅读状态 | D06 | T11、T12 | A07、A08、A09 |
| R09 摘录测量 | D08 | T16、T17 | A10 |
| R10 迁移 | D02、D04 | T04、T05、T14 | A01、A13 |
| R11 能力和回退 | D03、D04、D10 | T02、T06、T09 | A02、A13 |
| R12 生命周期 | D04、D06、D10 | T08、T12、T19 | A08、A14、A15 |
| N01—N07 | D05、D06、D10 | T18、T19、T20 | A14、A15 |

## 10. 风险与处理

| 风险 | 发现方式 | 处理与门槛 |
| --- | --- | --- |
| `.ligature` 与 font feature 的实际组合不同于预期 | P0 原生探针 | 修正特性配置；没有证据的字体标记未验证 |
| 字重派生丢失 feature | 比较角色字体与实际成形 | 派生完成后重新合并 feature |
| `.kern` 影响连接形态 | 放大声明样例对照 | 冻结自然字距策略，保留默认兼容测试 |
| 字体切换落入旧 projection 重建路径 | 计数断言 | 对纯排版建立属性更新分支 |
| 字号相同导致 Reading Set 复用旧尺寸 | A10 同字号切换用例 | 布局键包含实际字体和特性 |
| 新设置提前返回，或字体安装后仍使用旧回退 | key 与环境版本测试 | 新字段进入主题／排版比较，环境独立失效 |
| 新字体旧几何导致滚动跳跃 | 布局事件、片段属性与截图 | 复用有界矫正，并丢弃过期回调 |
| 大文件强制布局导致阻塞 | 主线程探针、大文件矩阵 | 维持同步恢复保护，选区独立恢复 |
| 原生选择内部边界不符合预期 | 鼠标／键盘／查找组合测试 | 记录原生行为；必要子范围不可选时不宣称支持 |
| 字体缺失被测试 skip 掩盖 | 专用验收 summary | 必需组合 blocked／failed，阻止发布通过 |

## 11. 验收记录模板

逐项现状见[验收记录](2026-09-22-reader-ligatures-acceptance.md)。下方保留记录格式；原生鼠标流程和 F1 性能门槛未关闭。

```text
验收 ID：Axx
状态：待执行 / 通过 / 失败 / 环境阻塞 / 非必需跳过
实现提交：
macOS / Xcode / Swift：
字体来源、版本、PostScript name、SHA-256：
fixture 与 SHA-256：
窗口尺寸、backingScaleFactor、wrap、字号、字重、mode：
实际解析字体及有效 feature：
操作步骤：
预期结果：
实际结果：
选区 / 源文本 / 复制断言：
首帧、稳定、阻塞、内存与计数：
截图与日志位置：
降级策略或限制：
复核者与日期：
```

性能记录同时保存预算版本、样本数和测试脚本参数。更新预算须说明改变原因及影响，不用新的预算覆盖原来的结果。

## 12. 完成定义

当代码实现、配置迁移、字体能力验证、所有支持阅读面、A01—A15、CI 和性能证据均完成后，本需求可以关闭。需求文档、设计文档和实施记录应指向同一个最终实现提交，剩余独立需求进入 backlog。

## 参考资料

[^reader]: [ReaderTextView：排版、设置更新、选择与绘制](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^viewport]: [ReaderViewportState 与 ReaderViewportGeometry](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderUI/ReaderViewportState.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^readingset]: [ReadingSetView 与 ReadingSetExcerptView](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightApp/ReadingSetView.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^paragraph]: [ReaderParagraphLayout：悬挂缩进与前导空白测量](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderUI/ReaderParagraphLayout.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^ci]: [CI 批次、测试数量校验与架构静态检查](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/scripts/ci.sh). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^firacode]: [Fira Code 官方仓库：编程连字及 calt 配置](https://github.com/tonsky/FiraCode). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^settings]: [ReaderSettings 与 ReaderTheme](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderCore/ReaderSettings.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
