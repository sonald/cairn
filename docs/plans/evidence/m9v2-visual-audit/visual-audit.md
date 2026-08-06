# M9 v2 三原型视觉审计（2026-08-06）

## 结论

上一版审计错误地把可横向扩张的 badge 判成 PASS；用户在宽 Relations 面板中复现的
`Inferred` 拉长和 `Verified` 贴边证明该结论无效。根因是 `NSStackView` 会把剩余宽度
分配给 badge 容器，仅设置 hugging priority 不能保证原型中的 `white-space: nowrap`。

修正后，**S2、S5、S6 的明确视觉合同已在真实 Cairn + Tokio + rust-analyzer 会话中
重新复验为 PASS。** badge 容器现在由标签固有宽高加 `1×5 pt / r4` 明确约束，与
`dynamic/direct` 使用相同轮廓，仅保留 Verified/Inferred 的语义配色；宽面板下仍保持
紧凑，并与右边缘保留 `10 pt`。SI Classic 的窗口背景、透明 titlebar 与 status bar
统一使用 theme chrome，不再出现白色外壳；三主题截图均已重新采集。

## 对照结果

| 原型 | 原型合同 | 实现与实机结果 | 状态 |
|---|---|---|---|
| S2 Primary Selection · Variant B | Light `#175CD3 / 13%`；Dark `#84ADFF / 20%`；SI `#163A5F / 12%`；`1.6 pt` stroke、`4 pt` radius、水平 `1.5 pt` padding；主选区不叠加 occurrence 黄底 | Reader 保留真实 selected range，系统 selection background 透明，自绘 fill + ring；其它 occurrence 继续为 amber；当前行底色继续存在；Escape 恢复原生 selection attributes 并清除。 | PASS |
| S5 Relations · After A | root/edge `44 pt`，group `26 pt`，evidence `24 pt`；标题 `12.5 pt`，路径 mono `11 pt`；dispatch chip 与 provenance badge 均为紧凑 `1×5 / r4` 轮廓；modifiers `10 pt`；badge 距右侧 `10 pt`；两行 row；`Show possible matches` + count pill | root path 移至第二行；真实 dispatch/modifiers 分列；Verified/Inferred badge 以 `label + 10×2 pt` 约束锁定紧凑 padding，不再吸收剩余宽度；右侧约束为 `10 pt`；折叠标题与计数拆分；真实 Tokio 展开后同时显示 Verified、Inferred、direct chip 和 modifiers。geometry 回归测试覆盖 padding、r4 及右侧留白。 | PASS |
| S6 Theme Surfaces | Window/titlebar/status bar、Sidebar、Reader、Relations、Context 同主题 chrome/header/divider/selection/accent；Light、Dark、SI Classic 三套固定 palette | `ReaderTheme` 是唯一颜色来源；窗口背景、透明 titlebar 和 status bar 均消费 theme chrome；侧栏和 Relations 使用同一个自绘 selection row；Reader、Context、分隔线同步更新；Light 选中行文字显式使用主题前景色，避免 AppKit 自动变白。 | PASS |

## 三主题固定值

| Theme | content | chrome | header | divider | row selection | accent |
|---|---|---|---|---|---|---|
| Light | `#FFFFFF` | `#F4F5F7` | `#ECEEF1` | `#E1E4EA` | `#E7F0FF` | `#175CD3` |
| Dark | `#1E1E1E` | `#252528` | `#2C2C30` | `#34363B` | `#2C3644` | `#84ADFF` |
| SI Classic | `#F5F0E6` | `#EEE7D6` | `#E7DEC9` | `#DAD0B9` | `#E7DAB9` | `#163A5F` |

## 真实 UI 证据

- [Light：最终紧凑 badge/chip 与主题 surface](light-set-len-chips-final.jpeg)
- [Dark：最终紧凑 badge/chip 与主题 surface](dark-set-len-chips-final.jpeg)
- [SI Classic：最终整窗 chrome 与紧凑 badge/chip](si-classic-set-len-chips-final.jpeg)
- [SI Classic：修正前白色外壳](si-classic-before-window-chrome.jpeg)

三张最终截图已在本轮 `1×5 / r4` 修正后重采，来自同一个真实 Tokio `set_len` Callers
状态；画面同时包含 dispatch chip 与 Verified/Inferred badge，可直接比较轮廓。SI Classic
截图还覆盖窗口外层、titlebar、status bar、Sidebar、Reader、Relations 与 Context 的统一
色温。AX 树确认 Relations 行值、badge 文本和 disclosure 状态仍可读；截图本身不用于替代
完整 accessibility 验收。

## “100%”边界

可以确认的是：**原型中可执行的颜色、透明度、圆角、描边、字号、padding、行高、
层级和状态合同已 100% 对齐。** 原型是响应式 HTML，不是固定 viewport/scale/font 的
像素母版；AppKit 还使用原生 SF 字体栅格化、滚动条和窗口 chrome，因此“整张截图逐像素
相等”没有可比较的定义。若验收要求 bitmap 级相等，需要补一张固定尺寸 PNG 或 Figma
frame（包含 viewport、display scale 和字体版本），并允许把原生控件也全部自绘。

当前主机可见区域不足以完整展示计划中的 `1600×1000` 窗口；该尺寸由真实 `NSWindow`
geometry self-test 覆盖，视觉证据使用当前显示器可完整看见的窗口尺寸。这不影响上述设计
token 与布局合同验收。
