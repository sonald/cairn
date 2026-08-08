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

## F0：`FoldRegion` 提取与传输 seam

结论：PASS（F0 数据层与候选消解门禁）。

- 新增七类 package 级折叠模型；候选来自 highlighter 既有 parse / walk，没有引入第二次解析。
- 逐类断言 header/body 语法节点边界；单个跨行 `use` / attribute / block comment、空 body
  与无花括号 closure 均不产出 region，连续节点按完整节点 extent 合并。
- 候选以完整 winner tuple 排序后贪心接受；固定种子置换结果逐字段一致。三组已知交叠胜者、
  真重复去重、矛盾摘要整组拒绝、laminar 复验及无空洞 `FoldID` 均有断言。
- `public RustHighlighter.highlight` 与 `ReaderDocument` 原签名不变；package 路径承载 folds。
  `DocumentLoader.load` 和 detached `loadSyntax` 均实测收到折叠数据；observer 在 completion 前
  写入且只收到一份完整样本，默认 nil observer 仍由完整回归覆盖。
- 固定 fixture：`m11-fold-perf-v1`，SHA-256
  `86bf0fac91bd7556b2ea49b9a6426d3d31de17cf1d81491972500371761f9578`，3,115,800 bytes，
  50,000 个换行；生产消解实测 8,400 candidates / 8,400 accepted，kind/depth 分布与 manifest 一致。
- Release 候选消解：28.722 ms，门禁 `≤ 500 ms`，PASS。该计时仅覆盖排序、去重、
  laminar 接受与 FoldID 分配，不包含 parse、summary、DocumentLoader 或 TextKit。
- `swift test --disable-sandbox`：PASS，444 / 444。
- `bash scripts/provision-corpora.sh --check`：PASS；Tokio `be8ee45`（720 files）、
  ripgrep `4649aa9`（98 files），Cargo offline check 通过。
- `TOKIO_TAG` / `TOKIO_DIR` / `TOKIO_REPO` 及对应 `RIPGREP_*` 常量相对 `M11_BASE`
  逐字节不变；M10、CanonicalDump、gold 与
  Prototypes 受保护路径零差异。

F2 仍须在真实 reducer/projector 就位后补齐 `codeinsight-app` control/fold 双进程 runner、
首次折叠延迟、峰值内存、真实布局参数与最终 app JSON；本片不以 resolver 微基准冒充该 UI 门禁。
