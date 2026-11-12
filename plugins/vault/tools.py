"""vault_search / vault_list / vault_read / vault_save / vault_move / vault_delete — Jarvis's side of
Pranav's Secure Vault.

None of these touch the vault. Each asks the webui for a Face ID approval for that exact action
(host-signed loopback); the webui keeps the arguments, pushes "Jarvis wants to use your vault" to his
iPhone and, once he approves with Face ID, runs the action once. The tool waits for that (up to the
approval's two minutes) and returns the result. Nothing here writes results anywhere else.
"""
from __future__ import annotations

import json
import time
from typing import Any, Callable

WAIT_S = 130.0        # a bit past the approval's 2-minute life
POLL_S = 1.5

_PHONE = ("Every call needs Pranav's Face ID on his iPhone: the tool sends the request and waits up to "
          "2 minutes for him to approve it. Tell him to check his phone if he isn't looking at it. "
          "Never repeat a call he denied. Vault contents are private: don't quote them beyond what he "
          "asked for, and never save them to memory, notes or files.")

SEARCH_SCHEMA = {
    "name": "vault_search",
    "description": "Search Pranav's Secure Vault (titles, note text, link titles/sites, filenames). " + _PHONE,
    "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]},
}
LIST_SCHEMA = {
    "name": "vault_list",
    "description": ("List a folder of Pranav's Secure Vault: its subfolders and items, newest first. folder is a "
                    "name or path like \"Travel/Japan 2026\" (case-insensitive) or an id; omit it for the top. "
                    + _PHONE),
    "parameters": {"type": "object", "properties": {"folder": {"type": "string"}}},
}
READ_SCHEMA = {
    "name": "vault_read",
    "description": ("Read one vault item by id (from vault_search / vault_list): a note's text, a link's URL, "
                    "preview and his note, a PDF's text when available; for photos, videos and other files, "
                    "details only. " + _PHONE),
    "parameters": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]},
}
SAVE_SCHEMA = {
    "name": "vault_save",
    "description": ("Save something to Pranav's Secure Vault. kind=note (title and/or body), link (url, optional "
                    "title, body = his note about it) or file (path = a chat attachment's file path on the "
                    "server). folder is a name or path (created if missing); omit it for the top. " + _PHONE),
    "parameters": {
        "type": "object",
        "properties": {
            "kind": {"type": "string", "enum": ["note", "link", "file"]},
            "folder": {"type": "string"},
            "title": {"type": "string"},
            "body": {"type": "string"},
            "url": {"type": "string"},
            "path": {"type": "string"},
        },
        "required": ["kind"],
    },
}
MOVE_SCHEMA = {
    "name": "vault_move",
    "description": ("Move vault items or folders (ids from vault_search / vault_list) into a folder (name, path or "
                    "id; omit for the top). " + _PHONE),
    "parameters": {"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "string"}},
                                                    "folder": {"type": "string"}}, "required": ["ids"]},
}
DELETE_SCHEMA = {
    "name": "vault_delete",
    "description": ("Permanently delete vault items or folders (with everything inside) by id. There is no trash. "
                    + _PHONE),
    "parameters": {"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "string"}}},
                   "required": ["ids"]},
}


def available() -> bool:
    return True


def _api(method: str, path: str, body: dict | None = None, timeout: float = 15.0) -> dict:
    from tools.chrome_device_tool import _api_request

    return _api_request(method, path, body, timeout=timeout)


def ask_and_wait(command: str, args: dict, api: Callable[..., dict] | None = None,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
                 wait_s: float = WAIT_S) -> dict:
    api = api or _api
    answer = api("POST", "/api/vault/approvals", {"command": command, "args": args})
    if not isinstance(answer, dict) or answer.get("_error") or not answer.get("ok"):
        err = (answer or {}).get("_error") or (answer or {}).get("error") if isinstance(answer, dict) else None
        return {"error": err or "Couldn't send the vault approval to his iPhone."}
    approval_id = str((answer.get("approval") or {}).get("id") or "")
    deadline = clock() + wait_s
    while clock() < deadline:
        sleep(POLL_S)
        got = api("GET", f"/api/vault/approvals/{approval_id}/result")
        if not isinstance(got, dict) or got.get("_error"):
            continue
        status = got.get("status")
        if status == "pending":
            continue
        if status == "done":
            return {"ok": True, "result": got.get("result")}
        if status == "denied":
            return {"denied": True, "message": "Pranav declined this on his iPhone. Don't ask again unless he does."}
        if status == "error":
            return {"error": got.get("error") or "The vault action failed."}
        if status == "expired":
            break
    return {"expired": True, "message": "He didn't approve it on his iPhone within 2 minutes; nothing was done."}


def _handler(command: str, keys: tuple[str, ...]):
    def handle(args: dict, **_: Any) -> str:
        args = args if isinstance(args, dict) else {}
        return json.dumps(ask_and_wait(command, {k: args[k] for k in keys if k in args}), default=str)
    return handle


TOOLS = (
    ("vault_search", SEARCH_SCHEMA, _handler("search", ("query",)), "🔐"),
    ("vault_list", LIST_SCHEMA, _handler("list", ("folder",)), "🔐"),
    ("vault_read", READ_SCHEMA, _handler("read", ("id",)), "🔐"),
    ("vault_save", SAVE_SCHEMA, _handler("save", ("kind", "folder", "title", "body", "url", "path")), "🔐"),
    ("vault_move", MOVE_SCHEMA, _handler("move", ("ids", "folder")), "🔐"),
    ("vault_delete", DELETE_SCHEMA, _handler("delete", ("ids",)), "🔐"),
)
