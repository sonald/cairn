# Go 语言支持的可行性探针（2026-11-11）

目的：在决定是否为 Go 立项前，实测 gopls 能否在 Cairn 的 Safe 沙箱规则下提供精确分析、能否跨 commit 原地切换，以及 tree-sitter-go 能否用仓库现有运行时解析真实代码。**Go 支持尚未实现**；这里不是产品验收，也不代表当前版本具备任何 Go 能力。

## 环境与局限

Apple M3 Pro，macOS 27.2.1，仓库 `745c534`；go 1.27.3（Homebrew），gopls v0.19.1（用 go1.24.5 构建，早于本机工具链）；tree-sitter 运行时为已 vendored 的 v0.25.8，tree-sitter-go v0.25.0 经 Go 模块代理取得（`h1:cEB0Q3LHgZtS+ECHx9wcP7AwzoOddJFQCVmytX42cVU=`，当时 GitHub 连接超时），只用于本次测量，未 vendored。

- gopls 由 `gopls_probe.py` 驱动：脚本照搬 `LSPClient.initialize` 的参数、`LSPClient` 对服务器请求的回答和 `LSPLanguageSession.switchSnapshot` 的顺序，但**不是经 Swift 会话本身**跑的。
- 沙箱规则与 `Sandbox.swift` 的 Safe 模式相同（只读、禁网、只有私有缓存可写、同一地址空间上限），额外设置 `GOCACHE`、`GOPLSCACHE`、`GOTOOLCHAIN=local`、`GOPROXY=off`，不设 `GOFLAGS`。
- 每个场景 1 次；语料只有 cobra（36 个 `.go`）和 Go 标准库（6,827 个 `.go`）。没有 `go.work` 仓库，没有打包应用内的验证。
- 模块缓存用探针专用目录（`GOMODCACHE`），没有改动本机 `~/go/pkg/mod`。

## 一、gopls 长会话（cobra `adbc881`，沙箱内）

| 项 | 结果 |
| --- | --- |
| 服务器发来的请求 | 只有 `workspace/configuration`（section `gopls`）和 `window/workDoneProgress/create`，现有客户端都已回答 |
| `initialized` 后立即发请求（工作区仍在加载） | 被挂起到加载结束后正确回答；启动后 0.42 s 得到前三个答案 |
| 加载信号 | `$/progress` “Setting up workspace” begin → end（0.07 s → 0.31 s） |
| 定义、引用、悬浮、类型定义、实现、调用层级 | 全部返回正确结果；跨文件定义 `command.go` → `args.go:28` |
| 依赖跳转 | `flag.FlagSet` → 模块缓存 `pflag@v1.0.9/flag.go:155` |
| 类型层级 | 接口 `SliceValue` 的 `typeHierarchy/subtypes` 列出 `customMultiString`、pflag 的 `boolSliceValue` 等实现（本机探针中 Pyright、tsserver、rust-analyzer 都不支持此查询） |
| 常驻内存 | 260–590 MB（单次采样） |

## 二、同一进程跨 commit 原地切换

顺序：关闭已打开文档 → `git checkout` → `workspace/didChangeWatchedFiles` → 重新打开并立即请求。每对来回切三次，进程始终存活。

| 提交对 | 判定点 | 结果 |
| --- | --- | --- |
| `f2878ba` ↔ `adbc881`（8 个文件，只改源码） | 未打开的 `args.go` 里 `ArbitraryArgs` 的行号：69 ↔ 82 | 三次都立即正确，每次切换合计 0.04–0.05 s |
| `3f3b818` ↔ `adbc881`（15 个文件，`go.mod`/`go.sum` 变） | `flag.FlagSet` 落在 `pflag@v1.0.6` ↔ `pflag@v1.0.9` | 三次都立即正确，每次 0.15–0.16 s |

没有观察到需要等待的重载信号：切换后第一个请求就是新答案。

## 三、缺少本机依赖

cobra `adbc881`（`go.sum` 完整，`go.mod` 声明 `go 1.15`），go-md2man 只被 `doc/` 子包使用：

| 模块缓存 | 根包里的定义、引用、依赖跳转 |
| --- | --- |
| 为空 | 全部失败：`no package metadata for file` |
| 只缺 go-md2man，连它的 `.mod` 也没有 | 全部失败，同上 |
| go-md2man 的 `.mod`/`.info` 在，只缺 zip 与解压目录 | 全部正确 |

失败时 `go list` 整体退出，gopls 不加载任何包；可用的识别信号是 `go.mod` 上的诊断 `go list packages.Load error … <模块>@<版本>: module lookup disabled by GOPROXY=off`。也就是说，缺的是模块的 `go.mod` 时整个单元的精确分析不可用，只缺源码时影响限于导入它的包。`go 1.15` 的模块没有裁剪过的依赖图，结论未必能照搬到 `go 1.17` 及以后的模块（未测）。

没有 `go.sum` 的玩具模块里项目内导航仍可用，那不是真实仓库的形态。

## 四、其他 gopls 行为（一次性 CLI，同一沙箱）

由 `gopls_cli_probe.sh` 跑出，各行的环境变量不完全相同（脚本固定设 `GOCACHE`、`GOPLSCACHE`、`GOPROXY=off`，其余按行内所述追加）；玩具模块没有随证据保存。

| 场景 | 结果 |
| --- | --- |
| 只用 Cairn 现有的环境变量（`TMPDIR`、`XDG_CACHE_HOME`） | `references` 返回空且退出码 0，日志有写 `~/Library/Caches/gopls` 被拒；对照组同时设了 `GOCACHE`、`GOPLSCACHE`、`GOTOOLCHAIN=local`、`GOPROXY=off`、`GOFLAGS=-mod=readonly`，返回 1 条引用 |
| 带 `vendor/`、模块缓存为空、不设 `GOFLAGS` | 定义落在 `vendor/` 内 |
| 同上加 `GOFLAGS=-mod=readonly` | `no required module provides package`，定义失败 |
| `CGO_ENABLED=0` | 含 `import "C"` 的文件退出分析 |
| cgo 开启 | 正常；首次加载 14 s，之后 1–2 s |
| `go.mod` 要求更新的 Go，`GOTOOLCHAIN=local` | `go.mod requires go >= 1.99 (running go 1.27.3; GOTOOLCHAIN=local)` |
| 同上，`GOTOOLCHAIN=auto` | 写模块缓存被拒，工作区加载失败 |
| 嵌套模块、无 `go.work`、从根启动 | 根模块与子模块的定义、引用都正确 |
| 构建标签变体 | 定义落在 `plat_darwin.go`；从 `plat_linux.go` 查引用有结果 |

## 五、下载依赖是否改动仓库

在 cobra 的克隆里运行 `go mod download`（沙箱外，联网）：

| `go.sum` 状态 | 仓库 |
| --- | --- |
| 完整 | 不变 |
| 删去两行 | `go.sum` 被改写 |
| 整个删除 | `go.sum` 被重建 |
| 删去两行，但用 `-modfile=<仓库外的 go.mod 副本>`（副本旁放 `go.sum` 副本） | 仓库不变，缺的行写进副本，模块正常下载 |

`go.work` 仓库（`gowork_download_probe.sh`：两个模块的玩具工作区，专用模块缓存为空）：

| 做法 | 结果 |
| --- | --- |
| 在模块目录直接 `go mod download -modfile=…` | 失败：`-modfile cannot be used in workspace mode` |
| 逐模块 `GOWORK=off go mod download -modfile=<仓库外副本>` | 两个模块都下载成功，仓库不变 |

下载之后 gopls 是否可用取决于仓库自己的清单（同一沙箱，一次性 CLI）：

| 仓库清单 | gopls |
| --- | --- |
| 各模块 `go.sum` 完整，没有 `go.work.sum` | 定义正确落在模块缓存，仓库里没有新增文件 |
| 模块 `go.sum` 不完整（一个为空、一个缺一行） | 工作区加载失败、0 个包：go 想写 `go.work.sum`，被沙箱拒绝（`updating go.sum: open go.work.sum: operation not permitted`） |

脚本第 3 步在沙箱外、工作区模式下运行 `go build`，它在仓库里新建了 `go.work.sum`：清单不完整时，任何不经沙箱也不带 `-modfile` 的 go 命令都可能改动仓库。

## 六、规模样本（Go 标准库，`GOROOT/src`）

冷启动到第一个定义答案 13.4 s（加载期间发出的请求被挂起后正确回答），随后引用 1.8 s、定义即时；常驻内存约 2.1 GB。这台机器上 gopls 比工具链旧，标准库里的新语法产生了类型检查诊断，数字只说明量级。

## 七、tree-sitter-go v0.25.0 + 仓库运行时

ABI 15（运行时接受 13–15），没有外部 scanner，1.5 MB `parser.c`。

| 语料 | 文件数 | 含 error 节点的文件 |
| --- | --- | --- |
| Go 1.27.3 标准库（不含 `testdata`） | 6,827（90 MB，解析 7 s） | 7 |
| 标准库 `testdata`（含故意写错的输入） | 1,259 | 58 |
| 本机模块缓存与探针模块缓存 | 2,586 | 0 |
| cobra | 36 | 0 |

标准库 7 个出错文件的首个错误行归为两种近期新语法：

- `new(表达式)`：`net/http/internal/http2/server.go:252` 的 `new("NewConnContextKey")`、`go/types/trie_test.go:66` 的 `new(42)`、`runtime/secret/secret_test.go:59`、`cmd/compile/internal/types2/trie_test.go:63`。语法把 `new` 的参数按类型解析。
- 带类型参数的方法：`math/rand/v2/rand.go:213` 的 `func (r *Rand) N[Int intType](n Int) Int`、`runtime/traceback_test.go:830`。

`encoding/json/v2/arshal_test.go` 的错误节点从文件开头起，没有定位到具体构造。本机 gopls 0.19.1 对这两种写法同样报错（`42 is not a type`、`method must have no type parameters`）。

## 复现

```sh
# 语料与依赖（探针专用模块缓存）
git clone https://github.com/spf13/cobra.git cobra && git -C cobra checkout -q --detach adbc881
(cd cobra && GOMODCACHE=$PWD/../modcache GOFLAGS=-modcacherw go mod download)

# 一、三：冷启动；把 --modcache 指向空目录即为缺依赖场景
python3 gopls_probe.py cold --root cobra --cache cache-cold --modcache modcache

# 二：热切换（先为旧提交下载依赖，再跑）
python3 gopls_probe.py switch --repo cobra --cache cache-sw --modcache modcache \
    --from 'adbc881~3' --to adbc881

# 六：规模样本
python3 gopls_probe.py scale --root "$(go env GOROOT)/src" --cache cache-std --modcache empty \
    --file net/http/server.go --pattern 'func \(\w+ \*Server\) (Serve)\(l net\.Listener\)'

# 四：一次性 CLI（追加的环境变量写在命令前）
GOTOOLCHAIN=local bash gopls_cli_probe.sh <模块目录> <缓存目录> "definition main.go:10:23"

# 七：G 为 tree-sitter-go 的源码目录
cc -O2 -ISources/CTreeSitter/include -ISources/CTreeSitter/src -I$G/src \
    docs/evidence/go-feasibility-2026-11/parse_count.c Sources/CTreeSitter/src/lib.c $G/src/parser.c -o parse_count
find "$(go env GOROOT)/src" -name '*.go' -not -path '*/testdata/*' | ./parse_count
```
