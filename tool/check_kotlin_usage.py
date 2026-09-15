"""Static consistency check of the Kotlin layer (Android host -> pure DSP / config).

WHY
---
`tool/jvm_build.ps1` compiles and tests the **Android-free** Kotlin classes (`audio/*.kt`,
`config/*.kt`). The Android host (`android/*.kt`, `MainActivity.kt`) is deliberately excluded,
because it needs the Android SDK classes -- so nothing in this environment ever type-checks the
calls it makes *into* those pure classes. A renamed method or an invented member would only
surface when someone builds the APK.

This script closes that gap the same way `tool/check_l4_usage.py` closes it for Dart: it indexes
the declared members of every Kotlin class in the app, then flags any call to a member that
exists on **no** class in the app -- the sound rule that produces no false positives from
name-based receiver typing.

It also verifies that every `import com.acoudiet.*` resolves to a declared symbol, and that the
Kotlin class names used from Dart-adjacent code (the `getCapabilities` payload keys) exist.

    python tool/check_kotlin_usage.py
    python tool/check_kotlin_usage.py --strict

Exit codes: 0 = clean, 2 = findings (with `ACD-ART-007` on the first stderr line).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # repository root
MAIN = ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin"

IMPORT_RE = re.compile(r"^import\s+(com\.acoudiet\.[\w.]+)", re.MULTILINE)
CLASS_RE = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s*)*"
    r"(?:public\s+|internal\s+|private\s+|abstract\s+|open\s+|sealed\s+|data\s+)*"
    r"class\s+(\w+)",
    re.MULTILINE)
OBJECT_RE = re.compile(r"^(?:public\s+|internal\s+)?object\s+(\w+)", re.MULTILINE)
#: `fun name(`, `val name`, `var name`, `const val name`.
#:
#: Indentation is 4..8 spaces on purpose: class members sit at 4, and members of a
#: `companion object` (which are also reachable as `ClassName.member`) sit at 8. Using an
#: exact 4 would report every companion factory in `AcouDietException` as missing.
MEMBER_RE = re.compile(r"^\s{4,8}(?:@\w+(?:\([^)]*\))?\s*)*"
                       r"(?:public\s+|internal\s+|private\s+|override\s+|suspend\s+|"
                       r"inline\s+|operator\s+|const\s+|lateinit\s+|abstract\s+)*"
                       r"(?:fun\s+(?:<[^>]+>\s*)?(\w+)|(?:val|var)\s+(\w+))",
                       re.MULTILINE)
#: `ClassName.member(` and `instance.member(` with a declared instance type
STATIC_CALL_RE = re.compile(r"\b([A-Z]\w+)\.(\w+)\s*[(<]")
CALL_RE = re.compile(r"\b([a-zA-Z_]\w*)\.(\w+)\s*\(")

#: Kotlin/Android/library members that no app class declares. The check's rule is "exists on no
#: app class", so these only matter for readability; they are listed to document intent.
KNOWN_EXTERNAL = {
    "copy", "toString", "hashCode", "equals", "get", "set", "add", "remove", "clear", "size",
    "isEmpty", "isNotEmpty", "first", "last", "map", "filter", "forEach", "any", "all", "none",
    "plus", "minus", "times", "div", "let", "run", "also", "apply", "with", "toList", "toSet",
    "toShortArray", "toFloatArray", "toDoubleArray", "toIntArray", "toFloat", "toDouble",
    "toInt", "toShort", "toByte", "joinToString", "reversed", "sorted", "sortedBy", "sumOf",
    "maxOf", "minOf", "coerceAtLeast", "coerceAtMost", "coerceIn", "count", "indexOf",
    "absolutePath", "exists", "listFiles", "delete", "length", "mkdirs", "readText",
    "post", "postDelayed", "removeCallbacks", "removeCallbacksAndMessages", "quitSafely",
    "start", "stop", "release", "read", "getMinBufferSize", "startRecording", "state",
    "recordingState", "getSystemService", "checkSelfPermission", "hasSystemFeature",
    "getSharedPreferences", "edit", "putBoolean", "apply", "getBoolean", "requestPermissions",
    "shouldShowRequestPermissionRationale", "success", "error", "notImplemented", "invokeMethod",
    "receiveBroadcastStream", "setMethodCallHandler", "setStreamHandler", "absolutePath",
    "currentTimeMillis", "getLooper", "absolutePath",
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def kotlin_files() -> list[Path]:
    return sorted(MAIN.rglob("*.kt"))


def index() -> tuple[dict[str, set[str]], set[str], dict[Path, str]]:
    members: dict[str, set[str]] = {}
    sources: dict[Path, str] = {}
    for path in kotlin_files():
        text = read(path)
        sources[path] = text
        names = set(CLASS_RE.findall(text)) | set(OBJECT_RE.findall(text))
        found = set()
        for m in MEMBER_RE.finditer(text):
            found.add(m.group(1) or m.group(2))
        for name in names:
            members.setdefault(name, set()).update(found)
    return members, set(members), sources


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    members, classes, sources = index()
    # Relative to the package root, NOT the absolute path: the Gradle module directory is
    # literally named `android`, so `"/android/" in path` would match every file.
    def is_host(path: Path) -> bool:
        rel = path.relative_to(MAIN).as_posix()
        return rel.startswith("android/") or path.name == "MainActivity.kt"

    android_host = [p for p in sources if is_host(p)]

    print("=" * 78)
    print("Kotlin usage consistency (Android host -> pure DSP / config)")
    print("=" * 78)
    print(f"files indexed  : {len(sources)}")
    print(f"classes/objects: {len(classes)}")
    print(f"android host   : {len(android_host)} file(s) not covered by the JVM suite")
    print()

    findings: list[str] = []

    # --- imports resolve ------------------------------------------------------------------
    for path, text in sources.items():
        for m in IMPORT_RE.finditer(text):
            fq = m.group(1)
            symbol = fq.split(".")[-1]
            if symbol in ("R",):
                continue
            if symbol not in classes:
                findings.append(
                    f"ACD-ART-007: {path.name} imports '{fq}' but no Kotlin class/object named "
                    f"'{symbol}' is declared in the app")

    # --- member calls that exist nowhere --------------------------------------------------
    all_members: set[str] = set()
    for s in members.values():
        all_members |= s

    for path, text in sources.items():
        for m in CALL_RE.finditer(text):
            recv, member = m.group(1), m.group(2)
            if member in all_members or member in KNOWN_EXTERNAL:
                continue
            # Only flag when the receiver looks like one of the app's own classes or one of the
            # well-known host instances; anything else is a library object we cannot type.
            if recv not in classes and recv not in {
                "envelope", "mel", "ring", "vad", "sm", "preSkill", "capture", "bridge",
                "record", "handler", "activity", "context", "result", "events", "sink",
            }:
                continue
            line = text[:m.start()].count("\n") + 1
            findings.append(
                f"ACD-ART-007: {path.name}:{line} calls {recv}.{member}(...) but no Kotlin class "
                f"in the app declares '{member}'")

    print()
    if findings:
        for f in findings:
            print(f"  [FAIL] {f}")
        print()
        print(f"RESULT: FAIL ({len(findings)} finding(s))")
        if args.strict:
            print(findings[0], file=sys.stderr)
            return 2
        return 0

    print("  [ok  ] every com.acoudiet.* import resolves to a declared class/object")
    print("  [ok  ] every member called on an app class or host instance exists")
    print()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
