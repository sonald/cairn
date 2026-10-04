# 开发与排障

开发规则见 [AGENTS.md](../AGENTS.md)，验证选择见[测试策略](testing.md)。本页提供构建、源码入口与按需复现命令；它们不是每次改动都要跑的检查清单。

## 构建与运行

需要 macOS 14+、Swift 6 和 Homebrew libgit2。SwiftPM 默认使用 brew 模式：

```bash
brew install libgit2
swift build
swift run codeinsight --help
CAIRN_LIBGIT2=brew bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

应用自测二进制为 `.build/debug/codeinsight-app` 或 `.build/release/codeinsight-app`；验收产品交互时使用刚打包的 `Cairn.app`，确认没有误操作另一个旧版本实例。

分发包使用 vendored 静态 libgit2，关闭其网络能力：

```bash
bash scripts/vendor-libgit2.sh
bash scripts/make-app.sh
```

`make-app.sh` 与普通 SwiftPM 的默认 libgit2 模式不同；以脚本参数为准。脚本会复制 SwiftPM 资源 bundle 并生成 `Sources/CLibGit2Vendored` 头文件/shim，不手工编辑生成目录。默认 ad-hoc 签名，不代表已经完成 Developer ID、公证、staple 或另一台 Mac 的发布验收。

## CLI 定位语义问题

先用相同快照、语言与位置复现，再判断是提取、解析、Exact 还是 UI 接线问题：

```bash
swift build --product codeinsight
.build/debug/codeinsight index /path/to/project --stats
.build/debug/codeinsight resolve src/main.rs:12:9 --project /path/to/project --type-hop
.build/debug/codeinsight resolve pkg/models.py:9:20 --project /path/to/project --type-hop
.build/debug/codeinsight exact-typedef src/main.rs:12:9 --project /path/to/project
.build/debug/codeinsight exact-hover --help
```

行/列是从 1 开始的 UTF-8 字节位置，不是视觉字符列。`resolve` 可由文件扩展名推断语言，也可传 `--language`；完整命令、选项与语言支持以各子命令 `--help` 为准。CLI 成功只证明这条 CLI 路径，不等于原生窗口的焦点、悬浮或沙箱交互成功。

## 按故障路径排查

| 现象 | 先查什么 |
| --- | --- |
| 点击错符号、类型直达不对 | 查原始字节位置、`Resolver.locatedName` 与 `EngineSession.typeHop`；明确点的是 receiver、field 还是 method name，核对绑定记录属于哪个文件。 |
| UI 显示旧结果 | 核对 snapshot/profile/generation、当前 token、异步请求取消以及目标内容身份；不要只刷新标签掩盖旧结果发布。 |
| Exact 不就绪/超时 | 核对实际 provider 可执行文件、版本、能力协商、项目配置、离线依赖、LSP 请求/响应和子进程退出。Safe 应明确受限，不静默切 Trusted。 |
| 只在打包应用中 Exact 卡住 | 在相同 Safe 沙箱下观察进程，不用裸 CLI 成功排除沙箱差异。2026-10-03 曾采到 cargo 阻塞于符号链接的全局 Git 配置访问；本次未复现，也没有据此修改用户 Git 配置。 |
| 字体/换行后错位 | 区分原始源位置、投影 UTF-16、实际视口几何；记录字体实际 PostScript 名、fallback、文件成本及选区。超高成本输入不保证精确垂直恢复。 |
| 原生性能忽然失败 | 固定二进制、fixture 与测量边界，检查电源和后台负载，先用少量同条件对照。不能凭进程名结束用户应用，不能反复重跑只取最快值。 |
| 会话恢复失败 | 核对项目规范路径、会话 schema、读写错误和项目卷可用性；保留原文件，不把失败当空会话写回。 |
| 界面出现 `model.*` 键 | 核对资源 bundle 归属与 `modelText`，运行对应本地化静态检查。 |

## 性能复现

只在相关改动或具体回归时使用这些入口。普通开发少量代表样本即可；历史 p95、测试条数和里程碑阶段名不构成新的硬门槛。

索引样本：

```bash
bash scripts/bench.sh /path/to/project 3
```

Reader 真实工作量样本可选择相关 suite（`identifiers`、`gutter`、`projection`、`reflow`、`lifetime`）：

```bash
swift build -c release --product codeinsight-app
bash scripts/run-readonly-workload.sh \
  --app-bin .build/release/codeinsight-app \
  --suite reflow --out .build/readonly-reflow
```

固定 fixture 的折叠性能入口：

```bash
bash scripts/run-fold-perf.sh \
  --app-bin .build/release/codeinsight-app \
  --fixture fixtures/fold_perf.rs \
  --manifest fixtures/fold_perf.manifest.json
```

fixture 的种子、哈希和重建入口保存在 [fixtures](../fixtures/) 的各自说明中。不要改变 fixture 或阈值来掩盖失败。`run-readonly-workload.sh --enforce-budgets` 目前会明确失败，因为没有已校准的时间/内存预算；不要把该参数当现有性能保证。

报告区分准备、操作耗时、实际绘制、稳定可用、源坐标正确性与进程内存。减少工作量不能直接推出所有交互更快，原生绘制调用耗时也不是显示器帧间隔。高成本精确恢复不适用时应记 NOT_RUN，不把 no-op 当 PASS。

[保留证据](evidence/README.md) 中的最终 readonly 配对记录只用于理解既有取舍；普通文件热查询与颜色变化收益和冷路径警戒同时存在。chunked-content 探索因为改变几何未采用，当前没有分块内容框架的实施要求。

## 文档与产物

产品行为更新 [product.md](product.md)，长期不变量更新 [architecture.md](architecture.md)，执行范围更新 [testing.md](testing.md)。一次实现不需要另外创建需求、设计、计划、评审、阶段验收五份文档。

临时日志、截图和报告放 `.build/` 或任务产物。完成时报告实际执行的检查、完整结果和未验证范围；需要长期保存的证据才进入 `docs/evidence/` 并加简短说明。许可证、上游来源与 fixture 的再现方法留在其资源附近。
