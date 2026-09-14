// app/lib/presentation/presenters/ui_strings.dart
//
// Every frozen user-visible string of the L5 layer, in one place so that a copy change is a
// one-line change and so that `tool/ui_presenter_tests.dart` can scan the whole set at once.
//
// PURE DART (no Flutter import).
//
// FF-25 discipline: the banned wording is deliberately **not** written down anywhere under
// `lib/` -- the repository-wide safety scan must stay at zero hits, so the negative list lives
// in `tool/ui_presenter_tests.dart`, which scans every string this file produces.

import '../theme/acou_format.dart';

/// Frozen copy shared by more than one page, or mandated verbatim by a SPEC.
abstract final class UiStrings {
  UiStrings._();

  // ---------------------------------------------------------------- brand

  /// FF-23 / visual-correction list: one brand string only.
  static const String appName = 'AcouDiet';
  static const String appNameZh = '声膳';
  static const String appTitle = 'AcouDiet · 声膳';

  /// ADR-38: the wordmark of the four inner pages' top bar.
  ///
  /// Not a second brand -- [appName] itself, drawn without the locale suffix, because that bar
  /// shares its width with a centred page title and two actions (the mockups drop the suffix in
  /// exactly the same place). The home header keeps the full [appTitle].
  static const String appBrandShort = appName;

  // ---------------------------------------------------------------- shared states

  /// A-04-K3: the demonstration-data badge, verbatim; `U-01`/`U-03`/`U-04`/`U-05` share it.
  static const String demoDataBadge = '演示数据';

  /// `API-01` section 3.2: the injected-audio badge, triggered **only** by
  /// `patch.source == "inject"` (never by `DietRecord.source`).
  static const String sampleDemoBadge = '示例演示';

  /// U-06 section 2.4: an out-of-range `classId` renders this instead of guessing a name.
  static const String unknownCategory = '未知类别';

  /// The retry affordance of the error state; only offered when `retryable == true`.
  static const String retry = '重试';

  /// ADR-10 / `x`-state rules: the flat wording and the empty marker come from [AcouFormat].
  static const String empty = AcouFormat.noValue;

  // ---------------------------------------------------------------- U-01 home

  static const String homeTitle = appTitle;

  /// ADR-24: the home header of the delivered mockups. The greeting is decorative; the second
  /// line is **gated on data**, because claiming an analysis on an empty day would be a claim the
  /// app cannot back (the same reason `homeEnergyEmpty` exists).
  static const String homeGreeting = 'Hi，今天也要好好吃饭呀！';
  static const String homeGreetingWithData = '已为你分析今日饮食';
  static const String homeGreetingEmpty = '今天还没有记录，点下面开始检测';

  static const String homeTodayRecordsEmpty = '今天还没有记录';

  /// The section header above the today list. `SPEC-U-01` §3 names the section
  /// 「今日记录列表」 and freezes only the *empty* string; this header mirrors the sibling
  /// wording (`本周记录` / `饮食记录`) instead of inventing new copy.
  static const String homeTodayRecordsTitle = '今日记录';
  static const String homeEnergyEmpty = '暂无数据';
  static const String weekRecordPrefix = '本周记录';

  /// SPEC-U-01 section 6: a failed week aggregate reads `本周记录 -- 次` -- the unit stays, so
  /// the row never looks like a truncated sentence.
  static String weekRecordCount(int? count) =>
      '$weekRecordPrefix ${count == null ? '$empty $snackCountSuffix' : '$count 次'}';
  static const String viewAll = '查看全部';
  static const String startDetect = '开始 AI 检测';
  static const String myEntry = '我的';

  // ---- ADR-34: the「AI 周综述」card was REMOVED with the on-device language model.
  // The `aiReview*` strings lived here; they are gone along with the widget. If a future
  // version reintroduces model-generated prose, restore them *with* the provenance label
  // (`aiReviewFromModel` / `aiReviewFromFallback`) -- that label existed because "the user
  // cannot tell whether a model wrote this" was a real, reported defect in v1.1.0.

  /// ADR-23: the home score card moved from 「今日」 to a seven-day window, because σ (三餐时间
  /// 标准差) needs at least two samples per meal class and the speed dimension needs at least
  /// one chewing sample -- a single day is structurally under-determined and showed `--` (or a
  /// saturated 30/30) no matter how much was eaten. The energy row, the week counter and the
  /// record list on the same page stay "today".
  static const String scoreCardTitle = '近 7 天健康评分';
  static const String scoreWindowLabel = '近 7 天';

  /// The comparison window follows the score window (ADR-23): the previous equal-length window,
  /// not "yesterday", which is what the old hard-wired `startOfLocalDay(range.start - 1)` meant.
  static const String deltaRowLabel = '较上一周期';
  static const String privacyDialogTitle = '隐私说明';
  static const String privacyDialogBody =
      '音频只在内存中处理，不写入存储；本应用不申请网络权限。';
  static const String privacyDialogOk = '知道了';

  // ---------------------------------------------------------------- U-02 detect

  static const String detectTabTitle = 'AI 检测';
  static const String detectStart = '开始检测';
  static const String detectStop = '停止检测';
  static const String detectWaiting = '等待进食声…';
  static const String detectListening = '正在感知进食声音…';
  static const String detectEnded = '已结束';
  static const String detectSensing = '正在感知…';
  static const String detectUnconfirmedHint = '未确认';
  static const String detectUnrecognised = '未识别到明确食物';
  static const String detectSaved = '已自动记录';
  static const String detectAgain = '再次检测';
  static const String askUserYes = '是';
  static const String askUserNo = '否';
  static String askUserText(String label) => '疑似 $label，请确认？';

  /// FF-20a: the only legal latency wording. See [firstConfirmNote].
  static const String firstConfirmHint = '从开始进食到首次确认结果约 4–5 秒';

  /// FF-21g: the MAE-degraded copy -- deliberately carries **no digit at all**.
  static const String chewRhythmDegraded = '咀嚼节奏：较快';

  static const String behaviorChewLabel = '咀嚼次数';
  static const String behaviorIntervalLabel = '平均咀嚼间隔';
  static const String behaviorDurationLabel = '进食时长';
  static const String behaviorSpeedLabel = '进食速度';

  // ---------------------------------------------------------------- U-03 records

  static const String recordsTitle = '饮食记录';
  static const String recordsEmpty = homeTodayRecordsEmpty;
  static const String recordsListError = '暂时无法读取记录';
  static const String recordsSummaryError = '-- / -- / --';
  static const String summaryBarLabel = '今日估算';
  static const String snackCountSuffix = '次';
  static const String weekSummaryCardTitle = '本周小结';
  static const String weekSummaryInsufficient = '数据不足';

  /// ADR-24: the meal chip row above the timeline (the mockups' 早餐 / 午餐 / 晚餐 / 零食 row).
  ///
  /// The mockup's four chips are **not** a partition of the data once ADR-23 is in force: a drink
  /// at 15:40 is neither a snack nor a meal sample, so folding it into 零食 would make the chip
  /// filter disagree with the 零食 count on the bar right above it. 饮品 is therefore a fifth
  /// bucket, and every record belongs to exactly one bucket.
  static const String recordsMealFilterAll = '全部';
  static const String recordsMealBreakfast = '早餐';
  static const String recordsMealLunch = '午餐';
  static const String recordsMealDinner = '晚餐';
  static const String recordsMealSnack = '零食';
  static const String recordsMealDrink = '饮品';

  /// The three items of the records stats bar. The estimate word stays attached to the number
  /// (FF-25), which is why the first label does not repeat 「估算」.
  static const String recordsStatKcalLabel = '今日热量';
  static const String recordsStatCountLabel = '已记录';
  static const String recordsStatSnackLabel = '零食';

  /// Shown when the active meal chip matches nothing (ADR-24), prefixed by the chip's own name so
  /// the blank list is never read as "no records at all".
  static const String recordsFilteredEmpty = '这一餐段还没有记录';

  /// ADR-24: the mockups' blocks that were added after the first UI pass.
  ///
  /// 「最近识别记录」 is **not a new metric**: it is the newest few rows of the same 7-day record
  /// window the records page already reads, rendered with the same `RecordCardText` template. It
  /// exists because the mockup draws it, and it is deliberately capped and labelled so it cannot
  /// be mistaken for a complete history.
  static const String reportRecentTitle = '最近识别记录';
  static const String reportRecentNote = '记录页同一窗口里最新的 6 条';

  /// The profile page's three-up panel (mockup 9). Same seven-day window as the report page.
  static const String overviewTitle = '本周健康数据概览';
  static const String overviewRecordsLabel = '总进食次数';
  static const String overviewSpeedLabel = '平均咀嚼速度';
  static const String overviewSnackLabel = '零食次数';

  /// Shown inside the overview tile when the window has no chewing sample at all -- the grade word
  /// is `--`, never `正常` (an absent sample is not a normal speed).
  static const String overviewNoSample = '无样本';

  /// The panel's footnote: it says which window the three tiles read and which one of them is a
  /// grade rather than a count.
  static const String overviewNote = '最近 7 个本地日；与报告页「本周」同一窗口，咀嚼速度为窗口内的平均档';
  static const String recordDetailTitle = '记录详情';
  static const String detailBasicSection = '基本信息';
  static const String detailRecognitionSection = '识别信息';
  static const String detailBehaviorSection = '当次行为分析';
  static const String detailKnowledgeSection = '知识库信息';
  static const String detailSourceSection = '来源';

  /// ADR-P6: the **only** confirmation badge the UI may ever render.
  static const String confirmedBadge = '已确认';

  static const String detailFoodName = '食物';
  static const String detailAttribute = '属性';
  static const String detailEatenAt = '记录时间';
  static const String detailConfidence = '置信度';
  static const String detailConfirmed = '是否已确认';
  static const String detailPortion = '标准份量';

  /// ADR-23: this record's own estimate, derived from its eating duration.
  static const String detailEstimatedAmount = '本次估算用量';
  static const String detailKcal = '估算热量';
  static const String detailRiskNote = '提示';
  static const String detailNoDataSpoken = '无数据';

  /// The knowledge-base block must state its origin and stay visually apart from confidence.
  static const String knowledgeOriginNote = '来自食物知识库估算，非模型输出';
  static const String recordMissing = '记录已不存在';

  // ---------------------------------------------------------------- U-04 report

  static const String reportTitle = '本周';
  static const String reportTrendTitle = '本周趋势';

  /// ADR-23: the report page carries **two** scopes in one page, switched by swiping (or by the
  /// segmented control) and **opening on 「每日」**. The weekly scope keeps the frozen title
  /// `本周` (SPEC-U-04 acceptance 1); the daily scope is the new one.
  static const String reportDailyTitle = '每日报告';
  static const String reportScopeDaily = '每日';
  static const String reportScopeWeekly = '本周';
  static const String reportScopeHint = '左右滑动切换每日 / 本周';
  /// ADR-25: the 每日 numbers are scored over the seven local days **ending** on that day, because
  /// a single calendar day cannot define σ (it needs two samples of the *same* meal). The three
  /// strings below therefore name the window; a score covering a week must never be read as that
  /// day's own score.
  ///
  /// ⚠️ **ADR-30: [reportDailyScoreTitle] is deliberately NOT rendered anywhere.** The 每日 scope
  /// used to show it as a standalone heading directly above the day's `ScoreCard`, whose own title
  /// is that same date -- so the date appeared twice in a row (reported by the user, and ADR-30
  /// removed the heading). The constant is kept because it is the frozen `SPEC-U-04` wording and
  /// names the window the number is scored over; the obligation to "say the window out loud" is
  /// now carried by the ScoreCard title + [reportDailySingleDayNote].
  ///
  /// If you render it again, you must also update `tool/ui_fingerprint_check.py`, which lists this
  /// exact string under "must be ABSENT" as evidence of the current UI.
  static const String reportDailyScoreTitle = '近 7 天评分（截至该日）';

  static const String reportDailySummaryTitle = '当日汇总';
  static const String reportDailyListTitle = '每日评分';
  static const String reportDailyListNote = '每个有记录的日子一个评分（该日及之前 6 天）；无记录的日子不列出，点一天看该日明细';
  static const String reportDailyPickTitle = '选择日期';
  static const String reportDailyCountLabel = '记录次数';
  static const String reportDailySnackLabel = '零食次数';
  static const String reportDailyKcalLabel = '估算热量';
  static const String reportDailyClassesLabel = '食物类别';
  static const String reportDailySingleDayNote =
      '评分按「该日及之前 6 天」共 7 个本地日计算（σ 需同一餐段 ≥2 条样本，单日无法成立），'
      '因此卡片里那行「记录 N 次」是这 7 天的；下面的「当日汇总」才是该日自己的数据';
  static const String reportTrendScoreNote = '评分口径：该日及之前 6 天（近 7 天）';
  static const String reportAxisScore = '评分';
  static const String reportAxisKcal = '估算热量';
  static const String reportInsufficient = '暂无足够数据';
  static const String reportInsufficientFew = '本周记录较少，暂不生成完整报告';
  static const String adviceEmpty = '暂不生成建议';
  static const String adviceTitle = '健康建议';
  static const String deltasTitle = '环比变化';

  /// §8: the footer is always present, in the `ready` and `insufficient` states alike.
  static const String disclaimerText =
      '本页数值来自知识库与标准份量的估算，不作为医学依据。';
  static const String trendNoDataWord = '无数据';
  static const String kcalUnit = '千卡';

  // ---------------------------------------------------------------- U-05 profile

  static const String profileTitle = '我的';
  static const String nicknameUnset = '未设置昵称';
  static const String activeDaysPrefix = '已坚持';
  static const String activeDaysSuffix = '天';
  static const String achievementsTitle = '我的成就';

  /// SPEC-U-05 §4.3, verbatim.
  static const String portabilityNotice =
      '你的记录仅保存在本机。卸载应用或更换手机后数据将无法找回，v1.0 不提供导出功能。';
  static const String privacyNotice =
      '本应用不申请网络权限，无法上传任何数据；音频只在内存中处理，不写入存储。';
  static const String privacyLossNotice = '数据仅存于本机，卸载即丢失。';
  static const String clearConfirmText = '将删除全部饮食记录与本地档案，且无法恢复。是否继续？';
  static const String exportEntryText = '数据导出将在 v1.1 提供';
  static const String exportEntryBadge = 'v1.1';
  static const String exportEntrySpoken = '数据导出，v1.1 提供，当前不可用';
  static const String exportEntryTitle = '数据导出';
  static const String copyAsText = '复制为文本';
  static const String copiedToClipboard = '已复制到剪贴板';
  static const String copyFailed = '复制失败，请重试';
  static const String clearAllData = '清空全部数据';
  static const String clearDemoData = '清除演示数据';
  static const String clearFailed = '清空失败，请重试';
  static const String cancel = '取消';
  static const String confirm = '确认';
  static const String privacyTitle = '隐私设置';
  static const String aboutTitle = '关于 AcouDiet';
  static const String healthReportEntry = '健康报告';
  static const String healthReportEntrySpoken = '健康报告，查看周度饮食分析与建议';
  static const String selfCheckEntry = '现场自检';
  static const String selfCheckEntrySpoken = '现场自检，检查麦克风与模型是否可用';
  static const String privacyEntrySpoken = '隐私设置，查看无网络权限与音频不落盘说明';
  static const String aboutEntrySpoken = '关于 AcouDiet，查看版本与合规说明';

  // ADR-38: the one-line description under each entry, which mockup `9.png` draws on every row and
  // which this page was the only one to omit.
  //
  // ⚠️ Each is **exactly the clause after the comma of that row's `spoken` label** -- not merely
  // "similar to it". The page has one sentence to say about each entry, and this slice of it is
  // already in the accessibility tree; repeating a slice cannot introduce a claim the row did not
  // already make. `test/ui/mockup_layout_test.dart` asserts the slice relationship for all four, so
  // a description that drifts away from its own row's spoken label fails rather than ships.
  static const String healthReportEntrySubtitle = '查看周度饮食分析与建议';
  static const String privacyEntrySubtitle = '查看无网络权限与音频不落盘说明';
  static const String selfCheckEntrySubtitle = '检查麦克风与模型是否可用';
  static const String aboutEntrySubtitle = '查看版本与合规说明';
  static const String saveFailed = '设置未保存，请重试';
  static const String versionPrefix = '版本';

  /// SPEC-U-05 section 4.2: while `activeDays()` is not ready the row reads `已坚持 -- 天`.
  static String activeDaysText(int? days) => '$activeDaysPrefix '
      '${days == null ? '$empty $activeDaysSuffix' : '$days $activeDaysSuffix'}';

  // ---------------------------------------------------------------- M-04 self check

  static const String selfCheckTitle = '现场自检与模式切换';
  static const String selfCheckRun = '一键自检';
  static const String selfCheckChecking = '自检中…';
  static const String selfCheckPassedWord = '通过';
  static const String selfCheckFailedWord = '失败';
  static const String selfCheckObservedLabel = '实测';
  static const String selfCheckUnavailable = 'unavailable';
  static const String selfCheckTimeout = 'timeout';
  static const String modeRealtime = 'A · 实时';
  static const String modeSampleAudio = 'B · 示例音频';
  static const String modeReportOnly = 'C · 报告演示';

  /// SPEC-M-04 §2.2 step 5: the four possible verdict lines, and nothing else.
  static const String verdictAllPassed = '麦克风侧与模型侧均正常';
  static const String verdictMicSide = '麦克风侧问题';
  static const String verdictModelSide = '模型侧问题';
  static const String verdictBothSides = '原生桥接/配置问题';
  static const String verdictUnknown = '自检未执行';

  // ---------------------------------------------------------------- M-03 report demo

  static const String reportDemoTitle = '报告演示（Mode C）';
  static const String reportDemoLoad = '加载演示数据';
  static const String reportDemoUnavailable = '演示数据集不可用';

  // ---------------------------------------------------------------- accessibility shapes

  /// U-01 §8: `近 7 天健康评分 85 分，评级良好，较上一周期 ↑12 分` (ADR-23 wording).
  static String scoreSemantics({
    required String total,
    required String grade,
    String? delta,
  }) {
    final buffer = StringBuffer('$scoreWindowLabel健康评分 $total 分');
    if (grade != empty) buffer.write('，评级$grade');
    if (delta != null) {
      buffer.write(delta == AcouFormat.flatText ? '，与上一周期持平' : '，较上一周期$delta');
    }
    return buffer.toString();
  }

  /// U-03 §8: `12 点 20 分，面条，约 120 千卡，软性主食 1 片，估算，置信度 88%，双击查看详情`.
  static String recordSemantics({
    required int hour,
    required int minute,
    required String foodName,
    required String estimateLine,
    required String kcalBadge,
    required String confidenceText,
  }) =>
      '$hour 点 $minute 分，$foodName，$kcalBadge，$estimateLine，$confidenceText，双击查看详情';

  /// U-04 §8: `本周趋势：周一 1100 千卡，周二 1200 千卡，周三无数据……`.
  static String trendSemantics(String body) => '本周趋势：$body';

  /// U-06 §8: the radar's text equivalent, e.g. `饮食规律性 26 分，满分 30 分；……总分 82 分`.
  static String radarSemantics(String body, String total) =>
      '$body；总分 $total 分';
}
