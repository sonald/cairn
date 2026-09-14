# Cairn 产品整改验收

**本轮整改完成。** 最终检查日期：2026-09-14。依据 [获批方案](2026-09-11-product-polish-audit.md)；用户于 9 月 14 日调整范围：“这个项目不要把辅助功能当成重点，可以不测。”因此辅助功能专项不作为本轮完成条件，已有基础键盘和 AX 支持保留。

源码基线：`695a2d9f21f2a46871b5b44c27907605b82cd907`。保留 AppKit、TextKit、Tree-sitter 和现有阅读/快照模型，无新依赖。提交范围为源码、测试、文档和验收证据；未发布。

## 交付

- [Cairn.app](/Users/siancao/work/ai/vibecoding/codeinsight/.build/polish-20260914/Cairn.app)
- [Cairn.zip](/Users/siancao/work/ai/vibecoding/codeinsight/.build/polish-20260914/Cairn.zip)
- 构建号：`20260914.1`；独立验收标识：`dev.cairn.Cairn.PolishFinal.20260911`。
- vendored static libgit2；ad-hoc 签名及 strict 验证通过，未公证。
- [源码补丁、二进制及压缩包 SHA-256](evidence/2026-09-11-product-polish/final/20260914/build-identity.json)。

## 逐项结果

| 批准范围 | 结果与证据 |
|---|---|
| Cmd+P 定位、宽度、留白、三态 | **PASS**。所属窗口定位、560–760pt 自适应宽度、稳定输入头、对称留白；零/单/多候选独立布局。13 项专项覆盖窗口移动和负坐标副屏几何；实机查询、Return/Escape、相对路径及窄宽窗口检查通过。 |
| Reader gutter 与排版 | **PASS**。消除重复占位；12 组字体/行号/滚动条组合实测首 glyph 间距均为 10pt。默认等宽 13pt、行高 1.3，声明强调更克制。真实明暗主题、24pt、折行和恢复默认已检查。 |
| Reader 局部重绘 | **PASS**。修复字号恢复并切文件后行号消失：脏区域判断改为 gutter 整行区域，统一覆盖行号和各类标记。正常窗口像素回归 RED→GREEN，4 项通过；新包实机复验通过。 |
| 高亮与 Outline 信息 | **PASS**。补调用、字段、宏/attribute、参数/局部绑定、枚举成员；未知引用仍保持中性。Outline 有真实父子关系、字段和签名摘要。Rust/Python/TypeScript 回归及 TS 模板插值回归通过。 |
| Files/Outline 密度与恢复 | **PASS**。紧凑行高、图标和缩进；两分区可分别或同时收至标题行，展开恢复比例；树展开、选中、切文件和真实控制器重建通过。 |
| Tabs、长路径和缩窗 | **PASS**。预览替换、Keep Open、文件双击保留、同名后缀和键盘切换。去掉遮挡短标签行的滚动条，缩窗时显露活动标签；同尺寸滚动不跳回。长路径允许原生压缩。7 个保留标签×明暗主题×两种滚动条样式×900/1280/1600pt 的原生矩阵通过；实机活动标签及关闭按钮完整可见。 |
| 分栏、Inspector 和尺寸保存 | **PASS**。外侧两向鼠标拖动、宽屏 Inspector 并排及内部分隔线拖动通过。恢复右/底面板时扣除 divider 厚度，消除累计缩窄；原有 2pt 断言不放宽。控制器重建、toggle、源文件/Reading Set/Markdown 往返及实际应用重启通过。 |
| 主窗口空态与阅读位置 | **PASS**。空 Context/Trail 收起；修复延迟 sizing 重新展开空 Context。面包屑和 scope 可导航；Reading Set 不再叠加普通 Reader 的占位文字。现有原生回归均完成 RED→GREEN。 |
| 设置 | **PASS**。常用项首屏、高级项折叠、真实 Reader 预览、恢复默认；首次布局、颜色、字形和设置往返检查通过。 |
| 查找、搜索、书签 | **PASS**。实机文件查找 1/9、项目搜索 30 处/4 文件。Find→Return→Escape 后可直接创建书签，无需鼠标点正文；当前位置优先于旧导航位置，Unicode、两标签恢复及不增加导航历史的 5 项回归通过。新包纯键盘创建 upgrade 书签，重启后同一记录恢复。 |
| Compare 进入与退出 | **PASS**。选择真实提交、显示差异并跳转；新增右区关闭按钮及 View→Close Comparison（⌃⌘W），共用已有清除动作并恢复阅读布局。Reading preset 仅隐藏的语义保留；明确关闭才清除对比状态与双侧标记。17 项 diff 检查及新包亲点关闭通过。 |
| Relations/Reading Set | **PASS**。真实 rust-analyzer 返回 spawn_actor 的 5 条 Verified 调用关系；Inspector 证据可读，冻结后的 5 个片段可见，返回源文件恢复布局。 |
| 最终包与重启 | **PASS**。实际启动交付路径中的新包；正常退出、重新启动后当前 actor.rs、标签、主题和 2 个书签恢复。App 保留打开供继续使用。 |

## 完整检查

[完整日志](evidence/2026-09-11-product-polish/final/20260914/product-gates.log)，命令最终 **exit 0**：

- **909 项测试**全部通过：905 主测试（268.882s）+2 书签隔离测试（0.458s）+2 面板测试（3.875s）。每批都有完整非零 Swift Testing 成功 summary。
- **17/17 产品通道**：`pass=17 fail=0 hang=0`。
- 书签产品检查、三主题及独立重启检查通过。
- 真实 rust-analyzer、Pyright、TypeScript 与离线覆盖通过；无新增遗留 provider 进程。
- Tokio、ripgrep、mcp-python-sdk、morphic 的 **全部 gold gates 通过**。
- 折叠性能与现有架构约束检查通过；`git diff --check` 通过。

复跑命令：

```bash
CODEX_SANDBOX=1 CAIRN_LIBGIT2=vendored \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache" \
  bash scripts/run-product-gates.sh \
    "$PWD/.build/polish-corpora/python-sdk" \
    "$PWD/.build/polish-corpora/morphic" \
    "$PWD/.build/polish-corpora/llm-tools"
```

固定语料：Python `f55831ee798cd4d7bafab4d50d6dba46e6fce387`（204 源文件）；TypeScript `f31fe4a9ce2d355c3a44203fcb6add9296cc9b61`；mixed `457b66e72da1967c2432131a7ff8adc4341eb337`；Tokio `be8ee45b3fc2d107174e586141b1cb12c93e2ddf`；ripgrep `4649aa9700619f94cf9c66876e9549d83420e16c`。未修改这些用户源仓库。

## 最终实机记录

截图和日志位于 [20260914](evidence/2026-09-11-product-polish/final/20260914/)：

- [最终阅读页](evidence/2026-09-11-product-polish/final/20260914/reader-final.png)
- [暗色窄窗](evidence/2026-09-11-product-polish/final/20260914/05-dark-900.png)、[浅色阅读页](evidence/2026-09-11-product-polish/final/20260914/light-reader-active.png)、[宽窗](evidence/2026-09-11-product-polish/final/20260914/light-wide.png)
- [单候选 Palette](evidence/2026-09-11-product-polish/final/20260914/04-palette-single.png)、[宽窗 Palette](evidence/2026-09-11-product-polish/final/20260914/palette-wide.png)
- [设置预览](evidence/2026-09-11-product-polish/final/20260914/settings-light.png)
- [纯键盘书签](evidence/2026-09-11-product-polish/final/20260914/01-keyboard-bookmark.png)、[重启记录](evidence/2026-09-11-product-polish/final/20260914/restart-bookmarks.ax.txt)
- [对比](evidence/2026-09-11-product-polish/final/20260914/02-comparison.png)、[关闭对比](evidence/2026-09-11-product-polish/final/20260914/03-comparison-closed.png)

`after/`、`final/` 根目录和 `release-3/` 保留早期候选证据，其中含后来修复的缺陷，不能用作最终效果图。

## 范围与历史诊断

按用户最新调整，**辅助功能专项不测**。曾短暂开启 VoiceOver，但工具未获准读取该应用，未将其记为通过；旁白已确认恢复为原来的关闭状态。静态语法配色最小对比度 light 4.96、dark 6.61、SI 5.21，不据此宣称整体无障碍合规。

早期 RA 超时/ENOSPC、旧尺寸/文件树/空态断言均保留在历史日志中；最终整套检查已经通过，没有放宽超时或以 exit 0/零测试输出替代成功 summary。大型引用自测里旧基线已有的 NSTableView 重入诊断未被当成新回归，也未为消除该日志改动导航回调。
