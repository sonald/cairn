# 架构重构收尾验收

计划：[面向后续阅读功能的架构重构方案](../../2026-09-28-architecture-refactor-plan.md)
日期：2026-09-28
范围：`508cf09`（基线）→ `8f136df`（R7）。纯重构；唯一的可观察行为变化是 R1a 的缺陷修复（已按 Q1 批准）。

## 提交

| 切片 | 提交 | 内容 |
|---|---|---|
| R0 | `f5d329f` | 方案与基线记录 |
| R1a | `42ca4c3` | Exact 回复不再覆盖用户在校验期间的选择 |
| R1b | `64d55d3` | Exact 内容校验只比较哈希，不再构建阅读文档 |
| R1c | `537f8d4` | 混合语言准备路径在锁内读取 store |
| R1d | `a5a5b6a` | 大文件语法加载可取消 |
| — | `acb6dbb` | R1 检查点记录 |
| R2 | `9e6cd99` | `DeclarationShape` 共享声明词汇；`ReaderSyntaxError` 改名；删除 `FileTreeModel` 被忽略的参数 |
| R3 | `5e22539` | Context 候选由结构化 `Basis` 推导标签；有效性检查收拢为一个函数 |
| R4 | `82e0ef2` | `ReadingPlan` 把折叠/焦点决策移到 ReaderCore |
| R5 | `888fd17` | `DecorationComposer` 按装饰层合成渲染属性 |
| R6a | `b9bfa3d` | 侧栏控制器搬到独立文件（逐字节一致）；三份相同的可见性 helper 合并为一份 |
| R6b | `a93b72d` | 侧栏按 `OutlineNode` 渲染，不再读取 `OutlineFacet` |
| R7 | `8f136df` | `SessionCheckpointStore` 从 AppModel 提取会话持久化 |

结构变化：`MainWindowController.swift` 8,581 → 7,539 行；`AppModel.swift` 4,324 → 4,016 行；新增六个文件：`ReadingPlan`、
`DecorationComposer`、`SessionCheckpointStore`、`SidebarViewController`、`DeclarationShape`、`NSViewSelfTestVisibility`。
Sources 与 Tests 合计 32 个文件，+2,882 / −1,896 行。

## 等价性证据

| 切片 | 证据 |
|---|---|
| R2 | 冻结的 Palette 标签表遍历全部 `DeclarationKind` 与 `OutlineKind`；在旧代码上先通过，重构后仍通过 |
| R3 | 5 种确定性 × 7 种调用方式的标签/徽章逐字特征测试，在旧代码上先通过；Exact/依赖徽章由原有 18 处断言固定 |
| R4 | 函数体原样搬移；原有 ReaderUI 折叠/焦点测试未改动并通过；fold 自测与性能门禁计数不变 |
| R5 | 旧三路扫描冻结为 oracle，2,000 组随机输入（含同层重叠区间）逐段相等；reading 自测 4 个样式计数与 R0 相等 |
| R6a | 搬出的 1,038 行与原文件逐字节相同（`cmp`） |
| R6b | 侧栏原生测试（含 CI 独立批次）通过 |
| R7 | 会话恢复、隔离、写保护、旧版迁移、清除、多窗口与书签测试全部通过 |

每条新增测试都做过逐条注入：撤掉对应实现后只有该测试变红，注入均已还原（细节见 [R1](r1.md) 与各次提交）。

## 最终完整 CI

`CAIRN_LIBGIT2=brew CODEX_SANDBOX=1 bash scripts/ci.sh`，于 `8f136df`，exit 0：

- 本地化检查通过（804 个双语键）。
- 主批次 1187 条（R0 基线 1171 + 新增 16），隔离批次 2/2/1/1/1，合计 1194 条，全部报告完成。
- 架构检查通过；5 个应用自测均 `passed:true`。
- fold 性能门禁 `status: pass`；四个 `observed` 计数 8400/8400/4400/200 与 R0 相同；`foldLatencyMs=48.3`（R0 为 49.8），单次样本。

## 原生检查

方法：应用自带的 `--self-test-bookmarks` 在真实窗口中打开固定语料 ripgrep 14.1.1（`4649aa9`，运行前后 `git status`
均为空），并把主窗口与书签面板在三个主题下渲染为 PNG。会话、书签、索引缓存与截图全部写入 scratchpad，不写入真实的
Application Support。本机系统语言为 `zh-Hans`，而该自测按英文菜单标题查找菜单项，因此加 `-AppleLanguages '(en)'` 运行
（不加时以 `menu unavailable` 失败，与代码无关）。

| 对比 | 结果 |
|---|---|
| 打包应用：基线 `508cf09` vs HEAD `8f136df`（同一份用户设置） | 三个主题主窗口**逐像素相同**（差异 0） |
| debug 二进制：基线 vs 基线（重复运行） | Light/Dark 0；SI Classic 1.1 万像素（Exact 状态与焦点时机） |
| debug 二进制：HEAD vs HEAD（重复运行） | 书签面板 11.7 万像素（搜索框焦点、选中行），状态栏时机差异 |
| debug 二进制：基线 vs HEAD | 书签面板 0；主窗口只有 Reading Trail 行与状态栏不同 |

Reading Trail 行的差异用二分法定位到 R5 `888fd17`：R4 两次均与基线相同，R5 两次均不同，且伴随截图时 Exact 状态从
「ready」变为「preparing」。同一份 HEAD 源码的 **release** 二进制两次运行与基线**逐像素相同**，打包应用也相同。结论：这一行的
布局取决于运行时机，而非 R5 的行为——R5 的输出已由 2,000 组逐段对照证明不变。根因是 `ReadingTrailView` 的横向 `NSStackView`
欠约束（面包屑与按钮都没有把剩余空间定死给谁），属于重构前就存在的问题，已另行标记，未在本轮修改。

截图中可见（HEAD）：侧栏 outline 两行 `main`/`example`（R6b）、语法高亮（R5）、阅读高度 Full（R4），三主题均非空白。

### 另行标记的既有问题（本轮未改）

1. Reading Trail 栏的「Branch」徽章位置随时机变化（上文）。
2. 使用用户真实设置的打包应用，浅色主题下文件路径栏为黑底，深色文字不可见；重构前的打包应用完全相同。

## 未运行（NOT_RUN）与实施偏离

- R1c 的 ThreadSanitizer 运行（可选项）。
- R1d 的 3 样本计时；取消行为由确定性测试证明。
- R7 的会话文件逐字节测试；理由见计划 R7。
- 实施偏离（均已写回计划）：R1b 改用 loader 计数代替解析计数；R1d 不在遍历中逐节点检查取消；R2 以 `DeclarationShape`
  为共享词汇、不保留兼容别名；R3 不加入暂无读取方的 `evidence` 字段；R4 用具体行为测试代替自比较的 oracle；
  R7 的恢复写保护留在 AppModel。
