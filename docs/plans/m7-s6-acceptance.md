# M7-S6 总验收报告

**基线**：`0f91b69`（S5B），工作树干净。执行者：监工（Opus），全部数字为真机实测。
**日期**：2026-07-29。

> **本报告的规矩**：每一行都要答"谁走过这条路"。
> 没有自动化证据的，写"**无自动化覆盖**"，不写空格、不写"应该没问题"。

---

## §0 门禁总表

| 项 | 结果 | 备注 |
|---|---|---|
| `swift test` | **381 全绿 × 5 次连跑，失败数 0/0/0/0/0** | 不看单次绿，见 §8.1 |
| `scripts/ci.sh` | **exit 0** | |
| `run-self-tests.sh` | **pass=12 fail=0 hang=0** | 覆盖分布见 §1 |
| canonical dump | **零 diff** | 23 个 `semanticFixture`，含在 `swift test` |
| ripgrep gold | **16 条，nostrong=0，unexpected failures=0** | |
| tokio gold | **17 条，nostrong=0，unexpected failures=0** | |
| `goldset/` git diff | **0 行** | |
| `RECORD` | **UNSET** | |
| 跑后孤儿进程 | **0** | `ppid=1` 的 rust-analyzer |

---

## §1 覆盖面分布（报"12 通道 PASS"时的强制附件）

按 `selfTestReaderRelation|selfTestSelectRelationEdge|relationTree|selfTestVisibleRelationEdge` 统计：

| 通道 | Relation 触点 |
|---|---:|
| **exact** | **100** |
| reading | 6 |
| pin | 2 |
| base / project-git / project-non-git / tabs / search / diff / history / switch / open | **0** |

> **"12 通道全 PASS"对 References 的信息量约等于"1 通道 PASS"。**
> 这句话必须与 `pass=12` 同时出现，否则就是误导。

---

## §2 入口路径

| # | 路径 | 证据 | 结论 |
|---|---|---|---|
| E1 | 右键菜单 → 四个方向 | `Tests/CodeInsightAppTests/ReaderContextMenuTests.swift` 三条，**直接驱动 `textView.menu(for: event)`**（当初坏掉的正是这条 AppKit 路径）：四方向各拿到 offset、只读铁律无编辑项、多标签取对 document | ✅ |
| E2 | 方向分段控件切换 | `relationProgrammaticRootDirectionAndReloadChangesDoNotNavigate`（切换不产生跳转）+ exact 通道 | ✅ |
| E3 | 展开 edge 下钻 | `RelationTreeModel.swift:471` `queryTarget ?? target`；exact 通道展开步骤 | ✅ |
| E4 | 双击 → re-root | `relationReferenceDoubleClickDoesNotNavigateTwiceAndHistoryReturns`（位置行不 re-root、不跳两次） | ✅ |
| E5 | 键盘 Enter 打开 | S5A `relationOutlineKeyboardPreservesReferenceConsumptionRules`，**走真实 `NSOutlineView`** | ✅ |

## §3 结果消费路径

| # | 路径 | 证据 | 结论 |
|---|---|---|---|
| C1 | 单击符号行 → Context 更新 | `3c5c4a1`；监工注入撤回 `queryTarget ??` → 该测试变红 | ✅ |
| C2 | 单击位置行 → 阅读区导航 | `2d37412`；监工三次注入（去掉导航／去掉规则边界／伪造程序性跳转）证明 5 条断言全有牙 | ✅ |
| C3 | 双击不跳两次 | 同 E4 | ✅ |
| C4 | 导航历史返回 | Fix3 `historyBack=true`（exact 通道实测）+ S5A 大结果语料下再验 | ✅ |
| C5 | Pin 只冻结 Context 不冻结阅读区 | `relationReferenceSingleClickNavigatesWhileContextIsPinned` | ✅ |

## §4 四方向 × 来源层（主矩阵）

| 方向 \ 来源 | Exact（fake） | Exact（**真实 RA**） | Fuzzy / 启发式 | Local |
|---|---|---|---|---|
| callers | exact 通道 | ✅ `real-incoming-calls` → **`relation_root`(lib.rs) + `main`(main.rs)** | ✅ | n/a |
| calls | exact 通道 | ✅ `real-outgoing-calls` → **`answer`(lib.rs)** | ✅ | n/a |
| implementations | exact 通道 | ✅ `real-implementations` → **`ExactFixtureBackend`(lib.rs)** | ✅ | n/a |
| references | ✅ S4（分列 Exact 组） | ✅ `real-references`（**见下方限定**） | S3 两阶段扫描 | S2 |

**真机实测**（`sandbox-exec` 与 `rust-analyzer` 均可用）：
`skipped rust-analyzer steps = 0`，`summary realProvider = passed`，`channel=exact exit=0`。

> **一处如实限定**：`real-references` 只输出布尔 `textDocumentReferencesReached=true`，
> **不像其它三条那样附落点清单**。它的落点是在 S4 验收时通过
> "Exact 组包含 `main.rs:` 行"单独确认的，**不是本次这条 artifact 直接给出的**。

**S4 的三条去重断言**：同位置双命中带 `heuristic also matched` ✅／
只 Fuzzy 命中不被顶掉 ✅／只 Exact 命中出现 ✅。

## §5 模式与语境

| # | 语境 | 证据 | 结论 |
|---|---|---|---|
| M1 | Safe / Trusted | `6808dfd` 修 overlay trust 串档；exact 通道 trust-revoke 变体 | ✅ |
| M2 | offline | `runRealOfflineCoverageVariant`；空态文案不谎称能力 | ✅ |
| M3 | 历史快照 | `runHistoricalExactVariant`；`relationTreeProjectReferencesReadHistoricalCommitSnapshot` | ✅ |
| M4 | git / 非 git 语料 | 通道各跑一次（`project-git` / `project-non-git`） | ✅ |
| M5 | pinned / unpinned | 同 C5 | ✅ |
| M6 | 多标签 | Fix3 `selfTestTabCount == 3`；E1 多标签取对 document | ✅ |
| M7 | 大结果规模 | S5A：18,001 候选 → 201 verified，首批 2,500ms，可见 201 行，footer `201 verified references · partial`；视口门控 `referenceScannedCount=55`（注入全扫 3,885,000） | ✅ 但见 §7 待观察 |

## §6 诚实与计数合同

| 状态 | 文案 | 证据 |
|---|---|---|
| complete | `M references` | ✅ 三种来源构成（fuzzy-only / exact-only / mixed）各有断言 |
| display cap | `Showing first 500 of 501 references` | ✅ |
| service truncated | `N verified references · partial` | ✅ **断言不含 `" of "`、不含伪造总数** |
| 组计数 scope | 组副标题只数本组，跨组总数挂兄弟节点 | ✅ S4-Fix；监工注入撤回后 3 条测试 4 个断言变红 |
| 空态 | 四种 `exactState` 不折叠 | ✅ |
| AX | provenance 可达、无编辑入口 | ✅ 读 `accessibilityValue()` / `isAccessibilitySelectorAllowed`，**非 label 字段**；监工两条注入均变红 |
| 视觉设置 | 默认零观感变化 | ✅ 逐字节快照对**字面量**基线；监工注入 `declarationMarkerAlpha 0.7→0.45` 后两条断言同时变红 |

---

## §7 未解决 / 需要人来判断（**不许静默略过**）

| # | 项 | 状态 |
|---|---|---|
| **B3** | G6.2 帧率手感 | **人工项，BLOCKED**。禁止用 fragment 数替代 |
| **B4** | ripgrep 语料 10 个 crate 缺 `Cargo.toml` | **不可用于真实 RA 实验**（gold 不受影响，走我们自己的索引器） |
| **B2** | `ExactOverlay.ReuseKey` 不含 worktree 内容身份 | 无稳定复现，S0B 红线内未改 |
| **N1** | 大语料 References **首批延迟 2,500ms** | 形态像撞时间预算而非真算了 2.5 秒。诚实标注正确（`partial` + 不声称真实总数），但**手感需决策者真机感受后再决定是否立项** |
| **N2** | 内存断言只挡粗大回归 | 监工三次实测 delta = **-14.1 / -28.4 / +4.4 MB**（前两次为负，属退化性通过）。有牙（64MiB 注入 → delta 86.9 → 红），但中小回归被 TextKit 回收噪声吃掉。**只能写"粗大内存回归有守护"** |
| **N3** | `real-references` 无落点清单 | 见 §4 限定 |

---

## §8 本轮暴露的方法论问题（比通过更值得记）

1. **相关不是因果**（§8.2）：孤儿进程存在 + 失败递增 + 防线确实缺 SIGTERM，
   三个真事实拼出一条假因果链。三臂实测才定出真因是 QoS 饿死。
   **"修好了"不等于"诊断对了"。**
2. **测法不同则数字不可迁移**：S5A 的 20 次内存表用独立进程，
   通道内是单进程序列，**那些数字不支持通道里那条断言**。
3. **注入要逐条报红绿**：M7-Fix2 报"四方向全 PASS"，实测撤回只有 1 条变红。
4. **语料形似而质不同**：三个声明冒充"引用"、fuzzy-only 场景两数恰好重合——
   都让断言永远绿。
5. **验收工具本身要先验**：本轮监工三次喂错工具路径
   （`CodeInsightApp` vs `codeinsight-app`、`codeinsight-cli` vs `codeinsight`、
   旧二进制未重建），外加一次 zsh `noclobber` 假 `exit=1`。
   **跑之前先 `ls .build/debug/`。**
6. **派发词的前提要核实**：S5B 首轮监工把 `:980` 写成"当前行 alpha"，
   实为 `drawDeclarationMarker`。**Codex 停下来质疑规格是对的**——这个行为要鼓励。

---

## §9 结论

**M7 主线（全局 References / 影响面导航闭环）完成。**

四个方向的真实 rust-analyzer LSP 往返**首次全部打通并有自动化守护**——
这是 M7 之前不存在的能力（建表时 `runRealExactVariant` 对 `relationTree` 触点数为 0）。

**未完成 / 需人判断的六项已在 §7 逐条列出，没有一项被静默略过。**
