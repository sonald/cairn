# P0 字体成形记录

日期：2026-09-22。状态：**Core Text 成形通过；真实 Reader 选择、查找、复制另行验收。**

环境：macOS 27.0 (26A428)，arm64；Apple Swift 6.4 (swiftlang-6.4.0.34.1)，macOS SDK 27.0。最低部署系统未实测。

复现：

```sh
swift -module-cache-path /tmp/ligature-module-cache scripts/ligature-font-probe.swift > /tmp/ligature-font-probe.json
python3 fixtures/ligatures/generate.py
```

字体通过本机用户字体目录提供，产品未添加字体二进制。沙盒内字体服务不能解析用户字体时，探针返回退出码 2；验收须在能访问用户字体服务的原生环境运行。最初误用 `FiraCode-Regular` 得到系统回退，核对 NSFontManager 后改为 `FiraCodeRoman-Regular`，未把回退结果计为通过。

官方项目：[Fira Code](https://github.com/tonsky/FiraCode)、[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono)。本次使用已有安装文件，不声称重新下载校验了上游发布包；下列本地 hash 固定实际测试输入。

## 字体环境

- 请求 `FiraCodeRoman-Regular`；实际 `FiraCodeRoman-Regular`；版本 `Version 6.002`；fallback=false。
  文件 `/Users/siancao/Library/Fonts/FiraCode-VF.ttf`；SHA-256 `04149681350f161aca538858b88d17443c586cacca83c165939a13423fe91a26`。
- 请求 `JetBrainsMono-Regular`；实际 `JetBrainsMono-Regular`；版本 `Version 2.305; ttfautohint (v1.8.4.7-5d5b)`；fallback=false。
  文件 `/Users/siancao/Library/Fonts/JetBrainsMono-Regular.ttf`；SHA-256 `e6fd0d7e91550b3ed2b735d4312474362c4716edc4fc0577a0f61ed782d5aed1`。
- 请求 `__missing_ligature_font__`；实际 `.AppleSystemUIFontMonospaced-Regular`；版本 `22.0d3e3`；fallback=true。
  文件 `unavailable`；SHA-256 `unavailable`。

## 冻结的特性桥接

```swift
let features: [[String: Any]] = tags.map {
    [kCTFontOpenTypeFeatureTag as String: $0,
     kCTFontOpenTypeFeatureValue as String: enabled ? 1 : 0]
}
let descriptor = CTFontDescriptorCreateCopyWithAttributes(
    CTFontCopyFontDescriptor(base),
    [kCTFontFeatureSettingsAttribute: features] as CFDictionary)
let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
```

- Default：从未覆写的基准 descriptor 开始，不设置 `.ligature`，不添加 feature 请求。
- On：`.ligature=1`；`calt/liga/clig=1`。
- Off：`.ligature=0`；`calt/liga/clig/dlig/hlig=0`。
- 字体派生后重新应用覆盖；不要从上次 Off 的字体开始构造 Default。
- 自然字距不写 `.kern`。对照 `.kern=0`、`.kern=0.3` 的 glyph IDs 在本次样例中不变，后者改变 advance；这不构成跨字体的字距兼容保证。

上述 Core Text 字典写法在当前 SDK 独立编译、实际 CTLine 成形成功。两个测试字体仅设置 `.ligature=0` 时仍产生连接形态，故必须关闭 calt 等 descriptor 特性。

## 操作符 glyph ID 证据

均为 16 pt，Default 与 On 相同；仅 `.ligature=0` 与 Default 相同。所有操作符 glyph 数量均保持字符数，因此不能用 glyph 数量减少来判断是否生效。

| 字体 | 原文 | Default / On | Off |
| --- | --- | --- | --- |
| `FiraCodeRoman-Regular` | `!=` | `[1204, 1135]` | `[1132, 1578]` |
| `FiraCodeRoman-Regular` | `->` | `[1186, 1458]` | `[1221, 1580]` |
| `FiraCodeRoman-Regular` | `=>` | `[1457, 1461]` | `[1578, 1580]` |
| `FiraCodeRoman-Regular` | `<=` | `[1651, 1403]` | `[1581, 1578]` |
| `FiraCodeRoman-Regular` | `>=` | `[1650, 1389]` | `[1580, 1578]` |
| `FiraCodeRoman-Regular` | `!==` | `[1204, 1649, 1136]` | `[1132, 1578, 1578]` |
| `FiraCodeRoman-Regular` | `===` | `[1649, 1649, 1388]` | `[1578, 1578, 1578]` |
| `FiraCodeRoman-Regular` | `::` | `[1202, 1125]` | `[1124, 1124]` |
| `FiraCodeRoman-Regular` | `..` | `[1201, 1118]` | `[1117, 1117]` |
| `FiraCodeRoman-Regular` | `...` | `[1201, 1201, 1119]` | `[1117, 1117, 1117]` |
| `JetBrainsMono-Regular` | `!=` | `[1751, 872]` | `[913, 1316]` |
| `JetBrainsMono-Regular` | `->` | `[1751, 841]` | `[934, 1318]` |
| `JetBrainsMono-Regular` | `=>` | `[1751, 1006]` | `[1316, 1318]` |
| `JetBrainsMono-Regular` | `<=` | `[1751, 1039]` | `[1319, 1316]` |
| `JetBrainsMono-Regular` | `>=` | `[1751, 1014]` | `[1318, 1316]` |
| `JetBrainsMono-Regular` | `!==` | `[1751, 1751, 873]` | `[913, 1316, 1316]` |
| `JetBrainsMono-Regular` | `===` | `[1751, 1751, 1004]` | `[1316, 1316, 1316]` |
| `JetBrainsMono-Regular` | `::` | `[1751, 860]` | `[910, 910]` |
| `JetBrainsMono-Regular` | `..` | `[1751, 855]` | `[908, 908]` |
| `JetBrainsMono-Regular` | `...` | `[1751, 1751, 856]` | `[908, 908, 908]` |

缺失字体用例保留请求名并解析为系统等宽字体；其十个操作符三态 glyph IDs 相同，符合“字体可能没有连接形态”。系统字体文件 URL 不由本次 API 返回，因此 hash 明确为 unavailable。

探针 JSON 包含每个 run 的实际字体、glyph IDs、位置、advances、UTF-16 indices，以及中文、emoji、组合字符、Tab 混排样例。它验证成形而不验证原生选择手势；完整 P0 门槛还需真实 Reader 交互证据。

## Fixtures

`fixtures/ligatures/generate.py` 无随机输入。`manifest.json` 记录字节数、行数、最大源行字节数、UTF-16 长度及 SHA-256。包括短操作符/折叠函数样例、同内容 CRLF 样例，以及恰好 2,000 行的长行混排常规性能样例。大文件与超长单行继续复用既有 wrap fixtures。

性能预算保留原 N03/N04 目标，未凭本探针修改或宣称通过。CTLine 是同步成形，没有 Reader 首帧、滚动、内存或恢复延迟数据。
