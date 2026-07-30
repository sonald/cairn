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
| **N1** | **warm 的 `relationAllResultsMS` = 2,947 ms**，是 cold（416 ms）的 7 倍，而首行反而更快（337 vs 360） | **真实现象，原因未查**。不影响首屏结论（用户感知量是首行），但需要单独查 |
| **N2** | 压测**三次挂起 183s** 未解释 | 停止时点与监工清理残留空转 shell 重合，但那些是 0% CPU，**建立不了因果**。后续 5 次全部 39–53s 完成 |
| **N3** | `real-references` **间歇** | 同一二进制第一次 `failed:references`，随后 3/3 `passed` |
| **N4** | 12 通道跑的仍是 `exact_fixture` | tokio 规模的测量要手工跑 `--self-test-relation-timing`，**未进自动化门禁** |
| **N5** | `real-implementations` 曾**静默坏掉** | M7-S6 在 `5a6e7e1` 实测四格全绿，到 `4a97884` 已红；中间无任何片声称改动它，也无守护发现——只有真机跑才会暴露 |
| **N6** | a11y 仅 Relation 结果行做过 | M2 起的 backlog #11，挂了五个里程碑，另立专项 |
| **N7** | 路径栏未做 | 一层列表的返回路径是否够用，待实测证据再定 |

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
