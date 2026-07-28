# M7-S1 Spike Findings：References 合同与证据

> 日期：2026-07-28
>
> CodeInsight 基线：`cb2cbbb85d39c6526c2015502db2fd0729fb239b`
>
> 执行期间并发 HEAD 移动：最终为 `4a1d22f76b48d93bfb4e89ca766649ecae5c79b4`；
> 该 commit 仅新增 `docs/plans/m7-status.md`，不是本 spike 创建，见 §4
>
> rust-analyzer：`rust-analyzer 0.0.0 (cac0779549 2026-07-18)`
>
> Tokio：`046852fd3f3171ad5f5ac703865fe53c8b70e102`，`cargo metadata` exit 0
>
> 结论状态：Q1–Q12 均已实测；import alias 测得当前 RA 的覆盖缺口；无环境
> BLOCKED。

## 0. 结论先行

1. **References ≠ Callers，已由真实 RA 证明。** `Foo` 的 10 个非声明引用包含
   类型标注、泛型实参、返回类型、struct literal、`Foo::new` qualifier 和解构
   pattern；`Choice::Bar` 的 2 个非声明引用包含构造与 match pattern。二者的
   `textDocument/prepareCallHierarchy` 都返回 `[]`。local / param / 解构绑定也有
   References，但没有 Call Hierarchy item。
2. **`includeDeclaration` 建议默认 `false`。** 普通符号的 true 结果均比 false 多
   1 个声明；References 产品面应默认列使用位置，声明已有独立跳转入口。若 UI 要显示
   声明，应作为单独行/开关，不混入默认计数。
3. **S3 的“直接复用现有 `SnapshotSearchService.search`”不可按原样派发。**
   当前默认 case-insensitive raw 搜索在语义验证前触发 5000 cap：
   `poll` 丢 1,574/6,574 raw candidates，并丢 427/1,020 个 syntax-verified
   identifier；`buf` 丢 46/5,046 raw、19/1,713 verified。
4. **只提高 cap 不是修复。** 三个样本显式 `caseSensitive: true` 后都未触 cap，
   说明 exact-case prefilter 是必要条件；但 cap 仍然放在验证前，只会把已知缺陷推迟
   到更热符号/更大仓库。
5. **建议把 S3 改成 verification-aware 两阶段扫描：**
   无 raw 数量 cap 的 exact-case content prefilter → 每个 candidate unique content
   on-demand parse 一次 → 只接收同名 identifier node → 最后才对 verified 结果应用
   批次、时间和展示 cap。无需保存 Tree、无需新数据库表、无需新增持久化实体。
6. **comment/string 排除可行。** Tree-sitter 语法节点过滤的反冒充结果是
   raw 6 → verified 2；string、两种 comment、`foo_suffix` 都被排除。现有
   Resolver byte fallback 不能单独承担这件事。
7. **truncated 文案只能是 `N verified references · partial`。** 201 个已知 raw
   命中的运行时 fixture 只返回 200；`SearchBatch` runtime fields 只有
   `matchesByPath/isFinal/completeness/truncatedPathIDs`，确实没有 universe total。

## 1. 方法、口径与运行记录

### 1.1 Exact

丢弃型 Python 探针直接启动 `/opt/homebrew/bin/rust-analyzer`，通过 stdio
`Content-Length` LSP 帧通信，绕过 CodeInsight `sandbox-exec`。初始化使用：

```json
{
  "initializationOptions": {
    "cargo": {"buildScripts": {"enable": false}, "features": "all"},
    "procMacro": {"enable": false},
    "checkOnSave": false
  },
  "environment": {"CARGO_NET_OFFLINE": "true"}
}
```

最小 fixture 是可编译 Cargo project，`cargo check --offline --quiet` exit 0。
LSP position/range 均为 0-based UTF-16；本文展示位置时转为 1-based `line:column`。

```text
$ python3 .m7-spike-ra-probe.py fixture
exit 0
$ python3 .m7-spike-ra-probe.py history
exit 0
$ python3 .m7-spike-ra-probe.py tokio
exit 0
Tokio workspace/symbol ready: 2467.563 ms, Runtime symbols=13
```

### 1.2 Fuzzy

丢弃型 Swift test 复刻 `SnapshotSearchService` 的 literal candidate 次序与
`200/file + 5000 total` cap；候选内容通过 Tree-sitter parse 一次，遍历
`*identifier*` nodes，以**大小写完全相同且 node text 完全等于 symbol**作为
Fuzzy verification predicate。

这里的 `verified` 是“语法上确为同名 identifier，可作为 Fuzzy 证据”，**不是**
跨文件 binding identity，也不冒充 RA Exact。prototype 故意采用宽口径：同名
declaration 与 use 都算 syntax-verified candidate；S3 若默认
`includeDeclaration:false`，应在验证后排除被选 symbol 的声明位置。

```text
$ M7_TOKIO_ROOT=<tokio> swift test --disable-sandbox \
    --filter m7FuzzyPrototypeMetrics
Build complete! (1.61s)
M7_FUZZY_METRIC ... poll ...
M7_FUZZY_METRIC ... cx ...
M7_FUZZY_METRIC ... buf ...
M7_ANTI_SPOOF ...
M7_SEARCH_BATCH ...
Test m7FuzzyPrototypeMetrics() passed after 10.362 seconds.
```

Tokio 的 717 个 tracked Rust paths 恰好对应 717 个 unique contents。本 prototype
只 parse 含 raw candidate 的 contents，而不是 parse 全仓或每个 candidate。

---

## 第一组：Exact References 语义

## Q1. `includeDeclaration` true / false

### 请求

同一 `foo` declaration position：

```json
{"id":5,"method":"textDocument/references","params":{
  "textDocument":{"uri":"file://$FIXTURE/src/lib.rs"},
  "position":{"line":24,"character":7},
  "context":{"includeDeclaration":false},
  "partialResultToken":"function foo-False"
}}
{"id":6,"method":"textDocument/references","params":{
  "textDocument":{"uri":"file://$FIXTURE/src/lib.rs"},
  "position":{"line":24,"character":7},
  "context":{"includeDeclaration":true},
  "partialResultToken":"function foo-True"
}}
```

### 响应与计数

```json
{
  "includeDeclaration": false,
  "count": 3,
  "totalMs": 0.571,
  "locations": [
    {"at":"44:18","text":"let called = foo(1);"},
    {"at":"45:26","text":"let function_value = foo;"},
    {"at":"46:12","text":"accept(foo);"}
  ]
}
{
  "includeDeclaration": true,
  "count": 4,
  "totalMs": 0.159,
  "locations": [
    {"at":"44:18","text":"let called = foo(1);"},
    {"at":"45:26","text":"let function_value = foo;"},
    {"at":"46:12","text":"accept(foo);"},
    {"at":"25:8","text":"pub fn foo(x: i32) -> i32 {"}
  ]
}
```

结论：在本 fixture 的 function / param / local / type / method / enum variant /
pattern binding / dependency symbol 上，true 均比 false **多 1 个声明**。默认建议
`false`。

## Q2. 覆盖面；证明 References ≠ Callers

### 全量计数

所有请求均为 `textDocument/references`，位置与实际响应如下：

| 符号 | position (0-based) | false | true | false/true 耗时 | false 响应的具体语义 |
|---|---:|---:|---:|---:|---|
| function `foo` | 24:7 | 3 | 4 | 0.571/0.159 ms | 调用 1、函数值赋值 1、函数值传参 1 |
| param `x` | 24:11 | 1 | 2 | 0.225/0.099 ms | 函数体读取 |
| outer local | 52:8 | 2 | 3 | 0.225/0.141 ms | 两个 outer-scope 读取 |
| type `Foo` | 7:11 | 10 | 11 | 0.406/0.210 ms | impl、返回类型、标注、泛型实参、literal、qualifier、pattern |
| constructor method `new` | 12:11 | 1 | 2 | 0.135/0.123 ms | `Foo::new(2)` |
| variant `Bar` | 18:4 | 2 | 3 | 0.104/0.097 ms | 构造 1、match pattern 1 |
| destructured binding | 33:17 | 1 | 2 | 0.224/0.114 ms | pattern 绑定后的读取 |
| import alias use | 46:22 | 1 | 2 | 0.133/0.094 ms | **见下述 RA 缺口** |

### function：调用与函数值

```json
{
  "referencesFalse": [
    "44:18 let called = foo(1);",
    "45:26 let function_value = foo;",
    "46:12 accept(foo);"
  ],
  "callHierarchyIncoming": {
    "caller":"uses",
    "fromRanges":["44:18","45:26","46:12"]
  }
}
```

RA References 覆盖调用、函数值赋值和函数值传参。当前 RA 的 Call Hierarchy
也把这三个 range 都归入 `uses -> foo`，因此**本版本的函数值不是**
“References 独有”证据；不能用它单独证明二者不同。

### type 与 constructor

`Foo` 的 false 响应：

```json
{
  "count":10,
  "locations":[
    "12:6 impl Foo",
    "13:27 fn new(...) -> Foo",
    "14:9 Foo { x }",
    "31:22 fn make_foo() -> Foo",
    "32:16 let typed: Foo",
    "32:22 Foo { x: 1 }",
    "33:25 Holder<Foo>",
    "33:39 Holder(Foo::new(2))",
    "34:9 let Foo { x: destructured }",
    "40:5 Foo { x: ... }"
  ],
  "prepareCallHierarchyResponse":[]
}
```

这同时证明 RA 返回：

- 类型标注：`let typed: Foo`
- 泛型实参：`Holder<Foo>`
- 返回类型：`-> Foo`
- struct literal constructor：`Foo { ... }`
- associated constructor qualifier：`Foo::new(...)` 中的 `Foo`
- destructuring pattern：`let Foo { ... }`

`new` 自身 false=1 / true=2；它是函数，所以 Call Hierarchy 有 1 个 item 和
1 条 incoming range `33:44`。但 `Foo` 类型/字面量/pattern 的 10 个 References
**没有任何 Call Hierarchy item**。

### pattern

```json
{
  "variantBarReferencesFalse":[
    "36:33 match Choice::Bar",
    "37:17 Choice::Bar => 1"
  ],
  "variantBarPrepareCallHierarchy":[],
  "destructuredBindingReferencesFalse":[
    "40:14 destructured + pattern_value + ..."
  ],
  "destructuredBindingPrepareCallHierarchy":[]
}
```

构造 variant、match arm pattern、解构绑定读取均由 References 返回，均不是
Call Hierarchy 能覆盖的关系。

### local / param

param 与 local 均有 References；`prepareCallHierarchy` 响应都是 `[]`。具体而言：

```json
{
  "paramX":{"false":["26:5 x + 1"],"trueAdds":"25:12 parameter declaration"},
  "outerLocal":{
    "false":["54:21 let outer_use = local","60:17 let after = local"],
    "trueAdds":"53:9 let local = param"
  }
}
```

这是另一组直接的 “References ≠ Callers” 证据。

### import alias：当前 RA 的实测缺口

fixture：

```rust
pub mod alias_mod { pub fn original() -> i32 { 1 } }
use crate::alias_mod::original as alias;
let alias_value = alias();
```

从 `alias()` 的 alias token 发请求，definition 正确指向 `original`：

```json
{"method":"textDocument/definition","position":{"line":46,"character":22},
 "response":[{"at":"2:12","text":"pub fn original() -> i32 { 1 }"}]}
```

但 References 实测为：

```json
{
  "includeDeclaration":false,
  "count":1,
  "response":[
    {"at":"5:23","rangeText":"original",
     "lineText":"use crate::alias_mod::original as alias;"}
  ]
}
{
  "includeDeclaration":true,
  "count":2,
  "response":[
    {"at":"5:23","rangeText":"original",
     "lineText":"use crate::alias_mod::original as alias;"},
    {"at":"2:12","rangeText":"original",
     "lineText":"pub fn original() -> i32 { 1 }"}
  ]
}
```

**`alias()` 当前使用位置没有出现在响应里。** `prepareCallHierarchy` 虽返回
`original` item，但 incoming 是空。结论不是“RA 覆盖 alias”，而是：
**当前 build 对该 import alias fixture 有可复现覆盖缺口**。S4 Exact 不能把
import alias 写成已覆盖合同；需保留 Fuzzy 补位或在未来 RA 版本复测。

## Q3. shadowing 与同名 sibling scope

### 实测响应

```json
[
  {"symbol":"outer local","includeDeclaration":false,"count":2,
   "totalMs":0.225,"locations":["54:21","60:17"]},
  {"symbol":"inner shadow local","includeDeclaration":false,"count":1,
   "totalMs":0.119,"locations":["57:25"]},
  {"symbol":"left sibling","includeDeclaration":false,"count":1,
   "totalMs":0.119,"locations":["63:20"]},
  {"symbol":"right sibling","includeDeclaration":false,"count":1,
   "totalMs":0.104,"locations":["68:21"]}
]
```

true 分别只增加自己的声明：outer `53:9`、inner `56:13`、left `62:13`、
right `67:13`。返回集没有串入 shadowed binding 或 sibling block，结论 **PASS**。

## Q4. comment / string 是否排除

反冒充行：

```rust
// local param foo alias Bar sibling
let text = "local param foo alias Bar sibling";
```

`foo` false 响应只有 44/45/46 三个代码位置；outer `local` false 只有 54/60；
param false 只有 26。上述 comment/string 行均未出现。

```json
{
  "query":"foo",
  "responseLines":[44,45,46],
  "commentLine":71,
  "stringLine":72,
  "totalMs":0.571,
  "commentOrStringHits":0
}
```

结论 **PASS**。

## Q5. dependency location 与路径形态

### path dependency fixture

从 `depcrate/src/lib.rs` 的 `DepType` 声明查询：

```json
{
  "includeDeclaration":false,
  "count":7,
  "locationsByFile":{
    "$FIXTURE/src/lib.rs":[
      "use depcrate::DepType",
      "let dep = DepType::new()"
    ],
    "$FIXTURE/depcrate/src/lib.rs":[
      "impl DepType",
      "fn new() -> DepType",
      "DepType(7)",
      "fn dependency_internal(value: DepType) -> DepType (two ranges)"
    ]
  }
}
```

true=8，另外增加 `pub struct DepType` 声明。RA 会返回依赖源码内部引用，URI 为普通
absolute `file://` URI。

### crates.io dependency：查询起点会改变依赖内部覆盖

Tokio 的 `bytes::BytesMut`：

```json
{
  "requestFromTokioUse":{
    "method":"textDocument/references",
    "position":{"file":"tokio/src/io/util/mem.rs","line":5,"character":17},
    "includeDeclaration":true
  },
  "response":{
    "count":138,
    "tokioWorkspace":137,
    "cargoRegistry":1,
    "totalMs":73.845
  }
}
```

唯一 registry location 是声明：

```text
file:///Users/siancao/.cargo/registry/src/
  index.crates.io-1949cf8c6b5b557f/bytes-1.12.1/src/bytes_mut.rs:60:12
pub struct BytesMut {
```

再从该 registry declaration position 查询：

```json
{
  "response":{
    "count":277,
    "tokioWorkspace":137,
    "cargoRegistry":140,
    "totalMs":81.385
  }
}
```

结论：

- RA 可以返回 registry dependency 源码，路径是 `$CARGO_HOME/registry/src/<index>/
  <crate-version>/...` 的 absolute `file://` URI。
- **从 workspace use 查询时只得到 dependency declaration，不得到其 139 个内部
  references；从 dependency declaration 查询时才得到。** Exact 产品应保留
  External/in-dependency 标注，且不能假设两种查询起点的 universe 相同。

## Q6. worktree 与历史 commit snapshot

丢弃型 git repo 先提交 v1，再让 worktree 修改为 v2；历史目录由该 commit 的
`git archive` 物化。commit：
`a7bcc1377420eef260f11ae82e115c0162cfc95c`。

```json
{
  "worktreeGitStatus":[" M src/lib.rs"],
  "worktree":{
    "request":{"includeDeclaration":true},
    "count":3,
    "totalMs":0.38,
    "locations":[
      "3:26 let function_value = foo",
      "4:5 foo() + function_value()",
      "1:8 pub fn foo() -> i32 { 1 }"
    ]
  },
  "historicalCommit":{
    "root":"$MATERIALIZED_COMMIT",
    "request":{"includeDeclaration":true},
    "count":2,
    "totalMs":0.44,
    "locations":[
      "2:27 pub fn use_foo() -> i32 { foo() }",
      "1:8 pub fn foo() -> i32 { 1 }"
    ]
  }
}
```

RA 没有“commit 参数”；它回答 provider root 当前磁盘内容。worktree session 看见
未提交 v2，历史 session 看见物化 commit v1，并返回各自 root 下的 absolute
`file://` URI。历史 Exact 的正确性因此依赖 materialization root 与 session identity，
不能复用 worktree session/result。

## Q7. Tokio 三档规模与延迟

请求都带 `includeDeclaration:true` 与 `partialResultToken`。当前 RA 没有发送任何
partial progress（`partialEventCount=0`），所以 **首批延迟 = 完整响应延迟**：

| 符号 | 位置 | 结果总量 | 首批 | 总延迟 | partial events |
|---|---|---:|---:|---:|---:|
| `Runtime` | `tokio/src/runtime/runtime.rs:95` | 86 | 371.606 ms | 371.606 ms | 0 |
| `ReusableBoxFuture::poll` | `tokio/src/signal/reusable_box.rs:114` | 2 | 485.899 ms | 485.899 ms | 0 |
| local param `cx` | `tokio/src/future/maybe_done.rs:63` | 2 | 0.254 ms | 0.254 ms | 0 |

代表性响应：

```json
{
  "Runtime":{
    "count":86,
    "sample":[
      "runtime.rs:129:6 impl Runtime",
      "runtime.rs:134:10 -> Runtime",
      "runtime.rs:135:9 Runtime {",
      "runtime/mod.rs:395:23 pub use runtime::{Runtime, RuntimeFlavor}",
      "runtime.rs:95:12 pub struct Runtime"
    ]
  },
  "ReusableBoxFuture::poll":{
    "count":2,
    "locations":[
      "signal/mod.rs:92:26 self.inner.poll(cx)",
      "signal/reusable_box.rs:114:19 fn poll declaration"
    ]
  },
  "local param cx":{
    "count":2,
    "locations":[
      "future/maybe_done.rs:65:68 future.poll(cx)",
      "future/maybe_done.rs:63:39 parameter declaration"
    ]
  }
}
```

结果数量与延迟不单调：`poll` 只有 2 项却用 485.899 ms，不能仅按结果条数冻结
Exact 预算。当前协议/RA 也不给 streaming 首批；不要预造 UI streaming 合同。

---

## 第二组：Fuzzy 实现路径

## Q8. 每个 unique content 是否只 parse 一次

### 计数

```json
[
  {"term":"poll","rawCandidates":6574,
   "candidateContentCount":341,"parseCount":341,"maxParsesPerContent":1,
   "parseMs":843.990},
  {"term":"cx","rawCandidates":1830,
   "candidateContentCount":256,"parseCount":256,"maxParsesPerContent":1,
   "parseMs":626.692},
  {"term":"buf","rawCandidates":5046,
   "candidateContentCount":205,"parseCount":205,"maxParsesPerContent":1,
   "parseMs":521.532}
]
```

Tokio 总计 717 paths / 717 unique contents。prototype 先按 contentID 去重，只在内容含
candidate 时 parse；parse count 等于 candidate unique content count，且每个
content 的最大 parse 次数为 1。不是每候选 parse：例如 `poll` 是
**341 parses / 6,574 raw candidates**。结论 **可行且已做出**。

这需要新的 on-demand parse 路径；现有 `ContentIndex` 不存 Tree / identifier
occurrences，不能假装从已有持久化产物免费得到。

## Q9. comment / string 排除是否真实可行

反冒充 source 的一次 parse：

```rust
fn foo() {}
fn call_site() { foo(); }
const TEXT: &str = "foo";
// foo
/* foo */
fn foo_suffix() {}
```

实测日志：

```json
{
  "parseCount":1,
  "parseMS":0.072208,
  "rawCandidateCount":6,
  "verifiedIdentifierCount":2,
  "totalMS":0.257375,
  "evidence":[
    {"line":1,"column":4,"verified":true,"text":"fn foo() {}"},
    {"line":2,"column":18,"verified":true,"text":"fn call_site() { foo(); }"},
    {"line":3,"column":21,"verified":false,"text":"const TEXT: &str = \"foo\";"},
    {"line":4,"column":4,"verified":false,"text":"// foo"},
    {"line":5,"column":4,"verified":false,"text":"/* foo */"},
    {"line":6,"column":4,"verified":false,"text":"fn foo_suffix() {}"}
  ]
}
```

结论 **PASS**：只接收 text 完全等于 symbol 的 identifier node，string/comment
没有 identifier child，identifier 子串也被排除。现有 Resolver ASCII byte fallback
没有这些语法信息，必须在进入 fallback 前做这一步；不能只靠 byte boundary 补丁。

## Q10. raw cap 是否吞掉有效引用

### 按当前 `ContentSearchQuery` 默认（case-insensitive）

`verified` 的口径是 Q9 的 exact-case identifier predicate：

| term | raw universe | cap 后 raw | raw 丢失 | verified universe | cap 后 verified | verified 丢失 |
|---|---:|---:|---:|---:|---:|---:|
| `poll` | 6,574 | 5,000 | 1,574 (23.943%) | 1,020 | 593 | **427 (41.863%)** |
| `cx` | 1,830 | 1,830 | 0 | 1,657 | 1,657 | 0 |
| `buf` | 5,046 | 5,000 | 46 (0.912%) | 1,713 | 1,694 | **19 (1.109%)** |

三个 symbol 均未触发 200/file；`poll` 与 `buf` 是 5000 total cap。也就是说 cap
不只丢噪声，确实丢了会通过 Fuzzy 验证的 identifier。

原始日志：

```json
{"term":"poll","defaultInsensitiveCaps":{
  "rawUniverse":6574,"visibleRaw":5000,"rawDropped":1574,
  "rawDroppedPercent":23.942804989351991,
  "verifiedVisible":593,"verifiedDropped":427,
  "verifiedDroppedPercent":41.862745098039213,
  "fileCapPathCount":0,"totalCapReached":true
}}
{"term":"buf","defaultInsensitiveCaps":{
  "rawUniverse":5046,"visibleRaw":5000,"rawDropped":46,
  "rawDroppedPercent":0.91161315893777251,
  "verifiedVisible":1694,"verifiedDropped":19,
  "verifiedDroppedPercent":1.1091652072387623,
  "fileCapPathCount":0,"totalCapReached":true
}}
```

### symbol-correct case-sensitive 对照

| term | raw universe | raw 丢失 | verified universe | verified 丢失 |
|---|---:|---:|---:|---:|
| `poll` | 4,225 | 0 | 1,020 | 0 |
| `cx` | 1,830 | 0 | 1,657 | 0 |
| `buf` | 4,195 | 0 | 1,713 | 0 |

显式 `caseSensitive:true` 是 Rust symbol 搜索的必要最小修正，并让本次三个样本不再
触 cap；但它不能证明所有仓库/符号都低于 200/5000。因为 cap 仍在 verification
之前，现有 API 仍然带着结构性缺陷。

## Q11. truncated 时能否知道 universe total

运行时 fixture 已知有 201 个 `foo`，实际 `SnapshotSearchService` 只返回 200：

```json
{
  "knownFixtureUniverse":201,
  "visibleMatches":200,
  "completeness":"truncated",
  "truncatedPathCount":1,
  "runtimeFields":[
    "matchesByPath",
    "isFinal",
    "completeness",
    "truncatedPathIDs"
  ],
  "hasUniverseTotal":false,
  "totalMS":0.714916
}
```

这是实际 stream final batch 的 Mirror 结果，不是只看源码推断。消费者只有
visible/verified N 与 partial 信号，不可能恢复 201，更不可能恢复真实仓库 universe。

结论：严格采用 §2.2 四态合同：

```text
complete                    -> M references
display cap only            -> Showing first N of M references
service/prototype truncated -> N verified references · partial
Exact + Fuzzy               -> 各自保留 completeness
```

## Q12. 候选发现 + 语义验证端到端延迟

prototype 的 first batch 门槛与服务相同：累计 16 个有结果文件或 200 个 verified
matches；所有数值来自一次 focused run：

| term | 首批 | 总耗时 | candidate scan | parse | validation |
|---|---:|---:|---:|---:|---:|
| `poll` | 254.161 ms | 3791.177 ms | 2001.003 ms | 843.990 ms | 920.691 ms |
| `cx` | 141.344 ms | 3308.999 ms | 1974.186 ms | 626.692 ms | 689.284 ms |
| `buf` | 352.039 ms | 3097.625 ms | 1959.845 ms | 521.532 ms | 600.450 ms |

```json
{"term":"poll","firstBatchMS":254.161334,"totalMS":3791.176709,
 "candidateScanMS":2001.002843,"parseMS":843.990253,
 "validationMS":920.690588,"verifiedIdentifierTotal":1020}
{"term":"cx","firstBatchMS":141.344084,"totalMS":3308.999042,
 "candidateScanMS":1974.185827,"parseMS":626.692169,
 "validationMS":689.284367,"verifiedIdentifierTotal":1657}
{"term":"buf","firstBatchMS":352.039000,"totalMS":3097.624917,
 "candidateScanMS":1959.844542,"parseMS":521.531547,
 "validationMS":600.449755,"verifiedIdentifierTotal":1713}
```

本 prototype 是直接 Swift byte scan，且同一 run 同时计算 insensitive/sensitive
对照；这些数值可作为可行性证据，不应直接冻结为产品 SLA。三项总耗时均低于现有
search 5s wall-clock，但余量最小只有约 1.18s，S3 仍需保留 cancellation/time partial。

---

## 2. 对 S3 的派发裁决

### 裁决：**现有设计不可原样派发；修改扫描顺序后可派发**

不接受：

```text
SnapshotSearchService.search(default query)
-> raw 200/5000 cap
-> parse / Resolver validation
```

因为真实 Tokio 已证明它会丢 427 个 `poll` 和 19 个 `buf` verified candidates。

建议最小设计：

```text
snapshot unique contents
-> exact-case byte presence prefilter（无 raw candidate 数量 cap）
-> candidate content parse exactly once
-> exact-name identifier-node verification
-> verified-result batching/cap/time limit
-> 若未扫完：N verified references · partial
```

- **不提高 raw cap**：提高到 10k/50k 只移动缺陷，还增加无效候选成本。
- **不保存 Tree / occurrences**：本次总耗时已证明 on-demand 路径可行；先不增加
  `ReferenceStore`、`ReferenceGraph`、数据库表或通用语言框架。
- 可复用现有 snapshot bytes、contentID 去重、batch/cancellation/completeness 语汇，
  **不能复用当前已经截断的 `search` 返回值作为候选 universe**。
- Rust symbol 查询必须显式 case-sensitive。
- verified cap 必须在语法过滤后；若因时间或 verified cap 停止，只报告 partial N。

## 3. 未能测得 / 限制

- **未能测得：无。** Q1–Q12 都取得真实响应或 prototype 运行结果。
- import alias 不是“未测得”，而是当前 RA build 的**实测覆盖缺口**。
- Fuzzy prototype 只承诺 syntax-verified heuristic，不做跨文件 binding identity；
  若产品要 Exact identity，应走 RA S4，不能把 Fuzzy 改名为 Exact。
- 延迟是当前机器单次样本；S3 实现后再用产品真实 snapshot/source 与 cancellation
  路径冻结预算。
- Exact References 当前 RA 不发送 partial progress，所以本文没有伪造 LSP streaming
  首批；first batch 等于完整响应。

## 4. 探针清理与最终工作树

丢弃型探针：

```text
.m7-spike-ra-probe.py
Tests/RustExtractorTests/M7FuzzySpikeTests.swift
```

均在形成本文后删除。未修改产品源码、`goldset/`、fixture、Package.swift 或既有计划。

最终核对：

```text
$ git rev-parse --short HEAD
4a1d22f

$ git reflog -2 --oneline
4a1d22f HEAD@{0}: commit: M7 状态交接：G0 门 PASS，S1 spike 进行中
cb2cbbb HEAD@{1}: commit: M7-G0: 门通过（16 PASS / 1 BLOCKED / 2 NOT RUN），S4 解锁

$ git status --short
?? docs/plans/m7-spike-findings.md

$ git diff -- goldset/
(empty)

$ git diff --name-status cb2cbbb..4a1d22f
A docs/plans/m7-status.md
```

开工时已实测 HEAD=`cb2cbbb` 且工作树干净；执行期间 HEAD 在 15:12:30 +0800
并发前进到 `4a1d22f`。本 spike 没有执行 commit/reset/checkout，也没有回退或改写
该外部 commit。最终工作树仍只有 findings 文档为新增，**本 spike 未 commit**。
