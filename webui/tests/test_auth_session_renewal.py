"""A paired device's session is renewed while the device is in use.

Sessions had a fixed 30-day life. Nothing renewed them, so every paired device
(the iPhone, the Mac client, the Pod) fell off the device bridge 30 days after
pairing: the Mac's relay started answering 401 (Cloudflare shows it as a 502)
and the phone's device tools would have followed two days later.
"""
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from urllib.parse import urlparse

_TEST_STATE = Path(tempfile.mkdtemp())
os.environ["HERMES_WEBUI_STATE_DIR"] = str(_TEST_STATE)

sys.path.insert(0, str(Path(__file__).parent.parent))

import api.auth as auth
import api.pairing as pairing


def _token(cookie: str) -> str:
    return cookie.rsplit(".", 1)[0]


class TestRenewSession(unittest.TestCase):
    def setUp(self) -> None:
        auth._sessions.clear()

    def test_slides_an_ageing_session_to_a_full_ttl(self) -> None:
        cookie = auth.create_session()
        auth._sessions[_token(cookie)] = time.time() + 3600  # an hour left
        self.assertTrue(auth.renew_session(cookie))
        left = auth._sessions[_token(cookie)] - time.time()
        self.assertGreater(left, auth._resolve_session_ttl() - 60)

    def test_an_expired_session_is_not_revived(self) -> None:
        cookie = auth.create_session()
        auth._sessions[_token(cookie)] = time.time() - 1
        self.assertFalse(auth.renew_session(cookie))
        self.assertNotIn(_token(cookie), auth._sessions)

    def test_a_forged_cookie_is_not_renewed(self) -> None:
        cookie = auth.create_session()
        forged = _token(cookie) + "." + "0" * 64
        self.assertFalse(auth.renew_session(forged))

    def test_a_fresh_session_is_not_rewritten(self) -> None:
        cookie = auth.create_session()
        with mock.patch.object(auth, "_save_sessions") as save:
            self.assertTrue(auth.renew_session(cookie))
        save.assert_not_called()


class TestCheckAuthRenews(unittest.TestCase):
    """check_auth renews paired devices' sessions, and only theirs."""

    def setUp(self) -> None:
        auth._sessions.clear()

    def _request(self, cookie: str) -> bool:
        handler = SimpleNamespace(headers={"Cookie": f"{auth.COOKIE_NAME}={cookie}"})
        with mock.patch.object(auth, "is_auth_enabled", return_value=True):
            return auth.check_auth(handler, urlparse("/api/sessions"))

    def _ageing_session(self) -> str:
        cookie = auth.create_session()
        auth._sessions[_token(cookie)] = time.time() + 3600
        return cookie

    def test_a_paired_devices_session_is_renewed(self) -> None:
        cookie = self._ageing_session()
        with mock.patch.object(pairing, "touch_device_by_session", return_value="dev-1"):
            self.assertTrue(self._request(cookie))
        self.assertGreater(auth._sessions[_token(cookie)] - time.time(), 86400)

    def test_a_browser_password_session_keeps_its_expiry(self) -> None:
        cookie = self._ageing_session()
        with mock.patch.object(pairing, "touch_device_by_session", return_value=None):
            self.assertTrue(self._request(cookie))
        self.assertLess(auth._sessions[_token(cookie)] - time.time(), 3601)


if __name__ == "__main__":
    unittest.main()
