"""获取 CMake 与 Ninja 的可执行文件（走 Python 的 TLS，绕开坏掉的 Windows Schannel）。

为什么不用安装器/包管理器：本机系统级 HTTPS 是坏的
（`schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`），
PowerShell / curl / git 都下不动；而 Python 的 OpenSSL 正常。

为什么需要它们：Android NDK 只带 **编译器/链接器**（clang、ld、sysroot、CMake toolchain 文件），
**不带 CMake 本身**，也不带 Ninja。而 llama.cpp 的构建是 CMake 工程。

装到 `_toolchain/tools/` 下，自包含、不改 PATH。
"""

from __future__ import annotations

import io
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "_toolchain" / "tools"
UA = {"User-Agent": "acoudiet-fetch"}

#: Kitware 的免安装 zip（Windows x64）。
CMAKE_URL = ("https://github.com/Kitware/CMake/releases/download/v3.30.5/"
             "cmake-3.30.5-windows-x86_64.zip")
#: Ninja 的官方 release（单文件 exe，解开即用）。
NINJA_URL = ("https://github.com/ninja-build/ninja/releases/download/v1.12.1/"
             "ninja-win.zip")


def fetch(url: str, dest: Path) -> int:
    if dest.exists() and dest.stat().st_size > 0:
        print("  已存在:", dest.name)
        return dest.stat().st_size
    part = dest.with_suffix(dest.suffix + ".part")
    start = part.stat().st_size if part.exists() else 0
    headers = dict(UA)
    if start:
        headers["Range"] = "bytes=%d-" % start
    req = urllib.request.Request(url, headers=headers)
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=60) as r:
        total = int(r.headers.get("Content-Length") or 0) + start
        mode = "ab" if start and r.status == 206 else "wb"
        if mode == "wb":
            start = 0
        got = start
        with open(part, mode) as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)
                el = time.time() - t0
                if el > 3 and got % (8 << 20) < (1 << 20):
                    print("    %.0f/%.0f MB  %.1f MB/s"
                          % (got / 1048576.0, total / 1048576.0,
                             (got - start) / max(el, .001) / 1048576.0))
    part.replace(dest)
    return dest.stat().st_size


def main() -> int:
    TOOLS.mkdir(parents=True, exist_ok=True)

    print("[1/2] CMake")
    cmake_zip = TOOLS / "cmake-win64.zip"
    fetch(CMAKE_URL, cmake_zip)
    cmake_dir = TOOLS / "cmake"
    if not (cmake_dir / "bin" / "cmake.exe").exists():
        print("  解压 ...")
        cmake_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(cmake_zip) as z:
            z.extractall(cmake_dir)
    cmake_exe = next(iter(cmake_dir.rglob("cmake.exe")), None)
    print("  cmake:", cmake_exe)

    print("[2/2] Ninja")
    ninja_zip = TOOLS / "ninja-win.zip"
    fetch(NINJA_URL, ninja_zip)
    ninja_dir = TOOLS / "ninja"
    ninja_dir.mkdir(parents=True, exist_ok=True)
    if not (ninja_dir / "ninja.exe").exists():
        with zipfile.ZipFile(ninja_zip) as z:
            z.extractall(ninja_dir)
    ninja_exe = ninja_dir / "ninja.exe"
    print("  ninja:", ninja_exe if ninja_exe.exists() else "FAIL")

    # 清掉 zip 省空间（NDK 那个已经很大了）
    for z in (cmake_zip, ninja_zip):
        if z.exists():
            z.unlink()

    ok = cmake_exe is not None and ninja_exe.exists()
    print("")
    print("OK" if ok else "FAIL")
    if ok:
        print("cmake=%s" % cmake_exe)
        print("ninja=%s" % ninja_exe)
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
