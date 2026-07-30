# M8 实现计划：Relations 的响应速度与认知负担（Planner: Opus，2026-07-29，v3）

> **版本沿革**
> - **v1** 被评审 BLOCKED，5 条阻塞项**监工逐条复核，全部成立**。
> - **v2 按阻塞项重写**。三处是我的实质错误，不是措辞问题：
>   1. **取消方案根本不成立**——我提的 `session.cancel()` 转发入口清不掉排队任务（§1.2）。
>      那几行代码我上一轮读过，没把 `cancelled = false` 和排队场景联系起来。
>   2. **cfg 排序不是小修**——索引里**根本没有 cfg 数据**（§1.3），照 v1 写会扩成
>      extractor/schema/cache/evaluator 改造。**已移出 M8。**
>   3. **v1 §3.2 自相矛盾**——一边说去掉 Probable 一边留 `Probable · direct`；
>      一边说不能靠"缺少 ✓"表达推断，一边让 Strong 只显示 dispatch。
>      **dispatch 描述调用方式，不描述可信度。**
> - **路径栏降级**：用户证据只支持"深树太复杂"，不支持新建 breadcrumb + 回跳 + 新环检测语义。
> - **v3 按第二轮评审的三条裁决修订**（`Likely`→`Inferred`、位置稳定契约、
>   默认 promotion fan-out = **0** 而非 ~6）。第三条监工已核代码确认：
>   `mergeExact`（`RelationTreeModel.swift:631-648`）**本就同时提供**
>   exact-only 行、同位置覆盖标记、未覆盖 heuristic 保留三种行为，
>   **所以默认视图根本不需要逐行 definition promotion**。

---

## §0 基线

**HEAD `8ba92f1`**，工作树干净。监工 2026-07-29 实测：`swift test` **383 全绿**
（3 次连跑 0/0/0）；`ci.sh` exit 0；`run-self-tests.sh` **pass=12 fail=0 hang=0**；
canonical dump 零 diff；双语料 gold nostrong=0；`goldset/` 零 diff；跑后孤儿 0。

**编排**：规划/派发词/验收/诊断/探针由 Opus 做；Codex 只接实现。每片不 commit。

---

## §1 已核实的事实基础

> 标注来源：**监工实测**＝我自己跑的；**另一 agent**＝我复核过代码但没自己复现时序；
> **评审**＝评审指出、监工已复核确认。

### 1.1 分钟级假死的成因

| 事实 | 来源 |
|---|---|
| `lock` 在 tokio 有 9 个定义、263 个 `.lock()` 调用点 | 监工实测 |
| 启发式 callers 返回 **215 条边**：possible 209 / probable 5 / strong 1 | 监工实测 |
| `promoteExactEdges` 对 `edges.prefix(500)` 逐条 Exact definition 校验，**无并发上限**，且**全部完成才替换 `Loading…`** | 监工核代码 `RelationTreeModel.swift:527` |
| RA `request()` **整个请求持 `operationLock`**，所有请求串行 | 监工核代码 `RustAnalyzerProvider.swift:441-442` |
| 空响应 / `content-modified` 时**持锁 `Thread.sleep` 1 秒、2 秒**重试 | 监工核代码 `:475-477` |
| 实测：6.8s / 39.8s 仍 `Loading…`，**141.2s 才结束**；采样 12 线程等锁，持锁线程在睡眠 | **另一 agent** |
| 二次（有缓存）仍 **>24 秒**，失败/未命中**不缓存** | **另一 agent** |

> **监工的判断错误（记录在案）**：我最初判断"协作线程池被 215 个 `Task.detached` 饿死"。
> **错了**——瓶颈是 `operationLock` 串行 + 持锁睡眠。我那条是读代码推的，
> 被进程采样推翻。

### 1.2 取消：v1 方案不成立（**评审阻塞项 1，监工已复核**）

```swift
private func request<Result>(...) throws -> Result? {
    operationLock.lock()
    defer { operationLock.unlock() }
    stateLock.lock()
    cancelled = false          // ← 拿到锁后第一件事就是清掉取消标志
    stateLock.unlock()
```

- `cancelOutstandingRequests()` 只能取消**已发出、有 request ID** 的请求
- 排队在 `operationLock` 上的 ~215 个任务**还没有 request ID**，够不着
- 它们轮到时**把 `cancelled` 清成 `false`** 继续跑

**所以 v1 §3.5「加一个 `session.cancel()` 转发入口」必然失效**，铁律⑫也必然不通过。

**正确契约见 §3.5：旧批次必须在「进入 RA 之前」就退出，而不是进去之后再取消。**

### 1.3 cfg 数据不存在（**评审阻塞项 3，监工已复核**）

| 事实 | 来源 |
|---|---|
| `DeclarationFacet` 无任何 cfg 字段 | 监工实测 |
| `grep -rn "cfg"`（排除 config）在 `CodeInsightCore` + `CodeInsightRustExtractor` **零命中** | 监工实测 |
| `AnalysisProfile` 无计算任意 `#[cfg(...)]` 是否激活的能力 | 评审，监工复核确认 |

**要做 cfg 感知排序 = extractor 抓属性 + schema 扩字段 + `extractorVersion` bump（废缓存）
+ 写 cfg evaluator。里程碑级，不是排序修复。已移出 M8。**

M8 用另一条路修正目标：**复用「确实属于本次 token」的已有选择 / RA Exact 结果**（§3.6）。

### 1.4 两种 Exact 查询不能混为一谈（**评审阻塞项 2**）

- **definition promotion**：对每条启发式边逐个校验 → 只能给已有行"盖章"
- **根符号的 Exact Call Hierarchy**：可能返回**启发式结果里根本没有的 caller**
  （`mergeExact` 的 `exactEdges + 未被覆盖的 heuristic edges` 结构即证）

**只做前者会漏掉 exact-only 结果。** 两者必须并行启动、独立合并。

### 1.5 分组是漂移，不是设计

| 来源 | 原文 |
|---|---|
| `docs/design.md` **F3.3（P0）** | "UI 主分组按 certainty（**Exact / Strong / Possible**……启发式结果不冒充编译器事实），dispatch 作为边标签" |
| `m2-plan.md:32` | "分组头**三段**……**probable 归 Possible 组**" |
| 今天实现 | `Strong`(:713) / `Probable`(:720) / `Possible`(:727) + Exact + External = **5 组** |

**漂了 5 个里程碑没被发现。**

### 1.6 `probable` 不只是显示层

引擎阈值 `certainty >= .probable`（`EngineSession.swift:234`、`:627`）；
gold `nostrong` 判违规用 `> .possible`（`GoldSet.swift:217`）。**内部枚举不动。**

### 1.7 首屏基线要重新测（**评审阻塞项 6，但数字要更正**）

监工实测的 CLI `callers lock` 2.662 秒**包含 `indexProject` 从零建索引**
（`CodeInsightCLI.swift:323`），**App 内索引是热的，所以 2.662 秒不是首屏下限**。

**评审的结论仍成立**：v1 的"2 秒"没定义计时起止，必须重定（§6⑪）。

---

## §2 本轮定位

> **用户点开 Callers，先看到可用结果再看到完整结果；等待不随符号热度爆炸；
> 切走要真的停下来；看到的东西不需要理解四档置信度。**

**明确不做**：cfg 感知（§1.3）、路径栏（§3.3）、TypeScript/Python、图视图、
类型关系、Rename、书签、`Certainty` 内部枚举删档。

---

## §3 设计裁决

### 3.1 首屏：两种查询并行，谁先完成谁先显示

1. **启发式查询**与**根符号 Exact Call Hierarchy** 同时启动（§1.4）
2. **谁先回谁先发布**——通常启发式先到
3. **Possible 默认折叠**成一行 `Show N possible matches`
4. **移除全量 definition 屏障**：不再"对所有启发式边逐一校验后才显示"

**默认路径的逐行 definition promotion＝0 条**（不是 v2 写的 ~6 条）。
理由：`mergeExact`（`:631-648`）本就同时提供 exact-only 行、同位置覆盖标记、
未覆盖 heuristic 保留——**根 Exact Call Hierarchy 已经够用**，
逐行 promotion 留到用户展开 Possible 后按需执行。

#### 位置稳定契约（**评审裁决，硬要求**）

- **已显示行不移动**
- Exact 命中已有行 → **原位升级**为 `Verified`
- exact-only 新行 → **追加末尾，不插入顶部**
- **首批发布后冻结顺序**，后续不因可信度变化重新排序
- 去重**复用现有 normalized `relationKey`**，不新增身份模型

**中间结果如何发布到 UI 必须显式定义**（评审阻塞项 2 后半）：
现有控制器只在整个 `loadTask` 完成后 reload。本片要定义**增量发布契约**——
哪些节点变更、如何避免整树 reload 导致选中/滚动位置丢失。

### 3.2 UI 只暴露两个来源词：`Verified` / `Inferred`（行 badge，不分组）

| 内部 | UI | tooltip |
|---|---|---|
| `exact` | **`Verified`** | Verified by rust-analyzer |
| `strong` | **`Inferred`** | Inferred from source structure |
| `probable` | **UI 完全不出现**，仅参与内部排序（排在 possible 前） | — |
| `possible` | 折叠在 `Show N possible matches` 里 | — |

**用来源语义，不用概率语义。** `Likely` 会被读成"也许对"从而低估 strong 的实际质量；
`High confidence` 之类又把内部置信度模型重新暴露出来。

**`Verified` / `Inferred` 是行 badge，不再形成两个分组。**
分组会随结果到达改变高度，进而扰动选中、滚动位置与辅助功能焦点；
badge 天然稳定，**不需要实现 scroll anchoring**。

- **`Probable` 字样从行副标签一并去掉**——留着等于没去掉（评审阻塞项 5）
- **dispatch 仍作边标签**（F3.3 要求），但它描述**调用方式**不描述可信度，
  **不能拿它替代可信度标注**
- 诚实红线：`Verified` 只给 exact；`Inferred` 是正向标签，
  **不靠"缺少 Verified"这个弱信号表达推断**

### 3.3 Call Tree 改为一层列表；**路径栏不做**

- 只展示当前根的**直接** Callers，列表扁平
- **复用现有的"点击换根"行为**，不新建 breadcrumb / 回跳 / 新环检测语义
- **路径栏推迟**：等一层列表实测证明"缺少返回路径"是真问题时再单独立项

**这仍然推翻 `docs/design.md` F3.1「逐层懒展开」与 F3.5 树内 `↻` 环检测**，
所以 §3.4 的文档同步照旧是硬交付——**只是改动范围比 v1 小**。

### 3.4 `docs/design.md` 同步修改是硬交付

Probable 那次漂移**不是"改了设计"的错，是"改了没写下来"的错**——
文档说三组、代码做五组，5 个里程碑无人发现。

S3 完成时 `design.md` 的 **F3.1**（改为一层 + 点击换根）、**F3.5**（环检测语义）、
**F3.3**（UI 词改为 Verified/Inferred，且**主分组模型从 certainty 分组改为行 badge +
单一折叠 Possible**）必须已改，并注明**由 M8 推翻、理由与日期**。
**只改代码不改文档 = 制造下一次漂移，本轮视为未完成。**

### 3.5 取消：旧批次必须在**进入 RA 之前**退出

**不是**加一个 `session.cancel()` 转发入口（§1.2 已证明无效）。契约是：

1. promotion 任务带**批次标识**（epoch / generation）
2. **在获取 `operationLock` 之前**校验批次；过期批次**直接退出，不发请求**
3. **限制 promotion 并发**，让排队长度本身可控
4. **重试的 `Thread.sleep` 移出持锁区**（v1 只写在红线里，v2 提升为切片内容）

**验收看的是"旧批次有没有进入 RA"**，不是"有没有调用 cancel"。

### 3.6 正确目标：token 匹配的候选复用（**不做 cfg**）

**不能直接用全局 `selectedCandidate`**（评审阻塞项 4）：
Context 在 `pinned` 状态会**故意保留旧 token**；用户也可能在另一个 token 上翻过候选。

**契约**：

> 只有当已有选择**确实属于本次右键的 token** 时才复用；否则**重新解析当前 token**。

必须覆盖三种情况的测试：**当前选择 / 过期选择 / pinned Context**。

---

## §4 切片（按评审建议重排：正确性优先）

| 片 | 内容 | 说明 |
|---|---|---|
| **S0** | **正确目标**：token 匹配的候选复用（§3.6）+ pinned/stale/current 三态测试 | 不含 cfg |
| **S1** | **快速首屏**：启发式与根 Exact 并行、先完成先发布、移除全量 definition 屏障、**默认逐行 promotion＝0**、**位置稳定契约**（§3.1） | |
| **S2** | **真取消**：promotion 批次门 + 并发上限 + **重试 sleep 移出锁**（§3.5） | **必须在 S4 之前**：S4 一展开就重新产生每批 20–50 个请求，不能先造 fan-out 再补取消；且与 S1 改的是同一条异步管线，拆远只会重复返工 |
| **S3** | **UX 收敛**：Verified / Inferred（行 badge）+ Possible 折叠 + 一层列表 + **同步改 design.md**（§3.2/3.3/3.4） | |
| **S4** | 展开 Possible 后分批校验（每批 20–50） | |
| **S5** | **真机验收**：计时口径见 §6⑪ | |

**路径栏不在本轮**；只有 S5 实测证明缺返回路径是真问题时才单独立项。

---

## §5 红线

- **不删 `Certainty` 内部枚举**（§1.6）
- **不做 cfg 感知**（§1.3）——发现需要时停下来报告，不要顺手扩
- **不改 `goldset/`**、不改 `Tests/RustExtractorTests/Fixtures/`
- **诚实红线**：`Verified` 只给 exact；`Inferred` 必须是正向标签；
  **dispatch 不得替代可信度标注**
- **不许用放宽超时 / 加重试 / 降并发掩盖延迟**
- **改了 design.md 才算完成 S3**
- 不改 `Prototypes/`；每片**不要 commit**

---

## §6 验收铁律

沿用 `m7-plan.md §6` 十条，追加三条：

- **⑪ 首屏时间口径**：**计时起点＝右键菜单动作，终点＝出现第一个可操作结果行**。
  **索引必须是热的**（`indexProject` 不计入——CLI 的 2.662 秒含建索引，不是下限，见 §1.7）。
  **warm / cold Exact 分别记录**。基线 141.2 秒（另一 agent 实测）。
- **⑫ 取消要证明"没进 RA"**：切走后**旧批次不得再获取 `operationLock` 或发出请求**。
  用请求计数或进程采样证明，**不许只断言调用了 cancel**。
- **⑬ 文档同步是可验收项**：S3 完成时 design.md 的 F3.1/F3.3/F3.5 必须已改并注明理由日期。

---

## §6.1 真机实测记录（监工，2026-07-30）

### 首屏计时（真实 rust-analyzer，`exact_fixture`，三次一致）

| | 首个可操作行 | 全部结果 | 首个来源 |
|---|---|---|---|
| **cold** | 85–95 ms | 98–132 ms | `heuristic` |
| **warm** | 32–34 ms | 43–46 ms | `heuristic` |

`relationFirstActionableKind` 三次都是 `heuristic`——**S1 的核心设计
（启发式先出、exact 后到升级）由真实 RA 证实**，不是 fake 推的。

> **这个数字不能对标 141.2 秒。** 埋点跑的是 `exact_fixture`（几个符号），
> 而 141 秒那次是 tokio 的 `lock`——**9 个定义、263 个调用点、215 条启发式边**，
> 差三个数量级。
>
> **现在能说的**：机制在小语料上被真实 RA 证实是渐进的。
> **不能说**：热符号不再假死。
>
> **S5 真机验收的必测项**：在 tokio 上对 `lock` 查 Callers 并按 §6⑪ 口径计时，
> 那才是与 141.2 秒等价的对照。

### 两条不稳定项

- **`real-references` 是间歇的**：同一个二进制，第一次 `failed:references`，
  随后 3/3 `passed`。真实 RA 偶尔在 45 秒内答不上来。
  **这格不稳定，不是"修好了"就完了**；S5 要多次跑并记录频率。
- **`real-implementations` 曾静默坏掉过**：M7-S6 报告在 `5a6e7e1` 实测四格全绿，
  但到 `4a97884` 时 implementations 已经红了（S1 的空 Exact 组消失所致）。
  **中间没有任何一片声称改动了它，也没有任何守护发现**——
  12 通道里只有 exact 一条会碰它，而它在 Codex 环境永远 skip。

## §7 第二轮评审的三条裁决（已并入正文）

| # | 裁决 | 落点 |
|---|---|---|
| 1 | `Likely` → **`Inferred`**，用来源语义不用概率语义 | §3.2 |
| 2 | **位置稳定**：追加末尾、原位升级、首批后冻结顺序、复用 `relationKey`；**badge 而非分组** | §3.1 |
| 3 | **默认 promotion fan-out ＝ 0**；S2 保持紧跟 S1，**最晚不得晚于 S4** | §3.1 / §4 |

**v3 无待确认项。** 评审确认后即可派 S0。
