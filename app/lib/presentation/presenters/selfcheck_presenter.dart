// app/lib/presentation/presenters/selfcheck_presenter.dart
//
// M-04 (on-site self-check and degradation panel) **display** logic. PURE DART (no Flutter
// import).
//
// Boundary: the 14 checks and their pass rules live in exactly one place -- `DemoController`
// .runSelfCheck() (`lib/domain/service/demo_controller.dart`), which applies `API-04` section
// 7.1 -- and `SelfCheckKeys` (lib/domain/model/demo.dart) owns the frozen keys, labels and
// order. This file therefore **holds no second list and no second rule**; it renders whatever
// `SelfCheckReport` it is given, normalises it to the fourteen frozen rows, and derives the
// two panel-level judgements the SOP needs:
//
//  * the verdict line ("microphone side" vs "model side" vs "bridge/configuration"), so the
//    operator can tell the two apart while the judges are watching;
//  * the field action per failing item, which differs between item 3 ("can the model be used"
//    -> switch to Mode C) and item 11 ("which model, and is the input shape right" -> do not
//    demonstrate at all). That distinction is ADR-04's whole point and it is a *presentation*
//    concern, which is why it is here.
//
// `ambientNoise` is deliberately absent: ADR-04 froze the checklist at exactly 14 items and the
// noise reading belongs to the pre-show manual SOP.

import '../../core/errors.dart';
import '../../domain/model/demo.dart';
import 'ui_strings.dart';

/// One rendered checklist row.
class SelfCheckRowView {
  const SelfCheckRowView({
    required this.index,
    required this.key,
    required this.label,
    required this.passed,
    required this.observed,
    required this.hint,
    required this.statusText,
    required this.semanticsText,
  });

  /// 1-based position in the frozen order; the panel numbers its rows with it.
  final int index;
  final String key;
  final String label;
  final bool passed;

  /// The machine-readable observation; never empty, never a vague word.
  final String observed;

  /// Present only for a failed item (API-04 section 7.1).
  final String? hint;

  /// `通过` / `失败` -- the text channel of the mandatory text + colour double channel.
  final String statusText;

  final String semanticsText;
}

/// The whole panel: fourteen rows plus the verdict line.
class SelfCheckView {
  const SelfCheckView({
    required this.rows,
    required this.verdictText,
    required this.allPassed,
  });

  final List<SelfCheckRowView> rows;
  final String verdictText;
  final bool allPassed;

  bool get hasResults => rows.isNotEmpty;

  int get passedCount => rows.where((r) => r.passed).length;
  int get failedCount => rows.length - passedCount;

  /// The panel before its first run: no rows, and a verdict that says so instead of claiming
  /// everything is fine.
  static const SelfCheckView idle = SelfCheckView(
    rows: <SelfCheckRowView>[],
    verdictText: UiStrings.verdictUnknown,
    allPassed: false,
  );

  /// Normalises a report: whatever the service returned, the panel renders exactly the
  /// fourteen frozen keys in the frozen order. A missing item becomes an explicit failure
  /// rather than a silently shorter list, because a short list would hide a broken probe.
  ///
  /// **ADR-34**：回到 `ADR-14` 的 14 项（`ADR-27` 增加的第 15 项 `adviceModel` 已随端侧
  /// 语言模型一起删除）。
  static SelfCheckView of(SelfCheckReport report) {
    final rows = <SelfCheckRowView>[];
    var index = 0;
    for (final key in SelfCheckKeys.all) {
      index++;
      final label = SelfCheckKeys.labels[key] ?? key;
      final item = report.byKey(key);
      if (item == null) {
        final hint = SelfCheckPresenter.fieldActionFor(key);
        rows.add(SelfCheckRowView(
          index: index,
          key: key,
          label: label,
          passed: false,
          observed: UiStrings.selfCheckUnavailable,
          hint: hint,
          statusText: UiStrings.selfCheckFailedWord,
          semanticsText: '$label，${UiStrings.selfCheckFailedWord}，'
              '${UiStrings.selfCheckObservedLabel} ${UiStrings.selfCheckUnavailable}，$hint',
        ));
        continue;
      }
      final hint = item.passed ? item.hint : (item.hint ?? SelfCheckPresenter.fieldActionFor(key));
      rows.add(SelfCheckRowView(
        index: index,
        key: item.key,
        label: item.label.isEmpty ? label : item.label,
        passed: item.passed,
        observed: item.observed.isEmpty ? UiStrings.selfCheckUnavailable : item.observed,
        hint: hint,
        statusText: item.passed ? UiStrings.selfCheckPassedWord : UiStrings.selfCheckFailedWord,
        semanticsText: '$label，'
            '${item.passed ? UiStrings.selfCheckPassedWord : UiStrings.selfCheckFailedWord}，'
            '${UiStrings.selfCheckObservedLabel} ${item.observed}'
            '${hint == null ? '' : '，$hint'}',
      ));
    }
    return SelfCheckView(
      rows: rows,
      verdictText: SelfCheckPresenter.verdictOf(rows),
      allPassed: rows.isNotEmpty && rows.every((r) => r.passed),
    );
  }
}

abstract final class SelfCheckPresenter {
  SelfCheckPresenter._();

  /// Keys whose failure points at the capture side.
  static const Set<String> micSideKeys = {
    SelfCheckKeys.permission,
    SelfCheckKeys.mic,
  };

  /// Keys whose failure points at the inference side. Item 5 (feature config) is deliberately
  /// **not** here: a drift between the native and Dart feature configurations is not "the model
  /// is broken", it is a build/bridge fault, so it lands in the bridge verdict below.
  static const Set<String> modelSideKeys = {
    SelfCheckKeys.model,
    SelfCheckKeys.delegate,
    SelfCheckKeys.modelInfo,
    SelfCheckKeys.envelope,
  };

  /// The single line that answers "is this a microphone problem or a model problem"
  /// (SPEC-M-04 section 2.2 step 5).
  static String verdictOf(List<SelfCheckRowView> rows) {
    if (rows.isEmpty) return UiStrings.verdictUnknown;
    final failed = rows.where((r) => !r.passed).map((r) => r.key).toSet();
    if (failed.isEmpty) return UiStrings.verdictAllPassed;
    final mic = failed.any(micSideKeys.contains);
    final model = failed.any(modelSideKeys.contains);
    if (mic && model) return UiStrings.verdictBothSides;
    if (mic) return UiStrings.verdictMicSide;
    if (model) return UiStrings.verdictModelSide;
    // Everything else -- feature configuration, database, knowledge base, temporary files,
    // sample audio, session state, drop rate, demo data -- is a bridge or configuration
    // condition rather than one side of the capture/inference split.
    return UiStrings.verdictBothSides;
  }

  /// The field action suggested by a failing item. Kept separate from the item's own hint
  /// because the SOP reads them differently: item 3 means "fall back to Mode C", item 11 means
  /// "do not demonstrate at all" (ADR-04 / D22).
  static String fieldActionFor(String key) => switch (key) {
        SelfCheckKeys.model => '切换到 Mode C（报告演示）',
        SelfCheckKeys.modelInfo => '禁止演示，先重载模型',
        SelfCheckKeys.permission => '按权限提示重新授权或前往系统设置',
        SelfCheckKeys.mic => '关闭其他录音应用，或切换到 Mode B',
        SelfCheckKeys.featureConfig => '重启应用；仍不一致则禁止演示',
        SelfCheckKeys.envelope => '不要声称会给出咀嚼次数',
        SelfCheckKeys.dropRate => '提高推理步长至 1.0 s',
        SelfCheckKeys.db => '重启应用',
        SelfCheckKeys.knowledge => '检查 assets/foods.json',
        SelfCheckKeys.tempAudio => '手动清理或重启',
        SelfCheckKeys.sampleAudio => '改用实时模式',
        SelfCheckKeys.session => '先停止当前会话再切换模式',
        SelfCheckKeys.demoData => '改用实时模式',
        _ => '按实测值排查该数据源',
      };

  /// The mode label a mode button shows.
  static String modeLabel(DemoMode mode) => switch (mode) {
        DemoMode.realtime => UiStrings.modeRealtime,
        DemoMode.sampleAudio => UiStrings.modeSampleAudio,
        DemoMode.reportOnly => UiStrings.modeReportOnly,
      };

  /// The three mode buttons, in the order the panel renders them (A / B / C).
  static const List<DemoMode> modes = [
    DemoMode.realtime,
    DemoMode.sampleAudio,
    DemoMode.reportOnly,
  ];

  /// The suggested action after a failed mode switch, keyed by the error code. This is the
  /// presentation half of SPEC-M-04 section 6: the operator sees the code, a human-readable
  /// reason (the mapped domain message) and one concrete next step.
  static String switchActionFor(String code) => switch (code) {
        Codes.demoModeSwitch => '先停止当前会话；或先加载演示数据集',
        Codes.demoAsset => '改用实时模式，或校验示例音频资产',
        Codes.demoDataset => '检查 assets/demo_dataset.json',
        Codes.cfgMismatch => '重启应用；仍不一致则禁止演示',
        Codes.inferLoad => '重试加载模型（模型侧问题）',
        Codes.permDenied || Codes.permPermanentlyDenied => '重试授权；永久拒绝则前往系统设置',
        Codes.audioRecordInitFailed || Codes.audioDeviceBusy => '重启应用，或切换到其他模式',
        Codes.dbTransaction => '重试一次；持续失败则改用实时模式',
        Codes.ioCleanup => '仅记日志，不阻断演示',
        _ => '按错误码排查后重试',
      };
}
