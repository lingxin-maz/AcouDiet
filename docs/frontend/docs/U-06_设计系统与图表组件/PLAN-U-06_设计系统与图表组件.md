# PLAN-U-06 设计系统与图表组件

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-U-06` |
| 负责 | C（主责）；B 协助主题接入与字体资源 |
| 目标日 | D3（D1 起做，D3 收口冻结签名） |
| 前置依赖 | 无（唯一无上游依赖的 U 项）；`SPEC-00` §3.7 FF-22 四维定义已冻结 |
| 预估工时 | 10 h（D1 4h + D2 3h + D3 3h） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/lib/presentation/theme/acou_theme.dart` | MD3 色板、语义色、间距/圆角/字号 token |
| 2 | `app/lib/presentation/theme/acou_format.dart` | `AcouFormat` 纯格式化函数（SPEC-U-06 §4.3） |
| 3 | `app/lib/presentation/widgets/food_icon.dart` | `FoodIcon` + 6 类映射表 |
| 4 | `app/lib/presentation/widgets/four_dim_radar.dart` | `FourDimRadar`（`fl_chart` `RadarChart`） |
| 5 | `app/lib/presentation/widgets/trend_line_chart.dart` | `TrendLineChart`（`fl_chart` `LineChart`） |
| 6 | `app/lib/presentation/widgets/waveform_view.dart` | `WaveformView`（`CustomPainter`） |
| 7 | `app/lib/presentation/widgets/state_view.dart` | `StateView` + `ViewStatus` 枚举 |
| 8 | `app/lib/presentation/widgets/record_card.dart` | `RecordCard` + `ConfidenceChip` + `ConfidenceTier` |
| 9 | `app/lib/presentation/widgets/food_class.dart` | `FoodClassId` 枚举（与 FF-19 逐字一致） |
| 10 | `app/test/widget/design_system_test.dart` | SPEC-U-06 §7 的 8 项自动判据 |
| 11 | `app/assets/icons/food/*.webp`（≤ 200 KB 合计） | 6 类食物图标位图 |
| 12 | `PLAN-U-01`~`PLAN-U-05` 可引用的**组件签名冻结页**（写入仓库 README 组件表） | 供其余 5 页并行开发 |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 定色板与 token（对齐 `1.png` 主色，落 MD3 `ColorScheme`） | `acou_theme.dart` | 2.0 h | 无 |
| 2 | 定 6 类图标（`chips/cabbage/gummies/noodles/carrot/drink`） | 图标资源 + `food_icon.dart` | 1.5 h | 无 |
| 3 | 实现 `AcouFormat` 全部格式化规则 | `acou_format.dart` | 1.0 h | 无 |
| 4 | 实现 `StateView` 四态 + 语义标签 | `state_view.dart` | 1.0 h | 1 |
| 5 | 实现 `FourDimRadar`（含文本等价物） | `four_dim_radar.dart` | 2.0 h | 1、FF-22 |
| 6 | 实现 `TrendLineChart`（含空洞不插值） | `trend_line_chart.dart` | 1.5 h | 1 |
| 7 | 实现 `WaveformView`（自绘层独立重绘） | `waveform_view.dart` | 1.5 h | 1 |
| 8 | 实现 `RecordCard` + `ConfidenceChip` | `record_card.dart` | 1.5 h | 2、3 |
| 9 | 写 widget test 8 项 + 人工核对表 10 项 | `design_system_test.dart` | 1.5 h | 3–8 |
| 10 | 冻结签名并同步其余 5 个 PLAN | README 组件表 | 0.5 h | 9 |

## 3. 技术方案

- **主题**：以 `ColorScheme.fromSeed` 生成 MD3 色板，主色取 `1.png` 的绿色系；间距/圆角/字号写为 `AcouTheme.spaceMd` 等常量，页面禁写魔法数。
- **格式化集中在 `AcouFormat`**：页面只调用，不拼字符串；热量区间与「估算」字样由该层强制拼接（SPEC-U-06 §4.3），使 §7 判据 5 可由单测覆盖。
- **雷达图**：4 轴等分，轴标签取 `DimensionScore.label`；`Semantics(label: ...)` 拼文本等价物供读屏。
- **折线图**：`null` 点**被过滤而非插值**，`FlSpot` 只对非空点生成。
- **波形**：`rms` 流经 `ValueNotifier` 驱动 `CustomPainter`，仅重绘自绘层；无事件 2 s 后进入静默态。
- **格式化骨架（≤30 行示例，非完整实现）**：

```dart
class AcouFormat {
  static String kcalRange(int kcal) {                    // estimatedKcal ± 20%
    final lo = (kcal * 0.8).round(), hi = (kcal * 1.2).round();
    return '估算能量参考 约 $lo–$hi kcal';
  }
  static String recordKcal(FoodInfo f) =>                 // 份量 + 估算，缺一不可
      '${f.portionDesc}（估算）≈${f.portionKcal} kcal';
  static String duration(int seconds) => seconds < 60
      ? '$seconds 秒' : '${seconds ~/ 60} 分 ${seconds % 60} 秒';
  static String percent(double p) => '${(p * 100).round()}%';
  static String? delta(int? d) => d == null
      ? null : d == 0 ? '持平'                                  // 0 = 确实持平（ADR-10）
      : '${d > 0 ? '↑' : '↓'}${d.abs()} 分';                    // 仅 null（无昨日数据）返回 null → 隐藏该行
}

enum ConfidenceTier { high, medium, low, none }
ConfidenceTier tierOf(double p) => p >= 0.70 ? ConfidenceTier.high
    : p >= 0.45 ? ConfidenceTier.medium : ConfidenceTier.low;   // 阈值 = FF-20
```

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `design_system_test.dart` | widget test | SPEC-U-06 §7 判据 1–8 全部通过 | 每次提交 |
| 雷达轴数 | widget test | 轴数 == 4，标签集合 == FF-22 四维 | D3、D8 |
| 图标覆盖 | widget test | 恰好 6 类；越界入参渲染占位图标 | D3 |
| 格式化 | unit test | `kcalRange(1250)` == `估算能量参考 约 1000–1500 kcal`；`delta(0)` == `持平`；`delta(null)` == `null`（`ADR-10`） | D3 |
| 禁用词扫描 | shell 断言 | `rg` 营养素/表外字段/FF-25 词命中数 == 0 | D3、D8、D9 |
| 无障碍 | 人工 + 语义树 | 雷达/折线有文本等价物；点击区 ≥ 48×48 dp | D3 |
| 人工核对表 | 人工 | SPEC-U-06 §7 的 10 项全 ✓ | D3 |

## 5. 完成定义（DoD）
- [ ] `SPEC-U-06` 第 7 节全部 11 项判据通过（含 10 项人工核对表逐项打钩）。
- [ ] 12 项交付物全部落盘，路径可点开。
- [ ] 组件签名冻结并经 B 复核；`U-01`~`U-05` 的 PLAN 已引用该签名。
- [ ] `flutter test test/widget/design_system_test.dart` 退出码 0。
- [ ] 全仓 `rg` 扫描：营养素词、表外字段、FF-25 禁用词、网络依赖均为 0 命中。
- [ ] 组件仅依赖入参，不 import 任何 Repository / `MethodChannel`。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| 组件签名反复变更导致 5 个页面返工 | D3 后仍改构造参数 | **D3 冻结签名**；后续变更走 `PLAN-C-03` 变更传播单 |
| `fl_chart` 雷达图 API 与预期不符 | D2 仍未出图 | 用 `CustomPainter` 自绘雷达（仅四轴，工作量约 +1 h） |
| 中文字体缺失导致方框 | 真机出现方框 | 回退系统字体，放弃 `9.png` 的标题体 |
| 图标风格不统一 | 人工核对项 6 不通过 | 统一改为单色 `IconData`，放弃彩色位图 |
| 无障碍工期挤占页面开发 | D3 超时 >1 h | 保留语义标签（必做），文本等价物延到 D8 与页面一并补 |

## 7. 与检查点的关系
- 本功能**不属于任何 CP 的判据项**，但它是 `CP2`（D5）的前置：`U-02` 的波形与状态组件未就绪则 D5 闭环无法显示结果。
- **D3 收口**：组件签名冻结视为 `PLAN-00` §4「接口先行」的第 4 个接口（前三个为 `feature_config` / `DietRecord` / `HealthScore`）。
- 未完成时：CP2 判据不变，但 `U-01` 的雷达与 `U-04` 的折线可临时用 `StateView(empty)` 占位，**不得**用假数据填充。

**文档结束**
