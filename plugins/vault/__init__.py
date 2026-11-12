"""Secure Vault — bundled, auto-loaded.

The vault itself runs in the webui (``service.VaultService``; routes in ``webui/api/vault_routes.py``):
AES-256-GCM at rest under a server-held master key, opened on the iPhone with Face ID or the vault
passcode. These tools are Jarvis's only way in, and every call waits for a Face ID approval of that
exact action (the car's Secure Enclave key, ``jarvis-vault`` messages).
"""
from __future__ import annotations

from plugins.vault.tools import TOOLS, available


def register(ctx) -> None:
    for name, schema, handler, emoji in TOOLS:
        ctx.register_tool(name=name, toolset="vault", schema=schema, handler=handler,
                          check_fn=available, emoji=emoji)
