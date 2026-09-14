# 志愿者归档清单（`consent_registry.md`）

**依据**：`SPEC-C-02` §4.2（字段权威）｜ **纪律**：**未登记 = 不可采集；未签署 = 不可使用**（R-11）

字段说明：`subjectId` / `signedDate` / `scopeVersion` / `sourceType` / `segmentCount` /
`consentScanPath` / `voiceRemovedCount` / `status` / `withdrawnAtMs`（可空）

`status` 取值：`RECRUITED` → `CONSENTED` → `COLLECTED` → `IN_DATASET`；异常路径 `WITHDRAWN` → `DELETED`；未签退出 `DROPPED`。
**只有 `CONSENTED` 及以上状态可以采集与入库。**

---

## 登记表

| subjectId | signedDate | scopeVersion | sourceType | segmentCount | consentScanPath | voiceRemovedCount | status | withdrawnAtMs |
|---|---|---|---|---|---|---|---|---|
| `P01` | | `v1.0` | `volunteer` | 0 | `docs/compliance/C-02/scans/P01_consent_masked.pdf` | 0 | `RECRUITED` | |
| `P02` | | `v1.0` | `volunteer` | 0 | | 0 | `RECRUITED` | |
| `P03` | | `v1.0` | `volunteer` | 0 | | 0 | `RECRUITED` | |
| `P04` | | `v1.0` | `volunteer` | 0 | | 0 | `RECRUITED` | |
| `P05` | | `v1.0` | `volunteer` | 0 | | 0 | `RECRUITED` | |

> 采集规模目标：主方案 §7.1。`P01`–`P03` 只进 `test_mobile.csv`，`P04`/`P05` 只允许进 `val.csv`
> （`API-06` §3.2 的四条禁止行为之一）。

---

## 采集命名规范

```
ai/data/raw/mobile/<subjectId>/<yyyymmdd>_<class>_<seq>.wav
```

`class` ∈ `chips, apple, cookie, bread, carrot, drink`（FF-19 六类，储备类别不入 v1.0）。

---

## 准入校验（机械执行）

```powershell
# 校验 splits/*.csv 里的每个 subject_id 都有 CONSENTED 及以上状态的登记，
# 且不含 WITHDRAWN / DELETED 编号。
$py = "D:\Desktop\Food\_toolchain\dl\python\python.exe"
& $py D:\Desktop\Food\AcouDiet\tool\check_consent_registry.py --strict
# 期望退出码 0；任一无签署编号进入划分 -> 非 0 退出并打印 ACD-ART-002
```

---

## 登记记录（追加式，不覆盖）

| 时间 | 操作 | 对象 | 说明 |
|---|---|---|---|
| | | | |
