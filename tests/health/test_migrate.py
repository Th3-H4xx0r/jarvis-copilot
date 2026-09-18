"""The per-wearable health spaces fold into the one Jarvis Health space."""
from jarvis_health.metrics import to_json
from jarvis_health.migrate import migrate_wearable_spaces
from jarvis_health.store import SHARED_SPACE, HealthStore

from .fixtures import day


def _legacy(registry, space_id, device_id, **settings):
    space = registry.space(space_id, name="Health R12")
    space.put("settings", {"kind": "ring", "device_id": device_id, "device_name": "R12",
                           "bridge_device_id": "phone-1", "protected": True, **settings})
    space.put("day-2026-09-17", to_json(day()))
    space.put("scores-2026-09-17", {"date": "2026-09-17"})
    space.append("alerts", {"rule": "short_sleep", "date": "2026-09-17"}, source="jarvis_health")
    return space


def test_a_wearable_space_moves_into_the_shared_one(tmp_registry):
    _legacy(tmp_registry, "wearable-ring-aaaa0000", "aaaa0000-1", model="m1", frequency="hourly")
    removed = []
    assert migrate_wearable_spaces(remove_schedule=removed.append)["moved"] == ["wearable-ring-aaaa0000"]
    assert removed == ["wearable-ring-aaaa0000"]
    assert not tmp_registry.exists("wearable-ring-aaaa0000")
    store = HealthStore()
    assert store.settings()["model"] == "m1"
    assert store.day("2026-09-17", "ring-aaaa0000") is not None
    assert store.scores("2026-09-17") == {"date": "2026-09-17"}
    assert store.fired_today("2026-09-17") == {"short_sleep"}
    (entry,) = store.roster()
    assert entry["key"] == "ring-aaaa0000" and entry["bridge_device_id"] == "phone-1"


def test_two_spaces_merge_and_the_first_settings_win(tmp_registry):
    _legacy(tmp_registry, "wearable-ring-aaaa0000", "aaaa0000", model="first")
    _legacy(tmp_registry, "wearable-ring-bbbb0000", "bbbb0000", model="second")
    migrate_wearable_spaces(remove_schedule=lambda _: None)
    store = HealthStore()
    assert store.settings()["model"] == "first"
    assert {e["key"] for e in store.roster()} == {"ring-aaaa0000", "ring-bbbb0000"}


def test_running_twice_changes_nothing(tmp_registry):
    _legacy(tmp_registry, "wearable-ring-aaaa0000", "aaaa0000")
    migrate_wearable_spaces(remove_schedule=lambda _: None)
    assert migrate_wearable_spaces(remove_schedule=lambda _: None)["moved"] == []
    assert tmp_registry.exists(SHARED_SPACE)


def test_nothing_to_move_creates_nothing(tmp_registry):
    assert migrate_wearable_spaces(remove_schedule=lambda _: None)["moved"] == []
    assert not tmp_registry.exists(SHARED_SPACE)


def test_the_old_default_alert_threshold_moves_to_the_battery_one(tmp_registry):
    _legacy(tmp_registry, "wearable-ring-aaaa0000", "aaaa0000",
            rules={"health_low": {"enabled": True, "threshold": 55}})
    migrate_wearable_spaces(remove_schedule=lambda _: None)
    assert HealthStore().settings()["rules"]["health_low"]["threshold"] == 25


def test_a_chosen_score_threshold_is_reset_too_because_the_rule_now_watches_the_battery(tmp_registry):
    _legacy(tmp_registry, "wearable-ring-aaaa0000", "aaaa0000",
            rules={"health_low": {"enabled": True, "threshold": 70}, "short_sleep": {"threshold": 4}})
    migrate_wearable_spaces(remove_schedule=lambda _: None)
    rules = HealthStore().settings()["rules"]
    assert rules["health_low"]["threshold"] == 25
    assert rules["short_sleep"]["threshold"] == 4, "other rules keep what was chosen"
