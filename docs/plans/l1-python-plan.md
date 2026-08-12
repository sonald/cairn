# L1 实施计划 v1：Python 单语言项目 vertical slice

> 状态：P0 可行性 **GO**；本计划可执行，但尚未授权修改生产代码。
> 架构基线：`0add42056b8f8dfd618d82371b211072c2f90899`。
> P0 证据：`docs/plans/evidence/l1-python/p0-feasibility.md`。
> 本计划延续 M12 的单活动语言模型；混合项目仍属于 L3，不在本里程碑预留容器。

---

## §0 结论先行

L1 可行。最小正确实现不是“给现有 Rust 路径换一个 parser”，而是在 M12 已有 switch 中补齐
一条 Python vertical slice：

```text
显式 Python 打开
  -> .py capture + Python AnalysisProfile
    -> PythonExtractor + cache
      -> Python module/import fuzzy resolution + search/relations
        -> Python Reader/outline/fold/local refs + diff
          -> Pyright definition/references/call hierarchy
            -> recent/session/history/真实 .app E2E
```

只要任一层未通过，`AppModel.validateProductSupport(.python)` 就继续拒绝 Python。不得先开放文件树，
再用空 Reader、空 relation 或“Exact unavailable”冒充整语言支持。

L1 新增的必要生产实体严格限于：

1. `PythonExtractor`：第二个真实 `LanguageExtractor`；
2. `PyrightProvider`：第二个真实 `ExactProvider`；
3. `PyrightSession`：处理 Pyright 与 rust-analyzer 已实测不同的 readiness/lifecycle；
4. `CTreeSitterPython` SwiftPM C target：承载 vendored Python grammar。

Reader 的 Python walk 用 module-internal/private 函数，不新增 public `PythonHighlighter`；profile、module、
recent、capability 不新增 adapter/protocol/registry/config bag。完成 L1 后再依据两个真实实现的重复度
复审，当前不抽通用 language-server runtime。

---

## §1 冻结产品决策

### §1.1 文件与编码

- 只支持小写 `.py`。
- `LanguageMode` 固定为 `LanguageMode(language: .python, variant: nil)`。
- `.pyi`、`.pyw`、`.ipynb`、大写扩展名、二进制 extension module 均 unsupported。
- 只接受有效 UTF-8；PEP 263 的非 UTF-8 源码编码另立切片。
- 一个打开态只有 Python 一个 `AnalysisProfile` / `EngineSession` / `ExactSession`。
- Python 项目中的 `.rs/.ts/.js` 不进入 tree、index、Reader、search 或 relation。

### §1.2 语言选择

- 不按文件数量、root marker、`pyproject.toml` 或 Git 内容猜语言。
- 现有 `openProject(root:)` 与 `Open Project…` 保持 Rust compatibility。
- 新增 `Open Python Project…`，显式调用现有 `openProject(root:language:)`。
- recent、retry、session restore 必须保存/恢复 Python；旧 recent/session 数据仍迁移为 Rust。
- drag/drop 或其他没有语言身份的目录入口必须让用户选 Rust/Python；不得静默看 marker。

### §1.3 Pyright 分发

- L1 采用用户本机已安装的官方 Pyright，和 rust-analyzer 一样由 Cairn 发现，不由 Cairn 安装。
- 查找 `pyright-langserver`，并要求同目录存在 companion `pyright` 用于版本读取。
- GUI bundle不能依赖交互 shell `PATH`。两个 Exact provider复用一个 internal candidate函数：
  sanitized absolute `PATH` entries，再检查 `/opt/homebrew/bin`、`/usr/local/bin`；不建 resolver type。
- 缺少 Pyright 只把 Exact 标为 unavailable；fuzzy/Reader 的 Python 项目仍可打开。
- 不 bundle Node/Pyright，不增加 updater、签名、许可清单或安装 UI；零安装分发另立里程碑。
- 官方安装依据：[Pyright installation](https://github.com/microsoft/pyright/blob/main/docs/installation.md)。

### §1.4 配置与环境 identity

Python `AnalysisProfile` 继续使用现有字段：

- `language = .python`；
- `projectRoot` 继续是活动 session 的 root `PathID`；
- `projectUnitName = project root lastPathComponent`；
- config：根 `pyrightconfig.json` 优先，否则根 `pyproject.toml`；
- `configFingerprint` 对“选择的相对文件名 + NUL + 完整字节”做 SHA-256；无文件使用下述固定
  nonempty sentinel hash；
- `environmentFingerprint` 对根 `uv.lock` 的“文件名 + NUL + 完整字节”做 SHA-256；无文件为空；
- `featureSelection = .defaultFeatures`、`featureNames = []`、`edition = nil`、初始 trust safe。

无 config不能使用空 `configFingerprint`：现有 `Materializer.safeComponent`拒绝空路径组件。固定对
`python-config\0<none>`做 SHA-256，结果固定为
`ad63780a0cbd089b3305c2cf137e6b6bf21da9bd79e5c110172db574a847be12`，保持
Materializer/layout零改；`environmentFingerprint`无 `uv.lock`时仍为空。全文件 fingerprint
可能因与 Pyright 无关的 `pyproject.toml` 变化多做一次重建，但不会错误复用；
这是首片接受的保守成本。当前真实验收项目使用 `[tool.pyright]` 和 `uv.lock`，其他 lock manager
等出现真实 corpus 再增加，不现在猜完整 Python 包管理生态。

ProfileDetector与ExactProfileKey必须调用同一个 package free function（read-bytes closure入、两个
fingerprint tuple出）；这是两个真实消费者的单一identity实现，不新增 profile/config type。

Pyright 官方规定 `pyrightconfig.json` 优先于 `[tool.pyright]`；配置还可影响 include/exclude、venv、
extra paths、Python 版本/platform 和 execution environments。L1 Exact 交给 Pyright解释；fuzzy 只实现
本计划冻结的 module roots。来源：
[Pyright configuration](https://github.com/microsoft/pyright/blob/main/docs/configuration.md)。

### §1.5 trust 与项目副作用

- Python 不安装依赖、不创建 venv、不运行 package manager。
- Safe/Trusted 两个请求模式都用现有 Safe sandbox 启动 Pyright：项目只读、私有 cache/tmp 可写、
  network denied。
- 该 Safe profile保护项目完整性、网络和写入范围，不是 host confidentiality boundary：现有
  `file-read*`/`process*`仍允许 Pyright及配置引用读取项目外可读文件，UI和验收不得称其为秘密隔离。
- 请求的 trust mode 仍进入 attribution 和 overlay key；Python 不获得 Rust 的 `target/` 写权限。
- 不向 Pyright发送项目 interpreter path。
- 启动环境清理 project-relative/empty `PATH` entry，清空 `PYTHONPATH/PYTHONHOME/PYTHONSTARTUP`、
  `VIRTUAL_ENV/CONDA_PREFIX`、`NODE_PATH/NODE_OPTIONS`，设置 `PYTHONNOUSERSITE=1`、
  `PYTHONDONTWRITEBYTECODE=1`、`PYTHONSAFEPATH=1`。
- V0 前把假 `python3/python/node/pyright-langserver/pyright` marker分别放入 project内的空、相对、
  绝对与 symlink-alias `PATH` entry，证明 discovery和child launch都排除 canonical project路径；
  `.venv/bin/python`只作补充，不得单独充当证明。任一 marker执行则 Exact保持off。

---

## §2 成功合同

### §2.1 完整产品合同

Python 只有同时满足以下行为才算交付：

1. 显式打开真实 Python Git 项目，文件树只包含 `.py`。
2. worktree 和 commit snapshot 都产生 Python profile/session，切 commit 再回 worktree 不丢语言。
3. content/symbol search、Reader、outline、fold、local references、fuzzy context/relations、diff 可用。
4. Pyright 提供 definition、references、incoming/outgoing calls；缺失 provider 诚实 unavailable。
5. implementations 显示 unsupported，而不是空结果或失败。
6. Python Exact始终显示 existing `dependenciesUnavailableOffline` limitation，不显示依赖完全覆盖；
   该状态不依赖可被配置关闭的 diagnostics。
7. session restore、recent、retry 仍按 Python 打开。
8. Rust product journey、cache identity、测试、自检和 gold 零行为回归。

### §2.2 fuzzy 语义合同

`DeclarationKind` 保留 Rust raw values `0...10`，只在末尾追加：

```text
11 pythonFunction
12 pythonClass
```

不新增 `pythonMethod`：类体直属函数仍是 `pythonFunction`，由
`parentFacetIndex -> pythonClass` 表达 method identity。Python function/class 都处于运行时
`.value` space；type-like UI 来自 declaration kind，不制造第二命名空间。

Extractor 首片保证：

- `def` / `async def` / decorated function；顶层、嵌套和 class method；
- class declaration；
- `parentFacetIndex`总是最近 enclosing declaration；只有直接 parent是 `pythonClass` 的 function才是
  method，嵌套 `C.m.inner` 中只有 `m` 是 method；
- module/class/function/lambda scope；
- parameter 与简单 `identifier = rhs` binding，binding 在 RHS 之后激活；
- module initializer、class body、function/method executable region；
- function/method executable region只覆盖 body block；decorator和default-argument call归属外层
  module/class region，不冒充函数 body call；
- `f()` direct call、`obj.m()` method call、class constructor call；
- named import、alias、relative named import、module import record、wildcard record；
- identifier range 不命中 string/comment；
- syntax-error tree 保留 partial index 并设置 `containsErrorNodes`。

确定性上限：

- same-file unique declaration 与 unique named import可为 Strong fuzzy；永远不是 Exact；
- Python `obj.m()` 只按同名 class member给 Possible + dynamic dispatch；
- 外层 computed callee（如 `(factory())()`）不生成 call；其中具名的内层 call仍正常记录；
- module-object member、external module、ambiguous module unresolved，不用全局同名冒充
  possible/strong。

明确 deferred：

- variable/property/type-alias declaration facet；
- use-before-assignment 的 Python compile-time locality；
- destructuring/comprehension/for/with/except binding；
- `global` / `nonlocal`；
- decorator/default-argument 作为函数内 call；
- callback/function-value inference；
- monkey patch、descriptor 和精确 receiver type；
- star import、`__all__`、re-export；
- `import pkg.mod as m; m.f()` 与 `from pkg import mod` module-object navigation；
- namespace package、editable install、site-packages、ambient `PYTHONPATH`；
- NFKC 等价 identifier 合并。

这些是公开的精度边界，不是 known-failure 豁免。Gold 中对应 case 必须是 `nostrong` 或
`unresolved`，不能写成伪成功。

### §2.3 module roots

Python module map继续使用现有 `ModuleMap`，不建 protocol。活动 manifest 的候选 import roots 只含：

1. project root；
2. conventional `src/`，仅当 manifest 中真实存在 `src/**/*.py`。

`ImportBinding.moduleSpecifier` 保存 Python source-spelled dotted name；relative import保留 leading
dots，例如 `.models`、`..shared.util`。`from pkg.mod import f as x` 保存 imported `f`、local `x`；
`import pkg.mod as m` 只保存 module binding，L1不承诺 `m.f()` navigation。

映射：

```text
pkg/mod.py            -> pkg.mod
pkg/mod/__init__.py   -> pkg.mod
pkg/__init__.py       -> pkg
src/pkg/mod.py        -> pkg.mod
src/pkg/__init__.py   -> pkg
main.py               -> main
```

除 module leaf外，每个 package目录段必须有 `__init__.py`；否则属于 deferred namespace package并
unresolved。一个点表示当前 package，每多一个点上移一级。`src/` 启用时，其子文件只按 `src`相对
路径建立 identity，不再同时生成 `src.pkg.*`。只接受 snapshot 中唯一真实 target；同一 module同时
命中 `mod.py` 与 `mod/__init__.py`、或 root/src 两处冲突时 unresolved。relative import使用 source
文件所属的唯一 root context。`src/` 是当前真实 acceptance corpus 的具体需求，不扩展到任意
`packages/*/src` 或配置化 search-path router。

### §2.4 Reader/Diff 合同

- `ReaderDocument.languageMode` 已存在，不新增重复 language 字段。
- 只给 `OutlineKind` 追加 `.class`；function 复用 `.fn`，class 直属 function 复用 `.method`。
- syntax highlight：keyword、comment/commentFigure、whole string、number/boolean/None、function/class name。
- f-string interpolation 不单独分色。
- fold：function/method declaration、class container、if/elif/else、for、while、try/except/finally、
  with、match/case block，以及连续 imports/comments。
- Python block 使用实际 indentation body range，不走 Rust brace trim。
- Reader syntax 只 parse 一次，同一 `Tree` 传给 `PythonExtractor.localReferences`。
- regular/large/huge 的 tier 和异步 identity/generation 行为保持现状。
- line diff直接放行 Python；function diff只筛 `pythonFunction`，name chain按parent facets显示
  `Class.method`或`Class.method.inner`。
- 不给 `FunctionChange` 增加 language 字段；separator 从 existing declaration kind 推导。

### §2.5 Exact capability 合同

Pyright `1.1.411` 实测协商：

```text
definition       yes
references       yes
call hierarchy   yes
implementations  no
serverInfo       absent
```

`PyrightSession`：

- `didOpen.languageId = "python"`；
- initialize 后直接 request，不调用 `waitForQuiescence`；
- 不复制 rust-analyzer 的 `-32801 content modified` retry；
- provider supported maximum固定为 definition/references/call hierarchy；session negotiated capability为
  “initialize advertised ∩ provider supported”，即使未来server声明 implementation，L1也不会自动放行；
- version 来自同目录 `pyright --version`；
- 同一 sanitized child `PATH`按 `python3`、`python`顺序解析首个可执行解释器；把其 canonical path
  和 `--version`结果（或明确的 unavailable sentinel）拼入现有 `toolVersion`，使解释器变化直接
  触发 overlay reuse miss，不新增 identity字段或类型；
- batch cancel 复用 `$/cancelRequest`；
- crash provider-local restart一次，第二次 unavailable；
- close 复用 `shutdown -> exit -> grace -> kill/reap`；
- base `ExactAnalysisEnvironment.limitations`始终包含现有 `.dependenciesUnavailableOffline`；不接入
  `publishDiagnostics`，因为项目可把 `reportMissingImports`配置为 `none`，通知不能作为完整性门禁。

Location/LocationLink/call hierarchy JSON conversion只有在 Rust/Python 两边都消费时，才挪成
`LSP.swift` internal free functions；不新增 codec、adapter 或 public injection API。

### §2.6 失败诚实与 Rust 回归

- TypeScript/JavaScript 仍在 Git traversal、cache write、Exact process 之前 unsupported。
- Python底层任何 identity mismatch 不发布 ready session。
- Pyright缺失不使 Python indexing failed；只使 Exact unavailable。
- `.pyi` Exact target不进入 overlay/navigation；dependency `.py` 仍可只读展示。
- unsupported configuration/capability不回退 Rust parser/provider。
- Rust convenience、fixed cache vector、Cargo profile、RA readiness、Reader output和gold保持不变。

---

## §3 明确不做

- mixed-language workspace、path-to-profile router、多 Engine/Exact session collection；
- `LanguageAdapter`、registry、plugin、capability map、provider registry；
- 通用 `LSPProvider` / `LSPExactSession` 重构；
- Python-specific profile type或 config object model；
- TOML dependency、package manager、venv manager、interpreter selector；
- `.pyi` / typeshed Reader支持；
- 全 CLI 多语言化；只允许 `goldset` 获得 Python 评估参数；
- 为 TypeScript/JavaScript 预加分支、test、type、placeholder；
- 重录 CanonicalDump、Rust fixture或已有 Rust gold；
- bundling/updating Pyright；
- 为 deferred fuzzy语义加空接口或 TODO-only field。

---

## §4 实施切片

每片遵守：先最小红测，后生产修改；片末定向 green、`git diff --check`、新增类型审计、受保护路径
审计。单片尽量 1–5 个手工文件；vendored grammar目录是唯一生成物例外。除非用户另行要求，
实施过程不 commit、不 push。

### F0：冻结实时实施基线

**目标**：在第一处生产修改前证明当前 checkout，而不是复用 P0 或 M12 历史 green。

**动作**：

1. 若本计划被单独提交，记录该提交为 `L1_BASE`；同时保留架构父基线 `0add420...`。
2. 记录 branch、ahead/behind、worktree/index/untracked、`RECORD`。
3. 运行 `CODEX_SANDBOX=1 bash scripts/ci.sh`，记录退出码、测试数、自检和 fold perf。
4. 重跑 M12 的 Rust cache/profile/Reader/Diff/Exact fixed characterization。
5. 重核 P0 evidence §2 的受保护 child Git objects；记录本里程碑新增文件 allow-list。
6. 记录本机 Pyright/Node版本与真实 corpus SHA；工具缺失不阻止 fuzzy实现，但阻止 Exact/V0。

**文件**：新建 `docs/plans/evidence/l1-python/l1-acceptance.md`；不改生产代码。

**完成条件**：实时 baseline PASS。稳定功能失败先诊断；不能拿今天较早的 M12 记录冒充。

### F1a：vendored Python grammar 与 field lookup

**依赖**：F0。

**手工文件**：

- `scripts/vendor-treesitter.sh`
- `Package.swift`
- `Sources/TreeSitterKit/TreeSitterKit.swift`
- `Tests/TreeSitterKitTests/TreeSitterKitTests.swift`
- generated `Sources/CTreeSitterPython/**`

**红测**：导入 Python C target并用 named field找 `function_definition` 的 `name/parameters/body`；
修前 target/API 不存在而编译失败。

**实现**：

- runtime保持 `v0.25.8`；
- Python grammar固定 official `v0.25.0`、commit `293fdc0`；
- 下载 release complete-source asset，记录 SHA-256和MIT license；
- 给现有脚本增加 `--python-only` scoped invocation；该模式不得下载、删除或写入
  `Sources/CTreeSitter/`、`Sources/CTreeSitterRust/`，legacy无参行为保持不变；
- vendored `parser.c/scanner.c/node-types.json`及所需headers；
- 生成 `tree_sitter_python.h`；
- 给现有 `Node` 增加最小 package `child(namedField:)` C API wrapper；不扩大 public API，不建
  query abstraction；
- Package只增加 internal C target和必要 target dependencies，不新增外部 SwiftPM dependency，
  不增加 public library product。

**绿门**：ABI 15 parser可构造；`module` root、def/class/import fixture无 error；损坏输入有 error；
field lookup准确；现有 Rust parser tests逐项不变；`--python-only` 前后 Rust/runtime Git object与文件
hash逐项相等。

### F1b：Python core identity

**依赖**：F1a。

**文件**：

- `Sources/CodeInsightCore/ContentIndex.swift`
- `Tests/CodeInsightCoreTests/CoreBehaviorTests.swift`

**红测**：`.py` classifier当前为 nil，Python declaration raw value不存在。

**实现**：

- `.python` 只接受 path extension `py`；
- `.pyi/.pyw/.PY`均 nil；
- 追加 `pythonFunction=11`、`pythonClass=12`；
- 不改现有 raw values、`LanguageMode`、cache schema或codec framing。

**绿门**：classifier矩阵、raw fixed vector、Codable round-trip、same-content Rust/Python key隔离；
现有 Rust cache canonical vector逐字不变。

### F2a：`PythonExtractor` 最小完整 index

**依赖**：F1a、F1b。

**文件**：

- new `Sources/CodeInsightPythonExtractor/PythonExtractor.swift`
- new `Tests/PythonExtractorTests/PythonExtractorTests.swift`
- `Package.swift`

**实现形状**：

- 一个 production struct；`grammarVersion=1`、`extractorVersion=1`作为其 static constants；
- `PythonExtractorTests`只依赖实际 import 的 `CodeInsightCore` 与
  `CodeInsightPythonExtractor`；不增加 public library product；
- declarations/scopes/calls/imports先用同文件 private function/tuple；只有实际复杂度证明需要时才拆；
- 使用 named fields，不依赖 child index；
- decorated/async wrapper的range/signature包含完整声明；body fingerprint只覆盖 block；
- declaration parent指向最近 enclosing declaration；直接 class child才是 method；
- function lexical parent跳过 class scope，符合 Python method lookup边界；
- simple assignment在 RHS后激活；
- import不重复生成 lexical `BindingRecord.importBinding`，避免抢过现有 `ImportBinding` resolution；
- outer computed call不建记录；module import receiver供 Resolver识别后直接 unresolved；
- error tree仍返回 partial index。

**红/绿 fixture**：inline bytes覆盖 decorated/async/nested/class/lambda、parameter、assignment、
shadowing、direct/method/inner-computed call、absolute/relative/alias/wildcard import、Unicode byte range、
string/comment exclusion和syntax error。

**完成条件**：ContentIndex每个字段精确断言；两次提取逐字段稳定；传入 key原样返回；
wrong language/mode失败；不出现 builder class、adapter或 `PythonExtractorInfo`。

### F2b：五文件真实 package fixture

**依赖**：F2a。

新增 `Tests/PythonExtractorTests/Fixtures/basic_package/`，并在 `Package.swift` 的新 test target加入
`exclude: ["Fixtures"]`：

1. `pyproject.toml`
2. `sample/__init__.py`
3. `sample/models.py`
4. `sample/service.py`
5. `main.py`

覆盖 class、method、factory function、simple local、absolute/relative named alias import、direct call、
method call。syntax-error/decorated/async/diff继续用 inline bytes，不继续增加 fixture文件。

### F3a：Python worktree capture 与 profile

**依赖**：F1b。

**文件**：

- `Sources/CodeInsightGit/GitSnapshot.swift`
- `Sources/CodeInsightCore/QueryContext.swift`
- `Sources/CodeInsightEngine/ProfileDetector.swift`
- `Tests/CodeInsightGitTests/GitSnapshotTests.swift`
- `Tests/CodeInsightEngineTests/ProfileDetectorTests.swift`

**红测**：Python worktree在遍历前 unsupported；profile只产生 Rust/Cargo identity。

**实现**：

- `WorktreeSnapshot` Python分支只捕获 `.py`；继续跳过 `.git/.venv/venv/__pycache__/build/dist`；
- config只捕获根 `pyrightconfig.json`、`pyproject.toml`、`uv.lock`；不递归抓所有pyproject；
- TypeScript/JavaScript仍在遍历前拒绝；
- `ProfileDetector`增加显式 language入口并在 private switch中构造 Rust/Python profile；现有无
  language签名继续作为 Rust convenience；
- Python按 §1.4 的 shared package free function计算 deterministic identity；不加 Python profile
  type/TOML parser。

**绿门**：worktree manifest只含 `.py`；config可 read但不出现在 source list；worktree/commit
相同字节得到相同 profile fixed vector；config/uv变化分别改变正确 fingerprint；无配置 fallback稳定；
无 config的 Python fingerprint固定且非空；Rust manifest/profile逐项等价；unsupported无 Git/cache I/O。

### F3b：Python module map 与 fuzzy resolver

**依赖**：F2a、F2b。

**文件**：

- `Sources/CodeInsightEngine/ModuleMap.swift`
- `Sources/CodeInsightEngine/Resolver.swift`
- `Sources/CodeInsightEngine/EngineSession.swift`
- `Tests/CodeInsightEngineTests/CodeInsightEngineTests.swift`

**红测**：人工 Python `SnapshotView` 在 `ModuleMap` precondition中终止；method fallback只筛 Rust。

**实现**：

- `ModuleMap` 保存现有 language，initializer/`targetFile`内部 exhaustive switch；
- Rust branch逐字保持；
- Python用root/src canonical module string到唯一 `PathID`的private map；`moduleChildren`可为空；
- 每个package段验证 `__init__.py`；src path只产生src-relative identity；
- absolute/relative named import按 §2.3解析；冲突/namespace/external/module-object返回 nil；
- Resolver的Rust receiver/impl路径只对Rust运行；
- Python method-call只筛 parent为class的同名 `pythonFunction`，certainty封顶Possible；
- receiver命中 module import时直接 unresolved，不进入全局 method-name fallback；
- `EngineSession.kindWeight`只追加 Python function/class对应现有 function/class权重；relation/impl仍
  Rust-only；
- same-file/class constructor/named import复用现有 candidate/evidence/sort；不新增 resolution protocol。

**绿门**：absolute/relative alias strong、constructor strong、method possible、module-object/namespace/
module conflict/external unresolved、缺 `__init__.py` unresolved、src-relative import、root/src唯一命中、
`C.m.inner` parent/method边界、foreign `.rs`隔离、callers/outgoing正确；Rust same-content foreign-path
regression继续通过。

### C1：parser / profile / fuzzy checkpoint

运行 Core、Git、PythonExtractor、Engine targets。审计：

- production新增 Swift type只能看到 `PythonExtractor`；
- cache schema无变化；
- CanonicalDump和Rust fixtures无 diff；
- `.pyi`在 classifier/manifest/view均不存在；
- 当前 App显式 Python仍同步 unsupported。

### F4a：ProjectIndexer、cache、search、tree

**依赖**：F2a、F3a、F3b。

**文件**：

- `Sources/CodeInsightEngine/ProjectIndexer.swift`
- `Package.swift`
- `Tests/CodeInsightEngineTests/CodeInsightEngineTests.swift`
- `Tests/CodeInsightEngineTests/SnapshotIndexerTests.swift`
- `Tests/CodeInsightEngineTests/SnapshotSearchTests.swift`

**红测**：extractor/profile switch仍拒绝 Python。

**实现**：

- Engine target依赖 `CodeInsightPythonExtractor`；
- `languageExtractor(.python)`返回 `PythonExtractor`；
- profile分支调用已实现 detector；
- 其余 prepare/complete/view/search/coverage继续走 M12现有 language/extractor identity；
- 不给 ProjectIndexer加第二份 Python pipeline。

**绿门**：fixture file/symbol/call/import counts、reference search identifier exclusion、FileTree/coverage、
same-content跨语言隔离；persistent cold run `extracted == uniqueContentCount`，第二次
`reused == uniqueContentCount && extracted == 0`；grammar/extractor version变化仅 miss Python entry；
Rust hot cache不重建。

### F4b：Python gold gate

**依赖**：F4a。

**文件**：

- `Sources/CodeInsightEngine/GoldSet.swift`
- `Sources/CodeInsightCLI/CodeInsightCLI.swift`
- `scripts/run-gold-gates.sh`
- new `goldset/mcp-python-sdk.gold`

**实现**：

- `evaluateGoldSet`增加显式 language，默认仍 Rust；
- 只给 `goldset`命令加 `--language python`，不迁移其他 Rust-only CLI；
- Python corpus gate接收显式路径/SHA，并要求 `HEAD == f55831ee798cd4d7bafab4d50d6dba46e6fce387`、
  `git status --porcelain`为空、tracked `.py == 204`、根 `pyproject.toml`与`uv.lock`存在；gate
  前后重核 HEAD/status/tracked hashes；现有无 Python参数行为不变；
- gold覆盖 same-file、absolute/relative alias、constructor、local bind、method nostrong、
  module-object unresolved；每个 known-failure必须有真实动态语义理由。

**绿门**：Python unexpected failure 0；Rust tokio/ripgrep总数和结果不变；脚本无 Python corpus时仍按
旧接口只跑两套 Rust gold；V0显式传入固定 mcp corpus并同时跑三套。

### F5a：Python Reader syntax / outline / fold / local refs

**依赖**：F2a。

**文件**：

- new `Sources/CodeInsightReaderCore/PythonReaderSyntax.swift`（只放 module-internal/private函数）
- `Sources/CodeInsightReaderCore/CodeInsightReaderCore.swift`
- `Sources/CodeInsightReaderCore/Folding.swift`
- `Package.swift`
- `Tests/CodeInsightReaderCoreTests/ReaderCoreTests.swift`

**红测**：DocumentLoader Python明确抛 unsupported。

**实现**：

- ReaderCore依赖 Python extractor/C grammar；
- loader/loadSyntax按 mode switch；Rust path不动；
- Python一次 parse完成span/outline/fold并把同一 tree交给 extractor local refs；
- 保留 public `RustHighlighterError` compatibility，不为 Python再造 Reader error type；
- `OutlineKind.class`追加在末尾；
- Fold accumulator按 language调用Rust braced或Python indented candidate；共用laminar resolve；
- `ReaderDocument.identifierOccurrences`按活动语言排除keyword；不继续写Rust规则。

**绿门**：byte geometry、decorated/async无重复outline、class/method depth、fold summary、local shadowing、
string/comment exclusion、regular/large/huge、async stale mode completion；DEBUG parse observer证明一次 parse；
Rust highlight/outline/fold fixture逐字不变。

### F5b：Reader UI 与 Python class呈现

**依赖**：F5a。

**文件**：

- `Sources/CodeInsightReaderUI/CodeInsightReaderUI.swift`
- `Sources/CodeInsightApp/MainWindowController.swift`
- `Sources/CodeInsightApp/PalettePanel.swift`
- `Tests/CodeInsightReaderCoreTests/ReaderUITests.swift`
- `Tests/CodeInsightAppTests/PaletteTests.swift`

补齐所有 `OutlineKind.class` exhaustive switch：structure group、gutter marker、颜色、symbol image、
palette order、fold member summary。Python尚未产品放行，通过人工 `ReaderDocument(.python)` 驱动。

**绿门**：class在outline/palette/gutter/fold summary可见，frame/selection正确；三主题无需新视觉设计，
若实际像素变化则补真实AppKit截图；已知 M11 fold recorded issue不得扩大。

### F5c：Python line/function diff

**依赖**：F2a、F5a。

**文件**：

- `Sources/CodeInsightReaderCore/DiffCore.swift`
- `Tests/CodeInsightReaderCoreTests/DiffCoreTests.swift`

**实现**：line diff允许 Python；function extraction按 mode选择现有 extractor；Python只筛
`pythonFunction`；display name用 Python `.`；不加 adapter或language字段。

**绿门**：signature/body changed、added/removed、class method `Class.method`、nested
`Class.method.inner`、line truncation；
Rust `::`和existing fixture不变；CompareModel stale language/generation测试继续通过。

### C2：Reader/Diff checkpoint

运行 ReaderCore、ReaderUI、AppModel language-mode focused suites和 reading/diff/fold self-tests。
结构审计只允许 Python grammar/extractor boundary直接写 Python parser；Context/Relation/Compare继续由
session `LanguageMode`驱动，不能回退默认Rust。

### F6a：Pyright provider/session

**依赖**：F0；可与 F3–F5并行开发，但不得产品放行。

**文件**：

- new `Sources/CodeInsightExact/PyrightProvider.swift`
- `Sources/CodeInsightExact/ExactProvider.swift`
- `Sources/CodeInsightExact/LSP.swift`
- `Sources/CodeInsightExact/RustAnalyzerProvider.swift`
- `Tests/CodeInsightExactTests/CodeInsightExactTests.swift`

**红测顺序**：

1. shell与empty-GUI-PATH provider discovery/version；
2. initialize没有 `serverInfo`；
3. no-quiescence definition；
4. references/call hierarchy；
5. implementations capability absent；
6. fake未来server声明 implementation仍被 provider supported maximum过滤；
7. 默认配置与 `reportMissingImports = "none"` 都保留 offline limitation；
8. batch cancel/no-response/new request；
9. crash/restart once/second crash unavailable；
10. graceful close与force-kill/reap；
11. fake project `PATH`中的 `python3/python/node/server/CLI` marker均不执行；`.venv` marker仅补充。

**实现**：新增 `PyrightProvider`、`PyrightSession`；复用 `LSPClient/LSPPositionMap/ExactRequestBatch/
Sandbox`；纯 JSON converter转 internal free functions；启动 `pyright-langserver --stdio`；companion
CLI Safe版本读取；同一 sanitized `PATH`解析解释器并把 canonical path/version合入现有
`toolVersion`；两种 trust请求都使用 Safe launch；环境按 §1.5清理；base environment直接携带现有
offline limitation。把现有 PATH scan提成两个 provider共用的 internal free function，加入标准绝对目录并
canonical-project排除；不建 executable resolver type。不要改 `RustAnalyzerSession` readiness算法来
塞 strategy closure。

**绿门**：fake protocol transcript逐帧断言；empty `PATH`候选包含两处标准目录；P0 real
deny-network fixture重复通过；non-ASCII位置映射；canonical project/alias `PATH` marker全未执行；
项目hash不变、允许目录之外零写；解释器canonical path/version变化导致reuse miss；production新增类型
恰为两个。

### F6b：Exact profile/coordinator/snapshot orchestration

**依赖**：F3a、F4a、F6a。

**文件**：

- `Sources/CodeInsightExact/ExactProvider.swift`
- `Sources/CodeInsightAppModel/ExactCoordinator.swift`
- `Sources/CodeInsightAppModel/AppModel.swift`
- `Tests/CodeInsightAppModelTests/ExactCoordinatorTests.swift`

**实现**：

- `validateExactLanguage`允许 Python；
- default provider factory Python分支发现/构造 Pyright；无 registry；
- 保留 public两参数 `SnapshotFactory(root, revision)` compatibility和现有注入调用；stored legacy
  override改为 optional，nil时Coordinator默认路径直接使用 captured language构造
  `WorktreeSnapshot(root, language)`，commit仍复用完整Git；传入旧closure时行为不变，不新增三参数
  public typealias或 injection API；
- Rust `ExactProfileKey`仍重读 Cargo/lock；现有 `ExactProfileKey(projectURL/snapshot, language:)`增加
  Python分支，通过同一 package free function从实际root/snapshot重算 config/uv fingerprint，再与
  传入 `AnalysisProfile`逐项比较；mismatch在materialize/provider前失败，不新增 profile type；
- Python feature固定default；
- overlay reuse继续用 language/profile/config/environment/trust/tool且不加随机 SnapshotID；Python
  provider的现有tool identity已包含解释器canonical path/version；
- definition/relation publish用 active language classifier过滤 `.pyi`和其他unsupported target；
- missing Pyright发布 Exact unavailable，不回滚 ready EngineSession；
- Materializer和cache layout不改。

**绿门**：worktree/commit profile identity、materialized历史定义、fresh SnapshotID reuse、
config/uv/trust/tool/interpreter miss、无 config的Python历史snapshot仍可materialize、
provider/profile mismatch、`.pyi` filter、dependency
`.py`只读、unsupported implementation、missing provider状态；Rust Cargo/lock/materializer fixed vector不变。

### C3：Exact checkpoint

运行 Exact/AppModel focused suites和真实 Pyright deny-network probe。必须同时看到：

- definition 1、references 2、incoming 1、outgoing 3；
- implementation unsupported；
- 默认配置与关闭 `reportMissingImports` 时均有 offline limitation；
- fake server的cancel/restart/force-kill/reap deterministic tests green；
- real Pyright的capability/offline navigation/graceful shutdown green；
- installed Pyright adversarial project `PATH` markers全部未执行；
- Safe/Trusted项目hash不变；
- App product validator仍拒绝 Python。

### F7a：recent/retry 与 explicit MainWindow入口

**依赖**：C1、C2、C3。

**文件**：

- `Sources/CodeInsightAppModel/RecentProjectsStore.swift`
- `Sources/CodeInsightApp/MainWindowController.swift`
- `Tests/CodeInsightAppModelTests/RecentProjectsStoreTests.swift`
- new `Tests/CodeInsightAppTests/MainWindowControllerTests.swift`

**实现**：

- 不新建 `RecentProject` type；保留paths数组，增加path到 `LanguageID.rawValue`的平行UserDefaults map；
- 旧path没有map entry时为Rust；invalid raw value也回Rust兼容；
- `record(url,language)`，旧 `record(url)`保持Rust convenience；
- record按8条paths同步裁剪orphan map entry，clear同时删除两把key；
- MainWindow显式 `openProject(root:language:)`，旧方法委托Rust；
- `lastOpened/pendingRecent/retry`同时保存一个language scalar；
- restore只从 `SessionCodec.Snapshot.language`恢复；recent click按path向store查language；drop在F7c
  使用独立callback，不能与recent click共用一个默认Rust URL callback；不给tab/excerpt重复加字段。

**绿门**：旧recent迁移、Rust/Python同path覆盖、顺序/上限/clear、language forwarding、纯 retry/recent/
restore identity helper测试和 Rust→Python旧completion不发布；validator仍拒绝 Python，所以不要求真实
Python open/restore green。此片仍可暂不显示menu，避免 dead product入口。

### F7b：provider-neutral profile/relation UI

**依赖**：F6b、F7a。

拆成两个小工作片，均保持编译green：

1. `AppModel.swift` + AppModel tests：Python `availableFeatureSelections == [.defaultFeatures]`；
   `switchFeatureSelection`对Python no-op且不增generation；Rust不变。
2. `MainWindowController.swift`、`ContextWindowModel.swift`、`NavigationHistory.swift`、
   `RelationTreeModel.swift`、`RelationWindowController.swift`及focused tests：Python profile不显示
   Cargo feature/edition；生产文案从写死 `rust-analyzer` 改为 `exact provider/server`，实际provider名
   继续来自 attribution。

Python profile展示在此片用人工 profile/pure display branch测试；真实 open integration留到F7c。不得为了
提前green绕过validator。不新增 capability model。UI是否显示 implementations直接读取现有 negotiated
result。

### F7c：最后产品 cutover、菜单与 Python self-test

**依赖**：F7a、F7b且C1/C2/C3全部green。

**文件**：

- `Sources/CodeInsightAppModel/AppModel.swift`
- `Sources/CodeInsightApp/CodeInsightApp.swift`
- `Sources/CodeInsightApp/EmptyStateView.swift`
- `scripts/run-self-tests.sh`
- `Tests/CodeInsightAppModelTests/AppModelTests.swift`

**顺序**：

1. 先加最终跨层 AppModel测试，修前在唯一 product validator同步失败；
2. 在 validator最后加入 `.python`；TypeScript/JavaScript仍拒绝；
3. 新增 `Open Python Project…`，两项菜单复用一个 `chooseProject(language:)`；
4. open-recent从store取language；`EmptyStateView`把recent click与drop拆成两个closure（不加type），
   unknown drop和其他无identity入口用最小Rust/Python/Cancel alert；不做marker auto-select；
5. 新增 `--self-test-python <repo>` 单一通道；不复制14套旧通道；
6. `run-self-tests.sh`接受可选第四个Python Git repo；不传时仍14通道，V0传入时15通道。

**Python self-test journey**：用fresh cache显式Python打开（cold counts）→tree只含`.py`→content/symbol
search→Reader outline/fold→fuzzy context/relation→Pyright definition/references/call hierarchy→HEAD~1→
worktree→关闭再按session/recent重开（hot counts）。每一步发结构化字段与
`SELF_TEST_FINISH ... exit=0`。

**绿门**：真实 Python retry/recent/session restore、profile UI与完整path通过；lower-layer人工
unsupported injection仍在任何state/cache/process之前原子失败；Rust菜单/key equivalent/自检行为
不变；15进程汇总 `pass=15 fail=0 hang=0`。

---

## §5 依赖图

```text
F0
└─ F1a grammar ─┬─ F1b core identity ─┬─ F2a extractor ─┬─ F2b fixture
                │                     │                 ├─ F3b module/resolver
                │                     │                 └─ F5a Reader ─ F5b UI
                │                     │                              └─ F5c Diff
                │                     └─ F3a capture/profile
                │
                └───────────────────────────────────────────── F6a Pyright

F2a + F3a + F3b → F4a index/cache/search → F4b gold
F3a + F4a + F6a → F6b Exact orchestration

C1(F1–F4) + C2(F5) + C3(F6)
  → F7a recent/open identity
  → F7b honest UI
  → F7c product cutover/self-test
  → V0
```

F6a可并行，但不能为了并行抽 strategy/registry。任何检查点失败都保持 App Python unsupported。

---

## §6 V0 总验收

### §6.1 自动门禁

```sh
set -euo pipefail
L1_BASE="${L1_BASE:-0add42056b8f8dfd618d82371b211072c2f90899}"
git rev-parse --verify "$L1_BASE^{commit}" >/dev/null
[[ -z "${RECORD:-}" ]]
l1_bundle_id="dev.cairn.Cairn.l1v0.$(/bin/date -u +%Y%m%d%H%M%S)-$$"
! /usr/bin/defaults read "$l1_bundle_id" >/dev/null 2>&1
test ! -e "$HOME/Library/Application Support/Cairn/$l1_bundle_id"

CODEX_SANDBOX=1 bash scripts/ci.sh

selftest_non_git_dir="$(mktemp -d /private/tmp/codeinsight-l1-selftest.XXXXXX)"
l1_cache_root="$(mktemp -d /private/tmp/codeinsight-l1-cache.XXXXXX)"
selftest_open_file="$PWD/Tests/CodeInsightExactTests/Fixtures/exact_fixture/src/lib.rs"
trap 'rm -rf "$selftest_non_git_dir" "$l1_cache_root"' EXIT
cp "$selftest_open_file" "$selftest_non_git_dir/main.rs"
test -d "$PWD/.git"
test -f "$selftest_non_git_dir/main.rs"
test -f "$selftest_open_file"

CODEINSIGHT_INDEX_CACHE_ROOT="$l1_cache_root/index" \
CODEX_SANDBOX=1 bash scripts/run-self-tests.sh \
  "$PWD" \
  "$selftest_non_git_dir" \
  "$selftest_open_file" \
  /Users/siancao/work/ai/mcp/mcp-python-sdk

CODEX_SANDBOX=1 bash scripts/run-gold-gates.sh \
  --python-corpus /Users/siancao/work/ai/mcp/mcp-python-sdk \
  --python-revision f55831ee798cd4d7bafab4d50d6dba46e6fce387

CODEX_SANDBOX=1 CAIRN_BUNDLE_IDENTIFIER="$l1_bundle_id" \
  CAIRN_OUTPUT_DIR=.build/l1-distribution \
  bash scripts/make-app.sh
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  .build/l1-distribution/Cairn.app/Contents/Info.plist)" = "$l1_bundle_id"

git diff --check
```

若F0前已单独提交本计划，必须把环境变量 `L1_BASE`设为该真实提交；只有计划仍未提交时才使用上面的
架构父基线默认值。

必须记录：

- full CI exit、Swift test数、每个target pass/fail、fold perf；
- self-test `pass=15 fail=0 hang=0`及artifact目录；
- Rust两套gold原计数与Python unexpected failure 0；
- Python cold/hot cache的reused/extracted/file count/elapsed；
- real Pyright版本、能力、deny-network、missing-import limitation、graceful shutdown；
- fake server cancel preemption、restart exhaustion、force-kill/reap；不得冒充real Pyright证据；
- final bundle/zip、Info.plist和 `codesign --verify --strict`；
- 本次唯一 `l1_bundle_id`、首次启动前UserDefaults/session domain为空；
- 不把skip当Pyright product gate通过。

### §6.2 真实 macOS bundle journey

使用同一个最终 `.build/l1-distribution/Cairn.app` 完成；其Info.plist必须保持§6.1本次唯一
`l1_bundle_id`，使UserDefaults/session与正式 `dev.cairn.Cairn`隔离。先记录 `launchctl getenv PATH`，
不得 `launchctl setenv`或从富化PATH直接执行bundle binary。用 `open -n`按正常LaunchServices路径启动：

1. 用现有 `Open Project…` / ⌘O打开 CodeInsight Rust repo；profile为Rust、tree只显示`.rs`，打开一份
   Reader并得到rust-analyzer attribution，证明最终bundle的Rust入口与provider discovery未回归；
2. `Open Python Project…`打开固定 clean corpus
   `/Users/siancao/work/ai/mcp/mcp-python-sdk@f55831e...`；
3. 文件树只含 `.py`，profile显示Python且不出现Cargo feature/edition；bundle进程内Pyright为ready；
4. 搜索并打开 `src/mcp/shared/memory.py:create_client_server_memory_streams`；
5. 验证highlight、class/function outline、fold、local reference；
6. 从call site得到Pyright definition和references；打开Calls/Callers并看到provider attribution；
7. implementations明确unsupported；
8. Compare选择 `HEAD~1` 对 Working Tree/HEAD，打开
   `src/mcp/server/fastmcp/server.py:get_prompt`并断言真实旧/新hunk；不得用相同HEAD/worktree冒充diff；
9. 主 snapshot切到HEAD~1，等待revision、`fullReady`、Exact ready；再回Working Tree并等待三项均完成，
   language/profile/Reader/Exact仍为Python；
10. 正常Quit，等待进程退出以完成同步checkpoint；从同一bundle再次正常启动，等待session恢复到
    Python `fullReady` + Exact ready；recent再次打开仍Python；
11. 前后两个repo的HEAD、`git status --porcelain`、index和tracked hashes不变。

验收只读写本次唯一bundle domain；不得读取、清理或修改正式 `dev.cairn.Cairn` 的UserDefaults、
Application Support/session/recent数据。同一个唯一ID贯穿首次启动、Quit和relaunch，不能中途换ID规避
恢复验证。

若正常bundle进程找不到任一provider，结果为 `BLOCKED`；不得通过临时修改LaunchServices环境把它改写
为PASS。

必须用真实AppKit/AX状态与可见frame断言；源码检查或debug binary不能替代最终bundle gate。若出现新UI
差异，补三主题真实截图；若无可见差异，不为里程碑制造截图任务。

### §6.3 结构门禁

`rg` allow-list逐项解释 production 中的：

- `.rust/.python`；
- `RustExtractor/PythonExtractor`；
- `RustHighlighter`与module-internal/private Python Reader函数；
- `RustAnalyzerProvider/PyrightProvider`；
- `waitForQuiescence`只能在RA路径；
- `implementationProvider`只按negotiation；
- project language默认只存在兼容入口/测试/Rust-only CLI。

禁止出现：`LanguageAdapter`、`ModuleResolver` protocol、provider registry、generic LSP runtime、
multi-session/profile collection、Python profile type、future TS placeholder。

### §6.4 范围门禁

```sh
git diff --name-only "$L1_BASE"...HEAD
git diff --name-only
git diff --cached --name-only
git ls-files --others --exclude-standard
```

- `CanonicalDump.swift`、`Prototypes/`、M11 evidence、existing Rust fixtures、`tokio.gold`、
  `ripgrep.gold`与`goldset/fixtures/`零改；`goldset/`父tree因新增Python child允许变化；
- `Sources/CTreeSitter/`、`Sources/CTreeSitterRust/`、`Package.resolved`零改；
- 新增文件只允许Python grammar/extractor/fixture/gold/evidence及计划列出的focused test；现有文件修改
  必须逐项属于§4 allow-list；
- `RECORD` UNSET；
- secrets/token scan PASS；计划/证据中的checkout、验收corpus和具名cache/tmp路径为显式allow-list，
  其他意外绝对路径为失败；
- 不publish、不tag、不push；是否commit由用户单独决定。

---

## §7 风险与停止条件

| 风险 | 触发信号 | 对策 / 停止条件 |
|---|---|---|
| Python动态语义被冒充Strong | `obj.m()`同名全局命中Strong | method封顶Possible；gold `nostrong` |
| module root过度猜测 | ambient PYTHONPATH/site-packages改变结果 | 只用manifest内`.`/`src`唯一target |
| cache串语言 | 同字节Rust/Python复用draft | full key + cold/hot isolation test；不改schema |
| profile复用过期 | config/uv/interpreter变化Exact overlay不失效 | fixed fingerprint + existing tool identity reuse tests |
| no-config历史Exact失败 | empty fingerprint被Materializer拒绝 | 固定nonempty sentinel hash；layout不改 |
| Pyright等待永久超时 | Python调用RA quiescence | `rg`门禁；独立session直接request |
| missing dependency伪完整 | definition空但UI绿色 | Python base environment始终携带existing offline limitation |
| project helper被执行 | adversarial PATH中的python/node/server/CLI marker出现 | Python Exact off；canonical排除/强化sandbox后重测 |
| GUI找不到provider | shell可见但正常bundle unavailable | 标准绝对目录fallback；不得用launchctl setenv偷渡 |
| trusted扩大写权限 | Python在project/target写文件 | 两种trust都Safe launch；hash gate |
| Safe被误称秘密隔离 | 项目外可读文件被provider读取 | 明确只保完整性/网络/写边界；不作confidentiality承诺 |
| `.pyi`越界导航 | Exact打开typeshed/stub | publish classifier filter；显示unsupported |
| recent丢语言 | Python recent按Rust重开 | path+language平行map；旧数据仅Rust |
| App过早放行 | 任一下层branch仍unsupported | F7c最后一行cutover；检查点前保持红 |
| 抽象膨胀 | adapter/registry/strategy出现 | 删除；两个concrete实现先交付 |
| real corpus `src/` imports失效 | `mcp.*`全部unresolved | 唯一`src/`root支持；不扩monorepo router |
| Rust回归 | fixed vector/gold/UI差异 | 回退当前片，不加兼容双实现遮掩 |

以下任一发生即 `BLOCKED`，不得宣告 L1完成：

- Pyright在deny-network/read-only项目下无法完成definition+references+call hierarchy；
- fake project PATH helper执行无法被最小discovery/launch/sandbox边界阻断；
- Python Exact需要执行项目代码或安装依赖才能满足真实项目gate；
- `EngineSession`必须改为多profile/container才能支持单Python项目；
- Rust full CI、14旧self-tests或两套Rust gold出现稳定回归；
- 正常LaunchServices启动的final `.app`找不到两个provider，或无法完成commit→worktree和
  session/recent恢复。

---

## §8 开工清单

- [ ] 用户批准本计划的 `.py` only、external Pyright、honest implementations unsupported边界。
- [ ] 计划若commit，记录真实 `L1_BASE`；不照抄架构父SHA。
- [ ] F0实时CI exit 0，受保护objects与P0一致。
- [ ] 正常GUI环境可发现Pyright、companion CLI和rust-analyzer；缺失时只做fuzzy slices，不越过
  C3/F7c/V0。
- [ ] tree-sitter-python release asset SHA和license已记录。
- [ ] 每新增production type能对应§0的四项之一；否则删除。
- [ ] 每片有修前失败和修后通过证据，且App Python在F7c前保持unsupported。
- [ ] 不commit、不push，除非用户在验证后明确要求。
