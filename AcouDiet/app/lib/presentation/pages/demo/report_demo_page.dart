// app/lib/presentation/pages/demo/report_demo_page.dart
//
// M-03 · Demo Mode C · 报告演示. The fallback that works when neither the microphone nor the model
// does: preloaded demonstration rows drive the report page.
//
// The page is an orchestrator, not a second report view: it loads / clears the Track 2 dataset
// through `DemoDataController` (via `DemoController.loadReportDemo`), shows the dataset state, and
// sends the user to the real report page. Two "演示数据" badges are rendered -- one here and one in
// the report page -- which is what M-03's C5 wants, and the badge is never a footnote.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../theme/acou_theme.dart';
import '../../widgets/demo_banner.dart';
import '../report/report_page.dart';

class ReportDemoPage extends StatefulWidget {
  const ReportDemoPage({super.key});

  @override
  State<ReportDemoPage> createState() => _ReportDemoPageState();
}

class _ReportDemoPageState extends State<ReportDemoPage> {
  bool _busy = false;
  String? _message;
  String? _datasetVersion;
  bool _versionRead = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_versionRead) {
      _versionRead = true;
      _readDatasetVersion();
    }
  }

  /// Reads the dataset's own declared version.
  ///
  /// `DemoDataController` has no version field (SPEC-M-03 section 10 #2 registers that as an open
  /// item against API-04 section 6), so the page reads the one field it needs straight from the
  /// file. It writes nothing and it does not re-validate: the loader remains the single validator.
  Future<void> _readDatasetVersion() async {
    final services = AcouScope.servicesOf(context);
    try {
      final text = await services.assets.readString(services.demoData.datasetPath);
      final decoded = jsonDecode(text);
      if (decoded is Map && mounted) {
        final version = decoded['schemaVersion'] ?? decoded['datasetVersion'];
        setState(() => _datasetVersion = version?.toString());
      }
    } catch (_) {
      // A missing or malformed file is reported by the loader as ACD-DEMO-002; here it simply
      // means "version unknown".
    }
  }

  Future<void> _load() async {
    final notifier = AcouScope.notifiersOf(context).selfCheck;
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = await notifier.loadReportDemo();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok
          ? '演示数据集已加载，报告页数字由该数据集复算得出'
          : notifier.switchFailure;
    });
  }

  Future<void> _clear() async {
    final notifier = AcouScope.notifiersOf(context).profile;
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = await notifier.clearDemoData();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok ? '演示数据已清除，真实记录未受影响' : UiStrings.clearFailed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final services = AcouScope.servicesOf(context);
    final demoActive = services.demoData.isDemoActive;
    return Scaffold(
      appBar: AppBar(title: const Text(UiStrings.reportDemoTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          // Badge one: the page header. The report page renders the second one.
          DemoBanner(
            visible: demoActive,
            note: '本次演示使用预置数据集，数字可由评分引擎复算',
          ),
          Padding(
            padding: const EdgeInsets.all(AcouTheme.spacePage),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusRow(label: '数据源', value: demoActive ? '演示数据' : '真实累积记录'),
                _StatusRow(
                  label: '数据集版本',
                  value: _datasetVersion ?? '随包发布（未声明版本）',
                ),
                const SizedBox(height: AcouTheme.spaceMd),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget + 8),
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _load,
                    icon: const Icon(Icons.science_outlined),
                    label: const Text(UiStrings.reportDemoLoad),
                  ),
                ),
                const SizedBox(height: AcouTheme.spaceSm),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                  child: OutlinedButton.icon(
                    onPressed: _busy || !demoActive ? null : _clear,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text(UiStrings.clearDemoData),
                  ),
                ),
                const SizedBox(height: AcouTheme.spaceSm),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: AcouTheme.minTapTarget),
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const ReportPage()),
                    ),
                    icon: const Icon(Icons.insights_outlined),
                    label: const Text(UiStrings.healthReportEntry),
                  ),
                ),
                if (_message != null) ...[
                  const SizedBox(height: AcouTheme.spaceMd),
                  Text(_message!, style: AcouTheme.caption),
                ],
                const SizedBox(height: AcouTheme.spaceMd),
                Text(
                  '演示数据是构造数据，不含任何真实受试者信息；清除演示数据只删除 '
                  'source = demo 的行，真实记录一条不动。',
                  style: AcouTheme.caption,
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AcouTheme.spaceXs),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AcouTheme.bodyMuted)),
            Text(value, style: AcouTheme.metric),
          ],
        ),
      );
}
