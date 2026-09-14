// app/lib/presentation/state/acou_scope.dart
//
// The dependency-injection surface that replaces Riverpod's `ProviderScope` + `ref.watch`.
//
// Why an `InheritedWidget` over a notifier registry: this build cannot resolve Riverpod, and the
// whole app needs exactly one scope, one set of page-level notifiers and one rebuild primitive.
// `AcouBuilder` is that primitive -- it listens to a single notifier, so a change to the score
// does not rebuild the timeline (the coarse rebuild an `InheritedNotifier` would cause).

import 'package:flutter/widgets.dart';

import 'app_services.dart';
import 'async_value.dart';
import 'notifiers.dart';

/// Holds the services plus one notifier per page, so that a page keeps its state while the user
/// moves between tabs.
class AcouNotifiers {
  AcouNotifiers(this.services)
      : home = HomeNotifier(services),
        records = RecordsNotifier(services),
        report = ReportNotifier(services),
        profile = ProfileNotifier(services),
        detect = DetectNotifier(services),
        selfCheck = SelfCheckNotifier(services);

  final AppServices services;

  final HomeNotifier home;
  final RecordsNotifier records;
  final ReportNotifier report;
  final ProfileNotifier profile;
  final DetectNotifier detect;
  final SelfCheckNotifier selfCheck;

  /// Loads the three read-only pages once at start-up so the first tab switch is instant.
  Future<void> prime() async {
    await Future.wait<void>([
      home.reload(),
      records.reload(),
      report.reload(),
      profile.reload(),
    ]);
  }

  Future<void> dispose() async {
    await detect.disposeHandle();
    home.dispose();
    records.dispose();
    report.dispose();
    profile.dispose();
    detect.dispose();
    selfCheck.dispose();
  }
}

/// The application scope.
class AcouScope extends InheritedWidget {
  const AcouScope({
    super.key,
    required this.services,
    required this.notifiers,
    required super.child,
  });

  final AppServices services;
  final AcouNotifiers notifiers;

  static AcouScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AcouScope>();
    assert(scope != null, 'AcouScope.of() called with a context that has no AcouScope above it');
    return scope!;
  }

  static AppServices servicesOf(BuildContext context) => of(context).services;

  static AcouNotifiers notifiersOf(BuildContext context) => of(context).notifiers;

  /// Looks the scope up without registering a dependency (for event handlers).
  static AppServices readServices(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AcouScope>()!.services;

  @override
  bool updateShouldNotify(AcouScope oldWidget) =>
      services != oldWidget.services || notifiers != oldWidget.notifiers;
}

/// Rebuilds [builder] whenever [notifier] publishes.
class AcouBuilder<T> extends StatelessWidget {
  const AcouBuilder({
    super.key,
    required this.notifier,
    required this.builder,
  });

  final AcouNotifier<T> notifier;
  final Widget Function(BuildContext context, AsyncValue<T> value) builder;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: notifier,
        builder: (context, _) => builder(context, notifier.state),
      );
}
