# 最终验收记录 — 2026-09-05 可靠性与阅读 UI 修复计划

更新：2026-09-09。实施基线 `ac18460` → 上轮记录 `1cc9da1`；本轮源码验收HEAD `306368c`。切片提交：`cf592cc`（焦点）、`fe7d22d`（store寿命）、`fdc966a`（书签错误）、`f3151a9`（版本溢出入口）、`306368c`（空载测量）。最终隔离构建：`.build/reliability-ui-final/Cairn.app`，bundle id `dev.cairn.Cairn.ReliabilityUIValidationNext`，ad-hoc签名，尚未公证。

## 总结论：部分完成

不能声明全部遗留问题已关闭。旧屏幕录制/AX权限拒绝已经解除；本轮已完成多项真实流程、修复3个确认问题，另有版本溢出菜单修复待原生复验。Mac随后两次自动锁屏，最终完整原生矩阵尚未完成；公证缺少Developer ID Application证书。各项当前状态如下，旧运行的BLOCKED原因不再作为当前状态。

详细过程：[本轮修复与原生证据](residual-fixes-20260909.md)、[资源测量](resource-rerun-20260909.md)、[前一次EOF原生重跑](v0-rerun-20260909.md)。S0–S11原实施证据保留在同目录`s*.md`，不撤销既有功能约束。

## 本轮修复

| 项目 | 当前结果 | 证据 |
|---|---|---|
| Quick Open关闭后鼠标/键盘无响应 | 已修复，原生与回归通过 | 最小复现不依赖provider；恢复应用激活与主窗口；旧实现故障注入FAIL，PaletteTests 12 PASS |
| 同项目演化内容线性保留 | 已修复，服务级回归通过 | 20次真实Git修订，旧实现累积21份/40断言失败，新实现每轮1份；旧会话仍可查询。保留原校验后建立磁盘缓存的时机 |
| Re-anchor成功仍显示旧漂移错误 | 已修复，最终原生复验待完成 | 真实UI确认；成功提交后清除该书签旧尝试，旧实现回归FAIL；既有严格锚点语义不变 |
| 窄窗口版本溢出菜单不打开面板 | 修复待原生复验 | 延后至菜单结束跟踪后展示transient popover；宽窗口直达入口可用 |
| Reading自测误用空载预算 | 测量口径已修正，最终门禁PASS | HEAD基线和修复版加载后均约144.8MB；设计§15的100MB适用于空载。现在在打开项目前检查空载，加载后内存继续原值报告，阈值不变 |

## V0 当前逐步骤状态

| 步骤 | 状态 | 已验证 / 尚缺 |
|---|---|---|
| 1 首次打开（鼠标+键盘） | 部分，主要流程PASS | 新隔离Next构建纯键盘picker→mixed预选→Quick Open→Rust可读，随后鼠标切Python成功；最终构建复验尚缺 |
| 2 CPU生命周期 | PASS（已记录构建） | 仅终止测试provider后CPU 0.0%，5秒sample主线程4133/4134停在事件等待，零handler帧；Quick Open仍可阅读。后续未修改EOF实现 |
| 3 内容一致性 | 部分 | mixed项目Rust前插中文/改名→关闭重开→旧搜索拒绝→Refresh→新符号第3行定位PASS；未打开/删除文件及Python、TypeScript各自完整矩阵尚缺 |
| 4 关系与Pin | 部分 | beta Callers为alpha/gamma，Verified；Pin alpha后关系导航与快捷键查询光标beta，Pin保持。Inspector及四尺寸往返尚缺 |
| 5 版本与Compare | 主要流程PASS，窄入口待复验 | 第一版42↔第二版43，beta body diff可见；返回Worktree显示外部修改。操作前后HEAD/index/全部文件含.git指纹完全一致。窄窗口溢出菜单修复待复验 |
| 6 预览往返 | 部分 | Markdown列表/内链→HTML（脚本未执行）/有效PNG/PDF/Unicode文本→源码，Reading Height/Context恢复；Back回README。外链/本地资源策略及完整Back/Forward矩阵尚缺 |
| 7 阅读证据 | 部分 | 真实Freeze Results与Freeze Path创建两份Reading Set；正常Quit/重启均恢复，Trail为空。完整兄弟分支、Restore与版本边界矩阵尚缺 |
| 8 书签与笔记 | 部分 | 创建中文笔记→Drifted→严格Open拒绝→显式Re-anchor→严格Open成功；旧错误残留已修复。最终构建重启/即时文案复验尚缺 |
| 9 视觉/AX | 部分 | 900宽Light和原生Zoom大窗口已检查；Markdown、预览、Reader可见。四个精确内容尺寸×Light/Dark/SI Classic完整矩阵尚缺；Trail超出主窗口截图边界需区分截图裁切与屏幕裁切，尚非确认缺陷 |
| 10 资源 | 自测矩阵PASS，原生回收部分 | 0/64/256MiB各5次冷索引+20次暖索引共75次，均PASS；暖first-paint p95为6.4/162.2/661.3ms。峰值RSS最高357.1MiB。GUI常驻/关闭Compare、tabs后的回收及固定A/B原生20轮尚缺 |

## 原延期项逐项处置

1. V0交互：从旧权限BLOCKED更新为以上实际子项；剩余矩阵不能用单元测试或模型通道替代。
2. EOF与RSS：EOF半步已关闭；75次进程外资源测量已保存，GUI回收矩阵仍待完成。
3. S1 bundle CPU：断开场景已实测，见`v0-eof-rerun.sample.txt.gz`，不再仅引用空载采样。
4. S8 Reader token：未发现对应问题，按原计划不作无需求的样式更改；此项为不适用，不是隐藏的未实施修复。
5. 同项目演化保留：应用服务生命周期已修复并有20轮回归；不新增淘汰器/引用计数，不影响已发布旧session。
6. 签名公证：BLOCKED。本机只存在Apple Development证书；缺Developer ID Application证书/私钥及notary配置。已请求用户在本机配置，未索取或写入密码。

## 门禁与保护边界

- 本轮完整swift test已通过893主测试+2隔离bookmark测试，共895；隔离契约未改变，新增2个测试已同步计数。
- 首轮缓存时机回归已发现并修正，定向14项复核PASS。
- Reading加载后内存检查在HEAD基线也失败，原始对照日志保留；实际空载检查修正后的最终完整门禁**PASS**（退出码0）：893主测试+2隔离测试，Exact/Diff/Reading/Projector/Fold自测，release构建与fold perf全部完成。Reading实测空载23.876MB。原始日志见`final-gates-20260909.log.gz`。这不替代V0交互矩阵。
- 正式`/Applications/Cairn.app`未启动或修改；正式App Support指纹校验不变。未改`.claude-trace/`或`docs/reviews/`。
- 原始fixture `/tmp/cairn-v0-fixture`保留；新增完整fixture `/tmp/cairn-v0-complete-20260909`。外部主动制造的drift已与版本零写测量分段取基线。

## 复现

```bash
CODEX_SANDBOX=1 bash scripts/ci.sh
CODEX_SANDBOX=1 bash scripts/make-app.sh --output .build/reliability-ui-final --bundle-id dev.cairn.Cairn.ReliabilityUIValidationNext
```

原生步骤按计划§6逐项执行。最终构建需要手动解锁的Mac；公证另外需要用户提供本机签名身份与notary profile。不得把上述未完成子项改为PASS。
