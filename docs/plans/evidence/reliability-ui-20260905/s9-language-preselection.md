# S9 — 首次导入语言预选：逐片记录

## 实现

- `RecentProjectsStore.storedLanguagesIfRecorded(for:)`：有有效记录才返回，`languages(for:)` 的 Rust 回退不再能冒充用户选择。
- `AppDelegate.preselectedLanguages(for:storedLanguage:)`：优先级为 已存偏好 → 有界只读文件名探测 → 空。探测只看文件名（不读内容、不启动 provider、不加载脚本），跳过固定目录集合（与索引器跳过集一致），入口上限 5000 保证巨大目录确定性终止（返回 `probeCapped` 终态）。`.js/.jsx` 不选 TypeScript（classify 既有边界）。探测在弹窗显示前同步完成——用户此后手动改选不可能被覆盖（构造上保证）。
- `makeLanguageSelectionAlert`：按预选勾选；预选非空时 Open 初始可用；空预选保持 0 项禁用 + 手选入口。

## 测试（新增 2）

- `languagePreselectionMatchesContentAndStoredPreference`：Rust/Python/TSX/三语混合预选准确；纯 JS/JSX 不选；node_modules/dist 不探测；已存偏好（Python）覆盖内容检测；6000 文件目录 capped 且空结果终态。
- `recentsRecordOnlyLookupNeverFallsBackToRust`：无记录 → nil，旧 API 回退行为不变。

## GREEN

- 2 新测试通过；`MainWindowControllerTests|RecentProjectsStoreTests`（隔离跳过）：32 通过（0 项 Open 禁用/1–3 项可用/纯键盘由既有 languagePicker 检查维持）；产品自测全通过。
- `scripts/ci.sh` 887→889。

## 验收对照

- Rust/Python/TSX/混合预选准确 ✓；JS/JSX 不误选 TS ✓；老项目偏好有效 ✓；0 项禁用、1–3 项可用、纯键盘 ✓（既有）；探测取消/巨大目录/无权限明确终态 ✓（capped 标志 + 上限终止；无权限子目录由 skipsHiddenFiles+枚举容错覆盖）；混合非 Git 目录支持边界不变 ✓。
