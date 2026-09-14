"""Dump a GGUF's header + metadata, and (optionally) compare two files byte-for-byte.

Why this exists: the on-device advice model reported "not available" and llama.cpp only says
"llama_model_load_from_file failed". `llama_model_load_from_file` is a black box that returns
NULL for every reason -- unreadable file, bad magic, unknown `general.architecture`, missing
tokenizer metadata. Reading the header directly separates "the file is fine, the runtime is
wrong" from "the file itself cannot be loaded by this llama.cpp".

    python tool/gguf_inspect.py <file.gguf> [<other.gguf>]
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

TYPES = {0: "u8", 1: "i8", 2: "u16", 3: "i16", 4: "u32", 5: "i32", 6: "f32", 7: "bool",
         8: "str", 9: "arr", 10: "u64", 11: "i64", 12: "f64"}
FMT = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}

GGUF_MAGIC = b"GGUF"
#: GGUF v2/v3 are what llama.cpp b10937 accepts; v1 (and anything newer) is rejected outright.
SUPPORTED_VERSIONS = (2, 3)


class Reader:
    def __init__(self, fh):
        self.fh = fh

    def u32(self):
        return struct.unpack("<I", self.fh.read(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.fh.read(8))[0]

    def string(self):
        n = self.u64()
        if n > 1 << 24:
            raise ValueError(f"string length {n} is implausible -- header is not GGUF")
        return self.fh.read(n).decode("utf-8", "replace")

    def value(self, t, depth=0):
        if t == 8:
            return self.string()
        if t == 9:
            et = self.u32()
            n = self.u64()
            # AGGREGATE arrays (the 150k-entry tokenizer vocabularies) are NOT skipped: they
            # must still be CONSUMED, or every following key/value pair is read from the wrong
            # offset. The first version of this parser returned a placeholder without advancing
            # the stream and then declared the file "not GGUF" -- a parser bug that looks exactly
            # like a corrupt model. `skip_array` advances without materialising the values.
            if n > 4096 or depth > 2:
                return self.skip_array(et, n, depth)
            values = [self.value(et, depth + 1) for _ in range(n)]
            if et in (8, 9):
                return values if n <= 24 else f"<array of {n} {TYPES.get(et, et)}>"
            return values
        if t in FMT:
            return struct.unpack("<" + FMT[t], self.fh.read(struct.calcsize(FMT[t])))[0]
        raise ValueError(f"unknown GGUF value type {t}")

    def skip_array(self, et, n, depth, scan_strings=24):
        """Advance exactly `n` elements of type `et` without decoding them.

        Only the first `scan_strings` strings are read (they carry the interesting facts, e.g.
        `tokenizer.ggml.model`); the rest are seeked over, so a 150k-token vocabulary costs
        nothing.
        """
        if et in FMT:
            self.fh.seek(n * struct.calcsize(FMT[et]), 1)
            return f"<array of {n} {TYPES.get(et, et)} (skipped)>"
        if et == 8:
            head = []
            for i in range(n):
                length = self.u64()
                if i < scan_strings:
                    head.append(self.fh.read(length).decode("utf-8", "replace"))
                else:
                    self.fh.seek(length, 1)
            return f"<array of {n} str; first {len(head)}: {head[:6]}{' ...' if len(head) > 6 else ''}>"
        if et == 9:
            for _ in range(n):
                inner_et = self.u32()
                inner_n = self.u64()
                self.skip_array(inner_et, inner_n, depth + 1, scan_strings)
            return f"<array of {n} array (skipped)>"
        raise ValueError(f"cannot skip GGUF array of type {et}")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def inspect(path: Path) -> dict:
    print("=" * 78)
    print(f"{path}  ({path.stat().st_size:,} bytes)")
    print("=" * 78)
    with path.open("rb") as fh:
        r = Reader(fh)
        magic = fh.read(4)
        print(f"  magic        : {magic!r}")
        if magic != GGUF_MAGIC:
            print("  !! not a GGUF file -- llama.cpp rejects this before anything else")
            return {"ok": False}
        version = r.u32()
        n_tensors = r.u64()
        n_kv = r.u64()
        print(f"  version      : {version}")
        print(f"  tensor count : {n_tensors:,}")
        print(f"  metadata k/v : {n_kv:,}")
        if version not in SUPPORTED_VERSIONS:
            print(f"  !! version {version} is outside {SUPPORTED_VERSIONS}; b10937 will refuse it")

        meta = {}
        for _ in range(n_kv):
            key = r.string()
            t = r.u32()
            meta[key] = r.value(t)

    for key in sorted(meta):
        rendered = str(meta[key])
        if len(rendered) > 110:
            rendered = rendered[:110] + "..."
        print(f"    {key:<44} {rendered}")

    arch = meta.get("general.architecture")
    print()
    print(f"  general.architecture : {arch!r}")
    print(f"  general.name         : {meta.get('general.name')!r}")
    print(f"  tokenizer.ggml.model : {meta.get('tokenizer.ggml.model')!r}")
    print(f"  tokenizer.ggml.tokens: {meta.get('tokenizer.ggml.tokens')}")
    blocking = []
    if arch is None:
        blocking.append("no general.architecture -- llama.cpp cannot pick an architecture")
    tokens = meta.get("tokenizer.ggml.tokens")
    if not tokens:
        blocking.append("no tokenizer.ggml.tokens -- vocabulary is absent")
    return {"ok": not blocking, "arch": arch, "version": version, "blocking": blocking,
            "sha256": sha256(path) if path.stat().st_size > (1 << 20) else None}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    paths = [Path(p) for p in argv[1:]]
    results = [inspect(p) for p in paths]

    if len(paths) == 2:
        print()
        print("=" * 78)
        a, b = paths
        same_size = a.stat().st_size == b.stat().st_size
        print(f"  sizes equal  : {same_size} ({a.stat().st_size:,} vs {b.stat().st_size:,})")
        if same_size:
            print(f"  sha256 equal : {sha256(a) == sha256(b)}")

    print()
    bad = [p for p, r in zip(paths, results) if not r.get("ok")]
    for p, r in zip(paths, results):
        for reason in r.get("blocking", []):
            print(f"  [BLOCKER] {p.name}: {reason}")
    if bad:
        print("RESULT: NOT LOADABLE AS-IS")
        return 1
    print("RESULT: header and required metadata are present (this alone does not prove a load)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
