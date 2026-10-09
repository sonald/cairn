# base16 映射原型（一次性）

验证 [theme-base16.md](../theme-base16.md) §3 的 16 色 → Cairn 角色映射：对 16 套 tinted-theming 方案跑 `ReaderSettingsTests.readerThemePaletteMeetsRequiredContrastRatios` 的 13 组对比度要求（安静/完整两种语法映射），并报告调色记录与高亮槽位的最近距离。

```sh
swift mapping-proto.swift base16/*.yaml
```

`output.txt` 是 2026-10-09 在 Xcode 27.0 / Swift 6.4 上的输出：16 套 × 2 种映射全部 PASS。`base16/` 下的 yaml 来自 tinted-theming/schemes `spec-0.11` 分支（MIT，见同目录 LICENSE），实施时把计划 §3 列出的 10 套和 LICENSE 移到 `Sources/CodeInsightReaderCore/Themes/`，其余 6 套只作证据。映射逻辑和检查循环进入产品代码与测试后，整个目录随计划删除。
