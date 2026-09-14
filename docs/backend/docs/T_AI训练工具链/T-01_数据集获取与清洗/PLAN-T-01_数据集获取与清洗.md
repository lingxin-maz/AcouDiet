# PLAN-T-01 数据集获取与清洗

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-T-01` |
| 负责 | A（主责）；C 协助自采招募与同意书（`PLAN-C-02`） |
| 目标日 | D0 → D1 |
| 前置依赖 | 环境激活（FF-23）+ `verify_env.py` PASS=28/FAIL=0；ESC 落位 `ai/data/raw/esc/`；自采 ≥5 人 × 6 类 × 8 段；`PLAN-C-02` 同意书签署 |
| 预估工时 | 10 h（D0 6 h + D1 4 h） |

## 1. 交付物（Deliverables）
| # | 路径 | 说明 |
|---|---|---|
| 1 | `ai/src/dataset.py` | ingest / check-noise 子命令 |
| 2 | `ai/scripts/collect_check.py` | 自采数据规模与姿态校验 |
| 3 | `ai/data/raw/ingest_manifest.csv` | 下游 `T-02` 的唯一输入清单 |
| 4 | `ai/data/raw/rejects.csv` | 剔除审计清单 |
| 5 | `ai/data/noise/{canteen,office,street}_NN.wav` | 自采噪声库（10–20 min） |
| 6 | `ai/data/raw/ESC_SOURCE.md` | ESC 出处、版本、许可证、文件 sha256 登记 |
| 7 | 控制台类别分布表 | `dataset.py` stdout，落盘进 `ESC_SOURCE.md` 附录 |
| 8 | `ai/data/rir/` 处置记录 | 依 `SPEC-T-01` §9：删除或留空并注明 `X-06` 裁剪 |

## 2. 任务拆解（WBS）
| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | ESC 下载、解压、许可证登记 | `ESC_SOURCE.md` | 1.5 h | 网络/许可确认 |
| 2 | 六类映射表编写（ESC 原始类名 → FF-19 ID） | `dataset.py` 内 `CLASS_MAP` | 1 h | #1 |
| 3 | 元信息遍历 + 采样率/时长校验 | `dataset.py --stage ingest` | 2 h | #2 |
| 4 | 坏样本规则实现（静音/削波/解码失败） | rejects 分支 | 1 h | #3 |
| 5 | 自采录音落位 + 命名规范校对 | `ai/data/raw/mobile/` | 1.5 h（含与 C 对齐） | 自采进度 |
| 6 | `collect_check.py`（240 段 + 姿态覆盖） | 校验脚本 | 1.5 h | #5 |
| 7 | 噪声采集（食堂/办公室/街道）与入库校验 | `ai/data/noise/*` | 1 h | — |
| 8 | 清单排序稳定化与幂等自测 | sha256 相等 | 1 h | #3 |
| 9 | 分布表产出 + 与 `T-02` 联调消费 | 清单被 `T-02` 读通 | 1 h | #8 |

## 3. 技术方案

**实现路径**：只读 `shared/feature_config.json`（**绝不写入**）→ 读头部元信息 → 规则过滤 → 稳定排序 → 写 CSV。

```python
# 骨架（≤30 行，非完整实现）
import csv, hashlib, json, pathlib, soundfile as sf
CFG = json.loads(pathlib.Path("shared/feature_config.json").read_text("utf-8"))
SR, PATCH_S = CFG["sample_rate"], CFG["patch_seconds"]
CLASS_MAP = {"chips":"chips","cabbage":"cabbage","gummies":"gummies",
             "noodles":"noodles","carrot":"carrot","drink":"drink"}

def probe(p: pathlib.Path):
    info = sf.info(str(p))                      # 只读头部，不解码
    return info.samplerate, info.frames / info.samplerate, info.channels

def verdict(p, label):
    sr, dur, ch = probe(p)
    if sr != SR:            return "SR_MISMATCH"
    if dur < PATCH_S:       return "TOO_SHORT"
    if label not in CLASS_MAP.values(): return "CLASS_OUT_OF_SCOPE"
    return ""

# 稳定排序键：清单必须字节级可复现
rows.sort(key=lambda r: (r["source"], r["label"], r["source_file_id"]))
```

**关键约定**：
- `source_file_id`：ESC 取文件名主干；自采取 `P0x_<class>_<pose>_<seq>`。它是 `SPEC-T-02` 的划分键，**不得**在后续阶段改写。
- 不做隐式重采样：不一致即剔除，避免重采样器实现差异污染 `T-08` 的对齐基线。
- 噪声库单声道 / FF-01 采样率 / 16-bit（FF-01），供 `T-03` 的 SNR 5–20 dB 混合直接使用。
- 输出 JSON 与 CSV 一律 `utf-8` + `\n`；float 统一保留 4 位小数。

## 4. 测试与验证
| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `dataset.py --stage ingest` | CLI | 退出码 0；stdout 含类别分布表 | D1 上午 |
| 规模阈值 | 脚本断言 | 3,000 ≤ ESC 片段数 ≤ 4,000 且每类 ≤ 1,000 | D1 |
| 采样率一致性 | pandas 断言 | `set(df.sample_rate) == {16000}`（按 `feature_config` 读取） | D1 |
| 无短片段 | pandas 断言 | `df.duration_s.min() >= feature_config.patch_seconds` | D1 |
| `collect_check.py` | CLI | 退出码 0；stdout 含 `240 segments`、`pose_coverage=OK` | D1 |
| 噪声库 | CLI | 退出码 0；总时长 ∈ [10,20] min；场景数 == 3 | D1 |
| 幂等 | 哈希比对 | 两次 ingest 的清单 sha256 相等 | D1 |
| 列契约 | `pytest ai/tests/test_dataset_contract.py` | 五列齐全、无空 `subject_id` | D1（并入 `PLAN-C-05`） |

## 5. 完成定义（DoD）
- [ ] `SPEC-T-01` §7 全部 12 条判据通过。
- [ ] `ingest_manifest.csv` 已被 `PLAN-T-02` 成功读取并产出划分文件（联调通过）。
- [ ] `ESC_SOURCE.md` 含出处、版本、许可证、sha256 与分布表附录。
- [ ] `ai/data/rir/` 已按 `X-06` 裁剪作出处置记录（删除或留空并注明）。
- [ ] 自采数据确认**未入 Git**，仓库中仅有清单与哈希。
- [ ] 未修改 `shared/feature_config.json`（`git status` 中该文件无变更）。

## 6. 风险与降级
| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| ESC 不可得（网络/许可） | D0 结束仍无 `ai/data/raw/esc/` | 立即上报；改用少量公开样本 + 240 段自采；`T-05` 明确标注 E1 无上限参考；**不得**在材料中声称使用 ESC |
| 自采人数不足 5 | `collect_check.py` 退出码 4 | P04/P05 由 C 在 D1 内补采；仍不足则自采规模降为 3 人并**同步修改 `PLAN-T-02` 的人划分方案**（P01–P03 测试、无域适应验证集） |
| 噪声库时长不足 | `--stage check-noise` 退出码 5 | 优先补采街道噪声；仍不足则 `T-03` 的噪声混合关闭（消融表新增一行 on/off） |
| 类别分布严重不均（某类 <500） | 分布表告警 | 提请评估 FF-19 四类降级开关；**不**通过放宽六类子集上限来补数 |
| 磁盘/内存不足 | ingest 中断 | 先剔除 >60 s 长片段；仍不足则分场景分批 ingest，清单合并后重跑校验 |

## 7. 与检查点的关系
- **CP0（D0 环境门槛）**：本功能与 `C-03` 同属 D0 交付；自采启动是 D0 硬验收项（「≥2 人完成 ≥6 类录音」，`PLAN-00` §1）。
- **CP1（D3 晚，跨域实测）**：本功能是 CP1 的**数据前置**。若 D1 结束仍未产出可用清单，则 `T-02`→`T-04` 全部顺延，**CP1 必然失守**；此时唯一处置是 D2 起把训练规模降到「自采 240 段 + 现有公开样本」，并在 D3 明确声明跨域数字的样本量与局限。
- 本功能**不属于**主方案 §8.2.1 的五项不可砍项，但它是其中 ①②③④ 的全部数据源，**实际不可砍**。

**文档结束**
