# 上下文窗口：类型直达、跟踪光标、跟踪所在函数 · 验收记录

需求：[2026-09-30-context-window-type-follow-requirements.md](2026-09-30-context-window-type-follow-requirements.md)
计划：[2026-09-30-context-window-type-follow-plan.md](2026-09-30-context-window-type-follow-plan.md)

## P0 拆开"用户指向的符号"和"窗口显示的内容"（纯重构）

日期：2026-09-30

### 做了什么

- `ContextWindowModel.selectedCandidate` 改名为 `symbolCandidate`（语义：用户指向的符号，
  R2.2），内部 `resolvedCandidate` / `lookup` / `explicitJump` / `selectedLanguageMode` /
  `setMode` 等继续读它；新增 `public var displayedCandidate: Candidate?`（R2.3，窗口显示的
  内容），P0 里恒等于 `symbolCandidate`，两个属性各带一行注释说明区别。
- 调用方逐个归类（`grep -rn selectedCandidate Sources Tests` 全量清点）：
  - 读 **displayedCandidate**（窗口内容）：`ContextWindowViewController` 的 `render()`
    （路径/名字/石子）、`openSelection()`（双击/⌘+单击打开）、`applyBadgeStyle()`；
    `CodeInsightApp.swift` 的 `pinContextSummary`（固定摘要）与历史版本精确自测的
    `uiPath`（镜头显示的路径）。
  - 读 **symbolCandidate**（对符号做事）：`CodeInsightApp.swift` 的 Python call-hierarchy
    自测等待条件（镜头解析到的符号 == 层级符号）；`RelationNavigationTests.swift` 全文件
    （关系窗口的目标就是那个符号）。
  - 计划把 `CodeInsightApp.swift:5986`（uiPath）列为 symbol 侧；按需求 R2.3
    "路径读 displayedCandidate" 的更具体规则归入 displayed，行为无差异（P0 两者恒等），
    特此记录。
- 测试文件归类：`ExactCoordinatorTests` / `AppModelTests` / `RelationTreeModelTests` /
  `MainWindowControllerTests` / `ReaderLigaturePropagationTests` 断言镜头内容 →
  `displayedCandidate`；`RelationNavigationTests` → `symbolCandidate`。
- 新增回归测试 `contextWindowDisplayedCandidateMatchesSymbolCandidateBeforeTypeHop`
  （AppModelTests）：单击普通函数名后两者 `path` / `targetByteOffset` 相同，作为 P1 的基线。

### 测试与注入证据

| 测试 | 注入方法 | 变红输出 |
|---|---|---|
| `contextWindowDisplayedCandidateMatchesSymbolCandidateBeforeTypeHop` | `displayedCandidate` 临时返回 nil | `#require(model.displayedCandidate)` 失败（AppModelTests.swift:3521） |

- 全部既有测试通过（无行为变化，未新增行为测试；计数 1263 → 1264）。
- `grep -rn "selectedCandidate" Sources Tests` 无结果。

### CI

- 完整 CI（`CODEX_SANDBOX=1 bash scripts/ci.sh`）通过，exit 0；
  `PASS: swift test total=1272 (main=1264 isolated=2 panels=2 mouse=2 fonts=2)`。

### 原生验证

无界面变化（纯重构），按计划不截图。
