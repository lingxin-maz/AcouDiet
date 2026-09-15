"""Fail the build if the APK cannot be loaded on a 16 KB-page Android device.

WHY THIS EXISTS (ADR-35)
------------------------
Android 15 introduced devices that use **16 KB memory pages**, and Play requires new/updated apps
to be compatible. A shared library whose ELF `PT_LOAD` segments are aligned to only 4096 bytes
**cannot be mapped** on such a device: `dlopen` fails, the model never loads, and the app's core
feature is broken -- on exactly the newest phones, with no build-time warning.

Measured on the artifact this replaced: every one of the four `libtensorflowlite_jni.so` ABIs in
the APK built against `org.tensorflow:tensorflow-lite:2.16.1` reported **`p_align = 4096`**, while
`libapp.so` / `libflutter.so` reported 65536. Nothing in the repo looked at that number, so the
only way to find out was to install it on a new device.

⚠️ **Do NOT try to establish this with `zipalign -c -p 16`.** In build-tools 34 that flag means
"check 16-**byte** alignment of every entry", not "16 KB pages": it reports `BAD` for ordinary
4/8/12-byte-aligned entries (META-INF, dexopt, the `.tflite` asset) on a perfectly good package,
and it has no option for the page size at all (`-P <pageSizeKb>` only arrived in build-tools 35).
Reading its exit code as a 16 KB verdict is how a correct APK gets declared broken. This script
reads the ELF headers directly, which is the property that actually decides loadability.

Two independent conditions are checked, because they fail for different reasons:

  1. **ELF**: every `PT_LOAD` segment of every `.so` inside the APK must have `p_align >= 16384`.
     This is a property of how the library was *linked*; it cannot be fixed by repackaging.
  2. **ZIP**: every **uncompressed** `.so` entry must start at a 16 KB-aligned offset. This is a
     property of how the APK was *packaged*, and it is fixable by repackaging.

    python tool/check_page_alignment.py                     # newest *release*.apk in release/dist/
    python tool/check_page_alignment.py path/to/app.apk

Exit codes: 0 = the APK is 16 KB compatible, 1 = it is not, 2 = the APK could not be read.
"""

from __future__ import annotations

import struct
import sys
import zipfile
from pathlib import Path

#: The page size Android 15+ devices may use. Not configurable: it is the platform's number.
REQUIRED_ALIGN = 16384

PT_LOAD = 1


def elf_load_alignments(blob: bytes) -> list[int] | None:
    """`p_align` of every PT_LOAD segment, or None when the blob is not an ELF."""
    if blob[:4] != b"\x7fELF":
        return None
    is64 = blob[4] == 2
    if is64:
        phoff = struct.unpack_from("<Q", blob, 0x20)[0]
        phentsize = struct.unpack_from("<H", blob, 0x36)[0]
        phnum = struct.unpack_from("<H", blob, 0x38)[0]
        align_off, fmt = 0x30, "<Q"
    else:
        phoff = struct.unpack_from("<I", blob, 0x1C)[0]
        phentsize = struct.unpack_from("<H", blob, 0x2A)[0]
        phnum = struct.unpack_from("<H", blob, 0x2C)[0]
        align_off, fmt = 0x1C, "<I"
    out = []
    for i in range(phnum):
        entry = phoff + i * phentsize
        if struct.unpack_from("<I", blob, entry)[0] == PT_LOAD:
            out.append(struct.unpack_from(fmt, blob, entry + align_off)[0])
    return out


def uncompressed_data_offset(zf: zipfile.ZipFile, info: zipfile.ZipInfo) -> int:
    """Byte offset of an entry's *data* in the file, for STORED (uncompressed) entries."""
    with zf.open(info, "r") as _:
        pass
    # Local file header: 30 fixed bytes + file name + extra field.
    zf.fp.seek(info.header_offset)
    raw = zf.fp.read(30)
    name_len = struct.unpack_from("<H", raw, 26)[0]
    extra_len = struct.unpack_from("<H", raw, 28)[0]
    return info.header_offset + 30 + name_len + extra_len


def default_apk() -> Path | None:
    root = Path(__file__).resolve().parents[1]
    # ADR-51: the release archive lives in `release/`; `dist/` is only the pre-ADR-50 location.
    dist = root / "release" / "dist" if (root / "release" / "dist").is_dir() else root / "dist"
    candidates = [p for p in dist.glob("*release*.apk") if p.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        apk = Path(argv[1])
    else:
        apk = default_apk()
        if apk is None:
            print("no *release*.apk under dist/; pass an APK path explicitly")
            return 2
        print(f"(no path given: checking the newest release package in dist/ -- {apk.name})")

    if not apk.is_file():
        print(f"APK not found: {apk}")
        return 2

    print("=" * 78)
    print("16 KB page compatibility")
    print("=" * 78)
    print(f"  apk      : {apk}")
    print(f"  required : p_align >= {REQUIRED_ALIGN} and STORED .so offsets % {REQUIRED_ALIGN} == 0")
    print()

    elf_problems: list[str] = []
    zip_problems: list[str] = []
    checked = 0

    with zipfile.ZipFile(apk) as zf:
        for info in zf.infolist():
            if not info.filename.endswith(".so"):
                continue
            checked += 1
            blob = zf.read(info.filename)

            alignments = elf_load_alignments(blob)
            if alignments is None:
                print(f"  [skip] {info.filename}: not an ELF")
                continue
            worst = min(alignments) if alignments else 0
            ok_elf = worst >= REQUIRED_ALIGN
            # STORED == 0; anything else is compressed and the loader handles it differently.
            if info.compress_type == zipfile.ZIP_STORED:
                offset = uncompressed_data_offset(zf, info)
                ok_zip = offset % REQUIRED_ALIGN == 0
                zip_note = f"offset={offset:,} ({'aligned' if ok_zip else 'NOT 16 KB aligned'})"
            else:
                ok_zip = True
                zip_note = "compressed (offset alignment does not apply)"
            print(f"  [{'ok  ' if ok_elf else 'FAIL'}] {info.filename}")
            print(f"          p_align={worst}   {zip_note}")
            if not ok_elf:
                elf_problems.append(f"{info.filename} (p_align={worst})")
            if not ok_zip:
                zip_problems.append(f"{info.filename} (data offset not 16 KB aligned)")

    print()
    if checked == 0:
        print("  !! no .so inside the APK -- nothing to check, which is itself suspicious")
        return 1

    if elf_problems:
        print("  [FAIL] these libraries cannot be mapped on a 16 KB-page device:")
        for p in elf_problems:
            print(f"         {p}")
        print("         fix: use an AAR/dependency whose .so was linked with")
        print("              -Wl,-z,max-page-size=16384 (LiteRT >= 1.4.x does;")
        print("              org.tensorflow:tensorflow-lite:2.16.1 does NOT)")
    if zip_problems:
        print("  [FAIL] these entries are not page-aligned in the zip:")
        for p in zip_problems:
            print(f"         {p}")
        print("         fix: repackage so STORED .so entries start at a 16 KB boundary")
        print("              (verify with build-tools 35+ `zipalign -c -P 16 4 <apk>`;")
        print("              build-tools 34 has no -P and its `-p 16` means something else)")

    print()
    print("=" * 78)
    if elf_problems or zip_problems:
        print("RESULT: NOT 16 KB COMPATIBLE")
        print("=" * 78)
        return 1
    print("RESULT: 16 KB COMPATIBLE")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
