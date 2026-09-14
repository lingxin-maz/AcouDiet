# 撤回权执行记录（`withdraw_log.md`）

**依据**：`SPEC-C-02` §2.4（撤回的删除范围）、§2.3（状态机 `WITHDRAWN` → `DELETED`）

**撤回请求到达后必须完成的四件事**（缺一即未执行完毕）：

1. 删除 `ai/data/raw/<subjectId>/`（含 `public/` 与 `mobile/` 下该编号的全部音频）；
2. 从 `ai/data/splits/*.csv` 中剔除该 `subject_id` 的所有行；
3. 删除派生特征/增强缓存（`ai/data/augmented/`、任何 `.npy`/缓存目录）；
4. 在 `consent_registry.md` 中把该编号标为 `DELETED` 并填写 `withdrawnAtMs`。

**已知限制（已向志愿者书面说明）**：本期不因单次撤回立即重训已发布权重；处置为「删除原始数据 +
剔除划分 + 书面确认」，并在本表记录「下一版重训时该编号不计入」。

---

## 记录

| # | subjectId | 请求时间（UTC ms） | 请求方式 | 删除范围确认（1–4） | 完成时间 | 执行人 | 已书面确认 | 备注 |
|---|---|---|---|---|---|---|---|---|
| （空） | | | | ☐1 ☐2 ☐3 ☐4 | | | ☐ | |

---

## 复核命令

```powershell
# 撤回编号是否仍残留
$py = "D:\Desktop\Food\_toolchain\dl\python\python.exe"
& $py D:\Desktop\Food\AcouDiet\tool\check_consent_registry.py --strict
# 期望：WITHDRAWN/DELETED 编号在 splits 中出现 0 次

# 原始音频目录
Get-ChildItem "D:\Desktop\Food\AcouDiet\ai\data\raw" -Recurse -Directory |
  Where-Object { $_.Name -match '^P(0[1-9]|10)$' } | Select-Object FullName
```

> ⚠️ 撤回执行不可逆。执行前先确认已收到志愿者本人的明确请求，并留存请求时间与方式（渠道截图或书面件）。
