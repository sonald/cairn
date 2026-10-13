# 计划：commit 阅读的精确分析——稳定检出目录、热语言服务器、依赖借用

状态：需求与阶段已定（2026-10-12），2026-10-13 按同行评审修订：S0 成为进入 S2 的门槛，补热切换顺序、复用条件、沙箱、检出策略、依赖路径与 Materializer 迁移。待实现。完成后把有效结论并入 [product.md](../product.md)、[architecture.md](../architecture.md) 并删除本文件。测量依据见 [warm-lsp-switch-2026-10](../evidence/warm-lsp-switch-2026-10/README.md)。

## 问题

切换阅读的 commit 时，Exact 整体重来：导出该 commit 全部 tracked 文件到缓存目录，冷启动语言服务器。测量表明文件导出只要 70–100 ms，语言服务器冷启动到第一个结果要 2.3–3 s（toydb），这是"切换慢、要重来"的主因。另外导出目录没有 `node_modules`、`.venv`、`target` 等被忽略的依赖目录，commit 下第三方符号的跳转、悬浮和关系退化。

原型证明：让语言服务器守着一个**内容随 commit 变化的稳定目录**，切换代价从秒级降到亚秒级（RA 0.25–0.9 s，tsserver 0.08 s，Pyright 0.02 s），已验证的判定点正确；前提是切换时关闭已打开的文件缓冲。原型**没有**证明：切换后第一个答案就正确、跨文件索引已更新、配置变化被处理、在 Cairn 沙箱中长驻可行。这四项是 S0 的门槛。

本计划只改善 Exact 的等待与依赖解析，不改变正文/索引的切换流程（已测只占 5%），也不解决"版本不好找"（见"不做"）。

## 决定

1. **Cairn 自有检出目录，用户仓库零写入。** 在应用目录按窗口建一个仓库：`git_repository_init` 后写 `objects/info/alternates` 指向用户仓库的 objects（取 `git_repository_commondir`，兼容用户自己的 worktree），写入后重开仓库或 `git_odb_add_disk_alternate` 再做首次查找。不用 `git worktree add`（会写用户 `.git/worktrees/`），不用 `git_clone`（libgit2 没有 `--shared`）。用户新 commit 经 alternates 直接可见，不需要 fetch。
2. **检出策略与快照边界一致。** 只落盘普通文件（100644/100755）：checkout 后按 tree 遍历删除符号链接与 gitlink 对应路径（gitlink 的空目录一并删）。禁用全部过滤：仓库配置 `core.autocrlf=false`、`core.symlinks=false`，`.git/info/attributes` 写 `* -text -eol -filter -ident`（优先级高于 tree 中的 `.gitattributes`）。`git_checkout_tree(FORCE)` 以 HEAD 为基线并 `set_head_detached`，tracked 文件的增删改由它处理；非跟踪残留只清理本计划自己创建的软链（见决定 6）。测试比较每个普通文件的内容哈希与 blob 字节，不只比文件列表。
3. **只替换 Exact 的文件系统视图。** 阅读区、索引、搜索、比较继续读 Git 对象快照，不变。检出目录只给语言服务器看。
4. **每窗口一份目录；Materializer 退役。** 应用会激活同一项目已有的窗口（`CodeInsightApp.swift:819`），所以同项目不会有两个窗口；按窗口建目录是为了不同项目窗口彼此隔离。目录在关窗时删除；窗口标识只在本次进程内有效，所以启动时的规则是"删除不属于本进程任一活动窗口的全部目录"，不需要任何过期判定。不再有 2 GB 配额：旧机制回收的是无人使用的历史导出，新机制只有活动窗口目录、关窗即删，没有可回收对象；设置页显示检出目录总大小并提供清理。
5. **热切换按固定顺序，就绪有确认。** 同一会话复用时的顺序：暂停新请求 → 等待/取消在途请求（它们可能在 checkout 后 `didOpen` 旧字节，污染服务器）→ `didClose` 全部已开文件 → checkout 目标 commit、重算软链 → 更新会话的快照引用 → `workspace/didChangeWatchedFiles`（新增/删除/修改分别 type 1/3/2）→ **等待服务器确认已吸收变化** → 恢复请求。确认信号按服务器：RA 用 `experimental/serverStatus` 从非空闲回到空闲；Pyright 用分析进度（`$/progress`）结束；tsserver 用项目加载进度结束。S0 验证这三种信号是否可靠；拿不到可靠信号的服务器，切换期间保持"准备中"直到 S0 确定的替代判定成立，不能把通知发完当成就绪。取消、失败、关窗、清理遵守同一顺序：等在途 checkout/prepare 结束，再关会话、删目录；checkout 部分失败后旧会话不得回到 ready，走重启或报不可用。
6. **复用条件覆盖配置与环境。** 候选与活动会话的 `ReuseKey` 除 `versionIdentity`、`configFingerprint` 外全部相同才热切换：语言、分析单元、`featureSelection`、`environmentFingerprint`（实际解释器等）、`trustMode`、`toolVersion` 任一变化都重启（它们是初始化参数或无法可靠热更新的环境）。`configFingerprint`（Cargo/pyproject/tsconfig 内容）变化走热更新，由服务器自己重载，S0 验证三种服务器都能重载。切换成功后同步替换会话的 profile、完整缓存键、结果归因与崩溃重启参数，不能只换 commit ID。结果缓存 `ReuseKey.versionIdentity` 仍按 commit。
7. **工作区 ↔ commit 双活动会话。** 工作区读真实目录、commit 读检出目录，两个根各一个会话槽；切换只换当前指向，另一槽待命不关闭；信任撤销、语言/单元变化、关窗、清理缓存关闭两槽。待命槽上到达的旧请求按 generation 拒绝。**重新激活待命槽也是复用**：它仍持有停放时快照的 `didOpen` 缓冲，而回到工作区会重新捕获快照、回到检出槽可能换了 commit，所以重新激活同样走决定 5 的顺序（关闭缓冲 → 更新快照引用 → 通知 → 确认 → 恢复；工作区槽省去 checkout 一步），不能只换快照 ID。待命槽是否按空闲时间或内存上限释放，依 S0 的 RSS 数据决定，默认不加。
8. **依赖借用按语言各取最佳方式，并在界面标注。**
   - TypeScript：工作区中存在、且目标 commit tree 中对应目录存在的每个 `node_modules`，软链到检出目录同一相对路径。已验证可解析。
   - Python：`workspace/configuration` 对 `python` 节回答 `pythonPath`，取工作区对应单元根的 `.venv/bin/python` 或 `venv/bin/python`；没有则维持当前行为（PATH）。commit 自己的 `[tool.pyright]`/`pyrightconfig.json` 配置了相对 `venvPath` 时同时软链该目录。已验证仅软链无效、`pythonPath` 有效。工作区模式同样回答 `pythonPath`（同一规则，顺带修正工作区看不到 `.venv` 的问题）。`PyrightProvider.interpreterIdentity` 必须用实际回答的解释器计算，否则 `environmentFingerprint` 与真实环境不一致。
   - Rust：Safe 模式依赖来自 `~/.cargo`，无需借用。Trusted 模式借用工作区 `target` 的收益未验证（cargo 指纹含源码路径），本计划不做。
   - 软链集合每次切换重算：以目标 tree 与当前工作区为输入得到应有集合，删除不在集合中的旧链（不只是父目录消失的情况，Python 环境路径变化也在内），再补建；与目标 commit 的 tracked 路径冲突时 tracked 内容优先、不建链。
   - 结果路径分类在会话层做：服务器可能返回软链路径（检出目录下）或真实路径（工作区 `node_modules`、`.venv`）。两种拼写都要归为依赖文件（与今天 `~/.cargo` 同类），从真实路径读取，不得当作快照相对路径去 `snapshot.readBytes`；关系查询中直接读快照的路径同样处理。
   - 标注：`ExactAnalysisEnvironment.limitations` 增加"依赖来自当前工作区，可能与该 commit 不一致"。
9. **沙箱为长驻进程重定。** 现有 `ulimit -t 60` 是累计 CPU 时间，长驻会话持续索引与切换会触发 `SIGXCPU`，不能沿用；S0 测量实际 CPU 用量后改为按单次请求/切换的监控或显著提高上限。同处的 `ulimit -v` 为 512 GiB 地址空间，预计不构成限制，但 S0 同时记录 VSZ 并观察分配失败。可写集：检出目录本身不可写（与今天导出目录一致，今天放行的只有 provider 缓存和 Trusted 的 `project/target`），tsserver 的 `tsbuildinfo` 等需要落点的写入必须指向缓存目录或禁用；借用依赖的真实目录、用户源码与 `.git` 保持不可写。历史分析在真实沙箱下验证这些边界。
10. **文档承诺改写。** product.md "不执行 Git checkout" 改为"不改动用户工作区与仓库；历史 commit 的精确分析在应用自有目录中检出"。

## 不做

- 不改用户仓库的 HEAD、索引、`.git/` 任何内容。
- 不保留按 commit 的会话 LRU（同根热切换后不需要）。
- 不处理子模块、LFS、本机未缓存的 Cargo.lock 版本。
- 不做跨 commit 符号映射、变更总览（另立题）。
- 历史定位（选择器只走 HEAD 第一父链最多 500 条，搜索只匹配 SHA 前缀与摘要，分支/tag 不参与）与本计划机制独立；若要做，另起小任务并行。

## 阶段

**S0 门槛（先于 S1 之后的一切；与 S1 可并行）**
- 打包应用基线：toydb 上每次切换记四段墙钟——正文出现、基础索引可用（大纲/搜索）、精确分析就绪（状态栏）、返回刚读过的版本；HEAD~5 与 HEAD~100 各 3 次；记录语言服务器 RSS（单会话与双槽各一组）。codex（`codex-rs/` 单元，8,274 commits，2,612 个 `.rs`）上同样两组。
- 跨文件更新：三种服务器各一例，从文件 A 跳到两个 commit 之间在文件 B 中新增/移动的声明，热切换后 definition 指向新位置；同时记录"状态栏就绪"与"首个正确跨文件结果"两个时间，后者是验收口径。
- 就绪信号：确定决定 5 中每种服务器可用的确认信号及其在切换后的时序；拿不到的给出替代判定。探针必须用 Cairn 的 `initialize` 能力集（`LSP.swift:502`，已含 `window.workDoneProgress` 与 `experimental.serverStatusNotification`）而不是脚本自己的，否则结论不能迁移到 S2。
- 配置变化：Cargo.toml features、pyproject/pyrightconfig、tsconfig 在两个 commit 间不同时，服务器是否正确重载；不能的列为重启条件。
- 真实沙箱：用 Cairn 的 Sandbox 启动热会话，连续切换 20 次以上，记录 CPU 累计用量、是否触发 `SIGXCPU`、写入拒绝日志；确认检出目录不可写、借用目录不可写。
- 用原型脚本在 codex 上量热 RA 切换（含 Cargo.lock 变化的一组）。
- 结论写入 evidence README；任何一项不达标，先修订决定 5/6/9 再进 S2。

**S1 检出目录替代导出**（CodeInsightGit + CodeInsightExact/AppModel）
- 新类型 `CheckoutRoot`：建仓、alternates、过滤禁用、`checkout(commit)`（含符号链接/gitlink 清理）、`remove()`；父目录按窗口标识；启动清理孤儿目录。
- `ExactCoordinator` 用它替代 `Materializer.materializeAndRetain`；其余流程（仍冷启动）不变。
- Materializer 职责迁移：`clearMaterializedCache` 的 epoch 门控与"清理期间不进新任务"保留，改为清理全部窗口的检出目录；设置页按钮与文案改为检出目录；选择器"已物化"徽标及说明删除（新机制下没有对应状态）；`ExactSelfTest` 中的引用更新；`MaterializerError.directoriesInUse` 对应的资源释放保护测试迁移到新类型。
- 测试：对两个 commit 依次 checkout，普通文件集合与内容哈希与 `CommitSnapshot` 一致，符号链接与 gitlink 不落盘；预置的未跟踪软链在再次 checkout 后仍在；带 `.gitattributes eol=crlf` 的 fixture 不被转换；alternates 指向的仓库移走时报可识别错误；同仓库两个协调器（两个检出目录）互不干扰。
- 完成后删除 Materializer 及其测试。

**S2 热切换**（依赖 S0 通过与 S1 合入）
- `LSPLanguageSession.switch(to:)` 实现决定 5 的顺序与就绪确认，暴露"切换中"状态；在途请求取消或等待的策略由 S0 的时序决定。
- `ExactCoordinator`：按决定 6 判定热切换或重启；成功后替换 profile、缓存键、归因、重启参数；双槽（决定 7）。
- 回归（假 LSP）：切换后旧打开文件被关闭、切换中不发 `didOpen`、就绪确认到达前请求不被回答、checkout 失败后会话不回到 ready；featureSelection 变化触发重启而非复用；待命槽上的旧请求被拒绝。

**S3 依赖借用**（依赖 S1；与 S2 并行）
- 决定 8 全部内容。会话层的路径分类改动在 `LSPLanguageSession` 的位置解析处，不只在协调器。
- 测试：软链集合重算按工作区/目标 tree fixture 做单元测试（含删除旧链、tracked 冲突）；Pyright/tsserver 在 llm-tools 的 commit 上用 CLI 验证第三方符号 hover/definition，并验证**打开依赖源码**与**关系展开**不因快照缺少该文件而失败，软链 URI 与真实 URI 两种返回都覆盖。

**S4 文档与原生验收**
- product.md、architecture.md 改写（只读承诺、Exact 根、依赖借用、窗口隔离、沙箱、限制）；本文件删除；evidence README 补入前后对比。
- 原生：toydb 四段计时对比 S0，并以"首个正确跨文件结果"为准；切换后从文件 A `⌘` 单击跳到文件 B 中该 commit 新增的声明；llm-tools commit 下 TS/Python 第三方 hover、打开依赖源码、关系展开；两个不同项目窗口各停在 commit 互不影响；关窗后目录删除；Refresh、切回工作区（待命槽即时）、恢复会话、清理检出目录后 Exact 重建。

## 风险

- 最大风险：切换变快，却把旧索引或旧配置的答案标成新 commit 的结果。决定 5/6 与 S0 门槛针对它；验收以跨文件结果为准，不以状态栏为准。
- 用户仓库 gc 后旧 commit 不可达：checkout 失败，Exact 报不可用，阅读不受影响（快照已另有缓存）。
- 规模：原型仓库都很小；codex 上的 manifest 变更重载成本与 RSS 待 S0 测量。
- 长驻进程的资源：取消 `ulimit -t` 后需要替代的失控保护（S0 给出用量，S2 定监控方式）。
