#!/usr/bin/env python3
"""WeSpeaker (what Live runs) vs ERes2Net, on his own confirmed voices.

Run ON THE SERVER, where the recordings live:

    cd /root/JarvisCopilot/webui && ../.venv/bin/python ../scripts/speaker_bench.py [--per-voice 40]

Takes Live lines of 3 s or more whose voice is confirmed, embeds each with both
models, and reports per model: how alike two lines of the same voice are, how
alike two different voices are, the equal error rate, and the threshold at it.
ERes2Net-base (3D-Speaker, VoxCeleb, 16 kHz, from the sherpa-onnx release) is
downloaded once to ~/.cache/jarvis-bench/. Writes nothing to the repo.

Switch Live's model only on a clear win on this data (≥ 20 % lower EER): a
switch re-embeds every stored voice on the server and the phone.
"""
from __future__ import annotations

import argparse
import itertools
import sys
import urllib.request
from pathlib import Path

# Run from webui/ (the documented way) or from the repo's scripts/ folder.
_WEBUI = Path.cwd() if (Path.cwd() / "api").is_dir() else Path(__file__).resolve().parent.parent / "webui"
sys.path.insert(0, str(_WEBUI))
sys.path.insert(0, str(_WEBUI.parent))

_ERES2NET_URL = ("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
                 "3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx")
_CACHE = Path.home() / ".cache" / "jarvis-bench"
_MIN_LINE_MS = 3000


def _eres2net():
    import onnxruntime as ort
    path = _CACHE / Path(_ERES2NET_URL).name
    if not path.exists():
        _CACHE.mkdir(parents=True, exist_ok=True)
        print(f"downloading {path.name} …")
        urllib.request.urlretrieve(_ERES2NET_URL, path)
    session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    name = session.get_inputs()[0].name

    def embed(pcm: bytes, rate: int):
        import numpy as np
        from api import live_voiceprint as vp
        samples = np.frombuffer(pcm, dtype="<i2").astype(np.float64)
        samples, rate = vp._to_16k(samples, rate)
        feats = vp.kaldi_fbank(samples, rate)
        if feats is None or feats.shape[0] < 2:
            return None
        vec = np.asarray(session.run(None, {name: feats[None, :, :].astype(np.float32)})[0]).reshape(-1)
        norm = float(np.linalg.norm(vec))
        return vec / norm if norm else None

    return embed


def _wespeaker():
    import numpy as np
    from api import live_voiceprint as vp

    def embed(pcm: bytes, rate: int):
        vec = vp.embed(pcm, rate)
        return np.asarray(vec) if vec else None

    return embed


def _lines(per_voice: int):
    from api import live_store
    with live_store.connect() as conn:
        rows = conn.execute(
            "SELECT live_session_id AS sid, ts_start_ms AS a, ts_end_ms AS b, device_id AS dev,"
            " speaker_id AS voice FROM live_segment WHERE label_state = 'confirmed'"
            " AND speaker_id IS NOT NULL AND ts_end_ms - ts_start_ms >= ? ORDER BY seq DESC",
            (_MIN_LINE_MS,)).fetchall()
    by_voice = {}
    for row in rows:
        picked = by_voice.setdefault(row["voice"], [])
        if len(picked) < per_voice:
            picked.append(dict(row))
    return {voice: lines for voice, lines in by_voice.items() if len(lines) >= 3}


def _eer(same, other):
    """Equal error rate and the threshold where the two error rates cross."""
    best_gap, best_threshold, best_rate = 2.0, 0.0, 1.0
    for threshold in sorted(set(same) | set(other)):
        false_reject = sum(s < threshold for s in same) / len(same)
        false_accept = sum(o >= threshold for o in other) / len(other)
        gap = abs(false_reject - false_accept)
        if gap < best_gap:
            best_gap, best_threshold, best_rate = gap, threshold, (false_reject + false_accept) / 2
    return best_rate, best_threshold


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--per-voice", type=int, default=40)
    args = parser.parse_args()
    import numpy as np
    from api import live_ws

    voices = _lines(args.per_voice)
    if len(voices) < 2:
        print(f"need two confirmed voices with 3+ lines of 3 s; have {len(voices)}")
        return
    print(f"{len(voices)} voices, {sum(map(len, voices.values()))} lines\n")
    audio = {}
    for voice, lines in voices.items():
        for line in lines:
            got = live_ws.pcm_for_range(line["sid"], line["a"], line["b"], line["dev"] or "")
            if got:
                audio[(voice, line["sid"], line["a"])] = got
    for label, embedder in (("WeSpeaker ResNet34 (Live today)", _wespeaker()),
                            ("ERes2Net-base VoxCeleb", _eres2net())):
        vecs = []
        for (voice, _sid, _a), (pcm, rate) in audio.items():
            vec = embedder(pcm, rate)
            if vec is not None:
                vecs.append((voice, vec))
        same, other = [], []
        for (va, a), (vb, b) in itertools.combinations(vecs, 2):
            (same if va == vb else other).append(float(np.dot(a, b)))
        if not same or not other:
            print(f"{label}: not enough embeddings")
            continue
        eer, threshold = _eer(same, other)
        print(f"{label}: {len(vecs)} lines  same-voice {np.mean(same):.3f}  other-voice "
              f"{np.mean(other):.3f}  EER {eer * 100:.1f}% at {threshold:.2f}")


if __name__ == "__main__":
    main()
