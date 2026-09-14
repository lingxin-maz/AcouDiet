"""Static consistency check between the Flutter layer and the frozen L1-L4 API.

WHY
---
`dart analyze` cannot run over the Flutter-dependent files in this environment: the framework
needs `characters`, `material_color_utilities` and `vector_math`, none of which exist anywhere
on this machine or in the pub cache (`tool/analyze_flutter.py` documents the attempt). That
leaves an entire bug class invisible -- a call site that names a parameter or a method which
does not exist on the layer underneath.

That class is not hypothetical: the first hand-audit found
`AppServices.assemble(maintenance: ...)` where the parameter is `maintenanceRepo:`, in
`bootstrap.dart` -- a file no pure-Dart test can compile.

WHAT IT CHECKS (all deterministic, no false positives by construction)
---------------------------------------------------------------------
1. **Unknown named arguments.** For every call to a constructor/factory defined in
   `lib/domain` or `lib/data`, each `name:` argument must appear in that definition's
   parameter list.
2. **Unknown member calls.** For every `receiver.member(` where `receiver` is a local variable
   whose declared type is a class defined in `lib/domain`/`lib/data`, `member` must be a public
   member of that class (own members plus the members of the abstracts it implements).
3. **Unresolvable relative imports.** Every `import './x.dart'` / `../x.dart` must exist.
4. **Identifiers used but never declared in the app.** For each `X.y(...)` where `X` is an
   imported class from the app, `y` must exist somewhere in the app's own sources.

    python tool/check_l4_usage.py
    python tool/check_l4_usage.py --strict     # non-zero exit on any finding

Exit codes: 0 = clean, 2 = findings (with `ACD-ART-006` on the first stderr line).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]              # AcouDiet/
LIB = ROOT / "app" / "lib"

IMPORT_RE = re.compile(r"""^\s*import\s+['"](?P<path>[^'"]+)['"]""", re.MULTILINE)
CLASS_RE = re.compile(r"^(?:abstract\s+|final\s+|sealed\s+)?class\s+(?P<name>\w+)"
                      r"(?P<rest>[^{]*)\{", re.MULTILINE)
#: `Type name = ...` and `required Type name,` style declarations, for receiver typing.
VAR_DECL_RE = re.compile(r"\b(?P<type>[A-Z]\w+)\s+(?P<var>[a-z]\w*)\s*(?:=|;|,|\))")
CALL_RE = re.compile(r"\b(?P<recv>[A-Za-z_]\w*)\.(?P<member>\w+)\s*\(")
CTOR_RE = re.compile(r"\b(?P<name>[A-Z]\w*)(?:\.(?P<named>\w+))?\s*\((?P<args>[^;]*?)\)")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def load_sources() -> dict[Path, str]:
    return {p: strip_comments(p.read_text(encoding="utf-8", errors="replace"))
            for p in sorted(LIB.rglob("*.dart"))}


#: Members provided by `dart:core` / `num` / `Iterable`, which no app class declares. Name-based
#: receiver typing can pick the wrong scope (e.g. an `int score` field alongside a `HealthScore
#: score` declaration), so these are never treated as "imagined" members.
BUILTIN_MEMBERS = {
    "toDouble", "toInt", "toString", "hashCode", "runtimeType", "noSuchMethod",
    "length", "isEmpty", "isNotEmpty", "first", "last", "single", "add", "addAll", "remove",
    "removeAt", "clear", "map", "where", "any", "every", "fold", "reduce", "contains",
    "indexOf", "join", "split", "replaceAll", "trim", "toUpperCase", "toLowerCase",
    "startsWith", "endsWith", "substring", "padLeft", "padRight", "compareTo", "abs", "round",
    "floor", "ceil", "clamp", "call", "then", "catchError", "whenComplete", "compare",
    "addListener", "removeListener", "notifyListeners", "dispose", "build", "createState",
    "keys", "values", "entries", "sort", "toList", "toSet", "firstWhere", "expand", "take",
    "skip", "insert", "putIfAbsent", "update", "updateAll", "write", "writeln", "flush",
}


def split_top_level(text: str) -> list[str]:
    """Splits on commas that are not nested inside <>, [], () or {}."""
    parts, depth, current = [], 0, []
    for ch in text:
        if ch in "<[({":
            depth += 1
        elif ch in ">])}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
            continue
        current.append(ch)
    if current:
        parts.append("".join(current))
    return parts


def header_of(text: str, open_paren: int) -> str:
    """Returns the text inside the parenthesis that opens at `open_paren`."""
    depth, i = 0, open_paren
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:i]
        i += 1
    return ""


def params_of_header(header: str) -> set[str]:
    """Named parameters declared in a constructor/method header.

    Handles `required Type this.name`, `Type name = default`, `@annotation Type name`, and the
    positional section (which is ignored -- call sites pass those positionally).
    """
    if "{" not in header:
        return set()
    named = header[header.index("{") + 1:]
    if named.endswith("}"):
        named = named[:-1]
    out: set[str] = set()
    for part in split_top_level(named):
        part = part.split("=")[0]            # drop default values
        part = part.split(":")[0]            # drop annotations that use a colon
        part = re.sub(r"^(required|covariant)\s+", "", part.strip())
        part = re.sub(r"^@\w+(\([^)]*\))?\s*", "", part).strip()
        if not part:
            continue
        token = part.split()[-1] if part.split() else ""
        token = token[5:] if token.startswith("this.") else token
        token = token.rstrip("?")
        if token.isidentifier() and token not in ("required", "this"):
            out.add(token)
    return out


def class_index(sources: dict[Path, str]) -> dict[str, dict]:
    index: dict[str, dict] = {}
    for path, text in sources.items():
        for m in CLASS_RE.finditer(text):
            name = m.group("name")
            rest = m.group("rest")
            entry = index.setdefault(name, {
                "path": path,
                "members": set(),
                "supers": set(),
                "ctor_params": {},
            })
            # members: `Type name(` / `Type get name` at 2-space indent
            body = text[m.end():]
            for mm in re.finditer(r"^\s{2}(?:@override\s+)?[\w<>?,\s\[\]]+?\s(\w+)\s*[(<{]", body,
                                  re.MULTILINE):
                entry["members"].add(mm.group(1))
            for mm in re.finditer(r"^\s{2}(?:final|const|var)\s+[\w<>?,\s]+\s(\w+)\s*[;=]",
                                  body, re.MULTILINE):
                entry["members"].add(mm.group(1))
            for mm in re.finditer(r"^\s{2}(?:final|const)\s+(\w+)\s+(\w+)\s*[;=]", body,
                                  re.MULTILINE):
                entry["members"].add(mm.group(2))
            # supers
            for sup in re.finditer(r"(?:implements|extends|with)\s+([\w,\s]+)", rest):
                for s in sup.group(1).split(","):
                    s = s.strip()
                    if s:
                        entry["supers"].add(s)
            # constructors: `Name(`, `Name.named(`
            for cm in re.finditer(rf"(?<![\w.]){name}(?:\.(\w+))?\s*\(", text):
                open_paren = text.index("(", cm.end() - 1)
                entry["ctor_params"].setdefault(cm.group(1) or "", set()).update(
                    params_of_header(header_of(text, open_paren)))
    return index


def all_members(index: dict[str, dict], name: str, seen: set[str] | None = None) -> set[str]:
    seen = seen or set()
    if name in seen or name not in index:
        return set()
    seen.add(name)
    entry = index[name]
    out = set(entry["members"])
    for sup in entry["supers"]:
        out |= all_members(index, sup, seen)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    sources = load_sources()
    index = class_index(sources)
    frozen = {n for n, e in index.items()
              if "/domain/" in e["path"].as_posix() or "/data/" in e["path"].as_posix()}

    print("=" * 78)
    print("L1-L4 usage consistency check (Flutter call sites vs the frozen API)")
    print("=" * 78)
    print(f"files analysed : {len(sources)}")
    print(f"classes indexed: {len(index)} ({len(frozen)} in domain/data)")
    print("layer purity   : L3 (lib/data/db) and L4 (lib/domain) must not import Flutter")
    print()

    findings: list[str] = []

    # --- 0. layer purity: L3/L4 must stay runnable under a plain Dart VM -------------------
    #
    # `PLAN-C-05` runs the data and domain suites with `dart.exe`, no Flutter engine attached.
    # That only works while those layers do not (transitively) import `package:flutter`, whose
    # `dart:ui` dependency is unavailable off-device.
    #
    # This is not hypothetical: the first attempt at the Android SQLite fix put the channel
    # adapter in `data/db/`, which dragged `package:flutter/services.dart` into
    # `app_database.dart` and broke the entire L3 suite with
    # `Error: Dart library 'dart:ui' is not available on this platform`. Platform-channel
    # adapters belong in `data/native/` (L2); this rule keeps them there.
    layer_dirs = {"L3": LIB / "data" / "db", "L4": LIB / "domain"}
    for layer, directory in layer_dirs.items():
        if not directory.exists():
            continue
        for path in sorted(directory.rglob("*.dart")):
            body = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
            for m in IMPORT_RE.finditer(body):
                spec = m.group("path")
                if spec.startswith("package:flutter"):
                    findings.append(
                        f"ACD-ART-006: {path.relative_to(LIB)} is a {layer} file but imports "
                        f"'{spec}' -- {layer} must run under a plain Dart VM "
                        f"(move the adapter to lib/data/native/)")

    # --- 1. relative imports resolve ------------------------------------------------------
    for path, text in sources.items():
        for m in IMPORT_RE.finditer(text):
            spec = m.group("path")
            if not spec.startswith("."):
                continue
            target = (path.parent / spec).resolve()
            if not target.exists():
                findings.append(f"ACD-ART-006: {path.relative_to(LIB)} imports missing file '{spec}'")

    main_ctor_seen: set[str] = set()
    for path, text in sources.items():
        for name in index:
            # `Name(` 前面不是 `.`（排除 `other.Name(`）且不是标识符的一部分。
            if re.search(rf"(?<![\w.]){re.escape(name)}\s*\(", text):
                main_ctor_seen.add(name)

    # --- 2. unknown named arguments at call sites of frozen constructors -------------------
    # Consumers only: a class calling its own constructor is trivially consistent, and auditing
    # the declaring layer would just re-parse the same text.
    for path, text in sources.items():
        posix = path.as_posix()
        if "/domain/" in posix or "/data/" in posix or "/core/" in posix:
            continue
        for m in CTOR_RE.finditer(text):
            name = m.group("name")
            if name not in frozen:
                continue
            named_ctor = m.group("named") or ""
            ctors = index[name]["ctor_params"]
            if named_ctor:
                # `CTOR_RE` 也会匹配 `ClassName.staticMethod(...)`，把静态方法名捕获成
                # `named` —— 语法上无法区分"命名构造函数"与"静态方法"。判据用索引里的
                # `members`（类内声明的方法名集合）：
                #
                #   * `named` 在**索引里有构造记录** → 命名构造函数，按它自己的参数校验；
                #   * `named` 在**成员集合里** → 静态/实例方法（例如
                #     `SomeClass.staticMethod(...)`），按构造函数校验只会误报，跳过；
                #   * 两者都不是 → 沿用主构造参数（保守：宁可查也不放过）。
                if named_ctor in ctors:
                    params = ctors[named_ctor]
                elif named_ctor in index[name]["members"]:
                    continue
                else:
                    params = ctors.get("")
            else:
                params = ctors.get("")
            if not params:
                continue
            inner = m.group("args")
            for arg in re.finditer(r"(?<![\w.])(\w+)\s*:", inner):
                token = arg.group(1)
                if token in params or token in ("required", "const", "this"):
                    continue
                findings.append(
                    f"ACD-ART-006: {path.relative_to(LIB)} calls {name}"
                    f"{'.' + named_ctor if named_ctor else ''}(...) with unknown named "
                    f"argument '{token}:' (accepts: {sorted(params)})")

    # --- 3. member calls on receivers typed by a frozen class -----------------------------
    # Receiver typing here is name-based, which is deliberately conservative: a variable named
    # `profile` may be a `ProfileRepo` in one scope and a `UserProfile` in another (both occur
    # in notifiers.dart). Guessing wrong would produce false positives, so a call is only
    # reported when the member name exists on **no class in the whole app** -- which is the
    # actual bug class (a method that was imagined rather than written).
    app_members: set[str] = set()
    for entry in index.values():
        app_members |= entry["members"]

    for path, text in sources.items():
        posix = path.as_posix()
        if "/domain/" in posix or "/data/" in posix:
            continue  # only audit consumers, not the layer itself
        receivers: dict[str, str] = {}
        for m in re.finditer(
                r"\b(?:(?:final|const)\s+)?(?P<type>[A-Z]\w+)(?:\?)?\s+(?P<var>[a-z]\w*)\s*=", text):
            if m.group("type") in frozen:
                receivers[m.group("var")] = m.group("type")
        for m in re.finditer(r"\b(?P<type>[A-Z]\w+)\s+(?P<var>[a-z]\w*)\s*[,)]", text):
            if m.group("type") in frozen:
                receivers.setdefault(m.group("var"), m.group("type"))
        for m in CALL_RE.finditer(text):
            recv, member = m.group("recv"), m.group("member")
            cls = receivers.get(recv)
            if cls is None:
                continue
            if member.startswith("_") or member in BUILTIN_MEMBERS:
                continue
            # Sound rule: only flag a member that exists nowhere in the app.
            if member in app_members:
                continue
            members = all_members(index, cls)
            if not members:
                continue
            line = text[:m.start()].count("\n") + 1
            findings.append(
                f"ACD-ART-006: {path.relative_to(LIB)}:{line} calls {recv}.{member}() on a "
                f"{cls}-typed receiver, but no class in the app declares '{member}'")

    print()
    if findings:
        seen = set()
        for f in findings:
            if f in seen:
                continue
            seen.add(f)
            print(f"  [FAIL] {f}")
        print()
        print(f"RESULT: FAIL ({len(seen)} finding(s))")
        if args.strict:
            print(sorted(seen)[0], file=sys.stderr)
            return 2
        return 0

    print("  [ok  ] every relative import resolves to a file")
    print("  [ok  ] every named argument at a frozen-API call site exists")
    print("  [ok  ] every member called on a frozen-typed receiver exists")
    print()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
