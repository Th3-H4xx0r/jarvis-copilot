"""Service pills (Stripe, GitHub, Vercel, Resend, Cal.com, n8n, Notion) and the
crypto watchlist / portfolio, polled on the server for the Mac notch app and the
iPhone. Keys stay on the server; clients only see snapshots and details.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations


def default_services() -> list:
    """Every polled service: the pills in the order the clients show them, then the
    crypto watchlist and the portfolio (published on their own topic)."""
    from jarvis_services.calcom import CalcomService
    from jarvis_services.crypto import CryptoService
    from jarvis_services.github import GitHubService
    from jarvis_services.n8n import N8nService
    from jarvis_services.notion import NotionService
    from jarvis_services.portfolio import PortfolioService
    from jarvis_services.resend import ResendService
    from jarvis_services.stripe import StripeService
    from jarvis_services.vercel import VercelService
    return [GitHubService(), StripeService(), VercelService(), ResendService(), CalcomService(),
            N8nService(), NotionService(), CryptoService(), PortfolioService()]
