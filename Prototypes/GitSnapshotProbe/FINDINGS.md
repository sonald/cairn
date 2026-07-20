# GitSnapshotProbe findings

## 原型问题与范围

这个可抛弃原型只回答三件事：libgit2 能否直接提供不可变 commit/worktree
字节源，相邻 commit 的 `ContentIndex` 能复用多少，以及 generation 是否足以阻止
旧查询覆盖新快照。测试仓库为 CodeInsight 当前 3-commit SHA-1 仓库；索引复用只统计
`RustExtractor` 能处理的 `.rs` 文件，包括 `Tests/Fixtures`。

环境：macOS，Swift 6，libgit2 1.9.6（Homebrew
`/opt/homebrew/opt/libgit2`）。下列数字是 2026-07-20 的 debug build 单次实跑，
用于验证可行性，不是稳定 benchmark。

## 实跑结果

### CommitSnapshot

```text
$ swift run gitprobe snapshot /Users/siancao/work/ai/vibecoding/codeinsight
.gitignore  e50cc11e0e395546f712240c137c3484251d9206
Package.resolved  a24e48a32ea8f7c994a712f1265ba1b3104a374e
Package.swift  d9c0784f627043ddc6821752480cd4962f7df491
... 135 more path -> blob OID rows ...
files=138 tree_walk_ms=3.792 blob_read_ms=37.155 blob_bytes=7534875
```

`git_tree_walk` 回调在 OID 指针仍有效时立刻转成不定长 hex 字符串；读取时通过
libgit2 OID API 查 blob，再从 `git_blob_rawcontent` 复制原始字节。没有读取 worktree。

### WorktreeSnapshot

```text
$ swift run gitprobe capture /Users/siancao/work/ai/vibecoding/codeinsight
files=152 clean_tracked=136 copied=16 copied_bytes=78861 capture_ms=1257.373
```

clean tracked 文件只保留 index blob OID；dirty/untracked 文件在捕获时读取一次，按主包
`ContentID.sha256` 写入临时 content store。忽略文件不进入快照。自动测试先捕获一个
dirty tracked 文件，再通过 `FileManager` 改写实时文件，快照仍返回捕获时字节。
这版为缩小 spike 使用逐文件 `git_status_file`，152 文件已耗时 1.257 s，不适合作为
正式扫描路径；生产实现应一次建立 `git_status_list`，再与 index/filesystem 合并遍历。

### HEAD -> HEAD~1 索引复用

```text
$ swift run gitprobe switch /Users/siancao/work/ai/vibecoding/codeinsight
head_files=30 target_files=30 cache_hits=30 new_extractions=0 hit_rate=100.0% switch_ms=27.718
assertion: hit_rate > 80%: PASS
```

HEAD 先按 `(ContentID, rust mode, grammar version, extractor version)` 建
`ContentIndex` 缓存；HEAD~1 只对未命中的 key 调用 `RustExtractor`。当前相邻 commit
没有改动 `.rs` 文件，因此 30/30 命中。保留题设的严格 `> 80%` 断言，无需下调。
`switch_ms` 从打开/遍历 HEAD~1 开始，包含该 commit 的 blob 读取、缓存查找和必要提取，
不包含预热 HEAD。

### generation

async 测试给 A 查询保存 generation 0 并人为 sleep，随后切换 B、generation 变为 1。
A 返回时 `publish` 因 token 过期返回 false，最终展示状态断言为 B。generation 解决
跨快照结果串线；它不替代 worktree 字节固化。

## libgit2 Swift 接入结论

- SwiftPM `systemLibrary` 通过 `module.modulemap` 的 `git2.h` shim 和
  `pkgConfig: "libgit2"` 接入 Homebrew 的 `.pc` 搜索路径，不新增 wrapper dependency。
- repo、object、peeled commit、tree、blob、index 都有不同释放函数。tree callback
  给出的 entry/OID 是借用指针，不能逃出回调；原型只复制 path 和 OID 文本。
- C callback 不能捕获 Swift 上下文。`git_tree_walk` 的同步调用用
  `Unmanaged.passUnretained` 传 collector，并保证 collector 覆盖整个 walk 生命周期。
- Homebrew dylib 在本机产生“built for newer macOS 26.0”的链接警告；当前机器运行正常，
  但 macOS 14 部署前必须换用以 14 为 deployment target 构建的 libgit2 artifact。
- 当前安装的 libgit2 headers 未启用 `GIT_EXPERIMENTAL_SHA256`。原型用 `git_oid` 与
  `git_oid_tostr_s`，没有假定 20 bytes 或 40 hex chars；本仓库确认是 SHA-1，
  SHA-256 仓库仍待用支持该 object format 的 libgit2 build 实测。

## 对 design §6 的修正建议

1. manifest 应直接保存不可变 locator；`SourceProvider.open` 接收这个 locator 即可。
   设计稿同时出现 `SourceLocator` 与未定义职责的 `SourceHandle`，原型没有发现需要两层
   identity。先改成 `open(_ locator: SourceLocator)`；只有 mmap/stream 确实需要显式生命周期
   时再引入 handle。
2. provider 不应接收实时 path，也不负责 generation。worktree 捕获阶段把 clean 文件变成
   Git blob locator、其余文件变成 content-store locator；查询协调层在 await 边界检查
   generation。这样“内部不漂移”和“结果不串线”各由一处负责。
3. 当前 `ProjectIndexer.index(root:)` 只会重读实时文件，不能消费 commit snapshot。
   正式路径应让 Engine 接收 manifest + provider 提供的字节，再调用 extractor；不要为
   Git 历史创建临时 checkout。这个 spike 因而直接复用了主包 `ContentID`、
   `ContentIndex` 和 `RustExtractor`。
4. design 写统一 BLAKE3，而当前主包 `ContentID` 只有 SHA-256。正式实现前应二选一并让
   `ContentID.algorithm` 成为持久化格式的一部分；Git OID 只作 locator，不能冒充统一
   ContentID。

## 验收

```text
$ swift build
Build complete!

$ swift test
Executed 2 tests, with 0 failures (0 unexpected)
```

受执行沙箱限制，记录三次实跑时额外给 SwiftPM 使用了 `--disable-sandbox` 并把 module
cache 指到 `/tmp`；生成的 `gitprobe` 及参数与上面命令相同，原型本身不依赖这些设置。
