# 资源复测 — 2026-09-09

最终隔离 bundle `.build/reliability-ui-final/Cairn.app` 的既有 `--self-test-switch` 通道；本机 macOS 26.6.2 arm64。每档20个Rust文件及0/64/256MiB唯一非源码负载，两个Git提交。cold-index为5个独立本地克隆路径，warm-index为同一路径20个独立进程。编译不计时。

| 负载 MiB | 阶段 | 次数 | 失败 | first-paint中位数ms | p95 ms（仅20次）/最大值（5次） | 峰值RSS MiB |
|---|---|---:|---:|---:|---:|---:|
| 0 | cold-index | 5 | 0 | 5.6 | 6.5 | 20.0 |
| 0 | warm-index | 20 | 0 | 6.0 | 6.4 | 19.2 |
| 64 | cold-index | 5 | 0 | 158.3 | 159.8 | 115.0 |
| 64 | warm-index | 20 | 0 | 158.4 | 162.2 | 114.3 |
| 256 | cold-index | 5 | 0 | 611.6 | 617.1 | 357.1 |
| 256 | warm-index | 20 | 0 | 602.9 | 661.3 | 356.6 |

75次全部成功，warm-index的first-paint p95均低于1秒。原始JSONL含cached/full-ready时序与每轮RSS；脚本保留为复现入口，exe路径须对应本仓库最终bundle。

边界：这是既有应用快照自测通道的进程外峰值RSS与模型发布时序，并非鼠标打开至屏幕实际绘制的计时；不是GUI常驻RSS，也不能替代关闭Compare/tabs后的原生回收采样。256MiB负载峰值约357MiB说明捕获瞬时成本仍存在；语义store非源码保留另由现有S4b回归约束。

同项目20修订服务级回归已由21份累积改为每轮当前1份，旧session仍可查旧符号。底层store显式复用探针的append语义未被偷偷改写。
