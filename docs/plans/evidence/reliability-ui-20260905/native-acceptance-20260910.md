# 原生验收续跑 — 2026-09-10

## 范围与构建

用户已将公证明确移出本次范围。构建仍为ad-hoc签名，不把公证作为阻塞。

早期资源采样明确绑定`.build/reliability-ui-final/Cairn.app`的PID 27751。之后发现多个测试副本复用了bundle id，加上辅助函数保留旧应用引用，可能路由到旧实例；已清理旧测试进程，后续辅助函数显式接收应用对象。关键新UI修复使用全新唯一ID复验：

- `.build/reliability-ui-unique-20260910/Cairn.app` / `dev.cairn.Cairn.ReliabilityUIValidation20260910`：全新键盘首开、最新标题栏、资源策略、预览往返。
- `.build/reliability-ui-verified-20260910/Cairn.app` / `dev.cairn.Cairn.ReliabilityUIVerified20260910`：全新鼠标首开、Trail键盘焦点、非空冻结和正常Quit/重启恢复、单语言入口。

未预写session代替操作。正式`/Applications/Cairn.app`未操作，正式App Support与fixture的分段指纹一致。首次CUA应用发现曾耗时数分钟，该工具调用时间不当作应用冷启动指标。

## 真实流程

- 全新键盘首开：⌘O→原生picker→目录→三语言正确预选→⌘P→lib.rs。全新鼠标首开：welcome Open Project→原生picker→Open→语言Open→disclosure→lib.rs。源码正确可读。
- mixed一致性：Rust前插中文/改名后关闭重开，旧结果拒绝，Refresh后第3行正确。未打开的Python/TS旧结果都被拒绝；刷新后Python新符号第5行、TS第3行。关闭并删除TS文件后旧结果拒绝；已还原测试文件。
- 单语言入口：Open Python Project、Open TypeScript Project及只选Rust的Open Project，分别正确定位python_renamed（app.py:5）、typescript_renamed（app.ts:3）、renamed_beta（lib.rs:3）；最后重新选三语言，mixed定位正确。
- Pin/Inspector：Reader声明查询得到alpha/gamma；Pin alpha，打开和关闭Inspector保留alpha选中及Pin。原生900宽已检查最新两行标题栏，全部方向标签与两个操作按钮可读，Inspector完整AX正文可滚动。
- Trail：真实关系导航alpha→Back→在Reader明确选择声明→gamma，图中显示alpha/gamma兄弟分支与Branches·1；Restore alpha回到对应源码。跨到commit 20913d6并导航后，图中同时有Worktree节点、commit节点和snapshot boundary。
- 快照诚实性：在commit上冻结不可用旧Worktree路径时，明确显示recorded worktree snapshot is unavailable，不挪用当前源码。最终唯一构建在当前可用快照中Freeze Results得到2个摘录，Freeze Path得到1个摘录（另外2个无证据节点明确跳过）。冷启动时Exact会话不可用的结果保留Inferred标记，没有冒充Verified；后续重开mixed后实际得到Verified。
- 最终Trail焦点：仅⌥⌘T打开，直接Down/Down就从既有选中节点到gamma，无需点击表格补焦点；Freeze Path成功。正常Quit并以ps确认退出，重启后gamma的1个摘录和renamed_beta的2个摘录均恢复，Trail为空。
- 书签：中文笔记重启恢复；受控改动后Drifted，严格Open拒绝，显式Re-anchor后立即显示Exact content并保留笔记；重新启动后正确恢复。即时错误清除在包含fdc966a的最终构建实测。
- 版本/Compare：第一版42、第二版43与beta Body diff、回到Worktree的改动源码；操作前后包含.git的完整文件哈希一致。
- 预览：HTML、PNG、PDF、Unicode文本、Markdown分别经过Back/Forward回到预览再回源码，阅读高度与Context/Relations恢复；真实图片/PDF与列表已查看。
- HTML策略：脚本未执行，越界本地SVG未加载；外链和本地文件链接点击后仍是原HTML，未出现测试URL浏览器标签，也无新应用启动。探针HTML已还原，fixture与正式App Support指纹均UNCHANGED。

## 视觉与资源

12格Reader主题/尺寸见`theme-matrix-20260910.json`及本任务CUA图像：900×600、1000×700、1280×820、1440×900，Light/Dark/SI Classic。大图为工具缩放图，不把JPEG像素误作窗口点数；小尺寸从未缩放基准校准，较大宽度同时核对AX布局宽度。窗口超出物理屏幕时先Zoom再缩小，之后完整查看，未以裁切图代替验证。新增Relations两行条另在唯一实例900宽专项复验。

原生资源：20轮A/B共40次项目打开，另256MiB五次打开后返回小项目。项目和文件树逐次验证；前14次额外验证源码，后续资源循环不重复Quick Open。两次入口重试/未完成的额外源码检查保留在端点说明中，不伪造计时。时间点见`native-resource-endpoints-20260910.json`，原始RSS CSV、sample、heap、vmmap均压缩保存。

- A/B后半段RSS约244.2–245.6MiB，未随轮次线性增长。
- 256MiB阶段RSS峰值约442.5MiB，返回小项目后约441.4MiB；CPU为0，主线程事件等待。
- heap活跃malloc约50MiB，最大活跃块640KiB；vmmap明确列出144.6MiB `MALLOC_LARGE (empty)`。因此不能把高RSS当作仍持有256MiB活跃源内容，也不将全部RSS都归因于分配器。语义store生命周期另有20修订回归。
- 75次冷/暖索引进程测量见`resource-rerun-20260909.md`；warm p95分别6.4/162.2/661.3ms，均低于1秒。

## 本轮新增修复

1. 版本溢出入口使用可见Symbols作为锚点，避免以整个内容区定位；分步等待菜单退场后900宽面板完整可读。额外Return会选择默认项并关闭，不属于打开步骤。
2. Relations按钮自然宽度128/98pt曾被限制为104/82pt，回归RED；改为两行及自然宽度，300pt单测和900宽原生GREEN。
3. Trail显示后聚焦节点表，沿用已有版本面板的聚焦时机。原生快捷键+方向键GREEN。
4. `windowDidResize`原来未接入NSWindowDelegate。回归不手动render，原实现侧栏不折叠、Reader仅320pt。接线并以实际窗口内容区限制过渡split宽度（探针观测window900/split1069），避免误判；Reading Set聚焦布局受到保护。四项针对性回归GREEN。最终原生resize复验和整套门禁完成后更新acceptance.md。

## 最终闭环

源码HEAD `8d0cc82`，最终包`.build/reliability-ui-verified-20260910/Cairn.app`，id `dev.cairn.Cairn.ReliabilityUIVerified20260910`。完整门禁PASS：895主测试+2隔离bookmark测试，共897；Exact/Diff/Reading/Projector/Fold、release与fold perf全部完成。原始日志`final-gates-20260910.log.gz`。

最终实机resize：从1600宽带alpha Inspector及Pin状态拖到900×652窗口帧（900×600内容区），AX确认侧栏退场、Inspector alpha及Pin保持。关闭Relations后⌘I重新打开，窗口仍900×652；版本溢出菜单能显示Search commits及两个提交。使用窗口直边拖动，避免圆角不命中。测试实例正常Quit并以ps确认退出。

四个提交：`00856cb`版本锚点，`6d45bee`标题栏，`b5fafcc`Trail焦点，`8d0cc82`真实resize接线/窗口容量/Reading Set保护。未遗留临时DEBUG探针。公证按用户明确要求不在范围内。
