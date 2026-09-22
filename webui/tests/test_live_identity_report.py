"""The identity report's two judgements, which are the whole point of it.

Not the printing and not the embedding — the arithmetic that decides whether a
run is worth reading (are the spans real?) and whether the voices are actually
separable (is there a gap to put a threshold in?). Those two numbers are what
made the difference between "identification is working" and "identification has
been labelling fifteen seconds of room tone".
"""
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "live_identity_report.py"
spec = importlib.util.spec_from_file_location("live_identity_report", SCRIPT)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def _rows(*spans):
    """Segment rows with the given durations, starting back to back."""
    out, cursor = [], 0
    for span in spans:
        out.append({"ts_start_ms": cursor, "ts_end_ms": cursor + span,
                    "speaker_id": "", "device_id": "", "text": "x"})
        cursor += span + 500
    return out


def test_spans_pinned_at_the_chunking_cap_are_counted_as_such():
    """The signature of the bug: 15.00-15.08 s whatever was said, because the
    gates never closed and only the cap ever ended an utterance."""
    spans = report.span_report(_rows(15000, 15050, 15080, 2100))

    assert spans["at_cap"] == 3
    assert spans["at_cap_share"] == 0.75
    assert spans["at_cap_share"] >= report.CAP_SHARE_ALARM, \
        "a run this pinned has to read as broken, not as borderline"


def test_real_utterances_do_not_read_as_pinned():
    spans = report.span_report(_rows(2120, 5120, 900, 3300))

    assert spans["at_cap"] == 0
    assert spans["median_ms"] == 2710
    assert spans["min_ms"] == 900 and spans["max_ms"] == 5120


def test_a_long_utterance_that_is_not_at_the_cap_is_not_flagged():
    """14 s of someone genuinely talking is not the same fault as 15.05 s of a
    gate that never closed."""
    assert report.span_report(_rows(14000))["at_cap"] == 0


def test_spans_with_no_duration_do_not_divide_by_zero():
    assert report.span_report([])["count"] == 0
    assert report.span_report(_rows(0, 0))["count"] == 0


def test_the_margin_is_the_gap_between_the_worst_match_and_the_best_mismatch(
        monkeypatch):
    """A threshold can only exist in that gap. Comparing MEANS would call these
    voices separable while their populations overlap."""
    # Two vectors for speaker A that score 0.6 against each other, one for B
    # that scores 0.7 against one of A's — so the means look fine and the
    # populations do not separate.
    handed = iter([[1.0, 0.0], [0.9, 0.1], [0.0, 1.0]])
    scores = {(1.0, 0.9): 0.6, (1.0, 0.0): 0.7, (0.9, 0.0): 0.2}

    monkeypatch.setattr(report.live_ws, "pcm_for_range",
                        lambda sid, s, e, dev: (b"\0\0", 16000))
    monkeypatch.setattr(report.live_voiceprint, "embed",
                        lambda pcm, rate: next(handed))
    monkeypatch.setattr(report.live_voiceprint, "cosine",
                        lambda a, b: scores[(a[0], b[0])])

    out = report.pair_report("s1", [
        {"ts_start_ms": 0, "ts_end_ms": 1000, "speaker_id": "A", "device_id": ""},
        {"ts_start_ms": 2000, "ts_end_ms": 3000, "speaker_id": "A", "device_id": ""},
        {"ts_start_ms": 4000, "ts_end_ms": 5000, "speaker_id": "B", "device_id": ""},
    ])

    assert out["same_pairs"] == 1 and out["different_pairs"] == 2
    assert out["same_min"] == 0.6 and out["different_max"] == 0.7
    assert out["margin"] == -0.1, "overlapping populations read as negative"


def test_a_session_with_one_voice_reports_no_margin(monkeypatch):
    """Nothing to separate from, so claiming a margin would be inventing one."""
    monkeypatch.setattr(report.live_ws, "pcm_for_range",
                        lambda sid, s, e, dev: (b"\0\0", 16000))
    monkeypatch.setattr(report.live_voiceprint, "embed", lambda pcm, rate: [1.0])
    monkeypatch.setattr(report.live_voiceprint, "cosine", lambda a, b: 0.7)

    out = report.pair_report("s1", [
        {"ts_start_ms": 0, "ts_end_ms": 1000, "speaker_id": "A", "device_id": ""},
        {"ts_start_ms": 2000, "ts_end_ms": 3000, "speaker_id": "A", "device_id": ""},
    ])

    assert out["same_pairs"] == 1
    assert "margin" not in out


def test_segments_with_no_speaker_or_no_audio_are_skipped(monkeypatch):
    """Both are ordinary states — a window that identified nobody, and a chunk
    already deleted — and neither may be counted as a measurement."""
    monkeypatch.setattr(report.live_ws, "pcm_for_range",
                        lambda sid, s, e, dev: None)
    monkeypatch.setattr(report.live_voiceprint, "embed",
                        lambda pcm, rate: [1.0])

    out = report.pair_report("s1", [
        {"ts_start_ms": 0, "ts_end_ms": 1000, "speaker_id": "", "device_id": ""},
        {"ts_start_ms": 2000, "ts_end_ms": 3000, "speaker_id": "A", "device_id": ""},
    ])

    assert out["embedded"] == 0
    assert out["same_pairs"] == 0 and out["different_pairs"] == 0


def test_a_session_files_every_segment_under_the_voice_its_audio_matches(
        monkeypatch):
    """The question "is identification working" — which is NOT the question
    "are these two voices far apart". One person recorded two ways answers
    badly to the second and perfectly to the first."""
    monkeypatch.setattr(report.live_voiceprint, "centroids",
                        lambda: {"A": [1.0, 0.0], "B": [0.0, 1.0]})
    monkeypatch.setattr(report.live_voiceprint, "cosine",
                        lambda a, b: 1.0 - abs(a[0] - b[0]))

    out = report.agreement([("A", [1.0, 0.0]), ("B", [0.0, 1.0]),
                            ("A", [0.9, 0.1])])

    assert out["filed_agreed"] == 3
    assert out["filed_share"] == 1.0


def test_a_segment_that_matches_another_voice_better_is_counted_against(
        monkeypatch):
    monkeypatch.setattr(report.live_voiceprint, "centroids",
                        lambda: {"A": [1.0, 0.0], "B": [0.0, 1.0]})
    monkeypatch.setattr(report.live_voiceprint, "cosine",
                        lambda a, b: 1.0 - abs(a[0] - b[0]))

    out = report.agreement([("A", [0.0, 1.0]), ("B", [0.0, 1.0])])

    assert out["filed_agreed"] == 1
    assert out["filed_share"] == 0.5


def test_no_voices_on_file_means_no_agreement_claim(monkeypatch):
    """Nothing to file against, so reporting 100% would be reporting nothing
    as if it were something."""
    monkeypatch.setattr(report.live_voiceprint, "centroids", lambda: {})

    assert report.agreement([("A", [1.0])]) == {}

