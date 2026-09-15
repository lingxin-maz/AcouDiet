"""A PowerShell script that contains non-ASCII bytes MUST carry a UTF-8 BOM.

    python tool/check_ps1_encoding.py            # report
    python tool/check_ps1_encoding.py --strict   # exit 2 on any finding
    python tool/check_ps1_encoding.py --selftest # prove the detector can fail

WHY THIS EXISTS -- IT ALREADY BIT US, TWICE, INCLUDING ON THE DAY IT WAS WRITTEN
-------------------------------------------------------------------------------
Windows PowerShell 5.1 decodes a BOM-less `.ps1` with the machine ANSI code page -- 936/GBK on
this machine. Chinese comments and Chinese string literals are stored as UTF-8 bytes, so they
get mis-decoded into garbage, and the file becomes a **parse error**: it dies before executing a
single line.

`tool/build_release.ps1` has a header warning about exactly this and even records the measurement
("7 parse errors without the BOM, 0 with it"). It still happened again during the ADR-44 work,
because an ordinary file-editing tool **strips the BOM on every write** and nothing looks at the
bytes. The symptom is maximally confusing: the file is valid UTF-8, every editor shows the right
characters, `git diff` shows only your intended change -- and PowerShell 5.1 refuses to run it.

The two other mitigations in this repository are both prose:
  * `verify_all.ps1`'s header says "KEEP THIS FILE PURE ASCII";
  * `build_release.ps1` says "THIS FILE MUST KEEP ITS UTF-8 BOM".
Neither is enforced, so both rely on somebody remembering. This is the mechanical version.

THE RULE
--------
  * non-ASCII bytes + NO BOM  -> FAIL (the GBK decode will corrupt it)
  * non-ASCII bytes + BOM     -> OK   (UTF-8 is declared, PS 5.1 honours it)
  * ASCII only, no BOM        -> OK   (nothing to mis-decode; this is the preferred state)

Exit codes: 0 = all files safe, 2 = findings, 1 = the selftest failed.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # repository root

BOM = b"\xef\xbb\xbf"

#: Directories to walk. `_toolchain` is excluded on purpose: it is a vendored toolchain that
#: lives OUTSIDE the deliverable tree and is not ours to police.
SCAN_DIRS: tuple[str, ...] = ("tool", "app/tool", "ai", "app/test", "app/lib")

#: Files that are allowed to be non-ASCII without a BOM, with the reason. Empty by default --
#: an entry here is a claim that the file is never executed by Windows PowerShell.
ALLOWLIST: dict[str, str] = {}


def scan(root: Path) -> list[str]:
    findings: list[str] = []
    seen: set[Path] = set()
    for rel_dir in SCAN_DIRS:
        base = root / rel_dir
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.ps1")):
            real = path.resolve()
            if real in seen:
                continue
            seen.add(real)
            rel = path.relative_to(root)
            data = path.read_bytes()
            has_bom = data.startswith(BOM)
            body = data[3:] if has_bom else data
            try:
                body.decode("ascii")
                non_ascii = False
            except UnicodeDecodeError:
                non_ascii = True
            if non_ascii and not has_bom and rel.as_posix() not in ALLOWLIST:
                findings.append(
                    f"{rel}: contains non-ASCII bytes with NO UTF-8 BOM. Windows PowerShell 5.1 "
                    f"will decode it as the ANSI code page (936 here), turning the Chinese "
                    f"comments into invalid syntax -- a parse error before line 1. Re-add the "
                    f"BOM: [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))"
                )
    return findings


# --------------------------------------------------------------------------- the selftest

#: (name, filename, raw bytes, must_be_caught)
SELFTEST_CASES: tuple[tuple[str, str, bytes, bool], ...] = (
    ("non-ASCII without a BOM must be caught", "bad.ps1",
     "# \u4e2d\u6587\u6ce8\u91ca\nWrite-Host 'x'\n".encode("utf-8"), True),
    ("the same bytes WITH a BOM must be accepted", "good.ps1",
     BOM + "# \u4e2d\u6587\u6ce8\u91ca\nWrite-Host 'x'\n".encode("utf-8"), False),
    ("pure ASCII without a BOM must be accepted", "ascii.ps1",
     b"# plain english\nWrite-Host 'x'\n", False),
    ("pure ASCII WITH a BOM must be accepted", "ascii_bom.ps1",
     BOM + b"# plain english\nWrite-Host 'x'\n", False),
    ("a non-ASCII .ps1 outside the scanned dirs is not our business", "other/bad.ps1",
     "# \u4e2d\u6587\n".encode("utf-8"), False),
)


def selftest() -> int:
    print("=" * 78)
    print("PowerShell encoding detector -- selftest")
    print("=" * 78)
    failures = 0
    for name, rel, body, must_be_caught in SELFTEST_CASES:
        tmp = Path(tempfile.mkdtemp(prefix="acd_ps1_"))
        try:
            # `other/` is deliberately outside SCAN_DIRS; `tool/` is inside.
            target = tmp / ("tool" if not rel.startswith("other/") else "other") / Path(rel).name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)
            got = bool(scan(tmp))
            ok = got == must_be_caught
            mark = "[ok]  " if ok else "[FAIL]"
            print(f"  {mark} {name}  (expected "
                  f"{'caught' if must_be_caught else 'clean'}, got {'caught' if got else 'clean'})")
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
    print("PowerShell script encoding (BOM required once non-ASCII is present)")
    print("=" * 78)
    findings = scan(ROOT)
    if findings:
        for f in findings:
            print(f"  ACD-PS1-001: {f}")
    else:
        print("  every non-ASCII .ps1 carries its UTF-8 BOM (or is pure ASCII)")

    print()
    print("=" * 78)
    if findings:
        print(f"PS1-ENCODING: {len(findings)} file(s) at risk")
        print("=" * 78)
        return 2 if args.strict else 0
    print("PS1-ENCODING: clean")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
