# PLAN-P-05 TFLite 端侧推理引擎

| 项 | 值 |
|---|---|
| 对应 SPEC | SPEC-P-05 |
| 负责 | B（主责）；A 提供 `T-07` 的 INT8 模型制品与 `model_card`，并执行 `PLAN-T-08` 的模型级 parity |
| 目标日 | D4（D5 完成端到端联调） |
| 前置依赖 | `PLAN-P-04` 的 `Float32List` 输出可用；`PLAN-T-07` 交付 INT8 `.tflite`（**硬闸门**：≤ FF-16 上限）；`PLAN-C-03` 的类别映射常量；`tflite_flutter` 版本锁定 |
| 预估工时 | 8 h |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `lib/domain/inference_engine.dart` | `InferenceResult` / `InferenceEngine` 契约（**类名与签名不得改**） |
| 2 | `lib/domain/tflite_inference_engine.dart` | `tflite_flutter` 实现（XNNPACK + NNAPI 尝试 + 静默回退） |
| 3 | `lib/domain/inference_isolate.dart` | 推理 isolate 的创建、消息协议与重启 |
| 4 | `lib/domain/model_labels.dart` | FF-19 的 `classId ↔ label` 映射（生成自 `feature_config`） |
| 5 | `test/domain/inference_engine_test.dart` | 加载、形状校验、输出结构、`dispose` |
| 6 | `test/domain/delegate_fallback_test.dart` | **NNAPI 失败静默回退**（注入必失败的委托工厂） |
| 7 | `test/domain/inference_isolate_test.dart` | 独立 isolate + UI 心跳 |
| 8 | `test/domain/inference_stateless_test.dart` | 无跨 patch 状态 |
| 9 | `test/domain/label_mapping_test.dart` | 类别映射与 FF-19 一致 |
| 10 | `test/domain/inference_degrade_test.dart` | 降级路径（步长 → 1.0 s） |
| 11 | `test/domain/inference_bench_test.dart` | 延迟**实测**采集 |
| 12 | `records/reports/p05_latency.md` | D4 实测延迟与委托回退记录（**不写预测值**） |
| 13 | `ai/scripts/check_model_size.py` | 模型体积断言（FF-16） |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 锁定 `tflite_flutter` 版本；确认 XNNPACK/NNAPI 的 API 形态 | 版本锁定记录 | 0.5 h | D0 环境 |
| 2 | 定义 `InferenceResult` / `InferenceEngine`（与 `API-02` 逐字一致） | 交付物 1 | 0.5 h | `API-02` |
| 3 | 推理 isolate：协议、串行化、超时与重启 | 交付物 3/7 | 2 h | 2 |
| 4 | 模型加载 + 张量整形 + 输出解析 | 交付物 2 | 1.5 h | 3、`T-07` |
| 5 | 委托链：XNNPACK 默认 + NNAPI 尝试 + **静默回退** | 交付物 2/6 | 1.5 h | 4 |
| 6 | 类别映射生成 + 一致性测试 | 交付物 4/9 | 0.5 h | `PLAN-C-03` |
| 7 | 降级路径（步长 → 1.0 s）与丢包判据接线 | 交付物 10 | 0.5 h | `PLAN-P-06` 接口 |
| 8 | 延迟实测（真机）+ 报告 | 交付物 11/12 | 0.5 h | 4 |
| 9 | 体积断言脚本 | 交付物 13 | 0.25 h | `T-07` |

**合计：7.75 h**，计入域 P 总工时。

## 3. 技术方案
**位置**：`SPEC-P-04` 的 `Float32List` → **本功能（推理 isolate）** → `SPEC-P-06` 聚合器。

**关键骨架（≤30 行，仅示意结构）**：
```dart
class TfliteInferenceEngine implements InferenceEngine {
  Interpreter? _interp;

  @override
  Future<void> load({required String assetPath}) async {
    final options = InterpreterOptions();
    options.addDelegate(XNNPackDelegate());                        // FF-18 默认
    try {
      options.addDelegate(NnApiDelegate());                        // 可选加速
    } catch (_) {
      _diag.add('ACD-INF-003');   // 静默回退：不抛、不提示（FF-18）
    }
    _interp = await Interpreter.fromAsset(assetPath, options: options);
  }

  @override
  Future<InferenceResult> run(Float32List mel, {required int nFrames}) async {
    _assertShapes(nFrames);                     // 不符 → ACD-INF-002，绝不 reshape
    final sw = Stopwatch()..start();
    _interp!.run(_inputFor(mel, nFrames), _output);
    sw.stop();
    return _parse(_output, latencyMs: sw.elapsedMilliseconds);     // 6 类 Softmax
  }
}
```
**要点**：
1. **`ACD-INF-003` 一律不上抛**：捕获后只写内存诊断环形缓冲；UI 不得出现任何提示（FF-18）。
2. `Interpreter.run()` 只能在推理 isolate 内调用；主 isolate 通过 `SendPort` 传 `Float32List`（Transferable 或拷贝，按实测选择）。
3. 引擎**无跨 patch 业务状态**（聚合状态在 `SPEC-P-06`），这是 `P-06` 状态不分裂的前提。
4. 形状校验失败**不得 reshape 兜底**；`n_frames` 与 FF-14 第 3 维必须同时满足。
5. 降级路径由本功能发出信号，实际节拍切换与聚合语义由 `SPEC-P-06` 承接；步长目标 = FF-12 的 2 倍。
6. 延迟只记录、不设通过线；任何延迟数字只能来自 `inference_bench_test.dart` 的**D4 实测**。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `inference_engine_test.load_int8Model_succeeds` | Dart 单测 | 无异常，`ready` 成立 | D4 每次提交 |
| `inference_engine_test.run_wrongNFrames_throwsACD_INF_002` | Dart 单测 | 错误码正确且无 reshape | D4 |
| `inference_engine_test.run_returnsSixProbs_sumToOne` | Dart 单测 | 长度 6，`|Σ−1| ≤ 1e-3`，无 NaN | D4 |
| `delegate_fallback_test.nnapiFailure_fallsBackSilently` | Dart 单测（注入必失败委托） | **不抛异常**；结果合法；诊断 1 条 `ACD-INF-003` | D4 / D9 前回归 |
| `inference_isolate_test` | Dart 单测 | 非 UI isolate；`run()` 期间 UI 心跳正常 | D4 |
| `inference_stateless_test` | Dart 单测 | 同输入两次结果逐元素相等 | D4 |
| `label_mapping_test` | Dart 单测 | 与 FF-19 逐行一致 | D4 / D10 |
| `inference_degrade_test` | Dart 单测（注入 2 s 假延迟） | 触发降级；步长 1.0 s；丢包趋势收敛 | D4 / D5 |
| `inference_bench_test` | Dart bench | 输出 `latencyMs` 分布（**实测产出**） | D4 |
| `check_model_size.py` | 脚本 | INT8 ≤ FF-16 上限 | D4 / D10 |
| `parity_test.py --n 50` | 跨框架 parity（`PLAN-T-08`） | 标签一致率 ≥ 0.98、置信度偏差 ≤ 0.05 | D4（**硬验收**） |
| 端到端最小闭环 | 真机手测 | 「真机点按钮出结果」（CP2） | **D5** |

## 5. 完成定义（DoD）
- [ ] `SPEC-P-05` §7 全部 14 条判据通过（**必需项**；第 13 条由 `PLAN-T-08` 在 D4 出结论）。
- [ ] 交付物 1–13 全部存在且路径一致。
- [ ] **D4 硬验收**：`PLAN-00` §1 D4 行「模型 ≤ FF-16 上限」「parity 通过」「无 INTERNET 权限」三项齐全。
- [ ] **NNAPI 失败静默回退**已由注入式测试证明：不抛异常、无 UI 提示、诊断有记录。
- [ ] 类别映射与 FF-19 一致，且映射常量**生成自** `feature_config`（不手写）。
- [ ] 单 patch 延迟实测值写入 `records/reports/p05_latency.md`（只写实测，不写预测）。
- [ ] 降级路径可用：步长可切到 1.0 s，`droppedPatches` 趋势收敛。
- [ ] 推理 isolate 在会话结束后被销毁（`dispose()` 断言）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `T-07` 的 INT8 模型 D4 未交付 | D4 中午模型资产仍缺失 | 先用 FP32 模型打通端到端（体积目标暂不满足），**CP2 不因此推迟**；`T-07` 补齐后换资产（形状一致，无需改代码） |
| `tflite_flutter` 版本的委托 API 与预期不符 | 编译失败 | 去掉显式 NNAPI 注册，只保留 XNNPACK/默认；**「静默回退」语义退化为「不注册即不用」**，并回写 `SPEC-P-05` §10 第 4 条 |
| 推理延迟过高导致丢 patch 超阈值 | `droppedPatches / patchesEmitted > 0.05` | 执行降级：步长 → 1.0 s；仍超则再降到 2.0 s（须回写 `SPEC-P-05` §5 并走 `API-00` §3.9 变更） |
| isolate 通信拷贝开销过大 | bench 显示拷贝占比高 | `Float32List` 用可转移内存传递，避免整块复制 |
| 与 `PLAN-P-06` 的降级接口未对齐 | D4 联调时接口不符 | 以 `SPEC-P-05` §10 与 `SPEC-P-06` 的「`voiced` 与步长」交界为准，先定接口再改代码 |
| 模型体积超 FF-16 上限 | `check_model_size.py` 失败 | 回退 `T-07` 重新量化/剪枝；**不得把超限模型写进 v1.0 交付** |

## 7. 与检查点的关系
- **CP2（D5 晚：端到端闭环跑通）** 的直接构成：`P-01`→`P-05` 打通，真机点按钮出结果（`PLAN-00` §1 D5 行）。CP2 未通 → D6 全天扑联调，UI 与报告页砍到最简。
- **D4 硬验收**与 CP 并列：模型 ≤ FF-16、`parity` 通过、无 `INTERNET` 权限（`PLAN-00` §1 D4 行）。
- 本功能在 `PLAN-00` §3 关键路径上（`T-07 → P-05 → D5 闭环`）；任何一环延期，优先砍 D6–D8 增强功能，**绝不动 D5 与 D9**。
- 本功能属「不可砍」五项之①实时检测闭环，**不得裁剪**。

**文档结束**
