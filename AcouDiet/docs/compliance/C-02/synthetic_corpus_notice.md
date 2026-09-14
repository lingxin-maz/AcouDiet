# 合成语料声明（`synthetic_corpus_notice.md`）

**为什么需要这个文件**：`SPEC-C-02` 的准入规则是「未签署 = 不可使用」（R-11）。
本实现环境**没有网络**，无法获取公共数据集，也无法招募真实志愿者，因此
`ai/scripts/make_synthetic_dataset.py` 生成了**机器合成的**音频语料作为离线替代，
其中 `test_mobile.csv` / `val.csv` 使用了 `P01`–`P05` 编号。

**这些编号背后没有任何人类主体** —— 音频由确定性算法合成，不含任何人的声音、姓名或可识别信息。
因此它们**既不需要也无法取得知情同意**；但为了不让「未签数据」悄悄进入管线，
本文件把它们**显式声明**为合成语料，检查脚本据此区分「已声明的合成数据」与「未签署的真实数据」。

> ⚠️ **真实招募开始后必须做两件事**，且必须先做第 1 件：
> 1. 删除或重新编号这批合成数据（`ai/data/raw/mobile/P0x*`），清空 `consent_registry.md` 中的合成行；
> 2. 按 `consent_form_v1.0.md` 完成真实签署与登记，再开始采集。
> **绝不允许**把真实志愿者的音频挂在"合成语料"的声明之下 —— 那正是 R-11 要拦的事。

---

## 机器可读声明

本检查脚本 `tool/check_consent_registry.py` 解析下面代码块中的 `synthetic_subjects` 列表：

```json
{
  "declaredAt": "2026-09-10",
  "reason": "offline environment has no network for a public corpus and no volunteers",
  "generator": "ai/scripts/make_synthetic_dataset.py",
  "synthetic_subjects": ["P01", "P02", "P03", "P04", "P05"],
  "paths": [
    "ai/data/raw/mobile/",
    "ai/data/raw/public/"
  ],
  "containsHumanVoice": false,
  "containsPersonalData": false,
  "expiresWhen": "the first real volunteer is consented"
}
```

---

## 真实数据与合成数据的区分（供评审与答辩）

| 项 | 合成语料（本声明覆盖） | 真实自采数据（需签署） |
|---|---|---|
| 主体 | 无人类主体 | 志愿者 `P01`…（真实） |
| 生成方式 | `make_synthetic_dataset.py`（确定性种子） | 手机麦克风采集 |
| 是否需要同意书 | 不需要（无主体） | **必须**，先签后用 |
| 入库准入 | 由本声明豁免 | 仅 `CONSENTED` 及以上状态 |
| 报告中的标注 | 只用于管线打通与门禁验证，**指标不作为产品结论** | 才是 CP1 实测准确率的来源 |

> 📌 **对交付结论的影响（必须如实说明）**：`ai/artifacts/metrics.json` 中基于合成语料得到的
> 准确率**不能**作为「在自采手机测试集上实测为 XX%」的证据（`SPEC-00` §3.10 FF-25）。
> 该数字必须在真实自采数据上重跑后写入测试报告。
