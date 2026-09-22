"""Server-side speaker identification: the promises it has to keep.

Three things are worth testing here and the rest is noise.

**The fbank's structural choices**, because a spike measured that getting them
wrong fails quietly: a librosa/Slaney-shaped mel bank scored 0.58 against a
correct frontend, forgetting CMN 0.52, a 20 ms window 0.98 — while ±0.01 of
numeric noise cost 0.00004. So these tests pin the STRUCTURE (a 512-point FFT
on a 400-sample window, 80 unnormalised Kaldi triangles, int16-scale samples,
CMN applied) and deliberately do not assert on float values, which is the axis
that does not matter.

**The two thresholds**, because they are the whole of design §5.2: above high
confirm, below low mint, in between hold the vector and decide when more audio
arrives.

**That none of it can hurt capture.** No onnxruntime, no checkpoint, a model
that raises — each has to degrade to None and leave the transcript alone.
Design §8: capture is the floor.
"""
from __future__ import annotations

import json
import math
import sys
import types
import wave
from urllib.parse import urlparse

import pytest

from api import config as api_config
from api import live_config, live_store, live_voiceprint, live_ws
from api import models as api_models

np = pytest.importorskip("numpy")


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(api_config, "STATE_DIR", tmp_path)
    sessions = tmp_path / "sessions"
    sessions.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(api_models, "SESSION_DIR", sessions)
    monkeypatch.setattr(api_models, "SESSION_INDEX_FILE", sessions / "_index.json")
    monkeypatch.setenv("HERMES_CONFIG_PATH", str(tmp_path / "config.yaml"))
    api_config.reload_config()
    monkeypatch.setattr(live_ws, "_server_stt_cache", False)
    live_store.reset_for_tests()
    live_voiceprint.reset_for_tests()
    live_ws.reset_identification_reports_for_tests()
    yield tmp_path
    assert live_ws.drain_identification(5.0), \
        "an identification job outlived its test"
    live_ws.close_writers()
    live_store.reset_for_tests()
    live_voiceprint.reset_for_tests()
    api_config.reload_config()


@pytest.fixture(autouse=True)
def stubbed_watchers(monkeypatch):
    """The real watchers arm timers and call models; capture tests must not."""
    module = types.ModuleType("api.live_watchers")
    module.on_segment_appended = lambda sid, seq: None
    module.on_session_ended = lambda sid: None
    monkeypatch.setitem(sys.modules, "api.live_watchers", module)


# ── harness ────────────────────────────────────────────────────────────────


def _basis(index: int):
    """One axis of the embedding space, as a unit vector."""
    vec = np.zeros(live_voiceprint.EMBED_DIM, dtype=np.float64)
    vec[index] = 1.0
    return [float(v) for v in vec]


def _mixed(target: float, other_axis: int, main_axis: int = 0):
    """A unit vector whose cosine with `_basis(main_axis)` is exactly `target`."""
    vec = np.zeros(live_voiceprint.EMBED_DIM, dtype=np.float64)
    vec[main_axis] = target
    vec[other_axis] = math.sqrt(max(0.0, 1.0 - target * target))
    return [float(v) for v in vec]


def _known_voice(vec=None):
    speaker = live_store.create_speaker(kind="other", name="Known")
    live_store.add_embedding(speaker["id"], vec or _basis(0),
                             live_voiceprint.model_id(), "test")
    return speaker["id"]


def _tone(ms: int, hz: float = 220.0, rate: int = 16000, amp: int = 8000):
    """Deterministic int16 PCM. Content is irrelevant; length and scale are not."""
    n = int(rate * ms / 1000)
    t = np.arange(n, dtype=np.float64) / rate
    samples = (amp * np.sin(2 * math.pi * hz * t)).astype("<i2")
    return samples.tobytes()


class _Client:
    def __init__(self):
        self.frames = []

    def __call__(self, frame):
        self.frames.append(frame)


def _connect_edge(**hello):
    """A real edge-lane handshake: on-device STT plus a matching embedder id."""
    conn = live_ws.LiveConnection(_Client())
    payload = {"t": "hello", "device_id": "iphone-17pm", "device_kind": "ios",
               "caps": {"audio": "stream", "text": "stream", "stt": "on_device",
                        "embed": "on_device",
                        "embed_model": live_config.DEFAULTS["embed_model"],
                        "codec": "opus", "rate": 16000, "speak": True}}
    payload.update(hello)
    conn.on_text(json.dumps(payload))
    return conn, conn.live_session_id


def _as_samples(pcm: bytes):
    return np.frombuffer(pcm, dtype="<i2")


def _opus_packets(pcm: bytes, rate: int = 16000):
    """Encode PCM the way a phone does, so the test exercises the real decoder."""
    voice_opus = pytest.importorskip("api.voice_opus")
    if voice_opus.available() is not None:
        pytest.skip(f"libopus unavailable: {voice_opus.available()}")
    return voice_opus.OpusEncoder(sample_rate=rate, channels=1).encode(pcm)


def _start_session(**body):
    handler = _FakeHandler()
    assert live_ws.handle_live_post(handler, urlparse("/api/live/session/start"),
                                    body)
    assert handler.status == 200
    return handler.payload()


class _FakeHandler:
    def __init__(self):
        import io
        self.wfile = io.BytesIO()
        self.headers = {}
        self.status = None

    def send_response(self, status):
        self.status = status

    def send_header(self, key, value):
        pass

    def end_headers(self):
        pass

    def payload(self):
        return json.loads(self.wfile.getvalue().decode("utf-8"))


# ── the fbank's structural choices ─────────────────────────────────────────


def test_the_window_is_400_samples_and_the_fft_is_512_point():
    """The one the spike singles out: an ``n_fft=400`` implementation is WRONG.

    `round_to_power_of_two=True` zero-pads a 25 ms / 400-sample window out to
    512 before the transform, so the frame width and the transform length are
    different numbers. Asserted at the call rather than inferred from the
    output, because the output shape cannot tell the two apart.
    """
    seen = {}
    real_rfft = np.fft.rfft

    def spy(frames, n=None, axis=-1):
        seen["frame_width"] = frames.shape[-1]
        seen["n_fft"] = n
        return real_rfft(frames, n=n, axis=axis)

    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(np.fft, "rfft", spy)
        live_voiceprint.kaldi_fbank(
            np.frombuffer(_tone(1000), dtype="<i2").astype(np.float64), 16000)

    assert seen["frame_width"] == 400, "25 ms at 16 kHz is a 400-sample window"
    assert seen["n_fft"] == 512, "round_to_power_of_two pads 400 out to 512"


def test_the_feature_matrix_is_80_bins_by_a_10ms_hop():
    samples = np.frombuffer(_tone(1000), dtype="<i2").astype(np.float64)
    feats = live_voiceprint.kaldi_fbank(samples, 16000)
    # snip_edges=True: 1 + (N - 400) // 160, not a zero-padded frame per hop.
    assert feats.shape == (1 + (16000 - 400) // 160, 80)
    assert feats.dtype == np.float32


def test_audio_shorter_than_one_window_is_no_frames_at_all():
    """snip_edges=True. A zero-padded partial frame would be a different spec."""
    short = np.frombuffer(_tone(1000), dtype="<i2").astype(np.float64)[:399]
    assert live_voiceprint.kaldi_fbank(short, 16000) is None


def test_cepstral_mean_normalisation_is_applied():
    """Forgetting this scored 0.52 against a correct frontend."""
    samples = np.frombuffer(_tone(2000), dtype="<i2").astype(np.float64)
    feats = live_voiceprint.kaldi_fbank(samples, 16000)
    per_bin_mean = feats.mean(axis=0)
    assert np.abs(per_bin_mean).max() < 1e-4, \
        "every mel bin's mean across frames must be subtracted"


def test_the_mel_bank_is_kaldi_shaped_and_not_area_normalised():
    """The librosa/Slaney failure mode (0.58), pinned at the filterbank.

    Slaney normalisation divides each triangle by its width, which reweights
    the spectrum against what the model was trained on. Kaldi's triangles are
    unit-height, so filter width shows up in the row sums instead.
    """
    bank = live_voiceprint.mel_filterbank(80, 512, 16000)
    assert bank.shape == (80, 257), "80 filters over a 512-point rfft's output"
    # The triangles are unit-HEIGHT, so nothing exceeds 1.0. (No row reaches
    # exactly 1.0 — the FFT bins are 31.25 Hz apart and rarely land on a
    # triangle's apex — which is why the height alone cannot be the assertion.)
    assert bank.max() <= 1.0 + 1e-6
    # The real tell against area normalisation: unnormalised filters get
    # WIDER towards the top of the mel scale, so their row sums grow with
    # index. Slaney normalisation divides each by its width, which flattens
    # exactly this ratio to ~1 — and scored 0.58 against a correct frontend.
    sums = bank.sum(axis=1)
    assert sums[-1] > 5 * sums[0], \
        "row sums must grow with filter width; a flat profile means the bank " \
        "was area-normalised"
    # Kaldi lays the bank out over padded_window_size/2 bins and pads ONE zero
    # column to meet the rfft width, so the Nyquist bin contributes nothing.
    assert np.all(bank[:, -1] == 0.0)
    # low_freq=20: nothing below it may leak in. Bin 0 is DC.
    below_20hz = int(20.0 / (16000 / 512))
    assert np.all(bank[:, :below_20hz + 1] == 0.0)
    # Triangles are adjacent and ordered, in mel space not linear space.
    centres = [int(np.argmax(bank[i])) for i in range(80)]
    assert centres == sorted(centres) and centres[0] < centres[-1]


def test_the_model_is_fed_int16_scale_samples():
    """Kaldi's ``normalize=False``: do NOT divide by 32768.

    Asserted where the choice is made, because CMN cancels a global gain in the
    log domain — so comparing two finished feature matrices cannot see it, and
    a test that tried would pass against the wrong code.
    """
    captured = {}

    def spy(samples, rate=16000, num_bins=80):
        captured["peak"] = float(np.abs(np.asarray(samples)).max())
        return None  # embed() treats this as "not enough features"

    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(live_voiceprint, "load_session", lambda: object())
        patch.setattr(live_voiceprint, "kaldi_fbank", spy)
        live_voiceprint.embed(_tone(1000, amp=8000), 16000)

    assert captured["peak"] > 1000, \
        f"samples reached the fbank at scale {captured['peak']}, i.e. divided " \
        "by 32768 — Kaldi wants the int16 scale"


def test_the_per_frame_pipeline_is_exactly_the_documented_kaldi_order():
    """Restate the spec independently and require the code to match it.

    Order and constants are what the spike proved fatal: DC removal, then
    preemphasis at 0.97 with the FIRST SAMPLE REPLICATED, then a symmetric
    hamming window, then the zero-pad. Any permutation of these produces
    plausible-looking features and a broken embedding.
    """
    rng = np.random.default_rng(11)
    samples = rng.uniform(-8000, 8000, 400 + 160 * 4)

    n_frames = 1 + (samples.size - 400) // 160
    expected = np.empty((n_frames, 80), dtype=np.float64)
    bank = np.asarray(live_voiceprint.mel_filterbank(80, 512, 16000),
                      dtype=np.float64)
    for index in range(n_frames):
        frame = samples[index * 160:index * 160 + 400].copy()
        frame -= frame.mean()                                   # 1. DC
        shifted = np.concatenate([frame[:1], frame[:-1]])       # 2. replicate
        frame -= 0.97 * shifted                                 #    preemphasis
        frame *= np.hamming(400)                                # 3. hamming
        spectrum = np.abs(np.fft.rfft(frame, n=512)) ** 2       # 4. 512-pt, power
        expected[index] = np.log(np.maximum(spectrum @ bank.T,
                                            1.1920928955078125e-07))
    expected -= expected.mean(axis=0, keepdims=True)            # 5. CMN

    actual = live_voiceprint.kaldi_fbank(samples, 16000)
    assert np.abs(actual - expected).max() < 1e-3


# ── identification: the two thresholds of design §5.2 ─────────────────────


def test_the_thresholds_sit_between_the_measured_separation():
    """The numbers came from the spike: same speaker 0.65, different 0.18-0.25.

    A contract about how the two relate, not a snapshot: confirm must be clear
    of the different-speaker ceiling and below the same-speaker score, or one of
    the two decisions is unreachable.
    """
    assert 0.25 < live_voiceprint.SIM_NEW_SPEAKER
    assert live_voiceprint.SIM_NEW_SPEAKER < live_voiceprint.SIM_CONFIRM
    assert live_voiceprint.SIM_CONFIRM < 0.65


def test_the_same_voice_again_confirms_that_speaker():
    known = _known_voice()
    decision = live_voiceprint.identify(_basis(0), live_session_id="s", seq=1)
    assert decision["speaker_id"] == known
    assert decision["label_state"] == live_store.LABEL_CONFIRMED
    assert decision["new_speaker"] is False
    assert decision["score"] == pytest.approx(1.0, abs=1e-3)
    # The exemplar is kept: a centroid sharpens as a voice is heard more (§3).
    rows = live_store.embeddings_for_model(live_voiceprint.model_id())
    assert len([r for r in rows if r["speaker_id"] == known]) == 2


def test_an_unrelated_voice_mints_a_new_speaker():
    known = _known_voice()
    decision = live_voiceprint.identify(_basis(7), live_session_id="s", seq=1)
    assert decision["speaker_id"] != known
    assert decision["new_speaker"] is True
    # Definitively a voice not heard before, so the LABEL is settled even
    # though the voice has no name yet.
    assert decision["label_state"] == live_store.LABEL_CONFIRMED
    assert len(live_store.list_speakers()) == 2


def test_a_middling_match_stays_provisional_and_mints_nothing():
    known = _known_voice()
    middling = (live_voiceprint.SIM_NEW_SPEAKER
                + live_voiceprint.SIM_CONFIRM) / 2
    decision = live_voiceprint.identify(_mixed(middling, 5),
                                        live_session_id="s", seq=1)
    assert decision["speaker_id"] == known, "the best guess is still named"
    assert decision["label_state"] == live_store.LABEL_PROVISIONAL
    assert decision["new_speaker"] is False
    assert len(live_store.list_speakers()) == 1, "no speaker invented on a maybe"
    # And the uncertain vector is NOT written into the centroid: a maybe must
    # not pull a known voice towards a second person.
    rows = live_store.embeddings_for_model(live_voiceprint.model_id())
    assert len(rows) == 1


def test_a_second_middling_utterance_promotes_the_held_group():
    """§5.2's "decide when more audio arrives", concretely.

    Two vectors at 0.40 average to 0.525 against the centroid, because
    averaging unit vectors cancels the part of each that points away. The whole
    held group is then confirmed at once.
    """
    known = _known_voice()
    first = live_voiceprint.identify(_mixed(0.40, 5), live_session_id="s", seq=1)
    assert first["label_state"] == live_store.LABEL_PROVISIONAL

    second = live_voiceprint.identify(_mixed(0.40, 9), live_session_id="s", seq=2)
    assert second["speaker_id"] == known
    assert second["label_state"] == live_store.LABEL_CONFIRMED
    assert second["score"] >= live_voiceprint.SIM_CONFIRM
    # Both utterances, including the earlier one already on screen.
    assert sorted(second["promoted"]) == [("s", 1), ("s", 2)]
    assert len(live_store.list_speakers()) == 1


def test_two_stored_voices_that_are_one_person_get_merged():
    """§5.2's retroactive merge, on the conservative condition it needs.

    Two centroids clearing the confirm threshold against EACH OTHER is the
    evidence; one utterance matching both is only ambiguity.
    """
    older = _known_voice(_basis(0))
    newer = live_store.create_speaker(kind="other")["id"]
    live_store.add_embedding(newer, _mixed(0.97, 3), live_voiceprint.model_id(),
                             "test")
    decision = live_voiceprint.identify(_basis(0), live_session_id="s", seq=1)
    assert decision["merged_from"] == newer
    assert decision["speaker_id"] == older, "the OLDER id survives a merge"
    assert [s["id"] for s in live_store.list_speakers()] == [older]


def test_distinct_voices_are_never_merged():
    _known_voice(_basis(0))
    other = live_store.create_speaker(kind="other")["id"]
    live_store.add_embedding(other, _basis(11), live_voiceprint.model_id(), "t")
    decision = live_voiceprint.identify(_basis(0), live_session_id="s", seq=1)
    assert decision["merged_from"] is None
    assert len(live_store.list_speakers()) == 2


def test_rows_from_another_checkpoint_are_never_compared():
    """The interlock (§5.3). A vector of a different width is a different model."""
    speaker = live_store.create_speaker(kind="other")["id"]
    live_store.add_embedding(speaker, [0.5] * 192, live_voiceprint.model_id(),
                             "ecapa-shaped")
    assert live_voiceprint.centroids() == {}
    decision = live_voiceprint.identify(_basis(0), live_session_id="s", seq=1)
    assert decision["new_speaker"] is True


def test_the_model_id_is_the_one_the_interlock_gates_on():
    assert live_voiceprint.MODEL_ID == live_config.DEFAULTS["embed_model"]
    assert "resnet" in live_voiceprint.MODEL_ID, \
        "the id must name the architecture it actually is"
    assert live_voiceprint.model_id() == live_config.load()["embed_model"]


# ── degrading without the extra, the model, or a working session ──────────


def test_no_onnxruntime_means_no_capability_and_no_embedding(monkeypatch):
    monkeypatch.setattr(live_voiceprint, "_onnxruntime_importable", lambda: False)
    assert live_voiceprint.available() is False
    assert live_voiceprint.can_try() is False
    assert live_voiceprint.embed(_tone(2000), 16000) is None
    assert live_ws.server_caps()["embed"] is False


def test_a_missing_checkpoint_is_not_a_capability_but_is_worth_trying(monkeypatch):
    """`available()` answers the handshake; `can_try()` decides whether to queue.

    They must differ on a fresh install, or the job that downloads the
    checkpoint is the job that never runs.
    """
    monkeypatch.setattr(live_voiceprint, "_onnxruntime_importable", lambda: True)
    assert live_voiceprint.available() is False
    assert live_voiceprint.can_try() is True


def test_a_failed_download_degrades_to_none_and_backs_off(monkeypatch):
    monkeypatch.setattr(live_voiceprint, "_onnxruntime_importable", lambda: True)
    calls = []

    def refuse(path):
        calls.append(path)
        return False

    monkeypatch.setattr(live_voiceprint, "_download_model", refuse)
    assert live_voiceprint.load_session() is None
    assert live_voiceprint.embed(_tone(2000), 16000) is None
    # Backed off: an unreachable network is a steady state, not a per-utterance
    # retry.
    assert live_voiceprint.can_try() is False
    assert len(calls) == 1


def test_a_model_that_raises_never_escapes_into_the_caller(monkeypatch):
    class Exploding:
        def run(self, *_args, **_kwargs):
            raise RuntimeError("the runtime said no")

    monkeypatch.setattr(live_voiceprint, "load_session", lambda: Exploding())
    assert live_voiceprint.embed(_tone(2000), 16000) is None


def test_a_model_returning_the_wrong_width_is_refused(monkeypatch):
    class Wrong:
        def run(self, *_args, **_kwargs):
            return [np.zeros((1, 192), dtype=np.float32)]

    monkeypatch.setattr(live_voiceprint, "load_session", lambda: Wrong())
    assert live_voiceprint.embed(_tone(2000), 16000) is None


def test_audio_too_short_to_carry_a_voice_is_refused(monkeypatch):
    monkeypatch.setattr(live_voiceprint, "load_session", lambda: object())
    assert live_voiceprint.embed(_tone(200), 16000) is None
    assert live_voiceprint.embed(b"", 16000) is None
    assert live_voiceprint.embed(b"\x00", 16000) is None


def test_capture_still_works_with_identification_entirely_unavailable(monkeypatch):
    """The floor (§8): no extra, no model, and the transcript is unaffected."""
    monkeypatch.setattr(live_voiceprint, "_onnxruntime_importable", lambda: False)
    session = _start_session(device_id="pod-1")
    sid = session["live_session_id"]
    row = live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=2000,
                                     text="the recorder does not care",
                                     device_id="pod-1")
    assert row["seq"] == 1
    stored = live_store.segments_after(sid, 0)
    assert [s["text"] for s in stored] == ["the recorder does not care"]
    assert stored[0]["speaker_id"] is None
    assert stored[0]["label_state"] == live_store.LABEL_PROVISIONAL


def test_an_identification_that_explodes_does_not_lose_the_utterance(monkeypatch):
    monkeypatch.setattr(live_voiceprint, "can_try", lambda: True)
    monkeypatch.setattr(live_voiceprint, "embed",
                        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("no")))
    session = _start_session(device_id="pod-1")
    sid = session["live_session_id"]
    live_ws.ingest_audio_chunk(sid, _tone(3000), ts_ms=0, device_id="pod-1",
                               codec="pcm16", rate=16000)
    row = live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=2000,
                                     text="still here", device_id="pod-1")
    assert live_ws.drain_identification(5.0)
    assert live_store.segments_after(sid, 0)[0]["text"] == "still here"
    assert row["seq"] == 1


# ── reading one utterance's audio back out of the stored chunk ────────────


def test_the_audio_for_an_utterance_is_the_matching_region_of_the_chunk():
    session = _start_session(device_id="pod-1")
    sid = session["live_session_id"]
    live_ws.ingest_audio_chunk(sid, _tone(5000), ts_ms=0, device_id="pod-1",
                               codec="pcm16", rate=16000)
    found = live_ws.pcm_for_range(sid, 1000, 3000, "pod-1")
    assert found is not None
    pcm, rate = found
    assert rate == 16000
    # Two seconds of 16 kHz mono int16, read from the still-OPEN chunk: a chunk
    # is five minutes and an utterance is seconds, so waiting for the roll
    # would identify nothing until the recording was nearly over.
    assert len(pcm) == 2 * 16000 * 2


def test_an_opus_chunk_is_decoded_back_into_samples():
    """THE case that matters: the iPhone streams Opus, not PCM.

    The first deployment of this feature recognised only `pcm16`, so every real
    recording returned None here, the job exited before reaching the model, and
    identification silently never ran — on the only device that exists.
    """
    session = _start_session(device_id="iphone")
    sid = session["live_session_id"]
    for packet in _opus_packets(_tone(4000), rate=16000):
        live_ws.ingest_audio_chunk(sid, packet, ts_ms=0, device_id="iphone",
                                   codec="opus", rate=16000)
    found = live_ws.pcm_for_range(sid, 500, 2500, "iphone")
    assert found is not None, "an Opus chunk must decode back to samples"
    pcm, rate = found
    assert rate == 16000, "decoded straight to the rate the model wants"
    # Two seconds, within a frame's rounding either way.
    assert abs(len(pcm) - 2 * 16000 * 2) < 16000 * 2 * 0.1
    assert max(abs(v) for v in _as_samples(pcm)) > 100, "decoded to real audio"


def test_an_unknown_codec_still_yields_nothing_rather_than_garbage():
    """A codec the server cannot turn back into samples must decline, not feed
    the model packet headers."""
    session = _start_session(device_id="odd")
    sid = session["live_session_id"]
    live_ws.ingest_audio_chunk(sid, _tone(4000), ts_ms=0, device_id="odd",
                               codec="some-future-codec", rate=16000)
    assert live_ws.pcm_for_range(sid, 0, 2000, "odd") is None


# ── the wiring: a segment becomes a labelled voice, off the capture thread ─


def test_a_segment_with_audio_gets_a_speaker_and_the_clients_are_told(monkeypatch):
    monkeypatch.setattr(live_voiceprint, "can_try", lambda: True)
    monkeypatch.setattr(live_voiceprint, "load_session", lambda: object())
    monkeypatch.setattr(live_voiceprint, "embed",
                        lambda pcm, rate: _basis(0))
    session = _start_session(device_id="pod-1")
    sid = session["live_session_id"]
    live_ws.ingest_audio_chunk(sid, _tone(4000), ts_ms=0, device_id="pod-1",
                               codec="pcm16", rate=16000)

    viewer = live_ws.subscribe(sid)
    try:
        live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=2000,
                                   text="hello there", device_id="pod-1")
        assert live_ws.drain_identification(5.0)
        frames = []
        while not viewer.empty():
            frames.append(viewer.get_nowait())
    finally:
        live_ws.unsubscribe(sid, viewer)

    speakers = live_store.list_speakers()
    assert len(speakers) == 1, "the Voices screen finally has a row in it"
    speaker_id = speakers[0]["id"]

    stored = live_store.segments_after(sid, 0)[0]
    assert stored["speaker_id"] == speaker_id
    assert stored["label_state"] == live_store.LABEL_CONFIRMED

    # The re-published `seg` is how a chip appears at all: both shipped clients
    # upsert a segment by `seq`.
    segs = [data for event, data in frames if event == "seg"]
    assert segs[-1]["speaker_id"] == speaker_id
    assert segs[-1]["label_state"] == live_store.LABEL_CONFIRMED
    assert segs[0]["speaker_id"] is None, "identification is not synchronous"

    ops = [data for event, data in frames if event == "speaker"]
    assert [o["op"] for o in ops] == ["confirm"]
    assert ops[0]["speaker_id"] == speaker_id
    assert ops[0]["seqs"] == [1]
    assert ops[0]["new_speaker"] is True


def test_an_edge_lane_segment_with_opus_audio_gets_identified(monkeypatch):
    """The regression that reached production, end to end.

    An iPhone on the EDGE lane transcribes on-device and sends finished `seg`
    frames while streaming Opus alongside. Identification has to fire for that
    segment — the trigger is "a segment was appended and audio covering its
    time range exists", NOT "the server transcribed something". This drives the
    real `LiveConnection` seg path with real Opus bytes; only the model itself
    is stubbed.
    """
    monkeypatch.setattr(live_voiceprint, "can_try", lambda: True)
    monkeypatch.setattr(live_voiceprint, "load_session", lambda: object())
    seen = {}

    def fake_embed(pcm, rate):
        seen["samples"] = len(pcm) // 2
        seen["rate"] = rate
        return _basis(0)

    monkeypatch.setattr(live_voiceprint, "embed", fake_embed)

    conn, sid = _connect_edge()
    # Audio first, exactly as a streaming phone does it.
    for packet in _opus_packets(_tone(4000), rate=16000):
        conn.on_binary(live_ws.encode_audio_frame(1, 0, packet))
    # Then the finished utterance the phone transcribed itself.
    conn.on_text(json.dumps({"t": "seg", "partial": False, "text": "hello there",
                             "ts_start_ms": 500, "ts_end_ms": 3000,
                             "local_label": "me"}))
    assert live_ws.drain_identification(10.0)

    assert conn.lane == live_ws.LANE_EDGE, "this is the edge lane"
    assert seen.get("rate") == 16000, "Opus decoded straight to the model's rate"
    assert seen.get("samples", 0) > 16000, "a real span of audio reached the model"

    speakers = live_store.list_speakers()
    assert len(speakers) == 1, "an edge-lane segment must produce a voice"
    stored = live_store.segments_after(sid, 0)[0]
    assert stored["speaker_id"] == speakers[0]["id"]
    assert stored["label_state"] == live_store.LABEL_CONFIRMED


def test_the_first_attempt_says_at_info_what_it_actually_did(monkeypatch, caplog):
    """A silent no-op is how the broken version shipped looking fine.

    The first deployment recognised only `pcm16`, so every real recording was
    skipped without a single line at any level — indistinguishable in the
    journal from a working feature. Each distinct outcome now surfaces once at
    INFO, and it has to name the reason well enough to act on.
    """
    import logging
    live_ws.reset_identification_reports_for_tests()
    monkeypatch.setattr(live_voiceprint, "can_try", lambda: True)
    monkeypatch.setattr(live_voiceprint, "load_session", lambda: object())
    session = _start_session(device_id="pod-1")
    sid = session["live_session_id"]
    # A segment with no audio stored for it at all.
    with caplog.at_level(logging.INFO, logger="api.live_ws"):
        live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=2000,
                                   text="nothing recorded", device_id="pod-1")
        assert live_ws.drain_identification(5.0)

    lines = [r.getMessage() for r in caplog.records if r.levelno >= logging.INFO]
    skips = [line for line in lines if "speaker identification skipped" in line]
    assert skips, f"the skip must be visible at INFO; got {lines}"
    assert "no readable audio" in skips[0]
    # And it must say what WAS stored, so "wrong codec" is diagnosable.
    assert "codecs" in skips[0]


def test_the_outcome_is_only_announced_once_per_reason(monkeypatch, caplog):
    """Bounded: a per-utterance INFO line would be its own incident."""
    import logging
    live_ws.reset_identification_reports_for_tests()
    monkeypatch.setattr(live_voiceprint, "can_try", lambda: True)
    monkeypatch.setattr(live_voiceprint, "load_session", lambda: object())
    session = _start_session(device_id="pod-1")
    sid = session["live_session_id"]
    with caplog.at_level(logging.INFO, logger="api.live_ws"):
        for index in range(4):
            live_ws.append_and_publish(sid, ts_start_ms=index * 3000,
                                       ts_end_ms=index * 3000 + 2000,
                                       text=f"utterance {index}",
                                       device_id="pod-1")
        assert live_ws.drain_identification(5.0)
    skips = [r.getMessage() for r in caplog.records
             if r.levelno >= logging.INFO
             and "no readable audio" in r.getMessage()]
    assert len(skips) == 1, f"one line per reason, not per utterance: {skips}"


def test_a_provisional_decision_sends_no_confirm_frame(monkeypatch):
    """Both shipped clients mark rows confirmed unconditionally on a `confirm`,
    so sending one for a middling match would overstate it. The `seg` frame
    carries the provisional label instead."""
    known = _known_voice()
    monkeypatch.setattr(live_voiceprint, "can_try", lambda: True)
    monkeypatch.setattr(live_voiceprint, "load_session", lambda: object())
    monkeypatch.setattr(live_voiceprint, "embed", lambda pcm, rate: _mixed(0.40, 5))
    session = _start_session(device_id="pod-1")
    sid = session["live_session_id"]
    live_ws.ingest_audio_chunk(sid, _tone(4000), ts_ms=0, device_id="pod-1",
                               codec="pcm16", rate=16000)

    viewer = live_ws.subscribe(sid)
    try:
        live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=2000,
                                   text="mumble", device_id="pod-1")
        assert live_ws.drain_identification(5.0)
        frames = []
        while not viewer.empty():
            frames.append(viewer.get_nowait())
    finally:
        live_ws.unsubscribe(sid, viewer)

    assert not [d for e, d in frames if e == "speaker"]
    seg = [d for e, d in frames if e == "seg"][-1]
    assert seg["speaker_id"] == known
    assert seg["label_state"] == live_store.LABEL_PROVISIONAL
    assert 0 < seg["speaker_conf"] < live_voiceprint.SIM_CONFIRM


def test_a_segment_a_device_already_attributed_is_left_alone(monkeypatch):
    """An edge device whose voiceprints the interlock trusts owns the label."""
    called = []
    monkeypatch.setattr(live_voiceprint, "can_try",
                        lambda: called.append(1) or True)
    session = _start_session(device_id="iphone")
    sid = session["live_session_id"]
    speaker = live_store.create_speaker(kind="me", name="Me")["id"]
    live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=2000, text="mine",
                               speaker_id=speaker, device_id="iphone")
    assert live_ws.drain_identification(5.0)
    assert not called, "identification must not fight the device for the label"


def test_identification_never_runs_on_the_capture_thread(monkeypatch):
    """The recorder must not wait on a model. Proven by blocking the embedder
    and requiring the append to return anyway."""
    import threading
    released = threading.Event()
    entered = threading.Event()

    def blocking(pcm, rate):
        entered.set()
        released.wait(5)
        return None

    monkeypatch.setattr(live_voiceprint, "can_try", lambda: True)
    monkeypatch.setattr(live_voiceprint, "load_session", lambda: object())
    monkeypatch.setattr(live_voiceprint, "embed", blocking)
    session = _start_session(device_id="pod-1")
    sid = session["live_session_id"]
    live_ws.ingest_audio_chunk(sid, _tone(4000), ts_ms=0, device_id="pod-1",
                               codec="pcm16", rate=16000)
    try:
        row = live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=2000,
                                         text="do not block me",
                                         device_id="pod-1")
        assert entered.wait(5), "identification should have started"
        assert row["seq"] == 1, "the append returned while the embedder was busy"
    finally:
        released.set()


# ── enrolling "me" from audio that already exists (design §5.4) ───────────


def _write_wav(path, ms=2000, rate=16000):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(_tone(ms, rate=rate))


def test_me_is_enrolled_from_stored_voice_turns(monkeypatch, tmp_path):
    from api import voice_recordings

    monkeypatch.setattr(voice_recordings, "RECORDINGS_DIR",
                        tmp_path / "voice_recordings")
    _write_wav(tmp_path / "voice_recordings" / "pod-1" / "1757900000123.wav")
    _write_wav(tmp_path / "voice_recordings" / "pod-1" / "1757900000456.wav")
    monkeypatch.setattr(live_voiceprint, "embed", lambda pcm, rate: _basis(0))

    report = live_voiceprint.enrol_me_from_voice_recordings()
    assert report["enrolled"] == 2
    me = [s for s in live_store.list_speakers() if s["kind"] == "me"]
    assert len(me) == 1 and me[0]["name"] == "Me"
    rows = live_store.embeddings_for_model(live_voiceprint.model_id())
    assert len(rows) == 2


