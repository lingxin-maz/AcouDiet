# RELEASE 1.3.1 (20260915)

| 字段 | 值 |
|---|---|
| `appVersion` | `1.3.1+7` |
| `flavour` | `agent` |
| `apkPath` | `docs/release/AcouDiet-v1.3.1-20260915-arm64-v8a-agent.apk` / `docs/release/AcouDiet-v1.3.1-20260915-armeabi-v7a-agent.apk` / `docs/release/AcouDiet-v1.3.1-20260915-x86_64-agent.apk` |
| `apkSha256` | `d040e7cb0a20a095d8eb4139fc52c2cce04ff286e0b5ab77f202c90e4200bf05` / `4641647d4992f80b96394643bd5a71314ce4e801e85d8d9c9d624fa677ace094` / `ceb639c505f611dbb2d51398cfc905407b5156a17680abaa4e06571fbc7177d9` |
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
