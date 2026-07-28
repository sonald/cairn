# M7-S6 全量验证路径清单

**用途**：S6 总验收的**穷举底稿**。S6 的验收报告必须逐行答"这条路谁走过、
绿来自哪里"，**不许出现没有对应证据的空行**。

**建立时间**：2026-07-28，基线 `2d37412`（S4 派发中）。
所有"现状"栏的数字都是**实测**，不是读代码推断；推断的一律标 `?`。

---

## §1 覆盖面现状（实测，`2d37412`）

### 1.1 12 条通道对 Relation/References 路径的触及数

`awk` 按 `selfTestReaderRelation|selfTestSelectRelationEdge|relationTree` 统计：

| 通道 | 触点数 | 说明 |
|---|---:|---|
| **exact** | **61** | 唯一真正覆盖 Relation 的通道 |
| pin | 2 | 只验 Pin 语义与 Relation 的交互 |
| base / project-git / project-non-git / tabs / search / reading / diff / history / switch / open | **0** | **完全不碰** |

> **这就是"12 通道全 PASS"最大的误导源**：Relation/References 的全部通道级证据
> 集中在**一条**通道上。报"12 PASS"时必须同时说明这一点（铁律⑩）。

### 1.2 真实 rust-analyzer 的盲区（**references 一格已由 S4 填上**）

建表时（`2d37412`）`runRealExactVariant` 对 `relationTree` 的触点数 = **0**：
真实 RA 只被验过 click→Context 的 definition 升级。

**S4（`4d184d4`）补上了 `references` 这一格。** 监工在真机实跑
`--self-test-exact .`（`sandbox-exec` 与 `rust-analyzer` 均可用），实测：

```
step=real-references  variant=rust-analyzer
realProvider=passed
textDocumentReferencesReached=true
skipped 步骤数 = 0（28 个 step 全跑）
channel=exact exit=0
```

> Codex 环境无 `sandbox-exec`，它自己那轮输出的是
> `realProvider="skipped:sandbox-unavailable"` 并**如实记 BLOCKED**。
> **注意 `runRealExactVariant` 的 skip 分支返回 `passed=true`**
> （`CodeInsightApp.swift:3438`）——skip 在通道门里算过。
> 所以"exact 通道 exit=0"**不蕴含真实 RA 跑过**，必须另看 `realProvider` 的值。
> 这是铁律⑧的具体形态，S6 报告要显式引这个字段而不是引 exit code。

**仍然是 0 的三格**：`implementations` / `incomingCalls` / `outgoingCalls`
的真实 LSP 往返，至今没有任何自动化覆盖。见 §8 B1。

---

## §2 入口路径（用户怎么拿到 Relation 结果）

| # | 路径 | 现状证据 | S6 要确认 |
|---|---|---|---|
| E1 | 右键菜单 → Show Callers / Calls / Implements / References | `df1fd8f` 修好（`NSTextView` 合并菜单导致 `menuNeedsUpdate` 从不触发，四方向全废） | 四方向各自能拿到 offset；**只读铁律：菜单无编辑项** |
| E2 | 方向分段控件切换 | S2 加第四段；`selfTestChangeRelationDirection` | 切换不产生跳转（Fix3 已断言）；generation 递增 |
| E3 | 展开 edge 节点下钻 | `:471` `queryTarget ?? target` | 展开用 queryTarget，与 E5 的落点区分 |
| E4 | 双击 edge → re-root | `openSelection` 的 `declarationFacet` 分支 | 位置行不 re-root（Fix3 已断言） |
| E5 | 键盘 Enter 打开选中行 | `outlineView.openSelection = { openSelection(nil) }` | 位置行按 Enter 仍导航（`sender == nil` 分支） |

## §3 结果消费路径

| # | 路径 | 现状证据 | S6 要确认 |
|---|---|---|---|
| C1 | 单击**符号行** → Context 更新 | `3c5c4a1`（`queryTarget ?? target`）；注入验证 1/1 红 | 连续点两行 Context 变两次 |
| C2 | 单击**位置行** → 阅读区导航 | `2d37412`（`representsLocation`）；注入 A/B/D 五条全有牙 | reference 行 + 局部引用行都跳；符号行不跳 |
| C3 | 双击 → 打开 | Fix3 断言不跳两次 | — |
| C4 | 导航历史返回 | Fix3 `historyBack=true`（exact 通道实测） | 跨文件跳转后能回原位置 |
| C5 | Pin 生效时 | Fix3 裁决：Pin 只冻结 Context，不冻结阅读区 | 两条断言都在 |

## §4 四方向 × 来源层（S6 的主矩阵）

**每格都要答"哪条测试/通道走到了"**，空格＝未覆盖，必须显式写 `未覆盖` 或 `BLOCKED`。

| 方向 \ 来源 | Exact（fake provider） | Exact（**真实 RA**） | Fuzzy / 启发式 | Local（S2） |
|---|---|---|---|---|
| callers | exact 通道 | **0 触点（盲区）** | ✓ | n/a |
| calls | exact 通道 | **0 触点（盲区）** | ✓ | n/a |
| implementations | exact 通道 | **0 触点（盲区）** | ✓ | n/a |
| **references** | ✓ S4（分列 Exact 组） | **✓ 真机实证** `realProvider=passed` | S3 两阶段扫描 | S2 |

**S4 的三条去重断言也进这张表**：同位置双命中（带 `heuristic also matched`）／
只 Fuzzy 命中／只 Exact 命中。

## §5 模式与语境（每条都要跨 §4 主矩阵至少抽验一格）

| # | 语境 | 现状 | S6 要确认 |
|---|---|---|---|
| M1 | Safe / Trusted | `6808dfd` 修过 overlay trust 串档 | 两种 trust 下结果与标注都对 |
| M2 | offline | 我们自己设 `CARGO_NET_OFFLINE=1`（`Sandbox.swift:51`，**Safe 与 Trusted 都设**） | 空态文案诚实，不谎称能力 |
| M3 | 历史快照（commit 时光机） | `runHistoricalExactVariant` | 语义操作在历史快照上仍可用 |
| M4 | git 语料 / 非 git 语料 | 通道各跑一次 | 非 git 下 Exact 不可用时 Fuzzy 兜底 |
| M5 | Context pinned / unpinned | Fix3 两条断言 | — |
| M6 | 多标签 | Fix3 `selfTestTabCount == 3` 断言 | 跳转落在正确 tab |
| M7 | 大结果（规模） | `m6_reference_density.rust`：100k 行 / 20k binding / 35k 引用 | 视口门控有效；显示上限与真实总数分开 |

## §6 诚实与计数合同（§2.2 四态）

| 状态 | 文案 | S6 断言 |
|---|---|---|
| complete | `M references` | 有 |
| display cap only | `Showing first N of M references` | 有 |
| **service truncated** | `N verified references · partial` | **必须断言文案不含真实总数** |
| （组计数 scope） | 组副标题只数本组，跨组总数只挂兄弟/父节点 | S4-Fix：complete 态 fuzzy-only / exact-only / mixed 三种构成各有断言 |
| （空） | 可区分的空态文案 | 四种 `exactState` 不得折叠成一句 |

**红线**：启发式结果一律封顶 Strong，绝不冒充 exact；nil 字段绝不显示。

## §7 determinism 硬门（每次都跑，不抽样）

- canonical dump **字节级零 diff**
- 双语料 gold **nostrong=0**（ripgrep 14.1.1 + tokio 1.47.1）
- **`goldset/` git 零 diff**
- **`RECORD` 禁止设置**（重录即作废）

## §8 已知盲区与未决项（S6 必须逐条给结论，不许静默略过）

| # | 项 | 状态 |
|---|---|---|
| B1 | 真实 RA 的 **references** 往返 | **已填**：`4d184d4` + 监工真机实跑 `realProvider=passed` |
| B1b | 真实 RA 的 **implementations / incomingCalls / outgoingCalls** 往返 | **仍 0 覆盖**，M7 不在范围内，需单独立项 |
| B2 | `ExactOverlay.ReuseKey` 不含 worktree 内容身份（改文件后可能命中陈旧 overlay） | 无稳定复现，S0B 红线内未改 |
| B3 | G6.2 帧率手感 | 人工项 BLOCKED，**禁止用 fragment 数替代** |
| B4 | ripgrep 语料 10 个 crate 缺 `Cargo.toml`，`cargo metadata` exit 101 | 需重新获取；**不可用于真实 RA 实验** |
| B5 | 批量通道偶发挂起的根因 | 未知；`run-self-tests.sh` 用 90s 超时 + 自动 `sample` 兜住 |
| B6 | **测试套件 40%+ 概率整体变红**（`ExactCoordinatorTests` 超时，单次最多 34 条） | **根因已取证**：`rust-analyzer` 孤儿进程泄漏（`ppid=1`，存活 6h57m / 3h42m）+ 171 个残留临时目录，累积抢 CPU。已派 LeakFix。**修好前 S6 的"全量绿"没有意义** |

## §8.1 B6 的实测数据（20 次同 commit 连跑）

同一 commit、零代码改动，`swift test` 全量跑 20 次的失败条数：

```
0, 12, 0, 13, 0, 0, 0, 0, 20, 34,
13, 0, 8, 13, 19, 3, 0, 32, 18, 9
```

**红占 40%+，且随跑次数递增**——递增是"孤儿进程累积"的直接指纹。
同样几条测试**单跑 0.03 秒全绿**。

已有防线 `Sources/CProcessGuard/CProcessGuard.c` 挂了 `atexit` 与五个 crash 信号
（`SIGTRAP/ABRT/SEGV/BUS/ILL`），**但没有 `SIGTERM`**；
而 `run-self-tests.sh` 用 `timeout` 守着，`timeout` 默认就发 SIGTERM。

> **给 S6 的方法论警告**：这一条同时说明，**"跑一次全绿"不构成套件健康的证据**。
> S6 的稳定性结论必须建立在**多次连跑的失败数分布**上，不是单次绿。
> 并且**跑前跑后都要查进程表孤儿数**
> （`ps -eo pid,ppid,command | grep rust-analyzer`，
> 排除用户编辑器自己那个——它的 `ppid` 不是 1）。

## §9 S6 验收方式的硬要求

1. **逐条红绿注入清单**：新测试写完后逐项撤回改动，列出哪些红、哪些绿。
   **仍绿的不计入"验了"。**
2. **否定性断言要单独注入**：用能真的制造出被禁行为的注入证明它有牙。
   （Fix3 里 `ProgrammaticChangesDoNotNavigate` 第一次注入没注进去——
   循环找不到 `.edge` 行，因为组是折叠的；换手法才证明有牙。）
3. **报"N 通道全 PASS"必须同时给 §1.1 那张分布表**，说明覆盖集中在哪一条。
4. **验收工具本身先验**：二进制名是 `codeinsight-app` 不是 `CodeInsightApp`；
   zsh `noclobber` 下 `>` 会拒绝覆盖并给出假 `exit=1`（用 `>|`）；
   喂给 `--self-test-open` 的文件必须真实存在（根目录**没有** README.md）。
