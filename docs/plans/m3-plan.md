# M3 Git 时间旅行 实现计划（Planner: Opus 4.8, 2026-07-21）

> Fable 5 因额度不可用，本轮由主模型 Opus 4.8 代行 Planner 角色（用户裁决）。
> Codex 仍负责实现，orchestrator 验收，末尾终审。

本文件为 M3 执行的权威依据，切片 S1–S8 串行。通用约束沿用 M1/M2：无头环境、
`swift build && swift test` 全绿、ci.sh 通过（引擎/model module 禁 AppKit）、
Swift 6 严格并发零 warning、不改 Prototypes/、每片不 commit。
**现有 121 测试 + 21 fixture + 双语料 gold set（nostrong=0）不得破坏。**

**目标**（design §16 M3）：Git 时间旅行完整（三级就绪 + 覆盖状态 UI + 跨版本
跳转历史）+ 面板预设 + 排版系统。验收基调："真实 git 历史仓库任意 commit
first paint < 1s，无串快照"。

## 现状核查（规划依据，已读代码确认）

- `ProjectIndexer.index(root: URL) -> EngineSession`：直接 walk 文件系统，
  **无 Snapshot 抽象**；`sourceKind: .untracked`/`fileMode: .regular` 硬编码；
  SnapshotID 是随机 UUID。
- ContentID 去重**只在单次 index() 内**（seenKeys）；ContentIndex/sourceBytes
  **不跨 session 复用**。每次 index() 全量重建。
- **interner（names/paths/strings）每 session 全新**，按首路径顺序分配 ID
  以保证 canonical dump 确定性。→ 跨 commit 复用的最大障碍：commit A 缓存的
  ContentIndex 带的是 A 的 interner 的 NameID，换 session 就对不上。
- AppModel：ProjectState = empty/indexing/ready(session, ctx)/failed；
  generation 递增只用于"重开项目整体替换"，**无"同项目内切 commit"维度**。
  QueryContext(snapshotID, profileID, generation) 已全链路传递。
  ContextWindow/RelationTree/Search 三个 model 都有 requestID+generation 作废模式。
- 探针（Prototypes/GitSnapshotProbe）：CLibGit2 systemLibrary（module.modulemap
  `link "git2"` + shim.h `#include <git2.h>`）、GitRepository、CommitSnapshot
  （tree walk + read(path) 返 raw blob）、WorktreeSnapshot（不可变捕获 + stats）、
  跨 commit `[ContentIndexKey: ContentIndex]` 复用（单一共享 interner）、
  generation 防串——**全部可抬升，类型对齐主引擎**（探针 import 主三个 module）。

## 决定 1：引擎"存储/视图"分离（M3 地基改造，最高风险）

**核心**：把"一次 index = 一个自包含 session"拆成**项目级存储 + 每快照视图**。

```text
ProjectIndexStore（项目生命周期，跨所有快照）
    shared interners（names/paths/strings）—— 跨快照稳定，NameID 不再随 session 变
    [ContentIndexKey: ContentIndex]  内容寻址缓存，跨 commit 复用
    [ContentID: [UInt8]]             内容字节缓存
    内容级 name posting（nameID → [(ContentIndexKey, localIndex)]）增量增长（§10.2）

SnapshotView（每快照，轻量）
    SnapshotManifest（此 commit 的 path → ContentID）
    ModuleMap（路径相关，每快照建）
    查询面：与 store 的内容级 posting 求交此 manifest 出现的 ContentIndexKey（§10.2）
```

**关键决策：EngineSession 的对外 API 形状不变**——ContextWindowModel/
RelationTreeModel/SearchPanelModel 都是 EngineSession 类型的消费者，保持它们零改动。
改的是 EngineSession 的**构造**：不再自持全新 interner，而是持 ProjectIndexStore
引用 + 本快照的 manifest/moduleMap。`EngineSession` 退化为"store + 当前 SnapshotView"
的门面。

**determinism 硬约束（回归安全锚）**：fixture/gold 的 canonical dump 由
`index(root:)` 对固定目录建。worktree 初次索引必须**逐字节不变**——sorted path
顺序 + 首见即分配 NameID 的规则对"从头索引一个 worktree"完全保留。interner 的
增量增长只发生在**切 commit** 时（新内容追加），不影响任何现有 fixture（它们只
索引 worktree、从不切 commit）。S2 验收：全部 dump 零 diff。

**风险**：这一片动的是 M0-A 以来所有查询的地基。策略——S2 先做纯重构
（存储/视图分离，行为等价，仍只有 worktree），**121 测试 + 21 fixture + gold set
零 diff 是硬门**；跨 commit 复用留 S3。重构与新功能分离，回归可定位。

## 决定 2：libgit2 进主 Package + CodeInsightGit module

新 systemLibrary target `CLibGit2`（抬升探针的 module.modulemap + shim.h，
`link "git2"`，Package linkerSettings 加 libgit2 的 lib 路径）。新 Swift module
`CodeInsightGit`（依赖 CLibGit2 + CodeInsightCore + CodeInsightRustExtractor）：
抬升 GitRepository/GitOID/CommitSnapshot/WorktreeSnapshot。**引擎/model 禁 AppKit
规则不变**（libgit2 是 C，无 AppKit）；ci.sh 禁令扩展覆盖 CodeInsightGit。

统一 `Snapshot` 协议（design §6.1 精神，M3 落地版）：

```swift
public protocol Snapshot: Sendable {
    var snapshotID: SnapshotID { get }
    var objectFormat: GitObjectFormat { get }   // sha1/sha256，不硬编码
    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)]
    func readBytes(path: String) throws -> [UInt8]   // CommitSnapshot 返 raw blob
}
// WorktreeSnapshot：捕获时读全部字节入内存（= 现在 index() 已做的），
//   之后不再按实时路径读（不可变捕获，还 §6.2 的债——见决定 3）
// CommitSnapshot：libgit2 tree walk + blob read
```

## 决定 3：WorktreeSnapshot 不可变捕获——部分还债，明确边界

design §6.2 要求 worktree 的 dirty/untracked 字节在捕获时固化。现状：index()
本就在开头一次性读全部字节入 `sourceBytesByContent`——**引擎侧内容其实已经是
不可变捕获的**（索引后查询/摘录都从内存字节走，不重读文件）。真正的活体重读只在
**ReaderCore 的 DocumentLoader**（显示时重读文件）。M3 落地：
- 引擎侧：Snapshot 捕获即固化（本就如此，形式化为 WorktreeSnapshot.listFiles 一次
  读入 + ContentID）。
- 阅读区：**CommitSnapshot 查看时，DocumentLoader 必须从快照读字节（blob），
  不读文件系统**（这是硬需求——看 commit A 不能显示磁盘当前内容）。worktree
  查看仍读实时文件（你就是在看当前文件，可接受）。
- 磁盘私有 content-store（§6.2 的 dirty 文件落盘）**继续挂起**：M3 的
  WorktreeSnapshot 内存捕获已消除引擎侧漂移；落盘只在"关闭后重开历史快照免重建"
  时才需要，属缓存生命周期（design §10.3），留后续。规划明确标为已知边界。

## 决定 4：三级就绪状态机 + 覆盖状态 UI

AppModel 增"当前快照"维度。切 commit 流程（design §6.3）：

```text
1. 用户在 commit 切换器选 commit C（generation &+= 1）
2. first paint：构建 C 的 SnapshotView（manifest + moduleMap，libgit2 tree walk
   百 ms 级）→ 文件树 + 当前打开文件切到 C 版本         ← 亚秒验收
3. cached semantic ready：命中 store 缓存的 ContentIndex 立即可查
4. full semantic ready：C 的新 ContentID 进后台索引队列（Task.detached，可取消——
   切到 C 后再切 D，C 的索引 Task cancel）；完成后合入 store
5. UI 分项覆盖状态：Files indexed X/Y、Imports resolved（不压成单一百分比，§14）
```

ProjectState 扩展或新增 SnapshotState（reviewing(snapshotView, coverage)）；
generation 递增时 ContextWindow/RelationTree/Search 统一收到 updateProjectState/
新 QueryContext → 旧查询作废（三个 model 已有此模式，只需切 commit 时触发）。

## 决定 5：commit 切换器 UI

design §14 顶栏一等公民。M3 范围：
- libgit2 读 commit 历史（git_revwalk）：sha、summary、author、time。
- 顶栏切换器（NSPopover 或工具栏下拉）：commit 列表 + 搜索框（按 summary/sha 过滤）；
  选中即虚拟切换。**分支图（graph）M3 不做**——纯线性 commit 列表 + branch/tag
  标签，标已知限制（分支图留后续）。
- 当前浏览的 commit 永远醒目（design §14 防"我在看哪个版本"迷失）——worktree
  态显示 "Working Tree"，commit 态显示短 sha + summary。

## 决定 6：跨版本跳转历史

M1 的 JumpRecord 已含 snapshotID/contentID（记录但未用于重放）。M3：
- push 时 snapshotID 记当前快照。
- 后退到"另一个 commit 的位置"：若 record.snapshotID ≠ 当前 → 先切快照
  （走决定 4 的切换流程）再定位 byteOffset。
- contentID 兜底：目标 commit 若该 path 内容变了，byteOffset 可能越界 → 退
  line/column → 符号锚点（symbolAnchor 现在启用）→ 文件头。
- 全部走 AppModel 的 navigate 单入口（M1 已收敛），扩展其快照维度。

## 决定 7：面板预设 + 排版系统（后段，相对独立）

- **面板预设**（design §14）：Reading（左+中+Context）/ Relations（中+右+Context）/
  Compare（分屏+Context，M3 因有双快照可做"同文件跨 commit diff 阅读"雏形——
  评估工作量，若超预算则 Compare 仅布局不做 diff，diff 留 M4）/ Focus（仅中）。
  预设 = 各面板折叠态 + 尺寸的命名组合，菜单 View > Preset + 快捷键。
- **排版系统**：SI Classic 主题（design §9.3 米白底 + 深蓝/深红符号致敬）作为
  可选主题；行距（已定 1.25）/字号 delta 落地为**设置界面**（可调，design §9.2
  要求用户可调）。SwiftUI 设置窗口（design 决定 1 允许 SwiftUI 用于轻量界面）。

## 决定 8：backlog 折入（S8）

折入 M3：m3-backlog #1（Calls 树外部/unresolved 调用边加 "External" 分组或灰显——
S8 触碰 RelationTreeModel）、#4（RelationTree 加载失败错误行）、#5（Exact 空组头
隐藏或加 "(0)"）、#7（右键 indexing 时空面板提示）、git 边界（#6.4：CommitSnapshot
展示全部 tracked、LFS pointer 识别提示、raw blob）。
挂起续：#2 impl trait 路径限定（模块图增强，非 M3）、#3 huge syntaxVisible
TextKit 优化（探针级专项，非 M3）、#6 SearchPanel 极限掉帧、#8 K5 Pin 语义
（**等用户手测裁决**——到 S8 时若已给则折入，否则保持现状并再标注）、#9 AX 专项。

## 切片（S1–S8 串行）

### S1 — CLibGit2 进主包 + CodeInsightGit module
libgit2 systemLibrary + GitRepository/GitOID/CommitSnapshot/WorktreeSnapshot 抬升 +
Snapshot 协议（决定 2）。CLI：`snapshot --project <repo> [--commit <rev>]`
（列出该快照文件 path→ContentID、fileMode）。ci.sh 禁令覆盖 CodeInsightGit。
**无头验收**：对本仓库（有 3+ commit）单测——listFiles(HEAD) 数量、readBytes 某
blob、SHA-1 objectFormat、CommitSnapshot(HEAD~1) 与 HEAD 文件集差异；tracked 文件
不受 .gitignore 影响（构造 .gitignore 后 commit tree 仍含）。既有 121 零回归。
**人工检查点**：无（纯引擎/CLI）。
**风险**：libgit2 链接路径（/opt/homebrew/opt/libgit2）在 Package linkerSettings
写死 or pkg-config；CI 机器需装 libgit2（本机已装 1.9.6）。

### S2 — ProjectIndexStore 重构（地基，纯行为等价）
决定 1 的存储/视图分离，**只做重构不加跨 commit 复用**：ProjectIndexStore 持
interners + 内容缓存 + 内容级 posting；ProjectIndexer 建 store + worktree
SnapshotView；EngineSession 重塑为 store + SnapshotView 门面（对外 API 不变）。
**无头验收（最严）**：121 测试 + 21 fixture + **gold set 双语料 nostrong=0 全绿**；
**所有 canonical dump 零 diff**（determinism 锚，git diff 确认 dump.golden 未变）；
新增 store 单测（同一 worktree 建 store，SnapshotView 查询结果与旧 EngineSession
逐字段一致——可用现有 fixture 对拍）。
**人工检查点**：无（重构对用户不可见；但 S2 后建议 orchestrator 跑一次 app
self-test 确认 UI 路径未破）。
**风险**：最高。interner 稳定性 + determinism 是硬门；任何 dump diff 都要逐条
解释根因，禁止静默重录。

### S3 — 快照索引 + 跨 commit 复用
`indexSnapshot(_ snapshot: Snapshot, into store) -> SnapshotView`：只新 ContentID
提取，命中缓存复用；内容级 posting 增长；查询面与 manifest 求交（§10.2）。
CLI：`switch-stats --project <repo> --from HEAD --to HEAD~1`（复用率）。
**无头验收**：HEAD↔HEAD~1 复用率 >80%（对拍探针 SnapshotSwitchProbe 结论）；
切换后查询结果正确（对 HEAD~1 版本 resolve 一个符号命中该版本定义）；同内容
跨快照零重复提取；determinism（同序列两次结果一致）。
**人工检查点**：CLI 对本仓库切 commit 复用率肉眼合理。

### S4 — AppModel 快照维度 + 三级就绪 + generation + 阅读区快照源
决定 4 + 决定 3 的阅读区快照源。ProjectState/SnapshotState 扩展；切快照三级就绪
状态机；generation 递增作废三个 model；DocumentLoader 加快照内容源（CommitSnapshot
查看读 blob 不读 fs）；后台索引可取消（切 C 再切 D，C 取消）。self-test-switch
计时通道（first paint / cached ready / full ready 分段）。
**无头验收**：三级就绪状态机单测；generation 作废三 model 单测（切快照后旧
Context/Relation/Search 结果丢弃）；切换取消单测（fake：切 C 未完再切 D，C 的
索引 Task 被 cancel）；DocumentLoader 快照源单测（commit 版本字节 ≠ worktree 版本）；
`--self-test-switch <repo>` 输出三级计时且 first paint < 1s exit 0。既有零回归。
**人工检查点**：无（S5 才有 UI 入口）。

### S5 — commit 切换器 UI + 覆盖状态
决定 5 + 决定 4 的覆盖 UI。libgit2 revwalk 读 commit 列表；顶栏切换器
（列表+搜索+当前版本醒目）；覆盖状态分项显示（Files indexed X/Y、Imports resolved）。
**无头验收**：commit 列表 model 单测（revwalk 解析、搜索过滤）；覆盖 model 单测；
build/ci 绿。
**人工检查点**：真实历史仓库（oatmeal/tokio）切 3 个 commit——first paint < 1s、
文件树+阅读区切版本、覆盖状态跑动、切换期间无串快照（切到旧 commit 的 Context
不显示新版本实现）、当前版本标识醒目。

### S6 — 跨版本跳转历史
决定 6。JumpRecord 启用 snapshotID/contentID/symbolAnchor；navigate 单入口扩展
快照维度；跨 commit 后退先切快照再定位；越界兜底链（byte→line/col→符号锚点→头）。
**无头验收**：NavigationHistory 跨快照重放单测（后退到另一 commit 的位置：断言
先切快照 ID 再定位）；越界兜底单测（目标 commit 该文件变短→退 line/col）；
B/F 不自 push 保持。
**人工检查点**：worktree 看 A → 切 commit 看 B → 后退回到 worktree 的 A 原位；
前进恢复 B。

### S7 — 面板预设 + 排版系统
决定 7。Reading/Relations/Compare/Focus 预设（View 菜单 + 快捷键）；SI Classic
主题；行距/字号设置界面（SwiftUI 轻量窗口）。Compare 若超预算则仅布局（diff 留 M4，
标注）。
**无头验收**：预设 model 单测（各预设的面板折叠态/尺寸组合）；主题/设置值
model 单测；build/ci 绿。
**人工检查点**：四预设切换布局正确；SI Classic 主题观感；设置里改行距/字号即时
生效；暗色/亮色正确。

### S8 — backlog 折入 + git 边界 + 性能收尾
决定 8 的 backlog 项 + git 边界（LFS pointer 识别提示、CommitSnapshot 全 tracked、
raw blob）+ 性能：bench.sh 增 commit 切换场景（真实历史仓库 first paint/cached/
full ready 计时）；benchmarks.md 新增 "M3 自测" 节。K5 Pin 裁决若已到则折入。
**无头验收**：backlog 各项回归测试；LFS pointer 识别单测（构造 pointer 文件）；
三 self-test + self-test-switch 不回退；ci + 全量 + fixture + gold set 绿。
**人工检查点（= M3 总验收）**：真实历史仓库 30 分钟走查——commit 间穿梭读代码、
跨版本历史往返、覆盖状态观察、Compare 预设、排版设置，记录"切版本是否顺滑 /
哪步想切回 git CLI"作 M4 输入。

**依赖**：S1→S2→S3→S4→S5，S6 依赖 S4，S7 独立（可任意插），S8 收尾。
按编号串行派发。

## 风险预警（给执行者）

1. **S2 是地基手术**（最高风险）：determinism 零 diff 是硬门。interner 跨快照
   稳定但 worktree 初次索引的 ID 分配顺序必须与今天逐字节一致。任何 dump.golden
   变化都要逐条解释根因，禁止 RECORD=1 整批重录。
2. **libgit2 内存/线程**（S1）：git_repository/tree/blob 的生命周期与释放
   （探针已踩过，抬升时保留其 deinit 模式）；libgit2 对象非线程安全，快照捕获
   在单线程完成再把不可变结果交出去。
3. **切换取消**（S4）：切 C 后台索引未完又切 D——C 的 Task 必须 cancel 且其
   部分结果不得污染 store（要么原子合入完成的，要么丢弃）；generation 双检。
4. **阅读区快照源**（S4）：commit 查看必须读 blob，绝不读文件系统当前内容——
   这是"看历史"的正确性底线，是 M3 存在的理由。
5. **跨快照 NameID**（S3）：查询结果的 SymbolOccurrenceID 跨快照的 pathID 稳定
   （interner 共享），但 localIndex 是 per-ContentIndex 的——跨快照比较符号身份
   要用 (contentID, localIndex) 或 qualified name，不能裸比 localIndex。

## 待决策者批注

(a) **K5 Pin 语义裁决**仍等用户手测（M2 遗留）。到 S8 若已给则折入；否则保持
    现状（单击不覆盖 / 右键 Show Relations 经 explicitJump 覆盖）并再标注。
(b) **Compare 预设是否含 diff**：若工作量超预算，M3 只做分屏布局，跨 commit
    diff 阅读留 M4（design F4.7 本就是 P1）。S7 前给倾向。
(c) libgit2 分发：M3 依赖系统 libgit2（本机 brew 装）。正式分发（M4）需静态链接
    或随包 vendor——非 M3 范围，但影响 CI 机器要求，先记录。
