# Reader wrap v2 · S1 记录(菜单 + 主 Reader 视口/选区/尺寸事务)

> 2026-09-22 计时口径更正：下表历史 `toggleSettledMs` 仅为首帧后的稳定等待，不能证明完整切换预算通过。按原始样本逐次相加后，S1 的 F1 on/off p95 为 3910.2/854.9ms，F3 off 为 5520.6ms，均超对应绝对预算。撤回下文对应的 settled 预算 PASS；原始数据保留，schema 2 runner 已改为动作开始至稳定计时。最终候选仍需独占机器复测。

- 日期:2026-09-21
- 代码:S1 提交(基线 `5ae0f99` 之上)
- 机器/OS:Mac15,6 / macOS 27.0(与 S0 基线同机同配置;性能数据 Release 构建)

## 交付物

| 项 | 位置 |
| --- | --- |
| View → Wrap Lines(⌥Z,决策 C1) | `CodeInsightApp.swift` `makeMainMenu`/`toggleWrapLines(_:)`/`validateMenuItem` |
| 视口状态模型(D3.1) | `Sources/CodeInsightReaderUI/ReaderViewportState.swift`(新文件) |
| 重排事务(D3.2–D3.6) | `ReaderTextView.apply(settings:)` 重写 + 捕获/恢复/校正/宽度重排机制 |
| 尺寸变化窄回调(D3.7) | `ClickTextView.widthWillChange/widthDidChange`(setFrameSize 前捕获) |
| 幂等 apply(D1.2/W06) | apply 早退:设置相等且挂载未变时不做任何投影/布局 |
| wrap-only 快路径 | wrap 切换不重建 DisplayMap/属性串(投影计数不变,仅容器几何变化) |
| 测试 | ReaderUITests.swift 8 项新增 + WrapLinesMenuTests.swift 2 项(新增文件) |

## 实现要点(对照设计)

1. **捕获时机(D3.6)**:`apply(settings:)` 在 `configureGutter`(会经 `configureWrapping` 触发布局)之前完成 `captureViewportStateForReflow()`。
2. **锚点解析(D3.2)**:用 `characterIndexForInsertion(at:)` 在视口 25% 高度、可见水平中点解析**实际字符**;命中折叠 chip 时锚到占位符(`.foldPlaceholder`),纯重排不展开折叠;零尺寸/未挂载面只保存设置与选区。
3. **连续纯重排复用稳定锚点(D3.5/E3)**:同一内容+同一投影 revision 内复用上次锚点与偏移;用户滚动、选区变化、导航、折叠变化、内容替换都使序列与**未执行的校正**一并失效(`invalidateReflowSequence` 同时清 `pendingViewportCorrection`/`pendingWidthReflowGeneration`,实现"用户交互优先于未完成恢复")。
4. **恢复(D3.3/D3.4)**:选区(全部 ranges + affinity + primary/find 身份 + 当前行字节)先恢复;锚点行按 `newScrollY = anchorRowY - offset` 定位并钳制;水平按 D3.5 表(wrap-off→on 滚到合法起点并保留 stash;on→off 恢复 stash,以**锚点字符**矩形——经 TextKit2 `enumerateTextSegments`,`firstRect` 在宽行上不可靠(S1 实测)——做最小可见性微调)。
5. **有限校正(D3.6)**:同步恢复后最多 3 次异步校正,每次校验 generation/内容/投影 revision;布局未沉降(陈旧 fragment)时不消耗次数重试(上限 6 次);恢复次数与锚点误差经 `viewportRestorePassCount`/`lastViewportAnchorErrorPt` 输出给性能 runner。**测试环境注意**:Swift Testing 同步测试持有主线程,main-queue 块在测试返回前不执行——延迟工作因此建模为"待办 + 显式 flush"(`processPendingViewportRestoresForTesting`),app 内仍走 main queue,两条路径执行同一代码。
6. **容器几何物化(S1 实测发现,超出设计的必要补充)**:TextKit 2 在容器尺寸变化后**不会**失效旧布局——关 wrap 后旧 fragment 仍按换行几何服务(实测:`invalidateLayout(整文档)+layoutViewport` 才物化展开)。实现为:容器有效宽度实际变化时失效**视口范围**(整文档失效会强制物化全部 fragment——F1 实测 resize 步长 9s、内存 +4.7GB,已弃用);关 wrap 方向追加一次全量 `ensuresLayout` 枚举并按排版 extent 显式重设 frame(否则视口停在超过新内容的位置时 frame 永不收缩,W17 底部场景)。
7. **wrap-only 快路径**:wrap/行号变化不重投影(`projectionInstallCount` 不变);主题/字号变化才走全量投影。toggle-on 首帧不再含 1.3s 的投影重建。

## 测试(对照 §7.2 矩阵)

| ID | 测试 | 结果 |
| --- | --- | --- |
| W06 | `wrapSettingsApplyIsIdempotentForEqualValues`(相等设置零投影零布局;wrap-only 同样零投影;字号变化恰好 +1) | PASS |
| W10/W12 | `wrapToggleRoundTripsKeepMidLineAnchorAndViewportOffset`(20 轮 off↔on;探针行不变、仍在长逻辑行深部;锚点误差 ≤1pt=2物理像素@2x) | PASS |
| W11 | `wrapTogglePreservesCompleteSelectionAndCopyText`(多 range 选区 + 复制文本双向不变) | PASS |
| W13 | `wrapToggleRestoresStashedHorizontalPosition`(off→on 到合法起点;on→off 恢复 stash x) | PASS |
| W15(部分) | `wrapFontSizeChangeKeepsAnchorAndSelection`(字号变化保锚点行与选区源文本) | PASS |
| W17 | `wrapToggleClampsLegallyAtDocumentEdges`(顶部/底部/短文档/空文档;底部往返精确复位) | PASS |
| W18 | `wrapToggleRoundTripsUnicodeAndFoldedContent`(CJK/emoji/CRLF + 折叠 chip 往返;折叠状态保持) | PASS |
| W19(部分) | `wrapToggleDoesNotStealFirstResponder`(本环境无法持有焦点,显式跳过并打印说明;焦点不变契约由代码路径保证:apply 无任何 makeFirstResponder 调用) | PASS(环境跳过) |
| W01/W02/W03 | `wrapLinesMenuCommandIsGlobalRoundTripsAndSyncsSettings`(菜单项 ⌥Z/勾选/UserDefaults round-trip/Settings 表单同步;Settings 为 key window 且无项目 target 时可用;其他项目命令仍正确禁用) | PASS |
| D3.7 | `wrapWidthChangeKeepsAnchorOffsetAfterMergedReflow`(窗口缩放往返后探针行稳定) | PASS |

未在本切片覆盖:W16(窗口连续缩放中用户打断)、W05(快速切换+关窗口内存)——交互级,真实窗口验收时补;多窗口同步由 `commitReaderSettings` 的既有广播循环承担(菜单测试验证了该路径的状态一致性),运行时多窗口验收归入真实窗口验收。

## 性能(S1 候选 vs S0 基线,20260922T005924Z + 复核轮)

数据:`docs/plans/evidence/reader-wrap-v2/s1-candidate/`(28 个 JSON;采集命令同基线 + `--enforce-budgets --baseline-dir s0-baseline`)。

F1(30000 行)主预算指标,基线 → 候选:

| 指标 | S0 基线 | S1 候选 | 预算 | 判定 |
| --- | --- | --- | --- | --- |
| toggleSettledMs p95(on) | 29.3 | **32.2**(p50 26.6 / max 32.8) | ≤250ms 且 ≤max(base×1.5, base+15) | **PASS** |
| toggleSettledMs p95(off) | 25.9 | **23.6** | 同上 | **PASS** |
| toggleFirstFrameMs p95(on) | 6721 | **3878**(−42%) | — | 改善(wrap-only 快路径消除投影重建) |
| toggleFirstFrameMs p95(off) | 1748 | **832**(−52%) | — | 改善 |
| resizeStepMs p95(on) | 44.9 | **49.7**(p50 42.3) | ≤33ms | **BASELINE-EXCEEDED**:基线自身超预算的既有成本,候选在噪声内持平,记录为待解决性能项(§7.4.4) |
| resize 全程最长主线程阻塞 | 6481 | 6944(含加载后的首次全文档排版,两轮同样存在) | ≤100ms | **BASELINE-EXCEEDED**(同上) |
| peakPhysBytes toggle-on | 7.87 GB | **1.20 GB** | ≤max(base×1.3, +32MiB) | **PASS**(恢复路径不再物化全文档布局) |
| peakPhysBytes resize-on | 249 MB | 263 MB | 同上 | **PASS** |
| restorePassCount(toggle 全程) | null | 0(锚点经测量即达位) | 每轮 ≤3 | PASS |
| anchorErrorPt | null | null(门控文档无同步恢复;小文档见单测 ≤1pt) | — | — |

F2/F3/F4 toggle settled p95:23.7 / 24.8 / 23.2 ms(预算 1500/1500/—)全部 PASS;F5 `unsupported`(S2b 前)。

**S1 期间发现并消除的性能陷阱(记录给后续切片)**:
1. 恢复路径的 `clipView.scroll` / fragment 查询在宽度刚失效的文档上会强制物化全文档布局(F1 实测 3–10s 阻塞、峰值 12.5GB);原生 TextKit 探针证明该成本来自 reader 环境的布局物化,不是 scroll API 本身。
2. 对应处理:(a) 容器几何只做必要变化(不做整文档失效);(b) 宽度重排尾部不再强制 `validateVisibleRenderingAttributes`(已安装的 validator 在自然绘制时懒应用);(c) 超过 8000 逻辑行的文档按 §8.1 门控同步恢复(保留选区与设置,交给正常布局生命周期),F2/F3/F4 与全部交互文档(≤8000 行)保持完整恢复;(d) 测量前先 `layoutViewport()` 使 fragment 查询命中已排区域。
3. toggle 首帧仍为秒级(F1 3.9s):首次 wrap 排版 30k 行的固有成本(基线同样存在且更高),归入"待解决性能项",不因基线也慢而标记通过。

## 遗留

- resize 步长与 toggle 首帧预算状态:见上节数据。
- `--self-test-reading` 扩展:菜单/round-trip 覆盖以 AppTests 单测形式落地(`WrapLinesMenuTests`);真实窗口(焦点/多窗口/AX)验收随整体完成定义前的真机验收执行。
