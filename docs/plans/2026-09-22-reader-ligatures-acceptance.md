# Reader 编程连字验收记录

执行日期：2026-09-22—23。**已实施，验收通过。** 最终源码`0296f21`完整产品门禁退出0：1033项测试、18通道原生自测及全部gold gates通过。

需求：[需求说明](2026-09-22-reader-ligatures-requirements.md) · [设计](2026-09-22-reader-ligatures-design.md) · [实施计划](2026-09-22-reader-ligatures-implementation-plan.md)

## 验收口径

2026-09-23用户明确：33ms等没有实际数据或理论依据的性能数字只作为 **best-effort目标，不作为硬性验收门槛**；本需求引用的类似指标同样处理。保留原始测量与差异，不再为追数字扩展实现。功能正确性、源码与复制保真、选区、资源有界性及完整测试执行仍严格验收。原始JSON中的N03/N04等预算布尔值仅代表采样时旧参考值比较。专用连字自测也已将性能比较与退出码解耦，新增`performanceTargetsAreBlocking: false`；正确性检查仍决定成功或失败。

## 实现与最终修复

最终产品源码：`0296f21`（含`b3b2a9e`性能口径调整），分支 `codex/reader-ligatures`；精确实现前基线 `5a9800be5ac8523bb16ca0ae03da7dd9bb3d4092`。没有推送或合并，用户原有`.zcodeignore`未修改、未纳入提交。

- Settings提供代码字体、连字On/Off/Default、字体刷新、实际字体与缺失回退提示、原生预览。重名菜单项用PostScript名称区分。
- 主Reader、对比、Context、新窗口、Settings预览和Reading Set共用字体策略；普通文本预览保留自身字体。生产复制路径已覆盖各代码面，见[补充测试](evidence/reader-ligatures/surface-copy-tests.log)。
- 纯字体变化不替换源码/投影，保留折叠附件、完整选区及affinity；保持原生Shift扩选起点，修复鼠标拖选被点击激活清空。
- 字重派生保留字体族、斜体/宽度与非weight变体轴；humanist注释清除代码连字覆盖。缓存有128条上限，字体环境刷新与窗口释放已覆盖。
- 超过8,000行或锚点源行超过64KiB保留选区/历史水平位置，跳过同步精确垂直恢复。大文件采用有界原生视口重排；未承诺巨行精确像素锚点。
- 修复原生textContainerOrigin触发全篇布局及可见属性枚举扫描尾部的问题；随后在真实UI发现EOF语法颜色丢失，加入原生布局完成后的合并校正，回归先失败后通过。
- 宽度变化只有缩进上限变化时才重算段落；修复性能探针旧队列回调污染新测量窗口的问题。120ms窗口内阻塞仍被测得121.75ms，没有屏蔽真实阻塞。

## 原生界面与回归

[桌面续验记录](evidence/reader-ligatures/desktop-20260923.md)包含真实Settings三态和键盘菜单、正反向拖选、复制、Reading Set重排、Context、对比、新窗口、普通文本预览。

`1f907ec`重新打包并启动后，真实窗口F1末尾29972—30000行在wrap On与Off均正确显示语法颜色，关闭换行后Cmd+Down可达30000行。普通main.rs鼠标拖选`!==`、Shift+Left缩选、复制到查找框得到原始`!=`。`0296f21`最后锚点修复后再次打包启动，复查EOF30000行和Context着色通过。原生离屏测试与真实窗口操作分开记录，不相互冒充。

最终完整产品门禁首轮发现普通文件连续字体/wrap切换后锚点偏移8.69pt；独立复现后，修复共享布局路径将程序滚动误当用户滚动、清空恢复状态的问题，原断言通过。红绿日志见[失败](evidence/reader-ligatures/viewport-followup/anchor-red.log) / [修复](evidence/reader-ligatures/viewport-followup/anchor-green.log)。整套门禁已重跑通过；前一完整轮次1032项CI、18通道自测、混合语言、书签原生/重启/三主题与gold gates全部通过，见[历史完整门禁](evidence/reader-ligatures/product-gates-unlocked.log)。最终源码完整测试已实际通过1033项（主批1028 + 书签隔离2 + 面板隔离2 + 原生鼠标1），见[主批](evidence/reader-ligatures/final-0296f21-tests.log)、[书签](evidence/reader-ligatures/final-0296f21-isolated.log)、[面板](evidence/reader-ligatures/final-0296f21-panels.log)、[鼠标](evidence/reader-ligatures/final-0296f21-mouse.log)。18通道应用自测已全部通过（pass=18 fail=0 hang=0），混合语言、书签原生/重启/三主题、真实分析服务覆盖与进程清理通过；gold gates全部通过，完整脚本退出0。见[最终完整日志](evidence/reader-ligatures/final-product-gates.log)。Release折叠检查实测47.72ms。各通道原始输出见[自测证据目录](evidence/reader-ligatures/final-self-tests)。

## 字体与性能实测

本机字体FiraCodeRoman-Regular 6.002、JetBrainsMono-Regular 2.305；产品不分发字体。版本、SHA与CoreText请求/有效features区别见[字体记录](evidence/reader-ligatures/fonts.md)。On/Off/Default按原生成形验证，不能仅用glyph数量判断连字。源码fixture包含Unicode/CRLF，见[manifest](../../fixtures/ligatures/manifest.json)。

以下完整系列测于`6eae9e1`，不是最终`1f907ec`重复测量；5次预热+30次有效样本，串行执行。最后收尾变化为缩进cap缓存、视口校正合并、心跳窗口隔离，`1f907ec`阶段另有resize实测；`0296f21`补充锚点修复、原生自测与完整功能回归，未重跑整套性能系列。逐文件来源及哈希见[清单](evidence/reader-ligatures/native/run-manifest.json)。N03/N04使用2×原生cacheDisplay，N05沿用wrap自测；同步绘制耗时不是显示器vsync帧间隔。

| 2,000行字体 | 正确首帧p95 | 稳定p95 | Off滚动p95 | On滚动p95 |
| --- | ---: | ---: | ---: | ---: |
| Fira Code | 37.42ms | 74.96ms | 6.26ms | 6.53ms |
| JetBrains Mono | 44.28ms | 85.01ms | 6.29ms | 8.00ms |

| Fira Code连字On场景 | wrap On稳定p95 | wrap Off稳定p95 |
| --- | ---: | ---: |
| F1 30,000行 | 247.02ms | 142.26ms |
| F2 约1MB长行 | 57.41ms | 179.04ms |
| F3 1.8MB无空格行 | 1476.61ms | 395.99ms |
| Reading Set | 199.51ms | 175.72ms |

F1同字体连字Off对照为171.10/130.26ms。精确旧基线`5a9800b`使用相同依赖构建，系统默认字体F1稳定p95为4562.83/2013.04ms；`6eae9e1`默认字体为161.52/119.32ms，见[基线对照](evidence/reader-ligatures/default-baseline/comparison.json)。这些是固定fixture、本机测量，不外推所有文件或机器。

最终`0296f21`额外运行Fira Code 2000行自测：30次样本、28项正确性检查全部通过，首帧p95 40.04ms、稳定p95 77.40ms，明确性能非阻塞。见[最终原生结果](evidence/reader-ligatures/native/final-policy-native.json)与[构建哈希](evidence/reader-ligatures/final-build-manifest.json)。

收尾源码（采样标签`6eae9e1+coalesced`，随后原样提交为`1f907ec`）resize 5次预热+30次：p50 **44.64ms**，p95 **50.09ms**，max54.15ms，心跳最大延迟39.04ms；不满足旧33ms参考值，按用户决定作为已披露的best-effort差异。没有新增更复杂的完成事件协议去追该数字。

历史失败、错误假设和中间测量保留在[原验收记录](evidence/reader-ligatures/acceptance-history-before-final.md)及before-viewport-fix目录；旧F1数秒结果不代表当前实测。旧Tabs171—177MiB与后续62.61MiB存在桌面状态关联，未证明因果；没有用未知SHA旧二进制冒充精确基线。

## A01—A15 结论

| ID | 结果 | 证据与边界 |
| --- | --- | --- |
| A01 | 通过 | 4 个隔离配置测试：旧 key、非法值、三态 round trip、恢复默认清旧名、保留缺失字体请求 |
| A02 | 通过 | 两字体三态原生成形及原生绘制；可见Settings三态与实际字体提示通过 |
| A03 | 通过 | 同族/斜体/变体轴、函数强调、humanist 清理及 syntaxFormatting 组合；可见代码面见桌面记录 |
| A04 | 通过 | 字节/显示字符串/投影不变，跨折叠源复制、附件身份保留；折叠旧属性已先失败复现再修复 |
| A05 | 通过 | 原生键盘、查找、生产copy和Unicode几何；`9eca0f9`及`1f907ec`真实窗口拖选!==、缩选与复制!=通过；最终自动化另计 |
| A06 | 通过 | wrap×字号×三态、首视觉行与 Unicode；可见字号与wrap切换已复验 |
| A07 | 通过 | 独立锚点≤2pt；六个正反方向自动化组合通过；`9eca0f9`真实窗口反向拖选!==、切换On后Shift+Right得到==；最终自动化另计 |
| A08 | 通过 | 人工滚动通知/换文档取消旧恢复，10 窗口×10切换后弱引用全部在2秒内释放 |
| A09 | 降级符合已记录策略 | 8,001 行及 >64 KiB 锚点行保留选区/原文/水平位置；不承诺精确同步定位 |
| A10 | 通过 | 同字号换字体、三态、字体环境、测量幂等、卡片选区与外层锚点；F5性能通过 |
| A11 | 通过 | 主/对比/Context/新窗口、普通文本不变；真实 AppDelegate 通知自动更新主面与预览；可见主Reader、Context、对比、新窗口与纯文本流程已验 |
| A12 | 通过 | 中文、emoji、组合字符、ZWJ、Tab、CRLF；几何扩展不回写源范围 |
| A13 | 通过 | 缺失字体、最近字重、字体环境刷新；设置原生菜单已复验；真实字体安装/移除组合未宣称通过 |
| A14 | 通过 | 相同 apply 的投影/属性/段落增量0；纯字体投影增量0；缓存≤128，压力后释放通过 |
| A15 | 通过 | 最终1033项测试、18通道与全部产品/gold gates通过；性能按用户确认的best-effort口径完整披露 |


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
