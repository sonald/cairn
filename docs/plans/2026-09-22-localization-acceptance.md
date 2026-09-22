# 简体中文与英文国际化：覆盖与验收

状态：实现和验收完成。自动门禁与最终独立发布包的原生中英文验收均通过。

## 文案范围

| 所属模块 | 已迁移界面/状态 | 资源 |
| --- | --- | --- |
| CodeInsightApp | 主菜单、欢迎页、打开/保存/信任对话框、设置、搜索/命令/提交/书签面板、阅读轨迹与阅读集、主阅读器、比较、关系与解析检查器 | `Sources/CodeInsightApp/Resources/{en,zh-Hans}.lproj` |
| CodeInsightAppModel | 关系分组/截断/验证、上下文候选、解析说明、搜索状态、书签状态、会话/项目错误、语言服务可用性 | `Sources/CodeInsightAppModel/Resources/{en,zh-Hans}.lproj` |
| CodeInsightReaderUI | 查找/出现次数、折叠行/成员描述、书签无障碍说明、阅读高度 | `Sources/CodeInsightReaderUI/Resources/{en,zh-Hans}.lproj` |

当前共 783 个双语资源键（App 534、AppModel 220、ReaderUI 29）。每个资源键以所属界面或模型命名，可由对应 `.strings` / `.stringsdict` 查看完整中英对照清单。`scripts/check-localizations.py` 检查两种语言的键、参数与复数规则，并已接入 CI。

## 术语

| English | 简体中文 |
| --- | --- |
| Reading Set | 阅读集 |
| Reading Trail | 阅读轨迹 |
| Relations | 关系 |
| Callers | 调用方 |
| Calls | 调用 |
| Verified | 已验证 |
| Inferred | 推断 |
| Unresolved | 未解析 |
| Possible matches | 可能匹配 |
| Corrected candidates | 已修正的候选 |
| Wrap Lines | 自动换行 |

代码和符号、路径、Git 标识、用户笔记、编程语言/工具/字体/主题专名保留原文。枚举 rawValue、持久化键、命令 selector、accessibilityIdentifier、日志与性能 JSON 不翻译。第三方工具的原始错误作为诊断保留；应用生成的外层说明翻译。

## 行为修复

- 关系树候选分组及异步刷新使用分组身份、验证/截断状态；不再从英文标题前缀推断节点类别。
- 关系与上下文徽标样式使用候选 certainty。短上下文标签直接接收绑定类别，不再猜测英文后缀。
- 菜单动作与快捷键保留；新增测试验证中文命令搜索继续指向原菜单动作。
- 数字格式保留当前地区，复数规则使用资源选中的界面语言，避免中文地区的英文界面显示 `1 matches`。
- 打包脚本复制三个实际依赖的 SwiftPM bundle，并在 plist 声明 `en`、`zh-Hans`。
- 新捕获的阅读集/轨迹保留中英文两份冻结说明，重启恢复时选择界面语言，不重新查询源码或验证服务。角色、跳过原因与 caveat 保留稳定存储值，在展示处翻译。会话格式新增可选字段，旧版纯文本证据保留原文；未知语言回退英文，拒绝嵌套或超限翻译快照。

## 验收记录

| 项目 | 状态 / 证据 |
| --- | --- |
| 双语资源键与参数检查 | PASS；`python3 scripts/check-localizations.py` |
| debug 应用构建 | PASS；应用 137 + 模型 383 个测试通过，见 `.build/localization/app-model-final-tests.log` |
| Foundation 双语复数 0/1/2 | PASS；真实 `.stringsdict` 探针及集成测试通过，含中文地区/英文界面的单数回归 |
| CI 各组成门禁与现有性能门禁 | PASS；1009 测试，Exact/Diff/Reading/Projector/Fold 自测 exit=0；折叠 247.35ms、额外内存 22,183,984 bytes，未调整门槛 |
| 发布脚本及签名完整性 | PASS；最终 release 包及独立目录副本均通过签名校验，3 个 bundle 含 en/zh-Hans，详见 `.build/localization/package-verified.log` |
| 独立目录发布包及语言兜底 | PASS；移开 6 个构建 bundle 后，`/private/tmp` 独立包以 `fr` 启动显示英文；系统默认启动显示中文。最终二进制 SHA-256 与打包记录一致，临时移动已恢复 |
| 简体中文实际用户流程 | PASS；菜单/项目/查找/折叠/书签/设置/多窗口已走通；最终版本展开 2 个可能匹配、冻结阅读集、查看证据、执行中文命令并比较历史提交 |
| 英文实际用户流程 | PASS；中文捕获的两段阅读集无语言参数重启后，角色和冻结说明均为英文，源码逐字不变；英文命令搜索执行、设置和历史比较通过 |
| 系统应用语言选择与重启 | PASS；系统设置为测试 bundle 选择英语，退出后无语言参数重启为英文；清理该覆盖项后无参数重启跟随系统简体中文 |
| 窄窗口/长内容/无障碍标签 | PASS；约 900 点最小宽度下检查双语阅读集/比较/检查器，英文高级设置标签完整；长文件名和路径正常省略且完整 tooltip/AX 可达，代码和标识符保持原文 |

计划要求的验收以最终日志和原生观察为准，源文件迁移和语法通过不作为全部完成的证明。

## 自动验收证据

- `.build/localization/verification.json` 汇总逐项状态及最终二进制 SHA-256。
- `.build/localization/ci-verified.log`：1009 项测试和静态规则通过；整段脚本随后在旧 Exact 单数文案断言处停止。
- 该自测断言修复后，`.build/localization/exact-verified.log` 记录完整 Exact 自测通过，包括真实 rust-analyzer。
- `.build/localization/remaining-ci.sh` 从现有 `scripts/ci.sh` 原样提取后续门禁，未删减检查；`.build/localization/remaining-ci.log` 记录其余自测与 release 性能门禁全部通过。未重复运行未受此自测断言修改影响的 1009 项测试。
- `.build/m11-fold-perf/result.json`：性能门禁 `status=pass`。
- `.build/localization/package-verified.log`：`make-app.sh` 完成构建、资源复制和 ad-hoc 签名校验。本次使用已有 brew 依赖模式，仅作当前 Mac 的本地验收，没有发布或公证上传。

## 最终原生复验

使用测试 bundle `dev.cairn.LocalizationAcceptance`，没有替换用户安装的 `/Applications/Cairn.app`。最终二进制与自动验收产物 SHA-256 一致。

1. 在中文界面打开 `/private/tmp/cairn-i18n-roundtrip`，选中 `unresolved_call_for_candidate_disclosure`，展开“显示 2 个可能匹配”，观察两个 `ping` 候选和中文修饰说明。
2. 冻结两段阅读集并查看中文证据。正常退出后，不传 `AppleLanguages` 重启，系统的单独应用英语偏好生效；`CALL`、`INFERRED`、来源/验证/可用性等说明均为英文，Alpha/Beta 两段源码保持原样。
3. 英文命令面板搜索 `Reading Trail` 并执行，打开轨迹详情；设置和高级排版截图无标签裁切。使用系统四分屏操作缩小到约 900 点宽，检查阅读集和检查器。
4. 英文比较面板选择 `999fcb4`，观察旧版 `Hello` 与工作区 `Welcome` 的真实差异和可用的差异导航。
5. 将构建目录中的 6 个资源 bundle 临时移开，以 `-AppleLanguages '(fr)'` 启动独立包，菜单、阅读器、模型状态和比较控件均回退英文。
6. 删除本任务创建的测试应用英语覆盖项，无语言参数重启后恢复系统简体中文。中文命令面板搜索并执行“阅读轨迹”；中文版本选择器和历史差异正常；先前的阅读集再次显示中文角色。
7. 在 900 点宽窗口打开两层长目录下的长文件名；标签和面包屑按既有方式省略，完整路径仍可通过 tooltip/AX 读取，`原文 stays unchanged` 源码没有被翻译。

原生证据为本任务的 Computer Use 无障碍树与截图记录，结构化摘要保存在 `.build/localization/verification.json`。上述复验没有重新运行分析来替代已捕获的说明，源码、内容身份及两份语言快照的保存往返另有测试覆盖。

## 清理与边界

- `.build/localization/hidden-bundles.json` 已恢复为空，所有构建资源已归位。
- `dev.cairn.LocalizationAcceptance` 的 `AppleLanguages` 测试覆盖项已删除并核实；未修改系统首选语言和正式 Cairn 的偏好设置。
- 旧版纯文本历史证据保持原文；新捕获的阅读集/轨迹保存双语说明。CLI、日志和第三方原始诊断仍保持既有语言。
- 其他未跟踪文件（包括 reader-ligatures 文档）未修改；未推送或发布到外部。
