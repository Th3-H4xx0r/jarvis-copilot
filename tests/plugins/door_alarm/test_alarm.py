"""The alarm state machine on a fake clock: every transition, delays, home/away, restarts."""
import pytest

from plugins.door_alarm.alarm import Alarm, ArmRefused

FRONT = {"id": "dp:front", "name": "Front Door", "open": False, "instant": False, "active_home": True,
         "notify_disarmed": False, "on_open_prompt": ""}
BACK = {"id": "dp:back", "name": "Back Door", "open": False, "instant": False, "active_home": False,
        "notify_disarmed": True, "on_open_prompt": ""}


def setup(contacts=None, settings=None, state=None):
    clock = [1000.0]
    contacts = contacts if contacts is not None else [dict(FRONT), dict(BACK)]
    alarm = Alarm(settings or {"exit_delay": 60, "entry_delay": 30, "siren_duration": 180},
                  contacts=lambda: contacts, clock=lambda: clock[0], state=state)
    return alarm, clock, contacts


def kinds(effects):
    return [e.kind for e in effects]


def contact(contacts, cid):
    return next(c for c in contacts if c["id"] == cid)


def test_arm_away_waits_for_the_exit_delay():
    alarm, clock, _ = setup()
    alarm.arm("away")
    assert alarm.state == "arming"
    clock[0] += 59
    alarm.tick()
    assert alarm.state == "arming"
    clock[0] += 1
    alarm.tick()
    assert alarm.state == "armed_away"


def test_opens_during_exit_delay_are_ignored():
    alarm, clock, contacts = setup()
    alarm.arm("away")
    assert kinds(alarm.door_opened(contact(contacts, "dp:front"))) == []
    assert alarm.state == "arming"


def test_entry_delay_then_trigger_with_every_alarm_effect():
    alarm, clock, contacts = setup(settings={"exit_delay": 0, "entry_delay": 30, "siren_duration": 180})
    alarm.arm("away")
    assert alarm.state == "armed_away"
    effects = alarm.door_opened(contact(contacts, "dp:front"))
    assert alarm.state == "entry" and kinds(effects) == ["push_entry"]
    assert effects[0].data["seconds"] == 30 and effects[0].data["name"] == "Front Door"
    clock[0] += 30
    effects = alarm.tick()
    assert alarm.state == "triggered"
    assert kinds(effects) == ["siren_on", "push_triggered", "ring_phone", "pod_alert", "note"]


def test_siren_stops_after_its_duration_but_the_alarm_stays_triggered_and_reopens_restart_it():
    alarm, clock, contacts = setup(contacts=[dict(FRONT, instant=True)],
                                   settings={"exit_delay": 0, "entry_delay": 30, "siren_duration": 180})
    alarm.arm("away")
    assert "siren_on" in kinds(alarm.door_opened(contact([dict(FRONT, instant=True)], "dp:front")))
    clock[0] += 180
    assert kinds(alarm.tick()) == ["siren_off"]
    assert alarm.state == "triggered" and not alarm.siren_on
    assert kinds(alarm.door_opened(dict(FRONT))) == ["siren_on", "note"]


def test_armed_home_only_watches_contacts_active_at_home():
    alarm, clock, contacts = setup()
    alarm.arm("home")
    assert alarm.state == "armed_home"
    assert kinds(alarm.door_opened(contact(contacts, "dp:back"))) == []
    assert kinds(alarm.door_opened(contact(contacts, "dp:front"))) == ["push_entry"]


def test_arming_with_an_open_door_is_refused_unless_bypassed():
    contacts = [dict(FRONT, open=True), dict(BACK)]
    alarm, clock, _ = setup(contacts=contacts)
    with pytest.raises(ArmRefused) as err:
        alarm.arm("away")
    assert [c["name"] for c in err.value.open_contacts] == ["Front Door"]
    alarm.arm("away", bypass=["dp:front"])
    clock[0] += 60
    alarm.tick()
    assert kinds(alarm.door_opened(contacts[0])) == []  # bypassed for this arming
    assert kinds(alarm.door_opened(contacts[1])) == ["push_entry"]


def test_home_mode_ignores_an_open_door_not_active_at_home():
    contacts = [dict(FRONT), dict(BACK, open=True)]
    alarm, _clock, _ = setup(contacts=contacts)
    alarm.arm("home")
    assert alarm.state == "armed_home"


def test_disarm_from_anywhere_clears_and_stops_the_siren():
    alarm, clock, contacts = setup(settings={"exit_delay": 0, "entry_delay": 0, "siren_duration": 180})
    alarm.arm("away")
    alarm.door_opened(contact(contacts, "dp:front"))
    assert alarm.state == "triggered"
    assert kinds(alarm.disarm()) == ["siren_off", "stop_ring", "note"]
    assert alarm.state == "disarmed"
    assert kinds(alarm.disarm()) == []


def test_silence_keeps_the_alarm_triggered():
    alarm, clock, contacts = setup(settings={"exit_delay": 0, "entry_delay": 0, "siren_duration": 180})
    alarm.arm("away")
    alarm.door_opened(contact(contacts, "dp:front"))
    assert kinds(alarm.silence()) == ["siren_off", "stop_ring"]
    assert alarm.state == "triggered" and not alarm.siren_on


def test_disarmed_opens_notify_only_opted_in_contacts_and_prompts_run_always():
    contacts = [dict(FRONT, on_open_prompt="Turn on the hall light"), dict(BACK)]
    alarm, _clock, _ = setup(contacts=contacts)
    assert kinds(alarm.door_opened(contacts[0])) == ["prompt"]
    assert kinds(alarm.door_opened(contacts[1])) == ["push_info"]


def test_a_restart_mid_entry_resumes_the_same_deadline():
    alarm, clock, contacts = setup(settings={"exit_delay": 0, "entry_delay": 30, "siren_duration": 180})
    alarm.arm("away")
    alarm.door_opened(contact(contacts, "dp:front"))
    saved = alarm.snapshot()
    clock2 = [clock[0] + 20]
    again = Alarm({"exit_delay": 0, "entry_delay": 30, "siren_duration": 180}, contacts=lambda: contacts,
                  clock=lambda: clock2[0], state=saved)
    assert again.state == "entry"
    assert kinds(again.tick()) == []
    clock2[0] += 10
    assert "siren_on" in kinds(again.tick())


def test_a_restart_after_the_deadline_passed_triggers_on_the_first_tick():
    alarm, clock, contacts = setup(settings={"exit_delay": 0, "entry_delay": 30, "siren_duration": 180})
    alarm.arm("away")
    alarm.door_opened(contact(contacts, "dp:front"))
    later = [clock[0] + 600]
    again = Alarm({"exit_delay": 0, "entry_delay": 30, "siren_duration": 180}, contacts=lambda: contacts,
                  clock=lambda: later[0], state=alarm.snapshot())
    assert again.tick()[0].kind == "siren_on"


def test_public_view():
    alarm, clock, _ = setup()
    alarm.arm("away")
    view = alarm.public()
    assert view["state"] == "arming" and view["seconds_left"] == 60 and view["mode"] == "away"
