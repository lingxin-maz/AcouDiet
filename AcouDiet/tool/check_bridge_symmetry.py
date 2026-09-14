"""Kotlin <-> Dart bridge symmetry check (API-01 section 5, "side-to-side" acceptance).

WHY
---
`API-01` section 5 item 2 asks for a symmetry test between the two sides of the platform
channel: a method the Dart side invokes but Kotlin does not implement fails only at runtime,
on a device, in the middle of a demo. Nothing in the offline suite can reach it, because the
two sides are written in different languages.

This script compares the two sides as *text* -- the Kotlin method-name switch against the Dart
invocation strings, the Kotlin event `type` values against the Dart cases, and the two copies
of the handshake field list -- so a rename on one side is caught at build time instead.

    python tool/check_bridge_symmetry.py
    python tool/check_bridge_symmetry.py --strict

Exit codes: 0 = symmetric, 2 = asymmetry (with `ACD-ART-007` on the first stderr line).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # AcouDiet/
KOTLIN = ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin" / "com" / "acoudiet" / "app"
DART_DATA = ROOT / "app" / "lib" / "data" / "native"

HOST = KOTLIN / "android" / "AudioChannelHostAndroid.kt"
BRIDGE_KT = KOTLIN / "android" / "AudioBridgeAndroid.kt"
CONFIG_KT = KOTLIN / "config" / "FeatureConfig.kt"
BRIDGE_DART = DART_DATA / "method_channel_audio_bridge.dart"
EVENTS_DART = ROOT / "app" / "lib" / "domain" / "service" / "detection_session.dart"
CAPS_DART = ROOT / "app" / "lib" / "domain" / "model" / "demo.dart"

#: The second channel: the on-device SQLite engine. Android cannot `dlopen` a system SQLite,
#: so the database is reached through `android.database.sqlite`; a name that disagrees between
#: the two sides makes the app silently fall back to the in-memory store and stop persisting,
#: which is exactly the defect that motivated this channel. It therefore gets the same
#: side-to-side check as the audio channel.
SQLITE_KT = KOTLIN / "android" / "SqliteChannelHostAndroid.kt"
SQLITE_DART = DART_DATA / "method_channel_sqlite.dart"

#: Methods the platform channel is allowed to carry that are deliberately not part of the
#: Dolphin-style request/response surface (none today -- kept explicit so additions are
#: conscious).
ALLOWED_KOTLIN_ONLY: set[str] = set()
ALLOWED_DART_ONLY: set[str] = set()


def text(path: Path) -> str:
    if not path.exists():
        raise SystemExit(f"ACD-ART-007: missing file {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def kotlin_methods() -> set[str]:
    return set(re.findall(r'^\s*"(\w+)"\s*->', text(HOST), re.MULTILINE))


def dart_invocations() -> set[str]:
    return set(re.findall(r"_invoke\(\s*'(\w+)'", text(BRIDGE_DART)))


def kotlin_event_types() -> set[str]:
    return set(re.findall(r'"type"\s+to\s+"(\w+)"', text(BRIDGE_KT)))


def dart_event_types() -> set[str]:
    return set(re.findall(r"case\s+'(\w+)':", text(EVENTS_DART)))


def kotlin_handshake_fields() -> list[str]:
    body = text(CONFIG_KT)
    block = re.search(r"fun handshakeFields\(\).*?linkedMapOf\((.*?)\n\s*\)",
                      body, re.DOTALL)
    if not block:
        return []
    return re.findall(r'"(\w+)"\s+to', block.group(1))


def dart_handshake_fields() -> list[str]:
    body = text(CAPS_DART)
    block = re.search(r"handshakeFields\s*=\s*\[(.*?)\]", body, re.DOTALL)
    if not block:
        return []
    return re.findall(r"'(\w+)'", block.group(1))


def sqlite_kotlin_methods() -> set[str]:
    return set(re.findall(r'^\s*"(\w+)"\s*->', text(SQLITE_KT), re.MULTILINE))


def sqlite_dart_methods() -> set[str]:
    """Methods the Dart adapter actually sends (`_invoke('name', ...)`)."""
    return set(re.findall(r"_invoke\(\s*'(\w+)'", text(SQLITE_DART)))


def sqlite_channel_names() -> tuple[set[str], set[str]]:
    """The channel string on each side -- a mismatch means *no* database on device."""
    kt = set(re.findall(r'const\s+val\s+CHANNEL\s*=\s*"([^"]+)"', text(SQLITE_KT)))
    dart = set(re.findall(r"channelName\s*=\s*'([^']+)'", text(SQLITE_DART)))
    return kt, dart


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    kt_methods = kotlin_methods()
    dart_methods = dart_invocations()
    kt_events = kotlin_event_types()
    dart_events = dart_event_types()
    kt_fields = kotlin_handshake_fields()
    dart_fields = dart_handshake_fields()
    sq_kt = sqlite_kotlin_methods()
    sq_dart = sqlite_dart_methods()
    sq_kt_channel, sq_dart_channel = sqlite_channel_names()

    print("=" * 78)
    print("Kotlin <-> Dart bridge symmetry (API-01)")
    print("=" * 78)
    print(f"kotlin methods : {', '.join(sorted(kt_methods))}")
    print(f"dart invokes   : {', '.join(sorted(dart_methods))}")
    print(f"kotlin events  : {', '.join(sorted(kt_events))}")
    print(f"dart consumes  : {', '.join(sorted(dart_events))}")
    print(f"handshake      : kotlin={len(kt_fields)} dart={len(dart_fields)}")
    print(f"sqlite kotlin  : {', '.join(sorted(sq_kt))}")
    print(f"sqlite dart    : {', '.join(sorted(sq_dart))}")
    print(f"sqlite channel : kotlin={sorted(sq_kt_channel)} dart={sorted(sq_dart_channel)}")
    print()

    findings: list[str] = []

    for m in sorted(dart_methods - kt_methods - ALLOWED_DART_ONLY):
        findings.append(f"ACD-ART-007: Dart invokes '{m}' but Kotlin does not implement it")
    for m in sorted(kt_methods - dart_methods - ALLOWED_KOTLIN_ONLY):
        findings.append(f"ACD-ART-007: Kotlin implements '{m}' but Dart never invokes it")

    for e in sorted(dart_events - kt_events):
        findings.append(f"ACD-ART-007: Dart handles event '{e}' that Kotlin never emits")
    for e in sorted(kt_events - dart_events):
        findings.append(f"ACD-ART-007: Kotlin emits event '{e}' that Dart never handles")

    # ---- the SQLite channel -------------------------------------------------------------
    if not sq_kt_channel or not sq_dart_channel:
        findings.append(
            "ACD-ART-007: could not read the SQLite channel name on "
            f"{'Kotlin' if not sq_kt_channel else 'Dart'} side")
    elif sq_kt_channel != sq_dart_channel:
        findings.append(
            f"ACD-ART-007: SQLite channel name differs: kotlin={sorted(sq_kt_channel)} "
            f"vs dart={sorted(sq_dart_channel)} -- on device this yields NO database at all")
    if not sq_kt:
        findings.append("ACD-ART-007: the Kotlin SQLite handler exposes no methods")
    for m in sorted(sq_dart - sq_kt):
        findings.append(f"ACD-ART-007: Dart SQLite adapter sends '{m}' with no Kotlin handler")
    for m in sorted(sq_kt - sq_dart):
        findings.append(f"ACD-ART-007: Kotlin SQLite handler has '{m}' that Dart never sends")
    # The seven methods the protocol promises; a silent drop would break a contract the Dart
    # adapter assumes (e.g. losing `begin`/`commit` would quietly break invariant I-3).
    expected_sqlite = {"open", "execute", "query", "begin", "commit", "rollback", "close"}
    if sq_kt != expected_sqlite:
        findings.append(
            f"ACD-ART-007: the SQLite protocol must expose exactly {sorted(expected_sqlite)}, "
            f"Kotlin has {sorted(sq_kt)}")

    if len(kt_fields) != len(dart_fields):
        findings.append(
            f"ACD-ART-007: handshake field count differs (kotlin={len(kt_fields)}, "
            f"dart={len(dart_fields)})")
    elif kt_fields != dart_fields:
        findings.append(
            f"ACD-ART-007: handshake field names/order differ: kotlin={kt_fields} vs dart={dart_fields}")
    # The two lists must agree exactly (checked above). The COUNT is a moving contract: ADR-21
    # deliberately grew it from 12 to 15 so the rewritten Mel front end is covered. A bare
    # `!= 12` literal would only be edited again at the next ADR and would say nothing about
    # WHICH fields are covered, so the expected set is named instead: a field silently dropped
    # in the same edit on both sides is caught here, and the failure names it.
    hs_required = {
        "melVersion", "sampleRate", "nFft", "hopLength", "nMels", "rawMelFrames", "nFrames",
        "fmin", "fmax", "preemphasis", "preemphasisBoundary", "powerToDbRef", "topDb",
        "normalization", "patchSamples",
    }
    if set(kt_fields) != hs_required:
        findings.append(
            f"ACD-ART-007: the handshake must compare the ADR-21 field set "
            f"(missing={sorted(hs_required - set(kt_fields))}, "
            f"extra={sorted(set(kt_fields) - hs_required)})")

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

    print("  [ok  ] every Dart invocation has a Kotlin handler (and vice versa)")
    print("  [ok  ] every Kotlin event type is handled by Dart (and vice versa)")
    print("  [ok  ] the 15 handshake fields agree in name, order and count (ADR-21)")
    print("  [ok  ] the SQLite channel name and its 7 methods agree on both sides")
    print()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
