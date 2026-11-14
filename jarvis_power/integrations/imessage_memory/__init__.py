"""iMessage memory: the Mac uploads chats you pick; Jarvis turns them into memories.

Its old "enabled" setting IS this switch. Off: the Mac stops uploading (its /config
reports off and it's told to re-read at once), running backfills stop, the closer
idles, and the phone hides its screen, fact cards and fact pushes.
"""
from __future__ import annotations

from jarvis_power import Link, PowerIntegration, Setting


def _store():
    from api import imessage_memory
    return imessage_memory.store()


class IMessageMemory(PowerIntegration):
    id = "imessage-memory"
    name = "iMessage memory"
    icon = "bubble.left.and.text.bubble.right.fill"
    summary = "Your Mac sends the chats you pick; Jarvis remembers what matters in them."
    default_enabled = False
    processes = ("webui",)
    route_prefixes = ("/api/imessage-memory",)
    route_exempt = ("/api/imessage-memory/config",)
    surfaces = ("ios.integrations.imessage", "ios.chat.imessage_facts", "ios.push.imessage_facts",
                "web.integrations.imessage", "mac.tray.imessage")
    links = (Link("ios", "imessage", "Choose chats and review facts"),
             Link("web", "imessage", "Choose chats and review facts"))
    settings = (
        Setting("ask_facts", "Ask before storing new facts", "toggle", default=True, jarvis="ask"),
        Setting("push_facts", "Notify me about new facts", "toggle", default=True),
    )

    def seed_enabled(self) -> bool:
        return bool(_store().settings().get("enabled"))

    def start(self, process: str) -> None:
        st = _store()
        if not st.settings().get("enabled"):
            st.update_settings(enabled=True)
        self._tell_mac(st)

    def stop(self, process: str) -> None:
        st = _store()
        if st.settings().get("enabled"):
            st.update_settings(enabled=False)
        st.stop_active_jobs()                    # the Mac stops reading, so it would never finish
        self._tell_mac(st)

    @staticmethod
    def _tell_mac(st) -> None:
        try:
            from api.imessage_memory_routes import push_refresh
            push_refresh(st)
        except Exception:
            pass

    def read_settings(self) -> dict:
        current = _store().settings()
        return {s.key: bool(current.get(s.key, s.default)) for s in self.settings}

    def write_settings(self, changes: dict) -> None:
        _store().update_settings(**{k: bool(v) for k, v in changes.items()})

    def status_line(self) -> str:
        st = _store()
        picked = sum(1 for c in st.chats() if st.effective_pick(c, st.skip_keys(st.settings())))
        return f"{picked} chat{'s' if picked != 1 else ''} remembered"

    def state(self) -> dict:
        return {"status": self.status_line()}
