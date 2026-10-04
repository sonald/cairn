# 可运行原型

这些独立程序用于回答局部技术问题，不是产品实现、验收门槛或路线图。产品现状见 [架构说明](../docs/architecture.md)，测试策略见 [testing.md](../docs/testing.md)。旧测量和设计过程可从 Git 历史查阅；本次文档整理没有重跑原型。

| 目录 | 用途与使用边界 |
| --- | --- |
| `GitSnapshotProbe` | 直接读取 Git commit、捕获工作区、观察索引复用。旧实现是验证用代码，不能据此规定产品缓存接口或性能预算。 |
| `ExactProbe` | 探查 LSP 定义、Safe 配置和历史快照物化。Safe 的服务器配置不构成安全隔离保证；测试结果只适用于被测工具版本。 |
| `TextKitProbe` | 比较 viewport 惰性属性与全量属性，观察 Unicode 映射与原生排版。离屏计时不能代替真实窗口交互。 |
| `ReadonlyChunkedContent` | 比较自然段分块与普通 TextKit 内容。当前方案改变几何，未采用；详见旁边的 [结论](ReadonlyChunkedContent/FINDINGS.md)。 |

在对应 Swift package 目录构建并运行：

```sh
# Prototypes/GitSnapshotProbe
swift run gitprobe snapshot /path/to/repo
swift run gitprobe capture /path/to/repo
swift run gitprobe switch /path/to/repo

# Prototypes/ExactProbe：按问题选一个，不要求全跑
swift run exactprobe rust
swift run exactprobe ts
swift run exactprobe py
swift run exactprobe safemode
swift run exactprobe materialize

# Prototypes/TextKitProbe
swift run TextKitProbe generate /tmp/cairn-probe.rs
swift run TextKitProbe measure /tmp/cairn-probe.rs --lazy --font-delta 2 --comment-font
swift run TextKitProbe measure /tmp/cairn-probe.rs --eager --font-delta 2 --comment-font
swift run TextKitProbe view /tmp/cairn-probe.rs --lazy --font-delta 2 --comment-font
```

按实验需要安装相应 libgit2/语言服务器。只在相关机制有疑问时使用原型；不要把旧原型的重复测试加入主工程 CI。
