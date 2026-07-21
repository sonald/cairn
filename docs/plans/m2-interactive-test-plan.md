# CodeInsight M2 交互测试规格（供 UI 自动化工具执行）

版本：对应 commit `c509af6`（M2 Relations Alpha 完成 + 终审通过）。
沿用 M1 规格的执行方式与报告格式（docs/plans/m1-interactive-test-plan.md）。
本轮聚焦 M2 新功能：Relation Window、全文搜索、符号大纲，外加少量 M1 回归点。

## 前置条件

```sh
cd /Users/siancao/work/ai/vibecoding/codeinsight
swift build -c release
swift run -c release codeinsight-app
# Cmd+O 打开 ~/work/ai/oatmeal
```

已验证的代码事实（断言锚点，均经 CLI 实测）：
- trait `Backend` 定义于 `src/domain/models/backend.rs:73`；其 impl 共 5+ 个：
  Claude（claude.rs:93）、Gemini、LangChain、Ollama、OpenAI——**全部应标 strong**。
- `Backend.name` 的 overrides：各 backend 文件的 `name` 方法——**全部 strong·traitDispatch**。
- `render` 的 callers 含 `src/application/cli.rs:482`（function parse）与
  `src/application/ui.rs:99/115`（closure）——**均为 possible 组**。
- `use super::Bubble;` 在 `src/domain/services/bubble_list.rs`（M1 回归锚点）。

## 已知行为白名单（不算 FAIL，请记录现象）

- K1 外部 crate 解析占位（M1 起）。
- K7 **Calls 树不显示 unresolved/外部调用边**：某函数体内的 `size_of`、`Box::pin`
  等外部调用在 Calls 树中缺席（CLI `calls` 可见）——M3 计划加 External 分组。
  对照源码发现"少边"时记 PASS(K7) 并列出缺席项。
- K8 **Exact 分组头可能恒空**：M2 无精确 provider，Exact 组无内容属正常。
- K9 **Pin + 右键 Show Relations 仍会改写 Context**：Pin 语义待定夺项，
  请专项记录实际行为（这是要收集的决策输入，不是 FAIL）。
- K10 高扇入符号（如 `new`）的 Callers 可能全部落 Possible 组且条目很多（500 上限
  + truncated 行）——名字级合并的如实标注。

## R1 Relation Window 基础

| ID | 步骤 | 预期 |
|----|------|------|
| R1.1 | 启动后观察右侧 | Relation 面板默认**折叠不可见** |
| R1.2 | Cmd+Ctrl+R | 右栏展开（空态）；再按折叠 |
| R1.3 | 打开 backend.rs，右键点击第 73 行 `Backend` → Show Implementations | 右栏自动展开，Implements 段显示 5+ 个 impl（Claude/Gemini/LangChain/Ollama/OpenAI），组头 STRONG |
| R1.4 | 观察每行 | 两行式：类型名 + 路径:行号，副标签 certainty |
| R1.5 | 单击 Claude 行 | 底部 Context 显示 claude.rs 的 impl 摘录；**主区不跳转** |
| R1.6 | 双击 Gemini 行 | 主区跳转到 gemini.rs 对应行；工具栏后退可回 |

## R2 Callers / Calls 树

| ID | 步骤 | 预期 |
|----|------|------|
| R2.1 | 打开 src/application/ui.rs，右键一个函数名（如 `render` 的调用处或定义）→ Show Callers | Callers 树出现；`render` 的调用方含 cli.rs:482（function parse）与 ui.rs 闭包，落 POSSIBLE 组 |
| R2.2 | 展开某个 caller 节点 | 懒加载其上级 caller（spinner 短现），流畅无卡顿 |
| R2.3 | 持续下钻 3–4 层 | 若出现递归路径节点带 ↻ 且不可再展开 |
| R2.4 | segmented 切到 Calls | 显示该函数调用的函数；对照源码抽查 3 条（注意 K7：外部调用缺席属已知） |
| R2.5 | 展开某 edge 的末级 | 出现缩进小字证据行（same file / via import / name only 等） |
| R2.6 | 搜索一个高扇入符号（Cmd+T `new`）→ 右键 Show Callers | 大量条目 + POSSIBLE 组 + 可能出现 truncated 行（K10） |
| R2.7 | Callers 树打开状态下 Cmd+O 重开同一项目 | 树清空/重置，无残留旧数据，无崩溃 |

## R3 全文搜索

| ID | 步骤 | 预期 |
|----|------|------|
| R3.1 | Cmd+Shift+F | 面板弹出，输入框有焦点 |
| R3.2 | 输入 `Backend`（oatmeal 中 ~403 命中/26 文件） | 结果流式出现，按文件分组（组头 = 路径 + 命中数），命中段加粗 |
| R3.3 | 底部状态行 | "N matches in M files" 与实际组内容自洽 |
| R3.4 | 快速连续修改查询（append → appen → append_te） | 无闪烁/旧结果残留 |
| R3.5 | 点击 .* 开 regex，搜 `fn\s+new` | 有结果且行文本含 fn new 形态 |
| R3.6 | 搜单字母 `e` | 出现 truncated 提示（预算生效） |
| R3.7 | Enter/双击某命中 | 跳转到对应文件行（短暂高亮），入历史可后退；面板关闭 |
| R3.8 | Esc / 点面板外 | 关闭 |

## R4 符号大纲

| ID | 步骤 | 预期 |
|----|------|------|
| R4.1 | 打开 src/infrastructure/backends/claude.rs | 侧栏下半区大纲即时出现：struct/impl/fn 层级缩进 + kind 图标 |
| R4.2 | 滚动文件到中部某方法 | 大纲对应行高亮跟随（~100ms 内） |
| R4.3 | 点击大纲某方法 | 主区跳到该方法（入历史） |
| R4.4 | 打开 10 万行文件（M1 规格的 /tmp/ci-huge-project） | 首屏不被大纲拖慢；大纲数秒后异步补齐 |

## R5 M1 回归抽查 + backlog 修复验证

| ID | 步骤 | 预期 |
|----|------|------|
| R5.1 | bubble_list.rs 单击 `use super::Bubble;` 的 Bubble | Context 显示 bubble.rs:24 定义，strong（M1 回归） |
| R5.2 | 选中几行 Cmd+C → 外部粘贴 | 剪贴板正确（M1 T3.4 回归） |
| R5.3 | 打开项目后**立即**（索引状态还在时）从文件树点开一个文件，索引完成后再跳转两次，然后连续后退 | 最初那次文件树打开也在历史中（backlog #7 修复验证） |
| R5.4 | A→B→后退→跳 C→后退→前进 | 历史序列自然，无重复条目感（backlog #6） |
| R5.5 | Cmd+T 输入累积、Esc、双击 | 全部正常（M1 回归） |

## R6 稳定性

| ID | 步骤 | 预期 |
|----|------|------|
| R6.1 | 5 分钟混合操作：Relations 三向切换下钻、全文搜索跳转、大纲导航、历史往返、Pin/Follow | 无崩溃、无 beachball、无内容错乱 |
| R6.2 | （沿用 M1 提醒）不要用 AX 接口直接设置滚动条值 | —— 已知风险项未修（M3） |

## 报告格式

同 M1：`ID | PASS/FAIL/BLOCKED | 备注`；FAIL 附截图与复现步骤；
K7/K9/K10 命中记 PASS(K#) 并**详细记录现象**（K9 的观察是 Pin 语义定夺的直接输入）。
