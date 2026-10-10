# 每语言多个分析单元（V2）：设计与实施计划

状态：待实现。2026-10-10 定稿；Fable 负责需求、设计与验收，实现交给其他 Agent。完成后把仍有效的结论归入 [product.md](../product.md)（"打开项目"一节的单元根规则、已知限制表）与 [architecture.md](../architecture.md)（第 26 行"单元根取包含该语言全部源码的最浅 marker 目录"一句），删除本文件。

## 0. 结论与范围

混合语言自动探测（已合入 main，3508dee）给每门语言恰好一个分析单元；多个互不嵌套的 marker（无 workspace 的多 crate、多个独立 `pyproject.toml`/`tsconfig.json`）回退到仓库根 `.`。本计划把这条回退改为"按 marker 划分成多个单元"：每个单元一个 `AnalysisProfile` 和一个 `EngineSession`，按文件所在单元路由，Exact 在正确的单元根启动。

用户可见的变化只有一条：真实混合仓库 `llm-tools` HEAD 里打开 `crates/qrcode2txt/src/main.rs`，状态栏 Rust 精确分析就绪，而不是今天的"缺少配置 Cargo.toml"。

不在本计划内：JavaScript 分析；零受支持语言的只浏览模式；CLI 一次多语言；按内容嗅探语言；单元数量上限（见 §3.5 的已知上限）。

## 1. 目标行为

### 单元划分规则（每门语言独立计算）

1. 该语言在本快照里没有源码 → 恰好一个空单元，根 `.`，不变。worktree 捕获不会出现这种语言；切到 commit 时 `projectLanguages` 沿用 worktree 集合，缺少的语言必须仍得到空 session（product.md："commit 中缺少的语言保留空 session"；LanguageSelfTest 2716-2720 断言历史 commit 的 TS 根为 `.`、0 个文件）。
2. 没有 marker，或存在一个 marker 目录包含该语言全部源码 → 恰好一个单元，根为最浅的那个 marker 目录，否则 `.`。**这一条不变**：tokio 仍然只有一个 Rust 单元，嵌套的单 crate 仍然从 crate 目录启动。
3. 否则（没有任何 marker 覆盖全部源码）→ 划分：每个源码文件归属于其**最深的** marker 祖先目录；没有 marker 祖先的源码归入根单元 `.`。单元集合 = 出现过的归属目录，按路径排序。每个单元的活动文件 = 归属于它的文件，因此嵌套在它下面的其他单元的文件**不**属于它（今天 `SnapshotView` 的前缀包含规则要为此改成"最深单元归属"，见 §3.1）。
4. 同一语言的两个单元推出相同的 `AnalysisProfileID` 时（同名目录 + 相同配置/环境指纹，见 §3.4），这门语言整体回退到今天的单个 `.` 单元，并在 `ProjectIndexer` 的错误/日志里说明原因。不改 `AnalysisProfileID.derived` 的 v1 框架。

marker 仍是 `Cargo.toml`、`pyproject.toml`/`pyrightconfig.json`、`tsconfig.json`（[ProfileDetector.swift:129-149](../../Sources/CodeInsightEngine/ProfileDetector.swift)）。

### llm-tools HEAD（bb6e992）的预期结果

| 语言 | 单元根 | 说明 |
| --- | --- | --- |
| Rust | `crates/qrcode2txt` | 11 个 `.rs`，Exact 就绪 |
| Rust | `tools/semantic-json-viewer/src-tauri` | 22 个 `.rs`，Exact 就绪 |
| Python | `.` | 8 个 `.py`，不变（规则 2） |
| TypeScript | `tools/model-files-web` | 49 个 `.ts/.tsx`，Exact 就绪 |
| TypeScript | `tools/semantic-json-viewer` | 21 个 `.ts/.tsx`（不含 src-tauri 下的），Exact 就绪 |

分析配置菜单列出 5 行（语言 · 源码文件数 · 单元根），不是今天的 3 行。

### 路由与切换

- 选中文件时路由到（该文件的语言，包含该文件的最深单元）的 session；文件不在该语言任何单元内时保持今天的"按语言取第一个"。
- 在同语言的两个单元之间切换文件，`analysisProfileID` 变化 → 现有的 `selectFile` 分支（[AppModel.swift:2975-2981](../../Sources/CodeInsightAppModel/AppModel.swift)）已经会重新发布 `.ready` 并调用 `prepareExact`，Exact 在新的单元根重启。不加第二个热 provider：接受冷启动，与今天跨语言切换一致。
- 项目搜索、符号搜索、关系树、分析配置菜单遍历全部 session（5 个），结果去重规则不变（同一个 store，不会重复提取）。
- Refresh、切 commit、重开/恢复会话：单元集合由每次 `prepareSnapshots` 重新计算；会话文件只存语言（[SessionCodec.swift:15](../../Sources/CodeInsightAppModel/SessionCodec.swift)），不需要迁移。commit 中某门语言的源码分布不同 → 单元集合可以不同，这是预期。

### CLI

CLI 仍一次一门语言。目录导入 `index(root:language:)`（`resolve`、`index`、GoldSet）今天就不做单元发现（[ProjectIndexer.swift:509-523](../../Sources/CodeInsightEngine/ProjectIndexer.swift) 直接 `detect(root:)`），不在本计划内。只有走快照的 `indexSnapshot(_:into:language:)`（`switch-stats`，CLI 443/447）受影响：该语言多个单元时返回活动文件最多的单元，CLI 在 stderr 打印 `unit: <root>`。不做多单元合并输出。

## 2. 受影响代码（行号为 main 3508dee）

- 划分：[ProfileDetector.swift](../../Sources/CodeInsightEngine/ProfileDetector.swift) 62-83（`detect(snapshot:language:sourcePaths:configurationPaths:internPath:)` 返回一个 profile）、85-114（`unitRoot` 返回 `String`，含回退 `.` 的注释）、129-156（`isMarker`、`parentDirectory`、`isWithin`）。
- 索引：[ProjectIndexer.swift](../../Sources/CodeInsightEngine/ProjectIndexer.swift) 23-36（`PreparedSnapshot`，含单个 `cachedSession`/`analysisProfile`）、203-214（`prepareSnapshot(language:)` 取 `[0]`）、219-232（`prepareSnapshots` 每门语言一个 profile）、233-290（按语言槽位 `newInputs`/`missingKeys`/`reusedKeys`——**不改**，提取按语言、`ContentIndexKey` 不含单元）、334-365（每语言槽位建 `SnapshotView` + `PreparedSnapshot`）、367-395（`completeSnapshot` 返回一个 `EngineSession`）、397-417（`indexSnapshot`）、536-546（`validated`）。`IndexService` 协议 [AppModel.swift:54](../../Sources/CodeInsightAppModel/AppModel.swift)、默认实现 131-135；三处顺序 `for item in prepared { completeSnapshot(item) }` 循环 2221-2230、2777-2784、3304-3308；书签安装 `prepared.map(\.cachedSession)` 2163-2166；自测替身 [ExactSelfTest.swift:2545-2557](../../Sources/CodeInsightApp/SelfTest/ExactSelfTest.swift)。
- 活动视图：[ProjectIndexStore.swift](../../Sources/CodeInsightEngine/ProjectIndexStore.swift) 92-168（`SnapshotView.init` 用 `isWithin(root:)` 前缀包含过滤活动文件并作为 `ModuleMap` 根）。另一个 `SnapshotView` 构造点 [EngineSession.swift:172](../../Sources/CodeInsightEngine/EngineSession.swift)。
- 模型：[AppModel.swift](../../Sources/CodeInsightAppModel/AppModel.swift) 294（`workspaceSessions: [AnalysisProfileID: EngineSession]`）、375-382（`querySessions` 的 `count == projectLanguages.count`）、385-394（`detectedLanguageUnits`，已经按 session 出行）、2168-2170（书签安装取 `coverage > 0` 的第一个）、3011-3024（`sessionCoverage` 只按语言过滤 manifest——两个 Rust session 会把对方的文件也算进 total）、3027-3053（`querySessionTuples` 的 `matches.count == 1`）、3056-3083（`installWorkspaceSessions`）、3085-3100（`validatedWorkspaceSessions` 的 `byProfile.count == languages.count`）、3102-3107（`workspaceCoverage`）、3109-3122（`routedSession` 按语言 `first`）、3135-3160（`languageMode(for:)` 按语言 `first` 再查 manifest）、2903-2921（`prepareExact` 已按 session 的 `projectRoot` 传 `profileRoot`，不改）。
- Exact：[ExactCoordinator.swift](../../Sources/CodeInsightAppModel/ExactCoordinator.swift) 506-523（`prepare(profileRoot:)`）、525-560（`prepareSupported` 每次 `invalidate` 后新建 provider，一次只活一个）。不改。
- 搜索面板：[SearchPanelModel.swift:105-148](../../Sources/CodeInsightAppModel/SearchPanelModel.swift) 持有 `[(EngineSession, QueryContext)]`，按数量和逐项比较更新；5 个 session 直接可用，不改。
- 菜单：[MainWindowController.swift:3175-3212](../../Sources/CodeInsightApp/MainWindowController.swift) 遍历 `detectedLanguageUnits`，不改。
- CLI：[CodeInsightCLI.swift](../../Sources/CodeInsightCLI/CodeInsightCLI.swift) 58-86（`resolvedLanguage` 的 stderr 公告，复用其格式）、443-447（`switch-stats` 的 `indexSnapshot`）。1553 的 `index(root:)` 与 GoldSet 不改。
- 测试：[SnapshotIndexerTests.swift](../../Tests/CodeInsightEngineTests/SnapshotIndexerTests.swift) 685-708（`independentUnitRootsFallBackToRepositoryRootAndIndexBothUnits`，断言 `.` 并且两个文件都在活动视图——V2 下断言翻转）、774-789（`singleLanguageEntryDiscoversTheUnitRootThatCoversEverySource`，保持）、838（`nestedRustCrateAndSuperStayInsideUnitRoot`，保持）、876（`activeViewKeepsUnionManifestButExcludesPathsOutsideManualUnitRoot`，保持）；[ProfileDetectorTests.swift:199](../../Tests/CodeInsightEngineTests/ProfileDetectorTests.swift)（单 Rust 单元 + 根 Python，保持）；[AppModelTests.swift](../../Tests/CodeInsightAppModelTests/AppModelTests.swift) 1104（`mixedOpenInstallsNormalizedWorkspaceSessionsAndRoutesByLanguage`，每语言一单元，保持，`querySessions` 顺序断言仍成立）、1551（`makeMixedSymbolWorkspace` 可复用来造多单元夹具）；[ExactCoordinatorTests.swift:231](../../Tests/CodeInsightAppModelTests/ExactCoordinatorTests.swift)（跨语言嵌套 profile 的 prepare，模式可复制到同语言两单元）。
- 自测：[LanguageSelfTest.swift](../../Sources/CodeInsightApp/SelfTest/LanguageSelfTest.swift) 2276-2290、2705-2720 断言固定语料 457b66e 的单元根；该 commit 每语言只有一个单元，断言不受影响，不改。

## 3. 设计约束

### 3.1 活动视图按"最深单元归属"过滤，不按前缀

`SnapshotView.init` 今天用 `isWithin(root:path:)`：根单元 `.` 会包含全部文件，父单元会包含嵌套子单元的文件。V2 给 `init` 增加一个参数 `unitRoots: [String]`（同语言全部单元根，含自己；默认 `[自己的根]` 保持旧行为），过滤条件改为"包含该路径的最深 `unitRoots` 成员 == 自己的根"。`ModuleMap` 的 `projectRoot` 仍是自己的根。这是本计划唯一一处引擎内不变量变化：**一个文件在同一语言内恰好属于一个单元**。

`sessionCoverage`（AppModel 3011）要用 session 的活动文件数而不是重新按语言扫 manifest，否则两个 Rust session 的 total 都会是 11+N。给 `EngineSession` 暴露活动文件的 `PathID` 集合（`SnapshotView.contentKeysByPath` 只含有索引的文件，不能当 total），`sessionCoverage` 的 `filesTotal` 取它的数量，`filesIndexed` 取其中 `content(at:)` 非空的数量。菜单第二列和状态栏覆盖率因此正确。

### 3.2 提取仍按语言，单元只影响视图和 session

`ContentIndexKey` = contentID + languageMode + 版本（[ContentIndex.swift:76-91](../../Sources/CodeInsightCore/ContentIndex.swift)），与单元无关；`prepareSnapshots` 的逐文件循环、`newInputs`/`missingKeys`/`reusedKeys` 槽位、缓存读写都保持按语言。

`PreparedSnapshot` 仍然**每门语言一个**（它是提取单位），但从单个 profile/session 变为一组：`profiles: [AnalysisProfile]`、`cachedSessions: [EngineSession]`（每单元一个 view，建在同一份 `storedAfterCache` 之上）；`completeSnapshot` 在一次提取、一次 `store.insert` 之后，从同一份 `store.snapshot()` 为每个单元各建一个 view，返回 `[EngineSession]`。`IndexStats` 的 `extractedCount`/`reusedCount` 是语言级事实（提取了几份内容），同一语言的每个单元 view 共用同一份数字；菜单显示的“源码文件数”来自覆盖率（§3.1），不来自它们。这样不依赖调用顺序，也不需要把提取状态拆到单元。

不采用"同语言第二个单元的 `missingInputs` 为空、靠第一个单元先提取"的做法：AppModel 的三处 `completeSnapshot` 循环今天虽是顺序的（2221-2230、2777-2784、3304-3308），但第二个单元的 view 建在调用时的 store 状态上，一旦顺序变化就会安装一个没有索引的完整 session 直到下次 Refresh。

调用方改动：`IndexService.completeSnapshot` 返回 `[EngineSession]`（协议 54、默认实现 131-135、ExactSelfTest 2555）；三处循环改 `completed.append(contentsOf:)`；书签安装 2163 改 `prepared.flatMap(\.cachedSessions)`；`prepareSnapshot(language:)` 仍返回 `[0]`（一门语言一个 PreparedSnapshot，语义不变）；`indexSnapshot(language:)` 从返回的数组里取活动文件最多的单元（§1 CLI）。测试 740-790（`mixedPrepare…`）把 `.cachedSession`、`completeSnapshot` 的返回值改成数组后断言不变（每语言一单元时数组长度 1）。

### 3.3 路由：一个辅助函数，两个调用点

新增 `private func unitSession(language: LanguageID, relativePath: String) -> EngineSession?`：在 `workspaceSessions.values` 中取 `analysisProfile.language == language` 且其单元根包含该路径的最深者。"包含"必须与 `SnapshotView.isWithin` 同一语义（`.` 包含一切；`path == root || path.hasPrefix(root + "/")`），把 `isWithin` 提到 `CodeInsightCore`（例如 `LanguageMode` 旁）作为 `package` 函数供两边共用，不要写第二份。`routedSession(for:)` 与 `languageMode(for:)` 都改用它；`languageMode` 第二段（manifest 查 variant）保持。

`querySessionTuples`：去掉 `matches.count == 1`，按 `projectLanguages` 顺序、同语言内按单元根字典序拼接所有 session；`validatedWorkspaceSessions` 与 `querySessions` 的 `count == languages.count` 改为 `Set(语言) == Set(projectLanguages)` 且非空（安装本来就是整体替换 `workspaceSessions = byProfile`，数量相等不再成立也不需要）。

### 3.4 身份

`AnalysisProfileID` 由（语言、`projectUnitName`、配置指纹、环境指纹、features）推出（[QueryContext.swift:71-95](../../Sources/CodeInsightCore/QueryContext.swift)），不含单元路径；`projectUnitName` 在引擎侧是单元根的 `lastPathComponent`（Rust 有包名时用包名，[ProfileDetector.swift:244-323，`unitName` 在 308](../../Sources/CodeInsightEngine/ProfileDetector.swift)），在 Exact 侧由 `detect(projectURL:)` 用 `root.lastPathComponent` 重算并比对（`verifyProfileMatches`）。**因此不能把 unit name 改成相对路径**，否则 Exact 的 profile 校验失败。两个单元碰撞（同名目录、同配置字节、同环境）走 §1 规则 4 的整语言回退；`prepareSnapshots` 在建 profile 后用 `Set(ids).count` 检测。没有持久化 `AnalysisProfileID` 的地方（本次 grep SessionCodec、IndexCache、Exact、RecentProjectsStore 均无），所以身份变化没有迁移问题。

### 3.5 已知上限（记入 product.md 已知限制）

单元数没有上限：N 个 `pyproject.toml` 的 Python monorepo 产生 N 个 session，每个 `SnapshotView` 扫一遍 manifest（O(文件数 × 单元数)），菜单列 N 行，Exact 一次只在一个单元活。`// ponytail: 无单元上限；超过几十个单元时再考虑合并到 `.` 或分页菜单`。本计划验收只用 llm-tools（5 单元）。

## 4. 实施切片与验证

每片单独提交，提交信息英文、一两句（见仓库 `fix:`/`feat:` 约定）。

### 切片 1：引擎划分 + 活动视图

- `ProfileDetector`：`unitRoot` → `unitRoots(language:sourcePaths:configurationPaths:) -> [String]`（规则 1-3）；`detect(snapshot:language:sourcePaths:...)` → 返回 `[AnalysisProfile]`（每个根一个，`projectRootName` 规则不变）。
- `SnapshotView.init(..., unitRoots:)`；`PreparedSnapshot` 改为 `profiles`/`cachedSessions`，`completeSnapshot` 返回 `[EngineSession]`（§3.2），`IndexService` 协议与三处循环、书签安装、ExactSelfTest 替身同步；profile 碰撞回退（规则 4）。
- `EngineSession` 暴露活动文件 `PathID` 集合。
- `indexSnapshot(language:)` 取活动文件最多的单元。

测试（`swift test --filter SnapshotIndexerTests`、`--filter ProfileDetectorTests`）：

1. 改写 `independentUnitRootsFallBackToRepositoryRootAndIndexBothUnits` → `independentUnitRootsBecomeUnitsThatEachSeeOnlyTheirOwnSources`：夹具在原来 `a/`、`b/` 两个 crate 之外再加一个无 marker 祖先的 `root.rs`。`prepareSnapshots(languages: [.rust])` 返回 1 个 `PreparedSnapshot`，其 `cachedSessions` 3 个，根为 `.`、`a`、`b`；`a` 的 session 对 `b/src/main.rs` 与 `root.rs` 的 `content(at:)` 为 nil，根单元 `.` 对 `a/`、`b/` 下的文件为 nil；三个 session 共享 store，`extractedCount` 三个都是 3（语言级），活动文件数各为 1。注入核验：把 `SnapshotView` 的过滤临时改回 `isWithin(root:)` 前缀包含 → 根单元看见全部 3 个文件，断言必红。
2. 新增 `nestedMarkerInsidePartitionBelongsToTheDeepestUnit`：`a/Cargo.toml`、`a/sub/Cargo.toml`、`b/Cargo.toml`，`a/src/x.rs`、`a/sub/src/y.rs`、`b/src/z.rs` → 3 个单元，`a` 不含 `a/sub/src/y.rs`。注入：把"最深祖先"换成"最浅祖先"必红。
3. 新增 `markerCoveringEverySourceStillYieldsOneUnit`：根 `Cargo.toml` + `crates/x/Cargo.toml` + `crates/y/Cargo.toml` → 1 个单元根 `.`（tokio 形态，防过度拆分）。注入：删掉规则 2 的"覆盖全部则单单元"短路必红。
4. 新增 `collidingUnitIdentitiesFallBackToOneRootUnit`：`a/core/pyproject.toml` 与 `b/core/pyproject.toml` 字节相同、各一个 `.py` → 1 个 Python 单元根 `.`。注入：去掉碰撞检测 → 2 个单元且 `AnalysisProfileID` 相同，断言数量必红。
5. 新增 `languageWithoutSourcesInThisSnapshotStillGetsOneEmptyRootUnit`：`prepareSnapshots(languages: [.rust, .typescript])` 于只有 `.rs` 的快照 → TS 的 `PreparedSnapshot` 有且只有一个 `cachedSession`，根 `.`，活动文件 0（commit 缺语言的情形，§1 规则 1）。注入：让无源码时返回空数组 → 必红，并会让 `validatedWorkspaceSessions` 在切 commit 时拒绝安装。
6. 保持通过：774、838、876、ProfileDetectorTests 199。

### 切片 2：模型路由与覆盖率

- `unitSession(language:relativePath:)`；`routedSession`、`languageMode(for:)` 改用；`querySessionTuples`/`validatedWorkspaceSessions`/`querySessions` 去数量相等（§3.3）；`sessionCoverage` 用活动文件集合（§3.1）。
- 书签安装（2168）无需改，仍取第一个有文件的 session。

测试（`swift test --filter AppModelTests`，夹具用 `temporaryGitProject` 像 1104 那样写盘）：

7. 新增 `twoRustUnitsRouteByContainingUnitAndSwitchProfileOnFileChange`：`crates/a`、`crates/b` 两个 crate 无根 Cargo.toml + 一个 `pkg.py`；打开后 `querySessions.count == 3`，`detectedLanguageUnits` 的 Rust 两行根为 `crates/a`、`crates/b` 且 `sourceFiles` 各为 1（不是 2）；`selectFile(crates/a/src/lib.rs)` 后 `projectState.ready` 的 profile 根为 `crates/a`，再选 `crates/b/...` 后 `analysisProfileID` 变化。注入：把 `unitSession` 换回 `first(where: language ==)` → 第二次选择 profile 不变必红；把 `sessionCoverage` 换回按语言扫 manifest → `sourceFiles == 1` 必红。
8. 新增 `exactCoordinatorPreparesSecondRustUnitRootWhenNavigatingBetweenCrates`（放 ExactCoordinatorTests，复制 231 的模式）：两次 `prepare` 的 providerRoot 分别为两个 crate 目录。注入：`prepareExact` 不传 session 的 `projectRoot` 而传 `.` 必红。

### 切片 3：CLI

- `switch-stats`（443-447）：`indexSnapshot(language:)` 返回的单元根在 stderr 打印 `unit: <root>`，复用 `resolvedLanguage` 的公告格式。其余命令不变。
- 验证：`swift run codeinsight switch-stats ~/.cache/cairn-corpora/llm-tools --language rust …`（参数见 `--help`）stderr 出现 `unit: tools/semantic-json-viewer/src-tauri`（22 个 `.rs`，多于 qrcode2txt 的 11 个）。不新增单元测试。

### 切片 4：文档

- product.md "打开项目"：把"单元根取包含该语言全部源码的最浅 marker 目录，否则项目根"改为 §1 规则 1-4 的用户语言版本；已知限制表加 §3.5。
- architecture.md 第 26 行同步；删除"因此 SnapshotView 按单元根过滤活动文件不会丢掉源码"中已不准确的因果（现在是"按最深单元归属"）。
- README/README.zh-CN 若提到单元回退（grep `Cargo.toml`/`单元`）同步。

## 5. 验收（Fable 执行，实现方不要做）

构建：`CAIRN_LIBGIT2=brew CAIRN_BUNDLE_IDENTIFIER=dev.cairn.Cairn.v2accept bash scripts/make-app.sh`（隔离 bundle id，避免污染用户的最近项目——上次验收没做）。语料：`~/.cache/cairn-corpora/llm-tools`（HEAD bb6e992）。

1. 打开 llm-tools：无对话框；分析配置菜单 5 行，根与 §1 表格一致，Rust 两行文件数之和 = 仓库 `.rs` 数。
2. 打开 `crates/qrcode2txt/src/main.rs`：状态栏 Rust · qrcode2txt，Exact 就绪（不再出现"缺少配置 Cargo.toml"）；hover 一个 std 符号得到精确结果。
3. 切到 `tools/semantic-json-viewer/src-tauri/src/main.rs`：profile 变为 src-tauri，Exact 重启后就绪。
4. 切到 `tools/model-files-web` 与 `tools/semantic-json-viewer` 下各一个 `.ts`：TS profile 分别切换，Exact 就绪。
5. 项目搜索一个两 crate 都有的标识符（如 `main`）：结果来自两个 Rust 单元。
6. Refresh Index：5 行不变；关窗从最近打开恢复：5 行不变、停在同一文件。
7. 版本选择器切到 457b66e：单元集合变为 3 行（旧 commit 每语言一单元），切回 HEAD 恢复 5 行。
8. 回归：打开 tokio（`~/.cache/cairn-corpora/tokio-tokio-1.47.1`）仍是 1 个 Rust 单元根 `.`。
9. `bash scripts/run-self-tests.sh` 的 mixed 通道（固定 457b66e）通过。

结果按 PASS/FAIL/BLOCKED 记录，附构建哈希与截图路径。
