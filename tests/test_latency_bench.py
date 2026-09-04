"""Unit tests for scripts/latency_bench.py's pure percentile/summary/table
helpers (plan task 0.3). No server, no network, no websocket-client import —
these must run in complete isolation, which is also what proves `--help`
never needs a live server or extra deps.
"""
import importlib.util
import sys
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "latency_bench.py"
_spec = importlib.util.spec_from_file_location("latency_bench", _SCRIPT_PATH)
latency_bench = importlib.util.module_from_spec(_spec)
sys.modules["latency_bench"] = latency_bench
_spec.loader.exec_module(latency_bench)


# ---------------------------------------------------------------------------
# percentile()
# ---------------------------------------------------------------------------

def test_percentile_empty_is_none():
    assert latency_bench.percentile([], 50) is None


def test_percentile_single_value():
    assert latency_bench.percentile([42.0], 50) == 42.0
    assert latency_bench.percentile([42.0], 95) == 42.0


def test_percentile_p50_median_odd():
    assert latency_bench.percentile([1, 2, 3, 4, 5], 50) == 3.0


def test_percentile_p50_median_even_interpolates():
    # nearest-rank interpolation between the two middle values
    assert latency_bench.percentile([1, 2, 3, 4], 50) == pytest.approx(2.5)


def test_percentile_p95_near_max():
    data = list(range(1, 101))  # 1..100
    p95 = latency_bench.percentile(data, 95)
    assert 94 <= p95 <= 100


def test_percentile_unsorted_input_is_sorted_first():
    assert latency_bench.percentile([5, 1, 3, 2, 4], 50) == 3.0


# ---------------------------------------------------------------------------
# summarize()
# ---------------------------------------------------------------------------

def test_summarize_scalar_spans():
    samples = {"ttft_ms": [100.0, 200.0, 300.0]}
    summary = latency_bench.summarize(samples)
    assert summary["ttft_ms"]["n"] == 3
    assert summary["ttft_ms"]["p50"] == 200.0


def test_summarize_flattens_list_spans():
    # tool_rtt_ms is a list per turn (one entry per tool call observed)
    samples = {"tool_rtt_ms": [[100.0, 150.0], [200.0], []]}
    summary = latency_bench.summarize(samples)
    assert summary["tool_rtt_ms"]["n"] == 3
    assert summary["tool_rtt_ms"]["p50"] == 150.0


def test_summarize_empty_span_has_none_percentiles():
    summary = latency_bench.summarize({"first_audio_ms": []})
    assert summary["first_audio_ms"]["n"] == 0
    assert summary["first_audio_ms"]["p50"] is None
    assert summary["first_audio_ms"]["p95"] is None


def test_summarize_ignores_none_entries():
    summary = latency_bench.summarize({"endpoint_ms": [100.0, None, 200.0]})
    assert summary["endpoint_ms"]["n"] == 2


# ---------------------------------------------------------------------------
# render_table()
# ---------------------------------------------------------------------------

def test_render_table_has_header_and_rows():
    summary = latency_bench.summarize({"ttft_ms": [100.0, 200.0], "stt_ms": []})
    table = latency_bench.render_table(summary)
    lines = table.splitlines()
    assert "span" in lines[0] and "p50_ms" in lines[0] and "p95_ms" in lines[0]
    assert any("ttft_ms" in line for line in lines)
    assert any("stt_ms" in line and " - " in f" {line} " for line in lines)  # empty span shows "-"


def test_render_table_rows_sorted_by_span_name():
    summary = latency_bench.summarize({"ttft_ms": [1.0], "endpoint_ms": [1.0], "stt_ms": [1.0]})
    table = latency_bench.render_table(summary)
    lines = [l for l in table.splitlines() if l and not l.startswith("-") and "span" not in l]
    names = [l.split()[0] for l in lines]
    assert names == sorted(names)


# ---------------------------------------------------------------------------
# merge_latency_frames()
# ---------------------------------------------------------------------------

def test_merge_latency_frames_collects_per_turn_samples():
    frames = [
        {"spans": {"ttft_ms": 100.0, "stt_ms": 50.0}},
        {"spans": {"ttft_ms": 150.0}},
        {"spans": {}},
    ]
    samples = latency_bench.merge_latency_frames(frames)
    assert samples["ttft_ms"] == [100.0, 150.0]
    assert samples["stt_ms"] == [50.0]
    assert samples["endpoint_ms"] == []


def test_merge_latency_frames_handles_empty_list():
    samples = latency_bench.merge_latency_frames([])
    assert all(v == [] for v in samples.values())


# ---------------------------------------------------------------------------
# CLI: --help works with zero dependencies and no server (module import above
# already proves the module itself never touches websocket-client or a
# network socket at import time; this proves argparse wiring is sane too).
# ---------------------------------------------------------------------------

def test_build_parser_help_does_not_require_network(capsys):
    parser = latency_bench._build_parser()
    with pytest.raises(SystemExit) as exc:
        parser.parse_args(["--help"])
    assert exc.value.code == 0
    out = capsys.readouterr().out
    assert "--turns" in out and "--baseline" in out


def test_main_without_url_fails_fast_with_exit_code_2(monkeypatch, capsys):
    monkeypatch.delenv("JC_BENCH_URL", raising=False)
    rc = latency_bench.main([])
    assert rc == 2
    assert "no server URL" in capsys.readouterr().err


def test_make_canned_wav_is_valid_wav():
    import wave
    import io as _io
    data = latency_bench._make_canned_wav(seconds=0.5, sample_rate=16000)
    with wave.open(_io.BytesIO(data), "rb") as wf:
        assert wf.getframerate() == 16000
        assert wf.getnchannels() == 1
        assert wf.getnframes() == 8000
