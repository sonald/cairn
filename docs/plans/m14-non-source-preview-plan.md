# M14：非源码只读预览与仓库内链接

## 规划基线

- 基线：`HEAD 43d8f1b`。
- 基线验证：`swift test --disable-sandbox`，exit 0。
- 本计划阶段只新增本文件；不得触碰未跟踪 `.claude-trace/`。
- 每个切片均遵循：先写失败验收（RED）→最小实现→聚焦验证（GREEN）→检查 diff→原子提交。

## 目标与明确边界

为项目文件树和 Reader 增加 Markdown、HTML、图片、PDF 及严格 UTF-8 纯文本的只读预览；Markdown/HTML 的显式仓库内文件链接进入现有文件导航、Back/Forward 和 tabs。

不在 `CodeInsightCore` 新增共享 `FileKind`、renderer protocol、renderer registry 或新的索引模型。文件发现不再按语言筛选：`FileTreeModel` 展示跳过目录外的所有常规、非 symlink 文件；`WorktreeSnapshot` 捕获这些文件；`CommitSnapshot` 保持全部 blob。源码索引、Exact、全文搜索仍只按既有 `LanguageMode` 工作。

非源码不支持 outline、fold、relations、bookmark、compare/diff、Reading Height、Reading Trail、语义 offset；必须清空/禁用/隐藏相关控件，且切换 tabs 后不能泄漏上一源码状态。tabs、侧栏、文件 palette 仍可用。

## 已确认真实调用链

1. `CodeInsightApplication.main`（`Sources/CodeInsightApp/CodeInsightApp.swift:112-489`）→`AppDelegate.launch`（`:8565-8594`）→`MainWindowController`。
2. 菜单项目入口 `openProject/chooseLanguagesProject`（`CodeInsightApp.swift:8701-8770`）；空态拖放经 `EmptyStateView.swift:35-165`、`MainWindowController.swift:2124-2150` 进入同一路径。
3. `SidebarViewController.outlineViewSelectionDidChange`（`MainWindowController.swift:3292-3304`）→`navigate`（`:2588-2619`）→`AppModel.navigate`（`AppModel.swift:1446-1496`）→`TabStripModel.open/selectFile`。
4. `MainWindowController.render`（`MainWindowController.swift:1815-1959`）→`ReaderViewController.display`（`:5060-5319`）→源码 `DocumentLoader`（`CodeInsightReaderCore.swift:805-880`）→`ReaderTextView`。
5. 现有 `AppModel.onDocumentChange`（`MainWindowController.swift:387-392`）把 `ReaderDocument?` 写入活动 tab；非源码必须写入 nil，清除旧源码状态。

## S1：文件发现与快照

**允许文件：**

- `Sources/CodeInsightAppModel/AppModel.swift`
- `Sources/CodeInsightGit/GitSnapshot.swift`
- `Tests/CodeInsightAppModelTests/AppModelTests.swift`
- `Tests/CodeInsightGitTests/GitSnapshotTests.swift`

**实现约束：**

- `FileTreeModel` 保留 `.git/target/node_modules/.build/venv/.venv/__pycache__/dist/build` 跳过规则及 symlink 排除，常规文件不再调用 `LanguageMode.classify`；保留 `.DS_Store` 排除。
- `snapshotPaths` initializer 只负责按传入 path 组树，不承担 fileMode 验证；真实 snapshot 调用者必须先从 `listFiles()` 排除 `.symlink/.gitlink`，再传 path，避免仅凭 path 假装验证。`.regular/.lfsPointer` 可见，后者交给 strict UTF-8 分支显示原始 pointer。
- `WorktreeSnapshot` 递归捕获所有允许目录中的常规文件，`listFiles()` 返回它们；`configurationPaths` 继续供 ProfileDetector 使用。Worktree Reader 仍直接读取当前磁盘；Commit Reader 只读该 snapshot bytes。
- `ProjectIndexer.prepareSnapshot` 可继续遍历全部 `listFiles()`；其既有 `LanguageMode` guard、`SnapshotView` 源码过滤和 semantic 统计不得改变。

**RED/GREEN 验收：**

- 新测试含 `README.md`、`docs/a.html`、`image.png`、`paper.pdf`、`notes.txt`、未知二进制、跳过目录和 symlink；RED 证明当前源码过滤不满足，GREEN 证明树路径/排序/选择路径正确。
- Worktree 捕获后修改磁盘文件，`snapshot.readBytes` 仍返回捕获 bytes；Reader 后续按决策读当前磁盘。Commit `listFiles/readBytes` 保持全部 blob 语义。
- 原有 `fileTreeUsesTheSharedRustClassifierAcrossBothSources`、Git snapshot source/config 计数断言按新文件树合同更新；semantic `filesIndexed/filesTotal` 和 `IndexStats.fileCount` 仍只数源码。

**验证：**

`swift test --disable-sandbox --filter 'CodeInsightGitTests|CodeInsightAppModelTests'`

## S2：Reader 非源码预览

**允许文件：**

- `Sources/CodeInsightApp/MainWindowController.swift`
- `Package.swift`（仅在导入 WebKit/PDFKit 必需时）
- `Tests/CodeInsightAppTests/NonSourcePreviewTests.swift`（新建）

**最小分发：**在现有 `ReaderViewController` 内按路径扩展和 bytes 分发，不建 renderer protocol/registry。

- `.md/.markdown`：`AttributedString(markdown:options:baseURL:)` 转 `NSAttributedString`，交给原生只读 `NSTextView`；不加载外部资源。
- `.html/.htm`：`WKWebView.loadHTMLString`；`WKWebpagePreferences.allowsContentJavaScript = false`，`javaScriptCanOpenWindowsAutomatically = false`，非持久 data store；注入 CSP：`default-src 'none'; style-src 'unsafe-inline'; img-src data:`。`baseURL` 仅用于链接解析，不使用 `loadFileURL`。
- `.pdf`：`PDFDocument(data:)` + `PDFView`；nil/损坏时显示明确错误。
- `NSImage(data:)` 可解码：`NSImageView` 等比显示。
- 其他严格 UTF-8：只读纯文本 `NSTextView`；UTF-8 失败且不是可解码 PDF/图片时显示 `Unsupported binary`，禁止乱码回退。

**状态合同：**非源码切换时清除 `ReaderDocument`、outline、scope header、find、fold、bookmark markers、diff markers、Reader Height、focus；隐藏/禁用源码菜单和 secondary compare；不得调用 semantic/context/relation 路径。保留 fileName、tabs、侧栏、palette。

**RED/GREEN 验收：**

- 测试覆盖每种预览、空/损坏 bytes、只读/不可编辑、切换 source→preview→source 的状态清理；确认非源码不产生 outline/fold/relations/bookmark/compare/Reading Height。
- HTML 的外链和本地子资源在测试中不可加载；data image 可以显示；Markdown link 属性可观察但不自动导航。

**验证：**

`swift test --disable-sandbox --filter 'CodeInsightAppTests.NonSourcePreviewTests|CodeInsightReaderUITests'`

## S3：安全链接、历史与会话恢复

**允许文件：**

- `Sources/CodeInsightApp/MainWindowController.swift`
- `Sources/CodeInsightAppModel/AppModel.swift`
- `Tests/CodeInsightAppTests/NonSourcePreviewTests.swift`
- `Tests/CodeInsightAppModelTests/SessionRestoreTests.swift`
- `Tests/CodeInsightAppModelTests/AppModelTests.swift`

**链接合同：**

- 仅在 Markdown/HTML 显式点击时响应；用当前文档目录解析相对 URL，去 query/fragment 后通过现有 `fileTree.selectionPath(for:)` 验证当前 snapshot 的项目文件。
- Foundation Markdown parser 可能把相对链接交付为绝对 `file://`；允许解析后的项目内 `file://` 目标，但必须去 query/fragment、标准化后通过现有 `fileTree.selectionPath(for:)` 精确验证当前 snapshot 成员。项目外绝对 `file://`、不存在、目录、`http/https/mailto/javascript` 等 scheme 和 symlink 逃逸均不在 Cairn 内打开，不调用 `NSWorkspace`。
- HTML 同文件 fragment 留在 WebView；跨文件链接进入现有 `navigate`，复用 tabs/history。链接导航不记录 Reading Trail/语义 offset。
- Commit 下目标 bytes 必须来自当前 `documentSource` snapshot closure，严禁读 live worktree；Worktree 继续由 Reader 直接读当前磁盘。

**历史/会话合同：**

- 在 `AppModel.replayWithinCurrentSnapshot`（`AppModel.swift:2997-3006`）增加非源码直接打开分支；不调用 `languageMode`、`DocumentLoader` 或 semantic replay。
- `Back/Forward` 从 Markdown/HTML 目标返回时恢复对应 tab/file；非源码 anchor 可保持 nil/0，不新增 SessionCodec schema。
- `restoreSession` 对非源码仅验证项目路径和当前 snapshot 文件，恢复 tab，不执行源码 anchor replay；源码恢复逻辑不变。
- `currentJumpRecord` 非源码可继续使用现有 path fallback；切换源码 tab 时不得复用非源码 Reader 状态。

**RED/GREEN 验收：**

- 覆盖 `docs/guide.md`、解析后项目内绝对 `file://`、`./image.png`、`#fragment`、空格/Unicode 编码、`../outside`、项目外绝对 file、外链、目录、symlink。
- 覆盖 Markdown→另一个 Markdown→Back/Forward；覆盖历史 commit 同一路径内容不同，断言 Reader bytes 等于 commit blob；覆盖 session restore 非源码 tabs。

**验证：**

`swift test --disable-sandbox --filter 'NonSourcePreviewTests|SessionRestoreTests|AppModelTests'`

## S4：文档、真实 bundle 自测与零写

**允许文件：**

- `Sources/CodeInsightApp/CodeInsightApp.swift`
- `README.md`、`README.zh-CN.md`
- `docs/plans/evidence/m14/*`（仅验收截图/JSON）

**真实入口与验收：**

1. 新增独立 `--self-test-non-source <fixture>`，驱动真实 `MainWindowController`/`Sidebar`/`ReaderViewController`，顺序验证树显示 → 点击 Markdown → 显式内部链接 → 图片 → PDF → Back/Forward；JSON 输出 kind、bytes/contentID、AX 和可见 frame。
2. fixture 置于 `/private/tmp`，含 commit/worktree、外链、本地危险资源和 symlink；运行前后比较 fixture Git HEAD、index、status、文件 hash，必须零写。
3. 新增参数后直接调用真实 bundle 二进制（不修改冻结的 `scripts/run-self-tests.sh` 14/17 通道合同，也不新建脚本）；最终仅运行既有 `CODEX_SANDBOX=1 bash scripts/ci.sh`。
4. `bash scripts/make-app.sh` 后启动 `.build/distribution/Cairn.app`，用真实菜单“Open Project…”进入 fixture；人工/AX 验证文件树、Reader、链接拒绝、只读、Light/Dark/SI Classic 截图。源码检查不能替代 bundle 证据。

## 提交与检查点

- Plan commit：`docs: plan M14 non-source previews`。
- S1：`feat: discover non-source project files in snapshots`。
- S2：`feat: render non-source files read-only`。
- S3：`feat: secure internal preview links and restore history`。
- S4：`test: verify non-source bundle preview flow`（self-test 参数直接调用 bundle binary，不改既有脚本合同）。
- 每次提交前：`git diff --check`、限定文件 staged diff、聚焦测试；S4 后再跑完整 CI 与最终审查。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 全部常规文件进入 WorktreeSnapshot，内存/首屏变慢 | 保留跳过目录；测量 tree/first-paint/RSS；必要时另立受证据支持的大小上限，不在本计划猜测。 |
| HTML 不可信内容借 file URL/网络泄露 | 禁 JS、CSP `default-src 'none'`、只允许 inline style/data image；导航 delegate 严格拒绝；不使用 `loadFileURL`。 |
| 历史预览误读工作树 | Commit 始终使用 `documentSource` snapshot bytes；测试断言 bytes/contentID。 |
| 旧源码控件状态泄漏 | 每次非源码 display 统一清空 Reader/outline/diff/bookmark/focus/find 状态，并做 source↔preview 往返测试。 |
| 旧 fileCount/性能基线变化 | semantic 统计继续 LanguageMode-only；更新仅代表文件树可见文件数的断言和文档。 |

## 明确 defer

HTML/Markdown 相对 CSS、脚本、字体和文件图片内联；外链打开/浏览器能力；Quick Look；编辑/保存；任意二进制通用预览；插件、renderer registry、QuickLook/第三方 Markdown 引擎；非源码全文搜索、语义索引、Exact、compare/diff、Reading Trail、bookmark。
