"""Link previews for vault links: title, site, author, duration, thumbnail and favicon.

Open Graph tags plus a duration from ``og:video:duration`` / ``itemprop=duration`` / JSON-LD
``VideoObject``; YouTube, Vimeo and TikTok through their oEmbed endpoints. Every hop, redirects and
image downloads included, goes through ``is_safe_url`` so a saved link can't make the server fetch
its own network. One deadline covers the whole preview. Never raises; never logs the URL.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import time
from html.parser import HTMLParser
from urllib.parse import parse_qs, quote, urljoin, urlparse

_USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
               "(KHTML, like Gecko) facebookexternalhit/1.1 Facebot Twitterbot/1.0")
_MAX_HTML = 768 * 1024
_MAX_IMAGE = 6 * 1024 * 1024
_MAX_FAVICON = 256 * 1024
_MAX_REDIRECTS = 4
BUDGET_S = 8.0

# is_safe_url logs a blocked hostname; a vault link's host must not reach the logs.
_quiet = threading.local()


class _QuietFilter(logging.Filter):
    def filter(self, record):
        return not getattr(_quiet, "on", False)


logging.getLogger("tools.url_safety").addFilter(_QuietFilter())


def _domain(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def parse_duration(value) -> float | None:
    """Seconds from an ISO 8601 duration (PT1H2M3S), "1:02:03", or a plain number."""
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        out = float(text)
        return out if out > 0 else None
    except ValueError:
        pass
    m = re.fullmatch(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?", text, re.I)
    if m and any(m.groups()):
        d, h, mi, s = (float(g) if g else 0.0 for g in m.groups())
        total = d * 86400 + h * 3600 + mi * 60 + s
        return total or None
    parts = text.split(":")
    if 2 <= len(parts) <= 3 and all(p.isdigit() for p in parts):
        total = 0.0
        for p in parts:
            total = total * 60 + int(p)
        return total or None
    return None


class _PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta: dict[str, str] = {}
        self.icons: list[str] = []
        self.title = ""
        self.ld: list[str] = []
        self._in_title = False
        self._in_ld = False
        self._ld_buf = ""

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "meta":
            key = (a.get("property") or a.get("name") or a.get("itemprop") or "").lower()
            content = a.get("content", "").strip()
            if key and content and key not in self.meta:
                self.meta[key] = content
        elif tag == "link":
            rel = a.get("rel", "").lower()
            if "icon" in rel.split() or rel in ("shortcut icon", "apple-touch-icon"):
                if a.get("href"):
                    self.icons.append(a["href"])
        elif tag == "title":
            self._in_title = True
        elif tag == "script" and "ld+json" in a.get("type", "").lower():
            self._in_ld, self._ld_buf = True, ""

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        elif tag == "script" and self._in_ld:
            self._in_ld = False
            self.ld.append(self._ld_buf)

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        elif self._in_ld:
            self._ld_buf += data


def _ld_video(blocks: list[str]) -> dict:
    def walk(node):
        if isinstance(node, list):
            for n in node:
                found = walk(n)
                if found:
                    return found
        elif isinstance(node, dict):
            kind = node.get("@type")
            kinds = kind if isinstance(kind, list) else [kind]
            if "VideoObject" in kinds:
                return node
            for key in ("@graph", "video", "mainEntity"):
                if key in node:
                    found = walk(node[key])
                    if found:
                        return found
        return None

    for raw in blocks:
        try:
            found = walk(json.loads(raw))
        except ValueError:
            continue
        if found:
            return found
    return {}


def parse_page(html: str, url: str) -> dict:
    """The preview fields (and image/icon URLs) of a fetched page. Pure: no network."""
    p = _PageParser()
    try:
        p.feed(html)
    except Exception:
        pass
    m = p.meta
    video = _ld_video(p.ld)
    title = m.get("og:title") or m.get("twitter:title") or video.get("name") or " ".join(p.title.split())
    image = m.get("og:image") or m.get("og:image:url") or m.get("twitter:image") or ""
    if not image and video.get("thumbnailUrl"):
        thumb = video["thumbnailUrl"]
        image = thumb[0] if isinstance(thumb, list) and thumb else (thumb if isinstance(thumb, str) else "")
    image = urljoin(url, image) if image else ""
    if urlparse(image).scheme not in ("http", "https"):
        image = ""
    duration = (parse_duration(m.get("og:video:duration")) or parse_duration(m.get("video:duration"))
                or parse_duration(m.get("duration")) or parse_duration(video.get("duration")))
    og_type = m.get("og:type", "").lower()
    if og_type.startswith("video") or video or duration:
        kind = "video"
    elif og_type == "article" or m.get("article:published_time"):
        kind = "article"
    else:
        kind = "page"
    author = m.get("author") or m.get("article:author") or m.get("twitter:creator") or ""
    if not author and isinstance(video.get("author"), dict):
        author = video["author"].get("name") or ""
    icons = [urljoin(url, i) for i in p.icons if urlparse(urljoin(url, i)).scheme in ("http", "https")]
    icon = icons[0] if icons else urljoin(url, "/favicon.ico")
    return {
        "title": title[:300], "site_name": (m.get("og:site_name") or _domain(url))[:120],
        "domain": _domain(url), "kind": kind, "duration_s": duration,
        "author": (author[:120] or None), "description": (m.get("og:description") or m.get("description")
                                                          or m.get("twitter:description") or "")[:500] or None,
        "_image": image, "_icon": icon,
    }


def youtube_id(url: str) -> str | None:
    u = urlparse(url)
    host = (u.hostname or "").lower()
    if host.endswith("youtu.be"):
        vid = u.path.strip("/").split("/")[0]
    elif host.endswith("youtube.com"):
        if u.path == "/watch":
            vid = (parse_qs(u.query).get("v") or [""])[0]
        else:
            parts = u.path.strip("/").split("/")
            vid = parts[1] if len(parts) >= 2 and parts[0] in ("shorts", "embed", "live", "v") else ""
    else:
        return None
    return vid if re.fullmatch(r"[A-Za-z0-9_-]{6,20}", vid or "") else None


def _oembed_endpoint(url: str) -> str | None:
    host = _domain(url)
    q = quote(url, safe="")
    if youtube_id(url):
        return f"https://www.youtube.com/oembed?url={q}&format=json"
    if host == "vimeo.com" or host.endswith(".vimeo.com"):
        return f"https://vimeo.com/api/oembed.json?url={q}"
    if host == "tiktok.com" or host.endswith(".tiktok.com"):
        return f"https://www.tiktok.com/oembed?url={q}"
    return None


class _Fetcher:
    def __init__(self, budget_s: float):
        import httpx

        self.deadline = time.monotonic() + budget_s
        self.client = httpx.Client(follow_redirects=False, trust_env=False, headers={"User-Agent": _USER_AGENT,
                                                                     "Accept-Encoding": "gzip, deflate"})

    def left(self) -> float:
        return self.deadline - time.monotonic()

    def get(self, url: str, cap: int, accept: str = "*/*"):
        """(final url, content-type, bytes) or None. Each hop checked with is_safe_url."""
        from tools.url_safety import is_safe_url, response_peer_is_public

        current = url
        for _ in range(_MAX_REDIRECTS + 1):
            left = self.left()
            if left < 0.3 or not is_safe_url(current):
                return None
            try:
                with self.client.stream("GET", current, timeout=min(6.0, left), headers={"Accept": accept}) as resp:
                    if not response_peer_is_public(resp):     # DNS rebinding: re-resolved to a private address
                        return None
                    if resp.is_redirect and resp.headers.get("location"):
                        current = urljoin(current, resp.headers["location"])
                        continue
                    if resp.status_code >= 400:
                        return None
                    body = bytearray()
                    for chunk in resp.iter_bytes():
                        body += chunk
                        if len(body) > cap or self.left() < 0:
                            if accept.startswith("text/html"):
                                break
                            return None
                    return current, resp.headers.get("content-type", "").lower(), bytes(body[:cap]), resp.encoding
            except Exception:
                return None
        return None

    def close(self):
        try:
            self.client.close()
        except Exception:
            pass


def fetch(url: str, budget_s: float = BUDGET_S, want_favicon: bool = True) -> dict | None:
    """{"preview": {...}, "image": bytes|None, "favicon": (bytes, mime)|None}, or None if the page
    couldn't be fetched at all."""
    try:
        f = _Fetcher(budget_s)
    except Exception:
        return None
    _quiet.on = True
    try:
        preview = None
        page = f.get(url, _MAX_HTML, "text/html,application/xhtml+xml")
        if page is not None:
            final, ctype, raw, enc = page
            if "html" in ctype:
                preview = parse_page(raw.decode(enc or "utf-8", errors="replace"), final)
            else:
                preview = {"title": "", "site_name": _domain(final), "domain": _domain(url),
                           "kind": "page", "duration_s": None, "author": None, "description": None,
                           "_image": "", "_icon": urljoin(final, "/favicon.ico")}
        endpoint = _oembed_endpoint(url)
        if endpoint:
            got = f.get(endpoint, 256 * 1024, "application/json")
            if got is not None:
                try:
                    oe = json.loads(got[2])
                except ValueError:
                    oe = {}
                if isinstance(oe, dict) and oe:
                    preview = preview or {"site_name": _domain(url), "domain": _domain(url), "description": None,
                                          "_icon": urljoin(url, "/favicon.ico"), "_image": ""}
                    preview["title"] = oe.get("title") or preview.get("title") or ""
                    preview["author"] = oe.get("author_name") or preview.get("author")
                    preview["site_name"] = oe.get("provider_name") or preview.get("site_name")
                    preview["kind"] = "video"
                    preview["duration_s"] = parse_duration(oe.get("duration")) or preview.get("duration_s")
                    preview["_image"] = oe.get("thumbnail_url") or preview.get("_image") or ""
        if preview is None:
            return None
        image = None
        vid = youtube_id(url)
        candidates = ([f"https://i.ytimg.com/vi/{vid}/maxresdefault.jpg", f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"]
                      if vid else [])
        if preview.get("_image"):
            candidates.append(preview["_image"])
        for candidate in candidates:
            got = f.get(candidate, _MAX_IMAGE, "image/*")
            if got is not None and got[1].startswith("image/") and len(got[2]) > 1000:
                image = got[2]
                break
        favicon = None
        if want_favicon and preview.get("_icon") and f.left() > 0.5:
            got = f.get(preview["_icon"], _MAX_FAVICON, "image/*")
            if got is not None and got[1].startswith("image/") and got[2]:
                favicon = (got[2], got[1].split(";")[0])
        clean = {k: v for k, v in preview.items() if not k.startswith("_")}
        return {"preview": clean, "image": image, "favicon": favicon}
    except Exception:
        return None
    finally:
        _quiet.on = False
        f.close()
