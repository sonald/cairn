# S8 — 视觉层级、字号和色彩收敛（App chrome 步）：逐片记录

按计划拆两步：本提交只改 App chrome（`MainWindowController.swift`、`RelationWindowController.swift`、`EmptyStateView.swift`）；共享 Reader token（`CodeInsightReaderUI.swift`）未动——用户 Reader 字号、语法色、主题与本切片无冲突，单独调整缺真实内容视觉评审支撑，按计划「保留必要的人工视觉判断」记为不必要变更（无对应本轮问题的 token 值不改）。

## 字号（§3.2 地板）

| 位置 | 原 | 新 | 依据 |
|---|---|---|---|
| Relations Inspector 解释正文/标题 | 11 / 10 | 12 / 11 | 解释正文优先 12–13 |
| Inspector audit 键/值（源码身份内容） | 10 / 10 | 11 / 11 | 关键辅助 ≥12 的折中：键值对紧凑布局取 11 并保持 monospace |
| Inspector Hide audit / Former candidate 按钮 | 11 | 12 | 关键操作 |
| Relations Inspect / Freeze Results 按钮 | 11 | 12 | 关键操作 |
| Relations 占位/加载/截断/错误行 | 11 | 12 | 辅助说明 |
| Relations 证据行（源码片段） | 10.5 | 11.5 | 证据行低于标题层级、高于修饰符 |
| Relations 修饰符标注 | 10 | 11 | 次要标注下限 |
| 状态栏 index/exact/truncated/Refresh 按钮 | 11 | 12 | 常驻状态与主动作 |
| Context 头部路径 | 12 | 12.5 | 第二层（文件/路径）高于状态 |
| Context 头部状态徽标 | 11 | 12 | 常驻简短状态 |
| Profile 按钮 | 11 | 12 | 第三层说明但可读性下限 |
| 空态最近项目路径 | 11 | 12 | 关键路径辅助文字 |
| 保留 11pt：计数（monospaced digits）、快捷键、drop 提示、RECENT 标题、徽标小标记 | — | — | 短次要标注 |

## 色彩

- 蓝色仅选中/主动作（既有）；绿色仅小型验证徽标（S6 后徽标为短状态文字 + 12% alpha 底，非整条染色）；黄色无 chrome 使用（保留给查找/跳转反馈）；Orange/Red 仅截断/错误行（重要区别保留）。
- 未改 provenance 徽标数据与配色映射（S6 已完成短标签化）。

## 验证

- UI 批 90 通过（徽标文本断言、布局几何、AX 维持——字号变化不破坏任何布局合同，S6 的窗口不变合同复验通过）。
- 产品自测全部通过。
- 纯样式值未写镜像测试（计划明示）；Light/Dark/SI Classic 同内容截图对比留 V0 步骤 9。

## 遗留

- Reader token 步：无本轮问题对应的 token 变更需求；如 V0 视觉复核发现具体问题再单列小提交。
