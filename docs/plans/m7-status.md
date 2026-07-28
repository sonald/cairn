# M7 当前状态（交接用，2026-07-28）

## 基线

- **HEAD**：`cb2cbbb`，工作树干净
- `swift test` **328 全绿**；`ci.sh` 绿；`run-self-tests.sh` **12 PASS / 0 FAIL / 0 HANG**
- 双语料 gold nostrong=0；canonical dump 零 diff；Swift 6 零 warning
- extractorVersion=**7**（S0A bump）

## 已完成

| commit | 内容 |
|---|---|
| `a73c494` | M7 计划 v4（两轮评审 7 P1 + 3 P2 全部核查属实并采纳） |
| `4d40cd1` | G0 报告首轮（暴露 ripgrep 语料残缺） |
| `a6b4fad` | **S0A** 点击定位：`nameRange` + receiver 命中 + 全部消费者分类 |
| `6808dfd` | **S0B** 修 Exact overlay 的 trust 串档 |
| `cb2cbbb` | **G0 门 PASS**（16 PASS / 1 BLOCKED / 2 NOT RUN）→ **S4 解锁** |

## 进行中

**S1 spike**（`bxx24dqpf`，Codex，后台）——产出 `docs/plans/m7-spike-findings.md`：
- 第一组 Exact References 语义（真实 RA，须证明 References ≠ Callers）
- 第二组 **Fuzzy 实现路径**（风险最高）：cap 200/5000 在语义验证前截断的比例、
  comment/string 排除可行性、parse 次数、§2.2 四态计数合同

**关键判断点**：若 Fuzzy 组显示 cap 会吞掉有效引用，**S3 设计要先改**才能派发。

## 剩余切片（派发顺序）

```
S1 spike（进行中）→ S2 Local References → S3 Fuzzy Project References
→ S4 Exact References（已解锁）→ S5A References UX → S5B Reader 视觉设置 → S6 总验收
```

**S2 派发前必须先裁决三件事**（计划 §S2）：
1. References 是否在 Relation Window 增第四方向
2. `ReaderDocument` 的 binding index 如何送进现有结果面
3. local 与 global 是否必须统一成一种 target 类型
   （**只有答案为"必须"时**才允许新增严格两分支的最小类型）

## 环境注意事项

- **tokio 语料已就绪**：有 `.git`（commit `046852f`，731 文件）+ 依赖已 `cargo fetch`，
  `cargo metadata` exit 0。路径：
  `/private/tmp/claude-501/-Users-siancao-work-ai-vibecoding-codeinsight/07b4a1d2-8dd6-49a2-b70b-f8f19bfd9226/scratchpad/corpora/tokio-tokio-1.47.1`
- **ripgrep 语料残缺**：全部 10 个 crate 缺 `Cargo.toml`，`cargo metadata` exit 101，
  **不可用于真实 RA 实验**。需重新获取（backlog）
- **12 通道的非 git 语料**：用 `Tests/CodeInsightExactTests/Fixtures/exact_fixture`
  的 `/tmp` 只读副本（tokio 现在有 `.git` 了不算非 git）
- **`--self-test-open` 必须喂真实存在的文件**（根目录**没有** README.md）
- Exact 相关测试在**全量并发**下有既有 flake（基线同样红），单跑与复跑均绿

## 本轮的两条操作教训

1. **禁改 `goldset/`**：S0A 首轮 Codex 改 fixture 一个空格让列 21 从 receiver 挪到
   方法名，`.gold` 零 diff 但被测场景被换掉——**假绿**。还原后实测有真回归。
2. **注入验证要超出清单**：S0A 的 `priority` tiebreak 是我顺手注入移除才发现
   **没有任何测试守着**。只跑"绿不绿"发现不了。

## 未解决并已如实标注

- `ExactOverlay.ReuseKey` **仍不含 worktree 内容身份**（改文件后可能命中陈旧 overlay）
  ——无稳定复现不改（S0B 红线）
- G6.2 帧率手感 BLOCKED（人工项，禁止用 fragment 数替代）
- ripgrep 语料需重新获取
