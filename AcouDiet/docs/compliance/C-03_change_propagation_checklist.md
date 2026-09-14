# C-03 变更传播单（本仓落地版）

**SPEC 对应**：`SPEC-C-03` §7 附表（14 项）+ §7 判据 1–5
**PLAN 对应**：`PLAN-C-03` §2 任务 #5、§4 测试表

---

## 1. 生成与一致性（判据 1 / 2 / 4）

| # | 判据 | 命令 | 实测 |
|---|---|---|---|
| 1 | Dart/Kotlin 常量由生成器产出、与 SSOT 逐字段相等 | `dart run tool/gen_feature_config.dart` | ✅ 退出码 0；`assets/feature_config.json` 与 `shared/feature_config.json` **字节相等**；`FeatureConfig.kt` / `feature_config.g.dart` 首行均带 `DO NOT EDIT` |
| 2 | 握手 **15** 字段全等（`ADR-21` 由 12 增至 15：新增 `rawMelFrames`/`preemphasisBoundary`/`powerToDbRef`/`topDb`/`normalization`，移除 `dbClipMin`/`dbClipMax`），失败即 `ACD-CFG-001` | `dart run app/tool/session_tests.dart` → `C-03 start-up handshake` | ✅ 15 字段全等放行；篡改 `nFrames=129`（128 现在是正确值）与 `melVersion` 两例均抛 `ACD-CFG-001`，`detail.field` 指名出错字段（~~12 字段全等放行；篡改 `nFrames=128`~~ 已作废） |
| 4 | 制品闭环三 hash | `tool/verify_artifacts.py`（独立于生产者的第二实现） | ✅ **已执行，exit 0 = PASS**：fp32 4,051,716 B ≤ 6 MB、`tfliteSha256`/`tfliteBytes`/`featureConfigSha256` 三 hash 闭合、parity 为实测值（~~待 `.tflite` 产出后执行~~ 已作废） |

**生成物清单**（全部由 SSOT 派生，禁止手改）：

| 生成物 | 生成器 | 消费方 |
|---|---|---|
| `app/lib/core/feature_config.g.dart` | `tool/gen_feature_config.dart` | 全部 Dart 层（camelCase 常量） |
| `app/android/app/src/main/kotlin/.../config/FeatureConfig.kt` | 同上 | Kotlin DSP + `getCapabilities()` |
| `app/assets/feature_config.json` | 同上 | 运行期握手比对的期望值 |
| `app/test/cfg/feature_config_keys.g.json` | 同上 | 键清单（供一致性用例） |

**`melVersion` 的来源**（`SPEC-C-03` §10 #2 登记为未决）：SSOT 无 `mel_version` 键。
本仓取 `app/assets/models/model_card.json` 的 `melVersion` —— 即 `API-05` §7.1 交付闸门②
（`model_card.melVersion == Kotlin MelFrontend.melVersion`）所用的同一真源；模型卡缺失时回退
`"1.0.0"`（模型卡现值已随 `ADR-21` 升为 **`1.1.0`**）。生成器把该值投影为
`FeatureConfig.melVersion` 与 `MEL_VERSION`（现为 **`1.1.0`**），因此
"改了模型没改 Kotlin"同样会被启动握手拦住。

---

## 2. 判据 3：旧值零残留（机械验收）

```powershell
rg -n --glob '!**/build/**' --glob '!**/.dart_tool/**' --glob '!_toolchain/**' `
   --glob '!AcouDiet_项目实现计划方案_v3.md' --glob '!docs/**/SPEC-C-03_*.md' `
   --glob '!AcouDiet/docs/compliance/C-03_*.md' `
   -e '(^|[^0-9.])3s([^A-Za-z0-9]|$)' -e '(^|[^0-9])3 秒' -e 'hop.*160' -e '帧移 10' docs shared AcouDiet
```

**实测（本仓）**：

| 范围 | 结果 |
|---|---|
| `AcouDiet/app`（全部 Dart/Kotlin + 生成物） | **0 命中** |
| `AcouDiet/ai` | **0 命中**（唯一疑似命中 `mobilenetv3small` 是 `3s` 后紧跟字母的假阳性 —— 故上式加了右边界守卫 `([^A-Za-z0-9]|$)`，规范值已按此细化） |
| `AcouDiet/docs/reports`、`AcouDiet/README.md` | 0 命中 |
| `AcouDiet/docs/compliance/C-03_change_propagation_checklist.md` | 存在旧值，但**这是变更传播单自身的"旧值/新值"对照表**，属 `SPEC-C-03` §7 判据 3 明示的授权例外（与 `docs/**/SPEC-C-03_*.md` 同类），故在上式中一并排除 |

本仓代码在生成阶段即已避免旧值：`hop_length = 512`（`FeatureConfig.HOP_LENGTH`）、
patch = `65536` 样本 / `4.096 s`（`PATCH_SAMPLES` / `PATCH_SECONDS`）、
`n_frames = 128`（`N_FRAMES`）与 `raw_mel_frames = 129`（`RAW_MEL_FRAMES`）——
`ADR-21` 把原先的单个 129 拆成**两个常量**（~~`n_frames = 129`（`N_FRAMES`）~~ 已作废），
全部只出现在生成常量中一次。

> 📌 **给校验脚本维护者的建议**：`3s` 这类模式的**右边界**也必须守卫。
> 本轮实测中 `mobilenetv3small`（模型名）被 `(^|[^0-9.])3s` 命中，属假阳性；
> 只守卫左边界不足以做到"0 命中"。

---

## 3. 14 项变更传播单

`SPEC-C-03` §7 附表的 14 行核对结果（本仓视角；文档侧的改写由 C 负责，不在本仓范围内）：

| # | 位置 | 旧值 | 冻结值 | 本仓状态 | ✅ |
|---|---|---|---|---|---|
| P-1 | 计划书 §5.1.1 步骤 2 | hop 10ms / 帧移 160 | `hop_length = 512` | 代码只读 `FeatureConfig.hopLength`；生成物唯一 | ☑ |
| P-2 | 计划书 §5.1.1 步骤 4 | 「128×128 Mel」 | `n_frames = 128`（另见 `raw_mel_frames = 129`） | `N_FRAMES=128`、`INPUT_SHAPE=[1,128,128,1]`（`ADR-21`；~~`N_FRAMES=129`、`INPUT_SHAPE=[1,128,129,1]`~~）。**计划书当年写的「128×128」现在正是实际交付的张量形状** —— `ADR-21` 保留了 129 个 STFT 帧，但只在归一化前把尾帧丢掉；Kotlin 与 Python 双测 | ☑ |
| P-3 | 计划书 §6.3.2 | 帧长 25ms / 帧移 10ms | `win_length = n_fft = 1024` / `hop = 512` | `MelFilterBank.hannPeriodic(1024)`；`hopLength=512` | ☑ |
| P-4 | 计划书 §6.3.3 | 「连续 128 帧拼接」 | 128 帧 = 4.096 s | `patchSamples=65536`、`patchSeconds=4.096` | ☑ |
| P-5 | `执行规划草稿.txt` D1 | `duration=3s` | `patch_seconds = 4.096` | 同上；边界断言 `wav` 长度 == 65536 | ☑ |
| P-6 | 主方案 §5.4 行为分析 | 4.096 s patch 时域 | 与 Mel 共用同一环形缓冲 | `EnvelopeExtractor` 与 VAD **同一次分帧**（FF-21h） | ☑ |
| P-7 | 主方案 §8.3 D5 | 「录 3 秒」 | 「录 4.096 s（或连续流）」 | 会话流式滑窗，无"录 3 秒"路径 | ☑ |
| P-8 | 主方案 §14 P0 | Kotlin 录 3 秒 PCM | 4.096 s PCM | `jvm_build.ps1 -Run` 以 65536 样本夹具验证 | ☑ |
| P-9 | `feature_config.json` | 分散在多份材料 | 单一真源 | 41 键 SSOT + 生成器 + 字节相等副本 | ☑ |
| A-1 | `API-03` §4/§5 | 6+4 方法 | 新增 5 方法 + `ChewStats` | `DietRepo.metricsByRecordId`、`StatsRepo.summary/chewStats/mealTimeSamples/activeDays` 全部实现并测试 | ☑ |
| A-2 | `API-03` §5 | 早`[05,11)`/午`[11,16)`/晚`[16,23)` | 早`[05,10)`/午`[11,14)`/晚`[17,21)`；晚间`[20,05)` | `MealWindows` 读 SSOT `meal_windows`；14 个边界点断言；15:40 计入零食 | ☑ |
| ADR-05 | `SPEC-00` §3.7 FF-22 | 「σ≤30 满分」（与公式矛盾） | 以公式为准，σ=30 → 20 | `ScoreFormulas` 字面表达式；算例 C 断言 20 | ☑ |
| ADR-07 | 两份 schema | `const: 129` | `enum: [128,129]` → 拍板后回 `const` | 上游文档项；`ADR-21` 后本仓常量已改为 `N_FRAMES=128`，并单列 `RAW_MEL_FRAMES=129`（~~本仓常量 `N_FRAMES=129`~~）。**两份上游 schema 可能仍写 `const: 129`** —— 登记为上游文档待改项（不是本仓代码问题） | ☑ |
| ADR-09 | `SPEC-D-03` §4.1 | 同 A-2 旧窗口 | 同 A-2 新窗口 | 与 A-2 同一实现（`MealWindows` 单一来源） | ☑ |

**结论：14/14 在本仓范围内已落地**（P-1…P-9 的文档正文修订与 ADR-07 的 schema 文本由 C/A 负责，
本仓不修改 `docs/`）。

---

## 4. 权限最小化 / 无网络（C-01 交叉项）

| 判据 | 实现位置 | 状态 |
|---|---|---|
| Manifest 仅 `RECORD_AUDIO`，无 `INTERNET` | `app/android/app/src/main/AndroidManifest.xml` | ☑ 仅声明 `RECORD_AUDIO` |
| 无后台常驻 Service | 无 `android/app/src/main/.../Service*`；`MainActivity` 无音频生命周期 | ☑（FF-24 第 6 条） |
| 音频不落盘 | `RingBuffer` 仅内存；`TempAudioAndroid` 只删不写；`Preprocess` 无 File 调用 | ☑（FF-24 第 1 条） |
| `cacheDir` 的 `audio_*` 冷启动 + 会话后清理 | `MainActivity.configureFlutterEngine` 冷启动清理；`API-01 §2.7` 提供会话后清理入口 | ☑ |
| 一键清除全部数据 | `MaintenanceRepoImpl.clearAllData()`（单事务） | ☑ 已在 `data_tests.dart` 验证 |
| 运行期抓包为 0 | 无任何 socket / http 依赖（依赖面见 `c04_dependency_deviation.md`） | ☑ 见 `docs/compliance/C-01_privacy_checklist.md` |
