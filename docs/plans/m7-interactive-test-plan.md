# Cairn (CodeInsight) M7 交互测试规格

**基线**：`5a6e7e1`（S6 总验收），`swift test` 381 全绿、12 通道 PASS。
**沿用** M5/M6 的执行与报告格式。

## 为什么还要人来跑

M7 的自动化已经跑满：381 测试、12 通道、四方向真实 rust-analyzer LSP 往返、
双语料 gold、canonical dump 零 diff。**但下面三件事自动化做不到**：

1. **手感与帧率**——S6 §7 的 B3、N1 明确留给人判断，禁止用 fragment 数或延迟数字替代。
2. **"绿但看不见"**——M7 期间决策者报的两个真机缺陷（右键菜单四方向全废、
   Follow 只响应一次），发生时**通道全绿、测试全绿**。存在性断言证明不了可见性。
3. **可读性**——provenance 标注与计数文案，机器只能断言字符串存在，
   判断不了"用户能不能看懂"。

**所以本轮的重点不是"再验一遍功能"，而是验自动化结构性覆盖不到的那部分。**

---

## 前置条件

```sh
cd /Users/siancao/work/ai/vibecoding/codeinsight
swift build -c release
swift run -c release codeinsight-app
```

- 窗口至少 **1600×1000**；三主题各过一遍：Auto/Light、Dark、SI Classic。
- **开测前先记录环境**（G6.1 的教训：环境不全会把 BLOCKED 误记成 FAIL）：
  RA 版本、trust mode、当前 feature profile、`CARGO_NET_OFFLINE`、
  `rust-src` 是否齐全、语料绝对路径。

### 语料可用性（**执行前已实测，不要临场再猜**）

| 语料 | `.git` | `cargo metadata` | 真实 RA | 可用于 |
|---|---|---|---|---|
| **tokio 1.47.1** | ✅ `046852f`，731 文件 | ✅ exit 0 | ✅ 可用 | **全部分组** |
| ripgrep 14.1.1 | ❌ 无 | ❌ exit 101（10 个子 crate 全缺 `Cargo.toml`） | ❌ 不可用 | **只能验 Fuzzy 与纯阅读**；Exact 相关项一律记 BLOCKED |

本机实测：`rust-analyzer 0.0.0 (12c3381f0b 2026-07-26)`、
`rust-src` 在 `1.87.0-aarch64-apple-darwin` 下齐全。

语料根：
`/private/tmp/claude-501/-Users-siancao-work-ai-vibecoding-codeinsight/07b4a1d2-8dd6-49a2-b70b-f8f19bfd9226/scratchpad/corpora/`

### 锚点（**均已实测存在，行号可直接跳**）

| 用途 | 位置 | 事实 |
|---|---|---|
| **Follow 更新回归** | `tokio/src/runtime/task/harness.rs:420` `fn can_read_output` | **恰好两个 caller，且都在同一文件**：`:133` `try_set_join_waker`、`:281` `try_read_output`。这正是决策者报缺陷时的现场 |
| callers / calls | `harness.rs:153` `pub(super) fn poll(self)` | |
| **引用但不是调用** | `tokio/src/runtime/task/core.rs:159` `pub(crate) struct Header` | **具名字段结构体，实测零个 `Header(` 构造调用**，因此不可调用；类型位置密集：`core.rs:164` `NonNull<Header>`、`:194` `Pointers<Header>`、`:269` `&Header` |
| ~~Notified~~（**首轮用错，勿再用**） | `task/mod.rs:247` `struct Notified<S>(Task<S>)` | **元组结构体，构造函数本身可调用**（`harness.rs:161`、`raw.rs:334`、`mod.rs:349` 都是真实构造点）。首轮把它当"不可调用符号"是规格错误 |
| implementations | `task/mod.rs:298` `pub(crate) trait Schedule` | 真 impl：`scheduler/current_thread/mod.rs:637`、`tests/task.rs:455` |
| 大结果规模 | `Tests/Fixtures/m6_reference_density.rust` | 100,000 行 / 20,000 binding / 35,000 引用。**只用于观感与工作量，不替代真实 RA** |

---

## 判定规则

- **PASS**：观察到期望现象，且**现象是可证伪的**（写下具体看到了什么，不是"正常"）。
- **FAIL**：观察到与期望不符。**必须记下复现步骤**。
- **BLOCKED**：前置不满足（RA skip、语料缺依赖、功能未实现）。
  **BLOCKED 不是 PASS**，不得混入通过率。
- **"看起来对" / "没发现问题"不是结果。** 每项都要写下实际看到的东西。

### 已知限制白名单（记录现象，不算 FAIL）

- ripgrep 语料的 Exact 全部不可用（见上表）——记 BLOCKED。
- Safe 模式禁用 build script 与 proc macro，相关 crate 覆盖可能 partial。
- 依赖源码只来自本地 Cargo 缓存；**Trusted 不会下载任何东西**，
  不要把"需要 Trusted"写成获取依赖的手段。
- **a11y 不在本轮范围。** 全仓库唯一被设计并验收过的 AX 只有 Relation 结果行
  （M7-S5A，`RelationWindowController:737/846-847`）；阅读区、大纲、搜索面板、
  设置窗从未做过 AX——这是 **M2 起挂了五个里程碑的 backlog #11**，
  将由独立专项处理。**本轮不测 VoiceOver，相关问题不记 M7 FAIL。**

---

## H1 入口：右键四方向（**决策者报过的缺陷 #1 的回归**）

> **为什么在这里**：自动化只能驱动 `textView.menu(for: event)`，
> 驱动不了真实弹出菜单。当初的缺陷正是 `NSTextView` 合并菜单导致
> `menuNeedsUpdate` 从不触发，**四个方向一起废**，而单测全绿。

在 `harness.rs:153` 的 `poll` 上右键：

| # | 操作 | 期望的可证伪观察 |
|---|---|---|
| H1.1 | 右键 → Show Callers | 菜单弹出且**能看到四项** Callers/Calls/Implements/References；点 Callers 后 Relation 面板**出现结果行**（写下第一行文本） |
| H1.2 | 同上 → Show Calls | 出结果，写下第一行 |
| H1.3 | 同上 → Show Implements | 出结果或**可区分的空态文案**（写下原文） |
| H1.4 | 同上 → Show References | 出结果，写下第一行 |
| H1.5 | **只读铁律** | 右键菜单中**不得出现任何编辑项**（Cut / Paste / 输入相关）。逐项扫一遍菜单，写下看到的全部菜单项 |
| H1.6 | 多标签 | 开两个 tab，切到第二个后右键，**结果对应当前 tab 的文件**（写下文件名） |

## H2 消费：点击结果行（**决策者报过的缺陷 #2 的回归**）

> **为什么在这里**：当初 Follow 只响应第一次。自动化现在有断言，
> 但这条路是"人点出来的",要人再走一遍。
> 锚点选的就是当时的现场：`can_read_output` 的两个 caller 都在 `harness.rs`。

对 `harness.rs:420` 的 `can_read_output` 查 Callers：

| # | 操作 | 期望的可证伪观察 |
|---|---|---|
| H2.1 | 点第一个 caller 行 | 底部 Context 显示 `try_set_join_waker` 相关内容（写下 Context 里的符号名与位置） |
| H2.2 | **接着点第二个 caller 行** | Context **变成** `try_read_output`（写下变化后的内容）。**没变 = FAIL** |
| H2.3 | 来回点两次 | 每次都跟着变，**不是只有第一次** |
| H2.4 | 切到 References 方向，点某一结果行 | **阅读区跳到该引用位置**（写下跳到的文件:行）。位置行是单击即跳 |
| H2.5 | 连点两个不同 reference 行 | 阅读区**每次都跳**，落点不同 |
| H2.6 | H2.4 之后按返回 | 回到原位置（写下回到哪里） |
| H2.7 | Pin 住 Context 后再点 reference 行 | **阅读区仍跳、Context 不动**——两件事都要确认 |
| H2.8 | 点 callers/calls/implements 的**符号行** | 阅读区**不跳**，只有 Context 变（这是规则边界，跳了反而是 FAIL） |

## H3 References ≠ Callers（**S3/S4 存在的理由**）

> **为什么在这里**：最容易退化成"Callers 的别名"。要用**类型位置**证明
> References 覆盖了 Call Hierarchy 覆盖不到的东西。

对 `task/core.rs:159` 的 `struct Header` 操作（**首轮用的 `Notified` 是元组结构体、
构造函数可调用，那是规格错误，已换锚点**）：

| # | 操作 | 期望的可证伪观察 |
|---|---|---|
| H3.1 | 查 References | 结果**包含类型位置**，例如 `core.rs:164` `NonNull<Header>`、`:194` `Pointers<Header>`、`:269` `&Header`。**写下至少两条** |
| H3.2 | 对同一符号查 Callers | `Header` 无构造调用，**期望空或"不是可调用符号"文案**（写下原文） |
| H3.3 | **两个结果集必须不同** | 把 H3.1 与 H3.2 的结果对比。**若相同 → FAIL，References 退化成 Callers 的别名** |
| H3.4 | 注释/字符串不得混入 | 浏览结果，确认没把注释或字符串里的 `Header` 当引用 |

## H4 Exact / Fuzzy 并置与来源可读性

| # | 操作 | 期望的可证伪观察 |
|---|---|---|
| H4.1 | 在 tokio 上查 References（Exact 就绪） | 面板出现 **Exact 组** 与 **References 组**两组，写下两组的标题原文与各自行数 |
| H4.2 | 找一条同位置双命中的行 | 标注为 `Exact · heuristic also matched`（写下原文）。**光看到"Exact"不够，要能看出两条证据链都命中** |
| H4.3 | 只 Fuzzy 命中的行 | **仍在结果里**，没被 Exact 顶掉 |
| H4.4 | 切到 Safe 且 Exact 不可用的情形 | Fuzzy 结果照常呈现；空态文案**可区分**（写下原文，不能是笼统的 `Exact (0)`） |
| H4.5 | **可读性主观判断** | 你能否只看面板就说出"这条结果是怎么来的"？**说不出来就记 FAIL 并写下卡在哪** |

## H5 计数四态的诚实性

| # | 操作 | 期望的可证伪观察 |
|---|---|---|
| H5.1 | 小结果 | 组副标题 `N references`，**N 等于该组实际行数**（数一下） |
| H5.2 | 超显示上限 | `Showing first 500 of M references`（写下原文） |
| H5.3 | 服务截断 | **看 References 面板内最后一行的橙色 footer**，不是窗口状态栏。状态栏那个 `Results truncated` 是另一个控件（`MainWindowController:56`），**不要拿它当本项证据**。footer 应为 `N verified references · partial` |
| H5.4 | Exact + Fuzzy 混合时 | **两组各自的数字都等于自己的行数**，没有一个组标着跨组总和（这是 S4-Fix 修的，回归重点） |

## H6 规模与手感（**S6 §7 N1 / B3，机器判不了**）

| # | 操作 | 期望的可证伪观察 |
|---|---|---|
| H6.1 | 对 tokio 里一个热门符号查 References | **首批结果多久出现**？自动化实测 2,500ms（形态像撞时间预算）。**你的体感是"可接受"还是"卡"**——写下判断 |
| H6.2 | 结果出现过程中滚动面板 | 是否掉帧、是否卡顿。**禁止用 fragment 数替代目视** |
| H6.3 | 大文件滚动 | **注意：文件树按 `pathExtension == "rs"` 过滤（`AppModel.swift:183`），`.rust` 后缀在树里看不见——这是设计，不是缺陷。** 先 `mkdir -p /tmp/bigfile/src && cp Tests/Fixtures/m6_reference_density.rust /tmp/bigfile/src/big.rs`，再把 `/tmp/bigfile` 当项目打开。滚动是否顺滑；语义引用样式是否只作用于视口内 |
| H6.4 | 大结果出现中途切换方向 | 旧结果**不得继续流入**面板 |
| H6.5 | 连续操作 10 分钟后 | 是否变慢、内存是否明显上涨（自动化只挡得住粗大回归，见 S6 §7 N2） |

## H7 S5B 视觉设置的粒度（**新功能首次人验**）

打开设置窗，四个新控件：参数引用 alpha、声明标记 alpha、函数名/声明标题字重、声明强调字重。

| # | 操作 | 期望的可证伪观察 |
|---|---|---|
| H7.1 | 不动任何设置，对比印象 | **观感与升级前一致**（自动化已逐字节验过，这里只需你确认没有"说不上哪里怪" ） |
| H7.2 | 逐项拖动 | 阅读区**立即重绘**，看得出变化（写下每项改动后你看到什么变了） |
| H7.3 | 关掉 App 重开 | 设置**保留** |
| H7.4 | **粒度判断** | 这四项是不是你想要的旋钮？**缺哪个、哪个没用**——直接写下来，这是本项的主要产出 |
| H7.5 | 三主题各看一遍 | 在 Dark 与 SI Classic 下这些值是否仍合适 |

## H9 语境交叉抽验

| # | 操作 | 期望的可证伪观察 |
|---|---|---|
| H9.1 | 切到历史 commit 快照后查 References | **要求只有"仍能出结果"**（计划 §S3 原文：Safe / offline / 历史快照三种场景各验）。行内是否带快照标注**目前不是需求**——若你觉得缺了会误导，写进建议，不记 FAIL |
| H9.2 | Safe → Trusted 切换后重查 | 结果或覆盖度**如实变化**，标注同步更新（写下切换前后的标注原文） |
| H9.3 | 在 ripgrep 语料上查 References | Exact 记 **BLOCKED**（`cargo metadata` exit 101）；**Fuzzy 应仍有结果**——这是 Fuzzy 存在的理由 |

---

## 报告格式

每项写三行：**操作 / 实际看到什么 / PASS·FAIL·BLOCKED**。

结尾必须给出：

1. **FAIL 清单**（含复现步骤）——这是本轮最有价值的产出
2. **BLOCKED 清单**（含原因）——**不得并入通过率**
3. **H4.5、H6.1、H7.4 三条主观判断的结论**——它们本来就没有机器答案
4. 环境记录（RA 版本、trust mode、profile、语料路径）

> **写给执行者的一句话**：M7 期间两个真机缺陷都是在"全绿"状态下被人点出来的。
> **本轮的价值与发现的问题数成正比，跟通过率无关。**
