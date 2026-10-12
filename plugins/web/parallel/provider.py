"""Parallel.ai web search + content extraction — plugin form.

Subclasses :class:`agent.web_search_provider.WebSearchProvider`. Uses two
distinct Parallel SDK clients:

- ``Parallel`` (sync)        — for :meth:`search`
- ``AsyncParallel`` (async)  — for :meth:`extract`

This is the first plugin to exercise the **async-extract** code path in
the ABC: :meth:`extract` is declared ``async def``, and the dispatcher
in :func:`tools.web_tools.web_extract_tool` detects coroutines via
:func:`inspect.iscoroutinefunction` and awaits.

Config keys this provider responds to::

    web:
      search_backend: "parallel"      # explicit per-capability
      extract_backend: "parallel"     # explicit per-capability
      backend: "parallel"             # shared fallback
      parallel_mode: "fast"           # turbo | fast ($1 / 1k) | basic | advanced ($5 / 1k)

Env vars::

    PARALLEL_API_KEY=...             # https://parallel.ai (required; Settings → Providers)
    PARALLEL_SEARCH_MODE=fast        # legacy override when web.parallel_mode is unset

Search calls ``POST https://api.parallel.ai/v1/search`` directly over httpx, so it
needs no SDK; extract still uses the SDK.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict, List

import httpx

from agent.web_search_provider import WebSearchProvider

logger = logging.getLogger(__name__)

SEARCH_URL = "https://api.parallel.ai/v1/search"
SEARCH_MODES = ("turbo", "fast", "basic", "advanced")
DEFAULT_SEARCH_MODE = "fast"  # $1 per 1,000 searches, ~700 ms
MAX_SNIPPET_CHARS = 1500
_TIMEOUT_S = 20.0

# Module-level note: the canonical cache slots ``_parallel_client`` and
# ``_async_parallel_client`` live on :mod:`tools.web_tools` so tests that do
# ``tools.web_tools._parallel_client = None`` between cases see fresh state.
# The plugin reads/writes through that public module (see
# :func:`_get_sync_client` / :func:`_get_async_client`).


def _ensure_parallel_sdk_installed() -> None:
    """Trigger lazy install of the parallel SDK if it isn't present.

    Mirrors the lazy-deps pattern used by the legacy implementation.
    Swallows benign ImportError from the lazy_deps helper itself; if the
    SDK is genuinely missing the subsequent ``from parallel import ...``
    raises ImportError that the caller can handle.
    """
    try:
        from tools.lazy_deps import ensure as _lazy_ensure

        _lazy_ensure("search.parallel", prompt=False)
    except ImportError:
        pass
    except Exception as exc:  # noqa: BLE001 — surface install hint as ImportError
        raise ImportError(str(exc))


def _get_sync_client() -> Any:
    """Lazy-load + cache the sync Parallel client.

    Cache lives on :mod:`tools.web_tools` (as ``_parallel_client``) so unit
    tests that reset that name between cases keep working.
    """
    import tools.web_tools as _wt

    cached = getattr(_wt, "_parallel_client", None)
    if cached is not None:
        return cached

    api_key = os.getenv("PARALLEL_API_KEY")
    if not api_key:
        raise ValueError(
            "PARALLEL_API_KEY environment variable not set. "
            "Get your API key at https://parallel.ai"
        )

    _ensure_parallel_sdk_installed()
    from parallel import Parallel  # noqa: WPS433 — deliberately lazy

    client = Parallel(api_key=api_key)
    _wt._parallel_client = client
    return client


def _get_async_client() -> Any:
    """Lazy-load + cache the async Parallel client.

    Cache lives on :mod:`tools.web_tools` (as ``_async_parallel_client``).
    """
    import tools.web_tools as _wt

    cached = getattr(_wt, "_async_parallel_client", None)
    if cached is not None:
        return cached

    api_key = os.getenv("PARALLEL_API_KEY")
    if not api_key:
        raise ValueError(
            "PARALLEL_API_KEY environment variable not set. "
            "Get your API key at https://parallel.ai"
        )

    _ensure_parallel_sdk_installed()
    from parallel import AsyncParallel  # noqa: WPS433 — deliberately lazy

    client = AsyncParallel(api_key=api_key)
    _wt._async_parallel_client = client
    return client


def _reset_clients_for_tests() -> None:
    """Drop both cached clients so tests can re-instantiate cleanly.

    Clears the canonical slots on :mod:`tools.web_tools` (where
    :func:`_get_sync_client` / :func:`_get_async_client` read/write them).
    """
    import tools.web_tools as _wt

    _wt._parallel_client = None
    _wt._async_parallel_client = None


# Backward-compatible aliases for the names that lived in tools.web_tools
# before the migration (matches existing tests + external callers).
_get_parallel_client = _get_sync_client
_get_async_parallel_client = _get_async_client


def _resolve_search_mode() -> str:
    """``web.parallel_mode`` (or the legacy PARALLEL_SEARCH_MODE env var), else "fast".
    Old SDK modes ("agentic", "one-shot") and typos fall back to "fast"."""
    import tools.web_tools as _wt

    mode = str(_wt._load_web_config().get("parallel_mode") or os.getenv("PARALLEL_SEARCH_MODE") or "")
    mode = mode.lower().strip()
    return mode if mode in SEARCH_MODES else DEFAULT_SEARCH_MODE


def _http_error(status: int) -> str:
    if status in (401, 403):
        return "Parallel refused the API key (check it in Settings → Providers)"
    if status == 402:
        return "Parallel credits are used up"
    if status == 429:
        return "Parallel rate limit hit"
    return f"Parallel search failed (HTTP {status})"


class ParallelWebSearchProvider(WebSearchProvider):
    """Parallel.ai search + async extract provider."""

    @property
    def name(self) -> str:
        return "parallel"

    @property
    def display_name(self) -> str:
        return "Parallel"

    def is_available(self) -> bool:
        """Return True when ``PARALLEL_API_KEY`` is set to a non-empty value."""
        return bool(os.getenv("PARALLEL_API_KEY", "").strip())

    def supports_search(self) -> bool:
        return True

    def supports_extract(self) -> bool:
        return True

    def search(self, query: str, limit: int = 5) -> Dict[str, Any]:
        """One Parallel ``/v1/search`` call in the configured mode (default "fast").

        Never raises: a missing/refused key, used-up credits, a rate limit or a
        network error comes back as ``{"success": False, "error": ...}``.
        """
        try:
            from tools.interrupt import is_interrupted

            if is_interrupted():
                return {"success": False, "error": "Interrupted"}
        except ImportError:
            pass

        api_key = os.getenv("PARALLEL_API_KEY", "").strip()
        if not api_key:
            return {
                "success": False,
                "error": "PARALLEL_API_KEY is not set. Add your Parallel key in Settings → Providers.",
            }

        mode = _resolve_search_mode()
        logger.info("Parallel search: '%s' (mode=%s, limit=%d)", query, mode, limit)
        body = {
            "objective": query,
            "search_queries": [query],
            "mode": mode,
            "advanced_settings": {
                "max_results": max(1, min(int(limit or 5), 20)),
                "excerpt_settings": {"max_chars_per_result": MAX_SNIPPET_CHARS},
            },
        }
        try:
            resp = httpx.post(
                SEARCH_URL,
                json=body,
                headers={"x-api-key": api_key, "Content-Type": "application/json"},
                timeout=_TIMEOUT_S,
            )
        except Exception as exc:  # noqa: BLE001 — network trouble is a plain failure
            logger.warning("Parallel search error: %s", exc)
            return {"success": False, "error": f"Parallel search failed: {type(exc).__name__}"}

        if resp.status_code != 200:
            logger.warning("Parallel search HTTP %s", resp.status_code)
            return {"success": False, "error": _http_error(resp.status_code)}
        try:
            results = resp.json().get("results") or []
        except Exception:  # noqa: BLE001
            return {"success": False, "error": "Parallel search returned an unreadable reply"}

        web_results = []
        for i, result in enumerate(results):
            if not isinstance(result, dict):
                continue
            excerpts = [str(e) for e in (result.get("excerpts") or []) if e]
            web_results.append(
                {
                    "url": result.get("url") or "",
                    "title": result.get("title") or "",
                    "description": " ".join(excerpts)[:MAX_SNIPPET_CHARS],
                    "position": i + 1,
                }
            )
        return {"success": True, "data": {"web": web_results}}

    async def extract(
        self, urls: List[str], **kwargs: Any
    ) -> List[Dict[str, Any]]:
        """Extract content from one or more URLs via the async SDK.

        Returns the legacy list-of-results shape that
        :func:`tools.web_tools.web_extract_tool` expects: one entry per
        successful URL plus one entry per failed URL with an ``error``
        field. Errors are not raised — they're returned as per-URL items.
        """
        try:
            from tools.interrupt import is_interrupted

            if is_interrupted():
                return [
                    {"url": u, "error": "Interrupted", "title": ""} for u in urls
                ]

            logger.info("Parallel extract: %d URL(s)", len(urls))
            response = await _get_async_client().beta.extract(
                urls=urls,
                full_content=True,
            )

            results: List[Dict[str, Any]] = []
            for result in response.results or []:
                content = result.full_content or ""
                if not content:
                    content = "\n\n".join(result.excerpts or [])
                url = result.url or ""
                title = result.title or ""
                results.append(
                    {
                        "url": url,
                        "title": title,
                        "content": content,
                        "raw_content": content,
                        "metadata": {"sourceURL": url, "title": title},
                    }
                )

            for error in response.errors or []:
                results.append(
                    {
                        "url": error.url or "",
                        "title": "",
                        "content": "",
                        "error": error.content or error.error_type or "extraction failed",
                        "metadata": {"sourceURL": error.url or ""},
                    }
                )

            return results
        except ValueError as exc:
            return [{"url": u, "title": "", "content": "", "error": str(exc)} for u in urls]
        except ImportError as exc:
            return [
                {"url": u, "title": "", "content": "", "error": f"Parallel SDK not installed: {exc}"}
                for u in urls
            ]
        except Exception as exc:  # noqa: BLE001
            logger.warning("Parallel extract error: %s", exc)
            return [
                {"url": u, "title": "", "content": "", "error": f"Parallel extract failed: {exc}"}
                for u in urls
            ]

    def get_setup_schema(self) -> Dict[str, Any]:
        return {
            "name": "Parallel",
            "badge": "paid",
            "tag": "Objective-tuned search + parallel page extraction.",
            "env_vars": [
                {
                    "key": "PARALLEL_API_KEY",
                    "prompt": "Parallel API key",
                    "url": "https://parallel.ai",
                },
            ],
        }
