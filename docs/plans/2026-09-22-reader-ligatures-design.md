# Cairn 编程连字支持：技术设计

日期：2026-09-22  
版本：1.1，已实施（2026-09-23验收）
代码基线：`sonald/cairn@d1f68eee3300df8525ce914b2fb37760c82c65a3`  
状态：已实施，验收通过；最终源码`0296f21`，性能按用户确认的best-effort口径披露；实际证据见[验收记录](2026-09-22-reader-ligatures-acceptance.md)。

配套文档：[需求说明](2026-09-22-reader-ligatures-requirements.md) · [实施计划](2026-09-22-reader-ligatures-implementation-plan.md)

## D01 设计决策与当前基线

采用现有 TextKit 2 成形与排版链路，在 ReaderCore 中增加字体选择与连字模式的值配置，在 ReaderUI 中集中解析字体、派生样式和应用字体特性。字体变化复用现有重排事务与几何查询。

### D01.1 已核对的源码事实

| 位置 | 当前实现 | 本次设计动作 |
| --- | --- | --- |
| `ReaderSettings.swift` | 保存字号、字重等；没有代码字体与连字字段；`save` 会重构设置 | 扩展配置和持久化全路径 |
| `ReaderTextView.apply(settings:)` | 相同设置提前返回；纯 wrap / gutter 变化避免重建投影；theme 变化仍走 project / install | 增加排版变化分支及字体环境失效判断 |
| `applyTypography` | 函数名、声明强调重新创建系统等宽字体；放大标题写 `.kern` | 统一从解析器取得角色字体和字距策略 |
| `ReaderViewportState` | 已保存完整选区、affinity、源锚点、偏移和投影版本 | 复用并补齐字体变化测试 |
| `ReaderViewportGeometry` | 已有 `visibleRects`、`characterRect`、`rowRect` | 验证连字子范围和 Unicode 边界 |
| `ReadingSetExcerptView` | 已用 TextKit 2 的真实布局测量；签名为 `[CGFloat]` | 改为能容纳字体、特性的具名值类型 |
| `ReaderParagraphLayout` | 独立测量空白缩进并缓存字体、段落样式、前缀 | 输入最终字体；统一失效 |

当前 Reading Set 的测量签名包含宽度、wrap、字号、行高、gutter 宽度和滚动条样式，没有字体身份和连字配置。它的 `measure()` 还会重新写系统等宽字体。因此仅修改 `apply(settings:)` 中的 `codeView.font` 会被后续测量覆盖。[^settings][^reader][^viewport][^readingset][^paragraph]

### D01.2 分层与数据流

```text
应用级 ReaderSettings（用户意图、持久化）
              │
       配置快照与变化判断
              │
 ReaderFontResolver（解析字体、派生字重、特性、回退）
              │
   .font / .ligature / .kern / 段落属性
              │
   NSTextStorage → TextKit 2 / Core Text
              │
   实际排版片段、文本段矩形、原生命中

源字节与语义范围 → DisplayMap → 显示 UTF-16 范围
                                  │
                         搜索、选择、复制、装饰
```

`DisplayMap` 只描述源文本与折叠显示文本之间的投影。字体成形位于其后，投影中不增加 glyph index、连字替换字符或连字压缩表。这个边界与 TextKit 2 对 glyph 处理的封装一致。[^displaymap][^textkit]

## D02 配置与类型契约

### D02.1 ReaderCore 中的纯值配置

以下代码表示拟新增的数据契约，具体访问级别与命名在实现时按 package 使用点调整。

```swift
public enum CodeFontSelection: Hashable, Sendable {
    case systemMonospaced
    case postScriptName(String)
}

public enum CodeLigatureMode: String, CaseIterable, Sendable {
    case fontDefault
    case enabled
    case disabled
}
```

`ReaderSettings` 增加 `codeFont` 和 `codeLigatures`，默认分别为 `.systemMonospaced` 和 `.fontDefault`。字体选择的 PostScript name 标识基准字体，用户界面显示其可读名称。

拟定持久化 key：

| Key | 类型及规则 |
| --- | --- |
| `reader.codeFont.kind` | `systemMonospaced` / `postScriptName` |
| `reader.codeFont.postScriptName` | 仅在指定字体时写入有效非空字符串 |
| `reader.codeLigatures` | `fontDefault` / `enabled` / `disabled` |

选择系统字体时清理旧的 PostScript name key。非法 kind 或空名字回退到系统字体；有效但未安装的名字保留为用户请求，由解析层处理实际回退。

新增字段进入初始化参数、`init(defaults:)`、`save(to:)` 的 validated 构造、实际 key 写入，以及配置相等比较测试。ReaderCore 保持 Foundation 值模型，字体解析不在持久化期间发生。现有 CI 明确禁止 Core targets 导入 AppKit / SwiftUI。[^settings][^ci]

### D02.2 排版键

新增纯值 `ReaderTypographyKey`，由已经校验的 ReaderSettings 生成，覆盖：代码字体选择、连字模式、正文字号、函数名字号增量、声明字重、syntaxFormatting、humanistComments，以及实际影响排版的字距策略。行高进入整体排版或测量键。

首版保留现有 `ReaderTheme` 的排版字段，并加入新字段，保证旧的 `newTheme != theme` 能观察到新设置。`ReaderTypographyKey` 用于明确比较和缓存，不再保存另一份可独立修改的用户状态。

字体环境版本 `fontEnvironmentRevision` 由 ReaderUI 的字体解析器管理。最终缓存与有效配置判断结合该版本，解决“设置相同，但字体刚被安装或移除”的情况。

## D03 编程连字特性策略

实施补充：两套固定字体的实际 Core Text 结果见[字体能力记录](evidence/reader-ligatures/fonts.md)。请求通过 `kCTFontOpenTypeFeatureTag` / `kCTFontOpenTypeFeatureValue` 与 descriptor 组合；Core Text 会省略不支持或已默认开启的特性，因此实际片段与解析字体的有效特性进行比较，不能要求每个请求都出现在输出 metadata。角色复用 `ReaderTheme`、字号和字重参数，没有再增加角色枚举。

### D03.1 为什么需要集中处理

Apple 的 `.ligature` 标准属性默认是 `1`；它不意味着所有编程字体的连接形态都可以靠这个值独立控制。Fira Code 官方的启用说明包含 OpenType `calt`。首版将 attribute 和字体 descriptor 的 feature 请求集中组合，避免各阅读面采用不同规则。[^attributes][^firacode]

### D03.2 首阶段待验证的请求表

下表是 P0 的候选实现策略。完成目标字体与部署 SDK 验证后，冻结为实际配置，并写入字体能力记录。

| 模式 | `.ligature` | descriptor 中的可选 feature 请求 |
| --- | --- | --- |
| Font Default | 移除本功能添加的覆盖 | 使用基准字体默认特性，清理上次开关添加的覆盖 |
| On | `1` | 请求 `calt=1`；按验证后的字体配置请求 `liga=1`、`clig=1` |
| Off | `0` | 请求关闭 `calt`、`liga`、`clig`；对需要覆盖的可选历史／任意连字配置关闭 `dlig`、`hlig` |

On 不采用 `.ligature=2` 作为通用策略，也不自动启用所有风格集合。必要成形与语言所需特性保持由系统处理；中文、emoji 以及复杂文字回退另做正常显示验证。

Apple 提供 Core Text feature descriptor 设置和 OpenType tag 常量；具体 Swift 桥接方式、可用性检查及属性优先关系在 P0 以实际 SDK 编译和原生效果确认。文档不把特定字典写法当作已经通过验证的生产实现。[^features][^opentype]

### D03.3 特性冲突和恢复

从未被本功能修改的基准 descriptor 派生每个结果。先选字号／字重变体，再合并目标 feature 请求，最后构造最终字体。

每个 feature tag 只保留一个有效请求。解析器拥有自己的编程连字覆盖，保留与此无关的字体默认设计。切回 Font Default 必须清掉上次 Off 注入的 `calt=0` 等值；不能以“这次没再写”代替清理。

`.ligature` 和 `.kern` 属于排版属性，同样要处理从有覆盖到无覆盖的过渡。测试顺序包括 `On → Off → Default → On`，并核对最终实际字体与成形。

### D03.4 能力反馈

记录三个不同结果：字体是否成功解析、请求的特性配置是什么、固定样例是否验证出预期连接形态。只有 feature 元数据时标记为“未验证”。

成形比较可使用同字体、同字号、同文本下的 CTLine / CTRun 字形标识、位置和 advances，并配合真实 Reader 的截图和交互。字形数量相同不代表连接形态没有变化，因此不能把“glyph 数量减少”作为唯一通过条件。

## D04 ReaderFontResolver

在 `Sources/CodeInsightReaderUI/ReaderFontResolver.swift` 新增 `@MainActor package` 字体解析器。它通过构造参数传入 Reader 与需要共享策略的 App 阅读面；独立测试可以使用单独实例。应用层可持有共享解析器，缓存中不保存 NSView 或 ReaderDocument。

### D04.1 输入和输出

| 输入 | 作用 |
| --- | --- |
| 字体选择 | 系统等宽或指定基准字体 |
| 角色 | 正文、函数声明、强调声明、代码注释、humanist 注释 |
| 字号与字重 | 使用现有 ReaderSettings 规则 |
| 连字模式 | 映射为已验证的 feature 配置 |
| 字体环境版本 | 触发重新查询与失效 |

输出 `ResolvedCodeFont` 包含实际 NSFont、请求及实际 PostScript name、特性请求、回退原因，以及可用于相等比较的 `ResolvedFontKey`。这些 AppKit 对象只在 UI 层使用。

`ResolvedFontKey` 包括实际字体身份、字号、实际字体变体或 variation、规范化后的 feature 列表及字体环境版本。它是进程内值键；性能结果记录可读字段，不持久化 Swift 的 `hashValue`。

### D04.2 角色派生

正文优先使用所选基准字体。函数名和声明从其字体族中解析现有配置要求的字号与字重。找到匹配变体后再合并连字特性，保证派生过程不会丢掉覆盖。

目标字重不存在时采用可解释的同族近似或基准字体；整套字体不存在时使用系统回退。回退结果记入诊断信息，并参与测量键。不要通过改变配置值来掩盖回退。

humanist 注释从自己的字体策略解析，并清理继承的代码连字覆盖。首版不开放 variable font 轴编辑器，系统解析得到的有效轴设置应保留并进入结果键。

### D04.3 字距策略

原代码在放大函数名时写 `.kern=0.15`，否则写 `0`。这属于既有视觉行为。[^reader]

首版拟定策略：默认“系统等宽 + Font Default”维持原有标题字距；显式连字模式或自定义代码字体优先使用字体自然字距，即移除这一路径创建的 `.kern`。此策略写入排版键并由 P0 对目标字体验证。

未来增加字距选项时，应独立列入需求并检查与连字的兼容；本版不新增字距控件。

### D04.4 缓存与字体环境

缓存以规范化请求和字体环境版本为键，采用明确上限，初始建议 128 个派生结果。上限是实现参数，在压力测试后调整。不要以临时浮点计算结果无限产生字号键。

设置面板刷新字体列表、应用重新激活时检测到字体环境变化，或显式刷新字体时，提高环境版本并广播重新解析。可以接入系统字体变化通知，但具体通知 API 和线程约束需按部署 SDK 核对。首版至少提供打开面板时刷新和可重复测试的显式刷新路径。

## D05 把排版样式应用到显示文本

### D05.1 统一角色字体入口

`baseAttributes`、`applyTypography`、段落缩进计算与 Reading Set 使用相同解析器。消除代码正文路径中随处创建系统等宽字体的行为；行号、chip、路径标签等 UI 字体调用保留其角色含义。

`applyTypography` 接收已经解析的角色字体集合或解析器依赖。新建 projection 和在原文本上更新排版必须使用相同的样式规则，避免首次打开与实时切换显示不同。

### D05.2 字体变化的属性更新

源内容和折叠集合相同时，复用 `DisplayMap` 和显示字符串，在现有 text storage 上批量更新本功能拥有的排版属性：

1. 根据当前 DisplayMap 确认可见源码区间，区分折叠附件。
2. 对源码正文恢复基准 `.font`、连字覆盖与字距规则，清理旧模式残留。
3. 按现有 highlight spans 应用函数名、声明强调与注释字体。
4. 以最终字体刷新相关段落缩进。
5. 保留 attachment、链接以及其他模块拥有的属性；针对派生字体实际变化触发布局失效。

在 `NSTextContentStorage.performEditingTransaction` 中执行批量 text storage 更新，并按既有代码管理 `beginEditing` / `endEditing`。Apple 要求通过 editing transaction 通知 TextKit 2 底层存储变化。[^textkit]

纯字体／连字切换的 `projectionRevision` 与投影安装计数保持稳定。新增 `typographyAttributeUpdateCount` 等计数区分属性变化和字符串安装。

实施补充：增量更新与首次投影一致，对完整显示文本合并基础字体、连字和段落属性，也覆盖 `U+FFFC` 占位字符；仅合并本功能拥有的属性，不替换 `.attachment` 或链接。折叠 chip 自身仍使用独立 UI 字体。已复现并修复占位字符残留旧字体/连字的失败，见[回归记录](evidence/reader-ligatures/fold-attributes-green.log)。

### D05.3 与 rendering attributes 的关系

`RenderingAttributesCoordinator` 继续承担当前已有的前景色、引用透明度与 occurrence 背景。语法与搜索颜色不调用字体解析器，也不根据单字符颜色变化主动切断文本成形。

一次设置变化可能同时包含字体、颜色和 wrap：变化判断要能组合处理。颜色刷新可复用现有路径；本版新增的字体分支必须满足纯字体不重建源投影的要求。不要把现有所有主题更新路径重写成新架构作为先决条件。

## D06 复用现有重排事务

### D06.1 更新分类

对比旧设置、新设置以及字体环境版本，得到可组合的变化集合：排版属性变化、容器几何变化、颜色变化。新字段必须纳入当前相同设置提前返回的条件。

| 变化 | 必要动作 |
| --- | --- |
| 所有有效输入相同 | 幂等返回 |
| 仅字体／连字／字重／字号 | 保存阅读状态，更新排版属性，布局和恢复 |
| 仅 wrap / gutter / 宽度 | 复用当前几何更新路径 |
| 同时变化 | 一次快照，一次合并提交，再进行恢复 |
| 字体环境改变 | 重新解析；有效结果变化时更新文本与测量 |
| 源内容或折叠集合变化 | 继续使用既有投影路径，并作正常版本更新 |

### D06.2 单次更新顺序

```text
比较设置与字体环境
→ 在任何 configureGutter / configureWrapping 之前捕获当前阅读状态
→ 增加现有 viewportStateGeneration，取消过期矫正
→ 解析最终字体并更新排版属性、段落属性和容器几何
→ 通知可见区域重新布局
→ 恢复选区与当前命中等逻辑阅读状态
→ 按文件规模执行有界视口恢复
→ 更新装饰，并沿现有合并通知路径发布状态
```

首次显示尚未挂载或尺寸为零时，只保存最新配置；得到有效几何后再排版。字体解析失败时使用可读的回退结果完成更新，错误不应留下半写入的样式状态。

### D06.3 选区和大文件

复用 `ReaderViewportState.selectedRanges`、`selectionAffinity`、primary selection、当前行源位置及水平状态。它们已经存在。selection affinity 表达软换行边界归属等语义，不能仅凭这个字段就断定所有拖选方向都被完整表示；A07 必须验证切换后的实际 Shift 扩选行为。[^viewport]

当前 `supportsSynchronousViewportRestore` 将同步恢复限制在不超过 8,000 个源行的文件。新字体分支把选区恢复与同步视口定位分开：即使跳过昂贵的视口定位，选区仍显式保留。不要为了达到普通文件的像素误差目标而对大文件强制整篇 ensureLayout。[^reader]

实施中的性能保护补充：原生调用栈显示 `characterRect → enumerateTextSegments → CTLineGetOffsetForStringIndex → EnumerateCaretOffsets` 会扫描整个超长行。保留 8,000 行保护，并对锚点源行字节跨度超过 64 KiB 的情况采用同样的同步恢复降级：选区与历史水平位置保留，垂直位置交给自然布局，不承诺普通文件的 2 pt 精度。折叠锚点也检查其源行；EOF 空行按实际尾行处理。1.8 MB 无空格行关闭 wrap 的稳定 p95 从约 1,738 ms 降至 364 ms，见[调用栈](evidence/reader-ligatures/mega-line-caret-profile.txt)和[测量](evidence/reader-ligatures/mega-line-bounded-restore.json)。没有通过猜测或均分连字宽度来替代原生几何。

### D06.4 延迟布局与过期任务

复用既有 generation、contentID、阅读面文件身份与 projection revision 检查。切换文件、折叠变化、窗口销毁、用户主动滚动或选区操作应使尚未执行的恢复任务失效。

字体切换后的“新几何”必须来自承载新排版属性的布局。仅检查 wrap 状态或容器宽度无法证明字体已经更新。P0 / P3 测试记录布局事件，并检查实际片段字体与绘制结果；避免拿旧 fragment 坐标恢复到错误位置。

连续改变设置沿用同一重排序列的稳定锚点；用户主动交互后再捕获新的锚点。

## D07 几何、连字部分选择与 Unicode

继续使用 `ReaderViewportGeometry.visibleRects` 取得多段矩形；底层为 `NSTextLayoutManager.enumerateTextSegments`。以 `textContainerOrigin` 完成坐标转换，不再重复添加 inset。当前 helper 已经采用此路径。[^viewport][^segments]

需要新增以下验证：`!=` 中一个字符的范围、多个运算符交界、跨视觉行命中、混合字体、emoji 与组合字符邻接连字、折叠 chip 两侧。

对于 TextKit 将一个范围的可视边界扩展到整个成形簇的情况，保留精确的搜索／复制范围，在验收记录中说明视觉覆盖。不要把源范围扩大为 glyph 范围，也不要把连字宽度平均分成若干列来伪造子字符几何。

当前 `characterRect` 以 UTF-16 offset 加一构造查询范围，需要重点验证 surrogate pair 和组合序列边界。必要时在几何查询内部求合法字符边界或使用 insertion segment；几何查询的边界调整不回写到搜索或复制范围。

CI 已约束 ReaderUI 只有 `DisplayMap.swift` 可以直接引用 `ByteUTF16Map`。新增 helper 继续从 DisplayMap 或文本系统的合法边界接口取得位置。[^ci]

## D08 Reading Set 与段落度量

### D08.1 替换测量签名

将当前 `[CGFloat] signature` 改成具名的 `ExcerptLayoutKey`，建议字段：内容身份或内容版本、有效宽度、wrap、`ResolvedFontKey`、连字 attribute 策略、行高、段落策略、gutter 宽度和滚动条样式。

每个字段使用符合其意义的类型。字体名称和 feature 不编码成 CGFloat，也不使用散列值假装稳定字体身份。输入浮点量沿现有布局容差规范化，避免相同宽度抖动触发重复测量。

只有成功得到有效布局后才提交新的测量键；零尺寸或测量被中止时，下次允许重新尝试。

### D08.2 统一正文与测量配置

`ReadingSetExcerptView.apply(settings:)` 和 `measure()` 使用同一份 `ResolvedCodeFont`。`measure()` 应清理旧连字覆盖并写入目标排版属性，不得在后续阶段重新使用硬编码的系统正文字体。

卡片已有局部全文排版测量，其范围是冻结摘录。继续利用真实 `textLineFragments` 计算高度、宽度和行号，并更新已有高度约束；这条有限摘录的测量策略不推广到主 Reader 大文件。[^readingset]

### D08.3 外层阅读位置

保留 Reading Set 外层的卡片／字符锚点恢复流程。一次全局字体变化先收集受影响卡片，批量测量、更新布局后恢复外层位置。各卡片分别保留本地选区和横向偏移。

### D08.4 悬挂缩进

将最终正文字体传给 `ReaderParagraphLayout.apply`。现有空白前缀缓存已比较字体和段落样式，需确认 descriptor 特性与实际 fallback 变化会触发失效；否则显式加入解析字体键或调用 reset。

该 helper 自己持有独立 `NSLayoutManager` 测量空白前缀，这是现有局部实现。本任务避免访问主 `NSTextView.layoutManager` 去取得 glyph API，以防打乱主阅读面的 TextKit 2 路径。[^paragraph]

## D09 设置界面与传播

在 `ReaderSettingsWindowController.swift` 的 Reader 设置面加入字体选择和三态连字控件，预览继续使用真实 Reader。样例至少包含 `!=`、`!==`、`->`、`=>`、`<=`、`>=`、`::`，并带一个放大的声明和注释。

控件改变通过现有 `commitReaderSettings` 链路提交。实现时复查 `CodeInsightApp.swift` 与 `MainWindowController.swift` 的广播和新建阅读面路径，确保每个代码阅读面都收到完整配置。既有 wrap 设计记载了这条传播链路，可作为定位入口。[^wrapdesign]

字体缺失显示“请求的字体不可用，当前使用系统字体”；未验证字体显示中性说明与预览。系统字体选择、回退字体和用户指定字体的状态均要可通过辅助功能读取。

## D10 观测、失败处理与性能

2026-09-23 按用户明确决定，本文及引用的 wrap 设计中未经实测或理论支持的性能阈值（包括 33 ms、250 ms 及相对耗时目标）均为 best-effort 参考，不作为发布硬门槛。保留原数值与各版本实测，说明差异及体验影响；正确成形、选区、复制、布局完整性和资源生命周期仍须验证。

建议增加以下可测试计数：`fontResolutionCount`、`fontCacheHitCount`、`typographyAttributeUpdateCount`、`projectionInstallCount` 的增量、卡片 `measurements` 的增量，以及视口恢复是否因规模或过期任务被跳过。

诊断记录实际字体名、字号、有效 feature、macOS / SDK、字体环境版本、fixture、显示内容身份与阶段耗时。源代码正文不进入普通性能日志。

性能比较分别测量：默认配置与原基线、同字体 On 与 Off、字体切换冷缓存与热缓存、主 Reader 与 Reading Set。不要把创建字体、更新全文属性和可见区域排版合并成一个无法解释的总耗时。

| 失败情况 | 处理 |
| --- | --- |
| 字体无法解析 | 系统回退，保留请求名称与提示 |
| 字重变体缺失 | 同族近似／基准字体，记录实际结果 |
| 特性没有产生预期效果 | 记录未验证或不支持；保留正常可读文本 |
| 新布局尚未可用 | 沿现有有界延迟矫正机制等待下一次布局事件 |
| 快照已过期 | 丢弃恢复，使用最新用户状态 |
| 大文件同步恢复成本过高 | 使用既有保护策略，显式记录降级，保持选区 |

## D11 文件改动清单

| 文件或目录 | 类型 | 改动 |
| --- | --- | --- |
| `Sources/CodeInsightReaderCore/ReaderSettings.swift` | 修改 | 字段、默认、持久化、ReaderTheme 派生 |
| `Sources/CodeInsightReaderCore/ReaderFontConfiguration.swift` | 拟新增 | 字体选择、连字模式与纯值排版键；也可先与设置同文件实现 |
| `Sources/CodeInsightReaderUI/ReaderFontResolver.swift` | 拟新增 | 字体解析、角色派生、特性策略、缓存与回退 |
| `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift` | 修改 | base attributes、typography、增量属性更新、重排接入 |
| `Sources/CodeInsightReaderUI/ReaderViewportState.swift` | 扩展验证，必要时修正 | 连字子范围、合法字符边界、字体重排几何 |
| `Sources/CodeInsightReaderUI/ReaderParagraphLayout.swift` | 修改 | 最终字体输入与缓存失效 |
| `Sources/CodeInsightApp/ReadingSetView.swift` | 修改 | typed layout key、统一字体、测量与外层恢复 |
| `Sources/CodeInsightApp/ReaderSettingsWindowController.swift` | 修改 | 字体与三态控件、诊断、预览 |
| `Sources/CodeInsightApp/CodeInsightApp.swift`、`MainWindowController.swift` | 核对并按需修改 | 设置提交和阅读面传播；测试入口 |
| `Tests/CodeInsightReaderCoreTests`、`CodeInsightReaderUITests`、`CodeInsightAppTests` | 新增测试 | 配置、字体、原生交互与全局传播 |
| `scripts/ci.sh` | 修改 | 注册新增测试后的期望数量和专用检查 |

新增文件均是计划，不代表当前仓库已存在这些实现。

## D12 方案选择与后续扩展

采用 TextKit 2 原生成形，可以复用 Cairn 当前的源范围和阅读交互。单独添加 `.ligature` 属性适合作为 P0 对照组；完整首版还需要字体选择、feature 控制、样式派生和测量失效。

自绘文本引擎会增加文字系统、选择与辅助功能的实现范围，本任务没有相应需求。逐操作符自定义替换则会引入新的语义显示契约，应另立需求。

当前设计为后续动态语义强调提供字体解析与重排入口。更细的风格集合、按语言覆盖、光标附近拆开连字，以及大文件异步锚点恢复，分别以实际用户场景和性能证据评审，不与本次首版绑定。

## 参考资料

[^settings]: [ReaderSettings 与 ReaderTheme](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderCore/ReaderSettings.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^reader]: [ReaderTextView：排版、设置更新、选择与绘制](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^viewport]: [ReaderViewportState 与 ReaderViewportGeometry](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderUI/ReaderViewportState.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^readingset]: [ReadingSetView 与 ReadingSetExcerptView](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightApp/ReadingSetView.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^paragraph]: [ReaderParagraphLayout：悬挂缩进与前导空白测量](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderUI/ReaderParagraphLayout.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^displaymap]: [DisplayMap：源字节与显示 UTF-16 投影](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/Sources/CodeInsightReaderUI/DisplayMap.swift). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^textkit]: [Apple：Meet TextKit 2，成形、事务与视口布局](https://developer.apple.com/videos/play/wwdc2021/10061/). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^ci]: [CI 批次、测试数量校验与架构静态检查](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/scripts/ci.sh). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^attributes]: [Apple：Attributed String 标准属性](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/AttributedStrings/Articles/standardAttributes.html). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^firacode]: [Fira Code 官方仓库：编程连字及 calt 配置](https://github.com/tonsky/FiraCode). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^features]: [Apple：Core Text 字体特性设置](https://developer.apple.com/documentation/coretext/kctfontfeaturesettingsattribute). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^opentype]: [Apple：Core Text OpenType feature tag](https://developer.apple.com/documentation/coretext/kctfontopentypefeaturetag). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^segments]: [Apple：TextKit 2 文本段几何枚举](https://developer.apple.com/documentation/appkit/nstextlayoutmanager/enumeratetextsegments(in:type:options:using:)). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。
[^wrapdesign]: [既有 Soft Wrap 设计；其中现状部分使用更早的代码基线](https://github.com/sonald/cairn/blob/d1f68eee3300df8525ce914b2fb37760c82c65a3/docs/plans/2026-09-19-reader-wrap-design.md). 源码链接固定于本文基线；外部资料核对日期：2026-09-22。


## 实施补充：F1 视口布局成本

`05e4b53` 保留原生 TextKit 2/NSTextView 成形、选择和辅助功能链路，仅收紧既有布局路径：

- Reader 固定左上对齐，`ClickTextView.textContainerOrigin` 返回当前 `textContainerInset`。采样发现 AppKit 的推导原点会在 clip 滚动时调用全文 `ensureLayoutForRange`；这一策略只适用于本 Reader，不声称适用于居中或特殊文字布局。
- 主动渲染属性验证同时受 `viewportRange` 的字符边界限制。未布局 fragment 的零矩形不能作为“仍在可见范围”的依据，否则会扫描并写入整篇临时样式。
- 超过8000源行的wrap-off使用原生viewport relocation与usageBounds估计，最多两次本地布局，避免显式全篇成形。滚动范围可随后由TextKit更新；普通文件仍保留原精确extent路径。
- 几何回归覆盖gutter、选区、附件实际位置和9000行文件末尾4000字符长行的水平/垂直可达性。大文件继续不承诺2pt精确锚点，保留原文、选区和affinity。

`05e4b53` 阶段的 F1 正式测量为 5 次预热 + 30 次样本：Fira 连字 On 的 wrap-on 稳定 p95 约 210 ms、wrap-off 约 170 ms；同字体 Off 约 187 ms、156 ms。这是阶段数据，后续实现的结果见验收记录。原 250 ms 及相对耗时数值保留作 best-effort 参考，按 2026-09-23 用户决定不再作为硬性验收门槛。

### 最终正确性收尾（2026-09-23）

`6eae9e1` 修复真实窗口滚动至EOF后语法颜色未及时应用的问题：在原生布局完成后校验最终可见片段，避免嵌套触发布局。`1f907ec` 将该校验合并到实际视口变化，并在宽度变化未改变缩进上限时复用段落属性；性能探针以测量代次排除旧队列回调，仍记录新窗口内阻塞。

最终回归又独立复现连续字体/wrap切换后8.69pt锚点偏移。`0296f21` 在共享可见属性校验触发原生布局期间保留既有恢复标志，防止布局自动调整clip origin被误作用户滚动而清掉锚点；真实用户滚动仍取消恢复，换文档仍取消旧状态。原断言及六项关联回归通过，红绿证据见验收记录。没有为追逐33ms参考值增加新的布局完成协议。
