# M1–M13 系统评审问题修复计划

> 状态：已批准执行（2026-09-01）。
>
> 规划基线：`7fbb239e1736a1272a3ee1a3637ef7374195b97b`。实施基线
> `REMEDIATION_BASE` 必须是包含本计划的提交；最终验收记录该完整 SHA。

## 0. 目标与边界

本轮只修复系统评审已经取得证据的问题：

1. M13 单语言项目打开后 `BookmarkModel.workspaceGeneration` 未同步，导致已保存的
   跨快照书签和 Attempt 消息可能被静默丢弃；
2. M13 bookmark/restart 自测未进入正式产品门禁，且纯黑主窗口截图会被判为 PASS；
3. M10/M11 产品化验收仍缺真实 bundle 的 Trail → Reading Set → 重启闭环；
4. `design.md`、L1/L2/L3/M13 计划状态、README 与实际产品范围不一致；
5. 当前只完成 ad-hoc bundle，不应写成已完成 Developer ID 公证发布；
6. 仓库内可控的 Swift 编译 warning 未清零。

明确不做：JavaScript 实现、Trail 持久化、Reading Set 整理能力、书签跨 commit
映射、SQLite、RepoIdentity、新 manager/registry、ScreenCaptureKit 抽象层、正式
Developer ID 公证。公开分发出现真实需求和凭据后再单独验收公证。

## 1. 执行与评审分工

- 代码和脚本实现：Luna，reasoning effort `max`；
- 主代理：冻结基线、逐片 RED/GREEN 复核、代码审查、真实 AppKit/bundle 验收、
  提交控制与最终结论；
- 每片只改列出的文件，先红测后最小修复；
- `.claude-trace/`、Gold、fixtures、Prototypes、正式 App Support 不修改；
- 不为并行或未来需求增加新类型。已有函数能承担职责时直接复用。

## 2. 实施切片

### S1 — M13 generation 正确性

**依赖**：`REMEDIATION_BASE`。

**允许文件**：

- `Sources/CodeInsightAppModel/AppModel.swift`
- `Tests/CodeInsightAppModelTests/BookmarkModelTests.swift`
- 必要时 `Tests/CodeInsightAppTests/MainWindowControllerTests.swift`

**RED**：通过真实单语言入口打开项目后，立即点击一个已保存的 commit 书签；修前
必须证明 strict jump 被 generation guard 拒绝。另覆盖同代 Attempt 消息和 feature
selection 导致 generation 变化时旧 Attempt 清除。

**实现**：所有会使 workspace generation 失效的既有入口同步调用
`bookmarkModel.workspaceDidChange(to:)`。不新增 generation manager/helper type。

**验收**：

- 单语言、mixed、snapshot switch、feature switch 四条路径无串线；
- exact jump 成功只增加一条 history；失败不移动 UI/history；
- `BookmarkModelTests`、`MainWindowControllerTests`、`SnapshotSwitchTests` PASS。

### S2 — M13 产品门禁与视觉证据

**依赖**：S1。

**允许文件**：

- `Sources/CodeInsightApp/CodeInsightApp.swift`
- `Tests/CodeInsightAppTests/MainWindowControllerTests.swift`
- `Scripts/run-product-gates.sh`
- `.github/workflows/product-quality.yml`

**RED**：构造纯黑 bitmap，证明现有视觉判据错误地接受；证明产品门禁不执行
`--self-test-bookmarks` / `--self-test-bookmarks-restart`。

**实现**：

- 截图只有在主窗口和 Bookmark Panel 均含可见像素变化时才 PASS；CGWindow 返回
  纯黑时使用已有 AppKit view-cache 路径，不新增截图框架；
- 保留现有 17 通道合同，在 `run-product-gates.sh` 追加隔离的 bookmark + restart
  产品门，使用唯一 session/export/capture 目录；
- 校验 bookmark JSON summary、restart summary、三主题非空视觉证据、正式数据零写；
- workflow 上传新的 bookmark gate artifact。

**验收**：

- 纯黑截图 RED、非空 AppKit 截图 GREEN；
- bookmark/restart 任一失败都会使产品门 exit 非 0；
- 既有 17 通道计数和 mixed/real-provider/Gold 合同不变。

### S3 — M10/M11 真实产品闭环

**依赖**：S2；不修改生产代码，除非真实运行复现新的产品缺陷并先补计划。

**允许文件**：

- `docs/plans/evidence/m10-m11-productization/m10-m11-productization-acceptance.md`
- 新增本轮真实截图/AX/命令证据

**真实任务**：

1. 唯一 bundle id、空 App Support 启动；
2. 通过真实 `NSOpenPanel` 和 `Choose Languages` 选择语言并打开项目；
3. 从 Relations 打开 Resolution Inspector，完成一次语义导航；
4. 形成 A → B → Back → C 分支并 Restore；
5. 分别执行 Freeze Path 与 Freeze Results，打开 Reading Set；
6. 正常 Quit，重启同一 bundle，证明 Reading Set 恢复且 Trail 为空；
7. 保存关键窗口截图和 AX 文本；正式 `dev.cairn.Cairn` 数据指纹不变。

**验收**：上述任务逐项 PASS；无法操作真实 UI 时保持 BLOCKED，不用 self-test 或
预写 session 冒充。

### S4 — 文档与发布口径收口

**依赖**：S1–S3 的真实结果。

**允许文件**：

- `docs/design.md`
- `docs/plans/l1-python-plan.md`
- `docs/plans/l2-typescript-plan.md`
- `docs/plans/l3-mixed-language-plan.md`
- `docs/plans/m13-plan.md`
- `README.md`
- `README.zh-CN.md`

**实现**：

- JavaScript 改为 deferred/unsupported，不补半成品实现；
- 更新 M5–M13 里程碑事实和 L1/L2/L3/M13 状态 banner；
- README 增加书签入口、状态、数量/笔记边界和不支持 surface；
- 发布状态明确为 ad-hoc bundle 可构建，Developer ID/notarization 尚未执行。

**验收**：中英文 README 同构；产品支持矩阵、代码 validator、设计与计划状态一致；
不承诺未验证能力。

### S5 — 可控 warning 与总验收

**依赖**：S4。

**允许文件**：只限本轮 build 实际报告 warning 的 App/test 文件。

**实现**：删除无效 `try`、未使用结果和含糊 trailing closure 等机械 warning；S2
移除 bookmark 自测对 deprecated `CGWindowListCreateImage` 的依赖。Homebrew/Wasmedge
宿主 linker 搜索路径不属于仓库修复范围，单列环境噪声。

**总验收**：

```bash
git diff --check "$REMEDIATION_BASE"
CODEX_SANDBOX=1 CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" bash Scripts/ci.sh
bash Scripts/run-product-gates.sh <python> <typescript> <mixed>
```

并执行：

- 100,000 行 dedicated open `< 2.5s`；
- M13 bookmark/restart 产品门；
- 唯一 ad-hoc bundle `plutil`、`codesign --verify --strict`、LaunchServices 启动、正常退出；
- M10/M11 真实任务矩阵；
- 当前分支远端 workflow 到 terminal success；未经用户授权不 push；
- tracked/staged/untracked 并集仅含本计划允许范围，`.claude-trace/` 保持用户状态。

## 3. 停止条件

- S1 不能用现有 generation seam 修复，需要新状态系统；
- S2 需要新截图框架或改变 17 通道参数合同；
- S3 真实 UI 复现产品缺陷且需要超出 allow-list 的代码；
- 任一切片破坏只读、安全、captured-source、session-only Trail 或 frozen-evidence
  Reading Set 合同；
- 正式公证缺凭据时如实记 `NOT RUN`，不得伪造 PASS，也不阻塞本轮“口径修正”。

## 4. 完成定义

S1–S5 均有 RED/GREEN 或真实产品证据；自动门禁、bundle、M10/M11 live journey、
文档事实和范围审计全部通过；无未解释失败、假绿截图或待处理计划项。最终新增
`docs/plans/evidence/m1-m13-remediation-acceptance.md`，逐项记录命令、退出码、
测试数、bundle id、截图、远端 run 和未适用项。
