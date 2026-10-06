# 验证策略

测试要保护长期成立的机制和真实故障边界。普通功能以少量集成场景和原生交互验收为主，不为每个方法、按钮、配置值建立一份同构测试。

## 如何选择

| 改动 | 最小验证 |
| --- | --- |
| 文档、注释 | 链接与差异检查；不跑 Swift 测试 |
| 颜色、文案、布局、菜单展示 | 必要静态检查，加原生应用中受影响流程；不新增常量快照 |
| 普通功能 | 一条穿过实际模块边界的主要旅程，必要时补一个失败分支 |
| 字节/字符坐标、投影、折叠、区间运算 | 固定种子的生成输入、不变量和独立参照实现；保留已知反例 |
| 缓存、存储、会话恢复、异步切换 | 集成验证输入边界、损坏恢复、取消和过期结果隔离 |
| LSP、子进程、Git | 协议/进程/仓库集成验证；不以模拟对象的调用次数代替结果 |
| 性能 | 有性能风险时用少量代表样本；发布或明确回归才运行完整性能门禁 |

先写出可能破坏的行为，再选择测试。没有新的改动、失败或未解风险，相关检查通过后就结束。不要因为新增一个功能默认运行全套；不要用测试数量或覆盖率代替价值判断。

## 运行命令

Swift 检查固定使用 Xcode 27.0（27A266a）及随附 Swift 6.4，本地与 CI 共用 `bash scripts/check-toolchain.sh`，选择方法见[开发说明](development.md)。仅 `static` 和帮助不要求 Xcode。工具链不符先终止，不把环境错误混入测试失败。固定版本不会消除宿主系统、字体、窗口服务或 LSP 的差异；远端通过必须由对应 Actions 完成结果确认。

```bash
# 静态：本地化、shell 语法、模块边界和现有架构约束
bash scripts/ci.sh static

# 可以组合，只执行选择的域
CODEX_SANDBOX=1 bash scripts/ci.sh core
CODEX_SANDBOX=1 bash scripts/ci.sh reader
CODEX_SANDBOX=1 bash scripts/ci.sh engine exact
CODEX_SANDBOX=1 bash scripts/ci.sh app

# 更小的回归范围直接用 Swift Testing filter
swift test --filter byteAndUTF16MappingPreservesScalarBoundariesAndRanges

# 发布、跨域基础设施变更，或有证据需要扩大检查时显式执行
CODEX_SANDBOX=1 bash scripts/ci.sh full
```

沙箱内运行直接 `swift test` 时，同 `ci.sh` 设置工作区内的模块缓存目录，并传入 `--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --manifest-cache local`。`CODEX_SANDBOX` 仅供脚本选择这些 SwiftPM 参数，不表示测试获得了原生交互权限。 原生 AppKit 测试还需要宿主窗口和剪贴板服务；若执行环境限制这些服务，先记录环境失败，再在获准的宿主环境只重跑受影响用例，不修改断言或扩大为全套重跑。

| 域 | 包含内容 |
| --- | --- |
| `core` | Core、Git、TreeSitterKit |
| `reader` | ReaderCore、ReaderUI；包括部分真实 AppKit/TextKit 集成 |
| `engine` | Engine 和 Rust/Python/TypeScript extractor |
| `exact` | LSP 编解码、进程、取消、版本边界 |
| `app` | AppModel、App；包括会话、持久化、窗口和菜单集成 |
| `full` | 所有域、静态检查、应用内部 self-test、折叠性能门禁 |

无参数显示帮助并退出，不再隐式全量运行。域选择只缩小执行范围；SwiftPM 发现测试时仍可能编译其他测试目标。

`ci.sh` 从当前构建发现用例，再核对每批完整成功摘要的数量。零测试、命令失败、缺少成功摘要、进程提前退出导致少测都会失败。无需每次新增或删除用例维护固定总数。依赖独立 AppKit 进程的鼠标、字体及窗口测试，以及读取进程级工作计数器的 ownership 测量，均隔离执行。并发搜索的同步 gate 场景放在串行 suite 中，但仍和其余引擎检查处于同一批；等待上限不能超过用于证明行为的阻塞或计时器间隔，以免等待放宽后掩盖回归。

日常 GitHub CI 根据改动路径选择域；文档不会触发 Swift 全套。产品语料质量和性能工作流改为手动触发，避免每个 PR 下载完整语料、安装全部语言工具链并重复运行性能测试。手动门禁用于明确的跨域验收或发布决策。

日常 CI 与产品门禁均安装 Rust 1.97.1 的 `rust-analyzer` 组件并选择该工具链。镜像中存在 `rust-analyzer` 的 rustup 代理不代表组件可运行；日常 CI 安装后先执行 `rust-analyzer --version`，避免等到 LSP 集成测试才发现环境缺失。

## 本次清理的取舍

删除以断言实现细节为主的用例：

- 颜色、字体、尺寸、文案和组件默认值快照，包括 `CairnComponentsTests`、`PanelThemeTests`、`ResolutionInspectorStyleTests`、`ScopeHeaderTests`；视觉效果由原生交互验收判断。
- 面板预设、提交选择器、快捷键表和简单模型透传/枚举转换的重复例子；保留输入校验、配置持久化和真实事件路由。
- Reader 的颜色表、字体表、行号默认开关、wrap setter 属性镜像、hover 卡片简单文案透传；保留实际换行、选择、复制、滚动锚点、折叠投影和字体更新的集成回归。
- 已被完整语法/提取/渲染场景覆盖的语言模式透传、基础高亮快照及重复小例子。

保留的测试不是仅因名字带 integration 或 native：

- `FoldTopologyTests`、`ReaderProjectionTests`、`ProjectionDeltaTests`、`ReadonlyDisplayMapOracle`、`DecorationComposerTests` 等保护折叠、投影、坐标和样式合成不变量；已有生成输入和独立参照实现继续使用。
- `ByteUTF16MapTests` 将两个例子整合成一个确定性属性测试：42 个 Unicode 输入 × 5 种检查点步长，以 Swift 原生 Unicode 编码计数为独立参照，检查全部合法/非法偏移、双向转换和全部范围端点组合。覆盖空串、组合字符、代理对、ZWJ emoji、换行和长输入，无新增依赖。
- `SessionCodecTests`、`SessionRestoreTests`、`BookmarkStoreTests`、`RecentProjectsStoreTests` 保护存储边界、版本兼容、损坏恢复和已有用户数据。
- `SnapshotSwitchTests`、`ExactCoordinatorTests`、`ReaderDerivedDataStoreTests`、reflow 系列保护取消、过期结果、窗口切换和主线程交付。
- Engine、Git、Exact、extractor 中的缓存身份、快照读取、真实语法绑定、跨文件导航、协议解析及子进程清理是机制或集成测试；没有为了削减总数而删除。
- 原生窗口、TextKit、菜单和鼠标测试保留真实输入、几何、选择、生命周期等曾经出错的边界。目录名不能代表验证层级，`ReaderCoreTests` 中也存在原生 UI 集成。

清理后的用例定义数（本次快照，不作为 CI 固定门槛）：

| 测试目标 | 清理前 | 保留 | 净减少 |
| --- | ---: | ---: | ---: |
| AppModel | 437 | 347 | 90 |
| App | 207 | 122 | 85 |
| ReaderCore | 275 | 258 | 17 |
| ReaderUI | 40 | 35 | 5 |
| Core | 17 | 14 | 3 |
| Git / TreeSitterKit / Engine / Exact / 三种 extractor | 357 | 357 | 0 |
| 合计 | 1,333 | 1,133 | 200 |

多数简单展示/功能矩阵已删，例如主窗口测试 48→20、命令面板 18→7；未按“删掉大部分总用例”的配额删除稳定机制、故障恢复或真实集成。快捷键冲突替换保留一条唯一归属→保存/重载→恢复默认的完整不变量检查，防止空 override 被误还原成原默认键。

## 原生交互验收与证据

当前仓库有原生组件集成和应用内部 self-test，但没有覆盖所有产品流程的外部端到端自动化。它们不能自动获得“真实用户端到端已通过”的结论。删除简单功能测试后，下面的交互验收仍由实际发布应用中的操作承担：

1. 打开项目和文件，经搜索/大纲/关系导航到目标，再前进后退，检查落点和阅读位置。
2. 在正文中点击、拖选、复制，折叠/展开并切换自动换行，检查文字、选择和锚点。
3. 经菜单或设置修改主题、字体、快捷键和面板，检查即时效果和重新打开后的保留。
4. 切换文件、快照和窗口，关闭再恢复会话，检查页面归属以及旧结果不会覆盖新页面。
5. 相关功能变更时验证 hover/上下文窗口、书签或 Reading Set 的完整入口到结果。

只执行与变更有关的流程。记录构建来源、操作步骤、预期/实际结果，以及 PASS / FAIL / SKIP / BLOCKED。本次工作没有改动产品 UI，未执行新的原生应用端到端验收；不能将测试删减理解为这些流程已经验证。VoiceOver 和语音相关验收按当前范围排除。

## 新测试准入

新增测试必须能说清：它保护什么长期不变量或真实风险，为什么现有集成/属性测试不能覆盖，以及它失败后会改变什么决策。修复 bug 优先把最小反例放入已有机制测试；只有需要独立环境或不同失败边界时才新增用例/文件。属性测试的参照必须独立于被测算法，随机输入必须可复现。

不要为可逆的小调整增加实现镜像，不为增加数量复制语言、主题、按钮组合。测试删除后若失去唯一的真实故障防护，应保留或提升那一条检查；不能用“以后补 E2E”掩盖已经知道的高风险缺口。

## 本轮清理验证（2026-10-04）

- **PASS**：全部测试目标编译，动态发现 1,133 个用例定义，与上表一致。
- **PASS**：受影响的 `core reader app` 共 805 个用例完成分批验证。首次受限环境执行主批 797 个，776 通过、21 失败；失败均涉及原生窗口/剪贴板服务。获准在宿主环境重跑这 21 个后全部通过，再补跑原有的 8 个隔离用例，8/8 通过。没有改产品代码或放宽断言。
- **PASS**：Unicode 映射属性测试、快捷键归属/持久化检查；本地化 894 个双语键与架构静态检查；shell 语法、文档链接、Git diff 格式检查。
- **PASS**：CI 批次校验的 5 个临时替身场景：正常成功被接受，零测试、部分完成、命令失败和无完成摘要均被拒绝。工作流 10 个路径路由案例及 3 个 YAML 解析检查通过。
- **SKIP**：未改动的 `engine exact` 328 个用例、完整性能/产品语料门禁、真实应用端到端交互；本次无需扩大到这些范围。

原始失败记录保留在 `.build/ci-swift-test-selected.log`；宿主重跑记录为 `.build/cleanup-native-recheck.log` 和 `.build/cleanup-native-isolated-0.log` 至 `-7.log`。这些是本地运行证据，不是永久测试数量要求。
