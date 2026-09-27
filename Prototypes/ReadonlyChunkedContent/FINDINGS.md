# S8a 分块内容原型：暂缓此方案采用

状态：**公开 API 接线修复后，原生语义对照已执行；内容/复制/AX getter 通过，几何不等价。** 不接入产品。此结论只针对“把一个自然段作为多个 NSTextParagraph 元素提供”的实现，不能推导为所有公共 TextKit 2 分块方案均不可行。

S8a 由 S6 已实测的超长段落字体/绘制瓶颈触发。该观测由阶段记录保存，本原型不把不同 fixture 或一次计时作为性能收益。S8b/c 没有额外具体体验需求，本阶段不建；本次完成原型裁决不意味着采用全部阅读投影方案。

## 修复过程与证据

1. 原始 chunked 运行在绑定 scroll.documentView 时出现 `offsetFromLocation(nil,nil)`。原证据保留在 [原始 stderr](../../.build/readonly/s8-unicode/chunked.stderr.txt)。
2. 新增三范围诊断确认：直接创建 NSTextParagraph、公开 `textElement(for:)` 工厂创建的元素均只有 elementRange，paragraphContentRange 与 paragraphSeparatorRange 为 nil。ordinary 元素的两范围正常。因此原崩溃属于原型接线不足，不能用来判定 API 不支持。
3. 增加小型 ChunkParagraph 子类，显式提供公开 content/separator range，继续使用系统 storage.location；不引入自定义 NSTextLocation。分块同时截断于真实自然段边界，且保持 composed-character sequence 完整、不插任何源换行。修复后两种模式均正常结束。
4. 复制探针改用 NSTextView.writablePasteboardTypes，并先 declareTypes。原 ordinary 的复制失败随之消失；没有自制复制实现。实际 returned bool、原生类型列表和期望/实际 UTF-8 bytes 都在新 JSON。
5. 远处 caret 起初两边都返回零矩形。除 scrollRangeToVisible、真实 run-loop readiness、绘制外，还需设置 NSTextView.maxSize 与关闭容器高度跟随：原默认文档高度被限制为 400。修复后全部 11 个源位置在两模式都确实可见、caret 高 20pt。没有把共同的零值当作几何通过。

三范围诊断：

- [ordinary](../../.build/readonly/s8-unicode-repaired/ranges-ordinary.json)
- [直接构造](../../.build/readonly/s8-unicode-repaired/ranges-direct.json)
- [公开工厂](../../.build/readonly/s8-unicode-repaired/ranges-factory.json)
- [显式公开范围](../../.build/readonly/s8-unicode-repaired/ranges-explicit.json)

## 修复后的最小功能 gate

| 检查 | ordinary | chunked |
| --- | --- | --- |
| 原文、TextKit 2 / content-manager 连接 | PASS | PASS |
| 3 处跨块原生复制，实际 bytes 相同 | PASS | PASS |
| AX selected text / range text / 字符数 | PASS | PASS |
| EOF 选择 | PASS | PASS |
| 11 处 caret 均真实可见、非零高度 | PASS | PASS |
| 同源 UTF-16 位置几何等价 ≤1pt | 对照基线 | FAIL：9/11 不同 |

以下坐标为 NSTextView 文档坐标；两模式均使用同一源 SHA、viewport 和 17pt 字体：

| 源 UTF-16 offset | ordinary x, y（pt） | chunked x, y（pt） |
| --- | --- | --- |
| 4098 | 261.37, 1180.00 | 676.97, 1200.00 |
| 4102 | 343.60, 1180.00 | 635.86, 1200.00 |
| 8190 | 479.29, 2360.00 | 99.58, 2360.00 |
| 8194 | 521.32, 2360.00 | 5.00, 2380.00 |
| 8198 | 563.36, 2360.00 | 47.04, 2380.00 |
| 12286 | 47.04, 3560.00 | 362.30, 3590.00 |
| 12290 | 89.07, 3560.00 | 5.00, 3610.00 |
| 12294 | 131.11, 3560.00 | 47.04, 3610.00 |
| 13819 | 5.00, 4020.00 | 5.00, 4040.00 |

在源 offset 4098 处，新块以空白、希伯来语和阿拉伯语开始；x/y 均变化。其他块边界也出现额外视觉行，EOF 从 y4020 变成 y4040。这证明当前“块即段落”的交付方式改变了排版几何；其中 bidi/shaping 影响的具体内部原因没有进一步宣称已证实。

## 输入、构建和复现

完整小型可追踪摘要见 [evidence.json](evidence.json)，包含失败位置、source/probe SHA 和原始 JSON 哈希。

- source SHA-256：`2813ac7d4a96825942663f255a2f7f35135c9019bda43977ffabed608436ed76`；源 UTF-16：13819。
- probe SHA-256：`563d06a168ae5f4f67a2c620971bafddc686d6de13f9230a57acbc66911066d0`。
- Swift 6.4，macOS SDK 27.0；OS `Version 27.0 (Build 26A428)`。
- viewport：`[700, 1046]`；font：`.AppleSystemUIFontMonospaced-Regular`，初始 13pt 后切换 17pt；块上限 4096 UTF-16（向完整字形簇边界推进）。

```bash
bash Prototypes/ReadonlyChunkedContent/build.sh  # swiftc -swift-version 6 -O
Prototypes/ReadonlyChunkedContent/chunked-content-probe --check-enumeration
bash Prototypes/ReadonlyChunkedContent/run-pair.sh \
  Prototypes/ReadonlyChunkedContent/unicode.txt \
  .build/readonly/s8-rerun
```

不要覆盖原始 crash 目录。重跑应换一个输出目录。[最终 raw 目录](../../.build/readonly/s8-unicode-repaired/native-sizing/) 包含两种模式 JSON、各自 stderr/time 日志和 comparison.json。`run-pair.sh` 在功能差异时退出 1 是预期 gate 结果。

## 采用边界

当前决定是**暂缓此分块方案**。自动 AX getter 不等于实际 VoiceOver 导航，程序化选区不等于鼠标拖选或 Shift 活动端；这些未运行。未进行 30 次交替性能样本，且几何失败前提下原始一次计时不可当作有效优化收益。

未来只有同时满足以下条件才考虑产品采用：源坐标与所有几何/Unicode/shaping 语义一致；真实拖选/复制/Shift/VoiceOver 可用；相同环境的足量性能/内存证据成立；元素生命周期与 extent 收敛可在公开 API 下维护。不能以插换行、重写源坐标、定制复制掩盖原生语义差异。该最小 provider 仍保留完整 NSTextStorage backing，因此也没有证明“内存按块释放”。

SDK 依据为本机公开 AppKit headers：NSTextContentManager.h（provider 强持元素要求及工厂接口）、NSTextElement.h:73–84（content/separator range 契约）、NSTextView.h（TextKit 2 网络入口）。reverse 起点遵循 NSTextContentManager.h:50–51 的“包含位置元素的前一个元素”，相关纯边界自检已与 root 执行结果一致。
