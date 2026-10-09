"""Home Assistant access for the Toyota tools and the Car page.

REST for states, services and config-entry flows; the websocket for what REST doesn't offer
(the entity registry, sign-ins in progress). aiohttp on purpose: Cloudflare in front of
Pranav's Home Assistant answers 403 to Python urllib's default User-Agent; aiohttp's gets through.
"""
from __future__ import annotations

import asyncio
import json
from typing import Any, Iterable

READ_TIMEOUT = 15.0
# A remote command waits for Toyota to hear back from the car. The phone reaches the server
# through Cloudflare, which cuts a request at 100 s, so the whole request stays under ~90 s.
COMMAND_TIMEOUT = 75.0
_PARALLEL_STATE_READS = 8
# The entity registry runs to several MB; anything far past that is not Home Assistant.
_WS_MAX_MESSAGE = 64 * 1024 * 1024


class HAError(Exception):
    """Home Assistant answered with an error — its own, or Toyota's behind the integration."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class HAUnreachable(HAError):
    """No answer from Home Assistant, or the server isn't set up to reach it."""


class HATimeout(HAUnreachable):
    """Home Assistant took longer than the timeout — it may still be working on the request."""


def config() -> tuple[str, str]:
    """(url, token) from HASS_URL / HASS_TOKEN: the environment first, then the server's .env."""
    from jarviscopilot_cli.config import get_env_value

    url = (get_env_value("HASS_URL") or "").strip().rstrip("/")
    token = (get_env_value("HASS_TOKEN") or "").strip()
    return url, token


def configured() -> bool:
    url, token = config()
    return bool(url and token)


def error_message(text: str, status: int) -> str:
    """The readable part of an error body: Home Assistant's ``message``, else short plain text."""
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, dict):
        for key in ("message", "error", "detail"):
            if data.get(key):
                return str(data[key])
    text = (text or "").strip()
    if text and len(text) < 300 and not text.startswith("<"):
        return text
    return f"Home Assistant answered {status}"


def _unreachable(exc: BaseException) -> HAUnreachable:
    return HAUnreachable(f"Home Assistant isn't reachable ({type(exc).__name__})")


class HAClient:
    """One Home Assistant, by URL and long-lived token."""

    def __init__(self, url: str | None = None, token: str | None = None) -> None:
        if url is None or token is None:
            env_url, env_token = config()
            url = env_url if url is None else url
            token = env_token if token is None else token
        self.url = (url or "").rstrip("/")
        self.token = token or ""

    def _check(self) -> None:
        if not self.url or not self.token:
            raise HAUnreachable("Home Assistant isn't set up on the Jarvis server (HASS_URL / HASS_TOKEN).")

    async def request(self, method: str, path: str, body: Any = None,
                      timeout: float = READ_TIMEOUT) -> Any:
        import aiohttp

        self._check()
        try:
            async with aiohttp.ClientSession() as session:
                return await self._send(session, method, path, body, timeout)
        except HAError:
            raise
        except asyncio.TimeoutError as exc:
            raise HATimeout(f"Home Assistant didn't answer within {timeout:g} s") from exc
        except (aiohttp.ClientError, OSError) as exc:
            raise _unreachable(exc) from exc

    async def _send(self, session: Any, method: str, path: str, body: Any, timeout: float) -> Any:
        import aiohttp

        async with session.request(
            method, self.url + path, json=body,
            headers={"Authorization": f"Bearer {self.token}"},
            timeout=aiohttp.ClientTimeout(total=timeout),
        ) as resp:
            text = await resp.text()
            if resp.status >= 400:
                raise HAError(error_message(text, resp.status), resp.status)
            if not text.strip():
                return None
            try:
                return json.loads(text)
            except ValueError as exc:
                raise HAError("Home Assistant sent something that isn't JSON.", resp.status) from exc

    async def get(self, path: str, timeout: float = READ_TIMEOUT) -> Any:
        return await self.request("GET", path, None, timeout)

    async def post(self, path: str, body: Any = None, timeout: float = READ_TIMEOUT) -> Any:
        return await self.request("POST", path, {} if body is None else body, timeout)

    async def delete(self, path: str) -> Any:
        return await self.request("DELETE", path)

    async def states(self, entity_ids: Iterable[str]) -> dict[str, dict]:
        """Current states by entity id; entities Home Assistant doesn't have are left out."""
        import aiohttp

        self._check()
        ids = sorted({e for e in entity_ids if e})
        out: dict[str, dict] = {}
        gate = asyncio.Semaphore(_PARALLEL_STATE_READS)

        async def read(session: Any, entity_id: str) -> None:
            async with gate:
                try:
                    state = await self._send(session, "GET", f"/api/states/{entity_id}", None, READ_TIMEOUT)
                except HAError as exc:
                    if exc.status == 404:
                        return
                    raise
                if isinstance(state, dict):
                    out[entity_id] = state

        try:
            async with aiohttp.ClientSession() as session:
                # Every read finishes before the session closes; the first failure is raised after.
                results = await asyncio.gather(*(read(session, e) for e in ids), return_exceptions=True)
        except (aiohttp.ClientError, OSError) as exc:
            raise _unreachable(exc) from exc
        for result in results:
            if isinstance(result, HAError):
                raise result
            if isinstance(result, asyncio.TimeoutError):
                raise HATimeout("Home Assistant didn't answer in time") from result
            if isinstance(result, (aiohttp.ClientError, OSError)):
                raise _unreachable(result) from result
            if isinstance(result, BaseException):
                raise result
        return out

    async def ws_call(self, kind: str, timeout: float = READ_TIMEOUT, **payload: Any) -> Any:
        """One websocket command (``{"type": kind, **payload}``); returns its ``result``.

        A failed command's ``error.message`` is the reason (Toyota's, for the integration's
        services) — REST only answers a failed service call with a bare 500.
        """
        import aiohttp

        self._check()
        ws_url = "ws" + self.url[len("http"):] + "/api/websocket"
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout + READ_TIMEOUT * 2)) as session:
                async with session.ws_connect(ws_url, max_msg_size=_WS_MAX_MESSAGE) as ws:
                    await ws.receive_json(timeout=READ_TIMEOUT)
                    await ws.send_json({"type": "auth", "access_token": self.token})
                    auth = await ws.receive_json(timeout=READ_TIMEOUT)
                    if auth.get("type") != "auth_ok":
                        raise HAError("Home Assistant refused the Jarvis server's token.", 401)
                    await ws.send_json({"id": 1, "type": kind, **payload})
                    while True:
                        msg = await ws.receive_json(timeout=timeout)
                        if msg.get("id") == 1:
                            break
        except HAError:
            raise
        except asyncio.TimeoutError as exc:
            raise HATimeout(f"Home Assistant didn't answer within {timeout:g} s") from exc
        except (aiohttp.ClientError, OSError, ValueError, TypeError) as exc:
            raise _unreachable(exc) from exc
        if not msg.get("success"):
            error = msg.get("error") or {}
            raise HAError(str(error.get("message") or f"Home Assistant refused {kind}."))
        return msg.get("result")

    async def entity_registry(self) -> list[dict]:
        rows = await self.ws_call("config/entity_registry/list")
        return [row for row in rows or [] if isinstance(row, dict)]

    async def flows_in_progress(self) -> list[dict]:
        """Config flows waiting on a step (REST lost this listing; the websocket has it)."""
        rows = await self.ws_call("config_entries/flow/progress")
        return [row for row in rows or [] if isinstance(row, dict)]
