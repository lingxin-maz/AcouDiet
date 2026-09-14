# PLAN-T-07 INT8 量化与 TFLite 导出

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-T-07` |
| 负责 | A（主责）；B 提供 `P-04` 的 `MelFrontend.melVersion` 并完成 `P-05` 集成 |
| 目标日 | D4 |
| 前置依赖 | `PLAN-T-04` 的 `SavedModel`；**`n_frames` 已修订（`ADR-21`，2026-09-12；FF-11 = `n_frames = 128` + `raw_mel_frames = 129`；原 `ADR-P1` 冻结值为 ~~129~~）**；B 的 `melVersion`（闭环第三项）；`PLAN-T-05` 的 `evaluate.py`（仅用于体积外的精度对照，不阻塞导出） |
| 预估工时 | 6 h |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `ai/src/export_tflite.py` | 代表性数据集 + INT8/FP32 双导出 + 制品卡生成 |
| 2 | `ai/artifacts/model_int8.tflite` | **硬闸门制品**（≤ FF-16 的 INT8 上限，即 2.5 MB） |
| 3 | `ai/artifacts/model_fp32.tflite` | 对照（≤ FF-16 的 FP32 上限） |
| 4 | `ai/artifacts/model_card.json` | 15 字段制品卡（`parity*` 先 `null`，由 `PLAN-T-08` 回填） |
| 5 | `app/assets/models/acoudiet_int8_v1.0.0.tflite` | 交付产物（`API-06` §1/§10 命名），与域内制品**字节相同** |
| 6 | `ai/tests/test_model_card.py` | 字段完整性、体积、dtype、形状判据（并入 `PLAN-C-05`） |
| 7 | 实测参数量记录 | 写入导出日志与制品卡，**非**照抄值 |
| 8 | 体积/形状/加载自检输出 | 控制台证据，供 D4 硬验收留档 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 代表性数据集（200 patch，分层，**不含测试集**） | `representative_dataset()` | 1 h | `PLAN-T-02` `PLAN-T-04` |
| 2 | INT8 转换（`TFLITE_BUILTINS`、float32 I/O） | `model_int8.tflite` | 2 h | #1 |
| 3 | FP32 对照转换 | `model_fp32.tflite` | 0.5 h | #2 |
| 4 | 体积自检与超标排查路径 | 自检输出 | 0.5 h | #2 |
| 5 | 制品卡生成（15 字段 + 三个 hash 计算） | `model_card.json` | 1 h | #2 |
| 6 | 交付到 `app/assets/models/` + sha256 一致性断言 | 交付产物 | 0.5 h | #5 |
| 7 | 与 B 对接 `melVersion` + `--check-card` 联调 | 闭环证据 | 0.5 h | B（`PLAN-P-04`） |

## 3. 技术方案

```python
# 骨架（≤30 行，非完整实现）
import hashlib, json, os, tensorflow as tf
CFG = json.loads(open("shared/feature_config.json", encoding="utf-8").read())   # 只读
N = 200

def representative_dataset():
    """校准样本只来自 train/val —— 绝不含 test_public / test_mobile。"""
    for patch in iter_train_val_patches(limit=N, per_class_min=20):   # 走 FF-02..FF-08
        yield [patch.astype("float32")]                               # 形状 FF-14

def convert(saved_model_dir, int8=True):
    c = tf.lite.TFLiteConverter.from_saved_model(saved_model_dir)
    c.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]     # 禁 SELECT_TF_OPS
    if int8:
        c.optimizations = [tf.lite.Optimize.DEFAULT]
        c.representative_dataset = representative_dataset
    c.inference_input_type = tf.float32          # 保 App 侧 Float32List 契约（API-01 §3.2）
    c.inference_output_type = tf.float32
    return c.convert()

blob = convert("ai/artifacts/saved_model", int8=True)
open("ai/artifacts/model_int8.tflite", "wb").write(blob)
assert len(blob) <= 2.5 * 1024 * 1024, "FF-16 硬闸门：INT8 体积超标"
sha = hashlib.sha256(blob).hexdigest()
card = build_card(sha=sha, bytes_=len(blob), n_frames=CFG["n_frames"],   # 取自 FF-11，不硬编码
                  input_shape=CFG["input_shape"], mel_version=ask_B_melVersion(),
                  feature_config_sha256=sha256_file("shared/feature_config.json"))
```

**关键约定**：
- `nFrames` / `inputShape` / `numClasses` / `classLabels` **一律从 `feature_config` 读取**，脚本内不出现 `129` / `128` 字面量（否则冻结值变更时极易漏改）。
- `melVersion` 由**B 提供**，A 不得代填；未提供则写 `null` 并使 `--check-card` 返回 2。
- `parityLabelMatch` / `parityMaxConfDelta` 生成时为 `null`，由 `PLAN-T-08` 的 `parity_test.py --update-model-card` 回填（避免 `T-07`↔`T-08` 循环依赖）。
- 体积断言用 FF-16 的**确切值**（INT8 2.5 MB / FP32 6 MB），写成 `2.5 * 1024 * 1024` 等表达式并在注释中标注 FF-16 编号。
- 交付到 App 侧只做**重命名复制**，绝不重新转换（保证字节一致、sha256 不变）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `pytest ai/tests/test_model_card.py` | 单测 | 15 字段齐全、体积达标、dtype float32、形状 == FF-14 / `(1,6)` | D4 |
| 体积 | 脚本断言 | INT8 ≤ FF-16 INT8 上限；FP32 ≤ FF-16 FP32 上限 | D4 |
| 无 Flex | 加载自检 | 转换使用 `TFLITE_BUILTINS`；无 `SELECT_TF_OPS` 回退 | D4 |
| 前向自检 | 加载自检 | 输出行和 ∈ [0.999, 1.001] | D4 |
| 三 hash 闭环 | `parity_test.py --check-card` | `n_frames` 已冻结（`ADR-P1`）；B 的 `melVersion` 到齐后退出码 0（未到齐则 2） | D4、D5 前 |
| 交付一致性 | sha256 | `app/assets/models/*.tflite` == `ai/artifacts/model_int8.tflite` | D4 |
| 参数量 | grep + 日志 | 实测值存在；`2500000`/`2.5M` 命中 0 | D4 |
| 无测试集校准 | grep | `export_tflite.py` 中 `test_public`/`test_mobile` 命中 0 | D4 |
| 可复现 | 哈希 | 同 SavedModel 两次导出 sha256 相等 | D4 |
| 端侧加载 | 集成 | `tflite_flutter` 在真机加载成功、XNNPACK 生效（B 侧） | D5（`PLAN-P-05`） |

## 5. 完成定义（DoD）
- [ ] `SPEC-T-07` §7 全部 15 条判据通过（判据 9 仅在 B 的 `melVersion` 未到齐时允许为"退出码 2"；`n_frames` 已冻结，`ADR-P1`）。
- [ ] `model_int8.tflite` 体积 ≤ **2.5 MB**（FF-16），`model_fp32.tflite` ≤ 6 MB。
- [ ] `model_card.json` 15 字段齐全，且 `parity*` 已由 `PLAN-T-08` 回填为实测值。
- [ ] `--check-card` 退出码 0（三 hash 闭环）—— **前提是 B 已公布 `melVersion`**（`n_frames` 已冻结，`ADR-P1`）；B 未公布时本项状态为 BLOCKED 并须在站会明示，不得标记为完成。
- [ ] 实测参数量已记录，仓库中**不存在**照抄的 `2.5M`。
- [ ] `app/assets/models/` 下的制品 sha256 与域内制品一致。
- [ ] D4 硬验收项「★模型 ≤2.5 MB」已在当日站会留档（`PLAN-00` §1 D4 行）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| **INT8 体积超标** | `getsize` > FF-16 上限 | ① 排查 Flex/未量化层；② 确认无冗余预处理层；③ 仍超标则上报 A/B/C 三方决策（可考虑结构收窄，但**须走 `SPEC-C-03` 变更传播并重跑 `T-05`/`T-08`**）。**不允许**"先交付再优化" |
| 需要 `SELECT_TF_OPS` | 转换器要求 | 回 `SPEC-T-04` 去掉不支持的算子（如自定义预处理）；**不得**启用 flex delegate |
| **`n_frames` 冻结值被改动** | FF-11 被改回 128 帧或窗口被缩短 | 闸门返回 10（制品不符），**判定为"无法闭合"**；D4 与 D5 的计划需据实调整并把该变更上报 —— 修订值 `n_frames = 128`（原 `ADR-P1` 冻结值 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订）**不得**被就地修改，须走 `SPEC-C-03` 变更传播 |
| B 未公布 `melVersion` | 字段为 `null` | 闸门停在退出码 2；D5 联调**缺少安全网**，须在站会明示；不得代填 |
| 量化后精度明显下降 | `T-08` parity 或 `T-05` 数字退化 | 保留 FP32 版作对照，排查是否需 `representative_dataset` 增量；若仍不达标，把量化损失如实写进报告（**不得**用 FP32 数字冒充 INT8） |
| 交付后制品被替换 | `--check-card` 退出码 10 | 立即回滚到仓库内制品并查因；D9 前重跑一次闭环校验 |
| 端侧加载失败 | `tflite_flutter` 报错（`ACD-INF-001`） | 用 Python `Interpreter` 复现，区分是制品问题还是委托问题（FF-18 的 NNAPI 失败应静默回退 CPU） |

## 7. 与检查点的关系
- **CP1（D3 晚）**：与本功能无直接依赖，但 `T-07` 的输入模型来自 `T-04`；若 D3 无模型，本功能顺延，**CP2 必然失守**。
- **CP2（D5 晚，端到端闭环）**：本功能是 `P-05`（`tflite_flutter` 集成）的**唯一输入**。`PLAN-00` §1 D4 行的硬验收是「★模型 ≤2.5 MB；★parity 通过」——本功能与 `PLAN-T-08` 同日交付、互为条件。
- **CP3（D9 午，三种 Demo 模式）**：Demo 用的就是本制品；D9 前必须重跑一次三 hash 闭环校验。
- **关键路径**：`D2 Baseline → D3 跨域 ★CP1 → D4 TFLite → P-05 → D5 闭环 ★CP2`（`PLAN-00` §3）——本功能在关键路径上，**任何延期直接推到 CP2**。
- **不可裁剪**：本功能是四硬闸门之一；不参与"优先砍增强功能"的候选集。

**文档结束**
