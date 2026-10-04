# Repository Guidelines

Cairn（Swift package 名称 CodeInsight）是 macOS 14+ 的原生只读代码阅读器。

## 工作原则

- 如无必要，勿增实体。新增类型、概念、依赖或抽象前，说明当前真实需求；遵守 YAGNI，优先复用已有机制和系统 API。
- 用清楚的日常语言解释行为与取舍，只在有助于理解时引用实现细节。
- 修改前检查工作区；不回退他人的改动，不顺手重构无关模块。未经要求不提交、不推送。
- 可以节省时间或提高质量的独立工作，应使用 collaboration 工具并行委派，明确文件所有权。

## 文档：只维护当前认知

[docs/README.md](docs/README.md) 是内部文档入口；产品行为、架构、开发操作和测试策略各有一份现行说明。本文件规定 agent 的工作方式，[docs/testing.md](docs/testing.md) 提供测试分类与命令。

- 修改已有主题的权威文档，不新增重复的里程碑、backlog、requirements、plan、acceptance 系列。
- 新决定推翻旧要求时，直接替换旧条款，并同步中英文 README 和受影响的文档；不要在旧规则后追加另一套例外。
- 临时实施清单放在任务中。只有跨任务仍需要执行的计划才进入文档，完成后把有效结论归入对应主题并删除计划。
- 历史过程从 Git 查阅。留存证据必须有复现用途，注明日期、版本、环境和局限；历史 PASS 不代表当前版本已验证。
- 文档与实现不一致时，确认当前意图再纠正；不得把未实现的设想写成产品能力。保留仍有效的已知限制和未完成验证。
- 第三方来源/许可、fixture 使用说明和可运行原型说明保留在资源旁边，不复制为产品规范。

## 代码结构与构建

- `Sources/CodeInsightApp`、`CodeInsightCLI`：应用和 CLI 入口。
- `CodeInsightCore`、`CodeInsightGit`、`CodeInsightEngine`、`CodeInsightExact`：领域数据、快照、索引、语言服务器；extractor 与 `TreeSitterKit` 负责语法。
- `CodeInsightAppModel`、`CodeInsightReaderCore`、`CodeInsightReaderUI`：应用状态、阅读逻辑、原生渲染。
- `Tests/` 对应模块；`fixtures/`、`goldset/` 提供验证输入；`scripts/` 提供构建与验证命令；`site/` 是静态官网。

使用 Swift 6 和 Homebrew libgit2（`brew install libgit2`），在仓库根目录执行：

```sh
swift build
swift run codeinsight --help
CAIRN_LIBGIT2=brew bash scripts/make-app.sh
open .build/distribution/Cairn.app
bash scripts/ci.sh --help
```

Swift 使用四空格缩进、`UpperCamelCase` 类型名、`lowerCamelCase` 成员名。AppKit/SwiftUI 只能进入 UI target；不要手工修改生成的 `Sources/CLibGit2Vendored`。

## 测试：按风险和边界选择

默认不为每个功能、方法或分支增加单元测试，不追求测试数量或覆盖率指标。大多数易变的功能细节交给少量集成场景和原生交互验证。

| 情况 | 应采用的验证 |
| --- | --- |
| 长期稳定的核心机制：坐标映射、投影、快照身份、缓存隔离、编解码 | 属性/不变量测试；覆盖边界和生成输入，使用独立参照，固定种子并能复现失败 |
| 跨模块工作流、持久化、取消/过期结果、进程生命周期 | 少量集成测试；观察最终输出和资源状态，尽量使用真实边界 |
| 菜单、快捷键、窗口、点击/拖选、布局、主题和设置 | 打包后的原生应用端到端交互；单独构造 view/model 或 self-test 只能提供辅助证据 |
| 文案、常量、简单 getter/setter、直接透传、可逆的样式调整 | 通常不新增单元测试；用对应静态检查或一次原生查看 |
| 明确发生过且难以靠交互稳定复现的错误 | 在能捕获错误的最低稳定边界留一个针对性回归；避免在多层重复同一断言 |

删除测试前检查它实际保护的风险：实现镜像、静态值断言、重复 happy path 可以删除；不能仅因它是单元测试就删除 Unicode、损坏输入、数据丢失、快照污染、竞态和释放资源的保护。UI 辅助测试仍保护这些机制时可以保留，但不得冒充端到端验收。

执行顺序：

1. 根据本次 diff 说明受影响机制和用户路径，选择对应测试域或更窄的 `swift test --filter`。
2. 只跑相关检查；纯文档改动检查事实、链接和命令即可，不运行 Swift 全套。
3. UI 行为改动用真实应用执行相关路径：准备输入 → 用户操作 → 可见结果；必要时验证切换、重开、恢复。记录使用的构建、输入、结果和截图/日志。
4. 完整测试仅用于测试基础设施变更、广泛跨模块改动、发布决策或用户明确要求。外部语料、LSP 全矩阵和长时间性能检查显式运行，不作为每次功能开发的默认前置条件。
5. 相关检查通过后停止。没有新改动、失败或未解决疑点，不重复全量 CI，也不自动扩大性能样本。

测试使用 Swift Testing（`@Test`、`#expect`），函数名描述行为。测试新增/删除不维护固定总数；运行器应从实际发现的测试核对执行完成情况，拒绝零测试、失败或缺失最终摘要。报告完成摘要中的通过、失败、跳过数量；退出码为零不等于完成。

区分 PASS、FAIL、SKIP、BLOCKED、INCOMPLETE；单元/集成、AppKit 进程内检查、self-test 和原生端到端结果分别说明。无法执行原生交互时明确写 BLOCKED，不用模型测试补成 PASS。当前验收不包含 VoiceOver 和语音相关测试，未经明确要求不重新引入。

性能验证默认少量相关样本，足以判断方向即可；反复 p95 测量和长时间资源测试只在明确回归或发布决策需要时进行。

## 提交与 PR

使用 `fix: ...`、`feat: ...`、`docs: ...` 或 `fix(reader): ...` 等聚焦主题。PR 描述最终行为、相关依据、实际验证和限制；UI 改动附原生交互证据。不要把历史测试结果写成本次验收。
