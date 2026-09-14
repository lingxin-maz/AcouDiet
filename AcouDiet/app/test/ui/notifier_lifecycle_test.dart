// 生命周期守卫的回归防线：**对已 dispose 的 ValueNotifier 赋值会抛异常**。
//
// 为什么单独立一个文件：这是一类**只有真实异步时序才会触发**的缺陷，而离线套件覆盖不到
// presentation 层的生命周期。本仓已多次栽在"用户会走到但测试不覆盖"的路径上
// （ADR-24 的 AppShell、v1.1.0 首包的润色层接线、ADR-29 的「否」按钮）。
//
// 实测到的风险：
//   1. ~~`HomeNotifier.requestWeeklyReview()` 在 await 之后写 `weeklyReview.value` /
//      `reviewLoading.value`~~ —— ADR-34 按用户要求删除了端侧语言模型层，这个方法与那两个
//      ValueNotifier 已不存在，对应的守卫断言随之删除（**不是被放宽，是主体没了**）。
//      保留这条注释，是为了让后来者知道这里**曾经**有一个真实缺陷，而不是"忘了写"。
//   2. `DetectNotifier` 的 `onLevel` 回调写 `level.value`，而 `dispose()` 调了
//      `level.dispose()` —— level 事件来自**真实平台通道**（10 Hz），
//      dispose 之后仍可能到达。**这一条仍然生效，且是现在唯一一条。**
//
// 本文件的第一条测试是**负控**：它证明这个异常真实存在。没有它，后面"守卫已接线"
// 的断言就只是文字游戏。
//
// 运行方式：`flutter test test/ui/notifier_lifecycle_test.dart`（需要 Flutter binding）。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('负控：对已 dispose 的 ValueNotifier 赋值确实会抛', (tester) async {
    final notifier = ValueNotifier<double>(0);
    notifier.dispose();

    // 这一条是"危险真实存在"的证据。如果哪天 Flutter 改成静默忽略，
    // 下面的守卫断言就失去了意义 —— 那时应当重新评估，而不是继续照抄。
    expect(
      () => notifier.value = 1,
      throwsA(isA<FlutterError>()),
      reason: '若这里不再抛，说明前提变了，本文件需要重新评估',
    );
  });

  test('DetectNotifier 的 level 回调带 mounted 守卫，而不是裸赋值', () {
    final src = File('lib/presentation/state/notifiers.dart').readAsStringSync();

    expect(
      src.contains('onLevel: _onLevel'),
      isTrue,
      reason: 'level 回调应指向带守卫的 _onLevel，而不是内联的裸赋值',
    );
    expect(
      src.contains('void _onLevel(double v)'),
      isTrue,
      reason: '找不到 _onLevel 守卫方法',
    );

    final start = src.indexOf('void _onLevel(double v)');
    final body = src.substring(start, start + 400);
    expect(body.contains('if (mounted) level.value = v;'), isTrue);

    // 反面：不得再出现内联的裸赋值（那正是修复前的写法）。
    expect(
      src.contains('onLevel: (v) => level.value = v'),
      isFalse,
      reason: '裸赋值会在 level 已 dispose 后抛未捕获异常',
    );
  });

  test('端侧语言模型层已彻底移除（ADR-34）', () {
    // ⚠️ 断言必须建立在**代码**上，不是原始文本上。本测试第一版直接 `src.contains('adviceModel')`，
    // 结果被自己写在注释里的 "`ADR-27` 增加的第 15 项 `adviceModel`" 判成失败 —— 一条**误报**
    // 的防线和一条永不触发的防线一样糟（本仓反复记录过这个模式）。所以先剥注释，再查代码。
    String code(String path) => File(path)
        .readAsStringSync()
        .split('\n')
        .where((l) {
          final t = l.trimLeft();
          return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
        })
        .join('\n');

    final notifiers = code('lib/presentation/state/notifiers.dart');
    final home = code('lib/presentation/pages/home/home_page.dart');
    final demo = code('lib/domain/model/demo.dart');

    for (final gone in ['WeeklyReview', 'weeklyReview', 'requestWeeklyReview', 'LlmEngine']) {
      expect(notifiers.contains(gone), isFalse, reason: 'notifiers.dart 仍残留 $gone');
    }
    expect(home.contains('aiReview'), isFalse, reason: 'home_page.dart 仍残留 AI 卡片');
    expect(home.contains('_AiWeeklyReviewCard'), isFalse);
    expect(demo.contains('adviceModel'), isFalse, reason: '自检键表仍残留第 15 项');

    // 键表回到 ADR-14 的 14 项闭集：`all` 里恰好 14 个标识符，且与 labels 一一对应。
    final allBlock = demo.substring(
        demo.indexOf('static const List<String> all'),
        demo.indexOf('static const Map<String, String> labels'));
    final keys = RegExp(r'^\s{4}([a-zA-Z]\w*),', multiLine: true)
        .allMatches(allBlock)
        .map((m) => m.group(1)!)
        .toList();
    expect(keys.length, 14, reason: '自检项应为 14 项，实际 ${keys.length}: $keys');
    expect(keys.toSet().length, 14, reason: '键不得重复');
    for (final k in keys) {
      expect(demo.contains(RegExp('$k: .+')), isTrue, reason: '$k 缺少 label');
    }
  });
}
