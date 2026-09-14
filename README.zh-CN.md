# CodeInsight / Cairn

<p align="center">
  <a href="https://github.com/sonald/cairn/actions/workflows/product-quality.yml">
    <img src="https://github.com/sonald/cairn/actions/workflows/product-quality.yml/badge.svg" alt="Mixed-language product gate" />
  </a>
  <a href="./LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

CodeInsight 是一个 macOS 原生、只读的代码阅读器，正式产品名为 **Cairn**。它为理解陌生代码而设计：打开项目即可建立符号索引，在阅读、搜索和调用关系之间联动，并能在 Git 快照之间虚拟切换。

这不是编辑器。Cairn 不保存文件、不执行构建，也不改写工作区；它把阅读过程中的证据和不确定性显式展示出来。

## 核心能力

- **原生只读 Reader**：基于 AppKit/Swift 的文件树、大纲、Context Window、关系面板、折叠与导航历史。
- **多语言索引**：当前支持 Rust、Python、TypeScript 和 TSX 的语法提取、符号索引与阅读面。
- **符号与全文搜索**：模糊符号查找、内容字面量/正则搜索、定义候选、调用者、外向调用、实现和 override 查询。
- **Exact 分析**：可选接入 rust-analyzer、Pyright 和 typescript-language-server；结果带 provider 与环境标注。
- **Safe Reading Mode**：默认拒绝网络、禁用项目构建脚本和 proc macros，并把限制显示为分析结果的一部分。
- **Git 时间旅行**：读取 worktree 或 commit 快照，比较不同版本，不 checkout、不修改仓库。
- **索引一致性**：索引来源的跳转先验证目标内容身份；文件在索引后变化时提示 `File changed since indexing` 并提供 Refresh Index——无损重捕获工作区，tabs、Reading Set、书签、Trail 与布局全部保留。
- **导入预选**：Choose Languages 对话框按 Recents 中保存的偏好或有界文件名探测结果预选（纯 `.js`/`.jsx` 不会选中 TypeScript）；手动选择始终优先。
- **CLI 工具链**：提供索引、查询、快照、缓存切换统计、gold-set 评估等命令。

## 非源码预览

Cairn 的文件树会显示跳过目录之外的常规非符号链接文件。源码索引和 Exact 分析仍只识别现有的 Rust、Python、TypeScript 和 TSX 语言模式。

- Markdown（`.md`、`.markdown`）以只读富文本渲染。
- HTML（`.html`、`.htm`）在只读 WebKit 视图中渲染，并封闭 JavaScript、网络和本地子资源。
- 可解码图片和 PDF 以只读方式显示；其他严格 UTF-8 文件使用可选择的纯文本预览。
- Markdown 和 HTML 的项目内链接可以打开项目文件；这些预览支持 Back/Forward，commit tab 读取所选快照字节。
- 未知或损坏的二进制内容会明确显示为不支持预览，不会渲染成乱码。

非源码预览不提供 outline、fold、relations、bookmark、compare/diff、Reading Height 或 search 控件；不会打开外链，也不承诺内联本地资源。

## 阅读操作

- `⌘P` 按文件名或项目内相对路径打开文件；`>` 查询命令，`@` 查询当前文件符号，`#` 查询项目符号，`:` 跳到行号。
- 单击文件打开斜体的预览标签；双击文件、选择 **Open in New Tab**，或在标签右键菜单选择 **Keep Open**，即可保留。后续浏览复用预览标签，保留的标签不会被覆盖；重启恢复的标签也会保留。
- 点击对比区的 **×**，或选择 **View → Close Comparison**（`⌃⌘W`），结束对比并返回保存的阅读布局。
- Files 和 Outline 可分别收起；拖动它们之间或 Relations 边界的分隔条调整空间，布局会被记住。大纲可以展开到成员，并显示类型和签名摘要。
- 状态栏的 **Context** 按钮显示或隐藏定义预览；空预览默认不占空间。信息按钮解释当前分析状态。
- 设置首屏提供主题、字号、行高、折行和行号，并有实时代码预览；其余选项收在 **Advanced typography**。**Restore Reader Defaults** 应用当前默认排版，不影响项目数据。

## 可解释阅读工作流

1. 打开项目，并选择项目中实际使用的语言。
2. 在 Relations 中选择已发布结果进行语义导航；使用 `⌘I` 打开 Resolution Inspector，查看来源与验证证据。
3. 使用 `⌥⌘T` 打开 Trail Details 或 Branches，检查当前路径，并在不丢弃兄弟分支的前提下恢复较早节点。
4. 在 Relations 中使用 **Freeze Results**，或在 Trail 中使用 **Freeze Path as Reading Set**。生成的 Reading Set 会保留冻结源码和证据，并可在 Cairn 重启后恢复。

Reading Trail 只属于当前应用会话，重启后按设计从空状态开始。Reading Set 是冻结证据集，不是可编辑的整理清单。折叠只作用于文件 Reader：`⌥⌘0/1/2` 分别选择 Full、Structure、Overview，`⌥⌘F` 聚焦当前作用域。当前产品界面文案为英文，Cairn 尚未提供完整本地化。

## 书签与笔记

- 在主阅读区的项目文件中按 `⌘⇧M` 切换书签；按 `⌘⌥B` 打开书签面板。
- 书签是精确的快照锚点：捕获内容匹配时为 **Exact content**；工作区内容变化时为 **Drifted**，必须显式 **Re-anchor**；版本/文件缺失或 offset 无效会保持诚实状态，绝不静默跳转。
- `bookmarks.json` 最多持久化 32 条记录；每条纯文本 note 上限为 2 KiB，并以原子方式写入。
- dependency 文件、Compare、Reading Set、空态和 mini reader 不支持书签。当前不实现跨 commit 符号映射；commit 书签始终绑定保存时的快照和完整 object ID。

## Repository Layout

| 路径 | 用途 |
| --- | --- |
| `Sources/CodeInsightApp` | Cairn 的 macOS 应用入口 |
| `Sources/CodeInsightCLI` | `codeinsight` 命令行工具 |
| `Sources/CodeInsightEngine` | 项目索引、关系解析与查询引擎 |
| `Sources/CodeInsightExact` | rust-analyzer / Pyright / TS language server 集成 |
| `Sources/CodeInsightReader*` | Reader 数据模型与 AppKit 渲染层 |
| `docs/plans` | 分阶段实施计划和验收记录 |

## 构建与运行

需要 macOS 14+、Swift 6 工具链和 Homebrew `libgit2`：

```bash
brew install libgit2
CAIRN_LIBGIT2=brew bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

构建可分发的 Cairn.app 时使用静态、关闭网络的 vendored libgit2：

```bash
bash scripts/vendor-libgit2.sh
bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

`scripts/make-app.sh` 默认使用 ad-hoc 签名，不执行公证或 staple。Developer ID 签名和公证需要显式签名身份或 Apple 凭据；本仓库尚未执行这些步骤。

## CLI 示例

构建命令行入口：

```bash
swift build --product codeinsight
.build/debug/codeinsight --help
```

常用查询：

```bash
# 索引 Rust 项目并输出统计
.build/debug/codeinsight index /path/to/rust-project --stats

# 模糊搜索符号
.build/debug/codeinsight symsearch spawn \
  --project /path/to/project \
  --limit 20

# 解析源码位置；column 按 UTF-8 byte 计算
.build/debug/codeinsight resolve Sources/Foo/Bar.rs:120:9 \
  --project /path/to/project
```

完整子命令包括 `parse`, `index`, `dump`, `defs`, `callers`, `calls`, `impls`, `overrides`, `resolve`, `search`, `symsearch`, `snapshot`, `switch-stats`, `goldset`, 和 `exact-def`。

## Exact Providers

| 语言 | 阅读器/索引 | Exact provider |
| --- | --- | --- |
| Rust | 内置 tree-sitter extractor | rust-analyzer |
| Python | 内置 tree-sitter extractor | Pyright |
| TypeScript / TSX | 内置 tree-sitter extractor | typescript-language-server |
| JavaScript / JSX | deferred / unsupported | — |

Provider 由本机安装；Cairn 不会替项目安装依赖。离线依赖缺失或 Safe Mode 的限制会作为结果状态显示，不会被静默当作“精确且完整”。

## 测试与质量门禁

运行 Swift 测试：

```bash
swift test
```

运行本地 CI（包含 self-test 和 release fold 性能门禁）：

```bash
CODEX_SANDBOX=1 bash scripts/ci.sh
```

混合语言产品门禁需要三个干净的 Git corpus：

```bash
bash scripts/run-product-gates.sh \
  /path/to/python-repo \
  /path/to/typescript-repo \
  /path/to/mixed-language-repo
```

GitHub Actions 会自动安装固定版本工具、克隆冻结 corpus 并运行同一套门禁。
产品门禁还会运行隔离的书签/重启检查，并验证 Light、Dark、SI Classic 三主题截图均为非空可见证据。

## 文档

- [需求与设计](docs/design.md)
- [基准](docs/benchmarks.md)
- [Gold set baseline](docs/goldset-baseline.md)
- [实施计划与验收记录](docs/plans/)

## License

本项目第一方源码以 [MIT](./LICENSE) 发布。仓库内 vendored 的 tree-sitter 运行时和语言 grammar 保留其上游许可证，详见对应目录下的 `LICENSE` 与 `VENDORED.md`。
