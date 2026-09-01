# M1–M13 系统评审问题修复总验收

验收日期：2026-09-01

`REMEDIATION_BASE`：`3166644822715527a3e5ed3430ebb15962661c75`

实现 HEAD：`6e3122d4823d465ee7f9b148f37682fe281adcd6`

当前结论：**BLOCKED**。S1、S2、S4 和 S5 的实现与独立门禁通过；S3 的真实
M10/M11 闭环未走完，S5b 的完整 `run-product-gates.sh` 仍不能在当前本机嵌套环境中
越过 CI。没有把独立 CI PASS 与后半段产品门 PASS 拼接成整条命令 PASS。

## 切片结论

| 切片 | 提交 | 状态 | 结论 |
|---|---|---|---|
| S1 generation 正确性 | `d64b5835d4c9422c8ea4680cd230569732f84868` | PASS | 单语言打开和 feature switch 均同步 bookmark generation；旧 Attempt 清除；未增加新类型 |
| S2 M13 产品门与视觉判据 | `c7923faf4e485faaa4c2d3dc8edd63e3717ccfda` | PASS | 纯色 bitmap 被拒绝；三主题 AppKit cache 截图、bookmark、restart、正式数据零写均通过 |
| S3 M10/M11 真实闭环 | `1871808d17c0c343724269d5ef1ae52271be1fab` | BLOCKED | First run、真实 Rust provider、Trail 分支与 Restore 通过；Relations 菜单 AXPress 不生效，后续 Freeze/Reading Set/restart 未到达 |
| S4 文档与发布口径 | `0ab0a7e0a693905b97cc85e55753d9cc20890b5f` | PASS | README、design、L1/L2/L3/M13 状态与实际范围一致；JavaScript 和公证未被虚报 |
| S5 warning 收口 | `fe1343c8ce47b03f14a5c7e4a365fa68e14e862d` | PASS | 仓库源代码 warning 清零；只余 Wasmedge/Homebrew 宿主路径噪声 |
| S5b CI 日志确定性 | `45b5cbd8fa58b167baa7e344e6806046f5592638`–`6e3122d4823d465ee7f9b148f37682fe281adcd6` | BLOCKED | 安静排水的 full suite 与独立 CI 通过；嵌套产品门仍在 AppKit 测试段无摘要结束 |

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
| `CODEX_SANDBOX=1 bash scripts/ci.sh` | PASS | exit 0；842 tests / 3 suites，219.616 s；后续 self-test/fold 全部通过 |
| 完整 `run-product-gates.sh` | BLOCKED | 嵌套 CI 在 AppKit 测试段无失败、crash 或最终摘要地结束；同 HEAD 的独立 CI 可重复通过 |
| 产品门 CI 之后的原样剩余步骤 | PASS（诊断，不替代完整门禁） | 17 通道 `pass=17 fail=0 hang=0`；mixed、真实三 provider、Gold、fold、bookmark/restart 全部通过；artifact `.build/self-test-run-20260901-121651-62651` |
| 远端 workflow | NOT RUN | 分支未 push；本轮没有获得 push 授权，不能声称远端成功 |

产品门剩余步骤的关键结果：

- Tokio Gold：17 total，known 0，unexpected 0；
- ripgrep Gold：16 total，known 3，unexpected 0；
- Python Gold：6 total，known 0；TypeScript Gold：10 total，known 0；
- fold：resolution 约 24.03 ms，latency 232.186 ms，delta 20,856,856 B；
- bookmark 三主题与 restart 均 PASS；正式 App Support 门禁前后指纹均为
  `8c691d6d9c5d0b428a2bfcc9434b16cce5801022171610c063da4c3cb68e6117`。

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
- 正常 Quit：BLOCKED；启动后 Mac 被锁定，Computer Use 无法读取或操作界面。未用
  `kill` 或 self-test 退出冒充正常菜单退出。
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
| A → B → Back → C 与 Restore | PASS | `Branches · 1`；恢复旧分支后兄弟分支保留 |
| Relations → Inspector | BLOCKED | `Show Callers` 可见且可高亮，但当前 Computer Use 无法对自定义 AppKit menu item 执行 AXPress；同 fixture CLI 有真实结果 |
| Freeze Path / Freeze Results | BLOCKED | 被上一项阻断，未到达 |
| Reading Set 与同 bundle restart | BLOCKED | 未创建 Reading Set，不能验证恢复；不使用预写 session 绕过 |

## 范围与零写审计

- `git diff --check REMEDIATION_BASE..HEAD`：PASS。
- 实现范围只有计划列出的 production、test、script、workflow 和文档文件。
- production/test/script diff 未增加 `struct`、`class`、`enum` 或 `protocol`；未增加依赖、
  manager、registry、持久化格式、UserDefaults key 或 feature flag。
- 17 通道参数合同保持不变；bookmark/restart 是其后的独立追加门。
- `goldset/`、fixtures、Prototypes 与正式 App Support 未修改。
- 用户已有未跟踪目录 `.claude-trace/` 保持原状，未纳入提交。

## 解阻与最终完成条件

总计划保持 BLOCKED，直到同时满足：

1. 用户解锁 Mac 后，从最终隔离 bundle 执行一次正常 Quit；
2. 用能实际触发自定义 AppKit context-menu action 的真实输入完成
   Relations → Inspector → Freeze Path/Results → Reading Set → restart；
3. `run-product-gates.sh` 在同一调用中越过嵌套 CI 并最终 exit 0；
4. 获得 push 授权后，远端 product workflow 到 terminal success。

前三项未完成前不把本地修复判为总验收 PASS；第四项未经授权保持 NOT RUN。
