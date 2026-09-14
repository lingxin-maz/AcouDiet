# PLAN-U-02 AI 检测页

| 项 | 值 |
|---|---|
| 对应 SPEC | `SPEC-U-02` |
| 负责 | C（主责 UI 与交互）；B 协助桥接事件接入与端到端联调 |
| 目标日 | D5（D4 起做，D5 收口，D6 稳定性打磨） |
| 前置依赖 | `PLAN-P-01`（采集）、`PLAN-P-05`（推理）、`PLAN-P-06`（聚合）、`PLAN-P-07`（行为，D7）、`PLAN-U-06`（波形组件）；`API-01` 事件契约 |
| 预估工时 | 11 h（D4 4h + D5 5h + D6 2h 打磨） |

## 1. 交付物（Deliverables）

| # | 文件路径 | 内容 |
|---|---|---|
| 1 | `app/lib/presentation/pages/detect/detect_page.dart` | 页面骨架与状态机绑定 |
| 2 | `app/lib/presentation/pages/detect/widgets/wave_circle.dart` | 波形圆 + 状态文案（复用 `WaveformView`） |
| 3 | `app/lib/presentation/pages/detect/widgets/prediction_card.dart` | 未确认灰色态 + 确认态双形态 |
| 4 | `app/lib/presentation/pages/detect/widgets/ask_user_sheet.dart` | 二选一确认弹层（是/否） |
| 5 | `app/lib/presentation/pages/detect/widgets/behavior_metrics_row.dart` | 四项行为指标 |
| 6 | `app/lib/presentation/pages/detect/widgets/saved_record_banner.dart` | 「已自动记录」提示 + 跳条目详情 |
| 7 | `app/lib/presentation/providers/detect_providers.dart` | `DetectUiState` 状态机 + 事件订阅 + 聚合接入 |
| 8 | `app/lib/presentation/pages/detect/permission_flow.dart` | 授权 / 永久拒绝 / 「去设置」分支 |
| 9 | `app/test/widget/detect_page_test.dart` | `SPEC-U-02` §7 判据 1–7 |
| 10 | `app/test/unit/detect_state_machine_test.dart` | 状态迁移与阈值边界 |
| 11 | 真机实测记录（首次确认耗时 + 连续吃 30 s 不闪烁） | `docs/review/U-02_实测记录.md`（评审附件） |

## 2. 任务拆解（WBS）

| # | 任务 | 产出 | 工时 | 依赖 |
|---|---|---|---|---|
| 1 | 页面骨架 + `DetectUiState` 状态机 | `detect_page.dart`、`detect_providers.dart` | 2.5 h | U-06 |
| 2 | 权限流程（申请 / 拒绝 / 永久拒绝 / 去设置） | `permission_flow.dart` | 1.0 h | `PLAN-P-01` |
| 3 | `EventChannel` 订阅（`level` / `patch` / `sessionEnded`）与 `ackPatch` | `detect_providers.dart` | 2.0 h | B 就绪（D5） |
| 4 | 波形圆与状态文案（含 2 s 静默态） | `wave_circle.dart` | 1.0 h | 1、U-06 |
| 5 | 未确认灰色预测 | `prediction_card.dart` | 1.0 h | 3 |
| 6 | 确认结果卡片（三要素 + 保持上一态） | `prediction_card.dart` | 1.5 h | `P-06` |
| 7 | 二选一确认弹层（0.45–0.70） | `ask_user_sheet.dart` | 1.5 h | 6 |
| 8 | 行为指标区（四字段 + `--` 空值） | `behavior_metrics_row.dart` | 1.0 h | `P-07`（D7） |
| 9 | 「已自动记录」提示 + 落库接入 | `saved_record_banner.dart` | 1.0 h | `D-02` |
| 10 | 停止/静默结束收尾 + `clearTempAudio` | `detect_providers.dart` | 1.0 h | `PLAN-D-05` |
| 11 | 测试 + 真机实测（CP2 闭环） | 2 个测试文件 + 实测记录 | 2.5 h | 1–10 |

## 3. 技术方案

- **事件订阅集中在 Provider**：页面只 watch 状态，不直接持有 `EventChannel`（保持可测）。
- **`DetectUiState` 单一真源**：UI 分支只由状态决定，避免多个 bool 组合出非法形态。
- **确认卡片保持上一态**：`decisionProvider` 只在 `stage == confirmed` 时更新展示值，低置信 patch 不清空。
- **二选一不阻塞检测**：弹层期间**继续消费 patch 与电平**，不暂停会话（暂停会破坏 Mel 上下文连续性与 FF-21a 计时）。
- **音频不落盘**：本页不写任何文件；会话结束调 `clearTempAudio`（FF-24 第 2 条）。
- **骨架示意（≤30 行）**：

```dart
final detectProvider = StateNotifierProvider<DetectController, DetectUiState>(
    (ref) => DetectController(ref));

class DetectController extends StateNotifier<DetectUiState> {
  DetectController(this.ref) : super(const DetectUiState.idle()) {
    _sub = _events.listen(_onEvent);          // level / patch / sessionEnded
  }
  StreamSubscription? _sub;
  final Ref ref;

  Future<void> start() async {
    final perm = await audio.requestPermission();
    if (!perm.granted) {
      state = DetectUiState.error(perm.permanentlyDenied
          ? 'ACD-PERM-002' : 'ACD-PERM-001');
      return;
    }
    final id = 'S-${DateTime.now().millisecondsSinceEpoch}-${_hex4()}';
    await audio.startSession({'sessionId': id, 'autoEndOnSilence': true,
        'silenceEndSeconds': 90});            // 90 s = FF-21a
    state = state.toListening(id);
  }

  void _onEvent(Map<String, Object?> e) { /* patch → 推理 → 聚合 → 状态 */ }
}
```

## 4. 测试与验证

| 测试 | 类型 | 断言 | 何时跑 |
|---|---|---|---|
| `detect_state_machine_test.dart` | unit test | `SPEC-U-02` §7 判据 2 的全部合法迁移可达、非法迁移报 `ACD-SESS-002` | 每次提交 |
| 阈值边界 | unit test | 0.45/0.699 显示询问；0.70/0.449 不显示 | D5 |
| 不闪烁 | widget test | 连续 30 次 patch（含置信度下降）确认卡片文本不变 | D6 |
| 空值 `--` | widget test | `chewCount=null` 渲染 `--`，且页面上无 `0 次` | D7 |
| 确认卡片三要素 | widget test | 含 `label` / `\d+%` / `attribute` | D5 |
| 端到端闭环 | 真机手测（**CP2**） | 点按钮 → 4–5 s 内出确认结果 → 落库 → 首页可见 | D5 晚 |
| 连续吃 30 s | 真机手测 | 结果稳定不闪烁 | D6 |
| 首次确认耗时 | 真机实测记录 | 实测值落在 FF-20a 的 4–5 s 区间 | D5、D6 |
| 飞行模式全流程 | 手测（`API-05` §12 判据 2） | 无网络仍可完整检测 | D9 |
| 禁用词扫描 | shell | 「识别历史」「2 秒」等命中数 == 0 | D5、D9 |
| 人工核对表 | 人工 | `SPEC-U-02` §7 的 10 项全 ✓ | D5、D9 |

## 5. 完成定义（DoD）
- [ ] `SPEC-U-02` 第 7 节 12 项判据全部通过（含 10 项人工核对表逐项打钩）。
- [ ] 11 项交付物落盘可点开；真机实测记录（首次确认耗时、30 s 不闪烁）已归档。
- [ ] **CP2 判据达成**：真机点按钮 → 录音 → Mel → 推理 → 落库 → 页面显示结果。
- [ ] `10.png` 的「识别历史」模块**完全不存在**（`X-05`），代码中无残留。
- [ ] 页面无任何 kcal 孤立数字；如出现自动记录摘要，必带份量与「估算」。
- [ ] 全仓扫描：表外字段、营养素词、FF-25 禁用词、网络依赖均 0 命中。
- [ ] 无障碍：开始/停止按钮、确认卡片、二选一弹层均可被 TalkBack 朗读，弹层焦点顺序为「是」→「否」。

## 6. 风险与降级

| 风险 | 触发信号 | 降级动作 |
|---|---|---|
| D5 端到端未打通（CP2 未过） | 点按钮无结果 | 按 `PLAN-00` §2：D6 全天扑联调，**UI 只保留波形 + 确认卡片**，砍二选一与行为指标到 D7 |
| 结果卡片闪烁 | 真机连续吃 30 s 时文本跳变 | 提高确认保持阈值/延长保持时间窗（仅 UI 层做迟滞，**不改 FF-20 判据**） |
| 低置信度频繁弹层打扰演示 | 单次会话弹 > 2 次 | 同一类别在本会话只追问一次（`SPEC-U-02` §2.3 已规定），并做现场演练 |
| 推理过慢丢 patch > 5% | `droppedPatches` 比例超线 | 提高推理步长到 1.0 s（`PLAN-P-05`），波形与确认机制不变 |
| 行为指标 MAE 超线 | MAE > 25% | 按 FF-21g 降级为「咀嚼节奏：较快」，不给绝对数字 |
| 演示现场环境噪声 > 65 dB | 现场实测底噪高 | 切 Demo Mode B（注入自采 wav），UI 显示「示例演示」标识 |

## 7. 与检查点的关系
- **CP2（D5 晚）**：本功能是 CP2 的直接判据载体——「真机点按钮出结果」。未通过则 D6 全天扑联调，UI 与报告页砍到最简。
- **CP3（D9 午）**：本页是 Demo Mode A/B 的展示面；三模式实测必须包含本页的完整流程。
- 本功能属主方案 §8.2.1 不可砍项①，**任何 CP 失败时的降级清单都不得包含本页**；若必须削减，只削减其增强部分（行为指标、二选一弹层的动效）。

**文档结束**
