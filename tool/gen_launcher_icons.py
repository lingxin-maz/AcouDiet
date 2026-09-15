"""Generates the Android launcher icons for AcouDiet.

WHY A GENERATOR
---------------
`AndroidManifest.xml` references `@mipmap/ic_launcher`, so without these resources Android's
resource linking step fails and no APK can be built. A fresh `flutter create` would supply
placeholder icons; this checkout had no Flutter toolchain available to run it, and the icons
must therefore be produced deterministically from code.

The design is deliberately trivial -- a dark rounded square with three vertical "level" bars,
echoing the app's waveform indicator -- and it is written straight to PNG (IHDR/IDAT/IEND with
zlib) so no imaging library is required. Replace with real artwork before a public release;
this exists so the build links and the launcher entry is not blank.

Usage::

    python tool/gen_launcher_icons.py
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # repository root
RES = ROOT / "app" / "android" / "app" / "src" / "main" / "res"

#: density folder -> icon edge length in pixels (Android launcher icon sizes).
DENSITIES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

BACKGROUND = (0x11, 0x2A, 0x33)          # deep teal
BAR_COLOR = (0x6F, 0xD1, 0xC7)           # mint
BAR_TOP_COLOR = (0xFF, 0xD1, 0x66)       # amber


def _png(width: int, height: int, rgba: bytearray) -> bytes:
    """Wraps raw RGBA scanlines in a minimal PNG container."""
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)                     # filter type 0 (None)
        raw.extend(rgba[y * stride:(y + 1) * stride])

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload +
                struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def _icon(size: int) -> bytearray:
    """Draws a rounded square with three vertical bars (a stylised level meter)."""
    canvas = bytearray(size * size * 4)
    radius = size * 0.22
    for y in range(size):
        for x in range(size):
            i = (y * size + x) * 4
            # rounded-corner mask
            cx = min(max(x, radius), size - radius)
            cy = min(max(y, radius), size - radius)
            if (x - cx) ** 2 + (y - cy) ** 2 > radius ** 2:
                canvas[i + 3] = 0          # transparent outside the rounded square
                continue
            canvas[i], canvas[i + 1], canvas[i + 2] = BACKGROUND
            canvas[i + 3] = 255

    # three bars of increasing height, centred
    bar_w = max(2, size // 12)
    gap = max(1, size // 18)
    heights = (0.34, 0.55, 0.78)
    total_w = len(heights) * bar_w + (len(heights) - 1) * gap
    x0 = (size - total_w) // 2
    for n, frac in enumerate(heights):
        bx = x0 + n * (bar_w + gap)
        bar_h = int(size * frac)
        by = (size - bar_h) // 2
        color = BAR_TOP_COLOR if n == len(heights) - 1 else BAR_COLOR
        for y in range(by, by + bar_h):
            for x in range(bx, bx + bar_w):
                if 0 <= x < size and 0 <= y < size:
                    i = (y * size + x) * 4
                    if canvas[i + 3] == 0:
                        continue           # stay inside the rounded square
                    canvas[i], canvas[i + 1], canvas[i + 2] = color
                    canvas[i + 3] = 255
    return canvas


def main() -> int:
    written = []
    for folder, size in DENSITIES.items():
        target = RES / folder
        target.mkdir(parents=True, exist_ok=True)
        out = target / "ic_launcher.png"
        out.write_bytes(_png(size, size, _icon(size)))
        written.append(f"{folder}/ic_launcher.png ({size}x{size}, {out.stat().st_size} B)")
    for line in written:
        print(f"  {line}")
    print(f"\n{len(written)} launcher icons written under {RES}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
