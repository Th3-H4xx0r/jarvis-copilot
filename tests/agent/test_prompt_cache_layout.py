"""The shared prompt layout's cache markers: the tools and the stable system
block are cached on their own (so every agent on a model shares them, and a
memory change doesn't invalidate them), the newest messages ride the tail."""
from agent.prompt_caching import apply_anthropic_cache_control, tool_cache_marker


def _msgs():
    return [{"role": "system", "content": "STABLE\n\nVOLATILE"},
            {"role": "user", "content": "a"}, {"role": "assistant", "content": "b"},
            {"role": "user", "content": "c"}]


def _markers(msgs):
    out = []
    for m in msgs:
        c = m.get("content")
        if isinstance(c, list):
            out += [b["cache_control"] for b in c if isinstance(b, dict) and b.get("cache_control")]
        elif m.get("cache_control"):
            out.append(m["cache_control"])
    return out


PARTS = {"stable": "STABLE", "volatile": "VOLATILE"}


def test_system_splits_into_a_cached_stable_block_and_an_uncached_volatile_one():
    msgs = apply_anthropic_cache_control(_msgs(), system_parts=PARTS, retention="long",
                                         reserve_for_tools=True)
    blocks = msgs[0]["content"]
    assert [b["text"] for b in blocks] == ["STABLE", "VOLATILE"]
    assert blocks[0]["cache_control"]["ttl"] == "1h"
    assert "cache_control" not in blocks[1]


def test_never_more_than_four_breakpoints_counting_the_tools():
    msgs = apply_anthropic_cache_control(_msgs() + [{"role": "assistant", "content": "d"},
                                                    {"role": "user", "content": "e"}],
                                         system_parts=PARTS, retention="long", reserve_for_tools=True)
    assert len(_markers(msgs)) + 1 <= 4


def test_long_retention_puts_every_1h_marker_before_any_5m_one():
    msgs = apply_anthropic_cache_control(_msgs(), system_parts=PARTS, retention="long",
                                         reserve_for_tools=True)
    ttls = [m.get("ttl", "5m") for m in _markers(msgs)]
    # The tools marker (1h) comes before all of these in the request.
    assert ttls == sorted(ttls, key=lambda t: 0 if t == "1h" else 1)
    assert ttls[-1] == "5m" and ttls[0] == "1h"


def test_standard_retention_is_all_5m():
    msgs = apply_anthropic_cache_control(_msgs(), system_parts=PARTS, retention="standard",
                                         reserve_for_tools=True)
    assert all("ttl" not in m for m in _markers(msgs))
    assert "ttl" not in tool_cache_marker("standard")
    assert tool_cache_marker("long")["ttl"] == "1h"


def test_mismatched_parts_fall_back_to_one_system_block():
    msgs = apply_anthropic_cache_control(_msgs(), system_parts={"stable": "OTHER", "volatile": ""},
                                         retention="long")
    content = msgs[0]["content"]
    texts = [b["text"] for b in content] if isinstance(content, list) else [content]
    assert texts == ["STABLE\n\nVOLATILE"]


def test_old_call_shape_still_works():
    msgs = apply_anthropic_cache_control(_msgs(), cache_ttl="5m")
    assert len(_markers(msgs)) == 4


def test_profile_cache_extras_default_to_nothing():
    from providers import ProviderProfile
    assert ProviderProfile(name="x").prompt_cache_extras("long", "k") == {}


def test_a_restored_prompt_is_split_when_it_starts_with_the_stable_block():
    from agent.system_prompt import split_stored_prompt
    assert split_stored_prompt("STABLE\n\nMEMORY v1", "STABLE") == {"stable": "STABLE", "volatile": "MEMORY v1"}
    assert split_stored_prompt("STABLE", "STABLE") == {"stable": "STABLE", "volatile": ""}
    # Stored under an older stable block: no split (one block, as before).
    assert split_stored_prompt("OLD STABLE\n\nMEMORY", "STABLE") is None
    assert split_stored_prompt("STABLEX\n\nMEMORY", "STABLE") is None
    assert split_stored_prompt("STABLE\n\nMEMORY", "") is None


def test_one_hour_markers_only_where_the_endpoint_takes_them(monkeypatch):
    from types import SimpleNamespace
    from agent.prompt_caching import marker_retention
    native = SimpleNamespace(_cache_retention="long", api_mode="anthropic_messages", _anthropic_base_url=None,
                             base_url="https://api.anthropic.com")
    openrouter = SimpleNamespace(_cache_retention="long", api_mode="chat_completions",
                                 base_url="https://openrouter.ai/api/v1")
    gateway = SimpleNamespace(_cache_retention="long", api_mode="anthropic_messages",
                              _anthropic_base_url="https://api.minimax.io/anthropic",
                              base_url="https://api.minimax.io/anthropic")
    standard = SimpleNamespace(_cache_retention="standard", api_mode="anthropic_messages",
                               _anthropic_base_url=None, base_url="https://api.anthropic.com")
    assert marker_retention(native) == "long"
    assert marker_retention(openrouter) == "long"
    assert marker_retention(gateway) == "standard"
    assert marker_retention(standard) == "standard"
