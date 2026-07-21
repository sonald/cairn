# M4 Backlog（M3 终审 2026-07-21 产出）

## M4 主体（design §16 + §8）

Exact Provider（机会式精确增强：rust-analyzer/tsserver/Pyright 或 SCIP 导入）+
Safe/Trusted 双模式（design §8.4）+ diff 阅读（跨 commit，含 Compare 预设的 diff）+
索引持久化 + 正式发布（签名/公证、libgit2 静态链接）。

## M3 终审非阻塞项（Opus review）

1. **ProjectIndexStore 计算属性锁内整拷**：`contentIndexes`/`namePosting`/
   `sourceBytesByContent` 每次访问 lock.withLock 整字典拷贝（S2 形态）。S3 已提示热
   路径取一次引用，但更大仓库前应给 store 加"稳定引用快照"或读写锁，避免查询循环
   反复整拷。当前 tokio/oatmeal 量级未咬（switch 38–104ms）。
2. **coverage.importsResolved 诚实性**：S4 允许 importsResolved 近似/占位——确认 UI
   显示的是如实数字或明确标"近似"，不造精确感。
3. libgit2 正式分发：静态链接或随包 vendor（M4 发布必需）。

## M3 期间挂起延续

- ~~**K5 Pin 语义裁决**~~：**2026-07-21 已裁决并实现**（design §2.2 F2.3）——
  Pin = 底部冻结；Cmd+单击跳主区不动底部；Show Relations 只填关系树不动底部（无条件）。
  由 `--self-test-pin` 集成通道断言守护。
- 分支图（graph）：M3 切换器只做线性列表 + branch/tag 标签。
- Compare 跨 commit diff：M3 只做分屏布局，diff 留 M4（design F4.7 P1）。
- huge syntaxVisible TextKit 属性重排优化（探针级专项）。
- AX 值变更防御专项（现有 4+ 个 NSOutlineView）。
- FileTreeModel / replay 越界兜底的主线程 IO 异步化（超大仓库）。
- SearchPanel 5000 命中极限掉帧、selectedIndex 随组重排漂移。

## 交互测试待人工确认（工具注入能力限制）

- Cmd+单击跳转手感、hover 零查询目测、大屏首启尺寸（M1/M2 遗留）。
