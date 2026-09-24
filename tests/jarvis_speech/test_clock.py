"""Stream time → session time when only speech is uploaded."""
from jarvis_speech.clock import ClockMap


def test_contiguous_audio_maps_straight():
    c = ClockMap()
    assert c.place(1000, 5000) == 0
    assert c.to_session(0) == 5000 and c.to_session(999) == 5999


def test_gap_inserts_capped_silence_mapped_onto_the_gap():
    c = ClockMap()
    c.place(1000, 0)              # 0..1000
    silence = c.place(500, 4000)  # a gap of 3000 ms
    assert silence == 600
    assert c.to_session(1000) == 1000  # the silence starts where speech stopped
    assert c.to_session(1600) == 4000  # speech resumes at its real time
    assert c.to_session(1700) == 4100


def test_small_gap_no_silence():
    c = ClockMap()
    c.place(1000, 0)
    assert c.place(100, 1200) == 0
    assert c.to_session(1000) == 1200


def test_backwards_timestamp_is_treated_as_contiguous():
    c = ClockMap()
    c.place(1000, 10_000)
    assert c.place(100, 2_000) == 0
    assert c.to_session(1050) == 11_050


def test_no_timestamps_is_identity_from_zero():
    c = ClockMap()
    c.place(300, None)
    c.place(300, None)
    assert c.to_session(450) == 450


def test_empty_map_is_identity():
    assert ClockMap().to_session(1234) == 1234
