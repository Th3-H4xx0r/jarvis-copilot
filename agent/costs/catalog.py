"""Every service Jarvis can run up a bill on, and how each one's cost is found.

A service is one of three kinds:

- ``usage``: pay as you go. Priced from the provider's billing API when one is connected
  (``billing``) and always from Jarvis's own counts (``estimate``).
- ``subscription``: a flat plan. Its price is entered once and spread over the days.
  The tokens it covers are still counted, so the detail can show what the same work
  would have cost on the pay-as-you-go API.
- ``free``: listed so the picture is complete, never priced.

``providers`` ties a service to the ``message_usage.provider`` values its LLM calls are
logged under. ``fields`` is the connect form (``env`` = where a secret is saved; a saved
secret is never sent back to a client; ``billing_only`` = only this page uses it, so
Disconnect may delete it). Prices checked on the providers' pricing pages
on 2026-10-31.
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional

# Per-unit prices for the local meter (USD).
PARALLEL_PER_SEARCH = {"turbo": 0.001, "fast": 0.001, "basic": 0.005, "advanced": 0.005,
                       "one-shot": 0.005, "agentic": 0.005}
SONIOX_PER_HOUR = 0.12          # realtime
FISH_PER_MILLION_BYTES = 15.0   # s2 / s2.1-pro

SERVICES: List[Dict[str, Any]] = [
    {
        "id": "anthropic",
        "name": "Anthropic API",
        "category": "AI models",
        "kind": "usage",
        "providers": ["anthropic-api", "anthropic"],
        "detect_env": ["ANTHROPIC_API_KEY"],
        "url": "https://platform.claude.com/settings/billing",
        "help": ("Jarvis prices every Claude call it makes from the official price list. "
                 "Add an Admin key (sk-ant-admin…, Console → Settings → Admin keys) to read "
                 "Anthropic's own daily cost report too. Admin keys need an organization account."),
        "fields": [
            {"key": "admin_key", "label": "Admin API key", "kind": "secret",
             "env": "ANTHROPIC_ADMIN_KEY", "billing_only": True, "placeholder": "sk-ant-admin01-…"},
        ],
    },
    {
        "id": "openrouter",
        "name": "OpenRouter",
        "category": "AI models",
        "kind": "usage",
        "providers": ["openrouter"],
        "detect_env": ["OPENROUTER_API_KEY"],
        "url": "https://openrouter.ai/settings/credits",
        "help": ("Your OpenRouter key reports today's and this month's spend. A management key "
                 "adds your credit balance and 30 days of daily history."),
        "fields": [
            {"key": "management_key", "label": "Management key", "kind": "secret",
             "env": "OPENROUTER_MANAGEMENT_KEY", "billing_only": True, "placeholder": "sk-or-v1-…"},
        ],
    },
    {
        "id": "celeris",
        "name": "Celeris",
        "category": "AI models",
        "kind": "usage",
        "providers": ["celeris"],
        "detect_env": ["CELERIS_API_KEY"],
        "url": "https://console.celeris.ai",
        "help": ("Celeris has no billing API, so this is priced from Jarvis's own call log. "
                 "Router decisions aren't logged per call, so they aren't included."),
        "fields": [],
    },
    {
        "id": "ollama-cloud",
        "name": "Ollama Cloud",
        "category": "AI models",
        "kind": "subscription",
        "providers": ["ollama-cloud", "ollama"],
        "detect_env": ["OLLAMA_API_KEY"],
        "url": "https://ollama.com/settings",
        "help": ("Your plan price is what you pay. Ollama also reports how much of the plan's "
                 "included usage is gone and any extra credit you bought."),
        "suggested_plans": [{"label": "Pro", "amount_usd": 20, "interval": "month"},
                            {"label": "Max", "amount_usd": 100, "interval": "month"}],
        "fields": [],
    },
    {
        "id": "openai-codex",
        "name": "ChatGPT / Codex",
        "category": "AI models",
        "kind": "subscription",
        "providers": ["openai-codex"],
        "url": "https://chatgpt.com/#settings/Subscription",
        "help": "Calls through your ChatGPT plan are covered by the plan price.",
        "suggested_plans": [{"label": "Plus", "amount_usd": 20, "interval": "month"},
                            {"label": "Pro", "amount_usd": 200, "interval": "month"}],
        "fields": [],
    },
    {
        "id": "claude-code",
        "name": "Claude subscription",
        "category": "AI models",
        "kind": "subscription",
        "providers": ["claude-code"],
        "detect_env": ["ANTHROPIC_TOKEN"],
        "url": "https://claude.ai/settings/billing",
        "help": "Claude Code calls are covered by your Claude plan.",
        "suggested_plans": [{"label": "Pro", "amount_usd": 20, "interval": "month"},
                            {"label": "Max 5×", "amount_usd": 100, "interval": "month"},
                            {"label": "Max 20×", "amount_usd": 200, "interval": "month"}],
        "fields": [],
    },
    {
        "id": "nvidia",
        "name": "NVIDIA API",
        "category": "AI models",
        "kind": "free",
        "providers": ["nvidia"],
        "detect_env": ["NVIDIA_API_KEY"],
        "url": "https://build.nvidia.com",
        "help": "NVIDIA's API catalog is free for trial use (rate-limited). Calls are still counted.",
        "fields": [],
    },
    {
        "id": "parallel",
        "name": "Parallel",
        "category": "Web search",
        "kind": "usage",
        "detect_env": ["PARALLEL_API_KEY"],
        "url": "https://platform.parallel.ai",
        "help": ("Parallel has no usage API for API keys, so every search Jarvis runs is "
                 "counted and priced ($1 per 1,000 in fast mode). Parallel's $5 of free monthly "
                 "credit isn't subtracted."),
        "fields": [],
    },
    {
        "id": "soniox",
        "name": "Soniox",
        "category": "Speech",
        "kind": "usage",
        "detect_env": ["SONIOX_API_KEY"],
        "url": "https://console.soniox.com",
        "help": ("Jarvis counts the audio it streams to Soniox ($0.12 an hour). Add an "
                 "organization API key (snx_org_…, Console → Settings → Organization API keys) "
                 "for Soniox's own daily cost and your balance."),
        "fields": [
            {"key": "org_key", "label": "Organization API key", "kind": "secret",
             "env": "SONIOX_ORG_API_KEY", "billing_only": True, "placeholder": "snx_org_…"},
        ],
    },
    {
        "id": "fish-audio",
        "name": "Fish Audio",
        "category": "Speech",
        "kind": "usage",
        "detect_config": "tts.fish-audio.api_key",
        "detect_env": ["FISH_AUDIO_API_KEY", "FISH_API_KEY"],
        "url": "https://fish.audio/app/api-keys/",
        "help": ("Jarvis counts the text it sends for speech ($15 per million bytes) and reads "
                 "your API credit balance, so a drop in the balance shows up as that day's spend."),
        "fields": [],
    },
    {
        "id": "photon",
        "name": "Photon",
        "category": "Messaging",
        "kind": "subscription",
        "detect_env": ["PHOTON_PROJECT_ID"],
        "url": "https://photon.codes/dashboard",
        "help": "Photon bills a flat plan for iMessage. Enter what you pay.",
        "suggested_plans": [{"label": "Free", "amount_usd": 0, "interval": "month"},
                            {"label": "Pro", "amount_usd": 25, "interval": "month"}],
        "fields": [],
    },
    {
        "id": "server",
        "name": "Server hosting",
        "category": "Hosting",
        "kind": "subscription",
        "always": True,
        "help": "What the machine Jarvis runs on costs you.",
        "fields": [],
    },
    {
        "id": "openai",
        "name": "OpenAI API",
        "category": "AI models",
        "kind": "usage",
        "providers": ["openai"],
        "detect_env": ["OPENAI_ADMIN_KEY"],
        "url": "https://platform.openai.com/usage",
        "help": "An OpenAI Admin key reads your organization's daily costs.",
        "fields": [
            {"key": "admin_key", "label": "Admin API key", "kind": "secret",
             "env": "OPENAI_ADMIN_KEY", "billing_only": True, "placeholder": "sk-admin-…"},
        ],
    },
    {
        "id": "elevenlabs",
        "name": "ElevenLabs",
        "category": "Speech",
        "kind": "subscription",
        "detect_env": ["ELEVENLABS_API_KEY"],
        "url": "https://elevenlabs.io/app/subscription",
        "help": "Reads how much of your plan's credits are used this period.",
        "fields": [
            {"key": "api_key", "label": "API key", "kind": "secret", "env": "ELEVENLABS_API_KEY",
             "placeholder": "sk_…"},
        ],
    },
    {
        "id": "browserbase",
        "name": "Browserbase",
        "category": "Browser",
        "kind": "subscription",
        "detect_env": ["BROWSERBASE_API_KEY"],
        "url": "https://www.browserbase.com/settings",
        "help": "Reads browser minutes and proxy data used.",
        "suggested_plans": [{"label": "Developer", "amount_usd": 20, "interval": "month"},
                            {"label": "Startup", "amount_usd": 99, "interval": "month"}],
        "fields": [
            {"key": "api_key", "label": "API key", "kind": "secret", "env": "BROWSERBASE_API_KEY",
             "placeholder": "bb_live_…"},
            {"key": "project_id", "label": "Project ID", "kind": "text",
             "env": "BROWSERBASE_PROJECT_ID", "placeholder": "Project ID"},
        ],
    },
    # Free services — listed so "everything Jarvis uses" really is everything.
    {"id": "telegram", "name": "Telegram", "category": "Messaging", "kind": "free",
     "detect_env": ["TELEGRAM_BOT_TOKEN"], "help": "The Telegram Bot API is free.", "fields": []},
    {"id": "home-assistant", "name": "Home Assistant", "category": "Smart home", "kind": "free",
     "detect_env": ["HASS_TOKEN"], "help": "Your own Home Assistant has no usage charges.",
     "fields": []},
    {"id": "notion", "name": "Notion", "category": "Productivity", "kind": "free",
     "detect_env": ["NOTION_API_KEY", "NOTION_API_TOKEN"],
     "help": "The Notion API has no usage charges.", "fields": []},
    {"id": "tuya", "name": "Tuya / Smart Life", "category": "Smart home", "kind": "free",
     "detect_env": ["TUYA_ACCESS_ID"], "help": "Tuya's cloud trial is free.", "fields": []},
    {"id": "spotify", "name": "Spotify", "category": "Media", "kind": "free",
     "detect_env": ["HERMES_SPOTIFY_CLIENT_ID"], "help": "The Spotify Web API is free.",
     "fields": []},
]

_BY_ID = {s["id"]: s for s in SERVICES}

# Names for LLM providers that show up in the call log but aren't in the catalog.
_PROVIDER_NAMES = {
    "gemini": "Google Gemini", "google": "Google Gemini", "deepseek": "DeepSeek",
    "xai": "xAI", "mistral": "Mistral", "groq": "Groq", "together": "Together AI",
    "minimax": "MiniMax", "moonshot": "Moonshot", "zai": "Z.ai", "nous": "Nous Portal",
}


def get(service_id: str) -> Optional[Dict[str, Any]]:
    return _BY_ID.get(service_id)


def service_for_provider(provider: Optional[str]) -> str:
    """The catalog id a ``message_usage.provider`` belongs to (unknown → the provider itself)."""
    p = (provider or "").strip().lower()
    for s in SERVICES:
        if p in s.get("providers", []):
            return s["id"]
    return p or "unknown"


def adhoc_service(service_id: str, config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """An entry for a service that isn't in the catalog: a subscription the user added,
    or an LLM provider seen only in the call log."""
    cfg = config or {}
    if cfg.get("custom"):
        return {"id": service_id, "name": cfg.get("name") or service_id,
                "category": cfg.get("category") or "Other", "kind": "subscription",
                "custom": True, "help": "A subscription you added.", "fields": []}
    return {"id": service_id, "name": _PROVIDER_NAMES.get(service_id, service_id.title()),
            "category": "AI models", "kind": "usage", "providers": [service_id],
            "help": "Priced from Jarvis's call log at the provider's list price.", "fields": []}


def public_fields(service: Dict[str, Any]) -> List[Dict[str, Any]]:
    """The connect form as a client sees it (labels and kinds only)."""
    return [{"billing_only": bool(f.get("billing_only")),
             **{k: f[k] for k in ("key", "label", "kind", "placeholder") if k in f}}
            for f in service.get("fields", [])]
