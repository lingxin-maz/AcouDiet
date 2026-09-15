// app/lib/presentation/pages/demo/self_check_panel.dart
//
// M-04 · 现场自检与降级面板. It is the only on-site rescue tool, so it is reachable from the home
// app bar and the settings list and it is **not** a fifth page or a fifth tab (FF-23).
//
// The panel's requirements, and where each one is satisfied:
//  * one tap runs the whole check -- `DemoController.runSelfCheck()`, whose 14 items and their
//    rules live in `lib/domain/service/demo_controller.dart` (the single implementation);
//  * the panel works even when the microphone, the session, the model or the database is broken,
//    because `runSelfCheck()` never throws and `SelfCheckView.of` normalises the row count;
//  * a failed mode switch shows the code, the readable reason and one suggested action;
//  * pass/fail is carried by text **and** colour.

import 'package:flutter/material.dart';

import '../../presenters/selfcheck_presenter.dart';
import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../state/notifiers.dart' show SelfCheckNotifier;
import '../../theme/acou_theme.dart';
import '../../widgets/self_check_list.dart';
import '../../widgets/state_view.dart';

class SelfCheckPanelPage extends StatelessWidget {
  const SelfCheckPanelPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AcouScope.of(context);
    final notifier = scope.notifiers.selfCheck;
    return Scaffold(
      appBar: AppBar(title: const Text(UiStrings.selfCheckTitle)),
      body: AcouBuilder<SelfCheckView>(
        notifier: notifier,
        builder: (context, value) => RefreshIndicator(
          // Pull-to-refresh re-runs the self check; a concurrent check is refused, so the
          // notifier's guard is what the gesture hits.
          onRefresh: notifier.reload,
          child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AcouTheme.spacePage),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget + 8),
              child: FilledButton.icon(
                // A concurrent check is refused, not queued: the button is disabled while one
                // runs (SPEC-M-04 section 2.3).
                onPressed: notifier.running ? null : notifier.reload,
                icon: const Icon(Icons.playlist_add_check),
                label: Text(
                  notifier.running ? UiStrings.selfCheckChecking : UiStrings.selfCheckRun,
                ),
              ),
            ),
            const SizedBox(height: AcouTheme.spaceMd),
            _ModeButtons(notifier: notifier),
            if (notifier.switchFailure != null) ...[
              const SizedBox(height: AcouTheme.spaceSm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AcouTheme.spaceMd),
                decoration:
                    AcouTheme.cardDecoration(fill: AcouTheme.demoBanner),
                child: Text(
                  notifier.switchFailure!,
                  style: AcouTheme.body.copyWith(color: AcouTheme.demoBannerInk),
                ),
              ),
            ],
            const Divider(height: AcouTheme.spaceLg),
            if (!value.hasValue && value.isLoading)
              const StateView(status: ViewStatus.loading, message: '正在执行自检…', compact: true)
            else
              SelfCheckList(view: value.data ?? SelfCheckView.idle),
          ],
          ),
        ),
      ),
    );
  }
}

/// The three demonstration modes. A switch that is refused keeps the current mode and explains
/// why, rather than optimistically pretending to have moved (API-04 section 7.2).
class _ModeButtons extends StatelessWidget {
  const _ModeButtons({required this.notifier});

  final SelfCheckNotifier notifier;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('演示模式', style: AcouTheme.sectionTitle),
          const SizedBox(height: AcouTheme.spaceSm),
          Wrap(
            spacing: AcouTheme.spaceSm,
            runSpacing: AcouTheme.spaceSm,
            children: [
              for (final mode in SelfCheckPresenter.modes)
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AcouTheme.minTapTarget,
                    minWidth: 120,
                  ),
                  child: OutlinedButton(
                    onPressed: () => notifier.switchMode(mode),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: notifier.mode == mode ? AcouTheme.seed : AcouTheme.outline,
                        width: notifier.mode == mode ? 2 : 1,
                      ),
                    ),
                    child: Text(SelfCheckPresenter.modeLabel(mode)),
                  ),
                ),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AcouTheme.minTapTarget,
                  minWidth: 120,
                ),
                child: OutlinedButton(
                  onPressed: notifier.loadReportDemo,
                  child: const Text(UiStrings.reportDemoLoad),
                ),
              ),
            ],
          ),
        ],
      );
}
