# CodeInsight M3 交互测试规格（供 UI 自动化工具执行）

版本：对应 commit `e3e959c`（M3 Git 时间旅行完成 + Opus 终审通过，无阻塞）。
沿用 M1/M2 规格的执行方式与报告格式。本轮聚焦 M3 新功能：commit 切换器、
时间旅行正确性、三级就绪、跨版本历史、面板预设、排版设置，外加 M2 回归抽查。

## 前置条件

```sh
cd /Users/siancao/work/ai/vibecoding/codeinsight
swift build -c release
swift run -c release codeinsight-app
# Cmd+O 打开 ~/work/ai/oatmeal（254 个 commit 的真实历史仓库）
```

测试锚点（已核实）：
- oatmeal 有 254 个 commit；`git -C ~/work/ai/oatmeal log --oneline | tail` 取很旧的
  commit 作切换目标。
- `src/domain/services/bubble.rs` 在 commit `03ae852`(perf 重构)前后内容不同——
  切到该 commit 之前的版本，bubble.rs 内容应与当前 worktree 不同。
- M2 锚点仍有效：`Backend` trait 5 个 strong impl、`use super::Bubble;` 等。

## 已知限制白名单（不算 FAIL，记录现象）

- K11 分支图（graph）未做——切换器是线性 commit 列表 + branch/tag 标签（M3 范围）。
- K12 Compare 预设只做分屏布局，**跨 commit diff 阅读未做**（留 M4）。
- K13 依赖系统 libgit2（brew）；正式分发的静态链接是 M4 事。
- 沿用 M2 白名单 K7（Calls 树外部边——M3 已加 External 分组，若仍有缺失记录）、
  K9（Pin+右键 Show Relations 覆盖 Context，仍待裁决）、K10（高扇入 Possible）。

## G1 commit 切换器

| ID | 步骤 | 预期 |
|----|------|------|
| G1.1 | 打开 oatmeal，观察顶栏 | 有当前版本标识，显示 "Working Tree"（醒目可见） |
| G1.2 | 点击切换器 | 弹出：搜索框 + commit 列表（短 sha、summary、日期），Working Tree 置顶；含 branch 标签（如 main/master） |
| G1.3 | 搜索框输入一段 summary 关键词（如 "highlight"） | 列表过滤到匹配 commit |
| G1.4 | 输入一个短 sha 前缀 | 按 sha 前缀过滤命中 |
| G1.5 | 选一个较旧 commit | 切换发生；顶栏标识变为 "⎇ <sha> <summary>"，与 Working Tree 视觉可区分 |
| G1.6 | ↑↓ + Enter 选择 | 键盘可操作 |

## G2 时间旅行正确性（M3 核心底线）

| ID | 步骤 | 预期 |
|----|------|------|
| G2.1 | 切到 `03ae852` 之前的某旧 commit，打开 src/domain/services/bubble.rs | 显示的是**该历史版本**内容，与 Working Tree 的 bubble.rs 不同（对照可先在 Working Tree 记住某处，再切换比对） |
| G2.2 | 切换后看文件树 | 文件集是该 commit 的（很旧的 commit 可能缺少后来新增的文件/目录） |
| G2.3 | 旧 commit 态单击一个符号 → Context | Context 显示的定义摘录来自**该版本**（不是 Working Tree 版本）——无串快照 |
| G2.4 | 切回 Working Tree | 文件树、内容、Context 恢复当前版本 |
| G2.5 | 快速连续切 3 个不同 commit | 每次 first paint 亚秒；最终显示的是最后选中 commit（无旧快照结果串入） |

## G3 三级就绪 / 覆盖状态

| ID | 步骤 | 预期 |
|----|------|------|
| G3.1 | 切到一个很旧、差异大的 commit | 切换期间工具栏出现覆盖状态（如 "Files X/Y…"，分项非单一百分比）；完成后消失 |
| G3.2 | 切换刚发生、语义未完全就绪时立即单击符号 | Context 要么立即可用（缓存命中），要么显示 building 占位后补齐——不空白卡死 |
| G3.3 | first paint 后立即滚动/浏览文件 | 文件浏览不被语义索引阻塞（可读） |

## G4 跨版本跳转历史

| ID | 步骤 | 预期 |
|----|------|------|
| G4.1 | Working Tree 打开文件 A → 切 commit 看文件 B → 点工具栏后退 | 回到 Working Tree 的 A 原位（**快照也切回 Working Tree**） |
| G4.2 | 前进一次 | 回到该 commit 的 B |
| G4.3 | 后退/前进按钮灰显状态 | 两端正确灰显 |

## G5 面板预设 + 排版

| ID | 步骤 | 预期 |
|----|------|------|
| G5.1 | View 菜单 / Cmd+1..4 切换 Reading/Relations/Compare/Focus | 布局按预设变化（Focus 仅中央；Relations 显示右栏；等） |
| G5.2 | Compare 预设 | 左右分屏容器出现，可各开文件（无 diff 高亮属预期 K12） |
| G5.3 | 打开设置窗口，改行距（如 1.25→1.5） | 阅读区行距即时变化 |
| G5.4 | 改字号、切主题到 SI Classic | 即时生效；SI Classic 呈米白底致敬配色 |
| G5.5 | 退出重开 app | 设置（行距/字号/主题）保留 |

## G6 M2 回归抽查

| ID | 步骤 | 预期 |
|----|------|------|
| G6.1 | Working Tree 态 Show Callers/Calls/Implements（backend.rs 的 Backend） | 关系树正常，5 impl strong（M2 回归）；Calls 树的外部调用现在有 External/Unresolved 分组（M3 新增，对照 K7） |
| G6.2 | Cmd+Shift+F 搜 Backend | 全文搜索正常（M2 回归） |
| G6.3 | 单击 use super::Bubble 的 Bubble | Context → bubble.rs strong（M2 回归） |

## G7 稳定性

| ID | 步骤 | 预期 |
|----|------|------|
| G7.1 | 5 分钟混合：切多个 commit、跨版本历史往返、关系/搜索/大纲、预设切换、改设置 | 无崩溃、无 beachball、无内容错乱（显示内容与当前快照+文件名一致） |
| G7.2 | Cmd+Q | 正常退出 |

## 报告格式

同 M1/M2：`ID | PASS/FAIL/BLOCKED | 备注`。FAIL 附截图与复现步骤。
**G2 是 M3 正确性底线**——切旧 commit 后显示的必须是历史内容，任何"切了 commit
但内容/Context 还是 Working Tree 版本"都是 FAIL（串快照）。K9 观察仍是 Pin 裁决输入。
