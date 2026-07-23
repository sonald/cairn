# M4 Backlog（2026-07-23 终审）

## M4 主体（design §16 + §8）

Exact Provider（机会式精确增强：rust-analyzer/tsserver/Pyright 或 SCIP 导入）+
Safe/Trusted 双模式（design §8.4）+ diff 阅读（跨 commit，含 Compare 预设的 diff）+
索引持久化 + 正式发布（签名/公证、libgit2 静态链接）。

## 已解决，可结案

1. **ProjectIndexStore 计算属性锁内整拷**：S5 已在
   `ProjectIndexStore.swift` 引入 `State` + `snapshot()`，查询热路径经
   `EngineSession.storeState` 读取、不再过锁，`ProjectIndexer` 也已使用批量
   `insert`。
2. **coverage.importsResolved 诚实性**：`AppModel.swift` 将其定义为 `Int?`，
   `statusText` 仅在非 nil 时显示；Sources 内 6 个 `SnapshotCoverage(...)`
   构造点均未伪造该值，并有 nil 断言守护。
3. **libgit2 正式分发**：S8 的 `scripts/vendor-libgit2.sh` 固定 v1.9.6 与
   SHA-256，构建静态库并关闭 SSH/HTTPS/NTLM/GSSAPI；`Package.swift` 提供
   brew/vendored 双路径，`scripts/make-app.sh` 默认要求 vendored 发布产物。
4. **Compare 跨 commit diff**：S6 已交付 `DiffCore`、`CompareModel`、hunk
   导航，且 `--self-test-diff` 在 `scripts/ci.sh` 恒跑。
5. **FileTreeModel / replay 主线程 IO**：S8 已通过 `AppModel.swift` 的
   `detachedValue` 将 `openProject` 全盘扫描及 replay 文件加载、highlight
   移出主线程。

## backlog 清理轮 A–D

- `bd06dab`（A）：取消选中会清空 `selectedRelationSymbol`，并补齐
  name-only 边的诚实标注。
- `7df5d8e`（B）：provider-proven External 方法调用会从 Possible 降组。
- `6068c1c`（C）：SearchPanel 以匹配身份保持选中，避免组重排后 Enter
  打开错误文件。
- CHUNK D（本片，按约束未提交）：扩展 SwiftUI 不稳定身份静态禁令并加 regex
  自检；让 `ExactCoordinator.attribution` 正确参与 Observation；记录
  RelationTree/provider 路径约定耦合。

## 防线留档

- **C1(G4.4) Revoke 崩溃仍属“无头不可证”**：真正的 bug 检测器是可见窗口
  G4.4（修前 2/2 复现，修后 30 分钟交互走查 PASS）；CI grep 只是按构造阻止
  `.indices, id:`、锚定 `ForEach`/`List` 的 `0..<` 与 `enumerated()` 回归，
  内嵌样本仅验证禁令 regex 自身覆盖，不等价于复现显示周期崩溃。
- **attribution Observation 测试是真正的 bug 检测器**：旧
  `@ObservationIgnored active` 下 prepare/invalidate 两次通知均失败，删除该
  标注后两次均触发；Sources 零命中检查则仍只是静态边界防回归断言。

## 存档 wontfix

- **设置窗口缓存 stale settings**：当前不可达，因为 `readerSettings` 唯一突变点
  是设置窗口自身 `onChange`，没有第二入口。**未来新增任何设置突变入口（如
  Cmd+± 字号）前，必须先移除 `settingsWindowController` 缓存或改绑定。**
- **LSPClient `serverDiagnostics` 64KB 截断**：每事件重发全量且每事件重算
  coverage，理论回翻窗口会在下一事件自愈，当前修复复杂度大于收益；M5 若做
  coverage 状态机时一并收。

## 继续挂 M5

- RA 孙进程进程组化：需弃 Foundation `Process` 重写 spawn，会触及 exact 主干。
- SearchPanel 5000 命中极限渲染：34ms 节流已缓解，无头无法证明真实帧表现。
- Context “位于依赖”展示：补全 design F2.7。
- receiver 类型建模：`UnresolvedCall.receiverRange` 已在 Core 预留。
- 分支图。
- AX 值变更防御专项。
- huge syntaxVisible TextKit 属性重排优化。
- TS/Python 整语言面。

## 改 provider 时的联动检查项

- `RelationTreeModel` 的 provider-proven External 降组以
  `exact.location.file.hasPrefix("/")` 判定项目外目标，依赖
  `RustAnalyzerProvider.parseDefinition` 对项目/物化根内返回相对路径、根外
  返回绝对路径的约定；若 provider 改为返回项目内绝对路径会误降组，因此任何
  provider 路径约定变更都必须同步复查此处。

## 交互测试待人工确认（工具注入能力限制）

- Cmd+单击跳转手感、hover 零查询目测、大屏首启尺寸（M1/M2 遗留）。
