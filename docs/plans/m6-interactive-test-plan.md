# Cairn (CodeInsight) M6 交互测试规格（供 UI 自动化工具/人工执行）

版本：对应 M6 S0–S7 完成工作树，基线 commit `a36e740`。沿用 M5 的执行与报告格式。
本轮聚焦真实 rust-analyzer 下的三方向 Exact Relations、exact/启发式并置与深层展开、
文件内语义引用样式。帧率、卡顿、行高与视觉层级只由真机目验，不用 bench 数字替代。

## 前置条件

```sh
cd /Users/siancao/work/ai/vibecoding/codeinsight
swift build -c release
swift run -c release codeinsight-app
```

- 真机需安装 `rust-analyzer`。真实 RA 相关项必须确认没有
  `skipped:sandbox-unavailable`；出现该标记时相应项记 BLOCKED，不把 fake provider
  或全绿单测当成真实 RA 证据。
- 语料：tokio 1.47.1 与 ripgrep 14.1.1。记录实际绝对路径；不用 self-test fixture
  代替真实 RA 与真实源码跳转。
- 三主题均测试：Auto/Light、Dark、SI Classic；窗口至少 1600×1000。
- 测试前记录 trust mode、Cargo 本地 registry 缓存与 `rust-src` 是否齐全、RA 版本、
  当前 feature profile 与 `CARGO_NET_OFFLINE=1`。
- 巨档锚点沿用 M5：100,000 行 Rust 文件，前 200 行含同名 `needle`，其余为空行。

### 依赖类分组前置：本地依赖齐全 × trust mode

Safe 与 Trusted 都设置 `CARGO_NET_OFFLINE=1`，两种模式都离线。Trusted 不会产生、
下载或补齐依赖源码；依赖可得性只取决于本地 Cargo registry 缓存与 `rust-src`。
因此不得把“需 Trusted”写成依赖测试的获取步骤，那会诱导无用授权。

trust mode 仍会影响分析覆盖：Safe 显式禁用 build scripts 与 proc macro，所以相关
crate 的 RA 覆盖确实受限；Trusted 只解除这类分析限制，不解除离线策略。

| 本地依赖状态 | Safe（离线） | Trusted（离线） |
|---|---|---|
| 本地依赖齐全 | 普通 crate 可测；build-script/proc-macro crate 的 RA 覆盖可能 partial/BLOCKED。 | 依赖源码仍只来自本地；build script/proc macro 未被 Safe 配置禁用，可对比更完整覆盖。 |
| 本地依赖不齐全 | 记 partial/BLOCKED/offline；同时保留 Safe 的 build-script/proc-macro 限制。 | 仍记 partial/BLOCKED/offline；授权不会下载 registry 源码或安装 `rust-src`。 |

## 测试锚点（已核实）

- **implementations 锚点**：ripgrep
  `crates/matcher/src/lib.rs:537` 的 `Matcher` trait；可核对
  `crates/regex/src/matcher.rs:409`、`crates/pcre2/src/matcher.rs:310` 与
  `crates/matcher/src/lib.rs:1124` 等真实 impl。
- **callHierarchy 锚点**：tokio
  `tokio/src/runtime/task/harness.rs:153` 的 `poll(self)`，以及同文件 `:535`
  的 `guard.core.poll(cx)`；用于分别查看 callers / calls 与实际跳转文件。
- **多 callsite/base URI 对照锚点**：执行时另建最小临时 Cargo 项目：
  `a.rs::foo` 连续两次调用 `b.rs::bar`。对 `bar` 查 callers、对 `foo` 查 calls；
  两个调用点都必须落在 `a.rs`。
- **引用样式锚点**：tokio 上述 `harness.rs` 与 ripgrep
  `crates/core/flags/defs.rs`；选取同一 viewport 内同时存在 param、local、声明与调用的
  区域，记录具体行号。
- **三层视觉锚点**：M5-S6 声明分级、M5-S7 点击后的词法同名高亮、M6-S6 语义
  Reference Styles 同屏；Compare 模式再叠加 diff gutter。
- **密度/巨档锚点**：`Tests/Fixtures/m6_reference_density.rust` 只用于工作量与巨档
  观感，不替代真实 RA；另沿用 M5 的 100,000 行 `needle` 文件。

## 已知限制白名单（不算 FAIL，必须记录现象）

- **K-M6-1 点击定位到整个调用表达式而非被点 token**：Context 在所有含调用的行上
  给的都是被调函数信息；同一行第二次点击会因 `locatedToken` 早退无反应。根因是
  `UnresolvedCall.range` 使用整个 `call_expression`。修法需区分表达式/token range，
  bump `extractorVersion`；M6 不修。
- **K-M6-2 同名高亮延迟约 1 秒**：根因未明；`activate` 是同步调用，理论上应立即。
  K-M6-1 修完后重新观察是否自愈，不基于猜测归因。
- **K-M6-3 巨档 footprint 绝对值超 100MB**：TextKit 2 基线，M5 之前既存，已转
  M7 候选；只记录 baseline/after/delta，不把不可归因 delta 设为安全门。
- **K-M6-4 self-test 通道批量连跑间歇挂起**：根因未明；当前只认可
  `scripts/run-self-tests.sh` 显式逐条单发与其 summary。
- **K-M6-5 `--self-test-pin` harness 竞态已修**：S0 修的是等待视图可见状态的
  harness，根因不属于产品 Pin 语义；仍需人工验证产品行为。
- **K-M6-6 同名高亮是词法匹配，不是语义引用**：M5-S7 只按同名 token 匹配；
  M6-S6 Reference Styles 才基于 S5 binding 数据。两者可共存，不得混淆。
- **K-M6-7 真实 RA 断言在无 sandbox 环境一律 skip**：Codex 报的“全绿”对这些项
  无意义；必须由有 sandbox 的 orchestrator 真机复核 S2/S3/S4。

---

## G1 S1/S2 implementations 能力与准确度

| ID | 步骤 | 预期 |
|----|------|------|
| G1.1 | Safe 打开 ripgrep，等待 Exact 状态稳定，在 `Matcher` trait 上切 implementations | Relations 显示 Exact 组；服务端支持时不出现“不支持”空态 |
| G1.2 | 核对 Exact 结果与已知 impl 文件 | 至少逐项核对 regex、pcre2 与 `&M` impl；落点是 impl/方法的 selection token，不是整个 block 或错误文件 |
| G1.3 | 在无实现 trait 与不支持 implementations 的 RA 环境分别观察 | 分别显示“无实现”与“服务端不支持”，不共用模糊的 `Exact (0)` |
| G1.4 | 将同一目标同时命中 Exact 与启发式 | 只显示一个目标，Exact 优先并明确标注启发式也命中 |
| G1.5 | 快速切 profile / history / revoke trust 后返回 | 旧 generation 结果不回写；当前 Exact 状态、目标与 profile 一致 |

## G2 S3 callers / calls 的 base URI 与跳转

| ID | 步骤 | 预期 |
|----|------|------|
| G2.1 | 在临时跨文件项目的 `b.rs::bar` 查 callers | 一个 caller 行聚合两个 call sites；依次点击都落在 `a.rs` 的两次 `bar()` |
| G2.2 | 在 `a.rs::foo` 查 calls | callee 是 `b.rs::bar`，但调用处点击仍落在源文件 `a.rs`，绝不套用 `b.rs` base URI |
| G2.3 | 在 tokio `harness.rs:153` 的 `poll` 查 callers | 逐个打开至少三个结果，文件、行、token 与源码调用一致 |
| G2.4 | 在 `harness.rs:535` 的 `guard.core.poll(cx)` 所在函数查 calls | 目标与调用处分别正确；calls 明确映射 outgoing，不冒充 references |
| G2.5 | 在不可调用 token 上查 callers/calls | 显示“此处不适用”；与“支持但无结果”“服务端不支持”两种空态可区分 |

## G3 S4 Exact Relations 并置、聚合与深层展开

| ID | 步骤 | 预期 |
|----|------|------|
| G3.1 | 在同一根节点同时观察 Exact 与 Strong/Probable/Possible 组 | 分组标题、来源与层级清楚，frame 在 1600×1000 可视区内且互不重叠 |
| G3.2 | 展开一个只有 Exact、没有引擎 symbol 的依赖节点 | 能继续请求并显示第二层；不因缺少 `SymbolOccurrenceID` 停止 |
| G3.3 | 连续展开形成回路的节点 | cycle 诚实标注“已展开过”，不静默截断、不无限递归 |
| G3.4 | 在多 callsite caller 行重复激活 | 保持一 caller 一行，subtitle 报真实 callsite 数，点击按调用点循环 |
| G3.5 | 制造超过 500 条 relation 的 fixture 或既有自测路径 | 只 cap 显示，提示 `Showing first 500 of M relations` 且 M 是真实总数 |

## G4 S5/S6 语义引用样式与三层视觉层级

| ID | 步骤 | 预期 |
|----|------|------|
| G4.1 | 浏览 tokio/ripgrep 的 param/local 密集 viewport | local 与 param 引用差异克制可辨；声明本身不被误当引用 |
| G4.2 | 在 shadowing、同名 sibling scope、声明前同名 token 处目验 | M6 语义样式只跟随真实 binding；不串 scope、不包含声明前 token |
| G4.3 | 同屏观察声明分级、语义 Reference Styles、点击后的词法同名高亮 | 三层职责可辨：声明是结构层、Reference Styles 是语义引用层、点击高亮是临时词法层 |
| G4.4 | 长距离滚动 tokio/ripgrep 后返回同一区域 | 行高、baseline 与横向位置稳定；明显跳动即 FAIL |
| G4.5 | Auto/Light、Dark、SI Classic 各重复 G4.1/G4.3 | param alpha、local、选择、高亮与语法色均可辨，不吞字、不刺眼 |
| G4.6 | 关闭 Syntax Formatting 总开关 | Reference Styles 与声明排版消失，回到素面排版；语法颜色仍可保留 |
| G4.7 | Compare 中叠加 diff gutter 与同名高亮 | diff、声明、语义引用、临时高亮层级稳定，任何一层不遮蔽其它层 |

## G5 依赖可得性 × trust mode 对照

| ID | 步骤 | 预期 |
|----|------|------|
| G5.1 | 本地依赖齐全，Safe 下测试普通 crate 的三方向 Exact | 保持离线且可用；不因 Safe 身份无条件写“需 Trusted” |
| G5.2 | 同一 build-script/proc-macro crate 在 Safe 与 Trusted 对照 | Trusted 可能提升 RA 覆盖；差异按实际结果记录，不编造百分比 |
| G5.3 | 本地移除/隔离一个依赖源码后重复 Safe/Trusted | 两种模式都不能下载补齐，均如实 partial/BLOCKED/offline |
| G5.4 | Trusted 完成后撤销授权 | 回到 Safe；旧 Trusted exact 结果不回写，RA/子进程生命周期正常 |

## G6 M6 总弧线、性能手感与回归

| ID | 步骤 | 预期 |
|----|------|------|
| G6.1 | Safe 开 tokio → callers → calls → implementations → 深层展开 → 引用样式 → Trusted 对照 → 撤销授权 | 全程无崩溃、beachball、文件/快照/profile 串档；所有 Exact 落点可核对 |
| G6.2 | 在 100,000 行锚点持续滚动 2 分钟 | 记录帧率/卡顿手感；不得用 55/28/55 或 fragment 数替代人工结论 |
| G6.3 | 点击调用表达式内不同 token，再点同一行第二个符号 | 按 K-M6-1/K-M6-2 记录现象，不把白名单误判成新回归，也不宣称已修 |
| G6.4 | Pin Context 后切 tab、Compare、profile 与 history | 人工产品行为稳定；S0 harness 修复不代替此项 |
| G6.5 | Cmd+Q | 正常退出；RA、helper 与其它子进程不残留 |

## 报告格式

逐项填写 `ID | PASS/FAIL/BLOCKED | 备注`。FAIL 附截图、当前主题、1600×1000 几何、
语料绝对路径、文件:行、RA 版本、feature/trust 状态与最短复现步骤。BLOCKED 必须写清
是缺 rust-analyzer、缺本地 registry/rust-src、无 sandbox，还是服务端能力不支持；
不得写“需 Trusted”代替真实阻塞原因。

M6 底线：

1. implementations、callers、calls 的准确度与文件落点必须由真实 RA 复核；
2. outgoing `fromRanges` 必须落在请求源文件，exact-only 节点必须可深层展开；
3. Exact 与启发式、语义 Reference Styles 与词法同名高亮不得混淆；
4. 帧率、卡顿、行高和视觉层级必须人工判定；
5. 七条已知限制只按白名单记录，不伪装已修，也不掩盖白名单之外的新失败。
