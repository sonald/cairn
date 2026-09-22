# S3 后续：文档末尾锚点与 F3 阻塞

2026-09-22，基于 `62a71f7`。

F3 Release 诊断复现关闭换行总耗时约 5032ms。调用栈落在 `placeViewportAnchor → scrollRangeToVisible → enumerateCaretOffsets`，见 `followup-checks/f3-before-stack.txt`。

修正包括：

- 文档末尾位置从前一个 fragment 取得尾空行；零宽、有高度的行可作锚点。
- 区分真实硬换行、尾空行与陈旧的 soft-wrap 多行布局，包括 U+2028。
- 缺少几何时采用既有有限校正流程，移除强制导航排版的兜底；有效校正同时恢复水平可见性。
- wrap on 时只需恢复水平起点，省去无用途的字符矩形查询。8000 行同步恢复门控继续生效。
- 关闭 wrap 的段落更新计数按实际段落计算；性能脚本所有 fixture 统一默认 5 次预热、30 样本。

`wrapTrailingEmptyRowRemainsALegalViewportAnchor` 新增 EOF/U+2028 场景，连同既有切换、选区、宽度、缩进测试，**11 项通过**：`followup-checks/anchor-tests.log`。

中间版本单样本诊断为约 1578ms（`f3-eof-diagnostic.json`）；它既不是最终树的正式采样，也未达到 1500ms 预算，不能标记性能通过。后续试验的 ASCII 单字符 API 仍内部枚举整行 caret，无稳定收益，已移除。最终实现保留原生 segment 几何路径，正式预算待独占机器采集。
