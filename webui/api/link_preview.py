"""Link previews for the web chat: a URL's title, description and image.

A browser page can't read another site's HTML (CORS), so the server fetches
the page the way iMessage's LinkPresentation does and returns its Open Graph
fields. Every hop, redirects included, goes through ``is_safe_url`` so a link
in a chat can't make the server fetch its own network.
"""
from __future__ import annotations

import threading
import time
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

import httpx

from tools.url_safety import is_safe_url

# The user agent LinkPresentation sends: sites that hide their Open Graph tags
# from unknown bots usually serve them to this one.
_USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
               "(KHTML, like Gecko) facebookexternalhit/1.1 Facebot Twitterbot/1.0")
_MAX_BYTES = 512 * 1024
_MAX_REDIRECTS = 4
_TIMEOUT_S = 6.0
_CACHE_TTL_S = 6 * 3600
_CACHE_MAX = 256

_cache: dict[str, tuple[float, dict]] = {}
_cache_lock = threading.Lock()


class _MetaParser(HTMLParser):
    """Collects <meta property|name=… content=…> pairs and the <title> text."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta: dict[str, str] = {}
        self.title = ""
        self._in_title = False

    def handle_starttag(self, tag, attrs):
        attrs = {k.lower(): (v or "") for k, v in attrs}
        if tag == "meta":
            key = (attrs.get("property") or attrs.get("name") or "").lower()
            content = attrs.get("content", "").strip()
            if key and content and key not in self.meta:
                self.meta[key] = content
        elif tag == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data


def _site(url: str) -> str:
    host = urlparse(url).hostname or ""
    return host[4:] if host.startswith("www.") else host


def parse_preview(html: str, url: str) -> dict:
    """The preview fields of ``html``, a page fetched from ``url``."""
    parser = _MetaParser()
    try:
        parser.feed(html)
    except Exception:
        pass  # a malformed page still yields whatever was parsed before it broke
    meta = parser.meta
    title = meta.get("og:title") or meta.get("twitter:title") or " ".join(parser.title.split())
    image = meta.get("og:image") or meta.get("og:image:url") or meta.get("twitter:image") or ""
    image = urljoin(url, image) if image else ""
    if urlparse(image).scheme not in ("http", "https"):
        image = ""
    description = (meta.get("og:description") or meta.get("description")
                   or meta.get("twitter:description") or "")
    return {
        "url": url,
        "title": title[:300],
        "description": description[:500],
        "image": image,
        "site": meta.get("og:site_name") or _site(url),
    }


def _fetch(url: str) -> dict | None:
    current = url
    headers = {"User-Agent": _USER_AGENT, "Accept": "text/html,application/xhtml+xml"}
    try:
        with httpx.Client(timeout=_TIMEOUT_S, follow_redirects=False, headers=headers) as client:
            for _ in range(_MAX_REDIRECTS + 1):
                if not is_safe_url(current):
                    return None
                with client.stream("GET", current) as resp:
                    if resp.is_redirect and resp.headers.get("location"):
                        current = urljoin(current, resp.headers["location"])
                        continue
                    if resp.status_code >= 400:
                        return None
                    if "html" not in resp.headers.get("content-type", "").lower():
                        return {"url": url, "title": "", "description": "", "image": "",
                                "site": _site(current)}
                    body = bytearray()
                    for chunk in resp.iter_bytes():
                        body += chunk
                        if len(body) >= _MAX_BYTES:
                            break
                    html = bytes(body).decode(resp.encoding or "utf-8", errors="replace")
                    return {**parse_preview(html, current), "url": url}
    except httpx.HTTPError:
        return None
    return None


def fetch_preview(url: str) -> dict | None:
    """The preview for ``url``, or None when it is unsafe or unreachable."""
    now = time.time()
    with _cache_lock:
        hit = _cache.get(url)
        if hit and now - hit[0] < _CACHE_TTL_S:
            return hit[1]
    preview = _fetch(url)
    if preview is not None:
        with _cache_lock:
            if len(_cache) >= _CACHE_MAX:
                _cache.pop(next(iter(_cache)))
            _cache[url] = (now, preview)
    return preview
