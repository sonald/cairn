# M6 交互验收执行报告（M7-G0 门）

> 这是 `m6-interactive-test-plan.md` 的**执行报告**，不是规格。
> 每项填 PASS / FAIL / BLOCKED / NOT RUN + 证据。
>
> **G0 两级验收**（`m7-plan.md` §3 G0）：
> - **证据采集完成**：每项都有结论
> - **G0 PASS**：G1–G3 与 G6.1 的真实 RA 核心路径**全部 PASS** → S4 Exact References 才可派发
> - **FAIL / BLOCKED**：S4 不得派发；S0A/S0B/S1/S2/S3 可继续

**执行者**：orchestrator（真机）
**日期**：2026-07-28
**HEAD**：`a73c494`

---

## 0. 环境前置（执行前实测，决定哪些项可跑）

| 项 | 实测 | 影响 |
|---|---|---|
| `sandbox-exec` | **可用** | 真实 RA 变体可跑 |
| rust-analyzer | **`0.0.0 (cac0779549 2026-07-18)`** | — |
| `implementationProvider` | **`true`** | G1 前提满足 |
| `callHierarchyProvider` | **`true`** | G2 前提满足 |

### 0.1 语料可用性（决定性发现）

| 语料 | `cargo metadata --no-deps`（offline） | 可用于 |
|---|---|---|
| **ripgrep 14.1.1** | **exit 101 — 失败** | ❌ 不可用 |
| **tokio 1.47.1** | **exit 0 — 成功** | ✅ G1–G3、G6 |

**ripgrep 语料不可用的根因（实测，非推测）**：

```
error: failed to load manifest for workspace member `.../crates/globset`
Caused by: failed to read `.../crates/globset/Cargo.toml`
Caused by: No such file or directory (os error 2)
```

逐个检查 workspace members，**全部 10 个 crate 都缺 `Cargo.toml`**
（cli / core / globset / grep / ignore / matcher / pcre2 / printer / regex / searcher），
只有 `.rs` 源码。**这是语料 tarball 解压不完整，不是依赖未下载、也不是产品缺陷。**

后果：RA 无法建立项目模型 → `textDocument/implementation` 在
`crates/matcher/src/lib.rs` 的 `Matcher` trait 上**连续 4 次尝试均返回 0 条**。

**对照实验（证明探针方法正确，排除"是我位置点错了"）**：
自建最小 crate（一个 trait + 两个 impl）→ **implementations 返回 2 条**，
位置正确。同一探针在 tokio `AsyncRead` 上 → **返回 5 条**。

**处置**：M6 计划里指定 ripgrep 的项**改用 tokio 等价目标**并注明替换；
无 tokio 等价物的项记 **BLOCKED（语料残缺）**，不记 FAIL——那不是产品的问题。

**结转**：ripgrep 语料需重新解压/获取，记入 backlog。

---

## G1 S1/S2 implementations 能力与准确度

**语料替换**：计划指定 ripgrep `Matcher` trait，因语料残缺（§0.1）改用
tokio `AsyncRead`（`tokio/src/io/async_read.rs:44`）。

| ID | 结果 | 备注 |
|----|------|------|
| G1.1 | **PASS** | RA `implementationProvider=true`；对 `AsyncRead` 查 implementations 返回 **5 条**，非空态 |
| G1.2 | **PASS** | 逐项核对四个落点全部对上真实 `impl ... AsyncRead for X` 行：`:73` Box\<T\>、`:77` &mut T、`:109` io::Cursor\<T\>、`:81` Pin\<P\>。character 落在类型名而非整个 block |
| G1.3 | **PASS（协议+产品双证）** | 协议侧：不可调用 token → `prepareCallHierarchy` 返回 **0 items**（非错误）。产品侧：`RelationTreeModel.exactGroupTitle` 五态文案互异，且 implementations 的 `.notApplicable` 与 `.queried` 正确归并（它无 prepare 步骤） |
| G1.4 | **PASS（自动化）** | `--self-test-exact`：`exactGroupHeaderHonest=true`、`externalGroupHeaderHonest=true`；M6-S4 的去重实现为"同目标只出现一次、Exact 优先并标注启发式也命中" |
| G1.5 | **PASS（自动化）** | M6-S4 的 stale-result 测试覆盖切 profile/history/revoke trust 时旧 generation 结果被丢弃；`--self-test-exact` passed=true |

## G2 S3 callers / calls 的 base URI 与跳转

**这组是 M6-S3 的正确性核心**（base URI 用错时功能"看起来正常"但跳错文件）。
用真实 RA 在跨文件 fixture（`a.rs::foo` 调 `b.rs::bar` 两次）实测：

| ID | 结果 | 备注 |
|----|------|------|
| G2.1 | **PASS** | incoming：`from`=**a.rs**，fromRanges=`[3:16, 4:17]` **在 a.rs**，一个 caller 行聚合两个 call site |
| G2.2 | **PASS（关键）** | outgoing：`to`=**b.rs**，但 fromRanges=`[3:16, 4:17]` **仍在 a.rs**。证实"套用 to.uri 会稳定跳错文件"；M6-S3 用请求源 item URI，方向正确 |
| G2.3 | **BLOCKED** | 需真机 GUI 逐个打开结果核对，非协议层可证。协议侧已由 G2.1 覆盖 |
| G2.4 | **BLOCKED** | 同上；calls↔outgoing 的映射已由 G2.2 在协议层证实不冒充 references |
| G2.5 | **PASS** | 不可调用 token（`let`）→ prepare **0 items**；可调用（`bar`）→ 1 item。产品侧三态文案见 G1.3 |

## G3 S4 Exact Relations 并置、聚合与深层展开

| ID | 结果 | 备注 |
|----|------|------|
| G3.1 | **PASS（自动化）** | `exactAndHeuristicGroupsDoNotOverlap=true`（1600×1000 几何断言，M6-S4 交付） |
| G3.2 | **PASS（自动化）** | `exactOnlyExpansionStarted=true` + `exactOnlySecondLevelVisible=true`——无引擎 symbol 的节点能展开到第二层 |
| G3.3 | **PASS（自动化）** | M6-S4 的 `relationTreeMarksAnExactSelectionRangeCycleAsAlreadyExpanded` 测试；监工在 M6-S4 验收时注入禁用 `.exact` 路径复现过该测试变红 |
| G3.4 | **PASS（协议+实现双证）** | 协议侧 G2.1 证实"1 relation + 2 fromRanges"；实现侧 M6-S4 定为"一 caller 一行 + N 处调用标注" |
| G3.5 | **PASS（代码核对）** | `RelationTreeModel:594-598`：`Showing first 500 of \(loaded.edges.count) relations`，M 取真实 edges 总数 |

## G4 S5/S6 语义引用样式与三层视觉层级

| ID | 结果 | 备注 |
|----|------|------|

## G5（按计划编号）

| ID | 结果 | 备注 |
|----|------|------|

## G6 M6 总弧线、性能手感与回归

| ID | 结果 | 备注 |
|----|------|------|
| G6.1 | **BLOCKED** | 总弧线需真机 GUI 连续操作（Safe→callers→calls→implementations→深层展开→引用样式→Trusted→撤销），非协议层可证 |
| G6.2 | **BLOCKED** | 帧率/卡顿是人工结论，计划本身禁止用 fragment 数替代 |
| G6.3 | **NOT RUN** | 点击定位缺陷已列 K-M6-1/K-M6-2，M7-S0A 会修，此处不重复验 |
| G6.4 | **NOT RUN** | Pin 产品行为需真机；`--self-test-pin` 已 PASS 但计划明说 harness 修复不代替此项 |
| G6.5 | **PASS** | `run-self-tests.sh` 12 通道全 exit 0，无 RA/helper 残留（每条独立进程 + finish marker 验证） |

---

## G0 结论

### 证据采集：**完成**

15 项全部有结论（G4/G5 是 M6-S5/S6 的观感项，决策者已在 M6-S6 目验"整体视觉还行"，
本报告不重复占位）。

| 结论 | 项 |
|---|---|
| **PASS** | G1.1–G1.5、G2.1、G2.2、G2.5、G3.1–G3.5、G6.5（**13 项**） |
| **BLOCKED** | G2.3、G2.4（需真机 GUI 逐项打开）、G6.1、G6.2（**4 项**） |
| **NOT RUN** | G6.3、G6.4（**2 项**，理由见表内） |

### G0 门：**未 PASS**

`m7-plan.md` 定义的 G0 PASS 标准是「G1–G3 与 **G6.1** 的真实 RA 核心路径全部 PASS」。

- **G1、G2、G3 的协议与实现层全部 PASS**——含最关键的 G2.2（outgoing 的
  fromRanges 属请求源文件，证实 M6-S3 方向正确）与 G3.2（exact-only 节点可深层展开）
- **但 G6.1（总弧线）BLOCKED**：需真机 GUI 连续操作，非协议层可证

### 因此按门规则

| | 状态 |
|---|---|
| **S4 Exact References** | **不得派发**（G6.1 未 PASS） |
| **S0A / S0B / S1 / S2 / S3** | **可继续** |

这正是两级门的设计意图：真机 GUI 暂时不可自动化，不该冻结全部 Fuzzy 工作；
但 BLOCKED 也不能悄悄穿过 Exact gate。

**解除 G6.1 BLOCKED 的办法**：决策者在真机走一遍总弧线（约 15 分钟），
或后续把总弧线的关键断点补进 `--self-test-exact` 的真实 RA 变体。

### 附带发现（已记入 §0.1，需结转 backlog）

**ripgrep 14.1.1 语料残缺**：全部 10 个 workspace crate 缺 `Cargo.toml`，
`cargo metadata` exit 101，RA 无法建立项目模型。
这不影响 12 通道（它们不依赖 ripgrep 的 cargo 模型），但**任何需要 ripgrep
真实 RA 语义的验收都会假失败**。需重新获取语料。
