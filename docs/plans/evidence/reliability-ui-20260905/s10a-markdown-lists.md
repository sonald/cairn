# S10a — Markdown 列表恢复结构：逐片记录

## 实现（`MainWindowController.swift`，无新引擎）

`markdownPreviewAttributedString` 复用 Foundation `presentationIntent`（实测组件叶优先排列、identity 为 Int、嵌套项含多组 list 容器）：

- 新列表项开始时输出标记：无序 `• `、有序 `N. `（按列表 identity 计数、换列表重置）；嵌套层级按组件中 ul/ol 容器数缩进两空格/层。
- 既有块间间距、标题/代码块等宽、行内强调/删除线/链接样式不变；标记插入在样式化文本之前，不进样式 run。

## 测试

- 新增 `markdownPreviewPreservesListMarkersNestingAndInlineStyles`：无序标记 + 嵌套缩进 + 有序 1./2. + 代码块等宽 + 列表内 bold + 只读可选面不回退。
- 既有断言 `first\nsecond` 按新合同更新为 `• first\n• second`（审查实测的"列表丢项目符号"即旧断言所描述的缺陷）。

## GREEN

- 2 测试通过；`NonSourcePreviewTests|MainWindowControllerTests`（隔离跳过）32 通过；产品自测全通过；`scripts/ci.sh` 889→890。

## 验收对照

- 序号/项目符号与嵌套可辨 ✓；列表内强调、链接、代码块不损坏 ✓（既有 link/CSP 断言维持）；窄窗换行与选择复制可用 ✓（既有 wrapping/selectable 断言）；内部链接安全策略、CSP、只读零倒退 ✓（HTML 安全测试不涉 markdown 路径且全部通过）；未扩成 CommonMark 重写 ✓（仅标记/缩进，总 ~40 行）。
