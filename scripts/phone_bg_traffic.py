#!/usr/bin/env python3
"""How much the phone talks to the server from the background, per hour and per path.

The battery number for an always-alive app: every request from the background wakes
the phone's radio. The webui access log marks those with ``"bg": 1`` (the app sends
``X-JC-App-State: background``). Feed it the webui journal:

    journalctl -u jarviscopilot-webui.service --since "22:00" --until "07:00" -o cat \\
        | python3 scripts/phone_bg_traffic.py
"""
from __future__ import annotations

import collections
import json
import re
import sys

_IDS = re.compile(r"c_[0-9a-f]{8,}|d_[0-9a-f]{8}|[0-9a-f]{16,}")


def summarize(lines) -> tuple[dict[str, int], collections.Counter]:
    per_hour: dict[str, int] = collections.Counter()
    per_path: collections.Counter = collections.Counter()
    for line in lines:
        if "[webui] {" not in line:
            continue
        try:
            row = json.loads(line.split("[webui] ", 1)[1])
        except (ValueError, IndexError):
            continue
        if row.get("bg") != 1:
            continue
        per_hour[str(row.get("ts", ""))[:13]] += 1
        path = _IDS.sub("…", str(row.get("path", "")).split("?", 1)[0])
        per_path[f'{row.get("method", "?")} {path}'] += 1
    return dict(per_hour), per_path


def main() -> int:
    per_hour, per_path = summarize(sys.stdin)
    if not per_hour:
        print("no background requests in the input")
        return 0
    hours = len(per_hour)
    total = sum(per_hour.values())
    print(f"{total} background requests over {hours} hour(s): {total / hours:.1f}/h")
    for hour in sorted(per_hour):
        print(f"  {hour}:00Z  {per_hour[hour]}")
    print("by path:")
    for path, n in per_path.most_common(15):
        print(f"  {n / hours:7.1f}/h  {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
