# SPEC-T-03 数据增强管线

| 项 | 值 |
|---|---|
| 域 | T · AI 训练工具链（离线） |
| 归属 | A |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.7 / §7.3（`X-06` 裁剪后）；`shared/feature_config.json`；`SPEC-00` §3.1 FF-01/FF-04/FF-05/FF-07/FF-08/FF-09/FF-11、§8；`SPEC-T-02` §2.2 断言 C；`docs/00_功能清单与数量分析.md` §4 |
| 依赖的 SPEC | `SPEC-T-01`（噪声库）、`SPEC-T-02`（划分约束）。下游：`SPEC-T-04` `SPEC-T-06` |

## 1. 目标与范围

### 1.1 一句话目标
在训练时**在线**生成四项增强（自采噪声混合 / 随机增益 / LUFS 响度归一化 / SpecAugment），提升跨域鲁棒性，同时**不产生任何落盘文件**、**绝不让测试集参与增强**。

### 1.2 范围内（In Scope）
1. **环境噪声混合**：SNR 5–20 dB，噪声源**必须**为 `SPEC-T-01` 入库的自采噪声库（`ai/data/noise/`）。
2. **随机增益**：0.5–2.0× 线性幅度。
3. **LUFS 响度归一化**：目标 −23 LUFS（EBU R128 / ITU-R BS.1770 测量）。
4. **SpecAugment**：时间掩码 `T=10`、频率掩码 `F=8`（解释见 §5）。
5. 增强**在线**执行、**不落盘**；增强链顺序固定（§3.3）。
6. 提供 `--disable-augment` / `--disable-denoise` 开关，供 `SPEC-T-06` 消融实验复用**同一条代码路径**。
7. 增强统计回传：`snr_db` / `g_r` / `clipped_ratio` / `specaug_masked_ratio` / `skipped_stats` 写入训练日志，供 `SPEC-T-04` 记录与 `SPEC-T-06` 解释消融差异。

### 1.3 范围外（Out of Scope）——必须显式写出
- **不做 RIR 混响卷积**、**不做 Mixup**（`X-06` 已裁剪，见 §9）。
- **不做**时间拉伸 / 音高偏移 / 变速（speed perturb）、**不做**频谱加性白噪声（噪声必须来自自采库）。
- **不落盘增强结果**：不允许生成「增强后的数据集」目录（离线扩增属明确禁止项）。
- **不在测试集上调用增强 API**：`augment()` 对 `split != "train"` 必须 `assert` 失败。
- **不改动 FF-07/FF-08 的归一化方式**：增强步骤不得替换训练链路的 dB 参考与归一化口径（`ADR-21`：`power_to_db_ref = "patch_max"` → 丢尾帧 → `per_patch_minmax`）。~~原措辞「不允许引入 `ref=np.max` 逐 patch 归一化（域偏移陷阱）」已由 `ADR-21`（2026-09-12）反转~~ —— patch 相对刻度**现在是**冻结链路的一部分，**增强侧不得把它换成绝对刻度或固定 dB 截断**。本行的约束方向不变（"不得替换"），只换了被替换物的名字。
- 不修改 `shared/feature_config.json`（本域只读）。
- 不在本功能内做降噪开关的**评估**（归 `SPEC-T-06`）；本功能只提供开关。

## 2. 功能行为

### 2.1 触发与前置条件
| 前置 | 说明 |
|---|---|
| 调用方 | `ai/src/dataset.py` 的 `__getitem__`，仅在 `split == "train"` 分支 |
| 噪声库 | `ai/data/noise/` 至少 3 个场景文件，总时长 10–20 min（`SPEC-T-01` §7 判据 9） |
| 划分 | `ai/data/splits/*.csv` 已冻结（`SPEC-T-02`） |
| 环境 | `. D:\Desktop\Food\_toolchain\acoudiet-env.ps1`；新依赖（`pyloudnorm`）必须经 `_toolchain\pip_runner.py --target D:\Desktop\Food\_toolchain\site-packages` 安装 |
| 采样 | 训练样本以 patch 为单位（FF-09） |

### 2.2 主流程（编号步骤）
1. 从 `train.csv` 取一条记录，读取 wav，按 patch 长度（FF-09）切出待增强片段 `x`（float32，单声道）。
2. **噪声混合**：从噪声库随机选文件与随机起点，取与 `x` 等长的片段 `n`（不足则循环平铺）；由均匀分布采样 `snr_db ~ U[5, 20]`，按 `x' = x + n · ‖x‖_rms / (‖n‖_rms · 10^(snr_db/20))` 混合；`x` 全静音时跳过噪声混合并记录。
3. **LUFS 归一化**：测量 `x'` 的积分响度 `L`，按增益 `g_l = 10^((−23 − L)/20)` 归一化到 −23 LUFS；`L` 低于测量下限（< −70 LUFS）时按 `SPEC-T-03` §6 处置。
4. **随机增益**：`g_r ~ U[0.5, 2.0]`，`x'' = clip(g_r · x', −1.0, 1.0)`。**必须在 LUFS 归一化之后**（否则归一化会抵消增益，见 §3.3）。
5. **特征提取**：走 FF-02 → FF-03/FF-04 → FF-05 → FF-06 → FF-07 → FF-08 的固定管线，得到值域 `[0,1]` 的 `[128, n_frames]` 张量。
6. **SpecAugment**：在归一化后的 Mel 上施加**时间掩码**与**频率掩码**，掩码填充值 `0.0`（归一化下界）。
7. 断言输出形状 == FF-14 的 `[1, 128, n_frames, 1]`、值域 ⊂ `[0,1]`、`dtype == float32`。
8. 返回张量；**不写任何文件**。

### 2.3 状态与状态迁移
**无状态**（纯函数式增强）。唯一状态是随机数发生器：每次调用以 `default_rng(seed_derived)` 构造，`seed_derived = f(base_seed, epoch, sample_index)`，保证同一 `(base_seed, epoch, index)` → 同一增强结果（可复现）。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 源片段短于 patch（FF-09） | 循环平铺至 patch 长度；不得零填充（零填充会伪造静音，污染 VAD 相关统计） |
| 源片段全静音（RMS < 1e-4） | 跳过噪声混合与 LUFS（无可测响度），只做随机增益；计入 `skipped_stats` |
| 噪声文件短于 patch | 循环平铺 |
| 增益后削波 | `clip(−1.0, 1.0)`，并计入 `clipped_ratio`；若某 batch 削波样本 >10% 则告警 |
| SpecAugment 掩码重叠 | 允许重叠，但掩码总面积不得超过单轴的 10%（§5 的宽度上限保证） |
| `disable_augment=True` | 跳过步骤 2–4 与 6，仅保留步骤 5（供 `SPEC-T-04` 无增强基线与 `SPEC-T-06` 消融） |
| 测试集样本传入 | `assert split == "train"` 失败 → 抛异常，非零退出 |
| 噪声文件采样率 ≠ FF-01 | 加载时统一重采样到 FF-01 并记录；**不得**直接混用（会污染 SNR 计算） |
| 同一 batch 内噪声片段被重复使用 | 允许（噪声库总时长有限），但须记录复用率；复用率过高时告警并在报告中说明噪声多样性局限 |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| 函数 | `augment_audio(x: np.ndarray, split: str, rng, cfg) -> np.ndarray` | 单声道 float32 patch；`split` | 增强后音频 | `AssertionError`（`split != "train"`） |
| 函数 | `augment_mel(mel: np.ndarray, rng, cfg) -> np.ndarray` | `[128, n_frames]`，值域 `[0,1]` | 同形状张量 | `ACD-MEL-001`（帧数不符，`API-00` §3.5） |
| 函数 | `load_noise_bank(dir, sample_rate) -> NoiseBank` | 噪声目录 | 噪声样本集合 | `ACD-IO-001`（文件读取失败） |
| CLI | `python ai/src/train.py --augment {on,off} --denoise {on,off}` | 见 §2.4 | 训练运行 | — |
| 消费方 | `SPEC-T-04` 的 `dataset.py` | — | — | — |
| 日志 | 增强统计回传 | 每次增强调用 | `snr_db`/`g_r`/`clipped_ratio`/`specaug_masked_ratio` 统计行 | — |

> 本功能不跨端，无 MethodChannel 契约；契约以 `ai/src/augment.py` 的导出函数为准。增强统计字段的登记位置（`train_log.jsonl`）属离线中间产物，**不进** `API-06` §1 的制品清单。

## 4. 数据契约
- 输入：`ai/data/splits/train.csv` 行 + 对应 wav；`ai/data/noise/*.wav`。
- 输出：**内存张量**，形状 FF-14、`dtype=float32`、值域 `[0,1]`；**无文件输出**（这是硬约束）。
- 统计输出（仅控制台/训练日志）：`snr_db` 采样值分布、`g_r` 分布、`clipped_ratio`、`specaug_masked_ratio`、`skipped_stats`；这些字段随 `SPEC-T-04` 的训练日志一并落进 `ai/artifacts/train_log.jsonl`（离线中间产物，非 App 制品）。
- `docs/common/docs_api/schemas/` 下无对应 schema；本功能**不产出**任何 App 侧契约文件。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 采样率 / 声道 | FF-01 |
| 预加重 / 窗 / `n_fft` / `hop_length` | FF-02 / FF-03 / FF-04 |
| `n_mels` / `fmin` / `fmax` / `power` | FF-05 / FF-06 |
| 压缩与 `top_db` / `ref` | FF-07（`ADR-21`：`ref = "patch_max"`、`top_db = 80`；旧值 ~~`ref = 1.0` 绝对刻度~~） |
| 归一化（patch 相对 dB + 丢尾帧 + per-patch min-max） | FF-08（`ADR-21`：`normalization = "per_patch_minmax"`；旧值 ~~固定 dB 截断 `clip(x,−80,0)`、`db_clip_range`~~ 已删除） |
| patch 采样数 | FF-09 |
| `n_frames` | FF-11 = **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| 输入张量形状 | FF-14 |

**本域自有常量（非 FF，权威定义在本 SPEC）**：

| 常量 | 值 | 说明 |
|---|---|---|
| 噪声 SNR 区间 | `[5, 20]` dB，均匀采样 | 主方案 §7.3 |
| 随机增益区间 | `[0.5, 2.0]`×，均匀采样 | 同上 |
| LUFS 目标 | `−23.0` LUFS | 同上 |
| SpecAugment `T` | `10` = 时间掩码**条数**上限 | 解释见 §10.1 |
| SpecAugment `F` | `8` = 频率掩码**条数**上限 | 解释见 §10.1 |
| 时间掩码单条宽度上限 | `⌊n_frames / 10⌋` 帧 | 由 `T=10` 推导，保证单轴遮蔽 ≤10% |
| 频率掩码单条宽度上限 | `⌊n_mels / 8⌋` 频带 | 由 `F=8` 推导 |
| 掩码填充值 | `0.0`（归一化下界） | 保证值域不越界 |
| 增强启用概率 | `1.0`（四步全做；随机性只来自参数采样） | 可复现优先 |
| 随机种子 | `base_seed = 20260910`，派生 `f(base_seed, epoch, index)` | 同配置可复现 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 噪声库缺失/为空 | `load_noise_bank` 返回空 | **不静默跳过**：抛错并非零退出；由 `PLAN-T-03` §6 决定是否转入「关闭噪声混合」的降级训练 | 无 UI；日志告警 |
| LUFS 无法测量（近静音） | `L < −70 LUFS` | 跳过归一化并计数；不写成 0 dB 或随意值 | 无 |
| `pyloudnorm` 不可用 | import 失败 | 按 BS.1770 用 numpy 自实现；**必须**在 10 条样本上与 `pyloudnorm` 偏差 ≤ 0.1 LU 才允许使用 | 无 |
| 掩码越界（宽度 > 轴长） | 宽度钳制 | `w = min(w, axis_len − 1)`；仍越界则跳过该条掩码并计数 | 无 |
| 测试集样本被传入 | 断言 | 抛 `AssertionError`，训练进程非零退出 | 无 |
| 增强结果越界 `[0,1]` | 形状/值域断言 | 抛错终止训练；**不得**用 clip 掩盖 | 无 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 增强链可运行 | `pytest ai/tests/test_augment.py` | 退出码 == 0 |
| 2 | 形状与值域 | `test_augment.py::test_shape_range` | 形状 == FF-14 且 `min ≥ 0`、`max ≤ 1`、`dtype == float32` |
| 3 | 测试集禁止增强 | `test_augment.py::test_reject_non_train_split` | 对 `split ∈ {val, test_public, test_mobile}`（`API-06` §3.1 的全部非训练枚举）均抛异常 |
| 4 | 不落盘 | `test_augment.py::test_no_disk_write` | 增强 500 次后 `ai/data/` 文件数与 sha256 集合**不变** |
| 5 | 无落盘式 API | 静态检查 `ai/src/augment.py` | 不含 `sf.write` / `np.save` / `write_bytes` / `open(...,'w')`，命中数 == 0 |
| 6 | SNR 区间 | `test_augment.py::test_snr_range` | 1000 次采样的 `snr_db` 全部落在 `[5, 20]` |
| 7 | 增益区间 | `test_augment.py::test_gain_range` | 1000 次采样的 `g_r` 全部落在 `[0.5, 2.0]` |
| 8 | 增益未被归一化抵消 | `test_augment.py::test_gain_applied_after_lufs` | 置 `g_r` 为固定 2.0 时，输出 RMS 与置 1.0 时之比 ∈ `[1.8, 2.0]`（证明顺序正确） |
| 9 | LUFS 命中 | `test_augment.py::test_lufs_target` | 10 条样本归一化后实测响度 ∈ `[−23.5, −22.5]` LUFS |
| 10 | SpecAugment 遮蔽比例 | `test_augment.py::test_specaug_ratio` | 单轴遮蔽像素占比 ≤ 10%（时间轴）/ ≤ 12.5%（频率轴） |
| 11 | patch 相对 dB 参考未被替换 | 静态检查 `ai/src/features.py` + `augment.py` | **必须**使用 `power_to_db_ref = "patch_max"`；不含绝对刻度 `ref=1.0` / 固定 dB 截断 `clip(x,−80,0)` / `db_clip_range`（命中数 == 0）。⚠️ **本判据已随 `ADR-21`（2026-09-12）反转**：原文为「固定 dB 截断未被替换 —— 不含 `ref=np.max` / `ref="max"`，命中数 == 0」，与交付制品直接冲突 |
| 12 | 可复现 | `test_augment.py::test_determinism` | 同一 `(base_seed, epoch, index)` 两次调用输出逐元素相等 |
| 13 | 关闭开关有效 | `python ai/src/train.py --augment off --dry-run` | 退出码 0 且日志中 `augment=off` 记录存在（供 `T-06` 复用） |
| 14 | 噪声源必须是自采库 | `test_augment.py::test_noise_source` | 被使用的噪声文件路径全部位于 `ai/data/noise/` 下；不得引入白噪声或外部噪声集 |
| 15 | 关闭增强不改变特征管线 | `test_augment.py::test_disable_preserves_features` | `--augment off` 时输出 == 原特征（逐元素），证明开关只影响增强步骤 |
| 16 | 越界自动检出而非静默掩盖 | `test_augment.py::test_range_guard` | 人为构造越界输入时抛错，**不得**用 `clip` 静默修正 |

## 8. 非功能约束
- **内存/吞吐**：增强＋特征提取单 patch 在 CPU 上 ≤ 50 ms（4 线程），不得成为 D2/D3 训练的瓶颈；噪声库一次性载入并常驻内存（≤200 MB）。
- **可复现**：同配置 + 同种子 → 同训练曲线；随机性来源仅 `default_rng`，禁止使用全局 `np.random`。
- **隐私**：噪声库为自采环境录音，不含可识别的人声内容；若含人声须剔除该片段（`SPEC-C-02` 的伦理要求）。
- **依赖**：允许新增 `pyloudnorm`（经 `pip_runner.py` 安装到 `_toolchain\site-packages`），**不允许**新增其他音频处理库（避免与 `SPEC-T-08` 的 Python 侧管线产生第二个实现）。
- **不做磁盘缓存**：即使为了加速也不允许缓存增强结果（会破坏「测试集不参与增强」的可审计性）。

## 9. 裁剪与未做
| 项 | 声明 |
|---|---|
| `X-06` RIR 混响 | **不做**。理由：需额外 RIR 数据集，且 10 天窗口内无验证收益的证据。**本项目不获取、不编写、不引用任何 RIR 数据**；`ai/data/rir/` 目录已无用途，应删除或保留为空并注明 `X-06` 裁剪（见 `SPEC-T-01` §9）。 |
| `X-06` Mixup | **不做**。理由：小数据下 Mixup 的线性插值假设不成立，可能有害（主方案 §8.2.2）。**禁止**在 `augment.py` 中顺手实现。 |
| 时间拉伸 / 音高偏移 / 变速 | **不做**（会改变类别可分的时序结构，且需额外依赖）。 |
| 加性高斯白噪声 | **不做**：噪声必须来自自采库，否则「跨域鲁棒性」的论据失效。 |
| 若本功能被裁剪 | 后果：`T-04` 只能产出无增强基线，跨域数字（`T-05` E2）将显著偏低且**无法归因于增强**；`T-06` 的「增强组合 on/off」消融行无法产出。此时必须在报告中声明「未使用增强」。 |
| 不可裁剪声明 | 本功能不在主方案 §8.2.1 五项内；允许在极端工时压力下只保留「噪声混合 + LUFS」两项，但**必须**在 `T-06` 消融表中体现实际保留项。 |

## 10. 开放问题
1. **SpecAugment `T=10` / `F=8` 的语义（需 A 拍板）**：本 SPEC 将两者解释为**掩码条数上限**，单条宽度由 `⌊轴长/10⌋` 与 `⌊轴长/8⌋` 推导。若原意是**单条掩码宽度**（10 帧 / 8 频带），则实际遮蔽比例将显著降低（约 10 条 × 10 帧 = 77% 时间轴被遮，属不可接受的强度）——两种解释的模型效果差异很大，**必须在 D2 前确认**。
2. **✅ 已关闭（依据 `ADR-P1`）**：原问题「`n_frames` 未拍板（FF-11，`SPEC-00` §3.5）的影响」**已随冻结定案，并已由 `ADR-21`（2026-09-12）修订**：~~`n_frames = 129`~~ → `n_frames = 128`（`raw_mel_frames = 129`，选项 B），掩码宽度按 `⌊n_frames/10⌋` 计得 12，**增强参数无需变更**；特征张量形状（FF-14）修订为 `[1, 128, 128, 1]`（旧值 ~~`[1, 128, 129, 1]`~~，`ADR-21`），基线权重的复用性不再有"改选另一选项即归零"的风险。选项 A（128 / 4.064 s / 65024 样本）**已否决**，改选须走 `SPEC-C-03` 变更传播。
3. **LUFS 与 `SPEC-P-03` 的响度归一化关系**：端侧 `P-03` 做 RMS/LUFS 归一化，训练侧做 −23 LUFS 归一化。两侧目标值是否必须同源，尚需与 B 对齐（`API-01` 的 `getCapabilities` 未含 LUFS 字段）。**需 A+B 确认**；若不一致，须在 `T-08` 的报告中登记为已知差异。
4. **噪声混入后的 `voiced` 语义**：端侧 `P-02` 的 VAD 在真实噪声下会改变 `voiced` 分布，而训练侧增强不模拟 VAD 行为。此差异是否需要在 `T-06` 消融中用「降噪 on/off」间接覆盖，**需 A 判断**。

**文档结束**
