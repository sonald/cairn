# 保留证据

这里是少量历史诊断输入，不是现行要求，也不证明当前提交已通过验收。当前行为和限制统一见[产品文档](../product.md)，验证选择见[测试策略](../testing.md)。重复 CI 日志、中间原型、被后续结果取代的测量和大批过程截图已移除，可从 Git 历史恢复。

| 证据 | 保留原因、来源与边界 |
| --- | --- |
| [readonly-performance.json](readonly-performance.json)、[原始记录](readonly-performance-raw.tar.gz) | 最终 r5（候选 `a99f10b2ec09c27c2610f3a651a638c070075470`，基线 `4fdabe38eb364f9e9d7aa6507aa445fb636ad485`）。178 个配对/356 个登记进程，Rust/长行各 29 对，其他四种输入各 30 对；完整原始包另保留未纳入统计的样本和供电记录。保留 12 项相关冷 p95 警戒、高成本精确重排 NOT_RUN 和基线 Python 锚点失败，不声称完整发布验收。用户已要求停止扩大采样。 |
| [font-registration.json](font-registration.json) | 字体同名重新注册/跨进程通知的来源身份、实际字体及字形宽度证据；支持 `fixtures/readonly/fonts` 的可复现说明。 |
| [font-shaping.json](font-shaping.json) | 2026-09-22—23 本机 Fira Code/JetBrains Mono 的 Core Text 成形探针。连字开关不能只以 glyph 数量减少判断；字体版本和环境仅代表当时输入。 |
| [type-follow.jpg](type-follow.jpg) | 2026-10-03 打包应用：键盘光标指向 `ps`，Context 显示 `ps: &S → S`。 |
| [enclosing-layout.jpg](enclosing-layout.jpg) | 同日所在函数模式，保留主体摘要与末行轻微重叠的观察，供修复后对照。 |
| [shortcuts.jpg](shortcuts.jpg) | 同日真实快捷键设置页；证明页面可见，不证明录制/冲突替换已完成真实交互。 |
| [hover-signature.jpg](hover-signature.jpg)、[hover-python.jpg](hover-python.jpg) | 2026-09-30 打包应用：TS 长签名按词换行，Python 语法降级正文保留缩进小节。不是完整三语言 hover 的当前验收。 |

readonly 原始包 SHA-256：`505037eab3af531eef4f56e0914f251b442b00ee0026ec4238c8bc872e24a1fb`。原始 JSON 与归档内容保持不变，内部旧路径、阶段名和当时状态是采样元数据，不作为当前链接或开发规则。

字体上游：[Fira Code](https://github.com/tonsky/FiraCode)、[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono)。产品不分发这些字体，本地 fixture 的许可证与生成说明保留在其目录中。
