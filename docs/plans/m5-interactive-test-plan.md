# Cairn (CodeInsight) M5 交互测试规格（供 UI 自动化工具/人工执行）

版本：对应 M5 S1–S9 完成工作树，基线 commit `fcb9ee7`。沿用 M4 的执行与报告格式。
本轮聚焦 feature profile、依赖落点、多标签、SI 式声明排版、阅读区基础设施和
SearchPanel cap。帧率、闪烁、行高与视觉层级只由真机目验，不用无头数字替代。

## 前置条件

```sh
cd /Users/siancao/work/ai/vibecoding/codeinsight
swift build -c release
swift run -c release codeinsight-app
```

- 真机需安装 `rust-analyzer`；依赖源码跳转还需对应 crate 源码或 `rust-src` 已在本机可用。
  缺失时 S2/S4 的真实 exact 项记 BLOCKED，fuzzy、UI 与只读路径仍须测试。
- 语料：tokio 1.47.1 与 ripgrep 14.1.1。用当前机器上的真实目录，不用 self-test fixture
  代替真机 RA。
- 三主题均测试：Auto/Light、Dark、SI Classic；窗口至少放大到 1600×1000。
- 巨档锚点：建立一个含 100,000 行的 Rust 文件，前 200 行各含同名标识符 `needle`，
  其余为空行；把它放进临时 Cargo 项目后由 Cairn 打开。

## 测试锚点（已核实）

- **feature 锚点**：`tokio/Cargo.toml:24` 的 `[features]`；默认 feature 为空，
  `full`、`net`、`rt-multi-thread` 等可用于观察 default/all/no-default 三档差异。
- **调用/依赖锚点**：`tokio/src/runtime/task/harness.rs:153` 的
  `pub(super) fn poll(self)`，以及同文件 `:535` 的 `guard.core.poll(cx)`；在真实 RA
  可用时从 `Future`、`Context`、`Poll` 等标准库类型跳依赖源码。
- **ASCII 图注释锚点**：`tokio/src/runtime/time/entry.rs:524-535` 的 `+---+` 表格；
  Unicode 树形注释锚点为 `tokio/src/runtime/handle.rs:489-497`。
- **大文件锚点**：`ripgrep/crates/core/flags/defs.rs`（约 7,675 行）和上述 100,000 行
  临时文件。
- **Compare 锚点**：CodeInsight 本仓任一相对 `HEAD~1` 有变化的 Rust/Swift 文件；
  用于验证 tab strip 与 Compare 分屏共存，以及同名高亮与 diff gutter 的视觉层级。

## 已知限制白名单（不算 FAIL，记录现象）

- **K-M5-1 同名高亮是词法匹配，不是语义引用**：会匹配同名标识符，但不承诺引用关系；
  语义版留 M6 的 Reference Styles + exact references。
- **K-M5-2 巨档 footprint 绝对值超 100MB**：这是 S6 之前已存在的 TextKit 2 基线；
  记录实值，不把它归因于 S7，也不放宽其它内存门。
- **K-M5-3 self-test 通道批量连跑会间歇挂起**：根因未明；当前只认可逐条单发结果，
  不基于猜测修复，详见 `m5-backlog.md`。
- **K-M5-4 `--self-test-pin` harness 有竞态**：S6 上曾 6/20 红，S7 的额外布局只是在
  当前样本中掩盖窗口；人工 Pin 产品行为仍须验证。
- **K-M5-5 workspace 多成员只展示 unit，不切 unit**：S2 本轮只切 feature 三档；
  不把 unit 标题误报成可切换能力。

---

## G1 S2 Profile 三档与 exact 联动

| ID | 步骤 | 预期 |
|----|------|------|
| G1.1 | Safe 模式打开 tokio，查看 Profile 菜单 | 标题显示真实 unit、feature 预设、edition、trust；当前项有勾选 |
| G1.2 | 依次切 default / all / no-default | 每次标题与勾选立即一致；切换期间 fuzzy Context/Relations 仍可用，无空白闪断 |
| G1.3 | 在 feature-gated 文件上观察 exact 落点与 coverage 徽标 | RA 重建后 exact 落点/覆盖随真实 feature 改变；不编造百分比或完整覆盖 |
| G1.4 | 切换期间反复点 `harness.rs:535` 的 `poll` | 旧 profile 结果不回写；新结果的 feature 归因与当前档一致 |
| G1.5 | 打开 workspace 根并查看 unit | unit 如实展示；没有不存在的 unit 切换行为（K-M5-5） |

## G2 S4 依赖落点与只读阅读

| ID | 步骤 | 预期 |
|----|------|------|
| G2.1 | 从 `Future`/`Context`/`Poll` 或可用的 serde 类型跳定义 | Context 卡片显示 `External · in dependency` / `in dependency`，crate 可证时显示 crate，否则显示绝对路径 |
| G2.2 | 比较 Context 与 Relations 的同一依赖落点 | 文案、Exact 徽标、来源归因一致，不把外部边留在 Possible |
| G2.3 | 双击依赖卡片打开源码 | 阅读区字节与依赖文件一致，明确只读；编辑操作不能修改文件 |
| G2.4 | 观察文件树与导航历史 | 外部文件不伪装成项目成员；Back/Forward 可在项目文件与依赖文件之间往返 |
| G2.5 | 依赖源码不可得时重试 | 如实 BLOCKED/partial/offline，不联网、不生成假落点 |

## G3 S5 多标签与 Compare 共存

| ID | 步骤 | 预期 |
|----|------|------|
| G3.1 | 连续新开两个文件并来回切换 | tab 内容不串档，切换无明显闪烁；各自滚动位置与选择锚点恢复自然 |
| G3.2 | 只留一个 tab，再打开第二个 | 一个 tab 时 strip 隐藏且 reader 撑满；两个 tab 时 strip 出现且不压住正文 |
| G3.3 | 打开 10+ tab | 上限/LRU 行为可理解；当前 tab 不被意外驱逐，关闭后落到合理相邻 tab |
| G3.4 | 在 Light/Dark/SI Classic 下查看 strip | 选中态、关闭入口、分隔线与文字均可辨，不抢正文层级 |
| G3.5 | 保持多 tab 后切 Compare 预设 | tab strip 与左右 reader 共存，无重叠/塌陷；返回 Reading 后仍保留正确 active tab |
| G3.6 | 切历史 commit 后激活该版本不存在的后台 tab | 显示诚实的无法打开占位，不显示工作树旧字节 |

## G4 S6 声明排版、行高与注释保护

| ID | 步骤 | 预期 |
|----|------|------|
| G4.1 | 浏览 tokio 与 ripgrep 的 struct/enum/trait/fn/type/mod/const 声明密集文件 | 声明层级让文件像文档；调用点不被误放大 |
| G4.2 | 长距离滚动后回看同一区域 | 行高稳定，无明显上下跳动；若跳动明显，本项 FAIL 并建议退回放大幅度 |
| G4.3 | 切 SI Classic 与 Light/Dark 对照 | 声明分级在三主题可读，SI Classic 接近 SI 的克制层级，不擅自出现 italic 引用样式 |
| G4.4 | 打开 humanist，查看 `entry.rs:524-535` 与 `handle.rs:489-497` | 散文注释可换 humanist；ASCII/Unicode 图表保持等宽且列对齐 |
| G4.5 | 关闭 Syntax Formatting 总开关 | 全文回到素面单一字体/字号/字距，只保留颜色；重新打开后分级恢复 |

## G5 S7 行号、当前行、同名高亮与滚动

| ID | 步骤 | 预期 |
|----|------|------|
| G5.1 | 打开 100,000 行锚点并持续滚动 2 分钟 | 记录帧率/卡顿手感；不得用 bench 的 fragment 数替代人工结论 |
| G5.2 | 点击 `needle`、其它同名标识符、空白并按 Esc | 同名高亮替换/清除符合预期；接受词法非语义限制 K-M5-1 |
| G5.3 | 三主题下查看行号、当前行与同名高亮 | 当前行、occurrence、正文选择都可辨，配色不过亮、不吞语法色 |
| G5.4 | 浏览声明密集文件的 gutter | 声明标记密度帮助导航，不形成连续噪声墙 |
| G5.5 | Compare 中制造 diff，再触发查找闪烁与同名高亮 | diff gutter、查找、同名、当前行视觉层级稳定，任何一层不遮蔽其它层 |
| G5.6 | 关闭行号再打开 | reader 宽度完整回收/恢复，无空槽、横向跳位或正文裁切 |

## G6 S8 SearchPanel cap 与大结果观感

| ID | 步骤 | 预期 |
|----|------|------|
| G6.1 | 在 tokio/ripgrep 搜常见单字母，制造 5000+ 命中 | 状态仍报真实 `totalMatches`；只构建前 2000 个匹配行 |
| G6.2 | 查看截断提示 | 文案为 `Showing first 2000 of N matches (truncated)`，N 与真实总数一致 |
| G6.3 | 快速滚动、键盘上下选中、跳首尾 | 记录滚动手感；选中不越过 2000 边界，不崩溃、不循环到不存在的行 |
| G6.4 | 改查询到少于/等于/刚超过 2000 | 1999/2000 不显示 display cap 文案；2001 显示，且旧截断状态不串到新查询 |

## G7 30 分钟总弧线与回归

| ID | 步骤 | 预期 |
|----|------|------|
| G7.1 | Safe 开 tokio → 切 feature → 看 `x.foo()` Strong → 跳依赖 → 多标签 → 声明/行号/高亮 → 大搜索 → 撤销授权回 Safe | 全程无崩溃、beachball、快照/feature/文件内容串档 |
| G7.2 | 中途 Pin Context，再切 tab、Compare、feature | Pin 产品语义稳定；若只有 harness 竞态而人工产品行为正确，按 K-M5-4 记录 |
| G7.3 | Cmd+Q | 正常退出，RA/子进程不残留 |

## 报告格式

逐项填写 `ID | PASS/FAIL/BLOCKED | 备注`。FAIL 附截图、当前主题、窗口尺寸、语料路径、
feature/trust 状态与最短复现步骤；BLOCKED 写清缺失的 RA、依赖源码或环境能力。

M5 底线：

1. feature、coverage、依赖与截断总数必须诚实；
2. 依赖源码必须只读；
3. 巨档帧率、闪烁、行高、配色与滚动手感必须人工判定；
4. 批量通道挂起、Pin harness 竞态和 TextKit 2 绝对 footprint 只按白名单记录，不伪装已修。
