"""Render a page in a real (headless) Chromium for its preview, when plain fetches can't get one.

Some sites only show their page — and its share card — to a browser that runs their JavaScript
("Please update your browser"). This loads the link in Playwright's Chromium and hands back the
rendered HTML, the large images actually on screen, any video posters, and a 16:9 screenshot to
fall back on when the page has no usable picture.

Safety:
- It runs in its own process (``python -m plugins.vault.render``) with a hard timeout, one at a
  time, so a heavy page can't take the webui down with it.
- Every request the browser makes — subresources, XHRs and redirects included — goes through a
  small proxy in that process that only connects to public addresses on ports 80/443, after
  resolving the name itself (so DNS rebinding can't point it inward). Service workers are off.
- The link is never logged.

``render(url)`` is what the preview engine calls; it returns None when Playwright or Chromium
isn't installed, or the page fails to load in time.
"""
from __future__ import annotations

import base64
import ipaddress
import json
import os
import select
import socket
import socketserver
import subprocess
import sys
import threading
from pathlib import Path
from urllib.parse import urlsplit

TIMEOUT_S = 15.0
_MAX_HTML = 1024 * 1024
_CHROME_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
              "Chrome/142.0.0.0 Safari/537.36")
_PORTS = (80, 443)
_one_at_a_time = threading.Semaphore(1)


# ── the parent side ──────────────────────────────────────────────────────

def available() -> bool:
    try:
        import importlib.util
        return importlib.util.find_spec("playwright") is not None
    except Exception:
        return False


def render(url: str, timeout_s: float = TIMEOUT_S) -> dict | None:
    """{"final": url, "html": str, "images": [url…], "screenshot": jpeg bytes|None} or None."""
    if not available() or urlsplit(url).scheme not in ("http", "https"):
        return None
    if not _one_at_a_time.acquire(timeout=timeout_s):
        return None
    try:
        repo = Path(__file__).resolve().parents[2]
        proc = subprocess.run([sys.executable, "-m", "plugins.vault.render"], input=json.dumps({"url": url}),
                              capture_output=True, text=True, timeout=timeout_s + 5, cwd=str(repo),
                              env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        out = json.loads(proc.stdout.strip().splitlines()[-1])
        if not isinstance(out, dict) or not out.get("ok"):
            return None
        shot = out.get("screenshot")
        return {"final": str(out.get("final") or url), "html": str(out.get("html") or "")[:_MAX_HTML],
                "images": [str(i) for i in out.get("images") or []][:8],
                "screenshot": base64.b64decode(shot) if shot else None}
    except Exception:
        return None
    finally:
        _one_at_a_time.release()


# ── the guard proxy (child side) ─────────────────────────────────────────

def public_ip(host: str, port: int) -> str | None:
    """The address to connect to for ``host`` if EVERY address it resolves to is public."""
    if port not in _PORTS or not host:
        return None
    try:
        infos = socket.getaddrinfo(host.strip("[]"), port, type=socket.SOCK_STREAM)
    except OSError:
        return None
    addrs = [info[4][0] for info in infos]
    try:
        if not addrs or not all(ipaddress.ip_address(a.split("%")[0]).is_global for a in addrs):
            return None
    except ValueError:
        return None
    return addrs[0]


def _pipe(a: socket.socket, b: socket.socket, idle_s: float = 20.0) -> None:
    socks = [a, b]
    while True:
        ready, _, _ = select.select(socks, [], [], idle_s)
        if not ready:
            return
        for s in ready:
            try:
                data = s.recv(65536)
            except OSError:
                return
            if not data:
                return
            (b if s is a else a).sendall(data)


class _GuardHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(10)
        try:
            head = b""
            while b"\r\n\r\n" not in head and len(head) < 65536:
                chunk = client.recv(4096)
                if not chunk:
                    return
                head += chunk
            header, _, rest = head.partition(b"\r\n\r\n")
            lines = header.decode("latin-1").split("\r\n")
            method, target, version = (lines[0].split(" ") + ["", ""])[:3]
            if method.upper() == "CONNECT":
                host, _, port = target.rpartition(":")
                ip = public_ip(host, int(port) if port.isdigit() else 0)
                if ip is None:
                    client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                    return
                upstream = socket.create_connection((ip, int(port)), timeout=10)
                client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                if rest:
                    upstream.sendall(rest)
            else:
                parts = urlsplit(target)
                port = parts.port or 80
                ip = public_ip(parts.hostname or "", port) if parts.scheme == "http" else None
                if ip is None:
                    client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                    return
                upstream = socket.create_connection((ip, port), timeout=10)
                path = parts.path or "/"
                if parts.query:
                    path += "?" + parts.query
                kept = [h for h in lines[1:] if not h.lower().startswith(("proxy-", "connection:"))]
                upstream.sendall(f"{method} {path} {version}\r\n".encode("latin-1")
                                 + "\r\n".join(kept + ["Connection: close"]).encode("latin-1") + b"\r\n\r\n" + rest)
            with upstream:
                _pipe(client, upstream)
        except Exception:
            return


class _Guard(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


# ── the child: drive Chromium ────────────────────────────────────────────

_COLLECT_JS = """() => {
  const seen = new Set(), out = [];
  for (const v of document.querySelectorAll('video[poster]')) if (v.poster) out.push(v.poster);
  const imgs = [...document.images].filter(i => i.naturalWidth >= 200 && i.naturalHeight >= 120)
    .map(i => { const r = i.getBoundingClientRect(); return {src: i.currentSrc || i.src, area: r.width * r.height,
                                                             top: r.top}; })
    .filter(i => i.area > 0 && i.top < 2000).sort((a, b) => b.area - a.area);
  for (const i of imgs) out.push(i.src);
  return out.filter(u => u && /^https?:/.test(u) && !seen.has(u) && seen.add(u)).slice(0, 8);
}"""


def _child(url: str) -> dict:
    from playwright.sync_api import sync_playwright

    guard = _Guard(("127.0.0.1", 0), _GuardHandler)
    threading.Thread(target=guard.serve_forever, daemon=True).start()
    proxy = f"http://127.0.0.1:{guard.server_address[1]}"
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True, args=[
                f"--proxy-server={proxy}", "--proxy-bypass-list=<-loopback>",
                "--disable-blink-features=AutomationControlled", "--disable-dev-shm-usage",
                "--mute-audio", "--no-first-run"])
            try:
                ctx = browser.new_context(user_agent=_CHROME_UA, viewport={"width": 1280, "height": 720},
                                          locale="en-US", service_workers="block", accept_downloads=False)
                # Media and fonts aren't needed for a preview; skipping them keeps it quick.
                ctx.route("**/*", lambda route: route.abort() if route.request.resource_type in
                          ("media", "font", "websocket", "eventsource") else route.continue_())
                page = ctx.new_page()
                page.goto(url, wait_until="domcontentloaded", timeout=int(TIMEOUT_S * 1000 * 0.6))
                try:
                    page.wait_for_load_state("networkidle", timeout=3500)
                except Exception:
                    pass
                images = page.evaluate(_COLLECT_JS)
                html = page.content()[:_MAX_HTML]
                shot = page.screenshot(type="jpeg", quality=72, timeout=4000)
                return {"ok": True, "final": page.url, "html": html, "images": images,
                        "screenshot": base64.b64encode(shot).decode()}
            finally:
                browser.close()
    finally:
        guard.shutdown()


if __name__ == "__main__":
    try:
        req = json.loads(sys.stdin.read() or "{}")
        result = _child(str(req.get("url") or ""))
    except Exception as exc:
        result = {"ok": False, "error": type(exc).__name__}
    sys.stdout.write(json.dumps(result) + "\n")
