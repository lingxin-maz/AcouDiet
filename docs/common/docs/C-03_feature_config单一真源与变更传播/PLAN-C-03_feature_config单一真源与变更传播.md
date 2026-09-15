# PLAN-C-03 `feature_config` 单一真源与变更传播

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-C-03`（**硬闸门**） |
| 负责 | A+B（A 主责训练侧读取与数值正确性；B 主责双侧生成器与 Kotlin 常量固化；C 协助文档旧值清理） |
| 目标日 | **D0→D1**（D1 结束前随「三方接口冻结」完成）；`n_frames` **已修订为 128（`ADR-21`，2026-09-12）**；原 `ADR-P1`（2026-09-10）冻结值为 ~~129~~ |
| 前置依赖 | `shared/feature_config.json` **已存在（41 键）**；Flutter 工程已初始化（`PLAN-00` D1）；**`dart run`/`flutter test` 须在沙箱外普通终端执行** |
| 预估工时 | 8 h（A 3 h + B 4 h + C 1 h） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `shared/feature_config.json` | SSOT（**既有文件，本 PLAN 只管理、不改数值**） |
| 2 | `tool/gen_feature_config.dart` | Dart 常量生成器（读 SSOT → camelCase 常量） |
| 3 | `app/lib/core/feature_config.g.dart` | 生成产物，首行含"禁止手改"标记 |
| 4 | `app/android/app/src/main/kotlin/.../NativeCapabilities.kt` | Kotlin 编译期固化常量 + `getCapabilities()` 返回体 |
| 5 | `app/test/cfg/generated_constants_test.dart` | 生成产物与 SSOT 逐字段相等断言 |
| 6 | `app/test/cfg/handshake_test.dart` | **15 字段**握手全等 + 不符即 `ACD-CFG-001`（`ADR-21`；原 ~~12 字段~~） |
| 7 | `records/compliance/C-03/change_propagation_checklist.md` | `SPEC-C-03` §7 附表的打勾件（**14 项** + 签名） |
| 8 | `records/compliance/C-03/cfg_scan_zero_hits.txt` | 判据 #3 的搜索命令与输出（命中 0） |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 冻结 SSOT 读取口径（训练侧 Python 直读；App 侧构建期同步到 `app/assets/`） | 读取约定 + 同步脚本说明 | 1 h | — |
| 2 | 写 Dart 生成器，产出 camelCase 常量 | 交付物 #2 #3 | 2 h | #1 |
| 3 | Kotlin 侧固化 **15 字段**并实现 `getCapabilities()`（`ADR-21`） | 交付物 #4 | 1.5 h | #1 |
| 4 | 写两个单测（生成一致性、握手放行/拦截） | 交付物 #5 #6 | 2 h | #2 #3 |
| 5 | 执行 **14 项**变更传播单（P-1~P-9 + A-1 / A-2 / ADR-05 / ADR-07 / ADR-09）并清理全项目旧值 | 交付物 #7 #8 | 1 h | #2、C 的文档修订 |
| 6 | `n_frames` **修订为 128（`ADR-21`，2026-09-12）** 后的四处同步演练（原 ~~已拍板 129（`ADR-P1`，2026-09-10）~~） | 同步记录 | 0.5 h | D2 前 |
| 7 | 与 `model_card.json` 的 hash 闭环核对 | 核对记录 | — | `PLAN-T-07` |

## 3. 技术方案

**生成器骨架（Dart，≤30 行；产出物首行必须带 `// GENERATED FROM shared/feature_config.json -- DO NOT EDIT`）**：

```dart
// tool/gen_feature_config.dart
import 'dart:convert';
import 'dart:io';

String camel(String s) => s.split('_').asMap().entries
    .map((e) => e.key == 0 ? e.value : e.value[0].toUpperCase() + e.value.substring(1))
    .join();

void main() {
  final json = jsonDecode(File('../shared/feature_config.json').readAsStringSync()) as Map<String, dynamic>;
  final buf = StringBuffer('// GENERATED FROM shared/feature_config.json -- DO NOT EDIT\n');
  buf.writeln('class FeatureConfig {');
  for (final e in json.entries) {
    if (e.key.startsWith('_')) continue;               // 元数据与决策登记（_decisions）不进常量
    final v = e.value;
    if (v is num || v is bool) buf.writeln('  static const ${camel(e.key)} = $v;');
    if (v is String) buf.writeln("  static const ${camel(e.key)} = '$v';");
  }
  // ADR-21 拆除了 db_clip_range 1->2 特例：normalization_output_min / _max 是普通键，直接走上面的通用分支
  buf.writeln('}');
  File('../app/lib/core/feature_config.g.dart').writeAsStringSync(buf.toString());
}
```

**同步与校验规则**：

| 规则 | 内容 |
|---|---|
| 单一写入点 | 只有 `shared/feature_config.json` 可以写数值；其余位置全是派生 |
| 生成物禁改 | `*.g.dart` 与 Kotlin 常量文件手改即判不通过（`SPEC-C-03` §2.4） |
| 变更顺序 | 先改 SSOT → 跑生成器 → 跑 §7 #3 搜索 → 更新 `model_card.json` → 跑 `PLAN-T-08` |
| 决策项保护 | `n_frames` **已修订为 128（`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~）**，决策记录在 SSOT 的 `_decisions` 块（`n_frames` 条目保留旧值与 `rejected_alternative`，并新增第 6 项 `mel_frontend_v1_1`）；所有文档一律写「`n_frames = 128`」（另见 `raw_mel_frames = 129`，见 `SPEC-00` §3.5），不得再写成未拍板或备选值 |

> ⚠️ **本文件下方「`n_frames` 拍板记录（129）」整段是 `ADR-P1`（2026-09-10）的历史记录，已被 `ADR-21`（2026-09-12）修订**：现行值为 **`n_frames = 128`**（`raw_mel_frames = 129`）。按本仓惯例**不删除历史**，故下方文字保留原样，仅在此处标注取代关系与取代者。

**`n_frames` 拍板记录（`ADR-P1` 历史：已拍板 129，2026-09-10；**该值已由 `ADR-21`（2026-09-12）修订为 128**）与拍板后的同步动作**：

1. A 复跑 `_toolchain/verify_mel.py` 与 `verify_mel2.py`，确认帧数事实。
2. A 已拍板选 **B**（保留 4.096 s 窗口 / 65536 样本），写入 SSOT 的 `_decisions` 块（含 `rejected_alternative`：128 帧 / 4.064 s / 65024 样本与否决理由）；B/C 会签。**⚠️ `ADR-21`（2026-09-12）后**：`n_frames` 定为 **128**（张量宽度），`129` 改称 `raw_mel_frames`，`_decisions` 新增第 6 项 `mel_frontend_v1_1`；**窗口 4.096 s / 65536 样本未变**，选项 A 仍未采纳。
3. 按四处同步：`feature_config`（`n_frames` + `input_shape`）→ `model_card.json`（`nFrames`/`inputShape`）→ Kotlin 常量 → Dart 常量（重新生成）。
4. 重跑判据 #1/#3/#4 与 `PLAN-T-08` 的对齐测试。
5. 在 `change_propagation_checklist.md` 的 P-2 行补记最终措辞（消除 `SPEC-C-03` §10 **#4** 的字面冲突）。

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `test/cfg/generated_constants_test.dart` | 单元 | 生成常量与 SSOT 逐字段相等，差异数 == 0 | 每次提交前 |
| `test/cfg/handshake_test.dart` | 单元 | **15 字段**全等放行；改 1 字段 → `ACD-CFG-001`，检测页不可达（`ADR-21`；原 ~~12~~） | 每次提交前、D4、D9 |
| 手写键名扫描 | 命令 | `rg "feature_config\[|'n_frames'" app/lib` 命中 0 | 每次提交前 |
| 旧值零残留搜索 | 命令 | `SPEC-C-03` §7 #3 命令命中行数 == 0 | 交付前、D1、D10 |
| **schema 与真实 JSON 双向差集** | 命令 | 比对 `docs/common/docs_api/schemas/feature_config.schema.json` 的 `required` 与 `properties` 对 `shared/feature_config.json` 的真实顶层键集合：**双向差集 == 0**（`required` 无缺失、无多余；`properties` 无缺失、无多余）。⚠️ **本行原记「实测 41 键 = 41 `required` = 41 `properties`」，该数字属 `ADR-21` 之前的旧口径、且已不成立**：`ADR-21`（2026-09-12）把 SSOT 顶层键改为 **49**（+8 顶层 + `_comment_4`，−`db_clip_range`），而**本文件未复核该 schema 是否同步**（见 `SPEC-C-03` §10 #5）。本条命令正是应当用来复核的机械手段，**在它跑出 0 之前不得假定 SSOT 已闭合** | 每次 SSOT 顶层键增删后 |
| **14 项传播完成后的重跑验收**（A-1 / A-2 / ADR-05 / ADR-07 / ADR-09 落地后） | 命令 | 改完 14 行变更传播单后必须重跑：① `SPEC-C-03` §7 判据 3 的「**旧值零残留**」`rg` 命令 → **命中行数 == 0**；② `python _toolchain/verify_docs.py` → **`BLOCKER × 0`**（预期 `RESULT: PASS`） | 14 项逐项打勾后立即重跑一次；D10 回归再跑一次 |
| 制品 hash 闭环 | 命令 | `model_card.nFrames` == SSOT `n_frames`；`tfliteSha256` 匹配 | D4、D8、D10 |
| Kotlin 常量一致性 | 仪器 | `getCapabilities()` 与 assets 配置全等（真机） | D4、D5 |

## 5. 完成定义（DoD）

- [ ] `SPEC-C-03` 第 7 节 **5** 条判据全部通过，输出已归档到 `records/compliance/C-03/`
- [ ] Dart 常量 100% 由生成器产出，业务代码零手写字符串键名
- [ ] Kotlin **15 字段**由 SSOT 派生，`getCapabilities()` 与 assets 全等（`ADR-21`；原 ~~12~~）
- [ ] 握手失败路径实测可拦截（构造用例通过）
- [ ] **14 项**变更传播单 14/14 打勾，A/B 签名齐全
- [ ] 旧值零残留搜索命中 0（授权例外仅两处历史对比表）；**14 项传播落地后重跑** 该 `rg` 命令（命中 0）与 `python _toolchain/verify_docs.py`（`BLOCKER × 0`）
- [ ] `n_frames` **已修订为 128（`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~）** 并完成四处同步（`feature_config` / `model_card.json` / Kotlin 常量 / Dart 常量）
- [ ] 变更顺序与生成物禁改规则写入仓库 README 或 `PLAN-00` 附录

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 生成器写不出来（Dart 工具链问题） | `dart run` 失败 | 退化为 B 手工生成 + 生成器脚本在 D1 内补齐；**手写常量不得超过 1 天**（超时即视为 R-20 高风险） |
| Kotlin 侧无法编译期读取 JSON | 构建脚本受限 | 改为构建期入参注入常量（`--dart-define` 风格），但仍**不得手写第二份** |
| `n_frames` 修订值但四处同步未完成 | 四处产物（SSOT / `model_card.json` / Kotlin 常量 / Dart 常量）不一致 | **禁止开始训练**；按 §3 的四处同步逐处补齐并重跑判据 #1/#4 与 `PLAN-T-08`，由 A 承担延期 |
| 旧值清理牵出大量文档改动 | 搜索命中 >20 行 | 按 `SPEC-C-03` §7 #3 的授权例外收敛范围；文档类旧值优先清理（C 负责） |
| 拍板后再次改选项 | 训练已开始 | 明确宣告权重作废（`SPEC-00` §3.5），回到 D2 重训 |
| 有人直接改生成文件 | 代码评审 | 判不通过并回退；在 CI 或提交前钩子加"生成物一致性"检查 |

## 7. 与检查点的关系

| CP / 节点 | 关系 | 未完成时的处置 |
|---|---|---|
| D0 | SSOT 读取口径与生成器框架就位 | 未完成 → D1 接口冻结延后，直接影响 `PLAN-P-04` |
| **D1 接口冻结** | `PLAN-00` §4「接口先行」的三项之一：`feature_config` 冻结 | 未冻结 → 不得进入 D2（关键路径起点） |
| **D2 训练前** | `n_frames` **已修订为 128（`ADR-21`，2026-09-12；原 `ADR-P1` 冻结值为 ~~129~~）**；训练启动的硬门槛转为「四处同步 + `PLAN-T-08` 对齐测试通过」 | 同步或对齐未完成 → 训练不启动，D2 顺延 |
| D4 | 真机握手 + 制品 hash 闭环（与 `PLAN-T-07` 同步验收） | 未过 → 检测页不可用，回退修生成/同步链路 |
| CP2（D5 晚） | 端到端闭环依赖两侧常量同源 | 未过 → 全天扑联调，优先修配置链路 |
| D10 | 旧值零残留搜索定稿 | 未过 → 只允许清理文档与常量（不改行为），清理后重跑搜索 |

**文档结束**
