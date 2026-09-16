# 恢复阅读现场：修复与原生验收

日期：2026-09-16。对应审查：`2026-09-16-reading-session-restore-review.md`。

## 修复

| 提交 | 内容 |
|---|---|
| `45b1061` | 同项目已打开但会话读取失败时，重新打开确实重试，权限恢复后可恢复原现场 |
| `4063e9e` | history 极值游标先钳制再裁剪，避免损坏数据触发整数溢出 |
| `c57d9e5` | 恢复任务清理核对 owner；失败代数保持写保护；同项目改语言先保存；读取权限失败保留并阻写；legacy 重试不被新快照遮蔽；同步活动文件和导航代数，让真实 Reader 应用位置 |
| `a801b43` | 回放先读取目标版本并定位，成功后提交 history/Trail/视口；快速前进后退保留连续请求语义 |
| `85efa4c` | 项目上下文改变或清除现场时关闭旧 frozen Inspector、取消旧关系查询 |
| `4669f22` / `3d13958` | 测试等待异步回放终态，移除对 SwiftUI 内部 NSSlider 类型的依赖，保留真实控件几何断言 |
| `7ac981a` | 阅读规模自测新增夹具后显式 Refresh Index，保留 201 条及 partial 断言 |
| `259304c` | 正常终止与实际 Reader 两进程验收；核对节点/边身份和重启后 Back/Forward；轨迹面板不再写 THIS SESSION |

没有扩大到方案明确延后的折叠、Focus、完整拖选范围或预览页码恢复。

## 新增发现：为什么必须检查实际 Reader

原测试保存并比较模型中的 scrollAnchor，滚动测试使用 0。因此活动文件未同步、Reader 从未应用恢复位置时也能通过。

加强后的两进程测试首次失败：正常终止确实保存了中段的锚点，但重启后 Reader 回到文件头。根因是批量恢复只调用 `tabStrip.endRestoredBatch`，没有同步 AppModel 的 selectedFile/navigationGeneration；控制器的 pendingTabRestore 没有执行。

修复后现有控制器回归改为非零视口、真实 caret 和 selectedFile 三项断言，并完成 RED→GREEN。新的两进程验收也已通过。

## 实际窗口验证

使用独立 bundle ID `dev.cairn.Cairn.SessionAcceptance20260916`，测试目录 `/tmp/cairn-session-ui-20260916`。没有操作用户原 Cairn 窗口、真实项目现场、书签或 Xcode 许可。测试源码为本轮生成的 Rust/Python/Markdown 夹具。

以下操作通过原生窗口、菜单、工具栏或控件完成；不是预写 session JSON：

| 场景 | 观察结果 |
|---|---|
| Open Project | 从目录选择器打开 A，选择 Rust＋Python；文件树真实呈现 |
| 标签与函数 | 固定 main.rs、other.rs、third.rs；Outline 导航 alpha/beta/gamma |
| 分支 | Back 后建立另一分支；Branches · 1 面板实际呈现两个兄弟节点 |
| 真实滚动与 Quit | 拖动原生滚动条到 gamma 中段；菜单 Quit 后重开，三标签顺序、gamma 和约第 86 行的视口恢复；像素内偏移不在契约内 |
| 关窗 | 关闭最后一个窗口再启动，活动标签和分支继续保留 |
| A→B→A | B 初始不带 A 的标签；B 打开 helper.py 与 README.md；返回 A 恢复其三标签及轨迹 |
| 最近项目 | File→Open Recent→B 恢复 Python 和 Markdown 两标签，Markdown 显示 B 的内容 |
| Reading Set | alpha 的 Calls 显示 beta/gamma Verified；沿关系导航后 Freeze Results，产生 beta Reading Set；关窗重启后仍显示冻结源码；View Evidence 显示 AT CAPTURE |
| 读取权限恢复重试 | 对隔离 B 快照临时撤销权限；实际 UI 显示 kept untouched，文件逐字节未变；恢复权限后 Open Recent→B 恢复 main.rs 标签并清除提示 |
| 跨项目 Inspector | A 的 Reading Set 打开 AT CAPTURE 后切到 B，B 仅显示关系空态，不再出现 A 的 println 证据 |
| 清除现场 | B 的 Clear Reading Session 显示范围确认；清除后标签和导航为空，源码仍在；关窗重启后没有复活旧标签 |
| 历史提交 | 在 B 选择初始 commit 阅读 beta；退出后从工作区删除 other.rs 并提交；重启仍能从原 commit 恢复 beta |
| 跨版本 Back/Forward | 切回当前工作区打开 main.rs；工具栏 Back 成功打开仅历史 commit 存在的 beta，Forward 返回当前 main.rs，并提示按当前工作区回放 |

Reader 截图和 AX 观察记录保留在本任务的工具输出中。两进程断言进一步核对实际 firstVisibleByteOffset、实际 NSTextView caret、全部 Trail 节点和边身份、活动节点，以及实际控制器 Back/Forward 后显示的文件。

## 可重复的两进程检查

```sh
bash scripts/run-session-acceptance.sh /tmp/cairn-session-ui-20260916/build/Cairn.app
```

脚本生成独立长文件夹具、UserDefaults suite、session 和索引缓存。进程 A 不手动 checkpoint，在最后阅读操作后调用正常 NSApplication.terminate；日志必须出现 WillTerminate。进程 B 经正常启动恢复后检查 Reader 和导航。脚本保留 artifacts 路径，失败不抹掉证据。

首轮修复后通过的原始输出在 `evidence/2026-09-16-session/two-process-*`。文件读取/父目录权限、legacy 权限/未来 schema、取消交错、游标溢出及 Inspector 等 RED/GREEN 摘要也保存在该目录。

## 验证状态

- 极值游标、恢复交错、读取权限、旧格式迁移、同项目语言重开、真实 Reader 位置、Inspector 重置：已有真实 RED→GREEN。
- 历史版本文件和异步读取失败：新增 2 个测试函数共 3 个场景 GREEN；最初 RED 运行因旧等待上限被终止，没有完整失败摘要，未将其标为已取得 RED。
- Inspector 跨项目原生 UI 复验已通过。完整 CI 终态和重复两进程结果见下节。

## 最终结果

**PASS。功能代码基线 `45b1061`；最终应用包已构建、签名校验，并重复通过两进程验收。**

- 完整 `bash scripts/ci.sh`：exit 0，**946 tests PASS**（主批次 942＋窗口隔离 2＋面板隔离 2）。Exact、Diff、Reading、Projector、Fold 原生自测均 exit 0。
- 折叠性能最终 **270.4 ms ≤ 400 ms**，内存增量约 15.5 MiB，门槛未修改。早先一次并行构建期间为 658.2 ms、未通过；独立复测 252.9 ms；最终无并行构建的完整 CI 通过。三份原始结果均保留，不据此推断全部波动原因。
- 最终两进程输出：`evidence/2026-09-16-session/final-two-process-*`；完整 CI 摘要：`final-ci-summary.log`。完整未裁剪 CI 日志仍在 `/tmp/cairn-session-final-ci.log`。
- 最后一次权限恢复重试及跨项目 Inspector 清理均通过真实 UI 验证。临时权限已恢复，测试窗口已关闭。
- 应用包：`/tmp/cairn-session-ui-20260916/build/Cairn.app`。本机验收使用 Homebrew libgit2 并随包封装、ad-hoc 签名；没有申请公证或替换用户原应用。
