"""Runs real `dart analyze` over the Flutter app without `flutter pub get`.

WHY
---
The Flutter-dependent files (`main.dart`, `presentation/pages/**`, `presentation/widgets/**`,
`presentation/state/bootstrap.dart`, `test/ui/**`) cannot be compiled by the offline runners,
so a name/arity mismatch in those files would go unnoticed until someone with a Flutter
toolchain builds them. That is not hypothetical: this script's first run is what found
`bootstrap.dart` calling `AppServices.assemble(maintenance: ...)` when the parameter is
`maintenanceRepo:` -- invisible to every pure-Dart test.

HOW
---
The Flutter SDK in this toolchain already contains everything the analyzer needs:

* `packages/flutter/lib`                     -- the framework (material, widgets, services)
* `bin/cache/pkg/sky_engine/lib`             -- the `dart:ui` SDK library
* `packages/flutter_test/lib`                -- the real widget-test API
* `packages/flutter_tools/.dart_tool/package_config.json`
                                             -- a complete, already-resolved package graph

So this script resolves that config to absolute URIs, adds the app's own package
(`acoudiet` -> `app/lib`), writes it to `app/.dart_tool/package_config.json` (a build artifact,
git-ignored) and runs `dart analyze` from `app/`. No network, no `pub get`.

    python tool/analyze_flutter.py                 # analyze lib/ and test/
    python tool/analyze_flutter.py --path lib      # analyze a subtree
    python tool/analyze_flutter.py --fatal-warnings

Exit code mirrors `dart analyze`: 0 = no issues, 1 = errors, 2 = warnings (with
--fatal-warnings), 3 = errors+warnings.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse, unquote

ROOT = Path(__file__).resolve().parents[1]              # AcouDiet/
APP = ROOT / "app"
TOOLCHAIN = Path(r"D:\Desktop\Food\_toolchain")
FLUTTER = TOOLCHAIN / "flutter"
DART = FLUTTER / "bin" / "cache" / "dart-sdk" / "bin" / "dart.exe"
SDK_CONFIG = FLUTTER / "packages" / "flutter_tools" / ".dart_tool" / "package_config.json"


def _abs_uri(root_uri: str, base: Path) -> str:
    """Resolves a package_config rootUri (relative, file:// or absolute) to a file URI."""
    if root_uri.startswith("file:"):
        path = Path(unquote(urlparse(root_uri).path.lstrip("/"))) if not root_uri.startswith(
            "file:///") else Path(unquote(urlparse(root_uri).path[1:]))
        return path.as_uri()
    candidate = (base / root_uri).resolve()
    return candidate.as_uri()


def build_config(target: Path) -> tuple[int, list[str]]:
    if not SDK_CONFIG.exists():
        raise SystemExit(f"ACD-ART-001: Flutter SDK package config not found at {SDK_CONFIG}")

    raw = json.loads(SDK_CONFIG.read_text(encoding="utf-8"))
    base = SDK_CONFIG.parent
    packages: dict[str, dict] = {}

    for entry in raw.get("packages", []):
        name = entry["name"]
        packages[name] = {
            "name": name,
            "rootUri": _abs_uri(entry["rootUri"], base),
            "packageUri": entry.get("packageUri", "lib/"),
            "languageVersion": entry.get("languageVersion", "2.12"),
        }

    # The app itself.
    packages["acoudiet"] = {
        "name": "acoudiet",
        "rootUri": (APP).as_uri(),
        "packageUri": "lib/",
        "languageVersion": "3.5",
    }
    # The real flutter_test, when the SDK config did not already carry it.
    flutter_test = FLUTTER / "packages" / "flutter_test"
    if flutter_test.exists():
        packages["flutter_test"] = {
            "name": "flutter_test",
            "rootUri": flutter_test.as_uri(),
            "packageUri": "lib/",
            "languageVersion": "3.5",
        }

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps({"configVersion": 2, "packages": list(packages.values())}, indent=2),
        encoding="utf-8",
    )
    return len(packages), sorted(packages)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--path", default=None, help="subtree to analyze (default: lib and test)")
    ap.add_argument("--fatal-warnings", action="store_true")
    ap.add_argument("--fatal-infos", action="store_true")
    args = ap.parse_args()

    if not DART.exists():
        print(f"FAIL: dart not found at {DART}", file=sys.stderr)
        return 2

    config = APP / ".dart_tool" / "package_config.json"
    count, names = build_config(config)
    print("=" * 78)
    print("dart analyze over the Flutter app (no pub get)")
    print("=" * 78)
    print(f"package config : {config}  ({count} packages)")
    for probe in ("acoudiet", "flutter", "flutter_test", "sky_engine"):
        print(f"  {probe:14s} {'present' if probe in names else 'MISSING'}")
    print()

    targets = [args.path] if args.path else ["lib", "test"]
    cmd = [str(DART), "analyze", "--no-fatal-warnings"]
    if args.fatal_warnings:
        cmd = [str(DART), "analyze", "--fatal-warnings"]
    if args.fatal_infos:
        cmd.append("--fatal-infos")
    cmd += targets

    proc = subprocess.run(cmd, cwd=str(APP), text=True, encoding="utf-8",
                          errors="replace", capture_output=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    print(out.rstrip() or "(no output)")

    errors = out.count("error •") + out.count("error -")
    warnings = out.count("warning •") + out.count("warning -")
    infos = out.count("info •") + out.count("info -")
    print()
    print(f"summary: errors={errors} warnings={warnings} info={infos} exit={proc.returncode}")

    # `dart analyze` already returns a meaningful code; surface it unchanged so this can be a
    # regression gate once a Flutter toolchain is present.
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
