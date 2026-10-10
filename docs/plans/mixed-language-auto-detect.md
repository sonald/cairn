# 自动探测的混合语言项目：设计与实施计划

状态：待实现。2026-10-10 定稿；Fable 负责需求、设计与验收，实现交给其他 Agent。完成后把仍有效的结论归入 [product.md](../product.md) 与 [architecture.md](../architecture.md)，删除本文件。

## 0. 结论与范围

打开项目不再选择语言。项目包含哪些受支持语言由捕获遍历直接得出，单语言只是混合的退化情形。本计划把 L3（2026-08）留下的"用户显式选择 1–3 门语言"改为"按内容探测"，并把它当时为了保守而留下的几条分叉收掉：两条打开管线、单语言与多语言不同的 unit root 规则、同语言多单元直接失败、非 Git 目录只能单语言。

不在本计划内：JavaScript 分析（`LanguageID.javascript` 继续被拒绝，`.js/.jsx` 只预览）；每语言多个分析单元（§3.4 定义了 V1 的降级规则和 V2 的扩展点，V2 另立任务）；零受支持语言的"只浏览"模式；CLI 一次多语言；按文件内容（shebang、编码声明）嗅探语言。

## 1. 目标行为

### 打开

- 所有入口（文件 → 打开项目…、最近项目、拖放、Launch Services、Retry、会话恢复）都不询问语言，也没有任何语言菜单项。
- 语言集合 = 捕获遍历中按后缀分类命中的语言，排序去重：`.rs` → Rust；`.py` → Python；`.ts`（不含 `.d.ts`、`.mts`、`.cts`）与 `.tsx` → TypeScript。遍历与索引共用同一次 `ProjectTreeWalk`，因此路径规则、默认跳过目录与符号链接规则天然一致，没有条目上限。
- 探测到零门语言时打开失败，状态栏/空状态显示原因："没有找到受支持的源码（Rust、Python、TypeScript）"。这与今天"对话框一个都不预选、Open 禁用"的实际效果一致，只是不再允许用户硬选一门来浏览。
- 非 Git 目录（含仓库子目录，`git_repository_open` 不向上发现）作为目录快照打开：没有提交历史，其余行为相同。今天只有单语言能这样打开，混合会失败。

### 集合的生命周期

- 集合在 worktree 捕获时确定：首次打开、Refresh Index、保存排除规则（已走 Refresh）。
- 切换到 commit 时沿用当前集合（L3 规则不变）：commit 中缺少的语言保留空 session；commit 中多出的语言不分析、只预览。切回 worktree 不重探。
- 重新打开或恢复会话时重新探测（探测对象始终是 worktree）。会话文件的 `languages` 字段继续按 schema 5 写入探测结果，读取时不再使用；恢复 tab 只看文件是否存在、是否可分类。因此恢复一个停在旧 commit 的会话时，worktree 已不再包含的语言在该 commit 里只预览，这是上一条规则的直接推论，不是回归。
- Refresh Index 失败回滚旧 session 时，同时回滚旧集合。

### 分析单元（unit root）

- 每门语言一个 unit root，单语言与混合同一规则（今天单语言固定为 `.`，混合才发现嵌套根）：包含该语言全部源码的最浅 marker 目录；没有 marker 时为 `.`。marker 仍是 `Cargo.toml` / `pyproject.toml` 或 `pyrightconfig.json` / `tsconfig.json`。
- 多个 marker 互不嵌套且没有共同祖先 marker 时（无 workspace 的多 crate、多个独立 Python 子项目），不再失败，而是回退到 `.`：该语言全部源码仍可见、可搜索、有大纲和关系，跨单元的模块身份（Rust `crate::`、Python 包路径）按仓库根近似，与今天单语言项目里嵌套 crate 的行为一致。Exact 从 `.` 启动：Pyright 与 tsserver 在仓库根照常工作；rust-analyzer 遇到根目录没有 `Cargo.toml` 时显示现有的"缺少配置 Cargo.toml"原因。用户加一个 workspace 清单即可恢复 Rust 精确分析；彻底解决留给 V2（§3.4）。
- 不选"源码最多的单元"：`SnapshotView` 的活动文件按单元根过滤，选任何一个真子集都会让其他单元的源码在语法层消失（无符号、无搜索、无大纲），这比失败更难察觉。
- 把单语言项目也纳入根发现后，嵌套在子目录里的单 crate 会从 `.` 变为该 crate 目录（前提是它包含该语言全部源码），rust-analyzer 从而在正确的目录启动；Cargo.toml 在仓库根的常见情形结果不变。

### 可见性

- 状态栏 profile 项不变：显示当前活动文件所属 profile（语言 · 单元名 · 特性 · 信任）。
- profile 菜单增加一组只读行，每门探测到的语言一行：语言、源码文件数、单元根（`.` 或相对路径）。数据来自 `AppModel` 现有的 `sessionCoverage`（目前 `private static`，需要以一个 `package` 只读属性暴露）。这是删除对话框后唯一展示"探测到了什么"的位置。
- 空状态最近项目列表不再显示 RS/PY/TS 徽标。

### CLI

- `--language` 变为可选。位置类命令沿用按文件后缀推断；项目级命令（`snapshot`、`switch-stats`、`symsearch`、搜索）未给 `--language` 时取探测集合中源码文件最多的语言，并在 stderr 打印所用语言。CLI 仍是一次一门语言，这是保留的限制。

## 2. 现状与受影响代码

- 打开路由与对话框：[CodeInsightApp.swift](../../Sources/CodeInsightApp/CodeInsightApp.swift) 662–700（`openProject`/`openPythonProject`/`openTypeScriptProject`/`chooseProject`/`chooseLanguagesProject`）、735（`PendingOpenRequest.languages`）、880–970（`openProjectIdentity` 的语言解析顺序）、985–1150（`presentLanguageSelection`、`languageProbe*`、`preselectedLanguages`、`LanguageSelectionGate`、`LanguageSelectionAlert`、`makeLanguageSelectionAlert`）、1886–1887 与 2113–2114（菜单项）。
- 窗口层：[MainWindowController.swift](../../Sources/CodeInsightApp/MainWindowController.swift) 167–175（`lastOpenedProjectLanguage(s)`、`pendingRecentProjectLanguages`）、829–925（`openProject(root:)`、`openProject(root:language:)`、`openProject(root:languages:)`、`openRecentProject`、`openProjectWithSavedSession(overridesSavedLanguages:)`、`openProjectFresh` 的 `count > 1` 分叉、`retryLastOpenedProject`）、943、3353–3359（Recents 记录语言）、3663–3680（`recentLanguageLabels`）；[EmptyStateView.swift](../../Sources/CodeInsightApp/EmptyStateView.swift) 的 `languageLabel`；[ReaderViewController.swift](../../Sources/CodeInsightApp/ReaderViewController.swift) 1675/1691/1708 的 `recentLanguages` 参数。
- 模型层：[AppModel.swift](../../Sources/CodeInsightAppModel/AppModel.swift) 44–140（`IndexService` 协议及其单语言默认实现）、181–330（`ProjectIndexService` 的 `index(root:language:)`、`captureSnapshot(language:)`/`(languages:)`、`prepareSnapshot`、`prepareSnapshots` 含 `GitRepository` 守卫）、485–488（`projectLanguages`、未使用的 `projectLanguage`）、1131–1190（`beginWorkspaceOpen(languages:)`、`openProject(root:languages:)`）、1258–1340（`restoreSession(overridingLanguages:)` 与两处 `languages.count == 1` 分叉）、1588–1660（同步单语言 `openProject(root:language:)`、`canPublishProjectResult(language:)`、`finishIndexing`）、1783（`refreshIndex` 的非空集合守卫）、3215–3310（`snapshotLoadTask(languages:)`）、3323（`publishFirstPaint(languages:)`）、3405–3420（`canPublishWorkspaceResult(languages:)`）、3552–3575（`querySessionTuples` 的 `count == languages.count`）、4065–4099（`sourceFileCount(languages:)`、`validateProductSupport`）。
- Exact：[ExactCoordinator.swift](../../Sources/CodeInsightAppModel/ExactCoordinator.swift) 1520–1530（`providerRelativeRequestPath` 对前缀外路径返回 nil，§3.3 说明为何项目内文件到不了这里）；[ExactProvider.swift:228](../../Sources/CodeInsightExact/ExactProvider.swift)（Rust 根无 `Cargo.toml` 的现有原因）。
- 引擎：[ProjectIndexer.swift](../../Sources/CodeInsightEngine/ProjectIndexer.swift) 72–195（目录导入 `index(root:language:)`，CLI 1513、GoldSet 27 与 `ComposableSearchTests` 使用）、201–345（`prepareSnapshot(language:discoverUnitRoot:)`：每门语言各读一遍全部文件字节、各建一份 manifest）、348–385（`validatedProfiles`、`profile(discoverUnitRoot:)`）、427–445（`indexSnapshot`，CLI `switch-stats` 使用）；[ProfileDetector.swift](../../Sources/CodeInsightEngine/ProfileDetector.swift) 86–114（`unitRoot`）、168–173（`multipleUnits`）；[ProjectIndexStore.swift](../../Sources/CodeInsightEngine/ProjectIndexStore.swift) 103–160（`SnapshotView.init` 按单元根过滤活动文件并以它为 `ModuleMap` 的根，这是 §3.4 不选真子集的原因）。
- 核心与 Git：[ContentIndex.swift](../../Sources/CodeInsightCore/ContentIndex.swift) 19–86（`classify(path:language:)`、`classify(path:languages:)`、`normalize`）；[Manifest.swift](../../Sources/CodeInsightCore/Manifest.swift) 37（`FileOccurrence.detectedLanguage`，今天只按所选语言填）；[GitSnapshot.swift](../../Sources/CodeInsightGit/GitSnapshot.swift) 82–91（`Snapshot` 协议）、256–268（`CommitSnapshot.configurationPaths` 已不按语言过滤）、316–370（`WorktreeSnapshot` 三个 init，`languages` 只用于过滤 `configurationPaths`）、445–456（`configurationLanguage`）。
- 持久化：[RecentProjectsStore.swift](../../Sources/CodeInsightAppModel/RecentProjectsStore.swift) 全部语言 API 与 `Cairn.RecentProjectLanguages` 键；[SessionCodec.swift](../../Sources/CodeInsightAppModel/SessionCodec.swift) 15/93（`languages`、`language`）、355（解码校验）、600–650（v1 迁移）。
- 快捷键与文案：[KeyBindings.swift](../../Sources/CodeInsightAppModel/KeyBindings.swift) 136–137、298–299；两份 `Localizable.strings` 的 `app.open.languages`、`app.open.languageDetail`、`app.menu.open.python.project`、`app.menu.open.typescript.project`；[README.md:42](../../README.md)、[README.zh-CN.md:42](../../README.zh-CN.md)、`product.md` 的"项目、快照与窗口"、`architecture.md` 的"身份与源码事实"。
- CLI：[CodeInsightCLI.swift](../../Sources/CodeInsightCLI/CodeInsightCLI.swift) 37–59（`--language` 默认 rust 与 `languageID(inferringFrom:)`）、98/193/276/374（`WorktreeSnapshot(repositoryURL:)` Rust 便捷 init）、1513。
- 自测：[SelfTestLaunch.swift](../../Sources/CodeInsightApp/SelfTest/SelfTestLaunch.swift) 568–596（对话框布局自测）；[SessionSelfTest.swift](../../Sources/CodeInsightApp/SelfTest/SessionSelfTest.swift) 961–984（`languagePickerOverride` 取消/重试）；[LanguageSelfTest.swift](../../Sources/CodeInsightApp/SelfTest/LanguageSelfTest.swift) 2094–2140（`--self-test-mixed` 合成 fixture）；[ExactSelfTest.swift](../../Sources/CodeInsightApp/SelfTest/ExactSelfTest.swift) 2534（`ExactSelfTestIndexService`）。
- 测试：`MainWindowControllerTests`（12 处 picker/preselection，含 `languagePreselectionMatchesContentAndStoredPreference`）、`MultiWindowLifecycleTests`、`SessionOpenBoundaryTests`、17 个文件共 27 处 `openProject(root:language:)` 与 41 处 `openProject(root:languages:)`、`SnapshotSwitchTests` 的 mixed 系列、`SessionRestoreTests` 452–620、`SnapshotIndexerTests` 的 `ambiguousIndependentRootsFailBeforeSnapshotReadOrStoreWrite`、`publicSingletonIndexKeepsRootProfileWhileStrictOverloadRejectsMarkerOutsideSource`、`activeViewKeepsUnionManifestButExcludesPathsOutsideManualUnitRoot`、`ProfileDetectorTests`、`RecentProjectsStoreTests`、`SessionCodecTests`、7 个测试内 `IndexService` 替身。

## 3. 设计约束

### 3.1 语言集合是快照的输出

- `Snapshot` 协议新增 `var languages: [LanguageID] { get }`（探测结果，按 `rawValue` 排序去重）。`WorktreeSnapshot` 与 `CommitSnapshot` 在构造时从捕获路径计算；`ProfileSnapshot`（Exact 内部包装）透传。
- `WorktreeSnapshot.init(repositoryURL:pathRules:)` 删除 `languages:` 参数与两个便捷 init。`configurationPaths` 收录全部已知配置文件，不再按语言过滤，与 `CommitSnapshot` 一致。
- `GitRepository` 打开失败且错误是 `GitError.git(operation: "git_repository_open", code: GIT_ENOTFOUND, _)` 时（`CommitLog.swift:37` 已用同一判别），`WorktreeSnapshot` 以所选目录为根、`objectFormat = .sha1` 继续；权限、I/O 等其他错误照常抛出。`CommitPickerModel.load` 对非仓库保持空历史。
- `LanguageMode`：新增 `static let supported: [LanguageID] = [.rust, .python, .typescript]` 与 `classify(path:)`（遍历 `supported`，后缀互斥所以顺序无关），只用于快照探测。`classify(path:languages:)` 保留：`languageMode(for:)`、`capturedProjectSource`、`sourceFileCount` 和 manifest 构建都必须按当前固定集合分类，否则 commit 中多出的语言会被路由成"无 session 的受支持文件"（Reader 显示 unsupported）而不是非源码预览。删除 `normalize`：集合只由探测构造，不再需要校验。`validateProductSupport` 与 `validateExactLanguage` 保留给 JavaScript 枚举值。

### 3.2 一条管线、一份 manifest

- `IndexService` 协议收敛为：`captureSnapshot(root:revision:)`、`prepareSnapshots(_:root:languages:)`、`completeSnapshot`、`flushPersistentIndexCache`、`setPathRules`。`languages` 只在 `prepareSnapshots` 保留，因为 commit 切换要为当前集合建 session（含空 session）；worktree 打开传 `snapshot.languages`。删除 `index(root:language:)`、单语言 `captureSnapshot`/`prepareSnapshot` 及扩展里的全部默认实现；更新 7 个测试替身与 `ExactSelfTestIndexService`。
- `ProjectIndexer.prepareSnapshots(_:into:languages:)` 一次遍历：读每个文件一次，用 `classify(path:languages:)` 对当前集合分类得到 `detectedLanguage`（语义与今天相同：命中集合中的语言），建一份 `SnapshotManifest`；为每门语言收集 `ExtractionInput` 与缓存草稿；每门语言一个 `PreparedSnapshot`，共享 manifest 与 store；profile 用 `ProfileDetector.detect(snapshot:language:sourcePaths:configurationPaths:)`（统一发现单元根）。`snapshotStats` 与 `sessionCoverage` 已按语言过滤，无需改动。今天混合打开要读 N 遍字节，改后读一遍；L3 P0b 记录的"重复 read"问题随之消失。
- 单语言公开入口 `prepareSnapshot(_:into:language:)`、`indexSnapshot(_:into:language:)`、`index(root:language:)` 保留给 CLI、GoldSet 与引擎测试，但改为调用 `prepareSnapshots` 取单元素，因此也获得统一的单元根规则（`publicSingletonIndexKeepsRootProfile…` 中"保持 `.`"的断言随之删除）。可选：把 `index(root:language:)` 改写为 `indexSnapshot(WorktreeSnapshot(repositoryURL:))`，删掉目录导入的那套 `FileInput`/`hasErrors` 重复实现；不阻塞主线。
- `AppModel`：
  - 公开入口只剩 `openProject(root:)`；`beginWorkspaceOpen(root:)` 把 `projectLanguages` 置空；`snapshotLoadTask` 在捕获完成、回到主线程后，仅当 `revision == nil` 时写入 `projectLanguages = snapshot.languages`，空集合直接 `failWorkspace` 并带原因；随后 `publishFirstPaint`、`prepareSnapshots(languages: projectLanguages)`。
  - `canPublishWorkspaceResult(generation:root:)` 去掉 `languages` 参数：每次打开、刷新、切换都递增 generation，集合又只在任务内写入，比较集合不再有独立含义。随之删除 `canPublishProjectResult(language:)`、`finishIndexing`、同步的 `openProject(root:language:)`、`restoreSession` 的 `overridingLanguages` 与两处 `count == 1` 分叉、`snapshotLoadTask`/`publishFirstPaint`/`failWorkspace`/`installWorkspaceSessions`/`refreshIndexDid*` 的 `languages` 形参。
  - `refreshIndex` 的守卫改为 `case .ready`；`refreshRestoreState` 同时保存/回滚 `projectLanguages`。
  - `querySessionTuples`、`installWorkspaceSessions`、`validatedWorkspaceSessions` 继续以 `projectLanguages` 校验 session 集合，语义不变。
  - 删除未使用的 `projectLanguage` 单数 getter；`sourceFileCount(languages:)` 改用 `classify(path:)`。
- 会话：`SessionCodec.Snapshot.languages` 继续写入 `projectLanguages`；解码时保留现有结构校验（损坏隔离），但 `restoreSession` 不读它。schema 版本不变。

### 3.3 Exact 不变

- 仍只为活动文件所属 profile 启一个 provider（warm budget = 1），文件切换跨语言时按现有 `selectFile` → `prepareExact` 切换；`ExactCoordinator` 不改。
- 不变量：引擎单元根总是包含该语言全部源码（§3.4 规则保证），Exact 的 `profilePrefix` 等于引擎单元根，因此 `providerRelativeRequestPath` 对项目内文件不会返回 nil，不需要新的"单元外"原因。
- 回退到 `.` 的 Rust profile 在根目录没有 `Cargo.toml` 时，`ExactProfileKey` 已经抛 `ExactError.missingConfiguration("Cargo.toml")`（[ExactProvider.swift:228](../../Sources/CodeInsightExact/ExactProvider.swift)），通过现有 readiness 展示；不新增文案。

### 3.4 单元根规则（V1）与扩展点（V2）

- `ProfileDetector.unitRoot(language:sourcePaths:configurationPaths:)`：源码为空 → `.`；marker 为空 → `.`；存在包含全部源码的 marker 根 → 最浅者（现规则）；否则 → `.`。删除 `multipleUnits`。规则保证返回的根总是包含该语言全部源码，`SnapshotView` 的活动过滤因此不会丢文件。
- V2（另立任务，本计划不做）：每语言 N 个 profile。触点已经明确：`workspaceSessions` 已按 `AnalysisProfileID` 键控；`routedSession(for:)` 改为按（语言，包含该文件的最深单元根）路由；`prepareSnapshots` 给每个单元一个按路径前缀过滤的 `PreparedSnapshot`；`querySessionTuples` 的 `count == languages.count` 改为按 profile 列表校验；Exact 跨单元切换复用现有 provider 切换。V1 的 `.` 回退在 V2 下被多个单元取代，期间没有需要撤销的中间状态。

### 3.5 App 层删除清单

- `AppDelegate`：`openPythonProject`、`openTypeScriptProject`、`chooseProject(language:)`、`chooseLanguagesProject` 合并为一个 `openProject(_:)`（NSOpenPanel → `enqueueOpenRequest(root:sourceWindow:)`）；`PendingOpenRequest.languages`、`openProjectIdentity` 中"已打开项目上显式换语言"的分支、`presentLanguageSelection`、`languagePickerOverride`、`languageProbeSkippedDirectories`、`languageProbeEntryLimit`、`preselectedLanguages`、`LanguageSelectionGate`、`LanguageSelectionAlert`、`makeLanguageSelectionAlert`。打开流程变为：显式路径 → 已打开则激活 → 有会话则恢复 → 否则 `openProject(root:)`。
- `MainWindowController`：`openProject(root:)` 一个入口；`openProjectWithSavedSession(root:forcingReopen:)`；删除 `lastOpenedProjectLanguage(s)`、`pendingRecentProjectLanguages`、`recentLanguageLabels`、`onChooseProjectLanguage` 回调改为直接 `openProject`。
- `EmptyStateView`/`ReaderViewController`：删除 `recentLanguages`/`languageLabel`。
- `RecentProjectsStore`：只剩 `record(_:)`、`paths`、`clear`；删除语言 API，`init` 中删除旧键 `Cairn.RecentProjectLanguages` 一次。
- `KeyBindings`：删除 `fileOpenPythonProject`、`fileOpenTypeScriptProject` 及其定义；用户覆盖里残留的 ID 因没有对应定义而自然失效。
- 文案：删除 4 个键；新增 `model.app.noSupportedSources`、`main.profile.detected`（profile 菜单行）中英文；`bash scripts/ci.sh static` 校验双语一致。
- 自测：删除 `SelfTestLaunch` 的对话框布局段；`SessionSelfTest` 961–984 改为"打开 C 直接就绪且 `projectLanguages == [.rust]`"；`--self-test-mixed` 改为不传语言打开并断言探测集合为 `[.rust, .python, .typescript]`、三门语言各自 Exact 可用；`ExactSelfTestIndexService` 按新协议实现。

### 3.6 其他约束

- 不加依赖；不改 `ContentIndexKey`、缓存 codec、`AnalysisProfileID` 的派生方式；不改 `ExactOverlay.ReuseKey`。
- `FileOccurrence.detectedLanguage` 与 `nonSourcePathCount` 语义不变（按当前集合分类），`LanguageSelfTest` 1004–1024、1566–1595 的断言不受影响；全语言分类只发生在 `Snapshot.languages`。
- 分支：在 `main` 之外的分支上提交，英文简短提交信息；验收前 rebase 到最新 `main`，不用 merge。

## 4. 实施顺序

每步结束都要能 `swift build` 并通过该步列出的测试；步骤 1–2 期间保留旧签名作薄包装，步骤 3 一次删除。

1. **快照探测**（Core、Git）：`LanguageMode.supported`/`classify(path:)`；`Snapshot.languages`；`WorktreeSnapshot` 新增 `init(repositoryURL:pathRules:)`，旧的带 `languages:` 的 init 转发给它直到步骤 3 删除；配置清单不过滤；非仓库目录退化；`CommitSnapshot.languages`。`normalize` 暂留。验证：`CODEX_SANDBOX=1 bash scripts/ci.sh core`。
2. **共享 manifest 与单元根**（Engine）：`prepareSnapshots` 一次遍历；单语言入口改为委托；`ProfileDetector.unitRoot` 对互不嵌套的 marker 回退 `.` 并删除 `multipleUnits`；`ambiguousIndependentRootsFailBeforeSnapshotReadOrStoreWrite` 改为断言根为 `.` 且两个单元的源码都在活动视图内；更新 `SnapshotIndexerTests`、`ProfileDetectorTests`。验证：`CODEX_SANDBOX=1 bash scripts/ci.sh engine`，另跑 `swift test --filter "SnapshotIndexer|ProfileDetector|ComposableSearch"`。
3. **模型收敛**（AppModel）：`IndexService` 新协议与 `ProjectIndexService`；`openProject(root:)`；集合在任务内写入；守卫去掉 `languages`；删除同步单语言路径与恢复分叉；Refresh 回滚集合；`RecentProjectsStore`、`KeyBindings`、`SessionCodec` 读取侧；删除 `normalize`；更新 `SnapshotSwitchTests`、`SessionRestoreTests`、`AppModelTests`、`RecentProjectsStoreTests` 与测试替身；`KeyBindingsTests` 加一条含已删 ID 的覆盖文件仍可加载。验证：`CODEX_SANDBOX=1 bash scripts/ci.sh app`（AppModel 部分）。
4. **App 层删除与 profile 菜单**（App）：§3.5 清单；`openProjectIdentity` 简化；profile 菜单探测行；文案；自测；更新 `MainWindowControllerTests`、`MultiWindowLifecycleTests`、`SessionOpenBoundaryTests`、`LocalizationTests`。验证：`bash scripts/ci.sh static`，`CODEX_SANDBOX=1 bash scripts/ci.sh app`。
5. **CLI**：`--language` 可选与"源码最多的语言"默认；`WorktreeSnapshot(repositoryURL:)` 调用改为新 init。验证：`swift run codeinsight snapshot --project <mixed>` 与 `--language python` 各一次。
6. **文档与验收**：`product.md`"项目、快照与窗口"改写打开与探测规则、集合生命周期（含恢复停在旧 commit 的会话时已删语言只预览）、单元根 V1 规则与多独立单元下 Rust Exact 的限制、非 Git 目录、零语言失败；`architecture.md`"身份与源码事实"补"语言集合是快照输出、manifest 每快照一份、单元根规则"，模块表的 `ProfileDetector` 一句；`README.md:42` 与 `README.zh-CN.md:42` 改为"打开项目"；§5 的原生验收与性能样本；最后删除本文件。

## 5. 验证

| 机制 | 验证 |
| --- | --- |
| 探测与配置清单 | Git 测试：worktree 与 commit 快照对同一 fixture 得到相同 `languages`；`.d.ts`/`.js` 不计；排除规则下的目录不计；非仓库目录快照可构造且 `languages` 正确 |
| 一份 manifest | `SnapshotIndexerTests`：混合 fixture 下三个 `PreparedSnapshot` 的 `manifest` 同一实例、每个文件只读一次（用计数快照替身）、各语言 stats 与改前一致；`pythonAndRustSameContentKeysStayIsolated` 继续通过 |
| 单元根 | `ProfileDetectorTests`：互不嵌套的 marker 回退 `.`；现有嵌套根、零源码、越界路径用例不变。`SnapshotIndexerTests`：回退后两个单元的源码都有内容索引 |
| 集合生命周期 | `SnapshotSwitchTests`：不传语言打开混合 fixture 得到 `[.rust, .python, .typescript]`；切到零 TS 的 commit 仍保留空 TS session；Refresh 后新出现的 `.py` 文件使集合增加一门；Refresh 失败回滚集合；零语言目录打开进入 `.failed` 且原因正确 |
| 会话恢复 | `SessionRestoreTests`：保存 `languages == [.python]` 的会话在现已含 Rust 的 worktree 上恢复后集合为探测结果，Python tab 照常恢复；`mixedRestoreOpensFullSetAndRestoresEachTabByMode` 改为不传语言 |
| 打开流程 | `MainWindowControllerTests`/`MultiWindowLifecycleTests`：打开不出现对话框、拖放与 Recents 直接就绪；删除 12 处 picker 用例 |
| 文案与快捷键 | `bash scripts/ci.sh static`；`KeyBindingsTests` 中含已删 ID 的覆盖文件仍可加载 |
| 原生端到端（打包应用） | 三个输入：L3 验收用的真实混合仓库（含 `crates/qrcode2txt`、`tools/model-files-web`）、单语言 tokio、一个非 Git 的混合目录。路径：打开 → 无对话框 → 文件树与状态栏 → profile 菜单列出探测行 → 分别在 `.rs`/`.py`/`.ts` 文件上 ⌘点击定义与 hover → 切一个历史 commit 再切回 → Refresh Index → 关窗重开恢复会话。若手头有无 workspace 的多 crate 仓库，再验证：打开成功、两个 crate 的符号都可搜索、状态栏 Rust 单元为 `.`、Exact 显示缺少 Cargo.toml。记录构建 SHA、操作、结果与截图；分别标 PASS/FAIL/BLOCKED |
| 性能样本 | tokio 冷打开 firstPaint/cachedReady/fullReady 改前后各 3 次（单语言不得变慢）；混合仓库冷打开改前后各 3 次（预期变快，1 次读取替代 3 次）。只记录方向，不做 p95 |
