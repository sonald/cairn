# 最终验收记录 — 2026-09-05 可靠性与阅读 UI 修复计划

日期：2026-09-09。验收构建：`.build/reliability-ui-validation/Cairn.app`（bundle id `dev.cairn.Cairn.ReliabilityUIValidation`，ad-hoc 签名，未公证——如实记录，不冒充公证发布）。
实施基线 `ac18460` → 验收 HEAD `6b99101`，共 18 个切片提交（S0–S11 + V0 记录）。全程单机 macOS 26.6.2 / arm64 / Swift 6.3.3。
`/Applications/Cairn.app` 原实例未被触碰；本轮 fixture 位于 `/tmp/cairn-v0-fixture`，验收后已终止唯一测试实例（PID 51717）。

## 总结论：部分完成（不可声明"所有问题已解决"）

计划 §7 判据：V0 任一关键真实步骤 BLOCKED/FAIL → 只能报告部分完成。本轮 **V0 的全部交互式步骤被自动化工具权限阻断**（详见下表），故按判据如实记为部分完成。单元/门禁级（G0/G1/G2 的自动化部分）全部通过。

## 逐切片结果

| 切片 | 结果 | 证据 |
|---|---|---|
| S0 基线 | PASS | baseline.md（探针复现 EOF 空转 1.6M 回调/2s） |
| S1 LSP EOF | PASS（单测级） | s1-eof.md；98/98 Exact 套件；EOF 后请求 10s→0.08s |
| S2a 内容身份 | PASS（单测级） | s2a-content-identity.md；5 新回归 + 860 全量 |
| S2b Context/Exact 一致性 | PASS（单测级） | s2b-source-consistency.md；4 新回归 |
| S2c Refresh Index | PASS（单测级） | s2c-refresh-index.md；6 新回归（真实 Git fixture） |
| S3a 打开流程收敛 | PASS | s3a-open-convergence.md；RED（多语言打开不取消）→GREEN |
| S3b 失败反馈 | PASS | s3b-error-feedback.md；三类失败原因 + Retry/另选目录 |
| S4a 测量 | PASS | s4a-measurement.md；冻结阈值先于修复 |
| S4b-1 项目边界寿命 | PASS | s4b1-store-lifetime.md |
| S4b-2 非源码不入 store | PASS（G1 达标） | s4b2-non-source-store.md；256MiB 负载保留 0 |
| S4c 捕获策略 | 未触发（判定记录） | s4b2 内判定：预算未超标，不做接口改造 |
| S5 关系命令操作面 | PASS | s5-relation-surface.md；Pin 独立性 + 顺带修复 toolbar family 崩溃 |
| S6 来源说明/几何 | PASS | s6-provenance-geometry.md；窗口 900→1401 撑大缺陷修复 |
| S7a 面板退场 | PASS | s7a-panel-exit.md |
| S7b Reader 优先/Inspector | PASS | s7b-reader-first-layout.md；打开 Relations 撑窗（既有缺陷）修复 |
| S8 视觉层级 | PASS（chrome 步） | s8-visual-hierarchy.md；Reader token 无对应问题未改 |
| S9 语言预选 | PASS | s9-language-preselection.md |
| S10a Markdown 列表 | PASS | s10a-markdown-lists.md |
| S10b 概念文案 | PASS | s10b-concept-copy.md |
| S11 文档与门禁 | PASS | s11-docs-gates.md；失败注入 ×2 使门禁 FAIL 验证 |

## 门禁（2026-09-09）

- `CODEX_SANDBOX=1 bash scripts/ci.sh`：**PASS** —— swift test 893（main 891 + 隔离 2），ByteUTF16Map 通道 PASS，自测 exact/diff/reading/projector/fold 全部 passed，release 构建 + fold perf 完成。
- 失败注入：还原 S1 EOF 缺口 → 3 断言 FAIL；拆除 S2a 身份验证 → 5 断言 FAIL。门禁有效。

## V0 逐步骤状态

| 步骤 | 状态 | 证据/限制 |
|---|---|---|
| 1 首次打开（鼠标+键盘） | **BLOCKED** | 自动化助手被拒屏幕录制（`Screen Recording is denied for ZCode`）与辅助功能（AX 树不可读，osascript -1719）；无法驱动原生 picker。未以单元测试冒充 |
| 2 CPU 生命周期 | **部分** | 空载实测：0.0% CPU ×3、10s `sample` 主线程阻塞于 `mach_msg` 事件等待、零 readability-handler 帧（v0-idle.sample.txt.gz）。EOF-断开后采样需先打开项目（依赖步骤 1）→ 该半步 BLOCKED |
| 3 内容一致性 | **BLOCKED** | 需 UI（改名→重开→stale→拒绝→刷新）。单测级全绿（s2a/s2c），不冒充原生 PASS |
| 4 关系与 Pin | **BLOCKED** | 需 UI |
| 5 版本与 Compare | **BLOCKED** | 需 UI；零写基线已记录（fixture git status/HEAD/index 验收前后不变——应用未获交互机会，不声称零写行为已实测） |
| 6 预览往返 | **BLOCKED** | 需 UI |
| 7 阅读证据（Freeze/重启） | **BLOCKED** | 需 UI + 持久化动作 |
| 8 书签与笔记 | **BLOCKED** | 需 UI |
| 9 视觉/AX 四宽度×三主题 | **BLOCKED** | 截图权限被拒 |
| 10 资源复测 | **部分** | 验收 bundle 空载 RSS ≈ 93–97MB（ps 三次）；S4a 确定性矩阵随 CI 复跑通过。进程外 RSS 分档 campaign 未完成（依赖打开各档项目） |

## 已确认延期项（明示，不隐藏）

1. V0 步骤 1、3–9 的原生交互验证：被工具权限阻断，需人工或授权环境重跑。**在此之前，S2a–S2c/S5/S7 的修复只能声明单测级 PASS。**
2. V0 步骤 2 的 EOF-断开后半、步骤 10 的 RSS 分档：同上。
3. S1 的 bundle 级 CPU 采样：以空载实测 + 单元级回调计数差异替代，断开场景未测。
4. Reader token 步的 S8 调整：无对应本轮问题，按计划"纯样式值不逐项镜像"未改。
5. 同项目演化内容线性保留（S4a 场景 C）：按计划收缩到项目边界，作为已报告开放风险。
6. ad-hoc 签名/未公证：维持事实状态。

## 复现指引

```bash
# 门禁
CODEX_SANDBOX=1 bash scripts/ci.sh
# 验收 bundle（唯一输出/bundle id）
CODEX_SANDBOX=1 bash scripts/make-app.sh \
  --output .build/reliability-ui-validation \
  --bundle-id dev.cairn.Cairn.ReliabilityUIValidation
open .build/reliability-ui-validation/Cairn.app   # fixture: /tmp/cairn-v0-fixture
```

V0 交互清单逐项见计划 §6「V0：真实 AppKit 流程」；重跑时按步骤记录 PASS/FAIL/SKIP/BLOCKED 并更新本文件。
