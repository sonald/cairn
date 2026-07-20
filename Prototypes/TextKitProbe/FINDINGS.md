# TextKit 2 大文件渲染 spike 结论

## 测量条件

- 时间：2026-07-20
- 机器：MacBook Pro（Mac15,6），Apple M3 Pro 11 核，36 GB
- 系统：macOS 26.5.2；Swift 6.3.3；target 为 macOS 14+
- 输入：生成器产出的 100,000 行 Rust，2,970,948 bytes / 2,670,948 UTF-16 units；包含长行、CJK、emoji 和 64 层嵌套；tree-sitter `hasError == false`
- 两组均使用 `--font-delta 2 --comment-font`。`firstVisibleTextMS` 从读文件前开始，到离屏 1024×768 `NSTextView` 的第一个 TextKit 2 layout fragment 可见为止，包含读文件、映射表、全文件 parse、高亮索引、属性和首屏布局。
- `stableFootprintMB` 是首屏完成后让 RunLoop 稳定 350 ms，再用 `TASK_VM_INFO.phys_footprint` 读取。
- 本执行环境限制 SwiftPM 自身的 sandbox/cache，所以实跑命令增加了 `--disable-sandbox` 和 `/tmp` module cache；计时从可执行程序内部开始，不包含 SwiftPM build 时间。

生成文件：

```sh
swift run TextKitProbe --generate /tmp/codeinsight-textkitprobe-20260720/synthetic-100000.rs
wc -l -c /tmp/codeinsight-textkitprobe-20260720/synthetic-100000.rs
# 100000 2970948
```

测量命令（去掉本环境所需的 SwiftPM sandbox/cache 参数后）：

```sh
swift run TextKitProbe measure /tmp/codeinsight-textkitprobe-20260720/synthetic-100000.rs --lazy --font-delta 2 --comment-font
swift run TextKitProbe measure /tmp/codeinsight-textkitprobe-20260720/synthetic-100000.rs --eager --font-delta 2 --comment-font
```

## 数据

| 指标 | lazy | eager | 差异 |
|---|---:|---:|---:|
| 读文件 | 5.46 ms | 1.99 ms | 噪声级 |
| 全文件 tree-sitter parse | 737.48 ms | 737.62 ms | 基本相同 |
| 高亮 span 索引 | 492.31 ms | 494.31 ms | 基本相同 |
| 一次性属性施加 | 0.02 ms | 977.81 ms | eager 多 977.79 ms |
| 首屏文字可见 | 3,459.89 ms | 5,413.54 ms | lazy 快 1,953.65 ms（36.1%） |
| 稳定 footprint | 458.67 MB | 649.44 MB | lazy 少 190.77 MB（29.4%） |
| 候选高亮 spans | 130,000 | 130,000 | 相同 |
| validator 回调 fragments | 100,000 | 0 | lazy 的 AppKit 预验证 |
| 实际惰性施加 fragments | 196 | 0 | 视口 ±2 屏 |
| 抽样映射往返断言 | 400 | 400 | 全部通过 |

原始 JSON 行：

```json
{"attributeApplyMS":0.02375,"bytes":2970948,"commentFont":true,"file":"/tmp/codeinsight-textkitprobe-20260720/synthetic-100000.rs","fileReadMS":5.455292,"firstVisibleTextMS":3459.89175,"fontDelta":2,"highlightIndexMS":492.305125,"highlightSpans":130000,"lazyStyledFragments":196,"lazyValidatedFragments":100000,"lines":100000,"mode":"lazy","parseHasError":false,"parseMS":737.480584,"sampledMappingRoundTrips":400,"stableFootprintMB":458.67285919189453,"utf16Units":2670948}
{"attributeApplyMS":977.812333,"bytes":2970948,"commentFont":true,"file":"/tmp/codeinsight-textkitprobe-20260720/synthetic-100000.rs","fileReadMS":1.987458,"firstVisibleTextMS":5413.5365,"fontDelta":2,"highlightIndexMS":494.311292,"highlightSpans":130000,"lazyStyledFragments":0,"lazyValidatedFragments":0,"lines":100000,"mode":"eager","parseHasError":false,"parseMS":737.617375,"sampledMappingRoundTrips":400,"stableFootprintMB":649.4386215209961,"utf16Units":2670948}
```

## 结论

### lazy vs eager

lazy 明显胜出，但当前 TextKit 2 路径仍不够便宜。它避免了 130,000 次全文件属性写入，只给首屏及两屏缓冲区的 196 个 fragment 写 rendering attributes，因此比 eager 少约 1.95 秒和 191 MB。

一个重要的反例是：`NSTextContentStorageDelegate.textParagraphWithRange` 和不加范围判断的 `renderingAttributesValidator` 都会在此配置下退化为全文件属性工作。最终实现使用 `renderingAttributesValidator`，并按 `viewportBounds` 与 fragment frame 相交判断后再施加属性。AppKit 仍为估算文档调用了全部 100,000 个 fragment 的 validator；范围判断避免了 attribute runs，却没有消除 TextKit 的全文件预验证成本。这解释了 lazy 仍需 3.46 秒、458.67 MB。

因此本 spike 证明“视口属性惰性施加可行且收益大”，没有证明“NSTextView 直接承载 10 万行已经满足产品目标”。只有主工程给出首屏/内存门槛且当前数据未达标时，才值得继续试自定义 content provider 或分块 backing store。

### byte ↔ UTF-16

方案可行。checkpoint 每 256 bytes 记录合法 Unicode scalar 边界上的 byte/UTF-16 对；转换先二分到 checkpoint，再最多局部扫描一个 stride。tree-sitter 的 byte range 到 `NSRange` 全部走该路径。单测覆盖 ASCII、CJK、emoji surrogate pair、非法“落在 scalar/surrogate 中间”的 offset；实测还抽样了 200 个 token 的起止边界，共 400 次往返，全部通过。

### +2 pt / 注释人文字体人工检查清单

`measure` 只验证混合字体能参与离屏布局；滚动锚点与视觉跳动需用以下命令人工确认：

```sh
swift run TextKitProbe view /tmp/codeinsight-textkitprobe-20260720/synthetic-100000.rs --lazy --font-delta 2 --comment-font
```

- 连续 Page Down、拖动滚动条到 25%/50%/75%，观察放大的 `fn` 名刚进入/离开缓冲区时是否让内容上下跳。
- 在同一位置分别用 `--font-delta 1` 与 `2` 打开，比较行高变化、滚动条 thumb 和当前首行锚点；若 +2 有可见跳动，主工程默认 +1。
- 快速滚过 CJK/emoji 注释和长行，确认新进入视口的 token 仍高亮、注释字体切换正确，且没有明显 hitch。
- 选择并复制跨越普通行、放大函数名和人文注释的文本，确认复制内容不受 rendering attributes 影响。
- 往返滚动相同区域，确认惰性属性不会重复叠加或在回收后丢失。

### 对 `docs/design.md` §9 的修正建议

1. 将“`NSTextContentStorage` delegate 惰性施加”改为机制中立的“TextKit 2 viewport 驱动的 rendering attributes”；本次 delegate 在 10 万段落上被全量调用。
2. 明确 validator 回调本身可能覆盖全文件，必须用 viewport + buffer 做二次范围门控；设计验收应统计“实际写属性的 fragment 数”，不能只看是否用了 lazy API。
3. 继续以 byte range 为高亮存储坐标，只在视口命中后经 checkpoint 转 `NSRange`；不要预先为所有 token 保存 UTF-16 range。
4. 把可变字号视为 layout 属性而不是纯颜色高亮：默认幅度需等人工滚动检查后在 +1/+2 中定；若跳动明显，优先固定行高或退回 +1。
5. 增加 10 万行首屏与 footprint 的明确预算。当前原生 `NSTextView` 即使惰性写属性仍有 100,000 次预验证，若预算不接受 3.46 秒/459 MB，再以数据决定是否增加自定义 content provider；现在不把它预先写进正式架构。

## 人工验收补记（2026-07-20，决策者亲测 view 模式）

- **结论：默认行距偏紧。** 系统默认 lineHeightMultiple=1.0 的等宽 13pt 阅读密度过高。
- 探针已加 `--line-spacing <1.0...2.0>`（NSParagraphStyle.lineHeightMultiple）供扫值：
  `swift run TextKitProbe view <file> --lazy --font-delta 1 --line-spacing 1.25`
- 巨文件成本（10 万行，同会话 lazy 对照）：1.3 vs 1.0 → 首屏 +390ms（+11%）、
  footprint +188MB（+25%）。常规档文件（≤1 万行）该成本可忽略。
- 跨进程 footprint 测量波动大（同配置 459 vs 750MB），结论只取同会话相对差。
- 待办：决策者在 1.15 / 1.25 / 1.35 中扫出主工程默认值。
