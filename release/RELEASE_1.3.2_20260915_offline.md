# RELEASE 1.3.2 (20260915)

| 字段 | 值 |
|---|---|
| `appVersion` | `1.3.2+8` |
| `flavour` | `offline` |
| `apkPath` | `docs/release/AcouDiet-v1.3.2-20260915-arm64-v8a-offline.apk` / `docs/release/AcouDiet-v1.3.2-20260915-armeabi-v7a-offline.apk` / `docs/release/AcouDiet-v1.3.2-20260915-x86_64-offline.apk` |
| `apkSha256` | `aa5e71e11592b1953c378b4c228d0d8f31b2a48768f68758333c13ff15d2c011` / `86e6782b0a82474b15ee6324b3571ec206199ea54872cae903c99ecb04962d67` / `766f3e74715b5176cf9cb2ae034e148380c82a3ca24986ca2cd228aed3ad0b13` |
| `apkBytes` | 27171516 / 22732974 / 30099595 |
| `tfliteBytes` | 4053556 |
| `permissions` | `["android.permission.RECORD_AUDIO"]` |
| `freezeCommit` | `00d3af9` |
| `analyzeErrors` | 0 |

ABI 清单：arm64-v8a, armeabi-v7a, x86_64

分析日志：`docs/release/analyze_20260915.txt`（warnings=31, info=83，均不阻塞但须记录）
哈希清单：`docs/release/apk_sha256.txt`

> 生成命令：`powershell -File tool\build_release.ps1 -Flavour offline`
> 本文件由脚本生成；发布前检查清单见 `docs/release/pre_release_checklist_20260915.md`。
