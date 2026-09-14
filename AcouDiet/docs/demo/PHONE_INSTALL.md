# 装到手机上测试

本文只讲**怎么把 App 装进手机并测什么**。所有命令都实测过（模拟器 API 34 / x86_64），
真机未测（本机 `adb devices` 为空）。

---

## 0. 拿哪个文件

> 🟢 **2026-09-15 最新（`ADR-38`）：手机自测请用这一份** ——
> **`AcouDiet-1.2.1-arm64-release-no-llm.apk`**，**70,858,649 B**（67.6 MB），
> sha256 **`97f794770adda06b13c0f6ae7faa4733714c27281ab0b40e22640c5494e91add`**。
> 相对 `1.2.0` 的变化**只在界面**（`ADR-38`）：四个顶层页面改成示意图那套**居中标题顶栏**
> （品牌字标在左、页面操作在右，被 push 的页面自动换成返回箭头）；记录卡的千卡移到**右侧列**；
> 「我的」每条入口补上一行描述；雷达四个轴名改为走设计系统并跟随系统字号；
> 检测页圆盘在**还没有任何音频样本**时显示一层静态站波母题（不再是一个空绿圆）。
> 声学模型、权限、口径**一个字节都没改**（仍是 `acoudiet_fp32_v1.3.0.tflite`）。
>
> ```powershell
> python AcouDiet\tool\ui_fingerprint_check.py "<这个包>"        # 期望 RESULT: CURRENT UI   → exit 0
> python AcouDiet\tool\check_apk_contents.py "<这个包>" --expect-no-internet   # 期望 exit 0
> ```
>
> ⚠️ **同一体积的两个包可以内容完全不同**：`1.2.1` 与上一版**字节数恰好都是 70,858,649**，
> sha256 却从 `9bfeb447…` 变成了 `97f79477…`（`ADR-24` 之后这是第二次撞上这种情况）。
> **判断"装的是哪个包"只能看 sha256，不能看大小。**

> 🟢 **2026-09-14（`ADR-34`）：无端侧语言模型的那一版** ——
> **`AcouDiet-1.2.0-arm64-release-no-llm.apk`**，**65,525,041 B**（62.5 MB），
> sha256 `edda873a6ecdf48d9c90619b15e9e236a93df2d227de222cdba255ea9979b2f3`。
> **端侧语言模型（Qwen）已被整体删除**：包里没有 532 MB 的权重、没有 `libacoudiet_llm.so`、
> 没有 `assets/llm/`，首页也没有「AI 周综述」卡片，自检面板回到 **14 项**。
> 保留的是 **v1.3 声学模型**（`acoudiet_fp32_v1.3.0.tflite`，4,053,556 B，sha256 `31fba3ec…19f4`）
> 与 `ADR-24/25/30` 的界面修复。
>
> ```powershell
> python AcouDiet\tool\ui_fingerprint_check.py "<这个包>"        # 期望 RESULT: CURRENT UI   → exit 0
> python _toolchain\check_apk_contents.py "<这个包>" --expect-no-internet   # 期望 exit 0
> ```
>
> 📉 **体积从 595 MB 回到 62.5 MB**：省掉的就是那份 532 MB 权重 + 5 MB 的 shim `.so`。
> 剩下的 62.5 MB 里，Flutter 引擎与 TFLite 的三个额外 ABI 占大头（本包按设计含全部 4 个 ABI）。
>
> ⚠️ **`ADR-34` 之前打的那两个 595 MB 包（sha256 `9a780c2f…` / `4fe4507e…`）现在会被判为
> `NOT THE CURRENT UI`** —— 不是它们坏了，而是它们**带着已经删掉的 AI 卡片**。
> `ui_fingerprint_check.py` 的判据里 `AI 周综述` 属于"必须缺席"，所以这几份只能作历史留档。

已经打好在 `AcouDiet/dist/`（**下表为 `ADR-24`（UI 按投放的界面示意图重构）之后重新实测的值**）：

| 文件 | 大小 | 用途 | 有没有 `INTERNET` 权限 |
|---|---|---|---|
| `AcouDiet-1.0.0-arm64-release.apk` | **24.4 MB**（25,533,450 B） | 真机测试、验收隐私声明。**只含 `arm64-v8a`** | **没有**（只有 `RECORD_AUDIO`） |
| `AcouDiet-1.0.0-arm64-profile.apk` | **92.5 MB**（96,995,714 B） | 需要连电脑抓性能/trace，或要用 `run-as` 看数据库落盘时用。**含全部 4 个 ABI**（文件名里的 `arm64` 只是沿用旧命名） | **有**（profile 覆盖层为 VM service 加的；`aapt2 dump badging` 实测） |
| `app-debug.apk`（在 `app/build/app/outputs/flutter-apk/`，**不在 dist**） | **219.6 MB**（230,219,564 B） | 只在模拟器里用；JIT 慢，且带 `INTERNET` | 有 |

> ⚠️ **2026-09-13：`dist/` 两个包都已按 `ADR-24` 的 UI 重构（含补丁轮的「健康建议」渐变卡 /
> 最近识别记录瓦片 / 我的页三宫格）+ `ADR-23` 的七项改动 + 报告页双分栏 + 模型标签对齐 v1.1 重新打出**
> （`flutter build apk --release --target-platform android-arm64 --android-project-arg=acoudietAbis=arm64-v8a`
> 与 `flutter build apk --profile`，均 exit 0）。**只认下表这两个新 sha256**；更早的包没有这些改动。
> 改动清单与证据见 `docs/reports/adr24_ui_rebuild.md`（UI）与 `docs/reports/adr23_portions_dims_refresh.md`（口径）。
> 包内模型为 `assets/models/acoudiet_fp32_v1.1.0.tflite`（sha256 `705ffc62…560a`，**与模型组交付的 fp32 逐字节相同**）。
>
> ⚠️ **更正（`ADR-32` / `ADR-34`）**：上面那句的**模型名**只对当时那一份 `AcouDiet-1.1.0-arm64-release.apk` 成立。
> 两份 `1.0.0` 包内是更早的声学模型，界面也停在 `ADR-24`；**当前该用的是本节顶部那一份**。
> 判断"手上这个包是哪一版"一律以 `tool/ui_fingerprint_check.py` 的**实测判定**为准，不要以文件名为准。

**`dist/` 里各包的实测指纹**（复核命令见 §3）：

```
★ 1.2.1 no-llm bytes  = 70,858,649      ← 当前该用的那一份（ADR-38：顶栏 / 记录卡 / 我的 / 雷达 / 检测圆盘）
               sha256 = 97f794770adda06b13c0f6ae7faa4733714c27281ab0b40e22640c5494e91add
               包内模型 = acoudiet_fp32_v1.3.0.tflite  4,053,556 B  sha256 31fba3ec…19f4

  1.2.0 no-llm bytes  = 65,525,041      ← ADR-34 那版界面（历史留档）
               sha256 = edda873a6ecdf48d9c90619b15e9e236a93df2d227de222cdba255ea9979b2f3
               包内模型 = acoudiet_fp32_v1.3.0.tflite  4,053,556 B  sha256 31fba3ec…19f4

  1.1.0 model-v1.3.0 bytes = 595,735,269  ← ADR-32 那版，**带已删除的 AI 卡片**（历史留档）
               sha256 = 9a780c2f9374357d67069957fdff4f9a6f277083236d795d37cecaf25235b5e1
  1.1.0       bytes  = 595,733,337      ← ADR-30 时代的界面 + 旧声学模型 v1.1.0（历史留档）
               sha256 = 4fe4507e766ce929d7666c2906415dee84dd8bc3943160f6ab9341495241a908
  1.0.0       bytes  = 25,533,450       ← ADR-24 时代的界面（历史留档）
               sha256 = 330ed47ed7b1e8b3b69d86f15df455023b0fa194bfc8b0ca2a5a6ae574bfc22f
  1.0.0 prof  bytes  = 96,995,714
               sha256 = 9319ded854183132904dc59fc42b86d4972da019201e5381ee3a1c1a861f7979

签名   = CN=AcouDiet TEST（release，测试密钥，见 §4）/ CN=Android Debug（profile）
         apksigner verify 退出码 0；zipalign -c -p 4 退出码 0（两者均实测）
权限   = release：只有 RECORD_AUDIO + com.acoudiet.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION，
         **无 INTERNET**（`1.2.1` 包实测：`ascii=False, utf16le=False`）
         profile：多一个 INTERNET（`aapt2 dump badging` 实测，见下方「一处闸门缺陷」）
ABI    = release 四个 ABI 齐全（arm64-v8a / armeabi-v7a / x86 / x86_64）；
         早前"release 仅 arm64-v8a"的说法只对已不再维护的窄包成立
minSdk = 24（Android 7.0）· targetSdk = 34
```

> 🚨 **不要安装 2026-09-13 早些时候打出的那一版 release 包**（sha256 `8e94d9fb…` / `f91689dc…` /
> `f4f7a10b…`）：那一版的**底栏会把整屏吃掉**，装上看到的是"页面空白 + 左边一条全屏薄荷长条"，
> 也就是"UI 好像完全没变"的那个现象。根因与修复见 `docs/reports/adr24_ui_rebuild.md` §9。
> 该版同时修掉了 `ADR-25`（报告页「每日」的分数与评价恒为 `--`，原因见
> `docs/reports/adr25_daily_score_window.md`）。
> ⚠️ **"只认某一个 sha256"这种说法本身已经过期过两次**：文件名/版本号/字节数都可能是对的而内容不是。
> 判断"装的是哪个包"用**逐文件 sha256** 与 `ui_fingerprint_check.py` 的**实测判定**，
> 而不要依赖本文里写死的某个"唯一正确"的哈希（`ADR-33` 记录了两处"闸门在说谎"的事故）。
> 拿不准一个包是哪一版，直接问工具（它读 `libapp.so` 里的字符串，正控+负控都有）：
>
> ```powershell
> python AcouDiet\tool\ui_fingerprint_check.py <任意.apk>
> # 期望：RESULT: CURRENT UI   →  exit 0
> # 判定词在 ADR-34 改成 CURRENT / NOT THE CURRENT UI：旧措辞"PRE-ADR-24"已经不成立，
> # 因为一个包现在会因为**带着更新的东西**（ADR-28 的 AI 卡片）而被拒，而不是因为太旧。
> ```

> ⚠️ **同一字节数 ≠ 同一个包**：release 包连续两次都是 `25,533,450 B`，但 sha256 从
> `8e94d9fb…` 变成 `f91689dc…` —— 代码确实变了（三块新 UI），**体积恰好相同是巧合**。
> 判断"装的是哪个包"只能看 sha256，不能看大小。
>
> profile 包这一版比上一次 `ADR-24` 构建大 **32,768 B**（96,962,946 → 96,995,714）—— 恰好一个
> 32 KiB 边界，与 zip 对齐填充同量级，但**本仓没有逐条目比对**，所以只报数、不做因果解释。
> 更早那一次（`ADR-23` 版 101,042,562 B → 96,962,946 B，−4,079,616 B）**差额原因仍未查明**：
> 旧包已被 `Copy-Item` 覆盖，本仓不是 git 仓库，取不回旧字节。能确证的是每个新包本身：
> 4 个 ABI 齐全、包内**只有一个** `.tflite`、`zipalign -c -p 4` 通过 ——
> 这不是"少了什么该在包里的东西"，但**"为什么少了 4 MB"这件事本仓没有证据**。
> 与手机安装无关：release 包的字节数两轮之间没有变化。

**三个包都含成品模型**，可直接用下面的命令核对（`ADR-22` 的教训：必须确认模型真的在包里）：

```powershell
python _toolchain\check_apk_contents.py D:\Desktop\Food\AcouDiet\dist\AcouDiet-1.2.1-arm64-release-no-llm.apk --expect-no-internet
# 期望：acoudiet_fp32_v1.3.0.tflite 4,053,556 B，且 sha256 =
#       31fba3ecba852cb51ac8166ab49cba1f4be3f4b23cafbfc5cace8780bfa019f4
# 期望：包内 model_card.json 的 tfliteSha256 / tfliteBytes 与该 .tflite 逐项一致
#       （ADR-32 起该检查器**由包内卡片驱动**，不再写死某个版本的哈希 —— 写死的那版
#        换模型后会对合法包打印 False，属于"闸门在说谎"，见 ADR-33）
# 期望：'android.permission.INTERNET' present in the binary manifest: False  → exit 0
```

> 🚨 **`ADR-24` 顺手修掉的一处闸门缺陷：这条 INTERNET 检查此前是"永远不会失败"的。**
> 二进制 AXML 的字符串池是 **UTF-16**，而检查器搜的是 ASCII 字节 —— 于是它对**任何**包都打印
> `False`。本次实测暴露了它：profile 包（`aapt2 dump badging` 明确有 `INTERNET`）也被打印成
> `False`。**一个不可能失败的闸门在证据上等于没有闸门**（与 `ADR-22`/`ADR-23` 同一主题）。
> 已修为：两种编码都搜，显示 `ascii=/utf16le=` 两个分量，并新增 `--expect-no-internet` 开关
> —— 带上它且真的搜到时**返回 1**。负控已实测：profile 包 + 该开关 → `exit 1`；
> release 包 + 该开关 → `False` / `exit 0`。

> ✅ **release 构建已做设备端实测**（2026-09-12，模拟器 API 34 / x86_64）：
> `adb install` 退出码 0、`Fully drawn …MainActivity: +1s430ms`、无 `FATAL EXCEPTION`、
> **模型加载检查 PASS**（应用自己的 pid 打出 `Initialized TensorFlow Lite runtime`，缺陷签名 0 命中）。
> ⚠️ **被测的具体文件是"4 个 ABI 的 release 包"**（62.2 MB），因为模拟器是 **x86_64**，
> 而 `dist/` 里那个 **24.4 MB** 的包**只含 arm64，装不进模拟器**（会 `INSTALL_FAILED_NO_MATCHING_ABIS`）。
> 两者**同一份源码、同一个工具链，差异只在打包了哪些 ABI**；`dist/` 的 arm64 包本身的
> "模型在包内 + sha256 逐字节相同" 已由上面那条命令核对过。真机（arm64）请用 `dist/` 那个。

> 体积解释（`ADR-20` 起）：release 里多了 **3.2 MB** 的 TFLite 运行时
> （`lib/arm64-v8a/libtensorflowlite_jni.so`）—— 之前**完全没有**这个库，模型放进去也跑不起来；
> 再加大约 **3.9 MB** 的模型资产（`ADR-21`），以及 `ADR-21` 的 Mel 前端改动本身不增体积。
> release 之所以是 **24.4 MB** 而不是 35 MB，是因为构建时加了
> `--android-project-arg=acoudietAbis=arm64-v8a`（Flutter 的 `--target-platform` **不过滤第三方
> AAR 的 native**，不加这个参数会把 4 个 ABI 的 TFLite 全打进来）。
> profile 包 **92.5 MB** 是因为它**保留全部 4 个 ABI**（模拟器是 x86_64，砍掉就没法实测）。

> ⚠️ **要验证「不申请网络权限」这条声明，只能用 release 包。**
> debug / profile 包为了能热重载和抓 trace，清单里带了 `INTERNET` —— 这是 Flutter 的
> 调试覆盖层，不是产品行为。`SPEC-C-01` §7 审计的也是 `app-release.apk`。
> 实测（`aapt2 dump badging`）：release 包权限 = `RECORD_AUDIO` +
> `com.acoudiet.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`（后者是 Android 自己加的，
> 不是网络权限），**无 `INTERNET`**。

### ⚠️ 装之前／"装了但界面没变"时：先确认这个 APK 里装的是哪一版 UI

```powershell
python AcouDiet\tool\ui_fingerprint_check.py
# 不给路径时它检查 dist/ 下**最新的**那个 *release*.apk，并把它选中的文件名打印出来
# （ADR-33 起如此：此前默认写死成 1.0.0 那个文件，于是换包后它会对自己挑的文件报"DO NOT INSTALL"）
# 期望：RESULT: CURRENT UI   →  exit 0
```

`2026-09-13` 的真实事故：`_toolchain/tmp/app-release-4abi.apk`（为 x86_64 模拟器打的 4 ABI
release 包，**旧界面**）被留在 `_toolchain/tmp/` 里。它是 release 构建、用的是**同一个测试密钥**，
所以装到手机上**不会报任何错**，装上就是旧界面。该文件已改名为
`app-release-4abi-PRE-ADR24-OLD-UI-DO-NOT-INSTALL.apk`，并且上面这条命令现在能直接判定一个包是
新 UI 还是旧 UI（正控 + 负控都在里面，判定式**能失败**）：

```
[ok  ] control: records page title          ← 正控：每版都有；它不中说明方法坏了，结论无效
[MISS] meal chip: breakfast                 ← 新 UI 才有的字符串
[BAD ] old score card title (must be absent) ← ADR-23 改名后已删除的旧标题
```

> ⚠️ 顺带记一条同族的坑：Dart 的字符串在 `libapp.so` 里是 **UTF-16**，用 `grep` 搜 UTF-8 中文
> **一个字都搜不到** —— 于是"新 UI 没进包"和"搜索方法不对"会得到同一个（错误的）结论。
> 这就是上面必须有**正控**的原因（与 `check_apk_contents.py` 那处 UTF-16 假阴性是同一个坑）。

### "装了但界面没变"的两个已知原因（按可能性排序）

| # | 原因 | 怎么确认 | 怎么修 |
|---|---|---|---|
| 1 | **装的是旧签名的包，新包被 Android 拒了**：`app-debug.apk` 是 **Debug 密钥**，`dist` 里的 release 包是 **CN=AcouDiet TEST**，签名不同 → `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，旧 App 原地不动 | 安装时是否闪过"未安装/应用未安装"；`adb install` 的退出码（**不是**输出里的 `Success` 字样，`ADR-22` 记录过这个判据缺陷） | `adb uninstall com.acoudiet.app` 再装 `dist` 的 release 包 |
| 2 | **装的是另一个 APK 文件**（例如上面的 4 ABI 旧包、或几天前拷到手机里的旧文件） | 对着手机里那个文件跑 `python AcouDiet\tool\ui_fingerprint_check.py <文件>` | 用 §0 顶部那一份（`dist\AcouDiet-1.2.1-arm64-release-no-llm.apk`，sha256 `97f79477…91add`） |

前置条件：手机 **Android 7.0（API 24）或更高**、CPU 为 **arm64**（近十年的手机基本都是）。
包名 `com.acoudiet.app`，版本 `1.1.0`。

---

## 1. 装法 A：只用手机（不用电脑）

1. 把 §0 顶部那一份 `AcouDiet-1.2.1-arm64-release-no-llm.apk` 传到手机
   （微信文件传输 / 云盘 / 数据线拷进「下载」目录都行）。**67.6 MB，传输很快**；
2. 手机上点这个文件安装。第一次会提示「不允许安装未知应用」→ 去
   **设置 → 应用 → 特殊应用权限 → 安装未知应用**，给「文件管理器」或你点的那个应用放行；
3. 装完桌面出现 **AcouDiet**，图标是绿底啃咬波形。

> ⚠️ **如果手机上原来装的是从 Android Studio / `flutter run` 来的 debug 版，这一版会装不上去**
> （签名不同 → `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，系统可能只弹一句"应用未安装"就结束了，
> 于是你看到的还是**旧界面**）。这种情况先卸载：**设置 → 应用 → AcouDiet → 卸载**，再装新包。
> 装完请顺手确认一眼：**底部「记录」页顶部应该有一排 `全部 / 早餐 / 午餐 / 晚餐 / 零食 / 饮品`
> 药丸**、选中 Tab 是**薄荷圆角块** —— 这两处在 `ADR-24` 之前不存在。

## 2. 装法 B：用数据线 + adb（能看日志，推荐）

```powershell
# 手机：设置 → 关于手机 → 连点「版本号」7 次开启开发者选项
#       → 开发者选项 → 打开「USB 调试」→ 插线 → 手机上允许此电脑的调试授权

$adb = 'D:\Desktop\Food\_toolchain\android-sdk\platform-tools\adb.exe'
& $adb devices          # 应看到你的设备号 + device（不是 unauthorized）

# 0) 如果装过 debug 版（签名不同），先卸载；不卸的话下面那条 install 会被拒
& $adb uninstall com.acoudiet.app

& $adb install -r "D:\Desktop\Food\AcouDiet\dist\AcouDiet-1.2.1-arm64-release-no-llm.apk"
# ⚠️ 看**退出码**，不要只看输出里有没有 Success 字样：输出被截断时两者都看不到（ADR-22）
"install exit = $LASTEXITCODE"

# 启动
& $adb shell am start -W -n com.acoudiet.app/.MainActivity

# 截一张图留证（同时能自己看一眼界面到底换没换）
& $adb exec-out screencap -p > D:\Desktop\Food\AcouDiet\docs\demo\phone_home.png

# 看日志（筛崩溃与业务码）
& $adb logcat -d | Select-String 'FATAL EXCEPTION|ACD-[A-Z]+-\d+'

# 看数据库是否真的落盘（debug/profile 包才允许 run-as；release 包不允许）
& $adb shell run-as com.acoudiet.app ls -la files/
```

> release 包**不能用** `run-as`（不是 debuggable）。要在真机上确认持久化，用
> **profile 包**装一次、产生一条记录、`run-as` 看 `files/acoudiet.db` 是否存在；
> 或者直接看首页「本周记录 N 次」在**杀掉 App 重开之后**是否还在。

## 3. 重新打包（改了代码或换了模型之后）

```powershell
# 【当前实际用法·推荐】一条命令完成"构建 + 命名 + 包内取证 + sha256"：
powershell -NoProfile -ExecutionPolicy Bypass `
    -File D:\Desktop\Food\AcouDiet\tool\build_release_v11.ps1 `
    -Version 1.2.1 -OutName 'AcouDiet-1.2.1-arm64-release-no-llm.apk'

# ⚠️ ADR-32 加的护栏（实测有效）：目标文件已存在时脚本**直接失败**，除非显式加 -Force。
#   理由：换模型重打若沿用同名，旧包会被静默覆盖而**不可恢复**（本仓不是 git 仓库，
#   PHONE_INSTALL 已经记录过一次同类教训）。`-OutName` 让"App 版本没变但模型变了"
#   这件事体现在**文件名**上。
```

手工构建（等价，但**不会**自动拷进 `dist/`、不会写 sha256）：

```powershell
. D:\Desktop\Food\_toolchain\acoudiet-env.ps1
cd D:\Desktop\Food\AcouDiet\app

# 全 ABI（**当前实际体积 568.1 MB**）：
flutter build apk --release

# 只保留 arm64（省掉其余 3 个 ABI 的原生库，约 −30 MB）：
flutter build apk --release --target-platform android-arm64 `
    --android-project-arg=acoudietAbis=arm64-v8a
# ⚠️ 后面那个参数不能省：Flutter 的 --target-platform 只过滤它自己的库，
#    **不过滤第三方 AAR 的 native**，省掉它会把 4 个 ABI 的 TFLite 全打进来。

# profile（4 个 ABI，可 run-as）：
flutter build apk --profile
```

> ⚠️ **包体积现在由"几个 ABI"决定，不是由模型决定**：端侧 Qwen 权重（532 MB）已于 `ADR-34`
> 删除，所以 release 包回到 **62.5 MB**（4 个 ABI）量级；若按上文只留 `arm64-v8a`，
> TFLite 与 Flutter 的其余三个 ABI 原生库省掉，还会更小。
> 本文里那些「568 MB / 595 MB」的数字是 `ADR-26`~`ADR-33` 期间的（带端侧模型）。
> 无论哪个时期，**判断包对不对的依据只有 sha256 与包内取证**，不是大小。

`tool\build_release.ps1` 是**完整发布流程**（先 `flutter analyze` 断言 0 error，再构建、逐 ABI 取证、
归档到 `docs/release/` 并生成索引）。它**不**写 `dist/`，所以手动拷贝那一步仍需自己做。
`tool\build_release_v11.ps1` 才是**手机自测用的那条**（写 `dist/` + 包内取证 + sha256 sidecar）。

> 打包后**请务必核对模型真的在包里**（`ADR-22` 的教训：应用能启动 ≠ 模型能用）：
>
> ```powershell
> python _toolchain\check_apk_contents.py <你的.apk>
> ```

---

## 4. ⚠️ 签名：现在用的是**测试密钥**，上线前必须换

`app/android/key.properties`（已被 `.gitignore` 忽略）现在指向：

```
D:\Desktop\Food\_toolchain\keys\acoudiet-test.jks
别名 acoudiet / 口令 acoudiet-test / CN=AcouDiet TEST
```

这是为了让你能打出一个**没有 INTERNET 权限**的 release 包而临时生成的，
**它不是发布密钥**。换正式密钥：

```powershell
& "$env:JAVA_HOME\bin\keytool.exe" -genkeypair -v `
    -keystore D:\AcouDiet-Keys\acoudiet-release.jks `
    -alias acoudiet -keyalg RSA -keysize 2048 -validity 10000 `
    -dname "CN=AcouDiet, OU=Project, O=AcouDiet, L=., ST=., C=CN"
# 然后把 app/android/key.properties 的四个字段改成正式密钥的值，密钥文件留在仓库之外
```

两条实务提醒：

* **换密钥前装过的包必须卸载才能装新签名的包**（签名不一致 Android 会拒绝覆盖安装）；
* 正式密钥一旦丢失，就**无法再给已发布的 App 发升级**，请交给保管人存好
  （`SPEC-C-04` §2.2 已规定）。

---

## 5. 装上之后测什么（以及现在**测不了**什么）

### 能测

| 项 | 预期 |
|---|---|
| 启动 | 首屏 `AcouDiet · 声膳`，`近 7 天健康评分`（`ADR-23` 起就是这个名字，不再是「今日健康评分」）显示 `-- 分`、四维全 `--`、雷达图带四个轴标签 |
| 空态诚实性 | `估算能量参考 → 暂无数据`、`本周记录 0 次`、`今天还没有记录`；**不编造任何数字** |
| C-02 先签后用 | 首次进「检测」页弹「隐私说明 —— 音频只在内存中处理，不写入存储；本应用不申请网络权限。」，需点「知道了」 |
| C-03 握手门禁 | 检测页可达（若原生/Dart 配置漂移，该页会被 `ACD-CFG-001` 挡住且**没有**开始按钮） |
| 权限流 | 点「开始 AI 检测」应弹系统录音权限请求；拒绝后给出可操作提示，不崩 |
| **连续两次检测**（ADR-22/23 修复项） | 第一次检测完 → 点「停止检测」→ 按钮变「再次检测」→ 再点：**波形必须照常动、4–5 s 后照常出结果**。修复前这一步会「麦克风开了但波形和识别都不动」 |
| **结果卡片上的按钮** | 出确认结果后按钮仍是「停止检测」（`SPEC-U-02 §2.3`：`confirmed` 是运行态），不是第二个「开始 AI 检测」 |
| **用量随时间变化**（ADR-23） | 记录里的克/毫升按**本次进食时长**估算（「约 150 g（估算）」），长短两次进食的数字不同；详情页同时显示「本次估算用量」与「标准份量」 |
| **饮品不算零食**（ADR-23） | 下午喝一瓶饮料后，记录页摘要栏的「零食 N 次」**不增加**；饮料仍按自己的类别计数 |
| **首页四维**（ADR-23） | 标题为「近 7 天健康评分」；四维下面有一行依据（`记录 N 次 · 零食 n 次 · 有咀嚼指标 m 条`）；只有 1–2 条记录时「食物结构」显示 `--` 而不是 30/30 |
| **报告「每日 / 本周」双分栏**（ADR-23） | 底栏「报告」**一个入口**进入后**默认是「每日报告」**（标题为「每日报告」）；**左右滑动**或点 AppBar 下的「每日 / 本周」分段控件即可切换；每日分栏可选日期、看当日四维雷达与当日汇总（记录次数 / 估算热量 / 零食次数 / 食物类别）与按天四维列表；本周分栏是原来的周报（趋势图 / 四维 / 环比 / 建议） |
| **检测页行为行实时变化**（ADR-23） | 会话进行中，「咀嚼次数 / 进食时长 / 进食速度」约每秒刷新一次，不再只在停止后出现 |
| **下拉刷新**（ADR-23） | 首页 / 记录 / 报告 / 我的 / 记录详情 / 自检面板 / 演示页都可下拉；**空态与错误态也能拉** |
| **切 Tab 先刷新**（ADR-23） | 点底部按钮切换时，先显示该页的「正在读取…」，**不会先闪一下旧数字** |
| **持久化** | 产生一条记录后**杀掉 App 重开**，`本周记录 N 次` 与「今日记录」列表应还在 |
| **界面已按投放的示意图重画**（ADR-24） | ① 首页 / 记录 / 检测 / 我的 / 报告都是薄荷→奶油渐变 + 白色圆角卡片；② 底部四个 Tab 的**选中项是薄荷圆角块**（不再是 Material 默认样式）；③ 记录页顶部有 **`全部 / 早餐 / 午餐 / 晚餐 / 零食 / 饮品`** 药丸筛选 —— 点它会过滤时间轴，但上方的「今日热量 / 已记录 / 零食」**始终是今日整体**，不随筛选变化；筛空时显示「这一餐段还没有记录」而不是空白；④ 记录卡片之间有**薄荷圆点时间轴**，日期头是 `今天 9月10日 ★`；⑤ 检测页预测卡显示**中文食物名**（`薯片 91%`，不再是 `chips 91%`） |
| **顶栏与卡片版式**（`ADR-38`） | ① 记录 / 报告 / 检测 / 我的四个页面的**页面标题在顶栏正中**，左边是 `AcouDiet` 字标、右边是各页自己的按钮；**从首页右上角进「我的」时，左槽变成返回箭头**（这是能退回首页的唯一出口）；② 记录卡的**千卡在卡片右侧列**（名称与「属性 · 份量」在左，置信度 chip 在最下面）；③ 「我的」的每一行标题下面**多了一行说明**；④ 检测页圆盘在**还没有任何音频样本**时显示一层**静态**声波母题（它不动、也不代表任何读数，旁边仍写「当前静默」；一有真声音就换成实时波形） |
| **报告页两块 + 我的页三宫格**（ADR-24 补丁轮） | ① 报告页「本周」底部「健康建议」是**浅绿渐变卡**（示意图里是中绿底白字，白字约 2.5:1 违反对比度红线，故只抄形状不抄字色）；② 「最近识别记录」是**横滑瓦片**（最新 6 条，点开进记录详情）；③ 我的页有 **`总进食次数 / 平均咀嚼速度 / 零食次数`** 三格 —— 它们与报告页「本周」是**同一个 7 日窗口**；数据读不到时三格一起显示 `--`，窗口里没有咀嚼样本时速度格显示 `无样本`（**不是** `正常`） |
| 权限声明 | `aapt2 dump badging app-release.apk` 里**没有** `INTERNET`；系统设置里该应用的「网络」权限项不存在 |

### 现在测不了（不是 bug，是缺件）

| 项 | 原因 |
|---|---|
| **识别准不准** | **模型已投放并能加载**（`ADR-21`/`ADR-22`/`ADR-32`，当前为 `acoudiet_fp32_v1.3.0.tflite`，见 `app/assets/models/README.md`），检测页不再报 `ACD-INF-001`。但**准确率无法在本机验证** —— v1.3 交付说明给的聚合 55.9%（Wilson CI 51.9–59.9%）来自模型组的公共测试集，而本仓 `ai/data/splits`、`raw`、`augmented` **是空的**，没有带标注语料可评。真机上能测的是"它响不响应、会不会崩、记录落不落盘"，**不是**"它认得对不对"。 |
| **「不申请网络权限」的运行时证据** | release 包没带 `INTERNET`，系统层面就没有这个权限项，所以只能从 APK 清单侧证明（上表最后一行） |

> ⚠️ **已经知道、但本次没有修的一条邻近缺陷**（详见
> `docs/reports/u02_second_session_event_binding.md` §5）：**90 s 静默由原生自动结束会话时，页面不会自己
> 变成「已结束」**（`DetectionSession` 对 `sessionEnded` 事件是 `break`）。此时页面还显示「正在感知…」，
> 点「停止检测」会报一次 `ACD-SESS-001`，**那一次会话里已确认的食物不会落库**；点完这一次之后，
> 「再次检测」是正常的。Demo 模式 B（示例演示）经同一条路径结束，记录同样不落库。

> ⚠️ **`ADR-22` 的教训，装到手机上时同样适用**：应用能启动 **≠** 模型能用。第一次设备端实测时
> 六项启动判据全绿，而模型**加载失败**（`E tflite : Could not open 'assets/models/...'`）。
> 现在 `run_on_emulator.ps1` 已把"模型真的加载了"作为**第 7 项独立判据**。在手机上自测时，
> 请打开首屏右上角的**自检面板**看**第 3 项（模型已加载）**是否通过 —— 那一项才是模型的证据。

### 值得顺手看一眼的两件事

1. **丢帧提示**：真机跑检测时若丢帧 > 5%，界面会给步长提示（`M-04`）；
2. **自检面板**（首屏右上角清单图标）：**14 项**逐项状态（`ADR-14` 的冻结闭集），
   其中第 3/11 项是声学模型，第 2 项是麦克风占用。
   `ADR-27` 曾新增第 15 项「建议模型可用」，**该层已随端侧语言模型在 `ADR-34` 一并删除**。

---

## 6. 装不上时怎么排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `INSTALL_FAILED_NO_MATCHING_ABIS` | 手机不是 arm64（很老的设备或 x86 平板） | 改用全 ABI 包：`flutter build apk --release` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 之前装的是另一个签名的同包名应用 | 先卸载：`adb uninstall com.acoudiet.app` |
| `INSTALL_PARSE_FAILED_NO_CERTIFICATES` | APK 传输中被当成文本改写了 | 重新拷；别用会改编码的编辑器打开 |
| 提示「解析包时出现问题」 | minSdk 高于系统版本 | 系统需 Android 7.0+ |
| 点了没反应 / 白屏 | 看 `adb logcat` 有无 `FATAL EXCEPTION`（会一并给 `ACD-*` 码） | 把日志贴回来 |
