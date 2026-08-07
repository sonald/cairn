# M10 总验收

日期：2026-08-07。结论：PASS；唯一受限项为 sandbox 内真实 provider 启动，按计划单列 BLOCKED，未以 fake provider 替代。

> **纠错复验**：此前版本的 N2 只有 Trail 数据模型，没有 D4/D5 指定的常驻路径条与分支浮层，因此旧的
> “M10 全部完成 / UIUX PASS”结论无效。现已补齐真实 UI、可发现入口、AX、三主题截图和 tokio 分支恢复，
> 并重新执行全量门禁；以下 PASS 是纠正后的结论。

## 分阶段交付

| 阶段 | 结论 | 提交 |
|---|---|---|
| G0 / E0 / E1a | PASS | `b8c97b7` |
| E1b | PASS | `7e60a40` |
| E1b0 | PASS | `4314ccc` |
| E1c | PASS | `d1ccbc1` |
| E1d | PASS | `7d717e3` |
| N1 / N2 | PASS（纠错复验） | `5b51fc8` + 本次 Trail UI 纠错提交 |
| E2 | PASS | `a3743bb` |
| E3 | PASS | `93cbbb2` |
| P0 | PASS | `b555d22` |

各阶段的规格、自动化和 UI/AX 证据分别见 `checkpoint-a.md`、`checkpoint-b.md`、`checkpoint-c.md`、
`reading-set-prototype.md`、三张 `resolution-inspector-*.png`、三张 `semantic-trail-{light,dark,si-classic}.png`
与 `semantic-trail-live-tokio.png`。

## V0 自动化门禁

| 门禁 | 结论 | 证据 |
|---|---|---|
| `swift test --disable-sandbox` | PASS | 435 / 435 |
| `scripts/provision-corpora.sh --check` | PASS | tokio 720 个 `.rs`，`be8ee45`；ripgrep 98 个 `.rs`，`4649aa9` |
| `CODEX_SANDBOX=1 bash scripts/ci.sh` | PASS | build、435 tests、exact/diff/reading self-tests 与依赖边界检查全通过 |
| `scripts/run-self-tests.sh` | PASS | 12 / 12；artifact `.build/self-test-run-20260807-144721-57949` |
| `scripts/stress-test.sh --runs 5 --load 8 --timeout 180` | PASS | 5 / 5；0 failure、0 hang、0 error；43 / 45 / 40 / 45 / 44 秒；artifact `.build/stress-test-20260807-143314-41932`；residual process 0 |
| `scripts/run-gold-gates.sh` | PASS | tokio Top1 8/8、Top5 3/3；ripgrep Top1 5/6、Top5 2/3；0 unexpected |

stress 的 `feature_scan` 在当前环境不可用（exit 3），脚本按合同诚实记录后仍完成全部 5 轮；这不是 provider 性能数据。

## CUA 任务式验收

原 Inspector / snapshot 截图来自独立 bundle id `dev.cairn.CairnM10`；Trail 纠错复验来自
`dev.cairn.CairnM10Trail` 的 vendored-libgit2 临时包 `.build/m10-trail-app/Cairn.app`。临时 bundle id 只用于
验收，没有进入产品源码或提交。

| 任务 | 时间 | 错误导航 | Back | 丢失位置 | 显式打开完整文件 | 结论 |
|---|---:|---:|---:|---:|---:|---|
| `spawn` → Show Callers → Inspector | 约 5.2 秒到首批可操作关系 | 0 | 0 | 0 | 0 | PASS |
| A `spawn` → B `task_panics` → C `join_all` → Back 到 B → D `abort_all` | 约 76.8 秒（含人工搜索与核对） | 0 | 1 | 0 | 0 | PASS |
| Trail：`spawn` → `task_panics` → Back → `abort_all` → 恢复 `task_panics` | — | 0 | 1 | 0 | 0 | PASS |
| 截断 / name-only 陷阱 | — | 0 | 0 | 0 | 0 | PASS |

- 真实 tokio `spawn` 返回 1096 条关系，首批 500 条并显示 `Show 488 possible matches`；Inspector 同时显示 SOURCE、VERIFICATION、候选完整性、关系结果集完整性、readiness 与 Safe limitations。
- 盲测没有把 Inferred / `name match only` 当成精确事实；Verified、Inferred、Unresolved 走同一 badge 通道，分析限制不抹掉 provider 正向目标。
- 陷阱 fixture 的 AppKit 测试确认 `candidate.complete + candidateRelationSet.truncated + name match only` 默认仍为 Inferred，Inspector 不声称 unique target。
- 最终 snapshot 复验：从 worktree 的 `tokio/src/task/join_set.rs:449 abort_all` 切到 `be8ee45` 后，仍显示并选中第 449 行；测试同时锁定 Trail 节点和 edge 数不变。旧 worktree 的 best-effort replay 仍显示 `replayed against current worktree`。
- 两条阅读任务都能从 Inspector 说明候选来源、完整性、provider 返回及环境限制；没有错误精确推断。
- Trail 纠错任务中，顶部 breadcrumb 从 `spawn ─relation→ abort_all` 切换到
  `spawn ─relation→ task_panics`；浮层仍同时保留 Verified 的 task_panics 与 Inferred 的 abort_all，`⑂ 1`
  不因恢复而消失。

## UI / UX 符合性

PASS。原生 AppKit 最终实现与设计合同一致：Relations 顶部文字按钮和菜单让 Inspector 可发现；
Relations / Inspector 等宽且不重叠；Trail 顶部 32pt 条常驻，breadcrumb 标 cause，`⑂` / `⌥⌘T` 打开
左右分栏 DAG，节点详情同时显示冻结态与当前态并可恢复。Inspector 与 Trail 的 light、dark、si-classic
截图均经人工逐项审计，并有真实 tokio 截图、几何、交互和 AX 断言；没有增加 SwiftUI bridge、第二状态源或非文件 tab。

## 迁移清单

| 旧断言 / 形态 | 新断言 / 形态 | 原因 |
|---|---|---|
| `ExactCoverage` 与 attribution 上独立 `trustMode` / `coverage` | `ExactAnalysisEnvironment` 是 trust 与 limitations 的唯一来源 | 消除双真值，并可同时表达 Trusted+offline、Safe+offline |
| Unresolved 使用独立 subtitle / modifier | Verified / Inferred / Unresolved 共用三值 badge；位置另用 chip | epistemic 状态与位置维度正交 |
| 空 definition 也可能被当作 conflict | 只有非空、可比较且目标不同才是 conflict；`.completed([])` 为 neutral not-corroborated | 空结果不能证明候选错误 |
| `alsoHeuristic` 存储布尔值 | 删除字段，由 preserved trace 的 `corroborated` 派生文案 | 避免重复状态 |
| Possible 默认一次展示 64 条 | Verified 后先展示 Possible 32 条，再可展开到 64 条 | 已批准的同层语义分组与 viewport 预算 |
| diff self-test 固定取 `HEAD~1` | 从历史中选择首个含多行源码 diff 的提交 | docs-only 阶段提交不应让门禁误报 |
| 直接 snapshot 切换只保留文件 | 复用既有 `pendingReplay` 恢复内容位置与 Trail，且不增重复 edge | 满足 commit 精确 replay 合同 |

没有删除既有测试；所有语义变化都保留或加强了对应断言。

## 边界与环境审计

- PASS：CanonicalDump、`goldset/`、`RECORD`、`Prototypes/`、`.zcache/`、`Fixtures/` 零 diff。
- PASS：P0 仅落文档，未实现 M11 Reading Set、非文件 tab、StableSymbolID 或额外状态源。
- PASS：真实 GUI 在无 sandbox、`GIT_CONFIG_GLOBAL=/dev/null` 下由真实 rust-analyzer 达到 `ready · Safe (limited)`；build scripts / proc macros 限制独立展示。
- BLOCKED：sandbox 内真实 rust-analyzer 因 `sandbox-exec: sandbox_apply: Operation not permitted` 无法启动。fake/self-test 只证明编排与 UI，不冒充真实 provider。
- 环境说明：当前 vendored libgit2 读取用户 global Git config 时会挂起；验收以 `GIT_CONFIG_GLOBAL=/dev/null` 隔离该外部配置，未扩大 M10 产品范围。

## 最终评审

PASS。纠错后逐条回读 §1、§3、E0–E3、N1–N2、P0、V0，未发现剩余 FAIL；N2 不再以模型测试冒充
UI 交付。分层无循环依赖，snapshot 不含 ID/ref，trace 不把 stale/cancelled 写入证据，Inspector、Trail、
分支恢复与 snapshot replay 均有真实 UI 和可运行检查。保留的实现均有当前需求，没有为 M11/M12 预建实体。
