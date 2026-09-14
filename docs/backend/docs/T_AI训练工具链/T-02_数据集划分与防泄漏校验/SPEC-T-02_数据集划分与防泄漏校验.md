# SPEC-T-02 数据集划分与防泄漏校验

| 项 | 值 |
|---|---|
| 域 | T · AI 训练工具链（离线） |
| 归属 | A |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §3.1 / §5.1；`SPEC-00` §3.1 FF-11、§3.3 FF-19、§7（验收写法）；`SPEC-T-01` §4 的 ingest 清单；`docs/00_功能清单与数量分析.md` §2 |
| 依赖的 SPEC | `SPEC-T-01`（清单与划分键）。下游：`SPEC-T-03` `SPEC-T-04` `SPEC-T-05` |

## 1. 目标与范围

### 1.1 一句话目标
把 `SPEC-T-01` 的 ingest 清单划成 `train/val/test_public/test_mobile` 四个子集，并产出**机器可检的防泄漏断言**，使「测试集被污染」在 D1 就能被脚本发现而不是在答辩时被问出来。

### 1.2 范围内（In Scope）
1. **公共集（ESC）按原始录音文件 ID 划分**：`train` 70% / `val` 15% / `test_public` 15%（`test_public` 即主方案所称 `test_domain`）。
2. **自采集按人划分**：`P01`/`P02`/`P03` → **仅**用于跨域测试（`test_mobile.csv`），**绝不进训练**；`P04`/`P05` → 域适应微调的**验证集**。
3. 四条禁止行为写成**自动化断言**（§2.2 步骤 6–9）：
   ① 同一次进食会话的片段不跨子集；② 同一人的片段不跨子集；③ 测试集不参与任何增强；④ 不用测试集调超参。
4. 产出 `ai/data/splits/train.csv` / `val.csv` / `test_public.csv` / `test_mobile.csv`，列名与 `SPEC-T-01` §4 一致（`path,label,subject_id,source_file_id,split`）。
5. 划分清单的 sha256 冻结登记（供 `T-05` 复现）。
6. 打印划分统计（每子集文件数/会话数/片段数/每类分布）与四个 CSV 的 sha256，作为 `SPEC-T-04` 与 `SPEC-T-05` 复现的凭据。

### 1.3 范围外（Out of Scope）——必须显式写出
- **不产生、不修改任何音频**：划分只写 CSV，不移动/复制/裁剪 wav。
- **不做增强**（`SPEC-T-03`）；不落盘 Mel（`SPEC-T-04` 在线计算）。
- **不做 patch 级划分**：划分单元最低粒度是**音频文件**（`source_file_id`），**禁止**把同一文件的 patch 分到不同子集。
- **不做 k 折交叉验证**：10 天窗口内单次三级划分即可，登记为 `SPEC-T-05` §10 的推迟项。
- **不允许按片段数精确凑比例**：比例在**文件/会话**粒度上满足即可（§2.4 容差）。
- 不新增第 5 个划分文件（P04/P05 的落位争议见 §10）。

## 2. 功能行为

### 2.1 触发与前置条件
| 前置 | 说明 |
|---|---|
| 输入 | `ai/data/raw/ingest_manifest.csv` 存在且 `SPEC-T-01` §7 全部判据通过 |
| 关键列 | `source_file_id`（公共集划分键）、`subject_id`（自采划分单元）、`source` |
| 随机性 | 固定随机种子写入划分文件头注释，保证同一输入 + 同种子 → 同一划分 |
| 环境 | `. D:\Desktop\Food\_toolchain\acoudiet-env.ps1`；装包经 `_toolchain\pip_runner.py` |

### 2.2 主流程（编号步骤）
1. `dataset.py --stage split` 读入 ingest 清单（只读，不修改 `SPEC-T-01` 的产物）。
2. **会话归组**：为每条记录计算 `group_id`——公共集取原始录音会话标识（同一次录音的全部片段共享同一 `group_id`，由 `source_file_id` 的前缀/目录确定）；自采集 `group_id == subject_id`。
3. **公共集划分**：以 `group_id` 为**划分单元**做确定性洗牌（`random.Random(seed)`），按 70/15/15 分配，并以 `source_file_id` 落实（同一 `group_id` 全部文件同进退）。
4. **自采集划分**：`subject_id ∈ {P01,P02,P03}` → 写入 `test_mobile.csv`（该文件**只含这三人**，绝不进训练）；`subject_id ∈ {P04,P05}` → 写入 `val.csv` 作域适应验证集（`API-06` §3.2 明确「`P04`/`P05` 只可用于验证集，不得进 `train.csv`」）。公共集行的 `subject_id` 一律为**空字符串** `""`（`API-06` §3.1），不得填 `ESC` 等占位值。
5. 写四个 CSV：`train.csv` / `val.csv` / `test_public.csv` / `test_mobile.csv`，行内 `split` 列与文件名一致。
6. **断言 A（会话不跨子集）**：`groupby(group_id).split.nunique() == 1` 对全部记录成立。
7. **断言 B（人不跨子集）**：`groupby(subject_id).split.nunique() == 1` 成立；且 `{"P01","P02","P03"} ∩ train.csv.subject_id == ∅`、`{"P01","P02","P03"} ∩ val.csv.subject_id == ∅`；`train.csv` 的 `subject_id` 集合 == `{""}`；`val.csv` 的 `subject_id` 集合 ⊆ `{"", "P04", "P05"}`（对齐 `API-06` §3.3 断言 2/3）。
8. **断言 C（测试集不参与增强）**：`train.csv ∩ test_public.csv ∩ test_mobile.csv` 的 `path` 交集为空；且 `ai/data/splits/` 下除四个 CSV 外**不存在**任何以测试集为输入生成的派生文件。
9. **断言 D（不用测试集调超参）**：`ai/src/train.py`、`ai/src/model.py`、`ai/src/augment.py` 源码中**不出现**字面量 `test_public` / `test_mobile`（grep 命中数 == 0）；且早停与模型选择只读 `val.csv`。
10. 输出划分统计（每子集文件数、会话数、片段数、每类分布）与控制台汇总；写 `sha256` 登记行。

### 2.3 状态与状态迁移
**无状态**：CLI 批处理，重复执行幂等（同种子 + 同输入 → 同 CSV 字节）。划分文件一旦被 `T-04` 消费即视为**冻结**；此后的任何变更等同于**重做训练**，须走 `SPEC-C-03` 变更传播。

### 2.4 边界条件
| 边界 | 处理 |
|---|---|
| 比例容差 | 会话/文件数比例允许 ±2 个百分点；**片段数比例不设容差**（只报告不判定） |
| 某一类在 `val` 中为 0 | 报错退出（`exit 6`）：早停与阈值标定会失效 |
| `test_mobile` 人数 <3 | 报错退出（`exit 4`）：跨域数字失去「跨人」含义 |
| `P04/P05` 缺失 | 允许降级：域适应验证集退化为公共 `val`，并在 `T-05` + `T-06` 的报告中显式声明「E3 使用公共验证集选型」 |
| 单文件被切成多 patch | 断言全部 patch 与该文件同子集（`group_id` 断言已覆盖） |
| 划分后 `train.csv` 为空 | 报错退出（`exit 2`） |
| 同一 `path` 出现在两个 CSV | 报错退出（`exit 7`） |
| 同一人的三种姿态 | 姿态是**人的属性**，不是划分单元 | 同一 `subject_id` 的三姿态必须全部同子集（断言 B 已覆盖）；禁止按姿态再分一层 |
| 消费方按文件名而非 `split` 列过滤 | 代码检查 | 报错退出（`exit 12`）：`API-06` §3.1 规定 `split` 值必须与所在文件名一致，因此 `val.csv` 内的域适应验证行**靠 `subject_id`（`P04`/`P05`）识别**，不能仅凭文件名与 `split` 值区分 |
| `label` 出现 FF-19 之外的类别 | 枚举校验 | 报错退出（`exit 1`）；不得"就近映射"到六类之一 |

## 3. 接口契约

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| CLI | `python ai/src/dataset.py --stage split --assert-leakage --seed <int>` | ingest 清单 | 退出码 0；四个划分 CSV；stdout 四行 `ASSERT_OK A|B|C|D` | 非零退出码（2/4/6/7），见 §2.4 |
| 文件 | 划分文件（下游 `T-03`/`T-04`/`T-05` 的唯一输入） | — | `ai/data/splits/*.csv` | — |
| 断言接口 | `pytest ai/tests/test_no_leakage.py` | 四个 CSV | 断言通过 | — |
| 消费方 | `SPEC-T-04` 的 DataLoader | `train.csv`/`val.csv` only | — | `ACD-MEL-002`（采样数不符，`API-00` §3.5） |
| 冻结 | 划分冻结登记（人读 + 机器比对） | 四个 CSV | sha256 清单打印 | — |
| 审计 | `pytest ai/tests/test_no_leakage.py -q` | 四个 CSV | 18 条判据通过 | — |

## 4. 数据契约

**四个划分文件同构**，列名与 `SPEC-T-01` §4 一致（不得改名）：

| 列 | 值域（本功能写入） | 可空 |
|---|---|---|
| `path` | 相对仓库根，POSIX 分隔符 | 否 |
| `label` | FF-19 的 6 个英文 ID | 否 |
| `subject_id` | 公共集行 = **空字符串** `""`；自采行 = `P01`–`P05`（`API-06` §3.1） | 公共集允许空串 |
| `source_file_id` | 原始录音文件 ID（公共集=文件名去扩展名；自采=会话 ID/文件名去扩展名） | 否 |
| `split` | `train` \| `val` \| `test_public` \| `test_mobile`（**必须与所在文件名一致**，`API-06` §3.1） | 否 |

- `val.csv` 内含两类行：公共集验证行（`subject_id == ""`）与域适应验证行（`subject_id ∈ {P04,P05}`），二者 `split` 均为 `val`（**不引入 `mobile_val` 枚举**，以符合 `API-06` §3.1）；消费方按 `subject_id` 区分二者。
- `test_mobile.csv` 只含 `P01`/`P02`/`P03`（`API-06` §3.2），文件名为 `test_mobile.csv` 且 `split == "test_mobile"`。
- `docs/common/docs_api/schemas/` 下无划分文件 schema；划分文件属**离线中间产物**（`API-06` §1 第 2 行），不进 App 制品清单。
- 划分文件本身入 Git（体积小、可审计），音频不入 Git。
- `path` 必须与 `SPEC-T-01` 清单中的字符串**逐字相同**（不做路径规范化重写）；若一处用 `\` 一处用 `/`，断言 C 的路径交集会因写法不同而失效。

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 六类枚举 | FF-19 |
| `n_frames` | FF-11 = **`n_frames = 128`**（旧值 ~~`n_frames = 129`~~ → `129` 现为 `raw_mel_frames`，已由 `ADR-21`（2026-09-12）修订；见 FF-11 / `ADR-21`） |
| patch 采样数与秒数 | FF-09 |
| 采样率 | FF-01 |
| 输入张量形状 | FF-14（仅用于形状自检，不在本功能产出张量） |

**本域自有常量（非 FF）**：公共集比例 `train/val/test_public = 70/15/15`；比例容差 ±2 pp；自采测试人 `P01–P03`；域适应验证人 `P04–P05`；划分随机种子默认 `20260910`（须写入 CSV 注释并可覆写）。

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 泄漏断言失败 | 断言 A/B 或路径交集非空 | **非零退出，禁止继续训练**；打印冲突的 `group_id`/`path` 全量清单 | 无 UI；日志 |
| `val` 缺类 | 每类计数 | 非零退出 `exit 6` | 无 |
| `train.py` 源码命中测试集字面量 | grep | 非零退出 `exit 8`；视为「用测试集调超参」的静态证据 | 无 |
| 测试集出现派生文件 | 目录扫描 | 非零退出 `exit 9`；删除派生文件并重跑划分 | 无 |
| `P04/P05` 缺失 | 清单 `subject_id` 集合 | 降级：域适应验证集退化为公共 `val`，并在报告中声明 | 无 |
| 清单列缺失 | 读入时断言 | 非零退出 `exit 1`，提示回到 `SPEC-T-01` | 无 |
| 会话粒度无法确定 | `group_id` 与 `source_file_id` 一一对应 | 改用「录制批次 / 参与者」归组；若确实无法归组，**必须**在 `T-05` 报告中声明「无法排除同会话跨子集，泄漏风险未消除」，不得沉默 | 报告脚注 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 划分成功 | `python ai/src/dataset.py --stage split --assert-leakage` | 退出码 == 0 |
| 2 | 四个文件齐全 | 文件存在性检查 | 4 个 CSV 全部存在 |
| 3 | 四条断言全通过 | 上述命令 stdout | 同时含 `ASSERT_OK A`、`ASSERT_OK B`、`ASSERT_OK C`、`ASSERT_OK D` |
| 4 | 列契约 | `pytest ai/tests/test_no_leakage.py::test_columns` | 五个列名逐个全等 |
| 5 | 会话不跨子集 | `test_no_leakage.py::test_group_not_cross_split` | `groupby(group_id).split.nunique().max() == 1` |
| 6 | 人不跨子集 | `test_no_leakage.py::test_subject_not_cross_split` | 同上，且 `P01–P03` 不在 `train.csv`/`val.csv` |
| 7 | 路径互斥 | `test_no_leakage.py::test_path_disjoint` | 三个集合两两交集大小 == 0 |
| 8 | 比例达标 | `test_no_leakage.py::test_ratio` | `train` 会话占比 ∈ [0.68, 0.72]；`val` ∈ [0.13, 0.17]；`test_public` ∈ [0.13, 0.17] |
| 9 | 无测试集调参 | `test_no_leakage.py::test_no_test_literal_in_train_code` | `ai/src/train.py` 等三文件中 `test_public|test_mobile` 命中数 == 0 |
| 10 | 无增强派生文件 | 目录扫描 | `ai/data/splits/` 中非 CSV 文件数 == 0 |
| 11 | 幂等可复现 | 同种子重跑两次并比对 sha256 | 四个文件 sha256 均相等 |
| 12 | 跨域测试集规模 | `test_no_leakage.py::test_mobile_size` | `test_mobile.csv` 行数 == 144 且人数 == 3 |
| 13 | 分层覆盖 | `test_no_leakage.py::test_stratified` | `val` 与 `test_public` 各自在六类上均 ≥1 个会话 |
| 14 | 划分统计可审计 | 控制台/日志检查 | 输出含「文件数 / 会话数 / 片段数 / 每类分布」四组统计，且片段数比例仅报告不判定 |
| 15 | 自采与公共集不混 | `test_no_leakage.py::test_source_isolation` | `train.csv` 的 `subject_id` 集合 == `{""}`；`test_mobile.csv` 的 `subject_id` 集合 == `{P01,P02,P03}` |
| 16 | 划分结果可被冻结引用 | sha256 登记行存在 | 四个 CSV 的 64 位 hex 全部打印且与文件相符 |
| 17 | 未引入不支持分组的划分工具 | grep `ai/src/dataset.py` | `train_test_split` / `sklearn` 命中数 == 0（该工具不支持会话级分组，会破坏断言 A） |
| 18 | 划分统计可复现 | 同种子重跑比对统计输出 | 四子集的文件数/会话数/片段数逐字段相等 |
| 19 | 对齐 `API-06` §3.3 六条断言 | `test_no_leakage.py::test_api06_assertions` | ①`path` 两两不相交；②`test_mobile.subject_id ⊆ {P01,P02,P03}` 且与 `train`/`val` 不相交；③`train`/`val` 的 `subject_id` 集合不相交；④`train` 与 `val` 的 `source_file_id` 集合不相交；⑤四子集每类样本数均 > 0；⑥全部 `label` ∈ `class_labels` 且 `split` 与文件名一致 |
| 20 | 泄漏错误码可诊断 | 构造坏数据（同一人跨 train 与 `test_mobile`）后运行断言 | 退出码 ≠ 0 且 stderr 首行含 `ACD-ART-002`（`API-06` §3.3/§11） |

## 8. 非功能约束
- **隐私**：自采人员仅以 `P01`–`P05` 匿名编号出现，不写姓名/设备号。
- **性能**：划分在 ≤10 s 内完成（纯 CSV 处理）。
- **可复现**：随机种子固定并记录；CSV 排序键固定 `(split, label, subject_id, source_file_id)`。
- **审计**：每次划分输出 sha256 登记行，供 `SPEC-T-05` 在报告中复现同一实验集合。
- **不得写入 `shared/feature_config.json`**（本域只读）。
- **依赖**：只用标准库（`csv`/`random`/`hashlib`）；禁止引入 `sklearn` 的划分工具（不支持会话级分组）。
- **审计产物**：划分统计以 stdout + 日志形式留存，**不额外生成文件**——保持 `ai/data/splits/` 内只有 4 个 CSV，便于判据 10 的目录扫描恒定成立。

## 9. 裁剪与未做
| 项 | 声明 |
|---|---|
| `X-06` RIR/Mixup | 与本功能无关，但**其裁剪使 `val` 的选择空间变小**：无混响增强的模型在真实房间里可能退化，此退化只能由 `test_mobile` 的跨域数字暴露（`T-05` E2）。 |
| k 折交叉验证 | **不做**（10 天窗口），推迟至后续阶段；后果：指标的不确定性只由 Wilson 区间表达，不做方差估计。 |
| 划分文件数保持 4 个 | **不新增第 5 个文件**（`P04`/`P05` 以 `split=val` 落在 `val.csv` 内，靠 `subject_id` 识别）。若确需新增文件，须走 `SPEC-C-03` 变更传播并同步 `T-04`/`T-05`/`T-06` 的消费代码。 |
| 若本功能被裁剪 | 后果：**训练集与测试集边界消失**，`T-05` 的一切数字不可信，属学术诚信问题——本功能**不得**被砍；即使 10 天窗口压缩，也只允许简化断言实现，不允许省略断言。 |
| 不可裁剪声明 | 本功能**不在**主方案 §8.2.1 五项之内，但它是 `T-05`（CP1 判据来源）的信任基础，**实际不可裁剪**。 |

## 10. 开放问题
1. **P04/P05 的落位（已按 `API-06` §3.2 裁定，仍建议 A 复核）**：`API-06` 规定 `P04`/`P05` **只可用于验证集、不得进 `train.csv`**，且 `split` 值必须与文件名一致（§3.1），因此本 SPEC **不引入 `mobile_val` 枚举**：P04/P05 作为 `val.csv` 中的行，其 `split == "val"`，消费方按 `subject_id` 区分域内验证与域适应验证。若 A 认为需要更强的可读性（例如新增 `mobile_val` 枚举或第 5 个文件），须走 `SPEC-C-03` 变更传播并同步 `API-06` §3.1、`T-04`/`T-05`/`T-06`。
2. **✅ 已关闭（依据 `ADR-P1`）**：原问题「`n_frames` 未拍板（FF-11，`SPEC-00` §3.5）的影响」**已随冻结定案，并已由 `ADR-21`（2026-09-12）修订**：~~`n_frames = 129`~~ → `n_frames = 128`（`raw_mel_frames = 129`）。划分在**文件级**完成、与帧数无关，因此**划分结果不受影响、无需重跑**；每文件可切出的 patch 数按 129 帧确定，`val` 早停评估与 `T-05` E1–E3 的评估成本随之固定。选项 A（4.064 s / 65024 样本）**已否决**，故**原「`T-01` 时长下界需重跑」的连带工作已取消**（`SPEC-T-01` §10.1 同结论）。
3. **`group_id` 在 ESC 上的真实粒度**：ESC 是否提供「同一次录音会话」的显式标识尚需在 D1 用实际目录结构确认。若 ESC 的每个文件即一次独立录制，则断言 A 退化为与断言「文件不跨子集」等价——**此时必须改用「同一参与者/同一录制批次」作为 `group_id`**，否则断言 A 变成空断言。**需 A 在 D1 用真实数据确认。**
4. **与 `API-06` 的差异已核对（无冲突）**：`API-06` §3.1 的 `subject_id` 规则（公共集填空串）与 §3.2 的划分规则（P04/P05 只进验证集）已被本 SPEC 全量采纳；本 SPEC 在其之上**追加**会话级（`group_id`）断言与 `exit 12` 的消费方过滤检查，属更严格的补充，不改动契约。**若 `API-06` 后续新增 `split` 枚举或 ingest 层契约，须同步本 SPEC 并重跑判据 19。**

**文档结束**
