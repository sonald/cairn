# 自然段分块方案：不采用当前实现

这个原型把一个自然段作为多个 `NSTextParagraph` 提供，保留完整 `NSTextStorage`。已有对照中，原文、复制、字符范围读取和 EOF 选择一致，但 11 个同源位置中 9 个排版坐标不同；块边界增加视觉行并改变双向文本布局。因此当前实现不接入产品，也没有证明内存按块释放。

这只否定当前“块即段落”的实现，不代表所有公开 TextKit 2 分块方案不可行。历史输入、环境、源码哈希与几何差异保存在 [evidence.json](evidence.json)；这是旧实验记录，不是当前版本验收。本次仅整理文档，未重跑。

从仓库根目录复现：

```sh
bash Prototypes/ReadonlyChunkedContent/build.sh
Prototypes/ReadonlyChunkedContent/chunked-content-probe --check-enumeration
bash Prototypes/ReadonlyChunkedContent/run-pair.sh \
  Prototypes/ReadonlyChunkedContent/unicode.txt \
  .build/readonly/chunked-rerun
```

`run-pair.sh` 发现功能差异时退出 1；选择新的输出目录保留原始结果。只有出现具体产品需要且能保持源坐标、Unicode 与排版语义时才重新研究；采用前还需真实选择、复制和相关性能验证。遵循 [当前测试策略](../../docs/testing.md)，不沿用旧阶段的测量数量或验收清单。
