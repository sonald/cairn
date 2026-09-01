# M1–M13 系统评审问题修复总验收

验收日期：2026-09-01

`REMEDIATION_BASE`：`3166644822715527a3e5ed3430ebb15962661c75`

实现 HEAD：`e803cf3fa9b9364fbad4d62297981050fe2196a1`

当前结论：**PASS**。S1–S5g、真实产品闭环、同一完整本地 `run-product-gates.sh` 和
远端 Mixed-language product quality run #34 均 terminal success；没有遗留失败或未完成
计划项。

## 切片结论

| 切片 | 提交 | 状态 | 结论 |
|---|---|---|---|
| S1 generation 正确性 | `d64b5835d4c9422c8ea4680cd230569732f84868` | PASS | 单语言打开和 feature switch 均同步 bookmark generation；旧 Attempt 清除；未增加新类型 |
| S2 M13 产品门与视觉判据 | `c7923faf4e485faaa4c2d3dc8edd63e3717ccfda` | PASS | 纯色 bitmap 被拒绝；三主题 AppKit cache 截图、bookmark、restart、正式数据零写均通过 |
| S3 M10/M11 真实闭环 | `1871808d17c0c343724269d5ef1ae52271be1fab` + current HEAD 复验 | PASS | First run、真实 provider、Relations/Inspector、分支/Restore、Freeze Path/Results、两份 Reading Set 与 restart 全部通过 |
| S4 文档与发布口径 | `0ab0a7e0a693905b97cc85e55753d9cc20890b5f` | PASS | README、design、L1/L2/L3/M13 状态与实际范围一致；JavaScript 和公证未被虚报 |
| S5 warning 收口 | `fe1343c8ce47b03f14a5c7e4a365fa68e14e862d` | PASS | 仓库源代码 warning 清零；只余 Wasmedge/Homebrew 宿主路径噪声 |
| S5b CI 日志确定性 | `45b5cbd8fa58b167baa7e344e6806046f5592638`–`6e3122d4823d465ee7f9b148f37682fe281adcd6` | PASS | 安静排水、失败打印和成功摘要合同均生效；它不是宿主 helper 提前退出的根因 |
| S5c cooperative wait 候选 | 无实现提交 | REJECTED | 宿主 RED 稳定；`Task.yield()` 候选仍失败并已还原，test/script 零 diff，不叠 workaround |
| S5d BookmarkPanel 测试进程隔离 | `02f827b6a06ae3b07c5a6a1ac3aab468db4ef16a` | PASS | 主 840 + 隔离 2 = 842；不改测试/产品逻辑；完整产品门单次 exit 0 |
| S5e weak test reference 兼容 | `ac8ad62` | PASS | weak mutable 分离声明/赋值；远端旧 Swift 编译通过，本机 warning=0 |
| S5f BookmarkPanel alignment geometry | `356588d` | PASS | 自测比较 alignment rect，不改产品约束；macOS 15/26 均通过 |
| S5g relation follow readiness | `e803cf3` | PASS | bounded final-state waits；Exact 连续 3 次与远端 run #34 PASS |

代码和脚本修改均由 Luna、reasoning effort `max` 完成；主代理负责 RED/GREEN 复核、
独立测试、真实 bundle 操作、范围审计和提交控制。

## 自动门禁

| 门禁 | 状态 | 证据 |
|---|---|---|
| S1 三个回归测试 | PASS | 3/3；覆盖单语言 generation、跨快照 strict jump、feature switch 清 Attempt |
| `CodeInsightAppModelTests` | PASS | 312 tests |
| `CodeInsightAppTests` | PASS | 84 tests；含纯色/变化像素判据、bookmark/restart |
| AppModel + App + ReaderUI 联合门 | PASS | 412 tests |
| 直接安静 full suite | PASS | 842 tests / 3 suites，220.411 s |
| `CODEX_SANDBOX=1 bash scripts/ci.sh` | PASS | exit 0；主 840 / 3 suites，247.684 s；隔离 2，0.355 s；total 842；后续 self-test/fold 全部通过 |
| 完整 `run-product-gates.sh` | PASS | S5g HEAD 单次 exit 0；17 通道、三 provider、Gold、fold、bookmark/restart 全部通过；artifact `.build/self-test-run-20260901-161631-67126` |
| S5d 失败注入 | PASS | main=839、isolated=1、isolated command rc=9 三种情况均打印对应错误并 exit 1 |
| 远端 workflow | PASS | run `33486436504` / job `99787494893`，HEAD `e803cf3`，16m12s，artifact upload 与 post steps 全部成功 |

产品门关键结果：

- Tokio Gold：17 total，known 0，unexpected 0；
- ripgrep Gold：16 total，known 3，unexpected 0；
- Python Gold：6 total，known 0；TypeScript Gold：10 total，known 0；
- final product fold：resolution 25.343 ms，latency 256.923 ms，delta 21,069,824 B；
- bookmark 三主题与 restart 均 PASS；正式 App Support 门禁前后指纹均为
  `8c691d6d9c5d0b428a2bfcc9434b16cce5801022171610c063da4c3cb68e6117`。

### 完整产品门执行结果与历史诊断

相同命令、相同 HEAD、相同三 corpus：

```bash
CODEX_SANDBOX=1 \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
  bash scripts/run-product-gates.sh \
    /Users/siancao/work/ai/mcp/mcp-python-sdk \
    /Users/siancao/work/ai/morphic \
    /private/tmp/cairn-remediation-mixed-corpus
```

| 环境 | CI | 17 通道 / provider | 终点 |
|---|---|---|---|
| S5g / 完全访问宿主 | PASS：840 + 2 = 842；CI self-tests/fold PASS | `pass=17 fail=0 hang=0`；三 provider、Gold、bookmark/restart PASS | **exit 0**；artifact `.build/self-test-run-20260901-161631-67126` |
| S5d 前 default sandbox（历史） | PASS：842/3，232.508 s | base 14 PASS；Python、TypeScript hang；Mixed sandbox-exec denied | exit 1；artifact `.build/self-test-run-20260901-133131-80177` |
| S5d 前完全访问宿主（历史） | helper 在 AppKit 测试后 rc 0、缺 summary | 跳过 CI 后的 17/17 与其余门 PASS | CI guard exit 1；remainder artifact `.build/self-test-run-20260901-121651-62651` |

最小宿主复现是
`bookmarkPanelSelfTestActionsTargetRowsByUUIDAndExposeTheirStatus|recentProjectClickForwardsStoredLanguageSet`：
两个用例单独 PASS；同进程第一项 PASS、第二项 started 后 helper rc 0 且无摘要。LLDB
证明 runner main 经 `swift_task_asyncMainDrainQueue` 自然退出。S5d 保持两项同一隔离进程
运行并从主进程精确 skip；当前分别 840 与 2，覆盖总数仍为 842。临时 AppKit 插桩与
S5c 候选均已还原。

### 远端 RED → GREEN

| Run | HEAD | 结论 | 证据 |
|---|---|---|---|
| `33479998094` #30 | `a732bf9` | RED | macOS 15 Swift 拒绝 `weak let`；S5e 输入 |
| `33480622895` #31 | `ac8ad62` | RED | 编译与 17 通道通过；BookmarkPanel raw frame 假交叠；S5f 输入 |
| `33483310346` #32 | `356588d` | RED | 840+2 通过；Exact follow rows 未就绪；S5g 输入 |
| `33486436263` #33 | `e803cf3` | CANCELLED | 同 push 的早发 run，被 workflow concurrency 自动取消 |
| `33486436504` #34 | `e803cf3` | **PASS** | workflow Success，16m12s；job Success，16m7s；artifact/post/complete 全 PASS |

最终 artifact：`product-quality-33486436504`，502 KB，SHA-256
`a2675e701b80767553d40367a700f38ab976f799b802ea9d32d771cb1fde3ca1`。远端仅余
Node 20 action deprecation 与 Homebrew tap trust 两条外部 warning，不影响门禁。

## 10 万行 dedicated open

当前实现 HEAD 执行：

```bash
.build/debug/codeinsight-app \
  --self-test-open Tests/Fixtures/m6_reference_density.rust
```

结果：PASS，exit 0；`firstVisibleMS=1898.605`，低于 2.5 s 门槛；
`outlineFacets=1000`，`syntaxVisibleMS=13046.768`。输入法、HIServices 和 spell server
日志属于当前 sandbox 的系统服务噪声，不影响 self-test 的结构化成功终点。

## 最终 bundle

- Bundle id：`dev.cairn.Cairn.remediation.final.20260901`
- Bundle：`.build/m1-m13-remediation/final/Cairn.app`
- Zip：`.build/m1-m13-remediation/final/Cairn.zip`
- `plutil -lint`：PASS。
- ad-hoc signing 与 `codesign --verify --strict --verbose=2`：PASS。
- LaunchServices 启动：PASS；进程 PID `67378` 已确认运行。
- 正常 Quit：PASS；Computer Use 对当前 bundle id 发送 `⌘Q` 后，运行列表不再包含它；
  闭环重启前后均以同样方式正常退出。
- Developer ID 签名 / notarization：NOT RUN；无凭据，且不在本轮范围。

构建使用本机 Homebrew libgit2 fallback，因此保留 Homebrew dylib 打包信息；
`/Users/siancao/.wasmedge/lib` 缺失是外部 linker search-path warning，不是仓库源 warning。

## M10/M11 真实任务

详细逐项证据见
`docs/plans/evidence/m10-m11-productization/m10-m11-productization-acceptance.md`。

| 任务 | 状态 | 当前证据 / 缺口 |
|---|---|---|
| 唯一 bundle 空态与真实打开 | PASS | `NSOpenPanel` → Choose Languages → Rust → Open |
| 真实 provider | PASS | rust-analyzer；`Exact: ready · Safe (limited)` |
| Relations → Inspector | PASS | `answer` → Show Callers → verified `relation_root`；Inspector 显示 source/completeness/readiness |
| A → B → Back → C 与 Restore | PASS | `Branches · 1`；恢复 `lib.rs:3` 后 `lib.rs:5` 兄弟分支保留 |
| Freeze Path / Freeze Results | PASS | 分别创建 `relation_root` 1-excerpt 与 `answer` 2-excerpt Reading Set |
| Reading Set 与同 bundle restart | PASS | 两份 frozen set 均恢复；Trail 重启后为空；没有预写 session |

真实截图：

- `docs/plans/evidence/m1-m13-remediation/s3-branch-restore.jpeg`
- `docs/plans/evidence/m1-m13-remediation/s3-freeze-path.jpeg`
- `docs/plans/evidence/m1-m13-remediation/s3-restart-reading-sets.jpeg`

## 范围与零写审计

- `git diff --check REMEDIATION_BASE..HEAD`：PASS。
- 实现范围只有计划列出的 production、test、script、workflow 和文档文件。
- production/test/script diff 未增加 `struct`、`class`、`enum` 或 `protocol`；未增加依赖、
  manager、registry、持久化格式、UserDefaults key 或 feature flag。
- 17 通道参数合同保持不变；bookmark/restart 是其后的独立追加门。
- `goldset/`、fixtures、Prototypes 未修改。正式 App Support 内容/拓扑指纹仍为
  `8c691d6d9c5d0b428a2bfcc9434b16cce5801022171610c063da4c3cb68e6117`；一次验收工具
  以显示名 `Cairn` 而非唯一 bundle id 定位时曾启动正式安装版，使正式 `session.json`
  被等内容重写、mtime 更新。内容无差异，但元数据层面不能表述为严格零写。
- 用户已有未跟踪目录 `.claude-trace/` 保持原状，未纳入提交。

## 解阻与最终完成条件

本地与远端计划均已 PASS；完成条件全部满足。
