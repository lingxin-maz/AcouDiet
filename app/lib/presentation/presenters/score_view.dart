// app/lib/presentation/presenters/score_view.dart
//
// The display projection of a `HealthScore`, shared by `U-01` (score card + radar) and `U-04`
// (report card + dimension drill-down). Keeping one implementation is what makes the
// SPEC-C-05 cross-function consistency assertion meaningful: the home page and the report page
// cannot disagree, because they read the same projection of the same `HealthScore` object.
//
// PURE DART (no Flutter import). Nothing here recomputes a score: every number is read from a
// `DimensionScore` / `HealthScore` produced by `HealthScoreService` (API-04 section 3).

import '../../domain/model/health_score.dart';
import '../../domain/service/health_score_service.dart';
import '../../domain/service/score_formulas.dart';
import '../theme/acou_format.dart';
import 'ui_strings.dart';

/// One evidence key, rendered as a Chinese label plus its observed value.
///
/// The key set is the contract (API-04 section 3); an unknown key is rendered verbatim rather
/// than dropped, so a contract drift shows up on screen instead of silently disappearing.
class EvidenceLine {
  const EvidenceLine({required this.key, required this.label, required this.text});

  final String key;
  final String label;
  final String text;

  static const Map<String, String> labels = {
    'sigmaMinutes': '三餐时间标准差 σ',
    'mealTimeSamples': '有效餐次样本数',
    'windowDays': '窗口天数',
    'healthyRatio': '健康食物占比 p',
    'healthyCount': '健康食物条数',
    'totalCount': '窗口记录总数',
    'snackCount': '零食次数 n',
    'lateNightCount': '晚间进食次数',
    'avgChewIntervalSeconds': '平均咀嚼间隔 t',
    'sampleCount': '有效指标条数',
    'missingMetricsCount': '缺失指标条数',
  };

  /// Formats one evidence value. Units are attached here (the domain layer never formats).
  static String formatValue(String key, Object? value) {
    if (value == null) return AcouFormat.noValue;
    switch (key) {
      case 'sigmaMinutes':
        return '${(value as num).toStringAsFixed(1)} 分钟';
      case 'avgChewIntervalSeconds':
        return '${(value as num).toStringAsFixed(1)} 秒';
      case 'healthyRatio':
        return AcouFormat.percent((value as num).toDouble());
      default:
        return '$value';
    }
  }
}

/// One radar axis / drill-down row.
class ScoreAxisView {
  const ScoreAxisView({
    required this.dimension,
    required this.label,
    required this.score,
    required this.max,
    required this.displayable,
    required this.formulaText,
    required this.evidence,
  });

  /// `regularity` / `structure` / `snack` / `speed` -- matches `ScoreFormulas.formulaOf`.
  final String dimension;
  final String label;
  final int score;
  final int max;

  /// `false` when the dimension has no computable basis (its evidence is `null`): the row
  /// renders the empty marker and contributes no number to the total (U-04 section 2.4).
  final bool displayable;

  /// The single authoritative formula string (A-01-K5) -- never re-written here.
  final String formulaText;

  final List<EvidenceLine> evidence;

  /// `26/30`, or the empty marker.
  String get scoreText => displayable ? AcouFormat.ratio(score, max) : AcouFormat.noValue;

  /// `饮食规律性 26/30`, or `饮食规律性 --`.
  String get ratioText =>
      displayable ? '$label ${AcouFormat.ratio(score, max)}' : '$label ${AcouFormat.noValue}';

  /// The radar value actually plotted: an undisplayable axis collapses to the centre.
  double get radarValue => displayable ? score.toDouble() : 0;

  /// `饮食规律性 分 26 分，满分 30 分` for the chart's text equivalent.
  String get semanticsText =>
      displayable ? '$label $score 分，满分 $max 分' : '$label ${AcouFormat.noValue}';
}

/// Everything the score card (U-01) and the report header (U-04) display about a score.
class ScoreView {
  const ScoreView({
    required this.score,
    required this.totalDisplayable,
    required this.totalText,
    required this.gradeText,
    required this.deltaText,
    required this.axes,
    required this.semanticsText,
  });

  final HealthScore? score;

  /// `false` when the scoring service itself failed: every numeric field renders the empty
  /// marker and the radar is empty (SPEC-U-01 section 6 / SPEC-U-04 section 6).
  bool get available => score != null;

  /// SPEC-A-01 section 4 `--` rules: the total is hidden when any of the three inputs the
  /// four formulas need is missing. A partial sum would be a fabricated number.
  final bool totalDisplayable;

  /// `85`, or the empty marker.
  final String totalText;

  /// `良好` / `一般` / `需改善`, or the empty marker.
  final String gradeText;

  /// Three-state delta (ADR-10): `null` means the row is hidden; `持平`; `↑12 分`.
  final String? deltaText;

  /// Always exactly four axes, in the FF-22 order.
  final List<ScoreAxisView> axes;

  /// `今日健康评分 85 分，评级良好，比昨天高 12 分` (U-01 section 8).
  final String semanticsText;

  bool get deltaVisible => deltaText != null;

  /// The four dimensions as `label score/max`, used by the drill-down sheet header.
  List<String> get ratioTexts => axes.map((a) => a.ratioText).toList(growable: false);

  /// Plain-text equivalent of the radar, read out instead of the picture (U-06 section 8).
  String get radarSemantics => UiStrings.radarSemantics(
        axes.map((a) => a.semanticsText).join('；'),
        totalText,
      );

  /// The inputs behind the four bars, e.g. `记录 12 次 · 零食 2 次 · 有咀嚼指标 9 条`.
  ///
  /// ADR-23 added this line because a bar is not self-explanatory: 「零食控制 20/20」 looks
  /// like an unexplained maximum until the reader can see that it means *zero snacks*, and
  /// 「食物结构 --」 looks broken until the record count explains why. Empty when the score
  /// itself is unavailable.
  String get inputCaption {
    final s = score;
    if (s == null) return '';
    final total = (s.structure.evidence['totalCount'] as num?)?.toInt() ?? 0;
    final snacks = (s.snack.evidence['snackCount'] as num?)?.toInt() ?? 0;
    final chewSamples = (s.speed.evidence['sampleCount'] as num?)?.toInt() ?? 0;
    return '记录 $total 次 · 零食 $snacks 次 · 有咀嚼指标 $chewSamples 条';
  }

  /// The projection of a real service result.
  static ScoreView of(HealthScore score) {
    final totalCount = (score.structure.evidence['totalCount'] as num?)?.toInt() ?? 0;
    final sigma = score.regularity.evidence['sigmaMinutes'];
    final interval = score.speed.evidence['avgChewIntervalSeconds'];

    final regularityOk = sigma != null && totalCount > 0;
    // ADR-23: a ratio over one or two records is not a "structure" -- one bowl of noodles made
    // the healthy ratio 100% and pinned this axis at 30/30 (the user's report: 「吃一顿面条就
    // 30/30 满分」). Below the page-level record threshold the axis is honestly undetermined.
    final structureOk = totalCount >= HealthScoreService.minimumRecordsForDisplay;
    // A snack count of zero with no records at all would score a perfect 20 -- that is exactly
    // the "invented number" the empty state exists to prevent.
    final snackOk = totalCount > 0;
    final speedOk = interval != null && totalCount > 0;

    final totalDisplayable = regularityOk && structureOk && speedOk;

    final axes = <ScoreAxisView>[
      _axisOf(score.regularity, 'regularity', regularityOk),
      _axisOf(score.structure, 'structure', structureOk),
      _axisOf(score.snack, 'snack', snackOk),
      _axisOf(score.speed, 'speed', speedOk),
    ];

    final amount = score.deltaVsYesterday;
    final delta = totalDisplayable ? AcouFormat.deltaText(amount) : null;

    return ScoreView(
      score: score,
      totalDisplayable: totalDisplayable,
      totalText: totalDisplayable ? '${score.totalScore}' : AcouFormat.noValue,
      gradeText: totalDisplayable ? score.grade : AcouFormat.noValue,
      deltaText: delta,
      axes: axes,
      semanticsText: UiStrings.scoreSemantics(
        total: totalDisplayable ? '${score.totalScore}' : AcouFormat.noValue,
        grade: totalDisplayable ? score.grade : AcouFormat.noValue,
        delta: delta,
      ),
    );
  }

  /// The projection used when the scoring service failed: the four axis **labels** (which are
  /// frozen, not data) are still rendered so the radar keeps its shape, but every number is the
  /// empty marker. No `HealthScore` is invented to satisfy a widget.
  static ScoreView unavailable() {
    const specs = <(String, String, int)>[
      ('regularity', ScoreFormulas.labelRegularity, 0),
      ('structure', ScoreFormulas.labelStructure, 0),
      ('snack', ScoreFormulas.labelSnack, 0),
      ('speed', ScoreFormulas.labelSpeed, 0),
    ];
    final axes = <ScoreAxisView>[];
    for (final s in specs) {
      axes.add(ScoreAxisView(
        dimension: s.$1,
        label: s.$2,
        score: 0,
        max: _weightOf(s.$1),
        displayable: false,
        formulaText: ScoreFormulas.formulaOf(s.$1),
        evidence: const <EvidenceLine>[],
      ));
    }
    return ScoreView(
      score: null,
      totalDisplayable: false,
      totalText: AcouFormat.noValue,
      gradeText: AcouFormat.noValue,
      deltaText: null,
      axes: axes,
      semanticsText: UiStrings.scoreSemantics(
        total: AcouFormat.noValue,
        grade: AcouFormat.noValue,
        delta: null,
      ),
    );
  }

  /// Dimension weights come from the SSOT, never from a literal (FF-22 / `health_score_weights`).
  static int _weightOf(String dimension) => switch (dimension) {
        'regularity' => ScoreFormulas.maxRegularity,
        'structure' => ScoreFormulas.maxStructure,
        'snack' => ScoreFormulas.maxSnack,
        'speed' => ScoreFormulas.maxSpeed,
        _ => 0,
      };

  static ScoreAxisView _axisOf(DimensionScore d, String dimension, bool displayable) {
    final evidence = <EvidenceLine>[];
    for (final entry in d.evidence.entries) {
      evidence.add(EvidenceLine(
        key: entry.key,
        label: EvidenceLine.labels[entry.key] ?? entry.key,
        text: EvidenceLine.formatValue(entry.key, entry.value),
      ));
    }
    return ScoreAxisView(
      dimension: dimension,
      label: d.label,
      score: d.score,
      max: d.max,
      displayable: displayable,
      formulaText: ScoreFormulas.formulaOf(dimension),
      evidence: evidence,
    );
  }
}
