# SPEC-P-05 TFLite 端侧推理引擎

| 项 | 值 |
|---|---|
| 域 | P · 感知与识别 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.2/§3.5；`API-00` §3.5/§3.6/§3.7/§3.8；`API-02`（`InferenceEngine` / `InferenceResult`）；`SPEC-00` §3.2（FF-13~FF-18）、§3.3（FF-19）、§3.10（FF-25） |
| 依赖的 SPEC | `SPEC-P-04`（Mel 输入）、`SPEC-T-07`（INT8 模型制品）、`SPEC-T-08`（模型级 parity）、`SPEC-P-06`（消费方） |

## 1. 目标与范围

### 1.1 一句话目标
用 `tflite_flutter` 加载**模型卡申报档位（fp32 / int8）的模型**（`ADR-21`；旧口径 ~~只加载 INT8~~）并在 Dart 独立 isolate 中执行 `Interpreter.run()`，XNNPACK 启用；NNAPI 委托初始化失败必须**静默回退 CPU 且不抛异常**（`ACD-INF-003` 属预期情况），并提供单 patch 延迟超预算时的降级路径（推理步长提高到 1.0 s）。

### 1.2 范围内（In Scope）
- 模型加载：从 `assets/models/` 读取 INT8 `.tflite`（FF-16 的体积目标由 `T-07` 交付、`C-04` 复核）。
- 输入张量整形：`[1, 128, n_frames, 1]` float32（FF-14）→ 量化输入（INT8 模型的 `input_details`）。
- 输出解析：6 类 Softmax 概率 → `InferenceResult.probs`（FF-19）。
- 委托策略：XNNPACK 默认；NNAPI 尝试初始化，失败静默回退（FF-18）。
- isolate 运行：`Interpreter.run()` 在独立 isolate，不得在 UI isolate（`API-00` §3.7）。
- 生命周期：`load` / `run` / `dispose`，含会话结束后的资源释放。
- 延迟测量：`latencyMs` 字段（仅 `Interpreter.run()` 的墙钟耗时，`API-02` §3）；`droppedPatches / patchesEmitted > 0.05`（`API-01` §3.3）时提高推理步长到 1.0 s。

### 1.3 范围外（Out of Scope）——必须显式写出，防止实现方自由发挥
| 不做 | 归属 / 依据 |
|---|---|
| Mel 计算 | `SPEC-P-04`（L1 Kotlin） |
| 三级聚合 / EMA / 确认判据 | `SPEC-P-06` |
| 行为分析 | `SPEC-P-07` |
| 模型训练与量化导出 | `SPEC-T-04` / `SPEC-T-07` |
| 模型级 parity（PT/Keras vs TFLite） | `SPEC-T-08` / `PLAN-T-08` |
| **原生侧推理** | `API-01` §6：会让 `P-06` 的聚合状态分裂成两份 |
| 云端推理 / 模型下载 | **FF-24 §4：APK 无 `INTERNET` 权限，绝对禁止** |
| 模型 OTA 更新 | 不做（无网络出口） |
| GPU / EdgeTPU / 其他委托 | 不做；委托只允许 XNNPACK 与（可选）NNAPI |
| NNAPI 失败时抛错或提示用户 | **禁止**：`ACD-INF-003` 是预期情况，必须静默回退（`API-00` §3.5） |
| 模型热切换 / 多模型并存 | 不做（v1.0 单一 INT8 模型，FF-13/FF-16） |

## 2. 功能行为

### 2.1 触发与前置条件
1. App 冷启动完成握手（`API-00` §3.6）；不一致 → `ACD-CFG-001`。
2. 模型资产存在且 `sha256` 与 `model_card` 一致（`SPEC-T-07` 产物）。
3. `load()` 已在推理 isolate 中完成，且输入/输出张量形状与 FF-14 一致。
4. 收到 P-04 的 `patch`（`voiced = true` 时才会被调用，`SPEC-P-02` §3）。

### 2.2 主流程（编号步骤）
1. 会话开始前（或 App 启动后首次进入检测页）调 `load(assetPath)`：在推理 isolate 内创建 `Interpreter`。
2. 尝试按 FF-18 初始化委托链：先 XNNPACK；（可选）尝试 NNAPI。
3. NNAPI 初始化抛错或返回失败 → **捕获并丢弃**，记录 `ACD-INF-003` 到内存诊断环形缓冲（`API-05` §3 第 10 类），**不向 L5 抛出、不弹提示**，继续使用 XNNPACK/CPU。
4. 校验输入张量形状与 FF-14 一致；不一致 → `ACD-INF-002`（不重试）。
5. 每个 `voiced = true` 的 patch：`Float32List(128 × n_frames)` → 填入输入张量 → `Interpreter.run()`。
6. 记录本次耗时到 `InferenceResult.latencyMs`（墙钟毫秒）。
7. 解析输出：6 个 Softmax 概率 → 找 `argmax` → `classId` / `label`（FF-19）/ `confidence`。
8. 返回 `InferenceResult` 给 `SPEC-P-06` 的聚合器；本功能**不保留任何跨 patch 状态**。
9. `droppedPatches / patchesEmitted > 0.05` 持续出现 → 输出「提高推理步长」信号，由会话层把滑窗步长从 FF-12 提高到 1.0 s（即 FF-12 的 2 倍）。
10. 会话结束 / App 退出 → `dispose()`，释放 isolate 与 `Interpreter`。

### 2.3 状态与状态迁移
| 状态 | 迁移条件 | 效果 |
|---|---|---|
| `UNLOADED` → `LOADING` | `load()` | 创建 isolate |
| `LOADING` → `READY` | 模型打开 + 委托链就绪 | 可接受 `run()` |
| `LOADING` → `FAILED` | 模型缺失/损坏/张量形状不符 | `ACD-INF-001` / `ACD-INF-002` |
| `READY` → `READY_CPU` | NNAPI 初始化失败（**仅诊断记录**） | 静默回退，`run()` 行为不变，`delegateInUse == 'cpu'` |
| `READY` → `DISPOSED` | `dispose()` | isolate 关闭，资源释放 |
| 任意 → `FAILED` | `run()` 返回非法输出（长度 ≠ 6 / NaN） | `ACD-INF-002`，本 patch 丢弃 |

> 说明：`READY` 与 `READY_CPU` 对上层**不可区分**（这正是 FF-18「静默回退」的要求）。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 模型文件缺失 | `load()` 抛 `ACD-INF-001`，检测页显示「模型不可用」，不得进入检测 |
| 输入 `n_frames` 与模型期望不符 | `ACD-INF-002`；**不得 reshape 硬凑** |
| 输出长度 ≠ 6（FF-19） | `ACD-INF-002`，本 patch 丢弃 |
| 输出含 NaN/Inf | `ACD-INF-002`，本 patch 丢弃 |
| `run()` 超时或 isolate 卡住 | isolate 重启（一次）后重试本 patch；再失败则丢弃本 patch 并计入诊断 |
| 会话暂停期间 / 并发 `run()` | 暂停时无 patch 故不调用；并发禁止（单 isolate 串行，上层最多 1 个待处理 patch，`API-00` §3.8） |
| 设备不支持 NNAPI | 视为预期，静默 CPU（FF-18） |
| `dispose()` 后再次 `run()`，或未 `load()` 即 `run()` | 抛 `ACD-INF-004`（状态非法，`API-02` §8） |

## 3. 接口契约
> 权威定义：`API-02`（Dart 域层接口）。**类名与方法签名不得改动**（`API-02` §1）。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| L4 → 本功能 | `InferenceEngine.load({required String assetPath})` | `assetPath` | `Future<void>`（幂等） | `ACD-INF-001`、`ACD-IO-002` |
| L4 → 本功能 | `InferenceEngine.run(Float32List mel, {required int nFrames})` | Mel（行主序）、`nFrames` | `Future<InferenceResult>` | `ACD-INF-002`、`ACD-INF-004` |
| L4 → 本功能 | `InferenceEngine.dispose()` / `isLoaded` / `delegateInUse` | — | `Future<void>` / `bool` / `String` | 无（`dispose` 幂等） |
| 本功能 → 诊断 | 委托回退记录 | — | 内存环形缓冲 1 条 `ACD-INF-003` | — |
| 运行时 → 模型 | `Interpreter.run()` | 输入张量 | 输出张量 | — |

```dart
class InferenceResult {
  int classId;            // [0,6)，FF-19
  String label;           // 必须 == feature_config.class_labels[classId]
  double confidence;      // == probs[classId]，[0,1]
  Float32List probs;      // 长度 6，Softmax，和 ≈ 1.0
  int latencyMs;          // 仅 Interpreter.run() 的墙钟耗时
}

abstract class InferenceEngine {
  Future<void> load({required String assetPath});
  Future<InferenceResult> run(Float32List mel, {required int nFrames});
  Future<void> dispose();
  bool get isLoaded;
  String get delegateInUse;   // 'xnnpack' | 'nnapi' | 'cpu'
}
```

## 4. 数据契约
> ⚠️ **本契约没有 JSON Schema**：schema 集**固定为 6 份**且**不覆盖原生桥接载荷与制品元数据**。
> - `patch` 事件的形状由 `API-01` §5 一致性测试的第 3/9 条保证；
> - `model_card.json` 的字段权威是 `API-06` §7，其**三个 hash 闭环**（`nFrames` / `melVersion` / `tfliteSha256`）由 `API-05` §7.1 的校验保证。

| 项 | 类型 | 值域 / 约束 |
|---|---|---|
| `mel` 入参 | `Float32List` | 长度 `128 × nFrames`，行主序 `mel[m * nFrames + t]`（`SPEC-00` §3.1） |
| `nFrames` | `int` | 必须等于 FF-11 与模型输入形状第 3 维；**`n_frames = 128`**（旧值 ~~`129`~~ → 已由 `ADR-21`（2026-09-12）修订，`129` 现为 `raw_mel_frames`；见 FF-11 / `ADR-21`） |
| 模型输入张量 | `float32` / INT8 量化 | 形状 `[1, 128, n_frames, 1]`（FF-14） |
| 模型输出张量 | `float32` | 形状 `[1, 6]`，Softmax（FF-14/FF-19） |
| `classId` ↔ `label` | 映射表 | 必须与 FF-19 逐行一致；不得自行改名或改序 |
| `probs` | `Float32List(6)` | `Σ ≈ 1.0`（容差 1e-3 内）；无 NaN |
| 模型资产路径 | `String` | `assets/models/<name>_<quantization>_v<version>.tflite`（`API-00` §3.4 命名；`ADR-21` 加入 `<quantization>` 段，例 `acoudiet_fp32_v1.0.0.tflite`） |
| 模型体积 | 文件字节数 | **按 `model_card.quantization` 申报的档位**取 FF-16 的对应上限（**fp32 ≤ 6 MB；int8 ≤ 2.5 MB，两档都可交付**）；由 `C-04` 复核 |
| `model_card` | JSON | 含 `sha256`、训练配置、类别映射（`T-07` 产物） |

## 5. 参数与常量
> 一律引用 `SPEC-00 §3`。

| 项 | 引用 |
|---|---|
| 模型架构 / 框架 | FF-13 |
| 输入 / 输出形状 | FF-14 |
| 参数量（以实测为准） | FF-15（**禁止照抄旧文档的 2.5M**） |
| 体积目标（FP32 / INT8） | FF-16 |
| 训练配置（仅用于解读模型卡，不在端侧使用） | FF-17 |
| 运行时与委托策略 | FF-18（NNAPI 失败必须静默回退 CPU） |
| `n_frames` | FF-11（**`n_frames = 128`**；旧值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订，`129` 现为 `raw_mel_frames`；见 FF-11 / `ADR-21`） |
| 推理滑窗步长（默认） | FF-12 |
| 降级后的滑窗步长 | FF-12 的 2 倍（1.0 s）；**降级阈值取 `API-01` §3.3 的 `droppedPatches / patchesEmitted > 0.05`** |
| 单 patch 延迟目标 | 以 `API-00` §3.7 的既有约定为准（**该值为上游约定，非本 SPEC 预测**）；**实测值在 D4 产出**，写入 `docs/reports/p05_latency.md` |
| 平台 / `minSdk` / ABI | FF-23 |

## 6. 异常与降级
| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 模型加载失败 / asset 缺失 | `Interpreter.fromAsset` 抛错 / 资产不存在 | `ACD-INF-001`（可重试 1 次）/ `ACD-IO-002`（`API-02` §8）；检测页禁用「开始检测」 | 「模型不可用，请重装应用」 |
| 输入张量形状不符 | 比对 `input_details.shape` 与 FF-14 | `ACD-INF-002`；**不 reshape 硬凑** | 无（开发期可见；连续出现则禁用检测页） |
| **NNAPI 委托初始化失败** | 委托创建抛错/返回 null | **`ACD-INF-003`：记诊断后静默回退 CPU，不抛异常、不提示**（FF-18；`API-00` §3.5） | **无任何提示**（预期情况） |
| XNNPACK 不可用 | 委托创建失败 | 回退纯 CPU 解释器（仍不抛错） | 无 |
| 输出非法（长度 ≠ 6 / NaN） | 输出校验 | `ACD-INF-002`，丢弃本 patch，不中断会话 | 无 |
| 推理过慢导致丢 patch | `droppedPatches / patchesEmitted > 0.05` | **降级路径**：滑窗步长提高到 1.0 s（FF-12 的 2 倍），推理负载减半 | 无提示；确认耗时变长（属 FF-20a 的口径范围，UI 不得承诺「2 秒内出结果」） |
| isolate 卡住 | `run()` 超时 | 重启 isolate 一次；再失败丢弃本 patch 并计数 | 无 |
| 内存不足（`OutOfMemoryError`） | 捕获 | 释放并重建解释器；仍失败则 `ACD-INF-001` 结束会话 | 「设备资源不足」 |

## 7. 验收标准（可机器判定）
| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 模型可加载 | `flutter test test/domain/inference_engine_test.dart` 的 `load_int8Model_succeeds` | 无异常；`ready` 状态成立 |
| 2 | 输入形状校验 | 同上 `run_wrongNFrames_throwsACD_INF_002` | 错误码 `ACD-INF-002`，**无 reshape 兜底** |
| 3 | 输出结构正确 | 同上 `run_returnsSixProbs_sumToOne` | `probs.length == 6`；`|Σprobs − 1| ≤ 1e-3`；无 NaN |
| 4 | 类别映射与 FF-19 一致 | `flutter test test/domain/label_mapping_test.dart` | `classId 0..5` 的 `label` 与 FF-19 逐行相等 |
| 5 | **NNAPI 失败静默回退** | `flutter test test/domain/delegate_fallback_test.dart` 的 `nnapiFailure_fallsBackSilently`（注入必失败的委托工厂） | **不抛任何异常**；`run()` 仍返回合法结果；`delegateInUse == 'cpu'`（FF-18）；内存诊断中出现 1 条 `ACD-INF-003` |
| 6 | XNNPACK 启用 | 同上 `xnnpack_enabledByDefault` | 委托链中存在 XNNPACK；`getDiagnostics` 可见 |
| 7 | 独立 isolate | `flutter test test/domain/inference_isolate_test.dart` | `Isolate.current.debugName !=` UI isolate 名；UI isolate 在 `run()` 期间仍能响应（心跳断言） |
| 8 | 不跨 patch 保留状态 | `flutter test test/domain/inference_stateless_test.dart` | 连续两次 `run()` 同一输入结果逐元素相等；引擎无可变业务字段 |
| 9 | 延迟实测记录 | `flutter test test/domain/inference_bench_test.dart`（**仅记录，不设通过线**） | 输出 `latencyMs` 分布；写入 `docs/reports/p05_latency.md`（**D4 实测产出**） |
| 10 | 降级路径可触发 | `flutter test test/domain/inference_degrade_test.dart`（注入 2 s 假延迟） | 出现降级信号；步长切换为 1.0 s；`droppedPatches` 不再持续增长 |
| 11 | `dispose()` 释放 | 同上第 1 条测试的 `dispose_thenRun_throwsACD_INF_004` | 抛 `ACD-INF-004`；`isLoaded == false`；isolate 已关闭（`kill` 计数断言） |
| 12 | 模型体积合规 | `python ai/scripts/check_model_size.py assets/models/*.tflite` | **按模型卡申报档位**取 FF-16 上限（fp32 ≤ 6 MB；int8 ≤ 2.5 MB，两档均可交付，`ADR-21`）；stdout 打印实测字节数。~~只按 INT8 上限判~~ |
| 13 | 模型级 parity | `python ai/scripts/parity_test.py --n 50`（**`PLAN-T-08` 执行，本功能为出口**） | 退出码 0；stdout 含「标签一致率 ≥ 0.98」「最大置信度偏差 ≤ 0.05」 |
| 14 | 无网络出口 | `aapt dump badging` + 抓包（`PLAN-C-01`） | 无 `INTERNET`；本应用 UID 网络字节数为 0 |

## 8. 非功能约束
- **线程**：`Interpreter.run()` 必须在 Dart 独立 isolate；**严禁在 UI isolate 执行**（`API-00` §3.7）。
- **实时性**：单 patch 延迟目标沿用 `API-00` §3.7 的既有约定；**本 SPEC 不写入任何预测数字**，实测值在 D4 产出并写入报告。
- **内存**：解释器单实例；输入输出张量缓冲复用；会话结束必须 `dispose()`，不得随会话数增长。
- **性能降级**：必须实现「提高推理步长到 1.0 s」这一条降级路径，且降级不得改变 `SPEC-P-06` 的聚合语义（步长变化只影响 patch 间隔）。
- **隐私**：推理全程在设备内；无任何网络调用（FF-24 §4）。
- **无障碍**：无 UI，不适用。

## 9. 裁剪与未做
- **本功能属「不可砍」五项之 ①实时检测闭环（`P-01`~`P-06`、`U-02`）**（`00_功能清单` §6）。**不得裁剪。**
- GPU / EdgeTPU / CoreML 等其他委托：**不做**（Android-only，FF-23；委托只允许 XNNPACK 与可选 NNAPI）。
- 云端推理、模型 OTA、模型热切换、多模型并存：**不做**（FF-24 §4 无网络；FF-13/FF-16 单模型）。
- 原生侧（Kotlin）推理：**不做**（`API-01` §6）。
- 模型重训 / 重新量化：**不做**（属 `T-04`/`T-07`；本功能只是消费者）。
- 15–20 类扩展：**不做**（改 FF-19 需重训重导出，推迟第二阶段）。
- 输入张量自适应 reshape（为兼容 128/129 做「自动裁剪」）：**不做**，形状不符一律 `ACD-INF-002`。

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`，2026-09-10；后经 `ADR-21`（2026-09-12）修订）**：`n_frames` 原冻结为 ~~`129`~~ → 现为 **`n_frames = 128`**（`129` 现为 `raw_mel_frames`，见 FF-11 / `ADR-21`）。**该值同时决定模型输入形状（FF-14）**，现与 `feature_config.input_shape = [1, 128, 128, 1]` 一致；`ADR-21` 的修订正是为了与交付制品的实测张量对齐，任何改动仍须走 `SPEC-C-03` 变更传播。
2. **NNAPI 是否默认尝试未定**：FF-18 写「NNAPI 为可选加速」，但未写「默认开启」还是「配置开关」。当前实现按「尝试 + 失败静默回退」处理；是否提供一个 `enableNnapi` 配置项需 A/B 确认。
3. **`ACD-INF-003` 是否应进入用户可见日志未定**：`API-00` §3.5 把它列为「可回退，应自动处理不抛出」，本 SPEC 按「仅内存诊断」处理。是否在 `M-04` 自检面板显示需与 `PLAN-M-04` 对齐。
4. **`Interpreter` 是否使用 `tflite_flutter` 的 `XNNPackDelegate` 显式注册**随版本 API 而异，需在 D4 按锁定版本确认；若该版本不支持显式注册，则「XNNPACK 启用」的验证改为「无显式禁用且实测延迟符合 `API-00` §3.7 约定」。
5. `SPEC-T-07` 产出的实际模型文件名与 `melVersion` 的绑定关系未定：模型卡是否应记录其训练时用的 Mel 版本？**建议 A 补入 `model_card`**，需三方确认。

**文档结束**
