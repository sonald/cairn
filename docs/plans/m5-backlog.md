# M5 Backlog（S7/S8 阶段记录，S9 收尾时汇总）

## 阻塞 S9 的 self-test 宿主缺陷（S8 验收时发现，优先级最高）

S9 要做「10 条通道双语料全家福连跑」，下面两条会让那件事无法自动化，**S9 开工前先解决**。

### ① 通道拿到不存在的文件时挂起，不报错退出

**复现**：`--self-test-open <不存在的文件>` → 进程打印 `NSCocoaErrorDomain Code=260`
后**不退出**，停在 `NSApplication.run()` 事件循环，CPU 0%，需外部 kill。

**危害（真实发生过）**：S8 验收时 orchestrator 一直用 `--self-test-open README.md`
跑通道，而**本仓库根目录没有 README.md**。表现时而"静默 exit 0"、时而挂起 30 分钟。
**S7 验收报告里那条 `--self-test-open → exit=0` 因此是无效的**（用真实文件
`Sources/CodeInsightAppModel/SearchPanelModel.swift` 重跑确认 exit 0、首屏 45.8ms，
S7 代码本身没问题，但当时那次验收没真正覆盖该通道）。

**修法方向**：fixture/输入不可用时走 `finish(checks:metrics:error:)` 那条已有的
错误退出路径，**绝不能落进事件循环**。所有通道的入口参数校验都该复查一遍。

### ② 通道在 shell 循环里间歇挂起，逐条单发正常（根因未明）

**现象**：把多条通道写进 `for ch in ...; do ... done` 循环连跑，会间歇卡在某一条
（观察到 exact / open / project / switch 各卡过一次），栈里**没有** self-test 逻辑，
纯粹停在 `NSApplication.run()`，CPU 0%、无子进程。**同一条命令单独发出去则必定正常退出。**

**已排除的假设（都做了对照实验）**：
- stdin 非 tty（`< /dev/null` 单跑 → 正常退出）
- 输出重定向到 /dev/null（单跑 → 正常退出）
- 连续运行状态污染（project 连跑 3 次 → 3 次都 exit 0）

**诚实标注：根因未明，orchestrator 复现不出稳定触发条件**（按 §6 铁律⑧，复现不了
就不假装知道）。当前 workaround 是**逐条单发**，11 次执行全部 exit 0。

**为什么必须查**：S9 的全家福连跑正是"循环里跑多条"这个形态，不解决就只能手工逐条发。
建议方向：查 self-test 结束时的退出路径（是否所有分支都调到了 `exit`/`finish`），
以及前一个进程的 WindowServer 连接释放是否影响下一个进程启动。

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
