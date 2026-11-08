from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Dict, Literal, Optional

from agent.model_metadata import fetch_endpoint_model_metadata, fetch_model_metadata
from utils import base_url_host_matches

DEFAULT_PRICING = {"input": 0.0, "output": 0.0}

_ZERO = Decimal("0")
_ONE_MILLION = Decimal("1000000")

CostStatus = Literal["actual", "estimated", "included", "unknown"]
CostSource = Literal[
    "provider_cost_api",
    "provider_generation_api",
    "provider_models_api",
    "official_docs_snapshot",
    "user_override",
    "custom_contract",
    "none",
]


@dataclass(frozen=True)
class CanonicalUsage:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    reasoning_tokens: int = 0
    request_count: int = 1
    raw_usage: Optional[dict[str, Any]] = None

    @property
    def prompt_tokens(self) -> int:
        return self.input_tokens + self.cache_read_tokens + self.cache_write_tokens

    @property
    def total_tokens(self) -> int:
        return self.prompt_tokens + self.output_tokens


@dataclass(frozen=True)
class BillingRoute:
    provider: str
    model: str
    base_url: str = ""
    billing_mode: str = "unknown"


@dataclass(frozen=True)
class PricingEntry:
    input_cost_per_million: Optional[Decimal] = None
    output_cost_per_million: Optional[Decimal] = None
    cache_read_cost_per_million: Optional[Decimal] = None
    cache_write_cost_per_million: Optional[Decimal] = None
    request_cost: Optional[Decimal] = None
    source: CostSource = "none"
    source_url: Optional[str] = None
    pricing_version: Optional[str] = None
    fetched_at: Optional[datetime] = None


@dataclass(frozen=True)
class CostResult:
    amount_usd: Optional[Decimal]
    status: CostStatus
    source: CostSource
    label: str
    fetched_at: Optional[datetime] = None
    pricing_version: Optional[str] = None
    notes: tuple[str, ...] = ()


_UTC_NOW = lambda: datetime.now(timezone.utc)


_ANTHROPIC_PRICING_URL = "https://platform.claude.com/docs/en/about-claude/pricing"
_OPENAI_PRICING_URL = "https://openai.com/api/pricing/"
_CELERIS_PRICING_URL = "https://docs.celeris.ai/pricing"
_DEEPSEEK_PRICING_URL = "https://api-docs.deepseek.com/quick_start/pricing"
_GOOGLE_PRICING_URL = "https://ai.google.dev/pricing"
_BEDROCK_PRICING_URL = "https://aws.amazon.com/bedrock/pricing/"


def _docs_price(
    source_url: str,
    pricing_version: str,
    input_cost: str,
    output_cost: str,
    cache_read_cost: Optional[str] = None,
    cache_write_cost: Optional[str] = None,
) -> PricingEntry:
    """A per-million-token entry copied from a provider's published price list."""
    return PricingEntry(
        input_cost_per_million=Decimal(input_cost),
        output_cost_per_million=Decimal(output_cost),
        cache_read_cost_per_million=None if cache_read_cost is None else Decimal(cache_read_cost),
        cache_write_cost_per_million=None if cache_write_cost is None else Decimal(cache_write_cost),
        source="official_docs_snapshot",
        source_url=source_url,
        pricing_version=pricing_version,
    )


# Official docs snapshot entries. Models whose published pricing and cache
# semantics are stable enough to encode exactly.
_OFFICIAL_DOCS_PRICING: Dict[tuple[str, str], PricingEntry] = {
    # ── Anthropic Claude 5 family ────────────────────────────────────────
    # Cache writes here are the 5-minute rate (1.25× input); 1-hour writes cost
    # 2× input. Haiku 5.5 is priced for prompts up to 100K tokens.
    # Source: https://platform.claude.com/docs/en/about-claude/pricing (2026-10)
    ("anthropic", "claude-fable-5-1"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-10", "10.00", "50.00", "0.25", "12.50"),
    ("anthropic", "claude-fable-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-10", "10.00", "50.00", "1.00", "12.50"),
    ("anthropic", "claude-opus-5-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-10", "4.00", "20.00", "0.20", "5.00"),
    ("anthropic", "claude-opus-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-10", "5.00", "25.00", "0.50", "6.25"),
    ("anthropic", "claude-opus-4-8"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-10", "5.00", "25.00", "0.50", "6.25"),
    ("anthropic", "claude-sonnet-5-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-10", "2.00", "10.00", "0.20", "2.50"),
    ("anthropic", "claude-sonnet-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-10", "2.00", "10.00", "0.20", "2.50"),
    ("anthropic", "claude-haiku-5-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-10", "0.10", "0.50", "0.01", "0.125"),
    # ── Anthropic Claude 4.7 ─────────────────────────────────────────────
    # Opus 4.5/4.6/4.7 share $5/$25 pricing (new tokenizer, up to 35% more
    # tokens for the same text).
    # Source: https://platform.claude.com/docs/en/about-claude/pricing
    ("anthropic", "claude-opus-4-7"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "5.00", "25.00", "0.50", "6.25"),
    ("anthropic", "claude-opus-4-7-20250507"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "5.00", "25.00", "0.50", "6.25"),
    # ── Anthropic Claude 4.6 ─────────────────────────────────────────────
    ("anthropic", "claude-opus-4-6"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "5.00", "25.00", "0.50", "6.25"),
    ("anthropic", "claude-opus-4-6-20250414"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "5.00", "25.00", "0.50", "6.25"),
    ("anthropic", "claude-sonnet-4-6"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "3.00", "15.00", "0.30", "3.75"),
    ("anthropic", "claude-sonnet-4-6-20250414"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "3.00", "15.00", "0.30", "3.75"),
    # ── Anthropic Claude 4.5 ─────────────────────────────────────────────
    ("anthropic", "claude-opus-4-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "5.00", "25.00", "0.50", "6.25"),
    ("anthropic", "claude-sonnet-4-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "3.00", "15.00", "0.30", "3.75"),
    ("anthropic", "claude-haiku-4-5"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "1.00", "5.00", "0.10", "1.25"),
    # ── Anthropic Claude 4 / 4.1 ─────────────────────────────────────────
    ("anthropic", "claude-opus-4-20250514"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "15.00", "75.00", "1.50", "18.75"),
    ("anthropic", "claude-sonnet-4-20250514"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "3.00", "15.00", "0.30", "3.75"),
    # OpenAI
    ("openai", "gpt-4o"): _docs_price(_OPENAI_PRICING_URL, "openai-pricing-2026-03-16", "2.50", "10.00", "1.25"),
    ("openai", "gpt-4o-mini"): _docs_price(_OPENAI_PRICING_URL, "openai-pricing-2026-03-16", "0.15", "0.60", "0.075"),
    ("openai", "gpt-4.1"): _docs_price(_OPENAI_PRICING_URL, "openai-pricing-2026-03-16", "2.00", "8.00", "0.50"),
    ("openai", "gpt-4.1-mini"): _docs_price(_OPENAI_PRICING_URL, "openai-pricing-2026-03-16", "0.40", "1.60", "0.10"),
    ("openai", "gpt-4.1-nano"): _docs_price(_OPENAI_PRICING_URL, "openai-pricing-2026-03-16", "0.10", "0.40", "0.025"),
    ("openai", "o3"): _docs_price(_OPENAI_PRICING_URL, "openai-pricing-2026-03-16", "10.00", "40.00", "2.50"),
    ("openai", "o3-mini"): _docs_price(_OPENAI_PRICING_URL, "openai-pricing-2026-03-16", "1.10", "4.40", "0.55"),
    # ── Anthropic older models (pre-4.5 generation) ────────────────────────
    ("anthropic", "claude-3-5-sonnet-20241022"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "3.00", "15.00", "0.30", "3.75"),
    ("anthropic", "claude-3-5-haiku-20241022"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "0.80", "4.00", "0.08", "1.00"),
    ("anthropic", "claude-3-opus-20240229"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "15.00", "75.00", "1.50", "18.75"),
    ("anthropic", "claude-3-haiku-20240307"): _docs_price(_ANTHROPIC_PRICING_URL, "anthropic-pricing-2026-05", "0.25", "1.25", "0.03", "0.30"),
    # Celeris (https://docs.celeris.ai/pricing) — decision model output is free.
    ("celeris", "celeris-1"): _docs_price(_CELERIS_PRICING_URL, "celeris-pricing-2026-10-11", "0.20", "0.70", "0.02"),
    ("celeris", "celeris-1-magnus"): _docs_price(_CELERIS_PRICING_URL, "celeris-pricing-2026-10-11", "0.20", "0.70", "0.02"),
    ("celeris", "celeris-1-decision"): _docs_price(_CELERIS_PRICING_URL, "celeris-pricing-2026-10-11", "0.04", "0", "0.04"),
    # DeepSeek
    ("deepseek", "deepseek-chat"): _docs_price(_DEEPSEEK_PRICING_URL, "deepseek-pricing-2026-03-16", "0.14", "0.28"),
    ("deepseek", "deepseek-reasoner"): _docs_price(_DEEPSEEK_PRICING_URL, "deepseek-pricing-2026-03-16", "0.55", "2.19"),
    ("deepseek", "deepseek-v4-pro"): _docs_price(_DEEPSEEK_PRICING_URL, "deepseek-pricing-2026-05-12", "1.74", "3.48", "0.0145"),
    # Google Gemini
    ("google", "gemini-2.5-pro"): _docs_price(_GOOGLE_PRICING_URL, "google-pricing-2026-03-16", "1.25", "10.00"),
    ("google", "gemini-2.5-flash"): _docs_price(_GOOGLE_PRICING_URL, "google-pricing-2026-03-16", "0.15", "0.60"),
    ("google", "gemini-2.0-flash"): _docs_price(_GOOGLE_PRICING_URL, "google-pricing-2026-03-16", "0.10", "0.40"),
    # AWS Bedrock — pricing per the Bedrock pricing page.
    # Bedrock charges the same per-token rates as the model provider but
    # through AWS billing.  These are the on-demand prices (no commitment).
    # Source: https://aws.amazon.com/bedrock/pricing/
    ("bedrock", "anthropic.claude-opus-4-6"): _docs_price(_BEDROCK_PRICING_URL, "bedrock-pricing-2026-04", "15.00", "75.00"),
    ("bedrock", "anthropic.claude-sonnet-4-6"): _docs_price(_BEDROCK_PRICING_URL, "bedrock-pricing-2026-04", "3.00", "15.00"),
    ("bedrock", "anthropic.claude-sonnet-4-5"): _docs_price(_BEDROCK_PRICING_URL, "bedrock-pricing-2026-04", "3.00", "15.00"),
    ("bedrock", "anthropic.claude-haiku-4-5"): _docs_price(_BEDROCK_PRICING_URL, "bedrock-pricing-2026-04", "0.80", "4.00"),
    ("bedrock", "amazon.nova-pro"): _docs_price(_BEDROCK_PRICING_URL, "bedrock-pricing-2026-04", "0.80", "3.20"),
    ("bedrock", "amazon.nova-lite"): _docs_price(_BEDROCK_PRICING_URL, "bedrock-pricing-2026-04", "0.06", "0.24"),
    ("bedrock", "amazon.nova-micro"): _docs_price(_BEDROCK_PRICING_URL, "bedrock-pricing-2026-04", "0.035", "0.14"),
    # MiniMax
    ("minimax", "minimax-m2.7"): _docs_price(None, "minimax-pricing-2026-04", "0.30", "1.20"),
    ("minimax-cn", "minimax-m2.7"): _docs_price(None, "minimax-pricing-2026-04", "0.30", "1.20"),
}


def _to_decimal(value: Any) -> Optional[Decimal]:
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except Exception:
        return None


def _to_int(value: Any) -> int:
    try:
        return int(value or 0)
    except Exception:
        return 0


def resolve_billing_route(
    model_name: str,
    provider: Optional[str] = None,
    base_url: Optional[str] = None,
) -> BillingRoute:
    provider_name = (provider or "").strip().lower()
    base = (base_url or "").strip().lower()
    model = (model_name or "").strip()
    if not provider_name and "/" in model:
        inferred_provider, bare_model = model.split("/", 1)
        if inferred_provider in {"anthropic", "openai", "google"}:
            provider_name = inferred_provider
            model = bare_model

    if provider_name == "openai-codex":
        return BillingRoute(provider="openai-codex", model=model, base_url=base_url or "", billing_mode="subscription_included")
    if provider_name == "openrouter" or base_url_host_matches(base_url or "", "openrouter.ai"):
        return BillingRoute(provider="openrouter", model=model, base_url=base_url or "", billing_mode="official_models_api")
    if provider_name in {"anthropic", "anthropic-api"}:
        return BillingRoute(provider="anthropic", model=model.split("/")[-1], base_url=base_url or "", billing_mode="official_docs_snapshot")
    if provider_name == "openai":
        return BillingRoute(provider="openai", model=model.split("/")[-1], base_url=base_url or "", billing_mode="official_docs_snapshot")
    if provider_name in {"minimax", "minimax-cn"}:
        return BillingRoute(provider=provider_name, model=model.split("/")[-1], base_url=base_url or "", billing_mode="official_docs_snapshot")
    if provider_name == "celeris":
        return BillingRoute(provider="celeris", model=model.split("/")[-1], base_url=base_url or "", billing_mode="official_docs_snapshot")
    if provider_name in {"custom", "local"} or (base and "localhost" in base):
        return BillingRoute(provider=provider_name or "custom", model=model, base_url=base_url or "", billing_mode="unknown")
    return BillingRoute(provider=provider_name or "unknown", model=model.split("/")[-1] if model else "", base_url=base_url or "", billing_mode="unknown")


def _normalize_anthropic_model_name(model: str) -> str:
    """Normalize Anthropic model name variants to canonical form.

    Handles:
      - Dot notation: claude-opus-4.7 → claude-opus-4-7
      - Short aliases: claude-opus-4.7 → claude-opus-4-7
      - Strips anthropic/ prefix if present
    """
    name = model.lower().strip()
    if name.startswith("anthropic/"):
        name = name[len("anthropic/"):]
    # Normalize dots to dashes in version numbers (e.g. 4.7 → 4-7, 4.6 → 4-6)
    # But preserve the rest of the name structure
    name = re.sub(r"(\d+)\.(\d+)", r"\1-\2", name)
    return name


def _lookup_official_docs_pricing(route: BillingRoute) -> Optional[PricingEntry]:
    model = route.model.lower()
    # Direct lookup first
    entry = _OFFICIAL_DOCS_PRICING.get((route.provider, model))
    if entry:
        return entry
    # Try normalized name for Anthropic (handles dot-notation like opus-4.7)
    if route.provider == "anthropic":
        normalized = _normalize_anthropic_model_name(model)
        if normalized != model:
            entry = _OFFICIAL_DOCS_PRICING.get((route.provider, normalized))
            if entry:
                return entry
    return None


def _openrouter_pricing_entry(route: BillingRoute) -> Optional[PricingEntry]:
    return _pricing_entry_from_metadata(
        fetch_model_metadata(),
        route.model,
        source_url="https://openrouter.ai/docs/api/api-reference/models/get-models",
        pricing_version="openrouter-models-api",
    )


def _pricing_entry_from_metadata(
    metadata: Dict[str, Dict[str, Any]],
    model_id: str,
    *,
    source_url: str,
    pricing_version: str,
) -> Optional[PricingEntry]:
    if model_id not in metadata:
        return None
    pricing = metadata[model_id].get("pricing") or {}
    prompt = _to_decimal(pricing.get("prompt"))
    completion = _to_decimal(pricing.get("completion"))
    request = _to_decimal(pricing.get("request"))
    cache_read = _to_decimal(
        pricing.get("cache_read")
        or pricing.get("cached_prompt")
        or pricing.get("input_cache_read")
    )
    cache_write = _to_decimal(
        pricing.get("cache_write")
        or pricing.get("cache_creation")
        or pricing.get("input_cache_write")
    )
    if prompt is None and completion is None and request is None:
        return None

    def _per_token_to_per_million(value: Optional[Decimal]) -> Optional[Decimal]:
        if value is None:
            return None
        return value * _ONE_MILLION

    return PricingEntry(
        input_cost_per_million=_per_token_to_per_million(prompt),
        output_cost_per_million=_per_token_to_per_million(completion),
        cache_read_cost_per_million=_per_token_to_per_million(cache_read),
        cache_write_cost_per_million=_per_token_to_per_million(cache_write),
        request_cost=request,
        source="provider_models_api",
        source_url=source_url,
        pricing_version=pricing_version,
        fetched_at=_UTC_NOW(),
    )


def get_pricing_entry(
    model_name: str,
    provider: Optional[str] = None,
    base_url: Optional[str] = None,
    api_key: Optional[str] = None,
) -> Optional[PricingEntry]:
    route = resolve_billing_route(model_name, provider=provider, base_url=base_url)
    if route.billing_mode == "subscription_included":
        return PricingEntry(
            input_cost_per_million=_ZERO,
            output_cost_per_million=_ZERO,
            cache_read_cost_per_million=_ZERO,
            cache_write_cost_per_million=_ZERO,
            source="none",
            pricing_version="included-route",
        )
    if route.provider == "openrouter":
        return _openrouter_pricing_entry(route)
    if route.base_url:
        entry = _pricing_entry_from_metadata(
            fetch_endpoint_model_metadata(route.base_url, api_key=api_key or ""),
            route.model,
            source_url=f"{route.base_url.rstrip('/')}/models",
            pricing_version="openai-compatible-models-api",
        )
        if entry:
            return entry
    return _lookup_official_docs_pricing(route)


def normalize_usage(
    response_usage: Any,
    *,
    provider: Optional[str] = None,
    api_mode: Optional[str] = None,
) -> CanonicalUsage:
    """Normalize raw API response usage into canonical token buckets.

    Handles three API shapes:
    - Anthropic: input_tokens/output_tokens/cache_read_input_tokens/cache_creation_input_tokens
    - Codex Responses: input_tokens includes cache tokens; input_tokens_details.cached_tokens separates them
    - OpenAI Chat Completions: prompt_tokens includes cache tokens; prompt_tokens_details.cached_tokens separates them

    In both Codex and OpenAI modes, input_tokens is derived by subtracting cache
    tokens from the total — the API contract is that input/prompt totals include
    cached tokens and the details object breaks them out.
    """
    if not response_usage:
        return CanonicalUsage()

    provider_name = (provider or "").strip().lower()
    mode = (api_mode or "").strip().lower()

    if mode == "anthropic_messages" or provider_name == "anthropic":
        input_tokens = _to_int(getattr(response_usage, "input_tokens", 0))
        output_tokens = _to_int(getattr(response_usage, "output_tokens", 0))
        cache_read_tokens = _to_int(getattr(response_usage, "cache_read_input_tokens", 0))
        cache_write_tokens = _to_int(getattr(response_usage, "cache_creation_input_tokens", 0))
    elif mode == "codex_responses":
        input_total = _to_int(getattr(response_usage, "input_tokens", 0))
        output_tokens = _to_int(getattr(response_usage, "output_tokens", 0))
        details = getattr(response_usage, "input_tokens_details", None)
        cache_read_tokens = _to_int(getattr(details, "cached_tokens", 0) if details else 0)
        cache_write_tokens = _to_int(
            getattr(details, "cache_creation_tokens", 0) if details else 0
        )
        input_tokens = max(0, input_total - cache_read_tokens - cache_write_tokens)
    else:
        prompt_total = _to_int(getattr(response_usage, "prompt_tokens", 0))
        output_tokens = _to_int(getattr(response_usage, "completion_tokens", 0))
        details = getattr(response_usage, "prompt_tokens_details", None)
        # Primary: OpenAI-style prompt_tokens_details. Fallback: Anthropic-style
        # top-level fields that some OpenAI-compatible proxies (OpenRouter, Vercel
        # AI Gateway, Cline) expose when routing Claude models — without this
        # fallback, cache writes are undercounted as 0 and cache reads can be
        # missed when the proxy only surfaces them at the top level.
        # Port of cline/cline#10266.
        cache_read_tokens = _to_int(getattr(details, "cached_tokens", 0) if details else 0)
        if not cache_read_tokens:
            cache_read_tokens = _to_int(getattr(response_usage, "cache_read_input_tokens", 0))
        cache_write_tokens = _to_int(
            getattr(details, "cache_write_tokens", 0) if details else 0
        )
        if not cache_write_tokens:
            cache_write_tokens = _to_int(
                getattr(response_usage, "cache_creation_input_tokens", 0)
            )
        input_tokens = max(0, prompt_total - cache_read_tokens - cache_write_tokens)

    reasoning_tokens = 0
    output_details = getattr(response_usage, "output_tokens_details", None)
    if output_details:
        reasoning_tokens = _to_int(getattr(output_details, "reasoning_tokens", 0))

    return CanonicalUsage(
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cache_read_tokens=cache_read_tokens,
        cache_write_tokens=cache_write_tokens,
        reasoning_tokens=reasoning_tokens,
    )


def estimate_usage_cost(
    model_name: str,
    usage: CanonicalUsage,
    *,
    provider: Optional[str] = None,
    base_url: Optional[str] = None,
    api_key: Optional[str] = None,
) -> CostResult:
    route = resolve_billing_route(model_name, provider=provider, base_url=base_url)
    if route.billing_mode == "subscription_included":
        return CostResult(
            amount_usd=_ZERO,
            status="included",
            source="none",
            label="included",
            pricing_version="included-route",
        )

    entry = get_pricing_entry(model_name, provider=provider, base_url=base_url, api_key=api_key)
    if not entry:
        return CostResult(amount_usd=None, status="unknown", source="none", label="n/a")

    notes: list[str] = []
    amount = _ZERO

    if usage.input_tokens and entry.input_cost_per_million is None:
        return CostResult(amount_usd=None, status="unknown", source=entry.source, label="n/a")
    if usage.output_tokens and entry.output_cost_per_million is None:
        return CostResult(amount_usd=None, status="unknown", source=entry.source, label="n/a")
    if usage.cache_read_tokens:
        if entry.cache_read_cost_per_million is None:
            return CostResult(
                amount_usd=None,
                status="unknown",
                source=entry.source,
                label="n/a",
                notes=("cache-read pricing unavailable for route",),
            )
    if usage.cache_write_tokens:
        if entry.cache_write_cost_per_million is None:
            return CostResult(
                amount_usd=None,
                status="unknown",
                source=entry.source,
                label="n/a",
                notes=("cache-write pricing unavailable for route",),
            )

    if entry.input_cost_per_million is not None:
        amount += Decimal(usage.input_tokens) * entry.input_cost_per_million / _ONE_MILLION
    if entry.output_cost_per_million is not None:
        amount += Decimal(usage.output_tokens) * entry.output_cost_per_million / _ONE_MILLION
    if entry.cache_read_cost_per_million is not None:
        amount += Decimal(usage.cache_read_tokens) * entry.cache_read_cost_per_million / _ONE_MILLION
    if entry.cache_write_cost_per_million is not None:
        amount += Decimal(usage.cache_write_tokens) * entry.cache_write_cost_per_million / _ONE_MILLION
    if entry.request_cost is not None and usage.request_count:
        amount += Decimal(usage.request_count) * entry.request_cost

    status: CostStatus = "estimated"
    label = f"~${amount:.2f}"
    if entry.source == "none" and amount == _ZERO:
        status = "included"
        label = "included"

    if route.provider == "openrouter":
        notes.append("OpenRouter cost is estimated from the models API until reconciled.")

    return CostResult(
        amount_usd=amount,
        status=status,
        source=entry.source,
        label=label,
        fetched_at=entry.fetched_at,
        pricing_version=entry.pricing_version,
        notes=tuple(notes),
    )


def has_known_pricing(
    model_name: str,
    provider: Optional[str] = None,
    base_url: Optional[str] = None,
    api_key: Optional[str] = None,
) -> bool:
    """Check whether we have pricing data for this model+route.

    Uses direct lookup instead of routing through the full estimation
    pipeline — avoids creating dummy usage objects just to check status.
    """
    route = resolve_billing_route(model_name, provider=provider, base_url=base_url)
    if route.billing_mode == "subscription_included":
        return True
    entry = get_pricing_entry(model_name, provider=provider, base_url=base_url, api_key=api_key)
    return entry is not None



def format_duration_compact(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.0f}s"
    minutes = seconds / 60
    if minutes < 60:
        return f"{minutes:.0f}m"
    hours = minutes / 60
    if hours < 24:
        remaining_min = int(minutes % 60)
        return f"{int(hours)}h {remaining_min}m" if remaining_min else f"{int(hours)}h"
    days = hours / 24
    return f"{days:.1f}d"


def format_token_count_compact(value: int) -> str:
    abs_value = abs(int(value))
    if abs_value < 1_000:
        return str(int(value))

    sign = "-" if value < 0 else ""
    units = ((1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K"))
    for threshold, suffix in units:
        if abs_value >= threshold:
            scaled = abs_value / threshold
            if scaled < 10:
                text = f"{scaled:.2f}"
            elif scaled < 100:
                text = f"{scaled:.1f}"
            else:
                text = f"{scaled:.0f}"
            if "." in text:
                text = text.rstrip("0").rstrip(".")
            return f"{sign}{text}{suffix}"

    return f"{value:,}"
