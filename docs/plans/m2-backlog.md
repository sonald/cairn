# M2 Backlog（截至 M1 交互验证完成，2026-07-20）

## M2 主体范围（design §16 M2 Relations Alpha）

双向 Call Tree（四维标注、certainty 分组、证据展示）+ 实现关系（trait→impls）+
全文搜索（SnapshotSearchService）+ 符号大纲面板。

## M1 终审遗留（非阻塞，按优先级）

1. **Pin 语义定夺**：计划说"Pin 态 Cmd+click 仍跳但不覆盖内容"，实现会覆盖。
   交互测试未能执行 Cmd+click（工具限制），待决策者手测后定夺（K5）。
2. **huge 档 validator 线性扫 span**：syntaxVisible 9.4s 的主因；spans 已排序应二分。
   交互测试 T7.3 平均 439ms/页、最大 1.53s——手感 4/5 但有优化空间。
3. **transition(to:) 状态机死代码**：生产路径绕过合法性检查，要么接入要么删。
4. **Context 点击链主线程同步 IO**：per-候选 DocumentLoader.load 无跨点击缓存。
5. **每次跳转全文件 SHA-256**：M1 不用 contentID 重放，纯浪费。
6. **NavigationHistory 回退后前进新目标留双重条目**。
7. **索引期间文件树点击不入历史**（K4，交互测试确认存在）。
8. **styledFragments 计数器 regular 档为 0 时预算不设防**（已加 >0 判定，保留观察）。
9. **replay 越界兜底同步读文件于主线程；FileTreeModel 主线程枚举**（超大 repo 风险）。
10. **搜索面板每击键重建 path→PathID 字典**。

## 交互测试（2026-07-20，36/42 PASS）新增输入

11. **AX/辅助功能加固**：经辅助功能接口直接设置巨文件滚动条值导致 98.5% CPU /
    ~1GB RSS（真实拖动正常）。VoiceOver/AX 兼容需要专项，至少加防御（AX 值变更
    合并/节流）。
12. 交互测试 BLOCKED 而待人工确认的三项：Cmd+单击跳转（T4.4）、hover 零查询目测
    （T4.8）、首启 1280×820（T1.1，需更大屏幕）。

## 走查期间引擎能力升级（已完成，记录供 M2 参考）

- 宏体条目恢复（cfg_rt! 类包裹宏，+1145 tokio 符号）
- 类型引用全局兜底（certainty 封顶 probable/possible）
- use 声明点击解析 + pub use re-export 链跟随（4 跳、防环）
- fixture 21 个、gold set 两语料 nostrong=0 保持
