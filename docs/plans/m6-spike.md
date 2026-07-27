# M6 Spike：用真实 rust-analyzer 问清 7 个设计问题（丢弃型）

**这是 spike，不是实现片。** 产出是**一份答案文档**，不是产品代码。

仓库：/Users/siancao/work/ai/vibecoding/codeinsight，**基线 HEAD = `922e084`**，工作树只有
未跟踪的 `docs/plans/m6-plan.md`（已冻结）与本文件。

## 为什么做 spike

M6 计划三轮评审共 **18 条 P1 全部属实**，越往后越深。根因不是文档打磨不够，而是
**规划阶段做了本该由实测决定的决策**。典型：v3 给 S5/S6 定了内存门，但指定的
`huge.txt` 是 200 行 `needle` + 99799 个空行、**零 Rust 代码**
（`CodeInsightApp.swift:4870`）——S5/S6 完全不运行也能通过。

下面 7 个问题**只能问真实 rust-analyzer 或实测代码**，读我们自己的源码想不出来。

## 硬性约束

- **产出是 `docs/plans/m6-spike-findings.md`**，回答下列每一个问题，**每条附实测证据**
  （请求/响应 JSON 片段、日志、计数、耗时）。
- **允许写丢弃型探针代码**（临时测试、临时可执行、临时脚本），但：
  - **不改任何产品代码语义**；探针用完**必须还原**，最终 `git status` 只应有
    `docs/plans/m6-spike-findings.md` 是新增
  - **不 commit**
- **答不出来就写"未能测得 + 原因 + 建议的后续办法"**，**绝不许编**。
  （本项目铁律⑧：复现不了就如实报告。M5 里编过一次根因，被验证实验推翻。）
- **你的环境 `sandbox-exec: Operation not permitted`，真实 RA 测试会 skip。**
  若某问题必须真机跑，**明确标 BLOCKED 并写清"监工需要跑什么命令、看什么输出"**，
  监工会在真机补测（这台机器装了 rust-analyzer 且 sandbox 可用）。
  **优先想办法绕过**：例如直接用 `LSPClient` 对 RA 裸进程通信（不经 sandbox），
  或用 `--offline` 的最小 cargo 项目——只要能拿到真实 RA 的响应即可。

---

## Q1. Call Hierarchy 的 `fromRanges` 各自相对谁？（最关键）

评审指出：**incoming 的 `fromRanges` 相对 `relation.from`，而 outgoing 的 `fromRanges`
相对"请求时传入的源 item"，不是 `relation.to`**。若统一保存 `item + raw ranges`，
outgoing 的调用点会被错误映射到被调用者文件。

**要测**：造一个含跨文件调用的最小 Rust 项目（如 `a.rs` 的 `foo()` 调用 `b.rs` 的 `bar()`，
且 `foo` 内**调用 `bar` 两次**），对 `bar` 查 incomingCalls、对 `foo` 查 outgoingCalls。

**回答**：
1. incoming 响应里 `fromRanges` 的行列，落在**哪个文件**的哪一行？贴 JSON。
2. outgoing 响应里 `fromRanges` 的行列，落在**哪个文件**？贴 JSON。
3. 同一 caller 有多个 callsite 时，是**一条 relation 带多个 range**，还是多条 relation？
4. **结论**：`ExactCallRelation` 应该怎么存才能让"跳到调用处"永远跳对？
   给出你建议的最小类型定义。

## Q2. RA 的 `textDocument/implementation` 返回哪些形态？

现有 definition parser 对数组**只取第一项**（`RustAnalyzerProvider.swift:526`），
且未处理 `LocationLink[]`。

**要测**：对一个有**多个 impl** 的 trait 方法查 implementation。

**回答**：
1. 实际返回的是 `Location`、`Location[]`、`LocationLink[]` 还是 null？贴 JSON。
2. 多个实现时是否真的返回多项？
3. `LocationLink` 若出现，它的 `targetSelectionRange` 与 `targetRange` 差别是什么？
4. **结论**：解析器需要覆盖哪几种形态？

## Q3. 不声明客户端能力，RA 还会响应吗？

现状 initialize 只声明 `textDocument.definition`（`LSP.swift:237`）。

**要测**：分别在「不声明」与「声明 `textDocument.implementation` +
`textDocument.callHierarchy`」两种 initialize 下，发同样的请求。

**回答**：
1. 不声明时，RA 的 `initialize` 响应里 `implementationProvider` / `callHierarchyProvider`
   是什么值？
2. 不声明时直接发请求，RA 是正常响应、返回 null、还是报错（错误码多少）？
3. **结论**：客户端能力是必须声明，还是可选？

## Q4. helper 崩溃重启后，旧 CallHierarchyItem 会怎样？

评审指出 `.exact(item)` 缺 session nonce：同一 generation 内 helper 重启会产生新
session，旧 item 直接重发会怎样？

**要测**：拿到一个 item → 杀掉 RA 进程 → 让它重启 → 用旧 item 发 incomingCalls。

**回答**：
1. RA 报错还是返回空还是返回错误结果？贴响应。
2. `data` 字段在新 session 里还有意义吗？
3. **结论**：是必须重新 `prepareCallHierarchy`，还是旧 item 可安全重用？
   如果必须重来，我们的模型里最小需要什么（session token？还是 Coordinator 持有 handle？）

## Q5. `data` 字段经 JSONSerialization 往返后还能用吗？

`LSP.swift:91` 用 `JSONSerialization`，**原始 JSON 字节已丢失**，只能语义往返。

**要测**：把 RA 给的 item 原样（经我们的解析→重新序列化）回传，看服务端认不认。

**回答**：
1. RA 给的 `data` 实际长什么样？贴一个真实样本。
2. 经 `JSONSerialization` 解析再重新序列化后回传，incomingCalls 是否正常工作？
3. **结论**：语义往返够不够？有没有需要特殊保留的类型（如整数精度、键序）？

## Q6. 真实 Rust 文件的引用密度是多少？（定 S5/S6 的 fixture 与阈值）

现有 `huge.txt` 零 Rust 代码，**不能守 S5/S6**。需要真实数据来设计新 fixture。

**要测**：在 tokio 1.47.1 与 ripgrep 14.1.1 里选几个**真实的大文件**（≥2000 行），
统计其中 local/param 绑定数与引用（identifier occurrence）数。
语料路径：`/private/tmp/claude-501/-Users-siancao-work-ai-vibecoding-codeinsight/07b4a1d2-8dd6-49a2-b70b-f8f19bfd9226/scratchpad/corpora/`
（若不存在则如实报告，改用本仓库自己的大文件如 `CodeInsightApp.swift` 的 Rust 等价物；
Rust 语料缺失就明说）。

**回答**：
1. 典型大文件的行数 / local+param 绑定数 / 引用总数各是多少？给 3-5 个样本。
2. 每千行大约多少个 local/param 引用？
3. **结论**：一个能真正压测 S5/S6 的 10 万行 Rust fixture 该怎么造？
   （建议：合成 vs 拼接真实文件？绑定密度取多少？）
4. **顺带**：用你造的 fixture 跑一次 tree-sitter parse，报解析耗时——
   这是 S5"零额外解析"要守的基线。

## Q7. 复用 extractor 的 binding 规则，最小入口长什么样？

评审指出：`RustScopeBuilder` 已有完整 scope/pattern 逻辑（`RustScopeBuilder.swift:40`），
Resolver 处理 shadowing 与声明顺序（`Resolver.swift:391`）；而 `CodeInsightReaderCore`
**已经依赖 `CodeInsightRustExtractor`**（`Package.swift:151`）。
v3 计划里"在 RustHighlighter 里顺带实现绑定解析"= **复写一遍解析器**，
且会被现有词法扫描 `identifierOccurrences`（`CodeInsightReaderCore.swift:170`）冒充。

**要答（这题偏读码分析，不必跑 RA）**：
1. 给 extractor 加一个**接受已解析 `Tree` 的入口**（避免第二次 parse）需要动哪些地方？
   列出最小改动面。
2. 现有 `RustScopeBuilder` 的产物能否直接回答"文件内某 local/param 的所有引用位置"？
   缺什么？
3. **结论**：最小可行的复用方案是什么？允许第二次 tree walk 但禁止第二次 parse——
   这个约束下可行吗？

---

## 完成后报告

写入 `docs/plans/m6-spike-findings.md`，逐条回答 Q1–Q7，**每条附实测证据**。
末尾列出：
- **哪些问题你环境答不了**、监工需要在真机跑什么（给出可直接执行的命令）
- 探针代码是否已全部还原（`git status` 输出）
- 你在过程中发现的、我没问到但影响 M6 设计的事实
