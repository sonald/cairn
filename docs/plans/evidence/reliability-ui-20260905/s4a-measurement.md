# S4a — 资源测量与预算冻结（G1）：逐片记录

日期：2026-09-07。测量入口：`Tests/CodeInsightEngineTests/SnapshotIndexerTests.swift::s4aRetentionMeasurementMatrix`（进程内确定性测量，无断言门槛——冻结阈值由 S4b 回归编码）。

## 测量矩阵（实测输出）

```
S4A-MEASURE A payloadMiB=0   prepareMs=1  retainedKiB=0      entries=20
S4A-MEASURE A payloadMiB=64  prepareMs=24 retainedKiB=65536  entries=36
S4A-MEASURE A payloadMiB=256 prepareMs=96 retainedKiB=262144 entries=84
S4A-MEASURE B fixedAB20rounds retainedKiB=0,0,...,0（20 轮全扁平）
S4A-MEASURE C evolving10 retainedBytes=534,548,...,660（+14B/修订，线性）
```

场景：A=相同 20 个 Rust 源文件 + 0/64/256 MiB 唯一内容 PDF 负载（16/64 个 4MiB 文件），每次全新 `ProjectIndexStore`，`ProjectIndexer.prepareSnapshot` 直测；B=固定 A/B 两个项目交替 20 轮共享一个 store；C=同一文件 10 个不同内容修订共享一个 store。进程内测量确定性成立（多次运行 A/B 数值逐位一致，共记录 ≥4 次稳定重复；不宣称 p95——p95 口径需 ≥20 次的场景留 V0 步骤 10）。

应用级（debug 构建自测）：`coldStartMS=202.9`（<500ms 预算 ✓）、`idleFootprintMB=30.6`（<100MB 预算 ✓）。commit 切换 first-paint p95 与 RSS 分档 campaign 留 V0 步骤 10，本轮不宣称。

## 结论（G1 三目标对照，冻结于 S4b 实施前）

1. **纯非源码资源不增加语义 store retained bytes——当前不达标**：64/256 MiB 负载 1:1 进入 `sourceBytesByContent`（+65536/+262144 KiB，entries 20→36/84）。定位：`ProjectIndexer.prepareSnapshot` 在语言分类（`guard let mode`）之前把每个文件字节放入 `capturedBytes`（ProjectIndexer.swift:241–244 → store.insert:297）。
2. **关闭项目后旧项目 store 生命周期可验证结束——待 S4b-1**：`ProjectIndexService` 持有的 store 仅插入、从不按项目边界替换（AppModel.swift:145）。
3. **固定 A/B 集合 20 轮后半段不线性增长——store 级已成立**（contentID 去重）；同项目不同内容线性保留（C 场景，+14B/修订）为**已知未关闭风险**，按计划允许收缩到项目边界并如实报告。

## 冻结阈值（S4b 回归必须达到，不得事后放宽）

- **S4b-2**：场景 A 负载 256 MiB 时 `retainedKiB` 与负载 0 相同（本 fixture 即 0 KiB、entries=20）；负载仅允许影响捕获瞬时峰值，不允许影响 store 保留。
- **S4b-1**：项目切换后，服务不再保留旧项目内容（服务级回归：切换后旧项目 contentID 不在 store，当前会话/Compare/pending replay 引用仍有效）；固定 A/B×20 保持扁平。
- 同项目演化内容保留（C）不设阈值：报告为开放风险。

## 捕获峰值/COW 说明

进程内 A 场景峰值 ≈ 负载本体（快照与 capturedBytes/store 共享同一 COW 缓冲，无三倍放大）；prepareMs 1→24→96ms 主要为 4MiB 块的读取/SHA-256/字典插入。RSS 与分配器保留内存分开报告留 V0 步骤 10（需进程外采样）。
