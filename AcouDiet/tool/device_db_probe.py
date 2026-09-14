"""Inserts one real record into the on-device AcouDiet database (emulator verification helper).

    python tool/device_db_probe.py --insert
    python tool/device_db_probe.py --dump

WHY
---
The Android SQLite defect was "nothing is ever persisted on device". Proving the fix needs the
database to be inspected *as the app sees it*, not as a host-side unit test sees it. This helper
talks to the device through `adb shell run-as` (possible because the debug APK is debuggable)
and feeds SQL over **stdin**: passing it as an argv element lets the device shell re-parse it,
which mangles parentheses and UTF-8 literals.

It writes exactly one `diet_record` row plus its 1:1 `behavior_metrics` row (invariant I-1),
using the **device's own clock** for the timestamp so the row lands inside the "this week"
window the home screen aggregates over.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

ADB = r"D:\Desktop\Food\_toolchain\android-sdk\platform-tools\adb.exe"
PACKAGE = "com.acoudiet.app"
DB = f"/data/data/{PACKAGE}/files/acoudiet.db"

INSERT_SQL = """
INSERT INTO diet_record (record_id, eaten_at_ms, ended_at_ms, class_label, class_id,
                         attribute, confidence, duration_seconds, source,
                         corrected_by_user, confirmed_by_user)
VALUES ('persist-1',
        CAST(strftime('%s','now') AS INTEGER)*1000,
        CAST(strftime('%s','now') AS INTEGER)*1000 + 300000,
        'noodles', 3, '软性主食', 0.82, 300, 'real', 0, 0);
INSERT INTO behavior_metrics (record_id, chew_count, avg_chew_interval_seconds,
                              duration_seconds, speed_grade)
VALUES ('persist-1', 42, 0.8, 300, 'normal');
"""

DUMP_SQL = """
SELECT 'user_version=' || (SELECT * FROM pragma_user_version);
SELECT 'record:' || record_id || '|' || class_label || '|' || attribute
       || '|' || confidence || '|' || eaten_at_ms FROM diet_record;
SELECT 'metrics:' || record_id || '|' || chew_count || '|' || speed_grade FROM behavior_metrics;
SELECT 'meta:' || key || '=' || value FROM app_meta;
"""


def run_sql(sql: str) -> tuple[int, str, str]:
    p = subprocess.run(
        [ADB, "shell", "run-as", PACKAGE, "/system/bin/sqlite3", DB],
        input=sql.encode("utf-8"), capture_output=True,
    )
    return (p.returncode,
            p.stdout.decode("utf-8", "replace"),
            p.stderr.decode("utf-8", "replace"))


def force_stop() -> None:
    subprocess.run([ADB, "shell", "am", "force-stop", PACKAGE], capture_output=True)


def pull(dest: pathlib.Path) -> int:
    """Pulls the database file. `exec-out` + Python capture keeps the bytes intact -- a
    PowerShell `>` would be a text redirection and corrupt the file."""
    p = subprocess.run(
        [ADB, "exec-out", "run-as", PACKAGE, "cat", DB], capture_output=True)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(p.stdout)
    return len(p.stdout)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--insert", action="store_true")
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--pull", metavar="PATH")
    args = ap.parse_args()

    if args.insert:
        force_stop()
        rc, out, err = run_sql(INSERT_SQL)
        print(f"insert rc={rc} stdout={out.strip()!r} stderr={err.strip()!r}")
        if rc != 0:
            return 1

    if args.dump:
        rc, out, err = run_sql(DUMP_SQL)
        print(f"dump rc={rc}")
        print(out.rstrip())
        if err.strip():
            print("stderr:", err.strip(), file=sys.stderr)
        if rc != 0:
            return 1

    if args.pull:
        n = pull(pathlib.Path(args.pull))
        print(f"pulled {n} bytes -> {args.pull}")

    if not (args.insert or args.dump or args.pull):
        ap.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
