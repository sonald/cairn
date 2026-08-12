# L2 实施计划 v1：TypeScript 单语言项目 vertical slice

> 状态：**草案；P0 尚未执行，尚未授权修改生产代码。**
>
> 草拟时实施基线：`2ace2ebf4ed78b1ae1bc1fa64b6d6917620c6b0d`，工作区干净。
> L1 产品基线：`44c6c4a`（Python vertical slice）；其后两个 Reader 稳定性提交属于
> 本计划 F0 的实时基线，不回写 L1 历史 evidence。
>
> 本计划延续 M12 的单活动语言模型。混合项目仍属于 L3；L2 不为它预留
> session collection、path router 或 registry。

---

## §0 结论先行

L2 可行，但必须先通过三个 P0 gate：

1. 真实编译并链接 TypeScript 与 TSX 两套 tree-sitter grammar，冻结来源、license、
   archive SHA、parser ABI 和 SwiftPM C target 布局；
2. 在现有 sandbox 内证明外部 TypeScript language server 能离线、只读地完成 Exact，
   且主进程和它创建的 `tsserver` 后代都能被取消、关闭和回收；
3. 冻结一个真实 TS+TSX corpus、revision、fuzzy/Exact 边界和具名产品验收目标。

不需要再做一次“多语言架构重构”。M12/L1 已有的 `LanguageMode`、`LanguageExtractor`、
`AnalysisProfile`、`ContentIndexKey`、`ModuleMap`、`ReaderDocument`、`ExactProvider` 和
`ExactSession` 足以承载第三门语言。实现只在现有五个 ownership switch 增加
`.typescript` 分支：capture/profile、extractor/index、module/resolver、Reader/diff、Exact。

```text
显式 TypeScript 打开
  -> .ts/.tsx capture + TypeScript AnalysisProfile
    -> TypeScriptExtractor 按 mode 选择 TS/TSX grammar
      -> cache/search + 有限且诚实的 fuzzy import resolution
        -> TS/TSX Reader/outline/fold/local refs + diff
          -> TypeScript language server Exact
            -> recent/session/history/final .app E2E
```

只要任一层未通过，`AppModel.validateProductSupport(.typescript)` 就继续拒绝 TypeScript。
不得先开放文件树，再以空 Reader、空 relation 或“Exact unavailable”冒充完成。

L2 新增生产实体的 allow-list 只有：

1. vendored TypeScript/TSX grammar C target（一或两个 target 由 P0 链接结果决定；不是 Swift 抽象）；
2. `TypeScriptExtractor`：同时处理 `.ts` 和 `.tsx`；
3. `TypeScriptLanguageServerProvider`；
4. `TypeScriptLanguageServerSession`。

新增 `DeclarationKind` case 只算既有枚举的真实数据值，不算新架构实体。Reader walk、profile
fingerprint、module path 计算和 LSP JSON 转换使用现有文件内或 package/internal free function；
不新增 adapter、registry、factory/config bag、`TSXExtractor` 或 generic LSP runtime。

---

## §1 冻结产品决策

### §1.1 文件与 mode matrix

| 路径 | `LanguageMode` | L2 行为 |
|---|---|---|
| 小写 `*.ts`，但先排除 `*.d.ts` | `(.typescript, nil)` | 支持 |
| 小写 `*.tsx` | `(.typescript, "tsx")` | 支持 |
| `*.mts` / `*.cts` | nil | 推后 |
| `*.d.ts` / `*.d.mts` / `*.d.cts` | nil | 推后 |
| `*.js` / `*.jsx` | nil | 不支持 |
| 大写或混合大小写扩展名 | nil | 不支持 |

必须先判断完整文件名后缀 `*.d.ts`，不能只看 `pathExtension == "ts"`。

- `.ts` 和 `.tsx` 属于一个项目语言、两个文件 mode；一个 `EngineSession` 可以同时包含两者。
- `.tsx` 的稳定 variant 固定为字符串 `"tsx"`，不新增 `LanguageVariant` enum。
- 一个 `TypeScriptExtractor` 根据 `ContentIndexKey.languageMode` 选择两套 grammar；不新增
  `TSXExtractor`。
- 同字节 `.ts` 与 `.tsx` 可以有相同 `ContentID`，但必须产生不同 `ContentIndexKey`、cache entry、
  parse tree、Reader document 和 identifier-search 结果。
- 仅接受无 BOM 的有效 UTF-8；UTF-8 BOM、非 UTF-8 与 generated source-map 另立切片，并在 extractor
  parse 前具名失败。

官方 tree-sitter 仓库明确把 TypeScript 与 TSX 作为两个 dialect/grammar：
[tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript)。`.mts/.cts` 强制携带
模块格式语义，不能静默当普通 `.ts`：
[TypeScript 4.7 file extensions](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-4-7.html#new-file-extensions)。
`.d.ts` 是声明文件而不是普通实现文件：
[Type declaration files](https://www.typescriptlang.org/docs/handbook/2/type-declarations.html#dts-files)。

### §1.2 单项目与显式语言选择

- 一个打开态只有 `.typescript` 一个 `AnalysisProfile`、`EngineSession` 和 `ExactSession`。
- 项目中的 `.rs/.py/.js/.jsx/.d.ts` 不进入 tree、index、Reader、search 或 relation。
- 现有 `Open Project…` / ⌘O 与 `openProject(root:)` 保持 Rust compatibility。
- 新增 `Open TypeScript Project…`，显式调用现有 `openProject(root:language:)`。
- recent、retry、session restore 和 snapshot switch 复用现有 project-level `LanguageID` scalar；
  不给 tab、excerpt 或 file occurrence 重复写项目语言。
- drag/drop 等没有语言 identity 的目录入口在最终 cutover 提供 Rust/Python/TypeScript/Cancel；
  不依据 marker 或文件数量自动猜。
- `.javascript` 继续在任何状态变化、cache I/O 或 provider 启动之前原子拒绝。

### §1.3 grammar 分发

- 只 vendor 官方 `tree-sitter-typescript` release/tag 对应的生成源码、必要 headers、LICENSE 和
  `VENDORED.md`。
- P0 现场冻结 tag/full commit、download URL、archive SHA-256、license、TS/TSX parser ABI。
  计划不预写未经下载验证的 hash 或 ABI。
- P0 必须实际裁决两份 generated parser/scanner 能否放在同一个 SwiftPM C target；若共享内部符号
  导致冲突，使用两个最小 C target。对 Swift 侧仍只暴露一个 `TypeScriptExtractor`。
- 不改现有 `CTreeSitter`、`CTreeSitterRust`、`CTreeSitterPython` 或 `Package.resolved`。
- grammar version 与 extractor version 只影响 TypeScript key；升级 TypeScript grammar 不清空
  Rust/Python cache。

### §1.4 profile、配置与 cache identity

继续使用现有 `AnalysisProfile`，不新增 TypeScript profile/config 类型：

- `language = .typescript`；
- `projectUnitName = "tsconfig.json"`；若根文件缺失则使用项目根目录名；
- config identity：根 `tsconfig.json` + 根 `package.json`，按固定文件名、长度和完整字节 framing 后
  SHA-256；无文件使用固定、非空 sentinel hash，避免 Materializer 空路径组件；
- environment identity：本期固定 corpus 的根 `bun.lockb`，按文件名 + NUL + 完整字节 SHA-256；
  无文件为空；其他 lock manager 出现被批准的真实 corpus 后再加，不先造 package-manager registry；
- `featureSelection = .defaultFeatures`、`featureNames = []`、`edition = nil`、初始 trust `.safe`。

增加一个与 `pythonConfigIdentity` 同级的 package free function，供 `ProfileDetector` 与
`ExactProfileKey` 共用。它只接受 `readBytes` closure 并返回现有 fingerprint tuple；不解析 JSON，
不新增 `TypeScriptConfig`。完整文件 hash 可能因无关字段变化多做一次重建，但不会错误复用；首片接受
这个保守成本。

`ContentIndexKey`、cache codec/schema、manifest 和 session codec 已携带足够 identity，生产结构不改：

- 同字节 `.ts`/`.tsx` 依靠完整 `LanguageMode` 隔离；
- `SessionCodec.Snapshot.language` 已能编码 raw value 2；旧 payload 缔结为 Rust；
- TypeScript round-trip/restore 先以测试证明，测试未暴露缺陷则不改 `SessionCodec.swift`。

### §1.5 capture 边界

- Worktree source 只捕获 classifier 认可的 `.ts/.tsx`。
- 继续跳过 `.git`、`node_modules`、`target`、`.build`、`dist`、`build`、venv 和 cache 目录；
  不遍历 `node_modules`。
- 根 `tsconfig.json`、`package.json`、`bun.lockb` 作为 configuration files 可由 profile/Exact
  `readBytes`，但不进入 source list、文件树或 fuzzy index。
- 不递归捕获 nested `tsconfig.json`，不实现 project references/workspaces/monorepo router。
- Commit snapshot 保持列出 Git tree，再由统一 classifier 构造 active view；不复制一套 commit capture。
- 下层显式 `.typescript` 入口在产品放行前可测试，但 `.javascript` 与非法 variant 必须在任何
  filesystem/cache side effect 之前失败。

### §1.6 module resolution 边界

TypeScript 官方 module resolution 依赖 host、compiler options、package metadata 与 resolution mode：
[Modules reference](https://www.typescriptlang.org/docs/handbook/modules/reference.html)。因此 fuzzy 只承诺
manifest 内、确定且可解释的子集；Exact 负责完整 tsconfig/host 语义。

L2 fuzzy 支持：

- 相对 `./`、`../` specifier；
- exact captured path；
- extensionless `.ts`、`.tsx`；
- directory `index.ts`、`index.tsx`；
- relative named import 与 alias；default/namespace import只记录unresolved evidence，不承诺跨文件命中；
- `export { ... } from` 和 `export * from` 的现有最多四跳 re-export 链；
- non-relative alias（包括固定corpus的`@/*`）在fuzzy保持unresolved，交给Exact；不为了一个corpus
  硬编码root alias或新增tsconfig配置通路。

不实现通用`paths`引擎：不支持root alias、多个target、wildcard composition、`baseUrl`、package
exports/imports、node_modules或ambient modules。所有non-relative specifier返回unresolved。

诚实性规则：

- lexical/same-file 可 `Strong`；
- fuzzy import 命中最多 `Probable`，`completeness = .partial`；
- method name-only 最多 `Possible + dynamicDispatch`；
- 未经 import 的跨文件同名在 TypeScript 返回空，不沿用全项目唯一名字 `Probable` fallback；
- namespace/default receiver 与 type-only import可记录unresolved import evidence，不伪连runtime call；
- 越出 root、多候选、unsupported extension、package dependency 都 unresolved；不读实时磁盘补猜。

### §1.7 TypeScript language server 分发

- L2 使用用户本机已安装的 community-maintained
  [`typescript-language-server`](https://github.com/typescript-language-server/typescript-language-server)，
  它是 `tsserver` 的 LSP wrapper，不把它描述为 Microsoft 官方 LSP。
- Cairn 不 bundle/install/update Node、TypeScript 或 language server，不执行 npm/bun/yarn/pnpm；缺失 provider
  只使 Exact unavailable，fuzzy/Reader 项目仍可打开。
- GUI discovery 不能依赖交互 shell PATH。复用现有 internal executable discovery：sanitized absolute PATH
  entries，再检查 `/opt/homebrew/bin` 与 `/usr/local/bin`；所有 helper canonical path 必须位于项目外。
- P0 冻结一条项目外 toolchain：`node`、`typescript-language-server`、`tsserver.js`；
  不选择 workspace `node_modules/typescript`。
- 实际启动固定为外部 `node <canonical language-server entry> --stdio`，避免 shebang 再从不可信 PATH
  选 Node。
- `toolVersion` 包含 language server、TypeScript、Node 的版本与 canonical runtime identity；任一变化
  使 Exact overlay reuse miss。

### §1.8 trust、sandbox 与项目副作用

- Safe/Trusted 请求均复用 `Sandbox(... trustMode: .safe)`：项目只读、Cairn 私有 cache/tmp 可写、
  network denied。请求 trust mode 仍进入 attribution/reuse key。
- TypeScript 不继承 Rust `target/` 写权限，不安装依赖，不执行 package scripts，不执行 workspace
  TypeScript、plugins 或 Automatic Type Acquisition。`node_modules` 的“不遍历”只约束 Cairn capture/
  fuzzy/project enumeration；sandbox 可允许 pinned tsserver 只读依赖声明，这不把依赖加入 Cairn manifest。
- initialize 固定请求关闭 ATA、plugins、tsserver logs；固定外部 `tsserver.js`。具体 option key/value 由
  P0 transcript 锁定，不在生产实现中猜。
- 现有 sandbox 是项目完整性、网络和写边界，不是 host confidentiality boundary；UI/evidence 不称其为
  秘密隔离。
- provider base environment 继续标记现有 `dependenciesUnavailableOffline` limitation；依赖缺失不得显示
  “完整分析”。
- P0 必须覆盖 TS language server 创建的 `tsserver` 后代。仅回收直接 LSP process 不算通过。

### §1.9 固定真实 corpus

首选并现场复核：

```text
/Users/siancao/work/ai/morphic
origin: https://github.com/miurla/morphic
HEAD:   f31fe4a9ce2d355c3a44203fcb6add9296cc9b61
HEAD~1: 431e5c5e179b1b01946c6a5559ac43df459619db
classifier-supported tracked: 2 .ts + 51 .tsx; deferred .d.ts: 0; excluded .js: 1
config: package.json + tsconfig.json + bun.lockb
```

该 revision 当前 clean，`HEAD~1..HEAD` 在 `components/search-results-image.tsx` 有真实 TSX hunk。
`tsconfig.json` 包含 `@/* -> ./*` 和 `plugins: [{ "name": "next" }]`，所以它同时检验TSX、fuzzy对
non-relative alias诚实unresolved、Exact能按真实config导航，以及“项目plugin不执行”的安全边界。

P0 不得为了让实现变简单而静默换 corpus：

- 若 pinned external provider 无法在禁网/只读/不加载 plugin 的前提下解析该项目，P0 `NO-GO`；
- `@/*` fuzzy必须unresolved，Exact必须在pinned safe provider下按真实config解析；
- call hierarchy/implementation 的具名 symbol 与期望数量只在 P0 实跑后冻结；计划不杜撰。

所有gold/self-test/V0 gate前后比较HEAD、status、index、tracked及ignored/untracked tree hash；corpus零写入。

---

## §2 成功合同

### §2.1 完整产品合同

- 显式 TypeScript open 完成 indexing/fullReady，tree 只含 `.ts/.tsx` 且两种 mode 同时存在。
- content/symbol/reference search、Reader、context/relations、Compare、snapshot switch、Exact、recent 与
  session restore 全链均保持 `.typescript`。
- worktree → `HEAD~1` → worktree 每次重建 snapshot/profile/mode；`.tsx` 不跨 revision 降级为 nil mode。
- cold/hot cache 对 rust、python、typescript(nil)、typescript(tsx) 四种 `LanguageMode` key 隔离并可共存；
  这不是四个项目语言/session。
- provider 缺失时 fuzzy/Reader 可用且 Exact 诚实 unavailable；安装存在时 final bundle 完成 §6.2。
- `.javascript` 与所有 deferred extension 保持 unsupported，不产生半成品文件或导航结果。

### §2.2 extractor/fuzzy 合同

最小 runtime-navigation slice 只增加：

- `DeclarationKind.typescriptFunction = 13`；
- `DeclarationKind.typescriptClass = 14`。

method 使用 `typescriptFunction + parentFacetIndex -> typescriptClass`，不加 method kind。L2 不索引
interface/type alias/enum/property 为 declaration；TypeScript 类型系统的精确导航交给 Exact。若真实 gold
证明 runtime slice 无法使用，再以真实 producer/consumer 追加 case，不预留占位。

提取语义：

- declaration：顶层 function/class、class direct method、顶层 variable 绑定的 arrow/function expression、
  export wrapper；对本文件真正导出的具名声明产出现有`ExportRecord(name,nil)`，未导出声明不进入跨文件
  import候选；匿名/default export首片不承诺；
- scope：module、function/method、class、block；
- binding：参数、简单 identifier `let`/`const`；fuzzy现有`BindingRecord`只能按name下界激活，首片不承诺
  `const x = x`这类self-initializer的精准解析；Reader local refs仍按initializer后激活；若真实gold要求
  fuzzy精准activation，再以真实数据需求扩模型；
- shadowing：nested block/function 局部解析；
- call：identifier call/new 为 direct；非 computed member call 为 method；computed member 不建 call fact；
- import/export：§1.6 子集，type-only flag 保留但不伪造 runtime target；
- diagnostics：语法 error node 进入已有 `containsErrorNodes`；非法 mode 在 parse 前具名失败。

明确不承诺 destructuring、hoisting、self-initializer fuzzy binding、namespace merge、overload signature merge、decorator execution、
generic/type reference、object property、JSX component relation、dynamic import、`require()` 或 receiver type
inference。不能支持的语法保持可读文本和无关系，不制造 name-only Strong。

### §2.3 Reader/Diff 合同

- `DocumentLoader` 依据 mode 选择 TS/TSX grammar；非法 variant 在 parse 前失败。
- 一次 parse 产生 highlight、outline、fold，并把同一 tree 交给 extractor 的 package local-ref helper；
  不二次 parse。
- highlight 只复用现有 kind：keyword、comment/comment figure、整段 string/template、number、boolean、null、
  function/method/class/type name；JSX tag 首片保持普通文本，不加 HighlightKind。
- outline：function、class、method、顶层 arrow/function component；depth 只随真实 nesting 变化。
- fold：function/method/arrow的跨行`statement_block`、class、if/else、for/while、switch、try/catch/finally，
  以及连续imports/comments；expression-bodied或单行arrow不产fold；继续交给现有laminar resolver。
- local refs：参数/简单 binding/shadowing/Reader RHS activation；排除 keyword、comment、string、number、property
  key/member 与 type token。
- line diff 对 TS/TSX 开放；function diff 只筛 `typescriptFunction`，class/member chain 使用 `.`；
  TSX body 必须由 TSX grammar fingerprint。
- Rust/Python Reader/Diff fixed fixtures 与可见行为不变。

### §2.4 Exact capability 合同

provider maximum沿用现有四项：definition、implementations、references、call hierarchy。P0现场冻结
server实际advertised set；session capability是advertised与maximum的交集，未advertised项诚实unsupported。
L2的最小Exact完成门是definition + references；call hierarchy/implementation只有实际advertised时才是
强验收，不因社区server少报一个可诚实降级的能力阻断整语言。

- `.ts` didOpen language ID 为 `typescript`；`.tsx` 为 `typescriptreact`。
- initialize 完成后直接发请求；不调用 RA `waitForQuiescence`，不复制 RA `-32801` retry。
- 只为 P0 实际观察到的 TS-specific transient 做 provider-local、次数/时间有界处理。
- `serverInfo == nil` 可接受；生产 `toolVersion` 来自启动前预读的项目外 canonical toolchain。
  `$/typescriptVersion` 在 P0 transcript 中交叉核对 source/version，但首片不为这个异步 notification
  新增观察 API 或 readiness gate；只有真实错选 toolchain 无法被预读/启动参数阻止时才修订本计划。
- 复用 `ExactRequestBatch` 的取消门、operation lock、restart once、second crash unavailable、
  shutdown → exit → kill/reap；不得留下 language server 或 tsserver descendant。
- definition/location/call hierarchy解析与路径转换继续使用`LSP.swift`现有internal free functions；只有
  `callHierarchyItemObject`/definition wrapper等确实第三次重复时，才把该无状态转换就地收敛，
  不抽lifecycle protocol。
- historical materialized snapshot 返回历史内容下的位置；不得偷用 worktree path/content。

### §2.5 失败诚实与回归合同

- `.javascript`、deferred extension、非法 variant、profile/provider mismatch 在 I/O/进程启动前具名失败。
- stale open/snapshot/compare/Exact completion 必须同时核对 root + language + generation + mode/profile；
  不发布旧 TypeScript 结果到 Rust/Python 或另一 revision。
- Rust/Python raw values、key fixed vectors、gold、Reader、Exact、recent/session 与 final bundle journey 不变。
- L1 后的 comment fold 预期已经在 `2ace2eb` 对齐；L2 没有“已知 FoldID 5 issue”，也不回写历史
  L1/M11 evidence。

---

## §3 明确不做

- 不做 mixed workspace、多 `AnalysisProfile`/`EngineSession`/Exact session 或 path router。
- 不新增 `LanguageAdapter`、registry、plugin、capability map、service locator 或 factory/config bag。
- 不新增 generic LSP session/lifecycle strategy；三个 provider 的 readiness/restart/sandbox 保持 concrete。
- 不新增 `ModuleMap` protocol/strategy、`TypeScriptModuleResolver` 类型或动态 resolver registration。
- 不新增 `LanguageVariant` enum、`TSXExtractor`、`TypeScriptHighlighter`、Reader adapter 或新 error hierarchy。
- 不支持 JavaScript/JSX、`.mts/.cts`、declaration files、default import/export导航、source maps或自动语言探测。
- 不实现通用 tsconfig parser、project references、nested configs、workspaces、package exports/imports、
  `baseUrl` 或完整 `paths`。
- 不运行 package manager、项目 script、workspace compiler/plugin，不安装依赖；Cairn capture/fuzzy不遍历
  `node_modules`，Exact provider仅在sandbox内只读依赖声明。
- 不把 CLI 全面多语言化；只扩展现有 `goldset --language` 所需的 `.typescript` case。
- 不改 `CanonicalDump.swift`、`Prototypes/`、M11/L1 历史 evidence、既有 Rust/Python fixtures/gold、
  Rust/Python grammar vendor 或 `Package.resolved`。
- 不为未来语言重命名 concrete Rust/Python 类型；不创建“以后也许有用”的 placeholder case/hook。

---

## §4 P0 可行性与停止条件

P0 只允许 probe、临时目录和 `docs/plans/evidence/l2-typescript/p0-feasibility.md`；不改生产代码、
Package.swift、现有 fixtures 或 corpus。

### P0a：grammar/ABI/link probe

记录并验证：

1. 官方 release/tag/full commit、archive URL、SHA-256、license；
2. TS/TSX 两个 C entry、node-types field 名与 parser ABI；
3. 当前 TreeSitterKit runtime 对两套 parser 的实际构造/parse；
4. 同一 C target 链接；冲突时两个最小 C target；
5. `.ts` 基础语法与 `.tsx` self-closing JSX 均无 root error；
6. TS grammar 解析 TSX fixture 必须失败或产生 error，证明不能静默 fallback；
7. generated source、header、scanner 的最小 vendor allow-list。

以下任一发生即 P0a `NO-GO`：来源/hash/license 不可固定；任一 grammar 不能在当前 runtime parse；
必须修改 TreeSitterKit public API；必须新增第二个 Swift extractor/registry 才能选择 grammar。

### P0b：Exact/trust/lifecycle probe

在 basic TS+TSX fixture 与固定 morphic corpus 上记录：

1. `command -v`、canonical paths、Node/TLS/TypeScript versions；单测注入 `PATH=""` 的 discovery，
   以及独立的正常 LaunchServices bundle discovery；不假定真实GUI PATH必为空；
2. 外部 pinned `tsserver.js` 的 `$/typescriptVersion.source == "user-setting"`，版本与预读一致；
3. initialize capabilities 与`serverInfo`；TS/TSX definition/references必须通过；implementation与incoming/
   outgoing只对actual advertised capability验收；
4. first request、warm request、cancel、timeout、crash/restart、second crash；
5. project plugin、ATA、workspace toolchain、project PATH/npm/npx/bun/yarn/pnpm marker 全未执行；
   plugin/ATA必须有能触发marker的正向control arm，或有等价的argv/protocol状态证据，避免假绿；
6. deny network、项目只读、仅 Cairn private cache/tmp 写；除Git状态/index/tracked hash外，还对包含
   ignored/untracked条目的完整项目树做前后快照，捕获`.tsbuildinfo`/log/cache等隐蔽写入；
7. graceful close、forced kill、App SIGABRT/SIGKILL 后语言服务及全部 tsserver descendant 为零；probe
   必须走production `Sandbox → wrapper → LSPClient → CProcessGuard`启动链，记录本次PID/PPID/PGID并
   有界轮询，不能用全局`pgrep`；
8. worktree、materialized `HEAD~1`、切回 worktree 的 location/content identity。

以下任一发生即 P0b `NO-GO`，L2 不开始生产实现：

- pinned toolchain source/version 不一致；
- 发生网络、项目写入、依赖安装、ATA、plugin 或项目 helper 执行；
- basic TS/TSX fixture不能完成definition+references，或advertised的implementation/call hierarchy无法完成；
- readiness 只能依赖 RA status/quiescence 或无界 sleep；
- 取消后旧请求仍发布，或第二次 crash 仍伪装 ready；
- language server/tsserver descendant 无法可靠回收；
- 历史 snapshot 返回 worktree location/content。

### P0c：真实 corpus/fuzzy scope probe

冻结 morphic revision/count/config hashes，并抽取可稳定验收的：

- 一个 same-file/local binding；
- 一个 relative import；
- 一个 `@/*` fuzzy unresolved + Exact resolved 对照；
- 一个 re-export；
- 一个 TSX outline/fold/local-ref；
- `HEAD~1..HEAD` Compare hunk；
- Exact definition/references及实际advertised implementation/call hierarchy symbol与期望。

若 `@/*` fuzzy没有诚实unresolved、Exact无法按真实config解析，或安全禁用project plugin后corpus无法完成
产品journey，P0c `NO-GO`；
不得换小 fixture 冒充真实项目 V0。

P0 全部 GO 后，先提交/批准 evidence，再开始 F1。

---

## §5 实施切片

每片遵循红→绿→回归→`git diff --check`；每片最多 1–5 个手写文件，vendored/generated 目录除外。
“1–5个文件”按一个worker ownership bundle计；同一逻辑片若列出更多文件，必须拆成顺序子提交且每个
中间点编译green。任何checkpoint未全绿，App产品validator继续拒绝`.typescript`。

### F0：冻结实时实施基线

**依赖**：批准本计划；P0 尚可并行，但生产代码不得开工。

**文件**：只写 `docs/plans/evidence/l2-typescript/l2-acceptance.md` 的 baseline 部分。

**动作**：

- 记录实际 `L2_BASE` full SHA，不照抄草拟 SHA；
- 记录 worktree/index/untracked、Swift/Node/provider版本和 `RECORD`；
- `CODEX_SANDBOX=1 bash scripts/ci.sh` 捕获真实 exit/test counts；
- 冻结受保护路径 blob/tree、Rust/Python gold计数、14+Python self-test状态；
- 确认当前 comment fold focused test PASS，不登记旧 known issue。

**停止**：baseline CI 稳定失败或受保护路径不明即 `BLOCKED`。

### P0：grammar、Exact、安全与 corpus

按 §4 执行，只提交 evidence。P0 evidence 必须明确 `GO/NO-GO`，列出原始命令、退出码、版本、
能力、写入/进程审计和未决项；历史 spike 只能作为起点，不能冒充当前 PASS。

### F1a：vendored TS/TSX grammar

**依赖**：P0a GO。

**文件**：

- `Package.swift`；
- new `Sources/CTreeSitterTypeScript*/**`（P0 决定一或两个 C target）；
- `Tests/TreeSitterKitTests/TreeSitterKitTests.swift`。

**红测**：两个 C entry/field lookup 不存在；TSX JSX 与 TS grammar 隔离未证明。

**实现**：仅 vendor P0 allow-list；记录 LICENSE/VENDORED；不包装 Swift grammar registry。

**绿门**：两 grammar 构造、ABI、field lookup、TS/TSX parse、错误 dialect 证据；Rust/Python parser tests不变。

### F1b：core mode identity

**依赖**：F1a。

**文件**：

- `Sources/CodeInsightCore/ContentIndex.swift`；
- `Tests/CodeInsightCoreTests/CoreBehaviorTests.swift`；
- `Tests/CodeInsightEngineTests/SnapshotIndexerTests.swift`。

**红测**：classifier 当前拒绝 TS；同字节 TS/TSX key尚无产品 fixed vector。

**实现**：唯一classifier加§1.1 matrix；不改key/schema，不提前增加尚无producer的declaration case。

**绿门**：`.ts/.tsx/.d.ts/.mts/.cts/.js/.jsx/大小写`矩阵；variant NFC/Codable；同字节key不同；
Rust/Python raw value与fixed vectors逐字不变。非法variant的零parse/零cache门留给真实producer F2a/F4a。

### F2a：`TypeScriptExtractor`

**依赖**：F1b。

**文件**：

- `Package.swift`；
- `Sources/CodeInsightCore/ContentIndex.swift`（只追加13/14两个真实case）；
- new `Sources/CodeInsightTypeScriptExtractor/TypeScriptExtractor.swift`；
- new `Tests/TypeScriptExtractorTests/TypeScriptExtractorTests.swift`；
- new `Tests/TypeScriptExtractorTests/Fixtures/basic_project/**`。

**红测顺序**：mode/grammar选择 → function/class/method/arrow parent identity → scope/binding →
direct/member/new calls → import/export/re-export → diagnostics/local refs → invalid UTF-8/BOM/variant零parse。

**实现**：此时才追加`DeclarationKind` 13/14并由一个extractor生产；现有穷举消费者在各自功能片补齐
（Engine F3a、Diff F5b）；文件内private walk/free functions；
按vendored node-types/field lookup驱动，不猜AST field；不建builder class hierarchy。

**绿门**：§2.2全合同；TSX JSX无error，TS mode拒绝同一TSX；bad variant/BOM/non-UTF8在parser observer或
source closure调用前失败；property/type/JSX token不误算local ref；导出的具名声明可跨文件、未导出同名
unresolved；default/type-only/namespace不伪连runtime；fixture fixed dump稳定。production type审计只新增
`TypeScriptExtractor`。

### F2b：capture 与 profile identity

**依赖**：F1b；可与 F2a 并行。

**文件**：

- `Sources/CodeInsightCore/QueryContext.swift`；
- `Sources/CodeInsightGit/GitSnapshot.swift`；
- `Sources/CodeInsightEngine/ProfileDetector.swift`；
- `Tests/CodeInsightGitTests/GitSnapshotTests.swift`；
- `Tests/CodeInsightEngineTests/ProfileDetectorTests.swift`。

**红测**：Worktree/Profile 当前拒绝/fallback TypeScript；config identity无实现。

**实现**：capture §1.5；增加 shared fingerprint free function；profile复用现有字段。

**绿门**：tree/list仅TS/TSX；按classifier统计固定corpus为2 `.ts`+51 `.tsx`且`.d.ts/.js`为0；config可读
但不列出；node_modules/symlink跳过；worktree/commit fingerprint
fixed vector一致；tsconfig/package/lock分别只改变对应 identity；无配置使用 nonempty sentinel；JavaScript在
遍历前失败且零cache/fs side effect。

### F3a：ModuleMap 与 resolver

**依赖**：F2a、F2b。

**文件**：

- `Sources/CodeInsightEngine/ModuleMap.swift`；
- `Sources/CodeInsightEngine/Resolver.swift`；
- `Sources/CodeInsightEngine/EngineSession.swift`；
- `Tests/CodeInsightEngineTests/CodeInsightEngineTests.swift`。

**红测**：ModuleMap当前fatal；Resolver unique import会Strong、global fallback会跨文件猜，且不检查
export visibility/typeOnly。

**实现**：在现有 concrete switch 加 §1.6；`EngineSession.kindWeight`补13/14；允许`candidate`接收默认
`.complete`参数，仅TS import传`.partial`；direct match先要求目标具名export；增加typeOnly/default/
namespace runtime guard、TS certainty cap、无import返回空/method分支。不新增resolver type/protocol。

**绿门**：`./service`、`../service`、exact、extensionless、directory index、TS↔TSX、root alias unresolved、
barrel chain；越root/非相对/unsupported/multi-target unresolved；relative named import≤Probable/partial；
未export同名、type-only value/call、default/namespace均unresolved；method≤Possible；未import同名空；
Rust/Python characterization不变。

### C1：grammar / extractor / profile / resolver checkpoint

运行 Core、TreeSitterKit、TypeScriptExtractor、Git、Engine focused targets。结构审计确认：

- 只有一个 Swift `TypeScriptExtractor`；
- `ContentIndexKey`/cache/session schema未改；
- 无 registry/adapter/new profile/module resolver type；
- App validator仍拒绝 TypeScript。

### F4a：ProjectIndexer、cache、search、tree

**依赖**：C1。

**文件**：

- `Sources/CodeInsightEngine/ProjectIndexer.swift`；
- `Tests/CodeInsightEngineTests/SnapshotIndexerTests.swift`；
- `Tests/CodeInsightEngineTests/SnapshotSearchTests.swift`。

`SnapshotSearch.swift` 预计不改；其现有 extractor/mode seam必须由测试证明，而不是复制分支。

**红测**：Indexer当前拒绝 TypeScript。

**实现**：`languageExtractor`/profile switch返回现有 concrete实现；保留底层 unsupported guards。

**绿门**：同一项目同时index TS/TSX；cold extracted、hot reused；variant-only miss；grammar/extractor升级
只miss TS；content/symbol/reference/identifier search选对grammar；commit snapshot等价；foreign language不进
active view；Rust/Python cache共存。

### F4b：TypeScript gold gate

**依赖**：F4a、P0c。

**文件**：

- `Sources/CodeInsightCLI/CodeInsightCLI.swift`；
- new `goldset/morphic-typescript.gold`；
- `scripts/run-gold-gates.sh`。

**实现**：现有 goldset language switch只加 `typescript`；脚本加显式 fixed corpus/revision preflight和
前后state hash；不建 corpus registry，不改其他 CLI。

**gold**：same-file、relative、root alias unresolved、re-export、direct call/local binding、TSX、nostrong；
真实 bug才用已有 `# KNOWN-FAIL`，TypeScript unexpected failure必须0。tokio/ripgrep/Python文件内容与计数不变。

### F5a：TS/TSX Reader syntax、fold、local refs

**依赖**：F1a、F2a；可与 F3/F4 并行。

**文件**：

- `Package.swift`；
- new `Sources/CodeInsightReaderCore/TypeScriptReaderSyntax.swift`；
- `Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift`；
- `Sources/CodeInsightReaderCore/Folding.swift`；
- `Tests/CodeInsightReaderCoreTests/ReaderCoreTests.swift`。

**红测**：DocumentLoader当前parse前unsupported；TS/TSX各自grammar observer=1，bad variant/BOM/invalid UTF-8
observer/source closure=0；TSX JSX、RHS/property/type排除和single-line arrow无fold均先红。

**实现**：module-internal/private walk；一次parse产出§2.3；复用现有 value types/fold resolver/error。

**绿门**：TS/TSX byte geometry、highlight、outline depth、laminar folds、shadow/RHS activation/property和
type排除、TSX grammar证据、跨行block fold、expression/single-line arrow无fold、large/detached syntax；
Rust/Python fixtures逐字不变。

### F5b：line/function diff 与 Reader UI

**依赖**：F5a、F2a。

**文件**：

- `Sources/CodeInsightReaderCore/DiffCore.swift`；
- `Tests/CodeInsightReaderCoreTests/DiffCoreTests.swift`；
- `Tests/CodeInsightReaderCoreTests/ReaderUITests.swift`；
- 必要时 `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`，仅测试证明现有mode transport缺陷才改。

**红测**：line/function diff当前unsupported；TS/TSX支持、bad variant在比较/parse前失败、TSX JSX body、
`Class.method`点号display与Rust/Python separator分别先红。

**实现**：line/function diff按§2.3；ReaderUI应由 `ReaderDocument.languageMode` generic transport驱动。

**绿门**：TS/TSX line diff、signature/body/add/remove、`Class.method`、arrow component、TSX JSX body change；
Reader viewport/outline/fold/local-reference显示；Rust `::`、Python `.`与所有 legacy fixtures不变。

### C2：Reader/Diff checkpoint

运行 ReaderCore、ReaderUI、AppModel language-mode suites及 reading/diff/fold self-tests。生产 allow-list中
不出现 direct TS parser outside extractor/Reader boundary；Context/Relation/Compare继续由 session mode驱动。

### F6a：TypeScript language server provider/session

**依赖**：P0b GO；可与 F3–F5 并行开发，但不得产品放行。

**文件**：

- new `Sources/CodeInsightExact/TypeScriptLanguageServerProvider.swift`；
- `Sources/CodeInsightExact/ExactProvider.swift`；
- `Sources/CodeInsightExact/LSP.swift`（只有第三消费者真实重复时）；
- P0若证明现有direct-PID guard不能回收后代：`Sources/CProcessGuard/CProcessGuard.c`与
  `Sources/CodeInsightExact/LSP.swift`仅允许一个最小process-group/descendant lifecycle修复；
- `Tests/CodeInsightExactTests/CodeInsightExactTests.swift`。

只有 shared canonical-project helper确有第三消费者时，才把它提成 internal free function；不新增 type。
共享process lifecycle文件也只有P0先取得稳定红证据时才允许修改；否则不触碰。

**红测顺序**：GUI PATH discovery/tool identity → exact initialize options/transcript → advertised∩maximum →
TS/TSX didOpen → direct no-quiescence queries → cancel → restart once → second crash unavailable →
shutdown/force-kill/descendant reap → adversarial plugin/ATA/workspace helper。

**实现**：只新增 allow-list两个类型；复用 LSPClient/position map/request batch/sandbox/converters；provider
maximum为四项但只强制definition+references；Safe launch；外部toolchain固定；provider-local lifecycle。

**绿门**：fake transcript deterministic；P0 real probe重复PASS；non-ASCII位置；项目/cache/network/process
边界；language server与tsserver后代为零；production新增类型恰为两个。

### F6b：Exact profile/coordinator/snapshot orchestration

**依赖**：F2b、F4a、F6a。

**文件**：

- `Sources/CodeInsightExact/ExactProvider.swift`；
- `Sources/CodeInsightAppModel/ExactCoordinator.swift`；
- `Tests/CodeInsightAppModelTests/ExactCoordinatorTests.swift`；
- `Tests/CodeInsightAppModelTests/SnapshotSwitchTests.swift`。

**实现**：

- `ExactProfileKey`用§1.4 shared identity增加 TypeScript分支；feature固定default；
- `validateExactLanguage`和default provider factory只放行`.typescript`，`.javascript`继续拒绝；
- provider/profile/config/environment逐项匹配后再materialize/start；
- reuse key继续使用language/profile/config/environment/trust/tool，不加随机SnapshotID；
- publish classifier只接受`.ts/.tsx`，`.d.ts/.js` target诚实unsupported；
- Materializer/cache layout与SnapshotFactory injection API不改。

**绿门**：worktree/commit profile identity、materialized历史位置、fresh SnapshotID reuse、config/package/lock/
trust/tool miss、provider mismatch、TS/TSX target、deferred extension filter、missing provider unavailable、
JavaScript preflight；Rust/Python exact fixed vectors不变。

### C3：Exact checkpoint

运行 Exact/AppModel/SnapshotSwitch focused suites和P0 real toolchain probe。必须同时看到：冻结的negotiated set、
TS/TSX请求、deny-network/zero-write/no-plugin、cancel/restart/descendant cleanup、historical materialization；
App validator仍拒绝 TypeScript。

### F7a：session/recent/profile UI characterization

**依赖**：C1、C2、C3。

**文件**：

- `Sources/CodeInsightAppModel/AppModel.swift`；
- `Sources/CodeInsightApp/MainWindowController.swift`；
- `Tests/CodeInsightAppModelTests/SessionCodecTests.swift`；
- `Tests/CodeInsightAppModelTests/SessionRestoreTests.swift`；
- `Tests/CodeInsightAppTests/MainWindowControllerTests.swift`。

**实现**：先测试 existing scalar seams；生产文件仅在测试证明缺陷时改。Rust-only feature/edition UI判断改为
“仅 `.rust` 显示/允许”；Python/TypeScript只显示 language · unit · trust。TypeScript feature switch no-op且
generation不变。不新增 view model/type。

**绿门**：TypeScript codec round-trip、recent raw value 2、人工TS session/display与lower-layer scalar forwarding、
snapshot/compare language+TSX mode的pure/fake路径、stale completion不发布、TS profile无Cargo UI；old payload仍
Rust；Rust/Python UI原样。validator仍拒绝真实TS open，因此真实`restoreSession`、retry与compare E2E留到F7b。

### F7b：最后产品 cutover、菜单与 TypeScript self-test

**依赖**：F7a且C1/C2/C3全部green。

**文件**：

- `Sources/CodeInsightAppModel/AppModel.swift`；
- `Sources/CodeInsightApp/CodeInsightApp.swift`；
- `scripts/run-self-tests.sh`；
- `Tests/CodeInsightAppModelTests/AppModelTests.swift`；
- `Tests/CodeInsightAppTests/MainWindowControllerTests.swift`。

**顺序**：

1. 跨层 AppModel红测先在唯一 validator同步失败；
2. validator最后加入`.typescript`，`.javascript`继续拒绝；
3. `Open TypeScript Project…`复用`chooseProject(language:)`；
4. 现有 drop/empty alert加TypeScript按钮；NSAlert可直接追加按钮，不建语言选择器类型；
5. 新增唯一`--self-test-typescript <repo>` channel；
6. harness冻结位置参数兼容：3参数=14通道，第四参数只能是Python=15，第五参数必须在Python之后且为
   TypeScript=16；不支持“只传TS的第四参数”，usage与preflight具名说明，不为此重写参数解析。

**TS self-test journey**：fresh cache显式open → tree TS+TSX only/profile无Cargo → search → TSX Reader →
fuzzy relative + alias-unresolved relation → negotiated Exact → Compare HEAD~1真实hunk → snapshot HEAD~1/fullReady/Exact ready →
worktree/fullReady/Exact ready → checkpoint → hot recent/session reopen。每步结构化输出，结束
`SELF_TEST_FINISH ... exit=0`。

**绿门**：真实 open/retry/recent/restore/compare全链；unsupported lower-layer injection仍原子失败；旧菜单/⌘O不变；
汇总`pass=16 fail=0 hang=0`。

---

## §6 依赖图与 checkpoints

```text
批准计划
├─ F0 baseline
└─ P0a grammar ─┬─ F1a grammar ─ F1b identity ─ F2a extractor ─┬─ F3a resolver ─ F4a index/search ─ F4b gold
                │                                               ├─ F5a Reader ─ F5b UI/diff
                └───────────────────────────────────────────────┘

P0c corpus ────────────────────────────────────────────────────────────────┤
P0b Exact ───────────────────── F6a provider ─ F6b orchestration ───────────┤
F1b ─ F2b capture/profile ───────┴───────────────┴───────────────────────────┤

C1(F1–F4) + C2(F5) + C3(F6)
  → F7a session/recent/UI characterization
  → F7b product cutover/self-test
  → V0
```

Checkpoint commands按实际SwiftPM target名执行，最低集合：

```sh
swift test --filter CodeInsightCoreTests
swift test --filter TreeSitterKitTests
swift test --filter TypeScriptExtractorTests
swift test --filter CodeInsightGitTests
swift test --filter CodeInsightEngineTests
swift test --filter CodeInsightReaderCoreTests
swift test --filter CodeInsightExactTests
swift test --filter CodeInsightAppModelTests
swift test --filter CodeInsightAppTests
git diff --check
```

每个checkpoint同时跑对应Rust/Python characterization。单个filter PASS不替代最终完整CI。

---

## §7 V0 总验收

### §7.1 自动门禁

下列命令是计划形状；P0批准后把`L2_BASE`、corpus hashes和具名targets写入acceptance，不照抄未知值：

```sh
set -euo pipefail
L2_BASE="${L2_BASE:?set approved L2 plan/base commit}"
git rev-parse --verify "$L2_BASE^{commit}" >/dev/null
test -z "${RECORD:-}"

l2_bundle_id="dev.cairn.Cairn.l2v0.$(/bin/date -u +%Y%m%d%H%M%S)-$$"
l2_output_dir=".build/l2-distribution-$(/bin/date -u +%Y%m%d%H%M%S)-$$"
! /usr/bin/defaults read "$l2_bundle_id" >/dev/null 2>&1
test ! -e "$HOME/Library/Application Support/Cairn/$l2_bundle_id"
test ! -e "$l2_output_dir"

snapshot_corpus_state() {
  local repo="$1" path
  git -C "$repo" rev-parse HEAD
  git -C "$repo" status --porcelain=v1 --ignored=matching --untracked-files=all
  while IFS= read -r -d '' path; do
    printf '%s\0' "$path"
    shasum -a 256 "$repo/$path"
  done < <(
    git -C "$repo" ls-files -z -c -o --exclude-standard
    git -C "$repo" ls-files -z -o -i --exclude='*'
  )
}
python_before="$(snapshot_corpus_state /Users/siancao/work/ai/mcp/mcp-python-sdk | shasum -a 256)"
typescript_before="$(snapshot_corpus_state /Users/siancao/work/ai/morphic | shasum -a 256)"
test "$(git -C /Users/siancao/work/ai/morphic rev-parse HEAD)" = \
  f31fe4a9ce2d355c3a44203fcb6add9296cc9b61
test -z "$(git -C /Users/siancao/work/ai/morphic status --porcelain=v1)"
test "$(git -C /Users/siancao/work/ai/morphic ls-files '*.ts' | \
  awk '!/\.d\.ts$/{n++} END{print n+0}')" -eq 2
test "$(git -C /Users/siancao/work/ai/morphic ls-files '*.tsx' | wc -l | tr -d ' ')" -eq 51

CODEX_SANDBOX=1 bash scripts/ci.sh

selftest_non_git_dir="$(mktemp -d /private/tmp/codeinsight-l2-selftest.XXXXXX)"
l2_cache_root="$(mktemp -d /private/tmp/codeinsight-l2-cache.XXXXXX)"
zip_probe="$(mktemp -d /private/tmp/codeinsight-l2-zip.XXXXXX)"
selftest_open_file="$PWD/Tests/CodeInsightExactTests/Fixtures/exact_fixture/src/lib.rs"
trap 'rm -rf "$selftest_non_git_dir" "$l2_cache_root" "$zip_probe"' EXIT
cp "$selftest_open_file" "$selftest_non_git_dir/main.rs"

CODEINSIGHT_INDEX_CACHE_ROOT="$l2_cache_root/index" \
CODEX_SANDBOX=1 bash scripts/run-self-tests.sh \
  "$PWD" \
  "$selftest_non_git_dir" \
  "$selftest_open_file" \
  /Users/siancao/work/ai/mcp/mcp-python-sdk \
  /Users/siancao/work/ai/morphic

CODEX_SANDBOX=1 bash scripts/run-gold-gates.sh \
  --python-corpus /Users/siancao/work/ai/mcp/mcp-python-sdk \
  --python-revision f55831ee798cd4d7bafab4d50d6dba46e6fce387 \
  --typescript-corpus /Users/siancao/work/ai/morphic \
  --typescript-revision f31fe4a9ce2d355c3a44203fcb6add9296cc9b61

CODEX_SANDBOX=1 CAIRN_BUNDLE_IDENTIFIER="$l2_bundle_id" \
  CAIRN_OUTPUT_DIR="$l2_output_dir" \
  bash scripts/make-app.sh
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$l2_output_dir/Cairn.app/Contents/Info.plist")" = "$l2_bundle_id"
test -d "$l2_output_dir/Cairn.app"
test -f "$l2_output_dir/Cairn.zip"
/usr/bin/codesign --verify --strict "$l2_output_dir/Cairn.app"
/usr/bin/ditto -x -k "$l2_output_dir/Cairn.zip" "$zip_probe"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$zip_probe/Cairn.app/Contents/Info.plist")" = "$l2_bundle_id"
/usr/bin/codesign --verify --strict "$zip_probe/Cairn.app"

test "$(snapshot_corpus_state /Users/siancao/work/ai/mcp/mcp-python-sdk | shasum -a 256)" = "$python_before"
test "$(snapshot_corpus_state /Users/siancao/work/ai/morphic | shasum -a 256)" = "$typescript_before"

git diff --check
```

必须记录：

- full CI exit/test counts/fold perf；
- self-test `pass=16 fail=0 hang=0`与artifact目录；
- tokio/ripgrep原计数、Python 6 assertions unexpected=0、TypeScript unexpected=0；
- TS/TSX cold/hot extracted/reused/file counts和variant隔离；
- real provider三工具版本、definition/references和实际advertised能力、deny-network/no-write/no-plugin、
  graceful/forced descendant cleanup；
- final app/zip、Info.plist、codesign；
- 本次唯一bundle id首次启动前defaults/Application Support为空；
- 三个项目在所有gate前后HEAD/status/index/tracked hash不变；
- skip或debug binary不能记为product PASS。

`scripts/ci.sh` 的no-AppKit gate显式加入Python与TypeScript extractor targets；不建动态target列表。现有14
base + Python + TypeScript = 16个独立进程，继续保持显式`run_case`，不改成隐藏问题的for-loop。

### §7.2 final macOS bundle journey

使用同一个`$l2_output_dir/Cairn.app`与同一个唯一bundle id。记录`launchctl getenv PATH`，不得
`launchctl setenv`或富化PATH；用`open -n`按正常LaunchServices启动。

1. Rust smoke：`Open Project…`打开CodeInsight，tree/profile/Reader与rust-analyzer attribution正常；
2. Python smoke：`Open Python Project…`打开固定mcp-python-sdk，tree/profile/Reader与Pyright正常；正常Quit、
   等待app/provider进程退出、同bundle重启并验证Python session/recent恢复，然后再打开TypeScript；
3. `Open TypeScript Project…`打开固定morphic；按classifier恰有2 TS + 51 TSX，且无JS/declaration files；
4. profile显示TypeScript · tsconfig.json · trust，不出现Cargofeatures/edition；provider在bundle环境ready；
5. 打开一份`.ts`和`components/search-results-image.tsx`，验证两grammar的highlight/outline/fold/local refs；
6. content/symbol search；从P0冻结的relative call site验证fuzzy certainty，从`@/*`验证fuzzy unresolved；
7. 验证Exact definition、references和实际advertised的implementations/incoming/outgoing及provider attribution；
8. Compare选择`HEAD~1`对Working Tree/HEAD，打开`components/search-results-image.tsx`并看到`onError`hunk；
9. 主snapshot切HEAD~1，等待revision + fullReady + Exact ready；再回worktree并等待三项，language/profile/
   Reader/Exact仍TypeScript；
10. 正常Quit并等待已解析的本次bundle executable PID及其provider后代退出；同bundle重启，等待session恢复
    TypeScript fullReady + Exact ready；recent重开仍TS；
11. Rust/Python/TypeScript三个repo前后HEAD/status/index/tracked hash不变，provider descendant为零。

`open -n`后从本次bundle executable URL解析PID，不按进程名全局猜；所有等待有固定timeout并记录PID/PPID/
PGID。使用真实AppKit/AX状态与可见frame断言菜单、language alert、profile、tree、Reader和relation。新增菜单/按钮是
可见差异，保存一个代表主题的最终bundle截图；只有本阶段实际改动主题相关像素才补三主题。正常bundle
找不到任一必需provider或无法回收后代则`BLOCKED`；
不得以debug binary、临时环境变量或skip改写PASS。不得读取/清理正式`dev.cairn.Cairn`数据。
命令、AX断言、PID树与截图固定保存到`docs/plans/evidence/l2-typescript/`，不得只写口头结论。

### §7.3 结构门禁

production type审计只允许§0四项新增实体及两个DeclarationKind值。`rg`逐项解释：

- `.rust/.python/.typescript/.javascript` ownership switches；
- Rust/Python/TypeScript extractor与Reader grammar构造位置；
- RustAnalyzer/Pyright/TypeScript provider；
- `waitForQuiescence`只能RA调用；
- `typescriptreact`只在TSX Exact didOpen；
- project language默认只存在Rustcompat入口/测试/Rust-only CLI。

禁止命中：`LanguageAdapter`、registry、generic LSP runtime/session strategy、`ModuleResolver` protocol、
`TSXExtractor`、`TypeScriptHighlighter`、multi-session/profile collection、JS支持分支或future placeholder。

### §7.4 范围门禁

```sh
git diff --name-only "$L2_BASE"...HEAD
git diff --name-only
git diff --cached --name-only
git ls-files --others --exclude-standard
git diff --check
```

- `CanonicalDump.swift`、`Prototypes/`、M11/L1历史evidence、既有Rust/Pythonfixtures与gold零改；
- `Sources/CTreeSitter/`、Rust/Python grammar、`Package.resolved`零改；
- 新增只允许TS grammar/extractor/fixture/gold/evidence和计划列出的focused tests；
- `RECORD` UNSET；secret/token scan PASS；
- 不publish/tag/push；是否commit由用户单独决定。

---

## §8 风险与停止条件

| 风险 | 触发信号 | 对策 / 停止条件 |
|---|---|---|
| TS/TSX cache串键 | 同字节复用同draft/parser | full mode fixed vector + cold/hot隔离；schema不改 |
| grammar链接冲突 | 双parser同target重复符号 | P0实编；必要时两个C target，Swift仍一个extractor |
| TS动态语义冒充Strong | method/name-only跨文件Strong | method≤Possible；import≤Probable/partial；无import返回空 |
| module resolver越界 | 读取node_modules/磁盘或猜package | manifest内子集；Exact处理完整语义 |
| alias过度泛化 | 实现root alias/paths/baseUrl | fuzzy全部non-relative unresolved；Exact读取真实config |
| type-only误作runtime | `import type`产生call target | 保留flag、runtime relation unresolved |
| profile过期复用 | config/package/lock变化不miss | shared fixed fingerprint + overlay tests |
| provider选到workspace工具 | marker执行或版本source非external | canonical project外toolchain；P0 NO-GO |
| ATA/plugin执行 | 网络/marker/项目写入 | 固定initialize+Safe sandbox；任一发生STOP |
| tsserver后代泄漏 | close/crash后进程仍在 | P0必须解决并实证；未解决不写F6 |
| readiness永久等待 | 复用RA quiescence/sleep | initialize后直接request；仅provider-local有界实测策略 |
| GUI找不到provider | shell可见、bundle unavailable | 标准绝对目录fallback；bundle gate BLOCKED，不改环境偷渡 |
| historical Exact串worktree | commit位置/字节来自当前树 | materialized fixture + snapshot identity gate |
| App过早放行 | 下层仍unsupported | F7b最后修改唯一validator |
| Rust/Python回归 | fixed vector/gold/UI变化 | 回退当前片，不堆兼容抽象 |
| 抽象膨胀 | adapter/registry/config bag出现 | 删除；concrete switch已覆盖当前三个实现 |

以下任一发生即`BLOCKED`，不得宣告L2完成：

- P0任一项NO-GO；
- 单TypeScript项目仍要求multi-profile/router才能工作；
- final corpus必须执行项目代码、安装依赖或加载workspace plugin才能通过；
- Rust/Python完整CI、既有gold或旧self-tests出现稳定回归；
- normal LaunchServices final bundle无法发现provider、完成commit→worktree→restore，或退出后有后代进程；
- 受保护路径发生越权修改。

---

## §9 开工清单

- [ ] 用户批准本计划的`.ts + .tsx`、deferred extensions、external community language server边界。
- [ ] 计划若commit，记录实际`L2_BASE` full SHA；不照抄草拟基线。
- [ ] F0实时CI exit 0，受保护objects与Rust/Python计数已冻结。
- [ ] P0a grammar来源/hash/license/ABI/target布局 GO。
- [ ] P0b pinned external toolchain、禁网/零写/no-plugin、definition+references、advertised能力与descendant cleanup GO。
- [ ] P0c morphic revision/count/hash/具名验收symbols GO。
- [ ] 正常GUI环境可发现rust-analyzer、Pyright和TypeScript provider；缺任一可开发lower slices，
      但不得越过对应C3/F7b/V0。
- [ ] 每个新增production type都能对应§0 allow-list；否则删除。
- [ ] 每片先有能在修前失败的focused test，再改production。
- [ ] 任一checkpoint失败时保持App TypeScript unsupported，不以部分功能改写完成标准。
