# fold-perf 失败根因与处理

日期：2026-09-17。结论：**根因已通过可逆对照确认，处理后原门限连续三次 PASS。**

## 1. 结论

导致本次性能门失败的主要外部因素，是一个运行约 43 小时的独立无头 agent-browser Chrome 实例。它使用 `agent-browser-chrome-1f71484f-cbe0-40e5-b47a-41c889be9ad7` 临时 profile，带 `--headless=new`，多个 GPU/utility/renderer 进程各消耗接近一个 CPU 核。

这不是前台 Chrome：自动化 daemon 为 PID 81508（PPID 1），其浏览器主进程为 PID/PGID 81509；前台 Chrome 是独立的 PID/PGID 2464。此前再验证记录将这些高 CPU 进程称为“用户活动应用”，归属判断不准确。PPID 1 和运行时间本身不是性能因果证据，下述暂停—恢复实验才是。

已向核对过身份的无头进程组及其 daemon 发送 SIGTERM，确认它们退出，前台 Chrome 2464 保持运行。没有停止前台应用，没有修改 Cairn 代码、fixture、计时方式或 400ms 门限。

本次定位到的是“该自动化进程组负载造成性能门超时”；没有进一步确认 Chrome 内部为何长期高 CPU，也不宣称修复了浏览器内部问题。

## 2. 实验

首轮原始命令在沙箱内复现 585.073ms，FAIL。随后所有因果对照均在相同正常权限下、使用同一现有 release 二进制串行执行，避免把沙箱权限变化混入暂停变量。

```bash
FOLD_PERF_RESULT_DIR=/tmp/cairn-fold-recheck \
  bash scripts/run-fold-perf.sh \
  --app-bin .build/release/codeinsight-app \
  --fixture fixtures/fold_perf.rs \
  --manifest fixtures/fold_perf.manifest.json
```

| 状态 | foldLatencyMs | 原 gate 结果 |
|---|---:|---|
| 无头实例运行，active-before | 522.689 | FAIL |
| 暂停该进程组，paused-1 | 260.847 | PASS |
| 继续暂停，paused-2 | 271.088 | PASS |
| 恢复该进程组，active-after | 531.090 | FAIL |
| 结束该实例后，clean-1 | 255.672 | PASS |
| 结束该实例后，clean-2 | 260.697 | PASS |
| 结束该实例后，clean-3 | 297.111 | PASS |

暂停对照使用 SIGSTOP/SIGCONT，并设置 finally 和独立看门狗恢复；实验结束后先恢复负载并重现失败，再执行清理。因此这不是仅通过“多重试几次取最快结果”得出的结论。

三个 clean 运行退出码均为 0，内存增量分别为 23,085,104 / 22,036,504 / 16,220,208 bytes，均低于 80 MiB。原脚本还核对了 fixture 哈希、8,400 个候选/接受折叠、4,400 个逻辑折叠、200 个渲染折叠、字体/窗口/viewport/换行配置，全部通过。

二进制 SHA256：`0fe88e4eec00942fb81a8e4f1aaf19c9a2d3603d232a57d8bc5af0afad1204e2`。使用的是当日 12:01 的已有 release 产物，本次没有重新编译；相关应用源码最后修改早于它。本实验的核心保证是各轮二进制与 fixture 相同，不依赖昨日测量作为因果对照。

## 3. 源码交叉检查

`runFoldPerformance` 在 `CodeInsightApp.swift` 的计时范围为：应用 Overview → fitViewport → layoutViewport → 同步 display。读取、语法解析、初次显示和后续 pumpRunLoop 不在 foldLatencyMs 内。未发现固定等待或明显错误计时。

性能入口与产品共用 `ReaderTextView.setReadingHeightLevel → applyFoldMutation → applyFoldProjection`，不经过 AppDelegate 的多项目创建和恢复路径。静态检查有重复布局的潜在优化点，但本次没有测得其为失败根因，因此不作无关重构。

`git diff -- scripts/run-fold-perf.sh Sources/CodeInsightReaderCore Sources/CodeInsightReaderUI` 为空；此结论只表示这些文件没有当前工作树改动，不单独作为“没有性能问题”的证明。

## 4. 证据与边界

- [完整汇总与哈希](evidence/2026-09-17-fold-perf/summary.json)。
- [处理前进程归属](evidence/2026-09-17-fold-perf/processes-before.txt) / [处理后进程归属](evidence/2026-09-17-fold-perf/processes-after.txt)：仅保留目标实例及前台 Chrome，未提交其他进程命令行。
- 每轮 `control.json`、`fold.json`、`result.json` 位于同一证据目录下对应 run 子目录。
- 这是对之前未通过的 **fold-perf 门** 的独立复验和环境处理；没有重新执行整个 CI，不能把本报告表述为“本轮完整 CI 已通过”。

后续自动化会话应在结束时关闭自己创建的无头浏览器。若性能门再次超时，先核对进程的 profile、父进程和进程组；不要仅凭 Chrome 名称认定是用户前台浏览器，也不要自动批量杀掉所有 Chrome。
