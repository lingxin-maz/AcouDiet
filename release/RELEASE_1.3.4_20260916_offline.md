# RELEASE 1.3.4 (20260916)

| 字段 | 值 |
|---|---|
| `appVersion` | `1.3.4+10` |
| `flavour` | `offline` |
| `apkPath` | `release/AcouDiet-v1.3.4-20260916-arm64-v8a-offline.apk` / `release/AcouDiet-v1.3.4-20260916-armeabi-v7a-offline.apk` / `release/AcouDiet-v1.3.4-20260916-x86_64-offline.apk` |
| `apkSha256` | `8cbec98500cadc3a3fdca3dcbe13fb471b8ebb5406e2f4d5de84705e5661fec5` / `88d0494fe2561cbc681ebae0f525a6a66a9e63140aa85781fb0e10cc3ca800f0` / `4996a2c8beccc323ea050a704db376f09aae0796508c3ca40f5b38c17ef18660` |
| `apkBytes` | 27171596 / 22733054 / 30099675 |
| `tfliteBytes` | 4053556 |
| `permissions` | `["android.permission.RECORD_AUDIO"]` |
| `freezeCommit` | `03e2b74` |
| `analyzeErrors` | 0 |

ABI 清单：arm64-v8a, armeabi-v7a, x86_64

分析日志：`release/analyze_20260916.txt`（warnings=31, info=83，均不阻塞但须记录）
哈希清单：`release/apk_sha256.txt`

> 生成命令：`powershell -File tool\build_release.ps1 -Flavour offline`
> 本文件由脚本生成；发布前检查清单见 `release/pre_release_checklist_20260916.md`。
