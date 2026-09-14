# C-04 构建、签名与发布 · 记录与判据映射

**SPEC 对应**：`SPEC-C-04` §7（10 条判据）
**PLAN 对应**：`PLAN-C-04`
**目标日**：D9 演练出包 → D10 冻结后定稿

---

## 1. 本仓已落地的部分（可在离线环境完成）

| PLAN 交付物 | 本仓文件 | 状态 |
|---|---|---|
| #4 `signingConfigs.release`（读本机 properties，不硬编码口令） | `app/android/app/build.gradle` | ✅ **缺失 `key.properties` 时在配置期抛 `GradleException`**，绝不静默回退 debug 签名（`SPEC-C-04` §6） |
| #3 `.gitignore` 覆盖签名材料 | `app/android/.gitignore` | ✅ `key.properties` / `*.jks` / `*.keystore` / `local.properties` |
| （前置）#2 本机 `key.properties` | `app/android/key.properties.example` | ✅ 模板 + `keytool` 生成命令（密钥本体在仓库外） |
| 出包与取证流程 | `tool/build_release.ps1` | ✅ 分析 → 构建 → 逐 ABI 取证 → 归档 → 写索引，一条命令 |
| #6 归档索引 | 由脚本生成 `docs/release/RELEASE_<ver>_<stamp>.md` | ✅ 字段与 `SPEC-C-04` §4 对齐（8 个必填字段） |
| #7 发布前检查清单 | `docs/release/pre_release_checklist_TEMPLATE.md` | ✅ 12 条（见 §4 的口径说明） |
| #8 `apk_sha256.txt` | 由脚本追加 | ✅ |
| 权限在构建期被强制 | `app/build.gradle` 的 `processManifestProvider` 钩子 | ✅ 合并后的 manifest 若含 `INTERNET` 或权限集合 != {RECORD_AUDIO} 即**构建失败**（FF-24 第 4/5 条的构建期防线） |

**关键设计**：`SPEC-C-04` §2.2 步骤 4 要求「debug 签名不得用于提交产物」。本仓把它做成
**两个硬失败点**而不是约定：
1. 缺 `key.properties` → Gradle 配置期直接抛错；
2. 合并 manifest 权限不符 → 构建失败。

## 2. 本环境无法完成的部分

`flutter analyze` / `flutter build apk` / `gradlew` 需要解析 pub 与 Gradle 依赖，本机**无网络**
（`pub.dev`、镜像、GitHub 实测均不通，Gradle 缓存为空）。因此 `SPEC-C-04` §7 的
#1/#2/#3/#7/#8/#9/#10 需在**普通终端 + 有网络**的环境执行。

命令已准备好（`tool/build_release.ps1`），只需在有网机器上：

```powershell
. D:\Desktop\Food\_toolchain\acoudiet-env.ps1
Copy-Item app\android\key.properties.example app\android\key.properties   # 填入真实口令
powershell -File tool\build_release.ps1                                   # 分析+构建+取证+归档
```

## 3. 判据映射（`SPEC-C-04` §7）

| # | 判据 | 本仓状态 |
|---|---|---|
| 1 | 静态分析零 error | ⏳ 需有网环境（`flutter analyze`） |
| 2 | release 构建成功 | ⏳ 同上 |
| 3 | 签名可用且正确 | ⏳ 同上（脚本内已断言 `apksigner verify` 退出码 0） |
| 4 | 签名材料未入库 | ✅ `.gitignore` 就位；判据命令见 §5 |
| 5 | 权限复核通过 | ✅ 静态层面已锁定（manifest 仅 1 条权限 + 构建期钩子）；⏳ 需打包后 `aapt dump badging` 取证 |
| 6 | 模型体积 ≤ 2.5 MB | ⏳ 待 `T-07` 产出（脚本会在超限时失败） |
| 7 | 命名与归档合规 | ✅ 脚本按 `AcouDiet-v<ver>-<yyyyMMdd>-<abi>.apk` 命名并校验 sha256 长度 |
| 8 | 归档索引字段齐全 | ✅ 脚本生成；8 字段齐全 |
| 9 | D10 冻结生效 | ⏳ 需要 git 仓库与流程执行 |
| 10 | 检查清单完成 | ✅ 模板就位（12 条，待签字） |

## 4. 两处文档不一致（登记，供维护者修）

| # | 现象 | 本仓处置 |
|---|---|---|
| 1 | `PLAN-C-04` §1 交付物 #7 写「发布前检查清单（**14 项**）」，而 `SPEC-C-04` §7 附表只列 **12 条** | 以 SPEC 为准执行 12 条；本文件与模板均注明差异 |
| 2 | `SPEC-C-04` §3 的接口表把 `flutter analyze` 写在「静态分析」行，但 `SPEC-00` §7 的判据类型要求「命令退出码」——`flutter analyze` 在存在 `info` 时也可能返回非 0 | 本仓改为**解析输出中的 `error •` 计数**（脚本已实现），并以退出码辅助判断；建议 SPEC 明示口径 |

## 5. 签名材料未入库的验证命令

```powershell
cd D:\Desktop\Food\AcouDiet
git check-ignore -v app\android\key.properties      # 期望：命中 .gitignore 规则（退出码 0）
git ls-files | Select-String -Pattern 'key\.properties|\.jks|\.keystore'
# 期望：无输出（命中行数 == 0）
```

> ⚠️ 本仓尚未初始化 git 仓库（工作区由 `docs/` 与本目录组成）。上述命令需在
> `D:\Desktop\Food` 成为 git 工作树后执行；`.gitignore` 规则本身已就位，因此一旦纳入版本控制即生效。
