"""Insights → Costs (agent/costs/): how each day's spend is worked out and kept.

Pranav, 2026-10-31: "connect all my services … look for their APIs or another way for me
to get that cost usage data and store historical trends". These pin the rules the screen
and the cost_insights tool both rely on.
"""
import calendar
import json
import sqlite3
import time

import pytest

from agent.costs import collector, meter, report, settings
from agent.costs.store import CostStore, day_of, days_back


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    for name in ("OPENROUTER_API_KEY", "OPENROUTER_MANAGEMENT_KEY", "ANTHROPIC_ADMIN_KEY",
                 "OLLAMA_API_KEY", "SONIOX_ORG_API_KEY", "PARALLEL_API_KEY", "OPENAI_ADMIN_KEY",
                 "ELEVENLABS_API_KEY", "BROWSERBASE_API_KEY", "ANTHROPIC_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr("agent.costs.store._STORE", None)
    return tmp_path


def _state_db(path, rows=(), searches=()):
    db = sqlite3.connect(path)
    db.executescript(
        "CREATE TABLE message_usage (id INTEGER PRIMARY KEY, session_id TEXT, turn INT, "
        "timestamp REAL, model TEXT, provider TEXT, input_tokens INT, output_tokens INT, "
        "cache_read_tokens INT, cache_write_tokens INT, reasoning_tokens INT);"
        "CREATE TABLE messages (id INTEGER PRIMARY KEY, role TEXT, tool_name TEXT, timestamp REAL);")
    for ts, provider, model, i, o, cr, cw in rows:
        db.execute("INSERT INTO message_usage (session_id, turn, timestamp, model, provider, "
                   "input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, "
                   "reasoning_tokens) VALUES ('s', 1, ?, ?, ?, ?, ?, ?, ?, 0)",
                   (ts, model, provider, i, o, cr, cw))
    for ts in searches:
        db.execute("INSERT INTO messages (role, tool_name, timestamp) VALUES ('tool', 'web_search', ?)", (ts,))
    db.commit()
    db.close()


def _card(o, sid):
    return next(c for c in o["services"] + o["available"] if c["id"] == sid)


def test_a_million_sonnet_output_tokens_cost_ten_dollars(home):
    _state_db(home / "state.db", [(time.time(), "anthropic-api", "claude-sonnet-5-5", 0, 1_000_000, 0, 0)])
    collector.collect()
    o = report.overview(7)
    card = _card(o, "anthropic")
    assert card["period_total"] == pytest.approx(10.0)
    assert card["status"] == "estimated"
    assert card["sources"] == ["estimate"]
    assert o["totals"]["period"] == pytest.approx(10.0)


def test_long_cache_retention_prices_writes_at_the_one_hour_rate(home):
    (home / "config.yaml").write_text("prompt_caching:\n  retention: long\n")
    _state_db(home / "state.db", [(time.time(), "anthropic-api", "claude-sonnet-5-5", 0, 0, 0, 1_000_000)])
    collector.collect()
    assert _card(report.overview(7), "anthropic")["period_total"] == pytest.approx(4.0)  # 2× $2 input


def test_subscription_calls_cost_nothing_but_show_their_api_value(home):
    _state_db(home / "state.db", [(time.time(), "claude-code", "claude-sonnet-5-5", 0, 1_000_000, 0, 0)])
    collector.collect()
    card = _card(report.overview(7), "claude-code")
    assert card["period_total"] == 0
    assert card["status"] == "needs_price"
    assert card["units"]["api_equiv_usd"] == pytest.approx(10.0)


def test_a_plan_price_is_spread_over_the_days_of_its_month(home):
    store = CostStore(home / "costs.db")
    today = day_of(time.time())
    settings.set_subscription("server", 31, store=store, since=today)
    rows = store.daily_rows(today, service="server")
    assert len(rows) == 1 and rows[0]["source"] == "subscription"
    dim = calendar.monthrange(int(today[:4]), int(today[5:7]))[1]
    assert rows[0]["amount_usd"] == pytest.approx(31 / dim, rel=1e-4)


def test_billing_beats_the_estimate_for_the_same_day(home):
    store = CostStore(home / "costs.db")
    day = day_of(time.time())
    store.upsert_daily("anthropic", day, "estimate", 5.0)
    store.upsert_daily("anthropic", day, "billing", 3.0)
    card = _card(report.overview(7, store=store), "anthropic")
    assert card["period_total"] == pytest.approx(3.0)
    assert card["estimate_total"] == pytest.approx(5.0)
    assert card["billing_total"] == pytest.approx(3.0)


def test_plan_usage_reported_by_a_subscription_is_not_extra_spend(home):
    store = CostStore(home / "costs.db")
    store.upsert_daily("ollama-cloud", day_of(time.time()), "billing", 1.5, {"plan_usage": True})
    card = _card(report.overview(7, store=store), "ollama-cloud")
    assert card["period_total"] == 0
    assert card["plan_usage_usd"] == pytest.approx(1.5)


def test_a_rise_in_a_cumulative_counter_becomes_that_days_spend(home):
    store = CostStore(home / "costs.db")
    now = time.time()
    store.add_snapshot("fish-audio", used_usd=8.0, ts=now - 86400)
    store.add_snapshot("fish-audio", used_usd=8.4, ts=now)
    collector.daily_from_cumulative(store, "fish-audio", now - 3 * 86400)
    rows = store.daily_rows(day_of(now), service="fish-audio")
    assert rows and rows[0]["source"] == "billing"
    assert rows[0]["amount_usd"] == pytest.approx(0.4)


def test_a_gap_of_several_days_is_not_booked_on_one_day(home):
    store = CostStore(home / "costs.db")
    now = time.time()
    store.add_snapshot("fish-audio", used_usd=1.0, ts=now - 4 * 86400)
    store.add_snapshot("fish-audio", used_usd=9.0, ts=now)
    collector.daily_from_cumulative(store, "fish-audio", now - 6 * 86400)
    assert store.daily_rows(day_of(now), service="fish-audio") == []


def test_the_meter_never_raises(home, monkeypatch):
    def boom():
        raise RuntimeError("disk gone")
    monkeypatch.setattr("agent.costs.store.get_store", boom)
    meter.record("parallel", "search", 1, mode="fast")


def test_metered_parallel_searches_are_priced_by_mode(home):
    meter.record("parallel", "search", 1, mode="fast")
    meter.record("parallel", "search", 1, mode="advanced")
    collector.collect()
    card = _card(report.overview(7), "parallel")
    assert card["period_total"] == pytest.approx(0.006)
    assert card["units"]["searches"] == 2


def test_parallel_history_is_backfilled_once_when_the_key_is_set(home):
    (home / ".env").write_text("PARALLEL_API_KEY=pk-test-12345678\n")
    now = time.time()
    _state_db(home / "state.db", searches=[now - 86400, now - 86400, now - 2 * 86400])
    collector.collect()
    collector.collect()
    card = _card(report.overview(7), "parallel")
    assert card["units"]["searches"] == 3
    assert card["units"]["from_history"] is True


def test_one_failing_billing_api_does_not_stop_the_others(home):
    (home / ".env").write_text("OLLAMA_API_KEY=ollama-test-key\nOPENROUTER_API_KEY=sk-or-test-key\n")

    def http_get(url, headers=None, params=None):
        if "ollama" in url:
            raise collector.ProviderError("HTTP 401: nope", status=401)
        return {"data": {"usage": 2.5, "usage_daily": 0.5, "limit": None, "limit_remaining": None}}

    result = collector.collect(http_get=http_get)
    assert result["services"]["ollama-cloud"]["ok"] is False
    assert result["services"]["openrouter"]["ok"] is True
    o = report.overview(7)
    assert _card(o, "ollama-cloud")["status"] == "error"
    assert _card(o, "openrouter")["status"] == "billing"
    assert _card(o, "openrouter")["period_total"] == pytest.approx(0.5)


def test_blank_keys_in_the_env_file_count_as_unset(home):
    (home / ".env").write_text("OPENROUTER_API_KEY=\n")
    calls = []
    collector.collect(http_get=lambda *a, **k: calls.append(a) or {})
    assert calls == []


def test_anthropic_cost_report_amounts_are_cents(home):
    (home / ".env").write_text("ANTHROPIC_ADMIN_KEY=sk-ant-admin01-test\n")
    day = days_back(1)[0]

    def http_get(url, headers=None, params=None):
        assert headers["x-api-key"] == "sk-ant-admin01-test"
        return {"data": [{"starting_at": f"{day}T00:00:00Z", "results": [
            {"amount": "1234.5", "currency": "USD", "model": "claude-sonnet-5-5"}]}],
            "has_more": False}

    collector.collect("anthropic", http_get=http_get)
    detail = report.service_detail("anthropic", 7)
    row = next(r for r in detail["daily"] if r["day"] == day)
    assert row["billing"] == pytest.approx(12.345)
    assert detail["billing_items"][0]["item"] == "claude-sonnet-5-5"


def test_a_custom_subscription_can_be_added_and_deleted(home):
    store = CostStore(home / "costs.db")
    sid = settings.add_custom("Domain", 12, interval="year", store=store)
    assert sid.startswith("custom-")
    assert _card(report.overview(30, store=store), sid)["status"] == "subscription"
    settings.clear_subscription(sid, store=store)
    assert sid not in store.all_service_configs()
    assert store.daily_rows("2000-01-01", service=sid) == []


def test_bad_prices_are_refused(home):
    store = CostStore(home / "costs.db")
    for bad in ("abc", -1, 10 ** 9, float("nan")):
        with pytest.raises(settings.SettingsError):
            settings.set_subscription("server", bad, store=store)


def test_the_views_never_contain_a_saved_key(home):
    (home / ".env").write_text("ANTHROPIC_ADMIN_KEY=sk-ant-admin01-SECRETVALUE\n")
    o = report.overview(30)
    text = json.dumps(o) + json.dumps(report.service_detail("anthropic", 30))
    assert "SECRETVALUE" not in text
    assert _card(o, "anthropic")["fields"][0]["is_set"] is True


def test_the_projection_uses_the_recent_daily_average(home):
    store = CostStore(home / "costs.db")
    now = time.time()
    for d in days_back(8, now=now)[:-1]:
        store.upsert_daily("anthropic", d, "estimate", 2.0)
    o = report.overview(30, store=store, now=now)
    today = day_of(now)
    dim = calendar.monthrange(int(today[:4]), int(today[5:7]))[1]
    done = int(today[8:10]) - 1
    done_spend = sum(2.0 for d in days_back(8, now=now)[:-1] if d[:7] == today[:7])
    assert o["totals"]["projected_month"] == pytest.approx(done_spend + 2.0 * (dim - done), rel=1e-3)


def test_a_routine_run_never_truncates_the_oldest_day_of_its_window(home, monkeypatch):
    """Bug sweep 2026-10-31: the 35-day window started at a time of day, so each run re-priced
    its oldest day from only the later calls and overwrote the full-day row."""
    from agent.costs.store import day_start_ts
    now = time.time()
    old_day = day_of(now - 35 * 86400)
    start = day_start_ts(old_day)
    rows = [(start + h * 3600 + 60, "anthropic-api", "claude-sonnet-5-5", 0, 100_000, 0, 0) for h in range(24)]
    _state_db(home / "state.db", rows)
    collector.collect()                       # first run: full backfill
    full = CostStore(home / "costs.db").daily_rows(old_day, old_day, service="anthropic")[0]["amount_usd"]
    collector.collect()                       # routine 35-day run
    again = CostStore(home / "costs.db").daily_rows(old_day, old_day, service="anthropic")[0]["amount_usd"]
    assert full == pytest.approx(24.0) and again == pytest.approx(full)


def test_an_impossible_start_date_is_refused_and_saves_nothing(home):
    store = CostStore(home / "costs.db")
    with pytest.raises(settings.SettingsError):
        settings.set_subscription("server", 10, since="2026-02-30", store=store)
    assert "server" not in store.all_service_configs()


def test_a_refused_custom_subscription_leaves_no_card(home):
    store = CostStore(home / "costs.db")
    with pytest.raises(settings.SettingsError):
        settings.add_custom("Netflix", 10, interval="weekly", store=store)
    assert store.all_service_configs() == {}


def test_one_broken_plan_does_not_stop_the_others_spreading(home):
    store = CostStore(home / "costs.db")
    store.set_service_config("server", {"amount_usd": 10, "interval": "month", "since": "2026-02-30"})
    store.set_service_config("photon", {"amount_usd": 25, "interval": "month"})
    collector.spread_subscriptions(store)
    today = day_of(time.time())
    assert store.daily_rows(today, service="photon")
    assert store.daily_rows(today, service="server")  # a bad date falls back to the default start


def test_plan_rows_without_a_config_are_cleared(home):
    store = CostStore(home / "costs.db")
    store.upsert_daily("custom-gone", day_of(time.time()), "subscription", 1.0)
    collector.spread_subscriptions(store)
    assert store.daily_rows("2000-01-01", service="custom-gone") == []


def test_a_named_sync_with_missing_keys_is_not_reported_as_success(home):
    (home / ".env").write_text("BROWSERBASE_API_KEY=bb_live_x\n")  # project ID missing
    res = collector.collect("browserbase", http_get=lambda *a, **k: {})
    assert res["services"]["browserbase"]["ok"] is False
