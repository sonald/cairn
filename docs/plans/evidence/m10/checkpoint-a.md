# M10 Checkpoint A 验收证据

日期：2026-08-07。范围：G0 / G1 / E0 / N1 / E1a。

## G0 / E1a

- §3.0 类型按 `Core ← Exact ← AppModel` 落位；Core observation 只持 `CandidateEndpoint`，Exact observation 只持 `ExactTarget`，`ObservedTarget` 仅在 AppModel。
- live trace 与 materialized trace 分型；`ResolutionExplanationSnapshot` 只含 materialized explanation 与时间，不含 context/reconciliation ID 或 ref。
- 九条不可撒谎红线见 `semantics.md` R1–R9；其中 v1.3.1 的 Exact-first、空目标中性、主行 reconciliation refs、Store 禁 live ref 均有独立条目。

## G1 视觉语义快照

结构门禁：三值均占同一个 badge 通道；Verified/Inferred 为实心，Unresolved 为 1 pt 中性描边。行仍为一层；折叠组上限不变。PNG 只作人工归档，不使用 SSIM 判定。

| Theme | Unresolved text | border | warning text | warning border | warning fill |
|---|---:|---:|---:|---:|---:|
| Light | `57606A` | `C4CAD1` | `B54708` | `EAAA7A` | `0.10` |
| Dark | `AAB1B8` | `4A4E54` | `F0A868` | `6B5334` | `0.15` |
| SI Classic | `6E6857` | `C4B79A` | `8A5A2E` | `C7A574` | `0.12` |

AX snapshot 门禁沿用 Relations 原生 cell：`label=<row title>`；`value=<subtitle>, <Verified|Inferred|Unresolved>`；tooltip 分别说明 rust-analyzer/source structure/unresolved source target；role 非 editable text field，value 不可写。

## E0 歧义陷阱

固定 synthetic fixture：`methodNameOnly + possible + candidate.complete（当前 resolver 合同） + candidateRelationSet.truncated`。

- 候选 badge 必须为 `Inferred`，行 caveat 为 `name match only`。
- 查询级截断单独显示 `Results truncated upstream`，不得伪装成 candidate `.partial`。
- 候选 badge 集合不得出现 `Verified`；可用性状态行 `Verified unavailable: ...` 是另一维度，不受此门禁误伤。
- 表面文案不得出现 `unique target`。

宏样本只检查固定诚实规则：Safe/Trusted 都不因环境模式压制 provider 已返回的正向目标；Safe 必须另列 build-script/proc-macro limitation；没有返回目标不构成否定。2026-08-07 的 fake Safe→Trusted→Safe 生命周期 PASS，只证明状态/文案 instrumentation；真实 rust-analyzer Safe 与 offline 变体均 **BLOCKED**：`sandbox-exec: sandbox_apply: Operation not permitted`，未把 fake 结果冒充真实宏分析。

## N1

- 上层导航统一进入 `NavigationRequest(destination, cause, policy, explanation)`；relation/outline/search/history/tab activation 各有 cause。
- `OutlineFollowArbitration` 只保存 `suppressedBy`；request 按 policy 置仲裁，`didLiveScroll` 只清仲裁。
- history replay 使用 `.replay`，不重复写 Trail；tab activation 使用 `.passive`。

## 自动验证入口

- `navigationRequestKeepsCausePolicyAndReplaySemantics`
- `outlineFollowArbitrationClearsOnlyOnLiveScroll`
- `m10AmbiguityTrapKeepsNameOnlyTruncatedCandidateInferred`
- `readerThemeProvidesChromeSurfacesForEveryExplicitTheme`
- `RelationUXTests.relationReferenceRowsExposeProvenanceThroughAccessibility`
- `--self-test-reading` 中 `didLiveScrollResumesViewportFollow`

本阶段实跑：上述 5 个 Swift Testing 门禁 PASS；`scripts/run-self-tests.sh` 12/12 PASS，reading JSON 的 `programmaticNavigationBlocksViewportFollow=true`、`didLiveScrollResumesViewportFollow=true`。real provider 限制按上节 BLOCKED 单列。
