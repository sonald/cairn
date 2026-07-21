# M3 Backlog（M2 终审 2026-07-21 产出）

## M3 主体（design §16）

Git 时间旅行完整（三级就绪 + 覆盖状态 UI + 跨版本历史）+ 面板预设 + 排版系统。
M0-C 探针结论（libgit2 接入、不可变捕获、generation 防串）为实现基础。

## M2 终审非阻塞项

1. **Calls 树静默丢弃 unresolved/外部调用边**（RelationTreeModel.makeChildren 不含
   .unresolved 组）：CLI 可见的 size_of/Box::pin 在 UI 树中消失，用户对照源码会
   误以为 bug。M3 加 "External/Unresolved" 分组或灰显行。交互测试已列入已知行为。
2. impl 关系丢弃 trait 路径限定（fmt::Display 只存 Display）：本地同名 trait 恰存在时
   外部 trait 的 impl 会被吸为 strong。名字级合并边界情况，记录待模块图增强。
3. 性能两处未兑现（benchmarks.md 已披露）：huge syntaxVisible 未降（根因移至 TextKit
   10 万 layout 属性重排——M3 优化方向：属性延迟/分批应用）；"展开 p95 <100ms" 未被
   in-session 度量（CLI 含索引重建）——M3 需要 in-session 探针。
4. RelationTreeModel 加载失败路径静默，无错误行提示。
5. Exact 空组头恒显：隐藏或加 "(0)" 计数（保留诚实性教育价值的权衡）。
6. SearchPanel 每帧全量 reloadData + 全组 expand，5000 命中极限可能掉帧；流中
   selectedIndex 随组重排漂移。
7. 右键 Show Relations 在 indexing 时展开空面板无提示；Cmd+Shift+H 无候选时静默。
8. **K5 Pin 语义（延续）**：单击联动已按"Pin 不覆盖"实现（有测试），但右键
   Show Relations 经 explicitJump 在 pinned 下仍改写 Context。**仍挂起待裁决**，
   待决策者手测统一定夺。
9. outgoingCalls 的 calls×regions 线性扫描（已留 TODO 注释），更大语料前 posting 化。

## M1 挂起项延续

- #9 replay 越界兜底与 FileTreeModel 主线程 IO 异步化（M3 与 git 层一起做）
- #11 AX 值变更防御专项（新增了 3 个 NSOutlineView，面积更大了）
- 交互测试 BLOCKED 三项人工确认：Cmd+单击、hover 零查询、大屏首启尺寸
