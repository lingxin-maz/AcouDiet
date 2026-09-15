# RELEASE 1.3.1 (20260915)

| 字段 | 值 |
|---|---|
| `appVersion` | `1.3.1+7` |
| `flavour` | `offline` |
| `apkPath` | `docs/release/AcouDiet-v1.3.1-20260915-arm64-v8a-offline.apk` / `docs/release/AcouDiet-v1.3.1-20260915-armeabi-v7a-offline.apk` / `docs/release/AcouDiet-v1.3.1-20260915-x86_64-offline.apk` |
| `apkSha256` | `dd9f213faa6aa47158d43b036932202337bdb19bc3fdf68d87f2bfbeee377c4f` / `387af7483139b844be530150d2b39b8eafe5ced357b9e8bebb94ce20c36fc272` / `fc746afaae81d9ca5d9b4632f3106022c2767f1f6e07c0e2a0d45478eb75ac66` |
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
