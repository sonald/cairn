# S10b — 概念与保存边界文案：逐片记录

## 文案变更（§3.3）

| 位置 | 旧 | 新 |
|---|---|---|
| Trail 空态（含 AX value） | `Navigate from Relations to build a trail · this session only` | `Follow symbols to build a trail · this session only`（search/outline 也进 Trail，与 reducer 实际一致） |
| Trail 详情证据标题 | `AT NAVIGATION · frozen snapshot` / `CURRENT · explanation store` | `Evidence at navigation · frozen snapshot` / `Current evidence`（去掉实现术语） |
| Freeze Results | 无说明 | tooltip：「Freeze the currently published source and evidence snapshots as a Reading Set tab」 |
| Reading Set 副标题 | `N excerpts · frozen at capture` | 追加 `· tab lifetime`（tab 可重启恢复；关闭/淘汰不永久保留——不宣称收藏库） |
| Reading Height 三档 | 无说明 | 分段 tooltip 按 reducer 实际行为：Full 整文件 / Structure 折叠函数体保留签名 / Overview 仅签名与顶层条目 |

菜单名称与快捷键（Full/Structure/Overview、⌥⌘0/1/2）保留；上限（10 tabs/50 excerpts/LRU）与 M11 裁决未改。

## 验证

- 文案断言更新后 UI 批（Relation/ReadingSet/MainWindowController/NonSource，隔离跳过）76 通过；产品自测全通过。
- 界面与 tooltip/AX 同义（Trail AX value 同步更换；按钮 AX label 既有）。
- 顺带清理 RelationWindowController 遗留的一行调试输出。

## 验收对照

- session-only 与 frozen 边界准确（Trail 副标题、Reading Set 副标题、Freeze tooltip）✓
- Structure/Overview 按既有 reducer 行为撰写 tooltip（非仅改名）✓
- 按钮文字未变长（无溢出风险）；核心动作无需 README ✓（Follow symbols/Freeze Results 均自明）
