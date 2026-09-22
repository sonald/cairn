# Reader wrap v2 · S3 悬挂缩进

日期：2026-09-22；基于 S2b `719b5d8`。

## 实现与覆盖

- `ReaderParagraphLayout` 由主 Reader 与代码摘录共用，按 `min(prefixAdvance, 24 × spaceAdvance, 0.25 × W)` 设置续行缩进，保留基础段落的行高与 Tab 配置。
- Tab 前缀复用单行 TextKit 测量上下文，缓存随字体/段落配置失效，内容替换释放缓存。未新增 Tab 偏好。
- 主 Reader 的所有投影安装在语法字体、附件安装之后统一处理段落；源行前缀通过 DisplayMap 映射，折叠占位符使用 header 源行。
- wrap/行号变更和合并后的宽度更新只更新必要段落，不重建 DisplayMap。滚动可以取消视口恢复，但不能取消当前宽度对应的段落值更新。
- Reading Set 使用同一段落步骤；普通文本和 Markdown 不使用代码悬挂缩进。另补普通文本窗口缩放前捕获字符锚点、重排后同步恢复，保留完整选区。
- 新的非换行投影沿用基础段落样式，不额外扫描全文；关闭 wrap 只清理确有缩进的属性区间。重排和滚动会清除旧 fold hover，避免指针未移动时标记跟随旧 FoldID。

## 行为检查

| 编号 | 测试 |
| --- | --- |
| W30/W33 | wrapHangingIndentUsesSpaceAndWidthCapsInActualRows：0/4/24/40 空格，检查实际续行 x、Syntax formatting off、关 wrap 归零 |
| W31 | wrapTabPrefixUsesTheSameExplicitStopsAsTextKit：混合空格/Tab，37/83pt 显式 stops，实际续行位置及幂等更新 |
| W32 | wrapHangingIndentRecomputesOnWidthChangesWithoutProjection：800→320→800，25% 上限随宽度更新，投影次数不增 |
| W34（部分） | wrapHangingIndentSurvivesSyntaxAndFoldProjectionChanges：updateSyntax、fold/unfold、字号更新及续行 chip 的真实几何 |
| W33 | wrapParagraphLayoutPreservesProportionalCommentsAndLargeDeclarations：比例字体注释、放大声明和 1.7 行高保留 |
| W39 补充 | plainTextPreviewResizePreservesVisibleCharacterAndSelection：窗口 640→420→800，字符锚点、完整双选区和 affinity |
| W38 补充 | readingSetWrapUsesActualRowsAndOneHeightConstraint：增加 100 次切换，固定高度约束数量不增长，重复设置零新增测量 |

先行测试曾复现实际续行缺少缩进及宽度变化后上限陈旧；Tab 独立测量已通过。宽度失败定位为视口失效逻辑取消了待执行段落更新，现将几何更新与可取消的位置恢复分开。

最终门禁及原生窗口结果统一见后续验收记录。W34 的 Focus/reading-height 交互、chip 点击以及其他真实窗口矩阵仍以整体验收为准，不能用段落属性测试替代。

### 功能门禁结果

- 全仓覆盖 1005 项：首次主批除 AppTests 外 866 项通过；AppTests 因沙箱内无 screen/sheet 失败后，在正常桌面环境按四个排除项重跑 135 项通过，两隔离批各 2 项通过。没有以退出码替代摘要。
- CI 功能部分的静态检查、Exact/Diff/Reading/Projector/Fold 自测和 fold fixture 哈希检查通过。执行的是 `ci.sh` 中 release/perf 之前的原命令，**不代表完整 CI 的性能段通过**。
- 最后优化非换行快路径及 hover 清理后，定向覆盖 49 项；其中 hover 测试复用旧坐标的失败已修正为重取实际首行几何，单独复跑通过。日志保留失败及复验过程。
- 日志：`s3-checks/functional-summary.log`、`s3-checks/wrap-regression.log`、`s3-checks/hover-final.log`。

## 性能口径修正

主 Reader 的 schema 1 `toggleSettledMs` 实际从首帧后开始计时。schema 2 已改成动作前开始、稳定后结束；`settleQuietPeriodMs` 单列等待期。脚本对旧基线逐个样本合并 first-frame 与 quiet，再计算 p95，保留原始基线文件。

历史数据还原结果（ms，非当前候选复测）：

| 场景 | S0 action-to-settled p95 | S1 action-to-settled p95 | 绝对预算 |
| --- | --- | --- | --- |
| F1 on | 6748.8 | 3910.2 | 250 |
| F1 off | 1771.6 | 854.9 | 250 |
| F3 off | 217.2 | 5520.6 | 1500 |

因此 S1 文档对应的旧 PASS 已明确撤回。F1 为既有超预算成本，F3 off 还原后暴露回退，不能以“基线也慢”解释；须在机器空闲时对最终候选复测并定位。当前不得将整个 wrap 方案标为实施完成。
