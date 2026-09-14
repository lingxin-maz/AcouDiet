// app/lib/presentation/pages/home/home_page.dart
//
// U-01 · 首页今日概览. The first screen: today's score, the four-dimension radar, the estimated
// energy band, the week counter, today's records and the most prominent element on the page --
// the "start AI detection" button.
//
// The page holds no logic: everything it renders comes from [HomeView], which the pure presenter
// built from domain objects (README section 3 is the data contract, and nothing outside that
// table appears here).

import 'package:flutter/material.dart';

import '../../../domain/service/health_score_service.dart';
import '../../presenters/home_presenter.dart';
import '../../presenters/records_presenter.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../state/async_value.dart';
import '../../theme/acou_theme.dart';
import '../../widgets/demo_banner.dart';
import '../../widgets/drill_down_sheet.dart';
import '../../widgets/record_card.dart';
import '../../widgets/score_card.dart';
import '../../widgets/state_view.dart';
import '../demo/self_check_panel.dart';
import '../detect/detect_page.dart';
import '../profile/profile_page.dart';
import '../records/record_detail_page.dart';
import '../records/records_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AcouScope.of(context);
    return Scaffold(
      // ADR-24: the mockups run the mint gradient behind the whole page, app bar included.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        titleSpacing: AcouTheme.spacePage,
        title: const _BrandHeader(),
        actions: [
          _HeaderAction(
            icon: Icons.badge_outlined,
            tooltip: UiStrings.selfCheckEntry,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SelfCheckPanelPage()),
            ),
          ),
          _HeaderAction(
            icon: Icons.person_outline,
            tooltip: UiStrings.myEntry,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ProfilePage()),
            ),
          ),
          const SizedBox(width: AcouTheme.spaceSm),
        ],
      ),
      body: DecoratedBox(
        decoration: AcouTheme.pageGradientDecoration(),
        child: AcouBuilder<HomeView>(
          notifier: scope.notifiers.home,
          builder: (context, value) {
            if (!value.hasValue) {
              return RefreshableBody(
                onRefresh: scope.notifiers.home.reload,
                child: StateView.of(
                  value,
                  emptyMessage: UiStrings.homeTodayRecordsEmpty,
                  loadingMessage: '正在读取今日数据…',
                  onRetry: scope.notifiers.home.reload,
                ),
              );
            }
            final view = value.data!;
            return RefreshIndicator(
              onRefresh: scope.notifiers.home.reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                // `extendBodyBehindAppBar` means the list starts under the bar: reserve its
                // height here rather than putting the gradient inside a second Scaffold.
                padding: EdgeInsets.only(
                  top: kToolbarHeight + MediaQuery.paddingOf(context).top,
                  bottom: AcouTheme.spaceXl,
                ),
                children: [
                  DemoBanner(visible: view.demoActive),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AcouTheme.spacePage,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Greeting(view: view),
                        const SizedBox(height: AcouTheme.spaceMd),
                        ScoreCard(
                          score: view.score,
                          onTap: () => DrillDownSheet.show(
                            context,
                            drills: drillsOf(view.score),
                            title: UiStrings.scoreCardTitle,
                          ),
                        ),
                        const SizedBox(height: AcouTheme.spaceMd),
                        // The mockups place two half-width cards side by side under the score
                        // card. Their *labels* stay the frozen ones: an estimated ±20% band and
                        // the week record count (README section 8 replaced the impossible
                        // "diversity 8/12" counter).
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: _EnergyCard(view: view)),
                              const SizedBox(width: AcouTheme.spaceSm),
                              Expanded(child: _WeekCountCard(view: view)),
                            ],
                          ),
                        ),
                        const SizedBox(height: AcouTheme.spaceLg),
                        StartDetectButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => const DetectPage()),
                          ),
                        ),
                        const SizedBox(height: AcouTheme.spaceLg),
                        _TodayRecordsSection(view: view),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The brand row of the mockups: a mint logo tile, the one-word brand and a small version chip.
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AcouTheme.mintDeep,
              borderRadius: BorderRadius.circular(AcouTheme.radiusSm),
            ),
            child: const Icon(Icons.graphic_eq, size: 18, color: AcouTheme.onMint),
          ),
          const SizedBox(width: AcouTheme.spaceSm),
          const Text(
            UiStrings.appTitle,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: AcouTheme.ink,
            ),
          ),
        ],
      );
}

/// A rounded white square holding one header action (the mockups' two top-right buttons).
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: AcouTheme.spaceXs),
        child: Semantics(
          button: true,
          label: tooltip,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(AcouTheme.radiusMd),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AcouTheme.surface,
                borderRadius: BorderRadius.circular(AcouTheme.radiusMd),
                boxShadow: AcouTheme.cardShadows,
              ),
              child: Icon(icon, size: 20, color: AcouTheme.ink),
            ),
          ),
        ),
      );
}

/// The greeting block, whose second line is honest about whether there is anything to show.
class _Greeting extends StatelessWidget {
  const _Greeting({required this.view});

  final HomeView view;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(UiStrings.homeGreeting, style: AcouTheme.headline),
          const SizedBox(height: AcouTheme.spaceSm),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AcouTheme.spaceMd,
              vertical: AcouTheme.spaceSm,
            ),
            decoration: BoxDecoration(
              color: AcouTheme.surface,
              borderRadius: BorderRadius.circular(AcouTheme.radiusLg),
              boxShadow: AcouTheme.cardShadows,
            ),
            child: Text(
              view.isEmptyDay
                  ? UiStrings.homeGreetingEmpty
                  : UiStrings.homeGreetingWithData,
              style: AcouTheme.bodyMuted,
            ),
          ),
        ],
      );
}

/// The estimated-energy card. Half-width per the mockups, and its value is the frozen ±20% band
/// with the estimate wording (A-03-K6 / FF-25) -- never a bare kilocalorie.
class _EnergyCard extends StatelessWidget {
  const _EnergyCard({required this.view});

  final HomeView view;

  @override
  Widget build(BuildContext context) => Semantics(
        label: view.energy.hasData
            ? '${view.energy.label} ${view.energy.valueText}'
            : '${view.energy.label} ${UiStrings.homeEnergyEmpty}',
        container: true,
        child: Container(
          padding: const EdgeInsets.all(AcouTheme.spaceMd),
          decoration: AcouTheme.cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _MiniCardIcon(icon: Icons.local_fire_department_outlined),
              const SizedBox(height: AcouTheme.spaceSm),
              Text(view.energy.label, style: AcouTheme.caption),
              const SizedBox(height: AcouTheme.spaceXs),
              Text(
                view.energy.hasData ? view.energy.valueText : UiStrings.homeEnergyEmpty,
                style: AcouTheme.metric,
              ),
            ],
          ),
        ),
      );
}

/// The week counter. `0 次` is a value; `-- 次` means the aggregate failed, and the two must not
/// look alike.
class _WeekCountCard extends StatelessWidget {
  const _WeekCountCard({required this.view});

  final HomeView view;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _MiniCardIcon(icon: Icons.event_note_outlined),
            const SizedBox(height: AcouTheme.spaceSm),
            const Text(UiStrings.weekRecordPrefix, style: AcouTheme.caption),
            const SizedBox(height: AcouTheme.spaceXs),
            Text(view.week.text.replaceFirst('${UiStrings.weekRecordPrefix} ', ''),
                style: AcouTheme.metric),
          ],
        ),
      );
}

/// The small mint chip that heads a mini card (the mockups' rounded icon chip).
class _MiniCardIcon extends StatelessWidget {
  const _MiniCardIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 32,
        height: 32,
        decoration: AcouTheme.softTileDecoration(),
        child: Icon(icon, size: 18, color: AcouTheme.gradeGood),
      );
}

/// The most prominent element of the screen (SPEC-U-01 acceptance 6). ADR-24 draws it the way the
/// mockups do: a circular microphone badge above a stadium-shaped mint action.
class StartDetectButton extends StatelessWidget {
  const StartDetectButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '${UiStrings.startDetect}，开始一次实时检测',
        button: true,
        container: true,
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AcouTheme.mint, AcouTheme.mintDeep],
                ),
                boxShadow: [
                  BoxShadow(color: Color(0x3345C9A5), blurRadius: 20, offset: Offset(0, 8)),
                ],
              ),
              child: const Icon(Icons.mic_none, size: 30, color: AcouTheme.onMint),
            ),
            const SizedBox(height: AcouTheme.spaceSm),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget + 8),
              child: FilledButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.graphic_eq),
                label: const Text(UiStrings.startDetect),
              ),
            ),
          ],
        ),
      );
}

/// Today's records, at most three rows plus the "view all" affordance.
class _TodayRecordsSection extends StatelessWidget {
  const _TodayRecordsSection({required this.view});

  final HomeView view;

  @override
  Widget build(BuildContext context) {
    if (view.recordsUnavailable) {
      return StateView(
        status: ViewStatus.error,
        message: view.todayRecordsEmptyText,
        compact: true,
      );
    }
    if (view.todayCards.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(fill: AcouTheme.surfaceMuted),
        child: Row(
          children: [
            const Icon(Icons.inbox_outlined, color: AcouTheme.inkMuted),
            const SizedBox(width: AcouTheme.spaceSm),
            Expanded(child: Text(view.todayRecordsEmptyText, style: AcouTheme.bodyMuted)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(UiStrings.homeTodayRecordsTitle, style: AcouTheme.sectionTitle),
        const SizedBox(height: AcouTheme.spaceSm),
        for (final card in view.todayCards)
          RecordCard(
            card: card,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RecordDetailPage(recordId: card.record.recordId),
              ),
            ),
          ),
        if (view.showViewAll)
          const SizedBox(height: AcouTheme.spaceSm),
        if (view.showViewAll)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const RecordsPage()),
              ),
              icon: const Icon(Icons.arrow_forward),
              label: const Text(UiStrings.viewAll),
            ),
          ),
      ],
    );
  }
}

/// The self-check entry. M-04 must not become a fifth page or a fifth tab (FF-23), so it is
/// reached from the home app bar and from the settings entry list.
abstract final class SelfCheckEntry {
  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SelfCheckPanelPage()),
      );
}
