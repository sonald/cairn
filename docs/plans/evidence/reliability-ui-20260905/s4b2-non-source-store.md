# S4b-2 — 非源码不进入语义 store：逐片记录

## RED（2026-09-07/08）

`s4b2NonSourceBytesDoNotEnterTheSemanticStore`（`SnapshotIndexerTests.swift`，20 源文件 + 64×4MiB 唯一 PDF 负载 + Cargo.toml）先于实现运行：`retained.count → 85`（全部进入）vs 预期 21。

## 消费者审计（实现前逐一核对）

- 全项目搜索 `SnapshotSearchService.activeFiles()`：仅遍历 `LanguageMode.classify` 命中文件——非源码本就不参与搜索。
- Resolver / `EngineSession.sourceBytes(at:)` / `capturedSource(atManifestPath:)`：仅源码路径调用（Context/Relations/Trail/Reading Set/Bookmark 经 `capturedProjectSource`→classify）。
- ProfileDetector / Materializer / Exact ProfileSnapshot：经 `snapshot.readBytes` 读配置（ProfileDetector.swift:44/58/81），不依赖 store 字节。
- CLI：`snapshot.readBytes`（CodeInsightCLI.swift:75）。
- M14 非源码预览 / 文件树：manifest（路径/大小）与快照原始字节，均不经 store。

## 实现（`ProjectIndexer.swift`）

`prepareSnapshot` 的 `capturedBytes` 只收录 `LanguageMode.classify` 命中的语义源码与 `snapshot.configurationPaths` 命中的真实配置（Cargo.toml/Cargo.lock、pyrightconfig/pyproject/uv.lock、tsconfig/package.json/bun.lockb）；其余文件字节留在快照内。manifest 的文件成员与 `size` 不变；提取路径（mode + 非 LFS）不变。

## GREEN 与冻结阈值复测

- RED 测试转绿：retained = 20 源 + 1 配置 = 21；负载 contentID 全部不在 store；字节数恰为源码+配置。
- **S4a 矩阵复测**：`A payloadMiB=0/64/256 retainedKiB=0,0,0 entries=20,20,20`——冻结阈值（256MiB 负载保留 == 0 负载基线）达成；prepareMs 1/24/96 不变（捕获成本属快照层，S4c 触发条件评估见 s4c 记录）。
- 一处既有断言按新合同更新：`snapshotIndexerReusesContentAndResolvesEachCommit` 原断言 Package.swift（Rust 仓库中的非源码负载）字节在 store——改为断言不在 store 且 `snapshot.readBytes` 原始字节仍可用。
- 全量：Engine/Git/Search/Extractor/AppModel/SnapshotSwitch/SessionRestore/ExactCoordinator 538 通过；UI 批 60 通过。
- `scripts/ci.sh` 877→878。

## G1 结论（计划要求只能二选一）

1. **预算达标**：非源码资源不再增加语义 store retained bytes（阈值复测 ✓）；项目边界后旧项目 store 生命周期结束（S4b-1 ✓）；固定 A/B 反复打开不随轮次线性增长（S4a 场景 B ✓）。
2. **仍不达标/剩余风险**：同项目演化内容线性保留（S4a 场景 C，按计划允许收缩到项目边界并如实报告——开放）；快照捕获本身仍全文件 eager（WorktreeSnapshot/CommitSnapshot 读取全部 blob）——S4a 实测 prepareMs 随负载线性（96ms@256MiB），**未触发 S4c 条件**（首屏/峰值预算未因此不达标：first-paint 由 manifest/目录发布驱动，进程内捕获峰值 ≈ 负载本体且 COW 共享；RSS 级 campaign 留 V0 步骤 10 复核）。

## S4c 触发条件判定

S4b 后全文件 eager 捕获未使 G1 的首屏或峰值预算实测不达标（本机进程内矩阵 + 应用冷启动 202.9ms/空闲 30.6MB）。按计划"不触发则不做该接口改造"——S4c 不实施，此为判定记录而非遗漏。
