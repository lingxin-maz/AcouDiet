# PLAN-P-07 行为分析（咀嚼/时长/速度）

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-P-07 |
| 负责 | B（主责）；C 提供咀嚼次数人工标注集；A 协助 FF-21g 的 MAE 评估口径 |
| 目标日 | D7 |
| 前置依赖 | `PLAN-P-02` 的 `patch.rmsEnvelope` 产出（**与 `PLAN-P-07` 共用同一份分帧实现**，FF-21h）与静默判据；`PLAN-P-01` 的 `SessionSummary`；`PLAN-C-03` 的 `behavior` 配置段；**人工标注集**（C，D0–D2 自采同步产出） |
| 预估工时 | 7 h（与 §2 WBS 的「合计：7 h」一致；📌 表头原写 6 h，属既有笔误，已对齐） |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `lib/domain/behavior_analyzer.dart` | `BehaviorMetrics` / `BehaviorAnalyzer`（**签名不得改**） |
| 2 | `lib/domain/rms_envelope.dart` | 包络入参校验 + **50 ms 滑动平均平滑**（**短时 RMS 计算已下沉原生，FF-21h；本文件不得从 PCM 重算包络**） |
| 3 | `lib/domain/peak_detector.dart` | 峰检测（FF-21b/FF-21c）+ 伪峰过滤（FF-21d） |
| 4 | `lib/domain/speed_grader.dart` | FF-21e 三档评级（证据不足时返回 `null`，**不得新增「数据不足」档**） |
| 5 | `test/domain/behavior_peaks_test.dart` | 最小间距 + 动态阈值 |
| 6 | `test/domain/behavior_pseudo_peak_test.dart` | 宽峰 / 孤立峰过滤 |
| 7 | `test/domain/behavior_speed_test.dart` | 三档边界 + 不可得语义 |
| 8 | `test/domain/behavior_finish_test.dart` | `null` 返回、重复 `finish` 非法 |
| 9 | `test/domain/behavior_duration_test.dart` | 暂停不计时长 |
| 10 | `test/domain/chew_copy_test.dart` | 「约」字强制（FF-21f）与降级文案（FF-21g） |
| 11 | `test/domain/behavior_failure_isolated_test.dart` | 行为分析失败不阻断主链路 |
| 12 | `ai/scripts/chew_mae_report.py` | 咀嚼次数 MAE 评估（FF-21g） |
| 13 | `ai/scripts/assert_x07_not_implemented.py` | `X-07`（节律 σ）未实现断言 |
| 14 | `ai/scripts/assert_no_hardcoded_behavior.py` | 阈值硬编码扫描 |
| 15 | `records/reports/p07_chew_mae.md` | MAE 报告（**D7 实测产出**）+ 平滑窗与 MAE 降级线标定记录 |
| 16 | `shared/feature_config.json` 的 `behavior` 段（经 `PLAN-C-03`） | 平滑窗/降级线的单一真源（包络帧长与 hop 引用 FF-21h） |
| 17 | `test/domain/fake_envelope_source.dart` | **`FakeEnvelopeSource`**：用固定包络数组喂入 `BehaviorAnalyzer`，使平滑与峰值检测可在**无设备**时单测（`API-01` §7「代价与缓解」） |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 定义 `behavior` 配置键（平滑窗 50 ms、MAE 降级线；包络帧长/hop 直接引用 FF-21h） | 交付物 16 | 0.5 h | `PLAN-C-03` |
| 2 | 包络入参校验 + 50 ms 滑动平均平滑（**RMS 计算在原生侧，FF-21h**） | 交付物 2 | 1 h | 1、`PLAN-P-02` |
| 3 | 动态阈值 + 局部极大值检测 | 交付物 3 | 1 h | 2 |
| 4 | 伪峰过滤（宽峰 > 150 ms、孤立峰） | 交付物 3/6 | 1 h | 3 |
| 5 | 最小间距约束与峰合并 | 交付物 3/5 | 0.5 h | 3 |
| 6 | 速度评级三档（不足返回 `null`） | 交付物 4/7 | 0.5 h | 5 |
| 7 | 进食时长（FF-21a 判据消费）+ 暂停剔除 | 交付物 9 | 0.5 h | `PLAN-P-02` |
| 8 | 文案层「约」与降级 | 交付物 10 | 0.5 h | 6 |
| 9 | MAE 评估脚本 + 报告 + 标定 | 交付物 12/15 | 1 h | 标注集（C） |
| 10 | 静态扫描 + 失败隔离回归 | 交付物 11/13/14 | 0.5 h | — |

**合计：7 h**，计入域 P 总工时。

## 3. 技术方案
**位置**：`API-01` §3.2 的 `patch.rmsEnvelope`（**原生侧算好的 RMS 包络**，FF-21h；由 `SPEC-P-02` 在**同一次分帧遍历**中产出）→ **本功能（独立于 Mel/推理链路）** → `D-01` 的 `behavior_metrics` 表 / `U-02`·`U-03` 展示 / `A-01` 的 `speed` 维。

**关键骨架（≤30 行，仅示意结构）**：
```dart
class RmsBehaviorAnalyzer implements BehaviorAnalyzer {
  final List<double> _envelope = [];
  var _finished = false;

  @override
  void feedEnvelope(Float32List rmsEnvelope, {required int hopMs, required int tStartMs}) {
    assert(!_finished);
    if (rmsEnvelope.length != expectedEnvelopeLength || hopMs <= 0)
      throw AcdError('ACD-BEH-001');            // 包络缺失 / 长度不符 / hopMs 非法（FF-21h），非 0/告警
                                                // expectedEnvelopeLength 来自 startSession 出参与 getEnvelopeCapability()（API-01 §2.3/§2.8）
    _envelope.addAll(rmsEnvelope);              // 原生已算好：直接入队，本层不做 RMS 计算（FF-21i）
  }

  @override
  BehaviorMetrics? finish({required int endMs}) {
    assert(!_finished); _finished = true;
    final smoothed = movingAverage(_envelope, cfg.smoothWindowMs);       // 主方案 §5.4 步骤 2（50 ms）
    final threshold = mean(smoothed) + 0.5 * std(smoothed);              // FF-21c
    var peaks = localMaximaAbove(smoothed, threshold);
    peaks = removeWidePeaks(peaks, cfg.chewMaxPeakWidthMs);              // FF-21d 前段
    peaks = removeIsolatedPeaks(peaks, cfg.isolationGapMs);              // FF-21d 后段（邻域半径）
    peaks = enforceMinInterval(peaks, cfg.chewMinPeakDistanceMs);        // FF-21b
    if (peaks.isEmpty) return null;                                      // 无证据：null，L3 仍写占位行
    final avg = peaks.length < 2 ? null : averageIntervalSeconds(peaks); // <2 峰 → null（不是 0）
    return BehaviorMetrics(chewCount: avg == null ? null : peaks.length,
        avgChewIntervalSeconds: avg, durationSeconds: durationSeconds,
        speedGrade: avg == null ? null : gradeSpeed(avg));               // FF-21e，仅三档或 null
  }

  @override
  void reset() { _envelope.clear(); _finished = false; }                 // 幂等，会话边界调用
}
```
**要点**：
1. 包络阈值与间隔**全部取自配置**（`PLAN-C-03`），代码内出现 `150`/`200`/`300` 等字面量即判失败。
2. FF-21c 的 `σ` 是**包络统计量**；**`X-07` 的「咀嚼节律标准差」不得实现**——两者名字相近，是本功能最容易被顺手做错的地方，用 `assert_x07_not_implemented.py` 钉死。
3. 无峰返回 `null`，不得返回 `chewCount = 0` 的假指标（否则 UI 会显示「约 0 次」）；**返回 `null` 不等于不落库**——L3 仍写一行全 `NULL` 占位指标（`API-03` §2.3）。
4. 峰数 `< 2` 时 `chewCount`/`avgChewIntervalSeconds`/`speedGrade` **均为 `null`**（不用 0、不用「数据不足」第四档，`API-02` §5）。
5. 输入校验必须抛 `ACD-BEH-001`（`rmsEnvelope` 缺失/长度不符、`hopMs` 非法、`tStartMs` 单调性、`endMs` 顺序），**不得只告警**（`API-02` §5）。
6. 行为分析失败必须被隔离：主链路（识别 → 记录）不因此中断。
7. 文案规则在渲染层强制：非降级必须匹配 `约\s*\d+\s*次`；降级必须无数字。
8. ✅ **数据源已就位（ADR-01）**：输入为 `API-01` §3.2 的 `patch.rmsEnvelope`（FF-21h），签名已改为 `feedEnvelope`（`API-02` §5）；**不得**在 Dart 侧从 PCM 重算包络，也**不得**自带第二套分帧实现（FF-21i；分帧唯一实现见 `PLAN-P-02` §3）。
9. **无设备可测性**：用交付物 17 的 `FakeEnvelopeSource` 喂固定包络数组，使平滑与峰值检测的单元测试**不依赖麦克风、真机或原生层**（`API-01` §7「代价与缓解」）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `behavior_peaks_test.minInterval_200ms` | Dart 单测 | 间隔 150 ms 只留 1 峰；250 ms 留 2 峰 | D7 每次提交 |
| `behavior_peaks_test.dynamicThreshold_mu_plus_halfSigma` | Dart 单测 | 阈值 == `μ + 0.5σ`（差 < 1e-9） | D7 |
| `behavior_pseudo_peak_test.widePeak_gt150ms_removed` | Dart 单测 | 200 ms 宽峰被排除；100 ms 保留 | D7 |
| `behavior_pseudo_peak_test.isolatedPeak_removed` | Dart 单测 | 前后 300 ms 无邻峰者被排除 | D7 |
| `behavior_speed_test.speedGrade_threeValues` | Dart 单测 | 合成「每 0.7 s 一个峰」→ `avg ≈ 0.7` 且 `speedGrade == '正常'`；两侧边界按 `speedFastSeconds`/`speedNormalSeconds` 划界 | D7 |
| `behavior_speed_test.singlePeak_givesNulls` | Dart 单测 | 峰数 < 2 时 `chewCount == null && avgChewIntervalSeconds == null && speedGrade == null` | D7 |
| `behavior_input_test.badInput_throwsACD_BEH_001` | Dart 单测 | `rmsEnvelope` 缺失/长度不符 / `hopMs` 非法 / `tStartMs` 回退 / `endMs` 顺序非法 → `ACD-BEH-001`，`retryable == false` | D7 |
| `behavior_envelope_input_test.envelopeOnlyInput_noPcmParam` | Dart 单测（反射） | 实现类方法签名**无 PCM / 样本数组入参**；输入仅为 `rmsEnvelope` + `hopMs` + `tStartMs`（FF-21h/FF-21i） | D7 |
| `behavior_smoothing_test.smoothingWindow_50ms` | Dart 单测 | 平滑窗长 == 50 ms（差 < 1e-9） | D7 |
| **`FakeEnvelopeSource`（交付物 17）驱动全部峰检测用例** | Dart 单测（**无设备**） | `behavior_peaks_test` / `behavior_pseudo_peak_test` / `behavior_speed_test` 全部用固定包络数组喂入即可跑通：**不打开麦克风、不依赖原生层、不需真机**（`API-01` §7「代价与缓解」） | D7 每次提交 |
| `behavior_finish_test.reset_isIdempotent` | Dart 单测 | 连调 2 次 `reset()` 不抛错；统计归零 | D7 |
| `behavior_finish_test.noPeak_returnsNull` / `finishTwice_throws` | Dart 单测 | 无峰返回 `null`；重复 `finish()` 抛错 | D7 |
| `behavior_duration_test.pauseExcludedFromDuration` | Dart 单测 | 暂停时长不计入 | D7 |
| `chew_copy_test.nonDegradedCopy_containsYue` | Dart 单测 | 文案匹配 `约\s*\d+\s*次` | D7 |
| `chew_copy_test.degradedCopy_hasNoDigits` | Dart 单测 | 降级文案为「咀嚼节奏：较快」且无数字 | D7 |
| `behavior_failure_isolated_test` | Dart 单测（注入抛错 analyzer） | 识别与落库仍完成 | D7 / D8 |
| `chew_mae_report.py --labels <set>` | 离线评估 | 输出 MAE 百分比；写入 `records/reports/p07_chew_mae.md`；超降级线时标注「文案降级生效」 | D7 |
| `assert_x07_not_implemented.py` | 静态扫描 | 命中数 == 0 | D7 / D10 |
| `assert_no_hardcoded_behavior.py` | 静态扫描 | 命中数 == 0 | D7 / D10 |
| **D7 硬验收**「约 45 次，偏快」 | 真机手测（人工核对表） | `PLAN-00` §1 D7 行输出形态正确（带「约」+ 速度评级） | D7 |

## 5. 完成定义（DoD）
- [ ] `SPEC-P-07` §7 全部 **16** 条判据通过（**必需项**；第 11 条依赖 C 的标注集）。
- [ ] 交付物 1–**17** 全部存在且路径一致。
- [ ] `API-02` §5 的 `BehaviorMetrics`（四字段**全部可空**）/ `BehaviorAnalyzer`（`feedEnvelope` + `finish` + `reset`）/ `BehaviorConfig` 签名与实现**逐字一致**（含 `feedEnvelope(Float32List rmsEnvelope, {required int hopMs, required int tStartMs})`）；`ACD-BEH-001` 已登记 `API-00` §3.5（ADR-08）。
- [ ] 输入契约已同步为**包络**（FF-21h）：实现中不存在 PCM 入参、不存在第二套分帧实现；`test/domain/fake_envelope_source.dart` 存在且被峰检测用例使用（无设备可单测）。
- [ ] **`X-07` 未实现**已由静态扫描与字段审查双重证明（`BehaviorMetrics` 字段名集合恰为 4 个）。
- [ ] FF-21f/FF-21g 文案规则在渲染层强制通过测试。
- [ ] **D7 硬验收**：能输出「约 45 次，偏快」（`PLAN-00` §1 D7 行 / CP4 判定）。
- [ ] `MAE` 实测值已写入 `records/reports/p07_chew_mae.md`；若超线，降级已生效且报告留痕。
- [ ] 行为分析失败不阻断主链路（注入式测试）；无证据时 `finish()` 返回 `null` 且 L3 仍写占位指标行。
- [ ] `behavior` 段已进 `feature_config` 并完成 `PLAN-C-03` 变更传播登记。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| ✅ **`pcm` 无合法数据源**（`API-02` §9 第 1 条）**已消除（ADR-01）** | — | 结论：输入改为原生侧下发的 `rmsEnvelope`（FF-21h），签名改为 `feedEnvelope`；同步已落入 `API-01` §3.2、`API-02` §5、本 PLAN §3/§4，登记走 `PLAN-C-03`。**不再阻塞开工。** |
| **无人工标注集**（MAE 无法计算） | D7 前标注集为空 | **立即降级**：文案一律使用「咀嚼节奏：较快/正常/偏慢」形态，**不给绝对数字**；报告中如实说明「MAE 未评估」 |
| `MAE > FF-21g 降级线` | 评估脚本输出超线 | 按 SPEC §2.2 步骤 10 降级文案；不得调低阈值来「通过」 |
| 峰检测在真实环境噪声下误检多 / 工时不足 | 真机手测异常；D7 中午峰检测未通 | 先调包络与平滑窗参数（走 `PLAN-C-03` 登记）；仍差或工时不足则按 `SPEC-P-07` §9 顺序降级：先保 `durationSeconds` + `speedGrade`（`A-01` 的 `speed` 维依赖），咀嚼次数最后补 |
| 与 `PLAN-P-02` 的静默判据口径不一致 | 时长偏差 | 以 `FF-21a` 为唯一口径，双方引用同一 `SessionSummary` 时间戳 |

## 7. 与检查点的关系
- **CP4（D7 晚：报告页数据已接通真实记录）**：`PLAN-00` §2 把 CP4 的关联 PLAN 列为 `PLAN-A-01`/`PLAN-A-03`/`PLAN-A-04`；本功能提供 `A-01` 的 `speed` 维输入（FF-22），是 CP4 数据链的组成部分。
- **D7 硬验收**：`PLAN-00` §1 D7 行「能输出「约 45 次，偏快」」——由本功能与 `A-01` 共同承担。
- 本功能**不在关键路径上**：`PLAN-00` §3 的关键路径为 `D0 → P-04 → T-08 → T-07 → P-05 → D5 闭环 → D9 Demo`。因此 D6–D8 若需腾工时，**本功能是优先被降级/简化的对象之一**（按 SPEC §9 的降级顺序），但不得整项删除（`A-01` 的 `speed` 维依赖它）。
- 未完成时的 CP 处置：CP4 未通 → 启用预置演示数据集（`A-04`），放弃真实累积。

**文档结束**
