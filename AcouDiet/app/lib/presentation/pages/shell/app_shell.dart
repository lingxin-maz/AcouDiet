// app/lib/presentation/pages/shell/app_shell.dart
//
// The four-tab shell (FF-23 / ADR-12):
//
//     [ 首页 ]  [ 检测 ]  [ 记录 ]  [ 报告 ]
//
// 「我的」 and the M-04 self-check panel are **entries**, not tabs: they live in the home app bar
// and in the settings entry list. Adding a fifth tab would break a frozen fact, so the shell's tab
// list is a `const` with four members and nothing may append to it.
//
// The shell also owns the two start-up side effects: priming the read-only pages once, and showing
// the one-off privacy note (FF-24) the first time the user lands on the detection tab.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../theme/acou_theme.dart';
import '../detect/detect_page.dart';
import '../home/home_page.dart';
import '../records/records_page.dart';
import '../report/report_page.dart';

/// The frozen tab set. Four, and the order is the one in FF-23.
enum ShellTab { home, detect, records, report }

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.initialTab = ShellTab.home});

  final ShellTab initialTab;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late ShellTab _tab = widget.initialTab;
  bool _privacyShown = false;

  static const List<ShellTab> tabs = [
    ShellTab.home,
    ShellTab.detect,
    ShellTab.records,
    ShellTab.report,
  ];

  @override
  void initState() {
    super.initState();
    // Prime the read-only pages once the first frame is on screen, so the first tab switch does
    // not show a spinner and the start-up handshake has already run.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AcouScope.notifiersOf(context).prime();
    });
  }

  void _select(int index) {
    final tab = tabs[index];
    if (tab == _tab) {
      // A second tap on the current tab refreshes it, without moving.
      _refreshTab(tab);
      return;
    }
    setState(() => _tab = tab);
    _refreshTab(tab);
    if (tab == ShellTab.detect && !_privacyShown) {
      _privacyShown = true;
      // FF-24: explained once, and it only claims what is true (no network permission, audio is
      // never written to storage).
      WidgetsBinding.instance.addPostFrameCallback((_) => _showPrivacyDialog());
    }
  }

  /// ADR-23: every tab switch pulls the fresh numbers **before** the page is shown.
  ///
  /// `reloadFresh()` drops the previous value first, so the incoming page renders its loading
  /// state instead of the stale content the user did not ask for. The request is fired here
  /// (not awaited) so the tab change stays instant; the page itself is what waits.
  ///
  /// 「检测」 has nothing to load -- it is a session page whose data only exists while a session
  /// runs -- so it is deliberately not refreshed.
  void _refreshTab(ShellTab tab) {
    final notifiers = AcouScope.notifiersOf(context);
    switch (tab) {
      case ShellTab.home:
        unawaited(notifiers.home.reloadFresh());
      case ShellTab.records:
        unawaited(notifiers.records.reloadFresh());
      case ShellTab.report:
        unawaited(notifiers.report.reloadFresh());
      case ShellTab.detect:
        break;
    }
  }

  Future<void> _showPrivacyDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(UiStrings.privacyDialogTitle),
        content: const Text(UiStrings.privacyDialogBody),
        actions: [
          ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AcouTheme.minTapTarget,
              minWidth: 64,
            ),
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(UiStrings.privacyDialogOk),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: tabs.indexOf(_tab),
        children: const [
          HomePage(),
          DetectPage(),
          RecordsPage(),
          ReportPage(),
        ],
      ),
      bottomNavigationBar: AcouNavBar(
        currentIndex: tabs.indexOf(_tab),
        onSelect: _select,
      ),
    );
  }
}

/// ADR-24: the mockups' bottom bar -- a white bar whose selected tab is a mint rounded tile with a
/// white glyph and caption, the other three plain grey.
///
/// It replaces `BottomNavigationBar` because Material's bar cannot draw the selected tile; the
/// contract it still satisfies is the one that matters: four fixed items, each at least 48 x 48 dp,
/// each exposed to the accessibility tree with its label and its selected state.
class AcouNavBar extends StatelessWidget {
  const AcouNavBar({super.key, required this.currentIndex, required this.onSelect});

  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// The labels, in FF-23's order. Kept here as a plain list so the bar and the shell can never
  /// disagree about how many tabs exist.
  static const List<String> labels = ['首页', '检测', '记录', '报告'];

  static const List<IconData> icons = [
    Icons.home_outlined,
    Icons.graphic_eq,
    Icons.list_alt_outlined,
    Icons.insights_outlined,
  ];

  static const List<IconData> activeIcons = [
    Icons.home,
    Icons.graphic_eq,
    Icons.list_alt,
    Icons.insights,
  ];

  /// The height of the bar's **inner** row (the selected tile is exactly this tall). It must stay
  /// a concrete number: see the note in [build].
  static const double barHeight = 56;

  /// The width of the selected tile. Narrower than a tab slot on purpose -- the mockup draws a
  /// rounded square around the active item, not a full-width panel.
  static const double tileWidth = 76;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '主导航',
        container: true,
        child: Container(
          color: AcouTheme.surface,
          padding: EdgeInsets.only(
            top: AcouTheme.spaceSm,
            bottom: AcouTheme.spaceSm + MediaQuery.paddingOf(context).bottom,
          ),
          // ⚠️ The explicit height is load-bearing, not decoration. `Scaffold` hands
          // `bottomNavigationBar` the **whole screen** as available height, so a `Column` that
          // keeps the default `MainAxisSize.max` (and the tile inside it) expands to fill that
          // space: the selected mint tile becomes a full-height bar and the page body is squeezed
          // to zero -- a blank screen. That is exactly how this bar first shipped (the emulator
          // screenshot in `docs/reports/adr24_ui_rebuild.md` section 11 records it), and
          // `test/ui/app_shell_layout_test.dart` now pins the height so it cannot come back.
          child: SizedBox(
            height: AcouNavBar.barHeight,
            child: Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: _NavItem(
                      index: i,
                      current: currentIndex == i,
                      onTap: onSelect,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.index, required this.current, required this.onTap});

  final int index;
  final bool current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: current,
        label: AcouNavBar.labels[index],
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onTap(index),
            child: Center(
              // The tile hugs its content (the mockups' rounded square), it never stretches to
              // the width of the tab slot.
              child: Container(
                width: AcouNavBar.tileWidth,
                height: AcouNavBar.barHeight,
                decoration: current
                    ? BoxDecoration(
                        color: AcouTheme.mintDeep,
                        borderRadius: BorderRadius.circular(AcouTheme.radiusMd),
                      )
                    : null,
                child: Column(
                  // Without this the column would try to be as tall as its parent allows.
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      current ? AcouNavBar.activeIcons[index] : AcouNavBar.icons[index],
                      size: 22,
                      color: current ? AcouTheme.onMint : AcouTheme.inkMuted,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AcouNavBar.labels[index],
                      style: AcouTheme.caption.copyWith(
                        fontWeight: current ? FontWeight.w700 : FontWeight.w600,
                        color: current ? AcouTheme.onMint : AcouTheme.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
