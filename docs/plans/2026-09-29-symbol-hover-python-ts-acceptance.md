# 符号悬浮文档 Python / TypeScript：验收记录

日期：2026-09-29（真实鼠标截图补于 2026-09-30）。计划：`2026-09-29-symbol-hover-python-ts-plan.md`。
截图：`evidence/hover-python-ts-acceptance/`。

测试项目（临时 git 仓库，不入库）：

- `/tmp/hoverpy`：`models.py` 含带装饰器、注解默认值、多行签名的函数与类；`use_os.py`
  引用标准库 `os.path`。
- `/tmp/hoverts`：`store.ts` 含 JSDoc（`@param` / `@deprecated` / `{@link}`）、接口；
  `node_modules` 内有 typescript 与 @types/node。2026-09-30 补拍时新增 `use_fs.ts`
  （`import { readFileSync } from "fs"`），用作依赖符号。

## 单元测试

新增 14 条，全部通过：

| 模块 | 条数 | 覆盖内容 |
|---|---|---|
| ReaderCore `SymbolDocTests` | 6 | Python 装饰器跳过、多行签名去缩进、docstring 引号/转义/PEP 257 去缩进、非首语句不算文档；TS JSDoc、装饰器夹层、箭头/别名尾部裁剪、聚合体内联、`{@link}` 转换与围栏跳过 |
| Exact `CodeInsightExactTests` | 4 | pyright / typescript-language-server 的 hover 协商、MarkupContent 解析、无 provider 返回 nil、空 hover 上报 completed(nil) |
| AppModel `SymbolHoverModelTests` | 1 | pyright（`(function)` 前缀 + `---`）与 tsserver（无分隔）两种真实形态的拆分、括号开头的签名不误剥前缀 |
| ReaderUI `SymbolDocCardTests` | 3 | 真实 AppKit 层级里渲染 Python/TS 卡片：签名条、docstring/JSDoc 正文、`{@link}` 链接（cairn-symbol）、降级态底栏说明行 |

原有"非 Rust 回退首行"测试改为 JavaScript 专用（P1：JS 不开放悬浮）。

## 真实语言服务器采样（CLI `exact-hover --language`）

本机 pyright / typescript-language-server 的原始返回（W3 拆分规则的依据）：

- pyright 函数：` ```python ` fence 内 `(function) def format_name(\n    user: str,\n    greeting: str = "Hello"\n) -> str`，`---` 之后是 docstring 的 Markdown 渲染。
- pyright 类：`class Repository()`（无前缀）；方法：`(method) def open(\n    self: Self@Repository,\n    oid: str\n) -> bytes`。
- pyright 标准库符号（`os.path`）：`(variable) path: Module("..path")` + os.path 模块
  docstring——前缀剥离后卡片显示 `path: Module("..path")`。
- tsserver 函数：` ```typescript ` fence 内签名（无前缀、无 `---`），正文里 JSDoc 标签已
  渲染为 `*@param*` `id` — …；接口：`interface Store` + 一行正文；无文档的成员 hover 返回
  null（CLI 打印 "hover empty"），卡片回退语法层并按 Q13 显示 limitation 说明。
- 两者都在 attribution 里带 `dependenciesUnavailableOffline`（与 definition 行为一致）。

## 原生验收

- **卡片原生渲染（通过）**：`SymbolDocCardTests` 在真实 `NSWindow` + `NSPanel` 层级里
  显示/隐藏卡片并断言渲染内容（同 ruler-bleed 回归的做法，不需要屏幕录制权限）。
  覆盖：Python 精确层形态、TS 精确层形态（含 `{@link}` 两个 cairn-symbol 链接）、
  Python 语法层降级 + 底栏"精确分析未就绪"。
- **真实鼠标悬浮截图（2026-09-30 补拍，通过）**：打包应用（`.build/distribution/Cairn.app`，
  构建时间晚于最后一个代码提交 `66ba762`），Safe 模式，真实鼠标移到符号上停留后截图。

  | # | 语言 | 状态 | 结果 | 截图 |
  |---|---|---|---|---|
  | 1 | Python | 项目内符号 `format_name`，精确层 | 通过。`(function)` 前缀已剥离，多行签名条，docstring 渲染为 Markdown（行内代码、`[link]`、Args/Returns 分行），头部 `models.py:4`。第 4 行上方放不下，卡片翻到下方 | 01 |
  | 2 | Python | 标准库符号 `os.path.join` | 通过。签名与正文来自 typeshed / 标准库 docstring；外部符号无位置头部 | 02 |
  | 3 | Python | 降级态（精确层准备中） | 通过。语法级签名 + docstring，底栏"语法级结果 · 精确分析未就绪"，状态栏"精确分析：准备中"。**发现问题 A**，见下 | 03 |
  | 4 | TypeScript | 项目内符号 `loadStore`，精确层 | 通过。签名条无前缀，`*@param* id — …`、`*@deprecated* — …` 分行渲染，头部 `store.ts:6`。卡片翻到符号上方 | 04 |
  | 5 | TypeScript | 依赖符号 `readFileSync`（@types/node） | 通过。正文来自 `node_modules/@types/node`，含代码块，超过 400pt 时卡片内滚动。**发现问题 B**，见下 | 05 |
  | 6 | TypeScript | 降级态（精确层准备中） | 通过。语法级签名 + JSDoc，底栏"语法级结果 · 精确分析未就绪"。精确层就绪后移开再悬浮，卡片换成精确层结果（等待中的结果没有被缓存）。**发现问题 A**，见下 | 06 |
  | 7 | TypeScript | 接口成员 `Store.id` | 通过。精确层返回 `(property) Store.id: number` + "Primary key."。**发现问题 C**，见下 | 07 |

  降级态的拍法：pyright / tsserver 在这两个小项目上 1–2 秒内就绪，手动来不及悬浮。补拍时从终端
  直接启动应用二进制，并在 `PATH` 前面放一个 scratchpad 里的包装脚本，把语言服务器的启动延迟
  20 秒（Python 包装 `pyright-langserver`；TypeScript 包装 `node`，只在参数含 `--stdio` 时延迟）。
  没有改动 Homebrew 或项目文件。应用本身的行为与正常冷启动一致。

  截图环境备注：本机多显示器下，computer-use 工具的点击命中检查会把窗口内坐标误判到程序坞，
  所以打开文件一律走 ⌘P 快速打开；窗口位置用 System Events 调整。首次在阅读区悬浮前需要让
  Cairn 成为活跃应用（鼠标跟踪是 `.activeInActiveApp`，与 Rust 验收修复 3 一致）。

  **补拍中发现的问题（未修复，记录待定）：**

  - **A. 语法级正文不做 Markdown 转换，换行被吞。** `SymbolDoc.swift` 把 PEP 257 去缩进后的
    docstring、去掉 `*` 前缀的 JSDoc 原样当 Markdown 用，单个换行在 Markdown 里是软换行：
    Python 的 `Args:` / `Returns:` 小节被拼成一段（"Args: user: the user name. greeting: …"），
    TS 的 `@param` / `@deprecated` 标签也挤成一行。精确层没有这个问题（pyright、tsserver 各自
    做了转换），所以同一个符号在降级态和精确态之间排版差别明显。影响只在冷启动或精确不可用时。
  - **B. 签名条在标识符中间断行。** tsserver 的签名是一整行（带重载的依赖函数很长），签名条按
    字符折行，出现 `ReadFileS|yncOptions…`、`overloa|ds`。pyright 和 rust-analyzer 返回的
    签名本身已分行，不受影响。
  - **C. TypeScript 保留 `(property)` / `(alias)` 这类前缀，Python 的 `(function)` / `(method)`
    会剥掉。** 与 VS Code 显示一致，可以接受；记录下来是因为两种语言的卡片风格不统一，是否统一
    待定。

- **打包应用冒烟（通过）**：`CAIRN_LIBGIT2=brew bash scripts/make-app.sh` 打包并启动
  成功（pid 可见、窗口进程在 System Events 进程列表中）。

## CI

`CODEX_SANDBOX=1 bash scripts/ci.sh` 于 2026-09-29 晚间在本机执行：

- 主批次 1241 条（当时计数）中 1238 通过；计数与新期望一致后追加卡片 3 条，
  期望总数 1244。
- **3 条既有失败，均在改动前的基线 `87b420c` 上复现**（同机同日单独重跑验证）：
  `readonlyResizeUserScrollResizeUsesTheUsersNewPosition`、
  `wrapToggleClampsLegallyAtDocumentEdges`（ReaderReflowLifecycleTests）、
  `ligaturePendingRestoreYieldsToUserScroll`（ReaderLigatureIntegrationTests）。
  三条都是 `abs(bounds.minY - expectedY) <= 1` 类滚动位置断言，当天早晨的上一轮验收
  CI 还是全绿，疑似环境因素（macOS 27 beta / 长时间运行的窗口服务），与本计划改动
  无关（改动未触碰布局与滚动代码）。
- 其余步骤全部通过：本地化、架构检查（4 项扫描）、隔离/面板/鼠标/字体批次、
  app 自检（exact/diff/reading/projector/fold 通道 exit=0）、release 构建、折叠性能
  门槛（budgetStatus: pass）。

## 遗留

- 补拍中发现的 A / B / C 三个展示问题（见"原生验收"），未修复。
- tsserver 对无文档成员返回空 hover、卡片回退语法层并显示限制说明的路径，只有 CLI 采样和单元测试，
  没有原生截图（测试项目里的成员都带文档注释）。
- 滚动位置类测试在当前环境的不稳定需要单独排查（不在本计划范围）。2026-09-30 用
  `swift test --filter` 单独重跑这 3 条，全部通过（1.1s / 2.9s / 3.1s），支持"环境因素"的判断，
  但只跑了一次，还不能算排查完。
- JavaScript 仍未开放悬浮（P1 决策，无 Exact provider）。
