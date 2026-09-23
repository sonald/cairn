# Reader 编程连字验收记录

执行日期：2026-09-22—23。**功能实现完成；整体验收未完成，不能关闭发布门槛。**

需求：[需求说明](2026-09-22-reader-ligatures-requirements.md) · [设计](2026-09-22-reader-ligatures-design.md) · [实施计划](2026-09-22-reader-ligatures-implementation-plan.md)

## 实现与回归

最终功能提交：`3bef9afcdf1081c408c1e7e2ca0049972d930710`，分支 `codex/reader-ligatures`。基线 `5a9800b`。没有推送或合并；用户原有 `.zcodeignore` 未修改、未纳入提交。

- Settings → Reader 增加代码字体、连字三态、实际字体/缺失字体提示、字体刷新与真实 Reader 预览，中英界面均已补齐。
- 主 Reader、对比、Context、新窗口、预览和 Reading Set 共用字体策略。普通文本预览保持原字体。
- 纯字体变化只合并排版属性，源文本与 DisplayMap 不替换；折叠附件身份保留，占位字符与首次投影使用一致的基础字体属性。
- 字重派生保留同族、斜体、宽度及非 weight 变体轴。humanist 注释清除代码连字覆盖。
- 选区和 affinity 保持；未改变的选区不重复赋值，保留原生反向 Shift 扩选起点。
- 普通文件独立测量的锚点误差 ≤ 2 pt。超过 8,000 行或锚点源行超过 64 KiB 时保留选区与历史水平位置，跳过同步精确恢复；不承诺这些场景的像素锚点精度。
- 字体缓存上限 128，显式刷新、字体注册通知、应用激活与设置窗口打开均有环境刷新路径；Reading Set 只在有效布局后提交测量键。

**完整 CI 通过：1,031 个测试（主批 1,027 + 隔离 2 + 面板 2）。** Exact、Diff、Reading、Projector、Fold 自测及架构静态检查全部完成，Release 折叠门槛通过，延迟约 252 ms。见 [CI 日志](evidence/reader-ligatures/final-ci.log)、[全部主测试](evidence/reader-ligatures/final-tests.log)、[隔离测试](evidence/reader-ligatures/final-isolated-tests.log)、[面板测试](evidence/reader-ligatures/final-panel-tests.log)、[折叠性能](evidence/reader-ligatures/final-fold-performance.json)。

基线沙盒曾因屏幕/弹窗权限产生 4 个 issue，同一产物在桌面权限下全部复核通过。另修复了 Git 测试硬编码工作仓库分支为 main 的问题，改为与实际 Git refs 比较；详见[环境](evidence/reader-ligatures/environment.md)。

## 桌面续验与修复

解锁后的真实操作覆盖Settings三态、键盘菜单、Reading Set拖选及重排、Context、对比、新窗口和纯文本预览。发现并修复字体菜单重名与主Reader鼠标拖选被点击处理清空两项问题，提交 `9eca0f9`。**修复后完整CI再次通过，共1,032项（main1,027 + bookmark2 + panel2 + mouse1），应用自测及fold门槛通过。** 见[续验记录](evidence/reader-ligatures/desktop-20260923.md)与[新CI日志](evidence/reader-ligatures/desktop-fixes-ci.log)。最终App已重新解锁并完成可见复验：正反向拖选、复制、切换字体/连字后的选区、同符号双击可见背景，以及字体菜单唯一身份均通过，详见续验记录末节。

## 产品门禁补充

完整产品门禁首次执行 18 个通道：15 通过、3 失败、0 挂起，因失败停止后续阶段，**整套产品门禁未通过**。见[原始日志](evidence/reader-ligatures/product-gates-first.log)。随后只复测失败通道，没有将单独复测冒充完整门禁重跑：

- Search：原断言硬编码 `2001`，实际本地化状态显示 `2,001`。改为使用相同的本地化数字格式；[复测](evidence/reader-ligatures/search-fixed.stdout)的真实总数、2000条上限及截断行可见性均通过，退出0。
- History：旧自测在50ms后立即要求 cursor变化，但现有导航在异步replay成功后才提交cursor。将该断言纳入原30秒等待；[复测](evidence/reader-ligatures/history-fixed.stdout)导航序列与选择同步通过，退出0。
- Tabs：内存预算仍为100MiB，当前Debug为171.20MiB、Release为177.24MiB；功能检查均通过。修改前的WrapValidation产物也为173.77MiB，见[旧产物结果](evidence/reader-ligatures/tabs-preligature.stdout)。旧二进制SHA-256为 `3b3577d166fcc8bfdd2cada3ae53a85009ed0557af25c76409b733752c1c720e`，没有ReaderFontResolver符号，但确切提交未知，不能冒充精确基线对照。当前[内存分类](evidence/reader-ligatures/tabs-vmmap.txt)以图形backing为主；未放宽预算或修改产品来掩盖该失败。

门禁脚本的汇总预期从过时的17通道纠正为现有18通道。门禁修复提交：`2e8e1c5`。以上补丁只影响自测和门禁脚本；1031项完整CI证据对应前述功能提交，补丁构建与两个相关原生通道另行验证。

## 字体与数据

本机验证字体：FiraCodeRoman-Regular 6.002、JetBrainsMono-Regular 2.305，以及系统回退。产品不分发字体二进制。版本、文件路径、SHA-256、上游来源与 glyph 数据见[字体记录](evidence/reader-ligatures/fonts.md) / [原始探针](evidence/reader-ligatures/font-probe.json)。源码 fixtures 与 SHA-256 见[manifest](../../fixtures/ligatures/manifest.json)。

已验证 On/Off/Default 的实际成形差异；相同 glyph 数量不当作没有连字。`.ligature=0` 单独控制不能关闭两套字体的编程连字。On 请求 calt/liga/clig；Off 关闭 calt/liga/clig/dlig/hlig；Default 从基准字体重新解析。Core Text 会规范化或省略不支持/默认启用的请求，记录中区分 requested 与 effective features。

[On 原生离屏截图](evidence/reader-ligatures/native/FiraCodeRoman-Regular-operators-enabled.png) / [Off 原生离屏截图](evidence/reader-ligatures/native/FiraCodeRoman-Regular-operators-disabled.png)。截图证明真实 AppKit 绘制，**不代替鼠标操作或可见窗口验收**。

## 正式性能

每项 5 次预热 + 30 次有效样本，串行执行，无并行构建。N03/N04 使用固定 2× 原生 cacheDisplay；N05 沿用既有 wrap 自测口径，不能把两种采集直接混为同一帧率指标。滚动是同步绘制耗时，不是显示器 vsync 间隔。提交、二进制哈希及各结果哈希见[运行清单](evidence/reader-ligatures/native/run-manifest.json)。

| 字体，2,000 行 | 正确首帧 p95 | 稳定 p95 | Off 滚动 p95 | On 滚动 p95 | 结果 |
| --- | ---: | ---: | ---: | ---: | --- |
| [Fira Code](evidence/reader-ligatures/native/FiraCodeRoman-Regular-2000.json) | 117.19 ms | 153.00 ms | 48.34 ms | 50.61 ms | N03/N04 通过 |
| [JetBrains Mono](evidence/reader-ligatures/native/JetBrainsMono-Regular-2000.json) | 121.63 ms | 155.72 ms | 49.42 ms | 48.73 ms | N03/N04 通过 |

以下使用 Fira Code、连字开启：

| 场景 | 稳定 p95 | 原预算 | 结果 |
| --- | ---: | ---: | --- |
| [Reading Set，wrap on](evidence/reader-ligatures/native/readingset-fira-on.json) | 176.77 ms | 250 ms | 通过 |
| [Reading Set，wrap off](evidence/reader-ligatures/native/readingset-fira-off.json) | 133.11 ms | 250 ms | 通过 |
| [约 1 MB 长行，wrap on](evidence/reader-ligatures/native/f2-mega-line-fira-on.json) | 54.79 ms | 1500 ms | 通过 |
| [约 1 MB 长行，wrap off](evidence/reader-ligatures/native/f2-mega-line-fira-off.json) | 277.31 ms | 1500 ms | 通过 |
| [1.8 MB 无空格行，wrap on](evidence/reader-ligatures/native/f3-no-whitespace-fira-on.json) | 1281.38 ms | 1500 ms | 通过 |
| [1.8 MB 无空格行，wrap off](evidence/reader-ligatures/native/f3-no-whitespace-fira-off.json) | 345.43 ms | 1500 ms | 通过 |

F3 wrap-off 原先约 1,738 ms。原生调用栈定位到 caret 几何扫描整条巨行；增加 64 KiB 源行保护后降至约 345 ms。选区及原文仍正确，精确视口恢复明确降级。[调用栈](evidence/reader-ligatures/mega-line-caret-profile.txt)和[边界回归](evidence/reader-ligatures/limit-boundaries-tests.log)包含依据。

### F1 未通过，不调整预算掩盖失败

| 30,000 行场景 | 连字 On p95 | 同字体 Off p95 | 结论 |
| --- | ---: | ---: | --- |
| wrap on | 3,980.39 ms | 3,991.18 ms | 均远超 250 ms；On 未增加这部分成本 |
| wrap off | 3,746.87 ms | 1,904.58 ms | 超出 250 ms，且 On 超出 1.5× Off 的相对门槛 |

F1 峰值约 7 GiB，是该自测进程的指标，不能推导普通文件或日常窗口的内存。原始结果在运行清单中。F1 测于 78e0826；后续仅修复纯字体变化的折叠占位属性和 Reading Set，F1 的 wrap-only 路径未变。此项本来就是失败，不作为最终通过证据。

已验证两条公开 TextKit 替代思路：relocateViewport + usageBounds 会出现中间空视口且仍全篇/重复成形；layoutQueue 在默认 NSTextView 路径未转移同步工作。未把这些不安全或无改善的试验放进产品：[视口探针](evidence/reader-ligatures/viewport-api-probe-mid.json)、[队列探针](evidence/reader-ligatures/layout-queue-probe.json)。JetBrains 的少量诊断样本更慢，不冒充正式预算。

## A01—A15 结论

| ID | 结果 | 证据与边界 |
| --- | --- | --- |
| A01 | 通过 | 4 个隔离配置测试：旧 key、非法值、三态 round trip、恢复默认清旧名、保留缺失字体请求 |
| A02 | 通过 | 两字体三态原生成形及原生绘制；可见Settings三态与实际字体提示通过 |
| A03 | 自动化通过 | 同族/斜体/变体轴、函数强调、humanist 清理及 syntaxFormatting 组合；实际窗口截图待验 |
| A04 | 通过 | 字节/显示字符串/投影不变，跨折叠源复制、附件身份保留；折叠旧属性已先失败复现再修复 |
| A05 | 通过 | 原生键盘、查找、生产copy和Unicode几何；最终CUA拖选!==、缩选与复制!=通过 |
| A06 | 自动化通过 | wrap×字号×三态、首视觉行与 Unicode；实际窗口组合截图待验 |
| A07 | 通过 | 独立锚点≤2pt；六个正反方向自动化组合通过；最终CUA反向拖选!==、切换On后Shift+Right得到== |
| A08 | 自动化通过 | 人工滚动通知/换文档取消旧恢复，10 窗口×10切换后弱引用全部在2秒内释放 |
| A09 | 降级符合已记录策略 | 8,001 行及 >64 KiB 锚点行保留选区/原文/水平位置；不承诺精确同步定位 |
| A10 | 通过 | 同字号换字体、三态、字体环境、测量幂等、卡片选区与外层锚点；F5性能通过 |
| A11 | 自动化通过 | 主/对比/Context/新窗口、普通文本不变；真实 AppDelegate 通知自动更新主面与预览；可见主Reader、Context、对比、新窗口与纯文本流程已验 |
| A12 | 通过 | 中文、emoji、组合字符、ZWJ、Tab、CRLF；几何扩展不回写源范围 |
| A13 | 自动化通过 | 缺失字体、最近字重、字体环境刷新；设置原生菜单已复验；真实字体安装/移除组合未宣称通过 |
| A14 | 通过 | 相同 apply 的投影/属性/段落增量0；纯字体投影增量0；缓存≤128，压力后释放通过 |
| A15 | 未通过 | 完整CI通过，常规/长行/Reading Set预算通过；F1预算及产品门禁未通过；本轮鼠标与菜单桌面修复已复验 |

## 尚需处理

1. **Tabs 内存门禁。** 旧产物同样超出100MiB，但没有精确基线提交对照；需独立解决图形内存问题后重跑完整产品门禁。
2. **F1 性能范围决策。** 已提交保留原门槛继续专项优化或接受明确已知限制的选择，尚未收到答复；默认保留未通过状态。没有未经同意放宽门槛，也未将 goal 标记完成。

待用的独立 GUI fixture 路径记录于 `/tmp/cairn-ligatures-native-root.txt`，包含 Rust 调用关系、两次 Git 提交、普通文本和 Markdown。验收 bundle 为 `.build/ligature-acceptance/Cairn.app`，独立 bundle id `dev.cairn.LigatureAcceptance`；已从9eca0f9代码重新打包并完成鼠标与菜单复验。

## 重跑

```bash
bash scripts/ci.sh
swift scripts/ligature-font-probe.swift > /tmp/ligature-font-probe.json
.build/release/codeinsight-app --self-test-ligatures \
  --font-postscript FiraCodeRoman-Regular --mode enabled \
  --fixture fixtures/ligatures/regular-2000.rs --json-out /tmp/ligature-reader.json
.build/release/codeinsight-app --self-test-wrap \
  --fixture fixtures/wrap/f5-reading-set.txt --wrap on --scenario reading-set \
  --font-postscript FiraCodeRoman-Regular --ligature-mode enabled \
  --output /tmp/ligature-reading-set.json --warmup 5 --samples 30
```

AppKit 与用户字体测试需要桌面会话权限；缺少必需字体返回 blocked，不当作通过。最低部署系统只完成 API 编译核对；本轮运行环境为 macOS 27 / Xcode 27 / Swift 6.4，不能外推到所有旧系统。
