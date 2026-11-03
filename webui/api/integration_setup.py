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
         {name?, profile?}                    set a new integration up
         {space, mode: "ui", profile?}        change that integration's UI only
    GET  /api/integrations/setup/<sid>   -> what has been built so far
"""
from __future__ import annotations

import logging
from typing import Optional

logger = logging.getLogger(__name__)

# Enough to build an integration, and nothing that could wander off into the
# filesystem or the network while doing it.
# The real toolset keys — a name that is not a key in TOOLSETS is dropped without
# a word, and the session would quietly have no way to make a schedule.
SETUP_TOOLSETS = ["registry", "cronjob", "skills", "forms"]

DIRECTIVE = """\
You are setting up ONE new Jarvis integration with the user, in a dedicated sheet \
in the app. This is the only thing this conversation is for.

An integration is a named space in the central registry plus the schedules and \
skills that belong to it. Build it with the tools you have:
  - `integration_create` FIRST, to make the space and get its id. Every other \
registry tool writes into a space that already exists, so until you call this there \
is nowhere to put anything — and writing into "general", the catch-all for things \
that belong nowhere, is not setting up an integration.
  - registry_describe / registry_put / registry_append to say what it holds
  - `cronjob` with action=create to add the schedules it needs, always passing this \
integration's space id
  - `skill_manage` with action=create to write a skill when one would help, with \
`integration: <space id>` in its front matter so it belongs here

How to run the conversation:
  - Ask for what you genuinely need and nothing more. When you need more than \
one answer, or an answer is a choice from a short list, call `form_ask` and let \
them fill in boxes — it is far less work than answering a paragraph of questions. \
One short question in prose is fine when there is only one. If the user has \
already told you something, do not ask again.
  - Create each piece as soon as it is settled, rather than saving it all for the \
end. The user is watching them appear.
  - Keep your messages short. This is a setup sheet, not a chat.
  - Do NOT call `integration_plan_propose` here. That tool draws a plan card for the user to approve in an ordinary chat; in this sheet you build the thing itself, and a card asking them to approve what you are already doing is only confusing.
  - An integration is not set up until something RUNS in it. If the user asked you \
to watch, track, monitor or tell them about something, that means a SCHEDULE — a \
skill describing the work is instructions nobody is following, and a settings \
document is not a tracker. Write the skill if it helps you do the work well, then \
create the schedule that actually does it.
  - Once its data, schedules and skills exist, give it its own UI: a compact card on \
the Integrations tab and a page at the top of its screen. First read the \
`integration-ui` skill with `skill_view` (and its references/elements.md). Then ask \
ONCE — a `form_ask` is fine — what they would like to see and do on the card and on \
the page, or whether they would rather skip a UI. If they skip, move on. Otherwise \
build it from that skill's elements with a `load` script and one script per action, \
store it with `integration_ui_set`, and check that load works (the state it returns \
has what the card and page bind to). Fix and set it again until it does.
  - When everything is in place, call `integration_ready` with the space id you got \
from `integration_create` and a one-line summary. It will refuse an integration \
that has neither a schedule nor a skill, because that one does not work yet. Never \
call it for "general".
"""


UI_DIRECTIVE = """\
You are changing the UI of ONE existing Jarvis integration, space id "{space}", with \
the user, in a dedicated sheet in the app. This is the only thing this conversation \
is for: change only this integration's UI — its card on the Integrations tab and its \
page. Do not create integrations, schedules or skills, and do not change other data \
unless an action script you write needs to.

How to do it:
  - Read the `integration-ui` skill with `skill_view` (and its references/elements.md) \
before you design anything.
  - Call `integration_ui_get` with space "{space}" FIRST to see the UI as it is now \
(it may have none yet) and the `prompt` it was built from. `registry_catalog` with \
space "{space}" shows the data it can show.
  - Ask only what you genuinely need; one short question, or a `form_ask` for several.
  - Build the change and store it with `integration_ui_set`, sending the WHOLE UI \
(card, page and every script) — anything left out is removed. Keep `prompt` up to \
date: what they asked for originally plus what they just changed. Check the load \
state it returns; if load failed, fix it and set it again.
  - When it is stored and loads, finish with a one- or two-line summary of what \
changed. Do not call `integration_ready`; this integration is already set up.
  - Keep your messages short. This is a sheet, not a chat.
"""


def start(name: str = "", profile: Optional[str] = None, space: str = "",
          mode: str = "") -> dict:
    """A session pinned to this job. Returns what the sheet needs to talk to it.

    The profile comes from the client that opened the sheet, like every other
    session: two tabs on different profiles must not clobber each other, and the
    run resolves its home from it — a session on the wrong profile builds the
    integration somewhere the page that asked for it will never look.
    """
    from api.models import new_session

    session = new_session(profile=profile or None)
    session.enabled_toolsets = list(SETUP_TOOLSETS)
    session.integration_setup = True
    if mode == "ui":
        # Editing an existing integration's UI: same sheet, a narrower job.
        session.integration_ui_space = space
        session.title = f"Editing the {name or space} UI"
    else:
        session.title = f"Setting up {name}" if name else "New integration"
    # Deliberately not saved: new_session() keeps a session in memory until its
    # first message precisely so an abandoned one leaves nothing behind, and the
    # + button is easy to tap and change your mind about.
    return {"session_id": session.session_id, "title": session.title}


def directive_for(session) -> str:
    """The system directive for a setup session, or "" for an ordinary one."""
    if not getattr(session, "integration_setup", False):
        return ""
    space = str(getattr(session, "integration_ui_space", "") or "").strip()
    if space:
        return UI_DIRECTIVE.format(space=space)
    return DIRECTIVE


# ── HTTP ─────────────────────────────────────────────────────────────────────
def handle_post(handler, parsed, body) -> bool:
    from api.helpers import j

    if parsed.path != "/api/integrations/setup/start":
        return False
    try:
        body = body if isinstance(body, dict) else {}
        mode = str(body.get("mode") or "").strip()
        space = str(body.get("space") or "").strip().lower()
        if mode and mode != "ui":
            j(handler, {"error": "mode must be 'ui' or absent"}, status=400)
            return True
        if mode == "ui":
            if not space:
                j(handler, {"error": "space is required to edit an integration's UI"},
                  status=400)
                return True
            from jarvis_registry.store import shared

            name = ""
            try:
                name = str(shared().open(space).info().get("name") or "")
            except Exception:
                j(handler, {"error": f"no integration named {space!r}"}, status=404)
                return True
            j(handler, start(name, profile=str(body.get("profile") or "").strip() or None,
                             space=space, mode="ui"), status=201)
            return True
        j(handler, start(str(body.get("name") or "").strip(),
                         profile=str(body.get("profile") or "").strip() or None), status=201)
    except Exception as exc:
        logger.warning("integration setup could not start", exc_info=True)
        j(handler, {"error": str(exc)}, status=500)
    return True
