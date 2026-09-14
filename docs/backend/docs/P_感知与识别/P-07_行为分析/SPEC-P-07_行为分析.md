# SPEC-P-07 行为分析（咀嚼/时长/速度）

| 项 | 值 |
|---|---|
| 域 | P · 感知与识别 |
| 归属 | B |
| 状态 | ✅ v1.0 交付（**「输入来源缺口」已由 ADR-01 关闭**，见 §10 第 1 条） |
| 上游依据 | 主方案 §5.3；**`API-02` §5（`BehaviorMetrics` / `BehaviorAnalyzer` / `BehaviorConfig` 与 `ACD-BEH-001` 的权威定义）**、§9；`API-03` §2.3（占位指标行）；`API-01` §2.3/§3.2（`rmsEnvelope` / `envelopeHopMs` / `includeEnvelope`）、§2.5（`SessionSummary`）、§7（包络下沉原生的架构裁定）；`SPEC-00` §3.6（FF-21a~FF-21j）、§3.10（FF-25） |
| 依赖的 SPEC | `SPEC-P-02`（**包络产出方**，FF-21h；与 `SPEC-P-07` 共用同一份分帧实现；静默判据）、`SPEC-P-01`（PCM 与 `SessionSummary`）、`SPEC-D-01`（`behavior_metrics` 表）、`SPEC-A-01`（`speed` 维使用 `avgChewIntervalSeconds`） |

## 1. 目标与范围

### 1.1 一句话目标
对**原生侧算好的短时 RMS 包络**（FF-21h，随 `patch` 事件的 `rmsEnvelope` 下发）做 50 ms 滑动平均平滑 → 峰值检测（最小间距见 FF-21b、动态阈值见 FF-21c）→ 伪峰过滤（见 FF-21d），输出咀嚼次数、平均咀嚼间隔、进食时长（以 FF-21a 的静默判据界定）与进食速度评级（见 FF-21e）。本功能**不再接触时域 PCM**（FF-21i）。

### 1.2 范围内（In Scope）
- `BehaviorAnalyzer.feedEnvelope` 的逐 patch **包络累积**（输入为**原生侧算好的 RMS 包络**，**不是 PCM、不是 Mel**，FF-21h/FF-21i）。
- 包络平滑（50 ms 滑动平均）；峰值检测（FF-21b 最小间距 + FF-21c 动态阈值 `μ + 0.5σ`）；伪峰过滤（FF-21d）。
- `BehaviorMetrics` 四个字段的产出，**全部可空**（证据不足时为 `null`，不得用 0 或「数据不足」代替，`API-02` §5）。
- 进食时长界定：`durationSeconds = (endMs − 首个进食 patch 的 tStartMs) / 1000` 取整，**不含** `pauseSession` 期间（`API-02` §5）。
- `reset()` 的幂等语义与会话边界调用（`API-02` §5）。
- 输入校验与错误码（含包络入参）：`rmsEnvelope` 缺失或长度 ≠ `envelopeLength`（FF-21h，`API-01` §2.3 出参）/ `hopMs` 非法 / `tStartMs` 非单调 / `endMs < tStartMs` → `ACD-BEH-001`（定义见 `API-00` §3.5）。
- 文案硬规则：咀嚼次数必须带「约」（FF-21f）；MAE 超线时降级文案（FF-21g）由 L5 按 `chewCount == null` 或降级标志执行。
- 与 `A-01` 的 `speed` 维共享同一个 `avgChewIntervalSeconds`（口径只定义一次）。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
| 不做 | 归属 / 依据 |
|---|---|
| **咀嚼节律标准差 σ** | **`X-07` 已裁剪**：`BehaviorMetrics` **不得**新增该字段（FF-21j；`API-02`「明确不做」）。 |
| 吞咽次数、咬合力度、单口大小、食物温度估计 | 不做（无传感器、无验证手段） |
| 基于 Mel / 模型的咀嚼检测 | 不做：行为分析走**时域 RMS 包络**这条独立链路 |
| **从 PCM 重算包络 / 自带第二套分帧实现** | **禁止**：包络由原生侧计算（FF-21h/FF-21i），本功能只消费 `rmsEnvelope`；分帧实现唯一，与 `SPEC-P-02` 共用同一份（`API-01` §7） |
| 健康评分与建议文案 | `A-01` / `A-02`（本功能只产出 `BehaviorMetrics`） |
| 进食时长的可视化与趋势 | `A-03` / `U-03` / `U-04` |
| 静默判据本身（90 s 判定） | `SPEC-P-02`（FF-21a）；本功能只消费其结果 |
| 自身承担落库 | 不做：落库归 L3（`D-01`/`D-02`，`API-03`）；本功能不写库 |
| IMU / 加速度计融合、个体化阈值学习 | 不做（多模态融合推迟第三阶段） |
| 新增 `speedGrade` 第四档（如「数据不足」） | **不做**：`API-02` §5 规定仅 `'偏快'`/`'正常'`/`'偏慢'`，证据不足用 `null` |

## 2. 功能行为

### 2.1 触发与前置条件
1. 会话处于 `RUNNING`；会话层在每个 `patch` 事件到达时调用 `BehaviorAnalyzer.feedEnvelope`（`pauseSession` 期间不调用，暂停时长不计入进食时长）。
2. `rmsEnvelope` 为 `Float32List`（**原生侧算好的短时 RMS 包络**，FF-21h），长度**必须** `== envelopeLength`（`API-01` §2.3 出参，与 `API-01` §2.8 的 `getEnvelopeCapability()` 一致）；不符 → `ACD-BEH-001`（`API-02` §5）。
3. `hopMs` 取自同一 `patch` 事件的 `envelopeHopMs`（FF-21h），**禁止硬编码**；非正数或与包络长度不自洽 → `ACD-BEH-001`。
4. `tStartMs` 必须单调不回退；非单调 → `ACD-BEH-001`。
5. 会话结束时调用 `finish(endMs:)`；`endMs` 必须 `≥` 最后一次 `feedEnvelope` 的 `tStartMs`，否则 `ACD-BEH-001`。
6. ✅ **数据源已就位（依据 ADR-01）**：`API-01` §3.2 的 `patch` 事件在 `startSession({includeEnvelope: true})`（默认 `true`）时携带 `rmsEnvelope` / `envelopeHopMs`；启动时应先以 `getEnvelopeCapability()`（`API-01` §2.8）断言包络通道可用。关闭 `includeEnvelope` 时字段缺失 → `ACD-BEH-001`。**不得**回退为在 Dart 侧从 PCM 重算包络（FF-21i）。

### 2.2 主流程（编号步骤）
1. `feedEnvelope`：校验入参（长度 == `envelopeLength`、`hopMs` 合法、`tStartMs` 单调），把**原生侧算好的** `rmsEnvelope` 追加到会话级包络序列，并记录该段的 `hopMs`（`BehaviorConfig` 只提供 `mealEndSilenceSeconds` / `chewMinPeakDistanceMs` / `chewMaxPeakWidthMs` / `speedFastSeconds` / `speedNormalSeconds`；**短时 RMS 计算在原生侧完成**，FF-21h/FF-21i，本功能**不得**重算）。
2. 平滑：对包络做 **50 ms 滑动平均**，消除包络毛刺（窗长取值登记见 §10 第 2 条）。
3. `finish(endMs:)` 触发峰检测：
   a. 计算本会话包络的 `μ` 与 `σ`，动态阈值 = `μ + 0.5σ`（FF-21c；此处的 `σ` 是**包络本身的统计量**，与 `X-07` 裁剪的「咀嚼节律标准差」不是同一物）。
   b. 找出所有高于阈值的局部极大值。
4. 伪峰过滤（FF-21d）：排除峰宽 > `chewMaxPeakWidthMs` 的宽峰；排除前后无邻峰的孤立峰。
5. 最小间距约束（FF-21b）：相邻保留峰间隔 < `chewMinPeakDistanceMs` 时，保留幅值更大的一个。
6. `chewCount` = 保留峰数；`avgChewIntervalSeconds` = 相邻保留峰间隔均值；**有效峰 `< 2` 时两者均为 `null`**（不是 0）。
7. `durationSeconds`：按 `API-02` §5 的公式（`endMs` − 首个进食 patch 的 `tStartMs`）取整；无有效进食证据时为 `null`。
8. `speedGrade`：用 `avgChewIntervalSeconds` 对照 FF-21e 的 `speedFastSeconds` / `speedNormalSeconds` 划界 → `'偏快'` / `'正常'` / `'偏慢'`；`avgChewIntervalSeconds == null` 时 `speedGrade` **也为 `null`**。
9. 无任何有效进食证据时 `finish()` 返回 `null`；**返回 `null` 不等于可以不落库**——L3 仍必须写一行占位指标（全 `NULL`），强 1:1（`API-03` §2.3），`A-01` 的 `evidence.missingMetricsCount` 统计该占位数。
10. 文案层（`U-02`/`U-03`）：`chewCount != null` 时必须带「约」（FF-21f）；若离线评估的咀嚼次数 `MAE > 25%`（FF-21g）→ 降级为「咀嚼节奏：较快」，**不给绝对数字**。

### 2.3 状态与状态迁移
`BehaviorAnalyzer` 是**会话级有状态**对象（包络序列累积）：

| 状态 | 迁移条件 | 效果 |
|---|---|---|
| `EMPTY` | 构造 / `reset()` | 包络与峰值统计清空 |
| `EMPTY` | `finish()` | 返回 `null`（无证据） |
| `ACCUMULATING` | 收到 `feedEnvelope` | 追加包络段；不产出最终指标 |
| `ACCUMULATING` | `pauseSession`（会话层） | **不调用 `feedEnvelope`**；暂停时长自然不计入 |
| `ACCUMULATING` → `FINISHED` | `finish(endMs:)` | 完成步骤 3–8，返回 `BehaviorMetrics?` |
| `FINISHED` → `EMPTY` | `reset()`（幂等） | 清空统计；状态**不跨会话复用** |
| `FINISHED` | 再次 `feedEnvelope` | 定义非法：断言失败（测试断言） |

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 会话内无峰 | `finish()` 返回 `null`；L3 仍写占位指标行 |
| 只有 1 个峰 | `chewCount == null`、`avgChewIntervalSeconds == null`、`speedGrade == null` |
| 极短会话（无有效 patch） | `finish()` 返回 `null` |
| 包络全 0（静音） | `σ = 0` → 阈值 = 0 → 无局部极大值 → `null` |
| 连续强噪声（风扇/说话） | 宽峰过滤大量排除；若保留峰仍异常多，`MAE` 评估暴露问题（FF-21g 降级线） |
| `finish()` 重复调用 | 定义非法：第二次抛错（测试断言） |
| 暂停后再恢复 | 包络继续追加；**跨越暂停点的间隔对无效**，不参与 `avgChewIntervalSeconds` |
| `rmsEnvelope` 长度 ≠ `envelopeLength` / `hopMs` 非法 | `ACD-BEH-001`（`retryable=false`），由会话层决定是否终止会话 |
| `includeEnvelope = false`（事件无 `rmsEnvelope`） | `ACD-BEH-001`；**不得**回退为从 PCM 重算包络（FF-21i） |
| `tStartMs` 回退 / `endMs` 早于最后一次 `tStartMs` | `ACD-BEH-001` |

## 3. 接口契约
> 权威定义：`API-02` §5。**类名、字段名、方法签名不得改动。**

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L4 内部（会话层 → 本功能） | `BehaviorAnalyzer.feedEnvelope(Float32List rmsEnvelope, {required int hopMs, required int tStartMs})` | **原生侧算好的 RMS 包络**（FF-21h）、包络帧移、patch 起始墙钟毫秒（三者均取自 `API-01` §3.2 的 `patch` 事件） | `void` | `ACD-BEH-001` |
| L4 内部 | `BehaviorAnalyzer.finish({required int endMs})` | 会话结束墙钟毫秒 | `BehaviorMetrics?` | `ACD-BEH-001` |
| L4 内部 | `BehaviorAnalyzer.reset()` | — | `void`（幂等） | 无 |
| 本功能 → `A-01` | `BehaviorMetrics.avgChewIntervalSeconds` | — | `double?` | — |
| 本功能 → `D-01` | `behavior_metrics` 表字段 | — | 结构化字段（**无 BLOB**，FF-24 §3） | `ACD-DB-002` |
| 本功能依赖 | `SessionSummary.firstVoicedAtMs` / `lastVoicedAtMs` / `endReason` | — | `int?` / `enum` | — |

```dart
class BehaviorMetrics { int? chewCount; double? avgChewIntervalSeconds; int? durationSeconds; String? speedGrade; }
abstract class BehaviorAnalyzer {
  void feedEnvelope(Float32List rmsEnvelope, {required int hopMs, required int tStartMs});
  BehaviorMetrics? finish({required int endMs});
  void reset();
}
class BehaviorConfig { int mealEndSilenceSeconds; int chewMinPeakDistanceMs; int chewMaxPeakWidthMs;
                       double speedFastSeconds; double speedNormalSeconds; }
```

## 4. 数据契约
| 项 | 类型 | 可空 | 值域 / 约束 |
|---|---|---|---|
| `chewCount` | `int?` | 是 | 峰检测 + 伪峰过滤后的计数；证据不足为 `null`（不用 0）；展示时必须带「约」或走降级文案（FF-21f/FF-21g） |
| `avgChewIntervalSeconds` | `double?` | 是 | 单位秒；有效峰 `< 2` 时为 `null`（不用 0）；`A-01` 必须先判 `!= null` 再使用 |
| `durationSeconds` | `int?` | 是 | `≥ 0`；按 `API-02` §5 公式取整，不含暂停；无有效证据为 `null` |
| `speedGrade` | `String?` | 是 | 枚举 `'偏快'` / `'正常'` / `'偏慢'`（FF-21e）；`avgChewIntervalSeconds == null` 时也为 `null`；**不得新增第四值** |
| 包络序列 / 峰值统计（内部态） | `List<double>` | — | 会话内存在，**由原生侧随 `patch` 事件下发**（FF-21h）；**不落盘、不入库**（FF-24）；`reset()` 后清空 |
| `behavior_metrics` 列 | — | — | 权威定义见 `SPEC-D-01`；字段可空并支持**占位行**（`API-03` §2.3）；**禁止 BLOB 音频列**（FF-24 §3） |
| `MAE` 评估产物 | 文件 | — | `docs/reports/p07_chew_mae.md`（**D7 实测产出**，含标注集说明） |

## 5. 参数与常量
| 项 | 引用 |
|---|---|
| 进食结束判据（`BehaviorConfig.mealEndSilenceSeconds`） | FF-21a（**不是 30 s**） |
| 咀嚼峰最小间距（`chewMinPeakDistanceMs`） | FF-21b |
| 峰值动态阈值 | FF-21c（本会话 `μ + 0.5σ`；**该 σ 是包络统计量，与 X-07 无关**） |
| 伪峰过滤（`chewMaxPeakWidthMs` 与孤立峰判据） | FF-21d |
| 进食速度划界（`speedFastSeconds` / `speedNormalSeconds`） | FF-21e |
| 咀嚼次数文案「约」 | FF-21f |
| MAE 降级线 | FF-21g（**阈值取自配置，不得硬编码**） |
| ❌ 不交付项 | FF-21j（咀嚼节律标准差 σ，`X-07`） |
| **包络来源与帧参数** | **FF-21h**（包络由原生侧计算，帧长 / hop 与长度公式均见该编号）；本功能只读 `rmsEnvelope` / `envelopeHopMs`（`API-01` §2.3/§3.2） |
| **算法位置分工** | **FF-21i**：包络计算在 Kotlin（L1），平滑与峰值检测在本功能（Dart/L4）；完整架构裁定见 `API-01` §7 |
| 包络长度 `envelopeLength` | **不在此复制字面值**：由 FF-21h 的公式给出；运行时真值以 `API-01` §2.3 出参与 `API-01` §2.8 的 `getEnvelopeCapability()` 为准 |
| patch 采样数与时长 | FF-09（上游上下文；本功能已不直接消费 PCM） |
| 平滑窗长（50 ms）/ MAE 降级线 | **未在 FF 中冻结**：定义在 `feature_config.behavior`，代码只读不写；登记见 §10 第 2 条，标定记录写 `docs/reports/p07_chew_mae.md` |
| 宣传口径 | FF-25（禁止「准确识别」；指标必须标注实测） |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| `rmsEnvelope` 缺失 / 长度 ≠ `envelopeLength` / `hopMs` 非法 | 长度与自洽性断言 | `ACD-BEH-001`（`retryable=false`） | 无（诊断可见） |
| `tStartMs` 非单调 / `endMs` 顺序非法 | 单调性与顺序断言 | `ACD-BEH-001` | 无 |
| 会话内无峰 | `chewCount == null` | `finish()` 返回 `null`；L3 仍写占位指标行 | 「本次未测到明确咀嚼节奏」 |
| `MAE > FF-21g 的降级线` | 离线评估脚本 | 文案降级为「咀嚼节奏：较快」，**不给绝对数字** | 「咀嚼节奏：较快」 |
| 只用 1 个峰 | 峰数 < 2 | 三字段均为 `null` | 只显示进食时长 |
| 包络统计量 `σ = 0`（全程静音） | 阈值计算 | 返回 `null`，不进入峰检测 | 同「无峰」 |
| 暂停跨越峰对 | 会话层标记 | 该间隔对置为无效，不参与均值 | 无 |
| `finish()` 后继续 `feedEnvelope` | 状态断言 | 抛错（开发期） | 无 |
| ✅ 数据源缺口（原 `patch` 事件不携带 `pcm`）**已关闭（ADR-01）** | — | `patch` 事件携带 `rmsEnvelope` / `envelopeHopMs`（FF-21h）；**不得**自行在 Dart 侧从 PCM 重建包络（FF-21i） | 无 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 最小间距生效（FF-21b） | `flutter test test/domain/behavior_peaks_test.dart` 的 `minPeakDistance_applied` | 构造间隔 150 ms 的两峰 → 只保留 1 个；间隔 250 ms → 保留 2 个 |
| 2 | 动态阈值生效（FF-21c） | 同上 `dynamicThreshold_mu_plus_halfSigma` | 阈值 == `mean(envelope) + 0.5 × std(envelope)`（差 < 1e-9） |
| 3 | 宽峰过滤（FF-21d 前段） | `behavior_pseudo_peak_test.dart` 的 `widePeak_removed` | 峰宽 > `chewMaxPeakWidthMs` 被排除；小于者保留 |
| 4 | 孤立峰过滤（FF-21d 后段） | 同上 `isolatedPeak_removed` | 前后无邻峰的峰被排除 |
| 5 | 速度评级三档（FF-21e） | `behavior_speed_test.dart` 的 `speedGrade_threeValues` | 合成「每 0.7 s 一个峰」→ `avgChewIntervalSeconds ≈ 0.7` 且 `speedGrade == '正常'`；两侧边界按 `speedFastSeconds`/`speedNormalSeconds` 划界 |
| 6 | 证据不足用 `null`（不用 0 / 不用第四档） | `behavior_speed_test.dart` 的 `singlePeak_givesNulls` | 峰数 < 2 时 `chewCount == null && avgChewIntervalSeconds == null && speedGrade == null` |
| 7 | 无峰返回 `null` 且仍可落库占位 | `behavior_finish_test.dart` 的 `noPeak_returnsNull` + `flutter test test/data/placeholder_metrics_test.dart` | `finish()` 返回 `null`；L3 仍插入 1 行全 `NULL` 指标（`API-03` §2.3） |
| 8 | `reset()` 幂等 | `behavior_finish_test.dart` 的 `reset_isIdempotent` | 连调 2 次 `reset()` 不抛错；统计归零 |
| 9 | 暂停不计时长 | `behavior_duration_test.dart` 的 `pauseExcludedFromDuration` | 暂停 10 s 的会话 `durationSeconds` 不含这 10 s |
| 10 | 输入校验与错误码 | `behavior_input_test.dart` 的 `badInput_throwsACD_BEH_001` | `rmsEnvelope` 缺失或长度不符 / `hopMs` 非法 / `tStartMs` 回退 / `endMs` 顺序非法 → `ACD-BEH-001`，`retryable == false` |
| 11 | 咀嚼次数 MAE 评估（FF-21g） | `python ai/scripts/chew_mae_report.py --labels <set>` | 输出 MAE 百分比并写入 `docs/reports/p07_chew_mae.md`；**MAE > 配置降级线时必须在报告中标注「文案降级生效」** |
| 12 | 文案降级生效 | `flutter test test/domain/chew_copy_test.dart`（注入降级标志） | 降级时渲染「咀嚼节奏：较快」且**不含任何数字**；非降级时匹配正则 `约\s*\d+\s*次` |
| 13 | **σ 未实现（X-07）** | `python ai/scripts/assert_x07_not_implemented.py` | 命中数 == 0；`BehaviorMetrics` 无 σ 字段（反射断言字段名集合 == 4） |
| 14 | 无硬编码阈值 | `python ai/scripts/assert_no_hardcoded_behavior.py` | 命中数 == 0（阈值只来自 `BehaviorConfig`） |
| 15 | 失败隔离 | `flutter test test/domain/behavior_failure_isolated_test.dart` | 行为分析抛 `ACD-BEH-001` 时识别与记录主链路仍完成 |
| 16 | **输入为原生包络（FF-21h/FF-21i），不存在 PCM 入参** | `flutter test test/domain/behavior_envelope_input_test.dart` 的 `envelopeOnlyInput_noPcmParam` + `flutter test test/domain/behavior_smoothing_test.dart` 的 `smoothingWindow_50ms` | ① 反射断言 `BehaviorAnalyzer` / 实现类的方法签名中**不含任何 PCM / 样本数组入参**；② 平滑窗长 == 50 ms（差 < 1e-9）；③ 用 `FakeEnvelopeSource`（固定包络数组）即可完成峰检测，**无需任何设备或真实音频**（缓解措施见 `API-01` §7「代价与缓解」） |

## 8. 非功能约束
- **实时性**：`feedEnvelope` 不再做 RMS 计算（已下沉原生，FF-21h/FF-21i），本功能只做入队、平滑与峰检测；单次目标 < 16 ms（**目标值，非承诺值**，实测出自 D7，`API-02` §5）；峰检测延迟到 `finish()`。
- **内存**：包络序列按 `hopMs` 累积，会话结束即释放；跨 isolate 传递的是**包络数组**（长度见 FF-21h）、**不是** `patch_samples` 数组（`API-02` §5：与推理同一后台 isolate）。
- **鲁棒性**：行为分析失败**不得**阻断识别与记录主链路（§7 判据 15）。
- **隐私**：只处理内存中的 RMS 包络（原始 PCM 由原生侧消费后不再上传，FF-21i），包络与指标不落盘音频（FF-24 §1/§3）。
- **无障碍**：本功能无 UI；文案与图表的无障碍由 `U-02`/`U-03` 承担。

## 9. 裁剪与未做
- **本功能不属于「不可砍」五项之一**（`00_功能清单` §6：五项为实时检测闭环、自动记录、健康报告+评分卡、`parity_test`、三种 Demo 模式）。但它通过 `A-01` 的「进食速度」维（FF-22）与 `U-02`/`U-03` 的行为指标卡**间接支撑 ③健康报告 + 评分卡**。**若必须腾工时，可降级为「只输出 `durationSeconds` 与 `speedGrade`」**；但**不得整项删除**，因为 `A-01` 的 `speed` 维依赖 `avgChewIntervalSeconds`。
- `X-07` 咀嚼节律标准差 σ：**不做**（FF-21j；`API-02`「明确不做」）。禁止顺手实现（含 UI 占位与文案预留位）。
- `X-05` 检测页「识别历史」列表、`X-06` RIR / Mixup 增强：**不做**。
- IMU / 加速度计融合、吞咽检测、咬合力度、单口大小、个体化阈值学习、按食物类别分别统计咀嚼次数：**不做**。

## 10. 开放问题
1. ✅ **已关闭（依据 ADR-01）**：原先本功能**没有数据源**（`API-01` 的 `patch` 事件只带 `mel` / `rms` / `voiced`，而原设计输入为 4.096 s 时域 PCM）。**结论**：采用候选 ② —— 包络由**原生侧**计算（FF-21h）并随 `patch` 事件下发 `rmsEnvelope` / `envelopeHopMs`，本功能签名改为 `feedEnvelope`；平滑与峰值检测仍留在 Dart（FF-21i）。已落入 `API-01` §2.3/§3.2/§7、`API-02` §5、本 SPEC §2.1/§3，登记走 `PLAN-C-03`。**无需再拍板。**
2. **包络帧参数已定、平滑窗长已登记**：包络帧长 / hop 与长度公式已由 **FF-21h** 冻结（原生侧计算，`API-01` §7），原先「包络窗长未冻结」的陈述作废；**✅ 已登记（依据 `ADR-P3`，2026-09-10）**：**平滑窗长 50 ms**（`smoothing_window_ms`）与 **MAE 降级线 0.25**（`chew_count_mae_degrade_ratio`）已随 `ADR-P3` 补入 `feature_config.behavior`（**4 → 11 键**，顶层 31 → **41 键**：`ADR-P3` 补至 34，`ADR-16`/`ADR-17` 再加 7 个音频键），登记路径仍为 `PLAN-C-03`。
3. **`MAE` 的标注集从哪来未定**：FF-21g 要求 MAE 与降级线比对，但仓库中尚无人工标注的咀嚼次数数据集。**需 C 在 D0–D2 的自采过程中同步产出标注**（每人每段音频标 1 个数）。这是本功能最大的前置风险。
4. **暂停跨越峰对的处理**是否应改为「按暂停前/后分段各自求均值」：本 SPEC 选择「置为无效」，**需 B 内部确认**。
5. **✅ 已关闭（依据 `ADR-P1`）**：`n_frames` 原冻结为 ~~`129`~~ → **`ADR-21`（2026-09-12）修订为 `n_frames = 128`**（`129` 现为 `raw_mel_frames`，见 FF-11 / `ADR-21`）—— 对本功能无影响（本功能输入为**原生侧算好的 RMS 包络**，不经过 Mel）。

**文档结束**
