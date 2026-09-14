"""Runs the SPEC-named `app/test/**` suites offline, without `flutter pub get`.

WHY
---
`SPEC-A-01` section 7, `SPEC-A-02` section 7, `SPEC-A-03` section 7 and `SPEC-C-05` section 5
name their acceptance tests as `flutter test app/test/...`. Resolving `package:flutter_test`
requires `pub get`, which requires network -- unavailable here
(`docs/reports/c04_dependency_deviation.md`).

The *domain* and *config* suites only use `test`/`group`/`setUp`/`expect` + matchers, so this
script:

1. builds a `package_config.json` by hand from the local pub cache
   (`_toolchain/cache/pub/hosted/pub.flutter-io.cn/<name>-<version>/`), mapping
   `acoudiet` -> `app/lib` and `flutter_test` -> `tool/shims/flutter_test`;
2. executes every test file that does NOT need a Flutter binding;
3. reports widget-dependent files as "requires flutter test" instead of failing them.

Usage::

    python tool/run_offline_tests.py                 # run everything runnable
    python tool/run_offline_tests.py --list          # just classify the files
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]            # AcouDiet/
APP = ROOT / "app"
TEST_DIR = APP / "test"
SHIM = ROOT / "tool" / "shims"
TOOLCHAIN = Path(r"D:\Desktop\Food\_toolchain")
PUB_CACHE = TOOLCHAIN / "cache" / "pub" / "hosted" / "pub.flutter-io.cn"
DART = TOOLCHAIN / "flutter" / "bin" / "cache" / "dart-sdk" / "bin" / "dart.exe"

#: APIs that genuinely need the Flutter engine.
WIDGET_MARKERS = ("testWidgets(", "WidgetTester", "pumpWidget(", "find.byType",
                  "testGoldens", "matchesGoldenFile", "TestWidgetsFlutterBinding")


def package_paths() -> dict[str, Path]:
    """Maps every cached package name to its directory, newest version wins."""
    found: dict[str, tuple[tuple[int, ...], Path]] = {}
    if not PUB_CACHE.exists():
        return {}
    for entry in PUB_CACHE.iterdir():
        if not entry.is_dir() or entry.name.startswith("."):
            continue
        match = re.match(r"^(?P<name>.+?)-(?P<version>\d+(?:\.\d+)*(?:\+[0-9A-Za-z.\-]+)?)$",
                         entry.name)
        if not match:
            continue
        name = match.group("name")
        version = tuple(int(p) for p in re.findall(r"\d+", match.group("version")))
        lib = entry / "lib"
        if not lib.exists():
            continue
        current = found.get(name)
        if current is None or version > current[0]:
            found[name] = (version, lib)
    return {name: path for name, (_, path) in found.items()}


def language_version(package_dir: Path, default: str = "2.12") -> str:
    """Reads a package's own SDK lower bound from its pubspec and returns `major.minor`.

    `pub` derives each package's language version from that lower bound, and it matters in both
    directions:

    * `collection` declares `>=2.18.0 <4.0.0` and uses `class X` as a mixin -- legal in 2.x,
      rejected once the language version reaches 3.0. Pinning it to 3.5 breaks it.
    * `test_api` declares `^3.0.0` and uses class modifiers and switch expressions -- rejected
      when the language version is below 3.0. Defaulting it to 2.12 breaks it.

    So the constraint forms `>=A.B.C ...`, `^A.B.C` and a bare `A.B.C` must all be understood.
    """
    pubspec = package_dir / "pubspec.yaml"
    if not pubspec.exists():
        return default
    text = pubspec.read_text(encoding="utf-8", errors="replace")

    match = re.search(r"^\s*sdk\s*:\s*(.+)$", text, re.MULTILINE)
    if not match:
        return default
    constraint = match.group(1).strip().strip("'\"").split("#")[0].strip()

    version = None
    caret = re.search(r"\^\s*(\d+)\.(\d+)", constraint)
    if caret:
        version = (caret.group(1), caret.group(2))
    if version is None:
        lower = re.search(r">=?\s*(\d+)\.(\d+)", constraint)
        if lower:
            version = (lower.group(1), lower.group(2))
    if version is None:
        bare = re.fullmatch(r"(\d+)\.(\d+)(?:\.\d+)?", constraint)
        if bare:
            version = (bare.group(1), bare.group(2))
    if version is None:
        return default
    return f"{version[0]}.{version[1]}"


def build_package_config(path: Path) -> dict[str, Path]:
    """Builds a pub-compatible package config from the local cache plus the two local entries."""
    packages: list[dict[str, object]] = []
    libs: dict[str, Path] = {}

    if PUB_CACHE.exists():
        seen: dict[str, tuple[tuple[int, ...], Path]] = {}
        for entry in PUB_CACHE.iterdir():
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            match = re.match(
                r"^(?P<name>.+?)-(?P<version>\d+(?:\.\d+)*(?:\+[0-9A-Za-z.\-]+)?)$", entry.name)
            if not match or not (entry / "lib").exists():
                continue
            name = match.group("name")
            version = tuple(int(p) for p in re.findall(r"\d+", match.group("version")))
            current = seen.get(name)
            if current is None or version > current[0]:
                seen[name] = (version, entry)
        for name, (_, entry) in sorted(seen.items()):
            libs[name] = entry / "lib"
            packages.append({
                "name": name,
                "rootUri": entry.as_uri(),
                "packageUri": "lib/",
                "languageVersion": language_version(entry),
            })

    # Local entries, appended (pub accepts duplicates only if names differ -- they do).
    local = [("acoudiet", APP, "3.5"), ("flutter_test", SHIM / "flutter_test", "3.5")]
    for name, package_root, lang in local:
        libs[name] = package_root / "lib"
        packages.append({
            "name": name,
            "rootUri": package_root.as_uri(),
            "packageUri": "lib/",
            "languageVersion": lang,
        })

    config = {"configVersion": 2, "packages": packages}
    path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return libs


def classify(test_file: Path) -> str:
    text = test_file.read_text(encoding="utf-8", errors="replace")
    return "widget" if any(m in text for m in WIDGET_MARKERS) else "runnable"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--list", action="store_true", help="classify only, do not run")
    args = ap.parse_args()

    if not DART.exists():
        print(f"FAIL: dart not found at {DART}", file=sys.stderr)
        return 2

    config_dir = ROOT / "_build"
    config_dir.mkdir(parents=True, exist_ok=True)
    config = config_dir / "package_config.json"
    paths = build_package_config(config)

    print("=" * 78)
    print("Offline execution of the SPEC-named app/test suites")
    print("=" * 78)
    print(f"package config : {config}  ({len(paths)} packages mapped)")
    print(f"flutter_test   : {paths.get('flutter_test')}  (shim)")
    print()

    files = sorted(TEST_DIR.rglob("*_test.dart"))
    if not files:
        print("no *_test.dart files found")
        return 0

    runnable, widget = [], []
    for f in files:
        (widget if classify(f) == "widget" else runnable).append(f)

    print(f"runnable now   : {len(runnable)} file(s)")
    for f in runnable:
        print(f"  - {f.relative_to(APP)}")
    print(f"needs flutter  : {len(widget)} file(s)  (widget/binding APIs)")
    for f in widget:
        print(f"  - {f.relative_to(APP)}")
    print()

    if args.list:
        return 0

    failures = []
    for f in runnable:
        rel = f.relative_to(APP)
        print("-" * 78)
        print(f">>> {rel}")
        print("-" * 78)
        # encoding/errors are explicit on purpose: the child prints Chinese test names, and
        # decoding with the locale default (GBK on this machine) crashes the reader thread and
        # silently loses the whole output.
        child_env = dict(os.environ)
        child_env["PYTHONIOENCODING"] = "utf-8"
        proc = subprocess.run(
            [str(DART), f"--packages={config}", str(f)],
            cwd=str(APP), text=True, encoding="utf-8", errors="replace",
            capture_output=True, env=child_env,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        # Surface only the meaningful lines: the package:test progress spam is not useful
        # here, but failures and the final verdict are.
        keep = ("All tests passed", "Some tests failed", "Expected:", "Actual:",
                "[E]", "Error:", "Exception", "+0 -")
        printed = 0
        for line in out.splitlines():
            plain = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
            if not plain:
                continue
            if any(k in plain for k in keep) or "+0 -1" in plain:
                print(f"    {plain}")
                printed += 1
        if printed == 0:
            print("    (no output)")
        if proc.returncode != 0:
            failures.append(str(rel))
        print()

    print("=" * 78)
    if failures:
        print(f"OFFLINE app/test: {len(runnable) - len(failures)} passed, {len(failures)} failed")
        for f in failures:
            print(f"  FAIL {f}")
        print("=" * 78)
        return 1
    print(f"OFFLINE app/test: all {len(runnable)} runnable file(s) passed "
          f"({len(widget)} need a real `flutter test`)")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
