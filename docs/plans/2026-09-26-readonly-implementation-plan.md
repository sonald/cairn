# Cairn 只读架构优化：实施计划与验收

日期：2026-09-26  
状态：**实施中。S0–S4 已完成（各阶段限制单独记录）；S5–S7 尚未验收。实际结果见 [S0](evidence/readonly/stage-s0.md)、[S1](evidence/readonly/stage-s1.md)、[S2](evidence/readonly/stage-s2.md)、[S3](evidence/readonly/stage-s3.md)、[S4](evidence/readonly/stage-s4.md)。**
复核基线：`6a54ef1562282c8852c3038022c12720b96d9fc0`。  
设计依据：[只读架构详细设计](2026-09-26-readonly-design.md)。

## 1. 执行方式

实施按 S0–S7 完成交互查询与显示更新，S8 单独验证后续原型。每个阶段由小提交组成；每个提交必须有针对其行为的测试和完整测试结束摘要。UI 变化还必须有原生窗口证据。仓库目前明确要求核心与模型不导入 AppKit/SwiftUI，新增测试时更新 CI 分批计数。[S1][S2]

本计划中的 `readonly…` 测试名、新脚本、新文件及新 CLI 参数均为**拟新增**。只有本文件 §12 标注为“当前已有”的命令，可以直接用于本基线。

### 1.1 提交包和依赖

```text
S0 基线、参考实现、工作量观测
 ├─ S1 标识符索引与共享构建
 ├─ S2 Gutter 数据生命周期
 └─ S3 静态折叠与调用归属
       │
       └──── S4 失效分类与绘制/排版分流
                 │
                 ├─ S5 投影拆分与局部文本更新
                 └─ S6 统一重排和大文件成本策略
                          │
                   S7 集成、回归和发布验收
                          │
                   S8 分块与阅读投影原型（独立决策）
```

S1–S3 可以在各自模块并行实现，但修改共享 `ReaderTextView` 时应按提交顺序集成。S4 的纯更新计划可在前面阶段开始时编写测试；正式切换依赖 S1–S3 提供稳定的数据身份。S5 的纯投影拆分可以先独立开发，局部 storage 更新应等 S4 事务分类稳定后接入。

交付包 A 由 S0–S3 加对应集成回归构成；交付包 B 由 S4–S7 构成。S8 不纳入这两个交付包的完成条件。

### 1.2 当前基线的继承点

| 已存在 | 实施约束 |
| --- | --- |
| `ReaderDocument`、局部绑定与行表 | 复用它们，不重新定义源码身份 |
| `ReaderTypographyKey` 和 `ReaderFontResolver` | S4 接入现有键与字体环境版本 |
| 纯排版更新路径 | 补齐它的测试和与颜色混合变化的事务 |
| 大于 8,000 行时的部分视口估算路径 | S6 扩大边界测试与成本分类 |
| `DisplayMap` 的折叠复制/映射语义 | S5 以旧实现为可执行参考 |
| `ReaderParagraphLayout` 的 Tab 测量 | 局部范围版本继承相同度量规则 |
| 分批 Swift Testing 和 fold 性能脚本 | 新测试加入原门禁，不改写已有通过含义 |

源码事实见 [S3][S4][S5][S6][S7]。本计划不包含从零实现字体、连字或基础软换行。

## 2. S0：冻结基线、建立参考结果和观测

### 目标

得到可以回答“改了什么、少做了什么、是否变快、有没有破坏阅读”的基线。性能优化以记录的固定提交和输入为参照。

### 任务

| 任务 | 操作与目标文件 | 产出 |
| --- | --- | --- |
| S0.1 基线记录 | 阅读 `AGENTS.md`、`Package.swift`、`scripts/ci.sh`；记录实际开发 HEAD 与本设计基线的差异 | `evidence/readonly/baseline.md` |
| S0.2 热路径调用图 | 搜索 `identifierOccurrences`、`drawRuler`、`project`、`installProjectedText`、`applyFoldProjection`、`apply`、`updateSyntax`、`outgoingCalls`；记录调用者及线程归属 | 按事件组织的调用链表 |
| S0.3 参考算法 | 从现有标识符查询、投影、折叠选择、调用归属逻辑提取测试参考实现 | 测试专用 oracle，冻结对应 SHA |
| S0.4 工作量观测 | 在真实扫描、物化、字典构建、storage 更新和 region 查询点增加计数；保持旧计数语义 | `ReaderWorkCounters` 及事件前后差值 |
| S0.5 Fixture 与 runner | 增加固定种子的多语言输入、输入 manifest、场景驱动 runner | 可重复的功能/性能输入与 JSON 产物 |

### 基线场景

至少记录：热标识符查询、稳定滚动、hover、单函数折叠/展开、Full↔Overview、纯颜色变化、纯字体变化、颜色+字体+wrap、异步语法到达、已有视口与无视口的大文件关闭折行、A→B→A、外部修改后刷新和多窗口关闭。

初始测试参考不要调用被优化的新实现，否则无法发现二者同时犯同一类错误。oracle 只存在于测试 target 中，避免运行时误用。

### 出口

基线源码 SHA、fixture 哈希、工具链、实际字体与环境齐全；每项操作能够输出原始计数和真实结果。当前已存在的失败、跳过和环境限制单独列出。S0 不要求把所有历史缺陷一次修完，但后续测试必须区分历史失败与新回归。

建议提交：`test(reader): capture readonly workload baselines`、`test(reader): instrument actual readonly work`。

## 3. S1：标识符索引与共享派生构建

### 目标

索引就绪后，同名出现查询复用不可变结果；点击、滚动、折叠和查找状态恢复不再重复扫描源字节。

### 任务

| 任务 | 具体步骤 | 文件与测试 |
| --- | --- | --- |
| S1.1 纯索引 | 实现 token 定位、名称驻留、posting 偏移和语法排除区间归并；与 oracle 比较 | 新增 `IdentifierIndex.swift`、`IdentifierIndexTests.swift` |
| S1.2 分析身份 | 定义内容+语言+Reader 分析版本+阶段；自定义测试文档明确使用独立身份 | 新增 `ReaderAnalysisKey` 与身份测试 |
| S1.3 构建服务 | 作用域服务维护 in-flight 与有界缓存；worker 构建；MainActor 只接收结果 | 新增 `ReaderDerivedDataStore.swift` 和异步测试 |
| S1.4 消费端迁移 | Reader 初始化/语法升级时请求派生数据；迁移 `occurrenceNSRanges`、`refreshOccurrenceRendering`、`refreshFoldExposures` 等调用 | `CodeInsightReaderUI.swift` 与实际调用者 |
| S1.5 就绪交互 | 未就绪保存最新意图；就绪校验订阅和身份；失败走本地化状态通道 | ReaderCore 状态模型、UI 状态测试与必要的 strings |

### API 迁移

新增交互查询从 prepared data 读取。运行时 UI 不再调用可能构建/扫描全文的同步入口。为保持已有 `public identifierOccurrences(at:)` 的源码兼容，可保留带弃用说明的同步包装器，用新 builder 计算结果，明确其构建成本；它不得出现在 Cairn 阅读交互调用链中。旧算法本身只保留在测试 oracle 中。

所有仓内调用者通过搜索核对并迁移。测试增加“交互路径不触发 builder”的断言，避免只修改主点击入口，遗漏折叠隐藏计数和状态恢复入口。

### 并发顺序

构建服务先登记任务，再等待结果。某个 Reader 关闭时移除订阅；另一个 Reader 仍在使用同键时不取消共享任务。缓存命中直接返回不可变数据。索引完成时，原 A 订阅即使窗口重新打开了 A，也不能覆盖新订阅的选择状态。

### 必测

I01–I09、A01–A04、M01–M03，编号定义见 §11。重点包括 Unicode 等价比较、关键词、点击注释内文字的基线行为、同名遮蔽、语法未就绪升级、构建中切文件和独立视图同时请求。

### 出口

与 oracle 的确定性结果一致；已就绪的重复点击 `identifierScannedBytes` 增量为 0；相同缓存键并发请求只构建一次；折叠/恢复命中结果不触发扫描；冷首屏和峰值内存有对比证据。

### 回退

在内部验证开关下恢复原交互实现，保留测量。回退不得把 `building` 状态伪装成无命中。撤销优化不改变源码、书签、会话或持久化格式。

建议提交：`feat(reader-core): add identifier posting index`、`feat(reader-core): coalesce derived data builds`、`perf(reader): reuse prepared identifier occurrences`。

## 4. S2：把 Gutter 数据准备移出绘制

### 目标

稳定滚动和 hover 的工作量主要与可见几何和可见标记相关，不与全文折叠数量相关。

### 任务

| 任务 | 具体步骤 | 文件与测试 |
| --- | --- | --- |
| S2.1 文档装饰 | 构建 FoldID→region、源头行、声明源行；明确同一行多个 fold 的稳定优先级 | 新增 `ReaderDocumentDecorations.swift` |
| S2.2 投影汇总 | 维护未隐藏折叠头、隐藏 diff/书签/命中计数；依赖投影与标记修订 | 新增 `ReaderDecorationState.swift` |
| S2.3 绘制迁移 | `drawRuler` 读取派生结果；移除每次 draw 的全局构建与排序 | `CodeInsightReaderUI.swift` |
| S2.4 交互迁移 | fold hover、点击、当前行、导航标记查询采用同一份数据和首视觉行几何 | UI 与原生交互测试 |

S2 可以先用现有 fold 数组生成文档装饰，S3 再替换为拓扑中的共享查询；避免两阶段都产生长期重复字典。源数据与像素坐标分别管理，窗口宽度变化只使后者失效。

### 必测

G01–G06、L03、V01。配置包含：无行号但有折叠、多个 fold 同一源行、折叠内书签与 diff、带长续行的 gutter、首次视觉行已滚出屏幕以及刚打开的新 provider。

### 出口

稳定滚动前后 `decorationBuildCount` 与 `drawGlobalRecordVisits` 的增量为 0；关闭/开启行号、更新 diff 或折叠时派生数据及时变化；绘制、命中与无障碍标记一致。不能仅以画面截图相同判定通过。

### 回退

按独立内部开关恢复旧 gutter 查询，正文投影不受影响。回退记录中保留全局扫描计数，不关闭观测。

建议提交：`perf(reader): prepare gutter data by document revision`、`fix(reader): share gutter drawing and hit testing data`。

## 5. S3：预计算折叠拓扑和调用归属

### 目标

将不可变语法关系从重复查询移到一次构建。

### 任务

| 任务 | 具体步骤 | 文件与测试 |
| --- | --- | --- |
| S3.1 折叠建树 | 对归一化 fold 区间建立父子、子树范围、头行、facet 关联 | 新增 `FoldTopology.swift`、`FoldTopologyTests.swift` |
| S3.2 折叠消费 | 迁移 recursive siblings、ancestor 展开、focus target、相关大纲查询 | `CodeInsightReaderUI.swift`；S2 共享文档索引 |
| S3.3 调用归属 | 建立 region 查找、call owner、facet owned-calls；保留所有 tie-break | 新增 `CallOwnershipIndex.swift` |
| S3.4 Engine 接入 | `outgoingCalls` 读取已分组调用；`callers` 的 region 定位读取 ID 索引 | `EngineSession.swift`、Engine 测试 |
| S3.5 生命周期 | 索引绑定内容分析/store；保持旧快照对象可读且可释放 | 生命周期和 profile 切换测试 |

### 正确性细节

折叠拓扑不对交叉区间强行套树算法。对同范围不同类型、空区域、重复 ID 等异常明确遵从原有归一化或失败规则。关闭祖先内的子状态仍保留；同一可见投影不能因为逻辑集合改变而被无条件替换。

调用归属建立时同时验证原有定义范围条件。嵌套函数与闭包的 owner 由现有规则确定。保留 512 条上限、完整调用数判定、结果顺序和解析证据。只有语法归属可共享，Resolver/Exact 结果仍按当前上下文生成。[S7]

### 必测

F01–F07、C01–C06、A03、M03。使用自动生成区间与可执行 oracle 验证父子/归属一致，不能只使用一棵整齐的人工嵌套树。

### 出口

重复查询不增加 topology/ownership 构建次数；外向调用查询的 region 全扫描为 0；所有旧结果和截断语义一致；跨 store 不复用错误的 intern ID。

建议提交：`perf(reader-core): index fold topology`、`perf(engine): precompute call ownership`。

## 6. S4：统一失效分类与绘制/排版分流

### 目标

同一种状态变化，无论从哪个入口到达，都产生相同且最小的更新计划。

### 任务

| 任务 | 具体步骤 | 文件与测试 |
| --- | --- | --- |
| S4.1 纯计划 | 为内容、分析、投影、排版、绘制身份定义变化矩阵和合并规则 | 新增 `ReaderUpdatePlan.swift`、参数化测试 |
| S4.2 复用字体键 | 使用现有 `ReaderTypographyKey` 与字体环境版本；记录实际有效文本宽度 | `ReaderSettings.swift`、`ReaderFontResolver.swift` 消费端 |
| S4.3 纯颜色路径 | 更新 renderer 与附件/provider 外观，不 `project`、不替换字符、不主动重排 | `ReaderTextView.apply(settings:)`、附件实现 |
| S4.4 分析升级 | 同内容语法结果到达时，仅更新变化层；fold 集合相同则复用投影 | `updateSyntax`、派生数据发布 |
| S4.5 混合事件 | 一次设置中字体+颜色+wrap 合并提交；幂等应用直接结束 | MainWindow/Settings 设置传播路径 |
| S4.6 属性缓存 | 缓存范围组合计算；系统 validator 被调用时仍履行属性设置协议 | `RenderingAttributesCoordinator` |

### 必测

V01–V09、L01–L03、A04。重点测试“字体变化后再改颜色”和“一次同时改字体颜色”，不能只测试各自独立更新。

字体环境变更需要重新解析实际字体，即便 PostScript 名称没变。系统自动明暗变化、参数透明度、声明标记透明度、附件后来才创建 provider 都要覆盖。[S5]

### 出口

纯颜色更新的投影构建、字符替换和应用主动全量布局计数都为 0；纯字体变化不替换字符；相同设置重复应用不发生额外应用主动重排；系统属性失效后颜色仍正确重建。

### 回退

按更新类别恢复原有路径。允许保留可靠的纯字体优化，仅回退有问题的附件颜色分支；不使用一个开关把已验收能力全部撤掉。

建议提交：`refactor(reader): classify update dependencies`、`perf(reader): update colors without rebuilding text`、`fix(reader): apply combined settings in one transaction`。

## 7. S5：拆分投影并实现局部文本更新

### 目标

先建立可独立测试的源段投影，再减少小范围折叠的文本物化和替换。两步分别提交，便于定位回归。

### S5a：先拆责任，保持显示行为

| 任务 | 具体步骤 | 产出 |
| --- | --- | --- |
| S5a.1 纯投影 | 实现 source/fold 段、UTF-16 前缀长度、源与显示查询、构建边界验证 | `ReaderProjection.swift` |
| S5a.2 适配原入口 | `DisplayMap` 委托新纯数据；UI 继续经统一映射入口访问 | `DisplayMap.swift` 兼容层 |
| S5a.3 独立物化 | 把字符串拼接、typography 和附件创建搬入物化器；先保持完整安装 | `ReaderProjectionMaterializer.swift` |
| S5a.4 全面比对 | 新旧投影文本、双向映射、可见/隐藏范围和复制结果一致 | P01–P06 |

S5a 的完成不代表已经获得局部替换性能收益。它的明确收益是职责与测试边界，以及无折叠映射无需全文解码。

### S5b：结构差异与局部更新

| 任务 | 具体步骤 | 产出 |
| --- | --- | --- |
| S5b.1 差异计划 | 对齐源段边界，比较新旧显示结构，产生旧坐标 patch | `ProjectionDelta.swift` |
| S5b.2 范围物化 | 只生成替换片段及需要的附件/属性；复用未变化片段 | 物化量计数 |
| S5b.3 段落范围更新 | 为 `ReaderParagraphLayout` 增加范围入口与源前导空白元数据；处理左右拼接段落 | 段落扫描计数与一致性测试 |
| S5b.4 提交预检 | 验证旧版本、NSRange、预期长度和附件；从后向前修改 | `ReaderTextCommitter.swift` |
| S5b.5 交互恢复 | 保存并恢复全部选区、affinity、两个隐藏端点和视口源锚点 | 选择/复制/拖拽测试 |
| S5b.6 安全回退 | 预检失败走全量新投影安装并记录原因；无合法新投影则保留旧内容 | 回退场景与计数 |

### 必须处理的例子

旧投影是一个完整 source slice，新投影在中间折叠 20 行。差异算法应先细分出共同的前后源码区间，最终只替换中间区间。仅比较 slice ID 会把整个文件判成不同，这个例子必须有测试。

展开一个祖先，内部若有已折叠子节点，替换片段应包含这些子占位。保留未变化的附件时须更新其当前位置与生命周期；不能把旧 display offset 当成永久位置。

当 projection 发生变化而字体/主题未变，段落处理不能无条件重写全部 attributed string。对一个占据全部文件的超长段落，允许报告无法获得局部排版收益，但不能伪造“局部已完成”的计数。

### 事务与错误路径

预检和 fallback 的选择在修改前完成。提交 MainActor 不挂起；应用回调与 validator 不能在新旧映射混合状态时查询。全部字符更新完成后，再安装对外可见的映射状态并恢复验证。

正确性验证分层：测试/Debug 可以做全文物化比对；正常热路径验证版本、长度、边界与变化区间，避免每次 patch 后重新扫描全文。Swift `do/catch` 不承担捕获 Objective-C 范围异常的常规职责。

### 必测

P01–P12、F03/F04、V03/V04、L01/L03/L04、A02。所有坐标相关测试都包括 ASCII、中文、emoji、组合字符、CRLF、尾部换行与 EOF。

### 出口

新旧完整投影与映射一致；无折叠投影构造的物化字节为 0；单个小折叠没有全量字符替换且变化片段正确；多 patch 结果与完整物化一致；回退原因可观察；完整选区与原文复制保持正确。

需要同时报告 `materializedUTF8Bytes`、`attributeUpdatedUTF16Units`、`paragraphRecordsVisited` 和原生布局耗时。不能只展示 partial replacement 次数。

### 回退

保留新纯投影，关闭局部 replacement 即可恢复完整物化后安装。若纯投影存在正确性问题，再按 S5a 的适配边界恢复旧 `DisplayMap`。两个回退层分别测试。

建议提交：`refactor(reader): separate projection from materialization`、`feat(reader-core): derive structural projection patches`、`perf(reader): commit local fold projection changes`、`fix(reader): preserve selection across projection patches`。

## 8. S6：统一重排并扩展大文件成本策略

### 目标

减少不同更新入口之间的行为偏差，并对大文件、超长行和异步状态提供可解释的恢复策略。

### 任务

| 任务 | 具体步骤 | 文件与测试 |
| --- | --- | --- |
| S6.1 成本描述 | 收集字节数、最长行、结构数量、投影长度；与现有 FileTier 并用 | ReaderCore 成本模型 |
| S6.2 共同事务 | 归并设置、宽度、语法、投影、字体环境入口；复用稳定源锚点 | `ReaderReflowCoordinator` |
| S6.3 取消规则 | 用户滚动、选择、导航、新内容、关窗终止旧恢复；布局自身的滚动不伪装用户输入 | coordinator 与原生事件接入 |
| S6.4 布局就绪 | 使用实际布局/绘制回调、几何与目标身份判断；有限次后续修正 | 现有视口诊断扩展 |
| S6.5 边界覆盖 | 大文件有/无 previous viewport、超长单行、EOF、隐藏 anchor、零宽到有效宽度 | L01–L09 |
| S6.6 阅读面接入 | 分别验证主/辅 Reader、Context、Settings、Reading Set 与普通文本 | 原生交互矩阵 |

### 策略更新方式

先用 S0 记录的分布评估现有 8,000 行条件。把“文件行数”扩展成成本分类时，新增阈值放在可注入配置中并记录来源；不要把多个随意常量分散到 `apply`、`updateSyntax` 和宽度回调。

无可恢复锚点的分支单独定义。缺少旧视口时，大文件不能无条件转入全量同步 extent 枚举。明确区分未显示范围的估算、当前可见范围的精确布局，以及无法完成的状态。

### 首帧与稳定状态

函数返回、调用 `layoutViewport()`、固定 sleep 结束都不构成首帧证据。runner 观察实际 draw，并确认当前内容和目标设置。稳定状态还需要锚点误差、待处理 correction、布局目标身份和最终选区相符。

测试可以有有限总超时，但要报告超时发生在哪个阶段，不把缺少原生事件循环的环境判为测试成功。

### 出口

同一组输入变化从不同入口到达时，最终投影、选区、锚点和状态一致；快速连续操作无旧恢复抢回视口；大文件路径不因遗漏分支触发无意全量布局；超长单行的剩余限制有单独测量和说明。

### 回退

保留已验证的原大文件策略，单独关闭新成本分类或新协调分支。恢复路径始终检查内容与请求身份；回退不能取消 stale 保护。

建议提交：`refactor(reader): unify reflow ownership and cancellation`、`perf(reader): classify layout cost beyond line count`。

## 9. S7：集成、资源验证与发布验收

### 目标

确认局部改进在真实阅读流程中共同工作，并形成可重复的完成记录。

### 任务

| 任务 | 步骤 | 完成证据 |
| --- | --- | --- |
| S7.1 工作流回归 | 打开仓库→查找→定义/调用跳转→聚焦→切版本→冻结结果→关闭恢复 | 操作日志、来源状态、原生截图 |
| S7.2 兼容性 | Rust/Python/TypeScript/TSX、字体/连字/wrap、已有非源码预览、安全与本地化 | 测试摘要与人工矩阵 |
| S7.3 生命周期 | 多项目窗口、两个视图共享文档、取消构建、反复切历史版本、关闭最后使用者 | retained IDs、派生量与物理内存记录 |
| S7.4 性能对比 | 固定环境交替运行基线与候选；分场景报告冷/热结果 | 原始 JSON、p50/p95、峰值、工作量差值 |
| S7.5 回退演练 | 分别关闭 identifier、decoration、local replacement、reflow 新分支 | 结果仍正确，回退原因可审计 |
| S7.6 文档和门禁 | 更新测试批次数、架构检查、验收记录；移除未使用原型入口 | PR/提交列表与验收签署 |

资源验证区分两种事实：缓存已移除条目，以及所有实际强引用已经释放。仅检查 LRU 数量下降不足以证明数据已释放。UI callback、Task、provider 和测试 observer 都需要检查保留关系。

### 完成条件

R01–R14 的必测项完成；所有已发布阅读面获得原生证据；功能/工作量门禁通过；专用性能样本完整；历史遗留项与新回归分开处置；回退路径验证；不存在未说明的跳过。

S7 通过之后才能把交付包 B 标记为完成。某个测试环境受限时，状态保持“代码已实施，原生验收未完成”。

建议提交：`test(reader): verify readonly integration and lifetimes`、`docs: record readonly optimization acceptance`。

## 10. S8：分块与阅读投影原型

### 进入条件

S7 的证据表明：剩余主要成本仍在大段落、远处布局或全量 backing storage；或者需要验证一个具体的跨文件阅读体验。由实际问题选择原型，不把所有设想合成一个大型框架。

### 原型任务

| 原型 | 最小实现 | 验证问题 | 产出 |
| --- | --- | --- | --- |
| S8a 分块内容 | 独立文本内容提供器，支持可见区、跨块选择、复制和定位 | 是否减少首屏/折叠工作；extent 和 AX 是否可靠 | 与现有 Reader 对比的 FINDINGS |
| S8b 符号阅读组合 | 一个函数及少量真实相关片段，明确来源与显示实例 | 重复片段、跨文件复制、返回导航是否容易理解 | 可操作原型与交互裁决 |
| S8c 逻辑骨架 | 可展开的真实片段和规则摘要 | 隐藏检查/清理路径会否误导；如何恢复完整上下文 | 规则与反例集 |

新原型放在独立 `Prototypes/` 子目录。采用条件包括明确性能/理解收益、完整来源映射、现有交互可承载以及可控制的维护成本。暂缓决定也要保存输入、结果和具体缺口。R15 在 S8 的原型范围内验收，不作为 A/B 发布的隐性依赖。

## 11. 测试清单与追踪矩阵

下列编号固定用于 PR、验收记录和失败报告。测试文件可按模块组织，函数使用行为命名；新增场景不要求每一行恰好对应一个函数。

### 11.1 标识符与异步派生物

| ID | 输入/操作 | 断言 |
| --- | --- | --- |
| I01 | 三语言与 TSX 的固定代码 | 每个可选位置与旧算法结果一致 |
| I02 | 中文、组合字符、规范等价名称、emoji 邻接 | 名称比较和字节边界保持原语义 |
| I03 | 关键字、注释、字符串、数字以及在这些区域内点击 | 明确区分选词规则与命中过滤规则，匹配基线 |
| I04 | Rust raw identifier、Python 标识符、TS `$`/TSX 文本 | 不把优化变成无记录的词法规则变更 |
| I05 | 重复查询同一名称/不同名称 | 索引构建次数不增加，扫描字节增量为 0 |
| I06 | 同名遮蔽和嵌套作用域 | 同名出现与同绑定引用的结果不同且准确 |
| I07 | 高命中数量与命中范围局部可见 | 不在每帧枚举全部命中，结果完整性有说明 |
| I08 | 空文件、EOF、标识符边界、非法偏移 | 无越界，不将 EOF 解释成 token |
| I09 | 纯文本对象升级为相同 ContentID 的语法对象 | 排除范围更新，旧派生身份不能错误命中 |
| A01 | 同键两个视图同时请求 | 一个构建任务，两个独立订阅 |
| A02 | A→B→A；原 A 任务晚到 | 新订阅可使用缓存，旧订阅不发布 |
| A03 | 刷新内容/profile/关窗时构建尚未完成 | 无旧结果覆盖、无无主任务持续持有 |
| A04 | 连续点击与设置变化同时进行 | 只发布最新关注对象及匹配身份的结果 |

### 11.2 折叠、装饰与调用归属

| ID | 输入/操作 | 断言 |
| --- | --- | --- |
| F01 | 多层合法折叠 | parent/children/subtree 与参考一致 |
| F02 | 同范围、同头行、不同类型 | 选择和 tie-break 稳定 |
| F03 | 关闭祖先后改变子折叠状态 | 子状态保留，可见段相同则无文本更新 |
| F04 | 展开祖先，内部已有关闭的子节点 | 子占位正确恢复 |
| F05 | recursive siblings、focus、unfold ancestors | 新索引与参考查询结果一致 |
| F06 | 交叉范围、重复 ID、无效边界 | 明确拒绝/兼容规则，不静默构造错误树 |
| F07 | 固定种子自动生成大量区间 | 重复查询无全体包含分析 |
| G01 | 50k 行固定 fixture 上滚动和 hover | 全局装饰构建/扫描增量为 0 |
| G02 | 首视觉行滚出，续行仍可见 | 无重复行号/折叠柄，命中区域准确 |
| G03 | 无行号但有 fold/diff；恢复行号 | 各列显隐与坐标正确 |
| G04 | fold 内书签、diff、标识符和搜索命中 | 汇总及时更新且未扫描源码 |
| G05 | 标记改变、投影改变、系统主题改变 | 只使相应数据失效 |
| G06 | 附件后建 provider、旧 provider 被释放 | 外观为最新状态，无泄漏或旧引用 |
| C01 | 普通函数、方法、顶层执行区 | owner 与旧算法一致 |
| C02 | 嵌套定义、匿名闭包、默认参数调用 | 不错误归属到外层或丢失必要调用 |
| C03 | 重叠区域、同长度区域 | 原有最小范围/ID tie-break 一致 |
| C04 | 0、512、513 条调用 | 顺序、限制和 truncated 一致 |
| C05 | 相同内容在不同 store/profile | 语法索引合法复用，驻留编号与解析证据正确 |
| C06 | 重复展开 Calls/Callers | query region 全扫描为 0，构建次数稳定 |

### 11.3 失效、投影与原生布局

| ID | 输入/操作 | 断言 |
| --- | --- | --- |
| V01 | 重复同设置/稳定滚动 | 无应用额外投影与文本更新 |
| V02 | 只改颜色/透明度 | 无字符替换、无应用主动全量布局 |
| V03 | 字体、字号、连字分别变化 | 保持来源与投影，只改属性/布局 |
| V04 | 字体+颜色+wrap 一次变化 | 一次合并事务，最终设置一致 |
| V05 | 同内容语法升级，fold 集合相同/不同 | 前者复用投影，后者正确新建 |
| V06 | 旧字体被同名替换或 fallback 改变 | 字体环境版本使布局失效 |
| V07 | 框架使 rendering attributes 失效但自有版本没变 | validator 仍正确提交属性 |
| V08 | 明暗自动切换与附件本地化文案变化 | 颜色即时更新，尺寸变化时重排 |
| V09 | 行号列改变有效宽度 | 分类为实际几何变化，不漏掉 wrap 重排 |
| P01 | 无折叠投影构造 | 不解码全文，长度/映射正确 |
| P02 | 随机合法单调投影 | 完整物化与旧 DisplayMap 一致 |
| P03 | 所有合法源边界双向查询 | visible/hidden/EOF 的往返规则成立 |
| P04 | 选中占位或跨越占位复制 | 与原源码范围拼接规则一致 |
| P05 | 大面积折叠 | 不按原文件大小无条件预留投影字符串容量 |
| P06 | 非法范围/溢出/未知 FoldID | 预检失败，不进入部分写入 |
| P07 | 全文件一段变成中间小折叠 | 能对齐源段边界，只更新实际差异 |
| P08 | 多个旧坐标 patch | 从后向前应用后与完整物化一致 |
| P09 | patch 前目标文档/投影改变 | 拒绝过期提交 |
| P10 | 选区两端、多个选区、隐藏端点与 EOF | 完整状态恢复，复制未改变 |
| P11 | patch 连接处 Tab、连字、跨行注释、CRLF | 邻接段落与字形正确，扫描范围可解释 |
| P12 | 强制预检失败、全量回退、无合法新投影 | 失败状态清晰，无半新半旧显示 |
| L01 | wrap/字号/宽度连续变更 | 源锚点、偏移与选区达到预期最终状态 |
| L02 | 恢复中用户滚动/导航/点击 | 旧 correction 不抢回视口 |
| L03 | 多视觉行、EOF、硬换行、空文档 | 首行标记、当前行背景与几何正确 |
| L04 | 语法结果到达时已在中间/末尾阅读 | 使用共同恢复策略，无跳回文件开头 |
| L05 | 大文件有/无 previous viewport | 无意外同步全量 extent 扫描 |
| L06 | 少行但超长单行 | 成本分类捕获，剩余限制可测量 |
| L07 | 窗口从零宽/未挂载变为可见 | 延迟布局与订阅正常收敛 |
| L08 | Reading Set 字体/wrap/颜色更新 | 外层锚点与卡片选区正确；纯颜色不重测量 |
| L09 | 两窗口不同宽度/字体环境变化 | 布局状态独立，共享派生数据安全 |

### 11.4 内存、兼容与追踪

| ID | 输入/操作 | 断言 |
| --- | --- | --- |
| M01 | 超过缓存软预算的大派生物 | 无无限驱逐重建，活跃超预算可观察 |
| M02 | 反复切文件/版本后关闭全部视图 | 无无主长期引用；缓存/进程数据分开记录 |
| M03 | shared task 的一个订阅取消 | 另一个订阅正常完成；最后订阅关闭可释放 |
| X01 | 原生鼠标拖选、复制、键盘选择、VoiceOver | 坐标与导出内容正确，TextKit 2 状态保持 |
| X02 | 关系跳转、快照切换、stale、书签、Reading Set、会话恢复 | 证据与身份保护未回归 |
| X03 | Safe Mode、非源码预览、本地化、Settings 传播 | 安全和产品功能通过现有检查 |
| X04 | 所有回退开关逐项演练 | 功能正确，原因与计数仍可见 |

| 需求 | 主要阶段 | 必要测试组 |
| --- | --- | --- |
| R01/R02 | S0/S4/S5/S7 | P03/P04/P09/P10、I02/I08、X01/X02 |
| R03/R04 | S1 | I01–I09、A01–A04 |
| R05 | S2 | G01–G06、L03 |
| R06 | S3 | F01–F07 |
| R07 | S3 | C01–C06 |
| R08 | S4 | V01–V09 |
| R09 | S5 | P01–P12 |
| R10 | S1/S4/S6 | A01–A04、P09、L02 |
| R11 | S5/S6 | P10/P11、L01–L09、X01 |
| R12 | S1/S3/S7 | M01–M03、A03 |
| R13 | S4/S6/S7 | V03/V06/V08、L08/L09、X01–X03 |
| R14 | S0/S7 | 所有场景的完整摘要、真实计数与环境记录 |
| R15 | S8 | 原型的来源映射、重复实例和跨文件复制测试 |

需求编号使用 R 前缀，布局测试使用 L 前缀；其余测试按表中前缀区分。

## 12. 测试入口与 CI 接入

### 12.1 当前已有的命令

在具有图形会话的 macOS 开发机、仓库根目录执行。当前仓库要求 macOS 14+、Swift 6 和相应 libgit2 环境。[S1]

```bash
swift build

# 按既有脚本运行分批测试、架构检查、自测和 fold 产物检查。
CODEX_SANDBOX=1 bash scripts/ci.sh

# 独占环境下复用现有 fold 预算验证。
swift build -c release --product codeinsight-app
bash scripts/run-fold-perf.sh \
  --app-bin .build/release/codeinsight-app \
  --fixture fixtures/fold_perf.rs \
  --manifest fixtures/fold_perf.manifest.json \
  --enforce-budgets

# 原生窗口检查。
CAIRN_LIBGIT2=brew bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

当前 `ci.sh` 配置主测试批次 1028 项，另有两个 2 项批次和一个鼠标隔离项；这是脚本中的预期计数，**不是本次执行的通过结果**。实施添加/移动测试后，按实际发现的测试更新批次数。完整结束摘要是必需条件，进程退出 0 不能单独判通过。[S2]

### 12.2 拟新增的单测命名与命令

以下入口需要在相应阶段实现测试后使用：

```bash
swift test --no-parallel --filter 'readonlyIdentifier'
swift test --no-parallel --filter 'readonlyGutter'
swift test --no-parallel --filter 'readonlyFoldTopology|readonlyCallOwnership'
swift test --no-parallel --filter 'readonlyInvalidation'
swift test --no-parallel --filter 'readonlyProjection'
swift test --no-parallel --filter 'readonlyReflow|readonlyLifetime'
```

每组必须有非零测试数和完整摘要。原生鼠标、窗口重建等测试根据现有隔离经验单独运行，避免 AppKit 状态污染。不要仅调整超时或增加 sleep 来修复不稳定测试。

### 12.3 拟新增的工作负载入口

建议 S0 增加 `scripts/run-readonly-workload.sh`，参数契约为：

```text
--app-bin <release executable>
--suite <identifiers|gutter|projection|reflow|lifetime|all>
--manifest <frozen fixture manifest>
--out <result directory>
--enforce-budgets   # 可选，仅专用环境使用
```

功能有效性、输入身份和工作量约束始终强制；时间/内存预算是否强制由明确参数决定。runner 需要区分 `pass`、`fail`、`blocked` 和 `not_run`，避免缺少图形环境时生成虚假的通过记录。

可为 app 增加内部 `--self-test-readonly` 场景入口，复用已有原生自测结构。入口由 S0 实现后，才能把它加入 CI；本基线尚无该新增入口。

### 12.4 静态边界检查

保留已有核心层 AppKit/SwiftUI 禁令及 ReaderUI 的映射访问限制。[S2] 新检查只约束具体生产调用路径，例如 Reader 交互中不得调用同步兼容扫描方法。

不能以宽泛 `grep NSLayoutManager` 禁止所有旧布局类，因为现有 Tab 前缀测量使用独立测量对象；需要检查的是主 `NSTextView` 是否请求了旧布局入口并实际进入兼容模式。[S10]

## 13. Fixture、测量协议与验收产物

### 13.1 Fixture 集合

以下规模是测试输入设计，不是性能结果。真实仓库样本与生成样本分别报告。

| ID | 输入 | 主要用途 |
| --- | --- | --- |
| Q01 | 空文件、一个字符、尾部有/无换行、CRLF/Unicode 分隔符 | 边界与 EOF |
| Q02 | 约 100 行的 Rust/Python/TypeScript/TSX | 可人工核验语义与视觉 |
| Q03 | 多层作用域、同名遮蔽、注释/字符串/关键字 | 标识符及局部引用 |
| Q04 | 中文、emoji、组合字符、规范等价名称、双向文本注释 | 坐标与名称比较 |
| Q05 | 当前 `fold_perf.rs` 与已有 manifest | 与既有折叠门禁保持可比 |
| Q06 | 10k、30k、50k、100k 行的固定种子样本 | 规模变化与成本策略 |
| Q07 | 很少行、单行 1 MiB/更大的受控样本 | 捕获按行数分类的盲点 |
| Q08 | 0/512/513 个调用及大量嵌套区域 | 归属与截断语义 |
| Q09 | 多个 fold 共用头行、相同范围与交叉异常范围 | 归一化和 tie-break |
| Q10 | 同一函数中高密度重复名称 | 结果数量大时的可见范围工作 |
| Q11 | 两个内容近似、快照不同的文件与版本序列 | 错误缓存键和过期发布 |
| Q12 | 多个冻结摘录与不同宽度窗口 | 卡片、共享资源与视口独立 |

manifest 保存生成器版本、seed、语言模式、文件哈希、字节数、逻辑行数、最长行、预期 token/fold/call 数和说明。计数与哈希由工具生成并交叉检查，不手工填写声称已测量的数据。

### 13.2 测量协议

先固定基线与候选提交，用同一 Swift/SDK 构建 Release。记录机器、OS、CPU、电源状态、窗口和 viewport 尺寸、实际解析出的字体和 OpenType 请求。先完成必要的解析、派生构建和可见布局，再执行热场景。

每个版本至少 30 次有效样本，按基线/候选成组交替，分别报告冷与热、首帧与稳定布局。原始样本保留，不能只保存平均值或一张截图。用户操作序列固定；异常/超时样本单列，不能直接从统计中无记录删除。

对短操作，记录被测区域自身时间与整个交互时间。避免把 worker 构建计入热查询，也避免把它完全隐藏而不报告冷路径成本。样本期间任何文本/字体/fixture 配置不同，均判为不可直接比较。

### 13.3 建议结果结构

下面为未执行模板，`null` 表示还没有测量：

```json
{
  "schemaVersion": 1,
  "status": "not_run",
  "baselineCommit": "6a54ef1562282c8852c3038022c12720b96d9fc0",
  "candidateCommit": null,
  "scenario": "warm_identifier_lookup",
  "fixtureSHA256": null,
  "environment": {
    "osVersion": null,
    "swiftVersion": null,
    "machine": null,
    "resolvedFont": null,
    "viewportPt": null
  },
  "samples": [],
  "workDelta": {
    "identifierScannedBytes": null,
    "projectionPlanBuildCount": null,
    "fullTextReplacementCount": null,
    "paragraphRecordsVisited": null
  },
  "latencyMs": {"p50": null, "p95": null, "max": null},
  "peakPhysBytes": null,
  "functionalChecks": [],
  "fallbacks": [],
  "limitations": []
}
```

不同场景记录其实际相关指标，不能把所有无关字段填写 0 来表示通过。工作量计数必须来自操作前后实际增量。

### 13.4 产物目录

```text
.build/readonly/<candidate-sha>/
  environment.json
  fixture-manifest.json
  raw/
  summaries/
  native-captures/
  test-logs/

docs/plans/evidence/readonly/
  baseline.md
  stage-s0.md ... stage-s7.md
  acceptance.md
```

原始大体积产物可以留在 CI artifact；仓库记录应保存可定位的 artifact 标识、哈希和必要摘要。截图是原生证据，不能代替行为断言。

## 14. PR 划分、风险与回退管理

### 14.1 推荐 PR 边界

| PR | 包含阶段 | 必须可独立证明的变化 |
| --- | --- | --- |
| PR-01 | S0 | 加入参考、计数和 runner，不改变交互语义 |
| PR-02 | S1 | 标识符索引与调用链迁移 |
| PR-03 | S2 | 绘制前全局数据工作移除 |
| PR-04 | S3 折叠 | 拓扑查询替换且结果一致 |
| PR-05 | S3 Engine | 调用归属索引替换且证据/截断一致 |
| PR-06 | S4 | 失效计划、颜色更新与混合设置事务 |
| PR-07 | S5a | 投影/物化拆分且输出完全一致 |
| PR-08 | S5b | 局部 patch 与选择/段落恢复 |
| PR-09 | S6 | 共同重排、成本分类与大文件边界 |
| PR-10 | S7 | 集成验收、资源和发布记录 |

PR-04 与 PR-05 分开，避免 Reader 与 Engine 的独立风险相互阻塞。PR-07 先合并正确性重构，再评审 PR-08 的增量收益。

### 14.2 风险优先处理

| 风险 | 最早检测点 | 处理 |
| --- | --- | --- |
| 正常文件首屏因新索引变慢 | S1 冷路径测量 | worker 构建、复用语法信息；发布前处理 |
| 缓存混淆纯文本/语法阶段 | I09/A03 | 完善分析键与发布身份 |
| 颜色更新遗漏未创建的 provider | G06/V08 | provider 从当前外观状态初始化 |
| 一次小 patch 之后全文段落扫描 | P11 与段落访问计数 | 范围段落更新与元数据复用 |
| TextKit 清空属性后自有缓存误判有效 | V07 | 缓存计算结果，履行 validator 提交 |
| 新旧投影中间态被回调观察 | P09/P12 | 预检、同步提交、回调抑制与发布边界 |
| 同名 Unicode 比较变化 | I02/I04 | 保留原 String 比较语义 |
| 调用上限/owner tie-break 改变 | C02–C04 | 精确复现参考规则 |
| 反复切版本持续占用内存 | M02 | 排查所有强引用，不只检查缓存容量 |
| 重排完成记录早于真正绘制 | L01/L04 与原生记录 | draw/布局身份/锚点共同确认 |

### 14.3 回退开关约定

内部配置分别控制 identifier cache、decoration cache、局部 projection replacement 和新 reflow 策略。开关用于测试、灰度或故障回退，默认值随阶段验收决定；不必增加用户设置 UI。

每次回退记录开关状态和原因。回退路径仍满足内容身份、复制、选择与安全约束。完成两个正常发布周期后，再依据维护成本决定是否删除兼容路径；周期数量是建议的工程策略，不代表已有发布安排。

## 15. 最终验收与交接

验收记录使用随文档提供的 [验收模板](evidence/readonly/acceptance-template.md)。填写实际 candidate SHA、阶段完成状态、测试摘要、原生证据、性能样本与回退结果。

正式交接同时给出：实现了哪些需求、还保留哪些限制、已知失败是否为历史问题、运行新脚本的方法、新增缓存的所有者与预算、尚未删除的兼容入口。

**完成状态按证据更新：**“设计评审通过”“切片代码完成”“功能与工作量验收通过”“原生与性能验收通过”“交付完成”。不可仅根据代码合并或进程退出成功，把整个项目标记为完成。

## 16. 源码参考

[S1]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/AGENTS.md "仓库开发规范"
[S2]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/scripts/ci.sh "现有 CI 与测试隔离"
[S3]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift "Reader 文档与查询"
[S4]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift "Reader 渲染、投影与重排"
[S5]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/Sources/CodeInsightReaderUI/ReaderFontResolver.swift "已有字体解析与环境版本"
[S6]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/Sources/CodeInsightReaderUI/DisplayMap.swift "当前投影参考"
[S7]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/Sources/CodeInsightEngine/EngineSession.swift "当前调用归属与查询"
[S8]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/scripts/run-fold-perf.sh "当前性能脚本及预算模式"
[S9]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/Sources/CodeInsightReaderCore/ReaderSettings.swift "已有排版键与设置"
[S10]: https://github.com/sonald/cairn/blob/6a54ef1562282c8852c3038022c12720b96d9fc0/Sources/CodeInsightReaderUI/ReaderParagraphLayout.swift "当前 Tab 与段落度量"
