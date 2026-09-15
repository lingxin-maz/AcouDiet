# C-06 合规归档目录

**对应 SPEC**：`SPEC-C-06_云端智能的隐私与合规`（`docs/common/docs/C-06_云端智能的隐私与合规/`）
**引入裁定**：`ADR-44`

---

## 1. 这份 README 为什么存在

`SPEC-C-06` §7 有 15 条机器判据，其中 **6 条要求真实文件**。本目录是它们指定的归档位置。

**但是本目录现在是空的，而且这是如实状态，不是遗漏。** 写这份 README 的唯一目的是让「哪些证据已产出、哪些没产出、为什么」变成一句可核对的话，而不是一个看起来像完成品的空目录。

**🚫 明确禁止**：不得为了让 `SPEC-C-06` §7 的判据变绿而放置占位文件（空 `.png`、手写的 `aapt` 输出、编造的时间戳）。本项目反复出现的那类事故（检查存在但从不执行 / 闸门在说谎）正是这样开始的。**一个假的证据文件，比没有证据文件坏得多**，因为它让下一个读它的人相信了一件不存在的事。

---

## 2. 产物清单与当前状态

> # ✅ `ADR-44` 收尾时已从**真实构建产物**补齐（2026-09-15）
>
> 本机**其实跑得动 `flutter build apk`** —— `tool/build_release.ps1` 头部那句「必须在普通终端运行、
> 沙箱会挡住管道 stdio」**已经过期**：实测 `cmd.exe /c ver`、`flutter --version`、Gradle
> `assembleAgentRelease`/`assembleOfflineRelease` 全部正常。两个风味各出 3 个 ABI 的 release APK，
> 下面 §2.1 的产物因此**已全部产出**。
>
> ⚠️ **这句话必须留在文件里**：它是本项目第三次遇到「限制写在文档里、却从没有人重新测过」。
> 一次过期了的限制，会以「不可能做到」的样子，把一个**完全可以做**的验证挡在门外三年。

| 判据 | 产物 | 状态 | 依据 |
|---|---|---|---|
| §7 #3 | `aapt_offline_v2.0.txt` | ✅ **已产出** | `aapt dump badging` 于 `AcouDiet-v1.3.0-20260915-arm64-v8a-offline.apk` |
| §7 #3 | `aapt_agent_v2.0.txt` | ✅ **已产出** | 同上，对象为 `…-agent.apk` |
| §7 #5 | `apk_sha256_offline.txt` | ✅ **已产出** | sha256 + 字节数 + 版本号 |
| §7 #5 | `apk_sha256_agent.txt` | ✅ **已产出** | 同上 |
| §7 #7 | `consent_copy_v2.0.md` | ✅ **已产出** | 从 `ui_strings.dart` 的同意门常量**逐字导出**，不是照散文重打 |
| §7 #10 | `gate_screenshot.png` | ❌ **仍未产出** | 需要真机或模拟器上的同意门截图。**本机无 adb 设备、无 AVD** —— 这是本轮**唯一**真正无法产出的证据 |
| §7 #15 | `dist/*offline*.apk` + `dist/*agent*.apk` | ✅ **已产出** | 归档在 `release/`（脚本的归档目录就是这里，不是 `dist/`）：`AcouDiet-v1.3.0-20260915-<abi>-<flavour>.apk` × 6 |

### 2.1 实测的两套权限证据（**这就是 `FF-24` 第 4 条的现场证据**）

| | `offline` | `agent` |
|---|---|---|
| `package` | `com.acoudiet.app.offline` | `com.acoudiet.app` |
| `versionName` | `1.3.0-offline` | `1.3.0` |
| `uses-permission` | `RECORD_AUDIO` **仅此一项** | `RECORD_AUDIO` + `INTERNET` |
| 两个 APK 里都另有 `…DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | AGP 内部条目，闸门刻意排除，不计入集合 | 同左 |
| arm64-v8a 字节数 / sha256 | 27,069,194 / `e9d6dfe3d1a9216f…` | 27,856,234 / `d715ebff3b16ad5b…` |

两档的**包名与版本名也不同**，不是只靠文件名区分 —— 两个 APK 的**权限集合差异**不可能被误认。

### 2.2 同一批产物上跑过的独立闸门（全部 exit 0）

| 闸门 | 结果 |
|---|---|
| Gradle `processAgentReleaseManifest` / `processOfflineReleaseManifest` 的 `doLast` 权限审计 | 两个风味、两个方向都**执行过并通过**（`internet=True OK` / `internet=False OK`） |
| `tool/check_apk_contents.py` | `offline --expect-no-internet` → 0；`agent --expect-internet` → 0 |
| `tool/check_page_alignment.py` | **16 KB COMPATIBLE**（`libapp.so` p_align=65536、`libtensorflowlite_jni.so` p_align=16384，偏移全部对齐） |
| `tool/ui_fingerprint_check.py` | **CURRENT UI**（9 条 must-be-present 全中，3 条 must-be-absent 全无） |
| 包内模型 sha256 vs 模型卡 | 相等（`31fba3ec…19f4`，4,053,556 B，fp32 ≤ 6 MB） |
| `apksigner verify` | 三个 ABI 均 `signature=OK` |

> ⚠️ **签名用的是测试密钥**（`key.properties` 自己写着 `THIS IS NOT A RELEASE KEY`），
> **不得对外分发**。见 `SPEC-C-04`。

---

## 3. 已可机械验证的部分（不需要构建产物）

这些判据**现在就是绿的**，且都有负控：

| 判据 | 命令 | 实测 |
|---|---|---|
| §7 #1 静态：音频类型不进网络层 | `python tool/check_audio_egress.py --strict` | clean；`--selftest` 5 个用例全判别正确 |
| §7 #1 的兄弟判据：唯一出网点 | `python tool/check_network_boundary.py --strict` | clean；`--selftest` **10** 个用例全判别正确 |
| §7 #2 运行时：请求体是纯结构化 JSON | `dart run app/tool/agent_tests.dart` | **all 80 checks passed**；`--without-negative-controls` → **74/80，恰好 6 条负控变红** |
| §7 #6 撤回即删除凭据 | 同上（`clear() removes the credential file`） | 通过 |
| §7 #11 无 FF-25 禁用表述 | `dart run app/tool/ui_presenter_tests.dart` | 通过（新文案已并入采集清单） |
| §7 #12 两向：禁代操作、须有交接 | 见 `SPEC-C-06` §7 #12（`ADR-44` 修正版） | 无障碍/手势 API **0** 命中；`startActivity` **1** 命中 |
| §7 #13 不得自称完全合规 | 只数肯定式 | 过滤否定语境后 **0** 命中 |
| §7 #14 Key 不出现在可外发表面 | `rg -n "sk-[A-Za-z0-9_\-]{16,}" records/compliance/C-06/ app/lib/presentation/pages/agent/` | **0** 命中（按**凭据形状**判定，不按这三个字符；见 `SPEC-C-06` §7 #14/#14b 的修正说明） |

---

## 4. 补齐这些产物需要什么

1. **一台能跑 `flutter build` 的机器**（本仓的 `tool/build_release.ps1 -Flavour <offline|agent>` 已经改造好，两个风味各自校验权限集合、各自产出带风味名的归档名）；
2. `app/android/key.properties`（release 签名，见 `SPEC-C-04`）；
3. 一次真机或模拟器运行，用于同意门截图。

补齐后请**逐条**回填本表，并且**把 `git` 提交号与构建日期写在文件名或文件首行**——「这份 `aapt` 输出对应哪一次构建」必须可追溯，否则它证明不了任何事。

---

## 5. 仍然开放的合规缺口（不得写成"已合规"）

1. **数据可携带性**（`API-05` §11）：`X-03` 裁剪了导出，本版**仍无**取得与转移个人信息的途径。个保法下的可携带权**未被满足**。
2. **`base_url` 可被用户改成任意主机**（`SPEC-G-01` §10 #2）：用户自己的 Key 可能被发到他没预期的服务器。当前处置是「允许 + 在设置页显式警示」，**不是**域名白名单。
3. **`FF-26d` 的七类结构化字段确实出境**：「音频不出境」**不得**被扩大解释为「数据不出境」。
4. **DeepSeek 侧的数据留存与删除策略不由本 App 控制**，本 App **不得**代其承诺。

**本文件与 `SPEC-C-06` 都不构成法律意见。** 如进入实际商用，须重新做法务评估。
