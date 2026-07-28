# M0-A 基准基线

环境：Apple Silicon (arm64e) macOS，release 构建（`swift build -c release`），
单次运行值（非 p50/p95——正式统计口径待基准自动化，见"后续"）。
日期：2026-07-20，代码版本：M0-A 收尾（commit 9049e80 之后）。

## 全量索引（`codeinsight index <repo> --stats`）

| 仓库 | 文件数 | LOC | scopes | bindings | symbols | calls | imports | 耗时 | 错误文件 |
|------|-------|-----|--------|----------|---------|-------|---------|------|---------|
| ripgrep 14.1.1 | 98 | 50,275 | 9,440 | 7,293 | 4,450 | 13,938 | 985 | **412ms** | 0 |
| tokio 1.47.1 | 717 | 159,291 | 24,670 | 18,743 | 11,407 | 34,658 | 5,911 | **1,496ms** | 0 |

对照设计目标（docs/design.md §15"10 万行级 < 2s"方向）：
ripgrep（5 万行）412ms、tokio（16 万行）1.5s——**目标达成**，且两仓库
`filesWithErrorNodes = 0`（tree-sitter-rust v0.24.0 对真实代码零解析错误）。

## 查询（tokio，3 次）

`callers spawn` 端到端 1,582 / 1,619 / 1,784 ms——其中 ~1.5s 是每次命令
重建内存索引（M0 CLI 无持久化，属已知设计），**查询本身 <150ms**。
`defs poll` 返回 104 个候选。

## 注意事项 / 后续

- 索引当前为单线程串行；设计中的并行流水线（design §11）尚未实现——
  这些数字是"未优化基线"，并行化后应显著下降。
- 正式基准需要：p50/p95 多次运行、冷/热文件缓存区分、峰值 RSS 记录、
  索引器分段计时（parse/extract/store）——留待基准脚本自动化任务。
- 语料放置于会话 scratchpad（不入库）；重取：
  `https://github.com/BurntSushi/ripgrep/archive/refs/tags/14.1.1.tar.gz`、
  `https://github.com/tokio-rs/tokio/archive/refs/tags/tokio-1.47.1.tar.gz`。

## 并行索引（M0-A 补完）

日期：2026-07-20。`bash scripts/bench.sh <repo> 5`，release 构建，活跃处理器
11 个；连续 5 次为热文件缓存口径，p50/p95 使用 nearest-rank。峰值 RSS 正常
由 `/usr/bin/time -l` 采一次；本次受限沙箱禁止其 `kern.clockrate` 查询，记录值
来自同一 rusage 的 `wait4.ru_maxrss` 回退。

| 仓库 | runs | 并行度 | min | p50 | p95 | max | 峰值 RSS |
|------|------|--------|-----|-----|-----|-----|----------|
| ripgrep-14.1.1 | 5 | 11 | 194ms | 195ms | 199ms | 199ms | 31.4 MiB (32,948,224 B) |
| tokio-tokio-1.47.1 | 5 | 11 | 701ms | 704ms | 761ms | 761ms | 69.3 MiB (72,679,424 B) |

与上方保留的串行单次基线比较（串行单次 / 并行 p50）：ripgrep
`412 / 195 = 2.11x`，tokio `1,496 / 704 = 2.13x`。两组语义统计与串行
基线完全一致；加速比仅作同机前后对照，旧基线是单次值，不是 p50。

## M1 Reader Alpha 自测

日期：2026-07-20。Apple Silicon (arm64e) macOS，release 构建。下面四项均由
`codeinsight-app` 的预算判定返回 exit 0；数值为一次验收运行：

| 场景 | 结果 |
|------|------|
| 空载 `--self-test` | `{"coldStartMS":179.095834,"idleFootprintMB":16.547653198242188}` |
| regular `Tests/RustExtractorTests/Fixtures/use_alias/db.rs` | `{"firstVisibleMS":2.807042,"styledFragments":0,"syntaxVisibleMS":2.807042,"tier":"regular"}` |
| huge `/tmp/codeinsight-m1-100k.rs` | `{"firstVisibleMS":2173.5151249999999,"styledFragments":280,"syntaxVisibleMS":9384.6200410000001,"tier":"huge"}` |
| tokio 1.47.1 项目 | `{"fileCount":717,"indexReadyMS":1011.913875,"treeVisibleMS":10.108584}` |

10 万行文件生成命令：

```bash
awk 'BEGIN { for (i = 1; i <= 100000; i++) printf "fn generated_%d() { let value = %d; }\n", i, i }' > /tmp/codeinsight-m1-100k.rs
```

huge 档 release 的 `syntaxVisibleMS` 为 9.38s，仍高于 5s；这是纯文本 first
visible 后的异步语法补齐路径，不阻塞首屏。M1 预算只卡
`firstVisibleMS < 2500` 与 `styledFragments < 500`，本次分别为 2.17s 与 280。

`bash scripts/bench.sh --app <tokio-dir>` 连续运行每个 self-test 3 次、取 p50：

| 命令 | runs | p50 |
|------|------|-----|
| `--self-test` | 3 | `{"coldStartMS":168.599291,"idleFootprintMB":16.516403198242188}` |
| `--self-test-open …/benches/copy.rs` | 3 | `{"firstVisibleMS":11.218709,"styledFragments":83,"syntaxVisibleMS":11.218709,"tier":"regular"}` |
| `--self-test-project <tokio-dir>` | 3 | `{"fileCount":717,"indexReadyMS":880.71575,"treeVisibleMS":9.95075}` |

## M2 Relations Alpha 自测

日期：2026-07-21。Apple Silicon (arm64e) macOS，release 构建；tokio 1.47.1
语料与 M0/M1 相同。CLI 数字由
`bash scripts/bench.sh --m2 <tokio-dir> 5` 采集，均包含每次命令重建内存索引，
因此是端到端 CLI 耗时，不等同于 session 内单次关系展开耗时。

| CLI 场景（含索引） | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `callers poll` | 5 | 874.6ms | 941.1ms | 1521.5ms |
| `calls tokio/src/runtime/task/harness.rs:153` | 5 | 773.9ms | 821.7ms | 844.8ms |
| `search block_on` | 5 | 775.5ms | 855.9ms | 869.5ms |

三个 app self-test 均连续运行 3 次且全部 exit 0；下表记录 p50 JSON：

| 场景 | p50 |
|---|---|
| 空载 `--self-test` | `{"coldStartMS":200.123458,"idleFootprintMB":17.15705108642578}` |
| regular `tokio/benches/copy.rs` | `{"firstVisibleMS":12.018833,"firstVisibleOutlineFacets":30,"outlineFacets":30,"styledFragments":161,"syntaxVisibleMS":12.018833,"tier":"regular"}` |
| tokio 项目 | `{"fileCount":717,"indexReadyMS":892.791666,"treeVisibleMS":9.764125}` |

huge 使用同一 `/tmp/codeinsight-m1-100k.rs` 连续运行 3 次；M2 p50 为：

`{"firstVisibleMS":2308.1365000000001,"firstVisibleOutlineFacets":0,"outlineFacets":100000,"styledFragments":280,"syntaxVisibleMS":9820.6941669999997,"tier":"huge"}`

`syntaxVisibleMS` 对比 M1 单次基线为 `9384.620041ms → 9820.694167ms`
（+4.6%，不同轮次数据）。ViewportGating 二分在运行探针中把首个可见 fragment
从 400,000 spans 剪到 4 spans，validator 本身约 22–25ms；总时长没有随之下降，
剩余主耗时是 TextKit 对 100,000 个 function-name 布局属性的延迟重排。huge 的硬预算
在最终三次样本中全部通过：`firstVisibleMS < 2500`、首屏 outline 为 0、
`styledFragments < 500`。release 重建后的首个冷样本曾出现一次
`firstVisibleMS=2848.451125ms`（exit 1），随后三次均 exit 0，说明该冷启动预算仍有波动。

## M3 Git 时间旅行自测

日期：2026-07-21。Apple Silicon (arm64e) macOS，release 构建。
`bash scripts/bench.sh --app <tokio-dir>` 的 tokio 1.47.1 语料是 tar 展开目录，
不含 Git 历史；脚本因此按规则回退到 CodeInsight 本仓库运行
`--self-test-switch`。四个场景均连续运行 3 次且全部 exit 0，表中为 p50。

| 场景 | p50 |
|---|---|
| 空载 `--self-test` | `{"coldStartMS":192.912208,"idleFootprintMB":17.688278198242188}` |
| regular `tokio/benches/copy.rs` | `{"firstVisibleMS":13.318875,"firstVisibleOutlineFacets":30,"outlineFacets":30,"styledFragments":161,"syntaxVisibleMS":13.318875,"tier":"regular"}` |
| tokio 项目 `--self-test-project` | `{"fileCount":717,"indexReadyMS":843.625708,"treeVisibleMS":8.673708}` |
| CodeInsight `--self-test-switch` | `{"cachedReadyMS":42.863417,"extracted":0,"firstPaintMS":38.233375,"fullReadyMS":43.647167,"reused":50}` |

三级就绪顺序为 `firstPaint 38.23ms → cachedReady 42.86ms → fullReady
43.65ms`，首屏低于 1s 硬预算。同一仓库的
`codeinsight switch-stats --from HEAD --to HEAD~1` 结果为 `totalFiles=50`、
`reusedCount=50`、`extractedCount=0`、`hitRate=100.0%`、
`switchMilliseconds=37.724`。

既有三项 self-test 均保持在原预算内：空载 192.91ms < 500ms，
regular 首屏 13.32ms < 100ms，tokio 项目索引 843.63ms < 2s 且文件树
8.67ms < 1s，未见 M3 回退。

## M4 正式版 自测

日期：2026-07-23。Apple Silicon (arm64e) macOS，release 构建，活跃处理器 11 个。
索引语料仍为 tokio 1.47.1（与 M0–M3 同一 tar 展开目录，无 Git 历史）。三组数据由
`bash scripts/bench.sh --m4 <rust-repo> 5` 采集，p50/p95 用 nearest-rank。

### 持久化冷/热（决定 6：SQLite ContentIndex 缓存）

`--self-test-project` 连跑两次；用 `CODEINSIGHT_INDEX_CACHE_ROOT` 把缓存指向隔离
临时目录（不碰用户真实 `~/Library/Application Support/CodeInsight`），每次冷跑前
清空该目录。冷跑（空缓存）逐文件提取，热跑（暖缓存）走 remap 复用路径。

| 场景 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `indexReadyMS cold (extracted=717, reused=0)` | 5 | 804.9ms | 817.4ms | 833.7ms |
| `indexReadyMS hot (extracted=0, reused=717)` | 5 | 703.4ms | 763.7ms | 766.9ms |

跨进程复用已证实：冷跑 `extracted=717 / reused=0`，热跑 `extracted=0 /
reused=717`，两次为独立进程。热跑省去 717 个文件的提取，p50 由 817.4ms 降到
763.7ms（约 −6.6%）。差幅有限是因为 tokio 的索引耗时以 tree-sitter 解析与树构建
为主，提取只是其中一段——持久化省的是提取那一段，解析仍在冷热两侧发生。两次均
远低于 `indexReadyMS < 2s` 硬预算，`extracted` 归零是可复现的核心信号。**毒化防线
未动**：CLI 默认不落盘、读失败静默回退重提取；所有 canonical dump 与 gold set
（nostrong=0）零 diff。

### Exact 原位升级（决定 1–3：fuzzy→exact 就地升级）

`--self-test-exact` 驱动内置 `Tests/CodeInsightExactTests/Fixtures/exact_fixture`，
fake provider 注入固定 0.25s 升级延迟，作为 CI 无关的确定性口径；同一进程内的真实
rust-analyzer 变体为 conditional，本机 `真实 RA=passed`。计时从读区点击到 Context
出现对应 provenance。

| 场景 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `fuzzy first answer` | 5 | 10.4ms | 10.5ms | 10.9ms |
| `fuzzy->exact upgrade (fake 250ms inject)` | 5 | 261.2ms | 262.5ms | 266.7ms |

首答（fuzzy）稳定在 ~10.5ms，升级 p50 262.5ms = 注入的 250ms + 协调层约 12ms
开销。真实 RA 首次 exact 受 workspace 就绪时间支配（数秒级，见 m4-plan 风险 1），
机会式设计保证 fuzzy 全程可用，故 bench 头条数字取确定性的 fake 口径。

### 跨 commit diff 计算（决定 5：DiffCore 行级 + 函数级）

`--self-test-diff` 在本仓库取一个 worktree 与 HEAD~1 blob 相异的真实文件，
`DiffCore().compare` 单文件 best-of-5 计时（不含项目打开/git 读取，仅纯计算）。

| 场景 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `DiffCore compute` (220→190 行) | 5 | 0.149ms | 0.153ms | 0.157ms |

标准库 `CollectionDifference` 行级 diff 对典型源文件（数百行）纯计算 <0.2ms，
预算门（>2 万行或 >5000 变更截断）在本样本未触发。

### 八条 self-test 通道 + 回归全家福

M4 总验收无头门：`ci.sh` 连跑两次通过（引擎/model 禁 AppKit 断言覆盖新增
CodeInsightExact）；全量 `swift test`（≥208 测试）、fixture、双语料 gold set
（`nostrong=0`）零回归；八条集成通道各自 exit 0 并断言真实 AppKit 控件状态：

| 通道 | 断言要点 |
|---|---|
| `--self-test` | 冷启动/空载内存预算 |
| `--self-test-open` | 首屏/语法可见时序 |
| `--self-test-project` | 文件树+索引就绪；持久化冷热 |
| `--self-test-switch` | 三级就绪、切 commit 复用率 |
| `--self-test-history` | 前进/后退与树选中同步 |
| `--self-test-pin` | Cmd+单击跳主区、底部保持钉住 |
| `--self-test-exact` | 先 fuzzy 后 Exact 原位升级、fuzzy 全留、Exact 组非"(0)" |
| `--self-test-diff` | 右 reader 字节==commit blob（≠worktree）、gutter 计数、hunk 导航 |

stress-switch（`--self-test-switch` + `--self-test-history` 交替）连跑无 hang/error，
持久化与 exact overlay 未破 M3 的切换量级。

## M5 Rust 深化 + UIUX 精修 自测

日期：2026-07-25。Apple Silicon (arm64e) macOS，release 构建。主数据由
`bash scripts/bench.sh --m5 <tokio-1.47.1> 5` 采集。已知 AppKit self-test 批量连跑
会间歇挂起，因此 profile 与 reading 各只启动一次独立进程；`runs=5` 只用于无 AppKit
的 tokio CLI 全量索引。下列数据只陈述耗时与计数，不评价帧率或手感。

### Profile 切换（S2，fake provider）

计时从 `reprofiled` 同步完成后开始，到切换后的 Context exact 可用、再到 Relations
Exact 组可用；两处都从真实 `MainWindowController` 状态取样。新 session 的
`extracted=0`，证明切换复用 ContentIndex、没有重提取。

| 场景 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `reprofile -> Context ready (extracted=0)` | 1 | 554.654ms | 554.654ms | 554.654ms |
| `reprofile -> Context + Relations ready (extracted=0)` | 1 | 870.838ms | 870.838ms | 870.838ms |

### receiver targetHint 解析开销（S3）

当前工作树对 tokio 1.47.1 全量索引 5 次：

| 场景 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `tokio index with targetHint` | 5 | 797.000ms | 818.000ms | 902.000ms |

与本文件保留的 M0 并行索引 p50 `704ms` 相比为 **+16.2%**；该值跨日期、跨多个切片，
只能作为历史总回归口径，当前仍低于 2s 预算。为隔离 S3，在同一机器、同一语料上把
S2 commit `bdf10d8` 与当前 release 二进制交替各跑 5 次：

| 二进制 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| S2 `bdf10d8`（targetHint 接线前） | 5 | 746.000ms | 750.000ms | 815.000ms |
| M5 当前（targetHint 接线后） | 5 | 764.000ms | 766.000ms | 773.000ms |

同机 A/B 的 p50 相对变化为 **+2.1%**，没有观察到显著提取回退；历史 +16.2% 不归因于
targetHint。

### 10 万行行号 + 同名高亮渲染路径（S7）

`--self-test-reading` 使用 100,000 行 fixture（200 个 `needle`，其余空行）。核心口径是
TextKit 2 实际写过属性的 fragment 数，而不是是否调用 lazy API。

| 场景 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `first visible` | 1 | 1491.312ms | 1491.312ms | 1491.312ms |
| `styledFragmentCount` | 1 | 185.000 | 185.000 | 185.000 |
| `visible lines` | 1 | 37.000 | 37.000 | 37.000 |

`185` 个 styled fragments 相对 100,000 行仍是 viewport 量级；首屏低于 2.5s 预算。
滚动帧率、配色层级与卡顿手感保留为 `m5-interactive-test-plan.md` 人工项。

### SearchPanel 5000+ 命中 cap（S8）

数据来自真实 `SearchPanelModel` 的 5,001 命中测试；显示行计数包含一条截断提示。

| cap 前匹配行 | cap 后匹配行 | 含截断提示的显示行 | totalMatches |
|---:|---:|---:|---:|
| 5001 | 2000 | 2001 | 5001 |

cap 限制了模型持有的匹配行，同时 `totalMatches` 仍诚实保留 5,001。

## M6 Exact Relations + Reference Styles 自测

日期：2026-07-28。Apple Silicon (arm64e) macOS。主数据由
`CODEX_SANDBOX=1 bash scripts/bench.sh --m6` 采集；Exact 与局部引用指标来自 DEBUG
测试进程内的真实请求/解析或 parse/build 计时，Reference Styles 来自 release
`codeinsight-app --self-test-reading` 单次独立进程。下列只陈述客观耗时、内存与计数；
帧率、卡顿和阅读手感保留为 `m6-interactive-test-plan.md` 真机人工项。

### implementations（S2，fake provider 响应请求 + 解析）

计时只包围 `session.implementations`，不含 fake session 初始化和关闭；包含 LSP
请求/响应与结果解析，因此不是脱离真实调用路径的 JSON parser 微基准。

| 响应形态 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `Location` | 5 | 0.637ms | 0.730ms | 0.916ms |
| `Location[]` | 5 | 0.690ms | 0.723ms | 0.957ms |
| `LocationLink[]` | 5 | 0.781ms | 0.845ms | 1.049ms |
| `null` | 5 | 3005.414ms | 3008.242ms | 3010.038ms |

`null` 约 3 秒是现有请求路径的真实行为：空结果会按既有策略重试三次，并执行
1 秒 + 2 秒退避；表中未删掉该成本，也未把它伪装成纯解析耗时。

### callHierarchy（S3，fake provider 响应请求 + 解析）

`prepare`、`incoming`、`outgoing` 分别计时；incoming/outgoing 的 fixture 同时守住
`fromRanges` 的方向性文件身份。

| 步骤 | runs | min | p50 | p95 |
|---|---:|---:|---:|---:|
| `prepare` | 5 | 0.762ms | 0.816ms | 1.029ms |
| `incoming` | 5 | 0.842ms | 0.892ms | 1.375ms |
| `outgoing` | 5 | 0.640ms | 0.791ms | 0.840ms |

### 局部引用索引（S5）

`Tests/Fixtures/m6_reference_density.rust`，单次独立测试进程；footprint 是进程级
metric-only 原始值，不作布尔预算门。

| parse | index build | baseline footprint | after footprint | delta | bindings | references | indexed tokens |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 437.642ms | 2811.718ms | 45.485MB | 45.766MB | +0.281MB | 20,000 | 35,000 | 55,000 |

### Reference Styles 写属性量（S6）

`--self-test-reading` 在 1600×1000 offscreen 窗口打开同一 35,000-reference fixture；
`referenceScannedCount` 是实际扫描候选的工作量指标，不用输出 run 数冒充门控证据。

| referenceAttributeRunCount | referenceStyledFragmentCount | referenceScannedCount |
|---:|---:|---:|
| 55 | 28 | 55 |

三项都保持 viewport 量级。该计数不能证明滚动流畅、不卡顿或视觉层级正确；这些结论
只能由真机交互测试给出。
