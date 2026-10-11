#!/usr/bin/env python3
"""Time Jarvis's web tools on this machine: search, page reads, browser loads.

Run from the repo root with the agent's venv (on the server):
    .venv/bin/python scripts/web_bench.py            # everything
    .venv/bin/python scripts/web_bench.py --only browser --engines chrome lightpanda

Goes through the real tool dispatcher (model_tools.handle_function_call), so the
numbers include whatever backend/engine the config selects. Prints a table and
writes JSON next to it (--out). Read-only apart from browser sessions it closes.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

QUERIES = [
    "cheap flights Houston to San Francisco",
    "best noise cancelling headphones 2026",
    "how does a heat pump work",
    "python asyncio gather vs wait",
    "weather Austin this weekend",
]
URLS = [
    "https://docs.python.org/3/library/asyncio-task.html",
    "https://en.wikipedia.org/wiki/Houston",
    "https://www.bbc.com/news",
    "https://www.kayak.com/flight-routes/Houston-HOU/San-Francisco-SFO",
    "https://www.google.com/travel/flights?q=Flights%20from%20HOU%20to%20SFO",
    "https://news.ycombinator.com/",
    "https://www.amazon.com/s?k=robot+vacuum",
    "https://github.com/lightpanda-io/browser",
]
BROWSER_SITES = URLS[1:6]


def _call(name, args, task_id="bench"):
    from model_tools import handle_function_call
    t = time.monotonic()
    raw = handle_function_call(name, args, task_id=task_id)
    ms = int((time.monotonic() - t) * 1000)
    try:
        return json.loads(raw), ms
    except ValueError:
        return {"success": False, "error": raw[:200]}, ms


def bench_search():
    rows = []
    for q in QUERIES:
        out, ms = _call("web_search", {"query": q})
        hits = len(((out.get("data") or {}).get("web")) or [])
        rows.append({"query": q, "ms": ms, "results": hits, "ok": bool(out.get("success"))})
    return rows


def bench_extract():
    rows = []
    for u in URLS:
        out, ms = _call("web_extract", {"urls": [u]})
        res = (out.get("results") or [{}])[0] if isinstance(out.get("results"), list) else {}
        rows.append({"url": u, "ms": ms, "chars": len(str(res.get("content") or "")),
                     "tier": ((res.get("metadata") or {}).get("tier")), "error": res.get("error") or out.get("error")})
    return rows


def bench_browser(engines):
    import tools.browser_tool as bt
    rows = []
    for engine in engines:
        bt._browser_engine_resolved, bt._cached_browser_engine = True, engine
        for i, site in enumerate(BROWSER_SITES):
            tid = f"bench-{engine}-{i}"
            nav, nav_ms = _call("browser_navigate", {"url": site}, task_id=tid)
            snap, snap_ms = _call("browser_snapshot", {"full": True}, task_id=tid)
            used = nav.get("browser_engine") or (bt._active_sessions.get(bt._last_session_key(tid)) or {}).get("engine")
            rows.append({"engine": engine, "site": site, "open_ms": nav_ms, "snapshot_ms": snap_ms,
                         "snapshot_chars": len(str(snap.get("snapshot") or "")), "ran_on": used,
                         "ok": bool(nav.get("success"))})
            bt.cleanup_browser(tid)
    bt._browser_engine_resolved = False
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["search", "extract", "browser"])
    ap.add_argument("--engines", nargs="+", default=["chrome", "lightpanda"])
    ap.add_argument("--out", default="web_bench.json")
    a = ap.parse_args()
    import model_tools  # noqa: F401  (tool + plugin discovery)
    report = {}
    if a.only in (None, "search"):
        report["search"] = bench_search()
        ms = [r["ms"] for r in report["search"]]
        print(f"web_search   median {statistics.median(ms)} ms  ({sum(r['ok'] for r in report['search'])}/{len(ms)} ok)")
    if a.only in (None, "extract"):
        report["extract"] = bench_extract()
        for r in report["extract"]:
            print(f"web_extract  {r['ms']:>6} ms  {r['chars']:>7} chars  {str(r['tier'] or '-'):8}  {r['url'][:60]}"
                  + (f"  ERR {str(r['error'])[:60]}" if r["error"] else ""))
    if a.only in (None, "browser"):
        report["browser"] = bench_browser(a.engines)
        for r in report["browser"]:
            print(f"browser[{r['engine']:10}] open {r['open_ms']:>6} ms  snapshot {r['snapshot_ms']:>5} ms  "
                  f"{r['snapshot_chars']:>7} chars  ran on {r['ran_on']}  {r['site'][:55]}")
    Path(a.out).write_text(json.dumps(report, indent=1))
    print(f"→ {a.out}")


if __name__ == "__main__":
    main()
