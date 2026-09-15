# SPEC-C-01 权限最小化与「无网络权限」可验证

| 项 | 值 |
|---|---|
| 域 | `C` · 合规与工程基础 |
| 归属 | B |
| 状态 | ✅ 交付（`ADR-44` **修订**：判据按**风味**重写） |
| 上游依据 | 主方案 §6.1 措施 4/5、§10.2 必现图表第 7 项、§9.2 现场 SOP；`SPEC-00` §3.9（FF-24 第 4/5/8 条）、§3.10（FF-25）、§3.11（FF-26）；`API-05` §1/§3.1/§10/§12/§13 |
| 依赖的 SPEC | 无（`SPEC-C-04` 反向复用本功能的权限复核口径；`SPEC-C-06` 复用本功能的证据链形式） |

> # ✅ `ADR-44` 修订摘要（本文件是**判据**文件，修订必须最先落地）
>
> | 原判据 | 现行判据 |
> |---|---|
> | 「release APK 不声明 `INTERNET`」 | **`offline` 风味**不声明；**`agent` 风味**声明且**只**多这一项 |
> | 「权限集合 == `{RECORD_AUDIO}`」 | `offline` == `{RECORD_AUDIO}`；`agent` == `{RECORD_AUDIO, INTERNET}` |
> | 「全仓搜索 `http`/`dio`/`socket`/`WebSocket`/`url_launcher` 命中 == 0」 | **白名单目录制**：命中必须**全部**落在 `app/lib/data/net/**`、`app/lib/domain/agent/**`、`app/android/.../agent/**` 之内；白名单外 == 0。**这条比原来更强**：原来的判据只能证明"没有网络"，新的判据还能证明"网络只在被设计的位置" |
> | （无） | 🆕 「`AccessibilityService` 与 `BIND_ACCESSIBILITY_SERVICE` 命中 == 0」（`FF-26i`） |
> | （无） | 🆕 「`deepseek-flash` 在 Dart/Kotlin 源码中命中 == 0」（`FF-26h`） |
>
> **`ADR-44` 的诚实边界**：`offline` 风味的证据链**只对 `offline` 风味成立**。若只出 `agent` 包，
> 本 SPEC 的原判据**一条都不适用** —— 所以 `PLAN-C-01` 的验收要求**两个风味都出包、都留证**。

## 1. 目标与范围

### 1.1 一句话目标

把「音频不出设备」这条隐私主张，从口号变成**可复核的证据链**：`offline` 风味合并后的 Manifest 只声明录音权限、不声明联网权限（用 `aapt dump badging` 留证），`agent` 风味恰好只多一个 `INTERNET`；再用「网络调用只许落在三个白名单目录」与「飞行模式下核心链路全可用」两道防线兜住。

### 1.2 范围内（In Scope）

| # | 内容 | 产物 |
|---|---|---|
| 1 | **两个风味**的合并后 `AndroidManifest.xml` 权限声明裁减与复核 | `offline` = `{RECORD_AUDIO}`；`agent` = `{RECORD_AUDIO, INTERNET}` |
| 2 | `aapt dump badging` 证据产出与归档（PPT 必现图表第 7 项，**取证对象 = `offline` 风味**） | **两份**证据文本 + 两个 APK 的 `sha256` |
| 3 | 网络调用**白名单目录**判据（口径见 §7 #3） | `tool/check_network_boundary.py --strict`，白名单外命中 0；**自带负控** |
| 4 | 音频出境判据（`FF-24` 第 8 条） | `tool/check_audio_egress.py --strict`，静态 + 运行时两项；**自带负控** |
| 5 | 飞行模式全流程实测（检测→记录→报告→三种 Demo 模式；**`agent` 风味下跑**） | 逐项核对表 + 截图（`agent` 的 Agent 页允许显示降级态） |
| 6 | 「开启网络会失去什么」成文说明（引 `API-05` §10 的四条对账） | 本文档 §2.4 与 §8 |
| 7 | `API-05` §11「数据可携带性」缺口登记为已知限制 | 本文档 §9 与 §10 |
| 8 | 发布前权限复核口径（供 `SPEC-C-04` 检查清单复用） | 本文档 §7 判据 #1a/#1b/#2 |

### 1.3 范围外（Out of Scope）

| 不做 | 归属 |
|---|---|
| 录音权限申请交互与「去设置」引导 | `SPEC-P-01`（`API-01` §2.2） |
| keystore、签名配置、出包命令 | `SPEC-C-04` |
| 同意书、伦理归档 | `SPEC-C-02` |
| 数据导出/可携带性实现（含「复制为文本」方案） | `X-03`、`API-05` §11，v1.0 不交付 |
| 数据库加密 | `API-05` §5.7（v1.0 明确不做） |
| 云端同步协议 | `API-05` §9（状态 `DISABLED`，任何 PLAN 不得引用为任务） |

## 2. 功能行为

### 2.1 触发与前置条件

| 项 | 要求 |
|---|---|
| 触发时机 | D4 出包后立即执行一次（当日硬验收「★无 INTERNET 权限」）；D9/D10 release 出包后**必须重跑并替换存档** |
| 前置 | 环境已激活（`_toolchain/acoudiet-env.ps1`）、`ANDROID_HOME` 下存在 build-tools（提供 `aapt`）、存在可解析的 APK |
| 前置 | D4 允许用 debug 包取证（Manifest 合并结果与 release 同源），但**存档必须标明构建类型**，D10 以 release 包为准 |
| 前置 | 构建与 `flutter` 命令**必须在沙箱外的普通终端执行**（沙箱禁止管道捕获子进程输出） |

### 2.2 主流程（编号步骤）

1. 打开 `app/android/app/src/main/AndroidManifest.xml`，删除模板默认声明的 `android.permission.INTERNET`（Flutter 调试模板会注入），确认无相机/位置/通讯录/`READ_MEDIA_*` 等声明。
2. 检查 `app/android/app/src/debug/AndroidManifest.xml` 与 `profile/AndroidManifest.xml`：其 `INTERNET` 声明**只允许存在于 debug/profile 变体**，release 合并结果不得含该权限。
3. 逐项审查 `app/pubspec.yaml` 及传递依赖：任何插件在自身 Manifest 中声明 `INTERNET` 均视为**网络出口**，必须移除该依赖（不得仅用 `tools:node="remove"` 掩盖）。
4. 出包（命令见 `SPEC-C-04`；`flutter` 命令在沙箱外普通终端执行）。
5. 定位 `aapt` 并对其执行 `dump badging`，把完整输出重定向到证据文件。
6. 对 APK 计算 `sha256` 并写入证据文件（与 `API-05` §7 制品契约的记录方式一致）。
7. 执行 §7 #3 的代码层 5 关键词搜索，把输出（命中行数 0）留存。
8. 手机开飞行模式，按 §7 #4 的逐项核对表跑完整流程（检测→记录→报告→三种 Demo 模式），截图归档。
9. 把证据文件、截图、核对表放入 `records/compliance/C-01/`（归档规范见 `PLAN-C-01` §1），并在 PPT 第 7 项图表位置引用。

### 2.3 状态与状态迁移

**无状态。** 本功能不引入任何运行时状态机，也不新增运行时组件；它是一条**构建期 + 验收期的证据链**。
证据本身有三个生命周期位置，供 `PLAN-C-01` 跟踪：

| 状态 | 含义 | 允许的下一状态 |
|---|---|---|
| `CAPTURED_DEBUG` | D4 用 debug 包取的权限证据 | `REFRESHED_RELEASE` |
| `REFRESHED_RELEASE` | D9/D10 用 release 包重跑并替换存档（**唯一可用于提交/答辩的状态**） | — |
| `STALE` | release 包重新构建后未重跑 | `REFRESHED_RELEASE` |

### 2.4 边界条件

- **只有一处允许声明 `INTERNET`**：Flutter 模板生成的 debug/profile 变体。若 release 合并结果出现该权限，本功能判不通过。
- **「开启网络会失去什么」必须成文**（引 `API-05` §10 三条，答辩口径一致）：
  1. 失去「**APK 连联网权限都没有**」这条最强隐私证据（主方案 §6.1 措施 4、§10.2 第 7 项、答辩 Q&A）；
  2. 失去**飞行模式下的完整功能演示**（主方案 §9.2 现场 SOP 第 2 步）；
  3. 失去「**无后端 = 无一致性/无重试/无冲突**」的工程简化（`API-05` §8：无超时、无断线重连、无最终一致性、无冲突解决、无幂等键）。
- **v1.0 不存在网络出口**：无 HTTP 客户端、无 WebSocket、无 SDK 上报、无崩溃收集、无分析埋点；类别 7–9 制品只有入境方向（`API-05` §3.1 `R-OUT-1`~`R-OUT-3`）。
- **模型更新只能发新 APK**，不接受热更新（`API-05` §3.1 `R-OUT-3` 的实际代价）。
- **数据可携带性缺口**（`API-05` §11）：v1.0 无任何导出途径，卸载即丢数据；此为已知限制，见 §9 与 §10。
- 若某依赖的 Manifest 声明无法去除，须在 §10 登记并走 `SPEC-C-03` 变更传播流程，**不得默认接受**。

## 3. 接口契约

> 本功能是构建期/验收期功能，运行时接口仅涉及权限查询与会话启动的既有契约；完整签名以 `docs/*/docs_api/` 为准。

| 方向 | 接口 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| Dart → Kotlin | `requestPermission()`（`API-01` §2.2） | `{}` | `{granted, permanentlyDenied}` | 拒绝是正常返回值，非错误 |
| Dart → Kotlin | `startSession()`（`API-01` §2.3） | 会话参数 | 会话摘要 | `ACD-PERM-001` / `ACD-PERM-002` |
| Dart → Kotlin | `getDiagnostics()`（`API-01` §2.8） | `{}` | 诊断快照（含权限与清理计数） | 无 |
| **出网** | ✅ **`ADR-44` 修订**：`POST {base_url}/chat/completions`，**仅** `agent` 风味、**仅** `G-01` 的 `DeepSeekClient` | 结构化 JSON（`FF-26d` 白名单，构造点唯一 = `G-02` 的 `AgentPromptBuilder`） | SSE 流（`data:` 行）/ JSON | `ACD-AGENT-001`~`ACD-AGENT-010`（`API-05` §8 第二张表）。**白名单目录之外的出网仍然"不存在"**，判据见 §7 #3 |

## 4. 数据契约

证据产物为**纯文本/截图**，不进入运行时数据流，**无对应 `docs/common/docs_api/schemas/*.schema.json`**（本功能不新增 schema 文件）。

| 证据文件 | 必备字段（文本行） | 值域 |
|---|---|---|
| `aapt_badging_<yyyyMMdd>_<buildType>.txt` | `package: name=`、`uses-permission:` 全列表、`sdkVersion`、`targetSdkVersion` | 文本，原样保存 `aapt` 输出 |
| `apk_sha256.txt` | APK 相对路径、`sha256`（64 hex）、字节数、构建类型、构建日期 | hex 长度必须为 64 |
| `code_scan_no_network.txt` | 搜索命令原文、5 个关键词、命中行数 | 命中行数必须为 `0` |
| `flight_mode_checklist.md` | 逐项核对表（见 §7 #4）+ 截图文件名 | 全部勾选 |
| `ppt_fig_07_no_internet.png` | `aapt` 输出截图（PPT 第 7 项图表） | 图片 |

## 5. 参数与常量

| 项 | 引用 | 说明 |
|---|---|---|
| 交付平台 / `minSdk` / `targetSdk` / `compileSdk` / 包名 | `SPEC-00` §3.8（FF-23） | **不在本文档复写数值** |
| 「音频不落盘」「临时文件清理」「无 BLOB」「不申请 `INTERNET`」「仅 `RECORD_AUDIO`」「无后台常驻」「一键清除」 | `SPEC-00` §3.9（FF-24 七条） | 本功能负责其中第 4、5 条的**证据化** |
| 宣传口径与术语禁令 | `SPEC-00` §3.10（FF-25） | 证据文件名与 PPT 文案不得出现绝对化表述 |
| 权限常量 | `android.permission.RECORD_AUDIO`（唯一允许） | 与 `android.permission.INTERNET`（禁止）为固定字面量 |
| 握手 **15 字段**（`ADR-21`；原 ~~12~~） | `API-00` §3.6 | 与本功能无关，但同属「启动即失败快」家族 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| 找不到 `aapt` | `Get-Command aapt` 失败 | 回退 `apkanalyzer manifest permissions` 或 `aapt2 dump badging`；仍失败则改用 Android Studio「Analyze APK」并人工截图 | 无（构建期） |
| release 包含 `INTERNET` | §7 #1 命中 | **判不通过**，定位来源依赖并移除；禁止用 `tools:node="remove"` 掩盖真实网络调用 | 无 |
| 依赖自带网络调用 | §7 #3 命中 | 移除该依赖；确需保留则登记 §10 并走 `SPEC-C-03` 传播 | 无 |
| 搜索命中来自第三方 NOTICE/许可文本 | 人工判读命中行 | 仅当位于 `docs/` 或 `LICENSE`/`NOTICE` 且不含可执行代码时登记白名单；**代码与 `pubspec.yaml` 不接受白名单** | 无 |
| 飞行模式下某 Demo 模式失败 | §7 #4 核对表 | 属 `M-01`~`M-03` 缺陷，按 `PLAN-M-*` 处置；不改本功能判据 | 现场演示降级到 Mode C |
| D10 重跑证据与 D9 不一致 | `sha256` 比对 | 以最新 release 包证据覆盖，旧证据标记 `STALE` 保留 | 无 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1a | **`offline` 风味**不声明联网权限 | `aapt dump badging dist/*offline*.apk` 重定向后 `Select-String 'uses-permission'` | 输出**不含** `android.permission.INTERNET` |
| 1b | **`agent` 风味**的额外权限恰好是 `INTERNET` 一项 | 同 #1a，对象为 `dist/*agent*.apk` | 权限集合**逐字等于** `{android.permission.RECORD_AUDIO, android.permission.INTERNET}` |
| 2 | 权限集合最小（两档都查） | 同 #1a/#1b 的 `uses-permission` 行 | `offline` == `{RECORD_AUDIO}`；`agent` == `{RECORD_AUDIO, INTERNET}`；两档均无相机/位置/通讯录/`READ_MEDIA_*`/`VIBRATE`；**`offline` 的权限集合与 `ADR-44` 之前的任何一版逐字相等**（这条是"没有退步"的判据） |
| 3 | 网络调用只在**白名单目录**内 | `python tool/check_network_boundary.py --strict` | 命中**全部**落在 `app/lib/data/net/**`、`app/lib/domain/agent/**`、`app/android/app/src/main/kotlin/com/acoudiet/app/agent/**`；白名单外命中数 **== 0**；脚本 `--selftest` 的负控（白名单外放一个 `HttpClient`）必须变红 |
| 3b | **音频不出境**（`FF-24` 第 8 条） | `python tool/check_audio_egress.py --strict` | ① 静态：网络层不得引用 `Float32List`/`Uint8List`/音频类型；② 运行时：`app/tool/agent_tests.dart` 断言每个请求体是纯结构化 JSON 且无长度 ≥1024 的数值数组。负控必须变红 |
| 4 | 飞行模式全流程可用 | 人工核对表（下表），逐项打勾 + 截图 | 全部 7 项通过，无异常弹窗、无加载失败 |
| 5 | 证据文件存在且自洽 | 断言 §4 的 5 个文件存在；`apk_sha256.txt` 中 hex 长度 64 | `Test-Path` 全真；hex 长度 == 64 |
| 6 | 制品体积约束（仅模型） | `Get-Item app/assets/models/*.tflite` | `≤6 MB`（`SPEC-00` §3.2 FF-16；`ADR-21` 起按卡片申报档位） |
| 7 | 权限证据可复核 | 对同一 APK 重跑 `aapt` 两次，比对 `uses-permission` 行 | 两次输出逐行相等 |
| 8 🆕 | **无无障碍代操作**（`FF-26i`） | 全仓搜索 `AccessibilityService` 与 `BIND_ACCESSIBILITY_SERVICE` | 命中数 **== 0**；负控：在 Kotlin 里加一行该字符串必须变红 |
| 9 🆕 | **模型名不硬编码**（`FF-26h`） | 搜索 `deepseek-flash` 在 `app/lib/**` 与 `app/android/app/src/main/kotlin/**` | 命中数 **== 0**（允许在 `shared/feature_config.json`、`app/assets/feature_config.json` 与 `docs/**`） |
| 10 🆕 | **Key 不出现在可外发的表面** | 搜索 `sk-` 于 `getDiagnostics()` 输出、日志与 `records/compliance/**` 的截图证据 | 命中数 **== 0** |

**§7 #4 飞行模式逐项核对表**（唯一允许的人工项，必须逐项给结论）：

| 序 | 检查项 | 期望 | ✅ |
|---|---|---|---|
| 1 | App 冷启动（飞行模式，无 Wi-Fi） | 进入首页，无网络错误提示 | ☐ |
| 2 | 检测会话（Mode A 实时） | 可开始/停止，未确认预测有刷新 | ☐ |
| 3 | Demo Mode B（示例音频注入环形缓冲） | 走同一条推理管线出结果 | ☐ |
| 4 | Demo Mode C（预置 7 天报告） | 报告页数字自洽 | ☐ |
| 5 | 记录落库与列表 | 新增记录可见，无写入失败提示 | ☐ |
| 6 | 健康报告页与四维下钻 | 正常渲染，无请求超时类提示 | ☐ |
| 7 | 系统层网络状态 | 飞行模式全程保持开启（截图含状态栏） | ☐ |

## 8. 非功能约束

| 项 | 约束 |
|---|---|
| 隐私 | 本功能是 FF-24 第 4/5 条的证据化手段，属**不可交易约束**；任何引入网络出口的改动自动失效 |
| 运行时开销 | **零**：不新增线程、不新增权限、不新增 Service |
| 功耗 | 无后台常驻（FF-24 第 6 条），检测由用户主动发起 |
| 体积 | APK 体积**只记录不设阈值**（禁止编造），仅模型制品受 FF-16 约束 |
| 无障碍 | 不涉及 |

## 9. 裁剪与未做

| 项 | 决定 | 依据 |
|---|---|---|
| CSV / 数据导出 | ❌ 不交付（入口保留但置灰标 `v1.1`） | `X-03` |
| **数据可携带性** | ❌ v1.0 无任何导出途径，卸载即丢数据；须在 PPT「后续工作」列出 SAF 导出 | `API-05` §11 |
| 数据库加密 | ❌ v1.0 不做（设备级 FBE 已提供基础保护） | `API-05` §5.7 |
| 云端同步 / 崩溃上报 / 分析埋点 | ❌ 不交付，规范状态 `DISABLED` | `API-05` §9 |
| 🆕 **云端推理** | ✅ **已交付**（`ADR-44`），但**仅 `agent` 风味**、**默认关闭**、**音频零出境**；`offline` 风味**没有**这条能力 | `API-05` §13、`SPEC-G-01`、`SPEC-C-06` |
| 🆕 **代下单 / 无障碍代操作** | ❌ **明文禁止**（不是"未实现"）：`FF-26i`。App 只做检索 URL 交接 | `SPEC-G-03` §9、`SPEC-U-07` §9 |
| 模型热更新 | ❌ 不交付（R-OUT-3 禁止运行时从网络更新） | `API-05` §3.1 |
| 数据库 BLOB 音频列 | ❌ 永不允许 | FF-24 第 3 条 |

> `X-03` 与 `API-05` §11 是**两条不同的缺口**：前者是「没做导出功能」，后者是「合规上缺少取得与转移个人信息的途径」。两者都不得写成「已合规」。

## 10. 开放问题

| # | 问题 | 影响 | 待谁拍板 |
|---|---|---|---|
| 1 | 证据归档目录 `records/compliance/` 为新增目录，`SPEC-00` §1 的目录表未列该类目 | 归档位置缺乏权威依据 | C + 文档负责人 |
| 2 | 全局搜索口径是否包含 `docs/`（现有 `API-05` 正文含 `http` 讨论文字） | 影响 #3 判据能否为 0 | A+B |
| 3 | `tools:node="remove"` 是否一律禁止（本文档取「一律禁止」） | 影响第三方依赖取舍 | B |
| 4 | D4 的 debug 包证据是否足以支撑当日硬验收，或必须等 release | 影响 D4 验收判定 | B |
| 5 | 飞行模式证据的载体（截图 vs 录屏） | 影响归档体积与可复核性 | C |

**文档结束**
