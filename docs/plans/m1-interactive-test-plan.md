# CodeInsight M1 交互测试规格（供 UI 自动化工具执行）

版本：对应 commit `f961d15`。每个测试点标注 ID、操作步骤、预期结果。
执行结果按"报告格式"节回传。

## 前置条件

```sh
cd /Users/siancao/work/ai/vibecoding/codeinsight
swift build -c release          # 必须先构建
swift run -c release codeinsight-app   # 启动被测应用
```

- 测试语料：`~/work/ai/oatmeal`（Rust 项目）。
- 涉及的已知代码事实（用于断言）：
  - `src/domain/services/bubble_list.rs` 第 8 行附近有 `use super::Bubble;`；
    文件内有 `struct BubbleCacheEntry<'a>`、`pub struct BubbleList<'a>`（字段
    `cache: HashMap<usize, BubbleCacheEntry<'a>>`）、`impl<'a> BubbleList<'a>` 与 `pub fn new`。
  - `Bubble` 真身在 `src/domain/services/bubble.rs:24`（struct）。
- 如需重置窗口尺寸记忆：删除偏好中 `CodeInsightMainWindow` 的 frame 记录（可选）。

## 已知限制白名单（观察到以下现象**不算 FAIL**，但请记录）

- K1 外部 crate 符号（std/第三方）解析显示 "external crate — not resolved (M1)" 或无候选。
- K2 宏调用内部（`println!` 等表达式宏）不解析。
- K3 无全文搜索、无 Call Tree/Relations 面板（M2 范围）。
- K4 索引完成前（打开项目最初 ~1 秒）的文件树点击不进入跳转历史。
- K5 Pin 状态下 Cmd+单击会覆盖已钉住的内容（语义待定，请记录实际行为）。
- K6 巨文件（>5 万行）打开先显示纯文本、高亮数秒后补上——这是设计行为。

---

## T1 窗口与工具栏

| ID | 步骤 | 预期 |
|----|------|------|
| T1.1 | 首次启动（或清除 frame 记忆后启动） | 窗口约 1280×820、屏幕居中；左侧栏/主阅读区/底部 Context 三面板完整可见，无截断 |
| T1.2 | 拖拽窗口缩小到极限 | 不能小于 900×600 |
| T1.3 | 观察标题栏/工具栏区域 | 可见：后退/前进两个 chevron 按钮（当前灰显）+ 项目名标签 |
| T1.4 | 调整窗口尺寸后退出（Cmd+Q）重启 | 恢复上次尺寸 |

## T2 打开项目

| ID | 步骤 | 预期 |
|----|------|------|
| T2.1 | Cmd+O 选择 `~/work/ai/oatmeal` | 文件树 1 秒内出现，含 src/ 可展开；只显示 .rs 文件与含 .rs 的目录 |
| T2.2 | 打开后立即观察工具栏 | 短暂出现 "Indexing N files…"，约 1 秒内消失 |
| T2.3 | 出现 Indexing 期间快速点击文件树多个文件 | 界面不卡顿，文件能打开显示内容 |

## T3 阅读区渲染

打开 `src/domain/services/bubble_list.rs` 后：

| ID | 步骤 | 预期 |
|----|------|------|
| T3.1 | 观察整体 | 有语法高亮：关键字（use/mod/struct/impl/fn/let/return）、注释、字符串、数字有区分色，不是全黑 |
| T3.2 | 对比 `pub fn new` 的 `new` 与正文 | 函数定义名比正文略大（+1pt）且 semibold |
| T3.3 | 观察行距 | 行间有明显呼吸感（1.25 倍），不拥挤（主观分 1–5） |
| T3.4 | 选择跨函数名/注释的几行文本，Cmd+C，粘贴到纯文本编辑器 | 内容正确，无乱码 |
| T3.5 | 系统外观切换到暗色（可用系统设置或自动化 API） | 阅读区背景/配色随动切换，文字清晰 |
| T3.6 | 滚动整个文件 | 高亮持续存在（新滚入区域也有色），无明显闪烁 |

## T4 Context Window（核心功能）

继续在 `bubble_list.rs`：

| ID | 步骤 | 预期 |
|----|------|------|
| T4.1 | **单击**（无修饰键）`use super::Bubble;` 中的 `Bubble` | 底部 Context 面板≈瞬时显示 `struct Bubble` 的定义摘录；header 显示路径 `src/domain/services/bubble.rs:24` 与标签 `strong·direct`；**主阅读区不跳转** |
| T4.2 | 单击 `BubbleList` 字段类型 `BubbleCacheEntry`（cache 字段行） | Context 显示本文件 `struct BubbleCacheEntry` 的定义摘录 |
| T4.3 | 在 `pub fn new` 函数体内单击局部变量/参数（如 `theme`） | Context 显示其声明行与 binding 类别（param/let） |
| T4.4 | **Cmd+单击** `use super::Bubble;` 的 `Bubble` | 主阅读区跳转到 `bubble.rs` 定义处并短暂高亮该行；Context 同步 |
| T4.5 | 点 Pin，然后单击文件中其他符号 | Context 内容**不变**；切回 Follow 后单击恢复联动 |
| T4.6 | 单击一个多定义符号（如 `new`——项目内多个 impl 都有 new） | header 出现 `‹n/m›` 候选计数，点左右箭头（或 Cmd+Alt+←/→）候选切换、路径变化 |
| T4.7 | 单击注释文字或空白处，再单击回 T4.1 的 `Bubble` | 第一次点击后 Context 转空态/保持；**回点后正常重新显示定义**（回归点：不得永久空白） |
| T4.8 | 缓慢移动鼠标掠过多个符号（不点击） | Context 无任何变化、无闪烁（hover 零查询） |
| T4.9 | 单击 `HashMap`（std 类型） | 显示外部 crate 未解析占位（K1，不是 FAIL），不 crash |

## T5 符号搜索（Cmd+T）

| ID | 步骤 | 预期 |
|----|------|------|
| T5.1 | Cmd+T | 居中浮层出现，输入框有焦点 |
| T5.2 | 依次输入 b、u、b、b、l、e | 输入框显示 "bubble"（**累积**，不是每键替换）；结果列表实时更新 |
| T5.3 | 观察结果 | 含 Bubble、BubbleList 等项，每行有 kind、名字（匹配段加粗）、路径:行号 |
| T5.4 | ↑↓ 键移动 | 选中行移动，到底部环绕 |
| T5.5 | Enter | 面板关闭，主区打开对应文件并定位到符号行（短暂高亮） |
| T5.6 | 再次 Cmd+T，输入 bblst | BubbleList 出现在前排（子序列匹配） |
| T5.7 | 双击结果中某行 | 同 Enter 效果 |
| T5.8 | Cmd+T 后按 Esc | 面板关闭，焦点回主窗口 |
| T5.9 | Cmd+T 后点击面板外部 | 面板关闭 |

## T6 跳转历史

| ID | 步骤 | 预期 |
|----|------|------|
| T6.1 | 依次：文件树打开 bubble.rs（记为 A）→ Cmd+T 打开 bubble_list.rs（B）→ 在 B 中 Cmd+单击某符号跳到第三处（C） | 每步正常到达 |
| T6.2 | 点工具栏"后退"两次 | 依次回到 B、A，且 A 恢复到离开时的滚动位置 |
| T6.3 | 点"前进"一次 | 回到 B |
| T6.4 | 观察按钮状态 | 在最早处"后退"灰显；在最新处"前进"灰显 |
| T6.5 | 用 Cmd+Ctrl+← / Cmd+Ctrl+→ 重复 T6.2/T6.3 | 行为一致 |

## T7 大文件

先生成 10 万行文件：

```sh
awk 'BEGIN { for (i = 1; i <= 100000; i++) printf "fn generated_%d() { let value = %d; }\n", i, i }' > /tmp/ci-test-100k.rs
mkdir -p /tmp/ci-huge-project && cp /tmp/ci-test-100k.rs /tmp/ci-huge-project/
```

| ID | 步骤 | 预期 |
|----|------|------|
| T7.1 | Cmd+O 打开 /tmp/ci-huge-project，点开 ci-test-100k.rs | ≤2.5 秒内出现纯文本内容（无高亮） |
| T7.2 | 等待高亮出现（可能数秒） | 视口内出现高亮（K6：延迟属设计行为） |
| T7.3 | 高亮就绪后连续 PageDown 20 次、拖动滚动条到 25%/50%/75%/100% | 滚动跟手，无长时间卡顿/白屏；新区域高亮出现；记录任何 hitch 的位置与时长 |
| T7.4 | 观察快速滚动时行的垂直稳定性 | 函数名 +1pt 不造成行高跳动/内容上下抖动 |

## T8 稳定性收尾

| ID | 步骤 | 预期 |
|----|------|------|
| T8.1 | 回到 oatmeal 项目，5 分钟混合操作：随机开文件、单击符号、Cmd+T 搜索跳转、历史往返、Pin/Follow 切换 | 无崩溃、无 beachball、无内容错乱（显示的内容与文件名一致） |
| T8.2 | Cmd+Q | 正常退出 |

## 报告格式

每条测试点回传：`ID | PASS/FAIL/BLOCKED | 备注`。

- FAIL 必须附：实际现象描述 + 截图 + 精确复现步骤。
- 命中"已知限制白名单"的记 PASS(K#) 并简述现象。
- T3.3 行距与 T7.3 滚动手感给 1–5 主观分。
- 全程如遇 crash：保存崩溃日志（Console.app → 崩溃报告）一并回传。
