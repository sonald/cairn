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

## F1：单遍 projector 与 `DisplayMap`

结论：PASS（零可见 UI 变化）。

- `DisplayMap.swift` 是 ReaderUI 唯一持有 `ByteUTF16Map` 的文件；source → display、
  display → source、range projection、复制用 source ranges 与 viewport 用 visible source ranges
  均由同一份 segment/prefix 数据回答。
- projector 从同一次 map 构造取得 projected string，并据此建立 attributed storage；map 与 storage
  同源安装。无折叠时文本、UTF-16 长度、每个合法 byte/display 边界，以及 highlight、outline、
  local reference、line-start 四类坐标与旧路径一致。
- 折叠命题通过：可见位置往返；隐藏 byte → `FoldID`；U+FFFC → placeholder `FoldID`；
  `project` 的 visible ranges 升序且不交叠；复制 range 展开隐藏 body，而 viewport range 在
  placeholder 处为空且不含隐藏 body。
- 非法输入均返回 nil：source/display 越界、UTF-8 scalar 中间、UTF-16 surrogate 中间及非法 range。
- 原 22 个 ReaderUI 换算点全部迁移；精确门禁
  `ByteUTF16Map|byteUTF16Map`（排除且只排除 `DisplayMap.swift`）零命中。该门同时进入
  `ci.sh`、`run-gold-gates.sh` 与具名 `--self-test-projector` 工作流。
- `--self-test-projector`：PASS；identity、folded length、单 placeholder、双向定位、复制展开、
  viewport 跳过隐藏源码全部为 true。
- `swift test --disable-sandbox`：PASS，446 / 446。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；既有 exact / diff / reading 与新增 projector
  self-test 全部通过。
- `CODEX_SANDBOX=1 bash scripts/run-gold-gates.sh`：PASS；Tokio 17 条、ripgrep 16 条，
  unexpected failures 均为 0。
- TextKit 复核依据：Apple
  [`NSTextContentStorage.offset(from:to:)`](https://developer.apple.com/documentation/appkit/nstextcontentstorage/offset%28from%3Ato%3A%29)
  将 locations 转成当前 storage 的字符偏移；
  [`NSTextLayoutManager.renderingAttributesValidator`](https://developer.apple.com/documentation/appkit/nstextlayoutmanager/renderingattributesvalidator)
  针对 layout fragment range 校验
  rendering attributes。因此 fragment offset 属于 display 空间，必须先经 `DisplayMap` 回到
  visible source ranges，再查询 source spans/references。

本片不激活任何 rendered fold ID，故产品显示与 F0 前逐字节一致；附件、点击与视觉样式仍由 F2
的真实 AppKit spike 和三主题验收负责。

## R4：Settings 缓存、⌘± 与换行

结论：PASS（R4 当前可实现域）；Reading Set 字号同步断言在 M11D 创建该文档类型后补跑，不能在
其类型尚不存在时伪造通过。

- 先在真实 `ReaderTextView` 复现 TextKit 2 换行：三条源码逻辑行仍恰好对应三个
  `NSTextLayoutFragment`；长行 fragment 高 341.25pt、普通行高 21.25pt。第 2 行的 line number、
  current-line、declaration marker 与 diff marker 均只出现一次。结论是 gutter 无缺陷；当前行背景
  覆盖该逻辑行的全部视觉换行属于期望行为，不新增修复实体。
- `ReaderSettings.wrapLines` 为 package 存储、默认 false；既有 public init 签名未增加参数。
  缺 key 恢复 false，写入 true 后经注入的 UserDefaults 完整 round-trip。
- wrap on 逐项实测：`widthTracksTextView=true`、有限 container width、
  `isHorizontallyResizable=false`、水平滚动条关闭、document view 随窗口缩放；wrap off 对每一项
  反向恢复，包括无限 container width 与水平滚动条重新出现。
- Settings Reader 页新增可见且可访问的 `Wrap lines` toggle。新打包的
  `.build/m11-r4-app/Cairn.app` 中，真实 AX 树同时报告 `static text Wrap lines` 与
  `checkbox Wrap lines`；截图为 `r4-settings.png`。已有 Settings controller 每次 show 前注入当前
  值，窗口打开期间通过重建既有 hosting root 即时更新；没有新增 observable settings module。
- View 菜单的真实 AX 菜单项为 `Increase Font Size` / `Decrease Font Size`；屏幕中显示
  `⌘+` / `⌘-`，AX command char 为 `+` / `-`、modifier 值为默认 Command、两项均可用。
  `--self-test-reading` 进一步实测连续 12→13→14 每次恰好 1pt，24/10 边界禁用且额外调用不越界，
  UserDefaults 回读一致，打开的文件 Reader 与 Settings window 都即时变为 14pt。
- `swift test --disable-sandbox`：PASS，449 / 449。
- `--self-test-reading`：PASS；新增 8 项 font-menu / persistence / immediate-apply 检查全部为 true。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；449 / 449、Exact、Diff、Reading、Projector
  全部通过，ReaderUI 坐标门禁仍为零违规。
- Release app bundle：`scripts/make-app.sh` PASS；Info.plist、严格 codesign 与指定要求校验通过。
- `M11_BASE...HEAD`、index、worktree、untracked 四域的 protected deny-list 均为零命中；
  `RECORD=UNSET`，`git diff --check` PASS。
- 真实可视验收继续打开 Tokio 时，macOS 弹出 ChatGPT Apple Events 持久授权提示；未扩大授权。
  因此未用桌面自动化重复长行测试，且不把这一权限阻塞描述成产品失败。产品行为由同一真实
  `ReaderTextView` 的 offscreen AppKit 几何/绘制断言覆盖。

M11D 完成时必须把同一 `commitReaderSettings` 路径应用到 Reading Set 的只读文本视图，并把
“Reading Set 字号即时变化”加入既有 `--self-test-reading`；完成前 R4 不宣称该跨片条件已验证。
