# SPEC-C-04 构建、签名与发布

| 项 | 值 |
|---|---|
| 域 | `C` · 合规与工程基础 |
| 归属 | B |
| 状态 | ✅ v1.0 交付 |
| 上游依据 | 主方案 §8.3/§8.4（D10 冻结）、§12.6；`SPEC-00` §3.2（FF-16）、§3.8（FF-23）；`SPEC-C-01`（权限复核）；`API-05` §7（制品契约）；风险 R-14 |
| 依赖的 SPEC | `SPEC-C-01`（权限证据口径）、`SPEC-C-03`（配置同源）、`SPEC-C-05`（提交前测试门禁） |

## 1. 目标与范围

### 1.1 一句话目标

在 D10 代码冻结后，产出一个**可安装、可复核、签名材料不进仓库**的 release APK，并用逐项可勾选的发布前清单把权限、体积、静态分析与冻结状态一次性验完。

### 1.2 范围内（In Scope）

| # | 内容 |
|---|---|
| 1 | release keystore 的**生成与保管规范**（位置、口令、备份、交接） |
| 2 | `key.properties` **不得入库**，`.gitignore` 覆盖校验 |
| 3 | release 签名配置与 `flutter build apk --release --split-per-abi`（或说明为何用 universal APK） |
| 4 | 产物体积与权限复核（权限部分回到 `SPEC-C-01` §7 #1/#2） |
| 5 | `dart analyze` / `flutter analyze` **零 error** |
| 6 | **D10 代码冻结**（冻结后任何人不得提交代码，风险 R-14 的收口） |
| 7 | 发布前检查清单（逐项可勾选）与 APK 命名/归档规范（含版本号与构建日期） |
| 8 | 构建命令**必须在沙箱外普通终端执行**的成文约束 |

### 1.3 范围外（Out of Scope）

| 不做 | 归属 |
|---|---|
| 应用市场上架、商店素材、隐私政策页 | v1.0 不做（无上架计划） |
| iOS 构建与签名 | ❌ 不验证、不承诺（FF-23） |
| CI/CD 流水线搭建 | ❌ 不交付（10 天窗口内收益不足） |
| 代码混淆/加固（R8/minify 开启） | ❌ 不要求；若开启须另行验证（见 §10 #3） |
| 崩溃上报 / 分析埋点接入 | ❌ **禁止**（`API-05` §1.2） |
| 权限声明内容本身、测试用例编写 | `SPEC-C-01`、`SPEC-C-05` |

## 2. 功能行为

### 2.1 触发与前置条件

| 项 | 要求 |
|---|---|
| 触发 | D9 三模式实测通过（CP3）后进入出包；**D10 冻结后只允许出包与取证，不允许改代码** |
| 前置 | `SPEC-C-05` 的提交前测试门禁全绿；`SPEC-C-01` 权限复核通过；`SPEC-C-03` 旧值零残留搜索命中 0 |
| 前置 | keystore 已生成并完成异地备份；`key.properties` 已由负责人在本机创建（**不进仓库**）；环境已激活，**所有 `flutter`/Gradle 命令在沙箱外普通终端执行**（沙箱禁止管道捕获子进程输出） |

### 2.2 主流程（编号步骤）

1. 生成 release keystore（`keytool`，RSA 2048、有效期 ≥25 年），口令由 B 保管并书面登记。
2. 在**仓库外**保存 keystore；在同一非仓库位置写 `key.properties`，并在 `app/android/key.properties`（或约定的不入库路径）放置本机副本。
3. 校验 `.gitignore` 覆盖 `key.properties`、`*.jks`、`*.keystore`；执行 `git check-ignore` 与 `git ls-files` 双查。
4. 在 `app/android/app/build.gradle` 中读取 `key.properties` 配置 `signingConfigs.release`；**debug 签名不得用于提交产物**。
5. 跑静态分析与提交前测试集：`dart analyze` 与 `flutter analyze` 的 **error 数必须为 0**；再跑 `SPEC-C-05` 的提交前集合（单元 + 对齐 + 隐私回归）。
6. 出包：`flutter build apk --release --split-per-abi`。
7. 对每个 ABI 产物执行：`apksigner verify`、`aapt dump badging`（权限复核回 `SPEC-C-01`）、`sha256`、体积记录。
8. 按 §4 命名规范重命名并归档到 `release/`，填写发布前检查清单（§7 附表），打冻结 tag 并记录时间戳；此后**任何人不得提交代码**（R-14 收口）。

### 2.3 状态与状态迁移

```
PRE_FREEZE ──冻结 tag──▶ FROZEN ──出包──▶ BUILT ──复核通过──▶ VERIFIED ──归档──▶ RELEASED
     │                       │               │
     └──仍有代码改动──────────┘               └──复核失败──▶ 回到 FROZEN（只允许重出包/重新取证，不允许改代码）
```

| 状态 | 含义 | 允许的下一状态 |
|---|---|---|
| `PRE_FREEZE` | 仍在修代码/跑测试 | `FROZEN` |
| `FROZEN` | 已打冻结 tag，代码不变 | `BUILT` |
| `BUILT` | APK 已产出，未复核 | `VERIFIED`、`FROZEN`（复核失败重出包） |
| `VERIFIED` | 权限/体积/签名/分析全部通过 | `RELEASED` |
| `RELEASED` | 归档完成，清单已签字 | 终态 |

### 2.4 边界条件

- **冻结后不得提交代码**（`PLAN-00` §4）：允许的动作只有「重新出包」「重新取证」「改文档」；任何 `.dart`/`.kt`/`build.gradle` 改动都会使 `FROZEN` 失效。
- **`key.properties` 与 keystore 永不入库**：包括截图、日志、粘贴到聊天记录；keystore 丢失不可恢复（v1.0 未用商店签名服务），备份至少两份异地。
- **`--split-per-abi` 是默认方案**：三个 ABI 产物各自具备独立权限证据与 `sha256`；若因现场安装便利改用 universal APK，必须在检查清单中写明理由，并**重新取证**。
- **体积只记录不设阈值**（APK 无编造上限；唯一硬阈值是模型制品 FF-16 INT8）；`flutter analyze` 的 `info`/`warning` 不阻塞但须记录条数，`error` 一条即阻塞。

## 3. 接口契约

本功能不产生运行时接口，只有命令行工具契约：

| 方向 | 工具/命令 | 输入 | 输出 | 错误码 |
|---|---|---|---|---|
| 构建 | `flutter build apk --release --split-per-abi` | 源码 + assets + `key.properties` | 每 ABI 一个 release APK | 非 0 → 停止，不归档 |
| 静态分析 | `dart analyze` / `flutter analyze` | 源码 | 诊断列表 | 出现 `error •` → 判不通过 |
| 签名核验 | `apksigner verify --print-certs` | APK | 签名者与方案版本 | 非 0 或签名者不符 → 判不通过 |
| 权限核验 | `aapt dump badging` | APK | `uses-permission` 列表 | 见 `SPEC-C-01` §7 #1/#2 |
| 哈希 / 冻结 | `Get-FileHash -Algorithm SHA256`；`git log --since=<freeze-ts> --oneline` | APK / 时间戳 | 64 hex / 提交列表 | hex 长度 != 64、或提交非空 → 判不通过 |

## 4. 数据契约

| 产物 | 命名规范 | 必备随附信息 |
|---|---|---|
| APK | `AcouDiet-v<版本号>-<yyyyMMdd>-<abi>.apk` | `sha256`、字节数、构建类型、ABI |
| 模型制品 | 随 `API-00` §3.4 的 `<name>_<version>.tflite` | `sha256` 记录在 `model_card.json`（`API-05` §7） |
| 归档索引 | `release/RELEASE_<版本号>_<yyyyMMdd>_<flavour>.md` | 字段见下表。**一份归档索引只描述一个风味**（表内有 `flavour` 行），因此文件名必须带风味：`ADR-48` 之前两份索引互相覆盖，v1.3.0 的 agent 记录就是这样丢的 |
| 发布前检查清单 | `release/pre_release_checklist_<yyyyMMdd>.md` | 逐项打勾 + 签字 |

**归档索引字段**：

| 字段 | 类型 | 值域 | 可空 |
|---|---|---|---|
| `appVersion` | string | 形如 `1.0.0+1`（与 `pubspec.yaml` 一致） | 否 |
| `apkPath` | string | `release/...` | 否 |
| `apkSha256` | string | 64 hex | 否 |
| `apkBytes` | int | `>0`（**只记录，不设上限**） | 否 |
| `tfliteBytes` | int | `≤2.5 MB`（FF-16） | 否 |
| `permissions` | string[] | **按风味**（`ADR-44`）：`offline` 必须为 `[android.permission.RECORD_AUDIO]`；`agent` 必须为 `[android.permission.RECORD_AUDIO, android.permission.INTERNET]`。两档都**不得**多出任何第三项 | 否 |
| `freezeCommit` | string | git commit 短哈希 | 否 |
| `analyzeErrors` | int | 必须为 `0` | 否 |

## 5. 参数与常量

| 项 | 引用 |
|---|---|
| 平台 / SDK 版本 / 包名 / 应用名 | `SPEC-00` §3.8（FF-23），**不在本文档复写数值** |
| 模型体积上限与权限集合 | `SPEC-00` §3.2（FF-16）、§3.9（FF-24 第 4/5 条，**`ADR-44` 已按风味修订** + 第 8/9 条）+ `SPEC-C-01` §7 #1a/#1b/#2 |
| 制品命名与 hash 闭环 | `API-00` §3.4、`API-05` §7.1 |

## 6. 异常与降级

| 异常 | 检测方式 | 处理 | 用户可见表现 |
|---|---|---|---|
| `flutter analyze` 出现 error | 命令输出含 `error •` | **停止出包**，修完重跑；冻结后出现 error 则冻结失效并记录 | 无（构建期） |
| `key.properties` 缺失 | 构建报签名缺失 | 在本机重建该文件；**不得把它加进仓库** | 无 |
| keystore 口令遗失 | 构建失败 | 只能用备份；若备份也丢失 → 更换签名（会改变升级链），登记 §10 | 无 |
| 某 ABI 构建失败 | 产物缺失 | 允许只交付可构建的 ABI，但**必须在归档索引中写明缺失项** | 相应设备无法安装 |
| 重构后 `sha256` 变化 | 哈希比对 | 重新取证并更新归档索引；旧证据标记过期 | 无 |
| 冻结后有人提交代码 | `git log --since` 非空 | 冻结失效，重跑测试门禁后重新冻结与出包 | 无 |

## 7. 验收标准（可机器判定）

| # | 判据 | 验证方式（命令/测试名） | 通过阈值 |
|---|---|---|---|
| 1 | 静态分析零 error（`flutter analyze` + `dart analyze`） | 两条命令 | 各自退出码 0；`error •` 与 `error` 计数均 == 0（`info`/`warning` 计数须记录） |
| 2 | release 构建成功 | `flutter build apk --release --split-per-abi` | 退出码 0；每个目标 ABI 产物存在 |
| 3 | 签名可用且正确 | `apksigner verify --print-certs <apk>` | 退出码 0；签名者 CN 与 keystore 一致 |
| 4 | 签名材料未入库 | `git check-ignore -v app/android/key.properties`；`git ls-files` | 前者退出码 0（命中忽略）；后者对 `key.properties`/`*.jks`/`*.keystore` **命中行数 == 0** |
| 5 | 权限复核通过 | 复用 `SPEC-C-01` §7 #1a/#1b/#2 命令（**按风味**） | `offline`：无 `INTERNET`，权限集合 == `{RECORD_AUDIO}`；`agent`：集合恰为 `{RECORD_AUDIO, INTERNET}`（`ADR-44`） |
| 6 | 模型体积达标 | `Get-Item app/assets/models/*.tflite` | `≤2.5 MB`（FF-16） |
| 7 | 命名与归档合规 | 断言 `release/AcouDiet-v*-<yyyyMMdd>-<abi>.apk` 存在 | 每个交付 ABI 均有匹配文件；`sha256` 长度 64 |
| 8 | 归档索引字段齐全 | 断言 §4 字段全部出现 | 缺失字段数 == 0；`analyzeErrors == 0` |
| 9 | D10 冻结生效 | `git log --since=<freeze-ts> --oneline`；`git tag -l 'v1.0.0-freeze'` | 提交行数 == 0；tag 存在 |
| 10 | 检查清单完成 | `release/pre_release_checklist_<yyyyMMdd>.md` 逐项打勾 | 全部勾选 + B/C 签字 |

**§7 附表：发布前检查清单（逐项可勾选）**

| # | 检查项 | 判据来源 | ☐ |
|---|---|---|---|
| 1 | `flutter analyze` / `dart analyze` 零 error | §7 #1 | ☐ |
| 2 | `SPEC-C-05` 提交前测试集全绿、`SPEC-C-03` 旧值零残留命中 0 | `SPEC-C-05` §7、`SPEC-C-03` §7 #3 | ☐ |
| 3 | release APK 的权限集合符合其风味 | `SPEC-C-01` §7 #1a/#1b/#2 | `offline`：无 `INTERNET`、仅 `RECORD_AUDIO`；`agent`：恰为 `{RECORD_AUDIO, INTERNET}`（`ADR-44`）—— **两个风味都要出包、都要留证** | ☐ |
| 4 | 签名有效且非 debug 签名 | §7 #3 | ☐ |
| 5 | `key.properties`/keystore 未入库 | §7 #4 | ☐ |
| 6 | 模型 `≤2.5 MB`（FF-16） | §7 #6 | ☐ |
| 7 | 三 ABI（或声明的子集）产物齐备、命名与归档路径符合 §4 | §7 #2/#7 | ☐ |
| 8 | 归档索引字段齐全、`analyzeErrors == 0` | §7 #8 | ☐ |
| 9 | 飞行模式全流程核对表通过 | `SPEC-C-01` §7 #4 | ☐ |
| 10 | 冻结 tag 已打、冻结后零提交 | §7 #9 | ☐ |
| 11 | 清单完成（B/C 签字）与版本号一致（§4 `appVersion`） | §7 #10 | ☐ |
| 12 | 材料齐备（PPT / 演示视频 / 测试报告 / 同意书扫描件 / `aapt` 隐私截图） | 主方案 §12.6 | ☐ |

## 8. 非功能约束

| 项 | 约束 |
|---|---|
| 可复现 | 同一源码 + 同一 `key.properties` → 权限、体积、哈希记录一致；构建命令写入归档索引 |
| 安全 | keystore 口令不写入任何入库文件；`key.properties` 不入库（含截图与聊天记录） |
| 体积 | **只记录不设阈值**（禁止编造）；模型制品受 FF-16 约束 |
| 网络与执行环境 | 构建期允许下载依赖（Gradle/pub），**运行期不得有网络出口**（`API-05` §1.2）；所有 `flutter`/Gradle 命令**必须在沙箱外普通终端执行** |
| 无障碍 | 不涉及 |

## 9. 裁剪与未做

| 项 | 决定 |
|---|---|
| iOS 构建与签名 | ❌ 架构兼容但不验证、不承诺（FF-23） |
| 应用市场上架与商店素材、CI/CD 流水线 | ❌ v1.0 不交付 |
| 代码混淆/加固（R8、minify） | ❌ 不要求；若开启须重跑 `SPEC-C-05` 全部门禁（见 §10 #3） |
| 模型热更新通道 | ❌ 永久禁止（`API-05` §3.1 `R-OUT-3`） |
| 崩溃上报/埋点、`X-03` CSV 导出 | ❌ 禁止 / 不交付 → 发布说明中不得宣称可导出 |

## 10. 开放问题

| # | 问题 | 影响 | 待谁拍板 |
|---|---|---|---|
| 1 | 最终交付形态：`--split-per-abi` 三份 vs universal 一份 | 影响现场安装便利性与取证工作量；**若改 universal 必须重新取证** | B + C |
| 2 | keystore 的保管责任人、口令交接、备份位置与冻结 tag 命名规范（本文档取 `v1.0.0-freeze`） | 影响长期可维护性与 §7 #9 判据 | B（团队知会） |
| 3 | 是否开启 R8/minify 与资源压缩 | 一旦开启，`SPEC-C-05` 全部门禁须重跑；且可能影响 `tflite_flutter` 反射路径 | B |
| 4 | APK 体积是否需要内部提醒线；`arm64-v8a` 之外的 ABI 是否为必需交付 | 影响归档索引口径与现场兼容性 | B + C |

**文档结束**
