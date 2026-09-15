# RELEASE 1.3.2 (20260915)

| 字段 | 值 |
|---|---|
| `appVersion` | `1.3.2+8` |
| `flavour` | `agent` |
| `apkPath` | `docs/release/AcouDiet-v1.3.2-20260915-arm64-v8a-agent.apk` / `docs/release/AcouDiet-v1.3.2-20260915-armeabi-v7a-agent.apk` / `docs/release/AcouDiet-v1.3.2-20260915-x86_64-agent.apk` |
| `apkSha256` | `fa299807987a0d3bfb23bfa2cd9e0ebf3c2b0942ac6a11441fcfd6d105ae26fd` / `9ebdbe7b7af96047919f57128ddb0a7fe410ffb038a76d4177608048bbe64698` / `dd7209eb7020c00860881bd4aa9fd22574a4b1e82951311978a7690c8e3735a2` |
| `apkBytes` | 28220696 / 23847690 / 31214311 |
| `tfliteBytes` | 4053556 |
| `permissions` | `["android.permission.RECORD_AUDIO", "android.permission.INTERNET"]` |
| `freezeCommit` | `00d3af9` |
| `analyzeErrors` | 0 |

ABI 清单：arm64-v8a, armeabi-v7a, x86_64

分析日志：`docs/release/analyze_20260915.txt`（warnings=31, info=83，均不阻塞但须记录）
哈希清单：`docs/release/apk_sha256.txt`

> 生成命令：`powershell -File tool\build_release.ps1 -Flavour agent`
> 本文件由脚本生成；发布前检查清单见 `docs/release/pre_release_checklist_20260915.md`。
