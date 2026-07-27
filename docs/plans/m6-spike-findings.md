# M6 Spike Findings：真实 rust-analyzer 与绑定密度实测

> 日期：2026-07-27
>
> 基线：`922e084e061ad2dd02ff271ebc0f1bb570bcb3bf`
>
> rust-analyzer：`rust-analyzer 0.0.0 (cac0779549 2026-07-18)`
>
> 结论状态：Q1–Q4、Q6、Q7 已测得；Q5 的 `data` 值未能测得（当前 RA 不发送该字段）；
> 无 sandbox BLOCKED。

## 0. 方法与结果总览

本次没有经过 CodeInsight 的 `sandbox-exec`。丢弃型 Python 探针直接启动
`/opt/homebrew/bin/rust-analyzer`，通过 stdio 的 `Content-Length` LSP 帧通信；
最小 Cargo 项目无依赖，进程环境设 `CARGO_NET_OFFLINE=true`。LSP 行列均为
**0-based UTF-16**。

最小项目：

```rust
// src/a.rs
use crate::b::bar;

pub fn foo() -> i32 {
    let first = bar();
    let second = bar();
    first + second
}

// src/b.rs
pub fn bar() -> i32 {
    1
}
```

implementation fixture 有一个 `Runner::run` trait 方法和 `First`、`Second` 两个 impl。

执行记录：

```text
$ rust-analyzer --version
rust-analyzer 0.0.0 (cac0779549 2026-07-18)

$ python3 .m6-spike-ra-probe.py q1q2
exit 0, wall 1.2s

$ python3 .m6-spike-ra-probe.py q3
exit 0, wall 0.7s

$ python3 .m6-spike-ra-probe.py q4q5
exit 0, wall 1.6s
```

探针与 fixture 已在写完本文后删除；关键请求、响应与计数完整摘录如下。

| 问题 | 状态 | 一句话结论 |
|---|---|---|
| Q1 | PASS | incoming 的 ranges 属于 `from`；outgoing 的 ranges 属于请求源 item；必须把 callsite 文件物化进结果 |
| Q2 | PASS | 本版 RA 返回 `LocationLink[]`，两个 impl 就有两项 |
| Q3 | PASS | 本版 RA 不要求客户端先声明；两种 initialize 都 advertise `true` 且请求正常 |
| Q4 | PASS | 当前 RA 的旧 item 跨新进程可用；它不含 `data`，服务端用 URI + selectionRange 重定位 |
| Q5 | PARTIAL | Foundation 语义往返成功；但 `data` 专项未能测得，因为当前 RA 固定不发送 |
| Q6 | PASS | 5 个真实大文件为 86–355 refs/kLoC；10 万行高密合成 fixture 单次 parse 372.880ms |
| Q7 | PASS | 单 parse + 第二次 walk 可行；现有 `ContentIndex` 缺引用边，且不能逐 token 调现有 Resolver |

---

## Q1. Call Hierarchy 的 `fromRanges` 各自相对谁？

### 请求

```json
{
  "method": "textDocument/prepareCallHierarchy",
  "params": {
    "textDocument": {"uri": "file:///.../src/b.rs"},
    "position": {"line": 0, "character": 7}
  }
}
```

拿到 `bar` item 后：

```json
{
  "method": "callHierarchy/incomingCalls",
  "params": {"item": {"name": "bar", "uri": "file:///.../src/b.rs", "...": "..."}}
}
```

对 `foo` prepare 后：

```json
{
  "method": "callHierarchy/outgoingCalls",
  "params": {"item": {"name": "foo", "uri": "file:///.../src/a.rs", "...": "..."}}
}
```

### 1. incoming：ranges 落在 `relation.from` 的文件

响应耗时 5.0ms；`from.uri` 是 `a.rs`，两个 range 正好是 `foo` 中两次 `bar()`：

```json
{
  "result": [
    {
      "from": {
        "name": "foo",
        "uri": "file:///.../src/a.rs",
        "range": {
          "start": {"line": 2, "character": 0},
          "end": {"line": 6, "character": 1}
        },
        "selectionRange": {
          "start": {"line": 2, "character": 7},
          "end": {"line": 2, "character": 10}
        }
      },
      "fromRanges": [
        {
          "start": {"line": 3, "character": 16},
          "end": {"line": 3, "character": 19}
        },
        {
          "start": {"line": 4, "character": 17},
          "end": {"line": 4, "character": 20}
        }
      ]
    }
  ]
}
```

即 `a.rs` 的 1-based 第 4、5 行；range 覆盖 `bar` 三个字符。

### 2. outgoing：ranges 落在请求时传入的源 item 文件

响应耗时 0.4ms。返回的 `to.uri` 是 `b.rs`，但 ranges 仍是 `a.rs` 中 `foo` 的两处
调用：

```json
{
  "result": [
    {
      "to": {
        "name": "bar",
        "uri": "file:///.../src/b.rs",
        "selectionRange": {
          "start": {"line": 0, "character": 7},
          "end": {"line": 0, "character": 10}
        }
      },
      "fromRanges": [
        {
          "start": {"line": 3, "character": 16},
          "end": {"line": 3, "character": 19}
        },
        {
          "start": {"line": 4, "character": 17},
          "end": {"line": 4, "character": 20}
        }
      ]
    }
  ]
}
```

因此把 outgoing 的 `fromRanges` 套到 `relation.to.uri` 会稳定跳错文件。

### 3. 同一 caller、多个 callsite 的聚合形态

是 **1 条 relation + 2 个 range**，不是两条 relation：

```text
incoming relation count = 1
incoming relation[0].fromRanges count = 2
outgoing relation count = 1
outgoing relation[0].fromRanges count = 2
```

### 4. 结论与最小类型

不要把原始 `fromRanges` 与“另一端 item”无文件信息地绑在一起。解析响应时就用正确的
base file 把 range 起点转成已有的 `ExactLocation`：

```swift
public struct ExactCallRelation: Sendable {
    /// incoming 时是 caller；outgoing 时是 callee。
    public let item: ExactCallHierarchyItem

    /// 已物化文件身份的调用处；不再依赖方向猜 range 属于谁。
    public let callSites: [ExactLocation]
}
```

- incoming：用每条 `relation.from.uri` 解释其 `fromRanges`。
- outgoing：用发起 `outgoingCalls` 的源 item URI 解释所有 `fromRanges`。
- 当前 Relations 导航只消费 path + byteOffset/line，已有 `ExactLocation` 足够；
  不为暂时没有消费者的 range end 新增类型。

---

## Q2. RA 的 `textDocument/implementation` 返回哪些形态？

### 请求

trait 中方法名 `run` 位于 0-based `1:7`：

```json
{
  "method": "textDocument/implementation",
  "params": {
    "textDocument": {"uri": "file:///.../src/implementations.rs"},
    "position": {"line": 1, "character": 7}
  }
}
```

### 1–2. 实际形态与多实现

响应耗时 0.7ms，实际为 **`LocationLink[]`，长度 2**：

```json
{
  "result": [
    {
      "originSelectionRange": {
        "start": {"line": 1, "character": 7},
        "end": {"line": 1, "character": 10}
      },
      "targetUri": "file:///.../src/implementations.rs",
      "targetRange": {
        "start": {"line": 7, "character": 4},
        "end": {"line": 9, "character": 5}
      },
      "targetSelectionRange": {
        "start": {"line": 7, "character": 7},
        "end": {"line": 7, "character": 10}
      }
    },
    {
      "originSelectionRange": {
        "start": {"line": 1, "character": 7},
        "end": {"line": 1, "character": 10}
      },
      "targetUri": "file:///.../src/implementations.rs",
      "targetRange": {
        "start": {"line": 15, "character": 4},
        "end": {"line": 17, "character": 5}
      },
      "targetSelectionRange": {
        "start": {"line": 15, "character": 7},
        "end": {"line": 15, "character": 10}
      }
    }
  ]
}
```

### 3. `targetSelectionRange` 与 `targetRange`

- `targetRange` 是整个 impl method：第一项覆盖 0-based `7:4` 到 `9:5`。
- `targetSelectionRange` 只覆盖方法名 `run`：`7:7` 到 `7:10`。
- 跳转落点应取 `targetSelectionRange.start`；`targetRange` 是展示/高亮整个定义的范围。

### 4. 解析器结论

需要覆盖 LSP 允许的全部结果：

1. `null`
2. 单个 `Location`：`uri + range`
3. `Location[]`
4. `LocationLink[]`：`targetUri + targetSelectionRange`，必要时才回退 `targetRange`

数组必须逐项解析并全部返回，不能再像现有 definition parser 一样只取第一项。
本次没有观察到单个 `LocationLink`（规范结果也把 link 定义为数组），无需为未出现的
第五种形态造分支。

---

## Q3. 不声明客户端能力，RA 还会响应吗？

### 两种 initialize 请求

未声明：

```json
{
  "capabilities": {
    "textDocument": {
      "definition": {"linkSupport": true}
    },
    "window": {"workDoneProgress": true},
    "workspace": {"configuration": true}
  }
}
```

声明：

```json
{
  "capabilities": {
    "textDocument": {
      "definition": {"linkSupport": true},
      "implementation": {"linkSupport": true},
      "callHierarchy": {}
    },
    "window": {"workDoneProgress": true},
    "workspace": {"configuration": true}
  }
}
```

### 1. initialize 响应

两种情况下服务端都返回：

```json
{
  "capabilities": {
    "implementationProvider": true,
    "callHierarchyProvider": true
  }
}
```

本轮单次耗时：

| 客户端声明 | initialize | prepareCallHierarchy | incomingCalls | implementation |
|---|---:|---:|---:|---:|
| 不声明 | 0.5ms | 7.1ms | 0.3ms | 0.2ms |
| 声明 | 5.0ms | 10.9ms | 0.3ms | 0.2ms |

这些是正确性探针的一次样本，不是性能比较。

### 2. 不声明时直接请求

三个请求都正常返回非空 result：

```text
prepareCallHierarchy: result[0].name = "bar"
incomingCalls: result[0].from.name = "foo"
implementation: result.count = 2
JSON-RPC error: none
```

没有 `null`，也没有错误码。

### 3. 结论

对 **当前 rust-analyzer build**，客户端能力声明不是请求成功的硬前置；server
capabilities 也不因缺少声明而隐藏。仍建议在 M6 initialize 中声明：

- 表达客户端能消费 `LocationLink`/call hierarchy；
- 避免依赖 RA 当前宽松行为；
- 但测试不要把“声明了”误写成“RA 才会响应”的因果。

---

## Q4. helper 崩溃重启后，旧 CallHierarchyItem 会怎样？

### 实测流程

```text
old rust-analyzer PID = 98278
prepare bar item: 3 attempts（早期空结果后成功）
SIGKILL old PID
new rust-analyzer PID = 99176
新 session didOpen 全部文件
把旧 item 原样发给 callHierarchy/incomingCalls
```

旧 item：

```json
{
  "name": "bar",
  "kind": 12,
  "detail": "pub fn bar() -> i32",
  "uri": "file:///.../src/b.rs",
  "range": {
    "start": {"line": 0, "character": 0},
    "end": {"line": 2, "character": 1}
  },
  "selectionRange": {
    "start": {"line": 0, "character": 7},
    "end": {"line": 0, "character": 10}
  }
}
```

注意：**没有 `data` 字段**。

### 1. 新 session 响应

第 2 次 readiness 重试成功，最终请求耗时 16.4ms，返回结果正确：

```json
{
  "result": [
    {
      "from": {
        "name": "foo",
        "uri": "file:///.../src/a.rs"
      },
      "fromRanges": [
        {
          "start": {"line": 3, "character": 16},
          "end": {"line": 3, "character": 19}
        },
        {
          "start": {"line": 4, "character": 17},
          "end": {"line": 4, "character": 20}
        }
      ]
    }
  ]
}
```

不是报错、空结果或错误 caller。

### 2. `data` 在新 session 是否有意义

**未能测得 `data` 的跨 session 语义，因为本版 RA 根本不生成它。**

这不是 fixture 偶然：当前 RA 的 `call_hierarchy_item` 转换明确构造
[`data: None`](https://fuchsia.googlesource.com/third_party/github.com/rust-lang/rust/+/8cc4de631b3af60d558a1b5b6195ab82b2ea2261/src/tools/rust-analyzer/crates/rust-analyzer/src/lsp/to_proto.rs)，
incoming/outgoing handler 则从传回 item 的 `uri + selectionRange` 重建位置。

### 3. 模型结论

对本次验证的 RA：

- helper 重启后不必强制重新 prepare；
- 不需要新增 session nonce/token；
- Coordinator 继续用已有 generation/content identity 防止文档变化后的旧坐标复用即可；
- 若重启后返回 invalid/empty，可有界重试 prepare，不能把它先验设计成新公共实体。

如果未来升级 RA 后开始出现非空 `data`，必须重跑本题；本文不把当前行为外推给任意
LSP server。

---

## Q5. `data` 经 JSONSerialization 往返后还能用吗？

### 1. RA 的真实 `data` 样本

**未能测得：字段缺失。** 本次 `bar`、`foo`、incoming 的 `from`、outgoing 的 `to`
四类 item 都不含 `data`；当前 RA 源码也固定为 `data: None`。

因此不存在可贴的非空 `data` 样本，不能编造一个替代品。

### 2. Foundation 语义往返实测

仍对**完整 item**执行了与产品一致的 Foundation `JSONSerialization`：

原 JSON：

```json
{"name":"bar","kind":12,"detail":"pub fn bar() -> i32","uri":"file:///.../src/b.rs","range":{"start":{"line":0,"character":0},"end":{"line":2,"character":1}},"selectionRange":{"start":{"line":0,"character":7},"end":{"line":0,"character":10}}}
```

`JSONSerialization` 解析后以 `.sortedKeys` 重序列化：

```json
{"detail":"pub fn bar() -> i32","kind":12,"name":"bar","range":{"end":{"character":1,"line":2},"start":{"character":0,"line":0}},"selectionRange":{"end":{"character":10,"line":0},"start":{"character":7,"line":0}},"uri":"file:\/\/\/...\/src\/b.rs"}
```

可见键序变化、`/` 的转义变化，字节显然不同。把重序列化 item 发给新 RA session：

```text
semanticRoundtripAttemptCount = 1
elapsedMs = 0.2
result[0].from.name = "foo"
result[0].fromRanges.count = 2
```

### 3. 结论

- 对当前 RA item，语义往返足够；原始字节、键序、斜杠转义都不需要保留。
- 观察到的数字只有 symbol kind 与 LSP 行列，均为小整数；没有证据要求特殊整数处理。
- `data` 专项仍是 **未能测得**，不能据此宣称任意未来 opaque JSON 都安全。
- RA-only 的 M6 不需要为了当前不存在的 `data` 新增公共模型字段。若仍选择做通用 LSP
  保真层，保存可重序列化的语义 JSON 值即可，并在首次观察到非空 `data` 时加真实互操作
  测试；不要测逐字节一致。

---

## Q6. 真实 Rust 文件的引用密度

### 语料与计数口径

指定目录存在，版本齐全：

```text
.../corpora/ripgrep-14.1.1
.../corpora/tokio-tokio-1.47.1
```

丢弃型 Swift probe 运行：

```text
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/swift-module-cache \
swift test --disable-sandbox --filter m6SpikeReferenceDensity

build exit 0
test exit 0
focused test elapsed 29.781s
```

口径：

- 行数：LF 数，与本轮 `wc -l` 一致。
- binding：真实 `RustExtractor` 产生的 `.param + .letBinding + .patternBinding`。
- reference：现有 tree-sitter tree 中的 `identifier` / `self` /
  `shorthand_field_identifier`，按 Resolver 的“最内 scope + 同名 + param 始终可见 /
  非 param 声明在使用前 + 最近声明优先”规则绑定；**排除 declarationRange 自身**。
- 所有 5 个样本 `tree.rootNode.hasError == false`。
- 这是当前 extractor 能覆盖的 syntactic local/param 口径；macro token tree 内部仍是
  partial，不冒充完整 Rust 语义。

### 1. 5 个真实样本

| 语料 / 文件 | 行数 | local+param bindings | refs（不含声明） | bindings/kLoC | refs/kLoC | 单文件 tree-sitter parse |
|---|---:|---:|---:|---:|---:|---:|
| ripgrep `crates/core/flags/defs.rs` | 7,675 | 1,625 | 1,472 | 211.7 | 191.8 | 52.949ms |
| ripgrep `crates/printer/src/standard.rs` | 3,842 | 589 | 1,215 | 153.3 | 316.2 | 26.685ms |
| ripgrep `crates/ignore/src/walk.rs` | 2,310 | 439 | 821 | 190.0 | 355.4 | 17.189ms |
| tokio `tokio/src/net/windows/named_pipe.rs` | 2,692 | 160 | 232 | 59.4 | 86.2 | 12.133ms |
| tokio `tokio/src/net/udp.rs` | 2,205 | 164 | 221 | 74.4 | 100.2 | 11.635ms |

原始分项计数示例：

```json
{
  "path": "crates/ignore/src/walk.rs",
  "lineCount": 2310,
  "localAndParamBindings": 439,
  "paramBindings": 226,
  "letBindings": 122,
  "patternBindings": 91,
  "referencesExcludingDeclarations": 821,
  "paramReferences": 405,
  "letReferences": 325,
  "patternReferences": 91,
  "referencesPerKLoC": 355.4112554112554,
  "containsErrorNodes": false
}
```

### 2. 每千行密度

```text
总行数 = 18,724
总 bindings = 2,977
总 references = 3,961

按总行数加权：
bindings = 158.99 / kLoC
references = 211.55 / kLoC

5 文件中位数：
bindings = 153.31 / kLoC
references = 191.79 / kLoC

实测范围：
references = 86.18 ... 355.41 / kLoC
```

### 3. 10 万行 fixture 建议

选**确定性合成**，不拼接真实文件：

- 拼接上游源码会引入版权文本、版本漂移、重复 item/inner attribute 等无关变量。
- 合成模板能把 binding/reference 数写成硬断言，避免第二次出现“10 万空行守空气”。
- 压测密度取接近本轮高位样本，而不是中位数：**200 bindings/kLoC +
  350 references/kLoC**。

本次实际构造：

```text
1,000 个唯一函数 × 100 行 = 100,000 行
每函数：2 params + 18 lets = 20 bindings
每函数：35 个 resolved local/param uses
其余 79 行为确定性 Rust 注释 padding

总 bindings = 20,000
总 references = 35,000
文件大小 = 3,062,890 bytes
```

模板核心：

```rust
fn fixture_0(p0: u64, p1: u64) -> u64 {
    let v0 = p0 + p1;
    let v1 = v0 + p0;
    // ... v2 到 v16，每行两个引用
    let v17 = 0;
    v16
}
// 79 行 deterministic density padding
```

另用小型正确性 fixture 守 destructuring、shadowing、match/for、closure 即可；不要把
所有语义角落塞进巨档、也不要新增 fixture 生成框架。

### 4. tree-sitter parse 基线

运行：

```text
swift test --disable-sandbox --filter m6SpikeSyntheticFixtureParseBaseline

build exit 0
test exit 0
test elapsed 5.154s
```

其中只计一次 `Parser.parse(bytes)` 的原始计时：

```json
{
  "bindingsPerKLoC": 200,
  "bytes": 3062890,
  "containsErrorNodes": false,
  "functionCount": 1000,
  "lineCount": 100000,
  "localAndParamBindings": 20000,
  "referencesExcludingDeclarations": 35000,
  "referencesPerKLoC": 350,
  "singleTreeSitterParseMs": 372.879667
}
```

这是一次基线样本，不应直接变成跨机器绝对门；但它证明在这台机上“无意重 parse”
会平白增加约 **373ms**，S5 的“零额外 full-file parse”有可测价值。

---

## Q7. 复用 extractor binding 规则的最小入口

### 1. 接受已解析 `Tree` 的最小改动面

当前链路：

- `RustHighlighter.highlight` 在 `CodeInsightReaderCore.swift:313-327` 创建 parser、
  parse 一次并 walk tree。
- `RustExtractor.extractWithDiagnostics` 在 `RustExtractor.swift:20-64` 自己再创建 parser、
  parse 一次并 walk。
- `CodeInsightReaderCore` 已直接依赖 `CodeInsightRustExtractor`、`TreeSitterKit`、
  `CTreeSitterRust`（`Package.swift:151-158`），**无需新增 target/dependency**。

最小产品改动应只碰：

1. `RustExtractor.swift`
   - 把 `extractWithDiagnostics(bytes:)` 拆成薄 parse wrapper + 接受现成 `Tree` 的 walk
     入口；
   - 现有 API parse 后委托新入口，保持 CLI/indexer 行为不变；
   - Reader 使用 tree 入口，不再 parse 整个文件。
2. `RustScopeBuilder.swift`
   - 在现有 scope/pattern walk 中，给 local/param binding 记录使用 ranges；
   - 用 binding 数组下标作为 identity，产出
     `referencesByBinding: [[ByteRange]]`（与 `bindings` 同下标），无需新增
     `BindingReference` 实体。
3. `CodeInsightReaderCore.swift`
   - 让 `RustHighlighter` 在现有一次 parse 后，先做原有高亮 walk，再把同一个 `Tree`
     交给 extractor 的 binding/reference walk；
   - 把结果直接变成 Reader 需要的样式 spans/lookup，不把整份 Engine `ContentIndex`
     长期挂在 `ReaderDocument`。
4. 对应的 extractor/ReaderCore 小测试。

不需要改 `Package.swift`，不需要新增 parser/highlighter abstraction，也不需要让
ReaderCore 依赖 `CodeInsightEngine`。

严格“禁止第二次 parse”还有一个现有陷阱：`RustExtractor.traverse` 在
`RustExtractor.swift:111-135` 遇到 item-position macro 会调用 `macroBody`，后者在
`:163-180` 对 token-tree fragment 再次 `parser.parse`。因此 Reader 的
local-reference 入口必须**跳过 macro fragment reparse**，并沿用现有
macro partial/unsupported 标注；否则即使复用了 root `Tree`，也不能宣称 parse 次数为零
增量。现有 CLI/indexer 全量入口可保持原宏行为。

### 2. 现有产物能否直接回答某 binding 的所有引用？

不能。

`BindingRecord` 只有：

```text
scopeID / localNameID / space / kind / declarationRange / targetHint
```

缺少：

- 每个 identifier use 的 range；
- use → binding index 的边；
- 供批量解析使用的 active scope / shadowing lookup。

`RustScopeBuilder` 已正确识别 parameter、self、closure param、let destructuring、
match/for/let-condition 等声明（`RustScopeBuilder.swift:194` 起），但输出止于声明。

Reader 现有 `identifierOccurrences` 只是同名词法扫描，不能区分：

- 内外层 shadowing；
- 同名 field/type/function；
- 声明前后的 binding；
- 不同函数中的同名 local。

它不能作为 S5 semantic fixture 的实现。

### 3. 最小可行复用方案；第二次 walk、零第二次 parse 是否可行

**可行。**

在高亮器持有同一 `Tree` 的生命周期内：

```text
Parser.parse(bytes)                  1 次
├─ 现有 highlight/outline walk       第 1 次 walk
└─ extractor binding/reference walk  第 2 次 walk
```

第二次 walk 继续用 `RustScopeBuilder` 的 scope/pattern 规则，并在 source order 中维护
每个 active scope 的“当前 name → binding index”。这样：

- param 在函数体开始前已可见；
- let/pattern 只在声明规则允许后加入；
- 内层/后声明同名 binding 覆盖外层/早期 binding；
- 每个 reference 直接追加到对应 binding index，线性完成；
- 不需要逐 token 扫描全体 scopes/bindings。

不能直接把每个 token 丢给现有 `EngineSession.resolve`：

1. `Resolver.locatedName` 先看 `index.calls`，而 `RustCalls` 把 `UnresolvedCall.range`
   记录成**整个 call_expression**。因此函数参数中的 local identifier 会被外层 callee
   匹配吞掉。
2. 本次真实数据交叉计数：

   | 文件 | `EngineSession.resolve` 逐 token 认出的 refs | scope/declaration rule refs |
   |---|---:|---:|
   | ripgrep `defs.rs` | 571 | 1,472 |
   | ripgrep `standard.rs` | 171 | 1,215 |
   | ripgrep `walk.rs` | 206 | 821 |
   | tokio `named_pipe.rs` | 83 | 232 |
   | tokio `udp.rs` | 10 | 221 |

3. 把 `Resolver.swift:374-415` 的数组全扫描原样用于 10 万行 bulk walk 也是
   `tokens × (scopes + bindings)`；探针超过 120 秒仍未完成，已中止。应利用 tree walk
   的 active scope 状态线性产边，而不是新增缓存/索引框架。

所以最小答案是：**复用 `RustScopeBuilder` 的第二次 walk，在 builder 内顺手产出
binding-indexed ranges；不要复写高亮器里的 binding parser，不要逐 token 调现有
Resolver，不要第二次 parse。**

---

## 无法回答 / 监工真机补测

### BLOCKED

无。虽然 CodeInsight 的 sandbox RA 测试路径在本环境会遇到
`sandbox-exec: Operation not permitted`，本 spike 已用裸 stdio RA 进程绕过并拿到真实
响应，不需要监工补跑 Q1–Q4。

### 未能测得但不是环境 BLOCKED

Q5 的非空 `data`：当前 RA build 不生成该字段，源码也固定 `data: None`。换到未来
出现非空 `data` 的 RA 后，监工可重跑同一互操作流程；在那之前没有真实命令能凭空制造
“RA 给的 data”。

---

## 探针清理与最终工作树

丢弃内容包括：

- `.m6-spike-ra-probe.py`
- `.m6-spike-ra-fixture/`
- `Tests/RustExtractorTests/M6SpikeReferenceDensityTests.swift`

最终核对见本文写完后的命令：

```text
$ git status --short
?? docs/plans/m6-plan.md
?? docs/plans/m6-spike-findings.md
?? docs/plans/m6-spike.md
```

与初始状态相比，唯一新增交付物是 `docs/plans/m6-spike-findings.md`；未改产品代码，
未 commit。

---

## 额外发现（影响 M6 设计）

1. **现有 Resolver 不是 local-reference bulk API。** 整个 call-expression range 会遮住
   参数 identifier；若 S5 用它验收，会系统性漏计并假绿。
2. **现有 Resolver 的单点查找复杂度不适合 10 万行全量着色。** 第二次 tree walk 应利用
   active scope 线性产边。
3. **复用 root Tree 不自动等于零 parse。** extractor 还会对 item macro token tree 做
   fragment parse；Reader local-reference 路径必须跳过并诚实标 partial。
4. **Q1 推翻 v3 的 `item + raw ranges`。** 方向无关模型必须保存已物化 file 的
   callsites，否则 outgoing 必错。
5. **当前 RA 的 CallHierarchyItem 不是 session handle。** 它无 `data`，跨新进程可用；
   session nonce 在当前产品范围内是无证据实体。
