// app/lib/main.dart
//
// AcouDiet (声膳) -- application entry point.
//
// What happens before the first frame:
//   1. `buildAppServices()` reads `assets/foods.json`, tries the SQLite repositories (falling back
//      to the deterministic in-memory ones), and runs the **C-03 start-up handshake**;
//   2. the handshake result decides whether the detection page is reachable at all: a mismatch is
//      `ACD-CFG-001` and the page renders the explanation with no start button (SPEC-U-02
//      section 6). That gate is not advisory -- it is the last line of defence against a
//      native/Dart feature-configuration drift silently corrupting every tensor;
//   3. the demo-data flag is refreshed so the badge is correct on the very first screen.
//
// The layer rule: this file is the only place that chooses between the real and the placeholder
// implementations. No page knows which one it got (API-00 section 1 rule 1).

import 'package:flutter/material.dart';

import 'presentation/pages/shell/app_shell.dart';
import 'presentation/state/acou_scope.dart';
import 'presentation/state/bootstrap.dart';
import 'presentation/theme/acou_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final boot = await buildAppServices();
  runApp(AcouDietApp(bootstrap: boot));
}

class AcouDietApp extends StatefulWidget {
  const AcouDietApp({super.key, required this.bootstrap});

  final BootstrapResult bootstrap;

  @override
  State<AcouDietApp> createState() => _AcouDietAppState();
}

class _AcouDietAppState extends State<AcouDietApp> {
  late final AcouNotifiers _notifiers = AcouNotifiers(widget.bootstrap.services);

  @override
  void dispose() {
    _notifiers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AcouScope(
      services: widget.bootstrap.services,
      notifiers: _notifiers,
      child: MaterialApp(
        title: 'AcouDiet 声膳',
        debugShowCheckedModeBanner: false,
        theme: AcouTheme.light(),
        home: const AppShell(),
        builder: (context, child) {
          // Follow the system font scale but never let a card overflow: the shell clamps the
          // scaler rather than letting a single long label push a chart off screen.
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: media.textScaler.clamp(
                minScaleFactor: 1.0,
                maxScaleFactor: 1.6,
              ),
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
      ),
    );
  }
}
