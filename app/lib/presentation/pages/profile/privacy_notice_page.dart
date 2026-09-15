// app/lib/presentation/pages/profile/privacy_notice_page.dart
//
// U-05 · 隐私设置. This is the compliance surface of the app, so the three notices of
// SPEC-U-05 section 4.3 appear verbatim and none of them is paraphrased:
//  * the privacy notice   (no network permission, audio stays in memory);
//  * the portability notice (data lives only on this device, v1.0 has no file export);
//  * the loss notice (uninstall and it is gone) -- mandatory after ADR-P4.
//
// The page also states what "copy as text" is **and is not**: it writes the clipboard, so it is
// not a file export and it does not weaken the privacy claim.

import 'package:flutter/material.dart';

import '../../../core/flavour.dart';
import '../../presenters/ui_strings.dart';
import '../../theme/acou_theme.dart';

class PrivacyNoticePage extends StatelessWidget {
  const PrivacyNoticePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text(UiStrings.privacyTitle)),
        body: ListView(
          padding: const EdgeInsets.all(AcouTheme.spacePage),
          children: [
            // ADR-44 / SPEC-U-07 section 4.3: the「无网络权限」entry is a claim about the OFFLINE
            // package's manifest (`SPEC-C-01` section 7 item 1a). The `agent` package declares
            // `INTERNET`, so it must render the egress-scope entry instead -- claiming the absent
            // permission in a build that has it would be the single worst sentence in the app.
            _Notice(
              icon: isOfflineFlavour ? Icons.wifi_off_outlined : Icons.cloud_outlined,
              title: isOfflineFlavour ? '无网络权限' : '云端智能的数据出境范围',
              body: UiStrings.privacyNotice,
            ),
            _Notice(
              icon: Icons.mic_none_outlined,
              title: '端侧推理',
              body: '音频只在内存的环形缓冲中处理，不写入存储；'
                  '会话结束时强制清理临时音频目录。',
            ),
            _Notice(
              icon: Icons.storage_outlined,
              title: '只存结构化字段',
              body: '数据库只保存时间、类别、置信度与行为指标，不保存任何音频、波形或特征张量。',
            ),
            _Notice(
              icon: Icons.inventory_2_outlined,
              title: '数据可携带性',
              body: UiStrings.portabilityNotice,
            ),
            _Notice(
              icon: Icons.content_copy_outlined,
              title: '复制为文本',
              body: '「${UiStrings.copyAsText}」把当前记录序列化为纯文本写入系统剪贴板：'
                  '不走网络、不落文件、不外发，也不申请任何新权限。',
            ),
            _Notice(
              icon: Icons.delete_forever_outlined,
              title: '一键清除',
              body: UiStrings.privacyLossNotice,
            ),
          ],
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: AcouTheme.spaceMd),
        padding: const EdgeInsets.all(AcouTheme.spaceMd),
        decoration: AcouTheme.cardDecoration(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AcouTheme.inkMuted),
            const SizedBox(width: AcouTheme.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AcouTheme.sectionTitle),
                  const SizedBox(height: AcouTheme.spaceXs),
                  Text(body, style: AcouTheme.body),
                ],
              ),
            ),
          ],
        ),
      );
}
