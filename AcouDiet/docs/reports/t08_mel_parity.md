# T-08b 跨语言 Mel 对齐实测记录（硬闸门）

**判据**：`SPEC-P-04` §7 判据 4 — `np.allclose(kotlin, python, atol=1e-3)` 为真
**命令**：
```powershell
$env:PYTHONPATH = "D:\Desktop\Food\_toolchain\site-packages"
& "D:\Desktop\Food\_toolchain\dl\python\python.exe" ai\scripts\mel_parity_test.py --n 12
```
**产物**：`ai/artifacts/parity_report.json`（`melParity` 块）

---

## 1. 实测结果（2026-09-10 环境，12 个夹具）

| 夹具 | 预处理 maxAbsDiff | Mel maxAbsDiff |
|---|---|---|
| `tone_1000hz` | 0.000e+00 | 5.960e-08 |
| `tone_250hz` | 0.000e+00 | 5.960e-08 |
| `tone_4000hz` | 0.000e+00 | 5.960e-08 |
| `noise_seed1` | 0.000e+00 | 5.960e-08 |
| `noise_seed2` | 0.000e+00 | 5.960e-08 |
| `impulse` | 0.000e+00 | 5.960e-08 |
| `step` | 0.000e+00 | 5.960e-08 |
| `silence` | 0.000e+00 | 0.000e+00 |
| `near_silence` | 0.000e+00 | 5.960e-08 |
| `chews_500ms` | 0.000e+00 | 5.960e-08 |
| `chews_700ms` | 0.000e+00 | 5.960e-08 |
| `square_500hz` | 0.000e+00 | 5.960e-08 |

```
allclose_ok=true
melParity:             atol=0.001  maxAbsDiff=5.960e-08  passed=true
preprocessParity:      atol=0.001  maxAbsDiff=0.000e+00
```

**结论：闸门通过，且余量约 4 个数量级**（`5.96e-08` vs `1e-3`）。`5.96e-08` 恰好是 float32 在
`[0,1]` 上的一个 ULP，即"两侧逐元素相等，只差最后一次 float32 舍入"。

---

## 2. 这条结果证明了什么

| 项 | 冻结值 | 两侧实现是否同源 |
|---|---|---|
| `pad_mode = constant`（零填充） | ADR-16 | ✅ Kotlin 显式零填充 / librosa `center=True` 默认 |
| 周期 Hann 窗（`fftbins=True`） | FF-03 | ✅ Kotlin 用 `0.5−0.5cos(2πn/N)`，非对称窗会立刻错位 |
| Slaney Mel 刻度 + Slaney 面积归一化 | ADR-16 | ✅ Kotlin 逐行复刻 `librosa.filters.mel(htk=False, norm='slaney')` |
| `power_to_db(ref=1.0, top_db=80)` | FF-07 / ADR-16 | ✅ 两侧同口径（含 `amin=1e-10`） |
| `clip(−80, 0)` 后逐 patch min-max | FF-08 | ✅ 两侧同一分支；全零 patch → 全 0（无 NaN） |
| 行主序 `mel[m * nFrames + t]` | `SPEC-00` §3.1 | ✅ Python 侧 `np.frombuffer(buf, '<f4').reshape(128,128)` 无剩余字节（**`ADR-21` 修订**，~~`reshape(128,129)`~~） |
| 预加重 `x[−1] = x[0]` | ADR-17 / FF-02 | ✅ 首样本差异 `0.000e+00` |

## 2.1 `ADR-21`：闸门改为覆盖**非零 offset**（v1.1 的判别力证据）

`ADR-21` 把 §2 表里的三条链路改掉了 —— ~~`power_to_db(ref=1.0)`~~ 改为 `ref = patch_max`（本 patch 最大值）、
~~固定 dB 截断 `clip(−80, 0)` 再 min-max~~ 改为「丢弃尾帧后 per-patch min-max」、
~~预加重 `x[−1] = x[0]`~~ 改为沿流取前一原始样本。上表是 v1.0 的历史记录，其"两侧同源"的结论对 v1.1 仍然成立，
但冻结值以 `SPEC-00` §3.1（`ADR-21`）为准。

改动里最容易被漏掉的是**预加重的流式前驱**：它只在 patch **不从样本 0 开始**时才真正被用到。
offset 0 恰好是"前驱 = 0.0"、旧规则"首样本原样通过"也碰巧同意的那一个点，所以
**只比 offset 0 的闸门看不见这个错误**。因此 `mel_parity_test.py` 的 `offsets_for()` 现在对每个 wav
同时比 **`0` / 中间 / `size − patch_samples`（最后一个完整窗口）** 三个 offset，语料也新增两个
**3 个 patch 长**的 WAV（`chews_long.wav`、`tone_long.wav`）来提供非零 offset。

**判别力是实测出来的，不是推理出来的**：

| 例子 | 预加重前驱 | `maxAbsDiff` | 对 `atol = 1e-3` |
|---|---|---|---|
| `tone_long.wav@65536` | **正确**值 `−0.153076`（patch 开始前的最后一个原始样本） | **5.96e-08** | ✅ 通过 |
| 同上（对照） | 错误值 `0`（假装该 patch 从源起点开始） | **1.779e-01** | ❌ 失败（差约 5 个数量级） |

即：用错前驱会被闸门当场抓住，这道闸门不是空跑。

另外，`mel_parity_test.py` 的 `labelMatch` / `maxConfDelta` 此前是**无条件写死的 1.0 / 0.0**，
现在改为**实测**（把 Kotlin 侧与 Python 侧的 Mel 分别喂给同一个出厂解释器，差异只能来自语言）：
实测 **`labelMatch = 1.0000`、`maxConfDelta = 8.34e-07`（18 个 patch）**。

## 3. 附带发现（已在本仓修复，供文档维护者参考）

`MelFilterBank` 最初把 Slaney 刻度常量（`f_sp` / `min_log_hz` / `log_step`）写成 **类体属性**，
而 Kotlin 的类体初始化按源码顺序执行、`init {}` 又写在它们之前 —— 于是建滤波器组时这些值仍是 `0.0`，
`hz_to_mel` 得到 `+Infinity`，权重矩阵全为 `NaN`，最终 Mel 张量**整片为 0 而不报错**。
症状与"参数不一致"完全一样，但根因在语言语义。

已改为 `companion object` 的编译期常量，并把该类加入 JVM 套件（`MelFrontendTest` 的
`range_within01` / `clip_minmax_usesFullRange` 正是会抓到它的两条断言）。
**建议**：任何"沉默的数值退化"都必须有一条断言盯着值域，不能只看形状。
