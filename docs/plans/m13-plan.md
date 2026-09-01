# M13 实施计划 v3：书签与阅读笔记（Cairn 石堆）

> 状态：M13 计划已批准（`67f4f06`），书签/笔记实现已落地（`1761077` 及后续修复）；
> 本轮 [remediation plan](m1-m13-remediation-plan.md) 的 V0 尚未全部通过。
> 本文件只定义实施顺序、边界和验收，不包含产品代码。
>
> 草拟时仓库基线：`d58776c61691a7a44c099711b83b377d17ece729`
>（`main` ahead of `origin/main` 1 个提交；工作区仅有本计划文件未跟踪）。
> 实施前必须先提交批准后的计划并把该提交记为 `M13_BASE`；开工时动态审计
> 全部 tracked / staged / untracked 路径，不依赖历史文件名。
>
> v3.1：书签不得调用 `switchSnapshot` / `publishFirstPaint`。
> v3.2：install 成功后才用现有 `navigate(..., leaving:)` 记一条 history。
> v3.3：原子 install；非持久 Attempt；mixed 按语言打标；重锚 key 冲突；
> 正式目录指纹含 symlink；删除 `createdAt`。
> v3.4：strict exact 的 worktree/commit 都用同一 captured `ContentSource`，
> 不以 live disk 为真；cached 初装后再 async fullReady，失败不回滚；
> 非当前行点击 missing 可显示 Attempt；产品进程不读正式 bundle，harness
> 只读指纹；`FILE_CAP` 固定映射 256/32、128/16、64/8。
> 主审收口：Attempt 使用独立 attempt generation/message；显示 contentID 是
> captured-source 的验收不变量，不在 `navigate` 入栈后伪装成可回滚分支。

---

## §0 结论先行

M13 只交付四件事：

1. **原快照 exact 书签**：按 `contentID + byteOffset` 精确跳回打标快照；
2. **worktree 漂移与显式重锚**：内容变化时不猜，不静默跳行；
3. **纯文本笔记**：小型原子 JSON 写穿保存；
4. **面板、gutter、快捷键、过滤与 markdown 导出**。

跨 commit 符号映射不在本期。当前只有未限定符号名、name-only 定义查询和多组
query session，也没有消费“映射到当前 commit”结果的产品动作。补这些能力需要
独立探针、查询 interface 与用户动作，不在书签 v1 中夹带。

三个实现裁决：

- **书签成功只有 exact 一种**。普通点击不使用 line / symbol / file-head 兜底；
- **历史记录与 generic replay 分离**。书签切换不设置 `pendingReplay`，不调用
  `replayOffset`；
- **不新建持久化基建**。复用 Codable + `Data.write(options: .atomic)`，不用
  SQLite、RepoIdentity、迁移框架或第三方依赖。

允许修改：`CodeInsightAppModel`、`CodeInsightApp`、`CodeInsightReaderUI`。
Core / Engine / Git / ReaderCore / Exact / extractors 保持零改动。

---

## §1 事实基线

### §1.1 既有 seam

- `SessionCodec` 已有 schema envelope、字段边界校验和原子写先例；默认数据目录为
  `~/Library/Application Support/Cairn/<bundle-id>/`。
- `AppModel.switchToCommit(_:leaving:)` / `switchToWorktree(leaving:)` 会 push
  history 并设置 `pendingReplay`；`switchSnapshot` 先 recapture，再
  `publishFirstPaint`（此处消费 `pendingReplay` → `replayOffset`），**然后才**
  `prepareSnapshots`。书签不得调用这些入口。
- `IndexService`（生产为 `ProjectIndexService`）已能对同一 `Snapshot` 做
  capture → prepare → complete。严格跳转只捕获一次，并在**任何 UI 变更之前**
  完成 validate + prepare。
- `ReaderTextView` 已持有 diff marker、ruler 与 fold 投影，并在显示新文档和
  `clear()` 时清理状态；书签直接复用这个生命周期。
- `RecentProjectsStore` 用 `standardizedFileURL.path` 作项目身份。v1 沿用该口径，
  诚实接受移动/重克隆后旧书签不自动迁移。

### §1.2 已知边界

- Git object 可能因浅克隆、GC 或历史改写而不可达；合法状态是
  `revisionUnavailable`，不是“永远可跳”。
- worktree generation 跨进程不稳定，不进入持久化记录。
- `Verified / Inferred` 属于 exact provider 语义，书签使用独立状态词表。
- v1 只允许在**主阅读区当前项目文件 tab** 打标。dependency、Compare、
  Reading Set、空状态和辅助 mini-reader 不支持打标，菜单禁用并提供 AX 状态。

---

## §2 成功合同

### §2.1 持久记录

```swift
// 形状示意；派生标题与求值状态不持久化。
struct BookmarkRecord: Codable, Equatable, Sendable {
    var id: UUID
    var projectPath: String
    var snapshot: SnapshotAnchor       // .worktree / .commit(fullOID: String)
    var path: String                   // 项目内相对路径
    var contentID: ContentID
    var byteOffset: UInt32
    var line: UInt32                   // 展示与显式重锚参考，不是普通跳转兜底
    var symbolName: String?            // 仅派生标题与导出
    var symbolKind: String?            // 仅展示与导出
    var note: String
    var updatedAt: Date
}
```

- `id` 是编辑、删除、重锚和过滤后选择的稳定身份。
- toggle 唯一键固定为
  `(projectPath, snapshot, path, contentID, byteOffset)`；同键不能重复。
- 标题不持久化：有 `symbolName` 时显示该名称，否则显示 `path:line`。
- commit 必须保存 capture 时解析出的完整 40/64 位十六进制 OID，不存分支名、
  abbreviated SHA 或 `HEAD~1`。
- 不保存 `createdAt`、`byteLength`、column、capture generation 或“上次状态”：
  v1 无展示/导出/排序消费者；排序只用 `updatedAt`。

### §2.2 状态词表

实际求值状态只有：

- `Exact content`
- `Drifted`（仅 worktree）
- `Revision unavailable`
- `File absent`
- `Offset invalid`

列表默认：只对 `record.snapshot` 与**当前显示快照**匹配的条目求值（worktree
对 worktree；commit 对相同 full OID）。其余行一律 `Not evaluated`：commit 为
`Saved at <short SHA> · Not evaluated`，worktree 为 `Worktree · Not evaluated`。
不另 capture、不读工作区磁盘。展示态不冒充求值结果。导出未求值写入同一语句。

严格点击失败不改持久记录、不改默认列表求值。`BookmarkModel` 持有
`bookmarkAttemptGeneration`、当前 `bookmarkJumpTask` 与非持久
`lastAttemptMessage: (id: UUID, workspaceGeneration: UInt64,
attemptGeneration: UInt64, message: String)?`。每次点击先递增 attempt generation、
取消上一任务；发布结果时同时核对 workspace 与 attempt 两个 generation。
目标求值失败写五态对应文案；capture / prepare / install 内部失败分别写具名
`Snapshot capture/preparation/install failed`，不硬塞进 `BookmarkStatus`。清除：
成功跳转、切换项目/快照、任一 generation 过期、删除该记录、或开始下一次跳转。
用户对**非当前行**做 preflight 且 object/file 缺失时，该行允许显示 transient
Attempt（`Revision unavailable` / `File absent`），不改默认求值、不改导出。
未点击的非当前行仍是 `Not evaluated`。V0 missing-object 即此口径。
不另建持久“上次状态”字段。

### §2.3 严格跳转

书签跳转在 `AppModel` 内完成。不得调用 `switchToCommit`、`switchToWorktree`、
`switchSnapshot`、`publishFirstPaint`、`replayOffset`；`pendingReplay` 全程保持 nil。
现有 `publishFirstPaint` 对 worktree 设 `documentSource = nil`，后续加载会读
实时磁盘；strict 路径禁止这条语义。

**字节真值**：commit 与 worktree 都必须安装/使用**同一** captured `Snapshot`
（及其 `EngineSession` captured bytes）作为 `documentSource`。不得把 live
disk 当 exact。同快照当前已显示文件可直接校验 `ReaderDocument.contentID`；
其他文件必须用 captured source。`navigate` 后显示 document 的 contentID 一致
是该确定性数据流的**验收不变量**，不是 `navigate(..., leaving:)` 已入栈后的
第二个可恢复失败分支；若不一致，产品显示内部错误且 `goBack` 仍可用，测试直接
FAIL，禁止把该跳转记录成产品 PASS。

同一快照：边界检查失败则返回。按上款校验。非 exact：写 Attempt，不 push、
不滚动。exact：`navigate(strict request, leaving: original)` 一次；显示
contentID 作为上述验收不变量核对。

跨快照：

1. 边界检查失败则返回。原位置存为局部 `original`，**不 push**。
2. `captureSnapshot` 只一次。不 bump generation、不改 UI。抛错 →
   Attempt `Revision unavailable`。
3. 在该 capture 的 bytes 上核 full OID / path / contentID / UTF-16。
   非 exact：写 Attempt，结束。
4. 仅 exact 才 `prepareSnapshots`。失败：具名 preparation Attempt，UI/history 不变。
5. `installPreparedSnapshot`：**发布前预验证** prepared sessions（语言集合、
   snapshotID、profile 数、共享 paths）。失败则返回、零 UI 变更，禁止
   `failWorkspace`。结构预验证失败写具名 install Attempt。通过后同一
   MainActor 回合提交 cached 初装（不得 first
   paint）：`generation &+= 1`；cancel `snapshotTask` / `compareSnapshotTask` /
   `replayTask`；`exactCoordinator.invalidate`；`compare.clear()`；
   `commitPicker.setCurrentRevision`；发布 `fileTree`、**captured**
   `documentSource`（worktree 也不得为 nil）、`currentSnapshotID`、
   `snapshotDestinations`、`snapshotPhase = .cachedReady`、`coverage`、
   `workspaceSessions`。**此阶段不设置** `lastInstalledRevision` /
   `lastInstalledProjectRoot` / `lastInstalledGeneration`。
6. 初装成功后 `navigate(..., leaving: original)` 一次。history 只新增一项；
   显示 contentID 是验收不变量。
7. **full completion**（同 generation、async，不挡 exact 阅读）：对 prepared
   项 `completeSnapshot`；成功则 `installWorkspaceSessions(..., .fullReady)`，
   **此时才**写 `lastInstalled*` 并 `prepareExact`。失败：保持 `cachedReady`
   与已完成的 exact 阅读；不 `failWorkspace`、不回滚、不伪称 fullReady。

做不到 captured `documentSource` 或原子 cached 初装则 F3 `BLOCKED`，缩小为
同快照当前已显示文件 exact，不临场读盘。

`goBack` 仍走现有 `replay(_:)`。只拆这一个 helper。

### §2.4 worktree 漂移与重锚

- worktree 重新捕获后，当前 path 的 contentID 不同即 `Drifted`。
- 普通点击 Drifted 行不导航。
- 显式动作“在当前内容第 N 行打开（内容已漂移）”可按边界收缩后的 line 打开，
  但不会自动改写锚。
- “重新锚定到当前内容”以该 line 计算新 byteOffset，改写 contentID / byteOffset /
  line / symbol metadata / `updatedAt`；保留 `id`、note。新 toggle key 已属于
  **另一 UUID** 时具名拒绝，两条记录均不改（含当前行的瞬时 UI）。同 UUID
  重锚到自身 key 是 no-op 成功。
- commit 书签没有重锚动作。

### §2.5 删除与笔记

- `Cmd+Shift+M` 在无同键记录时新增；有同键空笔记时删除；有非空笔记时先显示
  原生确认，避免快捷键静默丢数据。
- 笔记纯文本，不渲染 markdown。
- 每次文本变更在 MainActor 上同步编码并原子写；保证只覆盖**写入调用成功返回后**
  的变更，不承诺进程在回调中途或掉电时零损失。
- 写失败时保留内存 dirty 状态并具名提示，不假装成功。
- `updatedAt` 在创建、成功重锚、笔记编辑失焦/关面板时推进；按键期间不推进，
  避免编辑行重排。

### §2.6 只读与数据隔离

- 用户项目、`.git`、依赖目录零写入；书签只写 Cairn App Support。
- 不联网、不 push、不 tag、不发布。
- 产品验收使用唯一 bundle id 与首次启动前不存在的 App Support 目录。
- **产品进程**不读取、不写入正式 `dev.cairn.Cairn` 数据。
- **验收 harness** 仅对该正式目录做只读指纹（内容与拓扑），禁止 rm/改。

---

## §3 范围与明确不做

### §3.1 范围

- bounded JSON store、记录捕获与状态求值；
- strict original-snapshot navigation、worktree drift/re-anchor；
- 面板、过滤、统计、快捷键、菜单、gutter；
- 纯文本笔记、Copy as Markdown、单文件导出。

### §3.2 不做

- 跨 commit 候选映射、lineage、改名跟随；
- SQLite、RepoIdentity、同步、tags、文件夹、自动书签；
- markdown 渲染、导入、持久内容钉住、缓存回收豁免；
- dependency / Compare / Reading Set / mini-reader 打标；
- 新引擎书签类型、新第三方依赖、新通用 marker host。

---

## §4 模块形状

### §4.1 CodeInsightAppModel

- `BookmarkRecord`：持久值与边界验证后的不变量；
- `BookmarkStore`：一个 schema envelope 的 read / replace；
- `BookmarkStatus`：纯求值枚举与函数；
- `BookmarkModel`：列表、过滤、dirty/error、CRUD 与严格跳转动作。

这些模块没有 adapter/factory/plugin seam。`BookmarkStore` 接受 file URL，生产与测试
各给一个 URL 即可。

### §4.2 JSON 边界

`bookmarks.json` envelope：`{ schemaVersion: 1, bookmarks: [...] }`。

硬上限由 F0 按固定映射选定，顺序 **256 → 128 → 64 KiB**，不得按比例临场改条数：

| `FILE_CAP` | 最多条数 | note | path/symbol |
|---|---|---|---|
| 256 KiB | 32 | 2 KiB | 1 KiB |
| 128 KiB | 16 | 2 KiB | 1 KiB |
| 64 KiB | 8 | 2 KiB | 1 KiB |

F0 从 256 KiB 起测 MainActor 全量 encode+atomic write p95（≥20 次，排除冷启动）。
该档 p95 ≤ 16 ms 即锁定该行；否则试下一档。三档都过不了则 M13 `BLOCKED`，
**修订本计划**后再改上限，不在实施中另定数字。解码拒绝大于 `FILE_CAP` 的
文件；写入前编码超过则失败、保留原文件。

解码后必须验证：

- UUID 唯一；toggle key 唯一；
- projectPath 是标准化绝对路径；
- path 非空、非绝对，且无空组件、`.`、`..`；
- commit OID 是 40 或 64 位小写十六进制；
- `ContentID.algorithm == 1` 且字节数为 32；
- 字段和总数未超上限。

缺文件是空库；超过上限、JSON 损坏、schema 不识别或语义校验失败均进入错误态，
保留原文件，绝不静默清空重写。错误态必须提供“导出原始字节副本”动作：F1
覆盖模型 API 逐字节一致；F5/V0 覆盖真实 AppKit 菜单/按钮 + AX 标签 + 写出
文件内容与原损坏字节一致。

写入为全量 encode + `Data.write(options: .atomic)`。只有 MainActor 一个写者，不建
队列/actor/锁，也不测试 Foundation 自身的 crash 原子性。性能门限已在 F0 用
`FILE_CAP` 探针锁定；F1 只回归该上限，不得临场加大文件或加后台队列。

### §4.3 ReaderUI

直接在现有 `ReaderTextView` 增：

```swift
func setBookmarkMarkers(_ labelsBySourceLine: [Int: [String]])
```

- private marker state与 diff marker 并列；显示新文档和 `clear()` 时清空；
- App 只传当前 project / snapshot / document contentID 均 exact 的书签；
- 同一行只画一个简单原生 glyph，AX 标签聚合并稳定排序全部派生标题；
- 折叠隐藏行投影到最内层 fold header；
- `lineNumbers == false` 时不画 marker，面板仍可用；
- tab/snapshot/generation 变化后旧 marker 不残留。

不创建 `DocumentMarkerHost`、`SourceLine` interface，不引用上层 `CairnMark`。

### §4.4 AppKit surface

- 菜单与快捷键 enablement 以“主阅读区 + 当前项目文件 tab + regular reader”为真；
- unsupported surface 菜单禁用，AX help 说明原因；
- 面板按当前 standardized project path 过滤，默认 updatedAt 降序；
- 行展示派生标题、path、snapshot、展示/求值状态和 note；
- 过滤只做 title/path/note 大小写不敏感子串匹配；不加 tags/分组/排序设置。

---

## §5 实施切片

每片先最小红测，后生产修改；片末定向测试、受保护路径审计和相对基线空白检查。
除非用户另行要求，实施不 commit。

### F0：冻结基线 + 写穿探针（P0）

- 提交批准计划，记录 `M13_BASE=<full sha>`、branch、ahead/behind；
- 动态列出 tracked / staged / unstaged / untracked；逐项确认归属；
- 运行 `CODEX_SANDBOX=1 bash scripts/ci.sh` 并记录退出码/测试数；
- 记录受保护模块与 fixtures/evidence 哈希；
- 按 §4.2 映射 256→128→64 做 MainActor encode+atomic write p95 探针；锁定
  整行（cap+条数），记入开工记录。三档都失败则 `BLOCKED`。不建后台队列。

失败则 `BLOCKED`，不开始产品修改。

### F1：BookmarkRecord + BookmarkStore

红测：

- round-trip、稳定 UUID、toggle key 唯一；
- 文件/数量/note/path/OID/contentID 全部上限与非法值（文件上限 = F0 `FILE_CAP`）；
- 缺文件空库；损坏/未知 schema/非法语义不改写原文件；
- 模型层救援导出逐字节一致（产品入口在 F5/V0）；
- 在 `FILE_CAP` 下一次 note 写入不超 F0 已测 p95；失败则修 store，不改大上限、不加队列。

### F2：捕获、eligibility 与状态

依赖 F1。红测：

- 仅主阅读区当前项目文件可打标，其他 surface disabled + AX；
- worktree exact / drifted / fileAbsent；
- commit 保存 full OID；object 缺失为 revisionUnavailable；
- 非当前显示快照行默认 `Not evaluated`；对该行 preflight missing object/file
  后显示 Attempt；workspace/attempt 任一 generation 过期或切快照后清除；
- 捕获使用当前 snapshot captured source，不重读可漂移磁盘作为真值。

### F3：严格跳转编排

依赖 F2。红测：

- 非 exact 不 push、不切 snapshot、不滚动；连续两次点击时前一任务不得覆盖
  后一结果；Attempt 同时核对 workspace/attempt generation；
- exact 校验与导航都走 captured `documentSource`（worktree 也不得 nil）；
  显示 `ReaderDocument.contentID` 与书签一致是验收断言；不一致直接 FAIL，
  `goBack` 仍可用；
- validate 之后改磁盘：最终显示仍是 captured bytes，或具名失败且不移动；
- cached 初装不写 `lastInstalled*`；fullReady 成功后才写并 `prepareExact`；
  complete 失败保持 cachedReady + 已完成 exact 阅读，不 `failWorkspace`；
- 预验证失败零 UI；不调用 `switchSnapshot` / `publishFirstPaint` / `replayOffset`；
- 成功仅一次 `navigate(..., leaving: original)`，history 只新增一项；
- `goBack` 走现有 replay；stale generation 不发布。

### F4：面板、删除、重锚与统计

依赖 F3，**与 F3 串行**。红测：

- 五种求值态 + Not evaluated + Attempt 错误文案/tooltip；
- 过滤后 edit/delete/re-anchor 仍按 UUID 命中原记录；
- 非空 note 快捷删除需确认；
- worktree 显式 line-open 不改锚；re-anchor 保留 id/note；新 key 撞另一 UUID
  则两条均不改；
- 删除后列表/统计/`lastAttemptMessage` 无残留。

### C1：模型层检查点

运行 AppModel 定向测试；Core/Engine/Git/ReaderCore/Exact/extractors diff 为空。

### F5：AppKit 面板、gutter、菜单与快捷键

依赖 C1。红测/验收：

- `ReaderTextView.setBookmarkMarkers` load/clear、exact scope、同线聚合；
- fold header 投影、lineNumbers=false 降级、tab/snapshot 无残留；
- 三主题真实 AppKit 截图 + AX tree；
- 键盘流程：打标 → 面板 → 过滤 → exact 跳转 → 返回；
- 损坏/未知 schema 库（**一个代表项目即可**）：面板进入错误态；真实菜单/按钮
  “导出原始副本”可用，AX 标签存在，写出文件与原字节逐字节一致；不静默清空；
- unsupported surface disabled + AX help；快捷键无冲突。

### F6：笔记与导出

依赖 F5。红测/验收：

- 写成功返回后重启保留最后一次变更；失败保留 dirty；
- 按键期间 updatedAt/排序稳定，失焦成功后推进；
- 导出不改库；Not evaluated 不冒充 Exact；
- 空 note 不生成空节，文本正确转义为 markdown 内容。

### V0：总验收

自动门禁：

```bash
CODEX_SANDBOX=1 bash scripts/ci.sh
CODEX_SANDBOX=1 bash scripts/run-gold-gates.sh
git diff --check "$M13_BASE"
git diff --cached --check "$M13_BASE"
```

完整改动清单必须取并集（含工作区 tracked、index/staged、untracked）：

```bash
git diff --name-only "$M13_BASE"
git diff --cached --name-only "$M13_BASE"
git ls-files --others --exclude-standard
```

对每个 untracked 文件执行 `git diff --no-index --check /dev/null <file>`；harness
把“内容不同”的 exit 1 视为正常，只在命令产生 whitespace error 输出或其他退出码时
失败。结构门禁对上述并集检查：只允许 AppModel/App/ReaderUI 与新测试/本计划，且
ReaderUI 只限 marker seam；受保护模块、fixtures、Gold、Prototypes、既有 evidence
零改动。

产品门禁使用：

```bash
m13_bundle_id="dev.cairn.Cairn.m13v0.<timestamp>-<pid>"
m13_output_dir=".build/m13-distribution-<timestamp>-<pid>"
test ! -e "$HOME/Library/Application Support/Cairn/$m13_bundle_id"
test ! -e "$m13_output_dir"
CODEX_SANDBOX=1 CAIRN_BUNDLE_IDENTIFIER="$m13_bundle_id" \
  CAIRN_OUTPUT_DIR="$m13_output_dir" bash scripts/make-app.sh
```

启动前对正式目录做只读指纹，启动后与结束后复验，**禁止 rm/改该目录**：

```bash
official="$HOME/Library/Application Support/Cairn/dev.cairn.Cairn"
fingerprint_official() {
  if [ ! -e "$official" ]; then echo ABSENT; return; fi
  # 内容与拓扑零写入证明：相对路径 + 类型 + 文件内容 / symlink 目标。
  # 含空目录。不纳入 stat mode（mtime/mode 噪声不是产品写入）。禁止 -L / rm。
  python3 - "$official" <<'PY'
import os, sys, hashlib
root = sys.argv[1]
h = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames.sort()
    filenames.sort()
    rel_dir = os.path.relpath(dirpath, root)
    h.update(b"D\0" + os.fsencode(rel_dir) + b"\0")
    for name in dirnames + filenames:
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        if os.path.islink(path):
            h.update(b"L\0" + os.fsencode(rel) + b"\0"
                     + os.fsencode(os.readlink(path)) + b"\0")
        elif os.path.isdir(path):
            continue
        elif os.path.isfile(path):
            h.update(b"F\0" + os.fsencode(rel) + b"\0")
            with open(path, "rb") as f:
                h.update(f.read())
print(h.hexdigest())
PY
}
official_before="$(fingerprint_official)"
# … 验收全程只用 $m13_bundle_id …
test "$(fingerprint_official)" = "$official_before"
```

产品进程只使用该唯一 bundle 的 App Support。harness 对正式目录只做只读指纹，
不清理。产品矩阵：

| 项目 | 覆盖 |
|---|---|
| Git Rust | worktree 打标/note/exact jump/goBack/drift/re-anchor/restart/导出；commit 打标、exact jump/goBack、Not evaluated、missing object；**损坏库救援 AppKit/AX（唯一代表）** |
| Git 混合 | 对**每个已支持语言**各选一个主阅读区项目文件打标并 exact 跳转；unsupported 只用 dependency / Compare / Reading Set，**不得**把非当前语言主文件当 unsupported |
| 非 git 目录 | **仅 worktree**：打标/note/exact jump/goBack/drift/re-anchor/restart/导出；无 commit / missing-object / 损坏库步骤 |

零写入 helper 必须：

- 所有 Git 命令设置 `GIT_OPTIONAL_LOCKS=0`；
- 用 `git rev-parse --path-format=absolute --git-dir --git-common-dir` 解析真实目录；
- 前后哈希工作树 HEAD/status/index entries/tracked/untracked/ignored 内容；
- 哈希实际 gitdir/common-dir 下存在的 HEAD、index、config、refs、packed-refs、shallow；
- linked worktree、普通 repo 各一；全部相等。

记录每条命令退出码、测试数、bundle id、输出路径与产品步骤结果。
`RECORD` UNSET；不发布、不 tag、不 push。是否 commit 由用户决定。

---

## §6 依赖顺序

```text
F0 → F1 → F2 → F3 → F4 → C1 → F5 → F6 → V0
```

所有切片串行；不为并行创建中间抽象。

---

## §7 风险与停止条件

| 风险 | 门禁 |
|---|---|
| generic replay 渗回 | F3 断言 pendingReplay/replayOffset 未消费 |
| worktree live-disk TOCTOU | captured `documentSource`；改盘后仍显示 captured 或失败不移动 |
| 半安装 / 伪 fullReady | cached 初装不写 lastInstalled*；complete 失败保持 cachedReady |
| 半安装后 failWorkspace | 预验证失败零 UI；complete 失败不 failWorkspace |
| install 前污染 history | 失败 history 计数不变；成功仅一项 |
| 失败态污染默认列表 | 默认 Not evaluated；点击 missing 才 Attempt |
| 连续点击 Attempt 串线 | 独立 attempt generation + 取消前任务 + 双 generation guard |
| 重锚撞 key | 另一 UUID 占用则两条均不改 |
| 未提交实现漏审 | tracked + staged + untracked 并集门禁 |
| JSON 写穿卡顿 | F0 锁定映射行；不临场改条数 |
| 救援导出只停在模型层 | 一个代表项目的 F5/V0 AppKit/AX + 逐字节 |
| 正式数据被验收污染 | 产品进程不读正式 bundle；harness 只读指纹 |
| mixed 语言漏打标 | 每门已支持语言各一主文件；unsupported 仅辅助 surface |
| marker 残留/折叠错误 | ReaderTextView 生命周期、fold/AX 证据 |
| Git 布局漏审 | gitdir/common-dir + optional locks |
| 范围蔓延 | §3.2 直接拒绝，另立计划 |

任一 P0 合同无法由现有 AppModel seam 表达（含原子 install）、或 F0 无 `FILE_CAP`
过 16 ms，立即 `BLOCKED` 并修订计划；不得临场增加 manager/router/queue/回滚。

---

## §8 后续路线（不在 M13）

1. 跨 commit 符号映射：先做多 session 查询探针和明确用户动作；
2. 稳定 repo 身份：真实移动/克隆需求出现后再设计 Git interface；
3. SQLite：只有规模/多写者实测证明 JSON 不足后评估；
4. 缓存生命周期、lineage、同步、markdown 渲染分别立项。

---

## §9 开工清单

- [ ] 用户批准本计划与 §2/§4 裁决（含 v3.4：captured ContentSource、cached 后
      fullReady、Attempt on missing 非当前行、独立 attempt generation、
      FILE_CAP 映射、harness 只读指纹）；
- [ ] `M13_BASE` 是包含批准计划的实际 full SHA；
- [ ] tracked/staged/unstaged/untracked 归属全部明确；
- [ ] F0 实时 CI 成功，并锁定 `FILE_CAP` 与 p95 证据；
- [ ] 受保护路径基线已记录；
- [ ] 唯一 bundle id / output / App Support 路径已预检；正式 `dev.cairn.Cairn`
      指纹基线已记录；
- [ ] 每个新增类型都有两个以上真实消费者或一个不可替代的深模块职责；否则不新增。
