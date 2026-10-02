"""Dashcam server store (api.dashcam_store): cameras, clips, fixes, thumbnails,
settings, destinations, chunked uploads and staging.

Pure: a real DashcamStore on tmp_path; the remux tests use a real ffmpeg when there is one
(skipped otherwise) and a mocked one for the failure paths. Run from webui/:
    TZ=UTC LANG=C.UTF-8 python3 -m pytest -o addopts="" -q -p no:cacheprovider tests/test_dashcam_store.py
"""
from __future__ import annotations

import hashlib
import json
import logging
import math
import re
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from api import dashcam_remux
from api import dashcam_store as ds
from api.dashcam_store import DashcamStore

CAM = "A4-1234"
T0 = 1790000000.0  # 2026-09-21T14:13:20Z — inside the accepted fix window
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 100 + b"\xff\xd9"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 100


@pytest.fixture()
def store(tmp_path):
    return DashcamStore(tmp_path)


def item(name, *, kind="normal", lens="front", start="2026-10-01T20:40:12Z", size=1000, duration=60):
    folder = {"normal": "Normal", "event": "Event", "parking": "Parking", "photo": "Photo"}[kind]
    return {"path": f"/sd/{folder}/F/{name}", "kind": kind, "lens": lens,
            "start": start, "duration": duration, "size": size}


def clip_of(store, it, camera=CAM):
    return store.get_clip(DashcamStore.clip_id(camera, it["path"]))


def add_dest(store, name="Drive", kinds=None, enabled=True, dtype="drive"):
    meta = {"type": dtype, "name": name, "remote": "", "path": "dashcam", "enabled": enabled}
    if kinds is not None:
        meta["kinds"] = kinds
    dest = store.add_destination(meta)
    store.update_destination(dest["id"], {"remote": "jc_" + dest["id"]})
    return store.update_destination(dest["id"], {})


def upload_clip(store, it, data, chunk_size=4):
    """Inventory one clip, upload `data` in chunks and complete it; returns (clip_id, upload)."""
    store.apply_inventory(CAM, [it])
    cid = DashcamStore.clip_id(CAM, it["path"])
    up, err = store.create_upload(cid, len(data), hashlib.sha256(data).hexdigest(), chunk_size)
    assert err is None, err
    for n in range(0, math.ceil(len(data) / chunk_size)):
        _, err = store.write_chunk(up["id"], n, data[n * chunk_size:(n + 1) * chunk_size])
        assert err is None, err
    clip, err = store.complete_upload(up["id"])
    assert err is None, err
    return cid, up


def make_ts(path, seconds=2) -> bytes:
    """A tiny real MPEG-TS (H.264 + AAC) made by ffmpeg; skips the test without one."""
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        pytest.skip("ffmpeg not installed")
    made = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=15",
                           "-f", "lavfi", "-i", "sine=f=440:sample_rate=16000", "-t", str(seconds),
                           "-c:v", "libx264", "-c:a", "aac", "-f", "mpegts", str(path)], capture_output=True, text=True)
    if made.returncode != 0:
        pytest.skip(f"ffmpeg can't make the fixture: {made.stderr.strip()[:200]}")
    return Path(path).read_bytes()


class FakeRemux:
    """Stands in for dashcam_remux.remux: writes ``output`` as the MP4, or fails with ``fail``;
    ``during`` runs inside the call (what another thread does while ffmpeg works)."""
    output = b"\x00\x00\x00\x18ftypisom" + b"m" * 40

    def __init__(self):
        self.calls, self.fail, self.during = [], None, None

    def __call__(self, src, dst):
        self.calls.append((Path(src), Path(dst)))
        if self.during:
            during, self.during = self.during, None
            during()
        if self.fail:
            return self.fail
        Path(dst).write_bytes(self.output)
        return None


@pytest.fixture()
def fake_remux(monkeypatch):
    fake = FakeRemux()
    monkeypatch.setattr(dashcam_remux, "remux", fake)
    return fake


def staging_names(store) -> list[str]:
    d = store.base / "staging"
    return sorted(p.name for p in d.iterdir()) if d.is_dir() else []


def make_legacy(store, cid, upload_id):
    """What a clip staged before uploads were remuxed looks like: nothing recorded about the staged file."""
    doc = store.get_upload(upload_id)
    for key in ("remuxed", "staged_size"):
        doc.pop(key, None)
    store._save_upload(doc)
    clip = store.get_clip(cid)
    for key in ("container", "staged_name"):
        clip.pop(key, None)
    store._save_clip(clip)


# ── clip ids ─────────────────────────────────────────────────────────────────

def test_clip_id_is_stable_path_safe_and_per_camera():
    a = DashcamStore.clip_id(CAM, "/sd/Normal/F/2026_1001_154012_F.MP4")
    assert a == DashcamStore.clip_id(CAM, "/sd/Normal/F/2026_1001_154012_F.MP4")
    assert re.fullmatch(r"c_[0-9a-f]{20}", a)
    assert a != DashcamStore.clip_id("other", "/sd/Normal/F/2026_1001_154012_F.MP4")
    assert a != DashcamStore.clip_id(CAM, "/sd/Normal/F/2026_1001_154112_F.MP4")


# ── inventory ────────────────────────────────────────────────────────────────

def test_inventory_creates_clips_and_returns_compact_rows(store):
    rows = store.apply_inventory(CAM, [item("a.MP4"), item("b.MP4", kind="event", lens="rear")])
    assert [r["path"] for r in rows] == ["/sd/Normal/F/a.MP4", "/sd/Event/F/b.MP4"]
    for r in rows:
        assert set(r) >= {"id", "path", "has_gps", "has_thumb", "uploaded", "size_stable"}
        assert r["has_gps"] is False and r["uploaded"] is False and r["size_stable"] is False
    clip = clip_of(store, item("b.MP4", kind="event"))
    assert clip["kind"] == "event" and clip["lens"] == "rear" and clip["name"] == "b.MP4"
    assert clip["on_camera"] is True and clip["start"] == "2026-10-01T20:40:12Z"
    assert clip["duration_s"] == 60.0 and clip["size"] == 1000
    assert clip["phone"]["state"] == "none" and clip["upload"]["state"] == "none"


def test_same_size_across_two_listings_is_stable_and_a_change_is_not(store):
    store.apply_inventory(CAM, [item("a.MP4", size=100)])
    rows = store.apply_inventory(CAM, [item("a.MP4", size=100)])
    assert rows[0]["size_stable"] is True
    rows = store.apply_inventory(CAM, [item("a.MP4", size=200)])
    assert rows[0]["size_stable"] is False
    assert clip_of(store, item("a.MP4"))["size"] == 200


def test_size_change_resets_an_unfinished_upload_and_drops_its_staging(store):
    add_dest(store)
    it = item("a.MP4", size=8)
    store.apply_inventory(CAM, [it])
    cid = DashcamStore.clip_id(CAM, it["path"])
    up, _ = store.create_upload(cid, 8, hashlib.sha256(b"x" * 8).hexdigest(), 4)
    store.write_chunk(up["id"], 0, b"xxxx")
    assert store.staging_path(up["id"]).exists()
    store.apply_inventory(CAM, [item("a.MP4", size=12)])
    clip = store.get_clip(cid)
    assert clip["upload"]["state"] == "none" and clip["upload"]["upload_id"] is None
    assert store.get_upload(up["id"]) is None
    assert not store.staging_path(up["id"]).exists()


def test_size_change_keeps_a_finished_upload(store):
    data = b"0123456789"
    it = item("a.MP4", size=len(data))
    dest = add_dest(store)
    cid, _ = upload_clip(store, it, data)
    store.set_destination_state(cid, dest["id"], "done", remote_path="dashcam/x")
    assert store.release_staging_if_done(cid) is True
    store.apply_inventory(CAM, [item("a.MP4", size=99)])
    assert store.get_clip(cid)["upload"]["state"] == "done"


def test_clips_missing_from_a_listing_are_marked_off_camera(store):
    store.apply_inventory(CAM, [item("a.MP4"), item("b.MP4")])
    store.apply_inventory("other-cam", [item("z.MP4")])
    store.apply_inventory(CAM, [item("b.MP4")])
    assert clip_of(store, item("a.MP4"))["on_camera"] is False
    assert clip_of(store, item("b.MP4"))["on_camera"] is True
    assert clip_of(store, item("z.MP4"), camera="other-cam")["on_camera"] is True


def test_invalid_inventory_items_are_skipped_with_warnings(store):
    warnings = []
    rows = store.apply_inventory(CAM, [item("ok.MP4"), {"path": "", "size": 1},
                                       {"path": "/sd/x", "kind": "weird", "size": 1},
                                       {"path": "/sd/y", "kind": "normal"}], warnings=warnings)
    assert [r["path"] for r in rows] == ["/sd/Normal/F/ok.MP4"]
    assert len(warnings) == 3


def test_inventory_start_with_an_offset_is_stored_as_utc(store):
    store.apply_inventory(CAM, [item("a.MP4", start="2026-10-01T15:40:12-05:00")])
    assert clip_of(store, item("a.MP4"))["start"] == "2026-10-01T20:40:12Z"


# ── listing ──────────────────────────────────────────────────────────────────

def _seed_states(store):
    """One clip per listing state; returns {name: clip_id}."""
    dest = add_dest(store)
    ids = {}
    store.apply_inventory(CAM, [
        item("cam_only.MP4", start="2026-10-01T10:00:00Z"),
        item("on_phone.MP4", start="2026-10-01T11:00:00Z"),
        item("uploading.MP4", start="2026-10-01T12:00:00Z", size=4),
        item("uploaded.MP4", start="2026-10-01T13:00:00Z", size=4),
        item("failed.MP4", start="2026-10-01T14:00:00Z", size=4, kind="event"),
    ])
    for name in ("cam_only", "on_phone", "uploading", "uploaded", "failed"):
        kind = "event" if name == "failed" else "normal"
        ids[name] = DashcamStore.clip_id(CAM, item(f"{name}.MP4", kind=kind)["path"])
    store.set_phone_state(ids["on_phone"], "local")
    up, _ = store.create_upload(ids["uploading"], 4, hashlib.sha256(b"abcd").hexdigest(), 4)
    for name in ("uploaded", "failed"):
        u, _ = store.create_upload(ids[name], 4, hashlib.sha256(b"abcd").hexdigest(), 4)
        store.write_chunk(u["id"], 0, b"abcd")
        store.complete_upload(u["id"])
    store.set_destination_state(ids["uploaded"], dest["id"], "done", remote_path="r")
    store.release_staging_if_done(ids["uploaded"])
    store.set_destination_state(ids["failed"], dest["id"], "failed", error="auth failed")
    return ids


@pytest.mark.parametrize("state,expected", [
    ("on_camera_only", {"cam_only"}),
    ("on_phone", {"on_phone"}),
    ("uploading", {"uploading"}),
    ("uploaded", {"uploaded"}),
    ("failed", {"failed"}),
    ("pending_upload", {"cam_only", "on_phone", "uploading", "failed"}),
])
def test_list_state_filters(store, state, expected):
    ids = _seed_states(store)
    clips, _ = store.list_clips(state=state)
    assert {c["id"] for c in clips} == {ids[n] for n in expected}


def test_counts_match_the_filters(store):
    _seed_states(store)
    c = store.counts()
    assert c == {"clips": 5, "on_camera_only": 1, "on_phone": 1, "pending_upload": 4,
                 "uploaded": 1, "failed": 1}


def test_list_is_newest_first_and_pages_by_cursor(store):
    store.apply_inventory(CAM, [item(f"{h:02d}.MP4", start=f"2026-10-01T{h:02d}:00:00Z") for h in range(10)])
    page1, cursor = store.list_clips(limit=4)
    assert [c["name"] for c in page1] == ["09.MP4", "08.MP4", "07.MP4", "06.MP4"]
    page2, cursor = store.list_clips(limit=4, cursor=cursor)
    assert [c["name"] for c in page2] == ["05.MP4", "04.MP4", "03.MP4", "02.MP4"]
    page3, cursor = store.list_clips(limit=4, cursor=cursor)
    assert [c["name"] for c in page3] == ["01.MP4", "00.MP4"] and cursor is None


def test_list_filters_by_kind_lens_time_and_drive(store):
    store.apply_inventory(CAM, [
        item("a.MP4", start="2026-10-01T10:00:00Z"),
        item("b.MP4", kind="event", lens="rear", start="2026-10-01T11:00:00Z"),
        item("c.JPG", kind="photo", start="2026-10-02T11:00:00Z"),
    ])
    assert [c["name"] for c in store.list_clips(kind="event")[0]] == ["b.MP4"]
    assert [c["name"] for c in store.list_clips(lens="rear")[0]] == ["b.MP4"]
    got = store.list_clips(start_from="2026-10-01T10:30:00Z", start_to="2026-10-01T23:59:59Z")[0]
    assert [c["name"] for c in got] == ["b.MP4"]
    store.assign_drive_ids({DashcamStore.clip_id(CAM, item("a.MP4")["path"]): "dr_1_A4-123"})
    assert [c["name"] for c in store.list_clips(drive="dr_1_A4-123")[0]] == ["a.MP4"]


# ── phone state ──────────────────────────────────────────────────────────────

def test_phone_state_transitions(store):
    store.apply_inventory(CAM, [item("a.MP4")])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    for state in ("queued", "downloading", "local", "deleted"):
        assert store.set_phone_state(cid, state)["phone"]["state"] == state
    clip = store.set_phone_state(cid, "failed", "camera went away")
    assert clip["phone"] == {"state": "failed", "error": "camera went away",
                             "updated_at": clip["phone"]["updated_at"]}
    assert store.set_phone_state(cid, "local")["phone"]["error"] is None
    assert store.set_phone_state("c_missing", "local") is None
    with pytest.raises(ValueError):
        store.set_phone_state(cid, "teleported")


# ── fixes ────────────────────────────────────────────────────────────────────

def test_put_fixes_drops_junk_sorts_and_sets_has_gps(store):
    store.apply_inventory(CAM, [item("a.MP4")])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    ok, warnings = store.put_fixes(cid, [
        [T0 + 2, 30.2, -97.7, 10.0, 90.0],
        [T0 + 1, 30.1, -97.7, None, None],
        [T0 + 3, 0, 0, 5.0, 0.0],              # null island
        [T0 + 4, float("nan"), -97.7, 5, 5],   # NaN
        [T0 + 5, 91, -97.7, 5, 5],             # lat out of range
        [T0 + 6, 30, -181, 5, 5],              # lon out of range
        [T0 + 7, 30, -97, 150, 5],             # 150 m/s
        [T0 + 8, 30, -97, 5, 361],             # heading
        [1000.0, 30, -97, 5, 5],               # 1970
        [time.time() + 5 * 86400, 30, -97, 5, 5],  # future
        [T0 + 9, 30, -97],                     # short
        "junk",
    ])
    assert ok is True
    assert len(warnings) >= 1 and "10" in " ".join(warnings)
    assert store.get_fixes(cid) == [[T0 + 1, 30.1, -97.7, None, None], [T0 + 2, 30.2, -97.7, 10.0, 90.0]]
    assert store.get_clip(cid)["has_gps"] is True


def test_put_fixes_all_invalid_clears_has_gps(store):
    store.apply_inventory(CAM, [item("a.MP4")])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    store.put_fixes(cid, [[T0, 30, -97, 1, 1]])
    ok, _ = store.put_fixes(cid, [[T0, 0, 0, 1, 1]])
    assert ok is True
    assert store.get_fixes(cid) == [] and store.get_clip(cid)["has_gps"] is False


def test_put_fixes_rejects_missing_clip_and_huge_lists(store):
    assert store.put_fixes("c_missing", [])[0] is False
    store.apply_inventory(CAM, [item("a.MP4")])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    ok, errors = store.put_fixes(cid, [[T0 + i, 30, -97, 1, 1] for i in range(20001)])
    assert ok is False and errors


# ── thumbnails ───────────────────────────────────────────────────────────────

def test_thumb_accepts_jpeg_and_rejects_png_and_oversize(store):
    store.apply_inventory(CAM, [item("a.MP4")])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    assert store.thumb_path(cid) is None
    assert store.put_thumb(cid, PNG)[0] is False
    assert store.put_thumb(cid, b"\xff\xd8" + b"\x00" * (512 * 1024))[0] is False
    assert store.put_thumb("c_missing", JPEG)[0] is False
    assert store.put_thumb(cid, JPEG) == (True, None)
    assert store.thumb_path(cid).read_bytes() == JPEG
    assert store.get_clip(cid)["has_thumb"] is True


# ── uploads ──────────────────────────────────────────────────────────────────

def test_create_upload_resumes_the_same_open_upload(store):
    add_dest(store)
    store.apply_inventory(CAM, [item("a.MP4", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    sha = hashlib.sha256(b"0123456789").hexdigest()
    up, err = store.create_upload(cid, 10, sha, 4)
    assert err is None and re.fullmatch(r"u_[0-9a-f]+", up["id"])
    assert up["chunk_size"] == 4 and up["received"] == [] and up["chunks"] == 3
    store.write_chunk(up["id"], 1, b"4567")
    again, err = store.create_upload(cid, 10, sha, 4)
    assert err is None and again["id"] == up["id"] and again["received"] == [1]
    assert store.get_clip(cid)["upload"]["state"] == "staging"


def test_a_stalled_upload_restarts_at_the_chunk_size_asked_for(store):
    # Over weak LTE a 16 MiB chunk never finished; the phone now asks for smaller ones.
    add_dest(store)
    store.apply_inventory(CAM, [item("a.MP4", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    sha = hashlib.sha256(b"0123456789").hexdigest()
    stalled, _ = store.create_upload(cid, 10, sha, 8)
    smaller, err = store.create_upload(cid, 10, sha, 4)
    assert err is None and smaller["id"] != stalled["id"] and smaller["chunk_size"] == 4
    store.write_chunk(smaller["id"], 0, b"0123")
    kept, _ = store.create_upload(cid, 10, sha, 8)      # chunks are in: keep its size, lose nothing
    assert kept["id"] == smaller["id"] and kept["received"] == [0]


def test_create_upload_with_a_new_hash_replaces_the_old_upload(store):
    add_dest(store)
    store.apply_inventory(CAM, [item("a.MP4", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    old, _ = store.create_upload(cid, 10, "a" * 64, 4)
    store.write_chunk(old["id"], 0, b"0123")
    new, err = store.create_upload(cid, 10, "b" * 64, 4)
    assert err is None and new["id"] != old["id"]
    assert store.get_upload(old["id"]) is None and not store.staging_path(old["id"]).exists()


def test_create_upload_validates(store):
    store.apply_inventory(CAM, [item("a.MP4", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    assert store.create_upload("c_missing", 10, "a" * 64, 4) == (None, "clip_not_found")
    assert store.create_upload(cid, 0, "a" * 64, 4)[1] == "bad_request"
    assert store.create_upload(cid, 10, "not-a-sha", 4)[1] == "bad_request"


def test_staging_cap_is_enforced(store):
    add_dest(store)
    store.update_settings({"staging_cap_bytes": 256 * 1024 * 1024})
    store.apply_inventory(CAM, [item("a.MP4"), item("b.MP4"), item("c.MP4")])
    a, b, c = (DashcamStore.clip_id(CAM, item(n)["path"]) for n in ("a.MP4", "b.MP4", "c.MP4"))
    mib = 1024 * 1024
    assert store.create_upload(a, 200 * mib, "a" * 64, 16 * mib)[1] is None
    assert store.create_upload(b, 100 * mib, "b" * 64, 16 * mib) == (None, "staging_full")
    assert store.create_upload(c, 300 * mib, "c" * 64, 16 * mib) == (None, "too_large")
    assert store.staging_bytes() == 200 * mib


def test_idle_unfinished_uploads_are_purged_when_space_is_needed(store):
    add_dest(store)
    store.update_settings({"staging_cap_bytes": 256 * 1024 * 1024})
    store.apply_inventory(CAM, [item("a.MP4"), item("b.MP4")])
    a, b = (DashcamStore.clip_id(CAM, item(n)["path"]) for n in ("a.MP4", "b.MP4"))
    mib = 1024 * 1024
    old, _ = store.create_upload(a, 200 * mib, "a" * 64, 16 * mib)
    doc = store.get_upload(old["id"])
    doc["updated_at"] = time.time() - 3 * 86400
    ds._write_json(store._upload_path(old["id"]), doc)
    new, err = store.create_upload(b, 100 * mib, "b" * 64, 16 * mib)
    assert err is None and store.get_upload(old["id"]) is None
    assert store.get_clip(a)["upload"]["state"] == "none"


def test_write_chunk_out_of_order_duplicate_and_short_last(store):
    add_dest(store)
    data = b"0123456789"
    store.apply_inventory(CAM, [item("a.MP4", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    up, _ = store.create_upload(cid, 10, hashlib.sha256(data).hexdigest(), 4)
    assert store.write_chunk(up["id"], 2, b"89")[0]["received"] == [2]
    assert store.write_chunk(up["id"], 0, b"0123")[0]["received"] == [0, 2]
    assert store.write_chunk(up["id"], 0, b"0123")[0]["received"] == [0, 2]
    assert store.write_chunk(up["id"], 1, b"456")[1] == "bad_chunk_length"
    assert store.write_chunk(up["id"], 2, b"89x")[1] == "bad_chunk_length"
    assert store.write_chunk(up["id"], 3, b"")[1] == "bad_chunk_index"
    assert store.write_chunk("u_missing", 0, b"0123")[1] == "upload_not_found"
    store.write_chunk(up["id"], 1, b"4567")
    clip, err = store.complete_upload(up["id"])
    assert err is None and clip["upload"]["state"] == "staged"
    assert store.staging_path(up["id"]).read_bytes() == data


def test_complete_upload_checks_chunks_and_hash(store):
    add_dest(store)
    data = b"0123456789"
    store.apply_inventory(CAM, [item("a.MP4", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    up, _ = store.create_upload(cid, 10, hashlib.sha256(b"something else").hexdigest(), 4)
    store.write_chunk(up["id"], 0, b"0123")
    assert store.complete_upload(up["id"])[1] == "missing_chunks"
    store.write_chunk(up["id"], 1, b"4567")
    store.write_chunk(up["id"], 2, b"89")
    clip, err = store.complete_upload(up["id"])
    assert clip is None and err == "sha256_mismatch"
    assert store.get_clip(cid)["upload"]["state"] == "staging"
    # The bad bytes are forgotten so a resume re-sends every chunk.
    assert store.get_upload(up["id"])["received"] == []
    assert store.complete_upload("u_missing")[1] == "upload_not_found"


def test_complete_marks_matching_enabled_destinations_pending(store):
    events_only = add_dest(store, "Events", kinds=["event"])
    everything = add_dest(store, "NAS")
    off = add_dest(store, "Off", enabled=False)
    cid, up = upload_clip(store, item("a.MP4", size=10), b"0123456789")
    clip = store.get_clip(cid)
    assert set(clip["destinations"]) == {everything["id"]}
    entry = clip["destinations"][everything["id"]]
    assert entry["state"] == "pending" and entry["attempts"] == 0 and entry["error"] is None
    assert clip["upload"] == {"state": "staged", "upload_id": up["id"], "bytes": 10,
                              "sha256": hashlib.sha256(b"0123456789").hexdigest()}
    assert events_only["id"] not in clip["destinations"] and off["id"] not in clip["destinations"]


def test_create_after_complete_reports_complete_instead_of_restarting(store):
    data = b"0123456789"
    dest = add_dest(store)
    cid, up = upload_clip(store, item("a.MP4", size=10), data)
    sha = hashlib.sha256(data).hexdigest()
    again, err = store.create_upload(cid, 10, sha, 4)
    assert err is None and again["id"] == up["id"] and again["complete"] is True
    assert again["received"] == [0, 1, 2]
    assert store.complete_upload(up["id"])[1] is None  # idempotent
    store.set_destination_state(cid, dest["id"], "done", remote_path="r")
    store.release_staging_if_done(cid)
    assert store.create_upload(cid, 10, sha, 4) == (None, "already_uploaded")


def test_release_staging_only_when_every_destination_is_done(store):
    a = add_dest(store, "A")
    b = add_dest(store, "B")
    cid, up = upload_clip(store, item("a.MP4", size=10), b"0123456789")
    store.set_destination_state(cid, a["id"], "done", remote_path="x/a.MP4")
    store.set_destination_state(cid, b["id"], "failed", error="bad password")
    assert store.release_staging_if_done(cid) is False
    assert store.staging_path(up["id"]).exists()
    assert store.get_clip(cid)["destinations"][a["id"]]["remote_path"] == "x/a.MP4"
    store.set_destination_state(cid, b["id"], "done")
    assert store.release_staging_if_done(cid) is True
    assert not store.staging_path(up["id"]).exists() and store.get_upload(up["id"]) is None
    clip = store.get_clip(cid)
    assert clip["upload"]["state"] == "done"
    assert store.list_clips(state="uploaded")[0][0]["id"] == cid


def test_a_destination_update_for_another_upload_is_ignored(store):
    dest = add_dest(store)
    cid, up = upload_clip(store, item("a.MP4", size=10), b"0123456789")
    assert store.set_destination_state(cid, dest["id"], "done", remote_path="x", upload_id="u_00000000000000ff") is None
    entry = store.get_clip(cid)["destinations"][dest["id"]]
    assert entry["state"] == "pending" and entry["remote_path"] is None
    assert store.release_staging_if_done(cid) is False
    clip = store.set_destination_state(cid, dest["id"], "done", remote_path="x", upload_id=up["id"])
    assert clip["destinations"][dest["id"]]["state"] == "done"


def test_deleting_a_failing_destination_lets_staging_go(store):
    a = add_dest(store, "A")
    b = add_dest(store, "B")
    cid, up = upload_clip(store, item("a.MP4", size=10), b"0123456789")
    store.set_destination_state(cid, a["id"], "done")
    store.set_destination_state(cid, b["id"], "failed", error="bad password")
    assert store.delete_destination(b["id"]) is True
    assert store.release_staging_if_done(cid) is True


def test_release_needs_at_least_one_destination(store):
    dest = add_dest(store)
    cid, up = upload_clip(store, item("a.MP4", size=10), b"0123456789")
    store.delete_destination(dest["id"])
    assert store.release_staging_if_done(cid) is False
    assert store.get_clip(cid)["upload"]["state"] == "staged"


def test_staged_clip_ids_lists_completed_uploads_only(store):
    add_dest(store)
    cid, _ = upload_clip(store, item("a.MP4", size=10), b"0123456789")
    store.apply_inventory(CAM, [item("a.MP4", size=10), item("b.MP4", size=10)])
    other = DashcamStore.clip_id(CAM, item("b.MP4")["path"])
    store.create_upload(other, 10, "a" * 64, 4)
    assert store.staged_clip_ids() == [cid]


def test_upload_is_refused_when_no_enabled_destination_takes_the_kind(store):
    store.apply_inventory(CAM, [item("a.MP4", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    sha = hashlib.sha256(b"0123456789").hexdigest()
    assert store.create_upload(cid, 10, sha, 4) == (None, "no_destination")
    add_dest(store, "Events", kinds=["event"])
    off = add_dest(store, "Off", enabled=False)
    assert store.create_upload(cid, 10, sha, 4) == (None, "no_destination")
    assert store.staging_bytes() == 0 and store.get_clip(cid)["upload"]["state"] == "none"
    store.update_destination(off["id"], {"enabled": True})
    up, err = store.create_upload(cid, 10, sha, 4)
    assert err is None and up["chunks"] == 3


def test_abandon_upload_resets_a_staged_clip_no_destination_takes(store):
    dest = add_dest(store)
    cid, up = upload_clip(store, item("a.MP4", size=10), b"0123456789")
    assert store.abandon_upload(cid) is False          # its destination still takes it
    store.update_destination(dest["id"], {"enabled": False})
    assert store.abandon_upload(cid) is True
    clip = store.get_clip(cid)
    assert clip["upload"] == {"state": "none", "upload_id": None, "bytes": 0, "sha256": None}
    assert clip["destinations"] == {} and store.is_uploaded(clip) is False
    assert store.get_upload(up["id"]) is None and not store.staging_path(up["id"]).exists()
    assert store.staged_clip_ids() == [] and store.staging_bytes() == 0
    assert store.abandon_upload(cid) is False          # nothing staged any more
    assert store.abandon_upload("c_missing") is False


def test_low_free_disk_is_staging_full(store, monkeypatch):
    add_dest(store)
    store.apply_inventory(CAM, [item("a.MP4", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    assert ds.DISK_RESERVE_BYTES == 2 * 1024 ** 3
    monkeypatch.setattr(ds, "DISK_RESERVE_BYTES", 1 << 62)   # more than any disk has free
    assert store.create_upload(cid, 10, "a" * 64, 4) == (None, "staging_full")
    assert store.get_clip(cid)["upload"]["state"] == "none"
    monkeypatch.setattr(ds, "DISK_RESERVE_BYTES", 0)
    assert store.create_upload(cid, 10, "a" * 64, 4)[1] is None


def test_a_chunk_racing_a_dropped_upload_leaves_no_orphan(store, monkeypatch):
    add_dest(store)
    data = b"01234567"
    store.apply_inventory(CAM, [item("a.MP4", size=8)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    up, _ = store.create_upload(cid, 8, hashlib.sha256(data).hexdigest(), 4)
    part = store.staging_path(up["id"])
    real_path = store.staging_path
    fired = []

    def racing(upload_id):
        if not fired:   # the next camera listing shows a new size between the check and the write
            fired.append(1)
            store.apply_inventory(CAM, [item("a.MP4", size=200)])
        return real_path(upload_id)

    monkeypatch.setattr(store, "staging_path", racing)
    assert store.write_chunk(up["id"], 1, data[4:])[1] == "upload_not_found"
    assert fired and not part.exists()


def test_create_upload_makes_the_part_file_up_front(store):
    add_dest(store)
    store.apply_inventory(CAM, [item("a.MP4", size=8)])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    up, _ = store.create_upload(cid, 8, "a" * 64, 4)
    assert store.staging_path(up["id"]).is_file()


def test_a_retried_complete_never_resets_destinations_in_flight(store, monkeypatch):
    dest = add_dest(store)
    cid, up = upload_clip(store, item("a.MP4", size=10), b"0123456789")
    store.set_destination_state(cid, dest["id"], "uploading", remote_path="r", upload_id=up["id"])
    stale = dict(store.get_upload(up["id"]), completed_at=None, complete=False)
    real_get = store.get_upload
    calls = []

    def first_call_stale(upload_id):   # the retry read the upload just before the first finished
        calls.append(upload_id)
        return dict(stale) if len(calls) == 1 else real_get(upload_id)

    monkeypatch.setattr(store, "get_upload", first_call_stale)
    clip, err = store.complete_upload(up["id"])
    assert err is None and clip["upload"]["state"] == "staged"
    assert store.get_clip(cid)["destinations"][dest["id"]]["state"] == "uploading"


# ── remux to MP4 ─────────────────────────────────────────────────────────────

def test_a_ts_upload_is_remuxed_to_mp4_before_it_is_staged(store, tmp_path):
    data = make_ts(tmp_path / "in.ts")
    dest = add_dest(store)
    cid, up = upload_clip(store, item("2026-10-02_13_19_31_f.ts", size=len(data)), data, chunk_size=16384)
    clip = store.get_clip(cid)
    assert clip["container"] == "mp4" and clip["staged_name"] == "2026-10-02_13_19_31_f.mp4"
    assert clip["name"] == "2026-10-02_13_19_31_f.ts"                      # the camera's name stays
    assert clip["upload"]["state"] == "staged" and clip["upload"]["bytes"] == len(data)
    assert clip["upload"]["sha256"] == hashlib.sha256(data).hexdigest()    # what the phone sent
    mp4 = store.staged_file(up["id"])
    assert mp4 == store.remuxed_path(up["id"]) and staging_names(store) == [mp4.name]   # .ts and temp gone
    assert mp4.read_bytes()[4:8] == b"ftyp"
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name:format=format_name",
                            "-of", "json", str(mp4)], capture_output=True, text=True)
    info = json.loads(probe.stdout)
    assert "mp4" in info["format"]["format_name"]
    assert sorted(s["codec_name"] for s in info["streams"]) == ["aac", "h264"]
    up_doc = store.get_upload(up["id"])
    assert up_doc["remuxed"] is True and up_doc["staged_size"] == mp4.stat().st_size
    assert store.staging_bytes() == mp4.stat().st_size != len(data)        # the real size on disk
    store.set_destination_state(cid, dest["id"], "done", remote_path="x.mp4")
    assert store.release_staging_if_done(cid) is True
    assert staging_names(store) == [] and store.staging_bytes() == 0
    assert store.get_clip(cid)["container"] == "mp4"                        # still what destinations have


def test_a_failed_remux_keeps_the_ts_and_the_upload_still_completes(store, monkeypatch, caplog):
    monkeypatch.setattr(dashcam_remux.shutil, "which", lambda name: f"/usr/bin/{name}")
    ran = []

    def run(cmd, **kwargs):
        ran.append(cmd[0])
        if cmd[0].endswith("ffprobe"):
            streams = [{"codec_type": "video", "codec_name": "h264"}, {"codec_type": "audio", "codec_name": "aac"}]
            return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps({"streams": streams}), stderr="")
        Path(cmd[-1]).write_bytes(b"half an mp4")          # ffmpeg died part-way through a corrupt clip
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="Invalid data found when processing input")

    monkeypatch.setattr(dashcam_remux.subprocess, "run", run)
    data = b"\x47" + b"t" * 99
    add_dest(store)
    with caplog.at_level(logging.WARNING):
        cid, up = upload_clip(store, item("a.ts", size=len(data)), data, chunk_size=64)
    assert ran == ["/usr/bin/ffprobe", "/usr/bin/ffmpeg"]
    clip = store.get_clip(cid)
    assert clip["upload"]["state"] == "staged" and clip["container"] == "ts" and clip["staged_name"] == "a.ts"
    assert list(clip["destinations"].values())[0]["state"] == "pending"
    part = store.staging_path(up["id"])
    assert store.staged_file(up["id"]) == part and part.read_bytes() == data
    assert staging_names(store) == [part.name]                  # the half-written MP4 is gone
    assert store.get_upload(up["id"])["remuxed"] is False and store.staging_bytes() == len(data)
    assert "Invalid data found" in caplog.text and "keeping the .ts" in caplog.text


def test_without_ffmpeg_ts_clips_are_staged_as_they_are_and_it_is_warned_once(store, monkeypatch, caplog):
    monkeypatch.setattr(dashcam_remux.shutil, "which", lambda name: None)
    monkeypatch.setattr(dashcam_remux, "_warned_missing", False)
    monkeypatch.setattr(dashcam_remux.subprocess, "run", lambda *a, **k: pytest.fail("ran without ffmpeg"))
    add_dest(store)
    with caplog.at_level(logging.WARNING):
        for name in ("a.ts", "b.ts"):
            data = name.encode() * 10
            cid, up = upload_clip(store, item(name, size=len(data)), data, chunk_size=64)
            clip = store.get_clip(cid)
            assert clip["upload"]["state"] == "staged" and clip["container"] == "ts" and clip["staged_name"] == name
            assert store.staged_file(up["id"]).read_bytes() == data
    assert sum("ffmpeg/ffprobe not found" in r.getMessage() for r in caplog.records) == 1
    assert "keeping the .ts" not in caplog.text


def test_clips_that_are_not_ts_are_staged_without_a_remux(store, fake_remux):
    add_dest(store)
    cid, up = upload_clip(store, item("2026_1001_154012_F.MP4", size=10), b"0123456789")
    clip = store.get_clip(cid)
    assert fake_remux.calls == [] and clip["container"] == "mp4" and clip["staged_name"] == "2026_1001_154012_F.MP4"
    assert store.staged_file(up["id"]) == store.staging_path(up["id"]) and store.get_upload(up["id"])["remuxed"] is False


def test_clip_fields_start_empty_and_reset_with_the_upload(store, fake_remux):
    dest = add_dest(store)
    store.apply_inventory(CAM, [item("a.ts", size=10)])
    clip = clip_of(store, item("a.ts"))
    assert clip["container"] is None and clip["staged_name"] is None
    cid, up = upload_clip(store, item("a.ts", size=10), b"0123456789")
    assert store.get_clip(cid)["container"] == "mp4"
    (store.base / "staging" / f"{up['id']}.0badc0de.mp4.tmp").write_bytes(b"left by a crash")
    store.apply_inventory(CAM, [item("a.ts", size=12)])            # the camera was still writing it
    clip = store.get_clip(cid)
    assert clip["container"] is None and clip["staged_name"] is None and staging_names(store) == []
    cid, up = upload_clip(store, item("a.ts", size=12), b"0123456789ab")
    store.update_destination(dest["id"], {"enabled": False})
    assert store.abandon_upload(cid) is True
    assert store.get_clip(cid)["container"] is None and staging_names(store) == []


def test_an_upload_dropped_during_its_remux_leaves_nothing_behind(store, fake_remux):
    add_dest(store)
    data = b"0123456789"
    store.apply_inventory(CAM, [item("a.ts", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.ts")["path"])
    up, _ = store.create_upload(cid, 10, hashlib.sha256(data).hexdigest(), 4)
    for n in range(3):
        store.write_chunk(up["id"], n, data[n * 4:(n + 1) * 4])
    fake_remux.during = lambda: store.apply_inventory(CAM, [item("a.ts", size=99)])
    assert store.complete_upload(up["id"]) == (None, "upload_not_found")
    assert staging_names(store) == [] and store.get_clip(cid)["upload"]["state"] == "none"


def test_a_complete_racing_another_discards_its_own_remux(store, fake_remux):
    dest = add_dest(store)
    data = b"0123456789"
    store.apply_inventory(CAM, [item("a.ts", size=10)])
    cid = DashcamStore.clip_id(CAM, item("a.ts")["path"])
    up, _ = store.create_upload(cid, 10, hashlib.sha256(data).hexdigest(), 4)
    for n in range(3):
        store.write_chunk(up["id"], n, data[n * 4:(n + 1) * 4])

    def the_other_complete_wins():
        clip, err = store.complete_upload(up["id"])
        assert err is None and clip["container"] == "mp4"
        store.set_destination_state(cid, dest["id"], "uploading", remote_path="r", upload_id=up["id"])

    fake_remux.during = the_other_complete_wins
    clip, err = store.complete_upload(up["id"])
    assert err is None and len(fake_remux.calls) == 2
    assert fake_remux.calls[0][1] != fake_remux.calls[1][1]          # each remux writes its own temp file
    assert staging_names(store) == [store.remuxed_path(up["id"]).name]
    assert store.get_clip(cid)["destinations"][dest["id"]]["state"] == "uploading"


def test_remux_staged_brings_a_clip_staged_before_remuxing_in_line(store, fake_remux):
    add_dest(store)
    fake_remux.fail = dashcam_remux.NOT_INSTALLED     # staged as a .ts ...
    cid, up = upload_clip(store, item("a.ts", size=10), b"0123456789")
    make_legacy(store, cid, up["id"])                 # ... before anything was recorded about it
    fake_remux.fail = None
    assert store.remux_staged(cid) is True
    clip = store.get_clip(cid)
    assert clip["container"] == "mp4" and clip["staged_name"] == "a.mp4" and clip["upload"]["state"] == "staged"
    assert store.staged_file(up["id"]) == store.remuxed_path(up["id"])
    assert staging_names(store) == [store.remuxed_path(up["id"]).name]
    assert store.staging_bytes() == len(FakeRemux.output)
    assert store.remux_staged(cid) is False and len(fake_remux.calls) == 2   # once is enough
    assert store.remux_staged("c_missing") is False


def test_remux_staged_records_a_ts_it_cannot_remux_and_leaves_fresh_uploads_alone(store, fake_remux):
    add_dest(store)
    cid, up = upload_clip(store, item("a.ts", size=10), b"0123456789")
    assert store.remux_staged(cid) is False and len(fake_remux.calls) == 1   # recorded at completion
    other, up2 = upload_clip(store, item("b.ts", size=10), b"abcdefghij")
    make_legacy(store, other, up2["id"])
    store.remuxed_path(up2["id"]).unlink()            # a legacy staged .ts: only the .part
    store.staging_path(up2["id"]).write_bytes(b"abcdefghij")
    fake_remux.fail = "ffprobe failed: Invalid data found when processing input"
    assert store.remux_staged(other) is True
    clip = store.get_clip(other)
    assert clip["container"] == "ts" and clip["staged_name"] == "b.ts"
    assert store.staged_file(up2["id"]).read_bytes() == b"abcdefghij"
    assert store.remux_staged(other) is False


@pytest.mark.parametrize("streams,wanted,unwanted", [
    ([("video", "hevc"), ("audio", "aac")], ["-tag:v", "hvc1", "-bsf:a", "aac_adtstoasc"], []),
    ([("video", "h264"), ("audio", "aac")], ["-bsf:a", "aac_adtstoasc"], ["-tag:v"]),
    ([("video", "h264"), ("audio", "mp2")], [], ["-tag:v", "-bsf:a"]),   # the AAC filter refuses other audio
    ([("video", "h264"), ("data", "bin_data")], [], ["-tag:v", "-bsf:a"]),
])
def test_remux_command(tmp_path, monkeypatch, streams, wanted, unwanted):
    monkeypatch.setattr(dashcam_remux.shutil, "which", lambda name: f"/usr/bin/{name}")
    cmds = []

    def run(cmd, **kwargs):
        cmds.append(cmd)
        assert kwargs["timeout"] and kwargs["stdin"] == subprocess.DEVNULL
        if cmd[0].endswith("ffprobe"):
            out = {"streams": [{"codec_type": t, "codec_name": c} for t, c in streams]}
            return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(out), stderr="")
        Path(cmd[-1]).write_bytes(b"mp4")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(dashcam_remux.subprocess, "run", run)
    src, dst = tmp_path / "u.part", tmp_path / "u.mp4.tmp"
    assert dashcam_remux.remux(src, dst) is None
    cmd = cmds[1]
    text = " ".join(cmd)
    assert cmd[:6] == ["/usr/bin/ffmpeg", "-nostdin", "-v", "error", "-y", "-i"] and cmd[6] == str(src)
    assert "-map 0:v -map 0:a? -c copy" in text and "-movflags +faststart" in text
    assert cmd[-3:] == ["-f", "mp4", str(dst)]
    for flag in wanted:
        assert flag in cmd
    for flag in unwanted:
        assert flag not in cmd


def test_remux_failures_leave_no_output(tmp_path, monkeypatch):
    monkeypatch.setattr(dashcam_remux.shutil, "which", lambda name: f"/usr/bin/{name}")
    dst = tmp_path / "out.tmp"
    video = json.dumps({"streams": [{"codec_type": "video", "codec_name": "h264"}]})

    def runner(ffmpeg):
        def run(cmd, **kwargs):
            if cmd[0].endswith("ffprobe"):
                return subprocess.CompletedProcess(cmd, 0, stdout=video, stderr="")
            return ffmpeg(cmd)
        return run

    def silent(cmd):                       # exit 0 but nothing written
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    def slow(cmd):
        Path(cmd[-1]).write_bytes(b"partial")
        raise subprocess.TimeoutExpired(cmd, 300)

    for ffmpeg, why in ((silent, "ffmpeg wrote nothing"), (slow, "ffmpeg timed out")):
        monkeypatch.setattr(dashcam_remux.subprocess, "run", runner(ffmpeg))
        assert dashcam_remux.remux(tmp_path / "in.ts", dst).startswith(why)
        assert not dst.exists()
    monkeypatch.setattr(dashcam_remux.subprocess, "run", lambda cmd, **k: subprocess.CompletedProcess(
        cmd, 0, stdout=json.dumps({"streams": [{"codec_type": "audio", "codec_name": "aac"}]}), stderr=""))
    assert dashcam_remux.remux(tmp_path / "in.ts", dst) == "no video stream"


def test_mp4_name():
    assert dashcam_remux.mp4_name("2026-10-02_13_19_31_f.ts") == "2026-10-02_13_19_31_f.mp4"
    assert dashcam_remux.mp4_name("X.TS") == "X.mp4"
    assert dashcam_remux.mp4_name("2026_1001_154012_F.MP4") == "2026_1001_154012_F.MP4"
    assert dashcam_remux.is_ts("a.ts") and not dashcam_remux.is_ts("a.tsx") and not dashcam_remux.is_ts(None)


# ── destinations ─────────────────────────────────────────────────────────────

def test_destinations_store_metadata_never_secrets(store):
    dest = store.add_destination({"type": "sftp", "name": "NAS", "path": "/dashcam", "host": "nas.local",
                                  "port": 22, "user": "pranav", "password": "hunter2", "token": "{}",
                                  "remote": "jc_x"})
    assert re.fullmatch(r"d_[0-9a-f]{8}", dest["id"])
    assert dest["enabled"] is True and set(dest["kinds"]) == {"normal", "event", "parking", "photo"}
    assert dest["status"] == "new" and dest["error"] is None and dest["created_at"]
    raw = (store.base / "destinations.json").read_text()
    assert "hunter2" not in raw and "password" not in raw and "token" not in raw
    assert store.update_destination(dest["id"], {"enabled": False, "password": "x"})["enabled"] is False
    assert "password" not in store.destinations()[0]
    assert store.update_destination("d_missing", {}) is None
    assert store.delete_destination(dest["id"]) is True and store.destinations() == []
    assert store.delete_destination(dest["id"]) is False


def test_add_destination_keeps_a_valid_preassigned_id(store):
    did = store.new_destination_id()
    assert store.add_destination({"id": did, "type": "ftp", "name": "F", "path": "x"})["id"] == did


# ── cameras, settings, snapshot ──────────────────────────────────────────────

def test_upsert_camera_merges_and_drops_secrets(store):
    store.upsert_camera({"id": CAM, "model": "A4", "ssid": "A4_1234", "wifi_password": "12345678"})
    cam = store.upsert_camera({"id": CAM, "firmware": "1.2", "sd": {"free": 5}})
    assert cam["model"] == "A4" and cam["firmware"] == "1.2" and cam["sd"] == {"free": 5}
    assert cam["last_seen"] and "wifi_password" not in cam
    assert "12345678" not in (store.base / "cameras.json").read_text()
    with pytest.raises(ValueError):
        store.upsert_camera({"model": "no id"})
    assert [c["id"] for c in store.cameras()] == [CAM]


def test_upload_rules_validate(store):
    saved, errors = store.update_settings({"rules": {"upload": False, "upload_data": "events", "upload_when": "parked"}})
    assert errors == [] and saved["rules"]["upload"] is False
    assert saved["rules"]["upload_data"] == "events" and saved["rules"]["upload_when"] == "parked"
    _, errors = store.update_settings({"rules": {"upload": "yes", "upload_data": "lte", "upload_when": "soon"}})
    assert len(errors) == 3


def test_settings_defaults_and_validation(store):
    s = store.get_settings()
    assert s["rules"] == ds.DEFAULT_SETTINGS["rules"]
    assert s["staging_cap_bytes"] == 4 * 1024 ** 3
    saved, errors = store.update_settings({"rules": {"normal": "front", "keep_on_phone": True}})
    assert errors == [] and saved["rules"]["normal"] == "front" and saved["rules"]["normal_when"] == "any"
    assert store.get_settings()["rules"]["keep_on_phone"] is True
    for bad in ({"rules": {"normal": "rear"}}, {"rules": {"normal_when": "sometimes"}},
                {"rules": {"phone_cap_gb": 0}}, {"rules": {"phone_cap_gb": 600}},
                {"rules": {"keep_on_phone": "yes"}}, {"staging_cap_bytes": 1024},
                {"staging_cap_bytes": 65 * 1024 ** 3}, {"rules": {"surprise": 1}}, {"surprise": 1}):
        saved, errors = store.update_settings(bad)
        assert saved is None and errors, bad
    assert store.get_settings()["rules"]["normal"] == "front"


def test_snapshot_shape(store):
    store.upsert_camera({"id": CAM})
    snap = store.snapshot()
    assert set(snap) == {"cameras", "settings", "destinations", "counts", "staging"}
    assert snap["staging"] == {"bytes": 0, "cap": 4 * 1024 ** 3}


def test_corrupt_files_read_as_empty(store):
    store.apply_inventory(CAM, [item("a.MP4")])
    cid = DashcamStore.clip_id(CAM, item("a.MP4")["path"])
    store.base.mkdir(parents=True, exist_ok=True)
    for name in ("cameras.json", "settings.json", "destinations.json", "drives.json"):
        (store.base / name).write_text("{not json")
    (store.base / "clips" / f"{cid}.json").write_text("[1, 2")
    (store.base / "fixes").mkdir(exist_ok=True)
    (store.base / "fixes" / f"{cid}.json").write_text("nope")
    assert store.cameras() == [] and store.destinations() == []
    assert store.get_settings()["rules"] == ds.DEFAULT_SETTINGS["rules"]
    assert store.get_clip(cid) is None and store.get_fixes(cid) == []
    assert store.list_clips() == ([], None) and store.drives() == []


def test_drives_round_trip(store):
    store.write_drives([{"id": "dr_2", "start": "2026-10-01T10:00:00Z"},
                        {"id": "dr_1", "start": "2026-09-30T10:00:00Z"}])
    assert [d["id"] for d in store.drives()] == ["dr_2", "dr_1"]
    assert store.get_drive("dr_1")["start"] == "2026-09-30T10:00:00Z"
    assert store.get_drive("dr_missing") is None


def test_ids_with_path_tricks_never_leave_the_store(store, tmp_path):
    assert store.get_clip("../../etc/passwd") is None
    assert store.get_upload("../x") is None
    assert tmp_path in store.staging_path("../../x").parents
