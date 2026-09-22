# Reader wrap v2 · S2a 首视觉行与跨行命中

- 日期：2026-09-22；基于 S1 `c1a3e4d`。
- gutter 使用 fragment 首视觉行几何；行号独立按字体高度居中，标记与 diff 条限于首视觉行。
- fold hover 按 FoldID 保存，与 click 共用首视觉行半开区间命中。
- 当前查找命中通过 TextKit 2 segment 枚举绘制全部可见片段。

## 验证

本次定向复跑通过 5 项（两个 target 的完成摘要分别为 1、4 项），日志见 `s2a-checks/focused-tests.log`：

| ID | 测试 | 结果 |
| --- | --- | --- |
| W20 | wrapGutterDecorationsOccurOnceOnTheFirstVisualRow | PASS |
| W21 | wrapFirstRowScrolledOutLeavesContinuationRowsUndecorated | PASS |
| W22 | wrapFoldHandleHitTestingUsesOnlyTheFirstVisualRow | PASS |
| W23 | wrapPrimarySelectionCoversAllVisibleRowSegments | PASS |
| 回归 | foldGutterHoverIdentifiesTheHoveredFoldRow | PASS |

W21 已将原宽松条件收紧为：首行滚出后，该逻辑行无 gutter 绘制记录且不在可见行号中。测试通过 bitmap cache 触发真实离屏绘制；这不替代真实窗口交互验收。W20 尚未穷举所有标记组合，W22 的 Option-click 与边界交互仍需整体验收补齐。

复跑命令（先将两个 module-cache 环境变量设置到 `.build/module-cache`）：

```sh
swift test --disable-sandbox --no-parallel --filter 'wrapGutterDecorationsOccurOnceOnTheFirstVisualRow|wrapFirstRowScrolledOutLeavesContinuationRowsUndecorated|wrapFoldHandleHitTestingUsesOnlyTheFirstVisualRow|wrapPrimarySelectionCoversAllVisibleRowSegments|foldGutterHoverIdentifiesTheHoveredFoldRow'
bash scripts/gen-wrap-fixtures.sh --verify
git diff --check
```

fixture 5 项哈希验证与 diff whitespace 检查均 PASS。交接记录报告主批 991 项通过；该结果为前一轮记录，本次未重复主批。`scripts/ci.sh` 主批计数由 987 更新为 991，另两批各 2 项。

## 性能与后续验收

本切片未重新采集性能，不能由绘制改动推断无性能影响。S1 数据仅作既有参考；最终候选需独占机器采集并对照 S0，保留既有超预算项。全量测试须使用 CI 的四个排除项及隔离批次，不能用裸 `swift test` 的退出码作为完成证据。
