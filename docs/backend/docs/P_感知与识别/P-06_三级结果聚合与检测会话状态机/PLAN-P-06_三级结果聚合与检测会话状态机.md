# PLAN-P-06 三级结果聚合与检测会话状态机

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-P-06 |
| 负责 | B（主责）；C 协助 `U-02` 的二选一交互与 `A-01` 的记录字段；A 协助 FF-20b 阈值标定 |
| 目标日 | D6 |
| 前置依赖 | `PLAN-P-05` 的 `InferenceResult` 可用；`PLAN-P-02` 的 `voiced` 标记可用；`PLAN-C-03` 的三档阈值常量；**D3 自采跨域测试集**（FF-20b 标定）；`SPEC-P-06` §10 第 1 条签名裁定（A/B） |
| 预估工时 | 9 h |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `lib/domain/vote_aggregator.dart` | `VoteStage` / `AggregatedDecision` / `VoteAggregator`（**签名不得改**） |
| 2 | `lib/domain/detection_session_controller.dart` | 检测会话状态机（Dart 侧镜像 `API-01` §4）+ 收尾事务触发 |
| 3 | `lib/domain/confirmation_gateway.dart` | 二选一确认的唯一入口（**只接受「是/否」**，`X-02`） |
| 4 | `test/domain/vote_aggregator_ema_test.dart` | Level 1 |
| 5 | `test/domain/vote_aggregator_confirm_test.dart` | Level 2 |
| 6 | `test/domain/vote_aggregator_level3_test.dart` | Level 3 两档边界（`tauLow`） |
| 7 | `test/domain/vote_aggregator_stage_table_test.dart` | `VoteStage` 五值按序判定（复刻 `API-02` §4 判定表） |
| 8 | `test/domain/vote_aggregator_state_test.dart` | FF-20c 跨 patch 保持 |
| 9 | `test/domain/vote_aggregator_silent_test.dart` | 静默 patch 语义（与 `PLAN-P-02` 共管） |
| 10 | `test/domain/vote_aggregator_seq_test.dart` | 幂等与跳号 |
| 11 | `test/domain/no_log_when_low_test.dart` | `p < tauLow` 不写日志 |
| 12 | `test/domain/binary_confirm_test.dart` | 只存在二选一 API（`X-02` 断言） |
| 13 | `test/domain/confirm_dedup_test.dart` | 会话内同类去重 |
| 14 | `test/domain/vote_aggregator_timing_test.dart` | 首次确认下界（不含预测值） |
| 15 | `test/domain/vote_aggregator_lifecycle_test.dart` | 会话边界释放与 `reset()` |
| 16 | `records/reports/p06_threshold_calibration.md` | FF-20b 标定过程 + 直方图（**D3 实测产出**） |
| 17 | `ai/scripts/assert_no_hardcoded_thresholds.py` | 阈值硬编码扫描 |
| 18 | `ai/scripts/check_thresholds_calibrated.py` | 标定完成度断言 |
| 19 | `shared/feature_config.json` 的 `voting` 段（经 `PLAN-C-03`） | `emaWindow`/`emaAlpha`/`confirmConsecutivePatches`/`tauConfirm`/`tauLow` 的单一真源；`ADR-47` 追加 `confirmation_mute_seconds`（FF-20d） |
| 20 | `test/domain/confirmation_mute_test.dart` | FF-20d 会话内静默窗口：窗口边界 / 按 `classId` / 按会话 / 不自动落库 / 答复同步生效（`ADR-47`） |
| 21 | `tool/session_tests.dart` 的 `_confirmationMuteChecks()` | 同一批断言的**离线等价物** + `negative control` 对照组（未作答的同一脚本仍在提问） |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 确认 `add()` 静默调用规则（沿用最近结果 / 改可空）并回写 `API-02` 与 SPEC | 裁定记录 | 0.5 h | A/B |
| 2 | `voting` 配置键定义（对齐 `API-02` §4 的 `VotingConfig`）+ `PLAN-C-03` 变更单 | 交付物 19 | 0.5 h | 1 |
| 3 | `VoteAggregator` EMA + 连续计数 + 五值判定表 | 交付物 1/4/5/6/7 | 2 h | 2 |
| 4 | 静默/幂等/跳号语义实现 | 交付物 1/9/10 | 1 h | 3 |
| 5 | `AggregatedDecision` 字段一致性 + `reset()` 生命周期 | 交付物 1/15 | 0.5 h | 3 |
| 6 | 二选一确认入口（只接受「是/否」）与去重 | 交付物 3/12/13 | 1 h | 3 |
| 7 | 检测会话状态机 + 收尾事务触发（对接 `D-01`/`D-02`） | 交付物 2 | 1 h | 3、`PLAN-D-02` |
| 8 | FF-20b 阈值标定（直方图 + 报告），与 A 同批 | 交付物 16 | 1.5 h | D3 数据 |
| 9 | 静态扫描 + 标定断言脚本 | 交付物 17/18 | 0.5 h | 8 |
| 10 | 与 `PLAN-P-02` / `PLAN-U-02` 联调 | 回归记录 | 0.5 h | 4、7 |
| 11 | 会话内同级静默窗口（FF-20d，`ADR-47`）+ 负例对照 | 交付物 20/21 | 1 h | 7 |

**合计：9 h**，计入域 P 总工时（`PLAN-00` §5）。

## 3. 技术方案
**位置**：`SPEC-P-05` 的 `InferenceResult` → **本功能（推理 isolate 内）** → `U-02`（呈现）/ `D-01`/`D-02`（落库）。

**关键骨架（≤30 行，仅示意结构）**：
```dart
class VoteAggregator {
  final List<double> _ema = List.filled(6, 0.0);
  var _seen = 0, _consecutive = 0, _lastTop1 = -1, _lastSeq = -1;
  bool _initialized = false;

  AggregatedDecision add(InferenceResult r, {required int seq, required bool voiced}) {
    if (seq == _lastSeq) return _snapshot();            // 幂等
    if (seq - _lastSeq > 1) _consecutive = 0;           // 丢包：连续计数清零、EMA 保留（API-02 §4）
    _lastSeq = seq;
    // EMA：voiced=true/false 都更新；静默时调用方沿用最近一次结果（API-02 §4）
    if (!_initialized) { _ema.setAll(0, r.probs); _initialized = true; }
    else { for (var c = 0; c < 6; c++) _ema[c] = A * r.probs[c] + (1 - A) * _ema[c]; }
    _seen++;
    if (voiced) {                                        // 连续计数只由 voiced patch 参与
      final top1 = _argmax(_ema);
      _consecutive = (top1 == _lastTop1) ? _consecutive + 1 : 1;
      _lastTop1 = top1;
    }
    return _snapshot();                                  // 五值判定见 API-02 §4 判定表
  }
  void reset() { /* 会话边界唯一允许的调用点 */ }
}
```
**要点**：
1. `VotingConfig` 的 `emaWindow`/`emaAlpha`/`confirmConsecutivePatches`/`tauConfirm`/`tauLow` **全部取自生成常量**（`PLAN-C-03`），文件内出现字面阈值即判失败。
2. `VoteStage` 五值必须**逐行复刻 `API-02` §4 判定表**（含「`none` ⟺ 有效样本数 == 0」「`observing` 覆盖 `p < tauLow` 与窗口未满」），不得新增枚举值。
3. 静默 patch 的语义必须与 `PLAN-P-02`、`SPEC-P-02` §3 完全一致：**仍进入 EMA、不参与连续计数（既不递增也不清零）**。
4. **二选一确认是 v1.0 唯一的「手动」能力**（`X-02`）：`ConfirmationGateway` 的接口签名只接受 `bool` 答复，**不得存在传入 `classId` 的方法**；用签名/反射测试钉死。
5. 聚合必须与 `run()` 同 isolate 执行（`API-02` §4；`API-00` §3.7），状态不跨 isolate 复制。
6. 落库去重键 = `sessionId + classId`，冲突按 `ACD-DB-002` 忽略；`smoothedProbs` **禁止入库**。
7. 降级（步长 → 1.0 s）不改变本功能的语义，只改变 patch 到达间隔。
8. **同级静默窗口（FF-20d）落在会话状态机，不在聚合器**：`VoteStage` 不新增值、`AggregatedDecision` 不新增字段、`VoteAggregator.add()` 签名不变；静默按 `classId` 记账（`Map<int, _ClassMute>`），窗口取自 `FeatureConfig.votingConfirmationMuteSeconds`，`start()` 清空。被静默类别的上报值只有两种：`confirmed`（用户答「是」）与 `observing + classId=null`（用户答「否」），后者同时挡住自动落库。时钟经构造函数注入（`int Function()? clock`），生产传 `null`。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `vote_aggregator_ema_test` | Dart 单测 | EMA 公式差 < 1e-9；首 patch 用真实概率初始化 | D6 每次提交 |
| `vote_aggregator_confirm_test` | Dart 单测 | `M−1` 次不确认；第 `M` 次且 p ≥ `τ_confirm` → `confirmed` | D6 |
| `vote_aggregator_level3_test` | Dart 单测 | `p == tauLow` → `lowConfidence`；`p < tauLow` → `observing` 且 `shouldAskUser == false` | D6 |
| `vote_aggregator_stage_table_test` | Dart 单测（参数化） | 逐行复刻 `API-02` §4 判定表：5 行条件各自命中对应 `stage`，无新增枚举值 | D6 |
| `vote_aggregator_state_test` | Dart 单测 | 10 次 `add()` 后状态未被重置（FF-20c） | D6 |
| `vote_aggregator_silent_test` | Dart 单测 | `voiced=false` 改变 `smoothedConfidence` 但 `consecutiveCount` **不变**（既不递增也不清零，`API-02` §4） | D6（与 `PLAN-P-02` 联跑） |
| `vote_aggregator_seq_test` | Dart 单测 | 重复 `seq` 幂等；跳号使 `consecutiveCount == 0` 且 `smoothedProbs` 保留 | D6 |
| `no_log_when_low_test` | Dart 单测 | 仓储 `insert` 次数 == 0 | D6 |
| `binary_confirm_test` | Dart 单测 | 只有 `bool` 答复入口，无 `classId` 参数 | D6 / D10 |
| `confirm_dedup_test` | Dart 单测 | 同 `sessionId + classId` 只落库 1 次 | D6 |
| `vote_aggregator_timing_test` | Dart 单测 | `confirmed` 时刻 ≥ 第 `M` 个 patch 的 `tStartMs + 4.096 s`（**不含预测值**） | D6 |
| `vote_aggregator_lifecycle_test` | Dart 单测 | `sessionEnded` 后拒绝 `add()`；新会话从初始态起步 | D6 |
| `confirmation_mute_test` | Dart 单测（注入时钟与解码器） | `T+179999 ms` 仍 `shouldAskUser == false`；`T+180000 ms` 恢复 `true`；另一 `classId` 不受影响；新会话不继承；窗口内 `confirmed` 不落库 | D6 每次提交 |
| `tool/session_tests.dart` → `_confirmationMuteChecks()` | 离线套件 + 负例对照 | 与上同源；对照组（**未作答**、同一解码器同一脚本）仍 `shouldAskUser == true`。**把 `_applyMute` 的调用注释掉后该组必须有 ≥ 6 项转红**（实测 8 项） | D6 每次提交 |
| `assert_no_hardcoded_thresholds.py` | 静态扫描 | 命中数 == 0 | D6 / D10 |
| `check_thresholds_calibrated.py` | 脚本 | 标定报告存在且三档阈值来自配置 | D6 / D9 |
| FF-20b 直方图标定 | 离线实验 | 自采跨域集置信度分布 + 三档阈值选点过程写入报告（**实测产出**） | **D3** |
| 连续吃 30 s 稳定性 | 真机手测（人工核对表） | 结果稳定不闪烁（`PLAN-00` D6 硬验收）；核对表见标定报告 | **D6** |

## 5. 完成定义（DoD）
- [ ] `SPEC-P-06` §7 全部 19 条判据通过（**必需项**；#15–#19 为 `ADR-47` 的 FF-20d 静默窗口）。
- [ ] 交付物 1–21 全部存在且路径一致。
- [ ] `API-02` §4 的 `VotingConfig` / `VoteStage` / `AggregatedDecision` / `VoteAggregator` 签名与实现逐字一致；`VoteStage` 五值判定与 `API-02` §4 判定表逐行一致。**FF-20d 不得改动这四处**（窗口在会话层）。
- [ ] `voting` 段（`emaWindow`/`emaAlpha`/`confirmConsecutivePatches`/`tauConfirm`/`tauLow`/`confirmation_mute_seconds`）已进 `feature_config` 并完成 `PLAN-C-03` 变更传播登记；`API-02` §8 的 4 个新增错误码（含 `ACD-INF-004`）已补登 `API-00` §3.5。
- [ ] **FF-20d 静默窗口**：点「否」后同一次检测内该 `classId` 三分钟内不再提问、不再命名、不自动落库；点「是」后同样不再追问且只落一条记录；新会话不继承（`ADR-47`）。
- [ ] **FF-20b 标定完成**：D3 用自采跨域测试集的置信度分布直方图标定三档阈值，过程写进 `records/reports/p06_threshold_calibration.md`。
- [ ] **D6 硬验收**：连续吃 30 s，结果稳定不闪烁。
- [ ] `X-02` 降级被固化：不存在「任意更改类别」的 API 或 UI 入口（测试 + 代码审查）。
- [ ] 「首次确认约 4–5 s」仅以 FF-20a 口径表述；**任何材料中不出现「2 秒内出结果」**（FF-25）。
- [ ] 与 `PLAN-D-02` 的会话收尾事务联调通过（一次事务提交）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 三档阈值标定缺数据（D3 自采样不足） | D3 晚直方图样本量不够 | 用 FF-20 的初值上线，标定推迟到 D6 前补齐；**报告中如实标注「未完成标定」**，不得编造数据 |
| 确认结果闪烁（stage 反复跳） | D6 手测发现 | 加严 `τ_confirm`（须回写 `feature_config` 并走 `PLAN-C-03`）；**不得**改 `M` 与 `α` 之外的口径而不留痕 |
| `lowConfidence` 频繁询问打扰用户 | 真机体验 | **已实现**：会话层按 `FF-20d` 静默已作答的 `classId`（同 `classId` 三分钟内只问一次）；聚合器不改判据 |
| 静默窗口把正常识别也静音了（「否」错点了） | 真机体验 / 用户反馈 | 窗口只有 180 s 且**不跨会话**：`stop()` 后再开始就是干净的；另可让用户重开一次检测立即解除。**不得**把窗口做成永久或全局 |
| 静默期间同一类别又被自动落库 | 饮食记录里出现刚被否掉的食物 | 窗口内该类别不得上报 `confirmed`（`_applyMute` 的 `denied` 分支）；`confirmation_mute_test.dart` 的「不得被自动落库」锁死 |
| 与 `PLAN-P-02` 的静默语义分歧 | 联测 `ema`/`consecutiveCount` 行为不一致 | 以 `API-02` §4 为唯一口径（静默仍进 EMA、连续计数不变），三处文档同时对齐后再改代码 |
| `add()` 签名裁定迟迟未定 | D6 初仍按临时约定实现 | 采用「沿用最近结果」临时约定（本 PLAN 已如此设计），签名一旦裁定只改适配层，不动算法 |
| D6 与 `PLAN-P-02` 争抢同一人日 | D6 中午级别 1/2 未通 | 优先保证 Level 1+2（CP4 与 D8 完整闭环依赖它），Level 3 的二选一交互可借 `U-02` 的占位实现先上线 |

## 7. 与检查点的关系
- **CP2（D5 晚）** 已由 `P-01`→`P-05` 打通；本功能是 **CP4（D7 晚：报告页数据已接通真实记录）** 与 **D8 完整闭环（吃 → 识别 → 记录 → 报告）** 的关键构成。
- **D6 硬验收**：连续吃 30 s，结果稳定不闪烁（`PLAN-00` §1 D6 行）——由本功能与 `P-02` 共同承担。
- **FF-20b 标定在 D3**（与 CP1 同日）：标定未完成会影响 D6–D8 的判定质量，但不阻塞 D5。
- 未完成时的 CP 处置：按 `PLAN-00` §3「任何一环延期，优先砍 D6–D8 的增强功能，绝不动 D5 与 D9」；CP4 未通 → 启用预置演示数据集（`A-04`），放弃真实累积。
- 本功能属「不可砍」五项之①实时检测闭环与②自动生成记录，**不得裁剪**。

**文档结束**
