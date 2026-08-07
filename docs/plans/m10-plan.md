# M10 实现计划 v1.3.1：Explainable Navigation（可解释的导航）

> **一句话目标**：让 Cairn 不只告诉用户"跳到哪里"，还告诉用户"为什么可以这样跳、这个判断
> 是否完整、后来有没有 exact provider 给出一致或不同的目标"，并让用户看见自己穿过陌生代码的
> 路径、返回分叉点继续另一条。
>
> **由来**：v1 定方向与语义；v1.1 修九项分层/协议阻塞；v1.2 修十一项接口阻塞；v1.3 建 §3.0 单一
> 类型定义源（治"定义散落导致跨节矛盾"的根因）；**v1.3.1 补最后一批并发/语义阻塞**——四条都是
> 编译器抓不到的运行期/语义 bug（Exact-first 到达、空目标 vacuous-truth 误判、主行无修正轨迹、
> Store 存 live ref）。它们印证了一件事：纯类型层可交 E1a 的编译器仲裁，但语义/并发合同必须在
> prose 里定死——否则会带 bug 进代码。修完 v1.3.1 后保留"开工前阻塞已解除"。
>
> **v1.3.1 补丁清单**（外部事实已核对：`UnresolvedSymbolRef`/`TrustMode` conformance/并行发布架构）：
> 1. `RelationQueryContext` 用状态机表达 Engine/Exact 并发到达（`exactQuery` 从 `let?` 改
>    `.notStarted/.pending/.completed` 状态机）——`nil` 分不出"没查"与"在查"会让早开 Inspector 撒谎（§3.4）。
> 2. `providerTargets.isEmpty` 时 `[].allSatisfy{.different}` 返回 `true` → 成功空查询被误判成
>    conflict；空目标作第一条规则、全部保持 Inferred（§3.8）。
> 3. 主 provider 行无 `ReconciliationRef` → 点它看不到"修正了谁"；ref 提升到行级
>    `reconciliationRefs: [ReconciliationRef]`（数组，一行可跨多 call site）（§3.8、§3.0）。
> 4. `ResolutionExplanationStore` 仍存 live `ResolutionTrace`（含 ref）+ 快照字段重复 → 彻底拆
>    `LiveResolutionExplanation` / `MaterializedResolutionExplanation`，定 row→explanationID 回写（§3.13）。
> 5. 五个小修：`UnresolvedSymbolRef`（非不存在的 `UnresolvedTargetHint`）；`exactQuery` 须可变；
>    `ReconciliationRole: Hashable`、`ExactAnalysisEnvironment` 去掉 Hashable（TrustMode 只 Sendable）；
>    `displayedCount`→`returnedCount`；`TargetComparison.different` 保守化（原始 path/offset 不等 ≠ different）。
>
> **v1.3 修正清单**（阻塞项均系 v1.2 自身跨节矛盾，已核对；小合同依赖的外部事实已核对）：
> 1. `CandidateObservation`(Core) 被 §3.7 要求"带 `ObservedTarget`"(AppModel) → 又成循环依赖；
>    `ObservedTarget` 与 `ResolutionEndpoint` 功能重复 → §3.0 定死：Core 持 `CandidateEndpoint`，
>
> **v1.3 修正清单**（阻塞项均系 v1.2 自身跨节矛盾，已核对；小合同依赖的外部事实已核对）：
> 1. `CandidateObservation`(Core) 被 §3.7 要求"带 `ObservedTarget`"(AppModel) → 又成循环依赖；
>    `ObservedTarget` 与 `ResolutionEndpoint` 功能重复 → §3.0 定死：Core 持 `CandidateEndpoint`，
>    `ObservedTarget` 仅展示层投影、删 `ResolutionEndpoint`。
> 2. `conflict.reconciliation` 与 `candidateOnly` 的 not-corroborated 判定都依赖查询级 context，
>    换根/关窗后悬空；与 E1a"trace 自包含"矛盾 → 会话级 `ResolutionExplanationStore` + 导航时
>    物化快照（§3.0、§3.13）。
> 3. `CallSiteReconciliation` 没存 `roles`、`ReconciliationRef` 没定义；集合差 `candidate−targets`
>    与"只有 `.different` 进 conflict、`.notComparable` 中性"冲突 → 显式三分算法 + `inconclusiveCandidate`
>    角色（§3.8）。
> 4. not-corroborated 用"context.exactQuery 非 nil"判据，但该枚举含 `.unsupported`/`.notApplicable`
>    → 逐 case 映射；`QueryExhaustiveness` 定 RA=`.bestEffort`（§3.4）。
> 5. `ExactAttribution` 已有 `trustMode`+`coverage`（已核 `ExactProvider.swift:152/154`），加
>    `environment` 会双真值 → E1b0 删旧两字段、`environment` 为唯一来源；`Set<ExactAnalysisLimitation>`
>    需 Hashable + 输出排序（§3.6）。
> 6. `RelationSetObservation` 未指明描述哪套结果 → 命名 `candidateRelationSet`、只描述 fuzzy/source
>    查询完整性；500 行 UI cap 留 presentation 状态；`RelationQueryObservation.completed` 自带
>    `ExactOrigin`（attribution 无 origin，已核）（§3.5）。
> 7. `ResolutionTraceSnapshot` 未定义、不能是 `ResolutionTrace` 的 typealias（含外部引用）→
>    定为无 ID/ref 的物化快照（§3.0）。
> 8. E0 "恢复进对应 snapshot" 与 §3.14 冲突 → 拆 commit 精确 / 旧 worktree best-effort（E0）。

---

## §0 事实基线（已核对 HEAD = `1c284f5`，仅列 v1.3 新增/关键项）

- `origin/main..HEAD = 0`；M9 PASS。真实体验/感知层验收由 **CUA 模型**执行。
- **模块依赖**：`Core ← Exact(依赖 Core+Git) ← AppModel(依赖 Core+Engine+Exact+Git+ReaderCore)`。
  `ExactAttribution`/`ExactLocation` ∈ **Exact**（`ExactProvider.swift:146/32`）；`ExactOrigin` ∈
  **AppModel**（`ExactCoordinator.swift:7`，`.worktree`/`.materialized(commitOID:)`，**独立于
  attribution**）。`RelationTreeModel`/`ContextWindowModel` 都在 AppModel。**Core 不得引用三者。**
- **`ExactAttribution` 全字段**（`ExactProvider.swift:146`）：provider/toolVersion/configFingerprint/
  environmentFingerprint/featureSelection/**`trustMode`**/generatedAt/**`coverage`**。→ 加
  `environment` 必须删旧 `trustMode`+`coverage`（§3.6），否则双真值。
- **两级完整性**：Resolver 每个 candidate 写死 `.complete`（`Resolver.swift:557`，**无 resolver 产出
  `.partial`**）；结果集截断在 `EngineSession.swift:307`（`>512 ? .truncated : .complete`）。500 行
  UI cap 在 `makeChildren`（`RelationTreeModel.swift`）是 presentation 状态。
- **路径归一化合同**（`ExactCoordinator.swift:14` 注释）：项目内位置归一为相对路径，依赖位置保持
  绝对路径——`§3.8` 的 `TargetComparison` 据此判 identity。
- **conflict/merge 现状**：`promoteExactEdges`（`:699`）逐 edge、conflict 分支（`:731`）压 `.unresolved`
  丢 RA 目标、同 call site 多 candidate 共享 `exactQuery` 重复请求；`mergeExact`（`:758`）exact 无条件
  `.exact`、未匹配 fuzzy 保持 Inferred（`:820`，合同测试 `RelationTreeModelTests.swift:251` 锁定）。
- **definition 三层塌 nil**：`parseDefinition` 取 `array.first`（`RustAnalyzerProvider.swift:1035`）；
  `ExactCoordinator.definition`（`:383`）无 active session 时 `return nil`（`:393`），此刻无 attribution。
- **badge 两通道**（`:1079`/`:1087`）；散文违例 `name match only`（`:1093`，不看 completeness/coverage）；
  `evidenceLine` seam 端到端在但走不到（`:1227`、`RelationWindowController.swift:728/1140`）。
- **两套 readiness**（`ExactReadiness` / `ExactCoordinator.Readiness:91`）；`onCoverageChange` observer
  （`RustAnalyzerProvider.swift:255`）；rawValue 已面向用户（`ContextWindowModel.swift:652`）。
- **导航三入口**：`AppModel.navigate`（`:531`）/ `MainWindowController.navigate(to:byteOffset:)`
  （`:1930`，设 flag）/ `.navigate(…snapshotID:source:)`（`:3493`，Reader 显示原语）；flag（`:73`）
  由 `didLiveScroll` 清（`:289`）。`JumpRecord`（`NavigationHistory.swift:3`，`symbolAnchor` 仅 facet 名）；
  history 线性、Back 删 forward；commit 目标存 revision（可精确恢复），worktree 目标只存 `.worktree`。
- `TabStripModel.Tab`（`:6`）强绑 `fileURL` → 非文件文档顺延 M11。无 `StableSymbolID`。
- **文件规模**：`CodeInsightApp` 7182、`MainWindowController` 3917、`RelationTreeModel` 1585、
  `RustAnalyzerProvider` 1162、`ExactCoordinator` 860、`ContextWindowModel` 798。**不拆文件。**

---

## §1 成功合同

1. epistemic 状态（**Verified / Inferred / Unresolved**）在**同一 badge 通道**一眼可辨；目标位置
   （依赖 / 未索引）作独立维度。
2. Inspector 能回答：为什么是候选？依据多强？还有没有可能遗漏其他目标？后来有没有 exact provider
   给出一致或不同的目标？默认简洁、渐进披露。
3. conflict 时主列表按明确 policy 优先显示 provider 结果、错误候选退出主集合作修正轨迹；
   not-corroborated 继续 Inferred，不降级/删除/标"已否定"。
4. 每句解释不撒谎：partial/truncated/unknown/nameOnly/依赖离线 必须显式改变句子；Exact 的
   "已验证目标"与"分析环境限制"分开表达。
5. 显式语义导航带 cause；会话内路径可见，返回分叉点走另一条会分支而非覆盖；切 snapshot 分段。
6. 一条关系的来源推断与验证结果同时可见（Inspector `SOURCE`/`VERIFICATION` 两段），不暗示"RA 即真值"。

---

## §2 范围

**M10A Explainable Resolution**：G0、E0、E1a、E1b、E1b0、E1c、E1d、E2、E3。
**M10B Semantic Navigation**：N1、N2。**探索 P0**：Reading Set 原型（固定 trace fixture，可提前）。
**总验收 V0**：迁移清单门禁 + CUA 任务式验收。

**明确不做**：非文件文档原语（`TabContent`）→ M11；Reading Set 实现 → M11；Symbol Lineage / Cairn
Time → M12+（跨快照身份走带证据的 `SymbolLineageEdge`，不发明伪精确 `StableSymbolID`）；Rust Lens
专项（Inlay/Macro Expansion/cfg/Ownership-Async）；中文本地化顺延；AI 解释层 Canvas 后；不拆
MainWindowController / CodeInsightApp。

---

## §3 设计裁决

### §3.0 类型模型（单一定义源，后续裁决只引用不重定义）

**CodeInsightCore**（不得引用 Exact/AppModel 类型）：
```swift
struct SourceLocation { let path: String; let byteOffset: UInt32; let line: UInt32?; let column: UInt32? }
enum CandidateEndpoint { case occurrence(SymbolOccurrenceID); case unresolved(UnresolvedSymbolRef) } // 无 exactLocation；UnresolvedSymbolRef 已存在于 ScopeModel.swift
struct CandidateObservation {   // 持 Core 原生 target，绝不持 ObservedTarget/ExactTarget
    let target: CandidateEndpoint
    let certainty: Certainty; let dispatch: DispatchKind; let provenance: ResolutionProvenance
    let completeness: Completeness   // 前向兼容分支：当前无 resolver 产出 .partial，synthetic 测（非死码）
    let evidence: [ResolutionEvidence]
}
```
**CodeInsightExact**：
```swift
struct ExactTarget { let location: ExactLocation }   // 只存目标，不含 query-level attribution
enum ExactDefinitionQueryResult { case completed([ExactTarget]); case cancelled; case unavailable(String) }
enum ExactAnalysisLimitation: Hashable { case buildScriptsDisabled; case procMacrosDisabled; case dependenciesUnavailableOffline }
struct ExactAnalysisEnvironment { let trustMode: TrustMode; let limitations: Set<ExactAnalysisLimitation> } // 不加 Hashable：TrustMode 只 Sendable（已核）；只有 Set 需 ExactAnalysisLimitation: Hashable
enum QueryExhaustiveness { case guaranteed; case bestEffort; case unknown }  // RA call hierarchy 固定 .bestEffort
// ExactAttribution 改造（E1b0）：删 trustMode + coverage，加 environment: ExactAnalysisEnvironment（唯一 trustMode 来源）
```
**CodeInsightAppModel**：
```swift
enum ObservedTarget { case candidate(CandidateEndpoint); case verification(ExactTarget) } // 仅展示层投影；唯一 target union（无 ResolutionEndpoint）
struct VerificationObservation { let target: ExactTarget; let attribution: ExactAttribution; let origin: ExactOrigin }
enum RelationQueryObservation { case completed(attribution: ExactAttribution, origin: ExactOrigin, exhaustiveness: QueryExhaustiveness); case unsupported; case notApplicable }
struct RelationSetObservation { let completeness: Completeness; let returnedCount: Int; let totalCount: Int? } // 只描述 fuzzy/source 查询完整性（§3.5）；returnedCount ≠ 500 行 UI cap
enum ReconciliationRole: Hashable { case corroborated(candidateIndex: Int, targetIndex: Int); case correctedCandidate(candidateIndex: Int); case inconclusiveCandidate(candidateIndex: Int); case notCorroboratedCandidate(candidateIndex: Int); case providerOnly(targetIndex: Int) }
struct CallSiteReconciliation { let id: ReconciliationID; let querySite: SourceLocation; let candidates: [CandidateObservation]; let providerTargets: [VerificationObservation]; let roles: [ReconciliationRole] }
struct ReconciliationRef: Hashable { let contextID: RelationQueryContextID; let reconciliationID: ReconciliationID; let role: ReconciliationRole }
enum ResolutionTrace {   // live 模型，可含 ref；持久化前必物化为 MaterializedResolutionTrace
    case candidateOnly(CandidateObservation)   // not-corroborated / pending 由所属 context.exactQuery 判定，见 §3.4
    case verificationOnly(VerificationObservation)
    case corroborated(candidate: CandidateObservation, verification: VerificationObservation)
    case conflict(candidate: CandidateObservation, reconciliation: ReconciliationRef)
}
// —— Relations-查询级、可变；用状态机表达并发到达顺序（§3.4 阻塞1：Exact 可先于 Engine 到达） ——
enum CandidateRelationQueryState { case pending; case completed(RelationSetObservation); case failed }
enum ExactRelationQueryState { case notStarted; case pending; case completed(RelationQueryObservation) }
struct RelationQueryContext { var candidateQuery: CandidateRelationQueryState; var exactQuery: ExactRelationQueryState; var reconciliations: [ReconciliationID: CallSiteReconciliation] }
struct RelationRowExplanation { let primaryTrace: ResolutionTrace; let contextID: RelationQueryContextID; let reconciliationRefs: [ReconciliationRef] } // refs 是数组：一行可合并多个 call site，主 provider 行也持有（§3.8 阻塞3）
// —— live 与会话级持久彻底分开（§3.13 阻塞4：Store 禁含 live ref） ——
struct LiveResolutionExplanation { let trace: ResolutionTrace; let contextID: RelationQueryContextID; let reconciliationRefs: [ReconciliationRef] } // 仅当前 Relations 用，可含 context/ref
struct RelationFactsSnapshot { let candidateRelationSet: RelationSetObservation?; let relationQuery: RelationQueryObservation? }
struct ReconciliationSnapshot { /* 物化的 call-site 集合与 roles，无 ID/ref */ }
struct MaterializedResolutionTrace { /* trace 无外部引用物化版：conflict 内联 ReconciliationSnapshot */ }
struct MaterializedResolutionExplanation: Sendable { var trace: MaterializedResolutionTrace; var relationFacts: RelationFactsSnapshot? } // 禁含任何 ID/ref；conflict 的 reconciliation 已内联进 trace，无独立字段
struct ResolutionExplanationSnapshot: Sendable { let explanation: MaterializedResolutionExplanation; let capturedAt: Date }
@MainActor final class ResolutionExplanationStore { func create(_: MaterializedResolutionExplanation) -> ResolutionExplanationID; func update(_: ResolutionExplanationID, to: MaterializedResolutionExplanation); func value(for: ResolutionExplanationID) -> MaterializedResolutionExplanation? } // AppModel 会话级；只存物化数据
struct NavigationExplanation { let explanationID: ResolutionExplanationID; let observedAtNavigation: ResolutionExplanationSnapshot }
```
两个 owner：`RelationQueryContext`（查询级、随 Relations 根存亡）与 `ResolutionExplanationStore`
（会话级、AppModel 持有、Trail 引用之）。无第三个并行存储。

### §3.1 分层门（引用 §3.0）
Core 只持 `CandidateEndpoint`；`ObservedTarget`/`Verification*`/`ResolutionTrace`/context/store 全在
AppModel；`ExactTarget`/`ExactDefinitionQueryResult`/`ExactAnalysisEnvironment` 在 Exact。E1a 以
**"编译无循环依赖"**为门。E1a 验收改为：**每种 observation 持所在模块原生 target（Candidate→
`CandidateEndpoint`、Verification→`ExactTarget`）；`ObservedTarget` 仅展示层投影，不被 Core 持有；
trace 非"全自包含"——conflict 经 `ResolutionExplanationStore` 物化后才自包含**（见 §3.13）。

### §3.2 扩大 Coordinator，definition case-specific
`ExactLocation?` → `ExactDefinitionQueryResult`（§3.0）；Coordinator 输出附 attribution/origin。规则：
`.completed([])`=成功无目标（≠unavailable≠cancelled）；**`.cancelled` 是控制流、不写 trace**；
**stale generation 直接丢弃、不返回当前模型**；`.unavailable` 更新 `VerificationAvailability`、
通常不形成边级 verification；无 session 的失败无 attribution（用 case-specific 表达，不强制非可选）。

### §3.3 conflict 与 not-corroborated 是两件事（核心红线）
*Exact 返回另一个目标 = 冲突（修正主结果 + 留审计）；Exact 结果集没出现候选 = 仅未 corroborate
（继续 Inferred）*。未匹配来自 provider 能力边界/macro/动态 dispatch/join key 非稳定身份/exact 缺陷——
都不构成"这条边不存在"。

### §3.4 not-corroborated 逐 case 映射（修正"非 nil"判据 + 并发到达状态机，阻塞1）
`RelationQueryContext` 用状态机（§3.0）表达 Engine/Exact 并发到达（Exact 可先于 Engine 到达、
`withTaskGroup` 到达即发布，已核）。`exactQuery == nil` 的旧判据分不出"没查"与"在查"，会让早开的
Inspector 撒谎。逐 case：
```
context.exactQuery == .notStarted                       → 未尝试 exact 关系查询
context.exactQuery == .pending                          → exact 查询进行中（既非"未尝试"也非 not-corroborated；Inspector 显"verifying…"）
context.exactQuery == .completed(.completed(...))       → 当前 exact 结果未 corroborate（不构成否定）
context.exactQuery == .completed(.unsupported)          → provider 不支持该查询
context.exactQuery == .completed(.notApplicable)        → 不适用于该根
unavailable/readiness                                   → 走 VerificationAvailability，不进 query observation
```
候选侧同理：`candidateQuery == .pending` 时（Exact-first 到达）主列表可能暂空，不得据此判 not-corroborated。
`QueryExhaustiveness`：当前 rust-analyzer call hierarchy 固定 `.bestEffort`；只有完全无法描述 provider
合同的来源才 `.unknown`。只有 `.guaranteed` 才允许从"没返回 X"推负面结论（本轮无此 provider）。

### §3.5 两级完整性 + 命名（修正描述对象不清）
`CandidateObservation.completeness`=候选生成本身；`RelationSetObservation` 命名字段
**`candidateRelationSet`**、**只描述 fuzzy/source relation query 的完整性**，**不描述** exact 穷尽性 /
合并后 UI 总行数 / corrected 数量 / **500 行 UI cap（留 presentation 状态，不进 semantic observation）**。
`.partial` candidate **取消 Engine 前置**、改 synthetic 单测（前向兼容分支）。查询级信息归
`RelationQueryContext`（§3.0），行按 `contextID` 引用；`RelationQueryObservation.completed` 自带
`ExactOrigin`（attribution 无 origin，not-corroborated 审计需说明查询来自 worktree 还是物化 commit）。

### §3.6 `ExactAnalysisEnvironment` 正交化 + 去重（修正双 trustMode）
E1b0 把 `ExactAttribution` 的 `trustMode`+`coverage` **删除**，加 `environment: ExactAnalysisEnvironment`
（唯一 trustMode 来源）。`Set<ExactAnalysisLimitation>` 需 `Hashable`，**用户文案输出前排序**避免快照
不稳定。Trusted+offline、Safe+offline 均可表达。用户可见文案走诚实评审，旧状态行进迁移清单。

### §3.7 共享 target，availability 动态算（引用 §3.0）
`CandidateObservation` 持 `CandidateEndpoint`、`VerificationObservation` 持 `ExactTarget`（各自模块原生，
**都不持 `ObservedTarget`**）；`ObservedTarget` 仅在展示层把两者投影为一个 union。**`TargetAvailability`
由 presentation 层动态计算（`availability(of:)`）、不存 trace**（否则源码后来可读仍显旧 `notIndexed`）。
**明记 limitation**：unresolved external import 的 endpoint 只是"源文件 import binding"（§0），
scope 只能诚实标此，无法恢复外部实体。

### §3.8 call-site reconciliation：显式三分（修正集合差与 notComparable 冲突）
按 `exactQuery` 分组、每 call site 查一次；比较函数
`compare(candidate: ObservedTarget, exact: ExactTarget) -> TargetComparison{same/different/notComparable}`
`compare` **保守定义**（阻塞·小5）：`.same` = 两边可归一到同一 `SymbolOccurrenceID`、或同一 identity
domain 内 canonical location 完全相同；`.different` = 两边都成功归一到可比较的语义身份**且身份明确不同**；
**其余一切（含"原始 path/offset 不相等"）= `.notComparable`**——原始 path/offset 不等本身**不足以**产生
conflict（exact selection range 与 fuzzy declaration range 可能落在同一符号不同字节）。
**空 provider 目标是第一条规则（阻塞2：`[].allSatisfy` 返回 `true` 会把成功空查询误判成 conflict）**：
```
providerTargets.isEmpty → 无 corroboration 也无 conflict；全部 candidate 继续 Inferred；
                          记中性 notCorroboratedCandidate（"definition query completed with no target"）
否则逐 candidate 三分（不能用集合差，会把 notComparable 误吞进 corrected）：
  存在任一 same                       → corroborated
  无 same 且与所有 target 都 .different → correctedCandidate（进 corrected 组、conflict trace）
  无 same 但至少一个 .notComparable    → inconclusiveCandidate（保持 Inferred、不进 corrected、作 candidateOnly）
provider target：与任一 candidate same → matched（corroborated 复用）；否则 providerOnly（verification-only）
```
`CallSiteReconciliation.roles` 保存全部角色。**主 provider 行与 corrected 行都通过
`RelationRowExplanation.reconciliationRefs`（数组）持 ref（阻塞3）**——点主行 C 时 Inspector 能显示"C 修正了
A/B"；用数组因一条合并行可跨多个 call site（在此 call site corroborate、在彼处修正他者）。主列表：所有去重
provider targets；corrected 按 call site 聚合进**一个** `Show corrected candidates (N)` 组。**必补验收**：
① `completed([])` → 全部 candidate 仍 Inferred、不进 corrected、不生成 conflict clause；
② A=same/B=different/C=notComparable + 一个 provider target → A corroborated、B corrected、**C 继续 Inferred**、
主行仅一条且其 `reconciliationRefs` 指向本次 reconciliation。

### §3.9 conflict 规则固定（不由实验决定）
模型层**无条件记 conflict、永不 refuted**；provider 正向目标照常 `Verified by rust-analyzer`；Safe 环境
在 Inspector 明示 `buildScriptsDisabled`/`procMacrosDisabled`；limitation 影响"没看到什么"的解释、
不自动否定 provider 已明确返回的正向目标。E0 宏样本**只验诚实、不定设计**。

### §3.10 "主列表听 RA"是显示策略、`conflict` 名永久
分歧本质对称，`Verified` 只表示"经 rust-analyzer 验证"、从不表示"为真"；模型不出现 `refuted`；主列表
显示 RA 目标是渲染层具名 policy。

### §3.11 导航：事件与派生状态分离
```swift
struct NavigationRequest { let destination: SourceDestination; let cause: NavigationCause; let policy: NavigationPolicy; let explanation: NavigationExplanation? }
struct OutlineFollowArbitration { var suppressedBy: NavigationCause? }
```
执行 request 时按 `policy.blockViewportFollow` 置 `suppressedBy`；`didLiveScroll` 只清仲裁。

### §3.12 NavigationHistory 与 Trail 身份连接
`struct NavigationRecord { let jump: JumpRecord; let trailNodeID: TrailNodeID? }`——replay 时据此把
`activeNode` 移到既有 Trail node（仅 path/offset 不够，同位置可多次访问属不同路径）。

### §3.13 会话级解释存储消除悬空（修正查询级引用悬空 + live/materialized 彻底分开，阻塞4）
`LiveResolutionExplanation`（含 `contextID`/`ReconciliationRef`）依赖 `RelationQueryContext`；换根/关窗后
context 释放会悬空。裁决：**Store 只存 `MaterializedResolutionExplanation`（§3.0，禁含任何 ID/ref，
conflict 的 reconciliation 已内联进 `MaterializedResolutionTrace`——无独立字段、无两套数据不一致）**。
读取物化解释时**忽略 live trace 中的 ref**（Store 里根本没有 live 类型）。
**row → explanationID 回写（修正"更新哪一个"未定义）**：
```
用户首次从某行导航：物化 LiveResolutionExplanation → MaterializedResolutionExplanation → create 得
    explanationID → 回写进该行 Node / RelationRowExplanation
Exact 原位升级：Node 已持 explanationID → update 同一 ID（不换 id）
    → TrailEdge.observedAtNavigation 快照不变；currentExplanationID 读到新态
```
`TrailEdge` 存 `observedAtNavigation: ResolutionExplanationSnapshot`（物化、无 ID/ref）+
`currentExplanationID`。当前 Relations 仍用可变 `RelationQueryContext`。**清理规则**：
```
Relations 换根：清理未被 Trail 引用的 explanation
snapshot/profile 切换：保留仍被 TrailEdge 引用的，清理无引用旧结果
关闭项目：全清
```

### §3.14 worktree 恢复合同拆分
commit snapshot → 精确恢复同 commit；仍存活 snapshot → 精确恢复；**旧 worktree snapshot → 当前
worktree 上按 `JumpRecord` 弱锚点 best-effort 重放、UI 明示 "replayed against current worktree"**。
精确恢复旧 worktree 需保存捕获内容，范围扩大，本轮不做。

### §3.15 corrected candidate 交互合同
badge 仍 `Inferred` + `Conflict/Corrected` chip；不参与主关系计数；**单击只打开 Inspector**；
**双击不执行普通 relation navigation**；提供显式 "Open former candidate" 次级动作。

### §3.16 文案语言无关 clause + 英文 renderer；§3.17 readiness 不进 trace / 视觉门禁两层无 SSIM / 折叠组≤2
`narrativeClauses(for:context:)` 同吃 trace 与查询事实（两级完整性各成 clause）；禁用"证明/确定/唯一"。
`Show N possible matches` 之外只加 `Show corrected candidates (N)`，不加层级。

---

## §4 实现切片

### G0：语义红线、§3.0 类型模型与视觉语法成文
成文 §3.0 类型模型 + §3.3/3.6/3.9/3.10/3.14/3.15 入 `evidence/m10/semantics.md`；定
`TargetScope`/`TargetAvailability`/`ExactAnalysisLimitation`/`TargetComparison` 与三值 badge 规格；
裁决用户可见文案改名。**验收**：[x] 八项修正各有条目；改名文案有诚实结论、受影响状态行入迁移清单。**范围**：S。

### G1：视觉语义快照 + AX harness
①结构行为断言 ②视觉语义快照（先于 Inspector）；AX snapshot；PNG 只归档、无 SSIM。**依赖**：G0。**范围**：S–M。

### E0：歧义陷阱 fixture 与文案合同（不依赖 Engine `.partial`）
fixture = `methodNameOnly + possible + candidate.complete + candidateRelationSet.truncated`；门禁：绝不显
Verified、默认行 `name match only`、Inspector 显 "relation result set truncated"（非 candidate partial）、
文案无"解析到唯一目标"。`.partial` 分支改 synthetic 单测（E2）。宏样本 Safe/Trusted 各跑，**只验固定规则
诚实、是否需加 limitation clause**（§3.9，非阻塞）。导航任务：`A→B→C`、Back 到 B、`B→D` 分支、切一次
snapshot、**commit 节点精确恢复 / 旧 worktree 节点 best-effort 重放并明示**、replay 不产生重复 Trail 边。
**验收**：[x] fixture 与门禁落盘；宏诚实结论落盘。**依赖**：G0。**范围**：S–M。

### E1a：§3.0 类型分层落地
按 §3.0 落 Core/Exact/AppModel 类型。**验收**：[x] 编译无循环依赖；observation 各持模块原生 target；
`ObservedTarget` 仅展示层；`ResolutionExplanationSnapshot` 无 ID/ref。**依赖**：G0。**范围**：S–M。

### E1b：Exact definition case-specific 结果
`ExactLocation?`→`ExactDefinitionQueryResult`；`parseDefinition` 不再只取 `array.first`；Coordinator 输出
附 attribution/origin、过滤 stale、原样传 cancelled/unavailable；`.cancelled`/stale 不写 trace。**验收**：
[x] 多目标含 candidate 全保留；成功无结果≠unavailable≠cancelled；无 attribution 的 unavailable 可表达；
fake provider 断言各态。**依赖**：E1a。**范围**：M。

### E1b0：ExactAnalysisEnvironment 迁移
`ExactAttribution` 删 `trustMode`+`coverage`、加 `environment`（§3.6 唯一来源）；`onCoverageChange`→
`onEnvironmentChange`；`ExactCoordinator.coverage`→`analysisEnvironment`；CLI/Context/Relations 状态文案
迁移（Set 输出排序）；旧 coverage 测试进迁移清单。**验收**：[x] Trusted+offline/Safe+offline 可表达；
无双 trustMode；状态行诚实评审通过、旧断言逐条列旧/新/原因。**依赖**：E1b。**范围**：M。

### E1c：call-site reconciliation 与 conflict 修复
`promoteExactEdges` 改 call-site 分组；实现 `compare()` + 路径归一化 + **逐 candidate 三分**（§3.8）；
`CallSiteReconciliation`（含 `roles`）挂进 context、行 trace 用 `ReconciliationRef`；conflict 保留 RA 目标、
corrected 按 call site 聚合折叠。**验收**：[x] §3.8 三分用例（same/different/notComparable）全对——
notComparable **继续 Inferred 不进 corrected**；多 candidate 共享 call site 只发一次 definition；provider
多目标全不匹配全部去重显示 + candidates 进 corrected；conflict 不再压 `.unresolved`/丢位置。
**依赖**：E1b（**不依赖 E0**；E0 宏样本非阻塞）。**范围**：M。

### E1d：完整投影与旧状态保留
`mergeExact` fuzzy-only→`candidateOnly`（保持 Inferred、守 `RelationTreeModelTests.swift:251`；
corroborate 与否看 context.exactQuery，§3.4）、exact-only→`verificationOnly`、重合→`corroborated`；补齐
`LoadedEdge`/`Candidate` 缺字段（从 `ResolutionCandidate` 无损带出）；三合并点保留升级前 candidate 观察；
`alsoHeuristic` 删除、由 `corroborated` 派生。**验收**：[x] §0 三态合同全绿；升级前观察保留；
`alsoHeuristic` 删后等价。**依赖**：E1c。**范围**：M。

### E2：语言无关 clause + 英文 renderer
`NarrativeClause` + `narrativeClauses(for:context:)` + `renderEnglish(_:)`；不变式测 clause（两级完整性各成
clause、`.partial` 用 synthetic observation）；`name match only` 迁移用例带 completeness caveat；conflict
clause ≠ not-corroborated clause ≠ inconclusive clause。**验收**：[x] 不变式全绿；`receiverType+partial`
(synthetic) vs `+complete` 产不同 clause；视觉语义快照覆盖 renderer。**依赖**：E1d、G1。**范围**：S–M。

### E3：Resolution Inspector
badge 单击/快捷键/disclosure；三层渐进；`SOURCE`/`VERIFICATION` 两段（conflict 修正轨迹、not-corroborated
中性事实、inconclusive 中性）；复用 `evidenceLine`/tooltip/AX；`VerificationAvailability` 独立区显 readiness；
corrected 按 §3.15 交互。**验收**：[x] 陷阱 fixture 默认不显 Verified、Inspector 显结果集截断；conflict 主行
显 RA 目标 + 修正轨迹；corrected 双击不导航、不参与主计数；Relations 不退化深树、折叠组≤2；AX 不倒退。
**依赖**：E1d、E2、G1。**范围**：M。

### N1：NavigationRequest / Cause / Policy + 仲裁拆分 + explanation 引用
定 `SourceDestination`/`NavigationCause`/`NavigationPolicy`/`NavigationExplanation`（§3.0）；上两层入口收敛
带 `NavigationRequest`；拆 `OutlineFollowArbitration`（`didLiveScroll` 只清仲裁）；Reader 显示原语不变。
**验收**：[x] 各入口带正确 cause/policy/explanation；outline 抑制走仲裁；M9 `didLiveScroll` self-test 继续
通过；replay/tab activation 的 policy 正确。**依赖**：G0（弱依赖 E1a 的 explanation 类型）。**范围**：M。

### N2：Trail DAG + Explanation Store + worktree 合同
`ResolutionExplanationStore`（AppModel 会话级，§3.13）+ 清理规则；`ReadingTrail`/`TrailNode`/`TrailEdge`
（存 `observedAtNavigation` 物化快照 + `currentExplanationID`）；`NavigationRecord.trailNodeID`（§3.12）；
只记显式语义导航；Back 分支、点击恢复、切 snapshot 分段；worktree 恢复按 §3.14 拆合同；不做磁盘持久化、
不引入非文件 tab。UI 按 D4/D5 落为 32pt 常驻顶部 active-path breadcrumb + `⑂` / `⌥⌘T` 浮层 DAG；
浮层左侧复用三值 badge、snapshot chip 与 git-log gutter，右侧显示导航原因、冻结态 / 当前态和恢复动作。
**验收**：[x] E0 导航任务全对；Trail 数据无 UI 依赖；trace 升级后 Inspector 从 store 读最新态而路径条
快照不变；**换根后 conflict/candidate-only 解释仍可生成（不悬空）**；旧 worktree 恢复显示
"replayed against current worktree"；AppKit 几何 / AX / 三主题视觉与真实 tokio 分支恢复全 PASS。
**依赖**：N1、E1a。**范围**：M。

### P0：Reading Set 原型（不进产品，可提前）
两种原型（原地展开 / `Open as Reading Set` 新 tab），用固定 trace fixture。结论入
`evidence/m10/reading-set-prototype.md`，不进 `Sources/`。**依赖**：G0。**范围**：S。

### V0：任务式总验收
**自动化门禁**：
```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache" swift test --disable-sandbox
bash scripts/provision-corpora.sh --check
CODEX_SANDBOX=1 bash scripts/ci.sh
CODEX_SANDBOX=1 bash scripts/run-self-tests.sh <git-repo> <non-git-dir> <open-file>
CODEX_SANDBOX=1 bash scripts/stress-test.sh --runs 5 --load 8 --timeout 180
bash scripts/run-gold-gates.sh
```
**真实体验（tokio，CUA 执行）**：重跑 E0 两条阅读任务 + 一条陷阱任务，记录完成时间、错误导航次数、Back
次数、丢失位置次数、打开完整文件次数、能否说出每条关系依据、**有没有把一条误以为精确的推断当真**（盲测）。
**迁移清单门禁**：既有测试不得静默删/弱化；因已批准语义变更（Unresolved 入 badge、conflict 行为、
`ExactCoverage`→environment、`alsoHeuristic` 删除）改的断言，逐条列旧/新/原因。**边界审计**：[x] canonical
dump/`goldset/`/`RECORD` 零 diff；[x] `Prototypes/`/`.zcache/`/`Fixtures/` 未意外改、P0 不在 `Sources/`；
[x] real provider 受限单列 BLOCKED；[x] 交付 `m10-acceptance.md`：逐项 PASS/FAIL/BLOCKED + 迁移清单 +
CUA 主观结论。**依赖**：G0–N2。**范围**：S。

---

## §5 顺序与检查点

| 顺序 | 切片 | 子里程碑 | 原因 |
|---|---|---|---|
| 1 | G0 / G1 | 共享 | §3.0 类型模型 + 改名先成文；视觉语义快照层先于 Inspector |
| 2 | E0 | M10A | 陷阱 fixture（结果集截断，无 `.partial` 前置）+ 宏诚实样本 |
| 2 | N1 | M10B | 导航接口 + 仲裁拆分 + explanation 引用，与 E0 并行 |
| 3 | E1a→E1b→E1b0→E1c→E1d | M10A | 分层→definition→环境迁移→call-site 三分→完整投影；**M10A 重心** |
| 3 | N2 | M10B | Trail DAG + Explanation Store + worktree，弱依赖 E1a，与 E1 并行 |
| 4 | E2 | M10A | clause + 英文 renderer |
| 5 | E3 | M10A | Inspector |
| — | P0 | 探索 | 固定 fixture 提前做 |
| 6 | V0 | 总验收 | CUA 任务式 + 迁移清单 |

### Checkpoint A：G0 / G1 / E0 / N1 / E1a
- [x] §3.0 成文；视觉语义快照基线；陷阱 fixture（结果集截断）+ 宏诚实样本落盘；导航接口 + 仲裁拆分、
  M9 self-test 过；**E1a 编译无循环依赖**、`ResolutionExplanationSnapshot` 无 ID/ref。

### Checkpoint B：E1b / E1b0 / E1c / E1d / N2
- [x] definition case-specific（无 attribution 可表达、cancelled/stale 不写 trace）；环境迁移无双 trustMode；
  **call-site 三分（notComparable 中性）**、conflict 修复；fuzzy-only 仍 Inferred、升级前观察保留、
  `alsoHeuristic` 删除；Explanation Store 换根不悬空、worktree best-effort、history 身份连接。

### Checkpoint C：E2 / E3 / P0 / V0
- [x] 诚实不变式全绿（两级完整性、synthetic partial、inconclusive clause）；Inspector 渐进披露 + conflict
  修正轨迹 + corrected 交互；Relations 不退化深树；Reading Set 原型出裁决；CUA 任务式验收 + 迁移清单交账。

---

## §6 风险与对策

| 风险 | 对策 |
|---|---|
| 类型定义散落导致跨节矛盾（v1.1/v1.2 反复） | §3.0 单一定义源，后续裁决只引用；E1a 编译门当最终仲裁 |
| Core 持 AppModel 的 `ObservedTarget` 造循环依赖 | §3.0/§3.1：Core 只持 `CandidateEndpoint`；`ObservedTarget` 仅展示层、删重复的 `ResolutionEndpoint` |
| conflict/candidate-only 依赖查询级 context，换根悬空 | §3.13 会话级 `ResolutionExplanationStore` + 导航物化快照；清理规则写死 |
| 集合差把 `.notComparable` 误判为 corrected/conflict | §3.8 逐 candidate 三分 + `inconclusiveCandidate` 保持 Inferred；补三分验收用例 |
| not-corroborated 用"非 nil"判据漏掉 unsupported/notApplicable | §3.4 逐 case 映射；`QueryExhaustiveness` 定 RA=`.bestEffort` |
| `ExactAttribution` 双 trustMode | §3.6/E1b0 删旧 trustMode+coverage、`environment` 唯一来源；Set Hashable + 输出排序 |
| `RelationSetObservation` 描述对象不清 | §3.5 命名 `candidateRelationSet`、只描述 fuzzy/source 查询；500 cap 留 presentation；completed 带 origin |
| `ResolutionTraceSnapshot` 含外部引用不成快照 | §3.0 `ResolutionExplanationSnapshot` 禁含任何 ID/ref、物化 conflict 集合 |
| definition 失败态无 attribution 表达不了 | §3.2 case-specific；unavailable attribution 可选；cancelled/stale 不写 trace |
| Safe 压制 conflict = 静默推断 | §3.9 无条件记 conflict、永不 refuted、Safe 限制 Inspector 明示；E0 只验诚实 |
| 旧 worktree 无法精确恢复 | §3.14 拆合同：commit 精确 / 旧 worktree best-effort + UI 明示 |
| 用户从已冲突 corrected 候选继续导航 | §3.15 Inspector-only 单击、双击不导航、"Open former candidate" |
| "既有测试零改动"与语义变更矛盾 | V0 迁移清单门禁：不得静默删弱、逐条列旧/新/原因 |
| E1 超 5 文件；范围/散文/harness 蔓延 | 拆 E1a–E1d；§2 顺延清单；§3.16 clause 不变式；§3.17 两层无 SSIM |

**开工前阻塞：已由 v1.1(9) + v1.2(11) + v1.3(8) + v1.3.1(4 阻塞 + 5 小) 修正全部解除。** 无前置任务
依赖。默认按 §5 执行，M10A / M10B 并行；每片开工前只读该片关联代码与验收合同。**分工边界**：纯类型层
（循环依赖、conformance、snapshot 无 ref）交 E1a 的编译器当最终仲裁——冲突以编译器为准并回修 §3.0；
而语义/并发合同（not-corroborated 状态机、空目标中性、notComparable 保守、conflict 修正轨迹、Store 无
live ref）是编译器抓不到的，已在 §3 定死，实现须带回归测试而非依赖编译通过。
