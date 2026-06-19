#!/usr/bin/env python3
"""JarvisCopilot — dynamic-island skill helper.

Stdlib-only. Talks to the running webui's REST API on localhost using a
host signing-key carve-out (identical to devices.py), so the agent can
create / manage Dynamic Island Designs without any cookies.

Designs are declarative layout trees (see ../SKILL.md for the schema).
This helper only carries JSON to/from the ``/api/island`` endpoints — it
does NOT validate the design itself (the server validator is the source
of truth and returns clear errors on a bad tree).

Usage examples (the SKILL.md has the full list):

    python3 island.py list
    python3 island.py create --file deploy.json
    python3 island.py create --json '{"schema":1,"id":"x",...}'
    python3 island.py update --file deploy.json          # same upsert
    python3 island.py delete deploy-status
    python3 island.py set-data deploy-status --json '{"pct":42,"phase":"build"}'
    python3 island.py pin deploy-status
    python3 island.py auto
    python3 island.py rules deploy-status --enabled true --priority 50 \
        --when '{"op":"gt","a":{"src":"battery.level"},"b":20}'

Exit codes:
    0   success
    1   error (printed to stderr as JSON)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path


# ── State paths ─────────────────────────────────────────────────────────────

def _state_dir() -> Path:
    """Resolve the webui's STATE_DIR (matches webui/api/config.py)."""
    env = os.environ.get("HERMES_WEBUI_STATE_DIR")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.home() / ".jarviscopilot" / "webui").resolve()


def _webui_origin() -> str:
    """Best-effort guess of the webui's local URL. Honors env overrides."""
    scheme = "https" if os.environ.get("HERMES_WEBUI_TLS_CERT") else "http"
    port = os.environ.get("HERMES_WEBUI_PORT", "8787")
    host = os.environ.get("HERMES_WEBUI_HOST", "127.0.0.1")
    return f"{scheme}://{host}:{port}"


# ── HTTP helpers ───────────────────────────────────────────────────────────

def _host_signature(method: str, path: str) -> str | None:
    """Build the X-JC-Host-Sig header value (`<ts>.<hmac>`).

    Matches webui/api/auth.py:_check_host_signature(). Returns None if
    the signing key isn't readable (in which case the call will get a 401
    and we surface the error JSON).
    """
    sk_path = _state_dir() / ".signing_key"
    try:
        import hmac as _hmac, hashlib as _hashlib
        sk = sk_path.read_bytes()
        ts = int(time.time())
        msg = f"{method.upper()}\n{path}\n{ts}".encode("utf-8")
        sig = _hmac.new(sk, msg, _hashlib.sha256).hexdigest()
        return f"{ts}.{sig}"
    except Exception:
        return None


def _http(method: str, path: str, body: dict | None = None,
          timeout: float = 30.0) -> tuple[int, dict]:
    """Make a host-signed request to the local webui. Returns (status, json|{})."""
    url = _webui_origin() + path
    data = None
    headers = {"Accept": "application/json", "X-Requested-With": "fetch"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    sig = _host_signature(method, path)
    if sig:
        headers["X-JC-Host-Sig"] = sig
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        ctx = None
        if url.startswith("https://"):
            import ssl
            ctx = ssl._create_unverified_context()
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            raw = r.read().decode("utf-8", errors="replace") or "{}"
            try:
                return r.status, json.loads(raw)
            except Exception:
                return r.status, {"raw": raw}
    except urllib.error.HTTPError as e:
        try:
            raw = e.read().decode("utf-8", errors="replace") or "{}"
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {}
    except Exception as e:
        return -1, {"error": str(e)}


def _fail(msg: str, **extra) -> int:
    """Print a JSON error object to stderr and return exit code 1."""
    print(json.dumps({"error": msg, **extra}), file=sys.stderr)
    return 1


def _ok(status: int, data: dict, *, on_ok=None) -> int:
    """Print the response JSON; success iff 2xx (and `ok` not explicitly false)."""
    success = 200 <= status < 300 and data.get("ok") is not False
    payload = on_ok(data) if (success and on_ok) else data
    if success:
        print(json.dumps(payload, indent=2))
        return 0
    return _fail(f"webui returned {status}", detail=data)


def _load_design(args) -> tuple[dict | None, str | None]:
    """Read a design/object from --json or --file. Returns (obj, error)."""
    raw = None
    if getattr(args, "json", None):
        raw = args.json
    elif getattr(args, "file", None):
        try:
            raw = Path(args.file).expanduser().read_text(encoding="utf-8")
        except Exception as e:
            return None, f"could not read --file {args.file!r}: {e}"
    else:
        return None, "provide one of --json or --file"
    try:
        obj = json.loads(raw)
    except Exception as e:
        return None, f"input isn't valid JSON: {e}"
    if not isinstance(obj, dict):
        return None, "input must be a JSON object"
    return obj, None


# ── Commands ───────────────────────────────────────────────────────────────

def cmd_list(args) -> int:
    """GET /api/island/designs -> {designs, catalog, selection}."""
    status, data = _http("GET", "/api/island/designs")
    return _ok(status, data)


def cmd_create(args) -> int:
    """POST /api/island/designs {design} -> {ok, id}. Upsert by id."""
    obj, err = _load_design(args)
    if err:
        return _fail(err)
    status, data = _http("POST", "/api/island/designs", body=obj)
    return _ok(status, data)


def cmd_delete(args) -> int:
    """DELETE /api/island/designs/<id> -> {ok}. Custom designs only."""
    status, data = _http("DELETE", f"/api/island/designs/{args.id}")
    return _ok(status, data, on_ok=lambda d: {"ok": True, "id": args.id, **d})


def cmd_set_data(args) -> int:
    """POST /api/island/designs/<id>/data {data} -> {ok}. Sets jarvis.* values + pushes."""
    obj, err = _load_design(args)
    if err:
        return _fail(err)
    status, data = _http("POST", f"/api/island/designs/{args.id}/data", body=obj)
    return _ok(status, data, on_ok=lambda d: {"ok": True, "id": args.id, **d})


def cmd_pin(args) -> int:
    """POST /api/island/selection {mode:'pinned', pinnedId:<id>} -> {ok}."""
    status, data = _http("POST", "/api/island/selection",
                         body={"mode": "pinned", "pinnedId": args.id})
    return _ok(status, data, on_ok=lambda d: {"ok": True, "mode": "pinned",
                                              "pinnedId": args.id, **d})


def cmd_auto(args) -> int:
    """POST /api/island/selection {mode:'auto'} -> {ok}."""
    status, data = _http("POST", "/api/island/selection", body={"mode": "auto"})
    return _ok(status, data, on_ok=lambda d: {"ok": True, "mode": "auto", **d})


def cmd_rules(args) -> int:
    """POST /api/island/designs/<id>/rules {enabled?,priority?,conditions?,schedule?} -> {ok}."""
    body: dict = {}
    if args.enabled is not None:
        body["enabled"] = (str(args.enabled).strip().lower()
                           in ("1", "true", "yes", "on"))
    if args.priority is not None:
        body["priority"] = args.priority
    if args.when is not None:
        try:
            body["conditions"] = json.loads(args.when)
        except Exception as e:
            return _fail(f"--when isn't valid JSON: {e}")
    if args.schedule is not None:
        try:
            body["schedule"] = json.loads(args.schedule)
        except Exception as e:
            return _fail(f"--schedule isn't valid JSON: {e}")
    if not body:
        return _fail("provide at least one of --enabled / --priority / --when / --schedule")
    status, data = _http("POST", f"/api/island/designs/{args.id}/rules", body=body)
    return _ok(status, data, on_ok=lambda d: {"ok": True, "id": args.id, **body, **d})


# ── CLI ─────────────────────────────────────────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(
        prog="island",
        description="JarvisCopilot Dynamic Island Designs management",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="List designs + catalog + selection").set_defaults(func=cmd_list)

    def _add_design_input(sp):
        g = sp.add_mutually_exclusive_group(required=True)
        g.add_argument("--json", help="Inline JSON object")
        g.add_argument("--file", help="Path to a JSON file")

    sp = sub.add_parser("create", help="Create/upsert a design (validated server-side)")
    _add_design_input(sp)
    sp.set_defaults(func=cmd_create)

    sp = sub.add_parser("update", help="Update a design (same upsert as create)")
    _add_design_input(sp)
    sp.set_defaults(func=cmd_create)

    sp = sub.add_parser("delete", help="Delete a custom design by id")
    sp.add_argument("id", help="Design id")
    sp.set_defaults(func=cmd_delete)

    sp = sub.add_parser("set-data", help="Push latest jarvis.* data values for a design")
    sp.add_argument("id", help="Design id")
    g = sp.add_mutually_exclusive_group(required=True)
    g.add_argument("--json", help="Inline JSON object of data values")
    g.add_argument("--file", help="Path to a JSON file of data values")
    sp.set_defaults(func=cmd_set_data)

    sp = sub.add_parser("pin", help="Pin a design as the active island")
    sp.add_argument("id", help="Design id to pin")
    sp.set_defaults(func=cmd_pin)

    sub.add_parser("auto", help="Switch selection to Auto (rules-driven)").set_defaults(func=cmd_auto)

    sp = sub.add_parser("rules", help="Update auto-selection rules for a design")
    sp.add_argument("id", help="Design id")
    sp.add_argument("--enabled", default=None,
                    help="true/false — include this design in the auto pool")
    sp.add_argument("--priority", type=int, default=None,
                    help="Integer priority (higher wins in auto mode)")
    sp.add_argument("--when", default=None,
                    help="Condition expression as JSON (see SKILL.md)")
    sp.add_argument("--schedule", default=None,
                    help='Schedule as JSON, e.g. {"days":[1,2,3,4,5],"from":"09:00","to":"18:00"}')
    sp.set_defaults(func=cmd_rules)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
