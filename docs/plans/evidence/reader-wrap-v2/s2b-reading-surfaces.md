# Reader wrap v2 · S2b Reading Set 与文本预览

日期：2026-09-22；基于 S2a `9e74ccf`。

## 实现

- Reading Set 保存完整 ReaderSettings，已有和新建卡片共用设置路径。
- 卡片显式使用 TextKit 2，按完整摘录的视觉行测量宽高；轻量 gutter 只绘制源行的首视觉行，保留省略行和尾换行语义。
- 每卡片复用一个固定高度约束；相同布局签名不再测量。外层保存卡片/字符锚点，选区及 affinity 保留，用户输入与集合替换使旧锚点失效。
- 普通文本创建与实时更新共用 wrap 配置和本地字符锚点恢复；Markdown 明确分流，保留自身段落规则。
- F5 runner 从固定 fixture 创建 31 张真实卡片，以 cacheDisplay 触发实际绘制，检查高度、选区、锚点和每轮测量次数。脚本改为双向 5 次预热、30 个样本，250ms 预算使用动作开始至稳定的完整时间。

## 本次验证

`swift test --disable-sandbox --no-parallel --filter 'readingSet|plainTextPreviewWrap|markdownPreviewKeepsParagraph'`：两个 target 完整摘要分别为 9、8 项，合计 **17 PASS**。日志：`s2b-checks/focused-tests.log`。

| 编号 | 测试 | 结果 |
| --- | --- | --- |
| W35/W37/W38 | readingSetWrapUsesActualRowsAndOneHeightConstraint | PASS：实际高度、源行标签、尾换行、两种滚动条、重复 apply、固定高度约束 |
| W36 | readingSetReflowPreservesThirdCardCharacterAndCompleteSelection | PASS：第三卡字符锚点、完整多选区与 affinity |
| W39 | plainTextPreviewWrapUpdatesLiveAndOnReopenPreservingSelectionAndAnchor | PASS：已有/重新打开、横滚、字符锚点与完整选区 |
| W40 | markdownPreviewKeepsParagraphLayoutWhenPlainTextWrapChanges | PASS：段落属性不随全局 wrap 改变 |

测试修正：emoji 内部的 UTF-16 位置会被 AppKit 规范化，现先验证规范化后的完整选区，再检查重排不变。固定高度约束只统计作用于 codeScroll 自身的约束，排除其 NSScroller 子视图约束。

F5 Debug 功能冒烟双向各 1 次预热、1 个有效样本：**PASS**，31 卡片每轮各测量一次，锚点误差 0，选区和高度检查通过。此轮有外部 Chrome 高负载，**不是性能证据，不据此判断预算通过**。正式 Release 独占采集与全仓门禁留至最终候选；§9.2 尚不能标记实施完成。
