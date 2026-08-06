# M9 v2 验收报告（2026-08-06）

## 结论

**M9 总验收：PASS（变更尚未提交）。**

此前 S4a 的“没有 readiness barrier”结论已被独立复核推翻：它使用了
未离线的 Tokio、错误的 features 和“响应到达”而非“请求开始”判定。修正后
`experimental/serverStatus.quiescent` 在 exact fixture 与 Tokio 的十个独立
cold 样本中均无 barrier 后假空；S4b 已按该结论落地并通过真实 provider
及 Tokio 重复验收。

## 已实现并自动验证

| 切片 | 状态 | 证据 |
|---|---|---|
| S1 Outline 仲裁 | PASS（自动） | 共享导航置显式意图；`didLiveScroll` 解锁跟随；真实 `NSWindow`/`NSScrollView` reading self-test 三项均 true。 |
| S2 主选中 Variant B | PASS（自动 + 实机） | 保留 native `selectedRange`/AX 语义，隐藏系统蓝底，按原型自绘 `1.6 pt` ring、`4 pt` radius 和三主题 fill；主选区不叠加 occurrence 黄底，Escape 清除并恢复原生 attributes。 |
| S3 divider | PASS（自动） | `NSSplitView.autosaveName`；专用名称前后清理 defaults；重建恢复断言为 true，65/35 geometry 继续为 true。 |
| S5 Relations 行式 | PASS（自动 + 实机） | After A 两行式完整落地：44/26/24 pt 行高、title/path/chip/modifiers 字号、compact Verified/Inferred badge、dispatch chip、`Show possible matches` + count pill；badge 与 dispatch chip 使用同一 `1×5 pt / r4` 轮廓，宽高由 label 锁定、右侧保留 10 pt，宽面板不再拉伸；原 AX subtitle 保留。 |
| S6 三主题 surface | PASS（自动 + 实机） | 三主题 chrome/header/divider/selection/accent 与 badge/chip 色集中在 `ReaderSettings.swift`；窗口背景、透明 titlebar、status bar、侧栏、Reader、Relations、Context 同步消费，SI Classic 不再出现白色外壳，Light 选中行文字不再被 AppKit 自动反白。 |
| S4a readiness | PASS（取证） | [S4a 原始时序与裁决](evidence/m9v2-s4a/readiness-probe.md)。 |
| S4b / 合同 6 | PASS（真实） | `quiescent` 在既有 LSP condition 内等待、等待不持锁；`ready + null` 立即空返，`-32801` 可恢复。exact fixture 真实 10/10 四方向落点齐全；Tokio 5/5 首行 <1s。见 [S4b 证据](evidence/m9v2-s4b/real-exact-and-tokio.md)。 |

## 自动化门禁

| 命令 | 状态 | 结果 |
|---|---|---|
| `swift test --disable-sandbox` | PASS | 414 tests passed |
| `bash scripts/provision-corpora.sh --check` | PASS | tokio `be8ee45`，ripgrep `4649aa9` |
| `CODEX_SANDBOX=1 bash scripts/ci.sh` | PASS | exit 0 |
| `codeinsight-app --self-test` | PASS | 包含 divider rebuild persistence |
| `codeinsight-app --self-test-reading` | PASS | 含 S1/S2 新检查 |
| 12 通道 self-tests | PASS | 12/12 `SELF_TEST_FINISH … exit=0`，0 hang；使用 `/private/tmp` 的非 git exact fixture 和其 `src/lib.rs` |
| stress | PASS | `--runs 5 --load 8 --timeout 180`：5 个 run status 均为 0；结束后无 stress worker 残留 |
| gold gates | PASS | tokio：17 total、`nostrong=0`、unexpected=0；ripgrep：16 total、`nostrong=0`、unexpected=0 |

## 真实 UI 验收

| 要求 | 状态 | 原因 |
|---|---|---|
| tokio Light / Dark / SI Classic 关键截图 | PASS | 实机 `mutex.rs`；见 [UI 回放](evidence/m9v2-s0/ui-replay.md) 和 `ui/` 截图。 |
| Outline 点击 → Reader 主选中 → Reader 滚动 → Escape | PASS | 点击 `Mutex` 跳至第 133 行；滚动回文件开头且 Outline 选择解除；Escape 清除保留 native 语义的自绘主选区。 |
| 1600×1000 geometry | PASS（自动） | 实机显示器无法完整呈现该尺寸；真实 `NSWindow` self-test 已测 1600×1000。 |
| Relations 四方向和真实结果行 | PASS | host UI 回放的 Safe 会话如实显示 offline 状态；另有 10 个真实 RA App self-test 进程验证实现、来电、去电、引用的落点，Relations 行 geometry/AX 合同由真实 `NSWindow` self-test 覆盖。 |
| divider 跨重启 | PASS | 实机紧凑布局无重叠；跨 rebuild persistence 由真实 `NSWindow` self-test 通过，无需破坏用户桌面会话。 |
| 三个视觉原型逐项还原 | PASS（合同级） | S2/S5/S6 的颜色、透明度、圆角、描边、字号、padding、行高、层级和状态均按原型值实现；见 [三原型视觉审计](evidence/m9v2-visual-audit/visual-audit.md) 及 Light / Dark / SI Classic 最终实机截图。 |

S0 的已测数据和未测边界见 [baseline status](evidence/m9v2-s0/baseline-status.md)。
HTML 原型不是固定像素母版，因此无法定义 AppKit 整窗截图的逐像素相等；若要求 bitmap
级 100%，需要固定尺寸 PNG/Figma frame、viewport、display scale 与字体版本，并允许
自绘原生窗口控件。当前验收的 100% 指原型明确设计合同的完全对齐。

## 边界审计

- `Prototypes/`、canonical dump、gold fixtures、`RECORD`：最终 diff 审计均无修改。
- 探针 instrumentation 已从产品和测试代码移除；仅保留 S4a 取证文档。
