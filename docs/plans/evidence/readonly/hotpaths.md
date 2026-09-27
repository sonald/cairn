# S0 热路径与观测位置

源码基线：`f5e116d6477fe20ed9bd83b08b82f4a0512594a7`。以下为静态调用链审查；命令未在本审查中执行，不构成性能或原生验收通过证据。行号对应此 SHA。

## 事件调用链

| 事件 | 调用链与线程 | 实际重复工作 |
| --- | --- | --- |
| 标识符点击 | `CodeInsightReaderUI.swift:590` clickHandler → activate(atCharacterIndex:) → activate(atByteOffset:)（2734）→ `CodeInsightReaderCore.swift:327` identifierOccurrences；ReaderTextView 在 458 标记 MainActor | 每次 UTF-8 全文 String 解码，再遍历全部 Unicode scalar/token 和相关 highlight spans；String 比较保留规范等价语义 |
| 原生选择恢复 | selectionHandler（607）→ occurrenceNSRanges（3063）→ 同一查询，MainActor | 已有 occurrence selection 时，原生选择路径也会扫描，不能只迁移点击 |
| 折叠与查找装饰 | refreshOccurrenceRendering（3025）、refreshFoldExposures（3081）→ 同一查询，MainActor | 找回出现范围和隐藏计数可再次扫描源码；foldedRangeCounts 又构造 renderedRegions 并排序范围 |
| 稳定滚动绘制 | ReaderRulerView.drawHashMarksAndLabels（4317）→ drawRuler（3401），MainActor | 重建源行→fold 字典、全 fold ID 字典；visibleBookmarkMarkers 与 foldedDiffMarkers 经 renderedRegions 过滤/排序全文 fold；随后才枚举可见几何 |
| Fold hover/click | updateFoldHover（3575）/clickFoldHandle（3582）→ foldRegion（3600），MainActor | 每次遍历未隐藏的 fold 构造 byLine。“可见 fold”指未隐藏结构，不是屏幕内几何 |
| 单 fold、预设、Focus | toggle/override/reading-height/focus/恢复 → applyFoldProjection（1530），MainActor | maximalFoldIDs → project → refreshVisibleFoldRegions → occurrence/装饰刷新 → installProjectedText → 选择/视口恢复 |
| 文件显示 | display → project（3863）→ DisplayMap.init（42）→ installProjectedText（1585），MainActor | 筛选/排序 folds；逐 source slice 解码并追加 placeholder；尾部解码；全量 attributed string、typography、fold 字典与附件建立 |
| 设置 | MainWindowController:2287 → 主/辅 ReaderController.apply（5975）、Context（7682）、Settings 预览（ReaderSettingsWindowController:535/544）→ ReaderTextView.apply（2421），MainActor | 幂等提前返回；纯字体且指定颜色项未变走属性更新；geometry-only 走段落；其他 theme 变化重建投影并替换全文；gutter 配置可触发布局 |
| 异步语法 | MainWindowController:7425 loadSyntax completion → Task MainActor（7427）→ updateSyntax（7439 / ReaderUI:2307） | 即使 renderedFoldIDs 不变也 project、建立附件字典并全量替换；仅视口恢复分支按 fold 集合变化区分 |
| 关闭折行 | apply/configureGutter → configureWrapping（3790），MainActor | >8000 行且有 previousViewportStart 才估算；无旧 viewport 或小文档从 documentRange 起 ensuresLayout 枚举整个 extent（3838） |
| 外向调用 | RelationTreeModel:683 Task.detached → nonisolated load（1823）→ EngineSession.outgoingCalls（260）；CLI:432 同步调用 | 每个符合 facet 范围的 call 全扫描 executableRegions，按最小 range 长度、较大 ID tie-break 选 owner；排序全部匹配再 prefix(512)，truncated 使用完整计数 |
| 反向调用 | RelationTreeModel.load → EngineSession.callers（185），同一 worker 路径 | 每个 posting/file 在 executableRegions.first(where:)（211）从头寻找 regionID，再运行 resolver |

ReaderDocument 可共享，EngineSession 是 Sendable class，查询本身不强制线程。表中 worker 指生产 App 调用者，测试/CLI 不一定采用相同线程。

## 最小插桩位置

- 标识符：327 入口记 lookup；实际扫描的两个 bytePosition 推进分支累计 scannedBytes；返回处记范围数。校验失败不可凭文件大小计作扫描。首次 String 解码成本与 token 扫描分开说明。S1 buildCount 只能在新 builder 真正启动处增加。
- 投影：DisplayMap.init 是结构构造 seam；每个 String(decoding: sourceSlice) 与 tail 统计实际 materializedUTF8Bytes / UTF16Units，placeholder 按输出字符计。ReaderTextView.project 另记 attributed string 属性量，不能把 source bytes 总数冒充物化量。
- Storage：installProjectedText 中 setAttributedString 实际执行处记 fullTextReplacementCount。保留 projectionInstallCount 原位置和含义；partial replacement 待实际 replaceCharacters 接入。
- Gutter：drawRuler 中遍历 visibleFoldRegions、foldRegions.map、marker/region 的实际访问记 drawGlobalRecordVisits。hover/click 的 byLine 构造也要有可区分记录。S2 decorationBuildCount 放在新装饰准备入口，不能只统计 visible fragments。
- 段落：ReaderParagraphLayout.apply:64 的 while 每次访问记 paragraphRecordsVisited；wrap-off enumerateAttribute 的访问也需观测。现有返回 Int 只记属性改变，不是访问数；不可重定义 paragraphUpdateCount。addAttribute 的 range.length 记 attributeUpdatedUTF16Units。
- Engine：outgoingCalls 的 executableRegions.filter 谓词内记 queryRegionVisits；callers 的 first(where:) 谓词同样计数。不能直接加 calls×regions，因为 facet guard 会跳过调用。S3 真正构建时才加 ownershipBuildCount。
- 布局：configureWrapping 全量 extent 的枚举入口/fragment 访问分开计；可见 ensureLayout 不可记成全文布局。firstPaint 必须源自 draw，不能使用 apply 返回时间。

计数按文档/Reader/Engine 会话归属快照取差值；共享查询计数须线程安全，避免进程级可变全局计数污染多窗口结果。

## 已有可复用观测

ReaderUI:528–543 已有 typographyAttributeUpdateCount、projectionInstallCount、paragraphUpdateCount、backgroundDrawCount、viewportRestorePassCount、widthReflowNotificationCount、mergedWidthReflowCount。Renderer:157–162 有 styled/reference fragment、attribute-run 和 reference scanned 计数，均保留原义。

ReaderUI:2714 周边记录最近实际绘制的 gutter 第一视觉行、标签、主选择矩形；setFoldGutterHoverForTesting 驱动命中；foldPerformanceCounts（1249）记录 logical/rendered fold 数。已有 visibleFoldRegionsCache（514/2276）可复用，但绘制与命中仍从缓存重建行字典。

LigatureSelfTest.swift 已保存实际字体/OpenType、viewport、截图、backgroundDrawCount、投影/属性差值、内存采样和至少 30 次样本；fragmentMatches + draw 增量等待可作 runner 原生就绪依据。ReadingSetView 已有 measurement/draw 计数。Fold perf 已有 fixture hash、8400 fold 校验、峰值物理内存和 control/fold 两路 JSON。

## 当前可执行入口（本审查未运行）

```bash
swift build
.build/debug/codeinsight-app --self-test-projector
.build/debug/codeinsight-app --self-test-fold
CODEX_SANDBOX=1 bash scripts/ci.sh

swift build -c release --product codeinsight-app
bash scripts/run-fold-perf.sh --app-bin .build/release/codeinsight-app \
  --fixture fixtures/fold_perf.rs --manifest fixtures/fold_perf.manifest.json
# 独占环境才附加 --enforce-budgets；FOLD_PERF_RESULT_DIR 可指定结果目录。

.build/release/codeinsight-app --self-test-wrap \
  --fixture fixtures/fold_perf.rs --wrap off --scenario toggle \
  --output /tmp/readonly-wrap.json --code-sha f5e116d6477fe20ed9bd83b08b82f4a0512594a7 \
  --warmup 5 --samples 30 --font-postscript Menlo-Regular --ligature-mode fontDefault
# scenario 接受 initial、toggle、resize、reading-set。

.build/release/codeinsight-app --self-test-ligatures \
  --fixture fixtures/fold_perf.rs --font-postscript system \
  --mode fontDefault --samples 30 --json-out /tmp/readonly-ligatures.json

CAIRN_LIBGIT2=brew bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

现有 projector/fold self-test 执行原生 AppKit 代码，不能代替真实窗口鼠标/复制/VoiceOver 验收。Fold/wrap perf 使用 prohibited activation policy；用户可见窗口证据须单独采集。Ligature runner 有字体缺失 blocked 状态；新 readonly runner 应保持 pass/fail/blocked/not_run 区分。当前 CI 预期 main=1028、isolated=2、panels=2、mouse=1；以实际完整测试结束摘要判定结果。
