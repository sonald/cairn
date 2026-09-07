# S3a — 收敛项目打开与代际清理：逐片记录

## RED（2026-09-07）

3 个行为守护测试先于重构运行：

- `openingASecondProjectCancelsTheInFlightMultiLanguageOpen`：**RED**——多语言打开 A 阻塞在 full 阶段时打开 B，A 从不被取消（`wasCancelled("first")` fuse 120s 超时），只是靠 generation 守卫放弃，持续占用捕获资源。
- `openingASecondProjectPublishesOnlyTheSecondForSingleLanguage`：守护（改造前即通过，防止重构倒退）。
- `singleLanguageOpenSharesTheWorkspaceResetBoundaries`：守护——单语言打开与其他入口共享同一重置边界（tabs/Trail/history/选中文件/compare/notice/refresh 全清）。

## 实现（`AppModel.swift`）

1. 抽出 `beginWorkspaceOpen(root:languages:) -> UInt64`：两个 open 入口共用的取消/代际推进/bookmark generation/Exact invalidate/会话与 UI 状态重置的单一实现（原先两份近似复制，字段顺序略有出入）。单语言入口的 `transition` 早退 assert 移除，与多语言行为一致。
2. 多语言 `openProject(root:languages:)` 的 ~90 行内联发布链删除，改为复用 S2c 抽出的 `snapshotLoadTask`（与快照切换、Refresh Index 同一条分阶段发布链），并存入 `snapshotTask`——打开 B 现在真正**取消**进行中的 A（RED→GREEN 的行为修复）。
3. `openProject(root:language:)` 保留 `index()` 链（普通非 Git 单语言 fallback），错误原样进入 `.failed`，不重新分类为"不是 Git 仓库"（错误原因呈现归 S3b）。
4. 不引入新 coordinator 类型；对外入口签名不变（`restoreSession` 依赖的同步 generation 推进保持）。

## GREEN

- 3 新测试全绿（含 RED 项）。
- `AppModelTests|SnapshotSwitchTests|SessionRestoreTests|ExactCoordinatorTests|SearchPanelModelTests|BookmarkModelTests|ReadingSetTests|TabStripModelTests`：332 通过（会话恢复、快照切换、刷新、书签代际不倒退）。
- UI 批（Relation/MainWindowController/NonSource）：59 通过。
- `scripts/ci.sh` 计数 870→873。

## 验收对照（计划 §5 S3a）

- 1 语言（含普通目录）、多语言打开、切版本、切配置生命周期一致：共享 `beginWorkspaceOpen` + 共享发布链；重置范围与 D2（刷新/切换不重置 tabs/Trail）明确区分。✅
- 加载 A 中打开 B 只有 B 发布，且 A 被取消。✅（多语言 RED→GREEN；单语言既有机制守护）
- bookmark generation/Exact 关闭/Compare 清理/pending replay/Trail/tabs 重置范围一致。✅（守护测试 + 332 既有套件）
- 本切片只做结构收敛，无 UI 风格修改。✅
