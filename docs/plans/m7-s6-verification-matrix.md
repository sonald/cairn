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
| M7 | 大结果（规模） | `m6_reference_density.rust`：100k 行 / 20k binding / 35k 引用；S5A 实测 18,001 候选 → 201 verified，首批 2,500ms，footer `201 verified references · partial` | 视口门控有效（正常 `referenceScannedCount=55`，注入全扫 3,885,000）；显示上限与真实总数分开 |

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
| B6 | **测试套件 40%+ 概率整体变红** | **已修** `fdadef7`：真因是 `m6_reference_density`（10 万行）在默认 QoS 上同步解析 9–13 秒饿死并发测试，移到 `.utility` 线程后 20/20 全 0。**注意：最初归因于孤儿进程是错的，见 §8.2** |
| B7 | `rust-analyzer` 孤儿泄漏（`ppid=1`，存活 6h57m） | **已修** `fdadef7`（fork reaper + 管道 EOF + 共享内存 PID 表，覆盖 SIGKILL）。**与 B6 是两件独立的事，不能互相冒充** |

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

## §8.2 一次归因失败的完整记录（S6 要引以为戒）

监工最初的因果链是：
`timeout 发 SIGTERM → atexit 不执行 → RA 变孤儿 → 累积抢 CPU → exactWaitUntil 超时`。
证据看起来很硬：孤儿真的存在（`ppid=1`，存活 6h57m / 3h42m）、失败数真的在递增
（12→13→20→34）、`CProcessGuard.c` 的 crash_signals 确实没有 SIGTERM。

**但注入实验推翻了它**：禁掉 reaper 后对 app 发 SIGTERM，RA 照样被回收——
因为 **rust-analyzer 在 stdin 关闭时会自行退出**。那两个孤儿不是从这条路来的。

三臂实测才定出真因：

| 配置 | 红的比例 | 孤儿 |
|---|---|---|
| 基线（都没有） | 4/10（12,13,20,34） | 有 |
| **只有 reaper，无 QoS** | **4/10（2,11,13,4）** | 0 |
| 完整修复 | **0/20** | 0 |

**"孤儿归零"和"套件变绿"是两条独立的曲线。**

三条可迁移的教训：

1. **相关不是因果。** 孤儿存在 + 失败递增 + 防线确实有缺口，三个真事实拼出了一条
   假因果链。每一环都真，链条是假的。
2. **修好了不等于诊断对了。** 完整修复确实 20/20 全绿——若不做"只撤一半"的
   区分实验，就会带着错误的因果故事提交，下次同类问题会照错方向查。
3. **别人报告里的注入证据要看语料。** Codex 报的 `signal=15 orphanAlive=true`
   用的是不会因 stdin EOF 退出的 helper 进程——它证明 guard 对通用子进程有效，
   **不证明真实 RA 走的是这条路**。又一次"语料形似而质不同"。

## §8.3 内存断言的真实强度（S6 不许高估）

`largeReferenceDeltaFootprintMB = 48` 这条断言**只挡得住粗大回归**：

- 监工真机三次实测 delta = **-14.1 / -28.4 / +4.4 MB**——前两次为负，
  即 References 这一步进程内存反而降了，断言属**退化性通过**。
- 它确实有牙：注入"真实持有 64MiB"后 delta 86.9MB、reading `exit=1`。
- 但中小回归会被 TextKit 缓存回收噪声吃掉，
  与 `huge` 步骤既有的 `TextKit cache reclamation makes the delta
  non-attributable` 是同一件事。

**S6 报告只能写"粗大内存回归有守护"，不许写成"References 的内存开销有守护"。**

### 附带的一次口径事故

S5A 首版用 `idleFootprintMB = 100` 卡**进程绝对占用**，
监工真机 baseline 本身就是 101.9–102.6MB——**在被测功能干活之前就注定失败**，
3/3 `exit=1`。而 Codex 那边绿，因为它的 20 次内存表用的是**每次独立进程**
（52.9→76.2），与通道内**单进程跑完整条序列**测的不是同一个东西。

> **给 S6 的判据**：看到"某某数字证明某断言成立"时，
> 先问**那些数字是不是在同一测法下产生的**。

### 其它待观察

大语料首批延迟 **2,500ms**（形态像撞了时间预算而非真算了 2.5 秒）。
诚实标注是对的（`partial` + 不声称真实总数），但手感偏慢，
**需要决策者真机感受后再决定是否单独立项优化**。

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
