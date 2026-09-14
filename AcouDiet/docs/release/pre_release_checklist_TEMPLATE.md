# 发布前检查清单 · AcouDiet v1.0.0

> 逐项打勾 + B/C 签字后才允许提交（`SPEC-C-04` §7 附表）。
> **条目数以 `SPEC-C-04` §7 附表为准（12 条）**；`PLAN-C-04` §1 交付物 #7 写「14 项」，
> 与附表不符 —— 已在 `docs/compliance/C-04_build_and_signing.md` §4 登记，本清单按 12 条执行。

| # | 检查项 | 判据来源 | 实测/证据 | ☐ |
|---|---|---|---|---|
| 1 | `flutter analyze` / `dart analyze` 零 error | `SPEC-C-04` §7 #1 | `docs/release/analyze_<stamp>.txt`：`error=0`，warnings=___，info=___ | ☐ |
| 2 | `SPEC-C-05` 提交前测试集全绿、`SPEC-C-03` 旧值零残留命中 0 | `SPEC-C-05` §7 / `SPEC-C-03` §7 #3 | `tool/verify_all.ps1` 退出码 0；旧值扫描 0 命中 | ☐ |
| 3 | release APK 无 `INTERNET`、仅 `RECORD_AUDIO` | `SPEC-C-01` §7 #1/#2 | `aapt dump badging` 输出：权限集合 == {RECORD_AUDIO} | ☐ |
| 4 | 签名有效且非 debug 签名 | `SPEC-C-04` §7 #3 | `apksigner verify --print-certs`：CN = ______ | ☐ |
| 5 | `key.properties` / keystore 未入库 | `SPEC-C-04` §7 #4 | `git check-ignore -v app/android/key.properties` 命中；`git ls-files` 命中 0 | ☐ |
| 6 | 模型体积 ≤ 本档 FF-16 上限（fp32 ≤ 6 MB / INT8 ≤ 2.5 MB；`ADR-21` 起两档都可交付，~~模型 ≤ 2.5 MB~~） | `SPEC-C-04` §7 #6 | `ai/artifacts/model_card.json` 的 `quantization` = ______、`tfliteBytes` = ______（当前投放 fp32 制品 = 4,051,716 B） | ☐ |
| 7 | 三 ABI（或声明的子集）产物齐备、命名与归档路径符合 `SPEC-C-04` §4 | `SPEC-C-04` §7 #2/#7 | `docs/release/AcouDiet-v1.0.0-<stamp>-<abi>.apk` | ☐ |
| 8 | 归档索引字段齐全、`analyzeErrors == 0` | `SPEC-C-04` §7 #8 | `docs/release/RELEASE_1.0.0_<stamp>.md` | ☐ |
| 9 | 飞行模式全流程核对表通过 | `SPEC-C-01` §7 #4 | 检测 → 识别 → 记录 → 报告 全程可用 | ☐ |
| 10 | 冻结 tag 已打、冻结后零提交 | `SPEC-C-04` §7 #9 | `git tag -l 'v1.0.0-freeze'`；`git log --since=<freeze-ts>` 为 0 行 | ☐ |
| 11 | 清单完成（B/C 签字）与版本号一致（§4 `appVersion`） | `SPEC-C-04` §7 #10 | 本文件底部签字；`appVersion = 1.0.0+1` | ☐ |
| 12 | 材料齐备（PPT / 演示视频 / 测试报告 / 同意书扫描件 / `aapt` 隐私截图） | 主方案 §12.6 | 见 `docs/release/` 与 `docs/compliance/C-02_consent_and_ethics.md` | ☐ |

---

## 体积记录（**只记录，不设阈值** —— `SPEC-C-04` §8）

| 产物 | 字节数 | sha256 |
|---|---|---|
| arm64-v8a | ______ | ______ |
| armeabi-v7a | ______ | ______ |
| x86_64 | ______ | ______ |
| 模型 `acoudiet_fp32_v1.1.0.tflite`（fp32 档，FF-16 上限 6 MB；~~`acoudiet_int8_v1.0.0.tflite`（INT8 档 ≤ 2.5 MB）~~ 旧档位） | ______ | ______ |

## 签署

| 角色 | 姓名 | 日期 |
|---|---|---|
| B（构建与发布主责） | __________ | __________ |
| C（归档与材料） | __________ | __________ |
