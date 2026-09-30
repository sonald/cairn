# 快捷键：集中定义表与设置页 · 验收记录

需求：[2026-09-30-keybindings-requirements.md](2026-09-30-keybindings-requirements.md)
计划：[2026-09-30-keybindings-plan.md](2026-09-30-keybindings-plan.md)

## K0a 定义表与迁移（不改行为）

日期：2026-09-30

### 做了什么

- 新增 `Sources/CodeInsightAppModel/KeyBindings.swift`（无 AppKit）：
  `KeyChord`（修饰键 + 键，规范字符串按 `control, option, shift, command` 排序，Codable 走单字符串）、
  `KeyBinding`（keyboard / click / fixed）、`CommandID`、`CommandGroup`、`CommandDefinition`、
  `KeyBindingScheme.default`（现有全部快捷键逐条迁入：菜单 45 组、⌥Z 监听、阅读器手势
  ⌘+单击 → `reader.gesture.definition`、⌥+单击 → `reader.gesture.symbolDoc`、面板固定键
  ↑↓/⏎/⎋ 三条）、`KeyBindingTable`（bindings/commands(boundTo:)/conflicts()/displayString，
  显示顺序 ⌃⌥⇧⌘，K-R2.6）。
- 新增 `Sources/CodeInsightApp/KeyBindings+AppKit.swift`：`KeyChord` ↔ `NSMenuItem.keyEquivalent`
  （方向键用 `NS*ArrowFunctionKey`，回车 `"\r"`，空格 `" "`）、`matches(_:)` 用
  `charactersIgnoringModifiers` 比较、`NSEvent.ModifierFlags` ↔ `Set<Modifier>`、
  `NSMenuItem/NSButton.applyKeyChord(_:)`。
- 迁移 `makeMainMenu()`（CodeInsightApp.swift）：每项改为 `menuItem(for: CommandID)` 工厂，
  标题与第一组快捷键来自定义表；第二组（⌘[ / ⌘]）由 `hiddenAlternateMenuItems(for:)` 生成
  隐藏备用项（`isHidden` + `allowsKeyEquivalentWhenHidden`），位置与迁移前一致。
  后退/前进各两组；⌘P 与 ⌘, 各只登记一次。
- 工具栏弹出菜单（MainWindowController.swift 的 Seek/Settings 菜单表示）：改查同一条命令
  （`file.quickOpen` / `app.settings`）的绑定，不再写字面量。
- `handleWrapKeyEquivalent` 泛化为 `handleMonitoredKeyEquivalent`：遍历定义表中所有
  只带 ⌥（或 ⌥⇧、不带 ⌘/⌃）的键盘绑定并 `matches(event)`，命中即执行命令 action
  （`performCommand`，含 `validateMenuItem` 校验，与菜单激活等价）。⌥Z 只是其中一例。
- 阅读器单击分发（ReaderViewController）：修饰键集合经 `ReaderClickGesture.action(for:table:)`
  查表得到 `.plain / .definition / .symbolDoc`；未登记的修饰键组合不动作（与迁移前一致）。
  上下文窗口迷你阅读器的 ⌘+单击 改查 `reader.gesture.definition`。
- 面板内按键行为不动；其用到的键登记为 `.fixed`（`panel.moveSelection` ↑↓、
  `panel.openSelection` ⏎、`panel.closePanel` ⎋）供设置页展示。
- 欢迎页 ⏎ 默认按钮改经适配器 `applyKeyChord`，行为不变。
- `scripts/ci.sh` 新增门禁：`Sources/CodeInsightApp` 除 `KeyBindings+AppKit.swift` 外禁止
  非空 `keyEquivalent: "…"` 字面量、`keyEquivalentModifierMask =` 赋值、`.keyEquivalent = "…"`
  赋值；门禁带三个样例自证正则可命中。

### 分叉决策（计划未覆盖，按需求与原型裁决）

- 分组枚举含 `application`（Cairn 菜单）：需求 K-R1.1 要求分组与菜单一致，原型的分组表
  第一项即 `['app', 'Cairn']`；计划注释里漏列。`app.about / app.settings / app.quit` 归入该组。
- `lens.previousCandidate / lens.nextCandidate`（菜单在"导航"里）按原型归入 lens 组
  （原型把它们与上下文窗口命令并列）。
- 面板固定键按原型归并为三条命令（上下移动 / 打开选中项 / 关闭面板），不按面板逐个拆分。
- 新增本地化键：`keybinding.gesture.definition`、`keybinding.panel.move/open/close`（App），
  `keybinding.click.word`（AppModel，手势展示词）；其余标题复用现有 `app.menu.*`。

### 测试与注入证据

| 测试 | 注入方法 | 变红输出 |
|---|---|---|
| `defaultKeyBindingSchemeHasNoConflicts`（CodeInsightAppModelTests/KeyBindingsTests.swift） | 给默认表的 `view.increaseFontSize` 临时加一组 ⌘F | `Expectation failed: table.conflicts().isEmpty` |
| `keyChordCanonicalStringRoundTripsAndSortsModifiers`（同上） | `canonicalString` 改为按字母序输出（不按 ⌃⌥⇧⌘ 声明序） | `typedCommandFirst?.canonicalString == "shift+command+f"` 与 `decoded.canonicalString == "control+option+shift+command+left"` 两处失败 |
| `keyChordDisplayUsesMacModifierOrder`（同上） | `displayModifiers` 改为 ⌘⇧⌥⌃ 逆序 | `displayString == "⌃⌥⇧⌘J"` 失败（实际 "⌘⇧⌥⌃J"） |
| `mainMenuShortcutsUnchangedByMigration`（CodeInsightAppTests/KeyBindingMenuTests.swift） | 默认表把 `find.next` 从 ⌘G 改成 ⌘U | `find[?] key u != g`（键快照逐项比较失败） |
| `mainMenuKeyEquivalentsMatchKeyBindingTable`（同上） | `menuItem(for:)` 里对 `go.openSymbol` 写死 `keyEquivalent = "u"` | 正向 `!bound.isEmpty` 失败（⌘U 无命令）+ 反向 `found` 失败（表里的 ⌘T 不在菜单） |
| `backAndForwardKeepHiddenAlternateShortcuts`（同上） | `hiddenAlternateMenuItems(for:)` 直接返回 `[]` | `both.count == 2` 失败、隐藏项 `#require` 失败 |
| `optionOnlyBindingDispatchesThroughMonitor`（同上） | `handleMonitoredKeyEquivalent` 恢复旧逻辑只认 "z"、不查表 | ⌥X 分发失败、⌥Z 切换失败、⌥⇧Z 穿透失败 |
| `readerClickGestureResolvesThroughTable`（MainWindowControllerTests.swift） | `ReaderClickGesture.action` 写死 ⌘→definition、⌥→symbolDoc，忽略表 | 无手势表的方案下 `action(for: [.command]) == nil` 失败 |

注入均为"改坏 → 该测试变红 → 改回 → 全部恢复绿色"，逐条单独执行。

### CI

- `expected_main_test_count` 1247 → 1255（新增 8 条测试：模型 3 + App 菜单 4 + 手势 1）。
- 完整 CI（`CODEX_SANDBOX=1 bash scripts/ci.sh`，含新门禁）：见下文结果记录。

### 原生验证

- 打包应用（`CAIRN_LIBGIT2=brew bash scripts/make-app.sh`，exit 0）可正常启动，
  进程驻留、无崩溃日志；CI 中的 `codeinsight-app --self-test-exact / --self-test-diff /
  --self-test-reading / --self-test-projector / --self-test-fold` 全部通过。
- **受限记录**：本机对宿主屏幕录制（`screencapture`）与辅助访问（osascript System Events）
  均无 TCC 授权，菜单截图（"导航"/"视图"）与实按 ⌘[、⌃⌘←、⌥Z、⌘+单击、⌥+单击 无法在本环境
  完成。行为一致性由以下程序化检查覆盖：
  - `mainMenuShortcutsUnchangedByMigration`：迁移前抓取的（标题、键、修饰键）三元组快照逐项相等；
  - `backAndForwardKeepHiddenAlternateShortcuts`：⌘[ / ⌘] 仍由隐藏项承载且
    `allowsKeyEquivalentWhenHidden == true`；
  - `optionOnlyBindingDispatchesThroughMonitor`：合成 ⌥Z 事件实际切换了自动换行偏好；
  - `mainMenuKeyEquivalentsMatchKeyBindingTable`：菜单 ↔ 定义表双向一致。
  实按与视觉抽查留给统一验收。
