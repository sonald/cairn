# M4 正式版 实现计划（Planner: Fable 5, 2026-07-21）

> M1/M2 由本 Planner 规划，M3 由 Opus 4.8 代行，本轮恢复原分工。Codex 实现，
> orchestrator 验收，末尾终审。本文件为 M4 执行的权威依据，切片 S1–S9 串行派发。

**通用约束（沿用 M1–M3，含 M3 血的教训）**：无头环境；`swift build && swift test`
全绿；ci.sh 通过（引擎/model 禁 AppKit，禁令清单须覆盖新 module）；Swift 6 严格
并发零 warning；不改 `Prototypes/`；每片不 commit。**既有 156 测试 + fixture +
双语料 gold set（nostrong=0）不得破坏**。
**每个涉及 UI 的切片必须有驱动真实 MainWindowController 的离屏集成通道断言**
（`--self-test-history` / `--self-test-pin` 模式），模型层测试全绿不算完成。
涉及执行外部进程的功能默认 Safe，测试要能证明"没执行"（M0-D marker 对照组）。

**目标**（design §16 M4 + §8）：Exact Provider + Safe/Trusted 双模式产品化 +
跨 commit diff 阅读 + 索引持久化最小闭环 + 正式发布。

## 现状核查要点（已实地读代码）

1. 四维标注体系就位但精确通道空转：`.lsp/.scip` 零产出；`ResolutionCandidate`
   无 provider/toolVersion/coverage/trustMode 归因字段。
2. **`.exactUpgrade` 不存在**（简报有误）——原位升级须全新设计。
3. 引擎地基：ProjectIndexStore/SnapshotView/EngineSession 门面完整；锁内整拷实为
   CoW，真实问题是 `completeSnapshot` 逐条 insert 触发整字典复制 → 改批量。
4. **CommitSnapshot.snapshotID 每次捕获都是新 UUID** → exact 缓存键必须用
   `commitOID`，不能用 snapshotID。
5. `coverage.importsResolved` 恒 nil 却显示"resolving imports"占位 → 造精确感。
6. 持久化为零（无 SQLite）；`DeclarationFacet` 已有 signature/bodyFingerprint。
   提取走 draft(局部 interner)→remap 两段——持久化的关键锚点。
7. 产品语言面 **Rust-only**（文件树都不列 .ts/.py）。
8. tree-sitter 已 vendor；系统依赖只剩 libgit2（brew + unsafeFlags）。
9. Compare 分屏已有，diff 未做；RelationTree Exact 组恒显 "(0)"。
10. Pin 已裁决实现，K5 结案。

## 八项决定

### 决定 1：ExactProvider = Rust-only（rust-analyzer），LSP 基座语言无关
只接 rust-analyzer（产品当前 Rust 单语言面，TS/Python 结果无处显示）。LSP 客户端层
按语言无关设计，M5 加适配器即可。SCIP 推后。Helper = **stdio 子进程非 XPC**
（bundle 化前无处安放，批注 d）。生命周期：prepare→ExactSession（readiness、
每请求超时、graceful close、强杀兜底）；崩溃→退避重启一次→标 unavailable，
**绝不影响 fuzzy**。

### 决定 2：精确结果融入四维体系 + Exact 不覆盖 fuzzy
新 `ExactOverlay`，条目携带 `ExactAttribution{provider,toolVersion,configFingerprint,
environmentFingerprint,trustMode,generatedAt,coverage}`（旁挂结构，**不动 Core**
避免 dump 回归）。**复用键 = commitOID × configFingerprint × toolVersion**。
`certainty=.exact` 只来自 provider；Safe 下标 `coverage=partial`（build script/
proc macro 缺席是覆盖缺口不是没找到）。升级 = exact 置顶/就地升级标注，
**fuzzy 候选全保留**；Pin 冻结时仅允许已显示目标自身标注就地升级。
Relations：边的 fuzzy 目标与 exact definition 一致 → 升入 Exact 组。

### 决定 3：Safe/Trusted = OS 边界 + 授权登记
双层防御：seatbelt（`sandbox-exec`：项目只读、写仅私有缓存、deny network）+ RA
safe options。**配置只是纵深，OS 沙箱才是边界**；沙箱不可用 → Safe 下禁 exact
（批注 e）。`TrustRegistry`（trust.json：仓库路径→mode/grantedAt，可见可撤销）；
Trust sheet 明文写后果；设置页列表 + 撤销（立即回 Safe）。Trusted 放宽 target/
写但 **network 恒 deny + CARGO_NET_OFFLINE=1**。rlimit + 请求超时。

### 决定 4：历史快照物化（可裁剪切片 S7）
Materializer 直接从 CommitSnapshot 已持有的字节写盘（不用 git archive），布局
`materialized/<commitOID>/<configFingerprint>/`，跳过 gitlink/symlink/lfsPointer，
命中 0 拷贝复用，2GB 配额 LRU + 设置清空。RA 指向物化目录，结果路径剥前缀映射回。
离线依赖缺失 → 如实标 `coverage: deps unavailable (offline)`，**绝不联网**。

### 决定 5：diff = 标准库 Myers 行级 + fingerprint 函数级，纯 Reader 层
行级用 `CollectionDifference`（不自研不引三方），预算门（>2万行或>5000变更 →
truncated + 仅并排）。函数级：两版本各跑单文件提取（不进 store），按 (名字链+kind)
配对 facet，比 signature/bodyFingerprint → added/removed/signatureChanged/
bodyChanged；**重命名不猜 lineage**（如实 removed+added，F4.8 留 M5）。
**与 SnapshotView 无关**：右侧独立 CommitSnapshot + ContentSource，不切主快照、
不进 store。

### 决定 6：索引持久化 = SQLite ContentIndex 缓存最小闭环，存 **draft 形态**
持久化 draft（局部 interner）自包含落盘，加载走**现有 remap 路径**并入当前 store
→ interner 不持久化、NameID 分配顺序不变、**determinism 与今天逐字节一致**。
系统 libsqlite3；per-project 单文件 DB；`meta(schemaVersion,grammarVersion,
extractorVersion)` + `contents(contentKey,payload,lastAccess)`。
**任何读失败/校验失败一律静默降级为重新提取**（毒化防线铁律）；版本不符/损坏→
整库重建。512MB LRU。**CLI 默认不落盘（--persist opt-in）**保 dump/gold 纯净。
折入 backlog #1：completeSnapshot 改批量 insert。
不做：manifest/relations/exact 产物、posting、源字节持久化。

### 决定 7：发布 = vendored 静态 libgit2 + 脚本化 bundle + 签名公证
`scripts/vendor-libgit2.sh`（固定版本、cmake 静态、**关 SSH/HTTPS/网络**，呼应 N3）；
Package 支持 vendored/brew 双路径。`scripts/make-app.sh` 组装 .app（Info.plist、
macOS 14.0、release 二进制）；codesign `--options runtime`；**App 本体不进
App Sandbox**（审计工具需任意路径读 + spawn helper，直接分发不上 MAS，批注 d）；
notarytool 参数化，无凭据走 ad-hoc 全流程供无头验证。真实公证是人工检查点。

### 决定 8：backlog 折入
折入：#1 store 批量 insert（S5）；#2 coverage.importsResolved 真实化或删占位
（S4，**禁止显示假进度**）；#3 libgit2 分发（S8）；主线程 IO 异步化（S8）。
挂起：分支图、huge syntaxVisible、AX 专项、SearchPanel 极限、outgoingCalls posting 化。
已结案：K5 Pin。

## 切片

### S1 — CodeInsightExact module：LSP 基座 + ExactProvider + RA provider
新 module（依赖 Core/Git，禁 AppKit，ci 禁令扩展）。参照探针不 import：
LSPFrameDecoder、LSPClient（stderr 排水、应答反向请求、shutdown/exit+SIGTERM/
SIGKILL、每请求超时）；ExactProvider/ExactSession 协议；RustAnalyzerProvider
（Safe/默认 options、有界重试）；ExactProfileKey（Cargo.toml/Cargo.lock 指纹，
**不动 Core 的 AnalysisProfile**）；ExactAttribution。
**无头验收**：帧解码单测；进程内 fake LSP server 全生命周期；不响应进程
SIGTERM→SIGKILL 且被 reap；RA 环境 conditional 真实 definition；ci + 156 零回归。

### S2 — Safe 的 OS 边界 + TrustRegistry
seatbelt profile 生成与沙箱启动、rlimit shim、沙箱不可用降级、TrustRegistry。
**无头验收**：**沙箱语义测试不依赖 RA、CI 恒跑**（sandbox-exec 包 /bin/sh 断言
写项目被拒/写缓存成功/网络失败）；TrustRegistry round-trip + 损坏恢复；
**marker 对照组**（RA conditional）：Safe 跑 definition → marker 与 target/ 均不
存在且答案正确，默认 options 对照组 → marker 存在。

### S3 — ExactCoordinator + Context 原位升级 + `--self-test-exact`
coordinator（provider 可注入、机会式起 session、异步 exact、requestID/generation
双检、崩溃恢复、overlay 按 commitOID×profileKey×toolVersion 缓存）；Context 原位
升级（exact 置顶、fuzzy 全留、Pin 下目标不变仅标注升级）；provenance 徽标。
**无头验收**：coordinator/ContextWindowModel 单测；**新集成通道
`--self-test-exact <repo>`（驱动真实 MainWindowController，fake provider）**：
断言真实 Context 视图先 fuzzy 后含 "Exact" 徽标且切换条仍含 fuzzy；RA 变体
conditional。既有 -history/-pin 不回退。
**人工**：观感"先 fuzzy 后 Exact 原位升级"不闪不跳；RA 加载期 fuzzy 全程可用。

### S4 — 授权 UI + Relations Exact 组 + 覆盖状态诚实化
Trust sheet（明文后果）+ 设置 Trust 页（列表/撤销→回 Safe 重建）；exact 状态徽标；
RelationTree 边查 overlay 升 Exact 组；coverage.importsResolved 真实化或删占位。
**无头验收**：Exact 组注入单测；Trust↔UI 状态流转；coverage 单测；
**集成通道**：fake overlay 下右键 Show Relations 后真实 NSOutlineView 的 Exact
组行数 >0 且组头非 "(0)"、状态栏含 exact 字样；self-test 全家不回退。
**人工**：授权→覆盖差异可感知；撤销→回 Safe；Exact 组第一次有真内容的观感。

### S5 — 索引持久化（SQLite ContentIndex 缓存）
决定 6 全部 + store 批量 insert。
**无头验收（determinism 硬门）**：round-trip 等价；损坏/版本 bump→重建；LRU；
批量 insert 等价；**156 测试 + fixture + gold set nostrong=0 + 所有 canonical
dump 零 diff**；**集成通道**：`--self-test-project` 连跑两次断言第二次
`extracted==0` 且 indexReadyMS 显著下降。
**人工**：tokio 关闭重开秒开。**风险**：毒化防线是铁律；dump diff 禁止重录。

### S6 — 跨 commit diff 阅读 + `--self-test-diff`
DiffCore（行级 CollectionDifference + hunk + 预算截断；函数级 facet 配对）；
Compare 右侧版本选择 + 独立 CommitSnapshot/ContentSource（切主快照即清理）；
gutter 三主题配色、hunk 导航、函数级摘要条。
**无头验收**：diff 单测（增删改/空/EOF/CRLF/巨行/截断）；函数摘要单测（重命名
=removed+added 不猜）；右侧生命周期单测；**新集成通道 `--self-test-diff`**：
断言真实右 reader 字节 == 该 commit blob（≠worktree）、gutter 计数与 DiffCore
一致、hunk 导航实际移动、切 Reading 预设右侧收起。
**人工**：HEAD vs HEAD~3 与 `git diff` 抽查一致；三主题配色可读。

### S7 — 历史快照物化 + 历史 exact（**可裁剪**）
Materializer + coordinator 扩展 + 离线降级标注。
**无头验收**：物化单测（布局/0拷贝复用/配额/特殊 fileMode 跳过）；路径映射；
双 commit fixture conditional RA（HEAD 与 HEAD~1 definition 行号不同）；
**集成通道**：切 HEAD~1 后 fake provider 收到的根是物化目录、UI 显示仓库相对路径。
**人工**：切 HEAD~5 点符号 → Exact 徽标 + 落点正确 + 归因显示物化来源。
**进度不支可整体裁剪**（Exact 保持 worktree-only，不构成 M4 失败）。

### S8 — 发布工程：vendored libgit2 + App bundle + 签名公证 + 主线程 IO
两个脚本 + Package 双路径 + IO 异步化。
**无头验收**：vendored 下 ci 全绿；ad-hoc bundle 结构断言、`otool -L` 不含
/opt/homebrew、`codesign --verify` 通过；**集成通道**：**从 .app bundle 内**跑
`--self-test` 与 `--self-test-project`（真实产物冒烟，预算不回退）。
**人工**：决策者机器真实 Developer ID 签名 + notarize + staple + Gatekeeper 打开。

### S9 — 收尾：bench + 回归全家福 + M4 总验收
bench.sh 增 `--m4`（exact 首答/升级延迟、持久化冷热、diff 耗时）；benchmarks.md
增节；stress-switch 回归；挂起项复核。
**无头验收**：ci + 全量 + fixture + gold set + **八条 self-test 通道全绿**
（-/-open/-project/-switch/-history/-pin/-exact/-diff）。
**人工（M4 总验收 30 分钟）**：Safe 开陌生仓 → fuzzy 阅读 → 授权 Trusted →
exact 原位升级 → 切历史 commit → Compare diff → 关闭重开秒开 → 撤销授权回 Safe。

## 依赖与派发顺序

```
S1 → S2 → S3 → S4（exact 主线严格串行）
S5（内容可提前）；S6（与 exact 无耦合，可机动）；S7（依赖 S1–S4，可裁剪）
S8（仅依赖仓库现状）；S9（依赖全部）
推荐：S1 S2 S3 S4 S5 S6 S7 S8 S9
```

## 风险预警

1. **RA workspace 就绪时间**：tokio 量级首次 exact 可能数十秒；机会式设计保证
   fuzzy 全程可用；readiness 必须可见；空结果/-32801 只做**有界**重试。
2. **S5 是地基旁路**：毒化防线（读失败→重提取、CLI 默认不落盘）是铁律；
   canonical dump 零 diff 硬门，禁止 RECORD 重录。
3. **sandbox-exec 已 deprecated**：需降级路径兜底；长期迁移留 M5。
4. **集成通道必须 CI 无 RA 也绿**：fake provider/overlay 是主体，真实 RA
   conditional skip；新通道必须断言**真实 AppKit 控件状态**。
5. **overlay 键控**：复用键用 commitOID×configFingerprint×toolVersion；
   展示作废用 generation/requestID。两套键别混。
6. **Compare 右侧独立快照生命周期**：切主快照/项目必须清右侧（整份 commit 字节）。
7. **物化离线依赖**：CARGO_NET_OFFLINE=1 恒置；依赖缺失是 coverage 降级不是错误；
   验收 fixture 必须无外部依赖。
8. **发布构建配方**：SwiftPM release + 脚本组装 bundle，不引 Xcode 工程。

## 待决策者批注

- (a) **ExactProvider = Rust-only**，TS/Python 整语言面推 M5（与 design §16
  "三语言"存在既成落差，需确认 M4 验收基调改写）。
- (b) S7 裁剪权是否预授权 orchestrator。
- (c) libgit2 分发形态（vendored 静态 vs 随包 dylib）。
- (d) 两处 design 偏差：stdio helper 非 XPC；App 本体不进 App Sandbox。
- (e) 沙箱不可用时：Safe 下禁 exact（宁缺毋滥）vs 允许但标注。
- (f) Trusted 授权身份键：仓库路径 vs 加 git 指纹。
- (g) 磁盘预算默认值：物化 2GB / 索引缓存 512MB。
- (h) **正式产品名**（design 待定 1）：S8 的 bundle id / 显示名需要。
