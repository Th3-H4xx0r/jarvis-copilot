"""Server-side speaker identification for Live Jarvis (design §5.2, §5.3, §5.4).

The transcript half of Live Jarvis works; this is the other half — turning an
utterance's audio into a voiceprint and deciding *whose* voice it is, so
`speaker` rows exist, the Voices screen has something in it, and a segment can
graduate from provisional to confirmed.

**Everything here is optional by construction.** `onnxruntime` is an extra, the
26 MB checkpoint is downloaded on first use rather than committed, and either
can be absent. When they are, `embed()` returns None, `available()` is False,
and capture carries on untouched — design §8: capture is the floor. Nothing in
this module may raise into the capture path.

The model
---------
WeSpeaker ``voxceleb_resnet34_LM`` (Apache-2.0 code, CC-BY-4.0 ungated weights,
6.64 M params). The published ONNX takes ``feats [B, T, 80]`` and returns
``embs [B, 256]``.

The frontend is the risk, and it was measured
---------------------------------------------
This model wants **Kaldi** fbank, and a plausible-looking port fails quietly
rather than loudly. Measured against a correct implementation, on a scale where
±0.01 of numeric noise costs 0.00004:

* a librosa / Slaney-normalised mel filterbank → 0.58
* forgetting cepstral mean normalisation → 0.52
* HTK mel without Kaldi's quirks → 0.93
* a 20 ms window instead of 25 ms → 0.98

So small numeric error is harmless and STRUCTURAL choices are fatal. The five
that matter, all reproduced below and each pinned by a test:

1. **int16-scale samples** — Kaldi's ``normalize=False``. Do NOT divide by
   32768. (WeSpeaker's own pipeline multiplies a float waveform by ``1 << 15``
   to get back here.)
2. **a 512-point FFT on a 400-sample window** — ``round_to_power_of_two=True``
   zero-pads 25 ms @ 16 kHz out to the next power of two. An ``n_fft=400``
   implementation is a different transform.
3. **an unnormalised Kaldi mel filterbank** — 80 triangles in
   ``1127·ln(1+f/700)`` space, no Slaney area normalisation, built over
   ``padded_window_size/2`` bins so the Nyquist bin is dropped.
4. **Kaldi's per-frame order** — remove DC offset, then preemphasis with the
   first sample replicated, then the hamming window, then zero-pad.
5. **CMN over the utterance** — subtract each mel bin's mean across frames.
"""
from __future__ import annotations

import logging
import math
import threading
import time
import uuid
import wave
from collections import OrderedDict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# ── the checkpoint ─────────────────────────────────────────────────────────

# The interlock id of §5.3, and it must equal `live_config.DEFAULTS["embed_model"]`:
# a device declaring this string is saying "my vectors are comparable with
# yours", and `speaker_embedding.model` records it on every row so a future
# checkpoint's vectors are never silently compared against these.
MODEL_ID = "wespeaker-resnet34-lm-v1"

MODEL_URL = ("https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM/"
             "resolve/main/voxceleb_resnet34_LM.onnx")
MODEL_FILENAME = "voxceleb_resnet34_LM.onnx"
# 26,530,309 bytes as published. Used only as a floor for "this file is not a
# truncated download or an HTML error page", not as an equality check — a
# re-export upstream should not brick identification.
_MODEL_MIN_BYTES = 20 * 1024 * 1024

EMBED_DIM = 256

# ── the Kaldi fbank spec (see the module docstring) ───────────────────────

SAMPLE_RATE = 16000
NUM_MEL_BINS = 80
FRAME_LENGTH_MS = 25
FRAME_SHIFT_MS = 10
PREEMPHASIS = 0.97
LOW_FREQ_HZ = 20.0
# Kaldi's `log(max(x, FLT_EPSILON))`, i.e. float32 epsilon exactly.
_LOG_FLOOR = 1.1920928955078125e-07

# An utterance shorter than this does not carry a usable voiceprint — the
# embedding is dominated by whatever phoneme happened to be in it — so it is
# better to leave the segment provisional than to mint a speaker from it.
MIN_SPEECH_MS = 600
# ResNet34 on CPU is linear in frames and this runs on a VPS beside the
# recorder. Twenty seconds is far more than identification needs and bounds
# what one long utterance can cost.
MAX_SPEECH_MS = 20_000

# ── thresholds (design §5.2's two thresholds) ─────────────────────────────

# From the spike's measured separation with this checkpoint: same-speaker pairs
# scored 0.65, different speakers 0.18–0.25.
#
# The two errors are not symmetric. Minting a speaker that turns out to be
# someone already known is cheap and self-correcting (the centroids converge,
# and `speaker{op:"merge"}` relabels the history in place). Confirming the
# wrong person writes a foreign vector into a centroid and pulls it towards two
# voices at once, which corrupts every later decision. So the confirm
# threshold is placed with margin over the different-speaker ceiling rather
# than close under the same-speaker score:
#
#   0.50 is 2× the top of the measured different-speaker range (0.25) and
#   leaves 0.15 of headroom below the measured same-speaker score (0.65), for
#   the same voice heard through a different mic or room.
SIM_CONFIRM = 0.50
#   0.30 sits just above that same 0.25 ceiling: at or under it, "I have not
#   heard this voice before" is the better explanation than a weak match.
SIM_NEW_SPEAKER = 0.30

# Between the two, a segment stays provisional and the vector is held so the
# decision can be revisited "when more audio arrives" (§5.2). Bounded, because
# this is per-process memory fed by whatever a client streams.
_MAX_PENDING_GROUPS = 64
_MAX_PENDING_VECS = 8
# Averaging unit vectors cancels per-utterance noise, so N held vectors give a
# better estimate of the voice than any one of them. Two is the least that can
# be called an average.
_MIN_VECS_TO_PROMOTE = 2


# ── lazy, fail-soft model loading ─────────────────────────────────────────

_session: Any = None
_session_lock = threading.Lock()
_load_failed_at = 0.0
# A failed load is usually a missing extra or a missing network, and both are
# steady states. Retrying every utterance would mean an HTTP request per
# utterance for the life of the process.
_RETRY_AFTER_SECONDS = 600.0
_warned = False


def model_path() -> Path:
    """Where the checkpoint is cached. Resolved per call, not at import.

    `api.config.STATE_DIR` is monkeypatched by the test suite, and a module
    constant computed at import time would point every test at the real one.
    """
    from api import config as api_config
    return Path(api_config.STATE_DIR) / "models" / MODEL_FILENAME


def model_id() -> str:
    """The id to store on rows and compare devices against.

    Read from `live_config` rather than `MODEL_ID` so a user who pins a
    different checkpoint id in `config.yaml` gets rows tagged with the id their
    devices are being asked to match — the interlock stays one value.
    """
    try:
        from api import live_config
        return str(live_config.load().get("embed_model") or MODEL_ID)
    except Exception:
        return MODEL_ID


def available() -> bool:
    """Whether identification can actually run right now.

    Deliberately does NOT download: this answers ``server_caps["embed"]`` on the
    handshake path, and a handshake must not block on 26 MB. So the first
    session after a fresh install reports False, the first identification job
    fetches the file in the background, and later handshakes report True.
    """
    if _session is not None:
        return True
    if not _onnxruntime_importable():
        return False
    return _model_file_ok(model_path())


def can_try() -> bool:
    """Whether it is worth queueing an identification job at all.

    Distinct from `available()`, and the difference is load-bearing: a fresh
    install has no checkpoint on disk, so gating the job on `available()` would
    mean no job ever runs, which means nothing ever triggers the download. This
    answers "the pieces could come together" — the extra is importable and we
    are not inside the backoff window after a failure — and lets the first job
    fetch the file on a worker thread instead of the recorder's.
    """
    if _session is not None:
        return True
    if not _onnxruntime_importable():
        return False
    if _load_failed_at and time.time() - _load_failed_at < _RETRY_AFTER_SECONDS:
        return False
    return True


def _onnxruntime_importable() -> bool:
    try:
        import onnxruntime  # noqa: F401
        import numpy  # noqa: F401
    except Exception:
        return False
    return True


def _model_file_ok(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size >= _MODEL_MIN_BYTES
    except OSError:
        return False


def _warn_once(message: str) -> None:
    global _warned
    if not _warned:
        _warned = True
        logger.warning("live: %s — speaker identification is OFF for this "
                       "process (capture and the transcript are unaffected)",
                       message)
    else:
        logger.debug("live: %s", message)


def load_session() -> Any:
    """The ONNX session, loading (and downloading) on first use. None on failure.

    Never raises. Callers are background workers whose worst available outcome
    is an unlabelled segment.
    """
    global _session, _load_failed_at
    if _session is not None:
        return _session
    with _session_lock:
        if _session is not None:
            return _session
        if _load_failed_at and time.time() - _load_failed_at < _RETRY_AFTER_SECONDS:
            return None
        try:
            import onnxruntime as ort
        except Exception:
            _load_failed_at = time.time()
            _warn_once("onnxruntime is not installed "
                       "(pip install 'jarviscopilot[live-voiceprint]')")
            return None
        path = model_path()
        if not _model_file_ok(path) and not _download_model(path):
            _load_failed_at = time.time()
            return None
        try:
            options = ort.SessionOptions()
            # This runs beside the recorder on a small VPS. Identification is
            # background work measured in hundreds of milliseconds either way,
            # so it does not get to fan out over every core and stall capture.
            options.intra_op_num_threads = 1
            options.inter_op_num_threads = 1
            options.log_severity_level = 3
            _session = ort.InferenceSession(
                str(path), sess_options=options,
                providers=["CPUExecutionProvider"])
        except Exception:
            _load_failed_at = time.time()
            logger.warning("live: the voiceprint model at %s did not load",
                           path.name, exc_info=True)
            return None
        logger.info("live: speaker identification ready (%s)", model_id())
        return _session


def _download_model(path: Path) -> bool:
    """Fetch the checkpoint once, atomically. False (not an exception) on failure.

    Weights are not committed: 26 MB of binary in the repo for an optional
    feature is the wrong trade. `.tmp` + `replace` so an interrupted download
    never leaves a half file that `_model_file_ok` would have to guess about.
    """
    try:
        import httpx
    except Exception:
        _warn_once("httpx is unavailable, so the voiceprint model cannot be "
                   "downloaded")
        return False
    tmp = path.with_suffix(path.suffix + f".{uuid.uuid4().hex[:8]}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        logger.info("live: downloading the voiceprint model (~26 MB) to %s",
                    path.parent)
        with httpx.stream("GET", MODEL_URL, follow_redirects=True,
                          timeout=300.0) as response:
            response.raise_for_status()
            with tmp.open("wb") as fh:
                for chunk in response.iter_bytes(1 << 20):
                    if chunk:
                        fh.write(chunk)
        if tmp.stat().st_size < _MODEL_MIN_BYTES:
            raise RuntimeError(f"got {tmp.stat().st_size} bytes, expected ~26 MB")
        tmp.replace(path)
        return True
    except Exception:
        _warn_once("the voiceprint model could not be downloaded")
        logger.debug("live: voiceprint model download failed", exc_info=True)
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def reset_for_tests() -> None:
    """Drop the loaded session, the retry clock and the pending groups."""
    global _session, _load_failed_at, _warned, _enrolment_attempted
    with _session_lock:
        _session = None
        _load_failed_at = 0.0
        _warned = False
    with _pending_lock:
        _pending.clear()
    _enrolment_attempted = False


# ── the Kaldi-compatible fbank ────────────────────────────────────────────


def _mel(hz):
    return 1127.0 * math.log(1.0 + hz / 700.0)


_filterbank_cache: Dict[Tuple[int, int, int], Any] = {}
_filterbank_lock = threading.Lock()


def mel_filterbank(num_bins: int = NUM_MEL_BINS, n_fft: int = 512,
                   rate: int = SAMPLE_RATE):
    """Kaldi's mel filterbank as a ``(num_bins, n_fft//2 + 1)`` matrix.

    Two structural details, and the first is the one a librosa-shaped port gets
    wrong (measured: 0.58):

    * **no area normalisation.** Each triangle peaks at exactly 1.0. Slaney
      normalisation divides by the filter's width, which reweights the whole
      spectrum against what the model was trained on.
    * **the triangles are laid out over ``n_fft // 2`` bins**, not
      ``n_fft // 2 + 1``, and the Nyquist column is then zero — Kaldi computes
      the bank over ``padded_window_size / 2`` bins and pads one zero column to
      meet the rfft's output width, so the 8 kHz bin contributes nothing.
    """
    import numpy as np

    key = (int(num_bins), int(n_fft), int(rate))
    with _filterbank_lock:
        cached = _filterbank_cache.get(key)
    if cached is not None:
        return cached

    num_fft_bins = n_fft // 2                     # 256 for a 512-point FFT
    nyquist = 0.5 * rate
    bin_width = rate / float(n_fft)
    mel_low = _mel(LOW_FREQ_HZ)
    mel_high = _mel(nyquist)
    delta = (mel_high - mel_low) / (num_bins + 1)

    index = np.arange(num_bins, dtype=np.float64).reshape(-1, 1)
    left = mel_low + index * delta
    center = mel_low + (index + 1.0) * delta
    right = mel_low + (index + 2.0) * delta

    freqs = bin_width * np.arange(num_fft_bins, dtype=np.float64)
    mels = (1127.0 * np.log1p(freqs / 700.0)).reshape(1, -1)

    up = (mels - left) / (center - left)
    down = (right - mels) / (right - center)
    bank = np.maximum(0.0, np.minimum(up, down))
    # The zero column that makes this multiply against a 257-wide rfft output.
    bank = np.concatenate([bank, np.zeros((num_bins, 1))], axis=1)
    bank = bank.astype(np.float32)

    with _filterbank_lock:
        _filterbank_cache[key] = bank
    return bank


def kaldi_fbank(samples, rate: int = SAMPLE_RATE, num_bins: int = NUM_MEL_BINS):
    """``(T, num_bins)`` log-mel features with CMN applied, or None if too short.

    `samples` is a float array on the **int16 scale** (±32768), not ±1.0 — see
    structural choice 1 in the module docstring. Every other choice Kaldi makes
    here is listed there too; this function is the one place they live.
    """
    import numpy as np

    audio = np.asarray(samples, dtype=np.float64).reshape(-1)
    frame_len = int(rate * FRAME_LENGTH_MS / 1000)        # 400 @ 16 kHz
    frame_shift = int(rate * FRAME_SHIFT_MS / 1000)       # 160 @ 16 kHz
    if audio.size < frame_len:
        # snip_edges=True: fewer samples than one window is zero frames, not a
        # zero-padded one.
        return None
    n_frames = 1 + (audio.size - frame_len) // frame_shift

    # Framing without a copy per frame.
    frames = np.lib.stride_tricks.as_strided(
        audio,
        shape=(n_frames, frame_len),
        strides=(audio.strides[0] * frame_shift, audio.strides[0]),
        writeable=False,
    ).copy()

    # Kaldi's per-frame order: DC, then preemphasis, then the window.
    frames -= frames.mean(axis=1, keepdims=True)          # remove_dc_offset
    # Preemphasis with the first sample REPLICATED, which is what makes
    # frame[0] == x0 * (1 - 0.97) rather than x0 untouched.
    shifted = np.concatenate([frames[:, :1], frames[:, :-1]], axis=1)
    frames -= PREEMPHASIS * shifted
    # Symmetric hamming: 0.54 - 0.46·cos(2πn/(N-1)), exactly Kaldi's.
    frames *= np.hamming(frame_len)

    # round_to_power_of_two: a 400-sample window, a 512-point FFT.
    n_fft = 1
    while n_fft < frame_len:
        n_fft *= 2
    spectrum = np.abs(np.fft.rfft(frames, n=n_fft, axis=1)) ** 2   # use_power

    bank = mel_filterbank(num_bins, n_fft, rate)
    energies = spectrum.astype(np.float32) @ bank.T
    feats = np.log(np.maximum(energies, _LOG_FLOOR))

    # CMN over the utterance. Forgetting this scored 0.52.
    feats -= feats.mean(axis=0, keepdims=True)
    return feats.astype(np.float32)


# ── pcm → embedding ───────────────────────────────────────────────────────


def _to_16k(samples, rate: int):
    """Resample to 16 kHz, because that is what the model was trained on.

    A boxcar average before the decimation is a crude anti-alias filter, but
    crude beats none: 48 kHz straight through `interp` folds everything above
    8 kHz back into the band the mel filters read, which is a structural error
    of exactly the kind the spike warned about. Identification quality at rates
    other than 16 kHz is untested — the protocol's own default is 16000.
    """
    import numpy as np

    if rate == SAMPLE_RATE or rate <= 0:
        return samples, SAMPLE_RATE if rate <= 0 else rate
    if rate > SAMPLE_RATE:
        factor = int(round(rate / SAMPLE_RATE))
        if factor >= 2:
            usable = (samples.size // factor) * factor
            if usable >= factor:
                samples = samples[:usable].reshape(-1, factor).mean(axis=1)
                rate = rate / factor
                if abs(rate - SAMPLE_RATE) < 1.0:
                    return samples, SAMPLE_RATE
    duration = samples.size / float(rate)
    target_n = int(duration * SAMPLE_RATE)
    if target_n < 2 or samples.size < 2:
        return samples, SAMPLE_RATE
    source_t = np.arange(samples.size, dtype=np.float64) / rate
    target_t = np.arange(target_n, dtype=np.float64) / SAMPLE_RATE
    return np.interp(target_t, source_t, samples), SAMPLE_RATE


def embed(pcm16: bytes, rate: int = SAMPLE_RATE) -> Optional[List[float]]:
    """One utterance's 256-d voiceprint, L2-normalised. None when it cannot.

    None is a normal answer, not an error: the extra is not installed, the
    checkpoint is not downloaded yet, the audio is too short to carry a voice.
    Every caller treats None as "leave this segment provisional", which is why
    nothing here raises.
    """
    if not pcm16:
        return None
    session = load_session()
    if session is None:
        return None
    try:
        import numpy as np

        # int16 PCM read at its own scale. NOT divided by 32768 — structural
        # choice 1; dividing scored 0.58-class damage in the spike.
        samples = np.frombuffer(pcm16, dtype="<i2").astype(np.float64)
        if samples.size == 0:
            return None
        samples, rate = _to_16k(samples, int(rate or SAMPLE_RATE))
        max_samples = int(rate * MAX_SPEECH_MS / 1000)
        if samples.size > max_samples:
            samples = samples[:max_samples]
        if samples.size < int(rate * MIN_SPEECH_MS / 1000):
            return None
        feats = kaldi_fbank(samples, int(rate))
        if feats is None or feats.shape[0] < 2:
            return None
        outputs = session.run(None, {"feats": feats[None, :, :]})
        vec = np.asarray(outputs[0], dtype=np.float32).reshape(-1)
        if vec.size != EMBED_DIM:
            logger.warning("live: the voiceprint model returned %d dims, "
                           "expected %d", vec.size, EMBED_DIM)
            return None
        norm = float(np.linalg.norm(vec))
        if not norm or not math.isfinite(norm):
            return None
        # Unit vectors make a centroid a plain mean and cosine a plain dot.
        return [float(v) for v in (vec / norm)]
    except Exception:
        logger.warning("live: embedding an utterance failed", exc_info=True)
        return None


def embed_wav(path) -> Optional[List[float]]:
    """Embed a mono PCM WAV file. Used by enrolment; None on anything unusable."""
    try:
        with wave.open(str(path), "rb") as wf:
            if wf.getsampwidth() != 2 or wf.getnchannels() != 1:
                return None
            rate = wf.getframerate()
            pcm = wf.readframes(wf.getnframes())
    except Exception:
        logger.debug("live: could not read %s for enrolment", path, exc_info=True)
        return None
    return embed(pcm, rate)


# ── similarity ────────────────────────────────────────────────────────────


def cosine(a, b) -> float:
    import numpy as np

    va = np.asarray(a, dtype=np.float64).reshape(-1)
    vb = np.asarray(b, dtype=np.float64).reshape(-1)
    if va.size != vb.size or not va.size:
        return 0.0
    na = float(np.linalg.norm(va))
    nb = float(np.linalg.norm(vb))
    if not na or not nb:
        return 0.0
    return float(np.dot(va, vb) / (na * nb))


def centroids(rows: Optional[List[dict]] = None) -> Dict[str, List[float]]:
    """One vector per speaker: the mean of that speaker's exemplars.

    `speaker_embedding` is plural per speaker on purpose (§3) — the centroid is
    what identification compares against and it sharpens as a voice is heard
    more.
    """
    import numpy as np

    if rows is None:
        rows = live_store_rows()
    grouped: Dict[str, list] = {}
    for row in rows or []:
        vec = row.get("vec") or []
        if len(vec) != EMBED_DIM:
            # A row from another checkpoint with the same id, or a truncated
            # blob. Comparing it would be meaningless rather than imprecise.
            continue
        grouped.setdefault(str(row.get("speaker_id") or ""), []).append(vec)
    out: Dict[str, List[float]] = {}
    for speaker_id, vecs in grouped.items():
        if not speaker_id:
            continue
        mean = np.mean(np.asarray(vecs, dtype=np.float64), axis=0)
        norm = float(np.linalg.norm(mean))
        if norm:
            out[speaker_id] = [float(v) for v in (mean / norm)]
    return out


def live_store_rows() -> List[dict]:
    from api import live_store
    return live_store.embeddings_for_model(model_id())


def best_match(vec, cents: Dict[str, List[float]]) -> Tuple[str, float]:
    best_id, best = "", -1.0
    for speaker_id, centroid in (cents or {}).items():
        score = cosine(vec, centroid)
        if score > best:
            best_id, best = speaker_id, score
    return best_id, (best if best_id else 0.0)


# ── identification (design §5.2) ──────────────────────────────────────────

# (live_session_id, speaker_id) → {"vecs": [...], "segments": [(sid, seq), ...]}
_pending: "OrderedDict[Tuple[str, str], dict]" = OrderedDict()
_pending_lock = threading.Lock()


def _pending_push(live_session_id: str, speaker_id: str, vec: List[float],
                  seq: int) -> dict:
    with _pending_lock:
        key = (live_session_id, speaker_id)
        group = _pending.get(key)
        if group is None:
            while len(_pending) >= _MAX_PENDING_GROUPS:
                _pending.popitem(last=False)
            group = {"vecs": [], "segments": []}
            _pending[key] = group
        _pending.move_to_end(key)
        group["vecs"].append(list(vec))
        group["segments"].append((live_session_id, int(seq)))
        del group["vecs"][:-_MAX_PENDING_VECS]
        del group["segments"][:-_MAX_PENDING_VECS]
        return {"vecs": list(group["vecs"]),
                "segments": list(group["segments"])}


def _pending_take(live_session_id: str, speaker_id: str) -> List[Tuple[str, int]]:
    """Claim the segments held provisionally for this voice in this session."""
    with _pending_lock:
        group = _pending.pop((live_session_id, speaker_id), None)
    return list(group["segments"]) if group else []


def identify(vec: List[float], *, live_session_id: str = "",
             seq: int = 0) -> Optional[Dict[str, Any]]:
    """Decide whose voice this is, writing the store rows that say so.

    The two thresholds of §5.2, and the third case is the interesting one:

    * ``score >= SIM_CONFIRM`` — this is that speaker. Store the vector as
      another exemplar and confirm the segment.
    * ``score <= SIM_NEW_SPEAKER`` (or nothing stored at all) — a voice not
      heard before. Mint a `speaker.id`. The segment is confirmed: it is
      definitively this new voice, even though the voice has no name yet.
    * in between — stay provisional and **hold the vector**. When another
      middling utterance lands on the same voice, their mean is a better
      estimate than either alone, and if the mean clears ``SIM_CONFIRM`` the
      whole held group is promoted at once. That is what "decide when more
      audio arrives" means here.

    Returns the frame body the caller publishes, or None if it could do
    nothing. Never raises — the caller is a background worker and an
    unlabelled segment is an acceptable outcome; a broken recorder is not.
    """
    if not vec or len(vec) != EMBED_DIM:
        return None
    try:
        from api import live_store
    except Exception:
        return None
    model = model_id()
    try:
        cents = centroids()
        best_id, score = best_match(vec, cents)

        if best_id and score >= SIM_CONFIRM:
            live_store.add_embedding(best_id, vec, model,
                                     _segment_ref(live_session_id, seq))
            promoted = _pending_take(live_session_id, best_id)
            return _decision(best_id, score, confirmed=True, new=False,
                             promoted=promoted,
                             merged_from=_maybe_merge(best_id, vec, cents))

        if best_id and score > SIM_NEW_SPEAKER:
            group = _pending_push(live_session_id, best_id, vec, seq)
            if len(group["vecs"]) >= _MIN_VECS_TO_PROMOTE:
                import numpy as np
                mean = np.mean(np.asarray(group["vecs"], dtype=np.float64), axis=0)
                if cosine(mean, cents[best_id]) >= SIM_CONFIRM:
                    promoted = _pending_take(live_session_id, best_id)
                    # The MEAN is the exemplar worth keeping: it is the
                    # estimate that cleared the threshold, not any one of the
                    # middling vectors that went into it.
                    norm = float(np.linalg.norm(mean)) or 1.0
                    live_store.add_embedding(
                        best_id, [float(v) for v in (mean / norm)], model,
                        _segment_ref(live_session_id, seq))
                    return _decision(best_id, float(cosine(mean, cents[best_id])),
                                     confirmed=True, new=False,
                                     promoted=promoted, merged_from=None)
            return _decision(best_id, score, confirmed=False, new=False,
                             promoted=[], merged_from=None)

        speaker = live_store.create_speaker(kind="other")
        live_store.add_embedding(speaker["id"], vec, model,
                                 _segment_ref(live_session_id, seq))
        return _decision(speaker["id"], score if best_id else 0.0,
                         confirmed=True, new=True, promoted=[], merged_from=None)
    except Exception:
        logger.warning("live: identification failed for %s#%s",
                       live_session_id[:8] or "?", seq, exc_info=True)
        return None


def _segment_ref(live_session_id: str, seq: int) -> str:
    return f"{live_session_id}#{int(seq)}" if live_session_id else ""


def _decision(speaker_id: str, score: float, *, confirmed: bool, new: bool,
              promoted: List[Tuple[str, int]],
              merged_from: Optional[str]) -> Dict[str, Any]:
    from api import live_store
    return {
        "speaker_id": speaker_id,
        "score": round(float(score), 4),
        "label_state": (live_store.LABEL_CONFIRMED if confirmed
                        else live_store.LABEL_PROVISIONAL),
        "new_speaker": bool(new),
        # Earlier segments this decision also resolves, as (session, seq).
        "promoted": [(str(s), int(q)) for s, q in promoted],
        "merged_from": merged_from,
    }


def _maybe_merge(speaker_id: str, vec: List[float],
                 cents: Dict[str, List[float]]) -> Optional[str]:
    """Collapse two stored voices that turn out to be one person (§5.2).

    Conservative on purpose, because a merge rewrites history: it fires only
    when this utterance clears ``SIM_CONFIRM`` against two different stored
    centroids AND those two centroids clear it against **each other**. One
    utterance matching two voices is ambiguity; two centroids matching each
    other is evidence that the clusters are the same person.

    The older `speaker.id` survives, so a name already given to it stays put.
    """
    from api import live_store

    others = [sid for sid, centroid in cents.items()
              if sid != speaker_id
              and cosine(vec, centroid) >= SIM_CONFIRM
              and cosine(cents.get(speaker_id) or [], centroid) >= SIM_CONFIRM]
    if not others:
        return None
    try:
        created = {row["id"]: float(row.get("created_at") or 0.0)
                   for row in live_store.list_speakers()}
        pair = sorted([speaker_id, others[0]],
                      key=lambda sid: created.get(sid, 0.0))
        older, newer = pair[0], pair[1]
        if older == newer:
            return None
        live_store.merge_speakers(newer, older)
        logger.info("live: merged voice %s… into %s… (same speaker)",
                    newer[:8], older[:8])
        return newer
    except Exception:
        logger.warning("live: a speaker merge failed", exc_info=True)
        return None


# ── enrolling "me" (design §5.4) ──────────────────────────────────────────

_enrolment_attempted = False
_enrolment_lock = threading.Lock()

# Enough utterances for a stable centroid without spending a minute of CPU on
# a first-run side effect.
_ENROL_MAX_RECORDINGS = 8


def enrol_me_from_voice_recordings(limit: int = _ENROL_MAX_RECORDINGS) -> Dict[str, Any]:
    """Seed the "me" voice from stored voice turns, not a read-these-sentences flow.

    `api.voice_recordings` keeps the 16 kHz mono PCM of every turn the user
    spoke to Jarvis through a pod, which is definitionally the user — so §5.4's
    enrolment is a read of audio that already exists.

    Returns a small report. Does nothing and says so when there is no such
    audio, which is the normal case on a fresh install: a user naming their own
    voice once on the Voices screen reaches the same place.
    """
    report = {"enrolled": 0, "speaker_id": "", "reason": ""}
    try:
        from api import live_store, voice_recordings
    except Exception:
        report["reason"] = "voice recordings are unavailable"
        return report

    existing = [s for s in live_store.list_speakers() if s.get("kind") == "me"]
    if existing:
        report["speaker_id"] = existing[0]["id"]
        report["reason"] = "already enrolled"
        return report

    root = Path(voice_recordings.RECORDINGS_DIR)
    if not root.is_dir():
        report["reason"] = "no stored voice audio to enrol from"
        return report
    wavs: List[Path] = []
    for device_dir in sorted(root.iterdir()):
        if device_dir.is_dir():
            wavs.extend(device_dir.glob("*.wav"))
    if not wavs:
        report["reason"] = "no stored voice audio to enrol from"
        return report
    # Newest first: the most recent turns are the current mic and the current
    # room, which is what the live session will sound like.
    wavs.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)

    vecs = []
    for wav in wavs[:max(1, int(limit))]:
        vec = embed_wav(wav)
        if vec:
            vecs.append(vec)
    if not vecs:
        report["reason"] = "stored voice audio produced no usable voiceprint"
        return report

    speaker = live_store.create_speaker(kind="me", name="Me")
    model = model_id()
    for vec in vecs:
        live_store.add_embedding(speaker["id"], vec, model, "enrolment")
    report.update({"enrolled": len(vecs), "speaker_id": speaker["id"],
                   "reason": "enrolled from stored voice turns"})
    logger.info("live: enrolled 'me' from %d stored voice turn(s)", len(vecs))
    return report


def enrol_me_once() -> None:
    """Run enrolment at most once per process, on a background thread's time."""
    global _enrolment_attempted
    with _enrolment_lock:
        if _enrolment_attempted:
            return
        _enrolment_attempted = True
    try:
        enrol_me_from_voice_recordings()
    except Exception:
        logger.debug("live: 'me' enrolment failed", exc_info=True)
