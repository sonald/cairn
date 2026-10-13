# 热语言服务器跨 commit 原地 checkout 探针（2026-10-12）

为"切换阅读 commit 时精确分析慢、退化"立项前的原型测量。结论用于 [commit 阅读计划](../../plans/commit-reading-warm-exact.md)；它不是当前产品的验收结果。

## 环境

Apple M3 Pro，macOS 27.0.1，git 2.54.0；rust-analyzer 65ac641199（2026-10-04），pyright 1.1.414，typescript-language-server 3.3.0 + typescript 5.0.2（`/opt/homebrew/lib/node_modules/typescript`），node v26.11.1。语言服务器直接以 stdio 启动，**不经 Cairn 沙箱**，初始化选项与 Cairn Safe 模式一致（见脚本）。每个场景跑 1–2 次。

语料：toydb（`~/work/rust/toydb`，60 个 `.rs`，404 commits）、mini-sglang（87 个 `.py`，103 commits）、llm-tools（`~/work/ai/llm-tools`，根 `.venv`，两个 TypeScript 单元各有 `node_modules`）。全部先 `git clone --local` 到临时目录再原地 checkout，不触碰原仓库。

## 当前成本拆分（toydb，CLI）

| 项 | 数值 |
| --- | --- |
| 索引切换（`codeinsight switch-stats`） | 相邻 commit 25 ms（内容复用 100%），HEAD~100→HEAD 86 ms（复用 5%） |
| 整树导出（`git archive \| tar` 代理 Materializer） | 70 ms（530 文件）；tokio 1.47.1 100 ms（783 文件，6.9 MB） |
| 增量 checkout | 相邻 10 ms，HEAD~100↔HEAD 70–90 ms |
| rust-analyzer 冷启动到第一个 hover（`codeinsight exact-hover`，含沙箱） | 2.3–3.0 s |

结论：文件写入不是瓶颈，语言服务器冷启动才是。

## 热服务器 + 原地 checkout

`rust_analyzer_probe.py`（toydb）：

| 场景 | 结果 |
| --- | --- |
| 冷启动到正确 hover | 3.2 s（×2） |
| 热 RA，HEAD~5→HEAD（16 个 `.rs`），不发通知 | 正确 hover 0.25 s，空闲 0.48 s |
| 同上，发 `didChangeWatchedFiles` | 0.52 s / 0.54 s |
| 热 RA，HEAD~100→HEAD（Cargo.toml/lock 变 + 323 文件） | 正确 hover 0.9 s，空闲 1.7 s（同起点冷启动 2.7–7.9 s） |
| 已 `didOpen` 的文件 | checkout 后 8 s 仍返回旧内容；`didClose`+`didOpen` 后 0.01 s 正确 |

`pyright_tsserver_probe.py`：

| 场景 | 结果 |
| --- | --- |
| tsserver 热，llm-tools e6ebaff→bb6e992（75 文件），未重开文件、不发通知 | 0.08 s 正确（×2） |
| Pyright 热，mini-sglang a52ad83→bc684fb（40 文件），未重开、不发通知 | 10 s 内仍旧；重开文件后 0.05 s 正确 |
| 同上，发 `didChangeWatchedFiles` | 未重开即 0.02 s 正确 |

## 依赖借用

| 语言 | 做法 | 结果 |
| --- | --- | --- |
| TypeScript（llm-tools，`@huggingface/tokenizers`） | 克隆目录无 `node_modules` | hover `import Tokenizer`，definition 指向自身（未解析） |
| | 软链工作区 `tools/model-files-web/node_modules` | 0.85 s，`(alias) class Tokenizer`，definition 进入工作区 `node_modules` |
| Python（llm-tools，`torch.Tensor`） | 克隆目录无 `.venv` | 90 s 后仍 `Tensor: Unknown` |
| | 软链工作区 `.venv` 到克隆根（pyproject 无 `[tool.pyright]` venv 配置） | 90 s 后仍 Unknown：Pyright 不自动发现 `.venv` |
| | `workspace/configuration` 回答 `python.pythonPath` = 工作区 `.venv/bin/python` | 4.3 s 解析为 `class Tensor`，definition 进入工作区 `.venv` |
| Rust | 未测：Safe 模式依赖来自 `~/.cargo`，与目录无关 | — |

## 局限

- 仓库都很小；大仓库规模未测。
- 所有判定点都在被 hover 的文件内（impl 头、`parseDisplayJSON`、`_initialize_metadata_once`、`Insert`），没有直接验证跨文件索引是否随 checkout 更新；RA 的"空闲"只是间接证据，Pyright/tsserver 没有。
- 未经 Cairn 沙箱；Pyright/tsserver 的 stale buffer 行为按 LSP 语义推定，未单独跑。
- mini-sglang 工作区 `.venv` 没有安装 torch，所以其 Python 依赖测试无效，已改用 llm-tools。
- toydb 在 Safe 模式报 `dependenciesUnavailableOffline`，与本探针无关，待单独排查。

复现：按脚本头部用法，先 `git clone --local` 到临时目录，`python3 -I <脚本> ...`。
