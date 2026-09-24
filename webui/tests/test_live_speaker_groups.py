"""Soniox splits the speakers, voiceprints name them (`live.speaker_split: engine`).

A speech engine that labels speakers already knows which lines are one person
inside a stream; it split every trial clip right, where one line's voiceprint
is wrong about one time in eight. So in this mode a label is one group: its
lines share one speaker, named from the voiceprint of ALL its audio pooled, and
a new voice is minted once, from enough audio to be sure of.
"""
import pathlib

import pytest

from api import live_config, live_store, live_voiceprint, live_ws
from tests.test_live_ws import isolated_state  # noqa: F401 — fixture used by name

_DIM = live_voiceprint.EMBED_DIM
_STATIC = pathlib.Path(__file__).resolve().parent.parent / "static"


def _vec(*hot):
    v = [0.0] * _DIM
    for i in hot:
        v[i] = 1.0
    return v


def test_speaker_split_defaults_to_voiceprints(isolated_state):
    assert live_config.load()["speaker_split"] == "voiceprint"
    assert live_config.save({"speaker_split": "engine"})["speaker_split"] == "engine"
    with pytest.raises(ValueError):
        live_config.save({"speaker_split": "soniox-please"})


@pytest.fixture
def group(isolated_state, monkeypatch):
    """A session, the voiceprint each line's audio embeds to, and every identify() call."""
    sid = live_store.start_session(device_id="d", title="t")["id"]
    vectors, calls = {}, []
    monkeypatch.setattr(live_ws, "_group_embed", lambda s, a, b, dev: vectors.get(a))

    def identify(vec, **kw):
        calls.append((list(vec), kw.get("learn")))
        return None
    monkeypatch.setattr(live_voiceprint, "identify", identify)

    def line(start, end, label="soniox:ab-1:1", vec=None):
        if vec is not None:
            vectors[start] = vec
        row = live_store.append_segment(sid, ts_start_ms=start, ts_end_ms=end, text="words",
                                        local_label=label, device_id="d")
        live_ws._run_group_identification(sid, int(row["seq"]), start, end, "d", dict(row))
        return int(row["seq"])

    return {"sid": sid, "line": line, "calls": calls, "mp": monkeypatch}


def _speaker(sid, seq):
    row = next(r for r in live_store.segments_after(sid, 0) if int(r["seq"]) == seq)
    return row.get("speaker_id") or ""


def test_a_new_voice_is_minted_once_from_enough_audio(group):
    minted = live_store.create_speaker(kind="other")

    def identify(vec, **kw):
        group["calls"].append((list(vec), kw.get("learn")))
        if kw.get("learn"):
            return {"speaker_id": minted["id"], "label_state": "confirmed", "score": 0.1,
                    "new_speaker": True}
        return None
    group["mp"].setattr(live_voiceprint, "identify", identify)
    first = group["line"](0, 2000, vec=_vec(0))       # 2 s: too little to mint a voice on
    assert _speaker(group["sid"], first) == ""
    second = group["line"](2500, 4500, vec=_vec(0))   # 4 s pooled: mint now
    assert [learn for _v, learn in group["calls"]].count(True) == 1
    assert _speaker(group["sid"], first) == _speaker(group["sid"], second) == minted["id"]


def test_the_name_comes_from_the_pooled_audio(group):
    group["line"](0, 4000, vec=_vec(0))
    group["line"](4000, 6000, vec=_vec(1))
    pooled, _learn = group["calls"][-1]
    # Weighted by length: 4 s of the first voice, 2 s of the second.
    assert pooled[0] > pooled[1] > 0


def test_a_better_answer_relabels_the_whole_group(group):
    early = live_store.create_speaker(kind="other", name="Guess")
    right = live_store.create_speaker(kind="other", name="Sam")
    answers = iter([{"speaker_id": early["id"], "label_state": "provisional", "score": 0.5},
                    {"speaker_id": right["id"], "label_state": "confirmed", "score": 0.8}])
    group["mp"].setattr(live_voiceprint, "identify", lambda vec, **kw: next(answers))
    first = group["line"](0, 4000, vec=_vec(0))
    assert _speaker(group["sid"], first) == early["id"]
    second = group["line"](4000, 9000, vec=_vec(0))
    assert _speaker(group["sid"], first) == _speaker(group["sid"], second) == right["id"]


def test_a_short_line_joins_its_group_without_teaching(group):
    sam = live_store.create_speaker(kind="other", name="Sam")
    group["mp"].setattr(live_voiceprint, "identify",
                        lambda vec, **kw: {"speaker_id": sam["id"], "label_state": "confirmed",
                                           "score": 0.9})
    taught = []
    group["mp"].setattr(live_store, "add_embedding", lambda spk, *a, **k: taught.append(spk))
    group["line"](0, 4000, vec=_vec(0))
    short = group["line"](4200, 4600)                  # 0.4 s: no voiceprint of its own
    assert _speaker(group["sid"], short) == sam["id"]
    assert taught == [sam["id"]]                      # the 4 s line taught; the short one did not


def test_labels_are_separate_groups(group):
    a = live_store.create_speaker(kind="other", name="A")
    b = live_store.create_speaker(kind="other", name="B")
    group["mp"].setattr(live_voiceprint, "identify",
                        lambda vec, **kw: {"speaker_id": a["id"] if vec[0] else b["id"],
                                           "label_state": "confirmed", "score": 0.9})
    one = group["line"](0, 4000, label="soniox:ab-1:1", vec=_vec(0))
    two = group["line"](4000, 8000, label="soniox:ab-1:2", vec=_vec(1))
    assert (_speaker(group["sid"], one), _speaker(group["sid"], two)) == (a["id"], b["id"])


def test_engine_rows_use_groups_only_in_engine_mode(isolated_state, monkeypatch):
    queued = []
    monkeypatch.setattr(live_ws, "_ident_submit", lambda fn, *a: queued.append(fn.__name__))
    monkeypatch.setattr(live_voiceprint, "can_try", lambda: True)
    sid = live_store.start_session(device_id="d", title="t")["id"]
    live_ws.append_and_publish(sid, ts_start_ms=0, ts_end_ms=4000, text="x",
                               local_label="soniox:ab-1:1", device_id="d", transcribed_by="soniox")
    live_config.save({"speaker_split": "engine"})
    live_ws.append_and_publish(sid, ts_start_ms=4000, ts_end_ms=8000, text="y",
                               local_label="soniox:ab-1:1", device_id="d", transcribed_by="soniox")
    live_ws.append_and_publish(sid, ts_start_ms=8000, ts_end_ms=12000, text="z",
                               local_label="phone-track", device_id="d")
    assert queued == ["_run_identification", "_run_group_identification", "_run_identification"]


def test_live_settings_offer_the_speaker_split_dropdown():
    js = (_STATIC / "live.js").read_text(encoding="utf-8")
    before = js.split('data-cfg="speaker_split"')[0]
    assert 'data-cfg="speaker_split"' in js and before.rstrip().endswith('<select id="liveCfgSplit"')
    assert 'data-cfg="embed_model"' not in js
