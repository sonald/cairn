# S11 — 文档与正式回归门禁：逐片记录

## docs 提交内容

- `docs/design.md`：
  - 当前实现事实更新为 2026-09-08：M10/M11 真实闭环 2026-09-01 复验 PASS（引用验收记录）；本轮稳定性修复轮（S1–S10）入列并链接计划与证据目录；签名/公证状态如实保留。
  - 「无 WebView」绝对表述改为 M14 局部受控 WKWebView 裁决（CSP/内链白名单/只读）。
  - F4.5 worktree 过滤按 M14 裁决改写：固定跳过目录之外的常规非 symlink 文件全部捕获，不按 `.gitignore` 过滤（文件树与 CLI 同规则）。
  - 新增 F5.5b（P0）：内容身份验证的语义导航 + 无损 Refresh Index 合同（live worktree 阅读、漂移检测、fallback 恢复、失败保留旧索引可重试）。
  - 里程碑表 M10/M11 状态更新；M11 注明 Reading Set 寿命受 tab 生命周期管理。
- `README.md` / `README.zh-CN.md` 同构新增：索引一致性（File changed since indexing + Refresh Index）与导入预选（Recents 偏好/文件名探测/JS 不误选 TS/手动优先）两条特性；既有结构与措辞不变。
- 本计划文件与全部切片证据随本提交入库。

## gates 提交内容

- `scripts/ci.sh`：`expected_main_test_count` 849 → 891，逐片累加注释（S1+6 … S10b+1）；隔离 BookmarkPanel 2 条契约不变。
- 未新增门禁通道：EOF/内容一致性关键回归均已进入主 swift test 通道（EOF 6 + 语义导航 5 + 刷新 6 等），M14 非源码真实入口验收由既有 `--self-test` 通道覆盖。

## 失败注入验证（门禁有效性）

1. 还原 S1 EOF 缺口（EOF 不注销 handler）→ `lspClientStopsStdout…` 等 3 处断言失败，门禁 FAIL。✅
2. 拆除 S2a 快路径身份验证（直接 commit）→ `semanticNavigationVerifies…` 等 5 处断言失败，门禁 FAIL。✅

## 自测脚本适配（记录，非削弱）

- S2a 使带偏移的导航经内容身份验证后异步提交；exact 自测两个步骤（feature-switch 后的 relations、relation-follow-context 前）此前隐式依赖"reader 仍停在 lib.rs"的同步时序，现按步骤意图显式 `selectFileInSidebar(relationFile)` 重建后再操作。
- S6 把完整 provenance 移入 tooltip；`selfTestContextProvenance` 改读完整来源（tooltip 优先），徽标内容断言（features: all 等）不变。

## 完整门禁运行（2026-09-09）

- `CODEX_SANDBOX=1 bash scripts/ci.sh`：**PASS**（main 891 + isolated 2 = 893；ByteUTF16Map 通道 PASS；自测 exact/diff/reading/projector/fold 全部 passed；release 构建 + fold perf 完成）。
