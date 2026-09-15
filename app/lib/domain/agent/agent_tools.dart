// app/lib/domain/agent/agent_tools.dart
//
// ADR-44 -- the four tools (`SPEC-G-03`). Pure Dart.
//
// WHAT THIS FILE REFUSES TO DO, AND WHY IT IS THE POINT OF THE FEATURE
// --------------------------------------------------------------------
// `FF-26i` says the agent performs a HANDOFF, not a purchase. Three routes were considered
// (`API-07` section 3.1) and two are forbidden outright:
//
//   * an AccessibilityService that taps through the delivery app -- requires a permission far
//     beyond recording, contradicts FF-24 item 5, and breaks the platforms' own terms;
//   * reversing a client's private endpoints -- unlawful and short-lived.
//
// So the delivered route is: build a SEARCH URL and hand it to the OS. `propose_takeout_search`
// does not even do that much -- it returns a proposal, and the launch happens when the user
// presses the button (`API-05` section 13.4.4). Without that split, "我饿了" would pop another
// app onto the screen with no button ever pressed, which is the same defect as a detector that
// starts listening on its own (FF-24 item 6).

import '../../core/feature_config.g.dart' as cfg;
import 'agent_tool.dart';

/// Reads the local aggregate for one range. Injected so this layer never imports a concrete
/// service and stays testable without a database.
typedef HealthSummaryReader = Future<Map<String, Object?>> Function(String range);

/// Reads the most recent N meals.
typedef RecentMealsReader = Future<List<Map<String, Object?>>> Function(int limit);

/// Reads the current rule-engine advice lines (`A-02`). The tool returns them verbatim; it does
/// not re-word them, because the advice text is contract-frozen and audited.
typedef AdviceReader = Future<List<String>> Function();

/// One delivery platform, projected from the SSOT.
class TakeoutPlatform {
  const TakeoutPlatform({
    required this.id,
    required this.label,
    required this.urlTemplate,
    required this.enabled,
    required this.verifiedOn,
    this.schemeTemplate = '',
  });

  final String id;
  final String label;

  /// The **web** search template (`https://…{q}`). Always works in a browser, and Android App
  /// Links/Smart Links may route it into the installed app.
  final String urlTemplate;

  /// The **app-scheme** template (`imeituan://…{q}`), tried FIRST so an installed app is opened
  /// directly instead of the phone landing on a web page. Empty when the platform has none.
  ///
  /// ⚠️ Unverified on a real device. The launcher therefore treats the scheme as an ATTEMPT, not
  /// as the answer: a `canOpenUrl` of `false`, or an `openUrl` that returns `false` because the
  /// OS found no handler, falls back to [urlTemplate]. An unverified template can cost a
  /// redundant probe; it must never cost the handoff.
  final String schemeTemplate;

  final bool enabled;

  /// ISO date, or `''` when the template has not been checked on a real device. It governs BOTH
  /// templates for this platform.
  final String verifiedOn;

  bool get isVerified => verifiedOn.isNotEmpty;

  /// Whether this platform can be attempted through its app scheme.
  bool get hasScheme => schemeTemplate.isNotEmpty;
}

/// The three platforms. Constructed from the SSOT at the composition root; the default
/// constructor here exists so tests and the offline wiring do not need the asset.
List<TakeoutPlatform> platformsFromFeatureConfig() => const <TakeoutPlatform>[
      TakeoutPlatform(
        id: 'meituan',
        label: cfg.FeatureConfig.agentPlatformMeituanLabel,
        urlTemplate: cfg.FeatureConfig.agentPlatformMeituanUrl,
        schemeTemplate: cfg.FeatureConfig.agentPlatformMeituanScheme,
        enabled: cfg.FeatureConfig.agentPlatformMeituanEnabled,
        verifiedOn: cfg.FeatureConfig.agentPlatformMeituanVerifiedOn,
      ),
      TakeoutPlatform(
        id: 'eleme',
        label: cfg.FeatureConfig.agentPlatformElemeLabel,
        urlTemplate: cfg.FeatureConfig.agentPlatformElemeUrl,
        schemeTemplate: cfg.FeatureConfig.agentPlatformElemeScheme,
        enabled: cfg.FeatureConfig.agentPlatformElemeEnabled,
        verifiedOn: cfg.FeatureConfig.agentPlatformElemeVerifiedOn,
      ),
      TakeoutPlatform(
        id: 'taobao',
        label: cfg.FeatureConfig.agentPlatformTaobaoLabel,
        urlTemplate: cfg.FeatureConfig.agentPlatformTaobaoUrl,
        schemeTemplate: cfg.FeatureConfig.agentPlatformTaobaoScheme,
        enabled: cfg.FeatureConfig.agentPlatformTaobaoEnabled,
        verifiedOn: cfg.FeatureConfig.agentPlatformTaobaoVerifiedOn,
      ),
    ];

/// Builds the **web** search URL. Pure, so a test can assert it byte for byte with no network.
///
/// The keyword is encoded with [Uri.encodeComponent]: a raw `奶茶` in a URL is not a URL.
String takeoutUrlFor(TakeoutPlatform platform, String keyword) =>
    platform.urlTemplate.replaceAll('{q}', Uri.encodeComponent(keyword));

/// Builds the **app-scheme** search URL, or `''` when the platform has no scheme template.
///
/// A custom scheme is NOT a URL that `Uri.encodeComponent` alone can be trusted to shape: the
/// keyword still needs percent-encoding (it lands in a query string), but unlike `https` a scheme
/// has no universal parser on the other side. Encoding is therefore the same and the template is
/// taken verbatim from the SSOT.
String takeoutSchemeFor(TakeoutPlatform platform, String keyword) =>
    platform.hasScheme ? platform.schemeTemplate.replaceAll('{q}', Uri.encodeComponent(keyword)) : '';

/// Truncates a keyword to the frozen cap (`feature_config.agent.recommend_keyword_max_chars`).
///
/// Truncation is by **runes** (Unicode code points), not by code units. `String.substring`
/// counts UTF-16 code units, so cutting an emoji in half produces an unpaired surrogate: a
/// string that is not valid UTF-16, cannot be encoded, and would throw or corrupt the request
/// body. The cap is small enough that this only shows up with emoji in the keyword -- which is
/// exactly the kind of input a food search gets.
///
/// Without a cap at all, a user's whole sentence ends up verbatim in a third-party URL, which is
/// both a poor search and an unnecessary disclosure to that platform's servers.
String capKeyword(String raw) {
  final cleaned = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  final max = cfg.FeatureConfig.agentRecommendKeywordMaxChars;
  final runes = cleaned.runes.toList();
  if (runes.length <= max) return cleaned;
  return String.fromCharCodes(runes.take(max));
}

/// The launch port. `U-07` calls it after a real tap; the tools never call it.
abstract class AgentPlatformLauncher {
  Future<bool> canOpen(String platformId);
  Future<bool> openSearch({required String platformId, required String keyword});
}

class GetHealthSummaryTool implements AgentTool {
  GetHealthSummaryTool(this.read);
  final HealthSummaryReader read;

  @override
  String get name => AgentToolNames.healthSummary;
  @override
  String get description => '读取本地健康评分：四维分数、总分与评级，以及某一时间范围的聚合计数。';
  @override
  bool get proposalOnly => false;
  @override
  Map<String, Object?> get parameters => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'range': <String, Object?>{
            'type': 'string',
            'enum': <String>['today', 'week'],
            'description': 'today 或 week',
          },
        },
        'required': <String>['range'],
      };

  @override
  Future<AgentObservation> run(Map<String, Object?> args) async {
    final range = args['range'];
    if (range is! String || (range != 'today' && range != 'week')) {
      return const AgentObservation.failed(
        summary: 'range 参数非法',
        rootCauseHint: 'range 只接受 today 或 week',
        safeRetry: '用 today 或 week 重新调用',
        stopCondition: '如果两次都被拒绝，停止调用并列出手头已有的数据',
      );
    }
    final data = await read(range);
    return AgentObservation.ok(
      '已读取 $range 的本地健康数据',
      artifacts: data,
      nextActions: const <String>['可以据此给出饮食建议'],
    );
  }
}

class GetRecentMealsTool implements AgentTool {
  GetRecentMealsTool(this.read);
  final RecentMealsReader read;

  @override
  String get name => AgentToolNames.recentMeals;
  @override
  String get description => '读取最近的几条饮食记录：类别、进食时间与置信度。不包含任何音频。';
  @override
  bool get proposalOnly => false;
  @override
  Map<String, Object?> get parameters => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'limit': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 20,
            'description': '返回条数，1 到 20',
          },
        },
        'required': <String>['limit'],
      };

  @override
  Future<AgentObservation> run(Map<String, Object?> args) async {
    final raw = (args['limit'] as num?)?.toInt() ?? 5;
    final limit = raw.clamp(1, 20);
    final rows = await read(limit);
    return AgentObservation.ok(
      '已读取最近 ${rows.length} 条记录',
      artifacts: <String, Object?>{'records': rows},
    );
  }
}

class RecommendFoodTool implements AgentTool {
  RecommendFoodTool(this.advice);
  final AdviceReader advice;

  @override
  String get name => AgentToolNames.recommendFood;
  @override
  String get description => '基于本地规则引擎的建议给出下一步吃什么的方向。返回的是建议及其理由，不含任何下单动作。';
  @override
  bool get proposalOnly => false;
  @override
  Map<String, Object?> get parameters => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'avoid': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
            'description': '用户明确不想吃的方向，可为空数组',
          },
        },
        'required': <String>['avoid'],
      };

  @override
  Future<AgentObservation> run(Map<String, Object?> args) async {
    final lines = await advice();
    return AgentObservation.ok(
      '已读取 ${lines.length} 条本地建议',
      artifacts: <String, Object?>{
        'advice': lines,
        'avoid': (args['avoid'] as List?)?.map((e) => '$e').toList() ?? const <String>[],
      },
    );
  }
}

/// The proposal-only tool (`FF-26i`).
class ProposeTakeoutSearchTool implements AgentTool {
  ProposeTakeoutSearchTool(this.platforms);
  final List<TakeoutPlatform> platforms;

  @override
  String get name => AgentToolNames.proposeTakeout;
  @override
  String get description => '为某个搜索词生成外卖 App 的交接卡片。它不会打开任何 App，也不会下单；'
      '卡片需要用户自己点击才会跳转。';
  @override
  bool get proposalOnly => true;
  @override
  Map<String, Object?> get parameters => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'keyword': <String, Object?>{'type': 'string', 'description': '想吃的东西，例如「牛肉面」'},
          'platforms': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'enum': <String>['meituan', 'eleme', 'taobao']},
            'description': '可选，缺省为全部已启用的平台',
          },
        },
        'required': <String>['keyword'],
      };

  @override
  Future<AgentObservation> run(Map<String, Object?> args) async {
    final rawKeyword = args['keyword'];
    if (rawKeyword is! String || rawKeyword.trim().isEmpty) {
      return const AgentObservation.failed(
        summary: 'keyword 为空',
        rootCauseHint: '这个工具需要一个非空的搜索词',
        safeRetry: '先用 recommend_food 拿到方向，再用方向作为关键词重试',
        stopCondition: '如果仍然拿不到关键词，直接问用户想吃什么，不要重复调用本工具',
      );
    }
    final keyword = capKeyword(rawKeyword);
    final requested = (args['platforms'] as List?)?.map((e) => '$e').toSet();

    final offered = <TakeoutPlatform>[];
    final skipped = <Map<String, Object?>>[];
    for (final p in platforms) {
      if (requested != null && requested.isNotEmpty && !requested.contains(p.id)) continue;
      // A disabled platform is reported as skipped, NOT silently dropped: the user should be
      // able to see that a platform exists and is currently off (API-07 section 3.3).
      if (!p.enabled) {
        skipped.add(<String, Object?>{'id': p.id, 'reason': 'disabled_in_config'});
        continue;
      }
      offered.add(p);
    }
    if (offered.isEmpty) {
      // `status: warning`, not `success` and not `error`. Zero cards is a legitimate, honest
      // outcome when every platform is switched off in the SSOT -- and `API-07` section 4.1 was
      // corrected to say `0..3` for exactly this reason. Reporting `success` would tell the
      // model there is a card to mention; reporting `error` would make it retry a request that
      // cannot succeed.
      return const AgentObservation(
        status: 'warning',
        summary: '没有可用的平台入口（全部平台在配置中被禁用）',
        artifacts: <String, Object?>{'cards': <Object?>[]},
        nextActions: <String>['如实告诉用户当前没有可用的外卖入口，并给出建议方向'],
      );
    }
    final cards = offered
        .map((p) => <String, Object?>{
              'platformId': p.id,
              'label': p.label,
              'keyword': keyword,
              'url': takeoutUrlFor(p, keyword),
              // The app-scheme form, which the launcher tries FIRST so an installed app opens
              // directly instead of the phone falling through to a web page (user requirement,
              // ADR-45). Empty when the platform declares none; the launcher then goes straight
              // to `url`.
              'scheme': takeoutSchemeFor(p, keyword),
              'verified': p.isVerified,
            })
        .toList();
    return AgentObservation.ok(
      '已生成 ${cards.length} 张交接卡片（未打开任何 App）',
      artifacts: <String, Object?>{'cards': cards, 'skipped': skipped},
      nextActions: const <String>['告诉用户可以点卡片跳转到外卖 App 自己的搜索页'],
    );
  }
}
