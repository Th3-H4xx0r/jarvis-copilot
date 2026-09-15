"""GET /api/devices/ball/image?url=…&size=… — a web image, made safe for the Jarvis Ball.

The ball's JPEG decoder handles baseline JPEG only, has no WebP/GIF, and a 240 px round
screen gains nothing from a 4 MB photo. So the server fetches the picture, crops it
square around the centre, scales it to `size` and re-encodes a small baseline JPEG.

Authenticated like every /api route. Only public http(s) hosts: private, loopback and
link-local addresses are refused so this can't be pointed at the LAN.
"""
from __future__ import annotations

import io
import ipaddress
import socket
import urllib.parse
import urllib.request

_MAX_DOWNLOAD = 12 * 1024 * 1024
_TIMEOUT = 12


def _public_host(url: str) -> bool:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return False
    try:
        infos = socket.getaddrinfo(parts.hostname, parts.port or (443 if parts.scheme == "https" else 80))
    except OSError:
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            return False
    return True


class _NoPrivateRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not _public_host(newurl):
            raise urllib.error.URLError("redirect to a non-public host")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_for_ball(url: str, size: int) -> bytes:
    """The picture at `url` as a `size`×`size` baseline JPEG. Raises ValueError."""
    from PIL import Image, ImageOps

    if not _public_host(url):
        raise ValueError("url must be a public http(s) address")
    opener = urllib.request.build_opener(_NoPrivateRedirects)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (JarvisBall image fetch)"})
    with opener.open(req, timeout=_TIMEOUT) as resp:
        data = resp.read(_MAX_DOWNLOAD + 1)
    if len(data) > _MAX_DOWNLOAD:
        raise ValueError("image too large")
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img).convert("RGB")
    except Exception as exc:  # not an image Pillow can read
        raise ValueError(f"not a readable image: {exc}") from exc
    img = ImageOps.fit(img, (size, size), method=Image.Resampling.LANCZOS)
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=85, progressive=False, optimize=True)
    return out.getvalue()


def handle_ball_image(handler, parsed) -> bool:
    from api.helpers import j  # webui's JSON responder

    qs = urllib.parse.parse_qs(parsed.query)
    url = (qs.get("url") or [""])[0]
    try:
        size = max(48, min(240, int((qs.get("size") or ["200"])[0])))
    except ValueError:
        size = 200
    try:
        body = fetch_for_ball(url, size)
    except ValueError as exc:
        j(handler, {"error": str(exc)}, status=400)
        return True
    except Exception as exc:
        j(handler, {"error": f"could not fetch the image: {exc}"}, status=502)
        return True
    handler.send_response(200)
    handler.send_header("Content-Type", "image/jpeg")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "private, max-age=300")
    handler.end_headers()
    handler.wfile.write(body)
    return True
