# M8 总验收报告

**基线**：`57b364b`，工作树干净。执行者：监工（Opus），所有数字为真机实测。
**日期**：2026-07-30。

---

## §0 结论：同场景 141.2 秒 → 360 毫秒

**这是 M8 唯一能写进结论的数字**，因为它满足三个条件：
**同一个符号、同一个规模（有字段证明）、真实 rust-analyzer 而非 fake**。

tokio `lock`（`tokio/src/sync/mutex.rs:434`，`utf8ByteOffset=15449`），
`measurementScope: "real rust-analyzer"`，`indexHot: true`，
**`relationCandidateEdgeCount: 215`**：

| | 首个可操作行 | 全部结果 | 首个来源 |
|---|---:|---:|---|
| **修前**（另一 agent 实测） | — | **141,200 ms** | — |
| **cold** | **360 ms** | 416 ms | `heuristic` |
| **warm** | **337 ms** | 2,947 ms | `heuristic` |

**约 390 倍。** `relationFirstActionableKind = heuristic`、首行 `blocking_lock`——
S1 的核心设计（启发式先出、exact 后到原位升级）**在真实 RA + 热符号下成立**。

复现命令：

```bash
TOKIO=…/scratchpad/corpora/tokio-tokio-1.47.1
.build/debug/codeinsight-app --self-test-relation-timing \
  "$TOKIO" tokio/src/sync/mutex.rs 15449 real
```

> **此前所有 37–95ms 的数字都不能当结论**——它们跑的是 `exact_fixture`（几个符号），
> 与 215 条边差三个数量级。不能相减。

---

## §1 门禁总表

| 项 | 结果 |
|---|---|
| `swift test` | **408 全绿** |
| `ci.sh` | exit 0 |
| `run-self-tests.sh` | **pass=12 fail=0 hang=0** |
| `stress-test.sh --runs 3 --load 8` | 全 0，`residual_load_processes=0` |
| canonical dump | 零 diff（23 fixtures） |
| ripgrep gold | `nostrong=0`，`unexpected failures=0` |
| tokio gold | `nostrong=0`，`unexpected failures=0` |
| `goldset/` git diff | 0 |
| 真机四格 | **3/3 `realProvider=passed`** |

## §2 各片交付与证据

| 片 | commit | 关键证据（监工实测或注入验证） |
|---|---|---|
| S0 候选复用 | `2869a89` | 注入撤回 → 四方向 4 个 issue 全红（`localIndex 11=.first` vs `14=用户选中`） |
| WaitFix + 压测脚本 | `eb73f77` | 同机同负载：**修前 20 失败 → 修后 0** |
| S1 首屏渐进发布 | `4a97884` | 注入接回逐行 promotion → `definitionRequests → 3 / 4` 变红 |
| 空 Exact 组 + 首屏埋点 | `da8befb` | 探针 `groups=["Strong","Probable","Possible"]` 定位组消失；埋点注入全量屏障 → 首行慢 8.2×/10.7× |
| S3 行 badge + 文档同步 | `d385db5` | 注入 `strong` 冒充 `Verified` → 字面量断言变红；`design.md` F3.1/F3.3/F3.5 已改并注明日期理由 |
| S2 真取消 | `e800622` | fake LSP 实收计数：**3 次切换 4 → 2**，不随切换线性增长 |
| S4 按需分批 | `1cd5f2e` | 215 条 Possible **分 7 批、批大小 32**；未展开时 promotion=0 |
| S5 测量入口 + 补漏 | `57b364b` | tokio 规模入口；`waitForFile` 族改保险丝，`timeout: 1` 短等待语义保留 |

## §3 修掉的两个「设计漂移」

| 漂移 | 双重佐证 | 处置 |
|---|---|---|
| 分组五段而非三段 | `design.md` F3.3（P0）与 `m2-plan.md:32` **都写三段、probable 归 Possible** | S3 收敛为行 badge，`design.md` 同步改并注明 |
| 组标签自相矛盾 | S1 位置稳定让 `Strong` 组里出现 `Exact · lsp` 行；`Exact (0)` 与事实冲突 | S3 取消 certainty 分组，从根上消除 |

> **漂移的教训不是"不该改设计"，是"改了没写下来"**——文档说三段、代码做五段，
> **漂了 5 个里程碑无人发现**。所以 §3.4 把文档同步定为硬交付。

---

## §4 未解决（**不许静默略过**）

| # | 项 | 状态 |
|---|---|---|
| **N1** | **warm 的 `relationAllResultsMS` = 2,947 ms**，是 cold（416 ms）的 7 倍，而首行反而更快（337 vs 360） | **已查明，见 §4.1（2026-08-05）**。不是 warm 比 cold 慢，是**固定重试睡眠落在哪一相是随机的** |
| **N2** | 压测**三次挂起 183s** 未解释 | 停止时点与监工清理残留空转 shell 重合，但那些是 0% CPU，**建立不了因果**。后续 5 次全部 39–53s 完成 |
| **N3** | `real-references` **间歇** | 同一二进制第一次 `failed:references`，随后 3/3 `passed` |
| **N4** | 12 通道跑的仍是 `exact_fixture` | tokio 规模的测量要手工跑 `--self-test-relation-timing`，**未进自动化门禁** |
| **N5** | `real-implementations` 曾**静默坏掉** | M7-S6 在 `5a6e7e1` 实测四格全绿，到 `4a97884` 已红；中间无任何片声称改动它，也无守护发现——只有真机跑才会暴露 |
| **N6** | a11y 仅 Relation 结果行做过 | M2 起的 backlog #11，挂了五个里程碑，另立专项 |
| **N7** | 路径栏未做 | 一层列表的返回路径是否够用，待实测证据再定 |

---

## §4.1 N1 查明：不存在「warm 比 cold 慢」，是重试睡眠随机落相

**调查日期** 2026-08-05，监工实测。**结论：M8 §0 表里那条「warm 是 cold 的 7 倍，
而首行反而更快」是我把一次抛硬币读成了规律**——两相谁慢是随机的，且首行完全不受影响。

### 机制（三步，逐步有直接证据）

1. `relationAllResultsMS` 的判据是 `root.children` 里不再有 `Loading…`
   （`CodeInsightApp.swift:4876-4882`），而 `Loading…` 由 `pendingQueryCount`
   控制（`RelationTreeModel.swift:648`）。启发式与根 Exact 两条查询并行，
   **所以这个量等于两者中慢的那条**——实测总是 Exact Call Hierarchy。
2. rust-analyzer 在 workspace 快照就绪前，对首次
   `textDocument/prepareCallHierarchy` **返回 `null`**。
   四处 parse 都把 `null` 转成 `nil`（`RustAnalyzerProvider.swift:901/946/1009/1023`）。
3. `request()` 把 **任何 `nil`** 一律当作「服务端没就绪」，
   按 `Double(attempt + 1)` 睡 **1 秒、再 2 秒** 后重试（`:556`、`:562`）。
   **多出来的那几秒是这个固定睡眠，不是 rust-analyzer 在算。**

### 证据一：trace 直接看到睡眠

`CAIRN_RA_TRACE=1` 探针（临时加在 `request()` 里，已撤回）打出的 cold 相：

```
[ratrace]        0.0 enter    textDocument/prepareCallHierarchy
[ratrace]        0.8 response textDocument/prepareCallHierarchy attempt=0
[ratrace]        0.9 emptyParse ...            ← RA 返回 null
[ratrace]        0.9 sleep    ... delay=1.0    ← 固定睡眠开始
[ratrace]     1003.2 lock     ... attempt=1
[ratrace]     2205.3 response ... attempt=1    ← 这次才是真活，1,202 ms
```

**2,205 ms 里 1,002 ms 是纯睡眠。**

### 证据二：改睡眠系数，多出来的秒数搬家（因果，非相关）

把重试延迟乘以 0.02（1s/2s → 20ms/40ms），其余不动。
语料：tokio 1.47.1 crate（154 条候选边，见下方口径说明）。

| 配置 | 样本 | cold 首行 | cold 全部 | warm 首行 | warm 全部 |
|---|---|---:|---:|---:|---:|
| **基线**（1s/2s） | 5 | 347–381 | **2,006–2,550** | 292–330 | **292–330** |
| **睡眠 ×0.02** | 3 | 358–372 | **404–438** | 297–343 | **1,458–1,708** |

三件事同时成立，才构成因果：

- cold 的多余秒数**消失**（2,006–2,550 → 404–438）
- `emptyParse` 次数**没减少**（反而变多）——说明改的是睡眠，不是 RA 的行为
- 那 ~1.2–1.4 秒的**真实首次开销守恒地搬到了 warm**（292–330 → 1,458–1,708）

**所以 M8 那次 warm=2,947ms 与本次 cold≈2,200ms 是同一件事的两种落法。**
1,000 + 2,000 = 3,000 ms 的睡眠上限，也正好解释 M8 的 2,947 ms。

### 代价必须说清楚：睡眠不是纯浪费

睡眠缩短后 cold 是快了，但**三次快速重试全部拿到 `null`，最终一条 exact 结果都没有**。
那 1 秒实际起的作用是「等服务端热起来」。
**所以修法不是删睡眠，而是换掉「靠盲睡猜就绪」这个机制**（见下）。

### 顺带查出的两条（本报告新增，不在原 §4）

- **`null` 与「没就绪」被混为一谈。** 光标停在真的没有调用层级/定义的位置时，
  也会走满 1s + 2s 才返回空。**用户为一个必然为空的结果等 3 秒。**
- **点结果行也踩同一个梯子。** 首次 trace 里，选中行触发的
  `textDocument/definition` 拿到 `null` → 睡 1 秒 → 重试，
  一直跑到 **6,564 ms**（测量早在 2,487 ms 结束）。
  **点一行之后 Context 可能空好几秒**，这是首行指标覆盖不到的用户可感延迟。

### 顺带复验：S2 的「睡眠移出锁」是真的

trace 里 `definition` 处于睡眠窗口（2,297→3,301 ms）期间，
`prepareCallHierarchy` 在 2,486 ms **拿到了 operationLock**。锁确实没被睡眠持有。

### 结论不受影响的部分

`relationFirstActionableMS` 在两种配置、8 次运行里始终是 **292–381 ms**。
**M8 §0 的首屏结论（360 ms、启发式先出）成立，不需要改。**

### 口径说明（不许当成同一语料）

M8 用的 tokio **workspace**（731 文件、215 条边）语料位于 `/private/tmp/...`，
**已被 macOS 临时目录清理器删除**（目录壳与 `.git` 均在，文件全空）。
本次改用 `~/.cargo/registry` 里的 **tokio 1.47.1 crate**（350 个 `.rs`、154 条边，
剥掉 dev-dependencies 后 `cargo metadata --offline` 通过，并 `git init`——
非 git 目录 RA 起不来）。**规模不同，绝对毫秒数不可与 M8 相减**；
但结论建立在 trace 与睡眠系数实验上，与语料规模无关。

> **教训（接 §5.1）**：M8 那条「warm 反常」是**两个样本**（cold 一次、warm 一次）
> 就写进报告的模式判断。§5.1 记了 3 次样本不足下结论，**这是第 4 次**，
> 而且它已经印在结论表里了。

### 建议的修法（未实施，待裁决）

| 方案 | 说明 |
|---|---|
| **A. 用服务端就绪信号取代盲睡** | rust-analyzer 有 `experimental/serverStatus` 与 workDoneProgress；就绪后再发首个请求，比睡 1 秒准确 |
| **B. 区分 `null` 与「没就绪」** | 只有 `-32801 content-modified` 才算没就绪；`null` 是合法的「这里没有」，直接返回空，不重试 |
| **C. 退避从小开始** | 首次重试 50–100 ms，指数退避到 1s 上限；总等待不变但常见情况快一个数量级 |

**B 最该先做**——它同时修掉「为必然为空的结果等 3 秒」这条独立缺陷。

**复现探针**：在 `RustAnalyzerProvider.request()` 的 `parse` 返回处、
`catch -32801` 处、`Thread.sleep` 前各加一行 stderr 打点，
用环境变量开关；把 `Double(attempt + 1)` 换成可乘系数即可重做上面的实验。

---

## §5 监工的过程失误（**给下一个里程碑的输入，不是自责清单**）

今天两类错误各犯了多次，值得当成模式来防：

### 5.1 样本不足就下结论（3 次，全部被更多数据推翻）

| 我的结论 | 当时样本 | 推翻它的数据 |
|---|---|---|
| "215 个 `Task.detached` 把协作线程池饿死" | 读代码推演，0 次采样 | 进程采样：瓶颈是 `operationLock` 串行 + **持锁 sleep** |
| "S1 引入了 flake" | 2/5 红 | 干净基线 + CPU 负载也红 20 条——是等待原语对负载敏感 |
| "S4 在负载下把套件挂住了" | 3 次挂起 | 后续 5 次 39–53s 完成，与基线同量级 |

**共同点：在 2–3 个样本时构建机制假说，然后当成事实往下传（包括写进派发词）。**

### 5.2 验收工具静默失败被当成结果（5 次）

`CodeInsightApp` vs `codeinsight-app`／`codeinsight-cli` vs `codeinsight`／
旧二进制未重建／zsh `noclobber` 假 `exit=1`／`head -14` 截掉自己的哨兵串／
正则 `tests passed` 不匹配 `tests in 1 suite passed`／Python 三引号嵌套导致探针没加上。

**共同点：读到了输出，但没读到"我的意图有没有生效"。** 其中最危险的一次给出**假绿**
（探针构建失败、跑的是旧二进制、报 `exit=0`）。

### 5.3 起了东西不管善后（多次）

`while :; do :; done` 死循环漏杀，两轮累积 **21 个**，`load average` 冲到 **86**；
后台任务留下空转 shell（1h18m、2h、2h37m 各一次，均由决策者先发现）。

**已修的两处流程**：
- 派发**不再管进 `tail`**（`tail` 要读到 EOF 才输出，导致 Codex 全程不可见）
- 完成判定**改盯 `[codex] Turn completed.` 标记**，不再等 wrapper 进程退出
  （之前多次一个多小时里，大部分是收尾空等）

---

## §6 结论

**M8 主线（Relations 的响应速度与认知负担）完成。**

同场景首屏从 **141.2 秒降到 360 毫秒**，启发式先出经真实 RA 证实；
切换符号不再累加等待；UI 从四档置信度收敛为两个来源词的行 badge；
两个存在多个里程碑的设计漂移被修正并写回文档。

**§4 的七项未解决已逐条列出，无一静默略过。**
