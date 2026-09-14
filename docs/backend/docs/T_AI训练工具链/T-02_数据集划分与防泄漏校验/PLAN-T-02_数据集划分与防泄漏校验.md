# PLAN-T-02 数据集划分与防泄漏校验

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-T-02` |
| 负责 | A（主责）；C 协助 `PLAN-C-05` 的回归测试落位 |
| 目标日 | D1 |
| 前置依赖 | `PLAN-T-01` 的 `ai/data/raw/ingest_manifest.csv`；D1 冻结的三接口之一（`feature_config`）已定 |
| 预估工时 | 6 h |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `ai/data/splits/train.csv` | 公共集训练划分（70%） |
| 2 | `ai/data/splits/val.csv` | 公共集验证（15%）+ 域适应验证行（`P04`/`P05`，`split` 仍为 `val`，靠 `subject_id` 识别） |
| 3 | `ai/data/splits/test_public.csv` | 公共集域内测试（15%，即主方案的 `test_domain`） |
| 4 | `ai/data/splits/test_mobile.csv` | 跨域测试：`P01`–`P03`，144 段 |
| 5 | `ai/src/dataset.py`（`--stage split`） | 划分与四条断言 |
| 6 | `ai/tests/test_no_leakage.py` | 防泄漏单测（并入 `PLAN-C-05`） |
| 7 | 划分统计与 sha256 登记 | 控制台输出 + 记录进 `SPEC-T-05` 的报告附件 |
| 8 | 划分冻结记录 | 四个 CSV 的 sha256，用于 `T-05` 可复现声明 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 用真实 ESC 目录确认「录音会话」粒度 | `group_id` 规则（并回写 `SPEC-T-02` §10.3） | 1 h | `PLAN-T-01` #3 |
| 2 | 实现 `group_id` 归组 + 确定性洗牌划分 | `--stage split` | 1.5 h | #1 |
| 3 | 实现四条断言 A/B/C/D 与退出码 | stdout `ASSERT_OK` 四行 | 1.5 h | #2 |
| 4 | 写 `test_no_leakage.py` 八项断言 | 单测 | 1 h | #3 |
| 5 | `val.csv` 承载两类验证行（公共集 `""` / 域适应 `P04`/`P05`）的实现 + 消费方过滤约定 | 行过滤规则 | 0.5 h | #2 |
| 6 | 幂等与 sha256 登记 | 两次跑同哈希 | 0.5 h | #4 |

## 3. 技术方案

**划分策略**：**先归会话、再洗牌、后落文件**。划分单元是 `group_id`（公共集=录音会话；自采=人），而不是单条音频——这是断言 A/B 能成立的前提。

```python
# 骨架（≤30 行，非完整实现）
import csv, random, hashlib, pathlib
SEED = 20260910
TRAIN, VAL, TEST = 0.70, 0.15, 0.15

rows = list(csv.DictReader(open("ai/data/raw/ingest_manifest.csv", encoding="utf-8")))
pub   = [r for r in rows if r["source"] == "esc"]
mob   = [r for r in rows if r["source"] == "mobile"]

# 1) 归组：同一录音会话同进退（断言 A 的前提）
groups = {}
for r in pub:
    groups.setdefault(group_id_of(r), []).append(r)

# 2) 以会话为单元确定性洗牌
gids = sorted(groups); random.Random(SEED).shuffle(gids)
n = len(gids); cut1, cut2 = int(n*TRAIN), int(n*(TRAIN+VAL))
assign = {g: ("train" if i < cut1 else "val" if i < cut2 else "test_public")
          for i, g in enumerate(gids)}

# 3) 自采按人：P01-P03 只进 test_mobile；P04-P05 进 val.csv（split 仍为 "val"，靠 subject_id 识别）
def mob_split(subject): return "test_mobile" if subject in {"P01","P02","P03"} else "val"

# 4) 断言 A/B/C/D（任一失败 -> 非零退出，绝不"先训再说"）
assert all(len({assign[group_id_of(r)] for r in rs}) == 1 for rs in groups.values())
assert all(len({s for _, s in subj.items()}) == 1 for subj in by_subject(mob).values())
assert not (paths("train") & paths("test_public") & paths("test_mobile"))
assert grep_zero("ai/src/train.py", ["test_public", "test_mobile"])
```

**关键约定**：
- 断言必须**先于训练脚本存在**：D1 结束时 `train.py` 尚未写完，但断言 D 的 grep 检查对象必须在 D2 前补齐（`train.py` 落盘当天即接入 `PLAN-C-05`）。
- 划分文件写入后即**冻结**；`T-04` 训练脚本只允许读 `train.csv` 与 `val.csv`。
- 所有比例按**会话/文件数**计算，片段数仅报告——避免长文件主导比例。
- 划分 CSV 一律 `utf-8` + `\n`，排序键 `(split, label, subject_id, source_file_id)`。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `dataset.py --stage split --assert-leakage` | CLI | 退出码 0；stdout 含四条 `ASSERT_OK` | D1 下午 |
| `pytest ai/tests/test_no_leakage.py` | 单测 | 8 项断言全通过（列/会话/人/路径/比例/源码 grep/派生文件/规模） | D1 起，每次划分后 |
| 比例检查 | 单测 | `train` ∈ [0.68,0.72]，`val` ∈ [0.13,0.17]，`test_public` ∈ [0.13,0.17] | D1 |
| 幂等 | 哈希 | 同种子两次划分四个 CSV sha256 相等 | D1 |
| 跨域集规模 | 单测 | `test_mobile.csv` 行数 == 144，人数 == 3 | D1 |
| 消费联调 | 集成 | `T-04` 的 DataLoader 只读 `train.csv`/`val.csv` 且不报错 | D2（`PLAN-T-04` #1） |

## 5. 完成定义（DoD）
- [ ] `SPEC-T-02` §7 全部 12 条判据通过。
- [ ] 四个划分 CSV 已落盘并被 `PLAN-T-03`/`PLAN-T-04` 成功读取。
- [ ] `test_no_leakage.py` 已并入 `PLAN-C-05` 回归套件，且在 D3/D7 的评估前后各跑一次。
- [ ] `group_id` 的真实粒度已用 ESC 实际目录确认，并把结论回写 `SPEC-T-02` §10.3。
- [ ] 划分 sha256 已登记，供 `PLAN-T-05` 复现同一实验集合。
- [ ] 未修改 `shared/feature_config.json`。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| ESC 无会话标识，断言 A 退化为空断言 | `group_id` 与 `source_file_id` 一一对应 | 改用「同一录制批次/同一参与者」为 `group_id`；若确实无法归组，则在 `T-05` 报告中**明确声明**「无法排除同会话跨子集，泄漏风险未消除」——不得沉默 |
| `val` 缺类导致早停失效 | 每类计数为 0 | 用分层洗牌（按 `label` 分层后组内洗牌）；仍缺类则把该类从 `val` 指标中排除并声明 |
| `P04/P05` 未在 D1 内采齐 | 清单 `subject_id` 缺人 | 域适应验证集退化为公共 `val`；`T-05` E3 与 `T-06` 消融表中标注「E3 选型使用公共验证集」 |
| 反泄漏断言被当作"流程装饰"绕过 | 有人直接写 `train.py` 手动读全量清单 | 断言 D 的 grep 对象扩到 `ai/src/*.py`；`PLAN-C-05` 在 D5/D8 节点各跑一次 |
| 比例不达标 | 会话数少导致颗粒粗 | 容差从 ±2 pp 放宽到 ±3 pp，但**必须**在报告中写出实际占比 |

## 7. 与检查点的关系
- **D1 三方接口冻结**：本功能的四个划分文件与 `feature_config`、`DietRecord`、`HealthScore` 同期冻结（`PLAN-00` §4「接口先行」）。
- **CP1（D3 晚，跨域实测）**：`test_mobile.csv`（`P01`–`P03`，144 段）是 CP1 判据的**唯一测量集**。若本功能延期，CP1 无测量集，跨域数字不存在。
- **不可裁剪**：本功能虽不在主方案 §8.2.1 五项内，但 `T-05` 的全部数字与 `T-08` 的一致性结论都建立在此；**只允许简化实现，不允许省略断言**。
- 与 `SPEC-C-05` 的关系：`test_no_leakage.py` 属其回归套件的必含项，D9 演示前回归必须包含。

**文档结束**
