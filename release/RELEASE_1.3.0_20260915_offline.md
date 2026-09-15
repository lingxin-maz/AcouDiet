# RELEASE 1.3.0 (20260915)

| 字段 | 值 |
|---|---|
| `appVersion` | `1.3.0+6` |
| `flavour` | `offline` |
| `apkPath` | `docs/release/AcouDiet-v1.3.0-20260915-arm64-v8a-offline.apk` / `docs/release/AcouDiet-v1.3.0-20260915-armeabi-v7a-offline.apk` / `docs/release/AcouDiet-v1.3.0-20260915-x86_64-offline.apk` |
| `apkSha256` | `d22821ec567b9df294a28e66e6cbc1d98f8dff28c6bf36fa9e9137a401385adb` / `c61f4e41fcecc4f8d40097d3e6dc7cc9138680031c88ce7a365a35c215fd7144` / `112fe455036e1dab1b67801c2f4a8299d1b32f15e3a80b2383fcda077193fdcf` |
| `apkBytes` | 27171504 / 22732962 / 30099583 |
| `tfliteBytes` | 4053556 |
| `permissions` | `["android.permission.RECORD_AUDIO"]` |
| `freezeCommit` | `00d3af9` |
| `analyzeErrors` | 0 |

ABI 清单：arm64-v8a, armeabi-v7a, x86_64

分析日志：`docs/release/analyze_20260915.txt`（warnings=31, info=83，均不阻塞但须记录）
哈希清单：`docs/release/apk_sha256.txt`

> 生成命令：`powershell -File tool\build_release.ps1 -Flavour offline`
> 本文件由脚本生成；发布前检查清单见 `docs/release/pre_release_checklist_20260915.md`。
