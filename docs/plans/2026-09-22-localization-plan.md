# Cairn 简体中文与英文国际化计划

状态：实现及验收已完成。自动门禁与独立发布包的原生中英文复验通过，详见 `2026-09-22-localization-acceptance.md`。

## 目标与范围

- macOS 应用提供简体中文（`zh-Hans`）和英文（`en`），英文为开发语言和兜底语言。
- 默认遵循 macOS 的语言偏好；支持系统设置中的应用语言选择，重新启动应用后生效。首版不增加应用内切换器或运行时热切换。
- 覆盖菜单、欢迎页、设置、搜索和命令面板、阅读器、关系树、书签、阅读轨迹、阅读集、提交选择、比较界面、应用生成的错误提示、工具提示及无障碍描述。
- 代码、符号、文件路径、Git 标识、用户笔记保持原文。CLI、日志、机器可读输出、网站和 README 不在本轮翻译范围内。第三方工具原始诊断保留原文，应用提供的标题和说明需要翻译。
- 不改变持久化键、枚举 rawValue、命令身份、快捷键或 accessibilityIdentifier；可供用户听取的 accessibilityLabel/help 应翻译。

## 当前代码的约束

1. 项目使用 SwiftPM，`Package.swift` 尚未声明 `defaultLocalization` 或本地化资源。界面同时使用 AppKit 与 SwiftUI。
2. 文案不仅在 `CodeInsightApp`，也在 `CodeInsightAppModel` 和 `CodeInsightReaderUI`。例如关系树状态、搜索占位提示和折叠区无障碍描述由这些模块生成。
3. `RelationTreeModel.swift` 使用 `title.hasPrefix("Show ")` 等条件维护候选分组，`stableGroupName` 从标题提取身份。翻译前必须解除行为对显示语言的依赖。
4. `ReaderSettingsWindowController.swift` 的自测辅助代码也会按英文无障碍标签查找控件；测试中还有按 `View`、`Wrap Lines` 等英文菜单标题定位的逻辑。
5. `scripts/make-app.sh` 目前只把可执行文件与图标复制进应用，没有复制 SwiftPM 资源 bundle。只验证开发目录中的程序不足以证明发布包正确。
6. `scripts/ci.sh` 当前要求主批次 1003、隔离批次 2、面板批次 2 个测试；这是脚本配置，不是本轮测试通过的结果。增加测试时需按真实发现数量同步维护。

## 最小实现方案

- 使用 Foundation/SwiftPM 原生本地化，不引入第三方依赖、翻译服务或新的公共国际化模块。
- 优先在实际拥有文案的现有 target 中加入 `Resources/en.lproj/Localizable.strings` 和 `Resources/zh-Hans.lproj/Localizable.strings`；有数量变化时使用 `.stringsdict`。
- `Package.swift` 设置 `defaultLocalization: "en"`，为相关 target 声明资源。AppKit 查找明确指定 `Bundle.module`；SwiftUI 也明确指定所属资源 bundle，避免默认查找主 bundle 导致漏译。
- 采用稳定、按场景命名的资源键，附翻译注释；同一概念在菜单、命令面板、工具提示中保持一致。仅在重复调用确有需要时增加 target 内的小函数，不建立自定义语言状态系统。
- 翻译完整句子，参数使用格式占位符；不通过拼接英语单词组成句子。计数覆盖 0、1、多项，日期和数字使用系统格式化能力。保留源代码行号和机器输出的既有格式。
- 对业务逻辑中的文案判断，优先复用现有 `kind`、certainty、direction 等状态。确实缺少身份时，只补充用于区分具体候选分组的最小字段，不扩展通用展示模型。
- 不为翻译改动 Core/Engine 的数据格式；如果底层已有结构化状态或错误，优先在展示边界翻译。对目前直接传递错误字符串的路径逐条确认，避免把内部诊断一并翻译。

## 实施步骤

| 步骤 | 改动与边界 | 验收 | 依赖 |
| --- | --- | --- | --- |
| 1. 文案清单与术语 | 按上述界面登记用户可见文案，区分产品文本、原始内容、诊断和稳定标识；统一 Reading Set、Reading Trail、Relations、Verified、Inferred 等译名 | 每个界面有清单；明确非翻译项；逐项标记依赖显示字符串的行为 | 无 |
| 2. 解除显示文本与行为的耦合 | 聚焦 `RelationTreeModel.swift` 及其测试；同时审计菜单/面板查找、自测辅助代码 | 中文、英文下候选分组展开、数量刷新、异步合并与去重行为一致；测试能在改变标题后发现回归 | 1 |
| 3. 完成第一条双语路径 | 配置 SwiftPM 资源，先迁移欢迎页和打开项目相关菜单；同步修改 `make-app.sh` 的资源复制与 plist 声明 | 开发程序和打包后的应用均可按语言偏好显示中英文，缺少匹配语言时使用英文 | 1 |
| 4a. 菜单与设置 | 迁移剩余菜单、设置、信任与缓存操作、打开失败提示；调整英文标签驱动的自测 | 操作、快捷键和默认按钮不变；设置页两种语言均无裁切 | 2、3 |
| 4b. 搜索与导航 | 迁移 SearchPanel、PalettePanel、CommitPickerPopover 及对应模型提示 | 中文命令可以被搜索与执行；代码符号仍按原文搜索；计数与空状态正确 | 2、3 |
| 4c. 阅读工作流 | 迁移主窗口、阅读器上下文菜单/折叠提示、书签、Reading Trail、Reading Set、比较状态 | 两种语言下阅读、跳转、查找、折叠、书签及比较可用；无障碍文本正确 | 2、3 |
| 4d. 关系与解析状态 | 迁移 RelationWindowController、RelationTreeModel、ContextWindowModel 的显示文本 | 加载、无结果、降级、截断、候选与错误状态都正确；原始证据/诊断不被破坏 | 2、3 |
| 5. 双语发布验收 | 检查漏译、格式参数、布局及资源分发，运行针对性测试和既有 CI | 满足下方完成标准，保留真实应用验收记录 | 4a–4d |

步骤 3 是首个检查点：先证明资源可随应用分发，再进行大批量替换。步骤 4 按界面分别提交，每批控制在少数相关源码文件及其资源/测试内。不同文件的文案迁移可以并行，但同一资源文件由一人汇总，避免覆盖。

## 验证方法与完成标准

### 自动验证

- 增加一个小型资源一致性检查：检查中英文键集合、格式占位符及复数资源结构，发现缺失和参数不匹配即失败；不为每条静态译文单独写测试。
- 增补关系树文案独立性回归测试；优先使用现有测试体系，不另建测试框架。
- 行为测试通过 selector、稳定标识或已有状态查找控件；少量专门的本地化测试显式断言中英文结果。语言选择分别在新进程中验证，避免全局 Locale/bundle 缓存相互污染。
- 阶段构建：`swift build --product codeinsight-app`。
- 模型回归：`swift test --no-parallel --filter CodeInsightAppModelTests`；AppKit 回归遵循 `scripts/ci.sh` 既有隔离批次，不把隔离测试合并运行。
- 完成迁移后运行 `bash scripts/ci.sh` 和 `bash scripts/make-app.sh`，依赖模式及沙箱参数沿用当前环境。不把零测试、缺失完成摘要或中途崩溃计为通过。

### 实际应用验收

- 使用打包的 `Cairn.app` 分别启动英文、简体中文、无匹配支持语言三个新进程；确认菜单、AppKit 控件和 SwiftUI 设置页使用一致语言。启动语言参数示例：`-AppleLanguages '(zh-Hans)'` / `-AppleLanguages '(en)'`。
- 校验 plist 的 `CFBundleDevelopmentRegion` / `CFBundleLocalizations` 与实际资源一致；验证系统设置中的应用语言选择及重启后的行为。
- 将产物移出构建目录，在源构建资源不可访问的隔离环境验证两种语言，防止 `Bundle.module` 的开发路径兜底掩盖漏打包。检查生成的资源访问代码与最终安装位置是否匹配。
- 实际走通：欢迎页 → 打开项目 → 文件/符号搜索 → 阅读与折叠 → 关系候选展开/刷新 → 添加书签/阅读集 → 设置 → 多窗口切换。
- 检查最小可用窗口尺寸、长路径、长符号名、0/1/多项结果；中文无乱码，英文扩展后无按钮和标签裁切；VoiceOver 标签可理解。
- 应用自有文案无未说明的漏译，正常界面不显示资源键。用户内容与诊断原文不计为漏译。

## 暂不增加

- 应用内语言设置、热切换、远程翻译、代码生成器和通用本地化框架。后续明确需要时再评估。
- 不以国际化为由重构窗口、阅读器或关系系统；只修复翻译确实会触发的文本耦合与布局问题。

## 依据

- [Apple：Localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources)
- [SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)

以上采用原生资源方案；具体构建产物位置与语言匹配行为必须由步骤 3 的实际产物验证。
