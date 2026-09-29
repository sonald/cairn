# 符号悬浮文档 Python / TypeScript：验收记录

日期：2026-09-29。计划：`2026-09-29-symbol-hover-python-ts-plan.md`。

测试项目（临时 git 仓库，不入库）：

- `/tmp/hoverpy`：`models.py` 含带装饰器、注解默认值、多行签名的函数与类；`use_os.py`
  引用标准库 `os.path`。
- `/tmp/hoverts`：`store.ts` 含 JSDoc（`@param` / `@deprecated` / `{@link}`）、接口；
  `node_modules` 内有 typescript 与 @types/node。

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
- **真实鼠标悬浮截图（受阻，未完成）**：本会话宿主进程没有屏幕录制权限
  （`screencapture` 报 "could not create image from display"），也没有辅助访问权限
  （osascript 报 -1719；cliclick 无法注入事件）。打包应用已能正常启动并打开
  `/tmp/hoverpy`。待补：给终端宿主授权后，用 `cliclick m:x,y` 停留在符号上 600ms 再
  `screencapture -x`，两语言各拍"项目内符号、依赖符号、降级态"三张，放入
  `evidence/hover-python-ts-acceptance/`。
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

- 真实鼠标悬浮的截图证据（见上，受阻原因与补拍方法已记录）。
- 滚动位置类测试在当前环境的不稳定需要单独排查（不在本计划范围）。
- JavaScript 仍未开放悬浮（P1 决策，无 Exact provider）。
