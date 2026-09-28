# UI 重设计 · 第三阶段（补齐设计稿）

日期：2026-09-28
状态：Q1–Q5 已实现并提交，全量 CI 与真实应用目视已完成。
依据：[设计方案](2026-09-27-ui-ux-redesign-design.md)、[第一阶段计划 §8.4](2026-09-27-ui-redesign-phase1-plan.md)、[第二阶段计划](2026-09-27-ui-redesign-phase2-plan.md)。

## 1. 范围

只做数据现成的项：

| 片 | 内容 | 数据来源 |
|---|---|---|
| Q1 | 欢迎页双栏：左侧字标与标语，右侧最近项目带语言缩写块 | `RecentProjectsStore.languages(for:)` |
| Q2 | Relations 当前方向分段显示结果数 | 关系树当前根下的边与可能匹配 |
| Q3 | 工具栏信任印章（Safe / Trusted） | `ExactCoordinator` 的信任模式 |
| Q4 | 命令面板符号行的种类色块 | 面板行已有的符号种类 |
| Q5 | 书签状态改为徽章 | `BookmarkStatus` |

## 2. 不做（仍无数据）

| 项 | 原因 |
|---|---|
| 提交选择器「Exact 已缓存」 | 提交模型没有物化状态 |
| Reading Trail 历史会话卡片 | 视图拿不到历史会话数据 |
| Inspector 标题旁的堆石 | 显示数据只有徽章，没有 certainty |
| 其他 Relations 方向的计数 | 未查询的方向没有结果 |

## 3. 约定

沿用前两阶段：颜色只取 `ReaderTheme`；UI 断言证明可见并逐条注入；每片全量 CI；computer-use 目视；commit 英文简短。

## 4. 验收记录（2026-09-28）

### 4.1 实现与测试

| 片 | 实现 | 新增测试（均逐条注入变红后恢复） |
|---|---|---|
| Q1 欢迎页 | 操作区与最近项目并排，欢迎页宽度 <820pt 时上下堆叠；最近项目左侧显示已记录语言的缩写块（RS / PY / TS / JS，多语言用 `·` 连接），未记录语言的旧条目保留文件夹图标，不把 Rust 回退值当事实显示 | `welcomeSetsRecentsBesideTheActionsAndStacksThemWhenNarrow`、`welcomeShowsRecordedLanguagesFromTheRecentProjectsStore` |
| Q2 Relations | 仅当前方向的分段标签带结果数（超过 99 显示 99+），其余方向保持原文案 | `relationActiveDirectionShowsItsResultCountOnly` |
| Q3 信任印章 | 工具栏 Profile 按钮前置盾形印章：Safe 苔绿勾盾，Trusted 琥珀感叹盾，随主题着色 | `profileButtonCarriesAThemedTrustSeal` |
| Q4 命令面板 | 当前文件与项目符号行左侧加种类色块（fn / st / en / cl / ty / tr / im / md / va），按种类族取主题色 | `paletteSymbolRowsCarryVisibleKindTagsColoredByFamily` |
| Q5 书签 | 状态改为标题旁的 `CairnBadgeView`：精确→已验证，漂移→受限，修订缺失 / 文件不存在 / 偏移无效→已更正，未评估→已捕获；明细行只在有尝试消息时追加文字，悬停提示保留完整状态 | `bookmarkRowsShowStatusAsAVisibleThemedBadgeInsteadOfDetailText` |

- Q5 注入时发现第一版测试取明细行的方式会匹配到同样含路径的标题，把状态塞回明细也不变红；改为按「路径 · 」前缀定位明细后，两种注入（改徽章样式、把状态文字放回明细）都变红。
- CI 主批次期望数 1158 → 1164。
- 全量 CI 通过：本地化 799 键；主批次 1164 条全部报告完成（合计 1171 条，含隔离 / 面板 / 鼠标 / 字体批次）；架构检查与折叠性能门禁 pass。

### 4.2 真实应用目视（computer-use，深色主题，rlm-minimal）

- 工具栏：Profile 按钮前为琥珀色感叹盾，与状态栏「已信任」一致。
- Relations：选中 `_colorize` 后「显示调用方」，分段显示「调用方 6」，与列表 6 行一致；其余方向无数字。
- 命令面板（全屏控制）：`#log` 结果中函数行为苔绿 `fn`、类为石板蓝 `cl`。
- 欢迎页（新建窗口）：左侧字标、标语与打开按钮，右侧最近项目带 PY / RS 语言块。
- 书签：临时添加一个书签查看，徽章「内容一致」为苔绿浅底；查看后已删除。

### 4.3 目视发现的问题

| 问题 | 处理 |
|---|---|
| 书签行的「打开」按钮被拉宽到约 295pt，文字列只剩 170pt，明细行折成两行 | 操作按钮保持自身宽度，文字列取剩余宽度；明细行用段落样式单行中间截断（属性字符串会覆盖控件的截断设置）。Q5 测试补两条断言：短明细仍占行宽一半以上、长路径只占一行；两处实现分别注入均变红 |

另：`swift test --filter bookmark` 并行跑时，`bookmarkCommandReportsTheEligibilityReasonOutsideThePrimaryReader` 所在进程会中途退出、没有批次摘要；在第三阶段之前的基线 `6cae0fd` 上同样如此，单独运行通过，CI 串行批次完整报告，属既有的测试隔离问题。

修复后（`75c4e12`）重跑全量 CI 通过：主批次 1164 条全部报告完成，合计 1171 条，折叠性能门禁 pass。
