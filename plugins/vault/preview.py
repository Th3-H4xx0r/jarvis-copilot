"""Link previews for vault links: title, site, author, duration, thumbnail and favicon.

Sites hide their previews behind bot walls ("Please update your browser", Cloudflare's "Just a
moment…"), so a page is asked for as several clients in turn — the Facebook crawler most sites
whitelist for share cards, then a real Safari, then Twitter's crawler — and the best answer wins.
A wall's title is never kept: it falls back to a title made from the link itself.

Where the preview comes from, best first:
- oEmbed (YouTube, Vimeo, TikTok, Dailymotion, SoundCloud, Spotify, Streamable, or any page that
  advertises an ``application/json+oembed`` link);
- Open Graph / Twitter card tags, ``itemprop`` microdata, ``<link rel=image_src>``;
- JSON-LD (``VideoObject`` for durations, any node's ``thumbnailUrl`` / ``image``);
- a ``<video poster>``, then the page's first large-looking ``<img>``.

Every hop, redirects and image downloads included, goes through ``is_safe_url`` so a saved link
can't make the server fetch its own network. One deadline covers the whole preview. Never raises;
never logs the URL. Links are only ever sent to their own site (and its oEmbed endpoint), never to
a third-party preview service.
"""
from __future__ import annotations

import json
import logging
import re
import threading
import time
from html.parser import HTMLParser
from urllib.parse import parse_qs, quote, unquote, urljoin, urlparse

_SAFARI_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/26.0 Safari/605.1.15")

# Who the page is asked for as, in order. Sites that block unknown bots usually still serve
# their share card to the Facebook crawler; the rest usually serve a real browser.
_PERSONAS = (
    {"User-Agent": "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
     "Accept": "text/html,application/xhtml+xml,*/*;q=0.8"},
    {"User-Agent": _SAFARI_UA,
     "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
     "Accept-Language": "en-US,en;q=0.9", "Upgrade-Insecure-Requests": "1",
     "Sec-Fetch-Dest": "document", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Site": "none"},
    {"User-Agent": "Twitterbot/1.0", "Accept": "text/html,application/xhtml+xml,*/*;q=0.8"},
)
_IMAGE_HEADERS = {"User-Agent": _SAFARI_UA, "Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8",
                  "Sec-Fetch-Dest": "image", "Sec-Fetch-Mode": "no-cors"}

_MAX_HTML = 1024 * 1024
_MAX_IMAGE = 6 * 1024 * 1024
_MAX_FAVICON = 256 * 1024
_MAX_REDIRECTS = 5
_MIN_IMAGE_SIDE = 120
BUDGET_S = 12.0

# Titles of pages that stand between a crawler and the real page.
_WALL = re.compile(
    r"update (your|the) browser|upgrade your browser|unsupported browser|browser (is )?(not supported|"
    r"outdated|out of date)|just a moment|attention required|access denied|access to this page has been "
    r"denied|are you a (robot|human)|verify(ing)? (you are|that you are|you're) (a )?human|captcha|"
    r"security check|enable (javascript|cookies)|javascript (is )?(required|disabled)|checking your browser|"
    r"ddos protection|request (blocked|rejected)|pardon our interruption|one more step|bot (check|detection)|"
    r"^(403|404|429|503)\b|^forbidden\b|page not found|too many requests|service unavailable|^error\b|"
    r"^loading\.*$",
    re.I)
# <img> sources that are chrome, not content.
_NOT_CONTENT_IMG = re.compile(r"logo|icon|sprite|avatar|favicon|pixel|spacer|blank|placeholder|badge|"
                              r"emoji|loader|loading|\.svg(\?|$)|\.gif(\?|$)|1x1", re.I)

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


def is_wall_title(title: str) -> bool:
    """A bot wall's or error page's title, not the page's own."""
    return bool(_WALL.search(" ".join(str(title or "").split())))


def title_from_url(url: str) -> str:
    """A readable title from a link's last path segment: "/videos/my-trip-to-japan-xh8Ka2" →
    "My Trip To Japan". Empty when the path says nothing."""
    segments = [s for s in urlparse(url).path.split("/") if s]
    for seg in reversed(segments):
        seg = re.sub(r"\.(html?|php|aspx?)$", "", unquote(seg), flags=re.I)
        words = [w for w in re.split(r"[-_+.\s]+", seg) if w]
        # Drop trailing ids: tokens that mix letters and digits, or long runs of digits.
        while words and (re.fullmatch(r"\d{4,}", words[-1])
                         or (re.search(r"\d", words[-1]) and re.search(r"[A-Za-z]", words[-1])
                             and len(words[-1]) >= 5)):
            words.pop()
        if len(words) >= 2 and sum(len(w) for w in words) >= 6:
            return " ".join(w if w.isupper() else w[:1].upper() + w[1:] for w in words)[:200]
    return ""


class _PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta: dict[str, str] = {}
        self.icons: list[str] = []
        self.links: dict[str, str] = {}
        self.posters: list[str] = []
        self.imgs: list[str] = []
        self.oembed = ""
        self.refresh = ""
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
            if a.get("http-equiv", "").lower() == "refresh" and not self.refresh:
                m = re.search(r"url\s*=\s*['\"]?([^'\"]+)", content, re.I)
                if m:
                    self.refresh = m.group(1).strip()
        elif tag == "link":
            rel = a.get("rel", "").lower()
            href = a.get("href", "")
            if not href:
                return
            if "icon" in rel.split() or rel in ("shortcut icon", "apple-touch-icon"):
                self.icons.append(href)
            elif "alternate" in rel.split() and "json+oembed" in a.get("type", "").lower():
                self.oembed = self.oembed or href
            elif rel == "image_src":
                self.links.setdefault("image_src", href)
            if a.get("itemprop", "").lower() in ("thumbnailurl", "image"):
                self.links.setdefault("itemprop", href)
        elif tag == "video" and a.get("poster"):
            self.posters.append(a["poster"])
        elif tag == "img" and len(self.imgs) < 40:
            src = a.get("data-src") or a.get("data-original") or a.get("data-lazy-src") or a.get("src") or ""
            if not src or src.startswith("data:") or _NOT_CONTENT_IMG.search(src):
                return
            dims = [int(v) for v in (a.get("width", ""), a.get("height", "")) if v.isdigit()]
            if dims and min(dims) < _MIN_IMAGE_SIDE:
                return
            self.imgs.append(src)
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


def _ld_nodes(blocks: list[str]) -> list[dict]:
    """Every dict in the page's JSON-LD."""
    out: list[dict] = []

    def walk(node, depth=0):
        if depth > 12 or len(out) > 400:
            return
        if isinstance(node, list):
            for n in node:
                walk(n, depth + 1)
        elif isinstance(node, dict):
            out.append(node)
            for value in node.values():
                if isinstance(value, (list, dict)):
                    walk(value, depth + 1)

    for raw in blocks:
        try:
            walk(json.loads(raw))
        except ValueError:
            continue
    return out


def _types(node: dict) -> list:
    t = node.get("@type")
    return t if isinstance(t, list) else [t]


def _ld_image(value) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        for v in value:
            got = _ld_image(v)
            if got:
                return got
    if isinstance(value, dict):
        return _ld_image(value.get("url") or value.get("contentUrl") or "")
    return ""


def parse_page(html: str, url: str) -> dict:
    """The preview fields (and candidate image/icon URLs) of a fetched page. Pure: no network."""
    p = _PageParser()
    try:
        p.feed(html)
    except Exception:
        pass
    m = p.meta
    nodes = _ld_nodes(p.ld)
    video = next((n for n in nodes if "VideoObject" in _types(n)), {})
    title = (m.get("og:title") or m.get("twitter:title") or video.get("name") or m.get("title")
             or " ".join(p.title.split()))

    def absolute(u) -> str:
        u = urljoin(url, u.strip()) if isinstance(u, str) and u.strip() else ""
        return u if urlparse(u).scheme in ("http", "https") else ""

    images: list[str] = []
    for raw in (m.get("og:image:secure_url"), m.get("og:image"), m.get("og:image:url"), m.get("twitter:image"),
                m.get("twitter:image:src"), _ld_image(video.get("thumbnailUrl")), m.get("thumbnailurl"),
                p.links.get("itemprop"), p.links.get("image_src"), m.get("image"),
                *(_ld_image(n.get("thumbnailUrl") or n.get("image")) for n in nodes
                  if not {"Organization", "WebSite", "Person", "Brand"} & set(_types(n))),
                *p.posters, *p.imgs[:6]):
        u = absolute(raw)
        if u and u not in images:
            images.append(u)
    duration = (parse_duration(m.get("og:video:duration")) or parse_duration(m.get("video:duration"))
                or parse_duration(m.get("duration")) or parse_duration(video.get("duration")))
    og_type = m.get("og:type", "").lower()
    if (og_type.startswith("video") or video or duration or m.get("og:video") or m.get("og:video:url")
            or m.get("og:video:secure_url")):
        kind = "video"
    elif og_type == "article" or m.get("article:published_time"):
        kind = "article"
    else:
        kind = "page"
    author = m.get("author") or m.get("article:author") or m.get("twitter:creator") or ""
    if not author and isinstance(video.get("author"), dict):
        author = video["author"].get("name") or ""
    icons = [absolute(i) for i in p.icons if absolute(i)]
    return {
        "title": str(title)[:300], "site_name": (m.get("og:site_name") or _domain(url))[:120],
        "domain": _domain(url), "kind": kind, "duration_s": duration,
        "author": (str(author)[:120] or None), "description": (m.get("og:description") or m.get("description")
                                                               or m.get("twitter:description") or "")[:500] or None,
        "_image": images[0] if images else "", "_images": images,
        "_icon": icons[0] if icons else urljoin(url, "/favicon.ico"),
        "_oembed": absolute(p.oembed), "_refresh": absolute(p.refresh),
    }


def _weak_title(preview: dict) -> bool:
    """No title, a wall's, or just the site's own name ("Instagram", "xHamster")."""
    title = " ".join(str(preview.get("title") or "").split()).lower()
    if not title or is_wall_title(title):
        return True
    site = str(preview.get("site_name") or "").lower()
    stem = str(preview.get("domain") or "").split(".")[0].lower()
    squashed = re.sub(r"[^a-z0-9]", "", title)
    return title in (site, stem) or squashed in (re.sub(r"[^a-z0-9]", "", site), stem, stem * 2)


def _score(preview: dict | None) -> int:
    """How complete a preview is: a real title is worth 1, an image 2."""
    if not preview:
        return -1
    return (0 if _weak_title(preview) else 1) + (2 if preview.get("_images") else 0)


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

    def on(*domains):
        return any(host == d or host.endswith("." + d) for d in domains)

    if youtube_id(url):
        return f"https://www.youtube.com/oembed?url={q}&format=json"
    if on("vimeo.com"):
        return f"https://vimeo.com/api/oembed.json?url={q}"
    if on("tiktok.com"):
        return f"https://www.tiktok.com/oembed?url={q}"
    if on("dailymotion.com", "dai.ly"):
        return f"https://www.dailymotion.com/services/oembed?url={q}&format=json"
    if on("soundcloud.com"):
        return f"https://soundcloud.com/oembed?format=json&url={q}"
    if on("spotify.com"):
        return f"https://open.spotify.com/oembed?url={q}"
    if on("streamable.com"):
        return f"https://api.streamable.com/oembed.json?url={q}"
    return None


class _Fetcher:
    def __init__(self, budget_s: float):
        import httpx

        self.deadline = time.monotonic() + budget_s
        # One client: cookies a site sets on the first hop (consent, "checked" walls) carry on.
        self.client = httpx.Client(follow_redirects=False, trust_env=False,
                                   headers={"Accept-Encoding": "gzip, deflate"})

    def left(self) -> float:
        return self.deadline - time.monotonic()

    def get(self, url: str, cap: int, headers: dict, keep_partial: bool = False):
        """(final url, content-type, bytes, encoding) or None. Each hop checked with is_safe_url."""
        from tools.url_safety import is_safe_url, response_peer_is_public

        current = url
        for _ in range(_MAX_REDIRECTS + 1):
            left = self.left()
            if left < 0.3 or not is_safe_url(current):
                return None
            try:
                with self.client.stream("GET", current, timeout=min(6.0, left), headers=headers) as resp:
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
                            if keep_partial:
                                break
                            return None
                    return current, resp.headers.get("content-type", "").lower(), bytes(body[:cap]), resp.encoding
            except Exception:
                return None
        return None

    def page(self, url: str, persona: dict) -> dict | None:
        """A page parsed into preview fields, following up to two ``<meta http-equiv=refresh>``."""
        got = self.get(url, _MAX_HTML, persona, keep_partial=True)
        for _ in range(3):
            if got is None:
                return None
            final, ctype, raw, enc = got
            if "html" not in ctype:
                out = _blank(final)
                out["_html"] = False
                return out
            parsed = parse_page(raw.decode(enc or "utf-8", errors="replace"), final)
            parsed["_final"], parsed["_html"] = final, True
            if parsed["_refresh"] and parsed["_refresh"] != final and _score(parsed) < 3:
                got = self.get(parsed["_refresh"], _MAX_HTML, persona, keep_partial=True)
                continue
            return parsed
        return None

    def json(self, url: str) -> dict:
        got = self.get(url, 256 * 1024, {"User-Agent": _SAFARI_UA, "Accept": "application/json"})
        if got is None:
            return {}
        try:
            out = json.loads(got[2])
        except ValueError:
            return {}
        return out if isinstance(out, dict) else {}

    def image(self, url: str, referer: str) -> bytes | None:
        """An image worth showing (≥ 120 px on its short side), or None."""
        from plugins.vault.store import image_size

        got = self.get(url, _MAX_IMAGE, {**_IMAGE_HEADERS, "Referer": referer})
        if got is None or not got[1].startswith("image/") or len(got[2]) < 1000:
            return None
        dims = image_size(got[2])
        if dims is None or min(dims) < _MIN_IMAGE_SIDE:
            return None
        return got[2]

    def close(self):
        try:
            self.client.close()
        except Exception:
            pass


def _blank(url: str) -> dict:
    return {"title": "", "site_name": _domain(url), "domain": _domain(url), "kind": "page", "duration_s": None,
            "author": None, "description": None, "_image": "", "_images": [],
            "_icon": urljoin(url, "/favicon.ico"), "_oembed": "", "_refresh": "", "_final": url}


def _apply_oembed(preview: dict, oe: dict, url: str) -> None:
    known = _oembed_endpoint(url) is not None
    if oe.get("title") and (known or _weak_title(preview)):
        preview["title"] = str(oe["title"])[:300]
    preview["author"] = oe.get("author_name") or preview.get("author")
    preview["site_name"] = oe.get("provider_name") or preview.get("site_name")
    if oe.get("type") == "video" or youtube_id(url):
        preview["kind"] = "video"
    preview["duration_s"] = parse_duration(oe.get("duration")) or preview.get("duration_s")
    thumb = oe.get("thumbnail_url")
    if isinstance(thumb, str) and thumb:
        preview["_images"] = [urljoin(url, thumb)] + [i for i in preview.get("_images") or [] if i != thumb]


def fetch(url: str, budget_s: float = BUDGET_S, want_favicon: bool = True) -> dict | None:
    """{"preview": {...}, "image": bytes|None, "favicon": (bytes, mime)|None}, or None if neither the
    page nor its oEmbed could be fetched at all."""
    try:
        f = _Fetcher(budget_s)
    except Exception:
        return None
    _quiet.on = True
    try:
        # The page, as each client in turn, until one gets a real title and an image.
        preview = None
        for persona in _PERSONAS:
            if f.left() < 1.5:
                break
            got = f.page(url, persona)
            if got is not None and _score(got) > _score(preview):
                preview = got
            if _score(preview) >= 3 or (preview is not None and not preview.get("_html", True)):
                break

        endpoint = _oembed_endpoint(url) or (preview or {}).get("_oembed")
        if endpoint and f.left() > 1.0:
            oe = f.json(endpoint)
            if oe:
                preview = preview or _blank(url)
                _apply_oembed(preview, oe, url)
        if preview is None:
            return None

        # Never keep a wall's title (or just the site's name); the link itself usually says what it is.
        if _weak_title(preview):
            from_link = title_from_url(url)
            if from_link or is_wall_title(preview.get("title") or ""):
                preview["title"] = from_link
            if preview.get("description") and is_wall_title(preview["description"]):
                preview["description"] = None

        image = None
        vid = youtube_id(url)
        candidates = ([f"https://i.ytimg.com/vi/{vid}/maxresdefault.jpg", f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"]
                      if vid else [])
        candidates += [c for c in preview.get("_images") or [] if c not in candidates]
        referer = preview.get("_final") or url
        for candidate in candidates[:8]:
            if f.left() < 0.5:
                break
            image = f.image(candidate, referer)
            if image:
                break
        favicon = None
        if want_favicon and preview.get("_icon") and f.left() > 0.5:
            got = f.get(preview["_icon"], _MAX_FAVICON, {**_IMAGE_HEADERS, "Referer": referer})
            if got is not None and got[1].startswith("image/") and got[2]:
                favicon = (got[2], got[1].split(";")[0])
        clean = {k: v for k, v in preview.items() if not k.startswith("_")}
        return {"preview": clean, "image": image, "favicon": favicon}
    except Exception:
        return None
    finally:
        _quiet.on = False
        f.close()
