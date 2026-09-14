# AcouDiet/tool/ui_fingerprint_check.py
#
# "Which UI is in this APK?" -- a one-command answer, because on 2026-09-13 the answer was
# **not** what the file name said.
#
# Why this tool exists
# --------------------
# `_toolchain/tmp/app-release-4abi.apk` was built on 2026-09-12 for the x86_64 emulator and left
# behind. It is a *release* build signed with the same test key, so it installs on any phone with
# no error -- and it contains the **pre-ADR-24** UI. Anyone who installs it sees the old screens
# and concludes "the UI never changed".
#
# Worse, the same trap exists INSIDE a check: reading Dart strings out of `libapp.so` with a UTF-8
# search returns "not found" for every Chinese literal, because the AOT snapshot stores them as
# **UTF-16**. A probe without a positive control would have "confirmed" that even the current build
# lacks the new UI. So:
#
#   * every needle is written as an ASCII `\uXXXX` escape (no shell/console codepage can mangle it);
#   * both UTF-8 and UTF-16LE are searched;
#   * a **positive control** (a string present in every version) must hit, or the verdict is
#     "method broken" rather than "UI missing";
#   * a **negative control** (a string the ADR-23 rename removed) must NOT hit.
#
# Usage
# -----
#   python tool/ui_fingerprint_check.py <file.apk>
#   python tool/ui_fingerprint_check.py            # defaults to dist/AcouDiet-1.0.0-arm64-release.apk
#
# Exit code 0 = this APK carries the ADR-24 UI; 1 = it does not (or the method failed).

from __future__ import annotations

import pathlib
import sys
import zipfile

_TOOL_DIR = pathlib.Path(__file__).resolve().parent
_DIST = _TOOL_DIR.parent / "dist"


def _default_apk() -> pathlib.Path | None:
    """The newest release APK in `dist/`, or None.

    This used to be the hardcoded `dist/AcouDiet-1.0.0-arm64-release.apk`. When ADR-32 added a
    newer package under an explicit name, the default silently became an artifact that is two
    UI revisions and one model revision old -- and the tool then reported `DO NOT INSTALL` for
    the file it had picked on its own. Picking the newest release package cannot go stale; the
    chosen path is printed, so the selection is visible rather than assumed.
    """
    candidates = [p for p in _DIST.glob("*release*.apk") if p.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)

# Present in EVERY version: if this misses, the search method is wrong and nothing else counts.
_CONTROL_PRESENT = {
    "control: records page title": "\u996e\u98df\u8bb0\u5f55",  # 饮食记录
}

# Only exist after ADR-24 (the UI rebuild) / ADR-23 (the copy rename).
_MUST_BE_PRESENT = {
    "meal chip: breakfast": "\u65e9\u9910",  # 早餐
    "records stat label": "\u4eca\u65e5\u70ed\u91cf",  # 今日热量
    "filtered empty copy": "\u8fd9\u4e00\u9910\u6bb5\u8fd8\u6ca1\u6709\u8bb0\u5f55",  # 这一餐段还没有记录
    "profile overview title": "\u672c\u5468\u5065\u5eb7\u6570\u636e\u6982\u89c8",  # 本周健康数据概览
    "profile overview speed": "\u5e73\u5747\u5480\u56bc\u901f\u5ea6",  # 平均咀嚼速度
    "profile overview no sample": "\u65e0\u6837\u672c",  # 无样本
    "report recent records": "\u6700\u8fd1\u8bc6\u522b\u8bb0\u5f55",  # 最近识别记录
    "score card title (ADR-23 rename)": "\u8fd1 7 \u5929\u5065\u5eb7\u8bc4\u5206",  # 近 7 天健康评分
    "trend score note (ADR-25)": "\u8bc4\u5206\u53e3\u5f84",  # 评分口径
}

# Changes that make a build NOT the current UI: a rename, a deliberate removal.
#
# ⚠️ Two needles here were live bugs in their own right, which is why this list is worth reading:
#
#  * ADR-30 deliberately deleted the report page's `近 7 天评分（截至该日）` title (it repeated the
#    date the ScoreCard title already shows). The checker was not updated with it, so from ADR-30
#    onwards EVERY correct build was reported as `PRE-ADR-24 UI -- DO NOT INSTALL THIS FILE`.
#    A probe that condemns the right artifact is worse than no probe.
#  * ADR-34 removed the on-device language model and with it the home page `AI 周综述` card. That
#    needle was added to _MUST_BE_PRESENT by ADR-33 and is now evidence of the OPPOSITE state, so
#    it moved here -- which is also where it discriminates: measured, it hits in the two LLM-era
#    packages and misses in the post-ADR-34 one.
_MUST_BE_ABSENT = {
    "old score card title (ADR-23 renamed it)": "\u4eca\u65e5\u5065\u5eb7\u8bc4\u5206",  # 今日健康评分
    "daily score window title (ADR-30 removed it)":
        "\u8fd1 7 \u5929\u8bc4\u5206\uff08\u622a\u81f3\u8be5\u65e5\uff09",  # 近 7 天评分（截至该日）
    "AI weekly review card (ADR-28 added, ADR-34 removed)":
        "AI \u5468\u7efc\u8ff0",  # AI 周综述
}


def _found(blob: bytes, needle: str) -> tuple[bool, bool]:
    return needle.encode("utf-8") in blob, needle.encode("utf-16-le") in blob


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        apk = pathlib.Path(argv[1])
    else:
        apk = _default_apk()
        if apk is None:
            print(f"no *release*.apk found under {_DIST}; pass an APK path explicitly")
            return 1
        print(f"(no path given: checking the newest release package in dist/ -- {apk.name})")
    if not apk.exists():
        print(f"APK not found: {apk}")
        return 1

    print("=" * 78)
    print(f"UI fingerprint check: {apk.name}")
    print("=" * 78)

    with zipfile.ZipFile(apk) as z:
        libs = [n for n in z.namelist() if n.endswith("libapp.so")]
        if not libs:
            print("  !! no libapp.so: this is not a Flutter AOT package")
            return 1

        verdict = 0
        for name in libs:
            blob = z.read(name)
            print(f"\n--- {name} ({len(blob):,} bytes) ---")

            control_ok = True
            for label, needle in _CONTROL_PRESENT.items():
                utf8, utf16 = _found(blob, needle)
                hit = utf8 or utf16
                control_ok &= hit
                print(f"  [{'ok  ' if hit else 'FAIL'}] {label}")

            if not control_ok:
                print("  !! the positive control did NOT match -> the search method is broken;")
                print("     this run proves NOTHING about the UI. Fix the probe before trusting it.")
                return 1

            missing = []
            for label, needle in _MUST_BE_PRESENT.items():
                utf8, utf16 = _found(blob, needle)
                hit = utf8 or utf16
                if not hit:
                    missing.append(label)
                print(f"  [{'ok  ' if hit else 'MISS'}] {label}")

            present_old = []
            for label, needle in _MUST_BE_ABSENT.items():
                utf8, utf16 = _found(blob, needle)
                hit = utf8 or utf16
                if hit:
                    present_old.append(label)
                print(f"  [{'BAD ' if hit else 'ok  '}] {label} (must be absent)")

            if missing or present_old:
                # The wording here used to be "PRE-ADR-24", which stopped being TRUE the moment a
                # later ADR removed a string (ADR-30) or added one (ADR-28): a build can now be
                # rejected for carrying something NEWER than ADR-24. Name the failure by what was
                # measured, not by which release the probe author had in mind.
                print(f"  -> verdict for this ABI: NOT CURRENT (missing {len(missing)}, "
                      f"present-but-removed {len(present_old)})")
                verdict = 1
            else:
                print("  -> verdict for this ABI: current UI present")

    print()
    print("=" * 78)
    print("RESULT:", "CURRENT UI" if verdict == 0
          else "NOT THE CURRENT UI -- DO NOT INSTALL THIS FILE")
    print("=" * 78)
    print("Dart strings live in libapp.so as UTF-16, so a plain UTF-8 `grep` of an APK finds")
    print("nothing and would look like 'the new UI is missing from the current build too'.")
    return verdict


if __name__ == "__main__":
    sys.exit(main(sys.argv))
