"""IT agent settings (config.yaml ``it_agent``): the supervisor model — the setting, else the Default
harness's Background node; never the Claude Code CLI or the fast lane — and the run's limits."""
from __future__ import annotations

from agent.it_agent.model import Limits

_NO_MODEL = ("No supervisor model for IT tasks: set it_agent.supervisor_model in config.yaml (your Default "
             "harness has no Background node).")


def _config(config) -> dict:
    if config is not None:
        return config if isinstance(config, dict) else {}
    try:
        from jarviscopilot_cli.config import load_config
        return load_config() or {}
    except Exception:
        return {}


def _section(config) -> dict:
    sec = _config(config).get("it_agent")
    return sec if isinstance(sec, dict) else {}


def _background_model(store) -> str:
    try:
        if store is None:
            from agent.harness.store import store_for_home
            store = store_for_home()
        doc = store.get(store.effective("default")) or {}
        node = next((n for n in doc.get("nodes") or [] if isinstance(n, dict) and n.get("type") == "background"),
                    None)
        return str((node or {}).get("model") or "").strip()
    except Exception:
        return ""


def supervisor_ref(config=None, store=None) -> tuple:
    """(ref, "") or (None, the error to show)."""
    ref = str(_section(config).get("supervisor_model") or "").strip() or _background_model(store)
    if not ref or ref == "@session":
        return None, _NO_MODEL
    from agent.harness import builtins, llm
    try:
        provider = llm.resolve_ref(ref)[1]
    except Exception:
        provider = None
    if provider == "claude-code":
        return None, (f"IT tasks can't run on the Claude Code CLI ({ref}): set it_agent.supervisor_model in "
                      "config.yaml to an API model.")
    try:
        fast = builtins.fast_model_ref()
    except Exception:
        fast = ""
    if fast and ref == fast:
        return None, f"IT tasks can't run on the fast lane ({ref}): set it_agent.supervisor_model in config.yaml."
    return ref, ""


def fast_ref(config=None):
    """``computer.planner_model``: the quick model for queries and picking pages (None = the supervisor)."""
    computer = _config(config).get("computer")
    ref = str((computer or {}).get("planner_model") or "").strip() if isinstance(computer, dict) else ""
    return ref or None


def _int(value, default: int, low: int, high: int) -> int:
    try:
        return max(low, min(high, int(value)))
    except (TypeError, ValueError):
        return default


def limits(config=None) -> Limits:
    s = _section(config)
    return Limits(max_rethinks=_int(s.get("max_rethinks"), 3, 0, 10),
                  max_total_rethinks=_int(s.get("max_total_rethinks"), 8, 0, 30),
                  reboot_wait_minutes=_int(s.get("reboot_wait_minutes"), 60, 5, 240),
                  offline_wait_minutes=_int(s.get("offline_wait_minutes"), 30, 1, 240))
