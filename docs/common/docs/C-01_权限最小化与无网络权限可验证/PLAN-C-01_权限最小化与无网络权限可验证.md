# PLAN-C-01 权限最小化与「无网络权限」可验证

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-C-01` |
| 负责 | B（主责）；C 协助证据归档与 PPT 图表第 7 项 |
| 目标日 | D4（首次取证，当日硬验收）→ D10（release 重跑并定稿） |
| 前置依赖 | 环境激活 `_toolchain/acoudiet-env.ps1`；`ANDROID_HOME` 下 build-tools 提供 `aapt`；可解析的 APK；`SPEC-C-04` 的出包命令；**构建须在沙箱外普通终端执行** |
| 预估工时 | 6 h（B 4 h + C 2 h） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/android/app/src/main/AndroidManifest.xml` | 合并后仅 `RECORD_AUDIO` 的权限声明（**本 PLAN 不新增文件，只改既有清单**） |
| 2 | `records/compliance/C-01/aapt_badging_<yyyyMMdd>_<buildType>.txt` | `aapt dump badging` 原样输出 |
| 3 | `records/compliance/C-01/apk_sha256.txt` | APK 路径 + 64 位 hex + 字节数 + 构建类型 + 构建日期 |
| 4 | `records/compliance/C-01/code_scan_no_network.txt` | 5 关键词搜索命令与输出（命中行数 0） |
| 5 | `records/compliance/C-01/flight_mode_checklist.md` | `SPEC-C-01` §7 #4 的 7 项核对表 + 截图文件名 |
| 6 | `records/compliance/C-01/ppt_fig_07_no_internet.png` | PPT 必现图表第 7 项的截图 |
| 7 | `records/compliance/C-01/README.md` | 证据索引（文件 → 判据编号 → 采集日期） |

> 路径 `records/compliance/` 为新增目录，`SPEC-00` §1 未列该类目 —— 已登记在 `SPEC-C-01` §10 #1，需 A/B/C 确认后增补目录表。

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 审查主线/debug/profile 三份 Manifest，删除模板注入的 `INTERNET` | 三份清单的差异说明 | 1 h | — |
| 2 | 传递依赖权限审查（`pubspec.yaml` + 依赖 Manifest） | 依赖权限结论表 | 1 h | #1 |
| 3 | 出包并在 D4 完成首次取证（`aapt` + `sha256`） | 交付物 #2/#3 | 1 h | #1、`PLAN-C-04` 出包命令 |
| 4 | 代码层 5 关键词搜索与命中清理 | 交付物 #4 | 1 h | #2 |
| 5 | 飞行模式全流程实测（含三种 Demo 模式） | 交付物 #5 | 1 h | `PLAN-M-01`~`PLAN-M-03` 可用 |
| 6 | D10 release 包重跑、覆盖存档、写索引 | 交付物 #2/#3/#6/#7 | 1 h | `PLAN-C-04` D10 出包 |

## 3. 技术方案

**Manifest 处置（文字化，不在本文档复制整份 XML）**：主线清单只保留 `<uses-permission android:name="android.permission.RECORD_AUDIO" />`；`INTERNET` 仅允许存在于 `debug`/`profile` 变体清单；依赖带入的权限**一律靠移除依赖解决**，不靠 `tools:node="remove"`（`SPEC-C-01` §3 与 §6）。

**取证与搜索骨架（PowerShell，≤30 行；构建命令必须在沙箱外普通终端执行）**：

```powershell
. D:\Desktop\Food\_toolchain\acoudiet-env.ps1
$aapt = (Get-ChildItem "$env:ANDROID_HOME\build-tools" -Directory |
         Sort-Object Name -Descending | Select-Object -First 1).FullName + '\aapt.exe'
$apk  = 'app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
$out  = 'docs\compliance\C-01'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd'
& $aapt dump badging $apk | Tee-Object "$out\aapt_badging_${stamp}_release.txt"
"path=$apk`nsha256=$((Get-FileHash $apk -Algorithm SHA256).Hash)`nbytes=$((Get-Item $apk).Length)" |
  Set-Content "$out\apk_sha256.txt"
rg -n --glob '!**/build/**' -e 'http' -e 'dio' -e 'socket' -e 'WebSocket' -e 'url_launcher' `
  app\lib app\android\app\src app\pubspec.yaml | Tee-Object "$out\code_scan_no_network.txt"
# 期望：rg 无命中 → 输出为空且退出码 1
```

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `aapt` 权限复核 | 命令 | 无 `INTERNET`；权限集合 == `{RECORD_AUDIO}` | D4、D10 |
| 权限复核可复现 | 命令 | 同一 APK 两次 `aapt` 的 `uses-permission` 行逐行相等 | D10 |
| 代码层零网络调用 | 命令 | 5 关键词命中行数 == 0（`rg` 退出码 1） | 每次提交前、D4、D10 |
| 模型体积复核 | 命令 | `app/assets/models/*.tflite ≤ 2.5 MB`（FF-16） | D4、D10 |
| 飞行模式全流程 | 人工核对表 | 7 项全通过，无异常弹窗 | D9 演练、D10 定稿 |
| 证据完整性 | 断言 | `records/compliance/C-01/` 下 5 类文件存在，`sha256` hex 长度 64 | D10 |

## 5. 完成定义（DoD）

- [ ] `SPEC-C-01` 第 7 节 7 条判据全部通过，验证输出已归档
- [ ] 主线 Manifest 仅 `RECORD_AUDIO`；debug/profile 的 `INTERNET` 未进入 release 合并结果
- [ ] 代码层 5 关键词搜索命中行数为 0，且不含白名单豁免（`pubspec.yaml` 与代码不接受白名单）
- [ ] 飞行模式 7 项核对表全部打勾并有截图
- [ ] `records/compliance/C-01/` 五类证据齐备，`README.md` 索引到判据编号
- [ ] PPT 第 7 项图表（`aapt` 无网络权限截图）已就位
- [ ] 「开启网络会失去什么」三条已写入答辩 Q&A 材料并与 `API-05` §10 一致
- [ ] `API-05` §11 数据可携带性缺口已在 PPT「后续工作」列出

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 某依赖强制声明 `INTERNET` 且不可去 | 依赖 Manifest 审查命中 | 换实现方案（如纯 Kotlin `AudioRecord`，与 `P-01` 一致）；登记 `SPEC-C-01` §10 |
| `aapt` 缺失或版本异常 | `Get-Command`/执行报错 | 回退 `apkanalyzer manifest permissions` 或 Android Studio「Analyze APK」+ 人工截图 |
| D4 无 release 包 | 签名未就绪（`PLAN-C-04`） | 用 debug 包取证并标注构建类型；D10 必须替换为 release 证据 |
| 飞行模式实测时 Mode B/C 不可用 | 核对表第 3/4 项失败 | 按 `PLAN-M-*` 修复；本功能判据不变（失败属 `M` 域） |
| 证据目录未被上游承认 | 评审指出 `SPEC-00` §1 无该类目 | 落回 `docs/` 下已承认的相邻目录，并走 `SPEC-C-03` 传播更新目录表 |

## 7. 与检查点的关系

| CP | 关系 | 未完成时的处置 |
|---|---|---|
| D4 当日硬验收 | 「★无 INTERNET 权限」是本 PLAN 的直接产物 | 未过 → 当日不得宣称隐私主张，PPT 第 7 项图表留空 |
| **CP3**（D9 午） | 现场演示的前提之一：飞行模式全流程可用 | 未过 → 与 `M-01`~`M-04` 一同进入「停止新功能、全员扑 Demo」 |
| D10 冻结 | release 证据重跑并定稿，之后不得再改代码/重打包 | 未过 → 按 `PLAN-C-04` §6 处置（只允许重跑取证，不允许改代码） |

**文档结束**
