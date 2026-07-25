# M5 Backlog（S7/S8 阶段记录，S9 收尾时汇总）

## self-test 通道在批量连跑时间歇挂起（S8 验收观察到，根因未明）

**现象**：把多条通道写进 shell `for` 循环连跑时，会间歇卡在某一条（观察到
exact 26min / open 30min / project 31min / switch 各卡过一次）。挂起进程的
`sample` 栈里**没有** self-test 逻辑，纯粹停在 `NSApplication.run()` 事件循环，
CPU 0%、无子进程——即 self-test 逻辑已跑完但进程未退出。

**同一条命令逐条单独发出去则正常退出**：S8 验收最终用逐条单发的方式，
10 条通道 + project 双语料共 11 次执行全部 exit 0。

**已做的对照实验（全部未能复现挂起）**：

| 假设 | 实验 | 结果 |
|---|---|---|
| 输入文件不存在导致不退出 | `--self-test-open /nonexistent-xyz.md` | **exit=1 立即退出**（catch 分支有 `Darwin.exit(1)`） |
| 同上（相对路径） | `--self-test-open README.md`（本仓库无此文件） | **exit=1 立即退出** |
| stdin 非 tty | `< /dev/null` 单跑 | 正常退出 |
| 输出重定向到 /dev/null | 单跑 | 正常退出 |
| 连续运行状态污染 | project 连跑 3 次 | 3 次全 exit 0 |
| 背靠背启动 | reading 跑完立刻跑 open | 两条都 exit 0 |

**诚实标注：根因未明。orchestrator 复现不出稳定触发条件**（§6 铁律⑧：复现不了
就如实报告，不假装知道）。**不要基于猜测的根因去改代码**——先要有稳定复现。

**一个尚未证实的观察**：`runSelfTest` / `runProjectSelfTest` / `runOpenSelfTest`
的签名是 `-> ()`，其余通道（tabs/reading/diff/history/pin/exact/switch）都是
`-> Never`。但上面的实验显示 open 在错误路径上能正常退出，**所以简单归因于签名
是不成立的**，仅作为起点记录。

**对 S9 的影响**：S9 的「10 条通道双语料全家福连跑」正是"循环里跑多条"这个形态。
在根因查明前，S9 应**以逐条单发为准**产出结果，并把这个限制在交互测试计划里如实标注。

## 一次无效验收的纠正（流程教训）

S7 验收报告中的 `--self-test-open → exit=0` **是无效数据**：当时喂的是
`README.md`，而本仓库根目录没有该文件。用真实文件
（`Sources/CodeInsightAppModel/SearchPanelModel.swift`）重跑确认 **exit 0、
首屏 45.8ms、styledFragments=87**——S7 代码本身没问题，但那次验收没有真正覆盖该通道。

**教训**：验收工具本身也要验。跑通道前先确认参数指向的文件/目录真实存在，
否则"绿"可能来自没跑到被测路径。

**注**：最初把这个现象写成"通道拿到不存在的文件会挂起"，后经实验证伪——
文件不存在时 open 是 `exit=1` 立即退出的。挂起是另一回事（见上一节）。

## 已确认的既有缺陷（非本轮引入，结转）

### `--self-test-pin` harness 竞态：等模型层就断言视图可见性

**现象**：`--self-test-pin .` 间歇失败，失败率随环境负载波动。

**实测归属（S7 验收时用 S6/S7 二进制在同一真仓库交替采样）**：

| 采样 | S6 `137a0bf` | S7（工作树） |
|---|---|---|
| 独立 20 次 | 6/20 红 | 0/20 红 |
| 复核 20 次 | — | 0/20 红 |
| 交替 15 轮（消除负载偏差） | 2/15 红 | 0/15 红 |

**根因**：`CodeInsightApp.swift:1444` 的 `waitUntil` 只等模型层
`pinContextSummary != nil`，但紧接着 `:1452` 断言的是**视图可见状态**
（`selfTestContextPlaceholderVisible` / `selfTestContextReaderVisible`）。
模型数据到位与视图完成布局之间没有同步点，窗口调度慢时抓到中间态。

**为什么 S7 是 0/20 —— 这是巧合掩盖，不是修复**：S7 新增的 ruler / 当前行
渲染让视图多走一次布局，恰好盖住了那个竞态窗口。**根因仍在**，渲染路径一变
就会复现。

**修法方向**：`waitUntil` 的条件应包含视图可见状态本身，而不是只等模型层数据。

**注意**：验证此项时**不能**用 `git archive` 导出的副本跑 `--self-test-pin`
——该通道需要真 git 仓库建 fixture 提交，副本无 `.git` 会一律报
`expected a.rs, b.rs, and main.rs fixture symbols`（20/20 假失败）。正确做法是
**用旧版本的二进制在真仓库里跑**。

### 巨档 footprint 绝对值超 100MB 预算（TextKit 2 基线，M5 之前既存）

**实测**：10 万行档 base footprint ~210–255MB，远超 100MB 预算。

**归属**：S6 `137a0bf` 上已存在（Codex 用 `git archive` 建净副本对照：S6 中位数
210.977MB vs S7 215.431MB）。**不是 S7 引入**。

**S7 增量不可测**：真机连跑三次的增量稳定在 **−27.9MB**（负值），因为测量区间被
TextKit 缓存回收/替换主导，`phys_footprint` 的进程净变化无法归因成 S7 增量。
原先的 `hugeS7IncrementUnderTenMB` 门因此是**恒真断言（假安全网）**，S7 收尾时
已删除，改为 metric-only 输出并在 `CodeInsightApp.swift:989` 标注。

**遗留**：巨档内存本身该不该治、怎么治，留 S9 决策。若要治，先解决"如何测出可归因
的增量"这个前置问题。

## 交互测试待人工目视（S7 部分，无头不可证）

- 巨档滚动帧率手感（行号绘制在滚动热路径上）
- 三主题下行号 / 当前行 / 同名高亮配色观感
- 声明 gutter 标记密度是否干扰阅读
- 同名高亮与 diff / 查找闪烁同屏时的视觉层级
- 点击、空白清除、Esc 清除的真实窗口手感

## M6 候选结转（S9 汇总，只挂账不预实现）

- **Exact 能力面**：references / implementations / callHierarchy。
- **SI Reference Styles**：与 exact references 共用语义引用数据后再做，不先造半套索引。
- **F5.7 书签**：需先裁决快照保留与历史回放语义。
- **Relation Window 随光标自动跟踪**。
- **RA 进程组化**：从直接子进程守卫扩到孙进程/进程组的生命周期治理。
- **AX 值变更防御**。
- **huge `syntaxVisible` 属性重排**：先建立可归因探针，再动 TextKit 热路径。
- **分支图**。
- **F4.8 lineage**：重命名/跨 commit 谱系，不用启发式冒充确定关系。
- **依赖全量浏览/搜索**：M5 只交付依赖落点与只读打开。
- **`sandbox-exec` 迁移**：保留 Safe 的 deny-network/只读边界。
- **Cmd+± 字号**：先拆 `settingsWindowController` 缓存地雷再接快捷键。
- **TS/Python 整语言面**：作为完整语言支持切片规划，不零散铺面。
