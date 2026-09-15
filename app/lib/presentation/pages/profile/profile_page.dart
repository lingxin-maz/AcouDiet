// app/lib/presentation/pages/profile/profile_page.dart
//
// U-05 · 我的 / 设置. The entry is an app-bar action, never a fifth tab (FF-23).
//
// What is here, and what is deliberately missing:
//  * the local profile replaces the cut login system (X-01): nickname, target meals, switches;
//  * "已坚持 N 天" is a dynamic count from `StatsRepo.activeDays()`, and `-- 天` while that port is
//    unavailable -- the page never scans the table itself and never hard-codes a day count;
//  * achievements are a static `const` list with no unlock logic and no progress widget (X-04);
//  * the file-export entry is **present but inert**, labelled `v1.1` (X-03);
//  * "复制为文本" writes the system clipboard only -- no file, no share intent, no network, no new
//    permission (ADR-P4).

import 'package:flutter/material.dart';

import '../../../core/flavour.dart';
import '../../presenters/settings_presenter.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../state/notifiers.dart';
import '../../theme/acou_theme.dart';
import '../../widgets/acou_app_bar.dart';
import '../../widgets/demo_banner.dart';
import '../../widgets/state_view.dart';
import '../demo/self_check_panel.dart';
import '../report/report_page.dart';
import 'about_page.dart';
import 'agent_key_page.dart';
import 'privacy_notice_page.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AcouScope.of(context);
    final notifier = scope.notifiers.profile;
    return AcouScrollEdge(
      child: Scaffold(
      // ADR-24: the mockups' profile screen is a mint gradient page with a white header card.
      extendBodyBehindAppBar: true,
      appBar: const AcouPageHeader(title: UiStrings.profileTitle),
      body: DecoratedBox(
        decoration: AcouTheme.pageGradientDecoration(),
        child: AcouBuilder<SettingsView>(
          notifier: notifier,
          builder: (context, value) {
            if (!value.hasValue) {
              return RefreshableBody(
                onRefresh: notifier.reload,
                child: StateView.of(
                  value,
                  loadingMessage: '正在读取本地档案…',
                  onRetry: notifier.reload,
                ),
              );
            }
            final view = value.data!;
            return RefreshIndicator(
              onRefresh: notifier.reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  top: kToolbarHeight + MediaQuery.paddingOf(context).top,
                  bottom: AcouTheme.spaceXl + AcouTheme.bottomInset(context),
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
                        ProfileHeader(view: view),
                        const SizedBox(height: AcouTheme.spaceMd),
                        EntryList(view: view),
                        const SizedBox(height: AcouTheme.spaceMd),
                        WeeklyOverviewPanel(view: view),
                        const SizedBox(height: AcouTheme.spaceMd),
                        const AchievementsStatic(),
                        const SizedBox(height: AcouTheme.spaceMd),
                        // The two data actions keep their frozen copy and behaviour.
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                              minHeight: AcouTheme.minTapTarget),
                          child: OutlinedButton.icon(
                            onPressed: notifier.copyAsText,
                            icon: const Icon(Icons.content_copy_outlined),
                            label: const Text(UiStrings.copyAsText),
                          ),
                        ),
                        const SizedBox(height: AcouTheme.spaceSm),
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                              minHeight: AcouTheme.minTapTarget),
                          child: OutlinedButton.icon(
                            onPressed: () => showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              showDragHandle: true,
                              builder: (_) => ClearDataSheet(notifier: notifier),
                            ),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text(UiStrings.clearAllData),
                          ),
                        ),
                        if (view.demoActive) ...[
                          const SizedBox(height: AcouTheme.spaceSm),
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                                minHeight: AcouTheme.minTapTarget),
                            child: OutlinedButton.icon(
                              onPressed: notifier.clearDemoData,
                              icon: const Icon(Icons.science_outlined),
                              label: const Text(UiStrings.clearDemoData),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      ),
    );
  }
}

/// Avatar, nickname and the dynamic day count.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({super.key, required this.view});

  final SettingsView view;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Row(
          children: [
            // A fixed local asset would be ideal; a bundled `IconData` is the honest v1.0 stand-in
            // and it needs no camera or gallery permission (FF-24 item 5). ADR-24 draws it as the
            // mockups' circular avatar.
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AcouTheme.mintSoft,
              ),
              child: const Icon(Icons.person, color: AcouTheme.gradeGood, size: 34),
            ),
            const SizedBox(width: AcouTheme.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(view.nicknameText, style: AcouTheme.headline),
                  const SizedBox(height: AcouTheme.spaceXs),
                  Text(view.activeDaysText, style: AcouTheme.bodyMuted),
                  Text('累计有记录的天数（不是连续天数）', style: AcouTheme.caption),
                ],
              ),
            ),
          ],
        ),
      );
}

/// ADR-24: the mockups' three-up 本周健康数据概览 panel.
///
/// It shows counts and one grade word, all read from the same seven-day window as the report
/// page's 「本周」 (see `SettingsView`), inside a mint panel with three white tiles. The tiles are
/// text-first: the panel adds **no** invented metric, and a failed query degrades all three to
/// `--` together.
class WeeklyOverviewPanel extends StatelessWidget {
  const WeeklyOverviewPanel({super.key, required this.view});

  final SettingsView view;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.overviewPanelDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(UiStrings.overviewTitle, style: AcouTheme.sectionTitle),
            const SizedBox(height: AcouTheme.spaceSm),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _OverviewTile(
                      label: UiStrings.overviewRecordsLabel,
                      value: view.overviewRecordCountText,
                    ),
                  ),
                  const SizedBox(width: AcouTheme.spaceSm),
                  Expanded(
                    child: _OverviewTile(
                      label: UiStrings.overviewSpeedLabel,
                      value: view.overviewSpeedText,
                    ),
                  ),
                  const SizedBox(width: AcouTheme.spaceSm),
                  Expanded(
                    child: _OverviewTile(
                      label: UiStrings.overviewSnackLabel,
                      value: view.overviewSnackCountText,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AcouTheme.spaceSm),
            const Text(UiStrings.overviewNote, style: AcouTheme.caption),
          ],
        ),
      );
}

class _OverviewTile extends StatelessWidget {
  const _OverviewTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AcouTheme.spaceSm),
        decoration: AcouTheme.cardDecoration(radius: BorderRadius.circular(AcouTheme.radiusMd)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AcouTheme.caption),
            const SizedBox(height: AcouTheme.spaceXs),
            Text(value, style: AcouTheme.metric),
          ],
        ),
      );
}

/// X-04: display only. No unlock check, no progress bar, no animation -- which is exactly what
/// the widget test asserts by finding no `LinearProgressIndicator` here.
class AchievementsStatic extends StatelessWidget {
  const AchievementsStatic({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AcouTheme.spacePage),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(UiStrings.achievementsTitle, style: AcouTheme.sectionTitle),
            const SizedBox(height: AcouTheme.spaceSm),
            Wrap(
              spacing: AcouTheme.spaceSm,
              runSpacing: AcouTheme.spaceSm,
              children: [
                for (final a in SettingsPresenter.achievements)
                  Container(
                    width: 160,
                    padding: const EdgeInsets.all(AcouTheme.spaceSm),
                    decoration: AcouTheme.cardDecoration(fill: AcouTheme.surfaceMuted),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.title, style: AcouTheme.metric),
                        const SizedBox(height: 2),
                        Text(a.subtitle, style: AcouTheme.caption),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
}

/// The entry list: report, the disabled export entry, privacy, the self-check panel and about.
class EntryList extends StatelessWidget {
  const EntryList({super.key, required this.view});

  final SettingsView view;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          _Entry(
            icon: Icons.insights_outlined,
            title: UiStrings.healthReportEntry,
            subtitle: UiStrings.healthReportEntrySubtitle,
            spoken: UiStrings.healthReportEntrySpoken,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ReportPage()),
            ),
          ),
          // X-03: the entry exists so the product does not look like it forgot, and it does
          // nothing when tapped.
          Semantics(
            label: UiStrings.exportEntrySpoken,
            container: true,
            child: Container(
              margin: const EdgeInsets.only(bottom: AcouTheme.spaceSm),
              padding: const EdgeInsets.all(AcouTheme.spaceMd),
              decoration: AcouTheme.cardDecoration(),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: AcouTheme.softTileDecoration(fill: AcouTheme.surfaceMuted),
                    child: const Icon(Icons.file_download_outlined,
                        size: 20, color: AcouTheme.inkMuted),
                  ),
                  const SizedBox(width: AcouTheme.spaceMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(UiStrings.exportEntryTitle,
                            style: AcouTheme.metric
                                .copyWith(color: AcouTheme.inkMuted)),
                        Text(view.exportEntryText, style: AcouTheme.caption),
                      ],
                    ),
                  ),
                  Text(view.exportEntryBadge, style: AcouTheme.caption),
                ],
              ),
            ),
          ),
          _Entry(
            icon: Icons.privacy_tip_outlined,
            title: UiStrings.privacyTitle,
            subtitle: UiStrings.privacyEntrySubtitle,
            spoken: UiStrings.privacyEntrySpoken,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PrivacyNoticePage()),
            ),
          ),
          // ADR-44: the ONE screen that writes the cloud agent's credential (`API-07` section 2).
          // It is a settings row rather than a tab, and the offline flavour has no such row
          // because it has no agent (`FF-24` item 4).
          if (!isOfflineFlavour)
            _Entry(
              icon: Icons.key_outlined,
              title: UiStrings.apiKeyEntry,
              subtitle: UiStrings.apiKeyEntrySubtitle,
              spoken: UiStrings.apiKeyEntrySpoken,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AgentKeyPage()),
              ),
            ),
          _Entry(
            icon: Icons.badge_outlined,
            title: UiStrings.selfCheckEntry,
            subtitle: UiStrings.selfCheckEntrySubtitle,
            spoken: UiStrings.selfCheckEntrySpoken,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SelfCheckPanelPage()),
            ),
          ),
          _Entry(
            icon: Icons.info_outline,
            title: UiStrings.aboutTitle,
            subtitle: UiStrings.aboutEntrySubtitle,
            spoken: UiStrings.aboutEntrySpoken,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AboutPage()),
            ),
          ),
        ],
      );
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.title,
    required this.spoken,
    required this.onTap,
    this.subtitle = '',
  });

  final IconData icon;
  final String title;
  final String spoken;
  final VoidCallback onTap;

  /// ADR-38: mockup `9.png` gives every row a one-line description; this page was the only one
  /// that shipped the rows bare. The line is **decorative in the accessibility tree** -- it is
  /// `ExcludeSemantics`-able text beside a node whose label already says the same thing, so a
  /// screen reader still hears one announcement per row, not two.
  final String subtitle;

  @override
  Widget build(BuildContext context) => Semantics(
        label: spoken,
        button: true,
        container: true,
        child: Padding(
          padding: const EdgeInsets.only(bottom: AcouTheme.spaceSm),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AcouTheme.radiusLg),
            child: Container(
              padding: const EdgeInsets.all(AcouTheme.spaceMd),
              decoration: AcouTheme.cardDecoration(),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: AcouTheme.softTileDecoration(),
                    child: Icon(icon, size: 20, color: AcouTheme.gradeGood),
                  ),
                  const SizedBox(width: AcouTheme.spaceMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: AcouTheme.metric),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          // Excluded from the semantics tree on purpose: this row's `spoken` label
                          // already carries the same sentence, so exposing it twice would make the
                          // page announce each entry twice.
                          ExcludeSemantics(
                            child: Text(
                              subtitle,
                              style: AcouTheme.caption,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: AcouTheme.inkMuted),
                ],
              ),
            ),
          ),
        ),
      );
}

/// The one-tap clear confirmation. It states that the action cannot be undone and that
/// uninstalling has the same effect, so nobody discovers the portability gap afterwards.
class ClearDataSheet extends StatelessWidget {
  const ClearDataSheet({super.key, required this.notifier});

  final ProfileNotifier notifier;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AcouTheme.spacePage),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(UiStrings.clearAllData, style: AcouTheme.sectionTitle),
              const SizedBox(height: AcouTheme.spaceSm),
              Text(UiStrings.clearConfirmText, style: AcouTheme.body),
              const SizedBox(height: AcouTheme.spaceXs),
              Text(UiStrings.privacyLossNotice, style: AcouTheme.caption),
              const SizedBox(height: AcouTheme.spaceMd),
              Row(
                children: [
                  // Focus order: cancel -> confirm (SPEC-U-05 section 8).
                  Expanded(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text(UiStrings.cancel),
                      ),
                    ),
                  ),
                  const SizedBox(width: AcouTheme.spaceSm),
                  Expanded(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                      child: FilledButton(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final navigator = Navigator.of(context);
                          final ok = await notifier.clearAllData();
                          navigator.pop();
                          messenger.showSnackBar(SnackBar(
                            content: Text(ok
                                ? '已清空全部本地数据'
                                : (notifier.actionMessage ?? UiStrings.clearFailed)),
                          ));
                        },
                        child: const Text(UiStrings.confirm),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}
