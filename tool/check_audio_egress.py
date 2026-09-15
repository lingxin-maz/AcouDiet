"""No audio-shaped value may appear in the cloud egress layer.

    python tool/check_audio_egress.py            # report
    python tool/check_audio_egress.py --strict   # exit 2 on any finding
    python tool/check_audio_egress.py --selftest # prove the detector can fail

WHY THIS EXISTS (`ADR-44`, `FF-24` item 8)
------------------------------------------
`FF-24` item 4 -- "the APK requests no INTERNET permission" -- used to be the project's
strongest privacy claim, and it was provable with one `aapt dump badging`. `ADR-44` adds a
flavour that DOES request it, so the strongest surviving claim became item 8:

    PCM, Mel tensors and audio files never leave the device. No flavour, no version.

That claim is weaker to prove and harder to keep, because it is a claim about DATA rather than
about a permission. There is no one command that settles it. So it is defended three ways, and
this script is the honesty about which layer each defence covers:

  1. **Type design** (`agent_transport.dart` / `agent_prompt.dart`): the message type has no
     binary member, and the one builder asserts every value it is handed. This is the strongest
     of the three and the only one a reviewer can confirm by reading.
  2. **Runtime assertion** (`app/tool/agent_tests.dart`): `assertEgressSafe` refuses typed
     buffers and any numeric array of length >= 1024, so the project's smallest audio-shaped
     object (the 819-point RMS envelope, `FF-21h`) cannot pass. Negative control included.
  3. **This static scan**: a tripwire over `app/lib/data/net/**` for audio-shaped identifiers.

Layer 3 is the WEAKEST and is written down as such on purpose. It catches a careless edit
(`Float32List` appearing next to a request), not a determined one -- anything can be laundered
through `List<int>`. Pretending otherwise would be the exact failure mode this project keeps
rediscovering: a gate whose docstring promises more than its code checks.

Note the deliberate exception: `Uint8List` is ALLOWED in this directory. It is the byte-stream
type of an HTTP body, and `SseDecoder` needs it. Forbidding it would make the rule
unsatisfiable and the checker would end up with a whitelist comment -- which is how gates die.

Exit codes: 0 = clean, 2 = findings, 1 = the selftest failed.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # repository root

#: The directory whose contents may reach the network. Relative to the repository root.
EGRESS_DIR = "app/lib/data/net"

#: Identifiers that are audio-shaped by construction. `Uint8List` is deliberately absent.
AUDIO_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("Float32List (the Mel tensor / envelope dtype)", re.compile(r"\bFloat32List\b")),
    ("Int16List", re.compile(r"\bInt16List\b")),
    ("Int32List", re.compile(r"\bInt32List\b")),
    ("mel", re.compile(r"\bmel\b", re.IGNORECASE)),
    ("pcm", re.compile(r"\bpcm\b", re.IGNORECASE)),
    ("waveform", re.compile(r"\bwaveform\b", re.IGNORECASE)),
    ("rmsEnvelope", re.compile(r"\brmsEnvelope\b")),
    ("audioPath", re.compile(r"\baudioPath\b")),
)

SOURCE_SUFFIXES = (".dart",)


def _strip_comments(text: str) -> str:
    """Remove comments so documentation cannot trip the scan.

    Concrete reason: `agent_transport.dart` says in a comment that it contains no `Uint8List`
    member and describes the forbidden list. A scanner that reads prose as code fires on the
    very sentence explaining the rule, and then someone adds an exception, and then the rule is
    gone.
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)
    text = re.sub(r"//.*$", "", text, flags=re.M)
    return text


def scan(root: Path) -> list[str]:
    """Returns findings for the egress directory under [root]. Empty means clean."""
    egress = root / EGRESS_DIR
    if not egress.exists():
        raise SystemExit(f"ACD-EGR-000: {EGRESS_DIR} does not exist under {root}")

    findings: list[str] = []
    for path in sorted(egress.rglob("*")):
        if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
            continue
        rel = path.relative_to(root)
        try:
            text = _strip_comments(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        for label, pattern in AUDIO_PATTERNS:
            for m in pattern.finditer(text):
                line = text[: m.start()].count("\n") + 1
                findings.append(
                    f"{rel}:{line}: audio-shaped identifier '{label}' inside the egress layer "
                    f"(FF-24 item 8: audio never leaves the device)"
                )

    # The runtime assertion lives in the app's own suite; its PRESENCE is asserted here,
    # because a defence whose test was deleted looks identical to a defence that holds.
    suite = root / "app" / "tool" / "agent_tests.dart"
    if not suite.exists():
        findings.append(
            "app/tool/agent_tests.dart is missing -- the runtime egress assertion "
            "(assertEgressSafe + the >=1024 numeric-array rule) has no test"
        )
    else:
        body = suite.read_text(encoding="utf-8", errors="replace")
        for needle, why in (
            ("a 4096-element numeric array is refused", "the FF-26e length rule"),
            ("the cap sits below the 819-point envelope", "the cap-vs-envelope justification"),
        ):
            if needle not in body:
                findings.append(
                    f"app/tool/agent_tests.dart no longer asserts {why} "
                    f"(missing: {needle!r})"
                )
    return findings


# --------------------------------------------------------------------------- the selftest

SELFTEST_CASES: tuple[tuple[str, str, str, bool], ...] = (
    (
        "a Float32List beside a request must be caught",
        "betrayer.dart",
        "import 'dart:typed_data';\nvoid send(Float32List m) {}\n",
        True,
    ),
    (
        "a Mel-shaped parameter must be caught",
        "mel_sender.dart",
        "void send(double mel) {}\n",
        True,
    ),
    (
        "the byte-stream type must be ALLOWED (it is an HTTP body, not audio)",
        "body.dart",
        "import 'dart:typed_data';\nvoid send(Uint8List body) {}\n",
        False,
    ),
    (
        "a comment naming Float32List must NOT be caught (prose is not code)",
        "doc.dart",
        "// the request body never carries a Float32List or a mel tensor\nvoid send() {}\n",
        False,
    ),
    (
        "the word 'model' must not be mistaken for 'mel'",
        "naming.dart",
        "const model = 'm';\n",
        False,
    ),
)


def selftest() -> int:
    print("=" * 78)
    print("audio egress detector -- selftest")
    print("=" * 78)

    failures = 0
    for name, filename, body, must_be_caught in SELFTEST_CASES:
        tmp = Path(tempfile.mkdtemp(prefix="acd_egr_"))
        try:
            (tmp / EGRESS_DIR).mkdir(parents=True, exist_ok=True)
            (tmp / EGRESS_DIR / filename).write_text(body, encoding="utf-8")
            # The app suite does not exist in the fixture, so its absence is itself a finding.
            # Filter to the file-level findings so each case tests exactly one thing.
            got = bool([f for f in scan(tmp) if filename in f])
            ok = got == must_be_caught
            mark = "[ok]  " if ok else "[FAIL]"
            print(f"  {mark} {name}  (expected "
                  f"{'caught' if must_be_caught else 'clean'}, got "
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
    print(f"RESULT: the detector discriminates all {len(SELFTEST_CASES)} cases")
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
    print("Audio egress (ADR-44 / FF-24 item 8) -- weakest of three layers, see docstring")
    print("=" * 78)
    findings = scan(ROOT)
    if findings:
        for f in findings:
            print(f"  ACD-EGR-001: {f}")
    else:
        print("  no audio-shaped identifier in the egress layer")

    print()
    print("=" * 78)
    if findings:
        print(f"AUDIO-EGRESS: {len(findings)} finding(s)")
        print("=" * 78)
        return 2 if args.strict else 0
    print("AUDIO-EGRESS: clean")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
