# M10/M11 产品化收口总验收

原验收日期：2026-08-30

修复计划复验：2026-09-01

`PLAN_BASE`：`7ec7c6c3b185b3085aef621cf62d6a3ffcaa38b1`

历史实现 HEAD：`a590c909f1279c3a2c8a8d78d15a9c1d69a8865d`

本轮 `REMEDIATION_BASE`：`3166644822715527a3e5ed3430ebb15962661c75`

当前结论：**BLOCKED**。原来的语言 checkbox 阻塞已在 2026-09-01 复验中解除；真实
`NSOpenPanel`、Rust checkbox、Open、Exact ready、A → B → Back → C 分支与 Restore
均已通过。新的唯一执行阻塞是 Computer Use 能读取并高亮 Reader 右键菜单里的
`Show Callers`，但无法对这个自定义 AppKit menu item 完成 AXPress；因此
Resolution Inspector、Freeze Path、Freeze Results、Reading Set 创建和同 bundle 重启恢复
仍未到达。计划禁止用预写 session、UserDefaults 或 self-test 注入绕过，未完成项继续
如实记 BLOCKED。

## 2026-09-01 真实 bundle 复验增量

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
| 1 | First run | BLOCKED | PASS：唯一 bundle 空启动、真实 `NSOpenPanel` 选择 repo、三语言完整显示、AX 顺序正确、0 项 Open disabled。BLOCKED：Computer Use 对 checkbox 的元素/坐标点击会关闭 native pipe；Tab/Space 未改变值，未完成 Rust → Open → files visible。 |
| 2 | Explain | BLOCKED | 自动/17 通道已证明 relation/Inspector source/verification；真实任务被 #1 阻断。 |
| 3 | Branch | BLOCKED | AppKit 测试证明 A → Back → B → Restore A 不丢 B；真实 bundle 任务被 #1 阻断。 |
| 4 | Freeze path | BLOCKED | frozen source、producer/path 顺序与 drift 测试 PASS；真实 bundle 任务被 #1 阻断。 |
| 5 | Freeze results | BLOCKED | 50 cap、skipped summary、`Freeze Results` title/tooltip/AX 测试 PASS；真实 bundle 任务被 #1 阻断。 |
| 6 | File reading | BLOCKED | ReaderUI 的 Structure/Overview/Focus/隐藏命中/复制合同 PASS；真实 bundle 回放被 #1 阻断。 |
| 7 | Restart boundary | BLOCKED | PASS：新 bundle restart/empty-session 文案明确 session-only。缺口：没有在真实 bundle 中先创建 Reading Set，因此无法证明同 bundle 重启恢复它。 |
| 8 | Accessibility | BLOCKED | PASS：空态 Trail、disabled Reading Height、三语言 picker 与 Open gate 的 AX。缺口：分支、Reading Set 与重启恢复的 live AX 未到达。 |

## 视觉与 AX 证据

| 要求 | 状态 | 文件 |
|---|---|---|
| First-run language picker | PASS | `s1-first-run-language-picker.png`、`v0-first-run-language-picker.png` |
| Trail 空态 / 最小窗口分叉 | PASS（部分） | `v0-empty-session.png`、`s2-trail-900x600.png` |
| Trail 线性 / 分叉 / detail 共三张 | BLOCKED | 仅空态与一张分叉证据；线性/detail live bundle 未到达 |
| Reading Set 来自 Trail / Relations | BLOCKED | live bundle 未到达 |
| Light / Dark / SI Classic 同内容 | BLOCKED | offscreen scroll-layer 抓图无效并已删除；real-window capture 在受限环境返回 Cocoa 512 |
| Reading Set 恢复 + session-only Trail | BLOCKED | 仅 `v0-empty-session.png` 证明 Trail 空态；未创建可恢复 Reading Set |

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
- 正式 session `/Users/siancao/Library/Application Support/Cairn/dev.cairn.Cairn/session.json` 保持 2026-08-27 16:15:32 +0800 的旧 mtime，SHA-256 为 `c40fa627e836e8f7596ee2cca836db84a6ed0634309a90cb0509c702b3368de7`；V0 仅创建唯一 bundle 的 Preferences。
- `git diff --check` PASS；最终 acceptance savepoint 后再次检查 index、worktree、untracked 三域。

## 解阻条件

继续 V0 需要一个可对原生 `NSAlert` checkbox 执行真实鼠标/AX press 的 Computer Use 通道，或用户在最终隔离 bundle 中手动选择 Rust 并点击 Open。解阻后从任务 1 的 checkbox 步骤继续，不需要重做已经 PASS 的自动门禁。
