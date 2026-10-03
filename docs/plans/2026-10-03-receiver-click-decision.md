# 决策：单击方法调用的接收者，解析为接收者本身

日期：2026-10-03
状态：已采纳（用户同意）
取代：M7-S0A（a6b4fad）里“命中判定覆盖 nameRange ∪ receiverRange”中的 receiverRange 部分
相关：[上下文窗口类型直达需求 R1.1](2026-09-30-context-window-type-follow-requirements.md)

## 背景

M7-S0A 修复了“点行内任意位置都命中同一个 call”的 bug（提交标题是“点击定位到被点 token”）。为了让 goldset 的 `def5`/`nostrong method.rs:9:21` 保持不动，它把 receiverRange 也算作 call 的命中范围：点接收者 `a` 会得到方法 `tick`。

这条规则和类型直达需求 R1.1（单击值绑定显示它的类型）冲突：`ps.get()`、`self.repo.open()` 这类链式调用里，接收者全都解析成了方法，类型直达形同虚设。它和通行做法也不一致：rust-analyzer 或 VS Code 在接收者上“跳到定义”，跳到的是变量；Source Insight 选中变量，显示的是变量的类型。

## 决定

单击解析的是光标下的那个 token：

| 单击位置 | 解析为 |
|---|---|
| 接收者是标识符、`self`/`this` | 这个绑定本身（上下文窗口：`ps: &S → S`） |
| 链中间的字段或属性 | 这个字段或类属性（Rust 字段 facet，Python `.memberBinding`），再直达它的类型 |
| 方法名 | 方法。仍按接收者类型分派 |
| 模块或限定前缀 | 这个模块或类型本身（原有的标识符回退已经如此） |

随之变化：在接收者上 ⌘+单击 跳到变量声明；查看引用、悬停文档都跟着点到的 token 走。想看方法，就点方法名。

## 实现

- `Resolver.locatedName` 不再把 receiverRange 的命中映射为方法名。`receiverRange` 本身保留，方法分派（`receiverMethodCandidates`、`receiverModuleImportCandidates`）仍靠它推断接收者类型。

## 金标迁移

逐条核对了全部锚点（脚本检查每个位置后面是不是 `.method(`）：

| 金标 | 落在接收者上的条目 | 处理 |
|---|---|---|
| `goldset/fixtures/runner/sample.gold` | `def5`/`nostrong method.rs:9:21`（接收者 `a`） | 挪到 `9:23`（方法名 `tick`）。被测场景“泛型接收者的方法分派在 Top-5 内、且不能给 Strong”不变。另加 `bind method.rs:9:21 -> method.rs:9:13`，锁住“接收者解析为形参”。这次只改金标的查询点、不改夹具，和 M7 记录中被拦下的“改夹具假绿”不同 |
| ripgrep（16 条）、tokio（17 条）、morphic-typescript（10 条） | 无：都锚在函数名或方法名上 | 不变 |
| mcp-python-sdk（6 条） | 本机没有该语料，无法逐条核对。`nostrong __main__.py:48:33`（“dynamically received session 上的方法调用”）和 `unresolved session_group.py:242:30`（“module-object member call `mcp.stdio_client`”）有可能落在接收者上 | **待核对**：有语料时运行 `bash scripts/run-gold-gates.sh --python-corpus <dir> --python-revision f55831ee798cd4d7bafab4d50d6dba46e6fce387`。如果锚点在接收者上，同样挪到方法名 |

## 测试

- 改为新语义：`methodCallReceiverResolvesItselfAndMethodNameStaysBelowStrong`（原名 `…ResolvesMethodsWithoutClaimingStrong`）；`pythonResolverScoresClassConstructorsStrongAndMethodsPossible` 的查询点挪到方法名。
- 新增：`receiverClickHopsToTheReceiversTypeInEveryLanguage`（覆盖 Rust、Python 形参、Python `self.repo`、TS）、`lensReceiverClickShowsTheReceiversTypeAndJumpsToItsDeclaration`。
- 注入：恢复旧的 receiverRange 命中规则后，以上 4 条和 `evaluatesGoldSetMetricsAndKnownFailures` 都变红。

## 验证（2026-10-03）

- 完整 CI（`CODEX_SANDBOX=1 bash scripts/ci.sh`，未设 `GIT_CONFIG_GLOBAL`）：`PASS: swift test total=1329 (main=1321 isolated=2 panels=2 mouse=2 fonts=2)`，exit 0。上一轮因宿主环境失败的 6 条（3 条滚动、3 条 rust-analyzer）这次全部通过，印证了当时“环境问题”的判断。
- 金标门：改动前后各跑一次 `bash scripts/run-gold-gates.sh`，ripgrep、tokio 的全部指标完全相同（diff 为空）。`--typescript-corpus ~/work/ai/morphic`（固定在 f31fe4a）：10 条，0 失败。Python 语料仍待核对，见上文。
- CLI 实测：Rust `ps.get()` 的 `ps` → `lexicalBinding`，`type -> S`；`get` → `receiverType` 方法。Python `r.open()` 的 `r` → 形参 → `Repository`；`self.repo.open()` 的 `repo` → `memberBinding` → `Repository`；`open` → 方法。
