# Cairn (CodeInsight) M4 交互测试规格（供 UI 自动化工具执行）

版本：对应 commit `97d8e6b`（M4 正式版 S1–S9 完成）。沿用 M1/M2/M3 规格的执行方式
与报告格式。本轮聚焦 M4 新功能：Safe/Trusted 双模式与信任 UI、Exact Provider
（rust-analyzer）原位升级、Relations Exact 组、跨 commit diff 阅读、历史 exact、
索引持久化秒开，外加 M3/M2 回归抽查。整体走 **M4 总验收 30 分钟弧线**：
Safe 开陌生仓 → fuzzy 阅读 → 授权 Trusted → exact 原位升级 → 切历史 commit →
Compare diff → 关闭重开秒开 → 撤销授权回 Safe。

## 前置条件

```sh
cd /Users/siancao/work/ai/vibecoding/codeinsight
swift build -c release
swift run -c release codeinsight-app
# Cmd+O 打开 ~/work/ai/oatmeal（254 commit 的真实 Rust 仓，含 Cargo.toml）
```

- 需本机装有 `rust-analyzer`（`/opt/homebrew/bin/rust-analyzer`）；未装则 exact 相关
  Gate 记 BLOCKED（不算 FAIL），fuzzy 路径仍须全绿。
- **首次 exact 有 workspace 预热**：rust-analyzer 首次加载 oatmeal 可能数十秒；期间
  fuzzy 必须全程可用、可读、可跳。exact 徽标是"到了才升级"，不是阻塞等待。

## 测试锚点（已核实）

- **跨文件 exact 锚点（不依赖外部 crate，Safe 离线也应解析）**：
  `src/domain/services/bubble.rs:14` 的 `use crate::domain::models::Author;`——
  `Author` 定义在 `src/domain/models/author.rs:8`（`pub enum Author`）。单击 `Author`
  应 fuzzy 命中 author.rs，exact 升级后置顶到 author.rs:8。
- **diff 锚点**：`src/domain/services/bubble.rs` 在 commit `03ae852`
  (perf 重构)前后内容不同。
- **历史 exact 锚点**：切到 `03ae852` 之前的某 commit，bubble.rs 的历史版本仍应能
  单击符号得 exact 落点（归因显示来自物化目录 / 该 commit）。
- M3/M2 锚点仍有效：bubble.rs 时间旅行、`Backend` trait impl、全文搜索等。

## 已知限制白名单（不算 FAIL，记录现象）

- **K-M4-1 Exact = Rust-only**：文件树只列 Rust；TS/Python 整语言面推 M5（design §16
  既成落差已确认）。
- **K-M4-2 真实签名/公证是人工项**：`bash scripts/make-app.sh` 产出 ad-hoc 签名
  bundle；真实 Developer ID + notarize + staple + Gatekeeper 需决策者机器操作，
  不在本自动化范围。
- **K-M4-3 沙箱后端**：`sandbox-exec` 已被 Apple 标记 deprecated；本机可用即走 OS
  边界。若某机沙箱不可用，Safe 下 exact 应**禁用并标注**（宁缺毋滥），不是静默降级。
- **K-M4-4 重命名不猜 lineage**：函数级摘要把重命名如实报 removed+added（F4.8 留 M5）。
- **K-M4-5 coverage.importsResolved** 恒不显示数字（诚实占位已删，只显示 Files X/Y）。
- 沿用 M3 白名单：K11 分支图未做（线性列表）；K7 Calls 外部边分组；K10 高扇入 Possible。

---

## G1 Safe 模式默认 + 信任状态可见（陌生仓第一观感）

| ID | 步骤 | 预期 |
|----|------|------|
| G1.1 | 打开 oatmeal（首次、未授权） | 默认进入 **Safe** 模式；某处（工具栏/状态栏）明确显示 "Safe" 信任态，不是静默 |
| G1.2 | 观察 exact 状态徽标 | 显示 exact 可用性（如 "Exact: …"）；Safe 下若已起 RA，应标覆盖为 **partial**（build script / proc-macro 缺席是覆盖缺口，不是"没找到"） |
| G1.3 | fuzzy 阅读：单击 bubble.rs:14 的 `Author` | Context 底部窗**立即**出 fuzzy 候选（author.rs），provenance 非 Exact；无需等待 RA |
| G1.4 | Safe 态浏览、滚动、Cmd+Shift+F 搜索 | 全程可读可用，不被 exact 阻塞 |

## G2 Exact 原位升级（M4 核心观感）

| ID | 步骤 | 预期 |
|----|------|------|
| G2.1 | 停在 G1.3 的 Context，等待 RA 就绪（可能数十秒，观察 exact 徽标转为可用） | fuzzy 结果**先在**，exact 就绪后**原位升级**：目标置顶 + 出现 "Exact" 徽标/provenance；**不闪不跳**，阅读区落点不乱动 |
| G2.2 | 对比升级前后候选列表 | **fuzzy 候选全保留**（exact 只是置顶+升级标注，不清空其它候选） |
| G2.3 | 单击 `Author` 跳转（Cmd+单击或双击按你们既有约定） | 跳到 author.rs 的 `pub enum Author`（exact 落点正确，行号对） |
| G2.4 | Pin 住当前 Context（钉住），再 Cmd+单击别处符号 | 主区跳转，**底部保持钉住内容**；钉住目标自身若 exact 就绪可就地升级标注，但不换内容（F2.3 裁决） |

## G3 Relations Exact 组 + 覆盖诚实

| ID | 步骤 | 预期 |
|----|------|------|
| G3.1 | 对 `Author`（或某函数）右键 Show Relations（Callers/Calls） | 右侧关系树出现；**Exact 组**在 RA 就绪后有真内容，组头**不再是 "(0)"** |
| G3.2 | 观察状态栏/组内 | 含 exact 字样；边的 fuzzy 目标与 exact definition 一致者升入 Exact 组 |
| G3.3 | 全程找"假进度" | 不得出现 "resolving imports N%" 之类**编造的精确进度**；只允许 Files X/Y 或明确 building 占位 |

## G4 授权 Trusted → 覆盖变化 → 撤销回 Safe

| ID | 步骤 | 预期 |
|----|------|------|
| G4.1 | 触发授权（工具栏 Trust 按钮 / 提示） | 弹出 Trust sheet，**明文写后果**（放宽到可执行 build script / proc-macro，但 network 恒 deny + 离线）；有明确"授权/取消" |
| G4.2 | 确认授权为 Trusted | 信任态变 Trusted；exact session 立即重建；覆盖状态从 partial 趋向完整（build script / proc-macro 派生符号可解析——在依赖它们的符号上可感知差异） |
| G4.3 | 打开设置 → Trust 页 | 列出已授权仓库（路径、授权时间），有**撤销**入口 |
| G4.4 | 撤销 oatmeal 授权 | **立即回 Safe**；exact session 重建为 Safe 形态；覆盖回落 partial。无需重开 app |
| G4.5 | 全程网络 | Trusted 也**从不联网**（无外发请求）；离线依赖缺失只应表现为 coverage 降级标注，不是报错、不是卡死 |

## G5 跨 commit diff 阅读（S6）

| ID | 步骤 | 预期 |
|----|------|------|
| G5.1 | 切 Compare 预设（Cmd+3 或 View 菜单），左侧开 bubble.rs（Working Tree） | 右侧出现版本选择；选 `03ae852`（或其父） |
| G5.2 | 右侧加载该 commit 的 bubble.rs | 右 reader 显示的是**该 commit 的 blob 内容**，与左侧 Working Tree 版本**不同**（内容非磁盘当前版） |
| G5.3 | 观察 gutter（行号槽）配色 | 增/删/改三类有可读的**三主题配色**；计数与实际差异一致 |
| G5.4 | hunk 导航（下一个/上一个变更块） | 视图**实际跳到**下一变更块；导航位置可见 |
| G5.5 | 函数级摘要条 | 报 added/removed/signatureChanged/bodyChanged；若有重命名，如实 removed+added（不猜 lineage，K-M4-4） |
| G5.6 | 切回 Reading 预设（Cmd+1） | 右侧对比栏收起；右侧那份独立 commit 快照被清理（不残留、不串主快照） |

## G6 历史 exact（S7，可能 BLOCKED）

| ID | 步骤 | 预期 |
|----|------|------|
| G6.1 | 用 commit 切换器切到 `03ae852` 之前某 commit | 时间旅行正确（bubble.rs 显示历史版本，M3 底线回归） |
| G6.2 | 历史态单击 bubble.rs 里一个跨文件符号，等 exact | exact 落点正确（对应**该历史版本**行号，不是 Working Tree 行号）；归因显示来源为**物化目录 / 该 commit**（非 worktree） |
| G6.3 | 若历史 commit 依赖离线不可得 | 如实标 `coverage: deps unavailable (offline)`——降级不是错误；**绝不联网** |
| — | 说明 | S7 标注"可裁剪"；若历史 exact 未启用，记 BLOCKED 并注明"Exact 保持 worktree-only"，**不算 M4 失败** |

## G7 索引持久化秒开（S5）

| ID | 步骤 | 预期 |
|----|------|------|
| G7.1 | 完整索引 oatmeal 后 Cmd+Q，再重开并打开 oatmeal | 第二次**明显更快就绪**（复用磁盘缓存，extracted≈0）；文件树/阅读秒出 |
| G7.2 | 阅读/跳转/Context 语义操作 | 与首次一致（复用不改变解析结果——determinism） |
| G7.3 | （可选）删 `~/Library/Application Support/CodeInsight/index-cache` 后重开 | 回到冷启动耗时（证明确实走缓存而非别的） |

## G8 M3/M2/M1 回归抽查

| ID | 步骤 | 预期 |
|----|------|------|
| G8.1 | Working Tree 态 Show Callers/Calls/Implements（backend.rs 的 Backend） | 关系树正常，impl strong（M2 回归）；Calls 外部边有 External/Unresolved 分组（M3） |
| G8.2 | 切多个 commit + 跨版本后退/前进 | 时间旅行 + 浏览器历史三者一致（阅读区/版本/文件树同步，M3 G4 回归） |
| G8.3 | 设置改行距/字号/主题（SI Classic），退出重开 | 即时生效且保留（M3 G5 回归） |
| G8.4 | 单击 use super::Bubble 的 Bubble | Context → bubble.rs strong（M2 回归） |

## G9 稳定性

| ID | 步骤 | 预期 |
|----|------|------|
| G9.1 | 8 分钟混合：Safe↔Trusted 切换、exact 升级、切多 commit、Compare diff、持久化重开、关系/搜索、预设切换 | 无崩溃、无 beachball、无内容错乱（显示内容与当前快照+文件名+信任态一致）；RA 崩溃只应退避重启一次后标 unavailable，**绝不拖垮 fuzzy** |
| G9.2 | Cmd+Q | 正常退出（RA 子进程被 graceful close，必要时强杀兜底，不留孤儿进程） |

## 报告格式

同 M1/M2/M3：`ID | PASS/FAIL/BLOCKED | 备注`。FAIL 附截图与复现步骤。

**M4 底线**：
1. **Safe 绝不越界**——未授权时 exact 走沙箱（项目只读、deny network），不执行
   build script（G1/G4）。任何"未授权却跑了 build.rs / 联网"都是 FAIL。
2. **Exact 不覆盖 fuzzy**——升级是就地增强，fuzzy 候选全留（G2.2）。任何"exact 就绪
   后 fuzzy 消失/内容闪跳"都是 FAIL。
3. **诚实**——不显示编造的精确进度（G3.3）；覆盖缺口如实标 partial / offline。
4. **时间旅行正确性**（M3 底线延续）——历史态显示/落点必须是历史版本（G5.2/G6.2）。
