# S7b — Reader 优先与 Inspector 收敛：逐片记录

## 既有缺陷复现（RED 依据）

以探针测试在上一提交（S7a 后）干净源码上复现：900pt 固定窗口从 Reader 打开 Relations，**NSWindow frame 实际从 900 撑到 1401**——违反 §3.1「不通过自动增大窗口满足约束」。逐步定位：

1. 仅 `relationItem.isCollapsed = false`（恢复面板自然宽 560）即在同步布局内撑大窗口；约束钉（优先级 253）对 NSSplitView 的 frame 管理无效；`setPosition(ofDividerAt:)` 在 sidebar 收起后索引失配被忽略（该索引缺陷同时解释了 relations preset 的 0.28 比例从未生效的历史现象）。
2. `applyPanelLayout` 的延迟 async `applyPanelSizes` 会把适配已收起的面板重新撑开。
3. 有效的杠杆是 `NSSplitViewItem.maximumThickness`（split view 自身强制）。

## 实现（`MainWindowController.swift` + `RelationWindowController.swift`）

- `openRelationsPane()`：打开前按 §3.1 折叠 sidebar（reader 会跌破 480 时）、以适配宽度**预先钳制** `maximumThickness` 再 uncollapse，窗口 frame 护栏兜底（瞬时需求撑大后立即还原）。`handleReaderRelation`/`showRelations(target:)`/`toggleRelations` 全部改走该入口。
- `updateRelationsWidthAdaptation()`（render + windowDidResize）：无状态判定——面板自然宽 560 无法与 reader 480 地板共存时钳制到 `available − sidebar − 480 − divider`；能共存时释放。阈值天然分离，宽度来回跨阈值不振荡。
- 迟到的 preset `applyPanelSizes` 不再重新展开已被适配收起的面板（`!item.isCollapsed` 守卫）。
- 厚度合同：Relations 面板 min 300（原 220）；Compare 双列 min 320（原 300）；Reader 480 地板由适配强制而非硬约束（硬最小会与并列面板的必需最小冲突→撑窗）。
- Inspector：`updateInspectorLayoutMode()`（viewDidLayout + show/refresh/hide 显式调用）——右区 < list 280 + inspector 300 + 间距时 Inspector **替换**列表（既有右区域，不引入新窗口/navigation store）；Close 经既有 onClose 恢复列表，选中与滚动不丢。迟滞（进入 604 / 退出 628）防振荡。

## 测试（新增 2，`RelationNavigationTests.swift`）

- `openingRelationsKeepsTheWindowAndReaderReadableAtTheFloor`：900pt 下窗口不变、sidebar 折叠、Reader ≥480、右区 ≥300；关闭 Relations 恢复用户 sidebar 选择。
- `inspectorReplacesTheListInNarrowRightAreaAndRestoresIt`：窄右区 Inspector 替换列表；Close 恢复同一结果（根/代数/选中不变，无查询重建）。

## GREEN

- 2 新测试通过（探针在修复前失败：900→1401）。
- UI 批（Relation/ContextMenu/MainWindowController/NonSource/Palette/ProvenanceBadgeStyle，隔离跳过）：90 通过。
- `AppModelTests|SnapshotSwitchTests|SessionRestoreTests`：335 通过。
- 产品自测（debug 构建）：全部通过（无项目面板退场检查随 §3.1 更新：`sidebarRetiredWithoutProject`、`emptyStateCarriesOpenProjectWithoutProject`、`relationsRetiredWithoutRoot` 替代旧占位可见断言）。
- `scripts/ci.sh` 885→887。

## 验收对照（计划 §5 S7b）

- 窄窗 Reader≥480、独立右区≥300：测试断言。✅
- Inspector 文本无逐词窄列：替换模式下占满右区（≥300）。✅
- 宽度来回跨阈值不振荡、不重建查询：钳制阈值进入/释放分离；Inspector 迟滞；generation/根不变断言。✅
- Compare 双列/Focus 不破坏：min 320 各列；未触碰 focus 路径（既有测试维持）。✅
- 鼠标/键盘打开、关闭 Inspector 均回到同一关系结果：单一 hide/show 路径 + 状态保留断言。✅
- 1000/1280/1440 宽度矩阵与三主题视觉复核留 V0 步骤 9（同一钳制公式驱动）。
