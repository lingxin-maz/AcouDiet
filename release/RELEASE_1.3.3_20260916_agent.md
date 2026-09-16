# RELEASE 1.3.3 (20260916)

| 字段 | 值 |
|---|---|
| `appVersion` | `1.3.3+9` |
| `flavour` | `agent` |
| `apkPath` | `release/AcouDiet-v1.3.3-20260916-arm64-v8a-agent.apk` / `release/AcouDiet-v1.3.3-20260916-armeabi-v7a-agent.apk` / `release/AcouDiet-v1.3.3-20260916-x86_64-agent.apk` |
| `apkSha256` | `fb24dc3affa610f867ff15efa988299f7f76b62ea5ffec6a5831ce47f714e689` / `666e28145d87ef0051f4f1ea5c284ac88adb246c471943072b837ca114e2cef0` / `e879bd8092380abda622fed61e1dc0f749fdfcae8a7f75663d47fcf03ae1c523` |
| `apkBytes` | 28220776 / 23847770 / 31214391 |
| `tfliteBytes` | 4053556 |
| `permissions` | `["android.permission.RECORD_AUDIO", "android.permission.INTERNET"]` |
| `freezeCommit` | `03e2b74` |
| `analyzeErrors` | 0 |

ABI 清单：arm64-v8a, armeabi-v7a, x86_64

分析日志：`release/analyze_20260916.txt`（warnings=31, info=83，均不阻塞但须记录）
哈希清单：`release/apk_sha256.txt`

> 生成命令：`powershell -File tool\build_release.ps1 -Flavour agent`
> 本文件由脚本生成；发布前检查清单见 `release/pre_release_checklist_20260916.md`。
