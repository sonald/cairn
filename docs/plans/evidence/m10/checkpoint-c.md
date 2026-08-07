# M10 Checkpoint C 验收证据

日期：2026-08-07。范围：E2 / E3 / P0 已完成；V0 待总验收补齐。

## E2 语言无关 clause 与英文 renderer

- `NarrativeClause` 分离候选证据、候选生成完整性、source relation 结果集完整性和 exact 查询事实；verification-only 不生成 SOURCE clause。
- `candidate.partial` 使用 synthetic observation 覆盖，不依赖 Engine 当前是否产出 partial。
- `conflict`、`notCorroborated`、`inconclusive` 是三个独立 clause，英文输出互不混同，也不使用“证明 / 确定 / 唯一”式断言。
- `methodNameOnly + candidate.complete + candidateRelationSet.truncated` 视觉语义快照固定为 `name match only`、候选生成完整、关系结果集截断、exact verifying 四条独立文案。

## 自动验证

- `m10NarrativeKeepsBothCompletenessLevelsIndependent`
- `m10NarrativeDistinguishesConflictNonCorroborationAndInconclusive`
- `m10NarrativeEnglishSnapshotKeepsNameOnlyCompletenessCaveat`
- `swift test --disable-sandbox`：430 / 430 PASS。
- `scripts/run-self-tests.sh`：12 / 12 PASS；artifact `.build/self-test-run-20260807-111748-4744`。
- `git diff --check`：PASS；CanonicalDump / gold / RECORD / Prototypes / Rust fixtures：零差异。

## E3 Resolution Inspector

- 原生 AppKit Relations pane 内按原型实现左列表 / 右 Inspector 等宽分栏；未引入 SwiftUI bridge 或第二套状态源。
- 渐进披露固定为行级三值 badge → 一句 why → `Show full audit`；Inspector 将 `SOURCE` 与 `VERIFICATION` 分段，conflict 使用 `VERIFICATION CONFLICT`。
- `VerificationAvailability` 单独显示 provider readiness；Safe / Trusted 与 limitations 放在独立 `ANALYSIS ENVIRONMENT` 区，不用环境限制否定 provider 正向目标。
- badge 点击只选中并打开 Inspector；⌘I 重开当前选择。corrected 单击 / 双击均不导航，只有 `Open former candidate` 执行次级跳转。
- provider 主行显示 `corrected N` chip 和被替换候选标题；corrected 仍在列表尾单一 disclosure，Possible + Corrected 同层折叠组上限为 2。
- Unresolved 迁入与 Verified / Inferred 相同 badge 通道，移除重复的 `Unresolved` subtitle；dependency scope 使用虚线 chip，name-only / corrected 使用 warning chip。

## E3 视觉与交互证据

- 三主题 AppKit PNG（只人工审计，不做 SSIM）：`resolution-inspector-light.png`、`resolution-inspector-dark.png`、`resolution-inspector-si-classic.png`；均为 1600×1000。
- 人工视觉审计修复了两处首轮不合规：非 flipped 文档导致内容落底、分栏在最终宽度前定位导致 2:1；最终截图为内容顶部对齐、列表 / Inspector 等宽、badge pill 不拉伸。
- `resolutionInspectorMatchesProgressiveDisclosureAndAX`：结构、可见几何、不重叠、三层 disclosure、SOURCE / VERIFICATION、readiness、environment、AX role/value/read-only、badge/⌘I 全 PASS。
- `correctedCandidateOnlyNavigatesThroughExplicitInspectorAction`：主行修正轨迹、corrected 单击/双击不导航、显式次级动作、折叠组≤2 全 PASS。
- `ambiguityTrapInspectorSeparatesCandidateAndResultSetCompleteness`：默认 Inferred + `name match only`；candidate complete、relation set truncated、verifying 三事实并存，无 `unique target`。
- `swift test --disable-sandbox`：433 / 433 PASS；`scripts/run-self-tests.sh`：12 / 12 PASS，artifact `.build/self-test-run-20260807-114052-42772`。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；真实 rust-analyzer Safe / offline 仍因 `sandbox-exec: sandbox_apply: Operation not permitted` 为 BLOCKED，未以 fake 结果替代。

## P0 Reading Set 原型

- 固定 tokio `spawn` trace 对比 A（Relations 原地展开）与 B（`Open as Reading Set` 新 tab），证据内容不随布局变化。
- 选择 B 作为 M11 目标形态；A 只作为独立轻量 peek，不替代 Reading Set。
- 结论记录于 `reading-set-prototype.md`；P0 未增加 Reading Set 产品实体或修改 `Sources/`。
