"""Every Android XML file must actually be XML.

    python tool/check_android_xml.py --strict

WHY THIS EXISTS
---------------
Two manifests in this repository were **not well-formed XML** and nobody noticed, because
nothing in the offline toolchain ever parsed them:

  * `app/src/main/AndroidManifest.xml` wrote `the privacy claim -- not an oversight`. XML
    forbids `--` *inside a comment*, so the file was unparseable;
  * `app/src/debug/AndroidManifest.xml` wrote `` `flutter build apk --profile` `` in a comment
    -- the same defect.

Both were found only when a real `flutter build apk --debug` reached
`:app:processDebugMainManifest` and died with
`ManifestMerger2$MergeFailureException: Error parsing ...AndroidManifest.xml`.

The failure mode is nasty out of proportion to the typo: the manifest is the one file that must
be valid for the app to install *at all*, and a build that cannot even parse it means the app
cannot start on any device. This check turns it into a one-second offline gate.

WHAT IT CHECKS (per file)
-------------------------
1. it parses as XML (`xml.etree.ElementTree`);
2. no comment body contains `--` (caught separately so the message is actionable rather than a
   bare "invalid token at line/column");
3. `<manifest>` is the root element.

Exit codes: 0 = all well-formed, 2 = at least one file failed.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # repository root
ANDROID = ROOT / "app" / "android"

COMMENT = re.compile(r"<!--(.*?)-->", re.S)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true", help="exit non-zero on any failure")
    args = ap.parse_args()

    files = sorted(ANDROID.rglob("*.xml")) if ANDROID.exists() else []
    if not files:
        print(f"ACD-ART-001: no Android XML files under {ANDROID}", file=sys.stderr)
        return 2

    print("=" * 78)
    print("Android XML well-formedness")
    print("=" * 78)

    failures: list[str] = []
    for path in files:
        rel = path.relative_to(ROOT)
        problems: list[str] = []
        text = path.read_text(encoding="utf-8", errors="replace")

        # 2 first: a `--` in a comment is the failure we actually hit, and the parser's own
        # message ("invalid token at line N") does not say what is wrong.
        for index, body in enumerate(COMMENT.findall(text), start=1):
            if "--" in body:
                line = text[:text.find(body)].count("\n") + 1
                problems.append(
                    f"comment #{index} (around line {line}) contains '--', which XML forbids "
                    f"inside a comment; use an em dash instead")

        try:
            root = ET.parse(path).getroot()
            # Only a manifest file must be rooted at <manifest>; `res/**` legitimately uses
            # <resources> / <layer-list> / <data-extraction-rules>, so asserting the root
            # globally was a bug in the first version of this very check.
            if path.name == "AndroidManifest.xml" and root.tag != "manifest":
                problems.append(f"root element is <{root.tag}>, expected <manifest>")
        except ET.ParseError as exc:
            problems.append(f"not well-formed XML: {exc}")

        if problems:
            print(f"  [FAIL] {rel}")
            for problem in problems:
                print(f"         - {problem}")
            failures.append(str(rel))
        else:
            print(f"  [ok]   {rel}")

    print()
    print("=" * 78)
    if failures:
        print(f"ANDROID-XML: {len(failures)} of {len(files)} file(s) FAILED")
        print("=" * 78)
        return 2 if args.strict else 0
    print(f"ANDROID-XML: all {len(files)} file(s) well-formed")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
