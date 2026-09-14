// app/lib/presentation/pages/profile/about_page.dart
//
// U-05 · 关于. The brand is `AcouDiet` / `声膳` and nothing else (the old names are only allowed
// in historical context). The version comes from the assembly layer's build constant rather than
// from a literal in the widget tree, and `v1.0` is the documented fallback when the build system
// cannot supply one (SPEC-U-05 section 6).

import 'package:flutter/material.dart';

import '../../presenters/ui_strings.dart';
import '../../state/acou_scope.dart';
import '../../theme/acou_theme.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AcouScope.servicesOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text(UiStrings.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AcouTheme.spacePage),
        children: [
          Row(
            children: [
              const Icon(Icons.graphic_eq, size: 32, color: AcouTheme.seed),
              const SizedBox(width: AcouTheme.spaceSm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(UiStrings.appName, style: AcouTheme.sectionTitle),
                  Text(UiStrings.appNameZh, style: AcouTheme.bodyMuted),
                ],
              ),
            ],
          ),
          const SizedBox(height: AcouTheme.spaceMd),
          _Row(label: UiStrings.versionPrefix, value: services.versionText),
          _Row(label: '识别类别', value: '6 类典型食物（薯片 / 卷心菜 / 软糖 / 面条 / 胡萝卜 / 饮料）'),
          _Row(
            label: '数据存储',
            value: '仅本机 SQLite；不申请网络权限，音频不落盘',
          ),
          _Row(
            label: '检测速度口径',
            value: '从开始进食到首次确认结果约 4–5 秒（窗口长度与稳定判据的必然结果）',
          ),
          const SizedBox(height: AcouTheme.spaceMd),
          Text(
            '本应用提供饮食行为与营养摄入的估算参考，不进行疾病诊断，'
            '不替代专业医疗意见。',
            style: AcouTheme.caption,
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AcouTheme.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AcouTheme.bodyMuted),
            const SizedBox(height: 2),
            Text(value, style: AcouTheme.body),
          ],
        ),
      );
}
