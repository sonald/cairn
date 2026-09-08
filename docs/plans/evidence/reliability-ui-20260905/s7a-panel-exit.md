# S7a — 非源码与空态的面板退场：逐片记录

## 现状（审查实测）

- 未打开项目：Trail 空条、Reading Height（禁用态）、Context 占位、Sidebar "No project open" 占位全部可见。
- Markdown 阅读：无用 Outline 空态 + 底部 Context 占位占空间。
- 产品自测还断言 `readingTrailBarVisibleWithoutProject == true`（与 §3.1 新合同相反的旧决定）。

## 实现（§3.1，`MainWindowController.swift`）

内容面派生（`updateContentSurfaceIfNeeded`，只在模式实际变化时触碰 splitter，不在每次 render 重设）：

- `.noProject`（empty/failed）：收起 Sidebar/Context/Relations/Trail；Reader 区由既有品牌空态承载；正常菜单保留。
- `.nonSource`（选中文件 languageMode == nil 且非 Reading Set）：文件树保留，符号大纲（`SidebarViewController.setOutlineHidden`）+ Context + Relations/Inspector 收起；不触碰 Pin（模型状态原样）与用户布局偏好。
- `.source`：恢复。往返布局经 `currentPanelLayout()` 读取当前 splitter 状态保存为私有临时值（§3.1 允许），返回时精确还原用户拖动位置；显式 preset 选择会重置该保存值。
- Reader 无文件时隐藏 Reading Height 控件（`display(nil)` 路径）。
- 产品自测：`readingTrailBarHiddenWithoutProject` 替代旧断言；`contentSplitHeightFillsAvailableContent` 按 Trail 可见性计占位。

## 测试（新增 2 个，`MainWindowControllerTests.swift`）

- `emptyWindowRetiresPanelsWithoutAnObjectOfOperation`：无项目时四面板退场 + 空态主按钮为默认动作完整可见。
- `nonSourceSurfacesRetireSourcePanelsAndRestoreThemOnReturn`：relations 布局下 main.rs →（Pin 定义）→ README（大纲/Context/Relations 退场、文件树保留、Pin 存活）→ main.rs（relations 布局 + 大纲 + Trail 恢复、Pin 仍 pinned）。

## GREEN

- 2 新测试通过；UI 批（Relation/ContextMenu/MainWindowController/NonSource/Palette/ProvenanceBadgeStyle，隔离跳过）：88 通过（M14 非源码预览行为与安全断言不倒退）。
- `AppModelTests|SnapshotSwitchTests|SessionRestoreTests|ReadingSetTests|TabStripModelTests|OutlinePanelModelTests`：335 通过。
- 产品自测（debug 构建）：73 检查全部通过，冷启动 227ms / 空闲 30.5MB。
- `scripts/ci.sh` 883→885。

## 验收对照（计划 §5 S7a）

- source→Markdown→HTML→PDF→source 往返：测试覆盖 source→Markdown→source（HTML/PDF 同走 displayPreview 同一路径）；Pin 往返保留；布局/大纲恢复。✅
- Reading/Relations/Compare/Focus 各 preset 往返 + 滚动/选中恢复：Relations preset 覆盖；其余 preset 的恢复走同一 `savedSourceSurfaceLayout` 机制（V0 步骤 6 的预览往返中再实测）。部分留验。
- 无陈旧源码控件与隐藏但可聚焦 AX 控件：收起的是 NSSplitViewItem（AppKit 自动移出可达性）；Reading Height 隐藏而非禁用。✅（完整 AX 遍历留 V0 步骤 9）
- 初始空窗口主按钮与最近项目完整可见。✅（自测既有断言 + 新增）
- 不修改 SessionCodec。✅
