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

## F2：折叠附件、gutter 折叠柄与原子入口

结论：PASS（自动门禁、最终签名包真实交互与三主题产品截图均已收口）。

- 真实 `ReaderTextView` attachment spike 四项均通过：provider 创建、0 → 3 → 999 计数更新、
  点击占位附件展开、AX label 可读。provider 的 `hitTest` 明确让回 `NSTextView`，点击只走既有
  `activate(atCharacterIndex:)` 路径；实测输出为
  `providerCreated=true countUpdated=true clickExpanded=true hitTesting=NSTextView`。
- 首轮最终包验收真实复现了“折叠后只有零宽 `U+FFFC`、pill 不可见”：provider 已创建且 AX
  label 正确，但 TextKit 布局未取得 provider 的固定 bounds。修复由同一
  `FoldAttachmentViewProvider.attachmentBounds` 返回 16pt chip bounds；并覆盖 TextKit 在 pill
  右半区返回 placeholder 后一位 insertion index 的点击语义。新增断言要求附件所在行宽至少包含
  provider 宽度；修前该真实路径失败，修后 attachment spike 与 31 / 31 ReaderUI 测试 PASS。
- 折叠状态只按 `(standardized fileURL, contentID)` 保存 baseline override；切换到新 pair 从空状态
  开始，切回旧 pair 原覆盖集合恢复。逻辑折叠集与渲染折叠集分离，渲染只取极大元；外层展开后
  内层折叠仍在。
- 折叠集合变更只有 `applyFoldMutation` 一个 private 入口：分别捕获 selection / viewport 的 source
  anchor，归一 reducer，重建同源 attributed storage + `DisplayMap`，再分别恢复可见或 latent anchor。
  两个 anchor 落入不同 fold、依次展开时，各自只在所属 fold 展开后恢复。
- attachment 使用单个 `U+FFFC`，chip 为 1pt 描边、r4、5pt 水平留白；动态计数区固定 54pt。
  0 / 3 / 999 matches 下 attachment 与整行布局宽度恒定，高度 16pt 且不超过单行行高。
- gutter 折叠列仅在可见 fold 存在时占 12pt；chevron 仅悬停显示，展开 / 折叠为 `▾` / `▸`；
  `hiddenLineCount < 2` 不进入可点击区域。`⌥` 点击对同级及其子树递归。行号关、diff 空但存在
  可见 fold 时 ruler 仍保留且可点击。
- 可见源码着色 / 引用扫描通过 `visibleSourceRanges` 的 source-ordered 单遍扫描；隐藏 body 不随
  `hiddenLineCount` 增长而增加引用扫描量。无折叠时保留原完整 span 路径。
- `--self-test-fold`：PASS，14 / 14；附件机制、固定宽高、单 placeholder、AX、hit testing、
  pair 隔离、极大元、嵌套状态、ruler-only 与 viewport 跳过隐藏源码全部为 true。
- 固定 fixture 校验：SHA-256
  `86bf0fac91bd7556b2ea49b9a6426d3d31de17cf1d81491972500371761f9578`，3,115,800 bytes，
  50,000 个换行；control / fold 均由真实 production load 观察到 8,400 candidates / 8,400
  accepted，Overview 为 4,400 logical / 200 rendered。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；其 release 双进程结果为 control resolution
  29.035 ms、fold resolution 25.138 ms、首次折叠 380.031 ms（门槛 ≤ 400 ms），峰值 RSS 增量
  6,733,824 bytes（6.42 MiB，门槛 ≤ 80 MiB），最终 `status=pass`。
- `CODEX_SANDBOX=1 bash scripts/run-gold-gates.sh`：PASS；Tokio 17 条、ripgrep 16 条，unexpected
  failures 均为 0；同一脚本独立重建 release 并复跑 fold runner，365.093 ms / 6,422,528 bytes，
  `status=pass`。
- 最终 pill 布局修复后再次以该 release 二进制复跑：与全屏验收包并行时首次为 447.732 ms，
  超过 400 ms（`status=fail`），没有忽略；关闭验收包排除进程竞争后，同一命令为 351.492 ms、
  峰值 RSS 增量 7,897,112 bytes，`status=pass`。同时 `--self-test-fold` 14 / 14 与 ReaderUI
  31 / 31 PASS。
- 当前 Swift Testing 与混合 AppKit test host 在单次全量进程中会提前正常退出，因此不以其退出码
  冒充完整覆盖。按 `swift test list` 的具名清单拆分模块，并将 ReaderCore 65 项逐条隔离执行，
  455 / 455 均得到明确 PASS；其中四个慢测也分别到达终态。
- 最终验收包为 `.build/m11-f2-ui-app-final/Cairn.app`；`scripts/make-app.sh` 重新构建并完成
  Info.plist、逐 dylib 签名与 designated requirement 校验。真实 AppKit 打开非 Git 的确定性
  Rust fixture，文件树、六项 outline 与 28 行 Reader 均可见；非 Git 仅隔离本机 Git 全局配置
  读取阻塞，Exact unavailable 为该 fixture 的预期状态，不用于 F2 结论。
- 真实交互顺序已完成：悬停第 1 行 12pt fold column → 点击收起外层 `mod` → 可见 summary pill
  `⋯ 1 impl · 1 struct · 19 lines` → 点击 pill 中部恢复全部 28 行；随后再次收起，并通过 Settings
  的真实 Theme popup 逐项切换 Light / Dark / SI Classic。三张最终产品截图分别为
  `f2-fold-light.jpeg`、`f2-fold-dark.jpeg`、`f2-fold-si-classic.jpeg`，最后恢复 SI Classic。
- attachment provider 的 AppKit AX label 实测为 button role 且包含
  `Collapsed, hides … lines, contains …`；桌面 CUA 对 NSTextView 子附件只扁平显示单个
  `U+FFFC`，因此以真实 provider AX 对象断言证明可读语义，不把 CUA 的树扁平化冒充缺陷。

## F3：折叠下的复制与选择

结论：PASS（无可见 UI 变化；复制结果始终来自完整源码空间）。

- `ClickTextView.writeSelection(to:type:)` 对 plain text 走单一 `sourceCopyHandler`；`copy(_:)`
  作为动作兜底，只向 general pasteboard 写 plain source text。没有复制 attributed storage，因而
  不会把 attachment 或其 `U+FFFC` 序列化出去。
- 选区只经 F1 的同一 `DisplayMap.sourceRanges(forDisplay:)` 回到 source `ByteRange`，再从当前
  `ReaderDocument.bytes` 顺序拼接；没有第二套位置换算或额外文本副本。
- 红测先证明原生路径在两种场景都不能提供所需结果；修后全折叠 `selectAll` 得到逐字节完整源码，
  跨一个折叠区的部分选区得到对应 source 子串，两者均明确断言不含 `U+FFFC`。
- Codex 文件沙箱内 macOS pasteboard 服务不可达时，两条测试仍验证完整 source 映射并打印
  `M11_COPY_PASTEBOARD unavailable`；同一测试在宿主 AppKit/pasteboard 环境复跑时没有走该分支，
  `writeSelection`、pasteboard 内容与 `U+FFFC` 断言全部 PASS。
- ReaderUI 33 / 33 PASS；`CODEX_SANDBOX=1 bash scripts/ci.sh` PASS，包含完整测试、自检、
  坐标门禁与 release fold runner。最终 runner 为 366.381 ms、RSS 增量 7,421,952 bytes，
  `status=pass`。

## F4：Reading Height 三档与 Folding 菜单

结论：PASS（层级 reducer、真实 AppKit 控件 / 菜单、三主题截图与完整 CI 均已收口）。

- 唯一新增语义类型为 package 级 `ReadingHeightLevel`：`Full`、`Structure`、`Overview`。
  Full baseline 为空；Structure 只包含 declaration / imports / cfgTest；Overview 在 Structure 上增加
  container；block / comment / attributes 始终只可手动折叠，且所有 baseline 都跳过
  `hiddenLineCount < 2`。
- 手动折叠状态继续复用 F2 的 `(fileURL, contentID)` override store，没有新增第二套状态容器。
  `logical = (baseline - forcedUnfolded) ∪ forcedFolded`；切换任一高度档会清除所有 pair 的旧 override，
  再从新 baseline 原子重建。测试覆盖 Full 下手动收起、Overview 下手动展开、嵌套极大元渲染以及
  跨两个 pair 的 override 清空。导航进入 Full 下的手动折叠区只移除 `forcedFolded`；导航进入
  Overview baseline 的嵌套 container / declaration body 会为完整祖先链加入 `forcedUnfolded`；两集合
  始终不相交，最终 rendered 集仍等于 logical 集的极大元。
- Reader 顶部新增固定 32pt header：11pt semibold 文件名、216×24 三段控件、spacer 与
  `⌥⌘0/1/2` 提示。三段宽度严格为 56 / 82 / 78pt；选中项使用当前主题内容背景、accent 文字和
  2pt 底部 accent 线。控件为真实 `NSSegmentedControl`，AX 暴露 Reading height radio group 和
  Full / Structure / Overview 三个 segment。
- `View ▸ Folding` 的真实菜单顺序严格为 Toggle Fold、Full、Structure、Overview、separator、
  Focus Current Scope。Full / Structure / Overview 使用 `⌥⌘0/1/2`；Toggle Fold 因原型建议的
  `⌘⇧[` 与既有 Previous Tab 冲突，按裁决允许的冲突替代使用 `⌃⌘[`，保留方括号助记。
  Focus Current Scope 属 F5，本片显示但保持禁用且不伪造动作。
- segment、菜单 checkmark 与 Reader reducer 共用同一状态入口。基础 self-test 断言五项菜单文案、
  全部快捷键、冲突替代、输入同步、header 文案 / AX 及 32 / 216 / 24 几何，全部为 true。
- 真实签名验收包：`.build/m11-f4-ui-app-final/Cairn.app`，bundle id
  `dev.cairn.Cairn.m11f4`。在非 Git 确定性 Rust fixture 中，AX 点击 Structure 后方法 / main body
  收起但 container 展开；点击 Overview 后 `mod renderer` 与 `fn main` body 收起；`⌥⌘0` 恢复
  Full；菜单点击 Structure 与 segment 同步。Outline 导航到 main 后 Toggle Fold 变为可用，点击只
  收起 main body。
- 三主题真实产品截图为 `f4-height-light.png`、`f4-height-dark.png`、
  `f4-height-si-classic.png`；均显示同一 32pt header、三段控件、选中底线和真实折叠 pill，主题色
  分别跟随 Light / Dark / SI Classic。
- 性能门首次在高负载环境报告 442.091 ms，随后隔离复跑仍为 411.373 ms，没有忽略。定位到
  TextKit 对 2 MB backing storage 的整段编辑通知后，保持 F1 单一 projector 不变：替换被包进
  `performEditingTransaction` / `beginEditing`，并仅在编辑期间临时摘下同一个 layout manager，随后
  立即挂回，再执行既有 selection / viewport anchor 恢复。ReaderCore 全套测试、Fold 与基础
  self-test 均证明 layout manager、渲染、附件、选择和滚动语义未变。
- 优化后隔离 release runner 为 240.847 ms；加入导航自动展开祖先的最终代码后，
  `CODEX_SANDBOX=1 bash scripts/ci.sh` 再次 PASS，重负载串行末尾结果为 control resolution
  25.766 ms、fold resolution 27.851 ms、首次折叠 232.340 ms（门槛 ≤ 400 ms），4,400 logical /
  200 rendered，峰值 RSS 增量 2,801,688 bytes（门槛 ≤ 80 MiB），`status=pass`。
- 完整 Swift Testing、Exact、Diff、Reading、Projector、Fold self-test 与 ReaderUI 坐标门禁全部
  PASS。真实 rust-analyzer 仍因系统 `sandbox-exec: sandbox_apply: Operation not permitted` 诚实标记
  skipped；fake provider 只作为结构 / UI 自测，不冒充真实 provider 覆盖。

## F5：Focus Current Scope

结论：PASS（作用域选择、折叠投影、状态恢复、跨文件跟随及真实 AppKit 退出路径均已收口）。

- Focus 从当前 caret 所在的最小 `outlineFacet.range` 选择目标；`fn` / `method` 优先，其余支持
  `struct` / `enum` / `trait` / `impl` / `mod`。facet header 与 closing brace 均属于目标范围；
  `cfgTest` 按 `mod` container 处理。目标完整 facet 与祖先 header chain 保持可见，范围外全部可折叠
  kind（含 block / comment / attributes）收起；仍跳过 `hiddenLineCount < 2`，渲染只取极大元。
- Focus 不新增第二套 projector：只保存进入前的 Reading Height 与既有 pair override store，再经 F2
  的同一个 `applyFoldProjection` 原子重建。退出后逐项恢复原高度档和全部 pair overrides；Focus
  期间 Toggle Fold 禁用，直接选择高度档会先退出 Focus，再应用所选档位。
- `⌥⌘F`、`View ▸ Folding ▸ Focus Current Scope` 与 Reader 的同一 toggle 入口同步。Escape 的
  优先级为先退出 Focus，再清除 occurrences；关闭文件也清理 Focus。无可识别 scope 时不折叠，
  仅通过既有 status bar 给出一次提示。
- 显式跨文件导航在 Focus 内继续跟随新 landing scope；syntax 尚未完成时保存 landing byte，完成后
  再计算目标。用户 live scroll 只解除显式导航跟随，不退出 Focus。显式导航落在无 scope 文件时
  退出并恢复原状态，同时给出一次提示。
- 五条具名 Focus 测试先以缺失 API 编译失败记录红测，修后全部 PASS：header / closing brace、祖先
  可见与七类范围外折叠、cfg-test container、无 scope、精确恢复与 Escape 优先级、跨文件跟随、
  live-scroll 仲裁，以及 deferred syntax landing point。完整 ReaderCore 与 `swift test --disable-sandbox`
  均 PASS。
- 最终签名验收包为 `.build/m11-f5-ui-app/Cairn.app`，bundle id
  `dev.cairn.Cairn.m11f5`；使用非 Git fixture `/private/tmp/m11-f5-ui-fixture-plain`，避免把 Git
  全局配置读取问题混入产品结论。Info.plist、严格 codesign 与 designated requirement 均通过。
- 真实 AppKit 回放从 Outline 的 `describe` 行进入 Focus。Reader AX 文本只保留祖先
  `mod` / `impl` header、完整 `describe` body，并把 `Frame`、`area`、`main` 显示为折叠 pill；
  Reading Height 仍为 Full。首轮真实回放发现 Outline 保持 first responder 时 Escape 未送达 Reader；
  修复为仅限当前主窗口、仅在 Focus 激活时消费 Escape 的 local monitor。最终包复跑同一路径，单次
  Escape 恢复完整源码；再次进入后从真实 Folding 菜单点击 Focus Current Scope 也恢复 Full。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；完整 Swift Testing、Exact、Diff、Reading、Projector、
  Fold self-test 与 ReaderUI 坐标门禁全部退出 0。最终 release runner 为 control resolution
  28.816 ms、fold resolution 53.023 ms、首次折叠 242.961 ms（门槛 ≤ 400 ms），4,400 logical /
  200 rendered，峰值 RSS 增量 11,157,480 bytes（门槛 ≤ 80 MiB），`status=pass`。
- 真实 rust-analyzer 仍因系统 `sandbox-exec: sandbox_apply: Operation not permitted` 诚实标记
  skipped；fake provider 只证明既有结构 / UI 自测，不作为真实 provider 证据。

## R0：⌘F 文件内查找

结论：PASS（共享 literal scan、完整结果发布、文档代际、折叠导航及真实 AppKit 查找条均已收口）。

- `SnapshotSearch` 原 private `asciiFold` / `literalRanges` 已提取为 CodeInsightCore 的 package 顶层
  唯一实现；Engine 与 Reader 查找共用同一份 `A-Z → a-z`、其余字节原样比较语义。扫描为字面、
  leftmost-first、不重叠；空 query 返回空，R0 对含 CR/LF 的 query 明确显示
  `Line breaks are not supported`。
- Core scan 每 4,096 byte 调用 `Task.checkCancellation()`；取消抛 `CancellationError`，不返回部分
  `[ByteRange]`。既有 Engine 仍通过 closure 保留自己的 wall-clock / per-file 上限语义；文件内查找
  不传 wall-clock，只有完整数组才发布。Core 专测以 20,000,000 bytes worker 证明取消抛错而非发布
  部分结果。
- Reader controller 复用既有 `requestID + Task` 形状：150 ms 输入去抖，分别持有并取消外层 publish
  task 与其派生的 detached worker。发布前逐项比较 `(standardized fileURL, contentID, query,
  caseSensitive)`；切文件、切 snapshot、关闭查找条三条延迟扫描路径分别证明旧 worker 已取消、旧
  计数不发布。没有新 registry / factory / 持久化 store。
- 逻辑命中唯一保存为 `[ByteRange]`，查找条计数始终使用其完整大小；渲染才经 F1 `DisplayMap`
  派生可见 `NSRange`。测试把命中置于 Overview 隐藏的 declaration 内，仍报告总数 1；跳转后仅展开
  包含命中的 container / declaration 祖先链并选中真实源码 range。
- Reader header 下新增 31pt 原生查找条：240×22 `NSSearchField`、Aa toggle、Previous / Next、
  `N / total` status 与关闭按钮，沿用现有 chrome header/divider token，不新增视觉色板。AX 暴露
  `Find in file`、`Match case`、`Previous match`、`Next match`、`Find result`、`Close find bar`；控件
  互不重叠。Find 菜单为 Find in File… / Find Next / Find Previous / Find in Project…，快捷键分别为
  `⌘F` / `⌘G` / `⇧⌘G` / `⇧⌘F`。
- 查询变化后若原选中 `ByteRange` 仍在新结果中则保持，否则选首条。到尾/首循环后 status 追加
  `· wrapped`。关闭查找条会清除 find 命中并按进入前 anchor 恢复原符号 occurrence；无原 occurrence
  时不残留高亮。
- Escape 的主窗口 monitor 只在当前窗口内工作，优先级固定为 find bar → Focus → occurrence。
  Reader 测试锁定 occurrence 恢复；真实 AppKit 回放在 Focus main 时打开查找，第一次 Escape 只移除
  查找条且 `mod renderer {…}` 仍折叠，第二次 Escape 才恢复完整源码。
- 最终签名验收包为 `.build/m11-r0-ui-app/Cairn.app`，bundle id
  `dev.cairn.Cairn.m11r0`。真实非 Git fixture 中，Find 菜单四项与内联 AX 控件全部可见；`frame`
  大小写不敏感为 `1 / 5`，连续 Next 后为 `1 / 5 · wrapped`，Aa 打开后为 `1 / 2`。实际 `⌘F`
  可从 Reader 直接打开并聚焦搜索框；结果高亮、header、折叠 pill、gutter 与 Reader 不重叠。
- `swift test --disable-sandbox`：PASS；新增 Core cancellation / literal、Reader hidden-fold 与单窗口
  AppKit 全合同测试全部通过，既有 SnapshotSearch timeout / cap / cancellation 测试亦通过。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；完整 Swift Testing、Exact、Diff、Reading、Projector、
  Fold self-test 与坐标门禁全部退出 0。最终 release runner 为 control resolution 25.675 ms、fold
  resolution 25.888 ms、首次折叠 255.286 ms（门槛 ≤ 400 ms），4,400 logical / 200 rendered，峰值
  RSS 增量 1,835,008 bytes（门槛 ≤ 80 MiB），`status=pass`。
- 真实 rust-analyzer 仍因系统 `sandbox-exec: sandbox_apply: Operation not permitted` 诚实标记
  skipped；R0 是纯当前文档扫描，不依赖 provider，故不以 fake provider 代替其产品结论。

## F6：折叠诚实合同

结论：PASS（导航、搜索、diff 与当前符号四条红线均独立验证，并在真实 AppKit 折叠 / 查找流中复跑）。

- 导航落点位于折叠 body 时仍只展开包含落点的 logical 祖先链；Full 下手动折叠与 Overview baseline
  分别沿用既有 override reducer，不引入第二条展开路径。gutter 在 landing source line 绘制 accent
  短标记，1.2 秒后按 generation 自动清除；标记存在期间即使最后一个 fold 已展开，ruler 也不会先消失。
- Fold attachment 仍是 F2 的单个固定宽度 `NSTextAttachment`。搜索命中与 symbol occurrences 都在
  source `ByteRange` 空间按当前 rendered 极大折叠区有序归属；视觉动态区按活动交互显示
  `· N matches` / `· N occurrences`，超过 999 仍截断为 `· 999`，不改 54pt 宽度、不重建
  `DisplayMap`。AX label 保留完整真实计数，并同时读出共存的 diff 暴露项。
- diff marker 继续保留原始逐行字典与总数；落在隐藏 body 的 marker 被归并到 attachment 的
  `· diff`，并在可见 fold header 的既有 diff 列绘制合并 marker。单一 kind 保留原颜色；隐藏 / header
  同时存在不同 kind 时诚实归为 changed。跳到隐藏 diff 行会先走同一祖先展开入口，再选择真实源码行。
- 当前符号在用户折叠其 selected occurrence 后仍保留 source anchor；隐藏 body 内的 occurrence 数写入
  attachment，未因投影后可见 range 为空而错误清除。搜索优先于 symbol 视觉计数；AX 对共存项不丢失。
- 四个具名独立测试分别锁定：祖先链与 1.2 秒 gutter 消退、隐藏搜索计数与逻辑总数、隐藏 diff chip 与
  header 合并 marker、折叠 selected occurrence 后的 symbol anchor 与 `· 3 occurrences`。定向 4 / 4
  PASS，完整 `swift test --disable-sandbox` PASS。
- 最终签名验收包为 `.build/m11-f6-ui-app/Cairn.app`，bundle id
  `dev.cairn.Cairn.m11f6`；Info.plist、严格 codesign 与 designated requirement 均通过。真实非 Git
  fixture 在 Overview 下搜索 `width` 报告 `1 / 6`；仍折叠的 impl / main pill 分别显示
  `· 4 matches` / `· 1 match…`，总数包含全部隐藏命中。Next 到第 2 条后只展开
  `renderer → impl → area` 包含链，`describe` 与 `main` 继续保持折叠，固定宽度 chip、find bar 与 gutter
  无重叠。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；完整 Swift Testing、Exact、Diff、Reading、Projector、
  Fold self-test 与 ReaderUI 坐标门禁全部退出 0。最终 release runner 为 control resolution
  25.669 ms、fold resolution 29.765 ms、首次折叠 269.499 ms（门槛 ≤ 400 ms），4,400 logical /
  200 rendered，峰值 RSS 增量 4,784,152 bytes（门槛 ≤ 80 MiB），`status=pass`。
- 真实 rust-analyzer 仍因系统 `sandbox-exec: sandbox_apply: Operation not permitted` 诚实标记 skipped；
  F6 的四条合同均为 Reader source / projection / AppKit 行为，不以 fake provider 代替产品结论。

## C1：Palette 五模式

结论：PASS（五模式、运行时菜单时序、查询确定性、原型视觉及全键盘真实 AppKit 流均已收口）。

- 新的 380pt 居中 borderless `KeyablePanel` 是文件、命令、当前文件符号、项目符号与行号的唯一
  Palette；输入前缀分别为无前缀 / `>` / `@` / `#` / `:`。列表按内容自适应高度、上限 200pt，圆角
  10pt、1pt chrome border、shadow、26pt 行与 20 条上限均对齐 P0 Spotlight 原型；超出时页脚严格显示
  `… 还有 N 条`。Light / Dark / SI Classic 三主题均在真实包中截图核对。
- `⌘P`、`⇧⌘P`、`⌘T`、`⌘L` 分别预填文件 / `>` / `#` / `:`。真实回放首次发现 AppKit 会全选预填
  前缀，直接输入把 `:` 替换成文件查询；修复为成为 first responder 后把 caret 放到预填末尾。最终
  `⌘L` 后直接输入 `12` 得到 `:12` 与 `Go to line 12`，`⌘T` 后直接输入 `area` 得到 `#area`。
- 文件模式只读 `FileTreeModel`，空查询先按 tab 顺序，再以 `(路径深度, 完整路径)` 排序其余文件；
  standardized URL 去重，同名文件显示最短唯一父目录。真实 `/tmp` fixture 暴露 child URL 被规范成
  `/private/tmp` 的符号链接差异；相对路径计算改为两端解析 symlink、导航 URL 不变，最终条目为
  `main.rs  src/`，不再泄露绝对路径。
- 命令模式每次打开、Palette 获得 first responder 之前即递归更新运行时 `NSMenu`；delegate 动态
  `Open Recent` 会先填充，分隔符、hidden、`action == nil` 与 Cut / Copy / Paste / Select All 等编辑命令
  均排除。执行顺序固定为关闭 → 还原 owner / 原 responder → 重新验证 → `NSApp.sendAction`。真实
  `>overview` 精确显示 `View ▸ Folding ▸ Overview  ⌥⌘2`，Enter 后 Overview segment 置为 on 且只剩
  `renderer` / `main` 折叠头；`>paste` 显示 `No commands found`。
- 本地三模式统一复用 Core `asciiFold` / `literalRanges` 的 ASCII 大小写不敏感子串语义；prefix 命中优先，
  文件、命令、当前符号各自使用计划规定的稳定 tie-break。当前符号真实 `@area` 显示
  `area  method · line 8`；项目符号继续复用既有 `SymbolSearchPanelModel`，并移除其旧的固定 50 条查询上限，
  55 个命中严格得到 20 行与 `… 还有 35 条`；真实 `#area` 显示 `area  src/main.rs:8:16`。旧的不可达
  `SymbolSearchPanel` UI 已删除，只保留该 model；共用
  `KeyablePanel` 提取为 4 行最小类型，全文搜索面板继续复用。
- 7 条 `PaletteTests` 覆盖五模式解析、文件空查询 / 消歧 / 稳定排序、当前符号 kind/name/range 排名、
  非法与越界行号、动态菜单 / hidden / nil action / 编辑排除、20 条上限与精确页脚、selection 保留 / 重置、
  restore → revalidate → send 顺序、项目索引结果与预填 caret。定向套件与完整
  `swift test --disable-sandbox` 均 PASS；runtime self-test 同时锁定四个快捷键、Folding 命令采集与编辑排除。
- 最终签名验收包为 `.build/m11-c1-ui-app/Cairn.app`，bundle id `dev.cairn.Cairn.m11c1`；Info.plist、
  严格 codesign 与 designated requirement 均通过。非 Git fixture `/private/tmp/m11-f5-ui-fixture-plain`
  完成全程无鼠标回放：`⌘P` 打开文件、`⌘L` 跳行、`@` / `#` 查符号、`⇧⌘P` 执行 Overview。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；完整 Swift Testing、Exact、Diff、Reading、Projector、Fold
  self-test 与 ReaderUI 坐标门禁全部退出 0。最终 release runner 为 control resolution 26.289 ms、fold
  resolution 25.926 ms、首次折叠 244.168 ms（门槛 ≤ 400 ms），4,400 logical / 200 rendered，峰值 RSS
  增量 5,406,720 bytes（门槛 ≤ 80 MiB），`status=pass`。真实 rust-analyzer 仍因系统 sandbox 限制诚实
  skipped；C1 文件 / 菜单 / 当前文档 / 本地项目索引行为不以 fake provider 代替产品结论。

## R1：常驻作用域头

结论：PASS（关联规则、caret 边界、零占位、原型几何、三主题与真实 AppKit 回放均已收口）。

- 作用域层级只从现有 `ReaderDocument.foldRegions` 与 `outlineFacets` 派生：每个 fold 仍使用 F5 已有的
  “最小包含 `bodyRange` 且 kind 兼容”关联，`declaration ↔ fn/method`、
  `container/cfgTest ↔ struct/enum/trait/impl/mod`；未增加 header parser、scope model 或第三套结构真值。
  `.block` / `.comment` / `.attributes` 等无兼容 facet 的层不会进入作用域头，`cfgTest ↔ mod` 有独立断言。
- 包围层按 outline depth 从外到内稳定排序；最多两层，三层以上严格保留最外与最内、用 `▸` 连接并省略
  中间层。真实 `main.rs` 的三层 `mod renderer / impl Frame / method area` 因而显示
  `mod renderer ▸ fn area  main.rs:8`；`.method` 使用源码关键词 `fn`，kind 走 syntax keyword 色、name 走
  foreground、location 走 secondary 色。
- 真实键盘回放首次发现 `⌘L` 跳行把 caret 放在签名行的行首缩进，而 tree-sitter facet 从第一个语法 token
  开始；仅做半开 byte range 判断会漏掉当前方法。边界现按 facet 首尾逻辑行补足：行 8 的缩进、行 12 的
  收尾 `}` 都保持 `fn area`；该判断不解析 header 文本，内部行仍沿用 byte range。`LineTable.line` 已是
  1-based，location 文案不再错误加一。
- AppKit 作用域条位于 tab 与 Reader 之间，固定 26pt；内容 alignment rect 严格为左内边距 13pt、相邻
  span 8pt，11pt monospaced，chrome surface + 1pt divider。Light / Dark / SI Classic 三个真实截图均与 P0
  原型一致；AX 暴露 `Current scope: mod renderer, fn area, main.rs line 8`。主题重绘保留 source caret，
  不依赖 TextKit 重装 attributed storage 后可能漂移的 display selection。
- 无包围 declaration 时 `scopeHeader.isHidden = true`，`NSStackView` 回收完整 26pt 给 Reader，不显示空文案、
  不保留 AX 元素。真实行 21 顶层空白回放确认 scope AX 节点从树中移除；切文件与语法加载期间先隐藏，
  不闪现上一文件的 scope。
- 3 条新增定向测试覆盖签名/收尾边界、`cfgTest`、不兼容 fold、无作用域、三层压缩、26pt 高度、13/8pt
  AppKit alignment geometry、monospaced、AX、三主题重绘及隐藏后 Reader 回收 26pt。完整
  `swift test --disable-sandbox` 与 `CODEX_SANDBOX=1 bash scripts/ci.sh` 均 PASS；最终 release runner 为
  control resolution 25.535 ms、fold resolution 24.927 ms、首次折叠 242.516 ms（门槛 ≤ 400 ms），
  4,400 logical / 200 rendered，峰值 RSS 增量 10,878,976 bytes（门槛 ≤ 80 MiB），`status=pass`。
- 最终签名验收包为 `.build/m11-r1-ui-app/Cairn.app`，bundle id `dev.cairn.Cairn.m11r1`；Info.plist、
  strict codesign 与 designated requirement 均通过。fixture 为
  `/private/tmp/m11-f5-ui-fixture-plain/src/main.rs`；R1 是本地 Reader/Fold/outline 行为，不依赖 provider，
  未以 fake provider 代替任何产品结论。

## R2：Reader 路径操作

结论：PASS（右键入口、点击行语义、路径格式、文件消失降级、剪贴板与 Finder 真实联动均已收口）。

- Reader 原有四个 Relations 操作之后增加一处分隔线，再依次放置 `Copy path:line` 与
  `Reveal in Finder`；沿用同一个 `NSMenu` 与右键点击 byte offset，不增加命令注册表、路径模型或第二套
  当前文件状态。AppKit 呈现时系统的 Look Up / Translate / Search / Share / Services 与产品项共存，产品
  六项相对顺序保持 `Show Callers / Calls / Implementations / References / Copy / Reveal`。
- 两个动作都读取当前 tab 实际显示的 `displayedFile` / `displayedDocument`，并由点击 byte offset 经现有
  `LineTable` 得到 1-based 行号；不复用可能属于另一 tab 的全局 selection。文件仍在项目根内时复制
  `relative/path.rs:line`，依赖或项目外文件复制绝对路径；格式与 Inspector / Trail 的路径语义一致且按
  R2 合同不附加 column。
- `Copy path:line` 即使磁盘文件刚被删除仍可复制当前已显示文档的位置；`Reveal in Finder` 在菜单打开时
  检查文件存在性并禁用，执行时再次检查，避免菜单打开后文件消失的竞态。Finder 调用只通过既有
  `NSWorkspace.activateFileViewerSelecting`，没有另建 workspace service。
- 3 条新增测试覆盖点击行与动作分发、菜单相邻顺序、当前 tab 隔离、项目相对 / 依赖绝对路径，以及文件
  消失时 Copy 保持可用而 Reveal 禁用；既有 Reader 只读与四方向关系菜单测试继续通过。定向 6 / 6 与完整
  `swift test --disable-sandbox` 均 PASS。
- 最终签名验收包为 `.build/m11-r2-ui-app/Cairn.app`，bundle id `dev.cairn.Cairn.m11r2`；Info.plist、
  strict codesign 与 designated requirement 均通过。真实非 Git fixture
  `/private/tmp/m11-f5-ui-fixture-plain/src/main.rs` 第 9 行右键后，两项均可用；执行 Copy 后在 Cairn Palette
  粘贴严格得到 `src/main.rs:9`，执行 Reveal 后 Finder 打开 `src` 且唯一选中 URL 对应的 `main.rs`。
- `CODEX_SANDBOX=1 bash scripts/ci.sh`：PASS；完整 Swift Testing、Exact、Diff、Reading、Projector、Fold
  self-test 与 ReaderUI 坐标门禁全部退出 0。最终 release runner 为 control resolution 26.603 ms、fold
  resolution 25.825 ms、首次折叠 247.786 ms（门槛 ≤ 400 ms），4,400 logical / 200 rendered，峰值 RSS
  增量 0 bytes（门槛 ≤ 80 MiB），`status=pass`。R2 为本地 Reader / AppKit / Finder 行为，不依赖 provider。
