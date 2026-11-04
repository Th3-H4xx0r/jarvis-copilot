"""Insights → Costs HTTP routes (Pranav, 2026-10-31: "options for me to connect all my
services … and store historical trends").

Billing keys typed on the Costs tab go to the profile .env and are never sent back;
plan prices and the budget are plain settings."""
import io
import json
from urllib.parse import urlparse

import pytest

from api import costs_routes, profiles


class _Handler:
    def __init__(self):
        self.wfile = io.BytesIO()
        self.headers = {}
        self.status = None

    def send_response(self, status):
        self.status = status

    def send_header(self, key, value):
        pass

    def end_headers(self):
        pass

    def payload(self):
        return json.loads(self.wfile.getvalue().decode("utf-8"))


def _offline(self, url, **kw):
    raise RuntimeError("offline")


@pytest.fixture
def home(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text("# keys\nOPENROUTER_API_KEY=sk-or-keep-me\n")
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setattr(profiles, "get_active_hermes_home", lambda: tmp_path)
    monkeypatch.setattr("agent.costs.store._STORE", None)
    for name in ("ANTHROPIC_ADMIN_KEY", "SONIOX_ORG_API_KEY", "OLLAMA_API_KEY", "OPENROUTER_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    # No network in tests: every billing fetch fails fast.
    monkeypatch.setattr("agent.costs.collector.Context.get_json", _offline)
    yield tmp_path


def _get(path):
    h = _Handler()
    assert costs_routes.handle_costs_get(h, urlparse(path))
    return h


def _post(path, body):
    h = _Handler()
    assert costs_routes.handle_costs_post(h, urlparse(path), body)
    return h


def _cards(days=7):
    data = _get(f"/api/costs?days={days}").payload()
    return {c["id"]: c for c in data["services"] + data["available"]}


def test_overview_lists_services_and_totals(home):
    h = _get("/api/costs?days=7")
    assert h.status == 200
    data = h.payload()
    assert data["days"] == 7
    assert "totals" in data and len(data["daily"]) == 7
    assert {"anthropic", "parallel", "server"} <= set(_cards())


def test_connect_saves_the_key_to_env_and_never_returns_it(home):
    h = _post("/api/costs/connect", {"service": "anthropic",
                                     "fields": {"admin_key": "sk-ant-admin01-SECRET1234"}})
    assert h.status == 200
    assert "SECRET1234" not in json.dumps(h.payload())
    env = (home / ".env").read_text()
    assert "ANTHROPIC_ADMIN_KEY=sk-ant-admin01-SECRET1234" in env
    assert "OPENROUTER_API_KEY=sk-or-keep-me" in env
    # The sync ran (offline here) and its failure is reported, not hidden.
    assert h.payload()["sync"]["ok"] is False
    card = h.payload()["detail"]["service"]
    assert card["fields"][0]["is_set"] is True and card["status"] == "error"


def test_connect_refuses_unknown_fields_and_junk(home):
    assert _post("/api/costs/connect", {"service": "anthropic", "fields": {"x": "y"}}).status == 400
    assert _post("/api/costs/connect", {"service": "anthropic",
                                        "fields": {"admin_key": "has spaces in it"}}).status == 400
    assert _post("/api/costs/connect", {"service": "nope", "fields": {}}).status == 400
    assert _post("/api/costs/connect", {"service": "anthropic", "fields": {"admin_key": ""}}).status == 400


def test_connect_refuses_a_regular_key_in_an_admin_field(home):
    before = (home / ".env").read_text()
    for key in ("sk-ant-usr-1234567890abcdef", "sk-ant-api03-1234567890abcdef"):
        h = _post("/api/costs/connect", {"service": "anthropic", "fields": {"admin_key": key}})
        assert h.status == 400
        assert "sk-ant-admin" in json.dumps(h.payload())
    h = _post("/api/costs/connect", {"service": "openai", "fields": {"admin_key": "sk-proj-1234567890"}})
    assert h.status == 400 and "sk-admin-" in json.dumps(h.payload())
    assert (home / ".env").read_text() == before


def test_disconnect_removes_only_billing_only_keys(home):
    (home / ".env").write_text("ANTHROPIC_ADMIN_KEY=sk-ant-admin01-x\nELEVENLABS_API_KEY=el-keep\n")
    assert _post("/api/costs/disconnect", {"service": "anthropic"}).payload()["removed_keys"] == 1
    assert _post("/api/costs/disconnect", {"service": "elevenlabs"}).payload()["removed_keys"] == 0
    env = (home / ".env").read_text()
    assert "ANTHROPIC_ADMIN_KEY" not in env and "ELEVENLABS_API_KEY=el-keep" in env


def test_plan_price_round_trip(home):
    h = _post("/api/costs/subscription", {"service": "claude-code", "amount_usd": "200",
                                          "interval": "month", "plan": "Max"})
    assert h.status == 200
    card = _cards()["claude-code"]
    assert card["status"] == "subscription" and card["subscription"]["amount_usd"] == 200
    assert card["period_total"] > 0
    _post("/api/costs/subscription", {"service": "claude-code", "amount_usd": None})
    assert _cards()["claude-code"]["subscription"] is None


def test_custom_subscription_and_bad_price(home):
    sid = _post("/api/costs/subscription",
                {"name": "Apple Developer", "amount_usd": 99, "interval": "year"}).payload()["service"]
    assert sid in _cards(30)
    assert _post("/api/costs/subscription", {"name": "X", "amount_usd": "lots"}).status == 400
    assert _post("/api/costs/subscription", {"name": "", "amount_usd": 5}).status == 400


def test_budget(home):
    assert _post("/api/costs/budget", {"monthly_usd": 150}).payload()["monthly_usd"] == 150
    assert _get("/api/costs?days=7").payload()["budget"]["monthly_usd"] == 150
    assert _post("/api/costs/budget", {"monthly_usd": None}).payload()["monthly_usd"] is None


def test_service_detail_404_for_unknown(home):
    assert _get("/api/costs/service?id=nope").status == 404
    h = _get("/api/costs/service?id=parallel&days=7")
    assert h.status == 200 and len(h.payload()["daily"]) == 7


def test_refresh_reports_per_service_results(home):
    (home / ".env").write_text("OLLAMA_API_KEY=ollama-test\n")
    res = _post("/api/costs/refresh", {}).payload()
    assert res["services"]["ollama-cloud"]["ok"] is False
    assert res["services"]["_calls"]["ok"] is True


def test_tool_summary_matches_the_screen(home):
    from tools.cost_insights_tool import cost_insights
    _post("/api/costs/subscription", {"service": "server", "amount_usd": 30})
    out = json.loads(cost_insights({"action": "summary", "days": 7}))
    screen = _get("/api/costs?days=7").payload()
    assert out["ok"] is True
    assert out["totals_usd"]["period"] == pytest.approx(round(screen["totals"]["period"], 2))
    assert any(s["id"] == "server" and s["plan"]["amount_usd"] == 30 for s in out["services"])
    assert json.loads(cost_insights({"action": "service", "service_id": "nope"}))["ok"] is False


def test_disconnect_keeps_the_plan_price_and_its_history(home):
    _post("/api/costs/subscription", {"service": "elevenlabs", "amount_usd": 22})
    (home / ".env").write_text("ELEVENLABS_API_KEY=el-keep\n")
    _post("/api/costs/disconnect", {"service": "elevenlabs"})
    assert _cards()["elevenlabs"]["subscription"]["amount_usd"] == 22


def test_browserbase_project_id_is_never_deleted_by_disconnect(home):
    (home / ".env").write_text("BROWSERBASE_API_KEY=bb_live_x\nBROWSERBASE_PROJECT_ID=proj-1\n")
    assert _post("/api/costs/disconnect", {"service": "browserbase"}).payload()["removed_keys"] == 0
    assert "BROWSERBASE_PROJECT_ID=proj-1" in (home / ".env").read_text()


def test_only_billing_only_fields_are_flagged_removable(home):
    cards = _cards()
    assert cards["anthropic"]["fields"][0]["billing_only"] is True
    assert all(not f["billing_only"] for f in cards["elevenlabs"]["fields"])
