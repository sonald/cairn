# S5 — 当前操作面驱动关系命令：逐片记录

## RED（2026-09-08，对照运行）

3 个新回归（`RelationNavigationTests.swift`，真实引擎 fixture）。将 `showRelations(direction:)` 临时还原为旧的 `contextWindow.selectedCandidate` 实现后重跑：7 处断言失败——

- `keyboardRelationCommandsFollowTheReaderSelection`：无 Context 候选时 Reader 光标处命令无效（审查复现：大纲定位/选中调用点后 ⌘⇧H 不可用）。
- `pinnedContextDoesNotStealRelationCommandTargets`：Pin A 后 Reader 去 B，命令仍查询 A。
- `relationCommandsDisabledOutsideReadableSourceSurfaces`：Markdown 预览面上命令未被禁用。

## 实现（D3）

- `ReaderViewController.currentSelectionByteOffset`：显示源码文档时返回选区/光标字节偏移。
- `MainWindowController.showRelations(direction:)`（全局菜单/快捷键入口）：改用 Reader 当前选区/光标，复用既有右键路径 `handleReaderRelation(offset:direction:)`（文件 + offset → resolve → relation root；references 方向保留 localBinding 快路径，其 manifest contentID 比对即内容身份验证；执行阶段异步 resolve，generation/快照守卫沿用）。Pin 的 Context 预览不再是隐式回退目标——`resolvedCandidate` 在 Pin 模式下只解析不改动预览，Context 仍为 A、Relations 根为 B。
- 菜单 validation 换为廉价检查 `canShowRelationsFromReaderSurface`（selectedFile + 项目路径 + 存在选择偏移；无 I/O、无 Exact、不依赖 first responder——菜单展开改变 responder 不影响判定）。
- Python 产品自测流程同步遵循新语义：命令前 `selfTestNavigate` 把 Reader 选中放到目标符号。

## 顺带修复（既有崩溃，S5 测试暴露）

批跑新增第 3 个 fixture 后确定性崩溃：`NSToolbar _removeItemAtIndex → _enumerateToolbarsInFamily → _itemAtIndex` 越界断言。根因：所有控制器共用 toolbar 标识 "MainToolbar"，AppKit family 同步会把 profile 项的增删镜像到同进程内先前（已关闭/未装配）测试控制器的 toolbar。stash 源码对照复现（崩溃与 S5 逻辑无关）。修复：每实例唯一 toolbar 标识（产品行为不受影响：无自定义/autosave，profile 项本就按控制器渲染）。

## GREEN

- 3 新测试全绿（旧实现对照 7 失败）。
- UI 批（Relation/ContextMenu/MainWindowController/Palette，隔离跳过）：75 通过；隔离 BookmarkPanel 2 通过。
- `AppModelTests|SnapshotSwitchTests|SessionRestoreTests|ExactCoordinatorTests`：335 通过（Relations 面板内切方向、Context 面板操作不倒退——既有用例维持）。
- `scripts/ci.sh` 878→881。

## 验收对照（计划 §5 S5）

- Reader 鼠标/键盘/大纲入口一致：命令与右键同一条 resolve 路径（测试以 caret 位置驱动）。✅
- Pin A 查询 B：Context 仍 A、Relations 根 B。✅
- 不支持 surface（非源码预览）正确禁用且命令无副作用。✅
- 菜单 validation 仅廉价检查；执行阶段异步 resolve + 内容/generation 验证（沿用 handleReaderRelation 既有守卫）。✅
