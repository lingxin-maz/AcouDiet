# PLAN-T-03 数据增强管线

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-T-03` |
| 负责 | A |
| 目标日 | D2 → D3 |
| 前置依赖 | `PLAN-T-01` 的噪声库（`ai/data/noise/`）；`PLAN-T-02` 的四个划分 CSV；`PLAN-T-04` 的 `dataset.py` 接口；`pyloudnorm` 经 `_toolchain\pip_runner.py` 安装 |
| 预估工时 | 8 h |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `ai/src/augment.py` | 四项增强，含 `augment_audio` / `augment_mel` / `load_noise_bank` |
| 2 | `ai/tests/test_augment.py` | §7 的 13 条判据单测（并入 `PLAN-C-05`） |
| 3 | `ai/src/features.py` 的增强无关性确认 | 特征管线保持 FF-02→FF-08（`ADR-21` 链路：`ref = "patch_max"` → 丢尾帧 → `per_patch_minmax`），**增强不得替换该口径**（~~旧措辞「不含 `ref=np.max`」已由 `ADR-21` 反转~~） |
| 4 | 训练日志中的增强统计 | `ai/artifacts/train_log.jsonl` 内的 `snr_db` / `g_r` / `clipped_ratio` / `specaug_masked_ratio` |
| 5 | 顺序正确性证据 | `g_r=2.0` 与 `g_r=1.0` 的输出 RMS 比值测试结果 |
| 6 | `--disable-augment` / `--disable-denoise` 开关 | 供 `PLAN-T-04` 基线与 `PLAN-T-06` 消融复用同一代码路径 |
| 7 | 设计说明（写进 SPEC 的 §10 回写） | SpecAugment `T/F` 语义确认结论 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | `pyloudnorm` 安装与 BS.1770 一致性抽查（10 条样本 ≤0.1 LU） | 依赖可用性结论 | 1 h | 环境 |
| 2 | 噪声库加载器 + 循环平铺逻辑 | `load_noise_bank` | 1 h | `PLAN-T-01` |
| 3 | 噪声混合（SNR 均匀采样 5–20 dB） | `augment_audio` 步骤 2 | 1.5 h | #2 |
| 4 | LUFS 归一化（−23 LUFS）+ 近静音降级 | 步骤 3 | 1 h | #1 |
| 5 | 随机增益（0.5–2.0×）+ 削波统计 | 步骤 4 | 0.5 h | #4 |
| 6 | SpecAugment（掩码条数与宽度上限、填充 0.0） | `augment_mel` | 1.5 h | #5 |
| 7 | 种子派生与可复现断言 | `default_rng` 派生 | 0.5 h | #6 |
| 8 | `test_augment.py` 13 条判据 | 单测 | 1 h | #7 |

## 3. 技术方案

**增强链顺序（不得调整）**：

```
wav → patch(FF-09) → ① 噪声混合(SNR 5–20 dB) → ② LUFS 归一化(−23 LUFS)
    → ③ 随机增益(0.5–2.0×) → ④ 特征(FF-02…FF-08) → ⑤ SpecAugment(掩码填充 0.0)
```

**为什么 ③ 必须在 ② 之后**：LUFS 归一化是**确定性电平标准化**，若先增益后归一化，归一化会把随机增益完全抵消，`g_r` 退化为无效参数——这是本管线最容易写错的一处，故 SPEC §7 判据 8 用 RMS 比值专门锁死。

```python
# 骨架（≤30 行，非完整实现）
import numpy as np, pyloudnorm as pyln
SNR_DB_RANGE, GAIN_RANGE, LUFS_TARGET = (5.0, 20.0), (0.5, 2.0), -23.0
T_MASKS, F_MASKS = 10, 8

def augment_audio(x, split, rng, noise_bank):
    assert split == "train", "测试集绝不参与增强"      # 判据 3
    if x.std() > 1e-4:
        n = noise_bank.sample(len(x), rng)             # 循环平铺
        snr = rng.uniform(*SNR_DB_RANGE)               # 判据 6
        x = x + n * (rms(x) / (rms(n) * 10 ** (snr / 20) + 1e-12))
        L = pyln.Meter(16000).integrated_loudness(x)
        if L > -70:                                    # 近静音降级
            x = x * 10 ** ((LUFS_TARGET - L) / 20)     # 判据 9
    g = rng.uniform(*GAIN_RANGE)                       # 判据 7
    return np.clip(g * x, -1.0, 1.0), g               # 判据 8

def augment_mel(mel, rng):
    for _ in range(T_MASKS):                           # 时间掩码（条数）
        w = rng.integers(1, mel.shape[1] // 10 + 1)
        t0 = rng.integers(0, max(1, mel.shape[1] - w))
        mel[:, t0:t0 + w] = 0.0                        # 填充归一化下界
    for _ in range(F_MASKS):                           # 频率掩码（条数）
        w = rng.integers(1, mel.shape[0] // 8 + 1)
        f0 = rng.integers(0, max(1, mel.shape[0] - w))
        mel[f0:f0 + w, :] = 0.0
    return mel                                         # 值域仍 ⊂ [0,1]
```

**关键约定**：
- 掩码在**归一化之后**、`[0,1]` 张量上施加，填充 `0.0`，保证 FF-08 与 FF-14 的值域契约不被破坏。
- 随机数一律走 `np.random.default_rng(derive(base_seed, epoch, index))`；**禁止**全局 `np.random`。
- 噪声库常驻内存，按 `sample_rate`（FF-01）一次性重采样到目标采样率并缓存。
- `--disable-augment` 只跳过步骤 ①②③⑤，特征管线不变——这样 `T-06` 的 on/off 对比才只差增强一项。
- 任何写盘调用视为缺陷（判据 4/5）。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `pytest ai/tests/test_augment.py` | 单测 | 13 条判据（形状/值域/拒测试集/不落盘/SNR/增益/顺序/LUFS/掩码比例/patch 相对 `ref` 未被替换/可复现/开关） | D2 起，每次改动 |
| 不落盘回归 | 文件快照 | 增强 500 次后 `ai/data/` 文件数与 sha256 集合不变 | D2、D3、D9 回归 |
| 顺序正确性 | 数值断言 | `g_r=2.0` 与 `1.0` 的输出 RMS 比 ∈ [1.8, 2.0] | D2 |
| BS.1770 一致性 | 数值断言 | numpy 自实现与 `pyloudnorm` 在 10 条样本上偏差 ≤ 0.1 LU | D2（仅在回退路径启用时） |
| 吞吐 | 计时 | 单 patch 增强 + 特征 ≤ 50 ms（4 线程） | D2 |
| 与训练联调 | 集成 | `train.py --augment on` 跑通 1 epoch 无异常 | D3（`PLAN-T-04`） |

## 5. 完成定义（DoD）
- [ ] `SPEC-T-03` §7 全部 13 条判据通过。
- [ ] `SPEC-T-03` §9 的 `X-06` 声明已在代码中以注释形式登记（`augment.py` 顶部说明「不实现 RIR/Mixup」）。
- [ ] `--disable-augment` 与 `--disable-denoise` 开关已可被 `PLAN-T-06` 直接调用。
- [ ] `ai/data/` 在增强过程中零写入（文件快照证据）。
- [ ] SpecAugment `T/F` 语义已获 A 确认并回写 `SPEC-T-03` §10.1。
- [ ] 未修改 `shared/feature_config.json`。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| `pyloudnorm` 不可用（装包失败） | import 失败 | 用 numpy/BS.1770 自实现；**必须**先与 `pyloudnorm`（若在另一环境可得）比过；否则把 LUFS 目标改为「RMS 归一化到 −20 dBFS」并**在报告中声明目标值已变更** |
| 噪声混入过强导致训练不收敛 | 训练 loss 抖动、`snr_db` 集中在 5 dB | SNR 下界从 5 dB 提到 8 dB；变更须回写 `SPEC-T-03` §5 并重跑 `T-04` 基线 |
| LUFS 归一化抹平类别间能量差异 | 混淆矩阵在 `chips`/`gummies` 间恶化 | 关闭 LUFS（`T-06` 消融表现有「增强组合 on/off」，可临时拆出单因子），并把结论写进 `SPEC-T-06` 表 |
| SpecAugment 语义误判导致过强遮蔽 | 训练准确率明显低于基线 | 按 `SPEC-T-03` §10.1 改判为「宽度」语义；两种语义各跑一次并保留数据 |
| 增强成为训练瓶颈 | step 耗时 > 100 ms | 提高 DataLoader worker 数；仍不足则把噪声混合的概率降为 0.7 并记录（属参数变更，须回写 SPEC） |
| 有人把增强结果离线落盘"提速" | 目录出现增强数据 | 视为**违反 SPEC**：删除产物，`PLAN-C-05` 回归加入目录扫描断言 |

## 7. 与检查点的关系
- **CP1（D3 晚，跨域实测）**：本功能是 `T-04` 增强训练的必要前置。若 D3 仍未接入增强，CP1 只能给出**无增强基线**的跨域数字，`T-05` E2 的结论必须标注「未使用增强」。
- **D3 → D4**：`T-06` 消融（同 D3）直接复用本功能的两个开关；若开关不可用，`T-06` 无法产出消融表，答辩「每个设计决策都有数据支撑」的主张失效。
- **不可裁剪性**：允许在极端工时压力下只保留「噪声混合 + LUFS」，但**必须**在 `T-06` 表中如实反映，不得声称做了四项。

**文档结束**
