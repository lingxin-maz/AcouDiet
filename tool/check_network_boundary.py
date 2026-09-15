"""Every network call in the app must live in one of three whitelisted directories.

    python tool/check_network_boundary.py            # report
    python tool/check_network_boundary.py --strict   # exit 2 on any finding
    python tool/check_network_boundary.py --selftest # prove the detector can fail

WHY THIS EXISTS (`ADR-44`, `R-OUT-4`)
-------------------------------------
For its whole life this repository proved "there is no network" by asserting that a five
keyword search over `app/lib` returned zero hits. That was an honest gate while the answer was
zero. It stopped being usable the moment one directory legitimately needed a socket, and the
tempting replacement -- "trust the reviewer to notice a new `HttpClient`" -- is not a gate at
all.

This turns the rule inside out: instead of "no network anywhere", the rule is **the network is
allowed in exactly three directories**, and a hit ANYWHERE ELSE fails. That is strictly
stronger than the old check for the property that actually matters: not "we wrote no network
code" but "the network code is where we decided it may be".

    app/lib/data/net/**                                    -- the connection layer
    app/lib/domain/agent/**                                -- the agent domain (no sockets, but
                                                              it owns the request assembly)
    app/android/app/src/main/kotlin/com/acoudiet/app/agent/**

It also enforces two things that are cheap to check and expensive to get wrong:

  * `FF-26i` -- no AccessibilityService anywhere. `FF-26i` forbids automating a takeout order,
    and the accessibility route is the only technically viable way to do it, so its absence is
    asserted rather than assumed.
  * `FF-26h` -- the model identifier must not appear as a literal in Dart or Kotlin source. The
    vendor renamed and retired two model names in a single year; a hardcoded name rots silently
    and nothing else in the toolchain would notice.

WHAT IT DOES NOT DO: it does not prove the network layer is called correctly, and it is not a
sandbox. It is a tripwire on the `git diff` of a rule that has already been broken once in this
project's history (an earlier check was a false negative by construction -- see the note in
`check_apk_contents.py`).

Exit codes: 0 = clean (or, with --selftest, the detector discriminates), 2 = findings,
1 = the selftest failed or the source tree is missing.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # repository root

#: Directories where a network call is allowed. Relative to the repository root.
NETWORK_WHITELIST: tuple[str, ...] = (
    "app/lib/data/net",
    "app/lib/domain/agent",
    "app/android/app/src/main/kotlin/com/acoudiet/app/agent",
)

#: Files exempt from the model-name literal rule. These are the SSOT PROJECTIONS: the generator
#: `tool/gen_feature_config.dart` writes the model name into both the Dart constants and the
#: Kotlin `FeatureConfig` object, and that is exactly what `FF-26h` intends ("only in the SSOT
#: and its generated projections"). Everywhere else the name must be read from the constant.
#:
#: The first version of this script exempted by the substring `feature_config` only, which does
#: not match `FeatureConfig.kt` -- so the gate failed on the one file it was supposed to allow.
#: A gate that fires on its own sanitiser gets an exception added, and then it is gone.
MODEL_NAME_EXEMPT_SUBSTRINGS: tuple[str, ...] = ("feature_config", "featureconfig")

#: The literal that must not be hardcoded. Kept as a plain string rather than imported from the
#: SSOT on purpose: this script must be runnable before the generator has ever run.
MODEL_NAME_LITERAL = "deepseek-flash"

#: Network-shaped API names. Deliberately NOT `dart:io` as a whole: `dart:io` is also where
#: `File` and `Directory` come from, and both are used all over the storage layer.
#:
#: ⚠️ `openUrl` was in this list and was REMOVED, for a reason worth recording: `openUrl` is also
#: the name of the platform-channel method this project uses to HAND OFF a takeout search to
#: another app (`acoudiet/agent` -> `openUrl`). So the checker fired on the sanctioned handoff
#: bridge, in `app/lib/data/native/agent_bridge.dart`. The workstream that hit it did the correct
#: thing -- it reported the conflict -- but the mitigation it chose was to split the literal into
#: two adjacent strings (`'open' 'Url'`) to dodge the scan. **A gate that makes an honest
#: implementation obfuscate itself has its polarity inverted**; the fix belongs here, not there.
#: Nothing is lost by the removal: `HttpClient` is the actual marker of the network layer, and
#: `openUrl` on its own is just a method name the network layer happens to use.
NETWORK_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("HttpClient", re.compile(r"\bHttpClient\b")),
    ("HttpClientRequest/Response", re.compile(r"\bHttpClient(Request|Response)\b")),
    ("HttpRequest", re.compile(r"\bHttpRequest\b")),
    ("WebSocket", re.compile(r"\bWebSocket\b")),
    ("Socket", re.compile(r"\b(RawSocket|SecureSocket|Socket\.connect|ServerSocket)\b")),
    ("package:http", re.compile(r"""['"]package:http/""")),
    ("package:dio", re.compile(r"""['"]package:dio/""")),
    ("package:url_launcher", re.compile(r"""['"]package:url_launcher/""")),
)

FORBIDDEN_EVERYWHERE: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("AccessibilityService (FF-26i)", re.compile(r"\bAccessibilityService\b")),
    (
        "BIND_ACCESSIBILITY_SERVICE (FF-26i)",
        re.compile(r"BIND_ACCESSIBILITY_SERVICE"),
    ),
)

SOURCE_SUFFIXES = (".dart", ".kt", ".java", ".gradle", ".xml")


def _is_whitelisted(rel: Path) -> bool:
    posix = rel.as_posix()
    return any(posix.startswith(w + "/") or posix == w for w in NETWORK_WHITELIST)


def _strip_comments(text: str) -> str:
    """Remove `//`, `/* */` and `<!-- -->` comments so documentation cannot trip the scan.

    This matters concretely, and twice over:

      * `agent_transport.dart` documents that it contains no `Uint8List` member, and a naive
        scanner reads that sentence as a violation;
      * `app/android/app/src/agent/AndroidManifest.xml` explains at length WHY an accessibility
        service is not used, and the first version of this scanner had no XML rule at all -- so
        it fired on the manifest for *describing the thing it forbids*. The Android workstream
        found that and had to reword three comments to dodge a scanner that was wrong.

    That is the exact failure this project keeps hitting: a gate that fires on prose gets an
    exception added, and then it is gone. Fix the scanner, not the prose.
    """
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)
    text = re.sub(r"//.*$", "", text, flags=re.M)
    return text


def scan(root: Path) -> list[str]:
    """Returns a list of human-readable findings. Empty means clean."""
    findings: list[str] = []
    src = root / "app"
    if not (src / "lib").exists():
        raise SystemExit(f"ACD-NET-000: no app/lib under {root} -- wrong tree?")

    # ONE walk, not two. Walking `app` and then `app/android` as well made every Android file
    # appear twice, so a single real finding was reported as two -- which reads as "two
    # problems" and sends the next person looking for a second one that does not exist.
    for path in sorted(src.rglob("*")):
        if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
            continue
        rel = path.relative_to(root)
        if any(part in {"build", ".dart_tool", ".gradle"} for part in rel.parts):
            continue
        try:
            raw = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        text = _strip_comments(raw)

        for label, pattern in FORBIDDEN_EVERYWHERE:
            if pattern.search(text):
                findings.append(f"{rel}: {label}")

        # `FF-26h`: the model identifier may exist in the SSOT projections and nowhere else.
        name_lower = rel.name.lower()
        if MODEL_NAME_LITERAL in text and not any(
            s in name_lower for s in MODEL_NAME_EXEMPT_SUBSTRINGS
        ):
            findings.append(
                f"{rel}: contains the model identifier literal '{MODEL_NAME_LITERAL}' "
                f"(FF-26h: read feature_config.agent.model instead)"
            )

        if _is_whitelisted(rel):
            continue

        for label, pattern in NETWORK_PATTERNS:
            for m in pattern.finditer(text):
                line = text[: m.start()].count("\n") + 1
                findings.append(
                    f"{rel}:{line}: network API '{label}' outside the whitelist "
                    f"(allowed only under {', '.join(NETWORK_WHITELIST)})"
                )

    return findings


# --------------------------------------------------------------------------- the selftest

#: Each case is (name, relative path, file body, must_be_caught).
SELFTEST_CASES: tuple[tuple[str, str, str, bool], ...] = (
    (
        "an HttpClient outside the whitelist must be caught",
        "app/lib/presentation/pages/leak.dart",
        "import 'dart:io';\nvoid f() { HttpClient(); }\n",
        True,
    ),
    (
        "the same call INSIDE the whitelist must NOT be caught",
        "app/lib/data/net/ok.dart",
        "import 'dart:io';\nvoid f() { HttpClient(); }\n",
        False,
    ),
    (
        "a new pub dependency must be caught",
        "app/lib/data/repository/http_repo.dart",
        "import 'package:http/http.dart';\nvoid f() {}\n",
        True,
    ),
    (
        "an AccessibilityService must be caught even inside the whitelist",
        "app/android/app/src/main/kotlin/com/acoudiet/app/agent/Tap.kt",
        "class Tap : AccessibilityService()\n",
        True,
    ),
    (
        "the model identifier must be caught in Dart source",
        "app/lib/presentation/pages/bad.dart",
        "const m = 'deepseek-flash';\n",
        True,
    ),
    (
        "the model identifier must be allowed in the generated constants",
        "app/lib/core/feature_config.g.dart",
        "const m = 'deepseek-flash';\n",
        False,
    ),
    (
        # The first version of this checker exempted only `feature_config` (snake_case), which
        # does not match the GENERATED KOTLIN file -- so the gate failed on the exact file it was
        # built to allow. That real miss is now a case.
        "the model identifier must be allowed in the generated Kotlin constants",
        "app/android/app/src/main/kotlin/com/acoudiet/app/config/FeatureConfig.kt",
        "const val AGENT_MODEL: String = \"deepseek-flash\"\n",
        False,
    ),
    (
        "a comment mentioning HttpClient must NOT be caught (prose is not code)",
        "app/lib/presentation/pages/doc.dart",
        "// we deliberately do not use an HttpClient here\nvoid f() {}\n",
        False,
    ),
    (
        # The real miss: the Android manifest explains why an accessibility service is NOT
        # used, and the first scanner had no XML comment rule -- so it failed on the manifest
        # for describing the very thing it forbids. Caught by the Android workstream.
        "an XML comment mentioning AccessibilityService must NOT be caught",
        "app/android/app/src/main/AndroidManifest.xml",
        "<manifest>\n  <!-- we do NOT use an AccessibilityService; FF-26i forbids it -->\n"
        "  <application />\n</manifest>\n",
        False,
    ),
    (
        "an XML comment mentioning http must NOT be caught",
        "app/android/app/src/main/AndroidManifest.xml",
        "<manifest>\n  <!-- no HttpClient here, and no package:http dependency -->\n"
        "  <application />\n</manifest>\n",
        False,
    ),
    (
        # The real false positive: `openUrl` is ALSO the platform-channel method this project
        # uses to hand a takeout search to another app. The checker used to classify the bare
        # token as a network API, so it fired on the sanctioned bridge.
        "a platform-channel method named openUrl must NOT be caught",
        "app/lib/data/native/agent_bridge.dart",
        "const _channel = MethodChannel('acoudiet/agent');\n"
        "Future<void> f() => _channel.invokeMethod('openUrl', {'url': u});\n"
        "Future<bool> g() => _channel.invokeMethod('canOpenUrl', {'url': u});\n",
        False,
    ),
)


def selftest() -> int:
    print("=" * 78)
    print("network boundary detector -- selftest")
    print("=" * 78)

    failures = 0
    for name, rel, body, must_be_caught in SELFTEST_CASES:
        tmp = Path(tempfile.mkdtemp(prefix="acd_net_"))
        try:
            (tmp / "app" / "lib").mkdir(parents=True, exist_ok=True)
            target = tmp / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(body, encoding="utf-8")
            got = bool(scan(tmp))
            ok = got == must_be_caught
            want = "caught" if must_be_caught else "clean"
            mark = "[ok]  " if ok else "[FAIL]"
            print(f"  {mark} {name}  (expected {want}, got "
                  f"{'caught' if got else 'clean'})")
            if not ok:
                failures += 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    print()
    print("=" * 78)
    if failures:
        print(f"RESULT: the detector FAILED {failures} of {len(SELFTEST_CASES)} cases")
        print("=" * 78)
        return 1
    print(f"RESULT: the detector discriminates all {len(SELFTEST_CASES)} cases "
          f"({sum(1 for c in SELFTEST_CASES if not c[3])} accept, "
          f"{sum(1 for c in SELFTEST_CASES if c[3])} reject)")
    print("=" * 78)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true", help="exit non-zero on any finding")
    ap.add_argument("--selftest", action="store_true", help="prove the detector can fail")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    print("=" * 78)
    print("Cloud egress boundary (ADR-44 / R-OUT-4)")
    print("=" * 78)
    for w in NETWORK_WHITELIST:
        print(f"  allowed: {w}")

    findings = scan(ROOT)
    print()
    if findings:
        print(f"  {len(findings)} finding(s):")
        for f in findings:
            print(f"    ACD-NET-001: {f}")
    else:
        print("  no network API outside the whitelist")

    print()
    print("=" * 78)
    if findings:
        print(f"NETWORK-BOUNDARY: {len(findings)} finding(s)")
        print("=" * 78)
        return 2 if args.strict else 0
    print("NETWORK-BOUNDARY: clean")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
