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
- 完整 CI（`CODEX_SANDBOX=1 bash scripts/ci.sh`）通过，exit 0；
  `PASS: swift test total=1263 (main=1255 isolated=2 panels=2 mouse=2 fonts=2)`，
  新增门禁输出 `PASS: App 层快捷键全部来自定义表`。

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

---

## K0b 用户覆盖与设置页

日期：2026-09-30

### 做了什么

- 模型层（`KeyBindings.swift`）：
  - 覆盖层 `setBindings(_:for:)` / `reset(_:)` / `resetAll()`；覆盖只在与默认不同时保留，
    设回默认即删除（K-R1.4）；`modifiedCommands` 供"已修改 N"筛选。
  - `validate(_:for:) -> KeyBindingValidation`：`.locked`（⌘Q/⌘W/⌘C/⌘V/⌘A/⌘X/⌘,）、
    `.needsModifier`（K-R2.1 / K-R2.4）、`.duplicateOnSameCommand`、`.conflict(with:)`、`.ok`
    （K-R2.1–K-R2.4）。语义注记：计划测试表里"⌥Z → .ok"按"⌥ 组合本身合法（未被占用时）"落实。
  - `replace(_:for:takingFrom:)` 原子地把绑定从原命令移除并加到新命令，两条命令都进覆盖层
    （失去全部绑定的命令记录为空数组覆盖，即"未设置"）。
  - `KeyBindingStore`：UserDefaults 持久化，键 `keyBindings.v1.overrides`，
    JSON `[CommandID: [规范串]]`；未知命令 ID 整条丢弃、坏字符串丢弃保留其余；支持注入独立 suite。
- 应用层：`AppDelegate.loadKeyBindingOverrides()` 启动时装载覆盖；`applyKeyBindings(_:)`
  保存 → 更新设置页模型 → 重建主菜单（`NSApplication.shared.mainMenu = makeMainMenu()` 先例）→
  逐窗口刷新（K-R3.6/K-R3.7）；`MainWindowController.applyKeyBindings()` 原地更新工具栏
  Seek/Settings 菜单表示的键帽。
- 设置页（新文件 `KeyBindingSettings.swift` + `ReaderSettingsWindowController` 接线）：
  - TabView 新增"快捷键"页（`keyboard` 图标，K-R3.1），TabView 选择改为状态驱动（self-test 读取口）。
  - 单列列表按 `CommandGroup` 分组、`LazyVStack(pinnedViews: [.sectionHeaders])` 吸顶分组标题（K1=A）；
    行内：修改圆点、标题、键帽（多组并排）、悬停"+"（再加一组）、已修改"恢复"、锁定行锁形图标、
    固定键只读填充键帽（K-R3.2）。ForEach 全部用 `CommandID` / `KeyBinding` 的稳定 ID。
  - 录制：`KeyChordRecordingSession` 用 `NSEvent.addLocalMonitorForEvents` 截获 `keyDown`/
    `leftMouseDown`；修饰键单独按忽略、Esc 取消、⌫ 清除这一组；手势行读点击修饰键；
    录制期间事件被吞掉，菜单快捷键不触发（K-R3.3）。
  - 冲突行内黄色提示条 + 替换/取消（K2=A）；锁定与缺修饰键的红字显示在行下。
  - 顶部搜索框、"按键搜索"按钮（一次性录制 → 键帽胶囊，再点清除）、"全部 / 已修改 N"胶囊（K-R3.4）。
  - 底部说明 + "全部恢复默认"（确认弹层，K-R3.5）。
  - self-test 读取口：当前页、可见行数、某命令键帽文字、冲突提示可见性。
- 新增中英双语本地化键 35 条（`settings.keybindings`、`keybinding.*`），
  `python3 scripts/check-localizations.py` 通过。

### 测试与注入证据

| 测试 | 注入方法 | 变红输出 |
|---|---|---|
| `overridesStoreOnlyDifferencesFromDefaults` | `setBindings` 改为始终保存覆盖 | `table.overrides[.fileQuickOpen] == nil` 失败 |
| `validationRejectsLockedAndModifierlessChords` | 删除 `.locked` 分支 | ⌘Q / ⌘, 两条 validate 断言失败 |
| `replaceMovesBindingAtomically` | `replace` 不从原命令移除绑定 | `!bindings(findInProject).contains(...)` 等三条失败 |
| `clickGestureRequiresModifierAndChecksConflicts` | 手势分支直接返回 `.ok`（跳过冲突检查） | `redefined.validate(...) == .conflict(...)` 失败 |
| `keyBindingStoreDropsUnknownCommandsAndKeepsTheRest` | load() 发现任一坏字符串就丢弃整个存储 | viewWrapLines / fileQuickOpen / readerGestureDefinition 三条加载断言失败 |
| `overrideRebuildsMenusInEveryWindow` | `applyKeyBindings` 只刷新 `projectWindows.prefix(1)` | `itemsAfter.allSatisfy { keyEquivalent == "b" }` 失败 |
| `commandPaletteShowsOverriddenShortcut` | `applyKeyBindings` 不重建主菜单 | `after.shortcut == "⌘B"` 失败（面板仍是 ⌘N） |
| `recorderSwallowsMenuKeyEquivalentsWhileRecording` | 录制会话对 ⌘R 事件直接放行 | `!probe.hit` 失败且冲突未出现 |

注：测试 6/7/8 触碰 `NSApp` 全局状态（delegate / mainMenu / 标准偏好），已放入
`@Suite(.serialized)`；`NSApp` 全局变量需先访问一次 `NSApplication.shared` 才非 nil。

### CI

- `expected_main_test_count` 1255 → 1263（新增 8 条：模型 5 + App 3）。
- 完整 CI（`CODEX_SANDBOX=1 bash scripts/ci.sh`）通过，exit 0；
  `PASS: swift test total=1271 (main=1263 isolated=2 panels=2 mouse=2 fonts=2)`，
  含 AppKit/SwiftUI 禁令检查与全部 app self-test。

### 原生验证

**受限记录**：与 K0a 相同，宿主未授予屏幕录制与辅助访问权限，设置页浅色/深色截图
（验收清单 1–6）无法在本环境完成；SwiftUI 页面的实渲染走查留待统一验收。
模型与刷新链路由上表 8 条测试覆盖（覆盖持久化、菜单/工具栏/命令面板同步、录制吞键）。


---

## 独立评审与修复

日期：2026-10-02

| # | 问题 | 修复 | 回归测试 |
|---|---|---|---|
| 2 | 录制会话装的是**整个应用**的按键监听，并吞掉所有 keyDown；关窗、切页、切到别的窗口都不会结束录制。设置窗口关闭后，主窗口按下的下一个组合键（例如 ⌘F）会被悄悄记成正在录制的那条命令的新快捷键 | 会话记下发起录制的窗口编号：来自其他窗口的事件结束录制并原样放行，不会被捕获；离开“快捷键”页（`selectedTab` 的 didSet）和 `windowWillClose` 也会结束录制 | `recorderEndsInsteadOfCapturingKeysFromAnotherWindow` |
| 2′ | 评审中新发现，比 #2 更严重：“按键搜索”的录制会话**从不停止**。捕获一次之后，监听仍在吞掉整个应用的所有按键，连 Esc 都结束不了，只能重启应用 | 抽成 `makeKeySearchSession`：第一次捕获、Esc、⌫ 或来自其他窗口的事件都会停止会话 | 同上测试的最后一段 |
| — | 需求 K-R3.2 的“新增”小标从未出现：`isNew` 写死为 `false`，P1 和 P3 新增命令后没有更新 | 新命令集合：`navigate.typeDefinition`、`reader.gesture.typeDefinition`、`lens.trackSymbol`、`lens.trackEnclosing`、`lens.togglePin` | 无（只是查一个集合，按 AGENTS.md 不写复述实现的测试） |

注入（逐条单独执行）：去掉窗口编号检查 → 菜单探针没有触发（`Issue recorded`：被当作绑定提交了）；去掉切页结束录制 → `model.recording == nil` 失败；去掉按键搜索的停止 → `probe.hit` 失败。

原生走查：设置页仍没有截图（同上，缺桌面授权）。
