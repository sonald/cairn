# CodeInsight / Cairn

<p align="center">
  <a href="https://github.com/sonald/cairn/actions/workflows/product-quality.yml"><img src="https://github.com/sonald/cairn/actions/workflows/product-quality.yml/badge.svg" alt="Product quality checks" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
</p>

<p align="center"><a href="README.md">English</a> · 简体中文</p>

**Cairn** 是 macOS 原生只读代码阅读器，用来理解陌生项目。CodeInsight 保留为 Swift package 和模块名。可以阅读源码、追踪符号与关系、比较 Git 快照，不编辑文件，也不 checkout 另一个提交。

- Rust、Python、TypeScript/TSX 语法索引、符号与可组合项目查询。
- 跟随符号或所在函数的 Context 窗口，支持值绑定的类型预览与固定。
- 可选 rust-analyzer、Pyright、typescript-language-server 分析，明确显示来源和限制。
- 只读 Git 快照、比较、带分支的阅读轨迹、冻结阅读集、书签与项目会话恢复。
- 多项目窗口、可配置快捷键、代码字体与连字、Light/Dark/SI Classic 主题、中英文界面。
- 只读 Markdown、受限 HTML、图片、PDF 和 UTF-8 文本预览。

默认 Safe 模式禁止网络，关闭 Rust 构建脚本与 proc macros。用户明确信任项目后可以开启这些分析步骤，并允许向项目 `target` 目录写入，网络仍关闭。语言服务和依赖需已存在于本机。

## 构建与运行

应用支持 macOS 14+。构建统一使用 Xcode 27.0（27A266a）、随附的 Swift 6.4 和 Homebrew libgit2；本地检查与 CI 校验同一工具链，配置见[开发说明](docs/development.md)。

```bash
brew install libgit2
CAIRN_LIBGIT2=brew bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

使用静态、关闭网络的 vendored libgit2 打包：

```bash
bash scripts/vendor-libgit2.sh
bash scripts/make-app.sh
```

默认是 ad-hoc 签名。Developer ID 签名、公证和 staple 需要独立配置与验证。不要手工编辑 `Sources/CLibGit2Vendored` 的生成文件。

## 开始阅读

1. 打开项目并选择语言。`⌘P` 查找文件；前缀 `>`、`@`、`#`、`:` 分别查询命令、文件符号、项目符号和行号。
2. 单击符号更新 Context。值绑定可以预览其类型；`⌘` 单击仍打开绑定声明，`⇧⌘` 单击或 `⌃⌘J` 打开类型。`ps.get()` 中点 `ps` 解析接收者，点 `get` 才解析方法。
3. 从 Relations 继续阅读，并查看结果的来源与验证证据。冻结结果或轨迹为阅读集，保存源码与解释。
4. 重新打开项目恢复阅读现场。新项目拥有自己的窗口；再次打开已打开的项目会激活其窗口。

上述均为默认快捷键，设置 → 快捷键显示当前绑定。单击文件打开可复用的预览标签，双击或 Keep Open 将其保留。字体、连字和折叠只改变显示，复制仍保留原始源码。

源码索引当前识别 `.rs`、`.py`、`.ts`、`.tsx`，JS/JSX、声明文件及其他变体扩展名不等于完整源码分析模式。非源码预览不提供关系、折叠、书签、比较和搜索控件。Exact 结果依赖 provider 能力与本地环境，“已验证”不代表掌握全部运行时行为。

`⇧⌘F` 打开停靠搜索：`lock await same:fn`、`lock OR mutex`、`-path:tests/`、`in:code` 可组合文本、路径和语法区域。查询历史随项目恢复，`⌥⌘G` / `⇧⌥⌘G` 逐条浏览结果。详见[查询行为与当前验收限制](docs/product.md#搜索选项)。

## CLI

```bash
swift build --product codeinsight
.build/debug/codeinsight --help
.build/debug/codeinsight index /path/to/project --stats
.build/debug/codeinsight search 'lock await same:fn -path:tests/' --project /path/to/project --json
.build/debug/codeinsight resolve src/main.rs:12:9 --project /path/to/project --type-hop
```

行/列从 1 开始，列按 UTF-8 字节计数。支持的选项与语言见各子命令的 `--help`。

## 开发文档

从[文档索引](docs/README.md)进入：

- [当前产品行为与限制](docs/product.md)
- [架构与源码入口](docs/architecture.md)
- [构建、排障与性能复现](docs/development.md)
- [测试选择与验证规则](docs/testing.md)

按受影响行为选择验证；完整产品与性能门禁用于明确需要的扩大验证。仓库工作规则见 [AGENTS.md](AGENTS.md)。旧里程碑要求已归并到现行文档，历史通过 Git 查询。

## 许可证

第一方源码使用 [MIT](LICENSE)。vendored tree-sitter 运行时和语言 grammar 保留上游许可证与来源说明，见各目录的 `LICENSE`、`VENDORED.md`。
