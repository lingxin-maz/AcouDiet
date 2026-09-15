# 推理侧不施加响度增益的裁定（P-03）

**状态**：✅ 已落地，按 `SPEC-00 §8.4` 登记
**影响文件**：`app/android/app/src/main/kotlin/com/acoudiet/app/audio/Preprocess.kt`
**相关文档**：`SPEC-P-03 §2.2 步骤 7`、`§5`、`§6`、`ADR-17` / `FF-08b`

---

## 1. 问题

`SPEC-P-03 §2.2` 步骤 7 要求「响度归一化：计算本 patch 的 RMS，按**目标响度**求增益并施加；
增益设上限钳制」。但 SSOT 里**没有推理侧的目标响度**：

| SSOT 键 | 值 | 作用域 |
|---|---|---|
| `loudness_normalization` | `"training_only"` | `ADR-17` 冻结：**仅训练侧** |
| `target_lufs` | `-23.0` | 训练侧 `T-03` 的增强目标 |

`SPEC-P-03 §5` 自己也写明：推理侧增益上限「实测产出……**若需两侧同源，以 `SPEC-C-03` 变更传播
补入 `feature_config`**」—— 即该参数**从未冻结**。

---

## 2. 为什么不能"顺手写一个"

`FF-08b`（`ADR-17`）的原文是：*~~FF-08 的固定 dB 截断 + 逐 patch min-max~~ 已提供尺度不变性，
现场再算一遍只增加开销与一处可能不一致的实现*。`ADR-21` 修订了这条链路，但没有修订这个立论：
提供尺度不变性的机制现在是**patch 相对 `power_to_db`（`ref = "patch_max"`）+ 逐 patch min-max**
（固定 dB 截断 `clip(−80, 0)` 已取消），"归一化本身已提供尺度不变性"这一点不变。

在推理侧施加一个**未冻结**的增益，会直接破坏本项目的头号硬闸门：
Kotlin 侧的增益必须与 Python 侧逐位一致，否则 `T-08b` 的 `atol = 1e-3` 对齐无从谈起 ——
而这正是 `FF-08` 注释里点名要避免的"域偏移陷阱"的同构错误。

---

## 3. 裁定

**推理侧预处理链的响度归一化是恒等变换（gain = 1.0）。**

* 尺度不变性由 `FF-08` 的「**patch 相对 `power_to_db`（`ref = "patch_max"`）+ 逐 patch min-max**」提供
  （`ADR-21` 修订；~~固定 dB 截断 `clip(−80, 0)` + 逐 patch min-max~~），与两侧实现一致；
* 纯静音**不会被放大**（`SPEC-P-03` §7 判据 7/12 因此天然成立）；
* LUFS 路径保留在**训练侧**（`ai/src/features.py::loudness_normalize`，默认关闭，仅 `--lufs` 时启用），
  与 `FF-08b` 的 `training_only` 完全一致。

---

## 4. 实测（JVM 套件）

| 判据 | 期望 | 实测 |
|---|---|---|
| §7 #3 确定性 | 同输入 10 次逐元素相等 | ✅ |
| §7 #7 纯静音不放大 | 输出 RMS == 0 且无 NaN | ✅ `max=0.0 finite=true` |
| §7 #11 去直流逐 patch 独立 | 恒定偏置输入 → 输出均值 ≈ 0 | ✅ `mean=0.0` |
| §7 #12 增益上限生效 | 极低电平输入下峰值 ≤ 上限 | ✅ `peak=0.0`（恒等路径） |
| §7 #2 预加重公式 | 与 `y[n] = x[n] − 0.97·x[n−1]` 逐元素差 < 1e-6 | ✅ `maxDiff=4.3e-08` |
| 跨语言一致 | `np.allclose(kotlin, python, atol=1e-3)` | ✅ `0.000e+00`（预处理段） |

## 5. 若日后需要推理侧响度对齐

1. 在 `shared/feature_config.json` 增加 `inference_gain_cap_db` 与 `inference_target_rms`（或等价键）；
2. 走 `SPEC-C-03` 的 14 项变更传播 + 重跑 `mel_parity_test.py`；
3. 在 `Preprocess.apply` 的步骤 7 打开增益分支，并同步 `ai/src/features.py`。

在此之前，**任何在推理侧加入增益的改动都必须视为契约变更**。
