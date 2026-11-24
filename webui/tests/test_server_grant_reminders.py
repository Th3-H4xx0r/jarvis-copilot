"""server._run_grant_reminders: the every-few-hours check that reminds him before an "Unlock without Face ID"
permission ends; it must never take the server down."""
import server


def test_it_runs_the_power_store_check(monkeypatch):
    calls = []

    class Store:
        def grant_reminders(self):
            calls.append(1)
            return 1
    monkeypatch.setattr("api.mac_power.store", lambda: Store())
    server._run_grant_reminders()
    assert calls == [1]


def test_a_failure_is_swallowed(monkeypatch):
    def boom():
        raise RuntimeError("no store")
    monkeypatch.setattr("api.mac_power.store", boom)
    server._run_grant_reminders()   # no exception
