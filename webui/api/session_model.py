"""Which model and provider a chat session's next turn really runs on: the stored pick, normalised against the configured provider and the live catalogue."""
from api.config import get_available_models
from api.config import DEFAULT_MODEL


def context_length_for(model: str, base_url: str = "", provider: str = "", cfg: dict | None = None) -> int:
    """The model's context window, 0 when unknown.

    config.yaml's ``model.context_length`` and ``custom_providers`` win over the
    metadata default (#1896): without them a 1M-context model reads as 256K and
    auto-compression fires at a quarter of the real window. ``cfg`` is the loaded
    config (read here when not given)."""
    try:
        from agent.model_metadata import get_model_context_length
        if cfg is None:
            from api.config import get_config
            cfg = get_config()
        cfg = cfg if isinstance(cfg, dict) else {}
        config_length = None
        model_cfg = cfg.get("model", {})
        if isinstance(model_cfg, dict) and model_cfg.get("context_length") is not None:
            try:
                parsed = int(model_cfg.get("context_length"))
                config_length = parsed if parsed > 0 else None
            except (TypeError, ValueError):
                pass  # an invalid override falls through to provider/registry probing
        custom_providers = cfg.get("custom_providers")
        try:
            return get_model_context_length(
                model, base_url,
                config_context_length=config_length,
                provider=provider or "",
                custom_providers=custom_providers if isinstance(custom_providers, list) else None,
            ) or 0
        except TypeError:
            # An agent build whose resolver predates those keyword arguments.
            return get_model_context_length(model, base_url) or 0
    except Exception:
        return 0


_PROVIDER_FAMILY_ALIASES = {
    "claude": "anthropic",
    "gpt": "openai",
    "gemini": "google",
    "openai-codex": "openai",
}


def provider_family(value: str | None) -> str:
    raw = str(value or "").strip().lower()
    if not raw:
        return ""
    if raw in _PROVIDER_FAMILY_ALIASES:
        return _PROVIDER_FAMILY_ALIASES[raw]
    for prefix, normalized in (
        ("openai-codex", "openai"),
        ("openai", "openai"),
        ("anthropic", "anthropic"),
        ("claude", "anthropic"),
        ("google", "google"),
        ("gemini", "google"),
        ("openrouter", "openrouter"),
        ("custom", "custom"),
    ):
        if raw.startswith(prefix):
            return normalized
    # Unknown prefix — return empty so callers treat it as "no match" and pass
    # the model through unchanged rather than incorrectly stripping it.
    return "" 


def _catalog_provider_id_sets(catalog: dict) -> tuple[set[str], set[str]]:
    raw_provider_ids: set[str] = set()
    normalized_provider_ids: set[str] = set()
    for group in catalog.get("groups") or []:
        raw = str(group.get("provider_id") or "").strip().lower()
        if not raw:
            continue
        raw_provider_ids.add(raw)
        normalized = provider_family(raw)
        if normalized:
            normalized_provider_ids.add(normalized)
    return raw_provider_ids, normalized_provider_ids


def _catalog_has_provider(
    provider_raw: str,
    provider_normalized: str,
    raw_provider_ids: set[str],
    normalized_provider_ids: set[str],
) -> bool:
    return (
        provider_raw in raw_provider_ids
        or (provider_normalized and provider_normalized in raw_provider_ids)
        or (provider_normalized and provider_normalized in normalized_provider_ids)
    )


def _model_matches_active_provider_family(
    model: str,
    active_provider: str,
) -> bool:
    model_lower = model.lower()
    for bare_prefix in ("gpt", "claude", "gemini"):
        if model_lower.startswith(bare_prefix):
            return provider_family(bare_prefix) == active_provider
    return False


def _catalog_model_id_matches(candidate: str, model: str) -> bool:
    candidate = str(candidate or "").strip()
    if candidate.startswith("@") and ":" in candidate:
        candidate = candidate.rsplit(":", 1)[1]
    if "/" in candidate:
        candidate = candidate.split("/", 1)[1]
    return candidate.replace("-", ".").lower() == model.replace("-", ".").lower()


def clean_session_provider(value: str | None) -> str | None:
    provider = str(value or "").strip().lower()
    if not provider or provider == "default":
        return None
    if provider.startswith("@"):
        provider = provider[1:]
    return provider or None


def _split_provider_qualified_model(model: str) -> tuple[str, str | None]:
    """(bare_model, provider) for ``@provider:model``; (model, None) otherwise.

    Delegates to config.split_provider_qualified_model so the session
    normaliser and the runtime router agree on where the provider ends —
    splitting on the last colon here turned ``@ollama-cloud:gemma4:31b`` into
    provider "ollama-cloud:gemma4" and swapped in the default model.
    """
    model = str(model or "").strip()
    from api.config import split_provider_qualified_model as _split_qualified
    parts = _split_qualified(model)
    if parts:
        provider = clean_session_provider(parts[0])
        bare = parts[1].strip()
        if provider and bare:
            return bare, provider
    return model, None


def needs_codex_provider_context(model: str, raw_active_provider: str, catalog: dict) -> bool:
    """Return True when a bare Codex model needs separate provider context.

    OpenAI, OpenAI Codex, Copilot, and OpenRouter can all expose GPT-looking
    bare names. If a session stores only ``gpt-...`` while Codex is active, a
    later provider-list/default-model round trip can lose the user's Codex
    choice. Store the provider separately instead of converting the persisted
    model to ``@openai-codex:model``.
    """
    if raw_active_provider != "openai-codex":
        return False
    if not model.lower().startswith("gpt"):
        return False
    for group in catalog.get("groups") or []:
        if str(group.get("provider_id") or "").strip().lower() != "openai-codex":
            continue
        return any(
            _catalog_model_id_matches(entry.get("id"), model)
            for entry in group.get("models", [])
            if isinstance(entry, dict)
        )
    return False


def resolve_session_model_state(
    model_id: str | None,
    model_provider: str | None = None,
) -> tuple[str, str | None, bool]:
    """Return (effective_model, effective_provider, model_was_normalized).

    Sessions can outlive provider changes. When an older session still points at
    a different provider namespace (for example `gemini/...` after switching the
    agent to OpenAI Codex), reusing that stale model causes chat startup to hit
    the wrong backend and fail. Normalize only obvious cross-provider mismatches.
    When a model has an explicit provider context, keep the model string itself
    in its picker/API shape and carry the provider as separate state.
    """
    catalog = get_available_models()
    default_model = str(catalog.get("default_model") or DEFAULT_MODEL or "").strip()
    model = str(model_id or "").strip()
    requested_provider = clean_session_provider(model_provider)
    if not model:
        return default_model, requested_provider, bool(default_model)

    active_provider = provider_family(catalog.get("active_provider"))
    # Also keep the raw active_provider slug for cross-provider detection with
    # non-listed providers (ollama-cloud, deepseek, xai, etc.) that provider_family
    # returns "" for. If the raw provider is set but normalization returned "", we still
    # want to detect that a session model from a known provider (e.g. openai/gpt-5.4-mini)
    # is stale relative to this unknown active provider. (#1023)
    raw_active_provider = str(catalog.get("active_provider") or "").strip().lower()
    if not active_provider and not raw_active_provider:
        bare_model, explicit_provider = _split_provider_qualified_model(model)
        return model, explicit_provider or requested_provider, False

    bare_for_context, explicit_provider = _split_provider_qualified_model(model)
    if requested_provider and not explicit_provider:
        return model, requested_provider, False

    if model.startswith("@") and ":" in model:
        provider_raw = explicit_provider or ""
        provider_normalized = provider_family(provider_raw)
        bare_model = bare_for_context.strip()
        if not provider_raw or not bare_model:
            return model, requested_provider, False

        raw_provider_ids, normalized_provider_ids = _catalog_provider_id_sets(catalog)
        hint_matches_active = (
            provider_raw == raw_active_provider
            or provider_raw == active_provider
            or (provider_normalized and provider_normalized == active_provider)
        )
        if hint_matches_active:
            # The @provider:model hint explicitly names the active provider, so this
            # selection is intentional — not a stale cross-provider artifact. Return
            # the full @provider:model string unchanged so downstream (resolve_model_provider
            # in config.py) can route through the correct provider. Stripping the prefix
            # here would collapse duplicate model IDs from different providers back to the
            # bare ID, causing the first matching provider to win on the next UI render
            # and the wrong provider to be used for the agent run. (#1253)
            return model, provider_raw, False

        if _catalog_has_provider(
            provider_raw,
            provider_normalized,
            raw_provider_ids,
            normalized_provider_ids,
        ):
            return model, provider_raw, False

        if _model_matches_active_provider_family(bare_model, active_provider):
            provider_context = (
                raw_active_provider
                if needs_codex_provider_context(bare_model, raw_active_provider, catalog)
                else None
            )
            return bare_model, provider_context, True
        if default_model:
            provider_context = (
                raw_active_provider
                if needs_codex_provider_context(default_model, raw_active_provider, catalog)
                else None
            )
            return default_model, provider_context, True
        return model, provider_raw, False

    slash = model.find("/")
    if slash < 0:
        model_lower = model.lower()
        for bare_prefix in ("gpt", "claude", "gemini"):
            if model_lower.startswith(bare_prefix):
                model_provider = provider_family(bare_prefix)
                if model_provider and model_provider != active_provider and default_model:
                    provider_context = (
                        raw_active_provider
                        if needs_codex_provider_context(default_model, raw_active_provider, catalog)
                        else None
                    )
                    return default_model, provider_context, True
                provider_context = (
                    raw_active_provider
                    if needs_codex_provider_context(model, raw_active_provider, catalog)
                    else requested_provider
                )
                return model, provider_context, False
        return model, requested_provider, False

    model_provider = provider_family(model[:slash])

    # For custom/openrouter active providers: only skip normalization when the
    # model's namespace prefix is actually routable by a group in the catalog.
    # A user who only has custom_providers configured (active_provider="custom")
    # with a stale session model like "openai/gpt-5.4-mini" would otherwise
    # never get cleaned up, causing "(unavailable)" to appear in the picker.
    if active_provider in {"custom", "openrouter"}:
        # These namespaces are always routable as-is — preserve them.
        if model_provider in {"", "custom", "openrouter"}:
            return model, requested_provider, False
        # Check if any catalog group can actually route this model's prefix.
        groups = catalog.get("groups") or []
        routable_provider_ids = {
            provider_family(g.get("provider_id") or "") for g in groups
        }
        # openrouter group can route any provider/model namespace
        has_openrouter_group = any(
            (g.get("provider_id") or "") == "openrouter" for g in groups
        )
        if model_provider in routable_provider_ids or has_openrouter_group:
            return model, requested_provider, False
        # Model prefix is not routable — stale cross-provider reference, clear it.
        if default_model:
            return default_model, requested_provider, True
        return model, requested_provider, False

    # Skip normalization for models on custom/openrouter namespaces — these are
    # user-controlled and should never be silently replaced.
    #
    # OpenAI Codex is intentionally normalized to the OpenAI family above so bare
    # GPT IDs survive provider switches. Slash-qualified OpenAI IDs are different:
    # ``openai/gpt-...`` is the OpenRouter shape for OpenAI models, and
    # resolve_model_provider() routes that through OpenRouter when Codex is the
    # configured provider. Legacy sessions can carry that stale slash ID without
    # a saved model_provider, so repair it to the active Codex default unless the
    # session/request explicitly says it is an OpenRouter selection. (#1734)
    if (
        raw_active_provider == "openai-codex"
        and model_provider == "openai"
        and requested_provider is None
        and default_model
    ):
        # Persist provider_context = "openai-codex" unconditionally on this
        # repair path so the resolved shape is stable across resolutions
        # (Opus stage-303 SHOULD-FIX: avoid redundant repair-writes per
        # chat-start when the catalog-coverage check fails — e.g. if a
        # future Codex default is itself slash-prefixed). Once we've
        # decided the session belongs to Codex, persist that decision.
        return default_model, raw_active_provider, True

    # Also normalize when the model is from a known provider but the active provider
    # is an unlisted one (e.g. ollama-cloud) — active_provider is "" in that case
    # but raw_active_provider is set. If model_provider doesn't start with the raw
    # active provider name, the session model is stale. (#1023)
    _active_for_compare = active_provider or raw_active_provider
    if model_provider and model_provider not in {"", "custom", "openrouter"} and model_provider != _active_for_compare and default_model:
        return default_model, requested_provider, True
    return model, requested_provider, False


