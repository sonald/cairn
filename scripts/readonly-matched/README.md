# Reader 原生性能对照

仅在相关性能回归或明确优化决策时运行。默认 `--samples 3 --max-pairs 3`，也可用一个样本确认方向；通过后停止。选择相关 `--scenario`（`identifiers`、`gutter`、`projection`、`reflow`），不自动扩大矩阵。

该工具对两个干净 checkout 安装临时观测代码，构建后记录二进制和资源哈希，随后恢复源码。它只改变 Reader 观测与 self-test 入口，不是产品功能。先保留两个版本各自的原始 Release 程序。

在仓库根目录分别对 baseline/candidate 执行；`ROOT`、`SHA`、`RECEIPT`、`BINARY` 使用各自实际路径和提交：

```sh
python3 scripts/readonly-matched/install_harness.py install --root ROOT --expected-sha SHA --receipt RECEIPT
# 在 ROOT 中用相同 Swift/SDK/libgit2 配置构建 Release codeinsight-app
python3 scripts/readonly-matched/install_harness.py seal --root ROOT --receipt RECEIPT --binary BINARY
python3 scripts/readonly-matched/install_harness.py restore --root ROOT --receipt RECEIPT
python3 scripts/readonly-matched/run_matched.py --help
```

安装器拒绝脏工作区，restore 拒绝覆盖意外编辑。保留已封存程序、同级资源 bundle、receipt 和构建日志；备份及结果放在忽略的 `.build` 目录。

`run_matched.py` 需要 `--baseline`、`--candidate`、两者 receipt、`--manifest` 和 `--out`。它交替执行 AB/BA，记录原始失败/超时，区分操作耗时、实际绘制、稳定 viewport 与内存。对照要求相同输入与工具链；运行期间不要并行构建、执行别的原生测量或操作测量窗口。

判断结果必须同时检查内容、设置、字体、选区、绘制与布局收敛，不能仅凭等待时间或旧诊断数据。draw marker 也不等于屏幕合成完成。冷启动显式设置初始 caret；不存在折叠的输入记录不适用，不能测一个 no-op 冒充通过。

超过日常样本数的收集需要明确的回归或发布问题。脚本的 `standaloneAcceptanceEligible` 仅表示样本量满足其历史统计条件，不表示产品可发布；失败不能靠补有利样本消除。`--supplemental` 记录单独补样，`--require-ac-power` 检查进程前后的供电状态；这些端点不证明整个运行期间供电未变化。

历史实验数据及限制见 [证据索引](../../docs/evidence/README.md)，当前验收规则见 [testing.md](../../docs/testing.md)。不要把历史测量结果或 30 样本规则作为日常开发门槛。
