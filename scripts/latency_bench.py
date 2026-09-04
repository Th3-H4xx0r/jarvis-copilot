"""scripts/latency_bench.py — plan 0.3 (Phase 0, sub-second latency rehaul).

Replays canned voice turns against a RUNNING JarvisCopilot server's realtime
voice WebSocket (``/api/voice/s2s/ws``) and reports p50/p95 latency per span
from the server's ``{"type":"latency","spans":{...}}`` frame (see plan task
0.1, webui/api/voice.py: ``_start_turn_timing`` / ``_finish_turn_timing``).

This is the acceptance gate for every later phase of the latency rehaul —
each phase should show a bench improvement over the previous baseline.

Usage:
    JC_BENCH_URL=http://localhost:8420 JC_BENCH_COOKIE="hermes_session=..." \\
        python3 scripts/latency_bench.py --turns 20 --wav-turns 10 --out results.json

    # Write/refresh the committed baseline:
    python3 scripts/latency_bench.py --baseline

Env vars:
    JC_BENCH_URL     Base URL of a running server, e.g. http://localhost:8420
    JC_BENCH_COOKIE  Cookie header value for auth (e.g. "hermes_session=...")

Networking uses ``websocket-client`` (imported lazily — NOT required just to
run ``--help`` or to exercise the pure percentile/table helpers below, which
is what tests/test_latency_bench.py covers without a live server).
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import time
import wave
import io
from pathlib import Path
from typing import Optional

# plan 0.3 — spans reported by the server's `latency` WS frame (plan 0.1).
# tool_rtt_ms is a list-of-lists (one list per turn) and is flattened by
# summarize() same as the scalar spans.
SPAN_NAMES = ("endpoint_ms", "stt_ms", "prep_ms", "ttft_ms", "first_audio_ms", "tool_rtt_ms")

DEFAULT_BASELINE_PATH = Path(__file__).resolve().parent / "latency_baseline.json"
DEFAULT_WS_PATH = "/api/voice/s2s/ws"
# Generous per-turn wait — a cold model / tool call can be slow; the bench
# should time out gracefully rather than hang the whole run on one turn.
DEFAULT_TURN_TIMEOUT_SECONDS = 30.0

# A handful of short, varied canned utterances for the text-turn replay (skips
# STT server-side, isolating prep/ttft/first_audio from STT latency).
CANNED_TEXT_TURNS = [
    "What time is it?",
    "What's the weather today?",
    "Set a timer for five minutes.",
    "Tell me a fun fact.",
    "What's on my calendar tomorrow?",
    "Turn on the living room lights.",
    "What's two hundred and thirty four times six?",
    "Read me my latest email.",
    "Play some music.",
    "How far away is the moon?",
]


# ---------------------------------------------------------------------------
# Pure helpers — percentile math + table rendering. Unit-tested without a
# server (tests/test_latency_bench.py).
# ---------------------------------------------------------------------------

def percentile(values, pct: float) -> Optional[float]:
    """Nearest-rank-interpolated percentile of a list of numbers.

    ``pct`` is 0-100 (50 for p50, 95 for p95). Returns None for an empty
    input so callers can render "-" instead of crashing on an unobserved
    span.
    """
    if not values:
        return None
    data = sorted(values)
    if len(data) == 1:
        return float(data[0])
    k = (pct / 100.0) * (len(data) - 1)
    lo = int(k)
    hi = min(lo + 1, len(data) - 1)
    if lo == hi:
        return float(data[lo])
    frac = k - lo
    return float(data[lo]) * (1 - frac) + float(data[hi]) * frac


def _flatten(values) -> list:
    """Flatten a list that may contain scalars and/or lists (tool_rtt_ms is a
    list per turn; every other span is a scalar per turn)."""
    flat = []
    for v in values:
        if v is None:
            continue
        if isinstance(v, list):
            flat.extend(x for x in v if x is not None)
        else:
            flat.append(v)
    return flat


def summarize(samples: dict) -> dict:
    """``{span: [sample, ...]}`` → ``{span: {"n", "p50", "p95"}}``.

    Samples may be scalars or lists (tool_rtt_ms); both are flattened before
    computing percentiles.
    """
    out = {}
    for name, values in samples.items():
        flat = _flatten(values)
        out[name] = {
            "n": len(flat),
            "p50": percentile(flat, 50),
            "p95": percentile(flat, 95),
        }
    return out


def render_table(summary: dict) -> str:
    """Render a ``{span: {n,p50,p95}}`` summary as an aligned text table."""
    headers = ("span", "n", "p50_ms", "p95_ms")

    def _fmt_ms(v: Optional[float]) -> str:
        return f"{v:.1f}" if v is not None else "-"

    rows = []
    for name in sorted(summary.keys()):
        s = summary[name]
        rows.append((name, str(s["n"]), _fmt_ms(s["p50"]), _fmt_ms(s["p95"])))

    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def _fmt_row(cells) -> str:
        return "  ".join(c.ljust(w) for c, w in zip(cells, widths))

    lines = [_fmt_row(headers), _fmt_row(["-" * w for w in widths])]
    lines.extend(_fmt_row(r) for r in rows)
    return "\n".join(lines)


def merge_latency_frames(frames: list) -> dict:
    """``[{"spans": {...}}, ...]`` (one dict per turn's `latency` WS frame) →
    ``{span: [sample_per_turn, ...]}`` ready for ``summarize()``."""
    samples: dict = {name: [] for name in SPAN_NAMES}
    for frame in frames:
        spans = (frame or {}).get("spans") or {}
        for name in SPAN_NAMES:
            if name in spans:
                samples.setdefault(name, []).append(spans[name])
    return samples


# ---------------------------------------------------------------------------
# Canned WAV turn — a short, valid silence clip (real audio isn't needed; the
# point is to exercise the STT round trip, not test transcription accuracy).
# ---------------------------------------------------------------------------

def _make_canned_wav(seconds: float = 1.5, sample_rate: int = 16000) -> bytes:
    n_frames = int(seconds * sample_rate)
    silence = struct.pack(f"<{n_frames}h", *([0] * n_frames))
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(silence)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Networking — one voice-WS session, replaying N text turns + N wav turns.
# Imports websocket-client lazily so `--help` and the unit-tested pure
# helpers above never require it (or a running server).
# ---------------------------------------------------------------------------

def _ws_url(base_url: str) -> str:
    if base_url.startswith("https://"):
        return "wss://" + base_url[len("https://"):] + DEFAULT_WS_PATH
    if base_url.startswith("http://"):
        return "ws://" + base_url[len("http://"):] + DEFAULT_WS_PATH
    return base_url.rstrip("/") + DEFAULT_WS_PATH


def _run_one_turn(ws, *, text: str = "", wav_bytes: Optional[bytes] = None,
                   timeout: float = DEFAULT_TURN_TIMEOUT_SECONDS) -> Optional[dict]:
    """Send one begin_turn/end_turn exchange and return the `latency` frame's
    payload dict, or None if the server never sent one before timing out /
    ending the turn."""
    import websocket  # type: ignore

    begin = {"type": "begin_turn", "sample_rate": 16000}
    ws.send(json.dumps(begin))

    end_turn = {"type": "end_turn", "client_ts": time.time() * 1000.0}
    if text:
        end_turn["text"] = text
        end_turn["speech_end_ts"] = end_turn["client_ts"] - 5.0  # ~instant endpointing
    elif wav_bytes:
        # PCM frames the WAV wraps — the server accumulates raw PCM, not WAV.
        with wave.open(io.BytesIO(wav_bytes), "rb") as wf:
            pcm = wf.readframes(wf.getnframes())
        ws.send(pcm, opcode=websocket.ABNF.OPCODE_BINARY)
        end_turn["speech_end_ts"] = end_turn["client_ts"] - 400.0  # simulated endpoint wait
    ws.send(json.dumps(end_turn))

    deadline = time.monotonic() + timeout
    latency_payload = None
    while time.monotonic() < deadline:
        try:
            ws.settimeout(max(0.1, deadline - time.monotonic()))
            raw = ws.recv()
        except Exception:
            break
        if not isinstance(raw, str):
            continue
        try:
            msg = json.loads(raw)
        except Exception:
            continue
        t = msg.get("type")
        if t == "latency":
            latency_payload = msg
        elif t == "end_turn":
            break
    return latency_payload


def run_bench(base_url: str, cookie: str, *, turns: int, wav_turns: int,
              timeout: float = DEFAULT_TURN_TIMEOUT_SECONDS) -> dict:
    """Connect once, replay `turns` text turns + `wav_turns` WAV turns, and
    return the merged per-span sample lists (see merge_latency_frames)."""
    import websocket  # type: ignore

    url = _ws_url(base_url)
    headers = [f"Cookie: {cookie}"] if cookie else []
    ws = websocket.create_connection(url, header=headers, timeout=timeout)
    frames = []
    try:
        for i in range(turns):
            text = CANNED_TEXT_TURNS[i % len(CANNED_TEXT_TURNS)]
            frame = _run_one_turn(ws, text=text, timeout=timeout)
            if frame:
                frames.append(frame)
        wav_bytes = _make_canned_wav()
        for _ in range(wav_turns):
            frame = _run_one_turn(ws, wav_bytes=wav_bytes, timeout=timeout)
            if frame:
                frames.append(frame)
    finally:
        try:
            ws.close()
        except Exception:
            pass
    return merge_latency_frames(frames)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    p.add_argument("--turns", type=int, default=20, help="canned text turns (skip STT)")
    p.add_argument("--wav-turns", type=int, default=10, help="canned short-WAV turns (exercise STT)")
    p.add_argument("--timeout", type=float, default=DEFAULT_TURN_TIMEOUT_SECONDS, help="per-turn wait, seconds")
    p.add_argument("--out", type=str, default="", help="write the full JSON summary here")
    p.add_argument("--baseline", action="store_true",
                    help=f"also write the summary to {DEFAULT_BASELINE_PATH} (the committed baseline)")
    p.add_argument("--url", type=str, default="", help="server base URL (default: $JC_BENCH_URL)")
    p.add_argument("--cookie", type=str, default="", help="auth cookie header (default: $JC_BENCH_COOKIE)")
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)
    base_url = args.url or os.environ.get("JC_BENCH_URL", "")
    cookie = args.cookie or os.environ.get("JC_BENCH_COOKIE", "")
    if not base_url:
        print("error: no server URL — pass --url or set JC_BENCH_URL", file=sys.stderr)
        return 2

    try:
        import websocket  # noqa: F401  (fail fast with a clear message)
    except ImportError:
        print("error: the 'websocket-client' package is required to connect to a live "
              "server (pip install websocket-client). The pure percentile/table helpers "
              "in this module don't need it — see tests/test_latency_bench.py.", file=sys.stderr)
        return 2

    samples = run_bench(base_url, cookie, turns=args.turns, wav_turns=args.wav_turns, timeout=args.timeout)
    summary = summarize(samples)
    print(render_table(summary))

    payload = {
        "generated_at": time.time(),
        "url": base_url,
        "turns": args.turns,
        "wav_turns": args.wav_turns,
        "summary": summary,
    }
    if args.out:
        Path(args.out).write_text(json.dumps(payload, indent=2), encoding="utf-8")
    if args.baseline:
        DEFAULT_BASELINE_PATH.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nBaseline written to {DEFAULT_BASELINE_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
