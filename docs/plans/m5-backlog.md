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

**M6-S0 workaround（根因仍未明）**：所有 self-test 退出路径现在先向 stderr 写
`SELF_TEST_FINISH timestamp=… pid=… channel=… exit=…`，再保持原有
`Darwin.exit` 行为；若再次挂起，可区分"未到 finish"与"finish 后进程未退"。
`scripts/run-self-tests.sh` 用显式列出的独立进程、每条 90 秒超时、挂起时 `sample`
和结果聚合替代 shell `for` 循环。M6-S0 验收的 11 个通道（project 分 git /
非 git 两次，共 12 个独立进程）为 **12 PASS / 0 FAIL / 0 HANG**；这只证明
workaround 可用，不把一次未挂起误报成根因已解。

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

**M6-S0 已清算**：未加干预的 S6 `137a0bf` 本轮 0/30 红，不能作为修复证据；
在临时 S6 构建中仅给 Context candidate render 加 100ms 调度延迟后，原条件
稳定为 **30/30 红**，且均为 `contextPlaceholderHiddenWithContent=false`。
只把 wait 条件补成"模型数据已到 × placeholder 隐藏 × reader 可见"，同一延迟下
变为 **0/30 红（30/30 绿）**。调度延迟只存在于临时复现构建，没有进入工作树。

### 巨档 footprint 绝对值超 100MB 预算（TextKit 2 基线，M5 之前既存）

**实测**：10 万行档 base footprint ~210–255MB，远超 100MB 预算。

**归属**：S6 `137a0bf` 上已存在（Codex 用 `git archive` 建净副本对照：S6 中位数
210.977MB vs S7 215.431MB）。**不是 S7 引入**。

**S7 增量不可测**：真机连跑三次的增量稳定在 **−27.9MB**（负值），因为测量区间被
TextKit 缓存回收/替换主导，`phys_footprint` 的进程净变化无法归因成 S7 增量。
原先的 `hugeS7IncrementUnderTenMB` 门因此是**恒真断言（假安全网）**，S7 收尾时
已删除，改为 metric-only 输出并在 `runReadingSelfTest` 的巨档测量段标注。

**M7 候选**：巨档绝对 footprint 超 100MB 正式转入 M7 候选，不再作为 M5/M6
pass/fail 门。进入预算或优化前，必须先解决"如何得到可归因的 baseline / after /
delta"这一测量方法学；方法学未成立前只输出三个原始 metric。

## 交互测试待人工目视（S7 部分，无头不可证）

- 巨档滚动帧率手感（行号绘制在滚动热路径上）
- 三主题下行号 / 当前行 / 同名高亮配色观感
- 声明 gutter 标记密度是否干扰阅读
- 同名高亮与 diff / 查找闪烁同屏时的视觉层级
- 点击、空白清除、Esc 清除的真实窗口手感

## M6 期间新记（2026-07-28）

### 【真缺陷，已定位根因】点击定位到整个调用表达式而非被点 token

**决策者报告的三个现象，同一个根因**：
1. 点 `Config::set(...)` 里的 `Config`，Context 显示的是 `set` 的定义
2. 同一行有多个符号时，点第二个符号 Context 不更新
3. 同名高亮延迟约 1 秒才出现（此条根因未明，见下）

**根因（监工实测坐实）**：`RustCalls.swift:43` 提取 call 时
`range: node.coreByteRange(...)` 的 `node` 是**整个 `call_expression` 节点**
（含 callee、参数、括号），不是函数名 token。探针实测：

```
click=Config     text=[Config::set(ConfigKey::Backend, 1)]
click=set        text=[Config::set(ConfigKey::Backend, 1)]
click=ConfigKey  text=[Config::set(ConfigKey::Backend, 1)]
```

于是 `Resolver.swift:195` 的 `call.range.contains(offset)` 让**行内任何位置都命中
同一个 call**，而该 call 的 `nameID` 是被调函数名 → 现象 1。

现象 2 叠加了 `ContextWindowModel.swift:255` 的早退：
`locatedToken.range.contains(token.offset)` 认为"还是同一个 token"直接返回旧结果，
连查都不查。第一次点把 range 记成整个表达式，第二次点必然落在里面。

**影响面**：Context 窗口在所有含调用的行上给的都是被调函数信息，与点了哪个词无关。
M1 起就存在，一直没暴露是因为用户习惯点函数名。

**修法方向**：`UnresolvedCall` 需要区分"调用表达式 range"与"函数名 token range"
（后者用于点击命中判定）。注意这会改 ContentIndex 语义，**需 bump extractorVersion
并走完整 determinism 验收**（canonical dump 会变）。

**现象 3（高亮延迟）根因未明**：`activate` 是同步调用（`CodeInsightReaderUI.swift:358`），
理论上应立即。可能与 Context 查询争抢主线程有关，**但无证据，不猜**。修现象 1/2 后
应重新观察是否自愈。

### 【功能需求】视觉调整项可配置

决策者 2026-07-28 提出：M5/M6 加的这些视觉调整应当可配置，而非硬编码。
当前散落的硬编码值包括但不限于：
- M6-S6 引用样式的 param alpha（`0.72`）
- M5-S6 声明分级的 `functionNameDelta`、二级 semibold 规格
- M5-S7 行号/当前行/同名高亮的配色与开关粒度

**建议**：统一收进 `ReaderSettings` + Settings 窗口的 Reading 页，
而不是每次微调都改代码。做之前先盘点全部硬编码视觉常量，避免只做一半。

## M6 候选结转（S9 汇总，只挂账不预实现）

- **Exact 能力面**：references / implementations / callHierarchy。
- **SI Reference Styles**：与 exact references 共用语义引用数据后再做，不先造半套索引。
- **F5.7 书签**：需先裁决快照保留与历史回放语义。
- **Relation Window 随光标自动跟踪**。
- **RA 进程组化**：从直接子进程守卫扩到孙进程/进程组的生命周期治理。
- **AX 值变更防御**。
- **M7 候选：huge `syntaxVisible` / 绝对 footprint**：先建立可归因测量方法，
  再谈预算或改 TextKit 热路径。
- **分支图**。
- **F4.8 lineage**：重命名/跨 commit 谱系，不用启发式冒充确定关系。
- **依赖全量浏览/搜索**：M5 只交付依赖落点与只读打开。
- **`sandbox-exec` 迁移**：保留 Safe 的 deny-network/只读边界。
- **Cmd+± 字号**：先拆 `settingsWindowController` 缓存地雷再接快捷键。
- **TS/Python 整语言面**：作为完整语言支持切片规划，不零散铺面。
