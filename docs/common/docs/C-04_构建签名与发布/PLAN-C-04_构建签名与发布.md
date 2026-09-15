# PLAN-C-04 构建、签名与发布

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-C-04` |
| 负责 | B（主责）；C 协助归档索引与材料清单 |
| 目标日 | **D9→D10**（D9 演练出包，D10 冻结后定稿） |
| 前置依赖 | `PLAN-C-01` 权限复核口径；`PLAN-C-05` 提交前测试门禁；`PLAN-C-03` 旧值零残留；keystore 与 `key.properties` 就位；**构建须在沙箱外普通终端执行** |
| 预估工时 | 6 h（B 4.5 h + C 1.5 h） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | 仓库外 keystore（位置由 B 登记，**不入库**） | release 签名密钥 + 口令保管记录 |
| 2 | 本机 `key.properties`（**不入库**） | `storeFile`/`storePassword`/`keyAlias`/`keyPassword` |
| 3 | `app/android/.gitignore`（或根 `.gitignore` 的相应条目） | 覆盖 `key.properties`、`*.jks`、`*.keystore` |
| 4 | `app/android/app/build.gradle` | `signingConfigs.release` 配置（**读本机 properties，不硬编码口令**） |
| 5 | `release/AcouDiet-v1.0.0-<yyyyMMdd>-<abi>.apk` | 交付 APK（每 ABI 一份） |
| 6 | `release/RELEASE_1.0.0_<yyyyMMdd>_<flavour>.md` | 归档索引（字段见 `SPEC-C-04` §4；**必须带风味**，`ADR-48`） |
| 7 | `release/pre_release_checklist_<yyyyMMdd>.md` | 发布前检查清单（14 项，逐项打勾 + 签字） |
| 8 | `release/apk_sha256.txt` | 各 ABI 的 64 位 hex 与字节数 |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 生成 keystore 并完成两份异地备份；登记保管责任人 | 交付物 #1 | 1 h | — |
| 2 | 写 `.gitignore` 条目并双查（`check-ignore` + `ls-files`） | 交付物 #2 #3 | 0.5 h | #1 |
| 3 | 配置 `signingConfigs.release` | 交付物 #4 | 1 h | #2 |
| 4 | 跑 `dart analyze` / `flutter analyze` 清零 error | 分析输出存档 | 1 h | 全代码冻结候选提交 |
| 5 | D9 演练出包 + 权限/体积/签名取证 | APK + 证据 | 1 h | #3、`PLAN-C-01` |
| 6 | D10 打冻结 tag、正式出包、归档索引、清单签字 | 交付物 #5 #6 #7 #8 | 1.5 h | #4 #5 |

## 3. 技术方案

**签名配置要点（不在此复制口令）**：`build.gradle` 从 `key.properties` 读取四个字段；缺失时**构建失败**而不是静默回退 debug 签名（避免把 debug 包当 release 提交）；`signingConfigs.release` 绑定到 `buildTypes.release`；`minifyEnabled` 保持现状（未开启，见 `SPEC-C-04` §10 #3）。

**出包与取证骨架（PowerShell，≤30 行；必须在沙箱外普通终端执行）**：

```powershell
. D:\Desktop\Food\_toolchain\acoudiet-env.ps1
# 1) 静态分析（error 计数必须为 0）
flutter analyze | Tee-Object docs\release\analyze_$(Get-Date -Format yyyyMMdd).txt
(Select-String -Path docs\release\analyze_*.txt -Pattern 'error •').Count   # 期望 0
# 2) 出包
flutter build apk --release --split-per-abi
# 3) 每 ABI 取证
$stamp = Get-Date -Format yyyyMMdd
Get-ChildItem app\build\app\outputs\flutter-apk\app-*-release.apk | ForEach-Object {
  $abi = ($_.BaseName -replace '^app-','' -replace '-release$','')
  $dst = "docs\release\AcouDiet-v1.0.0-$stamp-$abi.apk"
  Copy-Item $_.FullName $dst -Force
  "$abi sha256=$((Get-FileHash $dst -Algorithm SHA256).Hash) bytes=$((Get-Item $dst).Length)" |
    Add-Content docs\release\apk_sha256.txt
  & apksigner verify --print-certs $dst
}
# 4) 冻结态复核
git log --since='<freeze-ts>' --oneline   # 期望 0 行
```

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `flutter analyze` / `dart analyze` | 命令 | `error` 计数 == 0 | 每次提交前、D10 |
| release 构建 | 命令 | 退出码 0；目标 ABI 产物存在 | D9、D10 |
| 签名核验 | 命令 | `apksigner verify --print-certs` 退出码 0；CN 一致 | D9、D10 |
| 签名材料未入库 | 命令 | `check-ignore` 命中；`git ls-files` 命中 0 | 每次提交前、D10 |
| 权限复核 | 命令 | 复用 `SPEC-C-01` §7 #1/#2 | D9、D10 |
| 体积复核 | 命令 | `tflite ≤ 2.5 MB`（FF-16）；APK 体积仅记录 | D9、D10 |
| 命名与归档 | 命令 | APK 文件名匹配 `AcouDiet-v1.0.0-<yyyyMMdd>-<abi>.apk`；`sha256` 长度 64 | D10 |
| 冻结态 | 命令 | 冻结后提交行数 == 0；tag 存在 | D10 |
| 安装冒烟 | 人工/仪器 | 真机安装成功、冷启动进入首页、握手不报 `ACD-CFG-001` | D9、D10 |

## 5. 完成定义（DoD）

- [ ] `SPEC-C-04` 第 7 节 11 条判据全部通过
- [ ] keystore 生成、两份异地备份、责任人登记完成
- [ ] `key.properties`/`*.jks`/`*.keystore` 未入库（`git ls-files` 命中 0）
- [ ] release APK 每个交付 ABI 均已签名、取证、按规范命名并归档
- [ ] 归档索引字段齐全且 `analyzeErrors == 0`
- [ ] 发布前检查清单 14 项全部打勾，B/C 签字
- [ ] 冻结 tag 已打，冻结后零提交（R-14 收口）
- [ ] 材料清单齐备（PPT / 演示视频 / 测试报告 / 同意书扫描件 / `aapt` 隐私截图）

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| keystore 丢失或口令遗忘 | 构建报签名失败 | 启用备份；备份也丢失 → 更换签名并登记（升级链断裂，属已知代价） |
| 分析 error 清不完 | D10 上午仍有 error | **冻结失效**，回 `PRE_FREEZE` 修完再冻结；优先修 error，不修 info/warning |
| 某 ABI 构建失败 | 产物缺失 | 只交付可构建 ABI，并在归档索引写明缺失项与影响设备 |
| 现场安装不便（split-per-abi） | 评委/自用机安装失败 | 改用 universal APK，但**必须重新取证**（权限 + hash + 命名） |
| 冻结后有人提交代码（**R-14**） | `git log --since` 非空 | 冻结失效：重跑 `SPEC-C-05` 门禁 → 重新冻结 → 重新出包与取证 |
| Gradle/依赖下载失败 | 构建中断 | 使用本机缓存重试；仍失败则延后出包，**不得引入网络依赖到运行期** |

## 7. 与检查点的关系

| CP / 节点 | 关系 | 未完成时的处置 |
|---|---|---|
| **CP3**（D9 午） | 三模式实测通过是出包的前置 | 未过 → 停止一切新功能，全员扑 Demo；出包顺延到 D10 |
| D9 | 演练出包（提前暴露签名/体积/权限问题） | 未出包 → D10 风险集中，须立刻定位阻塞点 |
| **D10 代码冻结** | 本 PLAN 是 R-14 的唯一收口：冻结后任何人不得提交代码 | 未冻结 → 材料可能带未验证代码，禁止提交 |
| D10 材料提交 | 归档索引 + 检查清单 + 证据链是提交物的一部分 | 未完成 → 提交材料不完整，按 `SPEC-C-04` §7 #11 判不通过 |

**文档结束**
