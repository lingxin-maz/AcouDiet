# 发布前检查清单 · AcouDiet v1.0.0

> 逐项打勾 + B/C 签字后才允许提交（`SPEC-C-04` §7 附表）。
> **条目数以 `SPEC-C-04` §7 附表为准（12 条）**；`PLAN-C-04` §1 交付物 #7 写「14 项」，
> 与附表不符 —— 已在 `docs/compliance/C-04_build_and_signing.md` §4 登记，本清单按 12 条执行。
> 🆕 **`ADR-44` 追加第 13 条**（两风味的权限检查与**两 APK 证据**义务，见下）。`SPEC-C-04` §7 附表**尚未**按风味重写（该文件由另一条工作流负责），因此这里显式登记这条偏差：**本次发布必须对 `offline` 与 `agent` 两个包分别取证**，只出一个包则不满足 `SPEC-C-01` §7 #1a/#1b。

| # | 检查项 | 判据来源 | 实测/证据 | ☐ |
|---|---|---|---|---|
| 1 | `flutter analyze` / `dart analyze` 零 error | `SPEC-C-04` §7 #1 | `docs/release/analyze_<stamp>.txt`：`error=0`，warnings=___，info=___ | ☐ |
| 2 | `SPEC-C-05` 提交前测试集全绿、`SPEC-C-03` 旧值零残留命中 0 | `SPEC-C-05` §7 / `SPEC-C-03` §7 #3 | `pwsh -File tool\verify_all.ps1` 退出码 0（**22 步**）；旧值扫描 0 命中 | ☐ |
| 3 | **两个风味分别核权限**：`offline` 包无 `INTERNET`、仅 `RECORD_AUDIO`；`agent` 包权限集合**逐字等于** `{RECORD_AUDIO, INTERNET}`（两档都不得含相机/位置/通讯录/`READ_MEDIA_*`/`VIBRATE`） | `SPEC-C-01` §7 #1a/#1b/#2 | 两份 `aapt dump badging` 输出（`docs/compliance/C-01/`）；`python tool\check_apk_contents.py <apk> --expect-no-internet` 与 `--expect-internet` 各得 `exit 0` | ☐ |
| 4 | 签名有效且非 debug 签名 | `SPEC-C-04` §7 #3 | `apksigner verify --print-certs`：CN = ______ | ☐ |
| 5 | `key.properties` / keystore 未入库 | `SPEC-C-04` §7 #4 | `git check-ignore -v app/android/key.properties` 命中；`git ls-files` 命中 0 | ☐ |
| 6 | 模型体积 ≤ 本档 FF-16 上限（fp32 ≤ 6 MB / INT8 ≤ 2.5 MB；`ADR-21` 起两档都可交付，~~模型 ≤ 2.5 MB~~） | `SPEC-C-04` §7 #6 | `ai/artifacts/model_card.json` 的 `quantization` = ______、`tfliteBytes` = ______（当前投放 fp32 制品 = 4,051,716 B） | ☐ |
| 7 | 三 ABI（或声明的子集）产物齐备、命名与归档路径符合 `SPEC-C-04` §4 | `SPEC-C-04` §7 #2/#7 | `docs/release/AcouDiet-v1.0.0-<stamp>-<abi>.apk` | ☐ |
| 8 | 归档索引字段齐全、`analyzeErrors == 0` | `SPEC-C-04` §7 #8 | `docs/release/RELEASE_1.0.0_<stamp>_<flavour>.md` | ☐ |
| 9 | 飞行模式全流程核对表通过 | `SPEC-C-01` §7 #4 | 检测 → 识别 → 记录 → 报告 全程可用 | ☐ |
| 10 | 冻结 tag 已打、冻结后零提交 | `SPEC-C-04` §7 #9 | `git tag -l 'v1.0.0-freeze'`；`git log --since=<freeze-ts>` 为 0 行 | ☐ |
| 11 | 清单完成（B/C 签字）与版本号一致（§4 `appVersion`） | `SPEC-C-04` §7 #10 | 本文件底部签字；`appVersion = 1.0.0+1` | ☐ |
| 12 | 材料齐备（PPT / 演示视频 / 测试报告 / 同意书扫描件 / `aapt` 隐私截图） | 主方案 §12.6 | 见 `docs/release/` 与 `docs/compliance/C-02_consent_and_ethics.md` | ☐ |
| 13 🆕 | **两 APK 证据义务**（`ADR-44`）：`offline` 与 `agent` 两个包来自**同一次构建**，各自的 `aapt dump badging` 全文与 `sha256` 均已归档；`offline` 的输出与 `ADR-44` 之前任何一版**逐字相等**（"没有退步"判据） | `SPEC-C-01` §7 #1a/#1b/#2/#5/#7；`PLAN-C-06` §7 #3 | `docs/compliance/C-01/` 下两份 `aapt_badging_*_<flavour>.txt` + 两份 `apk_sha256.txt`（hex 长度 64）；缺任一风味的包 → 判不通过 | ☐ |

---

## 体积记录（**只记录，不设阈值** —— `SPEC-C-04` §8）

> `ADR-44` 起**两个风味都要记录**；两个包的权限证据必须与下表的 `sha256` 一一对应。

| 产物 | 风味 | 字节数 | sha256 |
|---|---|---|---|
| arm64-v8a | `offline` | ______ | ______ |
| arm64-v8a | `agent` | ______ | ______ |
| armeabi-v7a | `offline` | ______ | ______ |
| armeabi-v7a | `agent` | ______ | ______ |
| x86_64 | `offline` | ______ | ______ |
| x86_64 | `agent` | ______ | ______ |
| 模型 `acoudiet_fp32_v1.3.0.tflite`（fp32 档，FF-16 上限 6 MB；两风味**共用同一个**模型制品） | — | ______ | ______ |

## 签署

| 角色 | 姓名 | 日期 |
|---|---|---|
| B（构建与发布主责） | __________ | __________ |
| C（归档与材料） | __________ | __________ |
