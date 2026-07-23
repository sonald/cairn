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
4. **RA 孙进程崩溃清理**：当前 crash guard 只覆盖登记的 RA 直系 PID；若要覆盖
   cargo / proc-macro-srv，需放弃 Foundation `Process`，改
   `posix_spawn` + `POSIX_SPAWN_SETPGROUP` 后按进程组清理，或引入 kqueue
   看护进程。

## M4-Fix 终审产出（Fable 5, 2026-07-23，`1239b70..bdf299e`）

**必须留档的 caveat：**

5. **C1(G4.4) Revoke 崩溃"无头不可证"**：修复是**按构造消除**（`List(trustedRepositories)`
   行闭包持 `TrustedRepository` 值拷贝，源码已无任何 index 回查，SwiftUI 重估过期行
   最坏只渲染一帧陈旧数据）。但**无头测不出原崩溃**——把 List 改回
   `indices + 行内回查` 旧写法，新增的 trust-revoke 通道 5/5 仍 exit 0（触发需真实
   显示周期里的 NSTableView 行生命周期，依赖可见窗口的 CA commit 节奏）。
   现有兜底：ci 静态禁令 grep `\.indices,\s*id:` + 人工 G4.4 复验（建议连做两次，
   原为 2/2 复现，二值信号强）。XCUITest 真窗口复现成本高且易 flaky，本轮不做。
6. **ci 禁令 regex 的同类形态盲区**：只拦 `.indices, id:`，不覆盖
   `0..<items.count, id: \.self` / `enumerated()` 等同类危险形态。作为 code review
   规则记录，暂不扩 grep（误报风险）。
7. **`methodNameOnly` 吸收外部方法调用成 Possible 的语义复审**：G8.1 只解决了空组的
   诚实性（恒显 "(0)"），**没解决吸收语义**——真实代码上 External 组仍可能偏少。
8. **`selectedRelationSymbol` 取消选中不清空**：`selectSelection` 在 `selectedRow < 0`
   或选中组行时早退、不清该字段；用户点空白取消选中后再点方向段控，会换根到"看上去
   已取消选中"的上一个 edge。非阻塞。
9. **设置窗口缓存导致 stale settings 展示**（可能）。
10. **LSPClient `serverDiagnostics` 64KB 截断**理论上可使 offline→partial 回翻
    （修前同义，非回归，下一事件自愈）；coverage 并发送达乱序窗口同理自愈。
11. **`ExactCoordinator.attribution` 是计算属性**、不参与 Observation 追踪，tooltip
    刷新搭 readiness/coverage/trustMode 的便车；若未来 attribution 独立变化需补发布。

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
