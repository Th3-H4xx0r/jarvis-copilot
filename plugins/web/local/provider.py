"""Local web extraction: fast fetch, then the headless browser, then a stealth browser.

Reads pages on this machine, with no API key. Each URL tries up to three tiers:

1. ``fetch`` uses Scrapling's ``Fetcher`` (curl_cffi with a real browser TLS
   fingerprint, no browser). trafilatura then pulls the main text out as
   markdown. This handles most pages in well under a second.
2. ``browser``: when the fetched text is too thin (the page builds itself with
   JavaScript), the headless browser from ``tools.browser_tool`` renders it and
   the rendered HTML goes through trafilatura.
3. ``stealth``: when the site serves a bot challenge (HTTP 403/429/503 with
   Cloudflare/captcha markers, or the browser tier was challenged too),
   Scrapling's ``StealthyFetcher`` tries once more. Turn it off with
   ``web.stealth_fallback: false``.

Every result records the tier that answered (``metadata.tier``) and how long the
URL took (``metadata.ms``). A URL that no tier could read gets an ``error`` that
says what each tier ran into. It never comes back as an empty success.

The tier functions are constructor arguments, so tests run without a network,
a browser, or the optional ``scrapling`` / ``trafilatura`` packages.
"""

from __future__ import annotations

import concurrent.futures
import importlib.util
import json
import logging
import threading
import time
import uuid
from typing import Any, Callable, Dict, List, Optional, Tuple

from agent.web_search_provider import WebSearchProvider
from tools.url_safety import is_safe_url
from tools.website_policy import check_website_access

logger = logging.getLogger(__name__)

# A page with less readable text than this is treated as "needs JavaScript".
MIN_TEXT_CHARS = 400
# Per-URL cap on the text handed back.
MAX_CONTENT_CHARS = 50_000
# Tier timeouts. Scrapling's Fetcher takes seconds; its browsers take milliseconds.
FETCH_TIMEOUT_S = 15
STEALTH_TIMEOUT_MS = 30_000
# Wall-clock cap for one extract() call; URLs still running then get an error.
EXTRACT_DEADLINE_S = 90
MAX_WORKERS = 5

_REQUIRED_MODULES = ("scrapling", "trafilatura", "curl_cffi")
_BLOCK_STATUSES = frozenset({403, 429, 503})
# Statuses no other tier can fix.
_FINAL_STATUSES = frozenset({404, 410})
_CHALLENGE_MARKERS = (
    "cf-chl",
    "_cf_chl_opt",
    "challenge-platform",
    "cf-browser-verification",
    "just a moment",
    "attention required",
    "checking your browser",
    "captcha",
    "are you a robot",
    "verify you are human",
    "px-captcha",
    "datadome",
    "access denied",
)
_HTML_TYPES = ("html", "xml")
_TEXT_TYPES = ("text/plain", "text/markdown", "json")
# The browser tier reads the rendered HTML and the visible text in one command.
_BROWSER_READ_JS = (
    "JSON.stringify({"
    "html: document.documentElement ? document.documentElement.outerHTML : '',"
    "text: document.body ? document.body.innerText : ''})"
)

Page = Dict[str, Any]
PageFn = Callable[[str], Page]


# ---------------------------------------------------------------------------
# Default tier implementations (real network / browser)
# ---------------------------------------------------------------------------


def _from_scrapling(resp: Any, url: str) -> Page:
    headers = getattr(resp, "headers", None) or {}
    content_type = ""
    if hasattr(headers, "get"):
        content_type = str(headers.get("content-type") or headers.get("Content-Type") or "")
    body = getattr(resp, "body", b"") or b""
    if isinstance(body, bytes):
        html = body.decode(getattr(resp, "encoding", None) or "utf-8", errors="replace")
    else:
        html = str(body)
    status = getattr(resp, "status", None)
    return {
        "status": int(status) if status is not None else None,
        "url": str(getattr(resp, "url", "") or url),
        "html": html,
        "content_type": content_type,
    }


def _scrapling_fetch(url: str) -> Page:
    """Tier 1: one plain HTTP request with a real browser TLS fingerprint.

    ``follow_redirects="safe"`` makes curl refuse redirects to private
    addresses, and the provider re-checks the final URL as well.
    """
    from scrapling.fetchers import Fetcher

    resp = Fetcher.get(url, timeout=FETCH_TIMEOUT_S, retries=1, follow_redirects="safe")
    return _from_scrapling(resp, url)


def _scrapling_stealth(url: str) -> Page:
    """Tier 3: Scrapling's stealth browser, which also solves Cloudflare challenges."""
    from scrapling.fetchers import StealthyFetcher

    resp = StealthyFetcher.fetch(
        url,
        headless=True,
        timeout=STEALTH_TIMEOUT_MS,
        solve_cloudflare=True,
        disable_resources=True,
        block_ads=True,
    )
    return _from_scrapling(resp, url)


def _decode_eval_result(raw: Any) -> Dict[str, Any]:
    payload = raw
    for _ in range(2):  # the CLI may hand back the JSON text once or twice encoded
        if not isinstance(payload, str):
            break
        try:
            payload = json.loads(payload)
        except (TypeError, ValueError):
            return {}
    return payload if isinstance(payload, dict) else {}


def _browser_read(url: str) -> Page:
    """Tier 2: render the page in the headless browser and read its HTML.

    Uses a throwaway browser session that is always closed afterwards.
    ``browser_navigate`` applies its own secret, SSRF and redirect checks.
    """
    from tools import browser_tool

    task_id = f"web-extract-{uuid.uuid4().hex[:12]}"
    try:
        nav = json.loads(browser_tool.browser_navigate(url, task_id=task_id) or "{}")
        if not nav.get("success"):
            return {"status": None, "url": url, "html": "", "error": nav.get("error") or "navigation failed"}
        final_url = nav.get("url") or url
        res = browser_tool._run_browser_command(task_id, "eval", [_BROWSER_READ_JS])
        if not res.get("success"):
            return {"status": None, "url": final_url, "html": "",
                    "error": res.get("error") or "could not read the rendered page"}
        payload = _decode_eval_result((res.get("data") or {}).get("result"))
        html = str(payload.get("html") or "")
        text = str(payload.get("text") or "")
        # browser_navigate flags challenge-looking titles. A long readable page
        # with "Cloudflare" in its title is an article, not a challenge.
        blocked = bool(nav.get("bot_detection_warning")) and len(text.strip()) < MIN_TEXT_CHARS * 4
        return {"status": None, "url": final_url, "html": html, "text": text,
                "title": nav.get("title") or "", "blocked": blocked}
    finally:
        try:
            browser_tool.cleanup_browser(task_id)
        except Exception as exc:  # noqa: BLE001 — cleanup must never mask the result
            logger.debug("web-extract browser cleanup failed for %s: %s", task_id, exc)


def html_to_text(html: str, url: str) -> Tuple[str, str]:
    """Main text of an HTML page as markdown, plus its title (trafilatura)."""
    import trafilatura

    text = trafilatura.extract(
        html,
        url=url,
        output_format="markdown",
        include_links=True,
        include_tables=True,
        include_comments=False,
        favor_recall=True,
    ) or ""
    title = ""
    try:
        meta = trafilatura.extract_metadata(html, default_url=url)
        title = (getattr(meta, "title", None) or "") if meta else ""
    except Exception as exc:  # noqa: BLE001 — a title is optional
        logger.debug("trafilatura metadata failed for %s: %s", url, exc)
    return title, text


def _stealth_fallback_enabled() -> bool:
    """``web.stealth_fallback`` from config.yaml (default on)."""
    try:
        from jarviscopilot_cli.config import load_config

        web = load_config().get("web") or {}
    except Exception as exc:  # noqa: BLE001 — unreadable config keeps the default
        logger.debug("Could not read web.stealth_fallback: %s", exc)
        return True
    from utils import is_truthy_value

    return is_truthy_value(web.get("stealth_fallback") if isinstance(web, dict) else None, default=True)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _has_challenge_markers(html: str) -> bool:
    head = (html or "")[:50_000].lower()
    return any(marker in head for marker in _CHALLENGE_MARKERS)


def _content_kind(content_type: str) -> str:
    ct = (content_type or "").lower()
    if not ct or any(t in ct for t in _HTML_TYPES):
        return "html"
    if any(t in ct for t in _TEXT_TYPES):
        return "text"
    return "unsupported"


def _cap(text: str) -> str:
    if len(text) <= MAX_CONTENT_CHARS:
        return text
    return text[:MAX_CONTENT_CHARS] + f"\n\n[... truncated at {MAX_CONTENT_CHARS:,} characters]"


def _ms_since(t0: float) -> int:
    return int((time.monotonic() - t0) * 1000)


def _failure(url: str, error: str, t0: float, **extra: Any) -> Dict[str, Any]:
    return {
        "url": url,
        "title": "",
        "content": "",
        "raw_content": "",
        "error": error,
        "metadata": {"tier": None, "ms": _ms_since(t0)},
        **extra,
    }


def _policy_failure(url: str, blocked: Dict[str, str], t0: float) -> Dict[str, Any]:
    return _failure(
        url,
        blocked.get("message") or "Blocked by website policy",
        t0,
        blocked_by_policy={k: blocked.get(k) for k in ("host", "rule", "source")},
    )


class _Verdict:
    """What one tier's attempt amounted to."""

    __slots__ = ("result", "final", "blocked")

    def __init__(self, result: Optional[Dict[str, Any]] = None,
                 final: Optional[Dict[str, Any]] = None, blocked: bool = False) -> None:
        self.result = result  # a usable page: stop and return it
        self.final = final  # a failure no other tier can fix: stop and return it
        self.blocked = blocked  # the site served a bot challenge


# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------


class LocalWebProvider(WebSearchProvider):
    """Extract-only provider that reads pages locally (no API key)."""

    def __init__(
        self,
        *,
        fetch: Optional[PageFn] = None,
        browser: Optional[PageFn] = None,
        stealth: Optional[PageFn] = None,
        to_text: Optional[Callable[[str, str], Tuple[str, str]]] = None,
        stealth_enabled: Optional[Callable[[], bool]] = None,
    ) -> None:
        self._fetch = fetch or _scrapling_fetch
        self._browser = browser or _browser_read
        self._stealth = stealth or _scrapling_stealth
        self._to_text = to_text or html_to_text
        self._stealth_enabled = stealth_enabled or _stealth_fallback_enabled

    @property
    def name(self) -> str:
        return "local"

    @property
    def display_name(self) -> str:
        return "Local (fast fetch)"

    def is_available(self) -> bool:
        """True when scrapling, curl_cffi and trafilatura are importable (no I/O)."""
        try:
            return all(importlib.util.find_spec(m) is not None for m in _REQUIRED_MODULES)
        except (ImportError, ValueError):
            return False

    def supports_search(self) -> bool:
        return False

    def supports_extract(self) -> bool:
        return True

    def get_setup_schema(self) -> Dict[str, Any]:
        return {
            "name": "Local (fast fetch)",
            "badge": "free · no key · extract only",
            "tag": "Reads pages on this machine: fast fetch, then the headless browser, then a stealth browser",
            "env_vars": [],
        }

    # -- extract -----------------------------------------------------------

    def extract(self, urls: List[str], **kwargs: Any) -> List[Dict[str, Any]]:
        """Read every URL in parallel; results keep the input order."""
        urls = [u for u in (urls or []) if isinstance(u, str) and u.strip()]
        if not urls:
            return []
        t0 = time.monotonic()
        # One browser-based tier at a time per call keeps memory in check on a
        # small server (Chromium is ~300-500 MB per live session).
        browser_slot = threading.BoundedSemaphore(1)
        results: List[Optional[Dict[str, Any]]] = [None] * len(urls)
        pool = concurrent.futures.ThreadPoolExecutor(
            max_workers=min(MAX_WORKERS, len(urls)), thread_name_prefix="web-local"
        )
        try:
            futures = {pool.submit(self._extract_one, url, browser_slot): i for i, url in enumerate(urls)}
            try:
                for fut in concurrent.futures.as_completed(futures, timeout=EXTRACT_DEADLINE_S):
                    i = futures[fut]
                    try:
                        results[i] = fut.result()
                    except Exception as exc:  # noqa: BLE001 — one URL must not sink the rest
                        logger.warning("local extract crashed for %s: %s", urls[i], exc)
                        results[i] = _failure(urls[i], f"{type(exc).__name__}: {exc}", t0)
            except concurrent.futures.TimeoutError:
                pass
        finally:
            pool.shutdown(wait=False, cancel_futures=True)
        return [
            r if r is not None else _failure(urls[i], f"timed out after {EXTRACT_DEADLINE_S}s", t0)
            for i, r in enumerate(results)
        ]

    def _extract_one(self, url: str, browser_slot: threading.BoundedSemaphore) -> Dict[str, Any]:
        t0 = time.monotonic()
        if not is_safe_url(url):
            return _failure(url, "Blocked: URL targets a private or internal network address", t0)
        policy = check_website_access(url)
        if policy:
            return _policy_failure(url, policy, t0)

        reasons: List[str] = []
        tried: set = set()
        tiers = {"fetch": self._fetch, "browser": self._browser, "stealth": self._stealth}

        def attempt(tier: str) -> _Verdict:
            tried.add(tier)
            try:
                if tier == "fetch":
                    page = tiers[tier](url)
                else:
                    with browser_slot:
                        page = tiers[tier](url)
            except Exception as exc:  # noqa: BLE001 — a failing tier escalates to the next
                page = {"status": None, "url": url, "html": "", "error": f"{type(exc).__name__}: {exc}"}
            return self._judge(tier, url, page if isinstance(page, dict) else {}, t0, reasons)

        verdict = attempt("fetch")
        if verdict.result or verdict.final:
            return verdict.result or verdict.final
        blocked = verdict.blocked
        stealth_on: Optional[bool] = None

        def stealth_allowed() -> bool:
            nonlocal stealth_on
            if stealth_on is None:
                stealth_on = bool(self._stealth_enabled())
            return stealth_on

        # A challenge page will not render for the plain headless browser either,
        # so go straight to stealth when it is allowed.
        if blocked and stealth_allowed():
            verdict = attempt("stealth")
            if verdict.result or verdict.final:
                return verdict.result or verdict.final

        verdict = attempt("browser")
        if verdict.result or verdict.final:
            return verdict.result or verdict.final
        blocked = blocked or verdict.blocked

        if verdict.blocked and "stealth" not in tried and stealth_allowed():
            verdict = attempt("stealth")
            if verdict.result or verdict.final:
                return verdict.result or verdict.final

        if blocked and not stealth_allowed():
            reasons.append("stealth fallback is off (web.stealth_fallback)")
        return _failure(url, "Could not read the page. " + "; ".join(reasons), t0)

    def _judge(self, tier: str, url: str, page: Page, t0: float, reasons: List[str]) -> _Verdict:
        status = page.get("status")
        final_url = str(page.get("url") or url)
        html = str(page.get("html") or "")

        if final_url != url:
            if not is_safe_url(final_url):
                return _Verdict(final=_failure(
                    url, "Blocked: redirect landed on a private or internal network address", t0))
            policy = check_website_access(final_url)
            if policy:
                return _Verdict(final=_policy_failure(url, policy, t0))

        if page.get("error"):
            reasons.append(f"{tier}: {page['error']}")
            return _Verdict(blocked=bool(page.get("blocked")))
        if status in _FINAL_STATUSES:
            return _Verdict(final=_failure(url, f"HTTP {status} from {final_url}", t0))
        if page.get("blocked") or (status in _BLOCK_STATUSES and _has_challenge_markers(html)):
            prefix = f"HTTP {status}, " if status else ""
            reasons.append(f"{tier}: {prefix}blocked by a bot challenge")
            return _Verdict(blocked=True)
        if status is not None and not 200 <= int(status) < 300:
            reasons.append(f"{tier}: HTTP {status}")
            return _Verdict()

        kind = _content_kind(str(page.get("content_type") or ""))
        if kind == "unsupported":
            return _Verdict(final=_failure(
                url, f"{page.get('content_type')} content is not supported by the local extractor", t0))
        if kind == "text":
            title, text = "", html
        else:
            title, text = self._to_text(html, final_url)
        title, text = (title or page.get("title") or ""), (text or "").strip()
        fallback = str(page.get("text") or "").strip()  # browser tier: the rendered page's visible text
        if len(text) < MIN_TEXT_CHARS and len(fallback) > len(text):
            text = fallback
        if len(text) < MIN_TEXT_CHARS:
            reasons.append(f"{tier}: only {len(text)} characters of readable text")
            return _Verdict()

        text = _cap(text)
        return _Verdict(result={
            "url": url,
            "title": title,
            "content": text,
            "raw_content": text,
            "metadata": {"tier": tier, "ms": _ms_since(t0), "final_url": final_url, "status": status},
        })
