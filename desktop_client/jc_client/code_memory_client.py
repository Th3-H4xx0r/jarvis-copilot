"""Client-side wrapper over the webui /api/code-memory endpoints, using the
paired pinned connection. Shared by the MCP server and the `code-memory` CLI."""
from __future__ import annotations

import os
import re
import subprocess
from urllib.parse import quote

from jc_client import credentials
from jc_client.protocol import HttpClient


class NotPaired(RuntimeError):
    pass


def _slugify(seg: str) -> str:
    s = seg.strip().lower().replace(" ", "-")
    return re.sub(r"[^a-z0-9._-]+", "_", s).strip("_.")


def slug_for(root: str, remote: str | None) -> str:
    if remote:
        r = re.sub(r"^[a-z]+://", "", remote.strip(), flags=re.I)
        r = re.sub(r"^[^@/]+@", "", r).replace(":", "/")
        r = re.sub(r"\.git$", "", r, flags=re.I)
        slug = _slugify("_".join(p for p in r.split("/") if p))
        if slug:
            return slug
    return _slugify(os.path.basename(os.path.normpath(root))) or "project"


def current_slug(root: str | None = None) -> str:
    root = root or os.getcwd()
    try:
        remote = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"],
                                capture_output=True, text=True, timeout=5).stdout.strip() or None
    except Exception:
        remote = None
    return slug_for(root, remote)


def _http() -> HttpClient:
    creds = credentials.load()
    if not creds.paired:
        raise NotPaired("not paired — run `jc-client pair`")
    return HttpClient(creds.server_url, cookie=creds.cookie, expected_fingerprint=creds.cert_fingerprint)


def register(slug, name, root, remote=""):
    return _http().request_json("POST", "/api/code-memory/register",
                                {"slug": slug, "name": name, "root": root, "remote": remote}).json()


def store(slug, kind, entry_type, content):
    return _http().request_json("POST", "/api/code-memory/write",
                                {"slug": slug, "kind": kind, "entry_type": entry_type, "content": content}).json()


def recall(slug, kind, limit=50):
    path = f"/api/code-memory?project={quote(slug)}&kind={quote(kind)}&limit={int(limit)}"
    return _http().request_json("GET", path).json().get("entries", [])


def projects():
    return _http().request_json("GET", "/api/code-memory/projects").json().get("projects", {})
