# 最终验收记录 — 可靠性与阅读 UI 修复

更新：2026-09-10。源码验收 HEAD：`8d0cc82`。最终隔离构建：`.build/reliability-ui-verified-20260910/Cairn.app`，bundle id `dev.cairn.Cairn.ReliabilityUIVerified20260910`，ad-hoc签名。**公证按用户2026-09-10指示移出本次范围，不再作为阻塞。**

## 结论：约定范围验收通过

S0–S11实施已完成；V0原生验收已补齐。早期权限/锁屏阻塞为历史状态，本次未再以其代替验收。过程中的工具路由歧义和失败重试均保留在证据中；最终新UI修复使用唯一bundle id验证，未预写session替代真实操作。

[2026-09-10原生详细记录](native-acceptance-20260910.md) · [资源矩阵](resource-rerun-20260909.md) · [前轮修复证据](residual-fixes-20260909.md)。原S0–S11证据仍在同目录`s*.md`。

## 补充修复与提交

| 修复 | 提交 | 验证 |
|---|---|---|
| Quick Open退出后恢复应用/主窗口焦点 | cf592cc | 原生复现→修复；旧实现故障注入FAIL，回归PASS |
| 同项目不同修订不再累积于服务store | fe7d22d | 20修订旧实现累积21份，新实现每轮仅当前1份，旧session仍可查询 |
| Re-anchor清除旧失败信息和旧异步尝试 | fdc966a | 原生漂移拒绝→显式重锚→即时Exact content，中文笔记保留，重启恢复 |
| 版本溢出菜单退场与可见锚点 | f3151a9 / 00856cb | 最终900宽弹层可见，AX包含Search commits和两个提交 |
| 按设计分别测量空载与加载后内存 | 306368c | 100MB阈值未提高；空载实测、加载后指标均保留；完整门禁PASS |
| Relations标题栏两行布局、自然按钮宽度 | 6d45bee | 旧104/82pt容不下128/98pt标签；300pt回归RED→GREEN，900宽原生可读 |
| Trail快捷键打开后聚焦节点表 | b5fafcc | 无鼠标补焦点，方向键可选gamma并冻结路径 |
| 接入真实resize通知并按窗口实际容量适配 | 8d0cc82 | 旧代码漏NSWindowDelegate且使用过渡split宽度；回归RED→GREEN，最终1600→900实拖保持Reader/Inspector/Pin |

## V0 逐项结果

| 步骤 | 结果 | 证据摘要 |
|---|---|---|
| 1 首次打开（鼠标+键盘） | PASS | 全新唯一实例：键盘原生picker→mixed预选→Quick Open→源码；最终实例welcome按钮→picker→语言Open→目录展开→源码 |
| 2 CPU生命周期 | PASS | 仅终止已识别测试provider后CPU 0.0%；5秒sample主线程4133/4134在事件等待、零handler帧；Reader继续可用。EOF实现后续未变 |
| 3 内容一致性 | PASS | Rust中文前插/改名、重开、旧搜索拒绝、Refresh新定位；未打开Python/TS的旧结果拒绝、刷新正确定位；删除TS旧结果拒绝；Rust/Python/TS单语言及mixed入口均实测 |
| 4 关系与Pin | PASS | Reader目标查询与Pin独立；Inspector开关保持选中；最终宽→900内容区，侧栏退场、alpha Inspector和Pin保持；⌘I重新打开不撑窗 |
| 5 版本与Compare | PASS | 第一版42、第二版43、beta body diff、返回Worktree；HEAD/index/全部fixture文件指纹一致；窄窗口版本入口最终复验通过 |
| 6 预览往返 | PASS | HTML/PNG/PDF/Unicode文本/Markdown的Back/Forward与源码控件恢复；列表和真实图片/PDF已查看；脚本、外链和越界本地资源策略实测 |
| 7 阅读证据 | PASS | alpha/gamma兄弟分支、Restore、Worktree→commit snapshot boundary；不可用旧快照明确跳过；最终真实冻结2摘录与1摘录，正常Quit/重启恢复且Trail为空 |
| 8 书签与笔记 | PASS | 创建中文笔记、漂移拒绝、显式Re-anchor、即时清除旧错误、严格打开与重启恢复；严格锚点语义未放宽 |
| 9 视觉/AX | PASS | 四内容尺寸×Light/Dark/SI Classic的Reader矩阵；宽度偏差校正后重验；长项目/环境信息、焦点和完整AX；新增标题栏及最终resize在900宽专项复验 |
| 10 资源 | PASS | 0/64/256MiB各5次冷索引+20次暖索引共75次；另原生A/B20轮、256MiB五次与返回小项目的RSS/heap/vmmap采样；活跃内容与分配器留存分开报告 |

上述场景按职责覆盖，并未将模型自测冒充鼠标首屏计时。12格Reader图像与新增UI专项分开记录；较大JPEG是工具缩放图，不以非空像素或图像像素数替代功能/窗口点数验证。原生截图保留在本任务CUA记录，结构化尺寸与时间点随证据提交。

## 资源结论与实际限制

- 暖索引first-paint p95：0/64/256MiB分别 **6.4 / 162.2 / 661.3ms**，均低于1秒；进程外峰值RSS最高约357.1MiB。这是既有应用快照自测通道，编译不计入。
- 原生A/B后半程RSS约244.2–245.6MiB，未随轮次线性增长。256MiB阶段RSS峰值约442.5MiB，回小项目后约441.4MiB。
- 回收后活跃malloc约50MiB、最大活跃块640KiB；vmmap明确显示144.6MiB `MALLOC_LARGE (empty)`。高RSS不等于仍持有旧256MiB源内容，也不将全部RSS归因于分配器。
- provider不可用时结果保持Inferred并显示限制；未将降级结果伪报Verified。旧Worktree快照不可用时Freeze明确跳过，未借用当前源码。
- S8 Reader token没有对应缺陷，按原计划不作无需求样式改动。底层显式复用ProjectIndexStore的append语义保留，应用服务通过生命周期边界避免累积。

## 门禁与保护边界

`CODEX_SANDBOX=1 bash scripts/ci.sh` **PASS，退出码0**：895主测试+2隔离bookmark测试，共897；Exact/Diff/Reading/Projector/Fold自测、release构建、fold perf完成。原始日志`final-gates-20260910.log.gz`。新增2个本轮回归已同步计数；两项bookmark隔离契约不变。

正式`/Applications/Cairn.app`未操作，正式App Support及fixture分段指纹保持不变（受控外部改动单独计入）。原fixture `/tmp/cairn-v0-fixture`未改；新增测试数据在`/tmp/cairn-v0-complete-20260909`及资源fixture目录。未改`.claude-trace/`和`docs/reviews/`，未推送或发布。最终测试实例已正常退出。

## 复现

```bash
CODEX_SANDBOX=1 bash scripts/ci.sh
CODEX_SANDBOX=1 bash scripts/make-app.sh --output .build/reliability-ui-verified-20260910 --bundle-id dev.cairn.Cairn.ReliabilityUIVerified20260910
```

同一时刻仅运行一个验收实例；更换构建先正常Quit并验证进程退出，UI辅助函数显式接收应用对象。原生清单仍以计划§6为准。
