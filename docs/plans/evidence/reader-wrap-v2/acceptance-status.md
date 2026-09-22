# Reader wrap v2 · 2026-09-22 验收状态

**状态：切片代码已实施，整体验收未完成。** 正式性能采集及剩余交互矩阵尚未关闭，因此设计 §9.2 不标记“实施完成”。

## 提交

| 切片 | 提交 | 证据 |
| --- | --- | --- |
| S2a | `9e74ccf` | [首视觉行与跨行命中](s2a-first-row.md) |
| S2b | `719b5d8` | [Reading Set 与普通文本](s2b-reading-surfaces.md) |
| S3 | `62a71f7` | [悬挂缩进与 Tab](s3-paragraph-layout.md) |
| EOF/硬换行恢复修正 | `eb5da4e` | [后续诊断](s3-anchor-followup.md) |
| 全局键盘路由修正 | 本记录所在提交 | 下节 |

## 功能验证

- S3 时点全仓分批完成 1005 项：沙箱中其他模块 866 项通过；AppTests 的 screen/sheet 环境失败后，正常桌面环境重跑 135 项及两个隔离批次各 2 项通过。随后新增 EOF、键盘两项，当前 CI 预期为主批 **1003**、隔离 **2+2**，共 **1007**。最终树未重新重复全部主批。
- EOF 与延迟恢复最终 11 项回归通过；应用级键盘路由 3 项通过。日志见 [anchor-tests.log](followup-checks/anchor-tests.log)、[keyboard-tests.log](followup-checks/keyboard-tests.log)。
- CI 功能段的静态检查、Exact/Diff/Reading/Projector/Fold 自测及 fixture 校验通过。实际执行保留 `ci.sh` 的四个 skip 和两隔离批次，未裸跑 `swift test`。
- Gold 内容段通过：Tokio 17 项、ripgrep 16 项；ripgrep 保留原有 3 个已知失败项。见 [gold-functional.log](followup-checks/gold-functional.log)。CI/Gold 的独立性能段尚未运行，不把内容段通过表述为完整脚本通过。

## 原生窗口

使用本地独立标识 `dev.cairn.WrapValidation` 的 App，最终 Debug 可执行文件经重新签名装入 `.build/wrap-validation/Cairn.app`。通过 Computer Use 操作实际菜单、文本、窗口和设置；25 张原始 JPEG 已按时间与 SHA-256 归档：[截图清单](native-windows/README.md)。

| 阅读面/行为 | 对应范围 | 本次证据 |
| --- | --- | --- |
| 主 Reader：长行、续行缩进、首行 gutter | W20/W21、W30/W33 的窗口补充 | [off](native-windows/01.jpg) / [on](native-windows/02.jpg) |
| Settings 为活动窗口，正文持有焦点 | W01/W02/W19 | [on](native-windows/08.jpg) / [off](native-windows/09.jpg)；切换后 AX 焦点仍在同一预览文本 |
| 普通文本创建/实时切换，正文焦点快捷键 | W39 | [off](native-windows/04.jpg) / [on](native-windows/05.jpg) / [正文焦点](native-windows/07.jpg) |
| Markdown 保持自身段落规则 | W40 | [全局 off](native-windows/10.jpg) / [全局 on](native-windows/11.jpg) |
| 点击真实调用点，Context 跟随并同步设置 | D5.7 | [on](native-windows/13.jpg) / [off](native-windows/14.jpg) |
| Relations → Freeze Results → Reading Set，24pt 卡片高度与尾行 | W35/W37/W38 的窗口补充 | [on](native-windows/17.jpg) / [off](native-windows/18.jpg)；多卡片/31卡与100次切换由自动化覆盖 |
| Git 历史对比两列 | D5.7、W20 | [on](native-windows/21.jpg) / [off](native-windows/22.jpg) |
| 从另一个项目切换后，后台对比两列同步 | W04 | [后台窗口同步](native-windows/23.jpg) |
| Structure 重投影与续行 fold chip 的真实点击 | W34 部分 | [折叠](native-windows/24.jpg) / [点击展开](native-windows/25.jpg) |

原生验收发现并修复了菜单单测遗漏的问题：Option-only 快捷键会被 NSTextView 的文本输入吞掉。现在由应用级 local key monitor 在 responder 分发前处理 ⌥Z，复用全局设置动作；重复按键不反复翻转，⌘Z 等其他组合不被消费。单测和实际 Settings/普通文本焦点复验均通过。

单项目 Git fixture 位于 `/var/folders/9k/7j3z072513z5hkf_xgcxzdzm0000gn/T/cairn-wrap-native-2oiky9bi`，含 F4 派生源码、F5 普通文本、Markdown 和两次历史提交。原工作目录因含多个 Rust project units 被现有 L3 V0 入口拒绝，未将其误判为 Wrap 回归。验收 App 已恢复 13pt/Wrap off 并退出；用户原有 `.zcodeignore` 未纳入提交。

## 尚未完成

1. **正式性能预算**：机器仍有浏览器/视频/其他桌面进程持续负载，遵守独占采集要求，未执行最终候选的 5 次预热 + 30 样本全矩阵。F3 off 的中间诊断约 1578ms，不能标记 1500ms 预算通过；见 [诊断与限制](s3-anchor-followup.md)。S1 旧 settled 指标只计首帧后等待，其错误 PASS 已在原证据中撤回。
2. **完整交互矩阵**：W05 关闭窗口压力、W16 连续缩放时主动打断、W22 Option-click 边界、W25 双 backing scale 尚无完整本轮原生记录。已有基础回归和本次截图不替代这些项目。
3. **最终完整门禁**：机器空闲后运行完整 CI/Gold（含 fold perf）及 Wrap perf。当前 Release 二进制曾用于诊断试验，正式采集前必须从最终提交重新构建，不能直接复用它。

```sh
CODEX_SANDBOX=1 bash scripts/ci.sh
CODEX_SANDBOX=1 bash scripts/run-gold-gates.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift build -c release --disable-sandbox --product codeinsight-app
bash scripts/run-wrap-perf.sh --binary .build/release/codeinsight-app \
  --out docs/plans/evidence/reader-wrap-v2/final-candidate \
  --enforce-budgets --baseline-dir docs/plans/evidence/reader-wrap-v2/s0-baseline
```

上述命令依次运行，不能与其他构建/测试或高负载任务并行。
