# `app/test/` — 官方套件与离线套件的对应关系

`SPEC-C-05` 要求的测试以 `flutter test app/test/...` 命名。本实现环境**无网络**，
`flutter pub get` 无法解析依赖，因此 `flutter test` 不能启动
（原因与处置见 `../records/reports/c04_dependency_deviation.md`）。

## 1. 两层结构（断言内容不重复定义，只换执行入口）

| 层 | 位置 | 执行入口 | 说明 |
|---|---|---|---|
| **逻辑断言** | `app/tool/*_tests.dart` | `dart run app/tool/<name>_tests.dart` | 纯 Dart，零依赖 |
| **SPEC 点名的套件** | `app/test/**/*_test.dart` | `python tool/run_offline_tests.py` | **本环境已实际执行**（见 §2） |
| **Widget / 绑定依赖** | `app/test/ui/**`、`app/test/data/audio_event_channel_test.dart` | `flutter test`（需 Flutter 引擎） | 需要 Flutter 引擎/测试信使，不能离线跑 |

## 2. 离线执行器（`tool/run_offline_tests.py`）

它做三件事：

1. **手工构造 `package_config.json`**：把 `acoudiet` 指向 `app/lib`，把 `flutter_test` 指向
   `tool/shims/flutter_test`（一个只 `export 'package:test/test.dart';` 的垫片），其余从本地
   pub 缓存解析；
2. **按每个包自己的 SDK 下界设定语言版本** —— 这一步必须做，否则两向都会炸：
   `collection`（`>=2.18.0`）用 `class X` 当 mixin，语言版本 ≥3.0 就会报
   "can't be used as a mixin"；而 `test_api`（`^3.0.0`）用了 class modifier 与 switch 表达式，
   语言版本 <3.0 就会报 "class-modifiers language feature is disabled"。
3. **只执行不需要 Flutter 绑定的文件**，widget 文件被识别并标注为「需真实 `flutter test`」，
   不会被误报为通过。

当前结果：

```
test/cfg/generated_constants_test.dart      +5   全部通过
test/cfg/handshake_test.dart                +5   全部通过
test/data/placeholder_metrics_test.dart     +13  全部通过
test/domain/advice_rules_test.dart          +11  全部通过
test/domain/behavior_analysis_test.dart     +13  全部通过
test/domain/health_score_formula_test.dart  +11  全部通过
test/domain/weekly_report_test.dart         +8   全部通过
                                            ─── 66 项，0 失败
needs flutter test: 10 个 widget/绑定文件（含 test/data/audio_event_channel_test.dart、
test/ui/refresh_and_tab_test.dart、test/ui/report_scope_test.dart）
```

> `test/data/audio_event_channel_test.dart` 断言的是 **`EventChannel` 的 `listen`/`cancel` 载荷**，
> 必须用真实 Flutter 的测试信使（`TestDefaultBinaryMessengerBinding`），因此被归入「需真实
> `flutter test`」那一档。它守的是真机缺陷「只能识别一次」的根因，见
> `../records/reports/u02_second_session_event_binding.md`。
>
> `test/ui/refresh_and_tab_test.dart` 守的是 `ADR-23` 的两条：**不可滚动的空/错状态也能下拉刷新**，
> 以及 **切 Tab 用 `reloadFresh()`（丢弃旧值）而下拉用 `reload()`（保留旧值）**。
>
> `test/ui/report_scope_test.dart` 守的是 `ADR-23` 的报告页双分栏：**打开即在「每日」**、
> **左右滑动真的能切到「本周」**、分段控件可点、选中的日期不回弹。

> ⚠️ 环境陷阱（踩过）：`subprocess` 默认用区域编码（本机是 GBK）解码子进程输出，
> 遇到中文测试名会抛 `UnicodeDecodeError` 并**静默丢掉整段输出**。
> 离线执行器已显式指定 `encoding="utf-8", errors="replace"`。

## 3. 其余判据的位置

`SPEC-C-05` §5 表中那些不在 `app/test/**` 的判据（数据层不变量、会话编排、14 项自检、
跨语言对齐、伦理准入）分别在 `tool/data_tests.dart`、`tool/session_tests.dart`、
`tool/check_consent_registry.py`、`ai/scripts/mel_parity_test.py`；
逐条映射见 `../records/compliance/C-05_regression_checklist.md` §3。


> 恢复网络后无需重写域层测试：`tool/*_tests.dart` 的断言函数可直接搬进 `flutter_test` 的
> `test(...)`，因为两者只依赖 `expect`/`equals` 这类语义，不依赖框架特性。
