"""GET /api/devices?skills=0 leaves out each device's skill catalogue.

The phone's own catalogue is ~90 KB of the ~117 KB list, and its dashboard, voice strip,
pod list and desktop picker fetched it ~40 times an hour to read names, kinds and who's
online. The default (the web UI, the phone's device ACL page) keeps the skills.
"""

import json
import time
import urllib.request

from tests._pytest_port import BASE
from tests.conftest import TEST_STATE_DIR


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=10) as r:
        return json.loads(r.read())


def test_skills_0_leaves_out_the_skill_catalogues_and_the_default_keeps_them():
    devices_file = TEST_STATE_DIR / ".devices.json"
    before = devices_file.read_text(encoding="utf-8") if devices_file.exists() else None
    now = time.time()
    devices_file.write_text(json.dumps({"devices": [
        {"id": "dev-skills-test", "name": "Test phone", "kind": "mobile", "last_seen": now, "paired_at": now},
    ]}), encoding="utf-8")
    try:
        full = {d["id"]: d for d in get("/api/devices")["devices"]}
        brief = {d["id"]: d for d in get("/api/devices?skills=0")["devices"]}
        assert "skills" in full["dev-skills-test"]
        assert "skills" not in brief["dev-skills-test"]
        # Everything else a brief caller reads is still there.
        for key in ("id", "name", "kind", "online", "bridge_connected", "invokable", "sync_capable"):
            assert key in brief["dev-skills-test"], key
    finally:
        if before is None:
            devices_file.unlink(missing_ok=True)
        else:
            devices_file.write_text(before, encoding="utf-8")
