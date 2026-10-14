# 热语言服务器跨 commit 原地 checkout 探针（2026-10-12）

为"切换阅读 commit 时精确分析慢、退化"立项前的原型测量。结论已归入 [product.md](../../product.md)“只读与分析信任”与 [architecture.md](../../architecture.md)“精确分析会话与历史检出”（计划文件实现后已删除，可从 Git 历史查阅）；它不是当前产品的验收结果。

## 环境

Apple M3 Pro，macOS 27.0.1，git 2.54.0；rust-analyzer 65ac641199（2026-10-04），pyright 1.1.414，typescript-language-server 3.3.0 + typescript 5.0.2（`/opt/homebrew/lib/node_modules/typescript`），node v26.11.1。语言服务器直接以 stdio 启动，**不经 Cairn 沙箱**，初始化选项与 Cairn Safe 模式一致（见脚本）。每个场景跑 1–2 次。

语料：toydb（`~/work/rust/toydb`，60 个 `.rs`，404 commits）、mini-sglang（87 个 `.py`，103 commits）、llm-tools（`~/work/ai/llm-tools`，根 `.venv`，两个 TypeScript 单元各有 `node_modules`）。全部先 `git clone --local` 到临时目录再原地 checkout，不触碰原仓库。

## 当前成本拆分（toydb，CLI）

| 项 | 数值 |
| --- | --- |
| 索引切换（`codeinsight switch-stats`） | 相邻 commit 25 ms（内容复用 100%），HEAD~100→HEAD 86 ms（复用 5%） |
| 整树导出（`git archive \| tar` 代理当时的导出缓存 Materializer，已退役） | 70 ms（530 文件）；tokio 1.47.1 100 ms（783 文件，6.9 MB） |
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
- toydb 在 Safe 模式报 `dependenciesUnavailableOffline`：S0 查明是本机 registry 缺 `arrayref 0.3.6` / `cc 1.0.68`（`cargo metadata` 离线失败），`cargo fetch` 一次后消失；codex 上同一标注来自 sysroot 的 `cc` 构建依赖，见下文。

复现：按脚本头部用法，先 `git clone --local` 到临时目录，`python3 -I <脚本> ...`。

## S0 门槛（2026-10-13）

对应当时计划（已删除）S0 段的六项；下文“决定 N”指该计划的编号，现行结论见 architecture.md。全部实测；每项标 PASS / FAIL / BLOCKED。

### 环境与方法

- 构建：worktree HEAD `1297f2e`，Xcode 27.0（27A266a）/ Swift 6.4，`CAIRN_LIBGIT2=brew bash scripts/make-app.sh`（另以 `CAIRN_BUNDLE_IDENTIFIER=dev.cairn.s0` 打了一份隔离数据的副本），CLI 用 `swift build -c release --product codeinsight`。
- 工具：rust-analyzer 65ac641199（2026-10-04），pyright 1.1.414，typescript-language-server 3.3.0 + typescript 5.0.2，node v26.11.1，cargo 1.98.1（codex 的 `rust-toolchain.toml` 让 rustup 自动安装了 1.95.0，含 rust-src），git 2.54.0，macOS 27.0.1，Apple M3 Pro / 36 GB。
- 语料：全部 `git clone --local` 到 scratch 目录再原地 checkout，不碰原仓库。toydb（404 commits，60 `.rs`），codex（8,274 commits，`codex-rs/` 2,596 `.rs`），llm-tools（TypeScript 单元 `tools/model-files-web`，软链工作区 `node_modules`），mcp-python-sdk（Python；llm-tools 只有 8 个 `.py`，扫完 290 个 commit 没有一处跨文件新增声明，所以 Python 跨文件用例改用 `~/.cache/cairn-corpora/mcp-python-sdk` 的克隆）。
- 探针：[`s0_probe.py`](s0_probe.py)。`initialize` 逐字段照搬 `LSP.swift:502`（`processId: null`、`clientInfo CodeInsight/4`、`definition.linkSupport`、`window.workDoneProgress`、`workspace.configuration`、`experimental.serverStatusNotification`、`trace: off`），`workspace/configuration` 同 Cairn 回 null；环境照 `Sandbox.swift`（`CARGO_NET_OFFLINE=true`、`TMPDIR`/`XDG_CACHE_HOME` 指向 scratch 缓存）；`--sandbox` 时用逐字复制的 sandbox 配置和 `ulimit -t 60`/`-v` shim 经 `/usr/bin/sandbox-exec` 启动。切换顺序按决定 5：`didClose` 全部已开文件 → checkout → `workspace/didChangeWatchedFiles`（按 `git diff --name-status` 给 1/2/3）→ `didOpen` 目标文件（TO 字节）→ 每 100 ms 发一次 `textDocument/definition` 直到指向期望文件:行。所有 `experimental/serverStatus`、`$/progress`、`window/logMessage` 带时间戳记录，并对照每个信号到达时刻之前/之后的答案。
- 依赖可得性：探针第一次跑 toydb 时本机 registry 缺 `arrayref 0.3.6`/`cc 1.0.68`，离线 `cargo metadata` 失败，RA 启动到空闲用了 **84 s**（n=1，之后没再复现）。此后对四个 toydb commit 和两个 codex commit 各做了一次 `cargo fetch`（联网，只写 `~/.cargo`），之后离线 metadata 成功。codex 的 sysroot 仍报 `Failed to read Cargo metadata with dependencies for sysroot`（std 的 `cc` 构建依赖离线缺失），RA 以 health=warning 继续工作；用户仓库上的 CLI 也因此报 `dependenciesUnavailableOffline`，hover 里 `String` 显示为 `{unknown}`。本机副作用：`cargo fetch` 写入了 `~/.cargo`（registry 与 `libwebrtc` 的 git 检出），rustup 自动安装了 1.95.0 工具链，克隆与缓存都在会话 scratch 目录；用户仓库只被只读访问。

### 1. 打包应用基线 — BLOCKED（原生四段计时）/ PASS（CLI 代理）

- 原生驱动：隔离副本 `dev.cairn.s0` 的 computer-use 访问请求被拒绝（`user_denied`）；已授权的 `dev.cairn.Cairn` 被另一会话正在跑的 Cairn 实例占用（窗口 "codex — Cairn"），不能用它做切换；版本选择器本来也需要全屏控制（见 memory）。因此"正文出现 / 基础索引可用 / 精确就绪 / 返回刚读过的版本"四段墙钟和双槽 RSS 都 **BLOCKED**，留给 S4 在用户在场时补。
- 隔离副本确实在 toydb 上跑起来了：它拉起的 rust-analyzer（pid 71502）RSS 726 MB、CPU 4.57 s（加载完成后），进程环境 `TMPDIR=~/Library/Caches/CodeInsight/Exact/tmp`、`XDG_CACHE_HOME=~/Library/Caches/CodeInsight/Exact`、`CARGO_NET_OFFLINE=true`，与 `Sandbox.swift` 一致；`ps` 看不到 sandbox-exec 参数（它 exec 成服务器进程），所以沙箱保真度只能靠下面第 5 项的写入拒绝来证明。
- CLI 代理（release 二进制，在用户仓库上、Safe 模式、经沙箱；每条 = 当时的导出缓存（已退役）不参与的工作区快照 + 冷启动 RA + 第一个 hover，相当于今天每次切 commit 要重来的部分）：

| 命令 | 3 次 wall | user CPU |
| --- | --- | --- |
| `exact-hover` toydb `src/sql/execution/mod.rs:40:79`（HashJoin） | 4.09 / 4.06 / 3.60 s | 6.4–6.9 s |
| `exact-hover` codex-rs `core/src/session/session.rs:586:59`（ThreadOriginator） | 15.28 / 13.11 / 13.28 s | 50.5 / 49.5 / 49.9 s |
| `switch-stats` toydb HEAD~5→HEAD | 49 ms（复用 80%） | |
| `switch-stats` toydb HEAD~100→HEAD | 93 ms（复用 5%） | |
| `switch-stats` codex HEAD~5→HEAD（unit codex-rs/core） | 8.69 s（复用 99%） | |
| `switch-stats` codex HEAD~100→HEAD | 8.38 s（复用 79%） | |

  codex 三次冷启动各用掉 ~50 s CPU，距 `ulimit -t 60` 只剩 10 s；codex 的索引切换 8.4–8.7 s 与 RA 热切换同量级（见第 6 项），计划里"索引切换只占 5%"在 codex 上不成立，但不在本计划范围内。

### 2. 跨文件更新 — PASS

从文件 A 发 definition 到两个 commit 之间在文件 B 中新增的声明；热切换后答案与冷启动一致。时间从 checkout 结束算。

| 服务器 / 语料 | FROM→TO（变更文件） | A → B | 热切换首个正确答案 | 冷启动对照 |
| --- | --- | --- | --- | --- |
| rust-analyzer / toydb | 46308de→babe5de（24） | `execution/mod.rs:40:79` → `join.rs:142 pub struct HashJoin` | 0.657 / 0.637 s（2 次） | 3.84 s |
| rust-analyzer / codex-rs | 71448a29e7→78ba047bda（16） | `core/src/session/session.rs:586:59` → `ext/extension-api/.../thread_lifecycle.rs:11 ThreadOriginator` | 7.73 / 7.40 s（2 次） | 27.9 s |
| tsserver / llm-tools | f141608→d0b9397（13） | `sourceHighlight.worker.ts:44:46` → `core/jsonSource.ts:43 highlightJsonWindow` | 0.794 s | 0.989 s |
| Pyright / mcp-python-sdk | 17f9c00c→679b2297（11） | `client/auth.py:143:20` → `shared/auth_utils.py:8 resource_url_from_server_url` | 0.112 s（重开 A）/ 0.051 s（不重开，A 已 didClose） | 0.396 s |

- 第一轮 toydb 用例把列给错（col 19 落在 `Node::HashJoin` 变体上），答案 `plan/mod.rs:71` 其实也是该 commit 新增的跨文件声明，且在 quiescent 后首个请求即正确；表中用 col 79（`HashJoin::new`）重跑的结果。
- codex 上 quiescent 之后首个请求用了 ~1.4 s 才返回（7.40 − 5.95），返回即正确，中间只有一次在途的 `-32801 content modified`；不是旧答案。

### 3. 就绪信号 — PASS（RA 要用组合信号；Pyright 没有协议信号，给出替代判定）

**rust-analyzer**：`experimental/serverStatus` 的 quiescent "false→true" 翻转**不可靠**：

- toydb 清单切换（69c46e5↔5b72c04，Cargo.toml/lock + 385 文件）两方向都**没有**发 `quiescent=false`；只在 +1.63 s 收到一次 `quiescent=true`。只看 `isQuiescent` 的客户端会在通知发完立刻放行，而 +0.46 s 的答案是**旧 crate graph 的**（definition 落在 `tokio-0.2.19/.../listener.rs:69`，正确应为 `tokio-1.6.2/.../listener.rs:52`；反向同样 +0.458 s 给出旧版本）。
- codex 的 .rs 切换第一次 `quiescent=false` 迟到 +2.2 s（第二次 +0.04 s），toydb .rs 切换 +0.002/+0.008 s 到——时机不稳定。

可靠的组合判定（5/5 切换成立，含第 6 项 codex 的 Cargo.lock 组）：通知后先等到 `$/progress` `rustAnalyzer/Fetching` 的 begin（+0.13～0.22 s 到达），再等它之后的第一个 `serverStatus quiescent=true`（紧跟 `rustAnalyzer/cachePriming` end）。该时刻答案：toydb .rs 两次下一请求正确（在途请求收 `-32801`，Cairn 现有重试覆盖）；toydb 清单两方向正确答案在 quiescent 之前 0.05 s 已出现；codex 下一请求正确（计算 1.4 s）。`-32801` 重试仍需保留。两点补充：实测的切换都含 `.rs` 变化，一个不涉及 Rust 文件的 commit 对可能根本不触发 Fetching，所以等 Fetching begin 要设上限（实测 0.11–0.33 s 到达，1 s 足够），超时则按现有空结果/`-32801` 重试路径放行；Cairn 的 `LSPClient.serverIsQuiescent` 是粘滞值，发出通知时必须本地清零，否则清单切换（服务器不发 false）会被当成已就绪。

**Pyright**：六次运行（含 167 文件的 mcp-python-sdk 冷启动）**一次都没有**发 `window/workDoneProgress/create` 或 `$/progress`。

- 源码变化：不需要信号。按决定 5 顺序（已 `didClose`）后首个 definition 就正确（0.05–0.11 s）；旧探针里"10 s 仍旧"是因为文件没关。
- 配置变化（pyrightconfig.json）：首个答案**是旧的**（+0.002 s 仍指 libA），随后 `window/logMessage` "Reloading configuration file at …"（+0.188 s）、"Found 3 source files"（+0.450 s），正确答案 +0.232/+0.239 s。替代判定：通知里含配置文件时，等 logMessage "Reloading configuration file"；否则直接放行。两次实测该判定成立。

**tsserver**：每次切换（源码或 tsconfig）都发 `$/progress` "Initializing JS/TS language features…" begin/end：begin +0.001～0.084 s，end +0.096～0.446 s；通知后发出的请求都在 end 之后返回且正确（0.097 / 0.794 s）。以 end 为就绪信号成立。

### 4. 配置变化 — PASS（三种都热重载；RA 与 Pyright 要先过第 3 项的门）

| 配置 | 用例 | 热切换 | 冷启动 |
| --- | --- | --- | --- |
| Cargo.toml + Cargo.lock（tokio 0.2→1.6 等 20 处依赖版本/features） | toydb 69c46e5→5b72c04，`server.rs` `TcpListener` definition 落到哪个 tokio | 1.586 s 正确（tokio-1.6.2）；+0.461 s 先给旧版本 | 3.47 s |
| 同上反向 | 5b72c04→69c46e5 | 1.438 s 正确（tokio-0.2.19）；+0.458 s 先给新版本 | — |
| pyrightconfig.json `extraPaths` libA→libB（合成两 commit fixture，[`make_config_fixtures.py`](make_config_fixtures.py)） | `main.py` `f` definition | 0.232 / 0.239 s 正确（libB）；+0.002 s 先给 libA | 0.348 s |
| tsconfig.json `paths` `@lib/*` libA→libB（同上合成） | `src/main.ts` `f` definition | 0.097 s 正确；无旧答案 | 0.466 s |

语料里找不到真实的 pyrightconfig/tsconfig 语义变化（llm-tools 两个 tsconfig 各只有一次新建提交，mcp-python-sdk 的 pyproject 改动只涉及 pyright 版本号和 `typeCheckingMode`），所以这两项用合成仓库，已标明。没有需要列为重启条件的配置变化；但 RA 和 Pyright 在配置变化后 0.5 s 内会用旧配置作答，必须按第 3 项的信号门控。

### 5. 真实沙箱长驻 — FAIL（决定 9 的 `ulimit -t 60`）/ PASS（写入边界）

- 写入拒绝（`writeprobe`，sandbox 配置逐字复制自 `Sandbox.swift`，Safe 模式，项目根 = llm-tools 克隆）：克隆根、克隆内源码目录、借用的工作区 `node_modules`、`.venv`、用户仓库根、用户 `.git` 六处 `printf > 文件` 全部 `Operation not permitted`（status 1，文件未创建），`/usr/bin/log show` 有对应 `Sandbox: bash(…) deny(1) file-write-create …` 记录；缓存目录和 `cache/tmp` 两处允许。
- 长驻（`longrun --sandbox`，RA 经逐字复制的沙箱配置与 rlimit shim 启动，每次切换按决定 5 顺序并发一次 definition 作存活检查；检查位置 `kv.rs:1:28 Catalog → schema.rs` 在两个 commit 都存在，所以这里只量资源和存活，不量过期——过期由第 2–4 项覆盖）：
  - toydb 46308de↔babe5de 交替 24 次（每次 24 文件）：累计 CPU 4.62 s（冷启动）→ 6.57 s，即 **≈0.08 s/次**；RSS 864→882 MB 平稳；VSZ 466.73 GiB 不变；24 次全部有正确答案（0.01–0.23 s）；退出状态 0，无 SIGXCPU。另一组 24 次（检查位置只在一个 commit 有效，奇数次等满 60 s 超时）累计 CPU 4.88→8.77 s，RSS 从 853 MB 在空闲后回落到 28–100 MB。
  - toydb 69c46e5↔5b72c04 交替 10 次（每次 Cargo.toml/lock + 385 文件）：累计 CPU 5.08→22.82 s，即 **≈1.8 s/次**；RSS 848→968 MB；答案 0.45–0.75 s；无 SIGXCPU。按 60 s 上限推算：toydb 清单级切换约 30 次后就会被杀。
  - 长驻确实在沙箱内：`/usr/bin/log show` 在两次长驻的 RA 进程（pid 87790、88948）启动时各有十余条 `Sandbox: rust-analyzer(…) deny(1) system-info vfs.disk-space`（profile 不放行 sysctl，RA 照常工作），没有任何 `file-write` 拒绝——它只写缓存目录。
- CPU 上限：toydb 每次切换只花 0.1–0.3 s CPU，但 codex 不同——探针里（沙箱外测得，CPU 计量相同）RA 加载 codex-rs 到空闲用 53–61 s CPU，一次 16 文件的热切换再花 **18.5–18.7 s CPU**（1:00.83→1:19.33，0:53.29→1:11.94）；CLI 冷启动在沙箱内已用 50 s。沙箱内实测（`switch --sandbox`，codex 71448a29e7→78ba047bda）：加载到空闲 52.35 s CPU，**一次热切换只加 3.7 s CPU**（→56.08），答案 +2.66 s 正确，退出状态 0，没有 SIGXCPU——但只是因为还差 4 s 到上限；再切一次就会越过 60 s。和沙箱外 18.5 s/次的差别见下一条。
- 沙箱内外 RA 的切换行为不同：沙箱外每次 .rs 切换 RA 都重走 Fetching → CrateGraph → Roots Scanned → cachePriming（整个 workspace 重扫，codex 18.5 s CPU、toydb 0.3 s）；沙箱内同样的 16 文件切换**没有任何** `$/progress`/`serverStatus` 通知（3 s 内），RA 只按 `didChangeWatchedFiles` 更新那些文件，首个 definition 2.66 s 返回且正确。toydb 的两次沙箱长驻也一样：.rs 组 24 次切换 idle 都在 0.01–0.11 s（没有 quiescent 翻转），而含 Cargo.toml 的组每次都有 0.75 s 的重载。原因有记录：这次沙箱运行里 `/usr/bin/log show` 有 6 条 `Sandbox: rust-analyzer(…) deny(1) mach-lookup com.apple.FSEvents`（另有 642 条 `system-info vfs.disk-space`、2 条 DiskArbitration、1 条 coreservicesd），即沙箱外 RA 自己的 FSEvents 监视看到 checkout 后触发了整体重载，沙箱内这个监视拿不到，只剩客户端的 `didChangeWatchedFiles`；Cairn 的会话都在沙箱内，所以 **S2 的 RA 就绪判定不能依赖 Fetching 一定出现**（第 3 项的上限条款因此是必需的，不是兜底）。VSZ 恒为 466–467 GiB（dyld 共享缓存），远低于 512 GiB 上限，无分配失败。
- RSS：toydb RA 850–1,000 MB，空闲一段时间后回落到 60–230 MB；codex RA 4.0–4.9 GB，切换后 3.4–4.3 GB。双槽（决定 7）若两槽都是 codex 量级约 8–9 GB，未在应用内实测。

### 6. codex 上的热 RA 切换 — PASS（量到了；但规模结论见第 5 项）

[`rust_analyzer_probe.py`](rust_analyzer_probe.py) 已改为 Cairn 的 initialize 能力集与沙箱环境变量，并加 `--serve-root/--target/--expect`（hover 判定，目标文件以 TO 字节 `didOpen`）；`s0_probe.py` 用 definition 判定同一组 commit。服务器根 `codex-rs/`（workspace 134 crates，Roots Scanned 1095）。

| 组 | 变更 | 原型脚本（hover 正确 / quiescent） | s0_probe（跨文件 definition 正确 / quiescent） | 冷启动 |
| --- | --- | --- | --- | --- |
| 只有 .rs：71448a29e7→78ba047bda | 16 文件 | 2.94 s / 5.37 s | 7.73、7.40 s / 6.29、5.95 s | hover 9.11 s（quiescent 15.15 s）；definition 27.9 s（quiescent 16.1 s） |
| 含 Cargo.lock：9ff47868eb→a47c661ea9（Cargo.lock −1、ext/skills/Cargo.toml −1 依赖、新文件 fielded_bm25.rs） | 7 文件（A=2 M=4 D=1） | 3.16 s / 5.12 s | 3.19 s / 5.49 s（`dynamic_skill_selector.rs:3:30` 的 `use` → 新文件 `fielded_bm25.rs:25`） | definition 9.21 s（quiescent 13.4 s） |

- 原型脚本的 `switch-rs --target` 路径在 toydb 46308de→babe5de 上跑过一次：hover 正确 0.78 s，quiescent +0.78 s，与 s0_probe 的 definition 0.64–0.66 s 一致。
- 表中数字都是沙箱外测得：两组热切换都在 5–6 s 回到 quiescent，比冷启动的 15–16 s 快约 3 倍，但每次切换 RA 都重走 Fetching → Building CrateGraph → Roots Scanned → cachePriming（1095 roots 重扫），CPU 18.5 s/次。沙箱内（FSEvents 被拒）同一 .rs 组不重载，definition 2.66 s 正确、CPU 3.7 s（第 5 项）。
- hover 在 didOpen 的文件上先于 quiescent 正确（它只依赖该文件自身），不能作为"索引已更新"的证据；跨文件 definition 才是验收口径。
- 含 Cargo.lock 组的 definition 在 `Roots Scanned` 结束后、cachePriming 期间就已正确（+3.19 s，quiescent +5.49 s）。最初选的使用点 `shadow_selection_experiment.rs:41:26`（`Box::new(FieldedBm25SkillSelector)`）热切换和冷启动都返回空（各 180 s），原因未查，换到 `use` 行后两者一致，所以不是热切换问题。
- 这一组是在 `cargo fetch` 之后测的：之前离线 metadata 失败时（9ff47868eb 还带 `libwebrtc` git 依赖），RA 以 health=warning 加载却对 ext/skills 内的 definition 一直返回空（300 s），冷启动也一样——依赖不可得时 RA 的 crate graph 残缺，不是热切换问题，但用户机器上会以"精确分析空结果"出现。
- RSS：codex RA 空闲 4.0–4.9 GB，切换后 2.6–4.3 GB；双槽按两份 codex 估算 8–9 GB（未实测）。

### 结论：可以进入 S2，但先修订决定 5、9，并给决定 7、6 补条件

| 项 | 结果 |
| --- | --- |
| 1 打包应用基线 | BLOCKED（原生四段计时、双槽 RSS）；CLI 代理 PASS |
| 2 跨文件更新 | PASS（三种服务器热切换后首个正确跨文件结果 = 冷启动答案） |
| 3 就绪信号 | PASS，但 RA 不能只看 quiescent 翻转，Pyright 没有协议信号 |
| 4 配置变化 | PASS（Cargo/pyrightconfig/tsconfig 都热重载，无需重启条件） |
| 5 真实沙箱长驻 | 写入边界 PASS；`ulimit -t 60` FAIL（codex 加载已用 52 s CPU，沙箱内每次 .rs 切换 3.7 s，第 2–3 次切换越限） |
| 6 codex 热 RA | PASS（5–6 s 回到空闲 vs 冷 15–16 s；definition 7.4–7.7 s vs 冷 27.9 s） |

需要修订的决定：

- **决定 5（就绪确认）**：RA 的确认改为"`$/progress` `rustAnalyzer/Fetching` begin 出现之后的第一个 `serverStatus quiescent=true`"，不能用 `quiescent` 的 false→true 翻转（清单切换不发 false，.rs 切换 false 可迟到 2 s）；quiescent 后仍要保留 `-32801` 重试。而且在沙箱内（Cairn 的真实环境）只改 `.rs` 的切换根本不触发 Fetching、不发任何通知，答案直接正确——所以等 Fetching 必须有约 1 s 的上限，超时即放行；只有通知里含 Cargo.toml/Cargo.lock 时才一定会有重载信号。Pyright 没有 `$/progress`：源码变化直接放行（已 `didClose` 的前提下首个答案即正确），通知含 pyrightconfig/pyproject 时等 `window/logMessage` "Reloading configuration file"；tsserver 用 "Initializing JS/TS language features…" 的 end。"暂停新请求直到确认"必须真的挡住请求：RA 清单切换和 Pyright 配置切换都在通知后 0.5 s 内给过旧答案。
- **决定 9（沙箱）**：废除累计 `ulimit -t 60`。实测沙箱内 codex 加载 52 s CPU、每次 .rs 热切换 3.7 s、toydb 清单切换 1.8 s/次（沙箱外因 FSEvents 触发整体重载是 18.5 s/次，不是 Cairn 会遇到的数字）；现有上限在 codex 上加载后只够切 1–2 次，CLI 冷启动已用 50 s。替代为按单次请求/切换的墙钟监控或把上限提到以小时计；`ulimit -v` 可保留（VSZ 恒 467 GiB）。写入边界按现配置即可：检出目录、借用的 `node_modules`/`.venv`、用户仓库与 `.git` 都已被拒。
- **决定 7（双槽）**：codex 单槽 RSS 4–5 GB，双槽 8–9 GB；"默认不加释放策略"要改成按 RSS 或空闲时间释放待命槽，至少对大仓库。
- **决定 6（复用条件）**：三种配置变化都能热重载，`configFingerprint` 走热更新的决定成立；补一条：Safe 模式下依赖离线不可得会让 RA 加载极慢（toydb 84 s，n=1）或 crate graph 残缺（codex 旧 lock 下 definition 全空），切换前后依赖可得性变化应作为"结果不可信"的标注条件，而不是复用条件。
- S4 原生验收前要补第 1 项：在用户在场时用隔离 bundle id 的构建跑四段计时与双槽 RSS。

复现：`docs/evidence/warm-lsp-switch-2026-10/s0_probe.py --help`；原始日志在本次会话 scratch 目录，未入库。

## 实现后测量（2026-10-13）

**测试层证据，非原生验收。** S1–S3 合入后（分支线性包含 a4f117d），用仓库里的真实语料测试复测热切换；它们走 `RustAnalyzerProvider` 的 Safe 模式（沙箱）、`CheckoutRoot` 检出目录与 `LSPLanguageSession.switchSnapshot` 的就绪确认，但不经 `ExactCoordinator` 与界面，不含正文、索引与状态栏时间。环境同 S0（M3 Pro，rust-analyzer 65ac641199，Xcode 27.0 / Swift 6.4）。

| 用例（测试） | 冷启动 | 热切换返回（含就绪确认） | 首个正确答案 |
| --- | --- | --- | --- |
| toydb 46308de→babe5de，`execution/mod.rs:40:79` → `join.rs:142 HashJoin`（`rustAnalyzerWarmSwitchResolvesACrossFileDeclarationOnToydb`） | 2.76–2.99 s（S2 报告）；本次复测 3.67 / 2.82 s | 0.46–0.49 s；复测 0.49 / 0.48 s | 0.50–0.54 s；复测 0.54 / 0.53 s |
| toydb 69c46e5→5b72c04（Cargo.toml/Cargo.lock，tokio 0.2→1.6），`server.rs` `TcpListener`（`rustAnalyzerWarmSwitchFollowsACargoLockChangeOnToydb`） | 复测 3.07 / 3.04 s | 1.8–2.0 s；复测 1.84 / 1.82 s | 返回后 +0.07 s，落在 tokio-1.6.2 |
| 同上反向 5b72c04→69c46e5 | — | 0.78 s；复测 0.80 / 0.80 s | 返回后 +0.04–0.05 s，落在 tokio-0.2.19 |

- 两组都没有出现旧 crate graph 的答案：S0 里通知发完 +0.46 s 会拿到旧 tokio，现在请求被挡到 Fetching→quiescent 确认之后。
- 复测命令：`swift test --no-parallel --filter 'rustAnalyzerWarmSwitchResolvesACrossFileDeclarationOnToydb|rustAnalyzerWarmSwitchFollowsACargoLockChangeOnToydb'`，需要 `~/work/rust/toydb` 与本机 rust-analyzer，缺少时打印 SKIP；Cargo.lock 组还需要本机 registry 有两版 tokio（S0 做过 `cargo fetch`）。
- 依赖借用（CLI，`codeinsight exact-hover --revision 1ed4fd3 --definition`，llm-tools）：TypeScript `tools/model-files-web/src/tokenizer.worker.ts:3:10` hover `(alias) class Tokenizer`，definition `…/tools/model-files-web/node_modules/@huggingface/tokenizers/types/core/Tokenizer.d.ts:21:15`；Python `main.py:233:43` hover `def is_available() -> bool`，definition `…/.venv/lib/python3.10/site-packages/torch/cuda/__init__.py:163:5`；两者标注 `dependenciesBorrowedFromWorkspace`，冷启动约 1.3–2.2 s。CLI 直接调用会话，不经协调器；`.d.ts` 被协调器保留为跳转目标由 `exactCoordinatorBorrowsWorkspaceNodeModulesAndKeepsTheirDeclarationsAsDependencies` 覆盖。
- 应用内热切换、双槽 RSS、四段墙钟见下文"原生验收结果（2026-10-14）"。

## 原生验收清单（2026-10-14 已执行，结果见文末）

S4 原生段，需用户在场（版本选择器、`⌘` 单击与弹出框无法由后台自动化驱动）。每项记 PASS / FAIL / BLOCKED，写明构建 SHA、语料 commit、时间和截图文件名；不得用上文测试层数字代替。

**准备**

- 构建：`bash scripts/check-toolchain.sh`；`CAIRN_LIBGIT2=brew bash scripts/make-app.sh`；隔离数据副本 `CAIRN_LIBGIT2=brew CAIRN_BUNDLE_IDENTIFIER=dev.cairn.s4accept bash scripts/make-app.sh --output .build/s4accept`（不给 `--output` 会覆盖默认产物）。记录：构建 SHA ______，应用路径 ______。
- 退出其他 Cairn 实例，或只用隔离副本。注意检出目录 `~/Library/Application Support/CodeInsight/checkouts/` 不随 bundle id 区分，两个实例共用父目录（各自持锁，不会互删）。
- 记录工具版本：`rust-analyzer --version`、`pyright --version`、`typescript-language-server --version`、`node --version`。
- 进程与内存：`ps -axo pid,ppid,rss,etime,command | grep -E 'rust-analyzer|pyright|typescript-language-server|tsserver' | grep -v grep`（rss 单位 KB）。检出目录：`ls -l ~/Library/Application\ Support/CodeInsight/checkouts/` 与 `du -sh` 同目录。
- 计时：屏幕录像或秒表，从在版本选择器中按下回车/点击条目开始。四段 = 正文出现、基础索引可用（大纲出现且项目搜索可执行）、精确分析就绪（状态栏）、返回刚读过的版本（切回后正文与精确就绪）。

**1. toydb 四段计时（`~/work/rust/toydb`）**

1. 打开 toydb，等工作区精确就绪，打开 `src/sql/execution/mod.rs`。
2. 版本选择器输入 `HEAD~5`，选“解析结果”；记四段中的前三段；再选回工作区，记第四段。重复 3 次。
3. 同样做 `HEAD~100` 3 次（含 Cargo.toml/Cargo.lock 变化）。
4. 预期：没有新的 rust-analyzer 冷启动（`ps` 中检出槽进程 pid 在同组重复中不变）；`HEAD~5` 精确就绪明显短于 S0 的冷启动 CLI 代理 3.6–4.1 s；切回工作区时待命槽即时可用（不出现新 pid）。
5. 记录：12 组墙钟、每次切换后的 pid、截图（状态栏就绪）。

**2. 跨文件正确性（toydb）**

1. 停在 46308de，打开 `src/sql/execution/mod.rs`，切到 babe5de。
2. 立即在第 40 行第 79 列（`HashJoin::new`）`⌘` 单击。
3. 预期：打开 `src/sql/execution/join.rs` 第 142 行 `pub struct HashJoin`；不出现旧位置或空结果。记录从切换到正确跳转的时间（验收以此为准，不以状态栏为准）。
4. Cargo.lock 组：停在 69c46e5，打开 `src/server.rs`，切到 5b72c04 后 `⌘` 单击 `TcpListener`，预期落到 `tokio-1.6.2/…/listener.rs`；反向预期 `tokio-0.2.19/…/listener.rs`。截图两次跳转结果。

**3. 双槽与释放（toydb、codex）**

1. toydb 停在任一 commit：`ps` 应看到两个 rust-analyzer（工作区待命 + 检出目录当前），记录两者 RSS。
2. 停在 commit 不操作 10 分钟以上：预期工作区那个进程消失（每 30 秒检查一次）；再切回工作区时冷启动一个新 pid。
3. codex（`codex-rs/` 单元）：切到 commit 后记录两槽 RSS；预期待命槽 RSS 超过 2 GB 时约 30 秒内被关闭。

**4. codex 四段计时**

1. 打开 codex，打开 `codex-rs/core/src/session/session.rs`，等工作区精确就绪。
2. `HEAD~5`、`HEAD~100` 各 3 次，记四段；注意 codex 的索引切换本身 8.4–8.7 s（S0），与精确分析分开记录。
3. 可选跨文件：71448a29e7→78ba047bda，`core/src/session/session.rs:586:59` `⌘` 单击，预期 `thread_lifecycle.rs:11 ThreadOriginator`。

**5. llm-tools 历史 commit 的第三方依赖（`~/work/ai/llm-tools`，1ed4fd3）**

1. 打开 llm-tools，版本选择器切到 1ed4fd3。
2. TypeScript：打开 `tools/model-files-web/src/tokenizer.worker.ts`，悬停第 3 行 `Tokenizer`，预期 `(alias) class Tokenizer`，来源标注“依赖来自当前工作区，可能与该 commit 不一致”；`⌘` 单击，预期在新标签页只读打开 `node_modules/@huggingface/tokenizers/types/core/Tokenizer.d.ts` 并按 TypeScript 高亮。
3. Python：打开 `main.py`，悬停第 233 行 `is_available`，预期 `def is_available() -> bool`；`⌘` 单击，预期打开 `.venv/lib/python3.10/site-packages/torch/cuda/__init__.py` 第 163 行。
4. 关系展开：在依赖文件中的符号（或 `Tokenizer`）上查看引用/调用关系，预期列出结果或明确说明，不因快照缺少该文件而报错。
5. 依赖标签页恢复：保留第 2 步打开的 `.d.ts` 标签，`⌘Q` 后重新启动，预期标签恢复、正文从磁盘显示、高亮正常。
6. 离线标注：切回工作区，打开同一 TypeScript 文件，预期不再显示“离线依赖不可用”（单元根有 `node_modules`）。
7. 截图：两处 hover、两次跳转后的路径栏、恢复后的标签。

**6. 窗口隔离与目录生命周期**

1. toydb 窗口停在 commit A，再打开 llm-tools 停在 commit B；`ls` 检出目录应有两个 UUID 子目录。
2. 在一个窗口切换 commit，另一个窗口的精确分析不受影响（状态栏不变，hover 正常）。
3. 再次打开 toydb：预期激活已有窗口，不新建。
4. 关闭 llm-tools 窗口：其检出目录被删除，另一个保留。
5. `kill -9` 应用后重新启动：预期残留目录在启动时被删除。

**7. 刷新、恢复与清理后重建**

1. 停在 commit 时 Refresh Index：精确分析重新就绪，hover 正常。
2. 切回工作区：待命槽即时可用（无新 pid）。
3. 停在 commit 时退出并重启（恢复会话）：精确分析在检出目录中重建并就绪。
4. 设置 → 清除检出目录：显示的总大小与 `du` 一致；确认后所有窗口精确分析停止、目录删除；再切 commit 时重新检出并就绪。

## 原生验收结果（2026-10-14）

**构建与环境**：main `a0f7f13`，隔离副本 `.claude/worktrees/agent-a5889da1be75ee92d/.build/s4accept/Cairn.app`（bundle id `dev.cairn.s4accept`，由同一 SHA 构建）。rust-analyzer 0.0.0 (65ac641199 2026-10-04)、pyright 1.1.414、typescript-language-server 3.3.0 / typescript 5.0.2、node v26.11.1；macOS 27.0、M3 Pro；09:10–10:24 本地时间。语料：toydb `HEAD~5`=a15a351、`HEAD~100`=69c46e5、跨文件对 46308de→babe5de、Cargo.lock 对 69c46e5↔5b72c04；codex HEAD=315195492c、`HEAD~5`=78ba047bda、`HEAD~100`=325cf16194（与 HEAD 差 700 文件，含 14 个 Cargo.toml/Cargo.lock；`HEAD~5` 差 34 文件，无 Cargo 变化）；llm-tools 1ed4fd3。

**执行方式**：由 agent 接管桌面（computer-use 全控制），版本选择器与 `⌘` 单击都是前台真实输入。计时用 `screencapture` 每约 0.4 s 截前窗一帧，按状态栏 / 正文 / 大纲 / 工具栏四个区域的哈希找变化帧；"点击"时刻取批处理里固定 1.5 s 等待后的点击，误差约 ±0.4 s。"就绪"以状态栏回到就绪文案的那一帧为准。每秒记录语言服务器 pid/RSS（`ps`），原始帧与日志在会话 scratch 目录，未入库。

| 项 | 结果 |
| --- | --- |
| 1 toydb 四段计时 | PASS。12 次切换无新 rust-analyzer pid（检出槽 30675 自首次切换起一直复用），正文与大纲同帧出现、≤0.45 s；返回工作区 ≤0.45 s、无准备中、无新 pid |
| 2 跨文件正确性 | PASS（babe5de `HashJoin::new` → `join.rs:142 pub struct HashJoin`，Cargo.lock 对两个方向分别落在 tokio-0.2.19 / tokio-1.6.2 的 `listener.rs`）；"切换后立即 `⌘` 单击"一次 INCOMPLETE（见下） |
| 3 双槽与释放 | PASS（10 分钟释放 ×2、RSS > 2 GB 释放 ×6）；发现 F4 |
| 4 codex 四段计时 | 已测 11 次有效；每次切换都冷启动检出槽，点击→状态栏就绪 11.1–12.5 s（原因见 F4），commit 上的 hover 未验证。可选跨文件未执行 |
| 5 llm-tools 依赖 | hover PASS ×2；来源标注 FAIL（F3）；`⌘` 单击打开依赖源码 FAIL ×2（F2，既有缺口）；关系展开 PASS（带保留）；标签恢复 BLOCKED（F2 之后没有可恢复的标签）；离线标注（5.6）未执行 |
| 6 窗口隔离与目录生命周期 | PASS ×5 |
| 7 刷新、恢复、清理 | 7.1、7.3、7.4 PASS；7.2 的"无新 pid"条件不适用（待命槽已按 10 分钟规则释放，切回冷启动但正文即时） |

**toydb 墙钟**（点击→正文；状态栏准备中可见时长；pid）

| 切换 | 正文 | 准备中→就绪 | rust-analyzer |
| --- | --- | --- | --- |
| 工作区→HEAD~5（首次） | ≤0.45 s | 未出现：状态栏始终"就绪"，但检出槽是冷启动（新 pid 30675，RSS 约 5 s 内升到 947 MB） | 25434 待命 + 30675 新 |
| HEAD~5→工作区 ×3 | ≤0.45 s | 无 | 不变 |
| 工作区→HEAD~5 第 2、3 次 | ≤0.45 s | 无 / 一帧（<0.45 s） | 不变 |
| 工作区→HEAD~100（首次，Cargo.lock 变化） | 0.4 s | 2.5 s | 不变 |
| HEAD~100→工作区 ×2 | ≤0.45 s（第 2 次 0.8 s 后再重绘一次） | 无 | 不变 |
| 工作区→HEAD~100 第 2、3 次（检出槽仍停在 69c46e5） | ≤0.45 s | 无 | 不变 |
| HEAD~100→HEAD~5 直接 | ≤0.55 s | 1.4 s | 不变 |
| HEAD~5→HEAD~100 直接 | ≤0.45 s | 1.3 s | 不变 |
| 46308de→babe5de | 0.4 s | 0.8 s | 不变 |
| 69c46e5→5b72c04、反向 | ≤0.45 s | 1.2 s / 未单独计时 | 不变 |

"基础索引可用"没有单独计时：大纲区域总与正文同帧变化，项目搜索未在切换中执行。状态栏在冷启动时不可信：协调器在 provider 准备完成时就把会话标为就绪（`ExactCoordinator.activate`），首次切换的 rust-analyzer 还在加载时状态栏已显示"就绪"。

**跨文件**：切到 babe5de 后约 17 s `⌘` 单击 `HashJoin::new`，直接打开 `join.rs:142`，上下文面板标"精确 · 直接"（`toydb-babe5de-cmdclick-hashjoin-join142.jpg`）。切换后约 1.5 s 的盲点 `⌘` 单击（弹出框尚在关闭）10 s 内没有任何跳转，无法区分是点击没落到正文还是查询为空，记 INCOMPLETE。Cargo.lock 对：69c46e5 的 `TcpListener` → `…/tokio-0.2.19/src/net/tcp/listener.rs`，5b72c04 → `…/tokio-1.6.2/src/net/tcp/listener.rs:52`（两张 `toydb-*-tcplistener-*.jpg`，路径在上下文面板标"外部"）。

**双槽与 RSS**

| 场景 | 观察 |
| --- | --- |
| toydb 停在 commit | 两个 rust-analyzer：工作区待命 25434 约 649 MB，检出槽 30675 约 947 MB |
| 10 分钟释放 | 待命槽在最后一次离开工作区（09:24:4x）后 10 分钟消失（最后一次出现 09:34:45）；期间 commit↔commit 切换不重置计时。之后切回工作区冷启动新 pid 57042（正文仍 ≤0.45 s，状态栏无准备中）。kill -9 重启后同样：65019 在 10:00:49 启动、10:11:05 消失 |
| codex（`codex-core` 单元；选择器按 crate 列单元，没有 `codex-rs` 工作区单元） | 工作区服务器 67267 加载中 4.2–4.3 GB，峰值 5.19 GB。切到 `HEAD~5` 后检出槽新 pid 69454（峰值 5.05 GB）；切回工作区后 69454 在约 21 s 内被关闭（RSS > 2 GB 规则生效）。之后每次 commit 访问都新起一个检出槽进程（72705、75216、77487、79790、82521，峰值 4.2–5.0 GB），切回时都在 20–60 s 内关闭 |

**codex 墙钟**（点击→正文 / 点击→状态栏就绪；`HEAD~5` 第 3 次的帧因弹出框成为前窗而作废）

| 切换 | 正文 | 状态栏就绪 | 检出槽 pid |
| --- | --- | --- | --- |
| 工作区→HEAD~5 ×2 | 0.4、0.9 s | 12.5、11.5 s | 69454、72705 新 |
| HEAD~5→工作区 ×3 | 0.8、0.8、0.9 s | 11.6、11.6、11.3 s | 复用 67267 |
| 工作区→HEAD~100 ×3 | 0.9、0.9、0.9 s | 11.6、11.4、11.4 s | 77487、79790、82521 新 |
| HEAD~100→工作区 ×3 | 0.6、0.8、0.85 s | 11.1、11.7、11.9 s | 复用 67267 |

状态栏序列固定为"准备中"（约 10 s）→"准备中 · 安全模式"（约 1 s）→"就绪 · 安全模式（受限）"（`codex-325cf16-status-preparing.jpg`）。切回工作区虽复用 67267，仍要 11 s 多才就绪，与切到 commit 的冷启动相当，说明 codex 规模下索引切换（S0 测 8.4 s）与会话激活合起来主导，热槽本身省下的时间不可见。状态栏数字在冷启动时只是下界（见上）：按 `ps` 日志，六个新检出槽进程从启动到 RSS 达峰值 90% 用了 8–13 s（峰值 4.1–4.9 GB），与状态栏就绪时刻大致重合，但 commit 上的 hover 没有做，精确结果何时可用未验证。

**llm-tools 1ed4fd3**：检出目录含借来的 `tools/model-files-web/node_modules` 与 `.venv`（16 MB）。TypeScript hover 卡片 `class Tokenizer` / `import Tokenizer`、"没有文档注释"（`llm-tools-1ed4fd3-hover-tokenizer.jpg`）；Python hover `def is_available() -> bool` 带 docstring（`llm-tools-1ed4fd3-hover-is_available.jpg`）。两张卡片都没有"依赖来自当前工作区，可能与该 commit 不一致"脚注（F3）。`⌘` 单击 `Tokenizer`：阅读区停在 import 行，上下文面板显示"Tokenizer → 类型需要精确分析 · 未就绪 … 高可信度 · 直接 · 导入绑定"，没有打开 `.d.ts`（`llm-tools-1ed4fd3-cmdclick-tokenizer-context.jpg`）；`⌘` 单击 `is_available` 没有任何导航。同时用 debug CLI `exact-hover --revision 1ed4fd3 --definition` 复核，两处 definition 都正确落到 `Tokenizer.d.ts` / `torch/cuda/__init__.py:163`，问题在应用的点击路径（F2）。关系面板在该 commit 上列出 47 条引用、带"已验证 / 直接"标签、无报错（`llm-tools-1ed4fd3-references-tokenizer.jpg`），但面板主题显示为所在函数 `reply`（`tokenizer.worker.ts:228`）而不是 `Tokenizer`，未深究。切回工作区再回 1ed4fd3 各起一对新的 tsserver 进程（50997/50998 → 52085/52086），旧对保留到关窗。

**窗口隔离与生命周期**：toydb 停 5b72c04、llm-tools 停 1ed4fd3 时检出目录有两个 UUID 子目录（3.9 MB、16 MB）。llm-tools 切换期间 toydb 状态栏保持就绪、`TcpListener` 上下文仍指向 tokio-1.6.2、rust-analyzer 30675 不变。`open -a … toydb` 激活已有窗口（仍两个窗口）。通过"文件 → 关闭窗口"关闭 llm-tools 后约 9 s 其目录删除、tsserver 退出，toydb 目录保留（`⌘⇧W` 键击在接管下没有关闭窗口，未查原因）。`kill -9` 后目录残留，重启时被删除并为恢复的窗口新建目录。

**刷新、恢复、清理**：停在 5b72c04 `⌘R`：状态栏经"准备中"约 0.5 s 回到就绪，pid 不变，hover 正常。之后切回工作区：待命槽已按 10 分钟规则释放，所以冷启动了新 pid（正文 ≤0.45 s）。停在 a15a351 退出再启动：新目录、两个新 rust-analyzer，窗口恢复到 a15a351 的 `server.rs`、状态栏就绪。设置 → 精确分析显示"2.4 MB"，等于目录的 apparent size（`du -sh` 磁盘占用 3.9 M）；确认清除后显示"检出目录已清除"，停在 commit 的窗口在约 9 s 内重新检出（同一 UUID 目录重建）、新 pid 64206、状态栏就绪。

**发现**

- F1 版本选择器：输入 `HEAD` 只显示摘要含 "headers" 的子串命中（80de019），没有解析行；因为有过滤命中就不解析（`CommitPickerModel`）。输入 `HEAD~5`、`HEAD~100` 正常解析。
- F2 应用内 `⌘` 单击不会打开项目根目录下的依赖目标（借来的 `node_modules/*.d.ts`、`.venv/*.py`），commit 与工作区模式都如此，是既有缺口不是本次回归：`ContextWindowModel.explicitJump` 只跳本地索引候选，没有候选即返回；精确结果只经 `applyExact` 进入，而 `projectPath()` 把项目根下的绝对路径相对化，候选因此失去 `exactLocationIsInDependency`，不作为依赖目标呈现。registry 等项目根之外的路径不受影响（toydb 的 tokio 跳转正常）。
- F3 借用依赖的 hover 脚注（`reader.hover.note.borrowed`）在两处 hover 都没有显示。
- F4 待命槽按 RSS 释放会漏掉驻留集被系统收走的进程：codex 工作区服务器停驻后 RSS 读数从 4.3 GB 降到 80 MB（疑为内存压缩，未直接观察），没有触发 > 2 GB 释放；而检出槽每次都超限被关，导致每次访问 commit 都冷启动。双槽同时驻留时实际峰值 5.19 + 5.05 GB。
- F5 文案：状态栏在冷启动期间已显示"就绪"（见上）；commit 模式路径栏仍显示"只读快照 · 工作区未改动"。

**局限**：帧间隔 0.4 s、点击时刻按批处理推算；"基础索引可用"未单独计时；codex 只测了 `codex-core` 单元、未在 commit 上 hover；5.5、5.6 与可选 codex 跨文件未执行；`screencapture` 首次运行触发了 macOS 屏幕录制权限提示，未处理，帧仍可用。截图：本目录 8 张 `*.jpg`。
