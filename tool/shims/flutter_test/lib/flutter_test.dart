// Minimal `flutter_test` shim for the offline test runner.
//
// WHY THIS EXISTS
// ---------------
// The tests under `app/test/**` import `package:flutter_test/flutter_test.dart`, because that
// is what the SPECs name (`SPEC-A-01` section 7, `SPEC-C-05` section 5). Resolving the real
// package needs `flutter pub get`, which needs network — unavailable in this environment
// (see `records/reports/c04_dependency_deviation.md`).
//
// The *domain* and *config* suites, however, only use `test` / `group` / `setUp` / `expect`
// plus matchers — none of which need a Flutter binding. This shim re-exports those from
// `package:test`, and `tool/run_offline_tests.py` builds a package config that maps
// `flutter_test` here. The result: the SPEC-named test files are **actually executed**, not
// merely written.
//
// What this shim deliberately does NOT provide: `testWidgets`, `WidgetTester`, `pumpWidget`,
// `find`, golden and binding APIs. Widget tests genuinely require the Flutter engine and must
// be run with a real `flutter test` on a networked machine; `tool/run_offline_tests.py`
// detects those files and reports them as "requires flutter test" instead of failing.
library flutter_test;

export 'package:test/test.dart';
