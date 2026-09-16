"""Setting an integration up by talking to Jarvis.

The + button on the Integrations page does not open a form. It opens a session
with the real agent, scoped to this one job: a system directive that says what it
is doing, and a toolset that reaches the registry, the scheduler and the skill
authoring tools and nothing else. Follow-up questions are just its turns.

Each piece is created as it is settled rather than proposed and approved at the
end — the user watches it being built. When the agent is finished it calls
``integration_ready``, which is how the sheet knows to stop offering a composer
and offer Close instead.

    POST /api/integrations/setup/start   -> {session_id}
    GET  /api/integrations/setup/<sid>   -> what has been built so far
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

# Enough to build an integration, and nothing that could wander off into the
# filesystem or the network while doing it.
# The real toolset keys — a name that is not a key in TOOLSETS is dropped without
# a word, and the session would quietly have no way to make a schedule.
SETUP_TOOLSETS = ["registry", "cronjob", "skills"]

DIRECTIVE = """\
You are setting up ONE new Jarvis integration with the user, in a dedicated sheet \
in the app. This is the only thing this conversation is for.

An integration is a named space in the central registry plus the schedules and \
skills that belong to it. Build it with the tools you have:
  - registry_put / registry_append / registry_describe to create its space and say \
what each collection holds
  - `cronjob` with action=create to add the schedules it needs, always passing this \
integration's space id
  - `skill_manage` with action=create to write a skill when one would help, with \
`integration: <space id>` in its front matter so it belongs here

How to run the conversation:
  - Ask for what you genuinely need and nothing more. One short question at a \
time. If the user has already told you something, do not ask again.
  - Create each piece as soon as it is settled, rather than saving it all for the \
end. The user is watching them appear.
  - Keep your messages short. This is a setup sheet, not a chat.
  - Do NOT call `integration_plan_propose` here. That tool draws a plan card for the user to approve in an ordinary chat; in this sheet you build the thing itself, and a card asking them to approve what you are already doing is only confusing.
  - When everything is in place, call `integration_ready` with the space id and a \
one-line summary. Do not call it before something exists.
"""


def start(name: str = "") -> dict:
    """A session pinned to this job. Returns what the sheet needs to talk to it."""
    from api.models import new_session

    session = new_session()
    session.enabled_toolsets = list(SETUP_TOOLSETS)
    session.integration_setup = True
    session.title = f"Setting up {name}" if name else "New integration"
    session.save()
    return {"session_id": session.session_id, "title": session.title}


def directive_for(session) -> str:
    """The system directive for a setup session, or "" for an ordinary one."""
    return DIRECTIVE if getattr(session, "integration_setup", False) else ""


# ── HTTP ─────────────────────────────────────────────────────────────────────
def handle_post(handler, parsed, body) -> bool:
    from api.helpers import j

    if parsed.path != "/api/integrations/setup/start":
        return False
    try:
        j(handler, start(str((body or {}).get("name") or "").strip()), status=201)
    except Exception as exc:
        logger.warning("integration setup could not start", exc_info=True)
        j(handler, {"error": str(exc)}, status=500)
    return True
