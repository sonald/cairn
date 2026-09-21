# Reader wrap v2 · S0 基线记录

- 日期：2026-09-20
- 代码基线：`7666dcb0079e5dfab88342c5dac826307332f542` + S0 提交（S0 只新增测量脚手架：性能入口、fixture、计数器与两个探针测试，不改变任何布局行为；性能数据由该 S0 树的 Release 构建采集）
- macOS：Version 27.0 (Build 26A428)；机器：Mac15,6（Apple Silicon）；backing scale 2；系统滚动条偏好为 legacy（”Always”），runner 在测量窗口内钉住 overlay 以稳定几何（见下）
- 采集命令：`bash scripts/run-wrap-perf.sh --out docs/plans/evidence/reader-wrap-v2/s0-baseline`（默认 warmup 5 / samples 30；F2/F3 为 2/10；F5 各 1 次探测）
- 汇总：`summary-20260920T072551Z.json`（26 个配置全部 `status: ok`；F5 两个方向 `status: unsupported`）

## 交付物

| 项 | 位置 |
| --- | --- |
| Fixtures F1–F5 | `fixtures/wrap/`，由 `scripts/gen-wrap-fixtures.sh` 生成并 `--verify` 校验（manifest 含 SHA-256/字节数/逻辑行数/最长行） |
| 性能入口 | `codeinsight-app --self-test-wrap --fixture … --wrap <on\|off> --scenario <initial\|toggle\|resize\|reading-set> --output … [--code-sha …] [--warmup N] [--samples N]` |
| 批量采集与预算门禁 | `scripts/run-wrap-perf.sh`（预算表来自设计 §7.4.4，含相对预算与内存门禁） |
| 坐标转换测试 | `wrapFirstVisualRowGeometryConventionsHoldInRealTextView`（`Tests/CodeInsightReaderCoreTests/ReaderUITests.swift`） |
| 尺寸回调时机测试 | `wrapResizeCallbacksOnlyObserveNewWidth`（同上） |
| 基线 JSON | 本目录 `s0-baseline/*.json` |

## S0 测量约定（由实测确定）

1. **真实绘制信号**：离屏（不 orderFront）窗口上 `display()`/`displayIfNeeded()` 不触发任何绘制回调。runner 使用 `NSView.cacheDisplay(in:to:)`（位图缓存路径）执行真实 draw 管线；`ReaderTextView.backgroundDrawCount`（`drawBackground` 回调计数）作为”帧已渲染”信号；绘制区域取 `visibleRect`（首帧只计可见区域）。`textLayoutFragment(for:).textLineFragments` 非空 + `viewportRange` 非空作为布局完成信号。
2. **稳定判定**：5ms runloop 泵 × 连续 3 次几何签名（`view.frame.height`、clip originY）不变视为 settled；期间签名变化次数记为 `settleAdjustments`。无固定 sleep。
3. **主线程阻塞**：后台队列 5ms 心跳，main-queue 续体记录迟到量；在测量窗口起点清零，窗口内最大迟到 ≈ 最长连续阻塞。
4. **toggle 场景**：每个样本 = 应用目标 wrap 设置 → 首帧 → 稳定（两者分记 `toggleFirstFrameMs` / `toggleSettledMs`，合计即设计口径 `toggleActionToSettledMs`）；随后不计时的反向应用恢复初始态。配置校验读取测量态快照（非结束态）。
5. **滚动条几何**：本机 preferred style 为 legacy 且在 runloop 泵送后才送达进程（会在加载期间重置早先设置的 scrollerStyle）——runner 在测量窗口起点重新钉住 `scrollView.scrollerStyle = .overlay` 并 `autohidesScrollers = true`，clipView 恒为 1200×760。`perfConfig.scrollViewScrollerStyle` 记录实际生效值。
6. **配置校验**（独立于 fold runner）：`widthTracksTextView == 请求`、水平滚动条与水平伸缩与请求相反、13pt（`.AppleSystemUIFontMonospaced-Regular`）、viewport 1200×760、窗口 1440×900、行号开、SI Classic；不匹配输出 `status: “error”` 且退出码 1。

## S0 探针结论

- **坐标约定（D2.1 前提成立）**：普通配置下 `textContainerOrigin == textContainerInset`；`fragment.layoutFragmentFrame.origin + lineFragment.typographicBounds.origin + textContainerOrigin` 与同一字符的 `firstRect(forCharacterRange:)`（屏幕坐标→view 坐标）在全部视觉行（含折行续行）上误差 < 0.5pt。`NSTextLineFragment.characterRange` 为 fragment 局部偏移，必须加 fragment 起点才是全文 UTF-16 位置（测试逐行锚定验证）。
- **尺寸回调时机（D3.7 前提成立）**：
  - clipView 的 `boundsDidChangeNotification` 在程序化窗口缩放中**完全不触发**（即使 `postsBoundsChangedNotifications = true`）——它是滚动信号；同一观察者在滚动时正常触发（健全性检查通过）。
  - 唯一的 resize 通知是 textview 的 `frameDidChangeNotification`，严格事后派发，且会经过中间宽度（观察序列 `360.0 → 334.0`：autoresize 先到，ruler 重排后修正）。
  - 结论：旧宽度几何在任何既有通知里不可观测，S1 必须在 frame 实际改变前捕获旧稳定状态（D3.7 的 ClickTextView 窄尺寸回调）。

## 基线数据（本机，Release，20260920T072551Z 采集）

F1（30000 逻辑行，3,109,590 字节，最长行 3659 字节）主预算指标：

| 指标 | wrap | p50 | p95 | max | 候选预算 |
| --- | --- | --- | --- | --- | --- |
| toggleFirstFrameMs | on | 6575 | **6721** | 6874 | — |
| toggleFirstFrameMs | off | 1704 | 1748 | 1749 | — |
| toggleSettledMs（首帧后静默段） | on | 27.6 | 29.3 | 29.8 | — |
| toggleActionToSettledMs（设计口径=首帧+静默） | on | ≈6603 | **≈6750** | ≈6903 | p95 ≤ 250ms 且 ≤ max(base×1.5, base+15ms)¹ |
| toggleActionToSettledMs | off | ≈1728 | ≈1774 | ≈1775 | 同上 |
| resizeStepMs | on | 40.5 | 44.9 | 53.5 | p95 ≤ 33ms² |
| longestMainThreadStallMs（toggle-on 全程） | on | — | — | 10837 | ≤ 100ms（resize 场景） |
| peakPhysBytes（toggle-on） | on | — | — | 7.87 GB³ | ≤ max(base×1.3, base+32MiB) |

¹ 基线本身远超绝对预算（见下”基线结论”），S1 起以绝对预算 250ms 为准；相对预算仅在基线达标后适用。
² 基线 44.9ms 已超 33ms 预算：resize 每步对 30k 行做全量重排，是候选必须解决的既有成本（设计 §7.4.4：”如果基线本身超过绝对预算，要先记录现有成本并区分本次增量”）。
³ F1 全文档加载 + 双向 toggle 循环下的进程物理内存峰值；含 fixture 3MB 与 TextKit 全量排版产物。

极端 fixture（单独报告，不并入 F1 均值）：

| Fixture | 特征 | toggleActionToSettled p95（on） | p95（off） | 预算 |
| --- | --- | --- | --- | --- |
| F2 | 983,058 字节单逻辑行（211 行） | 53.7 | 136.2 | p95 ≤ 1500ms ✅ |
| F3 | 1,835,038 字节无空白单行（1 行） | 919.3 | 219.4 | p95 ≤ 1500ms ✅ |

F4（组合文本 965 字节）：toggle 双向 firstFrame p95 ≈ 16ms、settled ≈ 26ms；initial/resize 全部 < 40ms。

**基线结论（旧行为的真实成本）**：

1. F1 上 wrap-on 切换的首帧阻塞约 **6.7s**（toggle-off 约 1.7s）：`apply(settings:)` 无条件全量重建 DisplayMap/属性串（≈1.3s），随后容器宽度变化触发 TextKit 对 30k 行的全量重排（≈5s，单一主线程连续阻塞，心跳探针实测 stall 10.8s 含反向半程）。这正是 S1 需要消除的主要成本：wrap-only 切换跳过重投影 + 视口恢复。
2. settled 静默段本身很快（~30ms），成本集中在首帧的一次性阻塞。
3. F2/F3（超长单行）在基线下即满足 1500ms 极端预算；F3 的 ~0.9s 来自单行 1.8MB 的排版本身。
4. 基线 resize 步长（44.9ms p95）已超 33ms 预算，属于记录在案的既有成本。

## 未运行项（not-run）与已知问题

- `scripts/run-gold-gates.sh`：tokio/ripgrep 语料就位，随 S0 提交前完整执行，结果记录于本节下方（见”仓库门禁”）。
- F5 reading-set 场景测量：`unsupported`（Reading Set wrap 能力在 S2b 落地；这是诚实状态，非 0 测量值）。
- `paragraphUpdateCount`/`restorePassCount`/`anchorErrorPt`/`mergedResizeRequests`：输出中显式为 `null`（分别由 S3/S1/S1/S1 落地）。
- **既有 flaky（与本工作无关，门禁不受影响）**：`CodeInsightAppModelTests` 中 `contextFuzzyCandidatesDoNotMixExcerptsFromDriftedBytes`（ExactCoordinatorTests.swift:2183）与 `appModelStrictCrossSnapshot*`（BookmarkModelTests.swift:1612）在并行执行或机器高负载时偶发失败/挂起（一次在干净 HEAD worktree 上挂起 25 分钟、零 CPU；本机并行运行复现 3–4 项失败）。串行执行（ci.sh 批次与单独 `--no-parallel` 全量）下 382 项全部通过。该 target 依赖 AppModel/Engine/Exact，与 ReaderUI/App 无依赖边（Package.swift:310-314），判定为负载敏感的既有 flaky，不由 wrap 工作修复。

## 仓库门禁

- `bash scripts/ci.sh`（CODEX_SANDBOX=1）：PASS——build、三批测试（主批 976 / bookmark 2 / panel 2，含本切片新增 2 项）、静态 rg 门禁、`--self-test-exact/diff/reading/projector/fold`、fold-perf（control/fold 均 `status: pass`）全部完成（脚本在 `set -e` 下到达并完成最后一步 fold-perf）。
- `bash scripts/run-gold-gates.sh`：PASS——"All gold gates passed."（tokio + ripgrep goldset 评估、ByteUTF16Map 门禁、projector/fold 自测、fold-perf）。
- 注：本机直接 `swift test --no-parallel`（不加 ci.sh 的 `--skip` 隔离）会在 AppTests 的 bookmark/panel 对上触发已知的进程退出截断——这正是 ci.sh 拆三批的原因，非本切片引入。

