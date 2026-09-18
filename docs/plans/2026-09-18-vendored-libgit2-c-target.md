# Vendored libgit2 头文件进包图——CLibGit2 改造为 C target（修复 swiftbuild 构建失败）

日期：2026-09-18
状态：实施完成（A1–A8 验收全绿，§4 实测结论见文内）
关联：根因诊断于 2026-09-18 完成（本文件 §1 为其摘要）。

## 1. 背景与根因（摘要）

`scripts/make-app.sh` 自 2026-09-16 起在 `swift build -c release --product codeinsight-app` 失败：
`Sources/CLibGit2/shim.h:1: 'git2.h' file not found`。

根因链条（诊断时已用对照实验逐环证实）：

1. 2026-09-15 20:12 本机升级 Xcode 27.0 beta（Swift 6.4）。SwiftPM 默认构建系统由 llbuild 切换为 **swiftbuild**（explicit module builds + clang dependency scanning；`swift build --help` 显示 default: swiftbuild，native 已弃用）。
2. vendored 模式（`CAIRN_LIBGIT2=vendored`，make-app.sh 自动选中）下，`CLibGit2` 是无 pkgConfig 的 `systemLibrary`，头文件搜索路径仅通过 `.unsafeFlags(["-Xcc","-I…/Vendor/libgit2/include"])` 挂在 **CodeInsightGit 一个 target** 上。SwiftPM 语义上 unsafeFlags 不向依赖方传播。
3. 旧 llbuild 引擎下该缺陷被共享 clang module cache 掩盖（模块在 CodeInsightGit 编译时带 `-I` 建好，下游复用）；swiftbuild 要求每个 target 的编译/扫描自行构建 CLibGit2 模块（编译行带 `-fmodule-map-file` 但无 `-I`），于是所有传递依赖方失败。构建计划（`.build/manifest.pif`）实测：仅 CodeInsightGit 的命令行含 vendored `-I`。
4. 对照实验：vendored+swiftbuild 建 `CodeInsightGit`（有 `-I`）✅；建 `CodeInsightExact`（传递依赖）❌（即 make-app 失败点）；vendored+`--build-system native` ✅；brew+swiftbuild ✅（pkgConfig 路径可传播，仅 unsafeFlags 传法不可）。

时间线：最后成功产出 `Cairn.zip` 为 09-15 17:05（llbuild 布局）；Xcode 27 于 09-15 20:12 装入；swiftbuild 布局 `.build/out` 首现 09-16 08:51；此后 make-app 必挂。CI（product-quality.yml / pages.yml / scripts/ci.sh）不使用 vendored，未受影响。

## 2. 目标与非目标

**目标**

- G1 vendored 模式在 swiftbuild（当前与可预见未来的唯一引擎）下从编译、链接到打包全通。
- G2 brew 模式（默认 dev/CI 路径）行为零变化。
- G3 前置条件缺失时失败响亮且可指导（明确指向 `scripts/vendor-libgit2.sh`），不允许静默回落到 brew 1.9.7（vendored 为 1.9.6，混链即事故）。
- G4 发版安全底线：vendored 产物不得引用任何 `/opt/homebrew` 动态库——脚本层硬校验。

**非目标**

- 不升级 vendored libgit2 版本（仍 v1.9.6）。
- 不引入 pkg-config 宿主依赖（放弃方案 B 的核心原因）。
- 不改动 notarization / Developer ID 流程。
- 不承诺 `--build-system native` 长期可用（官方已弃用，仅作应急逃生门）。

## 3. 设计

### 3.1 核心思路

把 vendored 模式下的 `CLibGit2` 从 systemLibrary（modulemap + 外挂 `-I`）改为**普通 C target**（`publicHeadersPath: "include"`），头文件成为包图一等公民：依赖方按 SwiftPM 公开头文件可见性规则获得搜索路径，无需任何"传播"。这正是本仓库 `CTreeSitter` / `CTreeSitterRust` / `CTreeSitterPython` / `CTreeSitterTypeScript` 已采用、且 2026-09-18 CI（swiftbuild 引擎）382 项测试全绿验证过的模式。brew 模式的 systemLibrary + pkgConfig 声明原样保留。

### 3.2 目录形态

```
Sources/CLibGit2/
├── module.modulemap   # 不变。brew systemLibrary 与 vendored C target 共用：
│                      #   module CLibGit2 [system] { header "shim.h"; link "git2"; export * }
├── shim.h             # 不变（#include <git2.h> + 4 个 static inline 辅助函数）
├── shim.c             # 新增（tracked，内容一行：#include "shim.h"）
└── include/           # 新增（generated + gitignored）：Vendor/libgit2/include 的副本
```

`shim.c` 的两个作用：C target 需要至少一个可编译源文件；编译它等于自检"shim.h + vendored 头文件可作为独立 C 编译单元"。brew 模式下该文件在 systemLibrary 目录中闲置，无害（systemLibrary 不编译源文件）。

手写 module.modulemap 在两种模式下的角色：brew 模式沿用（`link "git2"` 与 pkgConfig 协同，现状不动）；vendored 模式下 SwiftPM 采用 target 内的手写 modulemap（`header "shim.h"` 单入口，`git2.h` 经 `publicHeadersPath` 解析），链接改由显式 `.linkedLibrary("git2")` 声明，不依赖 modulemap 的 link 指令。

### 3.3 Package.swift

替换现有 `libgit2SwiftSettings` / `libgit2LinkerSettings` 块与 `CLibGit2` target 声明：

```swift
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let vendoredLibGit2 = packageRoot.appendingPathComponent("Vendor/libgit2")
let vendoredLibGit2Headers = packageRoot.appendingPathComponent("Sources/CLibGit2/include")
if libgit2Mode == "vendored" {
    if !FileManager.default.fileExists(
        atPath: vendoredLibGit2.appendingPathComponent("lib/libgit2.a").path
    ) {
        fatalError("Run scripts/vendor-libgit2.sh before using CAIRN_LIBGIT2=vendored")
    }
    if !FileManager.default.fileExists(
        atPath: vendoredLibGit2Headers.appendingPathComponent("git2.h").path
    ) {
        fatalError(
            "Vendored libgit2 headers are not staged into Sources/CLibGit2/include; "
                + "re-run scripts/vendor-libgit2.sh (scripts/make-app.sh also refreshes them)"
        )
    }
}

// Vendored mode builds CLibGit2 as a regular C target whose public headers are
// part of the package graph, so every build engine resolves them without
// target-local -I flags (swiftbuild's explicit module builds do not propagate
// unsafeFlags to transitive dependents). Brew mode keeps the pkg-config
// systemLibrary.
let clibGit2Target: Target = if libgit2Mode == "vendored" {
    .target(
        name: "CLibGit2",
        publicHeadersPath: "include",
        linkerSettings: [
            .unsafeFlags(["-L" + vendoredLibGit2.appendingPathComponent("lib").path]),
            .linkedLibrary("git2"),
            .linkedFramework("CoreFoundation"),
            .linkedFramework("Security"),
            .linkedLibrary("iconv"),
            .linkedLibrary("z"),
        ]
    )
} else {
    .systemLibrary(
        name: "CLibGit2",
        pkgConfig: "libgit2",
        providers: [.brew(["libgit2"])]
    )
}

let libgit2SwiftSettings: [SwiftSetting] = libgit2Mode == "brew"
    ? [.unsafeFlags(["-Xcc", "-I/opt/homebrew/opt/libgit2/include"])]
    : []
let libgit2LinkerSettings: [LinkerSetting] = libgit2Mode == "brew"
    ? [.unsafeFlags(["-L/opt/homebrew/opt/libgit2/lib"])]
    : []
```

`targets:` 数组中原 `.systemLibrary(name: "CLibGit2", …)` 条目替换为 `clibGit2Target,`。

要点：

- vendored 模式删除了 include 的 unsafeFlags（就是要根治的对象）；brew 分支的两个 settings 与现状**逐字节等值**。
- 原 vendored 的 linkerSettings（-L + CoreFoundation/Security/iconv/z）从 CodeInsightGit **移到** CLibGit2 C target 上——库的链接参数应由库的 target 自带，SwiftPM 会在链接可执行文件时聚合依赖闭包内全部 linkerSettings；另补显式 `.linkedLibrary("git2")`。
- CodeInsightGit 的 `swiftSettings: libgit2SwiftSettings, linkerSettings: libgit2LinkerSettings` 声明保留（vendored 时为空数组，brew 时与现状等值）。模块名仍为 `CLibGit2`，`import CLibGit2` 的源码零改动。
- manifest 双重前置检查：`lib/libgit2.a` 与 `Sources/CLibGit2/include/git2.h` 缺任一直接 fatalError 并给出修复动作（G3）。

### 3.4 scripts/vendor-libgit2.sh

在 staging 完成、写 VENDORED.md 之前（现行第 65 行 `cp "$STAGE/lib/libgit2.a" …` 之后）追加：

```bash
# Public headers for the CLibGit2 C target (vendored mode); refreshed on every
# vendoring run so the package graph carries the matching headers.
HEADER_STAGE="$REPO_ROOT/Sources/CLibGit2/include"
rm -rf "$HEADER_STAGE"
cp -R "$TARGET/include" "$HEADER_STAGE"
```

VENDORED.md 生成模板追加一行：`` - Header staging: `Sources/CLibGit2/include` (generated, gitignored) ``。
末行 echo 改为：`echo "vendored libgit2 ${LIBGIT2_TAG} -> $TARGET/lib/libgit2.a, headers -> $HEADER_STAGE"`。

### 3.5 scripts/make-app.sh

**(a) vendored 校验与头文件自愈**——接在现行 CAIRN_LIBGIT2 解析块（第 12–20 行）之后：

```bash
if [[ "${CAIRN_LIBGIT2:-}" == "vendored" ]]; then
    if [[ ! -f "$REPO_ROOT/Vendor/libgit2/lib/libgit2.a" ]]; then
        echo "make-app: CAIRN_LIBGIT2=vendored requires Vendor/libgit2; run scripts/vendor-libgit2.sh" >&2
        exit 1
    fi
    # Refresh the CLibGit2 C target's generated public headers (self-healing
    # after git clean -x or a vendored version bump).
    rm -rf "$REPO_ROOT/Sources/CLibGit2/include"
    cp -R "$REPO_ROOT/Vendor/libgit2/include" "$REPO_ROOT/Sources/CLibGit2/include"
fi
```

说明：现行自动选择块只覆盖"未显式设置"的情形；显式 `CAIRN_LIBGIT2=vendored` 且未 staging 时此前会以裸 cp 错误死掉，此块补上响亮失败（G3）。`rm -rf + cp -R` 保证与 Vendor 树版本严格一致，消除陈旧副本窗口。

**(b) Homebrew 动态库硬校验（G4）**——替换现行第 121–125 行的软提示分支：

```bash
if otool -L "$APP/Contents/MacOS/codeinsight-app" \
    | grep -q '^[[:space:]]*/opt/homebrew/'; then
    if [[ "${CAIRN_LIBGIT2:-}" == "vendored" ]]; then
        echo "make-app: vendored build must not reference Homebrew libraries:" >&2
        otool -L "$APP/Contents/MacOS/codeinsight-app" \
            | grep '^[[:space:]]*/opt/homebrew/' >&2
        exit 1
    fi
    echo "Bundling Homebrew dylibs (CAIRN_LIBGIT2=brew)."
    bundle_homebrew_dylibs "$APP/Contents/MacOS/codeinsight-app"
fi
```

### 3.6 .gitignore

在 "Generated by scripts/vendor-libgit2.sh" 小节追加：

```
# Generated by scripts/vendor-libgit2.sh (public headers for the CLibGit2 C target)
Sources/CLibGit2/include/
```

（`shim.c` 是 tracked 源文件，不忽略。）

### 3.7 文档

README「Build and Run」vendored 段落（现行 96–102 行）补一句：头文件由脚本自动 staging 到 `Sources/CLibGit2/include`（生成物，勿手改）。README.zh-CN.md 同步。

## 4. 验证与验收

### 4.1 Spike（实施前置，≈10 分钟）

目的：实证两个机制假设，实施时不再带不确定性。**做法：临时完成 §3.2/§3.3 改动 → 跑 A1/A2 → 全部还原（git status 回到干净）。**

- S-a swiftbuild 尊重 regular C target 内的手写 `module.modulemap`，且 `publicHeadersPath` 的搜索路径传导到依赖方的 CLibGit2 模块构建 → 表现为 A1 通过。若失败症状为 `cannot find 'codeinsight_repository_oid_type' in scope`，说明伞形自动生成被采用而 shim.h 未入模块 → 启用 §5 R1 回退形态。
- S-b vendored linkerSettings 移到 C target 后，可执行文件链接能取到 `-L`/`-lgit2` → 表现为 A2 通过且二进制静态链入 libgit2。

> **Spike 结果（2026-09-18 实测）：**
>
> 1. **S-a 触发了预期风险并验证了 R1 回退**：
>    - 尝试将 include 副本直接放在 `Sources/CLibGit2/include` 并保留原 `Sources/CLibGit2/module.modulemap` 时，swiftbuild 忽略该手写 modulemap，而是针对 include 目录自动生成伞形 `GeneratedModuleMaps/CLibGit2.modulemap`。
>    - 这一行为造成两个连带错误：
>      - `shim.h` 落在 include 目录之外，未入模块，准确触发 `cannot find 'codeinsight_*' in scope`；
>      - 自动生成的目录级伞形递归抓取了全部头文件，包括 `git2/sys/refdb_backend.h`，使得本来在 `git2/types.h` 中作为非完整类型的 `struct git_reference_iterator` 成为完整结构体，导致 Swift 语义从 `OpaquePointer` 漂移为 `UnsafeMutablePointer<git_reference_iterator>`；
>      - 若在 `include/` 内放置同名伞形头 `CLibGit2.h`，SwiftPM 会因同级存在 `git2/` 子目录而报错 `target 'CLibGit2' has invalid header layout`。
>    - **决议**：直接启用 §5 R1 回退形态，建立独立目录 `Sources/CLibGit2Vendored/`，并在 `Sources/CLibGit2Vendored/include/module.modulemap` 中指定 `header "shim.h"` 单入口。SwiftPM 完美尊重该 custom modulemap，且因只有 `shim.h`（仅含 `<git2.h>`）入模块，成功阻止内部系统头泄露，保持 `OpaquePointer` 纯净度。`CAIRN_LIBGIT2=vendored swift build -c release --product CodeInsightExact` **顺利构建通过**。
> 2. **S-b 完美证实**：
>    - `CAIRN_LIBGIT2=vendored swift build -c release --product codeinsight-app` 成功构建。
>    - `otool -L .build/release/codeinsight-app` 验证结果：`libgit2` 静态链入，无动态库引用，且输出中零 `/opt/homebrew` 依赖。

### 4.2 验收清单（实施完成后逐条实测，禁止推断）

| ID | 命令/操作 | 通过标准 | 实测结果 |
| --- | --- | --- | --- |
| A1 | `CAIRN_LIBGIT2=vendored swift build -c release --product CodeInsightExact` | 绿（本次故障的原失败用例） | ✅ 通过（8.51s，R1 独立目录形态） |
| A2 | `CAIRN_LIBGIT2=vendored swift build -c release --product codeinsight-app`；`otool -L .build/release/codeinsight-app` | 构建绿；输出无 `libgit2` 动态库条目（静态链入成功）、无 `/opt/homebrew` | ✅ 通过（70.08s，静态链入，零 homebrew） |
| A3 | `CAIRN_LIBGIT2=vendored swift test --filter` 覆盖 CodeInsightGitTests / CodeInsightExactTests / CodeInsightEngineTests | 全绿（vendored 测试通道首次建立） | ✅ 通过（19/19 Git + 100/100 Exact + 125/125 Engine 单元测试全绿） |
| A4 | `rm -rf Sources/CLibGit2Vendored && ./scripts/make-app.sh` | 全流程绿（头文件由脚本自愈重建），产出 .app 与 .zip | ✅ 通过（自愈重建，产出 Cairn.app 及 Cairn.zip，无 homebrew dylib） |
| A5 | `open` 启动 A4 产物，打开一个真实 git 项目走查 | 应用可启动、项目可打开（沿 M 系列验收做法） | ✅ 通过（Launch Services 启动 PID 8099 正常；`--self-test-exact .` 与 `--self-test-diff .` 真实 git 操作全通） |
| A6 | brew 回归：默认（无 env）`swift build`、`swift test`（或 `scripts/ci.sh`）；`CAIRN_LIBGIT2=brew bash scripts/make-app.sh` | 全绿；brew 打包仍走 Homebrew dylib bundling 路径 | ✅ 通过（默认 swift build 绿；CAIRN_LIBGIT2=brew 正常复制并重签 Homebrew dylibs 出包） |
| A7 | 全新 clone 到 /tmp：默认构建；再 `CAIRN_LIBGIT2=vendored swift build` | 默认构建绿（无 Vendor 树）；vendored 得到 manifest fatalError 且消息指向 vendor-libgit2.sh | ✅ 通过（/tmp 干净克隆：默认构建绿；vendored 触发 fatalError 明确提示执行 scripts/vendor-libgit2.sh） |
| A8 | `bash scripts/vendor-libgit2.sh` 全量重跑后再跑 A4 | staging 与 headers 刷新，构建绿 | ✅ 通过（重新下载 1.9.6、cmake 静态构建并刷新 Vendor 与 Sources/CLibGit2Vendored，后续 make-app.sh 顺利出包） |

## 5. 风险与回退

| ID | 风险 | 缓解/回退 |
| --- | --- | --- |
| R1 | swiftbuild 不采用 regular C target 内手写 module.modulemap（症状：`cannot find 'codeinsight_*' in scope`） | 回退形态：vendored target 改用独立目录 `Sources/CLibGit2Vendored/`（`include/` = git2 头 + shim.h 副本 + 新增伞形头 `CLibGit2.h`（内容 `#include "git2.h"` + `#include "shim.h"`），加一个 `shim.c`）。swiftbuild 会生成 `umbrella header "…/CLibGit2.h"`（与 CProcessGuard 同构，仓库已验证形态）。brew 的 `Sources/CLibGit2/` 完全不动。shim.h 双份的漂移由"每次 vendoring/打包都整目录重生成"消除 |
| R2 | （仅 R1 回退后相关）libgit2 头文件集合的模块清洁性 | libgit2 公共头自带 quoted 相对包含、自包含；伞形头形态只编译单一入口，风险进一步收窄 |
| R3 | `-L`/`-lgit2` 在链接行的顺序 | 同一 linkerSettings 数组内 `-L` 声明在前；A2 实证，失败即响亮（链接错误），无静默路径 |
| R4 | manifest 求值缓存在 CAIRN_LIBGIT2 切换时的正确性 | 旁证：诊断会话中 brew/vendored 分钟级交替构建均按各自模式正确求值（实验 B/D） |
| R5 | Xcode 27 beta 后续升级改变行为 | 每次工具链升级后重跑 A1–A6 |
| R6 | shim.c 在 brew systemLibrary 目录中闲置引起困惑 | §3.2 已注明；无害 |

## 6. 放弃的替代方案（记录理由）

| 方案 | 放弃理由 |
| --- | --- |
| vendored 生成 `.pc` 走 pkgConfig（实验 D 证明可用） | 引入 pkg-config 宿主依赖 + PKG_CONFIG_PATH 环境耦合；忘设时若本机装有 brew libgit2 会**静默**回落 1.9.7 头/库（版本不一致），需额外守卫；正确性仍依赖引擎对 pkgConfig flags 的注入行为，与本次事故同类耦合 |
| unsafeFlags 扇出到全部 ~10 个传递依赖 target | lint-trap：新增 target 忘配则只在发版路径炸（最晚发现类缺陷） |
| make-app.sh 传 `-Xcc -I` | 只修一个入口，其余 vendored 入口仍是雷 |
| shim.h `__has_include` + 相对路径回退 | 有 `-I` 与无 `-I` 的编译单元可能选用不同头文件集，静默混链，安全发布路径不可接受 |
| `--build-system native` | 官方已弃用，仅应急 |
