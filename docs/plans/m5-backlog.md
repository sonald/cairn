# M5 Backlog（S7 阶段记录，S9 收尾时汇总）

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
