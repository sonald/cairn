# 遗留项继续修复（2026-09-09）

基线：1cc9da1。原生探针 bundle：`.build/reliability-ui-validation-next/Cairn.app`，id `dev.cairn.Cairn.ReliabilityUIValidationNext`。该构建包含 Palette 焦点修复；后续 store / bookmark 修复需使用最终重新构建复验。正式 `/Applications/Cairn.app` 未启动或修改。

## Quick Open 焦点

- RED 原生：重启旧隔离实例后 lib.rs/other.rs 点击正常；⌘P → lib.rs → Return 后点击 other.rs 无效。复现不依赖 provider 断开。
- 修复：Palette 关闭并显式恢复焦点时，激活 NSApp 并 makeKeyAndOrderFront(owner)。失去 key 的自动关闭路径不抢回焦点。
- GREEN 原生：全新 bundle 纯键盘 ⌘O → 原生 picker → 输入新 fixture → Return → 三语言全选 → Return → ⌘P → lib.rs → Return，然后点击 app.py 正常切换。
- 回归：dismissRestoresOwnerResponderBeforeOpening。注入旧实现后 owner.isVisible 断言 FAIL；修复后 PaletteTests 12/12 PASS。焦点测试与真实点击证据分别记录，不以窗口断言替代原生点击。

## 同项目演化内容保留

- RED：sameProjectRevisionsDoNotAccumulateInServiceStore，真实 Git 仓库连续20次修改、capture/prepare/complete，旧实现40断言失败，store累积到21份。
- 修复：每次新捕获替换服务持有的内存store；不再仅跨项目替换。已发布session保留其自身引用，已有持久索引缓存继续复用。没有新增淘汰器或缓存类型。
- 定向 GREEN：20轮保留恒为当前一份，原session仍能查到旧符号；项目边界与mixed边界检查通过。
- 完整门禁首轮发现提前构造持久缓存破坏 ambiguousAndNonGitFailBeforePersistentCache。已移除该额外改动，保持原有校验后建立磁盘缓存的时机；复核14项通过。完整门禁最终结果另记。
- 此修复关闭应用服务的同项目线性保留风险；直接复用底层ProjectIndexStore的测量探针仍体现其append语义，不将其冒充应用生命周期。

## Re-anchor 残留错误

- 原生 RED：创建gamma书签及中文笔记 → 外部前插中文行并重命名beta → Refresh Index → 书签显示Drifted → Open被拒绝 → Re-anchor成功，计数Exact content:1，但行仍显示旧Bookmark content has drifted。
- 修复：reanchorWorktree成功提交后 clearAttempt(for:id)，同时使旧异步尝试失效；冲突/拒绝不清除。
- 既有reanchor回归扩展先观察旧错误，再重新锚定并断言清除；旧实现此断言FAIL。最终门禁与原生复验另记。

## 已完成的原生子流程

完整 fixture：`/tmp/cairn-v0-complete-20260909`，Rust/Python/TypeScript，Rust alpha→beta/gamma调用链，两个Git提交；有效64×64 PNG、单页PDF、HTML、Unicode文本、Markdown列表与内链。资源fixture另有 `/tmp/cairn-v0-resource-{0,64,256}`（20 Rust文件+唯一4MiB非源码块）。

- 首开：新隔离Next实例通过纯键盘正常进入可读Rust；mixed三语言正确预选；鼠标切换Python成功。
- 一致性：外部修改后尚未重开时Reader保留原内容，旧索引定位与之匹配；关闭重开后显示中文前插行与renamed_beta。此时旧#beta激活被拒绝，出现File changed since indexing与Refresh Index。刷新后#renamed_beta为src/lib.rs:3:8，激活正确。
- Relations：beta的Callers为alpha/gamma且Verified；单击alpha得到Context源码，Pin后双击gamma导航到gamma中的beta调用点，Pin仍显示alpha。⇧⌘H查询光标beta符合合同，不能以作用域标题gamma误判。
- 预览：README无序/有序/嵌套列表正确；HTML内链显示HTML fixture/Local preview，脚本未执行；Back返回README；PNG内链显示蓝色图片；PDF内链显示Cairn PDF fixture；文本包含中文；源码返回后Reading Height和Context恢复。
- Freeze Results：真实按钮生成beta的两个Verified excerpts。Freeze Path：真实Trail选择gamma关系节点后按钮生成一个excerpt并明确skipped 1/no frozen evidence。
- 重启：正常⌘Q后进程退出；重新启动后Reading Set gamma恢复，Trail为空。Open File可回源码。另一beta Reading Set也在后续关闭源码标签后可见，证明两者恢复。
- 书签：View→Toggle Bookmark创建gamma，Show Bookmarks编辑V0 persistence note — 中文；刷新后Drifted，严格Open拒绝，Re-anchor显式绑定原行的新符号renamed_beta且笔记保留。
- 零写：从冻结结果前取基线到重启/创建书签后，正式App Support/dev.cairn.Cairn与完整fixture指纹均UNCHANGED。外部主动制造drift之后需重新取基线，不能计作应用写入。

## 尚需完成

最终构建原生复验；未打开/删除文件及Python/TS各自的内容一致性矩阵；Inspector与窗口四尺寸三主题；Trail完整兄弟分支/Restore/版本边界；Compare与版本零写；书签修复后的重启复验；资源冷热5次、p95至少20次及RSS原始采样。

CUA曾报告Mac锁屏、自动解锁失败，用户已回复解锁。Trail弹层截图左侧超出主窗口截图范围：需区分原生popover超出主窗口与真实屏幕裁切，尚不作为已确认产品缺陷修改。

公证：security find-identity -v -p codesigning仅有Apple Development，没有Developer ID Application。已请求用户安装证书/私钥并提供notary profile名称；没有密码写入文档。此项不能伪报公证完成。

## 后续补充

- Worktree→第一版commit：Rust beta为42；Compare第二版为43，Body · beta变更可见；返回Worktree恢复中文前插与renamed_beta。版本操作前后全部fixture文件（含.git/HEAD、index、objects）SHA-256映射一致，VERSION_ZERO_WRITE=True。
- Re-anchor后再执行严格Open成功，Reader定位原行的新符号renamed_beta，笔记保留。即刻旧错误文案的修复仍需最终bundle重放。
- 溢出菜单Version入口：900宽下点击没有出现版本面板；Zoom后直达Version按钮正常。实现改为菜单跟踪结束后异步显示transient popover，最终原生复验仍因再次锁屏等待。
- Reading内存自测：同环境HEAD基线也失败，regularFootprintMB=144.813；修复前后不能据此声称回归。设计§15仅规定空载100MB；已在openProject/扩大viewport之前取空载读数，保持加载后regular指标。最终自测idle=23.876MB且通过。锁屏、窗口backing与运行状态会影响绝对加载后读数，不把这次regular约40MB与前次144MB宣称为代码优化收益。
- Mac两次自动锁屏，第二次已请求再次解锁；签名配置仍待用户。最终原生矩阵未完成。

## 最终代码门禁

源码HEAD `306368c`；完整`CODEX_SANDBOX=1 bash scripts/ci.sh`退出0。893主测试+2隔离bookmark测试，Exact/Diff/Reading/Projector/Fold自测、release构建与fold perf完成。原始日志`final-gates-20260909.log.gz`。五个切片提交见acceptance.md。原生最终矩阵与公证仍未完成。
