// app/lib/presentation/presenters/settings_presenter.dart
//
// U-05 ("my" / settings) display logic. PURE DART (no Flutter import).
//
// The important, non-obvious rules:
//  * "已坚持 N 天" is a **dynamic** count fed by `StatsRepo.activeDays()`; a `null` (the port is
//    not ready) renders the empty marker -- the page never scans the table itself and never
//    hard-codes a day count;
//  * achievements are static: a `const` list, no unlock logic, no progress, no animation;
//  * the file-export entry stays disabled and labelled "v1.1" (X-03);
//  * ADR-P4: the portability action is "copy as text" -- it writes **only** the system
//    clipboard, never a file, never a share intent, never the network. The payload is built
//    here from contract-table fields alone (time / food / kcalRange / confidence / attribute).

import '../../domain/model/diet_record.dart';
import '../../domain/model/food_info.dart';
import '../../domain/service/behavior_analyzer.dart';
import '../../domain/service/portion_estimator.dart';
import '../theme/acou_format.dart';
import 'food_catalog.dart';
import 'ui_strings.dart';

/// One statically displayed achievement badge (X-04: display only, never an unlock check).
class AchievementView {
  const AchievementView({required this.title, required this.subtitle});

  final String title;
  final String subtitle;
}

/// Everything the settings page renders.
class SettingsView {
  const SettingsView({
    required this.nicknameText,
    required this.activeDaysText,
    required this.activeDaysKnown,
    required this.versionText,
    required this.achievements,
    required this.portabilityNotice,
    required this.privacyNotice,
    required this.privacyLossNotice,
    required this.clearConfirmText,
    required this.exportEntryText,
    required this.exportEntryBadge,
    required this.demoActive,
    required this.copyEnabled,
    required this.recordCount,
    required this.overviewRecordCountText,
    required this.overviewSnackCountText,
    required this.overviewSpeedText,
  });

  final String nicknameText;

  /// `已坚持 3 天` / `已坚持 -- 天`.
  final String activeDaysText;
  final bool activeDaysKnown;

  final String versionText;
  final List<AchievementView> achievements;

  final String portabilityNotice;
  final String privacyNotice;
  final String privacyLossNotice;
  final String clearConfirmText;

  final String exportEntryText;
  final String exportEntryBadge;

  final bool demoActive;

  /// `false` when there is nothing to copy: the button is disabled rather than copying an
  /// empty payload.
  final bool copyEnabled;
  final int recordCount;

  /// ADR-24 · the three-up 「本周健康数据概览」 panel (mockup 9).
  ///
  /// All three read the **same** seven-day window the report page calls 「本周」, and two of them
  /// are the frozen `WeekSummary` counters; the speed tile is the grade word of `ChewStats`'
  /// mean interval, produced by `BehaviorAnalyzer.speedGradeFor` -- the mapping a live session
  /// uses. There is deliberately no fourth, invented metric.
  ///
  /// When a single query fails the whole panel degrades to `--` (`overviewAvailable == false`),
  /// and a window with **no** chewing sample says `无样本` rather than `正常`: an absent sample is
  /// not a normal speed.
  final String overviewRecordCountText;
  final String overviewSnackCountText;
  final String overviewSpeedText;

  /// A-04-K3 badge, shown on the settings page as well (SPEC-A-04 criterion 7 wants the badge
  /// on all four pages).
  String get demoBadgeText => demoActive ? UiStrings.demoDataBadge : '';

  static SettingsView of({
    required String? nickname,
    required int? activeDays,
    required String versionText,
    bool demoActive = false,
    int recordCount = 0,
    bool activeDaysUnavailable = false,
    int? weekRecordCount,
    int? weekSnackCount,
    double? meanChewIntervalSeconds,
    bool overviewUnavailable = false,
  }) =>
      SettingsView(
        nicknameText: (nickname == null || nickname.isEmpty)
            ? UiStrings.nicknameUnset
            : nickname,
        activeDaysText: activeDaysUnavailable
            ? UiStrings.activeDaysText(null)
            : UiStrings.activeDaysText(activeDays),
        activeDaysKnown: !activeDaysUnavailable && activeDays != null,
        versionText: versionText,
        achievements: SettingsPresenter.achievements,
        portabilityNotice: UiStrings.portabilityNotice,
        privacyNotice: UiStrings.privacyNotice,
        privacyLossNotice: UiStrings.privacyLossNotice,
        clearConfirmText: UiStrings.clearConfirmText,
        exportEntryText: UiStrings.exportEntryText,
        exportEntryBadge: UiStrings.exportEntryBadge,
        demoActive: demoActive,
        copyEnabled: recordCount > 0,
        recordCount: recordCount,
        overviewRecordCountText: overviewUnavailable || weekRecordCount == null
            ? AcouFormat.noValue
            : '$weekRecordCount ${UiStrings.snackCountSuffix}',
        overviewSnackCountText: overviewUnavailable || weekSnackCount == null
            ? AcouFormat.noValue
            : '$weekSnackCount ${UiStrings.snackCountSuffix}',
        overviewSpeedText: overviewUnavailable
            ? AcouFormat.noValue
            : (meanChewIntervalSeconds == null
                ? UiStrings.overviewNoSample
                : BehaviorAnalyzer.speedGradeFor(meanChewIntervalSeconds)),
      );
}

abstract final class SettingsPresenter {
  SettingsPresenter._();

  /// X-04: a fixed pair of badges. Deliberately not a computed list -- there is no unlock rule
  /// and no progress anywhere in this feature.
  static const List<AchievementView> achievements = [
    AchievementView(title: '记录起步', subtitle: '完成第一次 AI 检测'),
    AchievementView(title: '本地优先', subtitle: '音频不落盘，数据只在本机'),
  ];

  /// §6: the fallback when the build-time version cannot be read. It is a build constant, so it
  /// is never a fabricated runtime value.
  static const String fallbackVersionText = 'v1.0';

  /// `已坚持 N 天`, with the empty marker while `activeDays()` is unavailable. The day count is
  /// deliberately cumulative, not a streak (SPEC-U-05 section 2.4).
  static String activeDaysText(int? days) => UiStrings.activeDaysText(days);

  /// X-03 stays cut: the entry is present but inert.
  static const bool exportEntryEnabled = false;

  /// The clipboard payload of the ADR-P4 action. **Contract fields only**:
  /// `time` / `food` / `kcalRange` / `confidence` / `attribute` -- no other field may appear
  /// (risk R-19), and every kilocalorie keeps its estimate wording (FF-25).
  ///
  /// [catalog] may be an unloaded knowledge base, in which case the food name degrades to the
  /// unknown-category placeholder and the kilocalorie columns are omitted rather than guessed.
  static String clipboardText(
    List<DietRecord> records,
    FoodCatalog catalog,
  ) {
    final buffer = StringBuffer()
      ..writeln(UiStrings.appTitle)
      ..writeln(UiStrings.copyAsText)
      ..writeln(UiStrings.privacyLossNotice);
    if (records.isEmpty) {
      buffer.writeln(UiStrings.recordsEmpty);
      return buffer.toString();
    }
    for (final r in records) {
      buffer.writeln(clipboardLine(r, catalog));
    }
    return buffer.toString();
  }

  /// One line: `12:20 面条 · 置信度 88% · 软性主食 · 1 片（估算）≈120 kcal`.
  ///
  /// The time and the food class are always present (SPEC-U-05 criterion 11).
  static String clipboardLine(DietRecord record, FoodCatalog catalog, {FoodInfo? food}) {
    final info = food ?? catalog.byClassId(record.classId);
    final name = info?.zhName ?? UiStrings.unknownCategory;
    final parts = <String>[
      AcouFormat.clock(record.eatenAtMs),
      name,
      AcouFormat.confidence(record.confidence),
    ];
    if (info != null) {
      // ADR-23: the clipboard carries the same per-record estimate the card shows.
      parts.add(AcouFormat.recordKcalCombined(
        record.attribute,
        PortionEstimator.of(info, durationSeconds: record.durationSeconds),
      ));
    } else {
      parts.add(record.attribute);
    }
    return parts.join(' · ');
  }
}
