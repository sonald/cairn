# M10 语义与视觉规格（G0 产出 · 实现单一参照）

> **状态**：G0 文档收口（2026-08-06）。冻结自 [`m10-plan.md`](../../m10-plan.md) v1.3.1 + 原型决策
> D1–D6（[`prototype-decisions.md`](prototype-decisions.md)）。E1a/E1b/E1b0/E1c/E1d/E2/E3/N1/N2
> 实现按此执行；语义细节以计划 §3.x 为准，本文补齐视觉规格与原型定稿，并索引红线。
>
> **单一定义源纪律**：类型只在计划 §3.0 定义一次；本文引用不重定义。若 prose 与 E1a 编译器
> 冲突，以编译器为准并回修 §3.0（纯类型层）；语义/并发合同（本文第 2 节）编译器抓不到，
> 实现须带回归测试。

---

## 1. 类型模型（引用计划 §3.0）

按模块分层，见 [`m10-plan.md` §3.0](../../m10-plan.md)。要点复述（防实现误放位置）：

- **Core**：`SourceLocation`、`CandidateEndpoint{occurrence(SymbolOccurrenceID) | unresolved(UnresolvedSymbolRef)}`（**无 exactLocation**）、`CandidateObservation`（持 `CandidateEndpoint`，**绝不持 ObservedTarget/ExactTarget**）。`UnresolvedSymbolRef` 复用 `ScopeModel.swift` 既有类型。
- **Exact**：`ExactTarget{location: ExactLocation}`、`ExactDefinitionQueryResult{completed([ExactTarget]) | cancelled | unavailable(String)}`、`ExactAnalysisEnvironment{trustMode; limitations: Set<ExactAnalysisLimitation>}`（**不加 Hashable**，TrustMode 只 Sendable）、`ExactAnalysisLimitation: Hashable{buildScriptsDisabled | procMacrosDisabled | dependenciesUnavailableOffline}`、`QueryExhaustiveness{guaranteed | bestEffort | unknown}`（RA call hierarchy 固定 `.bestEffort`）。
- **AppModel**：`ObservedTarget{candidate | verification}`（**唯一 target union，展示层投影**，无 `ResolutionEndpoint`）、`VerificationObservation{target: ExactTarget; attribution; origin}`、`RelationQueryObservation{completed(attribution, origin, exhaustiveness) | unsupported | notApplicable}`、`RelationSetObservation{completeness; returnedCount; totalCount?}`（字段命名 `returnedCount`，**不是** 500 UI cap）、`ReconciliationRole: Hashable{corroborated | correctedCandidate | inconclusiveCandidate | notCorroboratedCandidate | providerOnly}`、`CallSiteReconciliation{…; roles: [ReconciliationRole]}`、`ReconciliationRef: Hashable`、`ResolutionTrace{candidateOnly | verificationOnly | corroborated | conflict(reconciliation: ReconciliationRef)}`（**live 模型**）、`RelationQueryContext{candidateQuery; exactQuery; reconciliations}`（**查询级、可变、状态机**）、`RelationRowExplanation{primaryTrace; contextID; reconciliationRefs: [ReconciliationRef]}`。
- **会话级持久（Store 禁含 live ref）**：`LiveResolutionExplanation`（可含 ref）→ 导航时物化为 `MaterializedResolutionExplanation{trace: MaterializedResolutionTrace; relationFacts?}`（无任何 ID/ref，conflict 的 reconciliation 内联进 trace）；`ResolutionExplanationSnapshot`；`@MainActor ResolutionExplanationStore`（AppModel 会话级）；`NavigationExplanation{explanationID; observedAtNavigation}`。

两个 owner：`RelationQueryContext`（查询级、随 Relations 根存亡）+ `ResolutionExplanationStore`（会话级、Trail 引用之）。无第三个并行存储。

---

## 2. 语义红线（不可撒谎，编译器抓不到，实现须带回归测试）

| # | 红线 | 计划 § |
|---|---|---|
| R1 | **conflict ≠ not-corroborated**：Exact 返回*另一个*目标=冲突（修正主结果+留审计）；Exact 结果集*没出现*候选=仅未 corroborate（继续 Inferred，不降级/删除/标否定）。 | §3.3 |
| R2 | **not-corroborated 逐 case**：`exactQuery == .notStarted`→未查；`.pending`→进行中（既非未查也非未corroborate，显 verifying…）；`.completed(.completed)`→未corroborate（不构成否定）；`.completed(.unsupported/.notApplicable)`→各自陈述；unavailable/readiness→走 VerificationAvailability，不进 query observation。`candidateQuery == .pending`（Exact-first 到达）主列表暂空时不得判 not-corroborated。 | §3.4 |
| R3 | **call-site 三分（不能用集合差）**：`providerTargets.isEmpty`=第一条规则→全部候选保持 Inferred、记中性 `notCorroboratedCandidate`（`[].allSatisfy` 返回 true 会误判成 conflict）。否则逐 candidate：有 `.same`→corroborated；无 same 且全 `.different`→correctedCandidate；无 same 但有 `.notComparable`→`inconclusiveCandidate`（**保持 Inferred、不进 corrected**）。 | §3.8 |
| R4 | **TargetComparison 保守**：`.same`=可归一到同一 `SymbolOccurrenceID` 或同 identity domain 内 canonical location 完全相同；`.different`=两边都成功归一到可比较身份*且明确不同*；**其余（含原始 path/offset 不等）=`.notComparable`**。路径归一化按 `ExactCoordinator.swift:14` 合同（项目内相对、依赖绝对）。 | §3.8 |
| R5 | **conflict 规则固定**：模型无条件记 conflict、**永不 refuted**；provider 正向目标照常 `Verified by rust-analyzer`；Safe 限制在 Inspector 明示、**不否定** provider 已返回的正向目标。「主列表听 RA」是渲染层具名 policy，不从模型推导；`Verified` 只表示「经 rust-analyzer 验证」、从不表示「为真」。 | §3.9/§3.10 |
| R6 | **文案受多字段约束**：解释 clause 是 `evidence × certainty × candidate completeness × relation-set completeness × verification coverage × targetScope` 的函数；partial/truncated/unknown/nameOnly/依赖离线 **必须显式改变句子**；禁用「证明/确定/收敛到唯一目标」，用「支持这个候选」。不变式测 clause 不测英文子串。 | §3.5/§3.16 |
| R7 | **冻结 vs 当前**：`TrailEdge` 存 `observedAtNavigation`（物化快照、无 ID/ref）+ `currentExplanationID`（读 store 最新态）；exact 原位升级 update 同一 ID（不换 id），快照不变、当前态更新。Store 只存物化数据。 | §3.13 |
| R8 | **worktree 恢复拆合同**：commit 节点=精确恢复同 commit；仍存活 snapshot=精确；**旧 worktree=best-effort 重放 + UI 明示 "replayed against current worktree"**。 | §3.14 |
| R9 | **`.cancelled`/stale 不写 trace**（控制流不是语义观察）；无 session 失败无 attribution（case-specific 表达、不强制非可选）。 | §3.2 |

---

## 3. 视觉规格（原型定稿，色值复用 M9 S6 token）

原型：[01 Inspector+badge](resolution-inspector-prototype.html) / [02 Trail](semantic-trail-prototype.html) / [02b 放置对比](trail-placement-options.html) / [03 Reading Set](reading-set-prototype.html)。

### 3.1 三值 Evidence Badge（D1）— 同一 badge 通道
| 状态 | 样式 | token |
|---|---|---|
| Verified | 绿实心药丸 | `--grn` / `--grnbg`（复用 M9） |
| Inferred | 蓝实心药丸 | `--blu` / `--blubg`（复用 M9） |
| Unresolved | **中性描边药丸**（权重最弱，仍占同一列）(D1) | `--neu` + `1px solid --neubd` |

**新增 token（三主题）**——Unresolved 中性 + conflict 告警：

| 主题 | `--neu` | `--neubd` | `--warn` | `--warnbg` | `--warnbd` |
|---|---|---|---|---|---|
| Light | `#57606A` | `#C4CAD1` | `#B54708` | `rgba(181,71,8,.10)` | `#EAAA7A` |
| Dark | `#AAB1B8` | `#4A4E54` | `#F0A868` | `rgba(240,168,104,.15)` | `#6B5334` |
| SI Classic | `#6E6857` | `#C4B79A` | `#8A5A2E` | `rgba(138,90,46,.12)` | `#C7A574` |

其余色（chrome/content/divider/sel/accent/grn/blu/occ 等）**沿用 M9 S6 已上线值不变**（`ReaderSettings.swift`）。view 层无裸 RGB。

### 3.2 次级维度 chip（正交于 epistemic，低权重）
- **TargetScope**：`dependency` 等 = 虚线 chip（`--sec` 文字 + `1px dashed --neubd`）。external import 只诚实标「import binding」，不谎称已知外部实体（§3.7）。
- **caveat**：`name match only` 等 = `--warn` 系告警 chip。
- **corrected / conflict**：`--warn` 系 chip。

### 3.3 Resolution Inspector（E3）
- **渐进披露三层**：行级 badge → 一句「why」clause → `Show full audit`（resolver/certainty/dispatch/evidence/coverage/snapshot/profile）。默认不倒全部枚举。
- **SOURCE / VERIFICATION 两段**：corroborated 两段都在；verification-only 只下段；conflict 下段变 `VERIFICATION CONFLICT`。
- **corrected candidate 交互（D2/§3.15）**：badge 仍 `Inferred` + `Conflict/Corrected` chip；不参与主关系计数；**单击只开 Inspector、双击不做普通导航**；显式「Open former candidate」次级动作。
- **主 provider 行**（如 `Future::poll`）经 `reconciliationRefs` 自带修正轨迹（「replaced Task::poll」）；被修正候选折进 **列表尾** 的 `Show corrected candidates (N)`（D2）。折叠组最多两个（另一个是 `Show N possible matches`），不加层级。
- **环境限制**：Safe 的 `buildScriptsDisabled`/`procMacrosDisabled` 作 limitation 明示（不否定正向目标，R5）。

### 3.4 Semantic Trail（N2）— A + C 组合（D4/D5）
- **A 顶部路径条**（常驻、几乎零空间）：显 active path breadcrumb（cause 标注边）。**分叉不在 A 处理**——A 上 `⑂` chip 仅唤出 C（D5）。
- **C 浮层**（⌘-键唤出、Esc 关闭）：整棵分叉 DAG（git-log 式缩进 + gutter 连线，D3）；节点复用三值 badge；snapshot 分段线；commit/worktree chip；节点详情含 R7 的「冻结 vs 当前」两卡片。
- **放弃 B 常驻侧面板**（与「不再增加固定工具表面」冲突）。
- 只记显式语义导航（`policy.recordInTrail`）；滚动/outline 自动跟随/tab 切换不进。`NavigationRecord.trailNodeID` 连接 history 与 Trail（§3.12）。

### 3.5 Reading Set（P0 结论 D6）— 不进 M10
- **B（Reading Set tab）为目标形态，属 M11**：`File Tab | Reading Set Tab` 并列，满宽连续 excerpt 流，每段带出处头（role + path:line + Verified/Inferred badge + commit chip + 「打开完整文件/扩大上下文/查看证据」，「查看证据」开 Inspector）。需「非文件文档」原语，与 Trail 浮层 C 的「Open as Reading Set」共用、M11 一次引入。
- **A 行内 peek** 作为 Relations 的轻量补充另算，非连续阅读材料。

---

## 4. 用户可见文案改名（§3.6，走诚实评审 — G0 实现时定稿）

`ExactCoverage`（现 rawValue 已面向用户：`ContextWindowModel.swift:652`、`CodeInsightCLI.swift:112`）→ 正交化为 `ExactAnalysisEnvironment{trustMode, limitations}`。

- **类型改名免费**；**case/文案属用户可见文本**，最终措辞走与 narrative clause 同一套诚实评审，G0 实现时对代码定稿。
- **待补迁移清单**（需对代码逐条列旧/新/原因）：受影响的状态行与断言至少含 `RelationTreeModelTests.swift:664`（`Verified unavailable: deps unavailable (offline)`）、`MainWindowController.swift:1590`、`RelationTreeModel.swift:925`。E1b0 迁移 `onCoverageChange`→`onEnvironmentChange` observer 链。
- `alsoHeuristic` 删除、由 `corroborated` 派生；Unresolved 从 modifier 移入 badge 通道——均为**已批准语义变更**，进 V0 迁移清单（不追求「测试零改动」）。

---

## 5. 原型决策索引

| # | 决策 | 状态 |
|---|---|---|
| D1 | Unresolved = 中性描边 | ✓ 定 |
| D2 | corrected 折叠组置列表尾 | ✓ 定 |
| D3 | Trail 分支 = git-log 式缩进+gutter | ✓ 定 |
| D4 | Trail 放置 = A 顶部条 + C 浮层组合（弃 B） | ✓ 定 |
| D5 | 分叉一律交给 C 浮层（A 仅唤出） | ✓ 定 |
| D6 | Reading Set = B 目标形态、属 M11、不进 M10 | ✓ 定（用户 2026-08-06 确认） |

---

## 6. G0 剩余（进入实现时完成，非本文档能定）

- [ ] `ExactCoverage`→`ExactAnalysisEnvironment` 用户可见 case 文案的最终措辞（诚实评审）。
- [ ] 完整迁移清单：对代码枚举所有受改名/语义变更影响的测试与状态行，逐条列旧/新/原因。
- [ ] `TargetScope`/`TargetAvailability`/`TargetComparison` 的完整 case 与 `availability(of:)` 计算契约落到代码 doc-comment。

以上三项需对 HEAD 代码逐一核，属 G0 实现动作；本规格文档为其提供裁决依据与视觉/语义合同。
