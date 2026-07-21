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
