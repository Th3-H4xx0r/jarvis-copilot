#!/usr/bin/env python3
"""JarvisCopilot — widgets skill helper.

Stdlib only, Python 3.10+. Carries Home Screen / Lock Screen widget designs to
and from the web UI's ``/api/widgets`` store with host-signed localhost requests
(the devices skill's client — the same auth the dynamic-island and X5 helpers
use, so no cookies). The server validates designs; this helper only reads the
JSON, prints the server's errors and warnings, and after a change asks every
phone offering the ``widgets_refresh`` device skill to pull the designs now.
A phone that can't be reached is a note, not a failure: it syncs when Jarvis
next opens.

    python3 widgets.py list
    python3 widgets.py show steps
    python3 widgets.py catalog
    python3 widgets.py upsert steps.json          # or: upsert - < steps.json
    python3 widgets.py delete steps

JSON on stdout; ``{"error": ...}`` on stderr and exit code 1 on failure.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import types
from collections.abc import Callable
from pathlib import Path
from typing import Any, NoReturn

REFRESH_SKILL = "widgets_refresh"
HTTP_TIMEOUT = 30.0
# Seconds the phone gets to pull the designs; a backgrounded phone is woken by push first.
REFRESH_TIMEOUT = 20.0
# The HTTP request outlives the invoke so the server's own timeout error comes back.
HTTP_GRACE = 5.0

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_HERE = Path(__file__).resolve()
_DEVICES_REL = Path("skills", "jarviscopilot", "devices", "scripts", "devices.py")
_loaded_devices: dict[Path, types.ModuleType] = {}

Transport = Callable[..., tuple[int, Any]]


class WidgetsError(RuntimeError):
    """The request could not be made, or the server refused it."""

    def __init__(self, message: str, errors: list[str] | None = None) -> None:
        super().__init__(message)
        self.errors = errors or []


# ── devices skill client ─────────────────────────────────────────────────────

def _devices_candidates() -> list[Path]:
    """Where the devices skill's devices.py may live, in the order they are tried."""
    candidates = [_HERE.parents[2] / "devices" / "scripts" / "devices.py"]
    checkout = os.environ.get("JARVISCOPILOT_DIR", "").strip()
    if checkout:
        candidates.append(Path(checkout).expanduser() / _DEVICES_REL)
    hermes_home = os.environ.get("HERMES_HOME", "").strip()
    if hermes_home:
        candidates.append(Path(hermes_home).expanduser() / _DEVICES_REL)
    candidates.append(Path.home() / ".jarviscopilot" / _DEVICES_REL)
    return list(dict.fromkeys(candidates))


def load_devices_module() -> types.ModuleType:
    """Imports devices.py for its host-signed ``_http(method, path, body, timeout)`` client."""
    candidates = _devices_candidates()
    for candidate in candidates:
        if not candidate.is_file():
            continue
        resolved = candidate.resolve()
        if resolved in _loaded_devices:
            return _loaded_devices[resolved]
        spec = importlib.util.spec_from_file_location("jarviscopilot_devices_skill", resolved)
        if spec is None or spec.loader is None:
            continue
        module = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(module)
        except Exception as exc:
            raise WidgetsError(f"could not load {resolved}: {exc}") from exc
        if not callable(getattr(module, "_http", None)):
            raise WidgetsError(f"{resolved} has no _http client; update the devices skill")
        _loaded_devices[resolved] = module
        return module
    raise WidgetsError(
        "could not find the devices skill's devices.py (looked in: "
        + ", ".join(str(path) for path in candidates)
        + "). Install the jarviscopilot/devices skill or set JARVISCOPILOT_DIR to the JarvisCopilot checkout."
    )


def _failure(status: int, data: Any) -> str:
    """The most useful error text from a failed web UI reply."""
    text = str(data.get("error") or data.get("detail") or "") if isinstance(data, dict) else ""
    if status < 0:
        return "could not reach the Jarvis web UI" + (f": {text}" if text else "")
    return text or f"HTTP {status}"


# ── client ───────────────────────────────────────────────────────────────────

class Widgets:
    """The widget designs store, plus the phone refresh. ``transport`` stands in for devices._http."""

    def __init__(self, transport: Transport | None = None) -> None:
        self._transport = transport

    def _request(self, method: str, path: str, body: dict[str, Any] | None = None,
                 timeout: float = HTTP_TIMEOUT) -> tuple[int, Any]:
        if self._transport is None:
            self._transport = load_devices_module()._http
        return self._transport(method, path, body, timeout)

    def _call(self, method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        status, data = self._request(method, path, body)
        if not 200 <= status < 300 or not isinstance(data, dict) or data.get("ok") is False:
            errors = data.get("errors") if isinstance(data, dict) else None
            raise WidgetsError(_failure(status, data), errors if isinstance(errors, list) else None)
        return data

    def list(self) -> dict[str, Any]:
        data = self._call("GET", "/api/widgets/designs")
        designs = [{"id": d.get("id"), "name": d.get("name"), "version": d.get("version"),
                    "icon": d.get("icon"), "sizes": list(d.get("presentations") or {}),
                    "builder": d.get("builder") is not None}
                   for d in data.get("designs") or [] if isinstance(d, dict)]
        return {"designs": designs, "catalog_keys": len(data.get("catalog") or [])}

    def show(self, design_id: str) -> dict[str, Any]:
        return self._call("GET", f"/api/widgets/designs/{_checked_id(design_id)}")["design"]

    def catalog(self) -> dict[str, Any]:
        entries = self._call("GET", "/api/widgets/catalog").get("catalog") or []
        if entries:
            return {"catalog": entries}
        return {"catalog": [], "note": "The phone hasn't posted its data catalog yet; it does when "
                                       "Jarvis opens. Keys still work once the phone publishes them."}

    def upsert(self, design: dict[str, Any]) -> dict[str, Any]:
        data = self._call("POST", "/api/widgets/designs", design)
        saved = data.get("design") or {}
        return {"ok": True, "id": saved.get("id"), "name": saved.get("name"),
                "version": saved.get("version"), "sizes": list(saved.get("presentations") or {}),
                "warnings": data.get("warnings") or []}

    def delete(self, design_id: str) -> dict[str, Any]:
        self._call("DELETE", f"/api/widgets/designs/{_checked_id(design_id)}")
        return {"ok": True, "id": design_id}

    def refresh_phones(self) -> str:
        """Asks each phone offering widgets_refresh to pull the designs now; returns a note."""
        later = "it picks the change up the next time Jarvis opens."
        try:
            status, data = self._request("GET", "/api/devices/skills")
        except Exception as exc:  # best effort: never fail the save over the phone
            return f"Couldn't ask the phone to refresh ({exc}); {later}"
        if not 200 <= status < 300 or not isinstance(data, dict):
            return f"Couldn't list the phone's skills ({_failure(status, data)}); {later}"
        phones: dict[str, str] = {}
        for row in data.get("skills") or []:
            if isinstance(row, dict) and row.get("name") == REFRESH_SKILL and row.get("device_id"):
                phones.setdefault(str(row["device_id"]), str(row.get("device_name") or row["device_id"]))
        if not phones:
            return f"No phone offers {REFRESH_SKILL} right now; {later}"
        refreshed, failed = [], []
        for device_id, name in phones.items():
            body = {"device_id": device_id, "skill": REFRESH_SKILL, "args": {}, "timeout": REFRESH_TIMEOUT}
            try:
                status, reply = self._request("POST", "/api/devices/skills/invoke", body,
                                              REFRESH_TIMEOUT + HTTP_GRACE)
            except Exception as exc:
                failed.append(f"{name} ({exc})")
                continue
            result = reply.get("result") if isinstance(reply, dict) else None
            if (200 <= status < 300 and isinstance(reply, dict) and reply.get("ok") is not False
                    and not (isinstance(result, dict) and result.get("ok") is False)):
                refreshed.append(name)
            else:
                failed.append(f"{name} ({_failure(status, result if isinstance(result, dict) else reply)})")
        notes = []
        if refreshed:
            notes.append("Refreshed widgets on " + ", ".join(refreshed) + ".")
        if failed:
            notes.append("Couldn't reach " + ", ".join(failed) + f"; {later}")
        return " ".join(notes)


def _checked_id(design_id: str) -> str:
    if not _ID_RE.match(design_id or ""):
        raise WidgetsError(f"{design_id!r} is not a design id (lowercase a-z, 0-9, - and _)")
    return design_id


def _read_design(source: str) -> dict[str, Any]:
    """The design JSON object from a file path, or stdin for ``-``."""
    if source == "-":
        raw = sys.stdin.read()
    else:
        try:
            raw = Path(source).expanduser().read_text(encoding="utf-8")
        except OSError as exc:
            raise WidgetsError(f"could not read {source}: {exc}") from exc
    try:
        design = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise WidgetsError(f"input isn't valid JSON: {exc}") from exc
    if not isinstance(design, dict):
        raise WidgetsError("input must be a JSON object (one design)")
    return design


# ── CLI ──────────────────────────────────────────────────────────────────────

class _Parser(argparse.ArgumentParser):
    """Usage errors keep the CLI contract: ``{"error": ...}`` on stderr and exit code 1."""

    def error(self, message: str) -> NoReturn:
        print(json.dumps({"error": f"{self.prog}: {message}"}), file=sys.stderr)
        sys.exit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(prog="widgets.py", description="Jarvis Home Screen and Lock Screen widget designs. "
                                                    "Prints JSON.")
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    sub.add_parser("list", help="every design: id, name, version, sizes")
    p = sub.add_parser("show", help="one design's full JSON")
    p.add_argument("id")
    sub.add_parser("catalog", help="the data keys the phone publishes")
    p = sub.add_parser("upsert", help="create or replace a design from a JSON file, or - for stdin")
    p.add_argument("source", metavar="FILE|-")
    p.add_argument("--no-refresh", action="store_true", help="don't ask the phone to pull it now")
    p = sub.add_parser("delete", help="delete a design")
    p.add_argument("id")
    p.add_argument("--no-refresh", action="store_true", help="don't ask the phone to pull it now")
    return parser


def _run(client: Widgets, args: argparse.Namespace) -> dict[str, Any]:
    if args.command == "list":
        return client.list()
    if args.command == "show":
        return client.show(args.id)
    if args.command == "catalog":
        return client.catalog()
    if args.command == "upsert":
        result = client.upsert(_read_design(args.source))
    elif args.command == "delete":
        result = client.delete(args.id)
    else:
        raise WidgetsError(f"unknown command {args.command!r}")
    if not args.no_refresh:
        result["phone"] = client.refresh_phones()
    return result


def main(argv: list[str] | None = None, transport: Transport | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = _run(Widgets(transport), args)
    except WidgetsError as exc:
        error: dict[str, Any] = {"error": str(exc)}
        if exc.errors:
            error["errors"] = exc.errors
        print(json.dumps(error, ensure_ascii=False), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
