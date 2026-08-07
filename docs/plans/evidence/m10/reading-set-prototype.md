# M10 P0 Reading Set 原型结论

日期：2026-08-07。范围：布局探索，不进 M10 产品代码。

## 固定 trace fixture

原型固定为阅读 tokio `spawn`，同一条 trace 包含 5 段：definition、Verified caller、name-only Inferred caller、trait contract、test。每段保留 role、`path:line`、Verified/Inferred、snapshot/commit 与“查看证据”入口；A/B 只改变布局，不改变证据。

## 两种布局

- A（Relations 原地展开）：不离开当前位置，适合快速 peek；窄栏无法连续阅读多文件上下文，一次只适合一两段。
- B（`Open as Reading Set` 新 tab）：满宽连续呈现固定 trace；需要主阅读区支持非文件文档、状态恢复和 tab 生命周期。

## 决策

选择 **B 作为 M11 的目标形态**。它能兑现“沿一条有证据的路径读懂一个符号”，并与 Trail 的 `Open as Reading Set` 复用同一个非文件文档原语。A 只可作为独立的轻量 peek，不替代 Reading Set。

P0 到此结束：M10 不新增 Reading Set 类型、tab 或 `Sources/` 实现。M11 实现时，每段出处头中的 Verified/Inferred、commit 与“查看证据”均为硬要求。

## 验证

- `reading-set-prototype.html`：固定 fixture、A/B 对照与 Light/Dark/SI Classic 三主题均已覆盖。
- `prototype-decisions.md` D6 与 `semantics.md` §3.5：结论一致。
- `Sources/`：P0 零差异。
