# L3 实施计划 v1：单 workspace 混合 Rust / Python / TypeScript

> 状态：**计划已批准；P0 GO；production 尚未实施**。
>
> `L3_BASE = 5af5d8253d3099214e91f56ae40b1758d5fbabfe`。
> 计划编写时 `main...origin/main [ahead 21]`，worktree/index 均干净；远端分支不是本轮
> 基线事实来源。实施 F0 必须重新核对 HEAD、worktree、测试清单和受保护范围，不能把本文的
> 记录当作未来实时 PASS。
>
> 本计划延续 M12 的语言身份链和 L1/L2 的三个完整单语言 vertical slice。L3 只增加
> **workspace collection/routing**；不会把已经工作的 Rust、Python、TypeScript 实现重写成
> adapter、registry、plugin 或通用 LSP runtime。

---

## §0 结论先行

L3 的最小可交付产品是：用户显式选择同一 Git workspace 中的两到三门已支持语言，Cairn
只捕获一次 worktree/commit snapshot，共享一个 `ProjectIndexStore`，为每门语言建立一个仍然
封闭的 `EngineSession`；文件选择决定当前活动 session，搜索可以覆盖全部 session，Reader、
Compare、Context、Relations 和 Exact 始终只消费当前文件所属 session。

架构裁决如下。

1. **不新增 public 类型或 protocol。** 混合集合直接使用现有
   `[AnalysisProfileID: EngineSession]`；最多三个元素，不为它创建 `WorkspaceSession`、
   `LanguageAdapter`、`ProfileRouter`、`ProviderPool` 或配置 bag。
2. `ProjectState.ready(EngineSession, QueryContext)` **保持不变**。它继续代表当前活动文件的
   session。`AppModel` 私有保存全部 workspace sessions；只有活动语言变化时才重新发布
   `.ready`。这样现有 Reader/Context/Relation 消费者不必理解集合。
3. 新产品入口使用显式、规范化的 `[LanguageID]`：只接受 `.rust/.python/.typescript`，拒绝
   重复后按 `rawValue` 排序，混合入口要求 2...3 门；`.javascript` 继续原子拒绝。旧
   `openProject(root:)` 和 `openProject(root:language:)` 保持 Rust/单语言兼容。
4. L3 V0 **每门语言最多一个 `AnalysisProfile`**。配置根由 snapshot 中的真实 marker 确定；
   若同一语言存在多个彼此独立、无法归入同一根的 project unit，则具名失败，不按文件数量、
   最近路径或 marker 权重猜测。多 unit/same-language workspace 留到真实 corpus 出现后。
5. path → profile 在 V0 不需要实体：先由现有 `LanguageMode` 分类，再在线性最多三个 session
   中匹配 `analysisProfile.language`。复杂度固定 O(3)，比维护第二份路由表更可靠。
6. **Exact 资源预算固定为 1 个 warm provider。** 继续复用一个 `ExactCoordinator`；切换活动
   profile 时取消并关闭旧 session，再准备新 profile。只有 P0/真实使用证明冷切换达不到现有
   30 秒产品等待边界时，才修订计划增加小型 LRU；L3 不预建 provider pool。
7. L3 V0 不承诺跨语言 fuzzy/Exact 调用关系。Rust→Python、Python→TypeScript 等同名候选
   不连接；provider 返回的 foreign-language target 继续由现有语言门禁过滤。UI 明示
   `Cross-language relations unavailable`，不把名字相同冒充语义。
8. `SessionCodec` 升到 schema v2，project 保存规范化语言数组；v1 的单个 `language` 解码成
   singleton。项目文件仍由 path 分类，不给每个 tab/excerpt 重复写 language/profile；absolute
   dependency 若在恢复时无法由后缀唯一分类，只跳过该 tab。
9. L3 的真实 corpus 固定为 `sonald/llm-tools@457b66e...` 的**干净临时 clone**。本机现有
   checkout 有用户的 untracked 文件，只可读，不得作为零写入验收目标。
10. 所有低层、App、Exact、final bundle 和 CI 门禁通过前，不增加 mixed 菜单 cutover；旧三种
    单语言入口与 16 通道必须持续全绿。

这不是“再做一次多语言架构重构”。真正需要的新状态只有：

```text
projectLanguages: [LanguageID]
workspaceSessions: [AnalysisProfileID: EngineSession]
```

两者都放在现有 `AppModel` 中，直到出现第二个真实消费者再考虑提取实体。

---

## §1 当前事实基线

### §1.1 已经可直接复用的语言身份链

当前仓库已有完整的三语言单项目链：

```text
LanguageID / LanguageMode
  → ContentIndexKey(content + mode + grammar + extractor)
  → AnalysisProfile / AnalysisProfileID
  → ProjectIndexer / persistent cache
  → SnapshotView / EngineSession
  → Reader / Diff
  → ExactProvider / ExactSession / ExactOverlay
  → AppModel generation + root + language publication fence
```

关键源码事实：

| 边界 | 当前实现 | L3 处理 |
|---|---|---|
| mode | `ContentIndex.swift` 已区分 Rust、Python、TS 与 TSX variant | 只增加对语言数组的唯一分类 convenience；不新增 variant/type |
| cache | `ContentIndexKey` 已含完整 `LanguageMode` 与 extractor/grammar version | 零 schema 变化；同 store 可安全共存 |
| profile | `AnalysisProfileID.derived` 已含 language/config/environment/features | 为 nested unit 传真实 `projectRoot`；不改变 v1 framing |
| snapshot | `WorktreeSnapshot` 只接收一门语言，且 Python/TS config 只看 workspace 根 | 增语言数组捕获与只读 config path 清单 |
| commit | `CommitSnapshot` 已捕获完整 Git tree | 复用同一个 commit snapshot，不做每语言 clone |
| index | `ProjectIndexer.PreparedSnapshot`、`SnapshotView`、`EngineSession` 都是单语言原子 | 对同一 snapshot/store 按语言调用，结果用标准 dictionary 收集 |
| module root | `ModuleMap` 的Python `src/`语义默认从workspace根开始 | 传现有`AnalysisProfile.projectRoot` scalar并裁前缀，不建module strategy |
| App | `projectLanguage`、`ProjectState.ready`、搜索均只有一个 session | scalar 改为数组；`ProjectState.ready` 仍发布活动 session |
| Exact | `ExactCoordinator` 只有一个 `Active`、一个 prepare task | 正好符合 warm budget 1；增加 nested profile root 与切换 fence |
| persistence | `SessionCodec` v1 与 recent store 保存一个 language | v2/recent map 保存规范化数组并兼容旧 number |
| UI | 三个单语言 Open 菜单，drop alert 三选一 | 新增一个 Mixed 入口与 2...3 项 checkbox，不改旧菜单语义 |

L2 已有的最终验收位于
`docs/plans/evidence/l2-typescript/l2-acceptance.md`；当前 HEAD 又增加了
`.github/workflows/product-quality.yml`，在 macOS 15 上安装 pinned RA/Pyright/Node/TLS/TypeScript
并运行三语言产品门禁。L3 不重新定义这些单语言合同。

### §1.2 当前六个真实阻塞点

1. `WorktreeSnapshot(repositoryURL:language:)` 一次只捕获一种 source，并且 nested Python/TS
   config 不可枚举；无法从同一 snapshot 构造三个可信 profile。
2. `ProfileDetector` 永远把 `projectRoot` 当 `"."`，只读 workspace 根配置；真实 monorepo 的
   `crates/qrcode2txt/Cargo.toml` 和 `tools/model-files-web/tsconfig.json` 会退化为错误 profile。
3. `SnapshotView/ModuleMap` 没有消费`AnalysisProfile.projectRoot`；尤其nested Python的`src/`会被
   当成workspace-root模块路径，必须在线性root scalar上裁前缀。
4. `AppModel` 的 generation fence 比较单个 `projectLanguage`；旧语言异步完成可能在混合切换后
   发布，必须升级为规范化语言数组 + 活动 `AnalysisProfileID`。
5. content/symbol search 只查询 `ProjectState.ready` 中的一个 session；即使底层同时有三个索引，
   用户也看不到全 workspace 结果。
6. session/recent 只保存一个 language；重启、Retry、Open Recent 会把 mixed workspace 错开成
   单语言。

ReaderCore、DiffCore、三个 extractor和三个provider的每语言语义不是阻塞点；`ModuleMap`只接收现有
root scalar，不扩 import 规则。

### §1.3 固定真实 mixed corpus

主 corpus：`https://github.com/sonald/llm-tools.git`，固定 commit：

```text
457b66e72da1967c2432131a7ff8adc4341eb337
```

该 revision 的 tracked 支持文件与配置事实：

| 项 | 固定值 |
|---|---:|
| `.rs` | 11 |
| `.py` | 8 |
| `.ts`（排除 `.d.ts`） | 22 |
| `.tsx` | 4 |
| `.d.ts`（仍不支持） | 1 |
| `.js` | 0 |
| Python unit | workspace 根 `pyproject.toml` + `uv.lock` |
| Rust unit | `crates/qrcode2txt/Cargo.toml` |
| TypeScript unit | `tools/model-files-web/tsconfig.json` + `package.json` |

固定配置 SHA-256：

```text
pyproject.toml                                      0c48694c3cc9668d7e062a03e98ab41d53a5b68a7500bd977da826e5f01273e6
uv.lock                                             562ebad06578ceca1bbcd1888942fcb8bf001340dbd63ce6c4d5737c144dbe4c
crates/qrcode2txt/Cargo.toml                        e0079b229039a8a02b440878c4235f6ac05a0c5e6db71b6cf61fcf28eee947a2
tools/model-files-web/tsconfig.json                 770b4140bbb581e2dfd9ea9946ffc9c75a1d86ba7d2db5f77c83e37cbdf9d808
tools/model-files-web/package.json                  798565f0dc3bcb30375457bd8e003d7c30b14679f0e79bc6a1c50ddd0d63eb6c
tools/model-files-web/package-lock.json             8373619bda0840fb24893976201504404cd0fde71f61621057b529dfc1719d31
```

固定历史 revision：

```text
6cc5b52f9f1bef28b27133155bbb858b2891c829
```

它位于固定 HEAD 的 first-parent 链；该 revision 的 mode counts 为 Rust 11、Python 9、TypeScript/TSX
0/0，故可验证“某 revision 零 source 仍保留 selected language”。Compare 固定文件
`crates/qrcode2txt/tests/qrcode_monkey_fixtures.rs`：历史 45 行、worktree 62 行，差异为 17 行新增，
低于现有 DiffCore 限制并提供真实 hunk；不得用无源码变化的 `HEAD~1` 冒充 snapshot/Compare 验收。

它证明的是一个真实 monorepo 需要同时浏览三个独立工具单元；README 明确这些工具保持独立。
因此它**不证明跨语言调用关系**，不能据此发明 FFI/IPC heuristic。

本机 `/Users/siancao/work/ai/llm-tools` 当前存在 `.DS_Store`、截图等 untracked 用户文件。
P0/V0 必须 clone 到本次唯一临时目录并 checkout 上述 commit；不得 clean/reset/修改用户 checkout，
也不得用“只比较 tracked 文件”把 corpus 写入冒充零副作用。

### §1.4 provider 事实与官方边界

- LSP 3.17 的 workspace folders 是 capability 协商项，不是所有 server 的共同强保证：
  [LSP 3.17 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceFolders)。
- Pyright 官方配置说明 multi-root 中每个 workspace root 可有自己的 config，且 execution
  environment 按 path 选择：
  [Pyright configuration](https://github.com/microsoft/pyright/blob/main/docs/configuration.md)。
- rust-analyzer 的配置、linked project 与 build/check 行为有 provider 自身语义：
  [rust-analyzer configuration](https://rust-analyzer.github.io/book/configuration)。
- TypeScript language server 依赖自己的 workspace root、`tsserver.js` 与 initialization options：
  [typescript-language-server](https://github.com/typescript-language-server/typescript-language-server)、
  [configuration](https://github.com/typescript-language-server/typescript-language-server/blob/master/docs/configuration.md)。

因此 L3 不把 `workspaceFolders` 包装成通用 provider orchestration；每次仍把一个具体
`AnalysisProfile.projectRoot` 交给现有具体 provider。

---

## §2 冻结产品合同

### §2.1 语言选择与兼容

支持的 persisted/open language set：

```text
[rust]
[python]
[typescript]
[rust, python]
[rust, typescript]
[python, typescript]
[rust, python, typescript]
```

规范化规则：

1. 输入非空；只允许 Rust/Python/TypeScript。
2. 输入不得重复；通过验证后按 `LanguageID.rawValue` 升序。
3. 单语言 API 接受一个；Mixed UI 必须选择 2...3 个。
4. empty、任何 duplicate、含 JavaScript 或未知 raw value 都在任何 project state/cache/provider
   变化前失败。
5. 不根据 `Cargo.toml`/`pyproject.toml`/`tsconfig.json` 自动勾选语言；marker 只用于已选择语言的
   profile root 定位。

旧 `⌘O`、`Open Project…`、`openProject(root:)` 仍表示 Rust；旧显式 Python/TypeScript 菜单不变。

### §2.2 文件 mode 与 path → profile

文件 mode matrix完全继承 L1/L2：

| suffix | mode |
|---|---|
| `.rs` | Rust / nil variant |
| `.py` | Python / nil variant |
| `.ts`，但非 `.d.ts/.mts/.cts` | TypeScript / nil variant |
| `.tsx` | TypeScript / `tsx` |
| `.pyi/.pyw/.d.ts/.mts/.cts/.js/.jsx` | unsupported |

同一路径至多命中一个现有 mode，因此路由算法是：

```text
relative path
  → LanguageMode.classify(path, selected languages)
  → first/only session whose AnalysisProfile.language == mode.language
  → QueryContext(snapshotID, profileID, generation)
```

找不到 mode、找不到对应 session、session snapshot 不一致或存在两个同语言 session时均返回 nil，
不得 fallback 到“当前活动语言”。absolute dependency 的在线请求使用发起请求的 profile；session
restore 只接受selected language set内唯一的受支持后缀分类，extensionless/ambiguous dependency tab
跳过，仍不猜。

### §2.3 一个 profile / language 的 unit root 规则

对每个已选语言，从同一 snapshot 的 source/config path 求唯一 unit root：

1. Rust marker：basename 恰为 `Cargo.toml`。
2. Python marker：同目录 `pyrightconfig.json` 优先，否则 `pyproject.toml`。
3. TypeScript marker：basename 恰为 `tsconfig.json`；`tsconfig.app.json` 等不是独立 root marker。
4. 只考虑 marker directory 为该语言**所有已捕获 source path 的共同祖先**的候选。
5. 有多个合格候选时选最浅者，保留 workspace/aggregator config 语义。
6. 没有 marker 但存在该语言 source 时用 workspace 根 `"."`，保持现有无配置 fallback。
7. marker 存在但没有任一 candidate 覆盖全部 source，表示多个独立 same-language unit；mixed open
   具名失败 `multiple <language> project units are not supported in L3 V0`。
8. 某 revision 中该语言零 source 时仍保留选择集合并建立空 session/profile；profile root 用
   `"."`，Exact 显示 `no source/config in this revision`，而不是偷偷删除语言。

`AnalysisProfile.projectRoot` 保存 intern 后的 relative unit root；config reader 以该 root 为前缀。
`projectUnitName`、fingerprint、feature/edition 仍使用各语言现有 detector。L3 不解析通用 Cargo/TOML/
tsconfig workspace graph，不支持同语言多 unit。

`SnapshotView`只安装该language且位于profile root下的paths；`ModuleMap`以同一root为语义基点。Python
先裁unit root再应用现有root/`src/`规则；Rust/TypeScript保留现有relative semantics，但不得越出unit
root命中候选。

### §2.4 snapshot / store / cache

1. 每次 worktree open 或 revision switch 只创建一个 `SnapshotID`。
2. Worktree capture 一次目录遍历，捕获已选 mode 的 source union；skipped directory 与三门单语言
   规则一致。
3. WorktreeSnapshot 与 CommitSnapshot 都另外暴露只读 configuration path 清单；config 不进入
   FileTree/ContentIndex。历史 revision 的 unit root 必须从该 revision 自身的清单重新发现，不能复用
   worktree marker。
4. 同一个 `ProjectIndexStore` 依次准备各语言 `PreparedSnapshot`。可复用现有 per-language extraction
   并行；L3 V0 不再加跨语言 task group。
5. 所有生成 session 的 `snapshotID` 与 store identity 必须相同；任何一个不一致，整个 workspace
   发布失败。
6. persistent cache 继续按 `ContentIndexKey` 隔离。Rust/Python/TS/TSX 相同 bytes 仍是四个 mode
   key；mixed cold 后 singleton hot 和 mixed hot 都必须复用。
7. first paint 文件树来自 snapshot path union；`cachedReady/fullReady` 只有所有已选语言都到同一
   阶段才发布，避免半个 workspace 对外可查询。
8. mixed V0 只支持 Git worktree/commit。非 Git 单语言入口继续工作；Mixed UI 对非 Git root
   给出具名 unsupported，不新增伪造 `GitObjectFormat` 的 DirectorySnapshot。

当前 per-language `prepareSnapshot` 可能对 union snapshot 重复读取 path。P0 先量化；只要固定 corpus
在现有 30 秒 product wait 内通过，L3 不为此新增 shared extraction draft/container。若不通过，优先
在现有循环中先按 language filter，再读取 bytes，不新增 pipeline 类型。

### §2.5 AppModel 与异步发布

`AppModel` 保存：

```swift
package private(set) var projectLanguages: [LanguageID] = []
private var workspaceSessions: [AnalysisProfileID: EngineSession] = [:]
```

不保存第二份 path map。以下 identity 构成所有 async publish fence：

```text
generation
standardized project root
normalized projectLanguages
snapshotID
requested/active AnalysisProfileID（有 profile-specific await 时）
navigation generation / request ID（现有局部 fence）
```

打开、snapshot capture/prepare/complete、compare capture、session restore、Reader load、Context、
Relation、search 和 Exact 完成均在 await 后重核相应 identity。旧 profile completion 不得更新
project state、Reader、search rows、Exact readiness 或 profile menu。

新open/snapshot generation进入`.indexing`时，query session快照立即变空；新集合未原子安装前不得暴露
旧sessions。任一语言失败时清空collection/active selection后进入`.failed`，不能让package getter继续返回
上一个workspace。

`ProjectState.ready` 始终放当前活动 session/context：

- 首次 fullReady 无选中文件时，选规范化语言数组首个非空 session；全部空则首个 session。
- 选中文件 mode 未变时不重发 project state。
- mode 改变时从 `workspaceSessions` 取 session，构造新 `QueryContext`，通过现有 `.ready → .ready`
  transition 发布，并重置 Context/Relation 的 profile-specific 请求。
- selected path 无 route 时 Reader 清空并显示 unsupported，不沿用上一个 session。
- Rust active profile切feature时，以新`AnalysisProfileID`原子替换dictionary中的Rust entry，Python/TS
  sessions保持；全体query contexts使用新generation。非Rust active profile调用仍no-op。

### §2.6 搜索、Reader、Diff 与 Relations

**Content search**：对 snapshot 相同的全部 session 启动现有 `session.search`；结果按 relative path、
byte offset 稳定合并，`displayLimit=2000` 仍是 workspace 总上限。单个 stream final 不能提前结束全局
loading；所有 stream 完成才 final。任一 stream 失败时本轮整体显示 `Search failed`，不把部分结果
冒充 complete。

**Symbol search**：每个 session 使用现有 scorer；合并后按 score desc、path、name range 排序，再应用
全局 limit。current/recent path boost 使用共享 store 的 `PathID`。同一路径同 offset同 profile去重；
不同语言同名保留两行，并显示路径，不新增语言专属 symbol kind。

**File tree / Quick Open**：展示所有 selected mode path；`.d.ts/.js` 等不出现。当前文件切换自动切活动
profile。L3 V0 不加语言筛选器、badge 或 virtual group。

**Reader / outline / fold / local refs / Compare**：继续由当前文件的 `LanguageMode` 分发，ReaderCore、
DiffCore 无生产改动。历史 commit/worktree compare 仍只比较一个选中文件。

**Context / Relations**：只查询当前活动 `EngineSession`。跨语言 fuzzy 为空；同名 symbol 不跨 session
fallback。搜索命中另一语言后先切活动 session，再允许 Context/Relation 请求。

**Reading Set**：excerpt 已冻结 source/inspector display，不增加 profile 字段；从 project path 重开时按
当前 snapshot route。absolute dependency excerpt 仍按冻结内容显示。

**Navigation/Trail dependency**：有受支持后缀时按selected set分类；extensionless dependency一旦离开
发起它的active profile便不可唯一重放，诚实跳过并显示原因，不给`JumpRecord`新增language/profile字段。

### §2.7 Exact、trust 与资源预算

L3 V0 的 Exact 规则：

1. 一个 `ExactCoordinator`、一个 `Active`、一个 prepare task；最大 warm provider = 1。
2. 活动 profile 变化：取消 batch → invalidate generation/profile epoch → 关闭旧 session及后代 → 以
   新 `AnalysisProfile.projectRoot` 对应 URL prepare。
3. worktree provider root = workspace root + relative profile root。
4. commit provider root = materialized workspace root + relative profile root；location 映射仍相对整个
   workspace materialized root，所以导航得到 workspace-relative path。
5. provider target若位于workspace/materialized root内但越出active profile root，具名拒绝，不能伪装成
   dependency；真正位于workspace外的dependency继续走现有allow-list与language classifier。
6. `ExactProfileKey` 读取 profile root 下的现有语言 config；不把 workspace 根配置错误套给 nested
   unit。
7. trust registry 仍按 repository root授权。切 trust 会 invalidate 当前 provider；下次活动 profile
   以新 trust prepare。不存在一个 profile Trusted、另一个 Safe 的混搭。
   L3不改变现有Sandbox写权限：Safe对项目只读；Trusted Rust仍只可写profile root下`target/`，
   Python/TypeScript不新增project writable path。
8. offline/readiness/attribution 是当前 profile 的状态。profile toolbar 明示活动语言/unit/provider；
   未活动 profile 显示 `Not started`，不假装 unavailable。
9. snapshot switch、root/language set change、quit、cache clear 后旧 session及所有子进程必须退出。
10. current `supportedTarget(file:language:)` 保持：foreign-language exact target 被过滤。跨语言关系在
   本期统一显示 unsupported。
11. P0 若证明一次只保温一个 provider 在固定 corpus 的语言切换中无法于现有 30 秒窗口 ready，
    本计划直接 BLOCKED 并单独批准 LRU；不得在实现中临时加 pool。

L3 不修改三个 provider 的 concrete lifecycle，也不利用可选 `workspaceFolders` 构造一个跨语言 LSP
session。

### §2.8 session、Recent、Retry

`SessionCodec` v2 project envelope：

```json
{
  "schemaVersion": 2,
  "projectRoot": "/absolute/root",
  "languages": [0, 1, 2],
  "revision": null,
  "activeTabOrdinal": 0,
  "panelPreset": "balanced",
  "tabs": []
}
```

兼容合同：

- v1：缺 `language` → Rust；有 `language` → singleton；拒绝同时伪造 v2 fields。
- v2：必须有 1...3 个唯一、supported、规范排序的 raw values；不接受 `language` key。
- encoder 只写 v2；不再写 v1。
- relative project file tab不保存 language/profile；path route足够。
- absolute dependency file tab也不新增 language/profile字段；受支持后缀可唯一分类，extensionless或
  ambiguous dependency在restore时跳过，不污染其他tab。
- active tab 若被跳过，选择恢复后的最近 ordinal；无 tab仍恢复 workspace。

`RecentProjectsStore` 继续使用现有 path list和 language-map key：

- 新值为 property-list `[NSNumber]`，规范排序。
- 旧 `NSNumber` 解码 singleton；缺失/无效仍 Rust fallback。
- `record(url, language:)` 转发 singleton；新增 `record(url, languages:)`。
- 新`languages(for:)`是product reopen入口；旧`language(for:)`保留source compatibility，对mixed值只返回
  canonical first，所有Open Recent/Retry生产caller必须迁走并由`rg`门禁证明。
- Open Recent、Retry、empty state callback携带完整数组。

不增加 `RecentProject` DTO；path 与 language set 的现有两份 UserDefaults 已足够。

### §2.9 UI 与可访问性

File menu 新增 `Open Mixed-Language Project…`，打开目录后展示原生 modal：

- 三个 checkbox：Rust、Python、TypeScript；默认全不选，不自动探测。
- 少于两个时 Open disabled；Cancel 零状态变化。
- label、help、checkbox、Open/Cancel 均有 AX role/name/value；键盘可达。

drop/empty state 的现有语言 alert 增 `Mixed…`，再进入同一 checkbox modal；不复制选择逻辑。

toolbar：

- 标题显示 `Mixed · 3 languages · <active language> · <unit> · <trust>`。
- profile menu列出规范顺序的语言/unit，当前活动项有 checkmark；行只用于状态展示，不另做 profile
  selector。
- Rust feature controls只在活动 Rust profile出现；Python/TS仍无 Cargo fields。
- Exact status只描述活动 profile；切文件后先显示 Preparing/Not started，不能残留旧 provider attribution。
- unsupported/unrouted file不打开 Reader，显示具名原因。

本阶段只改菜单/profile文案与可访问性，不重设计侧栏、不加语言颜色或 icon。最终 bundle保留一张代表
主题 screenshot；主题像素未改，不重复三主题证据。

### §2.10 失败诚实与原子性

以下在任何 persistent cache/provider启动前拒绝：

- empty/duplicate-invalid/含 JavaScript的 language set；
- Mixed UI 少于两门；
- mixed non-Git root；
- 同语言多个无法由共同 unit root覆盖的 project units；
- profile language/root 与请求不匹配；
- sessions store/snapshot/language集合不一致。

运行期某语言 extraction 失败，整个 workspace进入 `.failed`；不能发布其余语言的 partial-ready state。
Exact unavailable只降级当前 profile，不使 fuzzy workspace失败。旧异步 completion只能丢弃，不能把新
workspace改成 failed。

---

## §3 明确不做

- 不做 same-language 多 `AnalysisProfile`、Cargo/TS workspace graph、Python多 execution environment UI。
- 不做 `WorkspaceSession`、`ProfileRouter`、`LanguageAdapter`、registry、plugin、capability map。
- 不做 generic LSP lifecycle/factory/config bag；不合并 RA/Pyright/TLS provider类。
- 不做两个以上 warm Exact provider、LRU/process pool或后台预热。
- 不做跨语言 fuzzy、FFI/IPC/import heuristic；不把同名当 relation。
- 不新增 JavaScript/JSX、`.pyi/.pyw/.d.ts/.mts/.cts`。
- 不扩 TypeScript fuzzy project references/path aliases，不解析通用 tsconfig。
- 不为 mixed 另造 extractor/cache/gold格式；四套现有 Gold语义保持。
- 不支持 mixed non-Git目录；不伪造 Git object format。
- 不给每个 project tab/excerpt重复存 language/profile。
- 不增加 file tree语言筛选器、badge、virtual grouping或主题重做。
- 不修改 `Package.swift`、tree-sitter vendor、DeclarationKind、ReaderCore/DiffCore语义。
- 不修改 CanonicalDump、Prototypes、既有 Rust/Python/TypeScript fixtures/gold、M11/L1/L2历史证据。
- 不读、清理或重置用户现有 `/Users/siancao/work/ai/llm-tools` checkout。

---

## §4 P0 可行性与停止条件

P0 全程只读产品仓库；临时 probe、clone、logs写入本次 `mktemp -d`。输出归档到实施时新增的
`docs/plans/evidence/l3-mixed/p0-feasibility.md`。没有 P0 GO，不开始 production patch。

### P0a：corpus 与 unit-root 事实

1. 从 HTTPS clone `sonald/llm-tools` 到唯一 temp目录，checkout固定 SHA。
2. 断言 HEAD精确、`status --porcelain=v1`为空、固定历史 revision可由first-parent到达。
3. 断言 mode counts `11/8/22/4`、unsupported `.d.ts=1/.js=0`。
4. 断言六个 config hash与 §1.3一致。
5. 用计划中的共同祖先规则手工/脚本求得：
   - Python `.`；
   - Rust `crates/qrcode2txt`；
   - TypeScript `tools/model-files-web`。
6. 断言固定历史revision counts `11/9/0/0`，TS profile为空但selected set不变；固定Rust Compare文件
   `45→62`行且有17行新增。
7. 构造一个 temp negative fixture：同语言两个独立 config root且 source分开；算法必须得出 ambiguous，
   不能按最浅目录之外的猜测吞掉一支。
8. gate前后比较 HEAD、status、index、tracked/untracked/ignored path+bytes hash。

**停止**：HTTPS不可获得固定 commit、counts/hash漂移、三个 unit root不唯一，均为 BLOCKED；不得换小
fixture冒充真实 mixed corpus。

### P0b：共享 capture/index/cache probe

用现有底层 API和最小 throwaway probe回答，不提交 production code：

1. 一次遍历捕获 union path的峰值 bytes与耗时；分别记录三次 singleton总和作对照。
2. 证明现有 `ProjectIndexStore` 可同时保存四种 mode key，同 bytes跨语言/TSX不碰撞。
3. 记录 per-language prepare在 union snapshot上的重复 read次数与总耗时。
4. 冷 cache、mixed hot cache、mixed→singleton hot、singleton→mixed hot分别记录 extracted/reused。
5. 固定 corpus从 open到 firstPaint、cachedReady、fullReady均须落在现有 30 秒 product等待窗口；
   若重复 read导致超时，批准“filter before read”的局部修改，不新增 pipeline类型。
6. commit snapshot使用一个 SnapshotID，三个 session snapshot相同；config/root身份精确。

**停止**：需要复制 store、改变 `ContentIndexKey` schema、或无法共享 SnapshotID时 NO-GO，先重审
M12地基。

### P0c：三个 nested provider root 与 warm-budget=1

在 clean clone上分别以真实 root启动当前 pinned provider，不执行项目 package manager/build script：

| profile | provider root | 最小真实目标 |
|---|---|---|
| Rust | `crates/qrcode2txt` | `src/lib.rs` 的 `Report::from_results` definition/references |
| Python | `.` | `src/tools/analysis/analysis.py` 的 `LogitsAnalyzer.get_top_tokens` |
| TypeScript | `tools/model-files-web` | `src/core/tokenizer.ts` 的 `inspectTokenizerStructure` |

逐个记录：provider/tool版本、initialize capabilities、首次ready/definition/references时间、Safe/Trusted、
deny-network、cache允许写、cancel、close后的PID/descendant=0。Safe使用主clean clone并要求project零写；
Trusted使用第二个可丢弃clone，Rust若写入只能位于nested profile的`target/`，Python/TypeScript不得新增
project writable path，且三者均不得改tracked/index。然后模拟
Rust→Python→TS→Rust，每次先关闭旧 provider，确认当前 profile在现有30秒边界内可用，旧 completion不
发布。

TypeScript根 `tsconfig.json` 使用 project references；L3只验证真实TLS Exact，不据此扩 fuzzy或profile
parser。若当前 concrete provider不能在该root完成definition+references，L3 BLOCKED并更换/批准 corpus，
不得放宽 Exact合同或偷装项目依赖。

### P0d：session迁移与UI原型

1. 用当前 v1 fixture验证 singleton decode向 v2内存模型迁移。
2. 枚举 v2 empty/duplicate/unsorted/JavaScript/unknown/mixed dependency tab负例。
3. 用 AppKit测试构造 checkbox alert，锁定 AX hierarchy、Open disabled逻辑和Cancel零副作用。
4. 锁定 mixed profile title/menu文案；不做高保真视觉原型。

### P0 GO 清单

- [x] fixed clean corpus与unit roots可复查；
- [x] shared snapshot/store/cache identity无需新schema/type；
- [x] 三个真实provider在nested root单独PASS；warm=1切换在30秒内；
- [x] deny-network、Safe project零写、Trusted既有allow-list未扩大、close后代=0；
- [x] v1→v2迁移与mixed chooser可执行；
- [x] 已把实测时间/RSS基线写入P0 evidence；
- [ ] 用户批准P0 GO后才开始F0/F1。

---

## §5 架构与数据流

### §5.1 打开与索引

```text
Open Mixed…
  → explicit [Rust, Python, TypeScript]
  → validate + normalize
  → capture WorktreeSnapshot once (source union + config path inventory)
  → first-paint union FileTree
  → discover one project root per language
  → prepareSnapshots(snapshot, root, languages)
       └─ existing per-language prepareSnapshot × N on one shared store
  → verify same snapshot/store + exact language set
  → publish all cached sessions atomically
  → completeSnapshot × N
  → publish all full sessions atomically
  → select/retain file
  → publish active EngineSession through existing ProjectState.ready
  → lazily prepare Exact for active profile only
```

### §5.2 文件选择与查询

```text
file URL
  → workspace-relative path
  → LanguageMode from selected language set
  → workspaceSessions.values.first(profile.language == mode.language)
  → QueryContext(shared snapshotID, selected profileID, generation)
  ├─ Reader / Diff
  ├─ Context / Relation
  └─ ExactCoordinator (one active provider)
```

Content/Symbol search是唯一默认 fan-out 的查询；它们对全部 sessions执行后合并。其他查询保持
single-session，避免把各语言 resolver结果拼成无语义的总图。

### §5.3 snapshot switch

```text
current workspace sessions
  → cancel search/navigation/compare/exact
  → generation += 1
  → capture CommitSnapshot/worktree once
  → first paint union paths
  → prepare/complete N sessions against same shared store
  → atomic workspaceSessions replacement
  → route retained selected path, or clear selection
  → prepare active Exact at new revision
```

每个 snapshot独立重新发现 profile root；profile ID可因 config/revision变化。selected language set来自用户
workspace选择，不因某revision文件为零而改变。

### §5.4 type/concept budget

允许的生产面变化：

- 现有 API新增 `[LanguageID]` overload/convenience；
- `Snapshot` 增 configuration-path只读入口（有默认实现以兼容test fakes，两个production snapshot
  都显式实现）；
- `IndexService`只增array capture/prepare requirements；默认仅转发singleton，mixed具名unsupported；
- `AppModel.projectLanguage`迁移为`projectLanguages`；
- 一个私有 `[AnalysisProfileID: EngineSession]`；
- SessionCodec字段/schema升级；
- 现有 UI menu/action。

禁止新增：

```text
WorkspaceSession / WorkspaceProfile / ProjectLanguageSet
ProfileRouter / Route / RouteResult
LanguageAdapter / LanguageRegistry / LanguagePlugin
ExactPool / ProviderPool / GenericLSPSession
MixedSnapshot / MixedIndex / MixedSearch
```

如果实现中发现某个新类型“让代码更整洁”，但没有两个独立生产消费者，先用private function/tuple/
stdlib collection。类型新增必须单独写YAGNI说明并重新批准计划。

---

## §6 实施切片

每片遵守红→绿；每片绿后单独 commit，不积到最后。手写 production/test文件目标为1...5个；generated
artifact不适用但L3预计没有。任何片失败，后续cutover不开始。

### F0：冻结实时基线与保护面

**依赖**：P0 GO。

**文件**：

- `docs/plans/evidence/l3-mixed/l3-acceptance.md`（新增，记录实时结果）

**动作**：

1. 记录实际HEAD/branch/upstream/worktree/index/untracked、Swift/Xcode/macOS、provider版本、`RECORD`
   unset、secret scan。
2. `CODEX_SANDBOX=1 bash scripts/ci.sh` 必须完整exit 0；记录真实test count，不能只看filter。
3. 当前三语言 product-quality workflow/manual gate实跑exit 0；provider skip即FAIL。
4. 冻结现有 Rust/Python/TypeScript gold、fixtures、vendor grammar、CanonicalDump、Prototypes、M11/L1/L2
   evidence blob/tree hash。
5. 冻结 current 16-channel matrix与four Gold totals。

**绿门**：baseline及protected hash全PASS；否则BLOCKED，不改production。

### F1a：语言数组分类与union worktree capture

**依赖**：F0。

**文件**：

- `Sources/CodeInsightCore/ContentIndex.swift`
- `Sources/CodeInsightGit/GitSnapshot.swift`
- `Tests/CodeInsightCoreTests/CoreBehaviorTests.swift`
- `Tests/CodeInsightGitTests/GitSnapshotTests.swift`

**红测**：

- selected languages的唯一mode matrix；invalid/duplicate/JS由调用边界拒绝；
- 一次worktree capture得到 `.rs/.py/.ts/.tsx` union且排除 `.d.ts/.js`；
- worktree与commit recursive config inventory都含三个nested unit config，config不出现在worktree
  `listFiles()`/FileTree；切历史revision使用该commit自己的marker；
- worktree与commit的symlink config marker均排除；skipped dirs/project bytes零写；旧singleton
  initializer结果逐字一致。

**实现**：给现有 `LanguageMode` 增 package-level array classification；给
`WorktreeSnapshot` 加语言数组initializer并让singleton转发；给 `Snapshot` 加只读configuration path入口
及默认空实现，`WorktreeSnapshot`/`CommitSnapshot`都显式实现。不新增snapshot类型。

**绿门**：Core/Git targets全绿，`git diff --check` PASS。

### F1b：nested profile root发现

**依赖**：F1a。

**文件**：

- `Sources/CodeInsightEngine/ProfileDetector.swift`
- `Sources/CodeInsightEngine/ProjectIndexer.swift`
- `Tests/CodeInsightEngineTests/ProfileDetectorTests.swift`
- `Tests/CodeInsightEngineTests/SnapshotIndexerTests.swift`

**红测**：

- llm-tools形状fixture发现 `.`, `crates/qrcode2txt`, `tools/model-files-web`；
- same-language两个independent roots具名失败且零cache write；
- absolute、空component、`.`/`..` configuration/source path在root选择前拒绝，不能构造越界
  `projectRoot`；
- ancestor/prefix按path component比较，`tools/py2`不得命中`tools/py`；
- no-marker fallback `.`；zero-source revision保留empty profile；
- profile `projectRoot`、unit/config/environment fingerprint按subroot读取；
- old root-level Rust/Python/TS fixed vectors不变。

**实现**：在现有detector中增加path-prefix reader与private root选择函数；`ProjectIndexer`把选择的
relative root intern后传入。不开通same-language多profile。

**绿门**：ProfileDetector/Engine focused suites及三门characterization PASS。

### F1c：active view与ModuleMap unit-root fence

**依赖**：F1b。

**文件**：

- `Sources/CodeInsightEngine/ProjectIndexStore.swift`
- `Sources/CodeInsightEngine/ModuleMap.swift`
- `Tests/CodeInsightEngineTests/CodeInsightEngineTests.swift`
- `Tests/CodeInsightEngineTests/SnapshotIndexerTests.swift`

**红测**：

- nested Python `tools/py/src/pkg/a.py`按`pkg.a`解析，不泄露`tools.py`前缀；
- active view不安装profile root外的same-language occurrence；path越界负例由F1b边界验证挡住；
- nested Rust crate的crate/super与TS relative import保持现有结果，TS `../`不能越unit root命中；
- root `.` 的Rust/Python/TS characterization逐字不变。

**实现**：`SnapshotView`从现有`AnalysisProfile.projectRoot`解析一个relative root scalar，过滤active
paths并传给`ModuleMap`；Python helper先裁该prefix再复用当前root/`src/`逻辑，Rust/TS只加boundary
guard。不新增module-root类型、protocol或strategy。

**绿门**：Engine resolver/module/snapshot完整target PASS，production diff无新entity。

### F2：同snapshot/store准备N个session

**依赖**：F1c。

**文件**：

- `Sources/CodeInsightEngine/ProjectIndexer.swift`
- `Sources/CodeInsightAppModel/AppModel.swift`（仅IndexService/ProjectIndexService区域）
- `Tests/CodeInsightEngineTests/SnapshotIndexerTests.swift`
- `Tests/CodeInsightAppModelTests/AppModelTests.swift`

**红测**：

- array capture只调用一次production snapshot initializer；协议默认对singleton转发、对mixed拒绝，
  不以N次singleton capture冒充union；
- mixed prepare返回3个唯一语言session，共享snapshotID/store/interner；
- cold/hot extracted/reused按语言和TSX准确；
- 任一profile mismatch/duplicate language/different snapshot失败，未返回partial数组；
- cached/full阶段都保持相同profile集合；
- unsupported/mixed non-Git与ambiguous units在persistent cache构造前失败。

**实现**：`IndexService`只增加
`captureSnapshot(root:revision:languages:)`与
`prepareSnapshots(_:root:languages:)`两个requirements；extension默认对singleton调用旧API，对mixed抛
featureUnsupported，现有conformer无需样板。`ProjectIndexService`显式override：capture一次union；prepare先
完成全部unit/profile验证，再构造一个persistent indexer并按规范语言顺序调用现有per-language prepare，
返回标准array。completion仍逐项调用现有API。先顺序执行，不新增array index/complete或跨语言task group。

**绿门**：Engine/AppModel focused suites，cache cold/hot证据，`swift build --target
CodeInsightAppModel` PASS。

### C1：snapshot / profile / index checkpoint

- [ ] F1a/F1b/F1c/F2 focused与完整Core/Git/Engine tests PASS；
- [ ] 一个SnapshotID、一个store、三个封闭session；
- [ ] mixed unit ambiguity无cache/provider副作用；
- [ ] singleton behavior/cache fixed vectors不变；
- [ ] production diff无新增type/protocol/dependency。

### F3：AppModel workspace collection与原子发布

**依赖**：C1。

**文件**：

- `Sources/CodeInsightAppModel/AppModel.swift`
- `Tests/CodeInsightAppModelTests/AppModelTests.swift`
- `Tests/CodeInsightAppModelTests/SnapshotSwitchTests.swift`

**红测**：

- explicit mixed open规范化languages并只捕获一次；旧single open相同；
- firstPaint/cached/full只在所有sessions同阶段原子发布；
- selected `.rs/.py/.ts/.tsx` 分别发布正确session/context；同mode文件不重复reset；
- package-level query session快照按规范语言顺序返回`[(EngineSession, QueryContext)]`，不泄露可变
  dictionary；
- old generation/root/language-set/profile completion全部丢弃；
- new open/snapshot/failure在首个await前让query session快照为空，旧workspace不再可搜索；
- commit→worktree roundtrip保留选择集合、共享snapshot与正确active route；
- 某revision某语言零source不删除选择。
- active Rust feature切换只迁移Rust dictionary key，保留Python/TS；切走再切回仍为新profile，
  non-Rust调用no-op。

**实现**：scalar迁到`projectLanguages`；加入private session dictionary、package-level只读query session
tuple数组和少量route/publish helper；`ProjectState`签名保持不变。coverage聚合union file total与session
indexed count。

**绿门**：AppModel/SnapshotSwitch完整target PASS；无旧`projectLanguage`生产caller。

### F4a：活动session消费者与profile fence

**依赖**：F3。

**文件**：

- `Sources/CodeInsightAppModel/AppModel.swift`
- `Sources/CodeInsightAppModel/ContextWindowModel.swift`
- `Sources/CodeInsightAppModel/RelationTreeModel.swift`
- `Tests/CodeInsightAppModelTests/AppModelTests.swift`
- `Tests/CodeInsightAppModelTests/RelationTreeModelTests.swift`

**红测**：

- Rust token request后切Python，旧Context/Relation/Reader completion不发布；
- `QueryContext.analysisProfileID`变化但generation相同时也重置profile-specific state；
- same-language navigation不重启Exact/Relation；
- search命中另一语言后导航先切session，再解析local binding；
- cross-language同名fuzzy结果为空且evidence不伪造。

**实现**：所有project-state consumer同时比较snapshot/profile/generation；复用现有cancel/requestID，不增
route token类型。

**绿门**：Context/Relation/AppModel tests及现有navigation App tests PASS。

### F4b：workspace content search

**依赖**：F3，可与F4a在不同文件上并行，最终顺序commit。

**文件**：

- `Sources/CodeInsightAppModel/SearchPanelModel.swift`
- `Sources/CodeInsightApp/SearchPanel.swift`
- `Tests/CodeInsightAppModelTests/SearchPanelModelTests.swift`
- `Tests/CodeInsightAppTests/MainWindowControllerTests.swift`

**红测**：

- 一次query同时命中三门语言，path/offset稳定排序；
- total/display limit按workspace计，不被每session final提前结束；
- one stream error整体failed；取消/新query丢弃所有旧stream；
- `SearchPanel` show/refresh传入完整session快照，不退回active-only；
- singleton groups与排序不变。

**实现**：model接收AppModel提供的session/context tuple数组，复用现有per-session searcher；用task
group或顺序async stream的最小可测方案，以P0时延决定。结果合并留在现有model，不建MixedSearch。

**绿门**：SearchPanelModel与App search focused tests PASS。

### F4c：workspace symbol search

**依赖**：F3，可与F4a/F4b在不同文件上推进，提交前串行复核。

**文件**：

- `Sources/CodeInsightAppModel/SymbolSearchPanelModel.swift`
- `Sources/CodeInsightApp/PalettePanel.swift`
- `Tests/CodeInsightAppModelTests/AppModelTests.swift`
- `Tests/CodeInsightAppTests/PaletteTests.swift`

**红测**：

- 一次query同时命中三门语言；merge按score desc、path、name range稳定排序；
- 同名跨语言保留，current/recent path boost使用共享PathID；
- 新query/profile set变化后旧detached completion不发布；
- `PalettePanel` project-symbol mode传入完整session快照；singleton rows不变。

**实现**：`SymbolSearchPanelModel`接收同一tuple数组，逐session复用现有`searchSymbols`后稳定合并；
`PalettePanel`只负责转发快照。不建symbol aggregate/result类型。

**绿门**：AppModel symbol tests与Palette完整target PASS。

### F4d：Reader / Compare / replay route

**依赖**：F4a。

**文件**：

- `Sources/CodeInsightAppModel/AppModel.swift`
- `Tests/CodeInsightAppModelTests/ReadingSetTests.swift`
- `Tests/CodeInsightAppModelTests/SnapshotSwitchTests.swift`
- `Tests/CodeInsightAppTests/RelationNavigationTests.swift`

**红测**：

- four modes加载正确Reader grammar/highlight/outline/fold/local refs；
- TSX仍variant `tsx`，same bytes TS/TSX不串；
- selected file compare使用自己的mode；切语言旧diff completion丢弃；
- mixed project-path reading trail跨语言replay，commit/worktree route正确；extensionless dependency
  离开origin profile后具名跳过；
- unsupported路径清空Reader且不fallback活动语言。

**实现**：仅改AppModel route/fence与测试；若测试暴露ReaderCore/DiffCore改动需求，STOP重审，不能在本片
顺手扩语义。

**绿门**：ReaderCore/ReaderUI/AppModel/App focused tests全PASS且production ReaderCore/DiffCore零diff。

### F5a：SessionCodec v2与Recent语言数组

**依赖**：F3。

**文件**：

- `Sources/CodeInsightAppModel/SessionCodec.swift`
- `Sources/CodeInsightAppModel/RecentProjectsStore.swift`
- `Tests/CodeInsightAppModelTests/SessionCodecTests.swift`
- `Tests/CodeInsightAppModelTests/RecentProjectsStoreTests.swift`

**红测**：

- v1 missing/explicit language→singleton；v2 roundtrip canonical；
- v2 empty/duplicate/unsorted/JS/unknown/oversize拒绝；
- project/dependency tab编码保持无language/profile字段；mixed dependency的唯一后缀分类与ambiguous跳过
  由restore测试覆盖；
- recent old number/new array/missing/invalid fallback；record覆盖与prune保持；
- encoder sorted-key deterministic vector。

**实现**：升级existing envelope/fields，不新增DTO层级之外实体；保留v1 decoder分支，encoder只写v2。

**绿门**：codec/recent tests PASS，旧payload fixtures不改或只新增v2 fixture。

### F5b：mixed checkpoint/restore/retry

**依赖**：F4d + F5a。

**文件**：

- `Sources/CodeInsightAppModel/AppModel.swift`
- `Sources/CodeInsightApp/MainWindowController.swift`
- `Tests/CodeInsightAppModelTests/SessionRestoreTests.swift`
- `Tests/CodeInsightAppTests/MainWindowControllerTests.swift`

**红测**：

- mixed fullReady checkpoint保存languages、revision、active跨语言tabs；
- normal Quit/restore重开mixed、等待fullReady、逐tab按mode恢复；
- supported-suffix dependency按mode恢复；extensionless dependency ambiguity只跳该tab；
- Retry/Open Recent使用完整set；old singleton行为不变；
- restore期间用户显式open另root时旧restore不发布。

**绿门**：SessionRestore/MainWindow/AppModel targets PASS；schema v1兼容证据记录。

### C2：App/query/Reader/persistence checkpoint

- [ ] AppModel完整target及Reader/App focused suites PASS；
- [ ] F4b content与F4c symbol两个真实UI caller均转发完整session快照；
- [ ] mixed search/Reader/Context/Relation/Compare/replay可从一个workspace连续使用；
- [ ] snapshot/profile/generation stale gates有确定性红绿测试；
- [ ] session/recent v1兼容与v2 mixed恢复PASS；
- [ ] Core/Engine/Reader语义类型无新增抽象。

### F6：nested Exact root与单warm切换

**依赖**：C2 + P0c。

**文件**：

- `Sources/CodeInsightExact/ExactProvider.swift`
- `Sources/CodeInsightAppModel/ExactCoordinator.swift`
- `Sources/CodeInsightAppModel/AppModel.swift`
- `Tests/CodeInsightExactTests/CodeInsightExactTests.swift`
- `Tests/CodeInsightAppModelTests/ExactCoordinatorTests.swift`

**红测**：

- worktree/commit profile root下读取config并启动provider；路径映射回workspace relative；
- workspace内但active profile root外的location被拒绝且不登记dependency；真实外部dependency仍按
  现有language/allow-list合同处理；
- Rust→Python→TS→Rust每次旧batch取消、旧session close、后代0、attribution不残留；
- same profile文件切换不重启；profile ID/config/revision变化必须重启；
- trust变更影响当前及下一profile，不能出现mixed trust；
- foreign-language exact target仍过滤，UI/query返回unsupported而非同名fallback；
- old profile environment callback和restart completion不发布；
- singleton Exact全部characterization不变。

**实现**：Exact prepare增加workspace root + relative profile root scalar；Active记录映射所需root/profile ID；
保持一个Active，不建pool。`ExactProfileKey` reader加prefix，不改provider protocol。

**绿门**：Exact/ExactCoordinator完整target，三provider Safe real P0 repeat，close descendants=0，Safe
项目零写；Trusted disposable-clone allow-list测试PASS。

### C3：Exact checkpoint

- [ ] 三门nested root真实definition/references按advertised capabilities PASS；
- [ ] warm provider恒≤1，切换/取消/restart/quit无孤儿；
- [ ] trust/offline/readiness/attribution严格属于活动profile；
- [ ] cross-language关系诚实unsupported；
- [ ] 三个provider生产文件除必要path root外无重构。

### F7：Mixed UI与最后product cutover

**依赖**：C3。

**文件**：

- `Sources/CodeInsightApp/CodeInsightApp.swift`
- `Sources/CodeInsightApp/MainWindowController.swift`
- `Tests/CodeInsightAppTests/MainWindowControllerTests.swift`

**红测**：

- File menu存在Mixed项且旧三项/Cmd-O不变；
- checkbox modal 0/1项disabled、2/3项enabled、Cancel零状态；
- drop/empty state复用同一chooser；
- mixed toolbar/profile menu active check、unit/trust/Exact状态、Rust-only features；
- AX role/name/value、键盘与菜单validation；
- unsupported/non-Git/ambiguous error不记录recent。

**实现**：现有delegate/controller加actions和private chooser函数；不建view-model/controller类型。

**绿门**：CodeInsightAppModel/App target build与AppKit focused tests PASS；Mixed入口至此才可见。

### F8：mixed product self-test与17通道harness

**依赖**：F7。

**文件**：

- `Sources/CodeInsightApp/CodeInsightApp.swift`
- `scripts/run-self-tests.sh`
- `scripts/run-product-gates.sh`

新增唯一flag：

```text
--self-test-mixed <llm-tools-repo>
```

现有positional harness兼容扩展：

```text
3 args = 14 base
4 args = + Python = 15
5 args = + Python + TypeScript = 16
6 args = + Python + TypeScript + Mixed = 17
```

不支持跳过前置corpus把第4/5参数解释成mixed。

self-test一条连续journey：

1. preflight fixed SHA/count/config hash/clean；
2. fresh cache explicit三语言open；firstPaint/fullReady；
3. tree恰有11 Rust、8 Python、22 TS、4 TSX，无`.d.ts`；
4. global content/symbol search各命中至少两门语言；
5. 依次打开Rust/Python/TS/TSX，验证active profile、Reader、Context、same-language Relation；
6. 真实active Exact按Rust→Python→TS切换，definition/references、attribution、旧PID退出；
7. 切固定 `6cc5b52...` 再回worktree；验证TypeScript零source时profile set不缩水，并对固定Rust文件
   得到17行真实新增hunk；
8. checkpoint、normal model shutdown、hot recent reopen/reused>0、session restore；
9. 结构化summary包含per-language files/extracted/reused、profile roots、provider versions、switch latency、
   snapshot IDs、all checks；
10. 前后repo完整state hash一致，`SELF_TEST_FINISH ... exit=0`，provider descendants=0。

**绿门**：17/17 pass、fail=0、hang=0；四套Gold仍原计数/unexpected=0。

### F9：mandatory macOS product-quality gate

**依赖**：F8。

**文件**：

- `.github/workflows/product-quality.yml`
- `docs/plans/evidence/l3-mixed/l3-acceptance.md`

workflow用HTTPS clone fixed llm-tools SHA到runner temp，检查config hashes/counts后把第三个corpus传给
`run-product-gates.sh`。artifact增加mixed stdout/stderr/timeout/sample及corpus log。provider missing、
mixed skip、17通道不足、corpus写入、orphan均使job失败。

**绿门**：真实macOS 15 host run exit 0，artifact可下载复查；不能用本地记录冒充workflow PASS。

---

## §7 依赖图

```text
P0 → F0
      ↓
     F1a → F1b → F1c → F2 → C1
                               ↓
                              F3
              ┌──→ F4a → F4d ──┐
              ├──→ F5a ────────┴→ F5b ──┐
              ├──→ F4b ─────────────────┼→ C2
              └──→ F4c ─────────────────┘
                                           ↓
                               F6 → C3 → F7 → F8 → F9 → V0
```

F4a/F4b/F4c/F5a可在合同冻结后按文件边界推进；F4d依赖F4a，F5b依赖F4d+F5a，C2还要求
F4b/F4c均完成。共享AppModel test helpers的提交必须串行rebase/复核。
F6不与AppModel/restore并行编辑。每个checkpoint都跑Rust/Python/TypeScript singleton回归。

---

## §8 V0 总验收

### §8.1 自动门禁

按顺序，任一步非零立即停止：

```bash
test -z "${RECORD:-}"
CODEX_SANDBOX=1 bash scripts/ci.sh

bash scripts/run-product-gates.sh \
  /absolute/frozen/mcp-python-sdk \
  /absolute/frozen/morphic \
  /absolute/frozen/llm-tools
```

其中product gate必须证明：

- 完整Swift tests确实报告N tests passed，不接受incomplete output；
- 17-channel self-test pass=17/fail=0/hang=0；
- Rust/Python/TypeScript/mixed真实provider均未skip；
- tokio/ripgrep/Python/TypeScript四套Gold totals和known-fail不变，unexpected=0；
- mixed cold/hot per-language counts正确；
- 所有corpus前后HEAD/status/index/tracked/untracked/ignored bytes一致；
- provider descendants=0；
- `git diff --check`、secret scan、protected hashes、forbidden entity names PASS。

L3不新增mixed Gold，因为路由层没有新的语言语义。self-test与unit/integration tests承担mixed合同。

### §8.2 final bundle

1. 生成唯一bundle ID与唯一、启动前不存在的output dir；不清理正式`dev.cairn.Cairn`数据。
2. `CODEX_SANDBOX=1 bash scripts/make-app.sh`（以脚本实际参数为准）构建Cairn.app+zip；验证两者
   Info.plist/bundle ID与`codesign --verify --strict`，解压后再验一次。
3. 正常LaunchServices `open -n`，不`launchctl setenv`、不富化PATH、不用debug binary。
4. 同一bundle先做Rust singleton回归，再Python、TypeScript singleton smoke，确保旧入口未回归。
5. File ▸ Open Mixed-Language Project打开fixed llm-tools clone，显式勾三门语言。
6. 验证union tree、global search、四mode Reader、active profile menu、Rust-only features、每语言Exact
   attribution、provider切换与旧PID退出。
7. 切固定`6cc5b52...`验证TS零source仍保留选择集合、Rust固定文件17行Compare hunk，再回worktree；
   Reading Trail/Context/Relation不跨profile污染。
8. normal Quit并等待app/provider全退出；同bundle relaunch，session恢复mixed、active tab/profile正确；Open
   Recent和Retry仍为三语言。
9. 保存一张代表主题 screenshot与AX tree/log到
   `docs/plans/evidence/l3-mixed/`；记录SHA-256、尺寸、bundle PID/provider PID序列。
10. 再次normal Quit；app/provider descendant=0；三个单语言corpus、mixed corpus、CodeInsight repo状态均
    与前置hash一致。

若正常bundle无法发现任一provider、mixed exact 30秒内不ready、AX不可用或app/provider无法回收，结论是
`BLOCKED`；不得用self-test/debug/skip改写为product PASS。

### §8.3 结构门禁

production源码必须满足：

```text
0 WorkspaceSession
0 ProfileRouter / RouteResult
0 LanguageAdapter / Registry / Plugin
0 GenericLSPSession / ProviderPool / ExactPool
0 MixedSnapshot / MixedIndex / MixedSearch
0 new public protocol/type
0 new dependency / Package.swift change
```

允许的collection仅AppModel私有dictionary与现有类型array。若计划实施中新增实体，V0直接FAIL，除非先
修订并重新批准本文。

### §8.4 范围门禁

- protected blobs/trees与F0一致；
- existing single-language menus/API/session payload兼容；
- CanonicalDump/Prototypes/vendor grammar/old fixtures/gold/M11/L1/L2 evidence零改；
- ReaderCore/DiffCore/extractor/provider concrete语义无顺手扩展；
- local user llm-tools checkout零操作；
- no push/tag/publish，除非用户另行明确授权。

### §8.5 完成定义

只有以下全部成立才可称L3完成：

- 自动门禁与final bundle均PASS且有成功exit/status证据；
- mixed真实项目三门同时可搜索/阅读，活动session准确；
- Exact单warm切换诚实、无孤儿、无跨语言伪关系；
- worktree/commit/session/recent roundtrip语言集合不丢失；
- 三个singleton产品journey无行为回归；
- repo/corpora零副作用，结构/YAGNI门禁PASS。

---

## §9 风险与停止条件

| 风险 | 早期信号 | 对策 |
|---|---|---|
| collection扩散到所有model | 大量`[EngineSession]`参数 | `ProjectState`只发active session；仅search fan-out |
| same-language多unit偷渡 | 两个独立Cargo/tsconfig root | V0具名拒绝，不猜，不建通用router |
| union snapshot重复读太慢 | fullReady>现有30秒 | 先filter-before-read；不建draft pipeline |
| profile root错误 | provider在workspace根找不到config | snapshot config inventory + prefix detector红测 |
| stale profile污染 | generation相同但profile变化 | fence加入profileID/snapshotID |
| 多provider吃内存/留孤儿 | 同时出现RA/Pyright/TLS | warm budget=1，切换先close并验PID=0 |
| global search提前final | 首个session结束即停止loading | 计数全部stream完成后再final |
| session v1被破坏 | old payload无法恢复Rust | 专门v1 decoder branch/fixed fixtures |
| Safe mixed corpus被写 | node_modules/target/.venv出现 | deny project write + 全状态hash，不运行package manager |
| UI概念膨胀 | badge/filter/虚拟组 | 只加chooser与active profile文案 |
| 跨语言同名误连 | Rust/Python同名出现Strong | 不跨session查询；foreign exact继续过滤 |
| L3顺手扩语言 | `.d.ts/.js`进入tree | fixed negative counts + protected L2 scope |

以下任一发生即BLOCKED并回到计划评审：

1. 固定corpus不能同时通过三个现有provider的minimum Exact；
2. 需要改变`ContentIndexKey`/cache schema或复制store；
3. 需要第二个same-language profile才能完成固定corpus；
4. warm=1真实切换超过30秒且没有用户批准pool；
5. cross-language relation被提升为产品必需但provider无可靠证据；
6. mixed non-Git被提升为本期必需；
7. 新增public abstraction/dependency才能继续；
8. singleton CI/gold/product journey不再全绿。

---

## §10 自检记录

本节是计划作者在写完后的第一轮自检；实施前仍需人类批准与F0实时复核。

### §10.1 正确性

- [x] 计划保留每个`EngineSession`单语言封闭，不让foreign index进入resolver。
- [x] snapshot/store/profile/query context identity均进入发布合同。
- [x] worktree与commit都提供自己的configuration inventory，历史revision不借用当前marker。
- [x] active view与ModuleMap都消费现有profile root，nested Python不会把workspace前缀当模块名。
- [x] worktree、commit、session restore、recent、Retry路径均覆盖语言集合。
- [x] mixed某语言失败不冒充partial-ready；Exact unavailable只降级当前profile。
- [x] v1 session/recent向后兼容有明确decoder与负例。
- [x] 未给tab/excerpt增加language/profile字段；ambiguous dependency restore只跳单tab。
- [x] cross-language relation明确unsupported，不声称真实corpus证明了不存在的调用。

### §10.2 架构与YAGNI

- [x] 没有新增`WorkspaceSession`/router/registry/plugin/provider pool。
- [x] `ProjectState`保持active single session，避免迁移全部消费者与测试。
- [x] routing使用现有`LanguageMode`+最多三个session的线性查找。
- [x] Exact复用现有单Active coordinator，warm budget=1。
- [x] one-profile-per-language和Git-only是具名V0边界，不预留空容器。
- [x] 新实体预算为0；必要变化都是现有类型字段/overload/private helper。

### §10.3 安全与副作用

- [x] language set、profile root、path、session payload均在边界验证。
- [x] provider继续deny network/Safe/Trusted现有策略，未执行project package manager。
- [x] fixed corpus使用clean temp clone；用户dirty checkout明确只读。
- [x] project、cache、materialized、PID/descendant审计均进入P0/V0。
- [x] unsupported/ambiguous在cache/provider前失败。

### §10.4 性能与资源

- [x] capture一次、store一个、cache key复用。
- [x] 搜索总上限沿用2000；session数量硬上限3。
- [x] Exact warm session硬上限1，避免未经测量的三provider常驻。
- [x] 重复read先P0量化，只有超现有30秒窗口才做局部filter-before-read。
- [x] 未增加materializer/pipeline/LRU实体。

### §10.5 可执行性

- [x] 每片列出依赖、1...5个主要文件、红测与绿门。
- [x] dependency graph、C1/C2/C3、V0和停止条件完整。
- [x] real corpus SHA/count/config hash与nested roots已从当前checkout读取。
- [x] historical revision、`11/9/0/0` counts与固定Rust `45→62/+17` Compare事实已实读。
- [x] 17-channel harness参数语义与现有3...5参数兼容。
- [x] final bundle、AX、normal Quit/relaunch、provider discovery与zero-write可复查。
- [x] 未把author acceptance记录冒充未来实时PASS。

### §10.6 自检结论

**PASS（计划可进入P0，不能直接越过P0写production）**。

已主动删除的过度方案：workspace aggregate type、stored path router、multiple same-language profile、
multi-provider LRU、mixed Gold、generic workspaceFolders orchestration、语言badge/filter。若未来真实数据证明
其中任一是必要能力，应以新的失败证据修订本文，而不是在实现切片中顺手加入。

---

## §11 开工清单

- [x] 用户批准本文的Git-only、one-profile-per-language、Exact warm=1、cross-language unsupported边界；
- [x] P0 clean clone、三个provider、unit roots、cache/时延/副作用全部GO；
- [ ] F0实时CI/product gate/protected hashes PASS；
- [ ] 每片红测先落，绿后独立commit；
- [ ] C1/C2/C3未通过不进入后续cutover；
- [ ] F7前Mixed产品入口不可见；
- [ ] V0前不宣告mixed支持完成。
