"""The Secure Vault: encrypted notes, photos and links, opened with Face ID.

Protected. Off: the vault_* tools and /api/vault refuse (a waiting approval can
still be answered), and the phone hides Settings → Privacy → Secure vault and the
share extension says the vault is off. Nothing in it is touched.
"""
from __future__ import annotations

from jarvis_power import Link, PowerIntegration


class Vault(PowerIntegration):
    id = "vault"
    name = "Vault"
    icon = "lock.square.stack.fill"
    summary = "Encrypted notes, photos and links that open with Face ID."
    protected = True
    toolsets = ("vault",)
    route_prefixes = ("/api/vault",)
    route_exempt = ("/api/vault/approvals",)
    surfaces = ("ios.settings.vault", "ios.share.vault")
    links = (Link("ios", "vault", "Open the vault"),)
