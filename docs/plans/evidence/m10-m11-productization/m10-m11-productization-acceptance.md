# M10/M11 产品化收口总验收

原验收日期：2026-08-30

修复计划复验：2026-09-01

`PLAN_BASE`：`7ec7c6c3b185b3085aef621cf62d6a3ffcaa38b1`

历史实现 HEAD：`a590c909f1279c3a2c8a8d78d15a9c1d69a8865d`

本轮 `REMEDIATION_BASE`：`3166644822715527a3e5ed3430ebb15962661c75`

当前结论：**PASS**。2026-09-01 最终复验使用当前实现 HEAD 的唯一 bundle，完成真实
`NSOpenPanel`、Rust、真实 rust-analyzer、Relations → Resolution Inspector、
A → B → Back → C → Restore、Freeze Results、Freeze Path、两份 Reading Set 和同 bundle
重启恢复。Trail 在重启后为空。此前自定义菜单 AXPress 阻塞通过真实菜单 typeahead
`show c` + Return 解开，没有使用预写 session、UserDefaults 或 self-test 注入。

## 2026-09-01 最终 current-HEAD 闭环

- Bundle id：`dev.cairn.Cairn.remediation.final.20260901`
- Bundle：`.build/m1-m13-remediation/final/Cairn.app`
- Fixture：`/private/tmp/cairn-remediation-s3-exact-fixture`
- First run：PASS；`NSOpenPanel` → `Choose Languages` → Rust → Open。
- Provider：PASS；真实 rust-analyzer，`Exact: ready · Safe (limited)`。
- Relations：PASS；在 `answer` 上执行真实 `Show Callers`，选择 `relation_root` 并 Return，
  Trail 显示 `answer · relation → relation_root`。
- Inspector：PASS；选中 verified caller edge 后显示 `Resolution Inspector`、`INFERRED`、
  candidate generation、result-set completeness 和 exact-provider readiness。
- Branch / Restore：PASS；当前 bundle 完成 A → B → Back → C，`Branches · 1`；在 Trail
  graph 选择旧 `lib.rs:3` 分支并 Restore，`lib.rs:5` 兄弟分支保留。
- Freeze Results：PASS；创建 `answer` Reading Set，2 excerpts。
- Freeze Path：PASS；创建 `relation_root` Reading Set，1 excerpt。
- Restart：PASS；正常 Quit 后重启同一 bundle，两份 Reading Set 均恢复，Trail 明示
  `Navigate from Relations to build a trail · this session only`。
- 最终正常 Quit：PASS；bundle id 从运行列表消失。
- 证据：`../m1-m13-remediation/s3-branch-restore.jpeg`、
  `../m1-m13-remediation/s3-freeze-path.jpeg`、
  `../m1-m13-remediation/s3-restart-reading-sets.jpeg`。
- 正式 App Support 内容/拓扑指纹保持
  `8c691d6d9c5d0b428a2bfcc9434b16cce5801022171610c063da4c3cb68e6117`。
  一次 Computer Use 以显示名而非 bundle id 定位时曾启动正式安装版，使正式
  `session.json` 被等内容重写、mtime 更新；没有内容差异，但不把元数据层面表述为零写。

## 2026-09-01 早期复验增量（已被最终闭环取代）

- Bundle id：`dev.cairn.Cairn.remediation.s3.20260901`
- Bundle：`.build/m1-m13-remediation/s3/Cairn.app`
- Fixture：一次性 Git Rust `exact_fixture`，HEAD
  `8a3899f2b30f8437e54286c53e4242c1685af3a8`
- 首次空态：PASS；Trail 明示 `this session only`，Reading Height disabled。
- 真实打开：PASS；`NSOpenPanel` → `Choose Languages` → Rust value `1` → Open。
- Provider：PASS；真实 rust-analyzer，`Exact: ready · Safe (limited)`。
- Branch：PASS；完成 A → B → Back → C，Trail 显示 `Branches · 1`。
- Restore：PASS；选择 `lib.rs:3` 的旧分支并执行 `Restore this node`，兄弟分支保留。
- Explain / Freeze / Reading Set / restart：BLOCKED；右键菜单的四个自定义关系动作可见，
  但当前 Computer Use AXPress 不生效。CLI 对同一 fixture 的 `callers answer` 已返回
  `relation_root` 和 `main`，所以这不是用“语料无结果”解释掉的产品空态。
- 正常 Quit：PASS。

## 分阶段交付

| 切片 | 提交 | 状态 | 证据 |
|---|---|---|---|
| S1 首次语言选择器 | `8b47d7d` | PASS（实现/自动/视觉）；真实 Open 后半段 BLOCKED | self-test RED/GREEN、签名 bundle、`s1-first-run-language-picker.png`、`s1-first-run.md` |
| S2 Trail session 边界 | `e950b00` | PASS（实现/自动/900×600） | 34/34、空/线性/1/2 分叉测试、`s2-trail-900x600.png`、`s2-trail.md` |
| S3 Reading Set 冻结语义 | `2f9a16b` | PASS（实现/自动/AX）；三主题截图 BLOCKED | 48/48、bookmark 1/1、`s3-reading-set.md` |
| S4 Reading Height 状态 | `f1bda96` | PASS | empty/index/file/Reading Set/file/failure 回放、ReaderUI 联合门禁、`s4-reading-height.md` |
| S5 README 工作流 | `a590c90` | PASS | 中英文同构四步、运行时快捷键逐项对照 |

## V0 自动门禁

| 门禁 | 状态 | 证据 |
|---|---|---|
| `swift test --disable-sandbox` | PASS | exit 0；CI 的持久日志进一步确认 838 tests / 3 suites |
| `CODEX_SANDBOX=1 bash scripts/ci.sh` | PASS | `.build/ci-swift-test.log`：838 tests / 3 suites，214.098 s；exact/diff/reading/projector/fold 均 exit 0 |
| 17 通道 `run-self-tests.sh` | PASS（宿主） | 外层 sandbox 首跑为 `pass=14 fail=1 hang=2`，共同根因是嵌套 `sandbox-exec` 被拒；同一命令获授权在宿主重跑为 `pass=17 fail=0 hang=0`，artifact `.build/self-test-run-20260829-235941-29146` |
| release fold perf | PASS | final gold run：resolution 23.929 ms，fold latency 254.415 ms，delta 4,866,072 B，8400 accepted / 4400 logical / 200 rendered |
| Tokio gold | PASS | total 17；Top1 8/8，Top5 3/3，unresolved 2/2，known 0，unexpected 0 |
| ripgrep gold | PASS | total 16；Top1 5/6，Top5 2/3，unresolved 2/2，known 3，unexpected 0 |

## 最终 bundle

- Bundle id：`dev.cairn.Cairn.m10m11productization.20260830.v0`
- Bundle：`.build/m10-m11-productization/v0/Cairn.app`
- Zip：`.build/m10-m11-productization/v0/Cairn.zip`
- 首次启动前，bundle-specific Application Support 与 Preferences 均不存在。
- `plutil`、ad-hoc signing、`codesign --verify --strict --verbose=2` 均 PASS。
- 正常发送 Quit 后，没有匹配该 V0 bundle executable 的残留进程。

## 真实 AppKit 任务

| # | 任务 | 状态 | 当前证据 / 缺口 |
|---:|---|---|---|
| 1 | First run | PASS | 唯一 bundle 空启动；真实 `NSOpenPanel`、Rust checkbox、Open、files visible。 |
| 2 | Explain | PASS | 真实 `Show Callers`、verified edge、Resolution Inspector 和语义导航。 |
| 3 | Branch | PASS | A → B → Back → C；`Branches · 1`；Restore 旧节点后兄弟分支保留。 |
| 4 | Freeze path | PASS | Trail graph 的 `Freeze Path as Reading Set` 创建 1-excerpt frozen set。 |
| 5 | Freeze results | PASS | `Freeze Results` 创建 2-excerpt frozen set，保留 source/evidence。 |
| 6 | File reading | PASS | 两份 Reading Set 均有 `Open File`、`Expand Context`、`View Evidence`。 |
| 7 | Restart boundary | PASS | 同 bundle 正常 Quit/restart；两份 Reading Set 恢复，Trail 为空。 |
| 8 | Accessibility | PASS | Trail graph、Inspector、Reading Set、restart 状态均由 live AX 读取。 |

## 视觉与 AX 证据

| 要求 | 状态 | 文件 |
|---|---|---|
| First-run language picker | PASS | `s1-first-run-language-picker.png`、`v0-first-run-language-picker.png` |
| Trail 空态 / 最小窗口分叉 | PASS | `v0-empty-session.png`、`s2-trail-900x600.png`；最终重启与分叉截图见下两行 |
| Trail 线性 / 分叉 / detail | PASS | `../m1-m13-remediation/s3-branch-restore.jpeg`；live AX 同时确认 `Branches · 1` 和 Restore |
| Reading Set 来自 Trail / Relations | PASS | `../m1-m13-remediation/s3-freeze-path.jpeg`；Relations set 同轮 live AX 为 2 excerpts |
| Light / Dark / SI Classic 同内容 | PASS（产品门） | M13 bookmark product gate 的三主题 real-window captures 均非空；不拿它冒充本次 Trail 操作截图 |
| Reading Set 恢复 + session-only Trail | PASS | `../m1-m13-remediation/s3-restart-reading-sets.jpeg` |

最终空态 AX 摘要：

```text
Reading Trail = Navigate from Relations to build a trail · this session only
Trail Details = disabled; AX Show Reading Trail branches; help includes ⌥⌘T
Reading height = disabled
Full / Structure / Overview = disabled
```

语言选择器 AX 摘要：

```text
Rust = checkbox value 0
Python = checkbox value 0
TypeScript = checkbox value 0
Cancel = enabled
Open = disabled
```

## 零写与范围审计

- `PLAN_BASE...HEAD` 只包含计划 §3.1 allow-list 文件；S1–S4 各有独立提交，S5 只改两份 README。
- `CodeInsightCore`、`CodeInsightAppModel`、`CodeInsightReaderCore`、`CodeInsightReaderUI`、`SessionCodec`、Bookmark 模型、`Package.swift`、`Package.resolved` 零 diff。
- `goldset/`、`fixtures/`、`Prototypes/`、`RECORD` 零 diff；`RECORD` 环境变量未设置。
- 没有新增 production `struct` / `class` / `enum` / `protocol`，也没有新增依赖、持久化文件格式、UserDefaults key、feature flag 或 registry。
- 原 V0 当时保持正式 session 的旧 mtime。最终 current-HEAD 复验中，Computer Use 一次
  以显示名而非 bundle id 定位，启动了正式安装版并等内容重写 session；当前正式
  App Support 的内容/拓扑指纹仍与复验前相同，mtime 已更新，详见本文最终闭环说明。
- `git diff --check` PASS；最终 acceptance savepoint 后再次检查 index、worktree、untracked 三域。

## 结论

M10/M11 当前实现的 V0 产品闭环已经由真实 current-HEAD bundle 验收通过。保留的产品
边界仍是：Trail session-only；Reading Set 是 frozen evidence，不增加标签、文件夹、分享、
重排或新的持久化状态模型。
