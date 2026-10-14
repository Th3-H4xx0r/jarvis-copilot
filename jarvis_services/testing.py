"""A fake for ``base.Http`` that answers canned JSON and records every request.

Tests (root and webui) use it so no service API is ever called for real.
"""
from __future__ import annotations

import json as _json
from dataclasses import dataclass, field
from typing import Any, Callable, Optional, Union
from urllib.parse import urlencode

from jarvis_services.base import HttpError, Response


@dataclass
class Call:
    method: str
    url: str
    headers: dict = field(default_factory=dict)
    params: Optional[dict] = None
    json: Any = None
    data: Any = None

    @property
    def full_url(self) -> str:
        if self.params:
            return f"{self.url}{'&' if '?' in self.url else '?'}{urlencode(self.params)}"
        return self.url


Answer = Union[Response, Callable[[Call], Response], BaseException]


class FakeHttp:
    """Routes ``(method, url)`` to an answer. A route URL with a query must match the
    full URL; without one it matches any query. Unmatched requests get a 404."""

    def __init__(self):
        self.routes: list = []
        self.calls: list = []

    def add(self, method: str, url: str, body: Any = None, status: int = 200,
            headers: Optional[dict] = None) -> "FakeHttp":
        if isinstance(body, (Response, BaseException)) or callable(body):
            answer = body
        else:
            content = body if isinstance(body, bytes) else _json.dumps(body).encode()
            answer = Response(status, content, headers or {})
        self.routes.append((method.upper(), url, answer))
        return self

    def fail(self, method: str, url: str, message: str = "offline") -> "FakeHttp":
        return self.add(method, url, HttpError(0, message))

    def request(self, method: str, url: str, *, headers: Optional[dict] = None,
                params: Optional[dict] = None, json: Any = None, data: Any = None,
                timeout: Optional[float] = None) -> Response:
        call = Call(method.upper(), url, dict(headers or {}), params, json, data)
        self.calls.append(call)
        full = call.full_url
        for m, route, answer in self.routes:
            if m != call.method:
                continue
            if route == full or ("?" not in route and full.split("?", 1)[0] == route):
                if isinstance(answer, BaseException):
                    raise answer
                return answer(call) if callable(answer) else answer
        return Response(404, b'{"message": "no fake route"}', {})

    def called(self, method: str, prefix: str) -> list:
        return [c for c in self.calls if c.method == method.upper() and c.full_url.startswith(prefix)]
