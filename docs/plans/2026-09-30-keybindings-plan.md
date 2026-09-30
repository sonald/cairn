# 快捷键：集中定义表与设置页（实施计划）

日期：2026-09-30
需求：[2026-09-30-keybindings-requirements.md](2026-09-30-keybindings-requirements.md)（下文 `K-R*` 指需求编号）
原型：[evidence/keybindings/keybindings-settings.html](evidence/keybindings/keybindings-settings.html)
后续：[上下文窗口类型直达计划](2026-09-30-context-window-type-follow-plan.md) 的 P1 起依赖本计划

K0 分两段，各自是一份自包含的任务说明，按顺序做：**K0a 定义表与迁移（不改行为）→ K0b 用户覆盖与设置页**。

## 0. 通用规则

与[类型直达计划 §0](2026-09-30-context-window-type-follow-plan.md#0-所有阶段通用的规则) 相同：先读 `AGENTS.md`；提交用英文、简洁；core 和 model 目标禁止 AppKit/SwiftUI；CI 是 Swift 6.1；每条新测试单独注入并记录；更新 `expected_main_test_count`；在仓库工作树里跑 `CODEX_SANDBOX=1 bash scripts/ci.sh`；界面改动在打包应用里截图证明可见。验收记录写到 `docs/plans/2026-09-30-keybindings-acceptance.md`，截图放 `docs/plans/evidence/keybindings/<阶段>/`。遇到计划没覆盖的分叉，停下来问。

---

## K0a 定义表与迁移（不改行为）

**覆盖**：K-R1、K-R2.5、K-R2.6。**行为变化**：无。所有现有快捷键在迁移前后必须完全一致。

### 数据模型（`Sources/CodeInsightAppModel/KeyBindings.swift`，新文件，不引入 AppKit）

```swift
public struct KeyChord: Hashable, Codable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable { case control, option, shift, command } // display order ⌃⌥⇧⌘
    public enum Key: Hashable, Codable, Sendable {
        case character(String)            // lowercased key equivalent: "j", "[", ",", "+", "1"
        case special(Special)
    }
    public enum Special: String, Codable, Sendable { case left, right, up, down, `return`, escape, space, delete, tab }
    public let modifiers: Set<Modifier>
    public let key: Key
}

public enum KeyBinding: Hashable, Codable, Sendable {
    case keyboard(KeyChord)
    case click(Set<KeyChord.Modifier>)   // reader mouse gesture
    case fixed(KeyChord)                 // panel-internal, display only
}

public struct CommandID: RawRepresentable, Hashable, Codable, Sendable { public let rawValue: String }

public struct CommandDefinition: Sendable {
    public let id: CommandID
    public let group: CommandGroup        // file, edit, find, go, view, relations, lens, readerGestures, panels
    public let titleKey: String           // localization key, reuse the existing app.menu.* keys
    public let defaults: [KeyBinding]
}

public struct KeyBindingScheme: Sendable {                    // K-R1.4: scheme + overrides
    public let id: String                                     // "default"
    public let commands: [CommandDefinition]
}

public struct KeyBindingTable: Sendable {
    public init(scheme: KeyBindingScheme, overrides: [CommandID: [KeyBinding]] = [:])
    public func bindings(for id: CommandID) -> [KeyBinding]
    public func commands(bound to binding: KeyBinding) -> [CommandID]
    public func conflicts() -> [(KeyBinding, [CommandID])]    // across keyboard; across click gestures
    public var displayString: (KeyBinding) -> String          // "⌃⌘J", "⌘⇧ + 点击"
}
```

- 规范字符串（持久化和测试用）：修饰键按 `control, option, shift, command` 排序，再接键名，例如 `control+command+j`。
- 默认方案 `KeyBindingScheme.default`：把 `makeMainMenu()` 里现有的每个快捷键逐条搬进来（清单见需求 §2 和原型页里的数据表）。“后退”和“前进”各两组。⌘P 和 ⌘, 各只登记一次。⌥Z、阅读器手势（⌘+单击 → `reader.gesture.definition`，⌥+单击 → `reader.gesture.symbolDoc`），以及面板内的固定键也要登记。
- 标题复用现有的 `app.menu.*` 本地化键，不新造重复文案。

### App 层适配（`Sources/CodeInsightApp/KeyBindings+AppKit.swift`，新文件）

- `KeyChord` ↔ `NSMenuItem.keyEquivalent` / `keyEquivalentModifierMask`（方向键用 `NSUpArrowFunctionKey` 等字符，回车用 `"\r"`，空格用 `" "`）。
- `func matches(_ event: NSEvent) -> Bool`：用 `charactersIgnoringModifiers` 加修饰键比较，给按键监听用。
- `NSEvent.ModifierFlags` ↔ `Set<Modifier>`。

### 迁移

1. **`makeMainMenu()`**（`CodeInsightApp.swift:11673` 起）：每个菜单项改为 `menuItem(for: CommandID, action:)` 这样的工厂函数：标题和第一组快捷键来自定义表；第二组起，按现有做法生成隐藏的备用项（`isHidden = true`、`allowsKeyEquivalentWhenHidden = true`）。
2. **工具栏弹出菜单**（`MainWindowController.swift:2664`、`2686`）：改为引用同一条命令的绑定，不再写字面量。
3. **只带 ⌥（或 ⌥⇧）、不带 ⌘/⌃ 的键盘绑定**：菜单匹配不上，要走按键监听。把 `handleWrapKeyEquivalent`（`CodeInsightApp.swift:11550`）泛化成 `handleMonitoredKeyEquivalent`：遍历定义表里所有这类绑定，匹配就执行对应命令的 action。⌥Z 只是其中一例。这样用户在 K0b 里录 ⌥X 之类的组合也能生效。
4. **阅读器手势**（`MainWindowController.swift:4659` 起）：`textView.onClick` 取修饰键集合，查定义表得到手势动作（`.definition`、`.symbolDoc`），不再写死 `[.command]`、`[.option]`。空修饰键仍是普通单击。上下文窗口迷你阅读器（`MainWindowController.swift:7388`）的“⌘+单击 打开”改用 `reader.gesture.definition` 的绑定。
5. **面板内按键**：6 处 `keyDown` 和监听的**行为不动**，只把它们用到的键登记为 `.fixed`，供设置页展示。
6. 在 `scripts/ci.sh` 加一条门禁：`Sources/CodeInsightApp` 里除适配文件外，不允许出现非空的 `keyEquivalent: "…"` 字面量和 `keyEquivalentModifierMask =` 赋值。仿照已有的 `rg` 门禁写法，并先用一个样例证明正则能命中。

### 测试（K0a）

| 测试 | 放在 | 断言 | 注入 |
|---|---|---|---|
| `defaultKeyBindingSchemeHasNoConflicts` | `CodeInsightAppModelTests`（新文件 `KeyBindingsTests.swift`） | `KeyBindingTable(scheme: .default).conflicts()` 为空（K-R2.5） | 在默认表里给两条命令同一组合 |
| `keyChordCanonicalStringRoundTripsAndSortsModifiers` | 同上 | `command+shift+f` 与 `shift+command+f` 规范化后相同，编码解码往返一致 | 不排序修饰键 |
| `keyChordDisplayUsesMacModifierOrder` | 同上 | 显示为 `⌃⌥⇧⌘` 顺序 | 改变显示顺序 |
| `mainMenuKeyEquivalentsMatchKeyBindingTable` | `CodeInsightAppTests` | 遍历 `makeMainMenu()` 的每个带快捷键的项（含隐藏项），都能在默认表里找到对应命令和绑定；反过来，表里每个键盘绑定都在菜单里出现 | 在菜单里写死一个不同的快捷键 |
| `mainMenuShortcutsUnchangedByMigration` | 同上 | 与迁移前抓取的快照（标题、键、修饰键三元组列表，写在测试里）逐项相等 | 改掉任意一项 |
| `backAndForwardKeepHiddenAlternateShortcuts` | 同上 | ⌘[ 和 ⌘] 仍由隐藏项承载，且 `allowsKeyEquivalentWhenHidden` | 不生成备用项 |
| `optionOnlyBindingDispatchesThroughMonitor` | 同上 | 合成 ⌥Z 事件，自动换行切换；合成一个定义表里其他只带 ⌥ 的绑定也能分发 | 监听只认 `z` |
| `readerClickGestureResolvesThroughTable` | `MainWindowControllerTests` | 修饰键集合 `[command]` → 跳转，`[option]` → 文档，`[]` → 普通单击 | 手势表查不到时仍走写死分支 |

### 验收（K0a）

- 完整 CI 通过，包括新门禁。
- 原生：打开应用，逐个抽查菜单里的快捷键显示（截“导航”和“视图”两个菜单）；实按 ⌘[、⌃⌘←、⌥Z、⌘+单击、⌥+单击，行为与迁移前一致。

---

## K0b 用户覆盖与设置页

**覆盖**：K-R1.4（覆盖层）、K-R2、K-R3。**前置**：K0a。

### 模型

- `KeyBindingTable` 支持覆盖层：`setBindings(_:for:)`、`reset(_:)`、`resetAll()`。覆盖只保存与默认不同的命令；设成和默认一样就自动删掉覆盖。
- 校验：`validate(_ binding: KeyBinding, for: CommandID) -> Validation`，结果为 `.ok`、`.needsModifier`、`.locked`、`.duplicateOnSameCommand` 或 `.conflict(with: CommandID)`（K-R2.1–K-R2.4）。锁定集合：⌘Q、⌘W、⌘C、⌘V、⌘A、⌘X、⌘,。
- `replace(_ binding:, for:, takingFrom:)`：把绑定从另一条命令上移除，再加到本命令上，作为一次原子操作。
- 持久化：`KeyBindingStore` 读写 `UserDefaults`，键名例如 `keyBindings.v1.overrides`，值为 `[CommandID.rawValue: [规范字符串]]` 的 JSON。遇到未知命令 ID 或解析失败，就丢弃该条、保留其余，不崩溃。仿照 `ReaderSettings.save(to:)` 的做法，测试里用独立的 suite。
- 变更通知：表更新后，App 层重建主菜单（`NSApplication.shared.mainMenu = makeMainMenu()` 已有先例，`CodeInsightApp.swift:10325`），刷新手势表和监听表。所有窗口共用一张表（K-R3.7）。

### 设置页（`ReaderSettingsWindowController.swift`）

- `TabView` 里加一页“快捷键”，图标 `keyboard`（K-R3.1）。
- 列表：单列，按 `CommandGroup` 分组，分组标题吸顶（K1=A）。行布局和状态按原型实现：修改圆点、标题、“新增”小标、键帽、悬停时出现的“+”、已修改时出现的“恢复”、锁形图标、固定键只读。
- 录制控件：SwiftUI 没有现成的按键录制，写一个 `NSViewRepresentable` 的录制视图：成为第一响应者后用 `NSEvent` 本地监听截获 `keyDown`，单独按修饰键时忽略，Esc 取消，⌫ 清除这一组。手势行的录制区接 `mouseDown` 读修饰键。录制期间必须挡住菜单快捷键，避免录 ⌘R 时触发了刷新索引。
- 冲突：行内黄色提示条“⇧⌘F 已分配给「在项目中查找…」 [替换] [取消]”（K2=A）；锁定和缺修饰键的错误用红色小字显示在行下。
- 顶部：搜索框、“按键搜索”按钮（进入一次性录制，结果显示为搜索框里的一个键帽胶囊，再点按钮清除）、筛选胶囊“全部 / 已修改 N”。
- 底部：说明文字，加“全部恢复默认”（先弹确认）。
- SwiftUI 的 `ForEach` 必须用稳定 ID（`CommandID`），CI 禁止用下标或 `enumerated()` 做 ID。
- 新增文案中英双语，`python3 scripts/check-localizations.py` 必须通过。
- self-test 读取口：当前页、可见行数、某条命令的键帽文字、冲突提示是否可见。

### 测试（K0b）

| 测试 | 放在 | 断言 | 注入 |
|---|---|---|---|
| `overridesStoreOnlyDifferencesFromDefaults` | `KeyBindingsTests` | 改回默认值后覆盖被删除 | 始终保存 |
| `validationRejectsLockedAndModifierlessChords` | 同上 | ⌘Q → `.locked`；⇧J → `.needsModifier`；⌥Z → `.ok` | 去掉任一分支 |
| `replaceMovesBindingAtomically` | 同上 | 替换后原命令失去该绑定，新命令获得；两条都在覆盖层里 | 不从原命令移除 |
| `clickGestureRequiresModifierAndChecksConflicts` | 同上 | 空修饰键被拒绝；两个手势同组合 → `.conflict` | 手势不参与冲突检查 |
| `keyBindingStoreDropsUnknownCommandsAndKeepsTheRest` | 同上 | 存储里混入未知 ID 和坏字符串，其余覆盖仍然生效 | 解析失败就全部丢弃 |
| `overrideRebuildsMenusInEveryWindow` | `CodeInsightAppTests` | 两个窗口，覆盖“在项目中查找…”后，主菜单项和工具栏引用同步更新 | 只更新当前窗口 |
| `commandPaletteShowsOverriddenShortcut` | 同上 | 命令面板 `>` 列表里该命令的快捷键列变为新值 | 面板缓存旧值 |
| `recorderSwallowsMenuKeyEquivalentsWhileRecording` | 同上 | 录制时按 ⌘R 不触发刷新索引，而是录下 ⌘R 并提示冲突 | 录制时不挡菜单 |

### 验收（K0b）

- 原生截图（浅色、深色各一套）：
  1. 设置 → 快捷键页全貌。
  2. 把“在文件中查找…”录成 ⇧⌘F → 行内冲突提示 → 替换 → “在项目中查找…”显示“未设置”，两行都有修改圆点。
  3. 试录 ⌘Q → 红字提示。
  4. 按键搜索 ⌘[ → 只剩“后退”。
  5. 回到主窗口：菜单里显示新快捷键；按 ⇧⌘F 实际打开文件内查找；命令面板显示新快捷键。
  6. 重启应用后覆盖仍在；“全部恢复默认”后全部复原。
- 完整 CI 通过。
