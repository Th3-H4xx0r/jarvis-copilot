#!/usr/bin/env python3
"""The phone's battery, hour by hour, from the ledger it sends with each hourly probe.

The same numbers as the app's Settings → Battery usage, read on the server — no cable, no
phone in hand. Each row: battery change, time on screen and in a pocket (kept alive, on
cellular), CPU, live-link frames and requests, the busiest place on screen. The summary at the
end is the keepalive decision: the phone's drain per hour in a pocket, kept alive vs suspended,
on Wi-Fi vs cellular.

    ssh jc-hermes cat /root/.jarviscopilot/webui/energy.jsonl | python3 scripts/phone_energy_report.py
    ... | python3 scripts/phone_energy_report.py --hours 48 --utc-offset -5
"""
from __future__ import annotations

import argparse
import json
import sys
import time


def hours_from(lines) -> list[dict]:
    out = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        hour = row.get("hour") if isinstance(row, dict) else None
        if isinstance(hour, dict) and "start" in hour and "end" in hour:
            out.append(hour)
    return sorted(out, key=lambda h: h["start"])


def drained(hour: dict) -> float | None:
    """Battery points lost; None when an end is unknown or it charged."""
    a, b = hour.get("batteryStart"), hour.get("batteryEnd")
    if a is None or b is None or hour.get("seconds", {}).get("charging", 0) >= 60 or a < b:
        return None
    return (a - b) * 100


def share(hour: dict, key: str) -> float:
    wall = hour["end"] - hour["start"]
    return hour.get("seconds", {}).get(key, 0) / wall if wall > 0 else 0


def drain_rate(hours: list[dict], pick) -> tuple[float | None, float]:
    """Points an hour across the picked hours (at least half an hour of them)."""
    picked = [h for h in hours if h["end"] - h["start"] >= 1800 and drained(h) is not None and pick(h)]
    span = sum(h["end"] - h["start"] for h in picked) / 3600
    if span < 0.5:
        return None, span
    return sum(drained(h) for h in picked) / span, span


def summary(hours: list[dict]) -> dict[str, tuple[float | None, float]]:
    def pocket(h):
        return share(h, "background") >= 0.9

    return {
        "pocket, kept alive": drain_rate(hours, lambda h: pocket(h) and share(h, "bg.keepalive") >= 0.9),
        "pocket, suspended": drain_rate(hours, lambda h: pocket(h) and share(h, "bg.keepalive") <= 0.1),
        "pocket, Wi-Fi": drain_rate(hours, lambda h: pocket(h) and share(h, "bg.wifi") >= 0.8),
        "pocket, cellular": drain_rate(hours, lambda h: pocket(h) and share(h, "bg.cellular") >= 0.8),
        "on screen": drain_rate(hours, lambda h: share(h, "foreground") >= 0.5),
    }


def row_text(hour: dict, utc_offset: float) -> str:
    secs, cpu, counts = hour.get("seconds", {}), hour.get("cpu", {}), hour.get("counts", {})
    when = time.strftime("%m-%d %H:%M", time.gmtime(hour["start"] + utc_offset * 3600))
    d = drained(hour)
    battery = "  chg" if secs.get("charging", 0) >= 60 else (f"{-d:+5.0f}" if d is not None else "    ?")
    frames = counts.get("bridge.in", 0) + counts.get("bridge.out", 0)
    requests = sum(v for k, v in counts.items() if k.startswith("net.") and not k.startswith("net.bg."))
    places = sorted(((k[6:], v) for k, v in cpu.items() if k.startswith("where.")), key=lambda kv: -kv[1])
    top = f"{places[0][0].replace('|', ' › ').rstrip(' › ')} {places[0][1]:.0f}s" if places else ""
    return (f"{when} {battery}%  screen {secs.get('foreground', 0) / 60:3.0f}m {cpu.get('foreground', 0):5.0f}s  "
            f"pocket {secs.get('background', 0) / 60:3.0f}m (alive {secs.get('bg.keepalive', 0) / 60:2.0f}, "
            f"cell {secs.get('bg.cellular', 0) / 60:2.0f}) {cpu.get('background', 0):4.0f}s  "
            f"link {frames:4d} drop {counts.get('bridge.drop', 0)}  req {requests:3d}  {top}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--hours", type=int, default=24, help="how many recent hours to list")
    parser.add_argument("--utc-offset", type=float, default=-5, help="hours to add to UTC for the times shown")
    args = parser.parse_args()
    hours = hours_from(sys.stdin)
    if not hours:
        print("no ledger hours yet (the app sends one with each hourly probe)")
        return 0
    for hour in hours[-args.hours:]:
        print(row_text(hour, args.utc_offset))
    print("\nphone drain per hour (whole phone, hours spent almost all that way):")
    for name, (rate, span) in summary(hours).items():
        print(f"  {name:20s} {'%.1f%%/h' % rate if rate is not None else 'not enough hours':>18s}  over {span:.1f} h")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
