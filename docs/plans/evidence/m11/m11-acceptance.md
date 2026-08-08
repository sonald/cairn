# M11 分片验收记录

日期：2026-08-08。状态：进行中。

## 实现基线

- `M11_BASE=2569e70486e93cc3e547201de1c80657d98f0adf`
- 该提交包含 M11 v15 计划；P0 原型证据从其后开始纳入 M11 变更域。
- 后续 V0 对 `M11_BASE...HEAD`、index、worktree 与 untracked 四个域执行完整审计。

## P0：三主题 HTML 原型与裁决

结论：PASS。

- 交互原型：`p0-prototype.html`。
- 裁决记录：`prototype-decisions.md`；D1–D5 已由用户确认，没有遗留待选项。
- 三主题截图：`p0-light.png`、`p0-dark.png`、`p0-si.png`，均为 1265×5947 完整页面。
- 浏览器 AX 快照可发现 Light / Dark / SI Classic 三个按钮，以及折叠 chip、折叠柄、高度档、
  Palette、作用域头、Reading Set 和 Folding 菜单各区。
- 主题切换后逐项实测全部 `.win` 应用对应的 `t-light` / `t-dark` / `t-si` class。
- `swift test --disable-sandbox`：PASS，437 / 437。
- `Sources/` 零差异；本片只落计划基线与 P0 证据。

F2 必须另行提供真实 AppKit 三主题截图、AX 与交互证据；P0 HTML 截图不替代产品验收。
