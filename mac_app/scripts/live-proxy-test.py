"""Run the live Swift integration test against a real PinnedProxy.

    "$HOME/Library/Application Support/jc-client/.venv/bin/python" \
        mac_app/scripts/live-proxy-test.py

Starts the same loopback proxy the tray starts, points the Swift tests at it,
and shuts it down again. Needs a paired client; skips cleanly if there isn't one.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "desktop_client"))

from jc_client import credentials              # noqa: E402
from jc_client._proxy import PinnedProxy       # noqa: E402

creds = credentials.load()
if not creds.paired:
    print("live-proxy-test: client is not paired — nothing to test against")
    raise SystemExit(0)

proxy = PinnedProxy(creds.server_url, creds.cert_fingerprint, creds.cookie,
                    cf_client_id=creds.cf_client_id, cf_client_secret=creds.cf_client_secret,
                    lan_url=creds.lan_url)
port = proxy.start()
origin = f"http://127.0.0.1:{port}"
print(f"live-proxy-test: proxy up on {origin}")
try:
    rc = subprocess.call(
        ["swift", "test", "--filter", "LiveTests"],
        cwd=os.path.join(os.path.dirname(__file__), ".."),
        env=dict(os.environ, JC_PROXY_ORIGIN=origin),
    )
finally:
    proxy.shutdown()
raise SystemExit(rc)
