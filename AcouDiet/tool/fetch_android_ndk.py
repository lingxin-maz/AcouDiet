"""下载并解压 Android NDK（本机用 Python 的 TLS，绕开坏掉的 Windows Schannel）。

为什么自己下而不是用 sdkmanager：
    * `sdkmanager` 需要 Java + 走网络，而本机系统级 HTTPS 是坏的（Schannel
      `SEC_E_NO_CREDENTIALS`），只有 Python 的 OpenSSL 能用；
    * NDK 的官方 zip 是自包含的（含 clang、ld、sysroot、CMake toolchain 文件），
      直接解压即可用，不需要写 `source.properties` 之外的任何配置。

用法：
    python tool/fetch_android_ndk.py                # 默认 r27
    python tool/fetch_android_ndk.py --version 27.2.12479018
    python tool/fetch_android_ndk.py --list         # 只列出可用版本
"""

from __future__ import annotations

import argparse
import re
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST_ROOT = ROOT / "_toolchain" / "android-sdk" / "ndk"
REPO = "https://dl.google.com/android/repository/repository2-3.xml"

#: `<url>` 里给的是**仓库目录下的文件名**，例如 `android-ndk-r27c-windows.zip`，
#: 前两部分固定是 `https://dl.google.com/android/repository/`。第一版直接把 `<url>`
#: 当成完整 URL，于是报 `unknown url type: 'android-ndk-r27c-windows.zip'`。
BASE_URL = "https://dl.google.com/android/repository/"

UA = {"User-Agent": "acoudiet-fetch"}

#: 默认版本。选它而不是最新的 r30：llama.cpp 对 NDK 版本不敏感，而 r27 更成熟、
#: 且体积略小。真正的判据是"能不能编出 .so"，不是"版本新不新"。
DEFAULT = "27.2.12479018"


def list_versions() -> list:
    xml = urllib.request.urlopen(urllib.request.Request(REPO, headers=UA), timeout=60)
    body = xml.read().decode("utf-8", "replace")
    pkgs = re.findall(r'<remotePackage[^>]*path="([^"]+)"[^>]*>(.*?)</remotePackage>',
                      body, re.S)
    out = []
    for path, seg in pkgs:
        if not path.startswith("ndk;"):
            continue
        rev = re.search(r'<revision>\s*<major>(\d+)</major>\s*<minor>(\d+)</minor>'
                        r'\s*<micro>(\d+)</micro>', seg)
        if not rev:
            continue
        ver = ".".join(rev.groups())
        for arch in re.findall(r'<archive>(.*?)</archive>', seg, re.S):
            if "windows" not in arch:
                continue
            u = re.search(r'<url>([^<]+)</url>', arch)
            s = re.search(r'<size>(\d+)</size>', arch)
            if u:
                name = u.group(1)
                full = name if name.startswith("http") else BASE_URL + name
                out.append((ver, full, int(s.group(1)) if s else 0))
    # 稳定版优先（剔除 beta/rc），版本倒序
    stable = [r for r in out if "beta" not in r[1] and "rc" not in r[1]]
    stable.sort(key=lambda r: tuple(int(x) for x in r[0].split(".")), reverse=True)
    return stable


def download(url: str, dest: Path) -> int:
    part = dest.with_suffix(dest.suffix + ".part")
    start = part.stat().st_size if part.exists() else 0
    headers = dict(UA)
    if start:
        headers["Range"] = "bytes=%d-" % start
        print("  续传，已有 %.0f MB" % (start / 1048576.0))

    req = urllib.request.Request(url, headers=headers)
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=60) as r:
        total = int(r.headers.get("Content-Length") or 0) + start
        mode = "ab" if start and r.status == 206 else "wb"
        if mode == "wb":
            start = 0
        got = start
        last = 0.0
        with open(part, mode) as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)
                now = time.time()
                if now - last >= 5:
                    last = now
                    print("  %6.0f/%6.0f MB (%4.1f%%)  %.1f MB/s"
                          % (got / 1048576.0, total / 1048576.0,
                             got * 100.0 / total if total else 0,
                             (got - start) / max(now - t0, .001) / 1048576.0))
    part.replace(dest)
    return got


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=DEFAULT)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--keep-zip", action="store_true")
    args = ap.parse_args()

    if args.list:
        print("可用的 Windows NDK：")
        for ver, u, s in list_versions()[:12]:
            print("  r%-16s %-46s %.0f MB" % (ver, u, s / 1048576.0))
        return 0

    print("查询 NDK 列表 ...")
    rows = list_versions()
    hit = next((r for r in rows if r[0] == args.version), None)
    if not hit:
        print("FAIL: 找不到版本 %s。用 --list 查看可用版本。" % args.version)
        return 2
    ver, url, size = hit

    target = DEST_ROOT / ("android-ndk-r%s" % ver.split(".")[0])
    if (target / "build" / "cmake" / "android.toolchain.cmake").is_file():
        print("已安装，跳过:", target)
        return 0

    dest_root_parent = DEST_ROOT
    dest_root_parent.mkdir(parents=True, exist_ok=True)
    zip_path = dest_root_parent / ("android-ndk-%s-windows.zip" % ver)

    print("NDK r%s  (%s, %.0f MB)" % (ver, url, size / 1048576.0))
    if not zip_path.exists():
        print("下载中 ...")
        n = download(url, zip_path)
        print("下载完成 %.0f MB" % (n / 1048576.0))
    else:
        print("已下载:", zip_path)

    print("解压到", target.parent)
    with zipfile.ZipFile(zip_path) as z:
        members = z.namelist()
        # 顶层目录名形如 `android-ndk-r27c/`。
        #
        # ⚠️ 它与 `<url>` 里的文件名**可能不同**：Kitware/Google 的 CDN 标签常常是
        # `android-ndk-r27c-windows.zip`，而 XML 里 revision 写的是 `27.2.12479018`。
        # 第一版按 revision 的 major 拼出 `android-ndk-r27` 再重命名，结果
        # `PermissionError: [WinError 5]` —— 而且**根本不需要重命名**，解出来的目录就是对的。
        top = members[0].split("/")[0]
        z.extractall(target.parent)
    extracted = target.parent / top
    print("实际目录:", extracted)

    ok = (target / "build" / "cmake" / "android.toolchain.cmake").is_file()
    print("toolchain file:", target / "build" / "cmake" / "android.toolchain.cmake")
    print("OK" if ok else "FAIL: 解压后没找到 android.toolchain.cmake")

    if not args.keep_zip and zip_path.exists():
        zip_path.unlink()
        print("已删除 zip 以省空间")
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main())
