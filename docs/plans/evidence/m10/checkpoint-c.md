# M10 Checkpoint C 验收证据

日期：2026-08-07。范围：E2 已完成；E3 / P0 / V0 待后续阶段补齐。

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
