# M10 原型视觉决策（随原型评审累积，供 G0/E3/N2 实现遵循）

> 惯例同 M9：原型里留的「待裁决」项，用户裁决后钉在此处，实现按此执行，不再各自发挥。

## 原型 01 · Resolution Inspector + 三值 Evidence Badge
文件：[`resolution-inspector-prototype.html`](resolution-inspector-prototype.html)

| # | 待裁决项 | 裁决（2026-08-06） | 落到 |
|---|---|---|---|
| D1 | Unresolved badge 用中性描边还是淡填充 | **中性描边**（保持原型）——权重弱于 Verified/Inferred 实心填充，但仍占同一 badge 通道 | G0 badge 规格 / E3 |
| D2 | corrected 折叠组位置：列表尾 vs 紧贴被修正的主行 | **列表尾**（保持原型）——`Show corrected candidates (N)` 作为默认折叠组置于列表末，不打断主关系流 | §3.8 / §3.15 / E3 |

## 原型 02 · Semantic Trail
文件：[`semantic-trail-prototype.html`](semantic-trail-prototype.html)

| # | 待裁决项 | 裁决（2026-08-06） | 落到 |
|---|---|---|---|
| D3 | 分支视觉：git-log 式缩进+gutter 连线 vs 更强的彩色分支轨道 | **保持现状**（git-log 式缩进 + gutter 连线） | §3.12 / N2 |
| D4 | Trail 放置：独立面板 vs 顶部路径条 vs 浮层 | **A + C 组合**（顶部路径条常驻 + 浮层按需唤出）；放弃 B 常驻侧面板 | §3.11 / N2 |
| D5 | 分叉在哪处理 | **一律交给 C 浮层**——A 顶部条只显当前主线，其 `⑂` chip 仅唤出 C，不做行内下拉 | §3.11–3.12 / N2 |

> D4/D5 落地说明：N2 的 Trail UI = 顶部薄路径条（active path breadcrumb，永远可见、几乎零空间）+ ⌘-键/`⑂` 唤出的浮层 DAG（看整棵分叉树）。原型 02 的 §3.13「冻结快照 vs 当前态」内容归入 **C 浮层**的节点详情，不再是常驻面板。

## 原型 03 · Reading Set（P0 探索）
文件：[`reading-set-prototype.html`](reading-set-prototype.html)

| # | 项 | 结论（2026-08-06，倾向·待用户确认） | 落到 |
|---|---|---|---|
| D6 | Reading Set 布局：A 行内展开 vs B 主区新 tab | **B（Reading Set tab）为目标形态，但属 M11**；A 行内 peek 作为 Relations 的轻量补充另算。P0 只选形态、**不进 M10** | P0 / M11 |

> 依据：只有 B 能兑现「沿一条有证据的路径读懂一个符号」；B 需「非文件文档」原语（§2 已定顺延 M11），与 Trail 浮层 C 的「Open as Reading Set」共用同一原语，M11 一次引入两处复用。每段出处头（Verified/Inferred + commit + 查看证据→开原型 01 Inspector）是硬要求，不可省。

## 原型 01 既定项（供实现对照）
- 三值 badge 同通道：Verified 绿实心 / Inferred 蓝实心 / Unresolved 中性描边（§3.4）。
- `dependency` 等目标位置 = 虚线 scope chip，正交于 epistemic 状态（§3.7）。
- Inspector 渐进披露：badge → 一句 why → `Show full audit`（E3）。
- SOURCE / VERIFICATION 两段；verification-only 只有下段；conflict 下段变 `VERIFICATION CONFLICT`（§1.6/§3.10）。
- 主 provider 行自带修正轨迹（`corrected N`），被修正候选折进 corrected 组（§3.8 阻塞3）。
- 色值复用 M9 S6 三主题 token，仅新增 Unresolved 中性描边 + conflict 琥珀 chip。
