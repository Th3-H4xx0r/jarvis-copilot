#!/usr/bin/env python3
"""Run the one-time memory-map backfill + cleanup from the shell.

Same job as Long-term Memory → Cleanup → Run: backs up memory.db, rewrites Live
windows to summaries, fixes UTC stamps to local time, merges duplicates and
maps every memory (dates, people, places) on the memory model.

    python scripts/memory_backfill.py            # run it
    python scripts/memory_backfill.py --report   # print the last report
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--report", action="store_true", help="print the last report and exit")
    args = ap.parse_args()
    from plugins.memory.jarvis_memory import cleanup, external, tz
    store, embedder, _ns, _th = external._open()
    if args.report:
        print(json.dumps(cleanup.load_report(store), indent=1))
        return 0
    try:  # follow his memory-model choice when the web server's wiring is importable
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "webui"))
        from api.memory_map import install
        install()
    except Exception as exc:
        print(f"(memory model: using the default — {exc})", file=sys.stderr)
    report = cleanup.run(store, embedder, zone=tz.user_zone(),
                         progress=lambda s: print(f"\r{s['step']} {s['done']}/{s['total']}   ",
                                                  end="", file=sys.stderr, flush=True))
    print(file=sys.stderr)
    print(json.dumps(report["counts"], indent=1))
    print(f"backup: {report['backup']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
