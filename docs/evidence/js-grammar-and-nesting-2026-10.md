# JavaScript 复用 TypeScript 语法与表达式嵌套深度（2026-10-10）

目的：决定 JavaScript 分析是否需要新 vendor 一份 tree-sitter-javascript，顺带得到抽取器在深嵌套表达式上的实际上限。环境：main 3508dee，Xcode 27.0 / Swift 6.4，M 系列 Mac；语法为已 vendored 的 tree-sitter-typescript v0.23.2（`Sources/CTreeSitterTypeScript`）。临时测试已删除，下面的数字可按"复现"一节重新得到。

## 一、JS/JSX 直接用 TS/TSX parser 过 `TypeScriptExtractor`

| 语料 | 文件数 | parser | 含 error node 的文件 |
| --- | --- | --- | --- |
| llm-tools bb6e992 的 `.ts/.tsx`（基线，`.tsx` 用 tsx） | 70 | ts/tsx | 0 |
| Homebrew `node_modules` 抽样 `.js`（排除 `.min.js`、`test/`，每 30 个取 1） | 444 | ts | 0 |
| 同上 | 444 | tsx | 0（符号/绑定/导入/调用计数与 ts 完全相同） |
| Homebrew `node_modules` 抽样 `.mjs` | 118 | ts 与 tsx | 2 |
| 本机 Spotlight 找到的 `.jsx`（排除编辑器历史） | 17 | ts | 15 |
| 同上 | 17 | tsx | 0 |

两个 `.mjs` 的出错点：pdf.js `pdf.worker.mjs` 的 `let as = src[...]`（`as` 作为变量名），mermaid 压缩块的 `?.5:1`（`?.` 与小数的词法歧义，源自 tree-sitter-javascript 共用的 scanner，不是 TS 特有）。

合成核验 23 个 TS 上下文关键字（`as`、`type`、`satisfies`、`declare`、`namespace`、`module`、`readonly`、`is`、`keyof`、`infer`、`asserts`、`unique`、`abstract`、`global`、`override`、`out`、`any`、`number`、`string`、`async`、`of`、`get`、`set`）分别作为 `let` 声明名、参数名、对象属性名：只有 `let as = 1` 与 `let satisfies = 1` 报错，ts 与 tsx 一致。

结论：JavaScript 不需要新的语法 vendor；`.js/.jsx/.mjs/.cjs` 统一用 tsx parser 即可（`.js` 里带 JSX 的 React 代码也能过）。已知差异只有 `as`/`satisfies` 作声明名，影响该语句所在区域的索引，不影响整文件。

## 二、深嵌套表达式让抽取崩溃（SIGBUS，栈溢出）

抽样时 highlight.js 的 `lib/languages/sqf.js`（347 个 `'…' +` 串接）在 debug 测试进程里以 `Thread stack size exceeded` 崩溃，崩溃栈在 `TypeScriptExtractor` 的递归 `walk`/`namedChildren`。三个抽取器都按节点递归（`TypeScriptExtractor.walk`、`PythonExtractor.walk`、`RustScopeBuilder`），`ProjectIndexer.parallelMap` 在 GCD 串行队列上提取，线程栈 512 KB。

用合成文件 `const s = 'kw' + 'kw' + …;`（Python 去掉 `const`/`;`，Rust `String::new() + "kw" + …`）测得：

| 构建 | 路径 | Python | TypeScript | Rust |
| --- | --- | --- | --- | --- |
| debug | `ProjectIndexer(parallelism: 2).indexSnapshot` | 60 层通过，80 层崩 | 150 通过，200 崩；sqf.ts（347）崩 | 1500 通过 |
| release | `codeinsight symsearch --project …`（同一 `parallelMap`，与打包应用相同配置） | 200 通过，500 崩 | sqf.ts（347）通过，500 崩 | 8000 通过 |

表中“通过”指进程未崩溃（CLI 的 `symsearch` 对合成文件没有命中，输出不证明已索引），“崩”指退出码 138 / `Thread stack size exceeded`。打包应用用 `swift build -c release`，提取走同一条 `parallelMap`，所以推断一个 500 层 `+` 串接的 Python 或 TypeScript 文件会让整个应用进程崩溃（SIGBUS 不可捕获）；这一点未在打包应用上复现。未测更细的阈值，也未测其他嵌套形态（深层括号、链式调用、嵌套三元）；方向已足够判断。

修复（同日），三处同类递归各一个回归，每条在修复前都以 SIGBUS 结束测试进程、修复后通过：

- 索引：`ProjectIndexer.parallelMap` 改为每个 worker 一个 64 MB 栈的 `Thread`，三门语言同时受益（`deeplyNestedExpressionsIndexWithoutOverflowingTheExtractionStack`，3000 层）。
- 项目搜索核验命中：`TypeScriptExtractor.identifierRanges` 从递归改为显式栈遍历，与 Python/Rust 已有的 `depthFirst()` 一致；它在 `SnapshotSearch` 的 Task 里跑（`identifierRangesSurviveDeeplyNestedExpressions`，3000 层）。
- 阅读侧高亮/折叠：`DocumentLoader.highlightWithFolds` 把 Python 与 TypeScript 的递归遍历放到 64 MB 栈线程上同步执行（Rust 高亮本来就是迭代的，3000 层直接通过）；它经 `loadSyntax(for:completion:)` 与上下文窗口的 `Task.detached` 在协作线程上跑（`readerSyntaxSurvivesDeeplyNestedExpressions`，三门语言 3000 层）。上表的阈值是修复前的数字，保留用于解释机制。修复后 release CLI 复测：Python 500/4000 层、TypeScript 500/4000 层、Rust 8000 层全部退出码 0，`sqf.ts` 索引出 `sqf` 函数；`CodeInsightEngineTests` 174 个测试通过。

## 复现

1. JS/JSX 抽样：`find /opt/homebrew/lib/node_modules -name '*.js' -not -name '*.min.js' -size +2k -not -path '*/test/*' | awk 'NR%30==0'`，`.mjs` 同理每 15 取 1；`.jsx` 用 `mdfind -onlyin ~ "kMDItemFSName == '*.jsx'"`。在 `Tests/TypeScriptExtractorTests` 放一个临时 `@Test`，对每个文件调用 `TypeScriptExtractor().extractWithDiagnostics(bytes:key:interner:)`，`LanguageMode(language: .typescript)` 与 `variant: "tsx"` 各一遍，统计 `containsErrorNodes`；用 `Node.depthFirst().filter { $0.kind == "ERROR" }` 取首个出错偏移。
2. 深度阈值：`swift build -c release --product codeinsight`，对每个深度生成一个只含该文件的 git 仓库，运行 `.build/out/Products/Release/codeinsight symsearch s --project <dir> --language <lang>`，退出码 138 即 SIGBUS。`swift test -c release` 在本仓库不可用（`TypeScriptExtractorTests` 引用 debug-only 的 `$parseObserver`）。
