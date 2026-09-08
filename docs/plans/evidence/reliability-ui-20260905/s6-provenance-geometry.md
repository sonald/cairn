# S6 — 来源说明和 toolbar 不撑窗：逐片记录

## RED（2026-09-08）

`contextHeaderLongProvenanceStaysShortAndDoesNotWidenTheWindow`（`MainWindowControllerTests.swift`，真实引擎会话 + `ContextExactBadgeGate` 延迟升级 + 900pt 固定窗口），先于实现运行，3 处失败完整复现审查现象：

- 徽标 237 字符（`Exact·direct · extremely-long-provider… · Safe · limitations: … · features: default`）整条进入头部。
- 无 tooltip/AX 承载完整来源。
- 超长 Exact 文本发布后 **NSWindow frame 实际改变**（审查截图 900→1244 的单约束根因确认：`candidateLabel` 水平压缩阻力为默认 750，且单元格允许换行，头排水平 NSStackView 两端固定时把需求上传给窗口）。

测试装配自身的一处缺陷（controller.view 未关 TAMIC 导致窗口塌缩 0×32）已修正，不影响产品结论。

## 实现（§3.2 + D1）

`ContextWindowViewController`：

- 显示层短标签 `shortProvenanceLabel`：保留 certainty·dispatch（Exact/Strong/Possible/Unresolved 区分不丢）与绑定种类；provider/toolVersion/trust/limitations/commit/features 全部移入既有 tooltip + AX label。**模型 `provenanceBadge` 数据不变**（D1：语义判断与既有徽标断言不受影响）。
- `candidateLabel`：压缩阻力/hugging 降为 defaultLow、cell 不换行 + 尾截断——长来源只能截断，不能要求窗格宽度。

Toolbar（审查"900pt 长项目名下 Symbols 进 overflow"根因：Symbols 优先级 .standard 低于 Project/Commit/Profile 的 .high，且 profileButton 固定 240pt 宽）：

- Symbols → .high；Project/Commit → .low（项目名/版本说明先压缩，menuFormRepresentation 保留菜单可达性）；Profile → .standard 且 240 固定宽改为 ≤180 有界 + 尾截断（完整标题在菜单表示中）；Settings 维持 .low。

## GREEN

- `contextHeaderLongProvenance…`：徽标 ≤40（实测 `Exact·direct`）、tooltip 含完整 provider 串、窗口 frame 不变、内容 fitting ≤900。✅
- `toolbarKeepsSymbolsVisibleAheadOfSecondaryChrome`：优先级合同锁定。✅
- UI 批（Relation/ContextMenu/MainWindowController/NonSource/Palette/ProvenanceBadgeStyle，隔离跳过）：86 通过——既有徽标数据断言（materialized、features、fake-exact 等）全部不倒退。
- `ExactCoordinatorTests|AppModelTests`：335 通过。
- `scripts/ci.sh` 881→883。

## 验收对照（计划 §5 S6）

1. 900pt 固定窗短 fuzzy → 超长 Exact 前后 NSWindow frame 不变（±0.5pt），无约束需求外溢。✅（1000/1280/1440 与三主题的完整矩阵留 V0 步骤 9——同一约束合同驱动，四宽度复测在验收记录中补）
2. 路径含文件名与行号（pathLabel 截断中段既有行为）；完整来源经 tooltip/AX 可读；Verified/Inferred/Unresolved 区别保留。✅
3. 长项目名/长版本下 Symbols 优先级合同成立；Profile 文字不再整条染色或撑宽。✅（真实 900pt 视觉确认留 V0 步骤 9）
