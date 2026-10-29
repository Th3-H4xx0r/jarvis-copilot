"""Built-in app updates: Claude uploads a build, the apps get a signed install link.

The install links are public (iOS's installer sends no cookie), so everything
about them rests on the token: it names one build, expires, and can't be forged.
"""
import io
import plistlib
import zipfile
from types import SimpleNamespace
from urllib.parse import unquote, urlparse

import pytest

from api import app_updates as au

_REAL_PUBLIC_BASE = au.public_base


@pytest.fixture(autouse=True)
def store(tmp_path, monkeypatch):
    monkeypatch.setattr(au, "STATE_DIR", tmp_path)
    monkeypatch.setattr("api.auth._signing_key", lambda: b"test-key")
    monkeypatch.setattr(au, "public_base", lambda handler=None: "https://ota.example.dev")
    return tmp_path


def _archive(platform: str, build, bundle_id="com.example.app") -> bytes:
    info = plistlib.dumps({"CFBundleVersion": str(build), "CFBundleShortVersionString": "1.0",
                           "CFBundleIdentifier": bundle_id})
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("Payload/App.app/Info.plist" if platform == "ios"
                    else "Jarvis.app/Contents/Info.plist", info)
        zf.writestr("filler.bin", b"x" * 1000)
    return buf.getvalue()


def _upload(platform, build, data=None, **kw):
    data = data if data is not None else _archive(platform, build)
    return au.store_upload(platform, build, io.BytesIO(data), len(data), **kw)


def test_an_uploaded_build_is_offered_to_an_older_app():
    _upload("ios", 200, notes="• Paste images\n• Faster PDFs")
    offer = au.latest("ios", 100, "https://ota.example.dev")
    assert offer["available"] and offer["build"] == 200 and offer["notes"].startswith("• Paste")
    assert offer["install_url"].startswith("itms-services://?action=download-manifest&url=")
    manifest = unquote(offer["install_url"].split("url=", 1)[1])
    assert manifest.startswith("https://ota.example.dev/ota/m/") and manifest.endswith(".plist")


def test_the_same_or_a_newer_app_is_not_offered_anything():
    _upload("ios", 200)
    assert not au.latest("ios", 200, "https://x")["available"]
    assert not au.latest("ios", 300, "https://x")["available"]
    assert not au.latest("mac", 0, "https://x")["available"]


def test_an_unstamped_build_is_never_offered_an_update():
    # Build 1 is Xcode Run / a plain build: possibly newer code than anything published.
    _upload("ios", 200)
    assert not au.latest("ios", 1, "https://x")["available"]
    assert not au.latest("ios", 0, "https://x")["available"]


def test_without_a_public_install_host_no_link_is_handed_out(monkeypatch):
    # The main host sits behind a login iOS's installer can't pass: better no link.
    settings = {"enabled": True, "domain": "example.dev", "routes": {"jarvis": "x"}, "ota_route": ""}
    monkeypatch.setattr("edge.state.load_settings", lambda: settings)
    assert _REAL_PUBLIC_BASE(SimpleNamespace(headers={"Host": "jarvis.example.dev"})) == ""
    settings.update(routes={"pub": "x"}, ota_route="pub")
    assert _REAL_PUBLIC_BASE() == "https://pub.example.dev"


def test_an_archive_whose_build_number_disagrees_is_refused():
    with pytest.raises(au.UploadError, match="not 200"):
        _upload("ios", 200, data=_archive("ios", 1))


def test_a_build_that_is_not_newer_is_refused():
    _upload("mac", 300)
    with pytest.raises(au.UploadError, match="not newer"):
        _upload("mac", 300)


def test_a_short_or_bogus_body_leaves_nothing_behind(store):
    data = _archive("ios", 5)
    with pytest.raises(au.UploadError, match="shorter"):
        au.store_upload("ios", 5, io.BytesIO(data[:10]), len(data))
    with pytest.raises(au.UploadError):
        _upload("ios", 6, data=b"not a zip")
    assert au.current("ios") is None
    assert not [p for p in (store / "app_updates").iterdir() if p.suffix in (".ipa", ".zip", ".part")]


def test_only_current_and_previous_builds_are_kept_and_rollback_restores(store):
    for build in (1, 2, 3):
        _upload("ios", build)
    files = sorted(p.name for p in (store / "app_updates").glob("*.ipa"))
    assert files == ["ios-2.ipa", "ios-3.ipa"]
    assert au.rollback("ios")["build"] == 2
    assert au.current("ios")["build"] == 2
    assert au.rollback("ios") is None


def test_tokens_expire_and_cannot_be_forged_or_retargeted():
    _upload("ios", 7)
    token = au.make_token("ios", 7, now=1000)
    assert au.check_token(token, now=1000)["build"] == 7
    assert au.check_token(token, now=1000 + au.LINK_TTL + 1) is None
    platform, build, exp, sig = token.split(".")
    assert au.check_token(f"{platform}.8.{exp}.{sig}", now=1000) is None
    assert au.check_token(f"mac.{build}.{exp}.{sig}", now=1000) is None
    assert au.check_token(f"{platform}.{build}.{int(exp) + 999}.{sig}", now=1000) is None
    assert au.check_token("../../etc/passwd") is None


def test_a_token_for_a_dropped_build_stops_working():
    _upload("ios", 1)
    token = au.make_token("ios", 1)
    _upload("ios", 2)
    _upload("ios", 3)
    assert au.check_token(token) is None


class _Handler:
    def __init__(self, path):
        self.path = path
        self.command = "GET"
        self.headers = {}
        self.status = None
        self.sent = {}
        self.wfile = io.BytesIO()

    def send_response(self, status):
        self.status = status

    def send_header(self, k, v):
        self.sent[k] = v

    def end_headers(self):
        pass


def _get(path):
    h = _Handler(path)
    au.handle_ota(h, urlparse(path))
    return h


def test_the_manifest_and_ipa_are_served_for_a_valid_token_only():
    data = _archive("ios", 9, bundle_id="com.jarvis.app")
    au.store_upload("ios", 9, io.BytesIO(data), len(data))
    token = au.make_token("ios", 9)
    h = _get(f"/ota/m/{token}.plist")
    assert h.status == 200
    meta = plistlib.loads(h.wfile.getvalue())["items"][0]
    assert meta["metadata"]["bundle-identifier"] == "com.jarvis.app"
    assert meta["assets"][0]["url"] == f"https://ota.example.dev/ota/d/{token}/JarvisCopilot.ipa"
    h = _get(f"/ota/d/{token}/JarvisCopilot.ipa")
    assert h.status == 200 and h.wfile.getvalue() == data
    for bad in (f"/ota/d/{token}/Jarvis.zip", "/ota/m/nope.plist", "/ota/d/x/JarvisCopilot.ipa",
                "/ota/", "/ota/../index.json"):
        assert _get(bad).status == 403, bad


def test_ota_paths_skip_the_session_check_for_reads_only(monkeypatch):
    from api import auth
    monkeypatch.setattr(auth, "is_auth_enabled", lambda: True)
    get = SimpleNamespace(command="GET", headers={}, client_address=("1.2.3.4", 1))
    assert auth.check_auth(get, urlparse("/ota/m/x.plist"))
    post = SimpleNamespace(command="POST", headers={}, client_address=("1.2.3.4", 1),
                           send_response=lambda s: None, send_header=lambda *a: None,
                           end_headers=lambda: None, wfile=io.BytesIO())
    assert not auth.check_auth(post, urlparse("/ota/m/x.plist"))


def test_the_edge_exposes_only_ota_on_the_ota_route():
    from edge.config_render import render_nginx
    settings = {"domain": "example.dev", "webui_port": 8787, "ota_route": "pub",
                "routes": {"jarvis": "https://127.0.0.1:8787", "pub": "127.0.0.1:8765"}}
    conf = render_nginx(settings)
    pub = conf.split("server_name pub.example.dev;", 1)[1].split("server_name", 1)[0]
    assert "location ^~ /ota/ {" in pub and "proxy_pass https://127.0.0.1:8787;" in pub
    jarvis = conf.split("server_name jarvis.example.dev;", 1)[1].split("server_name", 1)[0]
    assert "/ota/" not in jarvis
    assert "/ota/" not in render_nginx({**settings, "ota_route": ""})
