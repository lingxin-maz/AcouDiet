"""静态检查：presentation 层的异步续体是否在写已释放的对象。

WHY
---
本项目反复栽在同一类缺陷上，而且**每次的特征都一样**：

  * `ADR-24`：没有任何测试 pump 过 `AppShell` 本身；
  * v1.1.0 首包：`polishedAdvices` 从未被任何页面调用（润色层形同虚设）；
  * `ADR-29`：检测页「否」按钮把合法操作当参数错误，100% 必然报错；
  * `ADR-31`：`await` 之后写已 `dispose` 的 `ValueNotifier`（`HomeNotifier.weeklyReview`）与
    裸写 `level.value`（`DetectNotifier`）。
    （`ADR-34` 删除了端侧语言模型层，`HomeNotifier` 那一处**已随功能整体移除**；
    `DetectNotifier` 那一处仍在，仍是本脚本的主要目标。）

共同点不是"代码难写"，而是**这些路径没有任何机械检查覆盖**：离线套件不编译
presentation 层的生命周期，`tool/*_tests.dart` 也不 pumpWidget。
人眼复查会漏，所以把它变成脚本。

本脚本检查两件事
----------------
1. **await 之后的写入必须带 `mounted` 守卫**：在每个 `await` 与紧随其后的
   `xxx.value =` / `publishXxx(...)` 之间，必须能找到 `mounted` 判断。
2. **写入 ValueNotifier 的回调必须是带守卫的方法**，而不是内联裸赋值
   （形如 `onLevel: (v) => level.value = v`）。

刻意做成**启发式 + 保守**：宁可漏报也不要大量误报 —— 一个总在报假的检查会被无视，
比没有检查更糟。所以只在"同一方法体内、await 之后、没有 mounted 字样"时报。

退出码：0 = 通过；2 = 发现问题。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE_DIR = ROOT / "app" / "lib" / "presentation" / "state"

#: 写入既有状态的动作。
#:
#: ⚠️ **只收"直接写 `.value =`"这一类。**
#: `publishValue` / `publishError` / `publishEmpty` / `notifyListeners` 刻意**排除**：
#: 它们要么是基类 `AcouNotifier` 的方法（内部已 `if (_disposed) return;`），要么是
#: `ChangeNotifier` 自己的 API，**本身就在"被释放后写入"这件事上做了保护**。
#: 第一版把它们一起收进来，结果在本仓报了 6 处**全部为假**的问题——
#: 一个总在报假的检查会被无视，比没有检查更糟。
#:
#: 真正危险的是**绕过基类、直接写字段上的 ValueNotifier**（例如
#: `DetectNotifier.level.value`），因为那些对象是**自己 dispose 的**，没有任何防护。
WRITE_PATTERNS = [
    re.compile(r"\.value\s*="),
]

#: 内联裸赋值（回调里直接写），必须改成带守卫的方法。
INLINE_WRITE = re.compile(r"=>\s*[\w.]*\.value\s*=")


def method_bodies(src: str):
    """按缩进切出顶层方法体，返回 [(name, start_line, body)]。"""
    lines = src.split("\n")
    out = []
    i = 0
    # 只处理 2 空格缩进的成员（类的方法）
    sig = re.compile(r"^  (?:@\w+\s+)?(?:Future<[^>]*>|void|bool|int|String|double)?\s*"
                     r"([A-Za-z_]\w*)\s*\(")
    while i < len(lines):
        m = sig.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        start = i
        depth = 0
        began = False
        buf = []
        j = i
        while j < len(lines):
            ln = lines[j]
            buf.append(ln)
            depth += ln.count("{") - ln.count("}")
            if "{" in ln:
                began = True
            if began and depth <= 0:
                break
            j += 1
        out.append((name, start + 1, "\n".join(buf)))
        i = j + 1
    return out


def check_await_then_write(path: Path) -> list:
    src = path.read_text(encoding="utf-8")
    problems = []

    for name, start_line, body in method_bodies(src):
        body_lines = body.split("\n")
        pending_await = False
        await_line = 0
        for idx, ln in enumerate(body_lines):
            stripped = ln.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            if "await " in ln:
                pending_await = True
                await_line = start_line + idx
                continue
            if not pending_await:
                continue
            if any(p.search(ln) for p in WRITE_PATTERNS):
                # 从 await 到这次写入之间必须有 mounted 守卫。
                window = "\n".join(body_lines[max(0, idx - 12):idx + 1])
                if "mounted" not in window:
                    problems.append(
                        f"{path.name}:{start_line + idx + 1}: 方法 {name}() 在 await"
                        f"（第 {await_line} 行）之后写入状态，但附近没有 mounted 守卫"
                    )
                pending_await = False
    return problems


def check_inline_value_write(path: Path) -> list:
    src = path.read_text(encoding="utf-8")
    problems = []
    for i, ln in enumerate(src.split("\n"), 1):
        s = ln.strip()
        if s.startswith("//") or s.startswith("///"):
            continue
        if INLINE_WRITE.search(ln):
            problems.append(
                f"{path.name}:{i}: 内联裸写 ValueNotifier（{s[:70]}）—— "
                f"dispose 后触发会抛 'used after being disposed'，应改为带 mounted 守卫的方法"
            )
    return problems


def main() -> int:
    if not STATE_DIR.is_dir():
        print(f"FAIL: 找不到 {STATE_DIR}")
        return 2

    problems = []
    files = sorted(STATE_DIR.rglob("*.dart"))
    for f in files:
        problems += check_await_then_write(f)
        problems += check_inline_value_write(f)

    print(f"checked {len(files)} file(s) under {STATE_DIR.relative_to(ROOT)}")
    if not problems:
        print("RESULT: PASS (no unguarded async state writes found)")
        return 0

    print("")
    for p in problems:
        print("  [!!] " + p)
    print("")
    print(f"RESULT: FAIL ({len(problems)} problem(s))")
    return 2


if __name__ == "__main__":
    sys.exit(main())
