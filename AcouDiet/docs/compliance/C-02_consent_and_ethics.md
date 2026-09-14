# C-02 知情同意与数据伦理归档 · 记录

**SPEC 对应**：`SPEC-C-02`（7 条条款 + 9 字段归档清单 + 状态机）
**PLAN 对应**：`PLAN-C-02`（D0 启动）
**性质**：本功能**不产生运行时接口**，是下游 `T-01`/`T-02` 的**准入约束** —— 因此它的证据是
「文件 + 可执行校验」，而不是单元测试。

---

## 1. 交付物（本仓已就位）

| `SPEC-C-02` §1.2 产物 | 本仓文件 | 状态 |
|---|---|---|
| #1 知情同意书模板（必含 7 条） | `docs/compliance/C-02/consent_form_v1.0.md` | ✅ 7 条逐字对应 §4.1，含撤回的方式与**已知限制** |
| #2 签署件扫描归档（姓名打码） | `docs/compliance/C-02/scans/` | ⏳ 需真实志愿者（打码要求写在同意书 §五） |
| #3 志愿者归档清单（9 字段） | `docs/compliance/C-02/consent_registry.md` | ✅ 表头即 §4.2 的 9 个字段 |
| #4 撤回权执行记录 | `docs/compliance/C-02/withdraw_log.md` | ✅ 含「四件事」清单与复核命令 |
| #5 招募 5–10 名志愿者，先签后用 | — | ⏳ 日历时间，压不动（`PLAN-01` §2 T0-5） |
| #6 R-7 兜底（组内自录仍需签） | 同意书 §五 的 `sourceType` 勾选项 | ✅ 流程就位 |
| #7 提交材料附打码扫描件 | `docs/release/pre_release_checklist_TEMPLATE.md` 第 12 项 | ✅ 已列入清单 |

**额外产物（为让准入变成可执行判据而新增）**：
`tool/check_consent_registry.py` + `docs/compliance/C-02/synthetic_corpus_notice.md` —— 见 §3。

---

## 2. 状态机 ↔ 准入规则（`SPEC-C-02` §2.3 / §3）

```
RECRUITED ──签署──▶ CONSENTED ──采集──▶ COLLECTED ──入库──▶ IN_DATASET
                        │                    │                   │
                        └────────撤回请求────┴───────────────────┘
                                     ▼
                                 WITHDRAWN ──删除执行+确认──▶ DELETED
```

* **唯一可采集状态**：`CONSENTED`（含 `COLLECTED` / `IN_DATASET`）。
* **禁止出现在 `splits/*.csv` 的状态**：`RECRUITED` / `DROPPED` / `WITHDRAWN` / `DELETED`。
* 撤回的删除范围 = 原始音频 + 划分行 + 派生缓存 + 归档清单标注（`withdraw_log.md` 逐项勾选）。

---

## 3. 机械校验：把「先签后用」变成命令

`SPEC-C-02` §3 把归档清单定义为**准入约束**。为了让它在管线里真的拦得住（而不是一句纪律），
本仓新增了一个离线可执行的检查器：

```powershell
$py = "D:\Desktop\Food\_toolchain\dl\python\python.exe"
& $py D:\Desktop\Food\AcouDiet\tool\check_consent_registry.py --strict
```

它执行四条规则：

| # | 规则 | 失败码 |
|---|---|---|
| 1 | `splits/*.csv` 中出现的每个 `subject_id` 必须有 `CONSENTED` 及以上状态 | `ACD-ART-002` |
| 2 | 磁盘上存在音频的每个 `P0x` 目录必须有 `CONSENTED` 及以上状态 | `ACD-ART-002` |
| 3 | 被声明为合成语料的编号**不得**同时被标为已签署（否则说明有人为没有主体数据签了字） | `ACD-ART-002` |
| 4 | 已签署、有音频，但未进入任何划分 → 记账缺口 | 仅告警 |

### 实测（两次运行，负例 + 正例）

| 运行 | 条件 | 结果 |
|---|---|---|
| ① 加入 `synthetic_corpus_notice.md` **之前** | `P01`–`P05` 在划分中，而登记状态是 `RECRUITED` | ✅ 检出 **5 条 `ACD-ART-002`**，`RESULT: FAIL` —— 负例证明规则真的会拦 |
| ② 声明合成语料**之后** | 同一批编号被 `synthetic_corpus_notice.md` 显式声明为机器生成 | ✅ `RESULT: PASS`，并打印 `[note] 5 subject id(s) are declared machine-generated` |

### 为什么要有「合成语料声明」而不是直接放行

本环境无网络，既取不到公共数据集也招募不到志愿者，`ai/scripts/make_synthetic_dataset.py`
合成了替代语料（`P01`–`P05`，无任何人类主体）。直接给检查器加开关会**削弱 R-11**；
显式声明则把「豁免」变成一份**可审计的产物**：谁、什么时候、为什么、覆盖哪些编号、何时失效
（"the first real volunteer is consented"）都写在文件里。真实招募开始后必须先删除/重编号合成数据
（见声明文件开头的两条强制动作）。

---

## 4. 对交付结论的影响（必须如实说明）

合成语料上得到的准确率**不能**用作「在自采手机测试集上实测为 XX%」的证据（`SPEC-00` §3.10 FF-25）。
`ai/artifacts/metrics.json` 的 `domainComparison` 里 `test_mobile` 一行，在真实自采数据到位前
必须标注为合成；CP1 的判定（现场 10 次实拍 ≥6/10）只能来自真实数据。
这一条已写入 `synthetic_corpus_notice.md` 的末尾。

---

## 5. 待完成（日历时间，不可压缩）

| 项 | 阻塞点 | 时点 |
|---|---|---|
| ≥2 名志愿者签署并完成 ≥6 类录音（`PLAN-01` §2 T0-5） | 需要真实人力 | D0–D1 |
| 打码扫描件入 `scans/` | 需要纸质签署件 | D0–D1 |
| 真实数据的 CP1 实测 | 需要真机 + 真实数据 | D3 |
