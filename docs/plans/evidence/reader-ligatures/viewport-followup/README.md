# F1 native viewport follow-up

2026-09-23，产品代码未修改。Fira Code，F1第15000行，native NSTextView/TextKit 2。从现有viewport probe派生，仅作定位实验，非正式性能验收。

设计核对：`2026-09-19-reader-wrap-design.md`第256/264/636–637行允许目标范围与viewport布局及后续最多3次高度校正，不要求主Reader首帧全篇精确尺寸。第389–391行的完整测量要求针对Reading Set。因此验证是否能关闭NSTextView自动文档尺寸路径是合法调查，并不表示已允许错误clamp、EOF不可达或空首帧。

| 变体 | 结果 |
| --- | --- |
| 禁止横/纵自动resize，保留旧frame，拆分scroll阶段 | 总计约1.8s；container/usage/tile约2.4ms，clip.scroll约1546ms；新建29992个fragment，立即viewport为空 |
| 只ensureLayout锚点字符，setBoundsOrigin替代scroll | 2840ms；锚点布局约0.4ms，bounds移动仍约1488ms；37854个已布局fragment，立即viewport为空 |
| 关闭clip bounds通知，手动layoutViewport | 1800ms；clip.scroll仍约1503ms；29992个fragment，最终可见目标但没有满足250ms |

结果排除了这几种局部方案，不能外推为所有TextKit方案都不可行。旧frame高2677361pt仍未随unwrapped usage约624020pt收敛，所以即使某阶段快也不能当正确实现。

复跑：`swiftc -parse-as-library -O scroll-stage.swift -o /tmp/f1-scroll-stage && /tmp/f1-scroll-stage 15000 natural`。另外两个源文件同样编译运行。需要AppKit桌面权限和已安装Fira Code；源码中fixture绝对路径对应本工作区。
