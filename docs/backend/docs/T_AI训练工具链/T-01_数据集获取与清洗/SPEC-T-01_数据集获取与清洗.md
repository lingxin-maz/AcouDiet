# SPEC-T-01 数据集获取与清洗

| 项 | 值 |
|---|---|
| 域 | T · AI 训练工具链（离线） |
| 归属 | A |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.1 / §5.1（修正 `N-14`）；`shared/feature_config.json`；`SPEC-00` §3.1 FF-01/FF-03/FF-04/FF-05/FF-09/FF-11、§3.3 FF-19；`docs/00_功能清单与数量分析.md` §2 |
| 依赖的 SPEC | 无（域 T 的起点）。下游：`SPEC-T-02` |

## 1. 目标与范围

### 1.1 一句话目标
把 Eating Sound Collection（Ma et al. 2020，20 类 / 11,141 片段）筛选为 FF-19 六类、规模 3,000–4,000 片段的可用语料，并把**自采环境噪声**与**自采手机数据**规范化入库，产出可被 `SPEC-T-02` 直接消费的清单与类别分布表。

### 1.2 范围内（In Scope）
1. ESC 公开数据集的获取、解压、许可证与出处登记。
2. `chips / cabbage / gummies / noodles / carrot / drink`（FF-19）六类子集筛选，目标 **3,000–4,000 片段**。
3. 时长、采样率、声道、位深校验（对照 FF-01）；坏样本剔除并给出剔除原因。
4. 类别分布表产出（每类片段数、总时长、来源）。
5. **自采环境噪声**（10–20 分钟，食堂 / 办公室 / 街道三类场景）入库至 `ai/data/noise/`，供 `SPEC-T-03` 的噪声混合使用。
6. **自采手机数据规范检查**：6 类 × 5 人 × 8 段 = 240 段，每段 5–10 s，覆盖桌面 30 cm / 手持 / 近距离 10 cm 三种姿态；由 `ai/scripts/collect_check.py` 校验并输出检查报告。
7. 为下游生成 `path,label,subject_id,source_file_id,split` 五列可用的 ingest 清单（`split` 列由 `SPEC-T-02` 填充）。

### 1.3 范围外（Out of Scope）——必须显式写出
- **不做划分**（train/val/test 的产生、防泄漏断言）→ `SPEC-T-02`。
- **不做增强**（噪声混合、增益、LUFS、SpecAugment）→ `SPEC-T-03`。
- **不落盘 Mel 特征**：特征在训练时在线计算（`SPEC-T-04` §2）；本功能只交付音频与清单。
- **不得为了「凑数字」把子集扩到每类 1,000 条**（主方案修正 `N-14`）：规模上限 4,000 片段，超出部分不因「更多更好」而纳入。
- **不获取 RIR 混响数据集**（`X-06` 已裁剪，`ai/data/rir/` 无用途，见 §9）。
- **不修改 `shared/feature_config.json`**：本域对该文件**只读**（FF 数值的唯一真源）。
- 不做音频内容人工标注（ESC 自带类别标签即真值）；不做重复片段聚类去重之外的任何模型级处理。

## 2. 功能行为

### 2.1 触发与前置条件
| 前置 | 说明 |
|---|---|
| 环境激活 | `. D:\Desktop\Food\_toolchain\acoudiet-env.ps1`（FF-23） |
| 装包方式 | 必须经 `_toolchain\pip_runner.py`，`--target D:\Desktop\Food\_toolchain\site-packages` |
| ESC 落位 | 原始压缩包/目录位于 `ai/data/raw/esc/`，**不入 Git** |
| 自采落位 | `ai/data/raw/mobile/`，命名规则 `P0x_<class>_<pose>_<seq>.wav` |
| 伦理前置 | 自采参与者已签 `SPEC-C-02` 的知情同意书，编号匿名化为 `P01`–`P05` |

### 2.2 主流程（编号步骤）
1. `dataset.py --stage ingest` 读取 `shared/feature_config.json`（只读）与 `ai/data/raw/` 索引。
2. 遍历 ESC 目录，按官方类别标签映射到 FF-19 的 6 类；不在这 6 类的目录直接跳过并计入 `skipped_classes`。
3. 逐文件读取元信息：`duration_s`、`sample_rate`、`channels`、`bits`（只读头部，不整段解码）。
4. 采样率校验：`sample_rate != FF-01` → 记 `reject_reason = SR_MISMATCH` 并剔除（**不做隐式重采样**，避免引入重采样器版本差异）。
5. 时长校验：`duration_s < patch_seconds`（FF-09）→ 记 `reject_reason = TOO_SHORT` 并剔除。
6. 坏样本剔除：全静音（RMS < 1e-4）、削波（|x| ≥ 0.999 样本占比 > 1%）、解吗失败、长度为零。
7. 生成去重键 `source_file_id`：ESC 用**原始录音文件 ID**（文件名主干，不含扩展名）；自采用 `P0x_<class>_<pose>_<seq>`。
8. 校验自采数据规模与姿态覆盖：`collect_check.py` 断言 6 类 × 5 人 × 8 段 = 240 段，每人每类 8 段，三姿态各 ≥2 段。
9. 校验噪声库：总时长落在 10–20 min 区间，三类场景各 ≥1 文件。
10. 汇总输出 ingest 清单与类别分布表；任何一类片段数越界则打印告警（见 §2.4）。

### 2.3 状态与状态迁移
**无状态**：本功能是一次性批处理脚本（CLI），不维护跨调用状态；重复执行必须幂等（同输入 → 同清单字节序稳定）。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 单类片段数 < 500 | `--strict` 下非零退出（`exit 3`），并提示触发 FF-19 降级开关评估 |
| 自采某类 <5 人的数据 | 非零退出（`exit 4`），自采必须补齐，不得用 ESC 顶替 |
| 噪声库不足 10 min | 非零退出（`exit 5`）；超过 20 min 只告警不退出 |
| 同一 `source_file_id` 出现在多个目录 | 记 `WARN_DUP_ID`，保留首个并以路径字典序决定 |
| 片段时长 > 60 s | 不剔除（长片段在训练侧按 patch 切分），但记 `LONG_FILE` 标记 |
| 文件路径含非 ASCII | 一律 `utf-8` 读写清单，禁止 `gbk` |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| CLI | `python ai/src/dataset.py --stage ingest [--strict]` | `--config shared/feature_config.json`；`--raw ai/data/raw/` | 退出码 0；stdout 印刷类别分布表；写 ingest 清单与 rejects 清单 | 离线工具，非零退出码 + rejects 清单；文件 IO 失败沿用 `ACD-IO-001`（`API-00` §3.5） |
| CLI | `python ai/scripts/collect_check.py` | `ai/data/raw/mobile/` | 退出码 0；stdout 打印 5×6 覆盖矩阵 | `exit 4`（规模/姿态不足）；采样数不符沿用 `ACD-MEL-002` |
| 文件 | ingest 清单（T-02 的输入契约） | — | `ai/data/raw/ingest_manifest.csv`，列见 §4 | — |
| 文件 | 剔除清单（审计用） | — | `ai/data/raw/rejects.csv`，列 `path,reject_reason` | — |
| 下游 | `SPEC-T-02` 消费 | ingest 清单 | `ai/data/splits/*.csv` | — |

> 完整签名以 `docs/*/docs_api/` 为准；本功能不跨端，无 MethodChannel 契约。

## 4. 数据契约

**ingest 清单列（列名冻结，不得改名；与 `API-06` 的训练侧数据契约一致）**：

| 列 | 类型 | 单位/值域 | 可空 |
|---|---|---|---|
| `path` | string | 相对仓库根路径，POSIX 分隔符 | 否 |
| `label` | string | 取自 FF-19 的英文 ID | 否 |
| `subject_id` | string | 自采填 `P01`–`P05`；公共集填**空字符串** `""`（无主体信息，`API-06` §3.1） | 否（公共集允许空串） |
| `source_file_id` | string | 原始录音文件 ID（T-02 的划分键） | 否 |
| `split` | string | 本功能输出为空；由 `SPEC-T-02` 填 `train`/`val`/`test_public`/`test_mobile` | 是 |
| `source` | string | `esc` \| `mobile` | 否 |
| `duration_s` | float | s，>0 | 否 |
| `sample_rate` | int | 必须等于 FF-01 | 否 |
| `pose` | string | `desk30` \| `handheld` \| `near10`；ESC 行为空 | 是 |

- 噪声入库契约：`ai/data/noise/{canteen,office,street}_NN.wav`，单声道、FF-01 采样率、16-bit PCM（FF-01）。
- `docs/common/docs_api/schemas/` 下**无**本功能对应的 schema 文件；离线中间产物位于 `ai/data/raw/`，**不进入** App 侧制品清单（`API-05` §7）。
- 自采原始音频**不入 Git**（体积 + 隐私），仓库内只保留清单与 sha256；此为准入规则，违反即视为验收不通过。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 采样率 / 声道 / 位深 | FF-01 |
| 窗长与 `n_fft` | FF-03（仅用于时长下界判定的校验记录） |
| `hop_length` | FF-04 |
| `n_mels` / `fmin` / `fmax` | FF-05 |
| patch 采样数与秒数 | FF-09 |
| `n_frames` | FF-11 = **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| 六类枚举 | FF-19 |
| 输入张量形状 | FF-14（本功能不产出张量，仅记录形状用于清单自检） |

**本域自有常量（非 FF，权威定义在本 SPEC）**：

| 常量 | 值 | 依据 |
|---|---|---|
| 六类子集规模 | 3,000–4,000 片段 | 主方案修正 `N-14`（禁止扩到每类 1,000 条） |
| 自采手机数据 | 6 类 × 5 人 × 8 段 = 240 段 | 本 SPEC §1.2 |
| 自采单段时长 | 5–10 s | 同上 |
| 采集姿态 | `desk30` / `handheld` / `near10` | 同上 |
| 自采噪声时长 | 10–20 min，3 场景 | 同上 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| ESC 无法获取（网络/许可） | 解压后目录为空或类别缺失 | 打印 `ESC_UNAVAILABLE`；降级为「仅自采 + 公开少量样本」，并在 `PLAN-T-05` 声明无法给出 E1 上限参考 | 无 UI；仅日志与清单 |
| 单类片段数不足 500 | 分布表统计 | 非零退出；提请评估 FF-19 降级开关（4 类） | 无 |
| 采样率不符 | 头部读取 | 剔除并记 `SR_MISMATCH`，不做隐式重采样 | 无 |
| 短片段 | 时长校验 | 剔除并记 `TOO_SHORT` | 无 |
| 噪声库不足 | 时长求和 | 非零退出 `exit 5`；不得用白噪声冒充自采噪声 | 无 |
| 自采规模/姿态不足 | `collect_check.py` | 非零退出 `exit 4`，责成补采 | 无 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | ingest 全流程成功 | `python ai/src/dataset.py --stage ingest --config shared/feature_config.json` | 退出码 == 0 |
| 2 | 六类子集规模达标 | 解析 `ai/data/raw/ingest_manifest.csv` 的 `source=esc` 行数 | 3,000 ≤ n ≤ 4,000 |
| 3 | 类别覆盖完整 | 清单 `label` 去重集合 | == FF-19 的 6 个英文 ID，无缺无多 |
| 4 | 采样率全部合规 | 清单 `sample_rate` 唯一值集合 | == {FF-01} |
| 5 | 无短片段 | 清单 `duration_s.min()` | ≥ FF-09 的秒数字段（按 `feature_config.patch_seconds` 读取，不写字面值） |
| 6 | 无坏样本残留 | 清单文件不存在 `reject_reason` 列非空行 | 命中数 == 0 |
| 7 | 剔除记录可审计 | `ai/data/raw/rejects.csv` 存在且列名 == `path,reject_reason` | 文件存在 + 列名全等 |
| 8 | 自采规模与姿态 | `python ai/scripts/collect_check.py` | 退出码 == 0 且 stdout 含 `240 segments`、`pose_coverage=OK` |
| 9 | 噪声库合规 | 脚本 `--stage check-noise` | 退出码 == 0 且 stdout 含 `noise_minutes in [10,20]`、`scenes=3` |
| 10 | 清单可被下游直接消费 | `pytest ai/tests/test_dataset_contract.py::test_manifest_columns`（`SPEC-C-05` 套件） | 断言五列齐全且 `subject_id` 无空值 |
| 11 | 幂等 | 连续执行 ingest 两次并比对 `sha256` | 两次清单 sha256 相等 |
| 12 | 未越界扩样 | 断言每类 ESC 片段数 ≤ 1,000 | 全部为真 |

## 8. 非功能约束
- **隐私**：自采音频匿名化为 `P01`–`P05`，与 `SPEC-C-02` 的同意书编号一一对应；原始 wav 不入 Git。
- **性能**：ingest 全流程（含元信息遍历）在开发机 ≤ 30 min；只读音频头部，不做全量解码。
- **可复现**：清单排序键固定为 `(source, label, source_file_id)`；同一输入目录树产出字节级相同的清单。
- **存储**：`ai/data/` 总占用 ≤ 8 GB；超出时先剔除长片段再告警，不得静默截断类别。
- **依赖**：只用 `librosa` / `soundfile` / `numpy` / 标准库；禁止引入新的音频解码库（避免与 `SPEC-T-08` 的 Python 侧管线产生第二个实现）。

## 9. 裁剪与未做
| 项 | 声明 |
|---|---|
| `X-06` RIR 混响 + Mixup | **不做**。故 `ai/data/rir/` 目录**已无用途**：应在仓库中**删除**；若因 `PLAN-00` §5 目录结构整洁性需要保留占位，则必须保留为空目录并在目录内说明「`X-06` 裁剪，不获取任何 RIR 数据」，且**不得**被任何脚本读取。 |
| 其他 `X-*` | 与本功能无关。 |
| 若本功能被裁剪 | 后果：下游 `T-02`→`T-08` 全部无输入，CP1（D3 跨域实测）无法出数，交付主张崩塌。**最低兜底**是 240 段自采数据 + 少量公开样本，但此时**不得**声称使用 Eating Sound Collection 作为训练语料。 |

## 10. 开放问题
1. **✅ 已关闭（依据 `ADR-P1`）**：原问题「`n_frames` 未拍板（FF-11，`SPEC-00` §3.5）」**已冻结为 ~~`n_frames = 129`~~ → 已由 `ADR-21`（2026-09-12）修订为 `n_frames = 128` + `raw_mel_frames = 129`（选项 B 的 4.096 s 窗口 / 65536 样本不变）**，本功能用 `feature_config` 的 `patch_seconds` 判定时长下界，阈值与训练窗长一致，**ingest 校验无需重跑**。选项 A（4.064 s / 65024 样本）**已否决**，故原「4.064–4.096 s 之间的片段会导致判定阈值必须随拍板重跑」的连带风险**已随拍板取消**；D2 训练可直接开工。
2. **`API-06`（AI 训练侧数据契约）已落盘**（`docs/backend/docs_api/API-06_AI训练侧数据契约.md`）。本 SPEC §4 的列名已与其 §3.1 逐列比对：**一致**（`path`/`label`/`subject_id`/`source_file_id`/`split`），且公共集 `subject_id` 已按其要求改为**空字符串** `""`。本 SPEC 的 ingest 清单属 `ai/data/raw/` 下的**离线中间产物**，`API-06` 未定义其额外列（`source`/`duration_s`/`sample_rate`/`pose`），不影响四份划分 CSV 的契约；若 `API-06` 后续新增 ingest 层契约，须走 `SPEC-C-03`。
3. **ESC 许可证与可得性**：需 A 在 D0 确认下载渠道与研究用途许可；若不可得，按 §6 降级。
4. **是否引入第 7 类「未识别」样本**：`SPEC-T-05` §2 允许 7 类混淆矩阵。数据侧结论是**不产生第 7 类训练样本**（FF-19 只有 6 类），第 7 类仅在评估侧由阈值判据产生。**需 A 确认评估侧口径。**
5. **类别不平衡是否需要类别权重**：ESC 六类自然分布不均，`FF-17` 未规定类别权重。本 SPEC 不做处理，登记待 A 在 `PLAN-T-04` 决策。

**文档结束**
