# RELEASE 1.3.4 (20260916)

| 字段 | 值 |
|---|---|
| `appVersion` | `1.3.4+10` |
| `flavour` | `agent` |
| `apkPath` | `release/AcouDiet-v1.3.4-20260916-arm64-v8a-agent.apk` / `release/AcouDiet-v1.3.4-20260916-armeabi-v7a-agent.apk` / `release/AcouDiet-v1.3.4-20260916-x86_64-agent.apk` |
| `apkSha256` | `6a3b33be580acf85e841c297ef45875e4b9066dfae504d6848f7ec48d3c2409a` / `fa59c85452a133364420088546359847d20f4b256586bd6d86fdbbb59dd2574f` / `5b88a7c4d4410bcc3f3d37ddd9781540e9d9b41aa8d9a23beabe3fb4edb02d0a` |
| `apkBytes` | 28220780 / 23847774 / 31214395 |
| `tfliteBytes` | 4053556 |
| `permissions` | `["android.permission.RECORD_AUDIO", "android.permission.INTERNET"]` |
| `freezeCommit` | `03e2b74` |
| `analyzeErrors` | 0 |

ABI 清单：arm64-v8a, armeabi-v7a, x86_64

分析日志：`release/analyze_20260916.txt`（warnings=31, info=83，均不阻塞但须记录）
哈希清单：`release/apk_sha256.txt`

> 生成命令：`powershell -File tool\build_release.ps1 -Flavour agent`
> 本文件由脚本生成；发布前检查清单见 `release/pre_release_checklist_20260916.md`。
