#!/usr/bin/env python3
"""Personal memory eval: mine his real misses, replay old vs new injection.

    python scripts/memory_eval.py mine [--days 60]      # chat history → eval/cases.jsonl
    python scripts/memory_eval.py replay --mode v2      # or --mode legacy
    python scripts/memory_eval.py compare               # both, side by side

Cases and reports live in $HERMES_HOME/memory/eval/ — they quote his chats.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def _paths():
    from jarviscopilot_constants import get_hermes_home
    home = Path(get_hermes_home())
    return home / "state.db", home / "memory" / "eval"


def _run(mode):
    from plugins.memory.jarvis_memory import evalset, external, tz
    store, embedder, namespace, _th = external._open()
    _state, folder = _paths()
    cases = evalset.load_cases(folder / "cases.jsonl")
    return evalset.replay(store, embedder, cases, mode=mode, zone=tz.user_zone(), namespace=namespace)


def _print(report):
    print(f"{report['mode']:>7}: n={report['n']}  first-try recall@5  retrieval {report['recall5_retrieval']:.0%}"
          f"  brief {report['recall5_brief']:.0%}  either {report['recall5_combined']:.0%}"
          f"  p50 {report['p50_ms']} ms  p95 {report['p95_ms']} ms  ~{report['avg_chars']} chars")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("mine")
    m.add_argument("--days", type=int, default=60)
    r = sub.add_parser("replay")
    r.add_argument("--mode", choices=("legacy", "v2"), default="v2")
    sub.add_parser("compare")
    args = ap.parse_args()
    from plugins.memory.jarvis_memory import evalset
    state, folder = _paths()
    if args.cmd == "mine":
        cases = evalset.mine_cases(state, since_days=args.days)
        evalset.save_cases(folder / "cases.jsonl", cases)
        print(f"{len(cases)} cases → {folder / 'cases.jsonl'}")
        for c in cases[:20]:
            print(f"- {c.question[:90]}  (gold {len(c.gold_ids)})")
        return 0
    reports = [_run(args.mode)] if args.cmd == "replay" else [_run("legacy"), _run("v2")]
    folder.mkdir(parents=True, exist_ok=True)
    out = folder / f"report-{time.strftime('%Y%m%d-%H%M%S')}.json"
    out.write_text(json.dumps(reports, indent=1), encoding="utf-8")
    for rep in reports:
        _print(rep)
    print(f"report: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
